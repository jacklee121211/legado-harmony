/**
 * paging.ts —— 分页数学（**纯函数**，可单测）
 * ============================================================================
 * 这是 v3 架构对 B3「持续翻页会回跳」的根治点。
 *
 * 旧实现（`WifiBookServer.ets` 内嵌 JS，v3.19/v3.20）：
 *   · 位置锚 = `pageIdx`（第几页）；`pageCount/stride` 由 `layoutCols()` **每次现算**；
 *   · `next()` 里 `last=pageCount-1` 用的是**上一次渲染遗留的旧值**，`t=total()` 是新值
 *     ⇒ 边界判断错位；`goPage()` 再把 `pageIdx` 夹进新页数 ⇒ 前进变成回跳。
 *   · 字号/行距/窗口/工具栏任何变化都会重排列数 ⇒ 同一个 `pageIdx` 指向**别的文字**。
 *
 * v3 的原则：**位置锚永远是"段落下标"（等价于字符偏移）**，页号只是派生结果：
 *   · 布局变化 ⇒ 重新 `buildPageMap()` ⇒ 按"段落下标"反查新页号 ⇒ 位置不变；
 *   · 已知每个段落在多列流里的横坐标 `lefts[i]`（= DOM 的 `offsetLeft`）与步长 `stride`，
 *     则 `页号(i) = round(lefts[i] / stride)`，`首段(p) = min{ i | 页号(i) = p }`。
 */

export interface PageMap {
  /** 页数（>=1） */
  pageCount: number
  /** 步长（一页的横向距离，含列间距；来自实测布局） */
  stride: number
  /** `firstPara[p]` = 第 p 页的首段下标（单调不减） */
  firstPara: number[]
}

/** 空映射（未布局/无内容时的安全值） */
export function emptyPageMap(): PageMap {
  return { pageCount: 1, stride: 0, firstPara: [0] }
}

/**
 * 由"每段横坐标 + 步长"构建页映射。
 * @param lefts 每段在多列流里的横坐标（DOM `offsetLeft`），长度 = 段落数
 * @param stride 一页步长（<=0 视为未布局 ⇒ 单页）
 */
export function buildPageMap(lefts: number[], stride: number, paraCount: number): PageMap {
  if (!(stride > 0) || paraCount <= 0) {
    return { pageCount: 1, stride: stride > 0 ? stride : 0, firstPara: [0] }
  }
  const firstPara: number[] = []
  let lastPage = -1
  for (let i = 0; i < paraCount; i++) {
    const x = Number.isFinite(lefts[i]) ? lefts[i]! : 0
    let p = Math.round(x / stride)
    if (!Number.isFinite(p) || p < 0) p = 0
    // 单调保护：段落顺序与列顺序一致，页号不允许回退
    if (p < lastPage) p = lastPage
    if (p > lastPage) {
      // 空缺的页（理论上不该出现，例如某页只有空内容）也补上，保证 firstPara 与页号对齐
      for (let q = lastPage + 1; q <= p; q++) firstPara.push(i)
      lastPage = p
    }
  }
  if (firstPara.length === 0) firstPara.push(0)
  return { pageCount: firstPara.length, stride, firstPara }
}

/** 段落下标 → 页号（二分；越界自动夹取） */
export function pageOfPara(map: PageMap, paraIndex: number): number {
  const arr = map.firstPara
  if (arr.length === 0) return 0
  if (paraIndex <= arr[0]!) return 0
  if (paraIndex >= arr[arr.length - 1]!) return arr.length - 1
  let lo = 0
  let hi = arr.length - 1
  while (lo < hi) {
    const mid = (lo + hi + 1) >> 1
    if (arr[mid]! <= paraIndex) lo = mid
    else hi = mid - 1
  }
  return lo
}

/** 页号 → 该页首段下标（越界自动夹取） */
export function firstParaOfPage(map: PageMap, page: number): number {
  const arr = map.firstPara
  if (arr.length === 0) return 0
  const p = Math.max(0, Math.min(arr.length - 1, Math.floor(page)))
  return arr[p]!
}

/** 双页模式把页号吸附到偶数页（跨页展开时左页为偶数） */
export function snapPage(page: number, twoUp: boolean): number {
  const p = Math.max(0, Math.floor(page))
  if (!twoUp) return p
  return p - (p % 2)
}
