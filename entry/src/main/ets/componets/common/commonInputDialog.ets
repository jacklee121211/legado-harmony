/**
 * 通用单窗口输入弹窗
 * 主要传值为title标题、textValue输入框值、cancel取消方法、confirm确认方法
 */
import PaddingConstants from '../../common/constants/PaddingConstants'
import { ThemeStorageKey } from '../../common/constants/Theme'
import { ThemeItem } from '../../common/model/Theme'
import { showMessage } from './promptShow'
import { MaterialColumnModifier } from '../../common/utils/ImmersiveMaterialUtil'

@CustomDialog
export default struct commonInputDialog {

  controller?: CustomDialogController

  /**
   * 弹窗背板（2026-09-21 接入沉浸光感）。本弹窗是小尺寸输入框，
   * 属官方"合理尺寸"范围。用修饰器而不是 `.backgroundColor(Color.White)` 的原因见
   * `MaterialColumnModifier` 注释：官方原文「已主动设置背景色…则不呈现沉浸光感效果」，
   * 而系统在 default 模式下**本来就会**给 Dialog 自动开沉浸光感 —— 是我们这行白底把它挡住的。
   * 关闭（回退）时自动落回白色。
   */
  private surface: MaterialColumnModifier = new MaterialColumnModifier(Color.White)

  cancel: () => void = () => {
  }
  confirm: () => void = () => {
  }
  //输入框内容长度
  @State ValueLength:number = 0
  //标题
  @Prop title:string = '新增'
  // @Prop titleWidth:string = '80%'
  // 主题颜色
  @StorageProp(ThemeStorageKey.THEME) theme: ThemeItem = {} as ThemeItem
  build() {
    Column() {
      Text(`${this.title}` ).fontWeight(600).fontSize(20).margin({ top: 20, bottom: 10 })
      this.input()
      Row({space:24}) {
        Text('取消')
          .onClick(() => {
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
            if (this.controller != undefined) {
              this.confirm()
              this.controller.close()
            }
          })
          .borderRadius(15)
          .padding({left:30,right:30,top:10,bottom:10})
          .fontColor(Color.White)
          .backgroundColor(this.theme.mainColor)
      }.padding({top:PaddingConstants.PADDING_20,bottom:PaddingConstants.PADDING_20})
    }
    .padding({left:PaddingConstants.PADDING_20,right:PaddingConstants.PADDING_20})
    .attributeModifier(this.surface)
  }
  //输入框提示
  @Prop placeholder:string = '请输入内容'
  //输入框值
  @Link textValue:string
  //默认可输入20长度
  @Prop maxLength:number = 20
  //是否显示统计
  @Prop isShowCount:boolean = false
  @Builder input(){
    Row(){
      TextInput({ placeholder: this.placeholder, text: this.textValue })
        .cancelButton({icon:{src:$r('app.media.clear')}})
        .height(40)
        .onChange((value: string) => {
          this.ValueLength = value.length
          if(this.maxLength === value.length){
            showMessage(`超出输入范围,最长可输入${this.maxLength}字符`)
          }
          this.textValue = value
        })
        .maxLength(this.maxLength)
      if (this.isShowCount && this.maxLength - this.ValueLength !== 0){
      Row(){
          Text(JSON.stringify(this.maxLength - this.ValueLength)).fontSize(10).fontWeight(600).fontColor(this.maxLength - this.ValueLength ===0?Color.Red:'')
          Text('/').fontSize(10).fontWeight(600).fontColor(10 - this.ValueLength ===0?Color.Red:'')
          Text(JSON.stringify(this.maxLength)).fontSize(10).fontWeight(600).fontColor(10 - this.ValueLength ===0?Color.Red:'')
      }.offset({x:this.ValueLength>0?-70:-40})
      }

    }
    .alignItems(VerticalAlign.Center)
  }
}