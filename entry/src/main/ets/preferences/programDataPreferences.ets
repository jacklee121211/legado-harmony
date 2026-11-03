/**
 * @author 2008
 * @datetime 2024/7/17 19:30
 * @className: programDataPreferences
 * 程序基础数据定义
 *
 * ── 2026-11-03（P8 / L2）：删掉整段**订阅源（RSS）**残留 ────────────────────────
 * Legado 的 RSS 域在本工程从未落地（无 DAO / 无实体 / 无页面），这里却留着
 * 「订阅源分组默认值」的初始化与四个读写方法，外加 `RSS_SOURCES_GROUP_INIT` /
 * `RSS_SOURCES_GROUP_LIST_DATA_KEY` 两个常量，只被 `storage/appData.ets` 启动时写一次，
 * **没有任何读取方**（分组页读的是 `book_groups`）。一并删除。
 *
 * ── 2026-11-03（P8）：`SYSTEM_UA` 部分**暂留** ──────────────────────────────────
 * 「WebView UA」同样是书源时代的遗留：全仓只有写（这里 + `appData` 镜像进 AppStorage），
 * **零读取方**。但删除它不属于 L2（RSS）范围，已记录在
 * `docs/待办-统一清单-2026-11-03.md` 的「顺路发现」里，等确认后再动 —— 本轮不顺手改。
 */
import CommonConstants from '../common/constants/CommonConstants'
import bookDataPreferences from '../common/utils/DataPreferencesUtils'

export class programDataPreferences {
  //WEB UA设置
  initWebUADataPreferences = () => {
    bookDataPreferences.shared.set(CommonConstants.SYSTEM_UA, 0)
  }
  //更新WEB UA
  updateWebUAData = (UAIndex:number ) =>{
    bookDataPreferences.shared.set(CommonConstants.SYSTEM_UA,UAIndex)
  }
  //获取WEB UA
  getWebUAData = () => {
    return bookDataPreferences.shared.get(CommonConstants.SYSTEM_UA) as number
  }
}

const programPreferences = new programDataPreferences()
export default programPreferences
