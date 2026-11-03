/**
 * 2026-11-02 新增：**架构收敛双轨开关**。
 *
 * ── 2026-11-03（Ⅱ-3）状态：**所有读取点已删除，本文件仅作一个版本的留档** ───────────
 * 五个读取点已随旧分支一起删除（闸门 `group-flags-old-branch` 预算 5→0）：
 *   · `BookFolder.loadGroupList()`        —— 固定走 `GroupStore`（唯一树真源）
 *   · `BookContent` 列表头分支            —— 固定 `if (this.useHeaderInList)`
 *   · `BookContentRefresh` 两处           —— 固定"子分组宫格作为列表头"
 *   · `FolderInfoDialog.hideGroup()`      —— 固定走 `GroupMutation.setVisible`
 * ⇒ 下面这些常量**改了不会有任何行为变化**（这正是当初 `USE_STORE_IN_MANAGE` 被删的原因）。
 * 回退方式：`git revert` Ⅱ-3 那笔提交，不要指望改常量。
 * 下一个版本可直接删除本文件。
 */
export class GroupFlags {
  /** @deprecated 2026-11-03（Ⅱ-3）：读取点已删，保留仅为一个版本的留档 */
  static USE_STORE_IN_FOLDER: boolean = true

  /** @deprecated 2026-11-03（Ⅱ-3）：读取点已删 */
  static USE_MUTATION_IN_DIALOG: boolean = true

  /** @deprecated 2026-11-03（Ⅱ-3）：读取点已删 */
  static USE_UNIFIED_SCROLL: boolean = true
}