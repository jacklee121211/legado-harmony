import { pasteboard } from '@kit.BasicServicesKit'
import { Haptics } from '../../common/utils/Haptics'
import { common } from '@kit.AbilityKit'
import { WifiBookServer } from '../../common/utils/WifiBookServer'
import { DevToken } from '../../common/utils/WebCredential'
import UiMotion from '../../common/utils/UiMotion'
import { WindowUtils } from '../../common/ezlt/utils/WindowUtils'

/**
 * wifi传书 / 电脑阅读 对话框。
 *
 * ── v2（2026-10-06 全量审计后重写）────────────────────────────────────────
 * 审计结论：旧服务监听 `0.0.0.0:1122` 且**所有接口零校验** ⇒ 同局域网任何人都能
 * 下载书架全部本地书、按 time 删任意书签、往手机传任意文件并直接进书架。
 * 因此这里新增**配对码 + 已配对设备管理**（用户拍板 A2「像 TOTP 配对、常态化、可清历史设备」）：
 *   · 服务开启后显示 6 位**一次性配对码**与**纯地址**：电脑打开地址 → 页面弹窗输码即配对
 *     （2026-10-06 用户拍板"输码弹窗"模式，嫌带码链接麻烦）；「显示二维码」仍是带码完整
 *     地址（扫码自动配对）。码默认 10 分钟有效，可一键刷新
 *   · 「已配对设备」列表：显示配对时间 / 来源 IP / 浏览器标识，可**单个移除**、
 *     **全部清除**、**换口令**（换口令 = 清空全部设备 + 生成新码）
 *   · 保活状态如实展示：长时任务被系统取消时提示"后台已停止"，**不自动重申请**
 *     （《Background Tasks Kit 接入规范》禁止恶意保活）
 *
 * 回退：`WifiBookServer.WEB_AUTH_ENABLED = false` ⇒ 恢复旧行为（不显示配对码、零校验）。
 */
@CustomDialog
export struct WifiTransferDialog {
    dark: boolean = false
  onClose: () => void = (): void => {}
  private controller?: CustomDialogController
  @State running: boolean = WifiBookServer.isRunning()
  @State address: string = WifiBookServer.address()
  @State pairCode: string = ''
  @State codeLeft: number = 0
  @State devices: DevToken[] = []
  @State keepAliveCancelled: boolean = false
  @State showQr: boolean = false
  private ticker: number = -1

  aboutToAppear(): void {
    this.refresh()
    // 配对/传书期间屏幕常亮：手机锁屏冻结是"网络错误/配不上"的头号元凶
    // （真机复盘 2026-10-06）。SDK `Window.setWindowKeepScreenOn`（@ohos.window.d.ts，since 11）。
    try {
      if (WindowUtils.window !== undefined) {
        WindowUtils.window.setWindowKeepScreenOn(true)
          .catch((e: Error): void => console.error('WifiTransferDialog keepScreenOn failed: ' + e.message))
      }
    }
    catch (e) {
      console.error('WifiTransferDialog keepScreenOn threw: ' + JSON.stringify(e))
    }
    // 配对码倒计时（每秒刷新；关闭对话框时清掉）
    this.ticker = setInterval((): void => {
      // 临期（<60s）自动换新码，保证屏幕上显示的码永远可用 ≥1 分钟（读码+输码足够）
      WifiBookServer.ensureFreshPairCode()
      const left: number = WifiBookServer.pairCodeSecondsLeft()
      if (left !== this.codeLeft) {
        this.codeLeft = left
      }
      // 续码/刷新后同步显示（旧实现 pairCode 是快照，过期后仍显示死码 ⇒ 用户照输必败）
      const code: string = WifiBookServer.currentPairCode()
      if (code !== this.pairCode) {
        this.pairCode = code
      }
      const cancelled: boolean = WifiBookServer.keepAliveCancelled()
      if (cancelled !== this.keepAliveCancelled) {
        this.keepAliveCancelled = cancelled
      }
      const running: boolean = WifiBookServer.isRunning()
      if (running !== this.running) {
        this.running = running
        this.refresh()
      }
    }, 1000)
  }

  aboutToDisappear(): void {
    if (this.ticker >= 0) {
      clearInterval(this.ticker)
      this.ticker = -1
    }
    // 恢复系统默认息屏（对话框才常亮，离开页面即交还控制权）
    try {
      if (WindowUtils.window !== undefined) {
        WindowUtils.window.setWindowKeepScreenOn(false)
          .catch((e: Error): void => console.error('WifiTransferDialog keepScreenOff failed: ' + e.message))
      }
    }
    catch (e) {
      console.error('WifiTransferDialog keepScreenOff threw: ' + JSON.stringify(e))
    }
  }

