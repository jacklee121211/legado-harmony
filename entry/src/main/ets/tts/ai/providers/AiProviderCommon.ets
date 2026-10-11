/**
 * AI TTS 服务商共享工具（自研）。
 *
 * 这里只放**跨厂商复用**的纯函数：鉴权头、URL 兜底、参数换算、请求 ID。
 * 厂商特有的协议（URL / 请求体 / 响应解析）一律留在各自的 provider 文件里，
 * 便于单家改动不影响其他家（审查要点：改 A 不碰 B）。
 */
import { util } from '@kit.ArkTS';
import { AiProviderMeta, AiTtsConfig } from '../AiTtsTypes';

/** Bearer 鉴权（DashScope / MiniMax 用） */
export function bearerHeaders(cfg: AiTtsConfig): Record<string, string> {
  const h: Record<string, string> = {};
  h['Content-Type'] = 'application/json';
  const k: string = cfg.apiKey.trim();
  if (k.length > 0) {
    h['Authorization'] = 'Bearer ' + k;
  }
  return h;
}

/** 自定义鉴权头（小米 MiMo 用 `api-key`） */
export function apiKeyHeader(cfg: AiTtsConfig, headerName: string): Record<string, string> {
  const h: Record<string, string> = {};
  h['Content-Type'] = 'application/json';
  const k: string = cfg.apiKey.trim();
  if (k.length > 0) {
    h[headerName] = k;
  }
  return h;
}

/** 用户填的 baseUrl 优先，否则回落厂商默认地址 */
export function baseUrlOf(cfg: AiTtsConfig, meta: AiProviderMeta): string {
  const b: string = cfg.baseUrl.trim();
  return b.length > 0 ? b : meta.defaultBaseUrl;
}

export function clampNum(v: number, lo: number, hi: number): number {
  if (!Number.isFinite(v)) {
    return lo;
  }
  return Math.max(lo, Math.min(hi, v));
}

/**
 * `.../v1` 风格地址拼接（MiniMax / 小米这类以 `/v1` 为根的厂商）。
 * 容错：用户只填 `https://api.minimaxi.com` 时自动补 `/v1`
 *（真机反馈里"地址少写一段"是最常见的输入错误之一）。
 */
export function v1Join(base: string, tail: string): string {
  let b: string = base.trim();
  while (b.endsWith('/')) {
    b = b.substring(0, b.length - 1);
  }
  if (!/\/v\d+$/.test(b)) {
    b = b + '/v1';
  }
  return b + (tail.startsWith('/') ? tail : '/' + tail);
}

/** 请求 ID（火山要求 `X-Api-Request-Id`） */
export function uuidLike(): string {
  try {
    return util.generateRandomUUID(false);
  } catch (e) {
    return 'ai' + Date.now() + '-' + Math.floor(Math.random() * 1e9);
  }
}

/**
 * 把「附加请求体 JSON」合并进基础 body（**所有厂商统一走这里**）。
 *
 * 做法：字符串级合并（去掉外层花括号后追加），最后用 `JSON.parse` 做一次**强校验**——
 * 避开 ArkTS 下动态对象合并的类型限制，同时保证不把非法 JSON 发出去。
 * ⚠️ 同名 key 会重复出现，JSON 语义为"后者生效"⇒ 用户可借此**覆盖我们生成的字段**
 *    （例如把 `language_type` 改成 `English`，或补中转站特有字段）。
 *
 * 历史（2026-10-11）：旧版这个函数只被 OpenAI 兼容 provider 使用，
 * 通义/火山/MiniMax/MiMo **完全不读** `cfg.extraBody`，
 * 但 UI 对五家都渲染「附加请求体」输入框 ⇒ **假控件**（填了没用）。
 * 现在收敛到本函数，四家 provider 在构造完 body 后统一调用。
 */
export function appendExtraBody(baseBody: string, extra: string): string {
  const t: string = extra.trim();
  if (t.length === 0) {
    return baseBody;
  }
  let inner: string = t;
  if (inner.startsWith('{')) {
    if (!inner.endsWith('}')) {
      throw new Error('附加请求体 JSON 不完整（缺少右花括号）');
    }
    inner = inner.substring(1, inner.length - 1).trim();
  }
  while (inner.endsWith(',')) {
    inner = inner.substring(0, inner.length - 1).trim();
  }
  const merged: string = inner.length === 0
    ? baseBody
    : baseBody.substring(0, baseBody.length - 1) + ',' + inner + '}';
  try {
    JSON.parse(merged);
  } catch (e) {
    throw new Error('附加请求体 JSON 解析失败：' + (e instanceof Error ? e.message : String(e)));
  }
  return merged;
}

/**
 * 追加用户自定义请求头（行式 `Key: Value`）。**所有厂商统一走这里**。
 * 空行与 `#` 开头的行忽略；可覆盖已有的同名头（如换鉴权方式）。
 *
 * 历史（2026-10-11）：旧版只被 OpenAI 兼容 provider 使用，其余四家是假控件（同 appendExtraBody）。
 */
export function applyExtraHeaders(cfg: AiTtsConfig, into: Record<string, string>): void {
  const raw: string = cfg.extraHeaders;
  if (raw.trim().length === 0) {
    return;
  }
  const lines: string[] = raw.split('\n');
  for (let i = 0; i < lines.length; i++) {
    const line: string = lines[i].trim();
    if (line.length === 0 || line.startsWith('#')) {
      continue;
    }
    const idx: number = line.indexOf(':');
    if (idx <= 0) {
      continue;
    }
    const k: string = line.substring(0, idx).trim();
    const v: string = line.substring(idx + 1).trim();
    if (k.length > 0) {
      into[k] = v;
    }
  }
}
