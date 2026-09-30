import { common } from '@kit.AbilityKit'
import { ShareReceiveItem } from '../entryability/BookShareExtensionAbility'
import { Haptics } from '../common/utils/Haptics'
import UiMotion from '../common/utils/UiMotion'
import { FileHandler } from '../common/utils/FileHandler'
import { NightMode, ShelfColors } from '../common/utils/NightMode'

/**
 * 分享接收页（2026-09-30 回填）：ShareExtensionAbility 的分享详情页 UI。
 *
 * 数据流：BookShareExtensionAbility.onSessionCreate 把 SharedRecord[]（uri/utd/title）
 * 放进 AppStorage('shareReceiveFiles') → 本页读取展示 → 用户点"导入书架" →
 * FileHandler.CopyFile（现有导入管线：拷贝进沙箱 + booksUtil.addBooks 写库）。
 *
 * 关闭：UIExtensionContext.terminateSelf()（@Entry 页 getContext 即扩展上下文）。
 * 自动导入说明：官方范式是详情页自行处理内容（share-sec-panel），本页默认
 * 进入即自动导入（用户零操作），失败项可手动重试。
 */
@Entry
@Component
struct ShareReceivePage {
  @State files: ShareReceiveItem[] = []
  @State results: Map<number, string> = new Map()
  @State importing: boolean = false

  aboutToAppear(): void {
    const stored = AppStorage.get<ShareReceiveItem[]>('shareReceiveFiles') ?? []
    this.files = stored
    // 官方 share-sec-panel 范式：详情页自行处理分享内容 ⇒ 进入即导入（零操作）
    this.doImport()
  }

  private async doImport(): Promise<void> {
    if (this.importing || this.files.length <= 0) {
      return
    }
    this.importing = true
    for (let i = 0; i < this.files.length; i++) {
      const ok: boolean = await FileHandler.CopyFile(this.files[i].uri, 0)
      this.results.set(i, ok ? '已导入' : '导入失败')
      // Map 元素更新需整体替换才能驱动 UI（V1 状态管理）
      this.results = new Map(this.results)
    }
    this.importing = false
  }

  private close(): void {
    const ctx = getContext(this) as common.UIExtensionContext
    ctx.terminateSelf()
  }

  build() {
    Column({ space: 16 }) {
      Text('喵阅 · 接收书籍')
        .fontSize(18).fontWeight(700)
        .fontColor($r('app.color.text_primary'))
        .margin({ top: 24 })

      Text(this.importing ? '正在导入…' : (this.results.size > 0 ? '导入完成' : '准备导入'))
        .fontSize(13)
        .opacity(0.55)

      List({ space: 8 }) {
        ForEach(this.files, (item: ShareReceiveItem, idx: number) => {
          ListItem() {
            Row({ space: 10 }) {
              Text(item.title !== '' ? item.title : `书籍文件 ${idx + 1}`)
                .fontSize(14)
                .fontColor($r('app.color.text_primary'))
                .layoutWeight(1)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
              Text(this.results.get(idx) ?? '等待')
                .fontSize(12)
                .fontColor(this.results.get(idx) === '已导入' ? '#24B277' : (this.results.get(idx) === '导入失败' ? '#EF4444' : '#999'))
            }
            .width('100%')
            .padding(12)
            .backgroundColor($r('app.color.card_bg'))
            .borderRadius(10)
          }
        }, (item: ShareReceiveItem) => item.uri)
      }
      .layoutWeight(1)
      .width('100%')
      .scrollBar(BarState.Off)

      Button(this.importing ? '导入中…' : '完成')
        .width('60%')
        .height(44)
        .backgroundColor(this.importing ? '#9CA3AF' : '#0A84FF')
        .fontColor(Color.White)
        .onClick(() => {
          Haptics.tap()
          if (this.results.size < this.files.length) {
            this.doImport()
            return
          }
          this.close()
        })
        .margin({ bottom: 20 })
    }
    .width('100%')
    .height('100%')
    .padding({ left: 20, right: 20 })
    .backgroundColor(ShelfColors.pageBg())
  }
}
