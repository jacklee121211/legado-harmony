// 「发现」域初始化（2026-11-03 P2 收敛后只剩空壳）。
//
// 历史：这里原来把 `CommonConstants.HAS_EXPLORE_URL` 写进 AppStorage，
//   但全仓**零读取方**（P2 键审计），连带 `initSourceList` / `initSourcePartList`
//   两个空函数一起清掉，只保留 `initFindData` 作为调用点（`appData` 里调它，
//   删除会牵动启动流程；当前是 no-op，注释说明原因）。
//
// 将来"发现"功能真要做：新增能力请走**事件**（参考 `ShelfRefresh` → `GroupEvents`）
//   或页面局部状态，不要再往 AppStorage 里加全局键（`check-all` 有键预算闸门）。
export const initFindData = (): void => {
}
