// 阅读器**排版标定纯计算**（2026-11-04 P3 批 A-2：从 `ReaderPage3.ets` 搬出）。
//
// 为什么独立成模块：这批函数是「页面几何 / 每行字数 / 逐段模拟排版 / 自绘两档度量 /
//   引擎留白 / 沉浸层预算」的**唯一实现**。它们全都不碰 `@State`、不写 AppStorage、
//   不持有 ReaderKit 实例，只吃「入参 + 模块常量 + `display` 纯查询」
//   ⇒ 抽成模块后公式只此一份，本页只剩调用点。
//
// ⚠️ 函数体除 `this.<成员>` → 形参名外**逐字未改**（连注释一起搬）：值、顺序、边界、
//   判定阈值全部原样。唯一的结构性变化是把 `readerSetting` 的读取改成显式入参
//   `setting: readerCore.ReaderSetting`（SDK 声明见
//   `@hms.core.readerservice.readerComponent.d.ets:69` `interface ReaderSetting`）。
//
// ⚠️ 不搬的函数（留 `ReaderPage3.ets`）：`recomputeAutoPitch`（写 `@State autoLineMul`）、
//   `immersiveShiftPx`（读 `TtsEngine` 单例 + 多份 `@State`）、`scrollFontPath`
//   （依赖与字体加载共用的 `SYSTEM_CJK_FONT_PATH`）。
//
// 回退：把这些函数/常量原样搬回 `ReaderPage3.ets`（git revert 对应提交即可）。

import { display } from '@kit.ArkUI';
import { readerCore } from '@kit.ReaderKit';
import { HL_ADVANCE_RATIO, HL_INDENT_SLOTS, SYSTEM_CJK_FONT_NAME } from './ReaderConst';

/** ReaderKit 一页的内容范围（ReaderKit 坐标：node 为 0 基块节点号，即 domPos 的 X-1） */
export interface PageRange {
  spine: number;
  startNode: number;
  startChar: number;
  endNode: number;
  endChar: number;
}

// ══════════════════════════════════════════════════════════════════════════════
// 常量：**排版标定的可微调项**（2026-11-04 从 `ReaderPage3.ets` 搬出，值逐字未改）
// ══════════════════════════════════════════════════════════════════════════════

// ── ArkUI 侧的族名（2026-10-23 真机日志定案，理由见 `arkFontName()` 注释）──────
/**
 * 系统中文黑体在 **ArkUI** 里认的族名（英文全名）。
 * `getFontByName('HarmonyOS Sans SC')` 实测正常返回；而传中文 family
 * 「鸿蒙黑体」会让 ArkUI 解析不到、静默回落默认族。
 */
export const ARK_FONT_SYS_CJK: string = 'HarmonyOS Sans SC';
/** 最后一级回退：ArkUI 的默认无衬线族（只有拉丁字形，仅作兜底，正常不应落到这里） */
export const ARK_FONT_FALLBACK: string = 'HarmonyOS Sans';
/**
 * 系统中文黑体在 ArkUI 侧的字重补偿（2026-10-23 真机验证：`-100` 后与分页模式
 * **完全一致**）。机理与"为什么不能全局用"见 `scrollWeightOffset()` 注释。
 */
export const SCROLL_SYS_CJK_WEIGHT_OFFSET: number = -100;

/**
 * 自绘两档的**字重补偿**（2026-11-01 实测加入）。
 *
 * 实测（两边同字体 `/system/fonts/HarmonyOS_Sans_SC.ttf`、同 weight=400；
 * 同区域像素采样、亮度 <90 计为墨）：
 *   · m80  ：仿真 10.32% vs 自绘 8.23%（自绘轻 20%）
 *   · PuraX：仿真  9.71% vs 自绘 6.36%（自绘轻 34%，肉眼可见）
 * ⇒ 不是参数传错，是**两个渲染栈**（ReaderKit 内部 Chromium 文本栈 vs ArkGraphics）
 *   的光栅/合成差异，只能调数值逼近。
 * 0 = 与设置页字重完全一致（旧行为）；100 = 加粗一档（400→500）。
 * ⚠️ 字重改变字形宽度 ⇒ 自绘重排后每行字数可能变；
 *    若发现与引擎错字加剧，把这个值调回 0。
 */
export const SELF_DRAWN_WEIGHT_BOOST: number = 100;

