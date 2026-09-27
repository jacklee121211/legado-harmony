/**
 * 阅读器「自定义背景色」—— 色彩数学 + 持久化（2026-09-25 新增）。
 *
 * ── 背景色到底是"图片"还是"渲染"？（先回答取证问题，再谈实现）──────────────────
 * **是渲染的纯色**，不是图片。证据：
 *  ① SDK 声明原文（`…\hms\ets\api\@hms.core.readerservice.readerComponent.d.ets:140-159`）：
 *     `themeColor: string;`  ——「theme background color.」
 *     `themeBgImg: string;`  ——「theme background image path.」
 *     两者是**并列的两个字段**：`themeColor` 管纯色、`themeBgImg` 管图片。
 *  ② 官方文档原文（documentId
 *     `开发指南/Reader_Kit_阅读服务/书籍内容排版/修改阅读设置/自定义页面背景/reader-setting-background`）：
 *     「单独设置背景色。如果有设置背景图片的情况下，背景色通常用于仿真翻页时背面主题色的绘制。
 *       **否则，背景色还会用于渲染阅读页的背景色。**」
 *     `this.readerSetting.themeColor = '#000000';` / `this.readerSetting.themeBgImg = '';`
 *  ③ 本工程现状：4 个推荐色**全部** `themeBgImg: ''`
 *     （`ReaderPage3.ets:841-846`，UI 也是 `.backgroundColor(item.themeColor)`
 *       + `.backgroundImage(item.themeBgImg)`，见 `ReaderPage3.ets:3377-3378`）
 *     ⇒ 现在走的就是"纯色渲染"这条路。
 * ⇒ 结论：**自定义背景色 = 改 `themeColor`**，`themeBgImg` 继续保持 `''`，
 *   全程不碰 `resourceRequest`（那是给背景**图片**用的，本工程目前只用它加载字体）。
 *
 * ── 这个文件负责什么 ──────────────────────────────────────────────────────────
 * · 色彩数学：RGB ⇄ HEX / HSV、WCAG 相对亮度、无极调色盘的 (x,y) ⇄ RGB 映射；
 * · 持久化：**按书**的记录（`ReaderBg_<书名>`）+ 一份**全局**记录（`ReaderBgGlobal`）
 *   + 一份"哪些书写过本书覆盖"的登记表（`ReaderBgOverrides`），供「同步全局」清场。
 *
 * ⚠️ 为什么不把新字段塞进 `readerCore.ReaderSetting`：那是 ReaderKit 的**接口**，
 *   SDK 里只有 13 个字段（`readerComponent.d.ets:69-200`），塞额外字段既过不了类型
 *   检查（对象字面量多余属性），也会被 ReaderKit 忽略。所以走**旁路 Preferences**，
 *   与工程既有做法一致（`RS_SETTING_VER` 的迁移版本号就是这么旁路存的，
 *   见 `ReaderPage3.ets:166-176`）。
 */
import { PreferencesUtil } from '@pura/harmony-utils';

/** RGB 三元组，分量 0-255 */
export interface RgbTriple {
  r: number;
  g: number;
  b: number;
}

/**
 * 一本书的「自定义背景色」记录。
 *
 * `prev*` 三个字段是**开关打开那一刻**的 `ReaderSetting` 原值，用来在用户把开关
 * 关掉时**原样还回去**（用户原话：「用户选择默认背景就是默认背景」——关掉就该回到
 * 他原来选的推荐色，而不是被我们改成第一个推荐色）。
 */
