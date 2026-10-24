/**
 * 整书进度百分比 ⇄（目录号 + 章内比例）的换算 —— **章等权**口径（2026-10-25 新增）。
 *
 * ══════════════════════════════════════════════════════════════════════════
 * 为什么单独抽一个文件、且只做"纯函数"
 * ══════════════════════════════════════════════════════════════════════════
 * 阅读页 dock 上方那条滑条从"章节索引滑条"改成"整书百分比滑条"后，
 * 需要把 `0..100` 的百分比翻译成「第几章 + 章内百分之几」，再翻译成 ReaderKit 的
 * `(spine, 块节点, 字符)` 坐标。这条换算要被三处共用：
 *   · 滑条松手后的跳转（`ReaderPage3.commitProgressSeek`）；
 *   · 滑条 thumb 的实时位置（`ReaderPage3.syncSliderPctFromPosition`）；
 *   · 气泡里显示的"第 N/M 章"预览。
 * 所以放在这里，**不持有任何状态、不碰引擎、不做 IO** —— 可单测、可复用。
 *
 * ══════════════════════════════════════════════════════════════════════════
 * 口径：章等权（用户 2026-10-25 拍板 A 案）
 * ══════════════════════════════════════════════════════════════════════════
 *   每章占 `100 / total` 个百分点，章内线性。
 *   · 好处：零成本、无需预扫全书字符数、无需新缓存文件；
 *   · 代价：章节长短不一时，百分比与"真实字数占比"有偏差（实测级 1%~3%）。
 *     用户明确"精度低一点没关系，只要方便使用"，故接受。
 *   · 若将来要提升精度：只改本文件的 `weightOf()` 换成"按章字符数/文件大小加权"，
 *     `percentToChapter` / `chapterToPercent` 的调用方**一行都不用改**。
 *
 * ⚠️ 为什么不用 0.01% 精度：滑条轨道实测约 210vp，1 个物理像素 ≈ 0.16%
 *    ⇒ 手指横拖的物理极限就在 0.1%~0.5%，写 0.01% 只是"数字好看、手感骗人"。
 *    故步长取 0.1%，显示一位小数。
 */

/** 百分比 →（目录号 + 章内比例）的结果 */
export interface ChapterRatio {
  /** 目录下标（0 基） */
  chapterIndex: number;
  /** 章内比例 0..1 */
  ratio: number;
}

/** 夹到 [0, 1]（不依赖外部工具，纯本地） */
function clamp01(v: number): number {
  if (!Number.isFinite(v)) {
    return 0;
  }
  if (v < 0) {
    return 0;
  }
  return v > 1 ? 1 : v;
}

/**
 * 百分比（0..100）→ 目录号 + 章内比例。
 *
 * 边界语义（与滑条两端一致）：
 *   · `pct <= 0`  ⇒ 第 0 章、比例 0（书首）；
 *   · `pct >= 100` ⇒ **最后一章、比例 1**（书末，不是"越界到下一章"）。
 *
 * @param pct 百分比，允许任意浮点（内部自行夹取）
 * @param total 目录项总数；`<= 0` 时返回 `{0, 0}`（目录未就绪的降级值）
 */
export function percentToChapter(pct: number, total: number): ChapterRatio {
  const none: ChapterRatio = { chapterIndex: 0, ratio: 0 };
  if (!Number.isFinite(pct) || total <= 0) {
    return none;
  }
  const p: number = pct < 0 ? 0 : (pct > 100 ? 100 : pct);
  // x ∈ [0, total]：第 i 章覆盖 [i, i+1)
  const x: number = p / 100 * total;
  let idx: number = Math.floor(x);
  if (idx >= total) {
    idx = total - 1;
  }
  if (idx < 0) {
    idx = 0;
  }
  const ratio: number = clamp01(x - idx);
  const out: ChapterRatio = { chapterIndex: idx, ratio: ratio };
  return out;
}

/**
 * （目录号 + 章内比例）→ 百分比（0..100）。
 *
 * 与 `percentToChapter` 严格互逆（同一 total 下往返误差 < 1e-9）。
 * 用于"引擎回报真实位置 → 滑条 thumb 该停在哪"。
 */
export function chapterToPercent(chapterIndex: number, ratio: number, total: number): number {
  if (total <= 0) {
    return 0;
  }
  let idx: number = Math.floor(chapterIndex);
  if (idx < 0) {
    idx = 0;
  }
  if (idx > total - 1) {
    idx = total - 1;
  }
  const v: number = (idx + clamp01(ratio)) / total * 100;
  return v < 0 ? 0 : (v > 100 ? 100 : v);
}

/**
 * 百分比显示文本：**固定一位小数**（`37.4%`）。
 *
 * 为什么固定一位：步长 0.1% ⇒ 一位小数正好是"手指能感知"的极限；
 * 多显示几位只会让人误以为可以更精确（见文件头注释）。
 * `toFixed` 在 ArkTS 里可用，且不会产生 `-0.0`（输入已夹到 [0,100]）。
 */
export function formatProgressPercent(pct: number): string {
  const p: number = !Number.isFinite(pct) ? 0 : (pct < 0 ? 0 : (pct > 100 ? 100 : pct));
  return `${p.toFixed(1)}%`;
}