/**
 * 自绘实际字重 = 设置值 + **按密度插值的补偿**（2026-11-01 用户实测结论）。
 *
 * 实测事实：
 *   · m80 (density 3.375)：补偿 0（400）正好；加到 500 时自绘**比 ReaderKit 黑**；
 *   · PuraX (2.55)：补偿 100（500）正好；400 时明显偏细；
 *   · 平板 (2.25)：倾向 PuraX。
 * ⇒ 同一补偿值无法同时满足，因为“字形笔画粗细”跟**字号落到多少 px** 相关：
 *   m80 的 18fp = 60.75px，PuraX = 45.9px，px 越小笔画越细、越需要加粗。
 *
 * 公式（线性插值，锚点由两处实测值定）：
 *   boost = clamp(round(120 × (3.375 − density)), 0, 200)
 *   · m80   3.375 → 0     ✅（用户实测“正好”）
 *   · PuraX 2.55  → 99    ≈100 ✅（用户实测“正好”）
 *   · 平板  2.25  → 135
 * 若某档不合适，只调系数 120 或上下限即可。
 */
export const WEIGHT_BOOST_PER_DENSITY: number = 120;

/**
 * 引擎上留白（vp）。
 *
 * ★ 2026-11-01 云真机实测（XT2 三折叠，4 次运行、3 种形态、density 2.55/3.0）：
 *   引擎正文首行墨迹**恒定在 ≈158~165px**，与窗口宽度（447~1249vp）、密度、折叠形态
 *   **全部无关** ⇒ 引擎页眉是**按 px 固定**的，不是按 vp，也不是按字号。
 *   （探针把 fontSize 从 14 扫到 28，5 个结果完全相同 ⇒ 该接口对引擎不生效，字号假设作废。）
 *
 * 因此提供两条路径，**默认仍走旧的固定 vp 常量**（= 已验证的 m80 / PuraX 完美行为）：
 *   · `ENGINE_MARGIN_BY_DENSITY = false`（默认）：top = ENGINE_TOP_MARGIN_VP(88)
 *   · `= true`：top = 160px / density + ENGINE_MARGIN_OFFSET_VP(40.6)
 *     ⇒ m80(3.375) 47.4+40.6 = 88.0（与旧值一致）；PuraX(2.55) 62.7+40.6 = 103.3；
 *        平板(2.25) 71.1+40.6 = 111.7
 * ⚠️ 切换后必须三台真机复验，不满意就把开关改回 false（一键回退）。
 */
export const ENGINE_MARGIN_BY_DENSITY: boolean = false;
export const ENGINE_MARGIN_PX: number = 160;
export const ENGINE_MARGIN_OFFSET_VP: number = 40.6;

/** 引擎正文**上**留白（vp，m80 实测反推；三台共用） */
export const ENGINE_TOP_MARGIN_VP: number = 88;
/**
 * 引擎正文**下**留白（vp，m80 实测反推）。
 * ReaderKit 墨迹末行 2586px=766.2vp；自绘在此留白下墨迹末行 ≈ 766vp ⇒ 对齐。
 * ⚠️ 与上留白**不相等**（88 vs 62）：说明引擎的页眉/页脚并非等宽，
 *    「上下对称」的假设在 m80 上不成立，所以这里用两个独立常量。
 */
export const ENGINE_BOTTOM_MARGIN_VP: number = 62;

/**
 * δ 是**唯一旋钮**（vp）：正 = 正文整体下移，负 = 上移；自绘与 ReaderKit 同步跟随。
 * 模型全文见 `ReaderPage3.ets` 的「基准模型（2026-11-01 换轨）」注释段
 * （顶 inset = marginVp + δ、底 inset = marginVp − δ ⇒ 高度 = 屏高 − 2·marginVp，与信息条位置无关）。
 */
export const SELF_DRAWN_DELTA_VP: number = 0;
/**
 * **只动自绘**的校正量（vp）：正 = 自绘整块下移，负 = 上移；高度不变。
 *
 * ── 为什么需要它（2026-11-01 真机实测）────────────────────────────────────
 * 代码能精确知道**自绘**的首行位置（`scrollTopInsetVp()`），但**无法计算**
 * ReaderKit 的首行位置 —— SDK 里 `PageDataInfo` 只有 header/footer/pageOffset，
 * `ReaderSetting` 13 个字段没有 margin（`@hms.core.readerservice.readerComponent.d.ets`）。
 * 现在自绘用的 `margin = calibTopPx/density` 来自 **TTS 高亮框顶**（`TtsHlCalibV3.topPx`），
 * 与引擎「行框顶」并不等价 ⇒ 实测 Mate 80 上自绘比 ReaderKit 高约 **1 行**。
 *
 * δ（`SELF_DRAWN_DELTA_VP`）两边一起动，修不了这种**相对**偏差；
 * 所以单独给自绘一个偏移：顶 +k、底 −k（高度不变）。
 */
