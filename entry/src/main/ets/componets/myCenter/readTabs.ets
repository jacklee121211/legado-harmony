import CommonConstants from '../../common/constants/CommonConstants'
import { Haptics } from '../../common/utils/Haptics';
import { dataItem } from '../dataList/dataItem'
import { NightMode, ShelfColors } from '../../common/utils/NightMode'

@Component
export struct readTabs{
  /** App 级深浅色：订阅只为深浅切换时触发重绘（取色走 `ShelfColors`） */
  @StorageLink(NightMode.KEY) nightOn: boolean = false

  /**
   * 页签切换回调（2026-09-29 新增，审核问题⑤「读过/读完筛选无效果」）。
   * 旧实现的选中态是组件内部 `@State read_index`，切换**只动滑块、不上报**，
   * 父页面无从得知 ⇒ 列表永远是全量。现在把新下标交回父页面去做过滤。
   *
   * 2026-10-11：分类页签只剩「书架」一个（漫画/有声书入口已删）⇒ 下标恒为 0，
   * 回调保留（父页面仍用它同步 `typeIndex`）。
   */
  onIndexChange: (index: number) => void = (_index: number): void => {}

  /**
   * 单个页签 / 滑块的宽度。
   *
   * ⚠️ 原实现写死 `"33%"`（恒按 3 个页签算）⇒ 页签只剩 1 个时，高亮块只占左侧 1/3，
   *    看起来像"坏掉的选择器"。改为按 `read_list` 实际数量取 `100/n %`。
   *    （ArkUI 的 `width` 接受百分比字符串，见 `read_builder()` 的 `.width()`。）
   */
  private itemWidth(): string {
    const n: number = this.read_list.length
    return n > 0 ? `${100 / n}%` : '100%'
  }

  @Prop read_list:dataItem[]
  @State read_index:number=0
  @State translateNum:number=0
  @State translateX:number=120
  @Builder read_builder(){
    Row(){
      ForEach(this.read_list,(item:dataItem,index:number)=>{
        Row(){
          Text(item.title)
        }.backgroundColor("rgba(0, 0, 0, 0)")
        .justifyContent(FlexAlign.Center)
        .width(this.itemWidth())
        .onClick((event)=>{
          Haptics.tap();
          let x=event.target.area.position.x?.toString()
          if( this.read_index>index){
            if(x!=undefined){
              this.translateNum-=parseInt(x)
            }
            if(index==0){
              this.translateNum=0
            }
          }else if( this.read_index<index){
            if(x!=undefined){
              this.translateNum=parseInt(x)
            }
          }
          this.read_index=index
          this.onIndexChange(index)
        })
      }, (item: dataItem): string => item.title)
    }.height(30)
    .width(CommonConstants.FULL_HEIGHT)
  }
  build() {
    Row(){
      Row()
        .backgroundColor(ShelfColors.card())
        .stateStyles({
          normal:this.readListStyles
        }).size({width:this.itemWidth(),height:30})
        .translate({x:this.translateNum,y: 0,z: 0})
        .animation({
          duration:200,
          curve:Curve.Linear
        })
    }.overlay(this.read_builder(), {
      align: Alignment.Center,
      offset: { x: 0, y:0}
    })
    .width(CommonConstants.FULL_HEIGHT)
    .backgroundColor(ShelfColors.chip())
    .stateStyles({
      normal:this.readListStyles
    })
    .padding(3)
    .margin({top:12,bottom:12})
  }

  @Styles readListStyles(){
    .height(32)
    .borderRadius(30)
  }
}
