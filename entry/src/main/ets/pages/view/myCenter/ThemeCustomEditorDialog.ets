import { Haptics } from '../../../common/utils/Haptics'
import { ThemeItem } from '../../../common/model/Theme'
import { ThemeStorageKey } from '../../../common/constants/Theme'
import { themeManager } from '../../../common/utils/ThemeManager'
import { ReaderCustomBg, RgbTriple } from '../../../common/utils/ReaderCustomBg'
import { ReaderBgPalette } from '../Reader/ReaderBgPalette'
import { MaterialColumnModifier } from '../../../common/utils/ImmersiveMaterialUtil'
import UiMotion from '../../../common/utils/UiMotion'
import { NightMode } from '../../../common/utils/NightMode'

/**
 * 「自定义主题」编辑弹窗（2026-10-01，**VIP 特权**）。
 *
 * ── 为什么可以做 ─────────────────────────────────────────────────────────────
 * 既有结论：现有主题方案都是**纯颜色渲染算法**（ThemeItem = mainColor 前景 + secondColor
 * 背景，全工程按这两个值取色），不含图片/资源 ⇒ 用户自选颜色即可生成一个合法主题。
 *
 * ── 与阅读器-设置页自定义颜色方案的关系 ───────────────────────────────────────
 * 取色器直接复用 `ReaderBgPalette`（无极色盘：横向色相 × 纵向明暗，任意点闭式可取色）
 * + 三条 0-255 RGB 滑块（ReaderPage3 同款交互：滑动线性震动 + 右侧实时数值）。
 *
 * ── secondColor 的推导算法 ───────────────────────────────────────────────────
 * 内置五套主题的色对关系是「secondColor ≈ mainColor 混白 ~88%」
 * （Theme.ets：#ff6600→#ffece0、#ef4444→#fde8e8、#188bff→#e3f1ff…），
 * 故自定义主题沿用同一算法：`ReaderCustomBg.mix(主色, WHITE, 0.88)`，
 * 保证自定义主题与内置主题在 chip/按钮（mainColor 前景 + secondColor 底）上的观感一致。
 *
 * ── 方案管理 ────────────────────────────────────────────────────────────────
 * 存取走 `ThemeManager` 既有基建：addTheme（THEMELISTSTR 持久化）→ setTheme（立即应用）；
 * 删除/切换由主题页既有长按删除、点击应用承担。
 */
@CustomDialog
export default struct ThemeCustomEditorDialog {
  controller?: CustomDialogController
  onClose: () => void = (): void => {}
  /** 背板：调用方 options 已给 systemMaterial ⇒ 让出背景 */
  private surface: MaterialColumnModifier = new MaterialColumnModifier(Color.White, true)

  /** 草稿 RGB（取色盘/滑块只写草稿，按「保存」才生成主题）——与阅读器同一交互哲学 */
  @State draftR: number = 255
  @State draftG: number = 102
  @State draftB: number = 0
  @State themeName: string = ''

  aboutToAppear(): void {
    // 初始草稿 = 当前主题主色（从用户正在用的颜色起步，比从纯白起步友好）
    const cur: ThemeItem | undefined = AppStorage.get<ThemeItem>(ThemeStorageKey.THEME)
    const rgb: RgbTriple = ThemeCustomEditorDialog.hexToRgb(cur?.mainColor ?? '#ff6600')
    this.draftR = rgb.r
    this.draftG = rgb.g
    this.draftB = rgb.b
    // 默认名 = 自定义序号（内置 5 套之后的第 N 套）
    const list: ThemeItem[] | undefined = AppStorage.get<ThemeItem[]>(ThemeStorageKey.THEMELIST)
    const n: number = Math.max(1, (list?.length ?? 5) - 5 + 1)
    this.themeName = `自定义${n}`
  }

