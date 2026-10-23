/**
 * 阅读器「字体库」（2026-09-26 新增）—— 字体清单 + 导入/下载/改名/删除 + ArkUI 侧注册。
 *
 * ── 官方取证（方案可行性）───────────────────────────────────────────────────
 * · 《修改阅读设置/自定义字体》（documentId `开发指南/Reader_Kit_阅读服务/书籍内容排版/
 *   修改阅读设置/自定义字体/reader-setting-font`）原文：
 *   「自定义字体文件支持两种存放路径：工程目录 resources/rawfile 文件夹。**应用沙箱目录**。」
 *   且示例 `fontName = '思源宋体'` 配 `SourceHanSerifCN-VF.ttf` ⇒ **fontName 是应用自定
 *   标签，不需要匹配字体文件内部族名**；格式 .ttf/.woff2/.otf（官方 isFont 示例）。
 *   ⇒ 用户导入 / 网络下载 = 把文件放进沙箱 + 登记，引擎侧零改动（resourceRequest 字体
 *     分支本就按 fontPath 读沙箱/绝对路径，真机验证过）。
 * · ArkUI 侧（弹窗预览 / 高亮测量通道）用 `@ohos.font.registerFont`：FAQ
 *   `FAQ/UI框架/UI界面/自定义字体的注册和使用/faqs-arkui-1064` 原文 —— familySrc 支持
 *   「**沙箱路径前加上 file://**」。本类 ensureRegistered 统一收口（幂等，内存去重）。
 *
 * ── 存储设计 ────────────────────────────────────────────────────────────────
 * · 字体文件：`filesDir/fonts/`（全局共用 —— 字体与书的排版无关，与「保存方案」同理）；
 * · 登记表：Preferences JSON `[{name, path, src}]`（src: 'import'|'download'）；
 * · 系统内置字体不进登记表（固定清单，路径取自真机 fontinfo 日志取证）；
 * · 「当前用哪支字体」**不入本类** —— 随 `readerSetting.fontName/fontPath` 按书持久化
 *   （现有机制），本类只管"库"。
 */
import { UIContext } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { PreferencesUtil } from '@pura/harmony-utils';
import { hilog } from '@kit.PerformanceAnalysisKit';

/** 一条字体登记项（系统内置项 src='system'，不入盘） */
export interface FontLibItem {
  /** 显示名（可改名）＝ ArkUI 注册族名 ＝ readerSetting.fontName */
  name: string;
  /** 字体文件路径：系统绝对路径 或 沙箱绝对路径 */
  path: string;
  /** 'system' 内置 / 'import' 导入 / 'download' 下载 */
  src: string;
  /**
   * 原始文件名（含扩展名，2026-10-24 新增）。
   *
   * 用途：与「内置字体库」做**智能合并** —— 判断"用户已装的这支字体，是不是
   * 内置库里那条"，靠文件名归一化（`normKey()`）比对，而不是靠可被用户改名的
   * `name`。老数据没有这个字段 ⇒ `registry()` 从 `path` 反推（去掉 `<ts>_` 前缀）。
   */
  file?: string;
  /** 来自内置库的哪一条（= 上游文件名）；'' / undefined = 不是内置库来的 */
  catalogKey?: string;
  /**
   * 本地这份文件对应的**上游版本指纹**（仓库 blob sha）。
   *
   * ⚠️ 只在「下载 / 更新」时写入，`syncCatalog()` **绝不覆盖** ——
   * 它就是「本地是不是旧版本」的唯一判据（`catalogSha !== 上游 sha` ⇒ 可更新）。
   */
  catalogSha?: string;
  /**
   * 用户是否在程序内改过名（`rename()` 会置 true）。
   *
   * 语义（用户 2026-10-24 定义）：改名过的字体**不再跟随上游改名**
   * ——「后续库的文件名称更新则无效」；没改过名的跟随上游更新。
   */
  renamed?: boolean;
}

/** 内置库条目的最小元数据（避免 ReaderFontLib 反向依赖 ReaderFontCatalog ⇒ 保持零网络依赖） */
export interface CatalogMeta {
  key: string;
  name: string;
  sha: string;
}

/** 上游改名导致的一次本地重命名（供调用方同步"正在使用"的引用） */
export interface FontRename {
  oldName: string;
  newName: string;
  path: string;
}


/**
 * 全局排版记录（2026-09-27「同步全局」拓展）：字体 + 字号 + 行距 三件套。
 * 语义与 `ReaderBgGlobal` 完全同构：不点同步全局则本书生效（本书进覆盖登记表），
 * 点了则全软件回落到这份全局记录（登记表清空）。
 */
export interface FontGlobalRecord {
  fontName: string;
  fontPath: string;
  fontSize: number;
  lineHeight: number;
}

