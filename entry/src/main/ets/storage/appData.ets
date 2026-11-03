import { initBookListData } from './bookListData'
import { initFindData } from './findData'


let APP_INDEX_SCROLLABLE = 'APP_INDEX_SCROLLABLE'

const APP_INDEX_SCROLLABLE_DATA = false

export const initAppData = ()=>{
  AppStorage.setOrCreate(APP_INDEX_SCROLLABLE,APP_INDEX_SCROLLABLE_DATA)
  // 2026-11-03（P8 / L2）：删掉启动时那段「订阅源（RSS）分组初始化」——
  //   它只为 Legado 的 RSS 域准备默认分组（小说/漫画/影视/资讯/收藏夹），而本工程
  //   既没有 RSS 表、也没有 RSS 页面，写进去的值**没有任何读取方**。
  // 2026-11-03（顺路发现收尾）：SYSTEM_UA 整链删除 —— 它是书源 WebView 时代的遗留，
  //   Preferences 只写不读、AppStorage 里的键全仓 0 个消费方（证据见 programDataPreferences 头注释）。
  initBookListData()
  initFindData()
}

export const updateAppData = (INDEX_SCROLLABLE:boolean)=>{
  AppStorage.set(APP_INDEX_SCROLLABLE,INDEX_SCROLLABLE)
}
