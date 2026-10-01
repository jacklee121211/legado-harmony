import { Haptics } from '../../common/utils/Haptics'
import { runJellyClick } from '../../common/utils/UiMotion'

/**
 * 弹窗图标按钮·统一范式（v3.21 从 BookInfoDialogs 抽出公共化）：
 * symbol 图标 + 独立 Q弹（runJellyClick 自驱 scale）+ 全局震动。
 * 用户要求全项目弹窗按钮统一此范式（长按书籍/长按分组等）。
 * 每键独立弹跳状态 ⇒ 必须是独立 @Component（父组件数组下标更新不触发 V1 渲染）。
 */
@Component
export default struct MarkToolButton {
  icon: Resource = $r('sys.symbol.pin')
  label: string = ''
  iconFontSize: number = 24
  labelFontSize: number = 12
  labelFontColor: ResourceColor = $r('app.string.color_black_65')
  onTap: () => void = (): void => {}
  @State jellyScale: number = 1

  build() {
    Column({ space: 6 }) {
      SymbolGlyph(this.icon)
        .fontSize(this.iconFontSize)
        .fontColor([$r('app.string.color_black_65')])
        .scale({ x: this.jellyScale, y: this.jellyScale })
      Text(this.label)
        .fontSize(this.labelFontSize).fontWeight(400)
        .fontColor(this.labelFontColor)
        .maxLines(1)
    }
    .onClick(() => {
      Haptics.tap();
      runJellyClick((v: number) => {
        this.jellyScale = v
      })
      this.onTap()
    })
  }
}
