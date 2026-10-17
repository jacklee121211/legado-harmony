import { PublicConstants, TextConstants } from '../constants/PublicConstants';

//column统一样式类
export class ColumnModifier implements AttributeModifier<ColumnAttribute> {
  private paddingNumber: Padding = { left: 20, right: 20 };
  private marginNumber: Margin | Length = 0
  private topRectHeight = AppStorage.get("topRectHeight") as number
  private bottomRectHeight = AppStorage.get("bottomRectHeight") as number
  private backgroundColors: ResourceColor = PublicConstants.WINDOW_BACKGROUND_COLOR
  /**
   * 是否**不让出**底部系统手势区（默认 false = 让出，即 padding.bottom = bottomRectHeight）。
   *
   * ── 为什么需要这个开关（2026-10-13）──────────────────────────────────────
   * 本修饰器把 `bottomRectHeight` 直接加在**页面容器盒子**上 ⇒ 滚动内容会被截在
   * 屏幕底以上，底部剩下一条永远是"页面底色"，看起来就是"内容穿不到底/被遮住一条"。
   * 这与 `docs/底部手势区贯通-排查记录.md` 第 2 节记的元凶是同一条：
   *   「滚动容器（List / Scroll / Grid / WaterFlow）**盒子自身的底部 margin/padding**
   *     会把内容截在屏幕底以上」；
   *   正确做法：「底部让位一律用 `contentEndOffset`（只动内容末尾）**或给内容加内边距**」。
   *
   * ⇒ 需要"贯穿到底"的页面（如「读过/读完」）调本方法，让底座不再留边，
   *   改由**滚动内容自己的末尾内边距**保证最后一项不被手势条/悬浮 dock 压住。
   * 默认行为**完全不变**（其它页面零影响）。
   */
  private skipBottomInset: boolean = false

  applyNormalAttribute(instance: ColumnAttribute): void {
    this.paddingNumber.top = this.topRectHeight
    this.paddingNumber.bottom = this.skipBottomInset ? 0 : this.bottomRectHeight
    instance.padding(this.paddingNumber);
    instance.margin(this.marginNumber);
    instance.backgroundColor(this.backgroundColors)
  }

  /**
   * 底部**不让出**系统手势区（内容可以画到屏幕最底）。
   * ⚠️ 调用方必须自己在**滚动内容末尾**补内边距，否则最后一项会被手势条 / 悬浮 dock 压住。
   */
  withoutBottomInset(): ColumnModifier {
    this.skipBottomInset = true
    return this;
  }

  setCustom(Padding: Padding): ColumnModifier {
    this.paddingNumber = Padding
    this.topRectHeight = 0
    this.bottomRectHeight = 0
    return this;
  }

  setPadding(left: number, right: number): ColumnModifier {
    this.paddingNumber.left = left
    this.paddingNumber.right = right
    return this;
  }

  margin(marginNumber: Margin | Length): ColumnModifier {
    this.marginNumber = marginNumber
    return this;
  }

  backgroundColor(backgroundColors: ResourceColor): ColumnModifier {
    this.backgroundColors = backgroundColors
    return this;
  }
}

//Text统一样式类
export class TextModifier implements AttributeModifier<TextAttribute> {
  private publicFontSize: number | string | Resource = TextConstants.TEXT_FONT_SIZE;
  private publicLineHeight: number | string | Resource = TextConstants.TEXT_LINE_HEIGHT;

  applyNormalAttribute(instance: TextAttribute): void {
    instance.fontSize(this.publicFontSize);
    instance.lineHeight(this.publicLineHeight);
  }

  fontSize(fontSize: number | string | Resource, textType: number = 0) {
    this.publicFontSize = textType == 1 ? TextConstants.TEXT_FONT_SIZE : fontSize
    return this
  }

  lineHeight(lineHeight: number | string | Resource, textType: number = 0) {
    this.publicLineHeight = textType == 1 ? TextConstants.TEXT_LINE_HEIGHT : lineHeight
    return this
  }
}
