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

  // ⚠️ 2026-11-02 第 26 轮（A③）：删掉了 `USE_STORE_IN_MANAGE`。
  //   原因：它**全仓 0 处读取**（脚本核对 `GroupFlags.USE_STORE_IN_MANAGE` 只命中定义处），
  //   写 true 不会有任何行为变化 —— 这种"看起来在切换、实际什么都不做"的开关比没有更危险：
  //   文档/注释里还写着"批量管理页改读 GroupStore"，会误导后续判断（本项目已踩过一次）。
  //   P1-2 真正接线时再加回来，且**必须同时给出读取点**。

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
