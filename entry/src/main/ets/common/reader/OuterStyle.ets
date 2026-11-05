/**
 * PuraX 外屏「极简阅读」的版式常量（2026-11-06）。
 *
 * ── 为什么要单独一份常量（而不是让外屏也走用户设置） ───────────────────────
 * 外屏只有 **326×326vp / 980×980px**（官方最佳实践 `bpta-purax-guide` 规格，
 * 见 `OuterScreen.ets:27-29`）。用户在内屏调过的字号/行距直接搬到外屏，
 * 行数会剧烈变化 —— 这正是官方适配回执第 2 条「上下留白」与内容截断的土壤。
 *
 * ⇒ 外屏**固定一套版式**：字号、行距、左右/上下留白都不跟随用户设置，用户也改不了
 *   （外屏没有设置入口）。日夜、字体、字色、背景仍然跟随内屏（同一份模型）——
 *   这就是"两种形态共享同一组数据，只在投影时覆盖版式字段"。
 *
 * ── 覆盖发生在哪里（单一通路）────────────────────────────────────────────
 *   1. 字号/行距：`ReaderPage3.projectSetting()` —— 唯一的只读投影出口
 *   2. 左右/上下留白：`ReaderPage3` 里传给两档的 `sideInsetVp/topInsetVp/bottomInsetVp`
 *   ⇒ 引擎（ReaderKit `setPageConfig`）与自绘层吃的是同一份覆盖后的投影，不会各算一套。
 *
 * ⚠️ **本组数值是初值，等真机看效果后定格**（用户 2026-11-06：「布局参数最后再商讨」）。
 *    调整只改本文件，不要散落到页面里。
 */
export class OuterStyle {
  /** 正文字号（fp）。外屏 326vp 宽，17fp ≈ 一行 13~14 字 */
  static readonly FONT_SIZE: number = 17

  /** 行距倍数（行高 = 字号 × 本值） */
  static readonly LINE_HEIGHT: number = 1.75

  /** 正文左右留白（vp）——官方回执要求"顶部、底部不留白"，左右同步收紧 */
  static readonly SIDE_INSET_VP: number = 18

  /** 正文上留白（vp）——替代内屏的引擎常量 88vp（外屏 326vp 高容不下） */
  static readonly TOP_INSET_VP: number = 18

  /** 正文下留白（vp）——替代内屏的引擎常量 62vp */
  static readonly BOTTOM_INSET_VP: number = 16
}
