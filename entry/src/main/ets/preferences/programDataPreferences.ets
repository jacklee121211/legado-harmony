/**
 * @className: programDataPreferences
 * 程序基础数据定义
 *
 * ── 2026-11-03（P8 / L2）：删掉整段**订阅源（RSS）**残留 ────────────────────────
 * Legado 的 RSS 域在本工程从未落地（无 DAO / 无实体 / 无页面），这里却留着
 * 「订阅源分组默认值」的初始化与四个读写方法，外加 `RSS_SOURCES_GROUP_INIT` /
 * `RSS_SOURCES_GROUP_LIST_DATA_KEY` 两个常量，只被 `storage/appData.ets` 启动时写一次，
 * **没有任何读取方**（分组页读的是 `book_groups`）。一并删除。
 *
 * ── 2026-11-03（顺路发现收尾）：`SYSTEM_UA` 也删了 ──────────────────────────────
 * 「WebView UA」同样是书源时代的遗留，且是**纯死链**（实测）：
 *   · 写：本文件的 `initWebUADataPreferences` / `updateWebUAData`（Preferences 落盘）
 *         + `storage/appData.ets` 镜像进 AppStorage；
 *   · 读：`getWebUAData()` 只有 `appData` 一处调用，取到的值又只写进 AppStorage；
 *   · AppStorage 里 `SYSTEM_UA` 的消费方：`@StorageProp` / `@StorageLink` / `AppStorage.get`
 *     **全仓 0 处**（书源 WebView 早已移除，没有任何地方需要 UA）。
 * ⇒ 整链删除：常量 + 3 个方法 + appData 里的镜像与兜底分支。
 *
 * 本类现在是空壳（没有任何成员），保留文件与默认导出是为了不动既有 import 路径；
 * 将来若要再加「程序级 Preferences」，仍挂这里。
 */
export class programDataPreferences {
}

const programPreferences = new programDataPreferences()
export default programPreferences
