/**
 * AI 音色清单缓存（2026-10-10，自研）。
 *
 * 需求（用户原话）：「每次和服务端获取？获取之后缓存，出现变更再更新」。
 * 落地方案 = **拉取 → 落盘 → 按指纹/时间失效**，而不是每次合成前都拉：
 *   · 缓存键（指纹）= `providerId|baseUrl`；换服务商或换地址**立即失效**；
 *   · 时间失效：超过 {@link AI_CATALOG_TTL_MS}（7 天）视为过期，UI 提示可刷新；
 *   · **只在用户点「拉取/刷新」时联网**（不自动后台拉，符合"用户主动发起"的合规口径）；
 *   · 拉不到 ⇒ UI 回落内置建议值 + 手填（保命线，见方案 §13.2 的 UI 规则）。
 *
 * 存储：Preferences（与 TtsPrefs 同一套机制，`@pura/harmony-utils` 的 PreferencesUtil）。
 * 上限 {@link AI_CATALOG_MAX_FP} 个指纹，超出淘汰最旧。
 */
import { PreferencesUtil } from '@pura/harmony-utils';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { AiTtsConfig, AiVoiceOption } from './AiTtsTypes';

const TAG: string = 'AiVoiceCatalog';
const DOMAIN: number = 0x0001;
const KEY: string = 'AiVoiceCatalog';
/** 过期时间：7 天（音色表变化极低频；到期只提示，不自动联网） */
export const AI_CATALOG_TTL_MS: number = 7 * 24 * 60 * 60 * 1000;
/** 最多记住几个服务商指纹 */
const AI_CATALOG_MAX_FP: number = 5;

interface CatalogEntry {
  fp: string;
  fetchedAt: number;
  voices: AiVoiceOption[];
}

interface CatalogRoot {
  entries: CatalogEntry[];
}

/** 缓存指纹：服务商 + 接口地址（地址变了就必须重拉） */
export function aiCatalogFp(cfg: AiTtsConfig): string {
  return cfg.providerId.trim() + '|' + cfg.baseUrl.trim();
}

function readRoot(): CatalogRoot {
  const empty: CatalogRoot = { entries: [] };
  try {
    const raw = PreferencesUtil.getSync(KEY, '') as Object;
    if (typeof raw !== 'string' || (raw as string).length === 0) {
      return empty;
    }
    const parsed = JSON.parse(raw as string) as Record<string, Object>;
    const arr = parsed['entries'];
    if (!Array.isArray(arr)) {
      return empty;
    }
    const src = arr as Array<Object>;
    const entries: CatalogEntry[] = [];
    for (let i = 0; i < src.length; i++) {
      const e = src[i] as Record<string, Object>;
      const fp = e['fp'];
      const at = e['fetchedAt'];
      const vs = e['voices'];
      if (typeof fp !== 'string' || typeof at !== 'number' || !Array.isArray(vs)) {
        continue;
      }
      const voices: AiVoiceOption[] = [];
      const vsrc = vs as Array<Object>;
      for (let j = 0; j < vsrc.length; j++) {
        const v = vsrc[j] as Record<string, Object>;
        const id = v['id'];
        if (typeof id !== 'string' || (id as string).length === 0) {
          continue;
        }
        const lb = v['label'];
        const ds = v['description'];
        const gd = v['gender'];
        const item: AiVoiceOption = {
          id: id as string,
          label: typeof lb === 'string' ? (lb as string) : (id as string),
          description: typeof ds === 'string' ? (ds as string) : '',
          gender: typeof gd === 'string' ? (gd as string) : ''
        };
        voices.push(item);
      }
      const entry: CatalogEntry = {
        fp: fp as string,
        fetchedAt: at as number,
        voices: voices
      };
      entries.push(entry);
    }
    const root: CatalogRoot = { entries: entries };
    return root;
  } catch (e) {
    hilog.warn(DOMAIN, TAG, 'read err: %{public}s', e instanceof Error ? e.message : String(e));
    return empty;
  }
}

function writeRoot(root: CatalogRoot): void {
  try {
    PreferencesUtil.putSync(KEY, JSON.stringify(root));
  } catch (e) {
    hilog.warn(DOMAIN, TAG, 'write err: %{public}s', e instanceof Error ? e.message : String(e));
  }
}

/** 读缓存（同步、无网络）。返回空数组 = 没有该指纹的缓存 */
export function loadAiCatalog(cfg: AiTtsConfig): AiVoiceOption[] {
  const fp: string = aiCatalogFp(cfg);
  const root: CatalogRoot = readRoot();
  for (let i = 0; i < root.entries.length; i++) {
    if (root.entries[i].fp === fp) {
      return root.entries[i].voices;
    }
  }
  return [];
}

/** 上次拉取时间（0 = 从未拉过） */
export function aiCatalogFetchedAt(cfg: AiTtsConfig): number {
  const fp: string = aiCatalogFp(cfg);
  const root: CatalogRoot = readRoot();
  for (let i = 0; i < root.entries.length; i++) {
    if (root.entries[i].fp === fp) {
      return root.entries[i].fetchedAt;
    }
  }
  return 0;
}

/** 是否过期（没缓存也算"需要刷新"） */
export function aiCatalogStale(cfg: AiTtsConfig): boolean {
  const at: number = aiCatalogFetchedAt(cfg);
  if (at <= 0) {
    return true;
  }
  return Date.now() - at > AI_CATALOG_TTL_MS;
}

/** 写入缓存（同指纹覆盖；超出上限淘汰最旧） */
export function saveAiCatalog(cfg: AiTtsConfig, voices: AiVoiceOption[]): void {
  if (voices.length === 0) {
    return;
  }
  const fp: string = aiCatalogFp(cfg);
  const root: CatalogRoot = readRoot();
  const kept: CatalogEntry[] = [];
  for (let i = 0; i < root.entries.length; i++) {
    if (root.entries[i].fp !== fp) {
      kept.push(root.entries[i]);
    }
  }
  const entry: CatalogEntry = { fp: fp, fetchedAt: Date.now(), voices: voices };
  kept.push(entry);
  // 超上限：按 fetchedAt 淘汰最旧
  kept.sort((a: CatalogEntry, b: CatalogEntry): number => a.fetchedAt - b.fetchedAt);
  while (kept.length > AI_CATALOG_MAX_FP) {
    kept.shift();
  }
  const next: CatalogRoot = { entries: kept };
  writeRoot(next);
  hilog.info(DOMAIN, TAG, 'saved fp=%{public}s voices=%{public}d total=%{public}d',
    fp, voices.length, kept.length);
}

/** 「上次更新」文案（给 UI 用） */
export function aiCatalogAgeText(cfg: AiTtsConfig): string {
  const at: number = aiCatalogFetchedAt(cfg);
  if (at <= 0) {
    return '未拉取过';
  }
  const ms: number = Date.now() - at;
  if (ms < 60 * 1000) {
    return '刚刚更新';
  }
  if (ms < 60 * 60 * 1000) {
    return Math.floor(ms / 60000) + ' 分钟前更新';
  }
  if (ms < 24 * 60 * 60 * 1000) {
    return Math.floor(ms / 3600000) + ' 小时前更新';
  }
  return Math.floor(ms / 86400000) + ' 天前更新';
}
