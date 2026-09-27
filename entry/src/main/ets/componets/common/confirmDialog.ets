import { ThemeStorageKey } from "../../common/constants/Theme"
import { ThemeItem } from "../../common/model/Theme"
import { Haptics } from "../../common/utils/Haptics"

@CustomDialog
export default struct confirmDialogExample {

  controller?: CustomDialogController
  // 若尝试在CustomDialog中传入多个其他的Controller，以实现在CustomDialog中打开另一个或另一些CustomDialog，那么此处需要将指向自己的controller放在所有controller的后面
  cancel: () => void = () => {
  }
  confirm: () => void = () => {
  }
  @Prop title:string = '删除'
  @Link delCache:boolean
  @Prop isShowCache:boolean = false
  // 主题颜色
  @StorageProp(ThemeStorageKey.THEME) theme: ThemeItem = {} as ThemeItem

  build() {
    Column() {
      Text(`确定${this.title}吗？` ).fontWeight(600).maxLines(1).minFontSize(12).maxFontSize(20).margin({ top: 20, bottom: 10 })
      if (this.isShowCache){
        Row({
          space:8
        }){
          Checkbox().selectedColor(this.theme.mainColor).select(this.delCache)
            .onChange((value: boolean) => {
              Haptics.tap();
              this.delCache = value
            })
          Text('同时删除本地缓存')
            .fontColor($r('app.color.text_secondary')).fontSize(14).fontWeight(400).lineHeight(22)
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