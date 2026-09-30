import { pasteboard } from '@kit.BasicServicesKit'
import { Haptics } from '../../common/utils/Haptics'
import { WifiBookServer } from '../../common/utils/WifiBookServer'
import UiMotion from '../../common/utils/UiMotion'

/**
 * wifi传书 / 电脑阅读 对话框（2026-09-30 回填）。
 * 开关 = WifiBookServer 启停（TCPSocketServer @ 1122）；运行中展示真实地址 +
 * 一键复制；电脑阅读 = 在电脑浏览器打开该地址后进入"书库列表"（.txt 在线阅读）。
 * 替代基座空壳 WebdavService（假开关+假地址），交互语言与基座一致但全部真实。
 */
@CustomDialog
export struct WifiTransferDialog {
  dark: boolean = false
  onClose: () => void = (): void => {}
  private controller?: CustomDialogController
  @State running: boolean = WifiBookServer.isRunning()
  @State address: string = WifiBookServer.address()

  build() {
    Column({ space: 14 }) {
      Row({ space: 10 }) {
        Text('Web服务 · WiFi传书')
          .fontSize(16).fontWeight(700)
          .fontColor(this.dark ? '#FFFFFF' : '#181818')
        Blank()
        Toggle({ type: ToggleType.Switch, isOn: this.running })
          .selectedColor('#0A84FF')
          .onChange((isOn: boolean) => {
            Haptics.tap()
            if (isOn) {
              WifiBookServer.start((ok: boolean, msg: string) => {
                this.running = ok
                this.address = WifiBookServer.address()
                if (!ok) {
                  this.getUIContext().getPromptAction().showToast({ message: msg })
                }
              })
            } else {
              WifiBookServer.stop((ok: boolean) => {
                this.running = false
                this.address = ''
              })
            }
          })
      }
      .width('100%')

      Text('手机与电脑连接同一 WiFi，电脑浏览器打开下方地址：上传书籍直接进入书架；打开"书库"可在电脑上阅读书架里的书。')
        .fontSize(13)
        .opacity(0.55)
        .width('100%')

      if (this.running && this.address !== '') {
        Row({ space: 12 }) {
          Text(this.address)
            .fontSize(14)
            .fontColor(this.dark ? '#FFFFFF' : '#181818')
            .layoutWeight(1)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text('复制')
            .fontSize(14).fontWeight(600)
            .fontColor('#0A84FF')
            .clickEffect(UiMotion.CLICK)
            .onClick(() => {
              Haptics.tap()
              const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, this.address)
              pasteboard.getSystemPasteboard().setData(data)
              this.getUIContext().getPromptAction().showToast({ message: '复制成功' })
            })
        }
        .width('100%')
        .height(44)
        .padding({ left: 16, right: 16 })
        .borderRadius(10)
        .backgroundColor(this.dark ? '#2A2A2C' : 'rgba(0, 0, 0, 0.04)')
      }

      Text('完成传书后可直接关闭本页，服务会保持运行。')
        .fontSize(12)
        .opacity(0.4)
        .width('100%')

      Text('完成')
        .fontSize(15).fontWeight(600)
        .fontColor('#0A84FF')
        .width('100%')
        .height(44)
        .textAlign(TextAlign.Center)
        .clickEffect(UiMotion.CLICK)
        .onClick(() => {
          Haptics.tap()
          this.controller?.close()
          this.onClose()
        })
    }
    .padding(20)
    .width('100%')
  }
}
