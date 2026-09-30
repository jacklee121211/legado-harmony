import { ShareExtensionAbility, UIExtensionContentSession, Want } from '@kit.AbilityKit'
import { systemShare } from '@kit.ShareKit'
import { BusinessError } from '@kit.BasicServicesKit'

/** 分享接收条目（Ability → 接收页 经 AppStorage 传递的结构化记录） */
export interface ShareReceiveItem {
  uri: string
  utd: string
  title: string
}

/**
 * 分享接收端（2026-09-30 回填，官方文档：
 * 开发指南/Share_Kit_分享服务/系统分享/目标应用处理分享内容/分享详情页处理分享内容/share-sec-panel）。
 *
 * 官方实现范式（原文照抄结构）：
 *   export default class TestShareAbility extends ShareExtensionAbility {
 *     onSessionCreate(want: Want, session: UIExtensionContentSession) {
 *       systemShare.getSharedData(want).then((data) => {
 *         data.getRecords().forEach(...)
 *         session.loadContent('pages/...')
 *       })
 *     }
 *   }
 *
 * 数据流：华为分享面板/碰一碰（应用路由）选中喵阅 → 系统拉起本 Ability
 * → getSharedData 解析出 SharedRecord[]（uri/utd/title）→ 经 AppStorage 交给
 * ShareReceivePage → 用户点导入 → FileHandler.CopyFile（现有导入管线）。
 * module.json5 声明（type:"share" + ohos.want.action.sendData + utd 穷举）见同文件配置。
 */
export default class BookShareExtensionAbility extends ShareExtensionAbility {
  onSessionCreate(want: Want, session: UIExtensionContentSession): void {
    systemShare.getSharedData(want)
      .then((data: systemShare.SharedData) => {
        const records: systemShare.SharedRecord[] = data.getRecords()
        // 只挑带 uri 的文件记录（书籍文件），交给接收页展示与导入
        const files: ShareReceiveItem[] = []
        records.forEach((record: systemShare.SharedRecord) => {
          if (record.uri && record.uri.length > 0) {
            const item: ShareReceiveItem = {
              uri: record.uri,
              utd: record.utd ?? '',
              title: record.title ?? ''
            }
            files.push(item)
          }
        })
        AppStorage.setOrCreate('shareReceiveFiles', files)
        session.loadContent('pages/ShareReceivePage')
      })
      .catch((error: BusinessError) => {
        console.error(`LTBOOK receive getSharedData failed. code: ${error.code}, message: ${error.message}`)
        session.terminateSelf()
      })
  }

  onSessionDestroy(): void {
    // 扩展页随收随走，无常驻资源
  }
}
