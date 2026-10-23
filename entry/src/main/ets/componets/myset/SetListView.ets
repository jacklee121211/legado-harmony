import { SetList } from '../dataList/SetListGroup'
import ImmersiveMaterialUtil from '../../common/utils/ImmersiveMaterialUtil'
import FontConstants from '../../common/constants/FontConstants'
import { ShelfColors } from '../../common/utils/NightMode'

@Component
export struct SetListView{


  topLeft: number = 0

  topRight: number = 0

  bottomLeft: number = 0

  bottomRight: number = 0

  @ObjectLink setList :SetList


  build() {
    Row(){

      // ⚠️ 2026-10-06 字号统一（用户实测："『显示文件拓展名』的字号和上面的不一样"）：
      //   旧实现把**行标题**的字号跟"这一行有没有副说明"绑在一起 —— 有副说明 14、没有 16
      //   ⇒ 同一个卡片里两种号混排（本页 `返回时提示放入书架` 的说明是空串，于是它比邻居大一号）。
      //   现在两个分支都取 `FontConstants.ITEM`；副说明/右侧值统一 12（`FontConstants.CAPTION`）。
      //   口径写在 `common/constants/FontConstants.ets` 的「语义阶梯」段。
      if (this.setList.bottomText != null && this.setList.bottomText.length > 0){
        Column(){
          Text(this.setList.value).fontSize(FontConstants.ITEM).margin({bottom:10}).width('100%')
          Text(this.setList.bottomText).fontSize(FontConstants.CAPTION).fontColor($r('app.color.text_tertiary')).width('100%')
        }.width('75%')

      }else {
        Text(this.setList.value).fontSize(FontConstants.ITEM).id('text')
      }



      Row(){
        // VIP 金标（2026-10-08）：防窥两层开关为会员特权。用户明确"与阅读页的做法不一样"
        //   —— 阅读页只在未开通时显示，这里**常驻**标记。
        // 配色取自阅读页顶栏同款（ReaderPage3.ets 的 VIP 金标）。
        if (this.setList.vipMark === true){
          Text('VIP')
            .fontSize(9)
            .fontWeight(600)
            .fontColor('#B8860B')
            .backgroundColor('rgba(255, 215, 0, 0.28)')
            .padding({ left: 4, right: 4, top: 1, bottom: 1 })
            .borderRadius(4)
            .margin({ right: 6 })
        }

        if (this.setList.rightText != null && this.setList.rightText.length > 0){
          // 2026-10-19 用户需求：「这种点击开关，增加下划线，确保用户看到之后知道还能点击」。
          // 只给**多档值行**（`hideControl === true`，右侧既无箭头也无 Toggle）加下划线 ——
          // 普通开关行的右侧文字（如滑块当前值）不加，避免误以为可点。
          Text(this.setList.rightText)
            .fontSize(FontConstants.CAPTION)
            .fontColor($r('app.color.text_tertiary'))
            .decoration({
              type: this.setList.hideControl === true ? TextDecorationType.Underline : TextDecorationType.None,
              color: $r('app.color.text_tertiary')
            })
        }

        if (this.setList.showArrow){
          // 箭头行 = 可点进去/可点换值；`hideControl` 的值行（多档设置，如「时间显示」）不画箭头
          // （2026-10-19：`hideControl` 见 `SetListGroup.SetList`）。
          // ── 2026-10-13 修「暗色下箭头是黑的」（用户实测反馈）────────────────────
          // 旧实现：`Image($r("app.media.right")).size({width:25,height:25})`。
          // 实测那张资源是**纯黑 PNG**（72×72，取样像素 `#000000` / alpha 224 ≈ 0.88）——
          // 位图的像素颜色烧死在文件里，`fillColor` / 主题色 / 深浅色**都改不动它**
          // ⇒ 深色底上就是一条看不见的黑箭头。
          // 现在改成文字型 `SymbolGlyph`：颜色完全由 `fontColor` 决定，
          // 日/夜跟随 `ShelfColors.icon()`（日 `rgba(19,19,19,0.88)` / 夜 `rgba(248,249,250,0.88)`），
          // 与全工程"图标一律 SymbolGlyph + ShelfColors"的口径一致
          // （同类历史修复见 `readStatistics.ets` 的返回箭头）。
          // 字号取 15：原 PNG 里箭头实际绘制区只有 19×30 px（画布 72），按 25vp 显示约 6.6×10.4vp
          // ⇒ 15 号 chevron 的观感最接近原样。
          SymbolGlyph($r('sys.symbol.chevron_forward'))
            .fontSize(15)
            .fontColor([ShelfColors.icon()])
        }else if (this.setList.hideControl !== true) {
          Toggle({ type: ToggleType.Switch, isOn: this.setList.toggleStatus})
            .selectedColor("#F60").hoverEffect(HoverEffect.None)
            // 整行置灰时开关不可点（2026-10-08：智控键在本机不支持）
            .enabled(this.setList.disabled !== true)
            // 沉浸光感（2026-09-21）。官方 `…/组件适配沉浸光感/…`「开关（Toggle）」原文：
            //   「组件级开启：开关支持通过 systemMaterial 属性设置沉浸光感效果。」
            //   「ToggleType.Switch：传入的材质参数**仅作为开启沉浸光感的开关标记**，
            //     不影响实际视觉效果，实际使用组件内部预设的视觉参数，主要影响滑块大小、
            //     滑块样式、阴影等；材质效果随设备算力档位变化。」
            // 所以这里传什么样式不影响观感，但仍按"选择类用薄材质 + 交互反馈"的官方建议走
            // `controlMaterial()`，方便以后统调。关闭 = `ImmersiveMaterialUtil.ENABLED = false`。
            //
            // ⚠️ 这条通用属性的 SDK 原文还提醒：
            //   「You are advised **not to use this API together with** the aforementioned APIs
            //     [backgroundColor, borderColor, borderWidth, shadow]」
            // ⇒ 这里只保留 Toggle 专属的 `selectedColor`，没有再叠加那四个通用属性。
            // ⚠️ 2026-10-23 向下兼容鸿蒙6（API 20）：**不要用 `.systemMaterial(...)`**。
            //   它是 **API 26.0.0** 才有（SDK `…\ets\component\common.d.ts:22642`
            //   `systemMaterial(material: SystemUiMaterial | undefined): T;` `@since 26.0.0`），
            //   声明式语法编译成裸调用 `Toggle.systemMaterial(...)`
            //   ⇒ 鸿蒙6 上 `undefined is not callable` ⇒ 设置页闪退。
            //   改走 `AttributeModifier` 回调通道，低版本挂空实现（开关退回普通样式）。
            .attributeModifier(ImmersiveMaterialUtil.toggleMaterialModifier())
        }
      }.alignItems(VerticalAlign.Center)


    }.width("100%")
    .backgroundColor(ShelfColors.surface())
    .backgroundBlurStyle(BlurStyle.COMPONENT_REGULAR, { colorMode: ThemeColorMode.SYSTEM })
    .padding({
      // 子项缩进（2026-10-19 新增）：`indent = true` 时左侧再多 20vp，
      // 视觉上等于"标题开头空两格"（父项「显示阅读器信息窗」下面的元素子项用）。
      left: this.setList.indent === true ? 40 : 20,
      right: 20,
      top: 12,
      bottom: 12
    })
    .justifyContent(FlexAlign.SpaceBetween)
    .alignItems(VerticalAlign.Center)
    // 置灰（2026-10-08）：整行降透明度，配合 Toggle.enabled(false)；
    // 点击数由页面 `itemOnclick` 自行拦截（本组件不持有回调）。
    .opacity(this.setList.disabled === true ? 0.45 : 1)
    .borderRadius({topLeft:this.topLeft,topRight:this.topRight,bottomLeft:this.bottomLeft,bottomRight:this.bottomRight})
    .onChildTouchTest((touchinfo) => {//将事件交给text处理，text不处理将由自己处理
      return { id:'text',strategy: TouchTestStrategy.FORWARD }
    })
  }
}