export const SELF_DRAWN_ONLY_OFFSET_VP: number = 0;

/**
 * 自绘**顶边**相对引擎的修正（vp）—— **由 m80 截图实测反推**（2026-11-01）。
 *
 * 实测（1320×2848，density 3.375，系统状态栏关，信息窗上/下各一组）：
 *   · ReaderKit 正文墨迹首行 = **338px = 100.1vp**（信息窗在上/在下都相同，已验证不随信息条移动）
 *   · 自绘   正文墨迹首行 = **270px = 80.0vp**
 *   · 行内墨迹偏移（行框顶→墨迹顶）≈ 40px = 11.9vp（两档同字体，可视为相同）
 *   ⇒ ReaderKit 行框顶 ≈ 338−40 = 298px = **88.3vp**；自绘行框顶 = calibTopPx 230px = 68.2vp
 *   ⇒ **顶部差 +20.1vp**
 *
 * ⚠️ 不直接改 `calibTopPx`：那个值还被 TTS 高亮（`TtsHlCalibV3`）使用，改了会连带移动高亮框。
 */
export const SELF_DRAWN_TOP_ADJUST_VP: number = 0;   // 2026-11-01：已并入 ENGINE_TOP_MARGIN_VP，勿重复加

/**
 * 自绘**底边**相对引擎的修正（vp，正值 = 底 inset 收小 = 正文更往下）—— 同批实测。
 *
 * 实测：ReaderKit 正文墨迹末行 = 2586px = **766.2vp**（信息窗上）、2584px（信息窗下）；
 *      自绘正文墨迹末行 = 2564px = **759.7vp** ⇒ 自绘比引擎**高 6.5vp**。
 * 行距两档一致（≈115px = 34vp）⇒ 不是字号问题，只需把自绘的下沿再放低 ~6.5vp。
 */
export const SELF_DRAWN_BOTTOM_ADJUST_VP: number = 0;   // 2026-11-01：已并入 ENGINE_BOTTOM_MARGIN_VP，勿重复加

// ══════════════════════════════════════════════════════════════════════════════
// 计算
// ══════════════════════════════════════════════════════════════════════════════

/** 生效的行高系数：优先用自动校准值 */
export function effectiveLineMul(autoLineMul: number, calibLineMul: number): number {
  return autoLineMul > 0 ? autoLineMul : calibLineMul;
}

/** 字号px（不含行高系数），供 `recomputeAutoPitch` 使用 */
export function geomSelfContained(setting: readerCore.ReaderSetting): number {
  const scale = setting.scaledDensity > 0 ? setting.scaledDensity : 1;
  return Math.max(1, setting.fontSize) * scale;
}

/** [densityPx, scale, fontPx, linePx] —— 高亮与标尺共用的几何基准 */
export function geom(setting: readerCore.ReaderSetting, lineMul: number): number[] {
  const disp = display.getDefaultDisplaySync();
  const densityPx = disp.densityPixels > 0 ? disp.densityPixels : 1;
  const scale = setting.scaledDensity > 0 ? setting.scaledDensity : 1;
  const fontPx = Math.max(1, setting.fontSize) * scale;
  const lh = Math.max(1, setting.lineHeight) * fontPx * lineMul;
  return [densityPx, scale, fontPx, lh];
}

/** 每行字数：按"中文实际字宽 = 字号px × HL_ADVANCE_RATIO"折算 */
export function cplFor(textWPx: number, fontPx: number): number {
  return Math.max(4, Math.floor(textWPx / Math.max(1, fontPx * HL_ADVANCE_RATIO)));
}

/**
 * 逐字模拟本页排版（块级节点强制换行 + 段首 text-indent）。
 * @returns 扁平数组：i*2 = 第 (startNode+i) 个节点的起始行，i*2+1 = 结束行；
 *          最后一项 = 本页总行数。
 */