export class ReaderFontLib {
  /** 登记表 Preferences 键 */
  static readonly KEY: string = 'ReaderFontLib';
  /** 默认字体（真机 fontinfo 日志取证：family=鸿蒙黑体, path=/system/fonts/HarmonyOS_Sans_SC.ttf） */
  static readonly DEFAULT_NAME: string = '鸿蒙黑体';
  static readonly DEFAULT_PATH: string = '/system/fonts/HarmonyOS_Sans_SC.ttf';
  /**
   * 内置系统字体（2026-09-26 定稿）：
   * · HarmonyOS Sans **移除** —— 无中文字形，中文全部回落，用户实测"两个像同一个"；
   * · 书宋-简（衬线）—— path 为空串 = 不走自定义字体管线，引擎按 `fontName` 匹配
   *   **系统族名**（该名来自真机系统字体清单日志：`sysfonts(1): ["书宋-简"]`）。
   *   ⚠️ 书宋-简的渲染效果【需真机验证】；不理想直接从本清单删掉即可，无副作用。
   */
  static readonly SYSTEM_FONTS: FontLibItem[] = [
    { name: '鸿蒙黑体', path: '/system/fonts/HarmonyOS_Sans_SC.ttf', src: 'system' },
    { name: '书宋-简', path: '', src: 'system' }
  ];
  /** 字体文件沙箱目录名 */
  private static readonly DIR: string = 'fonts';
  /** 登记条数保险丝（防失控；用户要求导入不设限 ⇒ 放宽到 200，实际很难碰到） */
  static readonly MAX_ITEMS: number = 200;
  /**
   * 单支字体文件体积上限（64MB，2026-10-24 与导入分支统一）。
   * 内置库最大的一支是 OPPO Sans 4.0（21.7MB），留足余量；再大的一律拒收，
   * 避免「下载 200MB 垃圾文件把沙箱塞满 + 全量进内存 OOM」。
   */
  static readonly MAX_FONT_BYTES: number = 64 * 1024 * 1024;

  /** 「同步全局」排版记录 / 字体覆盖登记表（2026-09-27 新增） */
  static readonly KEY_FONT_GLOBAL: string = 'ReaderFontGlobal';
  static readonly KEY_FONT_OVERRIDES: string = 'ReaderFontOverrides';

  // ── 全局排版（同步全局；语义与 ReaderBgGlobal 同构）────────────────────────

  /** 读全局排版记录；不存在/损坏 ⇒ null（调用方维持本书现状） */
  static loadFontGlobal(): FontGlobalRecord | null {
    let raw: string = '';
    try {
      raw = PreferencesUtil.getSync(ReaderFontLib.KEY_FONT_GLOBAL, '') as string;
    } catch (e) {
      return null;
    }
    if (typeof raw !== 'string' || raw.length === 0) {
      return null;
    }
    try {
      const rec = JSON.parse(raw) as FontGlobalRecord;
      if (rec === null || rec === undefined
        || typeof rec.fontName !== 'string' || typeof rec.fontPath !== 'string'
        || typeof rec.fontSize !== 'number' || typeof rec.lineHeight !== 'number') {
        return null;
      }
      return rec;
    } catch (e) {
      return null;
    }
  }

  static saveFontGlobal(rec: FontGlobalRecord): void {
    try {
      PreferencesUtil.putSync(ReaderFontLib.KEY_FONT_GLOBAL, JSON.stringify(rec));
    } catch (e) {
      // 落盘失败不阻断 UI
    }
  }

  /** 字体覆盖登记表（JSON string[]；损坏项剔除） */
  static fontOverrides(): string[] {
    let raw: string = '';
    try {
      raw = PreferencesUtil.getSync(ReaderFontLib.KEY_FONT_OVERRIDES, '') as string;
    } catch (e) {
      return [];
    }
    if (typeof raw !== 'string' || raw.length === 0) {
      return [];
    }
    try {
      const list = JSON.parse(raw) as string[];
      return Array.isArray(list) ? list : [];
    } catch (e) {
      return [];
    }
  }

  static fontInOverride(bookName: string): boolean {
    return ReaderFontLib.fontOverrides().includes(bookName);
  }

  static addFontOverride(bookName: string): void {
    if (bookName.length === 0) {
      return;
    }
    const list: string[] = ReaderFontLib.fontOverrides();
    if (list.includes(bookName)) {
      return;
    }
    list.push(bookName);
    try {
      PreferencesUtil.putSync(ReaderFontLib.KEY_FONT_OVERRIDES, JSON.stringify(list));
    } catch (e) {
      // 落盘失败不阻断 UI
    }
  }

  /** 清空字体覆盖登记表（「同步全局」用），返回清除的书名数 */
  static clearFontOverrides(): number {
    const list: string[] = ReaderFontLib.fontOverrides();
    try {
      PreferencesUtil.putSync(ReaderFontLib.KEY_FONT_OVERRIDES, '[]');
    } catch (e) {
      // 落盘失败不阻断 UI
    }
    return list.length;
  }

  /** ArkUI 侧已注册族名（内存去重；registerFont 异步且不支持并发，串行调用） */
  private static registered: Map<string, boolean> = new Map();

  static isFontFile(name: string): boolean {
    const s: string = name.toLowerCase();
    return s.indexOf('.ttf') >= 0 || s.indexOf('.otf') >= 0 || s.indexOf('.woff2') >= 0;
  }

