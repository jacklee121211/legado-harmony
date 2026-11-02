import { Books } from '../../database/entities/Books'
import { BookGroups } from '../../database/entities/BookGroups'
import BooksDao from '../../database/dao/BooksDao'
import BookGroupsDao from '../../database/dao/BookGroupsDao'
import bookGroupUtils from '../utils/bookGroupUtils'
import { GroupStore } from './GroupStore'
import { GroupEvents } from './GroupEvents'
import { HiddenGroups } from './HiddenGroups'

/**
 * 2026-11-02 新增（架构收敛 P2 骨架）：**唯一写入口**。
 *
 * ── 契约（真源文档 S6/S8）───────────────────────────────────────────────
 * · 预检 → 快照 → 执行 → 失败回滚 → **只发一次** `GroupEvents.emit(...)`；
 * · 结构变更（解散/删除/移动子树）后：`GroupStore.refresh()` + 隐藏集合刷新 + 选中集失效；
 * · 页面**禁止**再直接调 `BookGroupsDao` / `BooksDao.updateBookGroup`。
 *
 * ⚠️ 本轮只做骨架 + 委托现有实现（不改变任何现有调用点），
 *    接线在 P2 逐页面进行（真实动作逻辑仍由 bookGroupUtils 承担，保证行为不变）。
 */
export class GroupMutation {
  /**
   * 隐藏 / 恢复显示。
   * @param show 目标可见性（true=显示，false=隐藏）
   *
   * ⚠️ 2026-11-02 第 24 轮（D5）修正：`structural` 原来是 **true** ⇒ 事件里发空数组
   *   对外宣称"结构变更"。但隐藏**不改变任何 id**（只改 `book_groups.show`），按 S6
   *   「结构变更 ⇒ 选中集失效」的语义它是**不该清空选中集**的。
   *   ⇒ 改为 false，发 `changedGroupIds=[groupId]`（订阅方用 `touchesGroup` 精准命中）。
   */
  static async setVisible(groupId: number, show: boolean): Promise<void> {
    await bookGroupUtils.updateGroupShow(groupId, show)
    await GroupMutation.afterChange([groupId], [], false)
  }

  /**
   * 2026-11-02 第 24 轮（D2 同类补漏）：**批量**隐藏/恢复，只发一次事件。
   *
   * 为什么需要它：批量页的「隐藏分组」和「分组管理」里的「恢复显示」原来都是
   *   **直接调 `bookGroupUtils.updateGroupShow()`** —— 那条路**完全不发 `GroupEvents`**
   *   （真机实证：隐藏走 GroupMutation 有 `[GRP-EMIT] v=5 groups=[31]`，而"恢复显示"0 条）。
   *   后果：别的页面（书架 / 全部 / 最近）收不到通知，要等下一次手动刷新才看到状态变化。
   * 批量时若逐个调 `setVisible` 又会变成 N 次事件（违反 S8）⇒ 这里循环写库、**只 emit 一次**。
   */
  static async setVisibleMany(groupIds: number[], show: boolean): Promise<void> {
    if (groupIds.length === 0) {
      return
    }
    for (const gid of groupIds) {
      await bookGroupUtils.updateGroupShow(gid, show)
    }
    await GroupMutation.afterChange(groupIds, [], false)
  }

  /**
   * 解散（书保留，按 mode 决定子树是否一并解散）。
   * @param mode 'keepChildren' | 'collapse'
   *
   * ⚠️ `dissolveGroup(..., false)`：让底层的 emit 关掉，由 `afterChange` 发**唯一一次**，
   *   否则会"底层发一次 + 收尾再发一次"= 双发（违反 S8）。
   */
  static async dissolve(groupId: number, mode: string = 'keepChildren'): Promise<void> {
    await bookGroupUtils.dissolveGroup(groupId, mode, false)
    await GroupMutation.afterChange([], [], true)
  }

  /**
   * 删除分组（书随删除，或保留子文件夹由上层已先行处理）
   *
   * ⚠️ 同上：`delGroupById(ids, false)` 关掉底层 emit，避免与 `afterChange` 双发（S8）。
   */
  static async remove(groupId: number | number[]): Promise<void> {
    const ids: number[] = typeof groupId === 'number' ? [groupId] : groupId
    await bookGroupUtils.delGroupById(ids, false)
    await GroupMutation.afterChange([], [], true)
  }