export function simulatePage(nodes: string[], r: PageRange, cpl: number): number[] {
  const pairs: number[] = [];
  let line = 0;
  let col = 0;
  for (let n = r.startNode; n <= r.endNode && n < nodes.length; n++) {
    const text = nodes[n];
    const from = n === r.startNode ? r.startChar : 0;
    const to = n === r.endNode ? Math.min(r.endChar, text.length - 1) : text.length - 1;
    if (from === 0 && col === 0) {
      col = HL_INDENT_SLOTS; // ReaderKit 给块级元素加的段首缩进
    }
    const startLine = line;
    let endLine = line;
    for (let i = from; i <= to; i++) {
      endLine = line;
      col++;
      if (col >= cpl) {
        col = 0;
        line++;
      }
    }
    pairs.push(startLine, endLine);
    if (col !== 0) {
      col = 0; // 块节点结束：强制换行
      line++;
    }
  }
  pairs.push(line);
  return pairs;
}

/**
 * 自绘两档（上下 / 无动画）的行高（fp）。
 *
 * ⚠️⚠️ **不再乘 `effectiveLineMul()`**（2026-10-27 真机像素实测定案）
 * ──────────────────────────────────────────────────────────────────────
 * 那个系数是**旧架构**的产物：当时自绘层没有排版权，只能"用 ReaderKit 每页行数
 * 反推行高"（见 `recomputeAutoPitch()`），拿到的 `autoLineMul` ≈ 1.25。
 *
 * 现在自绘两档由引擎（`@ohos.graphics.text`）自己排版，行高就**应该直接等于**
 * `lineHeight × fontSize` —— 与 ReaderKit 用的是同一个公式。
 * 继续乘 1.25 的后果（同一章、同一字号实测）：
 *   · 我们行距 **193px** vs ReaderKit **154px**（大 25%）⇒ 整页又疏又空；
 *   · 每页行数偏少 ⇒ 页边界与 ReaderKit 差得更远 ⇒ 进度对不上。
 *
 * ⇒ 去掉系数后：154px（= 1.9 × 24fp × 3.375），与 ReaderKit 逐像素一致。
 */
export function scrollLineHeightFp(setting: readerCore.ReaderSetting): number {
  return setting.lineHeight * setting.fontSize;
}

/** 滚动视图的段首缩进（fp）：2 个字位（`HL_INDENT_SLOTS`） */
export function scrollIndentFp(setting: readerCore.ReaderSetting): number {
  return setting.fontSize * HL_INDENT_SLOTS;
}

/**
 * **引擎族名 → ArkUI 族名**的翻译（2026-10-23，真机日志定案）。
 *
 * ── 为什么需要翻译（`docs/日志.md` 原文证据）────────────────────────────────
 * 引擎侧 config：`fontName:"鸿蒙黑体", fontPath:"/system/fonts/HarmonyOS_Sans_SC.ttf"`
 * —— 引擎是**按 fontPath 直接加载字体文件**的，不依赖族名匹配 ⇒ 永远正确。
 *
 * ArkUI 侧（滚动层/沉浸层/测量通道）只能给 `.fontFamily(名字)`，必须让 ArkUI 的
 * 字体管理器**按名字匹配到族**。而：
 *   · `fontinfo HarmonyOS Sans SC: {"family":"鸿蒙黑体", "fullName":"HarmonyOS Sans SC"}`
 *     ⇒「鸿蒙黑体」只是该 TTF **name 表里的中文本地化 family**；
 *   · 真机实测：`getFontByName('鸿蒙黑体')` **1 秒超时（解析不到）**，
 *     而 `getFontByName('HarmonyOS Sans SC')` 正常返回上面那条 fontinfo
 *     （`ReaderPage3.ets` 的 `readerSetting` 初值注释里也记着这个实测）。
 * ⇒ 直接传「鸿蒙黑体」会让 ArkUI **静默回落到默认族 `HarmonyOS Sans`**
 *   （只有拉丁字形，中文再走另一套 CJK 兜底）⇒ 字形与引擎不同、观感"更黑"。
 *   注意**不是**字重问题：两边 `fontWeight` 都是 400。
 *
 * 反过来，自定义/系统别名（如「书宋-简」）在系统字体清单里就是真名
 * （`sysfonts(1): ["书宋-简"]`），`getFontByName` 能直接解析 ⇒ 原样传即可。
 */
export function arkFontName(setting: readerCore.ReaderSetting): string {
  const n: string = setting.fontName;
  if (n === undefined || n === null || n.length === 0) {
    return ARK_FONT_FALLBACK;
  }
  if (n === SYSTEM_CJK_FONT_NAME) {
    // 「鸿蒙黑体」= HarmonyOS_Sans_SC.ttf 的中文 family ⇒ ArkUI 要英文全名
    return ARK_FONT_SYS_CJK;
  }
  return n;
}

