import CommonConstants from '../common/constants/CommonConstants'

/**
 * 初始化页面公用变量
 */

export const initBookListData = ()=>{
  AppStorage.setOrCreate(CommonConstants.BOOK_IS_BOOK_REFRESHING, 0)
  // 2026-11-04（P2 批次 2）：`BOOK_IS_BOOK_GROUPS_REFRESHING` 的初始化写入已删 ——
  //   分组刷新通道 2026-11-03 已整体切到 `GroupEvents` / `ShelfRefresh.groups()`，
  //   这个计数器在 `ShelfRefresh` 里只留了字面量常量、**写入点已归零、读取点全仓为 0**
  //   （`scripts/audit-appstorage.mjs` 判为「只写不读」）⇒ 键与常量一并删除。
}