  /**
   * 把一批书移动到目标分组（书级移动，不动结构）。
   * 快照用于失败回滚（真源 S8 / 用户 U4 的"陌生书"防护）。
   */
  static async moveBooks(bookIds: number[], targetGroupId: number): Promise<void> {
    if (bookIds.length === 0) {
      return
    }
    const snapId: number[] = []
    const snapGroup: number[] = []
    const all: Books[] = await BooksDao.search()
    for (const b of all) {
      if (b.id !== undefined && bookIds.indexOf(b.id) >= 0) {
        snapId.push(b.id)
        snapGroup.push(b.bookGroup ?? 3)
      }
    }
    try {
      for (const id of bookIds) {
        await BooksDao.updateBookGroup(id, targetGroupId)
      }
    } catch (e) {
      console.error(`[GRP-MUTATION] moveBooks 失败，开始回滚：${JSON.stringify(e)}`)
      for (let i = 0; i < snapId.length; i++) {
        try {
          await BooksDao.updateBookGroup(snapId[i], snapGroup[i])
        } catch (e2) {
          console.error(`[GRP-MUTATION] 书回滚失败 id=${snapId[i]}: ${JSON.stringify(e2)}`)
        }
      }
      throw e as Error
    }
    await GroupMutation.afterChange([targetGroupId], bookIds, false)
  }

  /**
   * 把若干个分组下的**全部书籍**并入目标分组（= 界面上「移动至 → 选分组」在
   * 「分组」节点上的那一步；底层 `bookGroupUtils.moveBookByGroupId` 做的是
   * "把这些分组里的书 bookGroup 改成目标值"，**不改树的 parentId**）。
   *
   * ⚠️ 2026-11-02 第 26 轮（B③）新增，修掉两个真实缺陷（原来调用点直接裸调底层）：
   *   1. **没有 await**（`BookSelectGroupDialog.ets` 原 `bookGroupUtils.moveBookByGroupId(...)` 一行）
   *      ⇒ `showMessage('已移动到…')` 会在写库完成**之前**弹出，失败也照样提示成功；
   *   2. **完全不发 `GroupEvents`** ⇒ 书架/管理页收不到通知，要等下次手动刷新才看到书换了组
   *      （与 D2「恢复显示不发事件」是同一类坑，见 `setVisibleMany` 注释）。
   * 这里补齐：await 到底 → 刷真源/隐藏集合 → 发**一次**非结构事件（书变了、树没变）。
   */
  static async moveBooksOfGroups(groupIds: number | number[], targetGroupId: number): Promise<void> {
    // 入参与底层一致（`moveBookByGroupId(oldGroup: number | number[], newGroup: number)`）：
    // 调用点 `this.Ids` 就是 `number | number[]`，这里统一成数组再过滤掉目标自身。
    const raw: number[] = typeof groupIds === 'number' ? [groupIds] : groupIds
    const ids: number[] = raw.filter((g: number): boolean => g !== targetGroupId && g > 0)
    if (ids.length === 0) {
      return
    }
    // 受影响书籍：与底层查询同源（`moveBookByGroupId` 内部就是 queryBooksByGroupId(ids)）
    const bookIds: number[] = await BooksDao.queryBooksByGroupId(ids)
    await bookGroupUtils.moveBookByGroupId(ids, targetGroupId)
    await GroupMutation.afterChange([targetGroupId], bookIds, false)
  }