export interface ReaderBgRecord {
  /**
   * 自定义颜色模式是否打开（true = 用自定义颜色，false = 用背景家族：推荐色/材质）。
   * ⚠️ 2026-09-25 语义收窄：材质划入**背景家族**（"自定义就是自定义，背景就是背景
   *   （包括材质），区分开"——用户原话），`on` 只管"自定义颜色"，不再管材质。
   */
  on: boolean;
  r: number;
  g: number;
  b: number;
  /** 打开开关前的 themeColor */
  prevTheme: string;
  /** 打开开关前的 fontColor */
  prevFont: string;
  /** 打开开关前的 nightMode */
  prevNight: boolean;
  /**
   * 材质背景（2026-09-25 新增）：`ReaderTexture` 的三位编号（texture_001 ⇒ 1），
   * `0` = 未用材质（纯色/推荐色）。材质属于**背景家族**，`on=false` 时照常渲染。
   * ⚠️ 旧记录 texId 是 0 基的 8 个硬编码 id，与新编号不完全对应；错位的旧记录
   *   会因找不到文件而回落纯色，重新点一次材质即恢复（本功能当天上线，无存量用户）。
   */
  texId: number;
  /**
   * 字色是否自动对比（2026-09-25 新增）。true = 按背景亮度自动选黑/白字；
   * false = 用户手动选过字色（推荐字色行 / 自定义字色保存），自动对比**停手**。
   * ⚠️ 旧记录没有该字段 ⇒ normalize 补 true（与历史行为一致）。
   */
  fontAuto: boolean;
  /**
   * 背景模糊开关（2026-09-26 新增）。true = 材质图先按当前档位高斯模糊再交给引擎
   * （模糊"洗进图里"，等效"模糊层位于背景之上、文字之下"，见 `ReaderPage3` bgBlurOn 注释）。
   * ⚠️ 旧记录没有该字段 ⇒ normalize 补 false（老书行为不变，这就是迁移）。
   */
  blurOn: boolean;
  /**
   * 背景模糊强度 = 高斯模糊半径（px，作用于 ≤1440px 的合成图）。
   * 只取 `BG_BLUR_TIERS` 5 个档位（normalize 吸附），对应 5 张预生成的磁盘缓存图。
   * ⚠️ 旧记录没有该字段 ⇒ normalize 补 `BG_BLUR_RADIUS_DEFAULT`。
   */
  blurRadius: number;
  /**
   * 自定义背景（2026-09-27 新增）：非空 = 本书用的是**用户导入的图片背景**
   * （id 对应 `ReaderTexture.customItems` 登记表，源图在 `filesDir/readerbg/custom/`），
   * 合成/均色/模糊与材质完全同管线。与 `texId`（内置材质）互斥，两者都空 = 纯色。
   * ⚠️ 旧记录没有该字段 ⇒ normalize 补 ''。
   */
  customTexId: string;
}

/**
 * 一条「保存方案」V2（2026-09-25 用户改版）：**背景色 + 字色** 成对。
 * `fontHex = ''` 表示字色未手动选过（应用时按背景亮度自动对比）。
 */
export interface BgSchemeEntry {
  bgHex: string;
  fontHex: string;
}

/**
 * 一键回退开关（`false` ⇒ 只改 `themeColor`，**不动** `fontColor` / `nightMode`）。
 *
 * 为什么默认 `true`：官方文档（同 `reader-setting-background`）原文警告 ——
 *   「更改页面背景色，可能会涉及到字体颜色和深色模式的适配。比如：设置了白色背景，
 *     但是当前是深色模式，字体颜色也是白色，这样会导致内容看不清楚。」
 *   ⇒ 不联动就会出现"白底白字"的不可读状态，所以默认按背景亮度自动切黑/白字并联动
 *     `nightMode`（阈值取 WCAG 里黑字/白字对比度**相等**的那一点，见 `LUMA_PIVOT`）。
 * 回退：把这里改成 `false` 即可 —— 自定义色只影响页面底色，字色/日夜完全由用户自己
 *   在原有的「推荐色 / 日间·夜间」按钮上决定（代价是可能出现看不清）。
 */
export const CUSTOM_BG_AUTO_CONTRAST: boolean = true;

/**
 * 背景模糊强度**分档表 / 默认档 / 上限**（2026-09-26 定稿：用户拍板「限制 0-30，
 * 0-30 之间五个档位，平均一点」⇒ 步长 6，五档 = 6/12/18/24/30）。
 *
 * 实现口径（真机推翻第一版后定案，见 `ReaderPage3.ets` bgBlurOn 注释）：
 * 模糊不做在 ArkUI 层，而是**把高斯模糊"洗进"材质图里**再交给引擎
 * （`ReaderTexture.blurredPath`，effectKit `Filter.blur`，SDK `@ohos.effectKit.d.ts:79`，
 * @since 9，官方明示用途即"background blurring / frosted glass background effect"）。
 * 强度只有这 5 档 ⇒ 每档一张磁盘缓存 JPEG，**生成一次永久命中**；
 * 设置面板用 `CapsuleSegmentButtonV2` 档位控件选档（不用拖块），切档 =
 * 换一个已缓存文件的路径 + 一次引擎重排。半径单位是 **px**（作用在 ≤1440px 的合成图上）。
 * ⚠️ 纯色背景模糊仍是同一纯色（处处梯度为 0），纯色/自定义颜色模式视觉无变化。
 * 回退：整个功能是加法开关，关掉「背景模糊」即回原图路径。
 */
export const BG_BLUR_TIERS: number[] = [6, 12, 18, 24, 30];
export const BG_BLUR_RADIUS_DEFAULT: number = 18;
export const BG_BLUR_RADIUS_MAX: number = 30;