/** 自绘层实际使用的字重（设置值 + 补偿，夹在 100~900） */
export function selfDrawnFontWeight(setting: readerCore.ReaderSetting): number {
  const d: number = densityVp();
  let boost: number = SELF_DRAWN_WEIGHT_BOOST;
  if (d > 0) {
    boost = Math.round(WEIGHT_BOOST_PER_DENSITY * (3.375 - d));
    boost = Math.max(0, Math.min(200, boost));
  }
  const w: number = setting.fontWeight + boost;
  return Math.max(100, Math.min(900, w));
}

/**
 * 滚动层的 `fontFamily` 取值：**ArkUI 族名 + 回退链**。
 *
 * ArkUI 的 `fontFamily` 支持逗号分隔的回退列表（与 CSS 同语义），
 * 前面的解析不到就用后面的 ⇒ 即使某个自定义字体在 ArkUI 侧注册失败，
 * 也会落到 `HarmonyOS Sans SC`（全字库），而不是掉进只有拉丁字形的默认族。
 */
export function scrollFontFamily(setting: readerCore.ReaderSetting): string {
  const primary: string = arkFontName(setting);
  if (primary === ARK_FONT_SYS_CJK) {
    return `${ARK_FONT_SYS_CJK}, ${ARK_FONT_FALLBACK}`;
  }
  return `${primary}, ${ARK_FONT_SYS_CJK}, ${ARK_FONT_FALLBACK}`;
}

/**
 * ArkUI 侧的字重补偿（2026-10-23 真机定案：`-100` 后与分页模式**完全一致**）。
 *
 * 机理：`HarmonyOS Sans SC` 是**可变字体**——
 *   · 引擎加载该 ttf 时**不指定 wght 轴** ⇒ 用文件**默认实例**（比 Regular 细一档）；
 *   · ArkUI 收到 `fontWeight(400)` 会**显式取 wght=400 实例**。
 * ⇒ 系统中文黑体必须减一档才对得上；真机已验证 400→300 完全吻合。
 *
 * ⚠️ **只对系统中文黑体生效**：自定义字体（书宋-简 `ShuS-SC.ttf`、用户导入字体）
 *    大多是单一字重的静态字体，减一档要么被忽略、要么触发合成变细 ⇒ 会弄坏。
 */
export function scrollWeightOffset(setting: readerCore.ReaderSetting): number {
  return arkFontName(setting) === ARK_FONT_SYS_CJK ? SCROLL_SYS_CJK_WEIGHT_OFFSET : 0;
}

/**
 * 引擎正文上留白（vp）—— **基准模型唯一的地基**。
 *
 * 取值优先级：`calibTopPx / density`（标定过的真实引擎首行位置）
 *            → 兜底 `SELF_DRAWN_MARGIN_FALLBACK_VP`（58vp，三台实测 55~62 的中值）。
 * 依据：探针 MEASURE 实测 topMargin = 55 / 62 / 56 vp
 *      （手机 3.375 / 宽折叠 2.55 / 平板 2.25）；
 *      官方 FAQ `faqs-reader-3` 原文：「ReadPageComponent 顶部和底部预留了页眉页脚，
 *      呈现效果为顶部和底部有空白」⇒ 上下留白对称，且 `ReaderSetting` 13 个字段里
 *      没有 margin/inset（SDK `@hms.core.readerservice.readerComponent.d.ets`）。
 *
 * ── 2026-11-01 第二次修正：**改为 vp 常量，不再除以 density** ────────────────
 * 旧实现 `margin = calibTopPx / density` 会让不同密度设备得到完全不同的 vp 留白：
 *   · m80  (3.375) ⇒ 230/3.375 = 68.2vp
 *   · PuraX(2.55)  ⇒ 230/2.55  = 90.2vp
 *   · 平板 (2.25)  ⇒ 230/2.25  = 102.2vp
 * ⇒ 用户实测「平板/PuraX 上自绘比 ReaderKit **上下都矮**」——正是这两个大留白挤掉的。
 * 引擎的页眉页脚是**按 vp 布局**的（三台探针实测行距 17.6~18.2vp 几乎恒定），
 * 所以这里改为**固定 vp**，按 m80 上"ReaderKit 实际墨迹位置"反推：
 *   · 上留白 88vp（RK 首行墨迹 100.1vp − 行内墨迹偏移 ≈12vp）
 *   · 下留白 62vp（把自绘末行推到 RK 的 766vp）
 * ⚠️ `calibTopPx` 仍保留给 **TTS 高亮**（`TtsHlCalibV3`），不参与这里。
 */
