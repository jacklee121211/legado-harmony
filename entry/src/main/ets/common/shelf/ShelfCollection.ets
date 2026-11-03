import ShelfPrefs, { SortKey, SortDir } from '../utils/ShelfPrefs'

/**
 * 2026-11-03（阶段 Ⅲ-1）：**书架"集合语义"唯一实现**。
 *
 * ── 为什么要它 ───────────────────────────────────────────────────────────────
 * 「最近 / 全部 / 分组 / 未分组 / 本地 / 自定义分组」这几档，本质只有两类集合：
 *   · **单层书集合**：最近、全部、未分组、本地 —— 一次 `books` 查询就够，没有子树；
 *   · **分组集合**：分组页（`bookTypeNumber === 1`）与自定义分组内 —— 需要树与子树计数。
 *
 * 收敛前，同一条语义在**三处各写一遍**、数字还硬编码：
 *   · `BookContent.buildQueryParams()`：`bookGroup: 2` + `SortKey.RECENT_READ` / `SortDir.DESC`
 *   · `BookManagePage.getBookList()`：`onRecentChip ? 2 : ShelfPrefs.getSortKey()`、
 *     `onRecentChip ? 1 : ShelfPrefs.getSortDir()`
 *   · `BookManagePage.pageInit()`：`onRecentChip ⇒ bookTypeNumber = 2`
 * 任何一处改口径，其它两处就会分叉（本项目已有多次"同一动作两个结果"的教训）。
 *
 * ── 口径（与既有实现逐字等价，勿改）──────────────────────────────────────────
 * · **最近** = 全部书（`bookGroup = 2` 在 `BooksDao.buildWhereClause` 里表示"不加分组条件"）
 *   + 排序**锁死**为最近阅读降序；它**不是** `book_groups` 里的一行（见 IndexShelf 注释）。
 * · 其余档 = `bookGroup = 当前分组 id` + `ShelfPrefs` 里的排序档。
 */
export class ShelfCollection {
  /** true = 单层书集合（最近/全部/未分组/本地）；false = 分组集合（分组页 / 自定义分组内） */
  isBookSet: boolean = true
  /** 是否「最近」态（决定排序锁死） */
  isRecent: boolean = false
  /** 传给 `BooksDao` 的 `bookGroup`（=2 表示"全部书，不分组"） */
  bookGroup: number = 2
  sortKey: number = SortKey.RECENT_READ
  sortDir: number = SortDir.DESC

  /**
   * @param onRecentChip     当前是否停在「最近」虚拟 chip
   * @param bookTypeNumber   当前档位：1=分组 2=全部 3=未分组 4=本地 >=5 自定义分组
   */
  static resolve(onRecentChip: boolean, bookTypeNumber: number): ShelfCollection {
    const out: ShelfCollection = new ShelfCollection()
    out.isRecent = onRecentChip
    if (onRecentChip) {
      // 「最近」= 全部书 + 最近阅读降序（硬锁，不受 ShelfPrefs 影响）
      out.isBookSet = true
      out.bookGroup = 2
      out.sortKey = SortKey.RECENT_READ
      out.sortDir = SortDir.DESC
      return out
    }
    out.isBookSet = bookTypeNumber !== 1
    out.bookGroup = bookTypeNumber
    out.sortKey = ShelfPrefs.getSortKey()
    out.sortDir = ShelfPrefs.getSortDir()
    return out
  }

  /**
   * 批量管理的**进入档位**：从「最近」进来要归一成「全部」。
   *
   * 依据 `BookManagePage.pageInit()` 原实现（2026-11-01）：最近 = 全部书 + 最近排序，
   * 批量页只有"按书"与"按分组"两种形态 ⇒ 最近直接按全部书处理，**不新增第二套批量逻辑**。
   */
  static batchEntryGroup(onRecentChip: boolean, bookTypeNumber: number): number {
    return onRecentChip ? 2 : bookTypeNumber
  }
}

export default ShelfCollection
