import { NightMode } from '../../common/utils/NightMode'

/**
 * 底部页签页（主题/设置/我的）的**统一标题头**（2026-10-01 用户需求：
 * "主题、设置的顶部标题位置字体都不一样，应该统一"）。
 *
 * ── 规格（取自 SetHead 的标题样式，三页一字不差）────────────────────────────
 * fontSize 16 · fontWeight 600 · `app.color.text_primary` · 水平居中 ·
 * 高 48 · 上下内边距 12。
 *
 * ── 与 SetHead 的区别 ───────────────────────────────────────────────────────
 * SetHead 自带**返回箭头**（AppRouter.back()）——那是给关于系列等 push 页用的；
 * 页签页没有返回语义，点返回会弹空 Navigation 栈 ⇒ 页签页一律用本组件。
 * 深浅色：text_primary 为语义色资源，跟随 Ability 配色自动翻面。
 */
@Component
export struct TabHeader {
  title: string = ''

  build() {
    Text(this.title)
      .fontSize(16)
      .fontWeight(600)
      .fontColor(NightMode.isDarkSurface() ? 'rgba(248, 249, 250, 0.92)' : $r('app.color.text_primary'))
      .textAlign(TextAlign.Center)
      .width('100%')
      .height(48)
      .padding({ top: 12, bottom: 12 })
  }
}