  /** '#rrggbb' → RGB（容错：非法串回退默认橙） */
  private static hexToRgb(hex: string): RgbTriple {
    const s: string = hex.replace('#', '')
    if (s.length !== 6) {
      return ReaderCustomBg.make(255, 102, 0)
    }
    const r: number = parseInt(s.substring(0, 2), 16)
    const g: number = parseInt(s.substring(2, 4), 16)
    const b: number = parseInt(s.substring(4, 6), 16)
    if (isNaN(r) || isNaN(g) || isNaN(b)) {
      return ReaderCustomBg.make(255, 102, 0)
    }
    return ReaderCustomBg.make(r, g, b)
  }

  private draft(): RgbTriple {
    return ReaderCustomBg.make(this.draftR, this.draftG, this.draftB)
  }

  private draftHex(): string {
    return ReaderCustomBg.hexOf(this.draft())
  }

  /** 次色推导：主色混白 88%（内置主题同一算法，见类注释） */
  private derivedSecondHex(): string {
    return ReaderCustomBg.hexOf(ReaderCustomBg.mix(this.draft(), ReaderCustomBg.WHITE, 0.88))
  }

  private setDraft(r: number, g: number, b: number): void {
    this.draftR = Math.min(255, Math.max(0, Math.round(r)))
    this.draftG = Math.min(255, Math.max(0, Math.round(g)))
    this.draftB = Math.min(255, Math.max(0, Math.round(b)))
  }

  private save(): void {
    if (this.themeName.trim().length === 0) {
      this.getUIContext().getPromptAction().showToast({ message: '主题名称不能为空' })
      return
    }
    const item: ThemeItem = {
      text: this.themeName.trim(),
      mainColor: this.draftHex(),
      secondColor: this.derivedSecondHex()
    }
    themeManager.addTheme(item)
    // 保存即应用（新方案排到列表尾并成为当前主题）
    const list: ThemeItem[] | undefined = AppStorage.get<ThemeItem[]>(ThemeStorageKey.THEMELIST)
    themeManager.setTheme(item, (list?.length ?? 1) - 1)
    this.getUIContext().getPromptAction().showToast({ message: `已应用「${item.text}」` })
    this.controller?.close()
    this.onClose()
  }

