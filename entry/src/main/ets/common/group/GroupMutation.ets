import { Books } from '../../database/entities/Books'
import BooksDao from '../../database/dao/BooksDao'
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
   */
  static async setVisible(groupId: number, show: boolean): Promise<void> {
    await bookGroupUtils.updateGroupShow(groupId, show)
    await GroupMutation.afterChange([groupId], [], true)
  }

  /**
   * 解散（书保留，按 mode 决定子树是否一并解散）。
   * @param mode 'keepChildren' | 'collapse'
   */
  static async dissolve(groupId: number, mode: string = 'keepChildren'): Promise<void> {
    await bookGroupUtils.dissolveGroup(groupId, mode)
    await GroupMutation.afterChange([], [], true)
  }

  /** 删除分组（书随删除，或保留子文件夹由上层已先行处理） */
  static async remove(groupId: number | number[]): Promise<void> {
    const ids: number[] = typeof groupId === 'number' ? [groupId] : groupId
    await bookGroupUtils.delGroupById(ids)
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