  /**
   * 把某个**分组节点**挂到目标父分组下（`targetParentId === 0` = 挂回根级）。
   *
   * ⚠️ 2026-11-02 第 26 轮（B⑥）新增 —— 补上 P2 的最后一个漏网写入口。
   * 原 `FolderInfoDialog.doMoveGroupNode()` 自己写 `parentId` + `updatePartialGroup`，
   * 只 bump 旧的 AppStorage 信号，**不刷 GroupStore、不发 GroupEvents**。
   * 真机后果（`2026-11-09-U3/50-restored-root.json`）：把「12」移回「1」之后，
   * **根页仍残留一张根级的「12」卡片**，要重新进入一次才消失
   * （因为根页按 `USE_STORE_IN_FOLDER=true` 读 `GroupStore`，而它没被刷新）。
   *
   * 语义按「结构变更」处理：写库 → 刷真源 → 刷隐藏集合 → **发一次**事件。
   * 防环/同名/合并等**业务校验仍留在调用方**（`FolderInfoDialog.doMoveGroupNode`），
   * 本方法只负责"写 + 收尾一致性"。
   */
  static async moveGroupNode(groupId: number, targetParentId: number): Promise<void> {
    if (groupId <= 0 || groupId === targetParentId) {
      return
    }
    await GroupStore.ensure()
    const me: BookGroups | undefined = GroupStore.find(groupId)
    if (me === undefined) {
      // 真源可能是旧的 ⇒ 重查一次再试；仍找不到就放弃（不瞎写）
      await GroupStore.refresh()
      const again: BookGroups | undefined = GroupStore.find(groupId)
      if (again === undefined) {
        console.error(`[GRP-MUTATION] moveGroupNode: 分组不存在 id=${groupId}`)
        return
      }
      again.parentId = targetParentId
      again.updateTime = Date.now()
      await BookGroupsDao.updatePartialGroup(again)
    } else {
      me.parentId = targetParentId
      me.updateTime = Date.now()
      await BookGroupsDao.updatePartialGroup(me)
    }
    await GroupMutation.afterChange([], [], true)
  }

  /**
   * **批量**解散，只发一次事件（2026-11-03 A2 新增）。
   *
   * 为什么需要它：`BookManagePage` 的批量「解散」原来直接调
   * `bookGroupUtils.dissolveGroups(gids, mode)` —— 那条路**底层自己 emit**，
   * 但**不刷 `GroupStore`**（与 `delGroupById` 同类）。批量页随后靠旧信号
   * `pageInit()` 兜底，而按 `USE_STORE_IN_FOLDER=true` 读真源的页面会看到旧树。
   * 这里关掉底层 emit，由 `afterChange` 统一"刷真源 + 刷隐藏集合 + 发一次事件"。
   */
  static async dissolveMany(groupIds: number[], mode: string = 'keepChildren'): Promise<void> {
    if (groupIds.length === 0) {
      return
    }
    await bookGroupUtils.dissolveGroups(groupIds, mode, false)
    await GroupMutation.afterChange([], [], true)
  }

  /**
   * 写分组自身的非结构性字段（封面等），2026-11-03 A2 新增。
   *
   * 原调用点：`coverInfoDialog.applyGroupCover / resetGroupCover` 直接调
   * `bookGroupUtil.updatePartialGroup(itemData)` —— 写库成功但**不刷真源、不发事件**，
   * 别的页面（分组管理 / 书架根页）要等下一次手动刷新才看到新封面。
   * 语义按「非结构变更」处理：发 `changedGroupIds=[groupId]`，不清选中集（S6 只针对结构变更）。
   */
  static async setGroupCover(group: BookGroups): Promise<void> {
    await bookGroupUtils.updatePartialGroup(group)
    const gid: number = group.groupId ?? -1
    await GroupMutation.afterChange(gid > 0 ? [gid] : [], [], false)
  }

  /**
   * 变更收尾：刷新真源、刷新隐藏集合、发**唯一一次**事件。
   * @param changedGroupIds 受影响分组（空数组 = 结构变更，订阅方按"全量"处理）
   * @param changedBookIds  受影响书籍
   * @param structural      是否结构变更（增删/移动整棵子树）
   */
  private static async afterChange(changedGroupIds: number[], changedBookIds: number[],
    structural: boolean): Promise<void> {
    await GroupStore.refresh()
    HiddenGroups.set(GroupStore.hiddenIds())
    GroupEvents.emit(structural ? [] : changedGroupIds, changedBookIds)
    // S6：结构变更后选中集立即失效（由订阅方清空；这里只保证事件里标记为"全量"）
  }
}
