import { ThemeStorageKey } from "../../common/constants/Theme"
import { ThemeItem } from "../../common/model/Theme"
import { MaterialColumnModifier } from "../../common/utils/ImmersiveMaterialUtil"
import { NightMode } from "../../common/utils/NightMode"
import { Haptics } from "../../common/utils/Haptics"


@CustomDialog
export struct serviceDialog{

  controller?: CustomDialogController
  // 若尝试在CustomDialog中传入多个其他的Controller，以实现在CustomDialog中打开另一个或另一些CustomDialog，那么此处需要将指向自己的controller放在所有controller的后面
  cancel: () => void = () => {
  }
  confirm: () => void = () => {
  }

  @Prop title:string = ''
  @Prop value:string=""
  @Prop type:string="text"

  /**
   * 弹窗背板（2026-09-21 接入沉浸光感）。
   * 本弹窗尺寸 `width(270)` × 约 150 高，属于官方"合理尺寸"范围
   * （官方功耗文档正例 328×216、反例 100%×100%）⇒ 适合开材质。
   * 为什么用修饰器而不是直接写 `.backgroundColor(...)`：见 `MaterialColumnModifier` 注释
   * ——「已主动设置背景色」会**屏蔽**材质效果，连透明色也算。
   * 关闭（回退）时自动落回原来的白色背景。
   */
  private surface: MaterialColumnModifier = new MaterialColumnModifier(NightMode.isDarkSurface() ? "#26262A" : "rgba(255, 255, 255, 1)")
  @Builder button(title:string,color:Array<ResourceStr|Color>,confirm: () => void){
    Text(title)
      .onClick(() => {
        Haptics.tap();
        if (this.controller != undefined) {
          this.controller.close()
          confirm();
        }
      })
      .borderRadius(40)
      .padding({left:30,right:30,top:10,bottom:10})
      .fontColor(color[0])
      .backgroundColor(color[1])
  }
  // 主题颜色
  @StorageProp(ThemeStorageKey.THEME) theme: ThemeItem = {} as ThemeItem

  build() {
    Column({space:15}) {
      Text(this.title)
        .fontWeight(600)
        .fontSize(16)
      if(this.type=="text"){
        Text(this.value)
          .fontWeight(600)
          .fontSize(14)
          .size({width:"80%"})
          .fontColor(NightMode.isDarkSurface() ? "rgba(248, 249, 250, 0.62)" : "rgba(0, 0, 0, 0.45)")
          .textAlign(TextAlign.Center)
          .lineHeight(25)
      }
      Row({space:24}) {
        this.button("取消",[this.theme.mainColor, this.theme.secondColor],this.cancel)
        this.button("确定",[Color.White,this.theme.mainColor],this.confirm)
      }.padding({top:10})
    }.padding({top:20,bottom:20})
    .width(270)
    // 背板：开启沉浸光感时由系统材质接管（**不能**再写 backgroundColor，会屏蔽材质）；
    // 关闭时由修饰器回落到原来的白色。详见 MaterialColumnModifier 的注释。
    .attributeModifier(this.surface)
    .borderRadius(15)
  }
}