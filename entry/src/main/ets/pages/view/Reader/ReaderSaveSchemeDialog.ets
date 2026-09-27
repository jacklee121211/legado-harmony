import { MaterialColumnModifier } from '../../../common/utils/ImmersiveMaterialUtil'
// ── 全局震动反馈（2026-09-25 新增）────────────────────────────────────────────
import { Haptics } from '../../../common/utils/Haptics'
import { hilog } from '@kit.PerformanceAnalysisKit'

/**
 * 「保存此颜色方案」确认弹窗（2026-09-26 按用户设计新建）。
 *
 * ── 用户需求原文 ──────────────────────────────────────────────────────────
 * 「在开启自定义后，翻页右侧再增加个按钮，**保存方案**，点击后出现弹窗，
 *   **是否保存此颜色方案，确定，取消**。」
 *
 * ── 配方与邻居完全一致（刻意照抄 `SleepTimerDialog`）────────────────────────
 * · 材质走 `CustomDialogControllerOptions.systemMaterial`
 *   （`custom_dialog_controller.d.ts`，@since 26.0.0）+ `customStyle:false`
 *   ⇒ 悬空四圆角 + 半透明沉浸光感；内容层**一个背景属性都不设**（设了会挡掉材质，
 *     见 `SleepTimerDialog` 文件头与本工程 `ImmersiveMaterialUtil` 的取证）。
 * · `@StorageLink('readerColorMode')` 而不是 `@Prop`：弹窗由页面**每次新建**时构造，
 *   但日夜配色是"随页面变化"的，直接吃父页面写进 AppStorage 的同一个 key
 *   ⇒ 零传参、天然同步（与 `ReaderListenDialog` / `SleepTimerDialog` 同款）。
 * · 次级按钮（取消）底色/字色必须随日夜翻，否则夜间是"深底黑字"看不见。
 *
 * 本弹窗**不做任何持久化**：只负责"问一句"，保存动作由页面（`ReaderPage3`）执行。
 */
@CustomDialog
export struct ReaderSaveSchemeDialog {
  controller?: CustomDialogController

  /** 待保存的背景色（`#RRGGBB`），只用于预览块与文案 */
  @Prop schemeHex: string = '#FFFFFF'
  /**
   * 待保存的**字色**（2026-09-25 方案 V2：方案 = 背景+字色 成对）。
   * `''` = 字色未手动选过（应用时按背景自动对比），预览块的"字"用自动对比色。
   */
  @Prop fontHex: string = ''

  /** 确定：交给调用方去落盘 */
  onConfirm: () => void = (): void => {}
  /** 取消 / 关闭 */
  onCancel: () => void = (): void => {}

  /** 0 = 夜间，1 = 日间（与 `ReaderPage3.colorMode` 同义，见文件头） */
  @StorageLink('readerColorMode') colorMode: number = 1

  private surface: MaterialColumnModifier = new MaterialColumnModifier(Color.White, true)

  private subBtnBg(): string {
    return this.colorMode == 0 ? 'rgba(255, 255, 255, 0.14)' : 'rgba(0, 0, 0, 0.06)';
  }

  private subBtnFg(): string {
    return this.colorMode == 0 ? 'rgba(255, 255, 255, 0.88)' : 'rgba(0, 0, 0, 0.88)';
  }

  /** 预览"字"的颜色：fontHex 为空 = 自动对比（深浅由背景明暗决定） */
  private previewFontHex(): string {
    if (this.fontHex.length > 0) {
      return this.fontHex
    }
    // 粗略自动对比：按 hex 的感知亮度选黑/白（与 ReaderCustomBg 同一思路的轻量版）
    const h = this.schemeHex.replace('#', '')
    if (h.length !== 6) {
      return '#000000'
    }
    const r = parseInt(h.substring(0, 2), 16)
    const g = parseInt(h.substring(2, 4), 16)
    const b = parseInt(h.substring(4, 6), 16)
    return (0.2126 * r + 0.7152 * g + 0.0722 * b) > 128 ? '#000000' : '#FFFFFF'
  }

  private fontLabel(): string {
    return this.fontHex.length > 0 ? this.fontHex : '自动'
  }

  aboutToAppear(): void {
    // 材质不可用时的兜底色（夜里给深底，否则白底 + 白字）
    this.surface = new MaterialColumnModifier(
      this.colorMode == 0 ? '#1F1F1F' : Color.White, true);
  }

  build() {
    Column() {
      Text('是否保存此方案（背景 + 字色）')
        .fontSize(16)
        .fontWeight(600)

      // 预览：这一块就是即将存进方案区的样子（底色 = 背景色，"字" = 字色）
      Row({ space: 10 }) {
        Column() {
          Text('字')
            .fontSize(15)
            .fontWeight(600)
            .fontColor(this.previewFontHex())
        }
        .width(40)
        .height(26)
        .justifyContent(FlexAlign.Center)
        .borderRadius(13)
        .backgroundColor(this.schemeHex)
        .borderWidth(1)
        .borderColor(this.colorMode == 0 ? 'rgba(255, 255, 255, 0.35)' : 'rgba(0, 0, 0, 0.25)')
        Text(`背景 ${this.schemeHex} · 字色 ${this.fontLabel()}`)
          .fontSize(13)
          .fontColor(this.colorMode == 0 ? 'rgba(248, 249, 250, 0.75)' : 'rgba(19, 19, 19, 0.7)')
      }
      .padding({ top: 14, bottom: 4 })

      Row({ space: 12 }) {
        // ⚠️ 2026-09-25 真机日志定位（2.md）：点取消时点击识别成功（CLK RACC T: Button）、
        //   onClick 也执行了（Haptics 探测日志都在），但 `this.controller?.close()` 没有关掉弹窗；
        //   而**页面侧**持有的 controller 调 close() 一直可靠（设置面板 Blank 关闭从未失手）。
        //   ⇒ 关闭权收回页面：onCancel/onConfirm 回调里由页面 close()，这里的双保险保留。
        Button('取消')
          .layoutWeight(1)
          .backgroundColor(this.subBtnBg())
          .fontColor(this.subBtnFg())
          .onClick(() => {
            hilog.info(0x0000, 'testTag', 'saveSchemeDlg: cancel clicked')
            Haptics.tap();
            this.onCancel()
            this.controller?.close()
          })
        Button('确定')
          .layoutWeight(1)
          .backgroundColor('rgba(0, 125, 255, 1.00)')
          .fontColor(Color.White)
          .onClick(() => {
            hilog.info(0x0000, 'testTag', 'saveSchemeDlg: confirm clicked')
            Haptics.tap();
            this.onConfirm()
            this.controller?.close()
          })
      }
      .width('100%')
      .padding({ top: 14 })
    }
    .width('100%')
    .padding(20)
    .borderRadius(20)
    .attributeModifier(this.surface)
  }
}