export function engineMarginVp(): number {
  if (!ENGINE_MARGIN_BY_DENSITY) {
    return ENGINE_TOP_MARGIN_VP;
  }
  const d: number = densityVp();
  if (d <= 0) {
    return ENGINE_TOP_MARGIN_VP;
  }
  return ENGINE_MARGIN_PX / d + ENGINE_MARGIN_OFFSET_VP;
}

/** 引擎下留白（vp）：与上留白保持固定差（旧行为 88→62 即 −26） */
export function engineBottomMarginVp(): number {
  if (!ENGINE_MARGIN_BY_DENSITY) {
    return ENGINE_BOTTOM_MARGIN_VP;
  }
  return Math.max(0, engineMarginVp() - 26);
}

/**
 * 自绘文本区**顶边**（vp）= 引擎上留白 + δ。
 *
 * 基准模型（2026-11-01 换轨）：自绘矩形 = 引擎矩形 + 一个 δ。
 *   · 不再按信息条位置分支：官方 FAQ 说上下留白是内建页眉页脚，
 *     信息条本来就落在页脚留白里 ⇒ **信息条不再驱动正文位移**；
 *   · 两态高度恒等（= 屏高 − 2·margin），切换信息条位置时正文不动。
 */
export function scrollTopInsetVp(): number {
  return Math.max(0, ENGINE_TOP_MARGIN_VP + SELF_DRAWN_DELTA_VP
    + SELF_DRAWN_ONLY_OFFSET_VP + SELF_DRAWN_TOP_ADJUST_VP);
}

/**
 * 滚动模式文本区**底部**（vp）—— 只让出手势条，尽量往下铺。
 *
 * 用户原话：「底部的话也向下，正好相当于把整个正文内容区域向下了」
 * ⇒ 顶部下移之后，底部**不再保留原来那 28vp 的呼吸位**（那会让整个文本区变矮、
 *   读起来比正常模式少一行），只留手势条本身的高度 + 8vp 余量，
 *   于是整块正文区域是"整体下移"的观感，而不是"上下各切一刀"。
 */
/**
 * 自绘文本区**底边**（vp）= 引擎下留白 − δ。
 *
 * 基准模型：引擎上下留白对称（官方 FAQ：顶部和底部预留了页眉页脚），
 * 所以底边 = margin − δ，与顶边 = margin + δ 配对 ⇒ 高度恒为 `屏高 − 2·margin`，
 * **两态（信息条在上/在下）完全一致**，切换时不重排、不跳行。
 */
export function scrollBottomInsetVp(): number {
  return Math.max(0, engineBottomMarginVp() - SELF_DRAWN_DELTA_VP
    - SELF_DRAWN_ONLY_OFFSET_VP - SELF_DRAWN_BOTTOM_ADJUST_VP);
}

/** 当前显示密度（px/vp）；查询失败或异常值一律按 1 处理 */
export function densityVp(): number {
  const d = display.getDefaultDisplaySync();
  return d.densityPixels > 0 ? d.densityPixels : 1;
}

/** 文本区左边界（vp）——独立计算，不能依赖标定模式（calibLeft 只在标定模式下才被赋值） */
export function textAreaLeftVp(setting: readerCore.ReaderSetting, windowWidth: number,
  calibWidthRatio: number): number {
  const densityPx = densityVp();
  const vw = setting.viewPortWidth > 0 ? setting.viewPortWidth : windowWidth;
  const textW = Math.max(1, vw * calibWidthRatio);
  return Math.max(0, (vw - textW) / 2) / densityPx;
}

/** 沉浸听读可见高度（px）：**按整屏**算，不按阅读器自身高度。
 *  实测（2026-09-20）：阅读器的 web 视图只有 2150px，而窗口是 2848px；
 *  若用阅读器高度算预算，沉浸层只占上方 3/4，底部空出一大块（截图为证）。 */
export function immersiveBudgetPx(windowHeight: number, bottomRectHeight: number,
  calibTopPx: number): number {
  const disp = display.getDefaultDisplaySync();
  const fullPx = disp.height > 0 ? disp.height : windowHeight;
  const reserveVp = 24 + bottomRectHeight + 46; // 浮条下距 + 浮条高度 + 2vp 余量
  return Math.max(120, fullPx - calibTopPx - reserveVp * densityVp());
}
