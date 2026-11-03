import booksDao from '../../database/dao/BooksDao'
import booksUtil from '../utils/booksUtils'
import { Books } from '../../database/entities/Books'

/**
 * 2026-11-03（P3 / A1）：**书籍域的唯一写入口**。
 *
 * ── 为什么需要它 ───────────────────────────────────────────────────────────
 * 分组域早在 Ⅱ-1 就有 `GroupMutation`（唯一写入口）；但**书籍域的 `bookGroup` 列**一直没有入口，
 * 于是 `FolderInfoDialog` 的「合并 / 解散」里出现了 5 处 `booksDao.updateBookGroup(...)` +
 * 2 处整行 `booksDao.update(...)`，全部直连 DAO。后果：
 *   · 换表/加字段时要改 UI 层；
 *   · 移书没有统一的地方加"刷新信号 / 事件"（现在靠调用方各自记得）；
 *   · 回滚逻辑（失败把书挪回原分组）也是 UI 里手写的循环。
 *
 * ── 边界（与 GroupMutation 的分工）──────────────────────────────────────────
 *   · **分组行**（`book_groups`）：`GroupMutation`；
 *   · **书籍行的 `bookGroup` / 整行改名等**：**本类**；
 *   · 目录里的批量移动（`bookGroupUtils.moveGroupTo`）与导入入库仍走 `booksUtils`/`bookGroupUtils`
 *     —— 它们属于"适配器/导入边界"，见 B4 的定性（`docs/待办-统一清单-2026-11-03.md`）。
 *
 * ── 刷新语义 ────────────────────────────────────────────────────────────────
 * 本类**不发**任何事件/刷新信号：移书属于"书籍域事实"，由调用方在业务事务结束后统一
 * `ShelfRefresh.books()`（与 `GroupMutation.afterChange` 只发分组事件的口径一致，避免重复刷新）。
 */
export class BooksMutation {
  /** 单本移到某分组（`bookGroup` 列；`groupId=3` 即"未分组"） */
  static async moveOne(bookId: number, groupId: number): Promise<void> {
    if (bookId === undefined || bookId === null || bookId <= 0) {
      return
    }
    await booksDao.updateBookGroup(bookId, groupId)
  }

  /** 批量移到同一分组（DAO 侧本身就是批量 SQL） */
  static async moveMany(bookIds: number[], groupId: number): Promise<void> {
    const ids: number[] = (bookIds ?? []).filter((id: number): boolean => id > 0)
    if (ids.length === 0) {
      return
    }
    await booksDao.updateBookGroup(ids, groupId)
  }

  /** 整行更新（改名/加"(2)"后缀等场景；与 `booksUtils.partialUpdate` 的区别：这里写全列） */
  static async update(book: Books): Promise<void> {
    await booksDao.update(book)
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // 2026-11-03（B4 收尾）：把原先散在 UI 里的三类 `booksUtil.*` 写调用也收进来。
  //   这三类的**重活**仍在适配器 `booksUtils` 里（删书要清封面文件 + 以书名为键的进度/设置/
  //   书签、移书要维护 `book_groups.bookIds` 映射），本类只做"唯一出口"，不再重复实现细节。
  //   这样 UI 层只认 `BooksMutation`，闸门 `legacy-book-write` 才能从 13 降到 0。
  // ═══════════════════════════════════════════════════════════════════════════

  /** 加入书架（`isJoin=true`、`bookGroup` 缺省 3 未分组；重活见 `booksUtils.addBooks`） */
  static async add(book: Books): Promise<void> {
    await booksUtil.addBooks(book)
  }

  /**
   * 删除书籍（连带清封面文件 + 以书名为键的阅读进度/设置/书签）。
   * @param id 单本 id 或 id 数组
   */
  static async remove(id: number | number[]): Promise<void> {
    await booksUtil.delBooksById(id)
  }

  /**
   * 批量移动（维护 `book_groups.bookIds` 映射的那条路径）。
   *
   * ⚠️ 与 `moveMany` 的区别：`moveMany` 只改 `books.bookGroup` 一列；
   *    本方法走 `booksUtils.updateBooks`，会同时维护分组行里的 `bookIds` 映射
   *    ——「移动至」弹窗用的是这条（原 `BookSelectGroupDialog:983`）。
   */
  static async moveTo(id: number | number[], groupId: number): Promise<void> {
    await booksUtil.updateBooks(id, groupId)
  }

  /**
   * **回滚**：按快照把书恢复到原分组。
   *
   * ⚠️ 与 `moveMany` 不同，这里**逐条**执行且**逐条吞异常**：回滚是"尽力而为"，
   *    一条失败不能让其余书停在错误分组（原实现就是 UI 里的 `for + try/catch`）。
   * @returns 成功恢复的条数（供日志/提示用）
   */
  static async restoreGroups(bookIds: number[], groups: number[]): Promise<number> {
    let ok: number = 0
    const n: number = Math.min(bookIds.length, groups.length)
    for (let i = 0; i < n; i++) {
      try {
        await booksDao.updateBookGroup(bookIds[i], groups[i])
        ok++
      } catch (e) {
        console.error(`[BOOKS-ROLLBACK] 书回滚失败 bookId=${bookIds[i]}: ${JSON.stringify(e)}`)
      }
    }
    return ok
  }
}

export default BooksMutation
