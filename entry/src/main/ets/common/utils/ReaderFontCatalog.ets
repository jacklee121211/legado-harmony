/**
 * 「内置字体库」目录（2026-10-24 新增）—— 远端字体清单 + 本地缓存 + 下载直链。
 *
 * ── 为什么要做（需求原文）───────────────────────────────────────────────────
 * 「我需要做一个内置库……因为如果直接写入项目，安装包会巨大，这种方式更为舒服」
 * ⇒ 字体文件**不打进 HAP**（5 支合计约 69MB，OPPO Sans 单支 21.7MB），
 *   只在字体列表里以「灰色 + 下载图标」的形式露出来，点了才下载落库。
 *   落库后由 `ReaderFontLib` 接管（沙箱文件 + Preferences 登记表），与导入/直链下载
 *   完全同一条持久化链路。
 *
 * ── 仓库取证（2026-10-24 实测）─────────────────────────────────────────────
 * · 目录 API：`https://api.gitcode.com/api/v5/repos/jacklee1202/oepnfonts/contents/`
 *   → JSON 数组，每项 `{type,name,path,sha,download_url,...}`；
 * · **`download_url` 才是真直链**：`https://raw.gitcode.com/<owner>/<repo>/blobs/<sha>/<name>`
 *   —— 实测 5 支全部 200、`application/octet-stream`、魔数与体积都对得上；
 * · ⚠️ `https://raw.gitcode.com/<owner>/<repo>/raw/main/<name>` 这种**分支式直链 403**，
 *   不要用（这正是用户「输入直链下载失败」的同类坑：贴了网页/分支地址拿回 HTML）；
 * · 仓库页 `https://gitcode.com/jacklee1202/oepnfonts` 本身是 **HTML**，
 *   直接当直链用必然失败 —— 所以这里统一由 API 取 `download_url`，不让用户自己拼。
 *
 * ── 清单从哪来（刷新策略，2026-10-24 定稿）─────────────────────────────────
 * **全部来自远端同步拉取，不做任何硬编码**（用户要求：「内置库不要硬解，就要这种同步拉取」）：
 * ① `refreshIfStale()`：**每次打开字体管理都会调用**，距上次成功刷新 >5 分钟才真联网
 *    （拉目录 API，拿到 `download_url` + `sha`）；
 * ② `refreshNow()`：列表里「内置字体库」右边的手动刷新图标，**无视 TTL 立即拉取**；
 * ③ 结果缓存进 Preferences（`ReaderFontCatalog`），冷启动先读缓存、过期再刷新；
 * ④ 首次进入且无网络 ⇒ 清单为空（**已安装字体不受影响**，它们来自本地登记表）。
 *
 * 为什么必须能刷新：blobs 直链里带 commit sha，字体一更新 sha 就变 ⇒
 * 写死的链接迟早 404；而且「上游换了字体文件」只能靠对比 sha 才能发现。
 * 上游往仓库里加一支字体，用户下次打开字体管理就能看到，不用发版。
 *
 * ⚠️ 本文件是**唯一**允许在字体模块里 import `http` 的地方：
 *    `ReaderFontLib` 保持「零网络依赖」（精简模式离线可用的设计前提，见
 *    `OfflineMode.ets:68` 的取证注释）。目录刷新失败一律静默降级到缓存。
 */

import { http } from '@kit.NetworkKit';
import { PreferencesUtil } from '@pura/harmony-utils';
import { hilog } from '@kit.PerformanceAnalysisKit';

/** 一条内置库字体（未下载时在列表里显示为灰色 + 下载图标） */
export interface CatalogFont {
  /** 仓库内文件名（含扩展名）＝ **唯一键**；与 `ReaderFontLib.normKey()` 对齐后做智能合并 */
  key: string;
  /** 展示名（下载入库时作为字体显示名） */
  name: string;
  /** 真直链（raw blobs） */
  url: string;
  /** 字节数（0 = 未知；仅用于列表上的体积提示） */
  size: number;
  /**
   * 上游**版本指纹**（仓库 blob sha，2026-10-24 新增）。
   *
   * 用途：判断"本地这份是不是旧版本" —— 安装时把当时的 sha 存进
   * `FontLibItem.catalogSha`，与这里当前 sha 一比就知道上游有没有换过字体文件。
   */
  sha: string;
}

