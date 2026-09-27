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

/** 一条字体登记项（系统内置项 src='system'，不入盘） */
export interface FontLibItem {
  /** 显示名（可改名）＝ ArkUI 注册族名 ＝ readerSetting.fontName */
  name: string;
  /** 字体文件路径：系统绝对路径 或 沙箱绝对路径 */
  path: string;
  /** 'system' 内置 / 'import' 导入 / 'download' 下载 */
  src: string;
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

  /** 全量清单：内置 + 登记表（登记表读不出/损坏 ⇒ 只回内置，绝不把坏数据交给 UI） */
  static list(): FontLibItem[] {
    const out: FontLibItem[] = ReaderFontLib.SYSTEM_FONTS.slice();
    for (const f of ReaderFontLib.registry()) {
      out.push(f);
    }
    return out;
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
          out.push({ name: f.name, path: f.path, src: f.src === 'download' ? 'download' : 'import' });
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

  /** 把沙箱里已有的字体文件登记入库（导入/下载共用的最后一步）。失败返回 null */
  static register(path: string, name: string, src: string): FontLibItem | null {
    try {
      if (!fs.accessSync(path)) {
        return null;
      }
    } catch (e) {
      return null;
    }
    const list: FontLibItem[] = ReaderFontLib.registry();
    if (list.length >= ReaderFontLib.MAX_ITEMS) {
      return null;
    }
    const finalName: string = ReaderFontLib.uniqueName(name);
    const item: FontLibItem = { name: finalName, path: path, src: src };
    list.push(item);
    ReaderFontLib.saveRegistry(list);
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
        if (st.size <= 0 || st.size > 64 * 1024 * 1024) {
          resolve(null); // 空文件 / 超过 64MB 视为无效
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
        resolve(ReaderFontLib.register(dstPath, displayName, 'import'));
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

  /** 网络下载落库：字体字节已由调用方取回。失败返回 null（含魔数校验，拒收 404/HTML） */
  static saveDownloaded(ctx: common.UIAbilityContext, fileName: string, data: ArrayBuffer): FontLibItem | null {
    if (data.byteLength <= 0 || !ReaderFontLib.isFontFile(fileName) || !ReaderFontLib.validFontMagic(data)) {
      return null;
    }
    try {
      const dir: string = ReaderFontLib.fontsDir(ctx);
      if (!fs.accessSync(dir)) {
        fs.mkdirSync(dir, true);
      }
      const dstPath: string = dir + '/' + Date.now() + '_' + fileName;
      const f = fs.openSync(dstPath, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(f.fd, data);
      } finally {
        fs.closeSync(f);
      }
      const displayName: string = fileName.substring(0, fileName.lastIndexOf('.'));
      return ReaderFontLib.register(dstPath, displayName, 'download');
    } catch (e) {
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
        ReaderFontLib.saveRegistry(list);
        return f;
      }
    }
    return null;
  }

  /**
   * 确保 ArkUI 侧（弹窗预览 / 高亮测量通道）能用 `Text.fontFamily(name)` 渲染该字体。
   * 只注册**沙箱**文件（系统字体族本就存在）；幂等（内存去重）；失败静默 ——
   * 预览退化为系统字形，不影响引擎渲染（引擎走 resourceRequest，另一条路）。
   * ⚠️ 走 `UIContext.getFont().registerFont`（SDK `@ohos.font.d.ts:445-446`：
   * 模块级 `font.registerFont` 已 @deprecated since 18，@useinstead 即本接口）。
   */
  static ensureRegistered(ui: UIContext, name: string, path: string): void {
    if (name.length === 0 || path.length === 0 || !path.startsWith('/')) {
      return;
    }
    if (ReaderFontLib.registered.get(name) === true) {
      return;
    }
    try {
      ui.getFont().registerFont({ familyName: name, familySrc: 'file://' + path });
      ReaderFontLib.registered.set(name, true);
    } catch (e) {
      // 注册失败：预览/测量回落系统字形；引擎侧不受影响
    }
  }
}
