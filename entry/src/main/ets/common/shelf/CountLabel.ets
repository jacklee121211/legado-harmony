/**
 * 2026-11-03（P6 / B2）：**计数文案的唯一实现**。
 *
 * ── 为什么需要它 ───────────────────────────────────────────────────────────
 * 「共 N 本 · M 个分组」「已选 N 本 · M 个分组」这类文案在收敛前有 4 份各自拼的字符串：
 *   · `BookFolder.ets:751`        分组卡片副标题
 *   · `BookContentRefresh.ets:502` 同一句的复制粘贴（两条刷新路径各一份）
 *   · `BookManagePage.ets:419`    批量页顶部"已选…"
 * 三份写法虽然目前一致，但改一处就漂；而 `coverInfoDialog.ets:186` 甚至直接写死
 * `` Text(`共${0}本`) ``（永远是 0，属于同一语义的第 4 份"错版"）。
 *
 * ── 口径（与用户 2026-11 口径一致，改动前请先确认）────────────────────────────
 *   · 分组卡片：`共12本 · 3个分组`；没有子分组时只显示 `共12本`；
 *   · 批量页顶部：`已选3本 · 2个分组`；只选了书则 `已选3本`（**分组数不含"全部/未分组"这类系统单元**，
 *     与 `BookManagePage.selectedGroupCount()` 的口径保持一致）；
 *   · 详情类小字：`共12本`。
 *
 * ⇒ 所有计数文案都从这里出；闸门 `count-label-fork` 会拦住"又自己拼一份"。
 */
export class CountLabel {
  /** 分组卡片副标题：`共N本 · M个分组`（M=0 时省略后半句） */
  static groupCard(books: number, groups: number): string {
    const b: number = books > 0 ? books : 0
    const g: number = groups > 0 ? groups : 0
    return g > 0 ? `共${b}本 · ${g}个分组` : `共${b}本`
  }

  /** 批量页顶部：`已选N本 · M个分组`（M=0 时省略后半句） */
  static selected(books: number, groups: number): string {
    const b: number = books > 0 ? books : 0
    const g: number = groups > 0 ? groups : 0
    return g > 0 ? `已选${b}本 · ${g}个分组` : `已选${b}本`
  }

  /** 详情类小字：`共N本` */
  static books(books: number): string {
    return `共${books > 0 ? books : 0}本`
  }
}

export default CountLabel