  build() {
    Column({ space: 14 }) {
      Text('自定义主题')
        .fontSize(16).fontWeight(700).lineHeight(24)
        .fontColor(NightMode.isDarkSurface() ? 'rgba(248, 249, 250, 0.88)' : 'rgba(0, 0, 0, 0.88)')
        .width('100%')

      // ── 实时预览（算法结果：主色前景 + 次色底，与全工程取色一致）────────────────
      Row({ space: 12 }) {
        Column({ space: 6 }) {
          Text('预览')
            .fontSize(11)
            .fontColor(this.derivedSecondHex() === '' ? '#ffffff' : 'rgba(0,0,0,0.45)')
          Text(this.themeName === '' ? '自定义主题' : this.themeName)
            .fontSize(15).fontWeight(600)
            .fontColor(this.draftHex())
          Row()
            .width(46).height(6).borderRadius(3)
            .backgroundColor(this.draftHex())
        }
        .justifyContent(FlexAlign.Center)
        .layoutWeight(1)
        .height(76)
        .borderRadius(12)
        .backgroundColor(this.derivedSecondHex())

        Column({ space: 4 }) {
          Text('主色')
            .fontSize(11)
            .fontColor(NightMode.isDarkSurface() ? 'rgba(248, 249, 250, 0.55)' : 'rgba(0, 0, 0, 0.45)')
          Text(this.draftHex())
            .fontSize(13).fontWeight(600)
            .fontColor(this.draftHex())
          Text('次色')
            .fontSize(11)
            .fontColor(NightMode.isDarkSurface() ? 'rgba(248, 249, 250, 0.55)' : 'rgba(0, 0, 0, 0.45)')
          Text(this.derivedSecondHex())
            .fontSize(13)
            .fontColor(NightMode.isDarkSurface() ? 'rgba(248, 249, 250, 0.65)' : 'rgba(0, 0, 0, 0.55)')
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
      }
      .width('100%')

      // ── 取色盘 + RGB 滑块（ReaderPage3 同款交互：滑动线性震动 + 实时数值）────────
      // ⚠️ build 内组件参数闭包只能单表达式（ets lint noNonUISyntax）；
      //    onCommit 用默认实现（落盘确认权在「保存」按钮）。
      Row({ space: 14 }) {
        ReaderBgPalette({
          paletteR: this.draftR,
          paletteG: this.draftG,
          paletteB: this.draftB,
          onPick: (r: number, g: number, b: number): void => this.setDraft(r, g, b)
        })

        Column({ space: 8 }) {
          this.rgbSliderRow('R', this.draftR, '#ef4444', (v: number): void => {
            this.setDraft(v, this.draftG, this.draftB)
          })
          this.rgbSliderRow('G', this.draftG, '#24b277', (v: number): void => {
            this.setDraft(this.draftR, v, this.draftB)
          })
          this.rgbSliderRow('B', this.draftB, '#188bff', (v: number): void => {
            this.setDraft(this.draftR, this.draftG, v)
          })
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')

      // ── 名称 ──
      TextInput({ placeholder: '主题名称（最多8字）', text: this.themeName })
        .height(40)
        .maxLength(8)
        .fontSize(14)
        .borderRadius(10)
        .onChange((value: string) => {
          this.themeName = value
        })
        .width('100%')

      // ── 操作行 ──
      Row({ space: 12 }) {
        Button('取消')
          .layoutWeight(1)
          .height(42)
          .fontSize(15)
          .fontColor(this.currentMainColor())
          .backgroundColor(this.currentSecondColor())
          .borderRadius(21)
          .onClick(() => {
            Haptics.tap();
            this.controller?.close()
            this.onClose()
          })
        Button('保存并应用')
          .layoutWeight(1)
          .height(42)
          .fontSize(15)
          .fontColor(Color.White)
          .backgroundColor(this.draftHex())
          .borderRadius(21)
          .onClick(() => {
            Haptics.tap();
            this.save()
          })
      }
      .width('100%')
      .margin({ bottom: 4 })
    }
    .padding(20)
    .borderRadius(20)
    .attributeModifier(this.surface)
    .width('100%')
  }

  private currentMainColor(): string {
    const cur: ThemeItem | undefined = AppStorage.get<ThemeItem>(ThemeStorageKey.THEME)
    return cur?.mainColor ?? '#ff6600'
  }

  private currentSecondColor(): string {
    const cur: ThemeItem | undefined = AppStorage.get<ThemeItem>(ThemeStorageKey.THEME)
    return cur?.secondColor ?? '#ffece0'
  }

  /** 一条 RGB 滑块行（ReaderPage3 同款：InSet 滑块 + 通道色标签 + 实时数值） */
  @Builder
  rgbSliderRow(label: string, value: number, channelColor: string, apply: (v: number) => void) {
    Row({ space: 6 }) {
      Text(label)
        .fontSize(12)
        .width(14)
        .fontWeight(600)
        .fontColor(NightMode.isDarkSurface() ? 'rgba(248, 249, 250, 0.88)' : 'rgba(19, 19, 19, 1)')
      Slider({ value: value, min: 0, max: 255, step: 1, style: SliderStyle.InSet })
        .selectedColor(channelColor)
        .blockSize({ width: 22, height: 22 })
        .borderRadius(20)
        .width('100%')
        .showTips(false)
        .onChange((value: number, mode: SliderChangeMode) => {
          Haptics.tick();
          apply(Math.round(value))
        })
      Text(`${value}`)
        .fontSize(12)
        .width(30)
        .textAlign(TextAlign.End)
        .fontColor(channelColor)
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
  }
}
