import { SetList } from '../dataList/SetListGroup'
import ImmersiveMaterialUtil from '../../common/utils/ImmersiveMaterialUtil'
// 字号阶梯（唯一标准处，见其文件头「语义阶梯」段与 docs/标准-弹窗与按钮统一规范.md 第 6 节）
import FontConstants from '../../common/constants/FontConstants'

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
        if (this.setList.rightText != null && this.setList.rightText.length > 0){
          Text(this.setList.rightText).fontSize(FontConstants.CAPTION).fontColor($r('app.color.text_tertiary'))
        }

        if (this.setList.showArrow){
          Image($r("app.media.right")).size({width:25,height:25})
        }else {
          Toggle({ type: ToggleType.Switch, isOn: this.setList.toggleStatus})
            .selectedColor("#F60").hoverEffect(HoverEffect.None)
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
            .systemMaterial(ImmersiveMaterialUtil.controlMaterial())
        }
      }.alignItems(VerticalAlign.Center)


    }.width("100%")
    .backgroundColor($r('app.color.card_bg'))
    .padding({ left:20,right:20,top:12,bottom:12 })
    .justifyContent(FlexAlign.SpaceBetween)
    .alignItems(VerticalAlign.Center)
    .borderRadius({topLeft:this.topLeft,topRight:this.topRight,bottomLeft:this.bottomLeft,bottomRight:this.bottomRight})
    .onChildTouchTest((touchinfo) => {//将事件交给text处理，text不处理将由自己处理
      return { id:'text',strategy: TouchTestStrategy.FORWARD }
    })
  }
}