import { ThemeStorageKey } from "../../common/constants/Theme"
import { Haptics } from '../../common/utils/Haptics'
import { ThemeItem } from "../../common/model/Theme"
import { NightMode } from "../../common/utils/NightMode"

/**
 * 自定义标题和内容弹窗
 * title标题、content内容、confirm确认按钮、cancel取消按钮
 */
@CustomDialog
export default struct TitleContentDialog {

  controller?: CustomDialogController

  cancel: () => void = () => {
  }
  confirm: () => void = () => {
  }
  @Prop title:string = ''
  @Prop content:string = ''
  // 主题颜色
  @StorageProp(ThemeStorageKey.THEME) theme: ThemeItem = {} as ThemeItem

  build() {
    Column() {
      Text(`确定${this.title}吗？` ).fontWeight(600).maxLines(1).minFontSize(12).maxFontSize(20).margin({ top: 20, bottom: 10 })
      if (this.content.length > 0){
        Row({
          space:8
        }){
          Text(this.content)
            .width('70%')
            // 2026-10-01 夜间适配（用户反馈"内容字体在夜间模式下还是黑色"）：
            // 原来写死 rgba(0,0,0,0.45)，夜间沉浸光感材质上不可读。
            // 取色走 NightMode.isDarkSurface()（与本工程其它弹窗文案同一套）。
            .fontColor(NightMode.isDarkSurface() ? 'rgba(248, 249, 250, 0.65)' : 'rgba(0, 0, 0, 0.45)')
            .fontSize(14).fontWeight(400).lineHeight(22).textAlign(TextAlign.Center)
        }
      }
      Row({space:24}) {
        Text('取消')
          .onClick(() => {
            Haptics.tap();
            if (this.controller != undefined) {
              this.controller.close()
              this.cancel()
            }
          })
          .borderRadius(15)
          .padding({left:30,right:30,top:10,bottom:10})
          .fontColor(this.theme.mainColor)
          .backgroundColor(this.theme.secondColor)
        Text('确认')
          .onClick(() => {
            Haptics.tap();
            if (this.controller != undefined) {
              this.controller.close()
              this.confirm()
            }
          })
          .borderRadius(15)
          .padding({left:30,right:30,top:10,bottom:10})
          .fontColor(Color.White)
          .backgroundColor(this.theme.mainColor)
      }.padding({top:20,bottom:20})
    }
  }
}