/** 目录 API 的单项（只取用到的字段） */
interface CatalogApiItem {
  type: string;
  name: string;
  path: string;
  download_url: string;
  sha: string;
}

/** 缓存结构 */
interface CatalogCache {
  updatedAt: number;
  items: CatalogFont[];
}

export class ReaderFontCatalog {
  /** 仓库归属（用户提供：https://gitcode.com/jacklee1202/oepnfonts） */
  static readonly OWNER: string = 'jacklee1202';
  static readonly REPO: string = 'oepnfonts';
  /** 目录 API（实测返回 application/json 数组） */
  static readonly API: string =
    'https://api.gitcode.com/api/v5/repos/jacklee1202/oepnfonts/contents/';
  /** 缓存键 */
  private static readonly KEY: string = 'ReaderFontCatalog';
  /**
   * 自动刷新间隔（5 分钟，2026-10-24 由 7 天收紧）。
   *
   * 用户要求「每次进入字体管理是否会自动刷新拉取」—— 现在**每次打开弹窗都会检查**，
   * 距上次成功刷新超过这个间隔就联网拉一次（目录只有 ~2.7KB，开销可忽略）；
   * 短时间反复开关弹窗则走缓存，避免把 API 打出限流。
   * 想立刻强制拉取 ⇒ 点列表里「内置字体库」右边的手动刷新图标（`refreshNow()`）。
   */
  private static readonly TTL_MS: number = 5 * 60 * 1000;

  /**
   * ⚠️ **不硬编码字体清单**（2026-10-24 用户明确要求：「内置库不要硬解，就要这种同步拉取」）。
   *
   * 清单的**唯一来源**是仓库目录 API（`ReaderFontCatalog.API`）：
   * 上游往 `jacklee1202/oepnfonts` 里加一支字体，用户下次打开字体管理就能看到，
   * 不用发版。代价是首次进入需要联网（离线/接口挂了 ⇒ 清单为空，已安装的字体照常可用，
   * 因为已安装项来自本地登记表 `ReaderFontLib`，与目录无关）。
   *
   * ⇒ 展示名直接用仓库里的文件名去扩展名（`MiSans-Regular` → `MiSans-Regular`），
   *   不做"中文别名映射"，避免又变相硬编码。
   */

  /** 缓存的内存副本（避免一次会话里反复读 Preferences） */
  private static memo: CatalogFont[] | null = null;
  /** 是否正在刷新（并发去重：弹窗重开不重复打网络） */
  private static refreshing: boolean = false;
  /** 上一次刷新是否失败（UI 用来给手动刷新一个准确的 toast） */
  private static lastFailed: boolean = false;

  /** 体积文案（'7.7 MB'） */
  static sizeText(size: number): string {
    if (size <= 0) {
      return '';
    }
    const mb: number = size / (1024 * 1024);
    if (mb >= 1) {
      return mb.toFixed(1) + ' MB';
    }
    return Math.max(1, Math.round(size / 1024)) + ' KB';
  }

  /** 当前可用清单：内存 → 缓存 → 空（**不再有硬编码基线**） */
  static load(): CatalogFont[] {
    if (ReaderFontCatalog.memo !== null) {
      return ReaderFontCatalog.memo;
    }
    const cached: CatalogCache | null = ReaderFontCatalog.readCache();
    const list: CatalogFont[] = (cached !== null && cached.items.length > 0) ? cached.items : [];
    ReaderFontCatalog.memo = list;
    return list;
  }

