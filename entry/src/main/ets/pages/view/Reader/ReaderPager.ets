/**
 * 章节级「行粒度分页」算法（2026-10-26 抽出）—— **沉浸听读层**与**无动画阅读层**共用同一份。
 *
 * ══════════════════════════════════════════════════════════════════════════
 * 为什么必须同源
 * ══════════════════════════════════════════════════════════════════════════
 * 「无动画」与「上下滚动」是**一母同胞**（用户 2026-10-26 口径）：两者都用本工程的
 * 自绘排版（`buildChapterNodes` 块节点 + 同一套字号/行高/段间距），差别只是
 * 「连续行流」vs「按页容量切开」。若两边各写一份切页算术，页边界就会随改动漂移，
 * 表现为「上下 ↔ 无动画」互切时文字轻微错位。
 * 所以切页只允许有**这一份**实现，沉浸层与无动画层都调它。
 *
 * ══════════════════════════════════════════════════════════════════════════
 * 算法（与抽取前 `ReaderPage3.ensureImmersivePages()` 逐字等价）
 * ══════════════════════════════════════════════════════════════════════════
 * · **行粒度**：与 ReaderKit 一致，允许在**段落中间断页**。
 *   （曾按"整段"切：当「已用行数 + 整段行数 > 上限」时只能提前关页，
 *     大段落白白浪费半页 —— 实测 estLines=6/12 = 50%，观感是每页占屏比例乱跳。）
 * · 空块节点（`trim()===''`）**占号但不渲染**，与 ReaderKit 行为一致，保证节点号不错位。
 * · 返回的 `pageOfNode[i]` = 该节点**起始页**号（-1 = 该节点不渲染）。
 *
 * ── 段间距（`gapLines`）────────────────────────────────────────────────────
 * `gapLines <= 0` ⇒ **完全不计价**，走整数分支 —— 这条分支就是抽出前的原代码，
 *   逐字节等价（沉浸听读层用这条，行为零变化）。
 * `gapLines > 0`  ⇒ 每个段落**开头**额外占用 `gapLines` 行的高度
 *   （无动画层用它对齐「上下滚动」的 `SCROLL_PARA_GAP_EM = 0.45em`：
 *    滚动层每行 `Text` 都带 `padding.top = fontSize × 0.45`，
 *    所以分页时这一段也必须占掉同样的高度，否则切模式会"段落忽然变密"）。
 *   此时用浮点累加，切字符时向下取整（宁可少放一个字，也不让内容溢出页面）。
 */

/**
 * 段首缩进字数（2 个字位）。
 *
 * ⚠️ 与 `ReaderPage3.HL_INDENT_SLOTS` **必须相等**：那个常量同时被标定通道、
 * 沉浸层、滚动层使用，改一处等于改全工程版式。这里复制一份是刻意的 ——
 * 分页算法不能反向 import 页面（页面已经 import 本文件，会成环）。
 */
export const INDENT_SLOTS: number = 2;

/** 分页结果：`pages[p]` = 第 p 页的切片数组，切片 = `[节点号, 起始字符, 结束字符]` */
export interface PaginateResult {
  pages: number[][][];
  pageOfNode: number[];
}

/**
 * 把一章的块节点切成固定页。
 *
 * @param nodes     本章块节点文本（下标 = ReaderKit 块节点号）
 * @param cpl       每行字数（`floor(文本宽 / 字宽)`，调用方按自己的几何算好）
 * @param maxLines  每页可容纳行数（同上，调用方按自己的页高算好）
 * @param gapLines  段间距折合行数（0 = 不计价，见文件头）
 */
export function paginateNodes(nodes: string[], cpl: number, maxLines: number,
  gapLines: number): PaginateResult {
  const pages: number[][][] = [];
  const map: number[] = [];
  const lines: number = nodes.length;
  for (let i = 0; i < lines; i++) {
    map.push(-1);
  }
  const charsPerLine: number = Math.max(1, Math.floor(cpl));
  const pageLines: number = Math.max(1, Math.floor(maxLines));
  const gap: number = gapLines > 0 ? gapLines : 0;

  // ── 整数分支：段间距不计价（= 抽取前的原实现，逐字等价）───────────────────
  if (gap === 0) {
    let curPage: number[][] = [];
    let used: number = 0;
    for (let i = 0; i < lines; i++) {
      const t: string = nodes[i];
      if (t.trim().length === 0) {
        continue;
      }
      const len: number = t.length;
      let from: number = 0;
      while (from < len) {
        const indent: number = from === 0 ? INDENT_SLOTS : 0;
        const nl: number = Math.max(1, Math.ceil((len - from + indent) / charsPerLine));
        const room: number = pageLines - used;
        if (nl <= room) {
          if (map[i] < 0) {
            map[i] = pages.length; // 该节点起始页
          }
          curPage.push([i, from, len]);
          used += nl;
          from = len;
        } else if (room <= 0) {
          pages.push(curPage);
          curPage = [];
          used = 0;
        } else {
          // 本页剩余空间放不下整段 ⇒ 按行切：本页放 room 行，余下到下一页
          const takeChars: number = Math.max(1, room * charsPerLine - indent);
          const to: number = Math.min(len, from + takeChars);
          if (map[i] < 0) {
            map[i] = pages.length;
          }
          curPage.push([i, from, to]);
          from = to;
          pages.push(curPage);
          curPage = [];
          used = 0;
        }
      }
    }
    if (curPage.length > 0) {
      pages.push(curPage);
    }
    return { pages: pages, pageOfNode: map };
  }

  // ── 浮点分支：每段开头额外占 `gap` 行（无动画层用）─────────────────────────
  let curPage: number[][] = [];
  let used: number = 0;
  for (let i = 0; i < lines; i++) {
    const t: string = nodes[i];
    if (t.trim().length === 0) {
      continue;
    }
    const len: number = t.length;
    let from: number = 0;
    while (from < len) {
      const indent: number = from === 0 ? INDENT_SLOTS : 0;
      // 段间距只在**段首**计一次（段中间续排不再计）
      const pad: number = from === 0 ? gap : 0;
      const nl: number = Math.max(1, Math.ceil((len - from + indent) / charsPerLine));
      const room: number = pageLines - used;
      if (pad + nl <= room) {
        if (map[i] < 0) {
          map[i] = pages.length;
        }
        curPage.push([i, from, len]);
        used += pad + nl;
        from = len;
      } else if (room - pad < 1) {
        // 本页连"段间距 + 至少一行"都放不下 ⇒ 直接换页（换页后重新尝试本段）
        if (curPage.length > 0) {
          pages.push(curPage);
        }
        curPage = [];
        used = 0;
      } else {
        // 能放 n 行：n = floor(room - pad)，至少 1 行
        const n: number = Math.max(1, Math.floor(room - pad));
        const takeChars: number = Math.max(1, n * charsPerLine - indent);
        const to: number = Math.min(len, from + takeChars);
        if (map[i] < 0) {
          map[i] = pages.length;
        }
        curPage.push([i, from, to]);
        from = to;
        pages.push(curPage);
        curPage = [];
        used = 0;
      }
    }
  }
  if (curPage.length > 0) {
    pages.push(curPage);
  }
  return { pages: pages, pageOfNode: map };
}
