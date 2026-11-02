/**
 * 2026-11-02 新增：**架构收敛双轨开关**。
 *
 * 目的：让"新数据通路"与"旧实现"并存，逐页面切换，任何一步都能秒回退。
 * 规则（真源文档第 4 节）：
 *   · 开关默认 **false**（旧路径），行为零变化；
 *   · 某页面验证通过（真机对照截图一致）后，把对应开关改 true 再提交一次；
 *   · 全部页面切完、稳定一个版本后，删除旧分支与开关本身。
 */
export class GroupFlags {
  /** P1-2：书架分组页改读 GroupStore（唯一树真源） */
  static USE_STORE_IN_FOLDER: boolean = true

  /** P1-2：批量管理页改读 GroupStore */
  static USE_STORE_IN_MANAGE: boolean = false

  /** P2-1：分组弹窗的 隐藏/解散/删除 改走 GroupMutation（唯一写入口） */
  static USE_MUTATION_IN_DIALOG: boolean = true

  /**
   * P4：分组页使用新渲染（分组+书籍同域滚动）。
   *
   * 接线点（2026-11-02 第 23 轮，全仓只有这两处读它）：
   *   · `BookContent.ets` 的 `List` 内容分支：开 ⇒ `ListItemGroup({header, space:10})`；
   *   · `BookContentRefresh.ets`：开 ⇒ 子分组宫格**不再**单独渲染，改为 `header` 传给 `BookContent`。
   * 回退 = 把本开关改回 false（两处同时回旧结构，无需改别的代码）。
   */
  static USE_UNIFIED_SCROLL: boolean = true
}