  private refresh(): void {
    this.running = WifiBookServer.isRunning()
    // 展示/复制用**纯地址**（2026-10-06 用户拍板"输码弹窗"模式：电脑打开地址 → 页面弹窗输码；
    // 带码链接只用于二维码自动配对，见 build() 里的 QRCode）
    this.address = WifiBookServer.address()
    this.pairCode = WifiBookServer.currentPairCode()
    this.codeLeft = WifiBookServer.pairCodeSecondsLeft()
    this.devices = WifiBookServer.pairedDevices()
    this.keepAliveCancelled = WifiBookServer.keepAliveCancelled()
  }

  private copyAddress(): void {
    Haptics.tap()
    const text: string = this.address !== '' ? this.address : WifiBookServer.address()
    if (text === '') {
      this.getUIContext().getPromptAction().showToast({ message: '服务未运行' })
      return
    }
    const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text)
    pasteboard.getSystemPasteboard().setData(data)
    this.getUIContext().getPromptAction().showToast({ message: '地址已复制，电脑打开后输入上方配对码' })
  }

  private fmtTime(ms: number): string {
    if (!(ms > 0)) {
      return '尚未使用'
    }
    const d = new Date(ms)
    const mm: string = `${d.getMonth() + 1}`.padStart(2, '0')
    const dd: string = `${d.getDate()}`.padStart(2, '0')
    const hh: string = `${d.getHours()}`.padStart(2, '0')
    const mi: string = `${d.getMinutes()}`.padStart(2, '0')
    return `${mm}-${dd} ${hh}:${mi}`
  }

  private deviceLabel(d: DevToken): string {
    const ua: string = d.ua
    let name: string = '浏览器'
    if (ua.indexOf('Edg') >= 0) {
      name = 'Edge'
    } else if (ua.indexOf('Chrome') >= 0) {
      name = 'Chrome'
    } else if (ua.indexOf('Safari') >= 0) {
      name = 'Safari'
    } else if (ua.indexOf('Firefox') >= 0) {
      name = 'Firefox'
    }
    const kind: string = ua.indexOf('Windows') >= 0 ? 'Windows' : (ua.indexOf('Mac') >= 0 ? 'Mac' : '')
    return kind === '' ? name : `${kind} · ${name}`
  }

  @Builder
  deviceRow(d: DevToken) {
    Row({ space: 10 }) {
      Column({ space: 2 }) {
        Text(this.deviceLabel(d))
          .fontSize(13).fontWeight(600)
          .fontColor(this.dark ? '#EEEEEE' : '#222222')
        Text(`配对 ${this.fmtTime(d.pairedAt)} · 最近使用 ${this.fmtTime(d.lastSeen)}`)
          .fontSize(11).opacity(0.5)
          .fontColor(this.dark ? '#FFFFFF' : '#000000')
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Text('移除')
        .fontSize(12).fontWeight(600)
        .fontColor('#EF4444')
        .padding({ left: 10, right: 10, top: 6, bottom: 6 })
        .borderRadius(8)
        .backgroundColor(this.dark ? '#2A2A2C' : 'rgba(239,68,68,0.08)')
        .clickEffect(UiMotion.CLICK)
        .onClick(() => {
          Haptics.tap()
          WifiBookServer.removeDevice(d.token)
          this.refresh()
          this.getUIContext().getPromptAction().showToast({ message: '该设备已失效，需重新配对' })
        })
    }
    .width('100%')
    .padding({ top: 8, bottom: 8 })
  }

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
              WifiBookServer.start(
                this.getUIContext().getHostContext() as common.UIAbilityContext,
                (ok: boolean, msg: string) => {
                  this.running = ok
                  this.refresh()
                  if (!ok) {
                    this.getUIContext().getPromptAction().showToast({ message: msg })
                  }
                })
            } else {
              WifiBookServer.stop(
                this.getUIContext().getHostContext() as common.UIAbilityContext,
                (_ok: boolean): void => {
                  this.running = false
                  this.refresh()
                })
            }
          })
      }
      .width('100%')

      Text('手机与电脑连接同一 WiFi。电脑浏览器打开下方地址，页面会弹出配对框，输入上面的 6 位配对码即可（每台电脑只需配对一次；10 分钟内同一码可配多台设备）；也可以点"显示二维码"扫码直接配对。配对时请保持本页打开，屏幕已自动保持常亮。')
        .fontSize(13)
        .opacity(0.55)
        .width('100%')

      if (this.running && this.address !== '') {
        // ── 配对码 ────────────────────────────────────────────────────────
        Column({ space: 8 }) {
          Row({ space: 8 }) {
            Text('电脑配对码').fontSize(12).opacity(0.55)
            Blank()
            Text(this.codeLeft > 0 ? `${this.codeLeft}s 后失效` : '已失效，请刷新')
              .fontSize(11)
              .fontColor(this.codeLeft > 0 ? '#8a8f99' : '#EF4444')
          }
          .width('100%')

          Text(this.pairCode !== '' ? this.pairCode : '— — — — — —')
            .fontSize(30).fontWeight(800)
            .letterSpacing(6)
            .fontColor('#0A84FF')

          if (this.showQr) {
            // 二维码内容 = 带配对码的完整地址（扫码即自动配对，免输码）
            QRCode(WifiBookServer.pairAddress() !== '' ? WifiBookServer.pairAddress() : this.address)
              .width(150).height(150)
              .color(this.dark ? '#FFFFFF' : '#181818')
              .backgroundColor(Color.Transparent)
          }

          Row({ space: 10 }) {
            Text('复制地址')
              .fontSize(13).fontWeight(600).fontColor('#0A84FF')
              .clickEffect(UiMotion.CLICK)
              .onClick(() => this.copyAddress())
            Text(this.showQr ? '收起二维码' : '显示二维码')
              .fontSize(13).fontWeight(600).fontColor('#0A84FF')
              .clickEffect(UiMotion.CLICK)
              .onClick(() => {
                Haptics.tap()
                this.showQr = !this.showQr
              })
            Text('刷新配对码')
              .fontSize(13).fontWeight(600).fontColor('#0A84FF')
              .clickEffect(UiMotion.CLICK)
              .onClick(() => {
                Haptics.tap()
                WifiBookServer.rotatePairingCode()
                this.refresh()
                this.getUIContext().getPromptAction().showToast({ message: '已换新口令，之前配对的电脑全部失效' })
              })
          }
          .width('100%')
          .justifyContent(FlexAlign.SpaceBetween)
        }
        .width('100%')
        .padding(14)
        .borderRadius(12)
        .backgroundColor(this.dark ? '#2A2A2C' : 'rgba(10,132,255,0.06)')

        // ── 地址（只读展示）──────────────────────────────────────────────
        Row({ space: 12 }) {
          Text(this.address)
            .fontSize(13)
            .fontColor(this.dark ? '#FFFFFF' : '#181818')
            .layoutWeight(1)
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .width('100%')
        .padding({ left: 14, right: 14, top: 10, bottom: 10 })
        .borderRadius(10)
        .backgroundColor(this.dark ? '#2A2A2C' : 'rgba(0, 0, 0, 0.04)')

        // ── 已配对设备 ────────────────────────────────────────────────────
        Column({ space: 6 }) {
          Row({ space: 8 }) {
            Text(`已配对的设备（${this.devices.length}）`).fontSize(13).fontWeight(600)
              .fontColor(this.dark ? '#EEEEEE' : '#222222')
            Blank()
            if (this.devices.length > 0) {
              Text('全部清除')
                .fontSize(12).fontWeight(600).fontColor('#EF4444')
                .clickEffect(UiMotion.CLICK)
                .onClick(() => {
                  Haptics.tap()
                  WifiBookServer.clearDevices()
                  this.refresh()
                  this.getUIContext().getPromptAction().showToast({ message: '已清除全部设备，需重新配对' })
                })
            }
          }
          .width('100%')

          if (this.devices.length === 0) {
            Text('还没有电脑配对过。把上面的地址在电脑浏览器打开即完成配对。')
              .fontSize(12).opacity(0.5)
              .fontColor(this.dark ? '#FFFFFF' : '#000000')
              .width('100%')
          } else {
            List({ space: 0 }) {
              ForEach(this.devices, (d: DevToken) => {
                ListItem() {
                  this.deviceRow(d)
                }
              }, (d: DevToken) => d.token)
            }
            .width('100%')
            .height(Math.min(150, this.devices.length * 52))
            .scrollBar(BarState.Auto)
          }
        }
        .width('100%')
        .padding({ left: 14, right: 14, top: 10, bottom: 10 })
        .borderRadius(12)
        .backgroundColor(this.dark ? '#2A2A2C' : 'rgba(0, 0, 0, 0.03)')

        // ── 保活状态（如实告知，不粉饰）───────────────────────────────────
        if (this.keepAliveCancelled) {
          Text('⚠️ 系统已停止本应用的后台运行（官方口径：数据传输类长时任务进度超过 10 分钟未更新会被取消）。'
            + '电脑端此刻可能连不上——请重新关闭再打开本开关。')
            .fontSize(12)
            .fontColor('#E0A020')
            .width('100%')
        }
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
