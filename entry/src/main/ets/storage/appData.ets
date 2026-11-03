import CommonConstants from '../common/constants/CommonConstants'
import { initBookListData } from './bookListData'
import { initFindData } from './findData'
import programDataPreferences from '../preferences/programDataPreferences'


let APP_INDEX_SCROLLABLE = 'APP_INDEX_SCROLLABLE'

const APP_INDEX_SCROLLABLE_DATA = false

export const initAppData = ()=>{
  AppStorage.setOrCreate(APP_INDEX_SCROLLABLE,APP_INDEX_SCROLLABLE_DATA)
  // 2026-11-03（P8 / L2）：删掉启动时那段「订阅源（RSS）分组初始化」——
  //   它只为 Legado 的 RSS 域准备默认分组（小说/漫画/影视/资讯/收藏夹），而本工程
  //   既没有 RSS 表、也没有 RSS 页面，写进去的值**没有任何读取方**。
  let SystemUA = programDataPreferences.getWebUAData();
  if (SystemUA) {
    AppStorage.setOrCreate(CommonConstants.SYSTEM_UA,SystemUA)
  } else  {
    programDataPreferences.updateWebUAData(0)
    AppStorage.setOrCreate(CommonConstants.SYSTEM_UA,0)
  }
  initBookListData()
  initFindData()
}

export const updateAppData = (INDEX_SCROLLABLE:boolean)=>{
  AppStorage.set(APP_INDEX_SCROLLABLE,INDEX_SCROLLABLE)
}
