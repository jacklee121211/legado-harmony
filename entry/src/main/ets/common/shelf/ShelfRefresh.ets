/**
 * 书架刷新门面（2026-11-03 B1）—— **唯一允许 bump 全局刷新键的地方**。
 *
 * ── 改造前是什么样 ──────────────────────────────────────────────────────────
 * 书架域靠几个全局 AppStorage 计数器"喊刷新"，实测 **56 处写点**散落在 12 个文件：
 *   · `BOOK_IS_BOOK_GROUPS_REFRESHING`  23 处（FolderInfoDialog 10 / BookManagePage 4 / …）
 *   · `isBookRefreshing`                29 处（FolderInfoDialog 8 / BookManagePage 4 / IndexShelf 4 / …）
 *   · `AppStorage.setOrCreate(...)`      4 处
 * 后果就是本工程反复出现的那个 bug 类型：**改了 A 忘了 B** —— 结构变了只 bump 分组键，
 * 「全部/最近」还留着旧数据（真机：隐藏分组后书仍在列表第一位）；或者只 bump 书键，
 * 分组卡片计数不刷新（U2b / B⑥ 的土壤）。
 *
 * ── 本门面的原则：**行为等价** ───────────────────────────────────────────────
 * 它**不改变**任何现有语义：仍然 bump 同一批键、仍然是"加一"的计数器、订阅方
 * （`@StorageLink(...) @Watch(...)`）照旧被唤醒。唯一变化是**写点从 56 处收敛到 3 处**（本文件内）
 * ⇒ 以后想改"谁该刷新"只需改这里，而不是满仓库找自增。
 *
 * ── 三类入口（与现有调用点一一对应，不要混用）────────────────────────────────
 *   · `groups()`    —— 只让"分组列表/树"刷新（原来 `this.BOOK_IS_BOOK_GROUPS_REFRESHING++`）；
 *   · `books()`     —— 只让"书籍列表/计数"刷新（原来 `this.isBookRefreshing++` 等）；
 *   · `structure()` —— 结构变更（增删分组/移动子树/可见性变化）⇒ 两组都刷
 *                      （原来多数调用点是连着做两行自增）。
 *
 * ⚠️ 为什么用 `AppStorage.setOrCreate` 而不是让调用方自增：
 *    `@StorageLink` 是双向绑定，组件里 `this.x++` 与这里写 AppStorage 对**所有订阅方**等价；
 *    但只有集中写才能被闸门（`scripts/check-single-path.mjs`）机械地守住"不许再有第 57 处"。
 */
import { GroupEvents } from '../group/GroupEvents'

export class ShelfRefresh {
  /** 分组结构 / 树（`BOOK_IS_BOOK_GROUPS_REFRESHING`）；返回自增后的值，便于调用方保留原有日志 */
  // 2026-11-03（双轨收口·三）：AppStorage 计数器已无任何订阅方 ⇒ 不再写全局键，只发事件。
  //   返回 GroupEvents 的全局版本号（调用方只用它打日志，例如 `groupsRefresh=${groupsTick}`）。
  static groups(): number {
    GroupEvents.emitFromBump('groups')
    return GroupEvents.version
  }

  /** 书籍数据 / 计数（`BOOK_IS_BOOK_REFRESHING`；`isBookRefreshing` 是它的本地别名）；返回自增后的值 */
  static books(): number {
    GroupEvents.emitFromBump('books')
    return GroupEvents.version
  }

  /** 结构变更：分组树 + 书籍可见性都要刷（等价于原来连着两行自增） */
  static structure(): void {
    GroupEvents.emitFromBump('both')
  }

  /** 书架排序 / 宫格列表切换（`SHELF_SORT_TICK`） */
  static sort(): void {
    ShelfRefresh.bump('SHELF_SORT_TICK')
  }

  /**
   * 2026-11-03（双轨收口）：**把"只 bump 计数器"的写路径也接上领域事件**。
   *
   * 为什么必须补这一步：`GroupEvents` 的唯一写入方原本只有 `GroupMutation`，而 UI 里存在大量
   * 「删/改完直接 `ShelfRefresh.groups()`」的路径（不进 GroupMutation）⇒ 事件订阅方收不到通知。
   * 补发后：**计数器（渲染广播）与事件（领域广播）由同一个出口同时发出**，
   * 新增的订阅者不会再"静默漏刷新"；同一次操作重复触发由 `GroupEvents.emitFromBump()` 的
   * "同一微任务只补一次 + 已有精确事件就不补发"两重规则压掉。
   *
   * 唯一性由闸门保证：`group-event-exit`（禁止在 ShelfRefresh 之外调 `GroupEvents.emitFromBump`）。
   */
  // 2026-11-04（P2 收尾）：原 `private static notifyGroupEvent(kind: string)` 已删 ——
  //   它只是 `GroupEvents.emitFromBump(kind)` 的一行包装，且**零调用**
  //   （双轨收口后 groups()/books() 直接调 `GroupEvents.emitFromBump`）。

  /** 加一（计数器语义，与原来的 `this.xxx++` 完全一致）；返回新值 */
  private static bump(key: string): number {
    const cur: number = AppStorage.get<number>(key) ?? 0
    const next: number = cur + 1
    AppStorage.setOrCreate<number>(key, next)
    return next
  }
}
// 2026-11-04（P2 批次 2）：文件末尾原有两个「与 CommonConstants 同值」的字面量
//   `KEY_GROUPS = 'BOOK_IS_BOOK_GROUPS_REFRESHING'` / `KEY_BOOKS = 'BOOK_IS_BOOK_REFRESHING'`。
//   两个都**从未被引用**（2026-11-03 双轨收口后 groups()/books() 只发事件、不再写计数器），
//   且 `BOOK_IS_BOOK_GROUPS_REFRESHING` 键本身已按"只写不读"删除 ⇒ 两行一并删除。