/**
 * 亮/暗分界（WCAG 相对亮度）。
 *
 * 依据：对比度公式（WCAG 2.x）
 *   与白字的对比度 = 1.05 / (L + 0.05)；与黑字的对比度 = (L + 0.05) / 0.05。
 *   两者相等时 (L + 0.05)² = 1.05 × 0.05 = 0.0525
 *   ⇒ L = √0.0525 − 0.05 = **0.179128784747792**（此处取全精度，不四舍五入 ——
 *     取 0.1791 会让"两侧对比度相等"这条定义性质带上 ~1.2e-3 的偏差，虽然不影响
 *     任何 8bit 颜色的归类，但没有理由留这个不精确）。
 * ⇒ `L <= 本值` 用白字（背景偏暗）+ `nightMode = true`；否则用黑字 + 日间。
 *   同一个阈值同时决定字色与 `nightMode`，保证"白字"与"夜间"永远同进同出，
 *   并且**对比度永远不会低于 4.58:1**（该阈值正是 max(对比度_黑, 对比度_白) 的全局最小值点）。
 */
const LUMA_PIVOT: number = 0.179128784747792;

export class ReaderCustomBg {
  /** 按书记录的键前缀（与 `ReaderSetting_<书名>` 同风格） */
  static readonly KEY_PREFIX: string = 'ReaderBg_';
  /** 全局记录（「同步全局」写这里） */
  static readonly KEY_GLOBAL: string = 'ReaderBgGlobal';
  /** 「写过本书覆盖」的书名登记表（JSON string[]），供「同步全局」逐条清场 */
  static readonly KEY_OVERRIDES: string = 'ReaderBgOverrides';
  /** 用户「保存方案」下来的颜色（JSON string[]，元素为 `#RRGGBB`）—— **全软件共用** */
  static readonly KEY_SCHEMES: string = 'ReaderBgSchemes';

  /**
   * 保存方案的数量上限（颜色方案与材质方案**各自**的上限，互不占用）。
   * 2026-09-25 由 10 改为 100：背景栏改成「一行四个最多三行 + 超出横向拖拽」布局后，
   * 拖拽行可以无限追加，100 只是防失控的保险丝，实际很难碰到。
   * 超上限时**不再添加**（返回 `'full'`，由页面提示用户先删几个），
   * 而不是悄悄丢掉最老的 —— 用户存下来的东西不能在我们手里消失。
   */
  static readonly MAX_SCHEMES: number = 100;

  static readonly WHITE: RgbTriple = { r: 255, g: 255, b: 255 };
  static readonly BLACK: RgbTriple = { r: 0, g: 0, b: 0 };

  // ── 基础工具 ───────────────────────────────────────────────────────────────

  private static num(v: number, def: number): number {
    return (typeof v === 'number' && isFinite(v)) ? v : def;
  }

  static clamp(v: number, lo: number, hi: number): number {
    return Math.min(hi, Math.max(lo, v));
  }

  static clamp01(v: number): number {
    return ReaderCustomBg.clamp(ReaderCustomBg.num(v, 0), 0, 1);
  }

  /**
   * 任意强度值**吸附到最近的模糊档位**（`BG_BLUR_TIERS`，5 档）。
   * 旧记录里的自由值（如 37）一律归档，保证落到某一张预生成的缓存图上。
   */
  static snapBlurTier(v: number): number {
    const r = ReaderCustomBg.num(v, BG_BLUR_RADIUS_DEFAULT);
    let best: number = BG_BLUR_TIERS[0];
    let bestDist: number = Math.abs(r - best);
    for (const t of BG_BLUR_TIERS) {
      const d: number = Math.abs(r - t);
      if (d < bestDist) {
        best = t;
        bestDist = d;
      }
    }
    return best;
  }

  static clamp255(v: number): number {
    return Math.round(ReaderCustomBg.clamp(ReaderCustomBg.num(v, 0), 0, 255));
  }

  static make(r: number, g: number, b: number): RgbTriple {
    return { r: ReaderCustomBg.clamp255(r), g: ReaderCustomBg.clamp255(g), b: ReaderCustomBg.clamp255(b) };
  }

  private static hex2(v: number): string {
    const s = ReaderCustomBg.clamp255(v).toString(16);
    return s.length === 1 ? '0' + s : s;
  }

  /** `#RRGGBB`（大写）。ReaderKit 官方示例用的就是这个形式，最稳。 */
  static hexOf(rgb: RgbTriple): string {
    return ('#' + ReaderCustomBg.hex2(rgb.r) + ReaderCustomBg.hex2(rgb.g) + ReaderCustomBg.hex2(rgb.b)).toUpperCase();
  }