  /** 缓存是否过期（没有缓存也算过期） */
  static isStale(): boolean {
    const cached: CatalogCache | null = ReaderFontCatalog.readCache();
    if (cached === null || cached.items.length === 0) {
      return true;
    }
    return (Date.now() - cached.updatedAt) > ReaderFontCatalog.TTL_MS;
  }

  /**
   * 过期才联网刷新（弹窗打开时调用）。**永不 reject**：失败就用现有清单。
   * 返回刷新后的清单，调用方直接拿去渲染即可。
   */
  static refreshIfStale(): Promise<CatalogFont[]> {
    if (!ReaderFontCatalog.isStale() || ReaderFontCatalog.refreshing) {
      return Promise.resolve(ReaderFontCatalog.load());
    }
    return ReaderFontCatalog.doRefresh();
  }

  /**
   * **强制**联网刷新（列表里那个手动刷新图标）。
   * 与 `refreshIfStale()` 共用同一套并发去重：正在刷新时再点，直接复用当前结果。
   */
  static refreshNow(): Promise<CatalogFont[]> {
    if (ReaderFontCatalog.refreshing) {
      return Promise.resolve(ReaderFontCatalog.load());
    }
    return ReaderFontCatalog.doRefresh();
  }

  private static doRefresh(): Promise<CatalogFont[]> {
    ReaderFontCatalog.refreshing = true;
    return new Promise<CatalogFont[]>((resolve: (v: CatalogFont[]) => void) => {
      ReaderFontCatalog.fetchRemote().then((items: CatalogFont[]) => {
        ReaderFontCatalog.refreshing = false;
        if (items.length > 0) {
          ReaderFontCatalog.lastFailed = false;
          ReaderFontCatalog.memo = items;
          ReaderFontCatalog.writeCache(items);
          resolve(items);
        } else {
          // 接口通了但没解析出字体（或 HTTP 非 2xx）⇒ 记一次失败，UI 好给准确提示
          ReaderFontCatalog.lastFailed = true;
          resolve(ReaderFontCatalog.load());
        }
      }).catch((e: Object) => {
        ReaderFontCatalog.refreshing = false;
        ReaderFontCatalog.lastFailed = true;
        hilog.warn(0x0000, 'ReaderFontCatalog', 'refresh failed, fallback to cache: %{public}s',
          e instanceof Error ? e.message : String(e));
        resolve(ReaderFontCatalog.load());
      });
    });
  }

  /** 是否正在联网刷新（UI 用来显示转圈） */
  static isRefreshing(): boolean {
    return ReaderFontCatalog.refreshing;
  }

  /** 上一次刷新是否失败（`refreshNow()` 之后用来决定 toast 文案） */
  static didLastRefreshFail(): boolean {
    return ReaderFontCatalog.lastFailed;
  }

  /** 上次成功刷新的时间戳（0 = 从未） */
  static lastUpdatedAt(): number {
    const cached: CatalogCache | null = ReaderFontCatalog.readCache();
    return cached !== null ? cached.updatedAt : 0;
  }

  /**
   * 拉目录 API → 归一化成 `CatalogFont[]`。
   * 展示名 = 文件名去扩展名（**不做中文别名映射**，避免变相硬编码）。
   */
  private static fetchRemote(): Promise<CatalogFont[]> {
    return new Promise<CatalogFont[]>((resolve: (v: CatalogFont[]) => void) => {
      const req = http.createHttp();
      req.request(ReaderFontCatalog.API, {
        method: http.RequestMethod.GET,
        expectDataType: http.HttpDataType.STRING,
        connectTimeout: 10000,
        readTimeout: 15000,
        header: { 'Accept': 'application/json' }
      }).then((resp: http.HttpResponse) => {
        req.destroy();
        if (resp.responseCode < 200 || resp.responseCode >= 300) {
          hilog.warn(0x0000, 'ReaderFontCatalog', 'api HTTP %{public}d', resp.responseCode);
          resolve([]);
          return;
        }
        const raw: string = resp.result as string;
        const list: CatalogFont[] = ReaderFontCatalog.parseApi(raw);
        hilog.info(0x0000, 'ReaderFontCatalog', 'api ok, %{public}d fonts', list.length);
        resolve(list);
      }).catch((e: Object) => {
        req.destroy();
        hilog.warn(0x0000, 'ReaderFontCatalog', 'api request failed: %{public}s',
          e instanceof Error ? e.message : String(e));
        resolve([]);
      });
    });
  }

