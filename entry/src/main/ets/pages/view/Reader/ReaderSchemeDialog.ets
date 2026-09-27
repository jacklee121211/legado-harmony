/**
 * 「更多方案」弹窗（2026-09-25 新增，用户设计）。
 *
 * ── 需求原文 ──────────────────────────────────────────────────────────────
 * 「保存的方案在底部显示很差，也拖不动，我们直接做一个**和更多材质一样的按钮和弹窗**，
 *   就放在更多材质旁边，就叫做**更多方案**。效果一样，如果选择的方案是其中，
 *   则**按钮外有红圈**。」
 * ⇒ 方案（背景色 + 字色 成对，见 `BgSchemeEntry`）不再铺在面板底部，
 *   全部收进本弹窗：四列网格、点选即应用、可删除。当前正在使用的方案画橙圈，
 *   弹窗关闭后「更多方案」按钮持圈（页面侧 `bgFocus === 'scheme'` 判定）。
 *
 * ── 交互 ──────────────────────────────────────────────────────────────────
 * · 点缩略图 = 应用该方案（回调页面 `applyScheme`）并自关；
 * · 右上角小 × = 删除该方案（本弹窗内即时刷新列表）。
 * 弹窗配方与「更多材质」同款：`systemMaterial` 沉浸光感 + 弹簧出入场。
 */
import { BgSchemeEntry, ReaderCustomBg } from '../../../common/utils/ReaderCustomBg'
import { Haptics } from '../../../common/utils/Haptics'
import UiMotion from '../../../common/utils/UiMotion'

@CustomDialog
export struct ReaderSchemeDialog {
  controller?: CustomDialogController

  /** 当前应用中的方案背景色（页面 `bgFocus==='scheme'` 时的 `schemeFocusBg`）；'' = 无 */
  @Prop focusBgHex: string = ''

  /** 点选回调：页面侧 `applyScheme(e)` 应用方案；本弹窗随后自关 */
  onPick: (e: BgSchemeEntry) => void = (): void => {}

  /**
   * 关闭回调（2026-09-26 弹窗协调）：完成/选中后由**页面**关本弹窗并恢复父弹窗
   * （设置面板）—— 关闭权在页面（弹窗内 controller?.close() 曾失灵，见页面侧注释）。
   */
  onClose: () => void = (): void => {}

  /** 0 = 夜间，1 = 日间（与 `ReaderPage3.colorMode` 同义，随 AppStorage 同步） */
  @StorageLink('readerColorMode') colorMode: number = 1

  /** 方案列表（弹窗内自持 @State：删除后本弹窗即时刷新，不必重建弹窗） */
  @State schemes: BgSchemeEntry[] = []

  aboutToAppear(): void {
    this.schemes = ReaderCustomBg.loadSchemes()
  }

  /** 方案"字"的显示色：没手动选过（fontHex=''）= 按背景自动对比 */
  private schemeFontHex(e: BgSchemeEntry): string {
    if (e.fontHex.length > 0) {
      return e.fontHex
    }
    const rgb = ReaderCustomBg.parseColor(e.bgHex)
    return rgb === null ? '#000000' : ReaderCustomBg.contrastFont(rgb)
  }

  /** 该方案是否为当前应用中的（画橙圈） */
  private isFocused(e: BgSchemeEntry): boolean {
    const rgb = ReaderCustomBg.parseColor(e.bgHex)
    return this.focusBgHex.length > 0 && rgb !== null
      && ReaderCustomBg.hexOf(rgb) === this.focusBgHex
  }

  build() {
    Column({ space: 12 }) {
      // 顶栏：标题 + 完成
      Row() {
        Text('更多方案')
          .fontSize(16)
          .fontWeight(600)
          .fontColor(this.colorMode == 0 ? 'rgba(248, 249, 250, 1)' : 'rgba(19, 19, 19, 1.00)')
        Blank()
        Text('完成')
          .fontSize(15)
          .fontColor('#007DFF')
          .onClick(() => {
            Haptics.tap();
            this.onClose()
          })
      }
      .width('100%')

      if (this.schemes.length === 0) {
        Text('还没有保存过方案：调好背景和字色后，按「保存方案」即可存到这里')
          .fontSize(12)
          .fontColor(this.colorMode == 0 ? 'rgba(248, 249, 250, 0.5)' : 'rgba(19, 19, 19, 0.5)')
          .width('100%')
          .textAlign(TextAlign.Center)
          .padding({ top: 30, bottom: 30 })
      } else {
        // 方案网格：四列、纵向滚动（上限 100，装得下）
        Grid() {
          ForEach(this.schemes, (e: BgSchemeEntry) => {
            GridItem() {
              Stack({ alignContent: Alignment.TopEnd }) {
                Column() {
                  Text('字')
                    .fontSize(18)
                    .fontWeight(600)
                    .fontColor(this.schemeFontHex(e))
                }
                .width('100%')
                .height(64)
                .justifyContent(FlexAlign.Center)
                .backgroundColor(e.bgHex)
                .borderWidth(this.isFocused(e) ? 2 : 1)
                .borderColor(this.isFocused(e)
                  ? '#ff6600'
                  : (this.colorMode == 0 ? 'rgba(248, 249, 250, 0.30)' : 'rgba(0, 0, 0, 0.20)'))
                .borderRadius(12)
                Text('×')
                  .fontSize(11)
                  .fontWeight(600)
                  .fontColor('#FFFFFF')
                  .width(16)
                  .height(16)
                  .textAlign(TextAlign.Center)
                  .borderRadius(8)
                  .backgroundColor('rgba(0, 0, 0, 0.55)')
                  .margin({ right: 3, top: 3 })
                  .onClick(() => {
                    Haptics.tap();
                    ReaderCustomBg.deleteScheme(e)
                    this.schemes = ReaderCustomBg.loadSchemes()
                  })
              }
              .width('100%')
              .onClick(() => {
                Haptics.tap();
                this.onPick(e)
                this.onClose()
              })
              .clickEffect(UiMotion.CLICK)
            }
          }, (e: BgSchemeEntry): string => 'sv2-' + e.bgHex + '-' + e.fontHex)
        }
        .columnsTemplate('1fr 1fr 1fr 1fr')
        .columnsGap(10)
        .rowsGap(10)
        .height(320)
        .width('100%')
        .scrollBar(BarState.Off)
      }
    }
    .width('100%')
    .padding(20)
  }
}