  /**
   * 解析颜色字符串 → RGB。支持 `#RGB` / `#RRGGBB` / `#AARRGGBB` / `rgb(...)` / `rgba(...)`。
   * 解析不出来返回 `null`（调用方必须自己兜底，不要让它进渲染）。
   *
   * 为什么必须支持 `rgba(...)`：`ReaderSetting.themeColor` 的默认值就是
   * `'rgba(248, 249, 250, 1)'`（`ReaderPage3.ets:829`），只认 `#RRGGBB` 会解析失败。
   * 注意 ArkUI 的 8 位写法是 **#AARRGGBB**（alpha 在前），故 8 位时丢掉前两位。
   */
  static parseColor(input: string): RgbTriple | null {
    if (input === undefined || input === null) {
      return null;
    }
    const s: string = input.trim().toLowerCase();
    if (s.length === 0) {
      return null;
    }
    if (s.charAt(0) === '#') {
      let h: string = s.substring(1);
      if (h.length === 3) {
        h = h.charAt(0) + h.charAt(0) + h.charAt(1) + h.charAt(1) + h.charAt(2) + h.charAt(2);
      } else if (h.length === 8) {
        h = h.substring(2);
      }
      if (h.length !== 6) {
        return null;
      }
      const r = parseInt(h.substring(0, 2), 16);
      const g = parseInt(h.substring(2, 4), 16);
      const b = parseInt(h.substring(4, 6), 16);
      if (isNaN(r) || isNaN(g) || isNaN(b)) {
        return null;
      }
      return { r: r, g: g, b: b };
    }
    if (s.indexOf('rgb') === 0) {
      const open = s.indexOf('(');
      const close = s.lastIndexOf(')');
      if (open < 0 || close <= open) {
        return null;
      }
      const parts: string[] = s.substring(open + 1, close).split(',');
      if (parts.length < 3) {
        return null;
      }
      const r = parseFloat(parts[0].trim());
      const g = parseFloat(parts[1].trim());
      const b = parseFloat(parts[2].trim());
      if (isNaN(r) || isNaN(g) || isNaN(b)) {
        return null;
      }
      return ReaderCustomBg.make(r, g, b);
    }
    return null;
  }

  // ── 亮度 / 对比色 ──────────────────────────────────────────────────────────

