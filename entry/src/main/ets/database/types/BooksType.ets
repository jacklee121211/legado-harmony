/**
 * @author 2008
 * @datetime 2024/7/23 11:02
 * @className: BooksType
 */
export interface BooksTypeSearchParams {
  // 搜索关键词书源名称/书籍名称/author
  searchKey?: string,
  // 源类型 0 小说；1 漫画；2 有声书；
  type?: number,
  //分组
  bookGroup?: number,
  /**
   * 旧排序参数（2026-10-19 起为**兼容保留**）。
   *
   * 语义仍是"是否指定了排序"：传了 = 最近阅读；不传 = 导入时间。
   * 新增的 `sortKey` / `sortDir` 优先于它（见 `BooksDao.buildOrderByClause` 调用处），
   * 保留它是为了让既有调用点（搜索、新书入架等只传部分字段的地方）不必全改。
   */
  order?: string,
  /**
   * 排序档位（2026-10-19 新增，需求第 6 条）。
   *
   * 取值与 `common/utils/ShelfPrefs.ets` 的 `SortKey` 枚举一致：
   *   0 = 首字母 / 1 = 导入时间 / 2 = 最近阅读 / 3 = 格式 / 4 = 文件大小。
   * ⚠️ 这里用 `number` 而不是 import 那个枚举：DAO 层不应反向依赖 UI 偏好层
   *    （避免 database → common/utils/ShelfPrefs 的循环依赖）。
   */
  sortKey?: number,
  /** 排序方向：0 = 升序（↑），1 = 降序（↓）。与 `SortDir` 枚举一致 */
  sortDir?: number
}