  /**
   * 从 URL / 路径里取出**干净的文件基名**（去 query、去 hash、去目录、去扩展名、
   * 去非法字符、URL 解码）。空结果兜底成 `font_<ts>`。
   *
   * ⚠️ 为什么要有这个方法（2026-10-24 修 bug）：
   * 旧 `downloadNext()` 写的是
   *   `url.split('?')[0].substring(url.lastIndexOf('/') + 1)`
   * —— `lastIndexOf('/')` 在**完整 URL** 上算下标，却去 substring **去 query 后**的串。
   * query 里只要出现 `/`（如 `?path=/a.ttf`）下标就越界 ⇒ 文件名为空 ⇒ 直接判下载失败。
   */
  static baseName(fileName: string): string {
    let s: string = fileName;
    // ① 先切 query / hash（在**解码前**切，避免 %3F 之类被误解成查询串）
    const q: number = s.indexOf('?');
    if (q >= 0) {
      s = s.substring(0, q);
    }
    const h: number = s.indexOf('#');
    if (h >= 0) {
      s = s.substring(0, h);
    }
    // ② 去目录
    const slash: number = s.lastIndexOf('/');
    if (slash >= 0) {
      s = s.substring(slash + 1);
    }
    // ③ URL 解码（下载路径旧代码漏了这一步 ⇒ 中文名变成 %E5%AD%97%E4%BD%93）
    try {
      s = decodeURIComponent(s);
    } catch (e) {
      // 解码失败按原文处理
    }
    // ④ 去扩展名（`dot > 0`：`.ttf` 这种纯扩展名不当成有扩展名）
    const dot: number = s.lastIndexOf('.');
    if (dot > 0) {
      s = s.substring(0, dot);
    }
    // ⑤ 文件系统敏感字符替换
    s = s.replace(/[\\/:*?"<>|]/g, '_').trim();
    if (s.length === 0) {
      s = 'font_' + Date.now();
    }
    return s;
  }

  /** 取路径里的文件名（去目录，保留扩展名；去掉下载时加的 `<ts>_` 前缀） */
  static fileFromPath(path: string): string {
    const slash: number = path.lastIndexOf('/');
    let s: string = slash >= 0 ? path.substring(slash + 1) : path;
    const us: number = s.indexOf('_');
    if (us > 0) {
      const head: string = s.substring(0, us);
      if (head.length > 0 && /^[0-9]+$/.test(head)) {
        s = s.substring(us + 1);
      }
    }
    return s;
  }

  /**
   * **归一化键**（智能合并的唯一判据）：基名 → 小写 → 去掉空白/下划线/连字符/点/括号。
   *
   * `MiSans-Regular.ttf` / `misans_regular.otf` / `MiSans Regular` 三者同键
   * ⇒ 内置库里有的字体，用户再用直链下一遍，列表里**只会有一条**（自动合并）。
   */
  static normKey(nameOrPath: string): string {
    return ReaderFontLib.baseName(nameOrPath).toLowerCase()
      .replace(/[\s_\-\.()（）]/g, '');
  }

  /**
   * 按**魔数**判定真实字体格式，返回规范扩展名（'' = 不是字体）。
   *
   * 2026-10-24：下载分支改用「魔数定扩展名」而不是「信 URL 文件名」——
   * 直链常无扩展名（`.../download?id=123`），也可能带错扩展名。
   */
  static sniffFontExt(data: ArrayBuffer): string {
    if (data.byteLength < 4) {
      return '';
    }
    const b = new Uint8Array(data, 0, 4);
    if (b[0] === 0x00 && b[1] === 0x01 && b[2] === 0x00 && b[3] === 0x00) {
      return '.ttf';
    }
    const tag: string = String.fromCharCode(b[0], b[1], b[2], b[3]);
    if (tag === 'OTTO') {
      return '.otf';
    }
    if (tag === 'wOF2') {
      return '.woff2';
    }
    return '';
  }

  /**
   * 内容像不像网页（用于给"贴成了网页链接"这个最常见的失败场景一个准确提示）。
   * 判据：跳过 UTF-8 BOM 与前导空白后，首字节是 `<`。
   */
  static looksLikeHtml(data: ArrayBuffer): boolean {
    if (data.byteLength === 0) {
      return false;
    }
    const n: number = Math.min(data.byteLength, 512);
    const u = new Uint8Array(data, 0, n);
    let i: number = 0;
    if (n >= 3 && u[0] === 0xEF && u[1] === 0xBB && u[2] === 0xBF) {
      i = 3;
    }
    while (i < n && (u[i] === 0x20 || u[i] === 0x0A || u[i] === 0x0D || u[i] === 0x09)) {
      i++;
    }
    return i < n && u[i] === 0x3C; // '<'
  }

  /**
   * URL 百分号编码（**只补必须补的**，已编码的 `%XX` 原样保留）。
   *
   * ── 为什么必须有（2026-10-24 真机日志定案）───────────────────────────────
   * 内置库里的 `OPPO Sans 4.0.ttf` **文件名带空格**，直接把原串交给
   * `http.request()` ⇒ netstack 直接拒收，请求根本没发出去：
   *   `E [http_exec.cpp:2457] not a normalized URL`
   *   `E [http_exec.cpp:2483] get host and port failed`
   *   `E [http_exec.cpp:741]  CURLcode result 3`（CURLE_URL_MALFORMAT）
   *   `errCode:2300003, RespCode:0`
   * 用户侧看到的就是「网络请求失败」—— 其实跟网络一点关系都没有。
   * 其余 4 支字体文件名无空格 ⇒ 全部正常，这正是"只有 OPPO 失败"的原因。
   *
   * ⚠️ 不能用 `encodeURI()`：它会把已编码的 `%` 二次编码成 `%25`
   *   （`a%20b` → `a%2520b`），把好好的直链弄坏。所以这里只处理
   *   「可打印 ASCII 之外」的字符（空格、中文、控制符），`%` 落在
   *   `0x21..0x7E` 区间内 ⇒ 原样保留。
   */
  static encodeUrl(url: string): string {
    let out: string = '';
    let i: number = 0;
    while (i < url.length) {
      const code: number = url.charCodeAt(i);
      if (code >= 0x21 && code <= 0x7E) {
        out += url.charAt(i);
        i++;
      } else {
        // 收集一段连续"需要编码"的字符，整段 encodeURIComponent
        // （整段传进去才能正确处理代理对 / 多字节中文）
        let j: number = i;
        while (j < url.length) {
          const c: number = url.charCodeAt(j);
          if (c >= 0x21 && c <= 0x7E) {
            break;
          }
          j++;
        }
        out += encodeURIComponent(url.substring(i, j));
        i = j;
      }
    }
    return out;
  }

  /**
   * 字体文件**魔数**校验（2026-09-26 加固 3.5：防止把 404 页/HTML 存成字体）：
   * ttf = 00 01 00 00；otf = 'OTTO'；woff = 'wOFF'；woff2 = 'wOF2'。
   */
  static validFontMagic(data: ArrayBuffer): boolean {
    if (data.byteLength < 4) {
      return false;
    }
    const b = new Uint8Array(data, 0, 4);
    if (b[0] === 0x00 && b[1] === 0x01 && b[2] === 0x00 && b[3] === 0x00) {
      return true; // ttf
    }
    const tag: string = String.fromCharCode(b[0], b[1], b[2], b[3]);
    return tag === 'OTTO' || tag === 'wOFF' || tag === 'wOF2';
  }

  static fontsDir(ctx: common.UIAbilityContext): string {
    return ctx.filesDir + '/' + ReaderFontLib.DIR;
  }

  /**
   * 全量清单：内置 + 登记表（登记表读不出/损坏 ⇒ 只回内置，绝不把坏数据交给 UI）。
   * 2026-10-24：登记表条目先做**幽灵清理**（文件没了就剔掉并回写），
   * 否则系统清理缓存后列表里会留下"点了没反应"的死条目。
   */
  static list(): FontLibItem[] {
    const out: FontLibItem[] = ReaderFontLib.SYSTEM_FONTS.slice();
    for (const f of ReaderFontLib.pruneMissing()) {
      out.push(f);
    }
    return out;
  }

  /** 剔除「登记表里有、磁盘上没了」的幽灵条目并回写；返回存活项 */
  static pruneMissing(): FontLibItem[] {
    const list: FontLibItem[] = ReaderFontLib.registry();
    const kept: FontLibItem[] = [];
    let dropped: number = 0;
    for (const f of list) {
      let exists: boolean = false;
      try {
        exists = fs.accessSync(f.path);
      } catch (e) {
        exists = false;
      }
      if (exists) {
        kept.push(f);
      } else {
        dropped++;
      }
    }
    if (dropped > 0) {
      ReaderFontLib.saveRegistry(kept);
      hilog.warn(0x0000, 'ReaderFontLib', 'pruneMissing: dropped %{public}d ghost entries', dropped);
    }
    return kept;
  }

  /** 用户登记表（import/download） */
  static registry(): FontLibItem[] {
    let raw: string = '';
    try {
      raw = PreferencesUtil.getSync(ReaderFontLib.KEY, '') as string;
    } catch (e) {
      return [];
    }
    if (typeof raw !== 'string' || raw.length === 0) {
      return [];
    }
    try {
      const arr = JSON.parse(raw) as FontLibItem[];
      if (!Array.isArray(arr)) {
        return [];
      }
      const out: FontLibItem[] = [];
      for (const f of arr) {
        if (f !== null && f !== undefined && typeof f.name === 'string'
          && typeof f.path === 'string' && f.name.length > 0 && f.path.length > 0) {
          // 老数据没有 file 字段 ⇒ 从 path 反推（去掉 `<ts>_` 前缀）
          const file: string = (typeof f.file === 'string' && f.file.length > 0)
            ? f.file : ReaderFontLib.fileFromPath(f.path);
          out.push({
            name: f.name,
            path: f.path,
            src: f.src === 'download' ? 'download' : 'import',
            file: file,
            catalogKey: typeof f.catalogKey === 'string' ? f.catalogKey : '',
            catalogSha: typeof f.catalogSha === 'string' ? f.catalogSha : '',
            renamed: f.renamed === true
          });
        }
      }
      return out;
    } catch (e) {
      return [];
    }
  }

  private static saveRegistry(list: FontLibItem[]): void {
    try {
      PreferencesUtil.putSync(ReaderFontLib.KEY, JSON.stringify(list));
    } catch (e) {
      // 落盘失败不阻断（下次操作还会再写）
    }
  }

  /** 名字是否已占用（含内置名 —— 内置名不允许被导入字体冒用） */
  static nameTaken(name: string): boolean {
    if (name === ReaderFontLib.DEFAULT_NAME) {
      return true;
    }
    for (const f of ReaderFontLib.SYSTEM_FONTS) {
      if (f.name === name) {
        return true;
      }
    }
    for (const f of ReaderFontLib.registry()) {
      if (f.name === name) {
        return true;
      }
    }
    return false;
  }

  /** 唯一化名字：占用时追加 " (2)" / " (3)"… */
  static uniqueName(base: string): string {
    if (!ReaderFontLib.nameTaken(base)) {
      return base;
    }
    for (let i = 2; i < 100; i++) {
      const n: string = base + ' (' + i + ')';
      if (!ReaderFontLib.nameTaken(n)) {
        return n;
      }
    }
    return base + ' (' + Date.now() + ')';
  }

  /**
   * 把沙箱里已有的字体文件登记入库（导入/下载共用的最后一步）。失败返回 null。
   *
   * @param file       原始文件名（含扩展名）；用于与内置库做智能合并。不传则从 path 反推。
   * @param catalogKey 内置库来源键（直链/导入传空）
   * @param catalogSha 内置库版本指纹（直链/导入传空）
   */
  static register(path: string, name: string, src: string, file?: string,
    catalogKey?: string, catalogSha?: string): FontLibItem | null {
    try {
      if (!fs.accessSync(path)) {
        return null;
      }
    } catch (e) {
      return null;
    }
    const list: FontLibItem[] = ReaderFontLib.registry();
    if (list.length >= ReaderFontLib.MAX_ITEMS) {
      hilog.warn(0x0000, 'ReaderFontLib', 'register: MAX_ITEMS(%{public}d) reached', ReaderFontLib.MAX_ITEMS);
      return null;
    }
    const finalName: string = ReaderFontLib.uniqueName(name);
    const item: FontLibItem = {
      name: finalName,
      path: path,
      src: src,
      file: (file !== undefined && file.length > 0) ? file : ReaderFontLib.fileFromPath(path),
      catalogKey: catalogKey !== undefined ? catalogKey : '',
      catalogSha: catalogSha !== undefined ? catalogSha : '',
      renamed: false
    };
    list.push(item);
    ReaderFontLib.saveRegistry(list);
    hilog.info(0x0000, 'ReaderFontLib',
      'register: name=%{public}s file=%{public}s src=%{public}s catalog=%{public}s path=%{public}s',
      item.name, item.file, src, item.catalogKey, path);
    return item;
  }

  /** 从文件选择器 uri 导入：拷贝进 fontsDir 并登记。返回入款项（null = 失败） */
  static importFromUri(ctx: common.UIAbilityContext, uri: string): Promise<FontLibItem | null> {
    return new Promise<FontLibItem | null>((resolve: (v: FontLibItem | null) => void) => {
      let src: fs.File | null = null;
      let dst: fs.File | null = null;
      try {
        src = fs.openSync(uri, fs.OpenMode.READ_ONLY);
        const st = fs.statSync(src.fd);
        if (st.size <= 0 || st.size > ReaderFontLib.MAX_FONT_BYTES) {
          resolve(null); // 空文件 / 超过上限视为无效
          return;
        }
        const buf = new ArrayBuffer(st.size);
        fs.readSync(src.fd, buf);
        // 文件名：uri 末段（去查询串、URL 解码、去后缀做显示名）
        let seg: string = uri.substring(uri.lastIndexOf('/') + 1).split('?')[0];
        try {
          seg = decodeURIComponent(seg);
        } catch (e) {
          // 解码失败按原文处理
        }
        if (!ReaderFontLib.isFontFile(seg) || !ReaderFontLib.validFontMagic(buf)) {
          resolve(null); // 不是字体文件（扩展名或内容校验不过）
          return;
        }
        const dir: string = ReaderFontLib.fontsDir(ctx);
        if (!fs.accessSync(dir)) {
          fs.mkdirSync(dir, true);
        }
        const dstPath: string = dir + '/' + Date.now() + '_' + seg;
        dst = fs.openSync(dstPath, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
        fs.writeSync(dst.fd, buf);
        const displayName: string = seg.substring(0, seg.lastIndexOf('.'));
        resolve(ReaderFontLib.register(dstPath, displayName, 'import', seg));
      } catch (e) {
        resolve(null);
      } finally {
        try {
          if (src !== null) {
            fs.closeSync(src);
          }
          if (dst !== null) {
            fs.closeSync(dst);
          }
        } catch (e) {
          // 关闭失败不影响结果
        }
      }
    });
  }

  /**
   * 网络下载落库：字体字节已由调用方取回。失败返回 null。
   *
   * ── 2026-10-24 重写（修「贴了网页链接 → 下载失败且无原因」）──────────────────
   * · 不再信 URL 里的文件名：**扩展名由魔数决定**（`sniffFontExt`），
   *   基名只当展示名用 ⇒ 无扩展名直链（`.../download?id=1`）也能正确入库；
   * · 体积上限与导入分支统一（`MAX_FONT_BYTES`）；
   * · 每一步失败都打 hilog（旧实现整条下载链路零日志，只能靠系统 NETSTACK 猜）。
   *
   * @param fileName    URL 里取到的文件名（可带扩展名 / 可为空 / 可被污染）
   * @param displayName 期望的展示名（内置库下载时传目录里的中文名）；不传则用文件基名
   * @param catalogKey  内置库来源键（直链传空）
   * @param catalogSha  内置库版本指纹（直链传空）
   */
  static saveDownloaded(ctx: common.UIAbilityContext, fileName: string, data: ArrayBuffer,
    displayName?: string, catalogKey?: string, catalogSha?: string): FontLibItem | null {
    if (data.byteLength <= 0) {
      hilog.error(0x0000, 'ReaderFontLib', 'saveDownloaded: empty body');
      return null;
    }
    if (data.byteLength > ReaderFontLib.MAX_FONT_BYTES) {
      hilog.error(0x0000, 'ReaderFontLib', 'saveDownloaded: too large %{public}d bytes', data.byteLength);
      return null;
    }
    const ext: string = ReaderFontLib.sniffFontExt(data);
    if (ext.length === 0) {
      hilog.error(0x0000, 'ReaderFontLib',
        'saveDownloaded: not a font (size=%{public}d, html=%{public}s)',
        data.byteLength, ReaderFontLib.looksLikeHtml(data) ? 'yes' : 'no');
      return null;
    }
    const base: string = ReaderFontLib.baseName(fileName);
    const file: string = base + ext;
    try {
      const dir: string = ReaderFontLib.fontsDir(ctx);
      if (!fs.accessSync(dir)) {
        fs.mkdirSync(dir, true);
      }
      const dstPath: string = dir + '/' + Date.now() + '_' + file;
      const f = fs.openSync(dstPath, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(f.fd, data);
      } finally {
        fs.closeSync(f);
      }
      const name: string = (displayName !== undefined && displayName.length > 0) ? displayName : base;
      hilog.info(0x0000, 'ReaderFontLib',
        'saveDownloaded: ok %{public}d bytes -> %{public}s', data.byteLength, dstPath);
      return ReaderFontLib.register(dstPath, name, 'download', file, catalogKey, catalogSha);
    } catch (e) {
      hilog.error(0x0000, 'ReaderFontLib', 'saveDownloaded: write failed %{public}s',
        e instanceof Error ? e.message : String(e));
      return null;
    }
  }

  /**
   * 删除一条用户字体（登记表 + 磁盘文件）。`inUse` = 正在被某书使用（调用方传当前
   * readerSetting.fontName 比对），正在用的拒绝删。
   */
  static remove(name: string, inUse: boolean): boolean {
    if (inUse) {
      return false;
    }
    const list: FontLibItem[] = ReaderFontLib.registry();
    const kept: FontLibItem[] = list.filter((f: FontLibItem) => f.name !== name);
    if (kept.length === list.length) {
      return false;
    }
    ReaderFontLib.saveRegistry(kept);
    const gone: FontLibItem | undefined = list.find((f: FontLibItem) => f.name === name);
    if (gone !== undefined) {
      try {
        if (fs.accessSync(gone.path)) {
          fs.unlinkSync(gone.path);
        }
      } catch (e) {
        // 文件删不掉不影响登记表（下次清缓存自然回收）
      }
    }
    return true;
  }

  /** 改名（只改显示名/注册名；文件与路径不变）。新名占用返回 null */
  static rename(oldName: string, newName: string): FontLibItem | null {
    const n: string = newName.trim();
    if (n.length === 0 || ReaderFontLib.nameTaken(n)) {
      return null;
    }
    const list: FontLibItem[] = ReaderFontLib.registry();
    for (const f of list) {
      if (f.name === oldName) {
        f.name = n;
        // ★ 用户主动改名 ⇒ 从此**不再跟随上游改名**（用户 2026-10-24 定义的语义）
        f.renamed = true;
        ReaderFontLib.saveRegistry(list);
        return f;
      }
    }
    return null;
  }

  // ══════════════════════════════════════════════════════════════════════════
  // 内置库联动（2026-10-24）：上游改名跟随 / 上游改字体的"可更新"检测
  // ══════════════════════════════════════════════════════════════════════════

  /**
   * 把登记表和上游目录对齐（**只改名字，不动文件、不动 `catalogSha`**）。
   *
   * ── 规则（用户 2026-10-24 明确要求）──────────────────────────────────────
   * · 用户在程序内**改过名**（`renamed === true`）⇒ 上游改名**无效**，本地名字保持；
   * · 文件**仍是默认名**（`renamed !== true`）⇒ **跟随库更新**显示名；
   * · `catalogSha` 一律不动 —— 它是"本地这份文件是哪个版本"的凭据，
   *   一旦被上游 sha 覆盖，「可更新」就永远检测不出来了。
   *
   * @returns 真正发生改名的条目（调用方据此同步"当前正在使用"的 fontName 引用）
   */
  static syncCatalog(metas: CatalogMeta[]): FontRename[] {
    const out: FontRename[] = [];
    if (metas.length === 0) {
      return out;
    }
    const list: FontLibItem[] = ReaderFontLib.registry();
    let changed: boolean = false;
    for (const m of metas) {
      if (m.key.length === 0) {
        continue;
      }
      const hit: FontLibItem | undefined = ReaderFontLib.matchMeta(list, m);
      if (hit === undefined) {
        continue;
      }
      // ① 补 catalogKey（老条目 / 直链下的同款字体，第一次认亲）
      if (hit.catalogKey === undefined || hit.catalogKey.length === 0) {
        hit.catalogKey = m.key;
        changed = true;
      }
      // ② 跟随上游改名（仅当用户没改过名）
      if (hit.renamed !== true && m.name.length > 0 && hit.name !== m.name) {
        if (!ReaderFontLib.nameTakenByOther(list, m.name, hit.name)) {
          const oldName: string = hit.name;
          hit.name = m.name;
          changed = true;
          out.push({ oldName: oldName, newName: m.name, path: hit.path });
          hilog.info(0x0000, 'ReaderFontLib',
            'syncCatalog: follow upstream rename %{public}s -> %{public}s', oldName, m.name);
        }
      }
    }
    if (changed) {
      ReaderFontLib.saveRegistry(list);
    }
    return out;
  }

  /** 在登记表里找某条上游目录项对应的本地条目（三级匹配，见各分支注释） */
  private static matchMeta(list: FontLibItem[], m: CatalogMeta): FontLibItem | undefined {
    // ① catalogKey 精确（下载/更新时写入的强键）
    for (const f of list) {
      if (f.catalogKey !== undefined && f.catalogKey.length > 0 && f.catalogKey === m.key) {
        return f;
      }
    }
    // ② 文件名归一化（直链下的同款字体：文件名一样 ⇒ 认成同一支）
    const want: string = ReaderFontLib.normKey(m.key);
    for (const f of list) {
      const file: string = (f.file !== undefined && f.file.length > 0) ? f.file : f.path;
      if (ReaderFontLib.normKey(file) === want) {
        return f;
      }
    }
    // ③ 内容指纹相同（上游只改了文件名、内容没变 ⇒ 仍是同一支）
    if (m.sha.length > 0) {
      for (const f of list) {
        if (f.catalogSha !== undefined && f.catalogSha === m.sha) {
          return f;
        }
      }
    }
    return undefined;
  }

  /** 新名字是否被**别人**占用（自己改自己不算冲突） */
  private static nameTakenByOther(list: FontLibItem[], name: string, selfName: string): boolean {
    if (name === selfName) {
      return false;
    }
    if (name === ReaderFontLib.DEFAULT_NAME) {
      return true;
    }
    for (const f of ReaderFontLib.SYSTEM_FONTS) {
      if (f.name === name) {
        return true;
      }
    }
    for (const f of list) {
      if (f.name === name && f.name !== selfName) {
        return true;
      }
    }
    return false;
  }

  /**
   * **原地更新**一支已安装的内置库字体（上游换了字体文件时用）。
   *
   * 与"再下一支新的"不同：这条必须保住**显示名、正在使用状态、列表位置**，
   * 所以是「写新文件 → 删旧文件 → 就地改登记项」，而不是 register 一条新记录
   * （否则 `uniqueName()` 会造出「MiSans 常规 (2)」这种重复项）。
   *
   * @param entry       已安装条目（调用方从 `list()` 拿）
   * @param catalogName 上游当前展示名（用户没改过名时用它覆盖）
   * @param sha         上游当前版本指纹
   * @returns 更新后的条目；失败 null（旧文件与旧登记项保持原样）
   */
  static updateFromCatalog(ctx: common.UIAbilityContext, entry: FontLibItem, data: ArrayBuffer,
    catalogName: string, sha: string): FontLibItem | null {
    if (data.byteLength <= 0 || data.byteLength > ReaderFontLib.MAX_FONT_BYTES) {
      hilog.error(0x0000, 'ReaderFontLib', 'updateFromCatalog: bad size %{public}d', data.byteLength);
      return null;
    }
    const ext: string = ReaderFontLib.sniffFontExt(data);
    if (ext.length === 0) {
      hilog.error(0x0000, 'ReaderFontLib', 'updateFromCatalog: not a font');
      return null;
    }
    const srcFile: string = (entry.file !== undefined && entry.file.length > 0) ? entry.file : entry.path;
    const file: string = ReaderFontLib.baseName(srcFile) + ext;
    let dstPath: string = '';
    try {
      const dir: string = ReaderFontLib.fontsDir(ctx);
      if (!fs.accessSync(dir)) {
        fs.mkdirSync(dir, true);
      }
      dstPath = dir + '/' + Date.now() + '_' + file;
      const f = fs.openSync(dstPath, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(f.fd, data);
      } finally {
        fs.closeSync(f);
      }
    } catch (e) {
      hilog.error(0x0000, 'ReaderFontLib', 'updateFromCatalog: write failed %{public}s',
        e instanceof Error ? e.message : String(e));
      return null;
    }
    const list: FontLibItem[] = ReaderFontLib.registry();
    let out: FontLibItem | null = null;
    for (const it of list) {
      if (it.name !== entry.name) {
        continue;
      }
      // 新文件已就位，才删旧文件（写失败时旧文件不能被破坏）
      try {
        if (it.path !== dstPath && fs.accessSync(it.path)) {
          fs.unlinkSync(it.path);
        }
      } catch (e) {
        // 旧文件删不掉只是占空间，不影响新文件可用
      }
      it.path = dstPath;
      it.file = file;
      it.catalogSha = sha;
      if (it.renamed !== true && catalogName.length > 0) {
        it.name = catalogName;
      }
      out = it;
      break;
    }
    if (out === null) {
      try {
        if (fs.accessSync(dstPath)) {
          fs.unlinkSync(dstPath);
        }
      } catch (e) {
        // 清理失败忽略
      }
      return null;
    }
    ReaderFontLib.saveRegistry(list);
    hilog.info(0x0000, 'ReaderFontLib',
      'updateFromCatalog: %{public}s -> %{public}s (sha=%{public}s)',
      entry.name, dstPath, sha);
    return out;
  }

  /**
   * 确保 ArkUI 侧（滚动层 / 沉浸层 / 弹窗预览 / 高亮测量通道）能用
   * `Text.fontFamily(name)` 渲染该字体。
   * 只注册**沙箱**文件（系统字体族本就存在）；幂等（内存去重）；失败静默 ——
   * 预览退化为系统字形，不影响引擎渲染（引擎走 resourceRequest，另一条路）。
   * ⚠️ 走 `UIContext.getFont().registerFont`（SDK `@ohos.font.d.ts:445-446`：
   * 模块级 `font.registerFont` 已 @deprecated since 18，@useinstead 即本接口）。
   *
   * ── 2026-10-20 改：新增第 4 个可选参数 `onReady` ────────────────────────────
   * 原因（真机缺陷）：`registerFont` 是**异步生效**的，注册完成前 `fontFamily(name)`
   * 解析不到该族名 ⇒ 回落系统默认字形。而原生文本一旦用错族名渲染出来，只要参数不变
   * 就**不会自己重排**（滚动层的 `List` 项就是这样）⇒ 字体永远停在默认字形，
   * 表现为「上下滚动模式下自定义字体失效、且比其它模式更黑」。
   * ⇒ 调用方必须能知道"什么时候真正注册好了"，注册完成后再逼一次重排。
   *
   * ⚠️ 为什么用**回调**而不是返回 Promise：SDK 里 `Font.registerFont` 的签名是
   *   `registerFont(options: font.FontOptions): void;`（`@ohos.arkui.UIContext.d.ts:69`）
   *   —— **返回 void、也没有回调重载**，拿不到完成信号。
   *   所以这里只能"发起注册 + 轮询 `getFontByName()` 直到族名可解析"，
   *   探到就回调 `onReady`；最多轮询 ~1s，超时也回调（宁可让调用方用当前字形，
   *   也不能把界面卡住）。
   *   旧调用点（只传 3 个参数）行为不变 —— 不传 `onReady` 就纯 fire-and-forget。
   */
  static ensureRegistered(ui: UIContext, name: string, path: string, onReady?: () => void): void {
    if (name.length === 0) {
      if (onReady !== undefined) {
        onReady();
      }
      return;
    }
    // ── 2026-10-23 修：**空 path 不再直接 return** ──────────────────────────────
    // 缺陷现场（真机日志）：用户选「书宋-简」时引擎 config 是
    //   `fontName:"书宋-简", fontPath:""` —— 它是**系统族名别名**（`SYSTEM_FONTS`
    //   里 path 就是空串）。旧代码第一行 `if (path.length === 0) return;` ⇒ 从未注册，
    //   而 ArkUI 又不认识这个别名 ⇒ `.fontFamily('书宋-简')` 解析失败 ⇒ 回落默认字形。
    // ⇒ 现在空 path 先向 ArkUI 反查真实文件路径（`getFontByName`），拿到就照常注册。
    let realPath: string = path;
    if (realPath.length === 0 || !realPath.startsWith('/')) {
      realPath = ReaderFontLib.probeFontPath(ui, name);
    }
    if (realPath.length === 0 || !realPath.startsWith('/')) {
      // 反查不到：ArkUI 侧可能本来就能按族名解析（系统内置族），交给调用方的
      // 回退链兜底；这里只记一条日志，便于真机定位"到底哪支字体没落到 ArkUI"。
      hilog.warn(0x0000, 'ReaderFontLib',
        'ensureRegistered: no path for name=%{public}s (ArkUI 将按族名回退)', name);
      if (onReady !== undefined) {
        onReady();
      }
      return;
    }
    if (ReaderFontLib.registered.get(name) === true) {
      // 已注册过：族名可解析，直接通知调用方重排即可
      hilog.info(0x0000, 'ReaderFontLib', 'ensureRegistered: name=%{public}s already registered', name);
      if (onReady !== undefined) {
        onReady();
      }
      return;
    }
    try {
      hilog.info(0x0000, 'ReaderFontLib',
        'ensureRegistered: register name=%{public}s src=file://%{public}s', name, realPath);
      ui.getFont().registerFont({ familyName: name, familySrc: 'file://' + realPath });
    } catch (e) {
      // 同步抛（参数非法等）：静默，让调用方按当前字形走
      hilog.error(0x0000, 'ReaderFontLib',
        'ensureRegistered: register THROW name=%{public}s', name);
      if (onReady !== undefined) {
        onReady();
      }
      return;
    }
    ReaderFontLib.pollFontReady(ui, name, 0, onReady);
  }

  /**
   * 反查某个族名在系统里的**真实字体文件路径**（空串 = 查不到）。
   *
   * 用途：`SYSTEM_FONTS` 里的系统族名别名（如「书宋-简」）`path` 是空串，
   * 但 ArkUI 侧要 `registerFont` 就必须有文件路径 ⇒ 这里向 ArkUI 的字体管理器反查。
   * 查不到就返回空串（调用方走族名回退链）。
   */
  static probeFontPath(ui: UIContext, name: string): string {
    try {
      const info = ui.getFont().getFontByName(name);
      const p: string = info.path;
      hilog.info(0x0000, 'ReaderFontLib',
        'probeFontPath: name=%{public}s -> path=%{public}s family=%{public}s',
        name, p.length > 0 ? p : '(empty)', info.family);
      return p !== undefined && p !== null ? p : '';
    } catch (e) {
      hilog.warn(0x0000, 'ReaderFontLib', 'probeFontPath: name=%{public}s not resolvable', name);
      return '';
    }
  }

  /**
   * 轮询"该族名是否已能被 ArkUI 解析"。
   *
   * 判据用 `getFontByName(name).path` 非空（`FontInfo.path` = 该字体文件路径，
   * `@ohos.font.d.ts` FontInfo 首字段）。未注册时该接口可能抛、也可能给出空 path，
   * 两种都按"还没好"处理。
   *
   * @param attempt 已尝试次数（0 起）；上限 `READY_MAX_ATTEMPTS`，间隔 `READY_POLL_MS`
   */
  private static pollFontReady(ui: UIContext, name: string, attempt: number,
    onReady?: () => void): void {
    let ready: boolean = false;
    try {
      const info = ui.getFont().getFontByName(name);
      ready = info.path.length > 0;
    } catch (e) {
      ready = false;
    }
    if (ready) {
      ReaderFontLib.registered.set(name, true);
      hilog.info(0x0000, 'ReaderFontLib',
        'pollFontReady: name=%{public}s ready after %{public}d ms', name, attempt * ReaderFontLib.READY_POLL_MS);
      if (onReady !== undefined) {
        onReady();
      }
      return;
    }
    if (attempt >= ReaderFontLib.READY_MAX_ATTEMPTS) {
      // 超时：不置 registered（下次进页面还能再试），但也要通知 —— 否则调用方永远等不到重排
      hilog.warn(0x0000, 'ReaderFontLib',
        'pollFontReady: name=%{public}s TIMEOUT after %{public}d ms（将回落族名回退链）',
        name, ReaderFontLib.READY_MAX_ATTEMPTS * ReaderFontLib.READY_POLL_MS);
      if (onReady !== undefined) {
        onReady();
      }
      return;
    }
    setTimeout((): void => {
      ReaderFontLib.pollFontReady(ui, name, attempt + 1, onReady);
    }, ReaderFontLib.READY_POLL_MS);
  }

  /** 轮询上限（20 × 50ms ≈ 1s，覆盖真机上 registerFont 的实测耗时） */
  private static readonly READY_MAX_ATTEMPTS: number = 20;
  /** 轮询间隔（ms） */
  private static readonly READY_POLL_MS: number = 50;
}