  /** sRGB 单通道线性化（WCAG 2.x 相对亮度定义） */
  private static linear(c: number): number {
    const v = ReaderCustomBg.clamp255(c) / 255;
    return v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4);
  }

  /** WCAG 相对亮度 L ∈ [0,1] */
  static luminance(rgb: RgbTriple): number {
    return 0.2126 * ReaderCustomBg.linear(rgb.r)
      + 0.7152 * ReaderCustomBg.linear(rgb.g)
      + 0.0722 * ReaderCustomBg.linear(rgb.b);
  }

  /** 该背景是否算"暗"（决定 nightMode） */
  static isDarkBg(rgb: RgbTriple): boolean {
    return ReaderCustomBg.luminance(rgb) <= LUMA_PIVOT;
  }

  /** 该背景上应该用的字色（黑或白），与 `isDarkBg` 同一阈值、永远互补 */
  static contrastFont(rgb: RgbTriple): string {
    return ReaderCustomBg.isDarkBg(rgb) ? '#FFFFFF' : '#000000';
  }

  // ── HSV ⇄ RGB（调色盘用）──────────────────────────────────────────────────

  /** `h ∈ [0,360)` → 该色相在 s=1/v=1 时的 RGB（彩虹条上的纯色） */
  static hueToRgb(h: number): RgbTriple {
    const hh = ((ReaderCustomBg.num(h, 0) % 360) + 360) % 360;
    const x = 1 - Math.abs(((hh / 60) % 2) - 1);
    let r = 0;
    let g = 0;
    let b = 0;
    if (hh < 60) {
      r = 1;
      g = x;
    } else if (hh < 120) {
      r = x;
      g = 1;
    } else if (hh < 180) {
      g = 1;
      b = x;
    } else if (hh < 240) {
      g = x;
      b = 1;
    } else if (hh < 300) {
      r = x;
      b = 1;
    } else {
      r = 1;
      b = x;
    }
    return { r: Math.round(r * 255), g: Math.round(g * 255), b: Math.round(b * 255) };
  }

  /** RGB → `[h(0-360), s(0-1), v(0-1)]` */
  static rgbToHsv(rgb: RgbTriple): number[] {
    const r = ReaderCustomBg.clamp255(rgb.r) / 255;
    const g = ReaderCustomBg.clamp255(rgb.g) / 255;
    const b = ReaderCustomBg.clamp255(rgb.b) / 255;
    const max = Math.max(r, Math.max(g, b));
    const min = Math.min(r, Math.min(g, b));
    const d = max - min;
    let h = 0;
    if (d > 0) {
      if (max === r) {
        h = 60 * (((g - b) / d) % 6);
      } else if (max === g) {
        h = 60 * (((b - r) / d) + 2);
      } else {
        h = 60 * (((r - g) / d) + 4);
      }
    }
    if (h < 0) {
      h += 360;
    }
    const s = max <= 0 ? 0 : d / max;
    return [h, s, max];
  }

  static mix(a: RgbTriple, b: RgbTriple, t: number): RgbTriple {
    const k = ReaderCustomBg.clamp01(t);
    return {
      r: Math.round(a.r + (b.r - a.r) * k),
      g: Math.round(a.g + (b.g - a.g) * k),
      b: Math.round(a.b + (b.b - a.b) * k)
    };
  }

  private static dist2(a: RgbTriple, b: RgbTriple): number {
    const dr = a.r - b.r;
    const dg = a.g - b.g;
    const db = a.b - b.b;
    return dr * dr + dg * dg + db * db;
  }

  /**
   * 调色盘归一化坐标 `(nx, ny)` → RGB（`nx` 横向 = 色相 0→360，`ny` 纵向 = 明暗）。
   *
   * 色盘由三层叠出来（见 `ReaderBgPalette`）：
   *   · 底层：横向彩虹（色相）
   *   · 上半：白 → 透明（`ny=0` 最白，`ny=0.5` 纯色相）
   *   · 下半：透明 → 黑（`ny=0.5` 纯色相，`ny=1` 最黑）
   * 所以映射就是 **纯色相色 ↔ 白/黑 的线性插值**，与渲染出的画面逐像素一致。
   */
  static paletteToRgb(nx: number, ny: number): RgbTriple {
    const x = ReaderCustomBg.clamp01(nx);
    const y = ReaderCustomBg.clamp01(ny);
    const pure = ReaderCustomBg.hueToRgb(x * 360);
    if (y <= 0.5) {
      return ReaderCustomBg.mix(pure, ReaderCustomBg.WHITE, 1 - y * 2);
    }
    return ReaderCustomBg.mix(pure, ReaderCustomBg.BLACK, (y - 0.5) * 2);
  }

  /**
   * RGB → 调色盘归一化坐标 `[nx, ny, dist]`：
   *   · `nx` / `ny` = 游标位置（0-1）；
   *   · `dist` = 该颜色到色盘上最近的**可画出颜色**的欧氏距离（0 = 正好在色盘上）。
   *
   * ⚠️ 色盘**画不出**所有 RGB（它只有"纯色↔白"和"纯色↔黑"两族，
   *    即 max 通道 = 255 或 min 通道 = 0；像 `(128,64,64)` 这种两侧都不挨的色
   *    只能靠右侧 RGB 滑块调出来）。所以这里做的是**最近点投影**：分别假设
   *    "在上半(v=1)"与"在下半(s=1)"算出两个候选点，取颜色更接近的那个，
   *    并把距离一并返回 —— 调用方（`ReaderBgPalette`）据此把游标画淡，
   *    向用户表达"当前色不在色盘上，这是最接近的点"。
   *
   * 【两个候选点的 y 必须由 `paletteToRgb` 反解，不能凭直觉写】
   *   · 上半：`paletteToRgb(x,y) = mix(pure, 白, 1 − 2y)`，
   *     要让白混合量 = `1 − s` ⇒ **y = s / 2**；
   *   · 下半：`paletteToRgb(x,y) = mix(pure, 黑, 2y − 1)`，
   *     要让黑混合量 = `1 − v` ⇒ **y = 1 − v / 2**。
   *   ⚠️ 第一版把上半写成了 `(1 − s) / 2`（凭直觉的"越不饱和越靠白"），
   *     结果**整个上半的游标都画反了**：纯色 `#FF0000` 会被定位到 `y=0`
   *     （色盘最顶端的白色区），`#FFFFFF` 反而被定到 `y=0.5`。
   *     已用 `node` 对 `paletteToRgb` 做 41×41 往返比对定位并修正（见本文件头说明）。
   */
  static paletteMarker(rgb: RgbTriple): number[] {
    const hsv = ReaderCustomBg.rgbToHsv(rgb);
    const h = hsv[0];
    const s = hsv[1];
    const v = hsv[2];
    const nx = ReaderCustomBg.clamp01(h / 360);
    const pure = ReaderCustomBg.hueToRgb(h);
    const yTop = s * 0.5;
    const cTop = ReaderCustomBg.mix(pure, ReaderCustomBg.WHITE, 1 - s);
    const yBot = 1 - v * 0.5;
    const cBot = ReaderCustomBg.mix(pure, ReaderCustomBg.BLACK, 1 - v);
    const dTop = ReaderCustomBg.dist2(rgb, cTop);
    const dBot = ReaderCustomBg.dist2(rgb, cBot);
    const useTop = dTop <= dBot;
    return [nx, useTop ? yTop : yBot, Math.sqrt(useTop ? dTop : dBot)];
  }

  // ── 持久化 ─────────────────────────────────────────────────────────────────

  static bookKey(bookName: string): string {
    return ReaderCustomBg.KEY_PREFIX + bookName;
  }

  private static normalize(rec: ReaderBgRecord): ReaderBgRecord {
    return {
      on: rec.on === true,
      r: ReaderCustomBg.clamp255(ReaderCustomBg.num(rec.r, 255)),
      g: ReaderCustomBg.clamp255(ReaderCustomBg.num(rec.g, 255)),
      b: ReaderCustomBg.clamp255(ReaderCustomBg.num(rec.b, 255)),
      prevTheme: typeof rec.prevTheme === 'string' ? rec.prevTheme : '',
      prevFont: typeof rec.prevFont === 'string' ? rec.prevFont : '',
      prevNight: rec.prevNight === true,
      // 材质：三位编号（1 基），0/缺省/坏值 = 未用材质
      texId: (typeof rec.texId === 'number' && isFinite(rec.texId) && rec.texId >= 1)
        ? Math.floor(rec.texId) : 0,
      // 字色自动对比：旧记录无此字段 ⇒ 默认 true（与历史行为一致）
      fontAuto: rec.fontAuto !== false,
      // 背景模糊（2026-09-26）：旧记录无此字段 ⇒ 默认关、强度取默认档（老书行为不变）。
      // 强度**吸附到最近的档位**（分档预生成只有 5 张缓存图；旧记录/坏值一律归档）
      blurOn: rec.blurOn === true,
      blurRadius: ReaderCustomBg.snapBlurTier(
        ReaderCustomBg.num(rec.blurRadius, BG_BLUR_RADIUS_DEFAULT)),
      // 自定义背景（2026-09-27）：旧记录无此字段 ⇒ 空（不用自定义背景）
      customTexId: typeof rec.customTexId === 'string' ? rec.customTexId : ''
    };
  }

  /** 读一条记录；不存在 / 解析失败 / 字段损坏都返回 `null`（绝不把半成品交给渲染） */
  static read(key: string): ReaderBgRecord | null {
    let raw: string = '';
    try {
      raw = PreferencesUtil.getSync(key, '') as string;
    } catch (e) {
      return null;
    }
    if (typeof raw !== 'string' || raw.length === 0) {
      return null;
    }
    try {
      const rec = JSON.parse(raw) as ReaderBgRecord;
      if (rec === null || rec === undefined) {
        return null;
      }
      return ReaderCustomBg.normalize(rec);
    } catch (e) {
      return null;
    }
  }

  static write(key: string, rec: ReaderBgRecord): void {
    try {
      PreferencesUtil.putSync(key, JSON.stringify(rec));
    } catch (e) {
      // 落盘失败不能影响阅读：下一次 save 或 aboutToDisappear 还会再写一次
    }
  }

  /** 本书的记录（`null` = 本书从没动过这个开关） */
  static loadBook(bookName: string): ReaderBgRecord | null {
    return ReaderCustomBg.read(ReaderCustomBg.bookKey(bookName));
  }

  /**
   * 写本书记录，并把书名登记进「覆盖表」。
   *
   * ⚠️ 登记表是**必须**的：`PreferencesUtil` 没有"列出全部键"的能力
   *   （`oh_modules\@pura\harmony-utils\…\PreferencesUtil.ets` 只有
   *    putSync / getSync / hasSync / deleteSync / clearSync），
   *   而「同步全局」要能把这批"本书覆盖"逐条清掉。所以自己维护一份索引。
   */
  static saveBook(bookName: string, rec: ReaderBgRecord): void {
    ReaderCustomBg.write(ReaderCustomBg.bookKey(bookName), rec);
    const list = ReaderCustomBg.loadOverrides();
    if (!list.includes(bookName)) {
      list.push(bookName);
      ReaderCustomBg.saveOverrides(list);
    }
  }

  static loadGlobal(): ReaderBgRecord | null {
    return ReaderCustomBg.read(ReaderCustomBg.KEY_GLOBAL);
  }

  static loadOverrides(): string[] {
    let raw: string = '';
    try {
      raw = PreferencesUtil.getSync(ReaderCustomBg.KEY_OVERRIDES, '') as string;
    } catch (e) {
      return [];
    }
    if (typeof raw !== 'string' || raw.length === 0) {
      return [];
    }
    try {
      const list = JSON.parse(raw) as string[];
      // 必须校验是数组：盘上要是被写坏成别的东西，后面 `list.includes/push/for-of` 会直接抛。
      return Array.isArray(list) ? list : [];
    } catch (e) {
      return [];
    }
  }

  private static saveOverrides(list: string[]): void {
    try {
      PreferencesUtil.putSync(ReaderCustomBg.KEY_OVERRIDES, JSON.stringify(list));
    } catch (e) {
      // 同上：落盘失败不阻断
    }
  }

  /**
   * 打开一本书时解析该用哪条记录：**本书记录优先，其次全局记录，都没有则 `null`**
   * （`null` ⇒ 维持推荐色，什么都不做）。
   */
  static resolve(bookName: string): ReaderBgRecord | null {
    const own = ReaderCustomBg.loadBook(bookName);
    if (own !== null) {
      return own;
    }
    return ReaderCustomBg.loadGlobal();
  }

  /**
   * 「同步全局」：把当前这条记录写进全局，并**清掉所有"本书覆盖"**，
   * 让全软件（含已单独设置过的书、以及以后新增的书）统一回落到这一条。
   *
   * 为什么是"清覆盖"而不是"逐本写入"：逐本写入要遍历书库做 N 次同步落盘
   *   （`booksDao.search({})` 拿到全部书），书多时是一次可感知的卡顿；
   *   而解析顺序本来就是"本书有覆盖才用本书"，清掉覆盖 = 效果完全等价且只写 1 次。
   *
   * @returns 被清掉覆盖的书名条数（用于给用户回执）
   */
  static syncGlobal(rec: ReaderBgRecord): number {
    const cleared = ReaderCustomBg.loadOverrides();
    ReaderCustomBg.write(ReaderCustomBg.KEY_GLOBAL, rec);
    for (const name of cleared) {
      try {
        PreferencesUtil.deleteSync(ReaderCustomBg.bookKey(name));
      } catch (e) {
        // 单条删除失败不影响其余
      }
    }
    // ⚠️ 本书的覆盖也一并清掉（它已包含在上面那张表里）：清完本书就"没有自己的记录"，
    //    解析时自然回落到刚落盘的全局记录 = 同一份值 ⇒ UI 状态不变。
    ReaderCustomBg.saveOverrides([]);
    return cleared.length;
  }

  // ── 「保存方案」（用户调好的颜色存成「背景」那一行的一格）────────────────────
  //
  // 归属：**全软件共用**（用户 2026-09-26 拍板）。理由：这是"我自己调出来的调色板"，
  //   跟书的排版无关；存成按书的话换一本书就找不到了。
  // 与 `ReaderBgGlobal`（同步全局）是**两件事**：
  //   · `ReaderBgGlobal` = "这本书现在用哪个颜色"这一个**状态**；
  //   · `ReaderBgSchemes` = 一份**可复用的颜色清单**（存下来不等于立刻生效）。

  private static readStringList(key: string): string[] {
    let raw: string = '';
    try {
      raw = PreferencesUtil.getSync(key, '') as string;
    } catch (e) {
      return [];
    }
    if (typeof raw !== 'string' || raw.length === 0) {
      return [];
    }
    try {
      const list = JSON.parse(raw) as string[];
      if (!Array.isArray(list)) {
        return [];
      }
      // 逐项纠正：只保留能解析成颜色的项（盘上被写坏时也不会让 UI 出现空白色块）
      const out: string[] = [];
      for (const s of list) {
        if (typeof s === 'string' && ReaderCustomBg.parseColor(s) !== null) {
          out.push(s);
        }
      }
      return out;
    } catch (e) {
      return [];
    }
  }

  // ── 「保存方案」V2（2026-09-25 用户改版：方案 = 背景色 + 字色 成对）──────────
  //
  // 用户原话：「保存方案按钮增加字体支持，保存后的方案**不再出现在背景中**，而是出现在
  //   保存方案这一排按钮的下方，方式和背景缩略图一样，一行四个，最多三行，
  //   第三行开始无限横向增加。」
  // ⇒ 方案从"单一颜色"升级为「背景色 + 字色」成对存储（`BgSchemeEntry`）；
  //   `fontHex = ''` 表示字色跟随背景自动对比（存的时候用户还没手动选字色）。
  // 存储换新键 `ReaderBgSchemesV2`；首次读取发现 V2 为空且旧键（纯 `#RRGGBB` 字符串数组）
  // 有数据时**一次性迁移**（旧方案补 `fontHex=''`），旧键保留不动（回退容易）。
  // 归属：**全软件共用**（用户 2026-09-26 拍板），与 `ReaderBgGlobal`（本书状态）是两件事。

  static readonly KEY_SCHEMES_V2: string = 'ReaderBgSchemesV2';

  private static schemeKey(e: BgSchemeEntry): string {
    // 统一规格化成 `#RRGGBB` 再比对，避免 '#fff' 与 '#FFFFFF' 被当成两条方案
    const bg = ReaderCustomBg.parseColor(e.bgHex);
    const bgHex = bg === null ? e.bgHex : ReaderCustomBg.hexOf(bg);
    return bgHex + '|' + e.fontHex;
  }

  /** 已保存的方案（顺序 = 添加顺序）。损坏项逐条剔除，不让坏数据进 UI */
  static loadSchemes(): BgSchemeEntry[] {
    let list: BgSchemeEntry[] = [];
    try {
      const raw = PreferencesUtil.getSync(ReaderCustomBg.KEY_SCHEMES_V2, '') as string;
      const parsed = JSON.parse(raw) as BgSchemeEntry[];
      if (Array.isArray(parsed)) {
        for (const e of parsed) {
          if (e !== null && e !== undefined
            && typeof e.bgHex === 'string' && ReaderCustomBg.parseColor(e.bgHex) !== null
            && typeof e.fontHex === 'string') {
            list.push({ bgHex: e.bgHex, fontHex: e.fontHex });
          }
        }
      }
    } catch (e) {
      list = [];
    }
    if (list.length === 0) {
      // 一次性迁移旧版（纯颜色）方案；迁移后旧键保留，不删（回退容易）
      const legacy = ReaderCustomBg.readStringList(ReaderCustomBg.KEY_SCHEMES);
      if (legacy.length > 0) {
        for (const s of legacy) {
          list.push({ bgHex: s, fontHex: '' });
        }
        try {
          PreferencesUtil.putSync(ReaderCustomBg.KEY_SCHEMES_V2, JSON.stringify(list));
        } catch (e) {
          // 落盘失败不影响本次返回
        }
      }
    }
    return list;
  }

  /**
   * 追加一个方案（同「背景+字色」组合不重复存）。
   * @param fontHex 手动选过的字色；'' = 未手动选（应用时按背景自动对比）
   * @returns `'ok'` 新增成功；`'dup'` 已存在；`'full'` 已达上限
   */
  static addScheme(bgHex: string, fontHex: string): string {
    const bg = ReaderCustomBg.parseColor(bgHex);
    if (bg === null) {
      return 'dup';
    }
    const entry: BgSchemeEntry = {
      bgHex: ReaderCustomBg.hexOf(bg),
      fontHex: (fontHex.length > 0 && ReaderCustomBg.parseColor(fontHex) !== null)
        ? ReaderCustomBg.hexOf(ReaderCustomBg.parseColor(fontHex) as RgbTriple)
        : ''
    };
    const list = ReaderCustomBg.loadSchemes();
    const key = ReaderCustomBg.schemeKey(entry);
    for (const x of list) {
      if (ReaderCustomBg.schemeKey(x) === key) {
        return 'dup';
      }
    }
    if (list.length >= ReaderCustomBg.MAX_SCHEMES) {
      return 'full';
    }
    list.push(entry);
    try {
      PreferencesUtil.putSync(ReaderCustomBg.KEY_SCHEMES_V2, JSON.stringify(list));
    } catch (e) {
      // 落盘失败不阻断 UI
    }
    return 'ok';
  }

  /** 删除一个方案（整条匹配；不存在时是幂等空操作） */
  static deleteScheme(e: BgSchemeEntry): void {
    const key = ReaderCustomBg.schemeKey(e);
    const list = ReaderCustomBg.loadSchemes();
    const kept = list.filter((x: BgSchemeEntry) => ReaderCustomBg.schemeKey(x) !== key);
    if (kept.length !== list.length) {
      try {
        PreferencesUtil.putSync(ReaderCustomBg.KEY_SCHEMES_V2, JSON.stringify(kept));
      } catch (e) {
        // 落盘失败不阻断 UI
      }
    }
  }
}