  /** 解析 API JSON（坏数据一律跳过，绝不把半截数据交给 UI） */
  static parseApi(raw: string): CatalogFont[] {
    const out: CatalogFont[] = [];
    try {
      const arr = JSON.parse(raw) as CatalogApiItem[];
      if (!Array.isArray(arr)) {
        return out;
      }
      for (const it of arr) {
        if (it === null || it === undefined) {
          continue;
        }
        if (typeof it.type !== 'string' || it.type !== 'file') {
          continue;
        }
        const name: string = typeof it.name === 'string' ? it.name : '';
        const url: string = typeof it.download_url === 'string' ? it.download_url : '';
        if (name.length === 0 || url.length === 0) {
          continue;
        }
        if (!ReaderFontCatalog.isFontName(name)) {
          continue;
        }
        out.push({
          key: name,
          name: ReaderFontCatalog.displayName(name),
          url: url,
          // 目录 API 不返回文件体积 ⇒ 0（UI 就不显示体积，只显示"点击下载"）
          size: 0,
          sha: typeof it.sha === 'string' ? it.sha : ''
        });
      }
    } catch (e) {
      hilog.warn(0x0000, 'ReaderFontCatalog', 'parseApi failed: %{public}s',
        e instanceof Error ? e.message : String(e));
    }
    return out;
  }

  /** 只收字体扩展名（目录里以后可能混进 README/图片） */
  private static isFontName(name: string): boolean {
    const s: string = name.toLowerCase();
    return s.endsWith('.ttf') || s.endsWith('.otf') || s.endsWith('.woff2');
  }

  /** 展示名 = 文件名去扩展名（完全跟着仓库走，无任何硬编码映射） */
  private static displayName(key: string): string {
    const dot: number = key.lastIndexOf('.');
    return dot > 0 ? key.substring(0, dot) : key;
  }

  // ── 缓存（Preferences）────────────────────────────────────────────────────

  private static readCache(): CatalogCache | null {
    let raw: string = '';
    try {
      raw = PreferencesUtil.getSync(ReaderFontCatalog.KEY, '') as string;
    } catch (e) {
      return null;
    }
    if (typeof raw !== 'string' || raw.length === 0) {
      return null;
    }
    try {
      const rec = JSON.parse(raw) as CatalogCache;
      if (rec === null || rec === undefined || !Array.isArray(rec.items)
        || typeof rec.updatedAt !== 'number') {
        return null;
      }
      const items: CatalogFont[] = [];
      for (const it of rec.items) {
        if (it !== null && it !== undefined && typeof it.key === 'string'
          && typeof it.name === 'string' && typeof it.url === 'string'
          && it.key.length > 0 && it.url.length > 0) {
          items.push({
            key: it.key,
            name: it.name,
            url: it.url,
            size: typeof it.size === 'number' ? it.size : 0,
            sha: typeof it.sha === 'string' ? it.sha : ''
          });
        }
      }
      if (items.length === 0) {
        return null;
      }
      return { updatedAt: rec.updatedAt, items: items };
    } catch (e) {
      return null;
    }
  }

  private static writeCache(items: CatalogFont[]): void {
    try {
      const rec: CatalogCache = { updatedAt: Date.now(), items: items };
      PreferencesUtil.putSync(ReaderFontCatalog.KEY, JSON.stringify(rec));
    } catch (e) {
      // 落盘失败不阻断 UI（下次开弹窗还会再试）
    }
  }
}
