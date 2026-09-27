import CommonConstants from '../../common/constants/CommonConstants'
import { Haptics } from '../../common/utils/Haptics';
import { dataItem } from '../dataList/dataItem'
import { NightMode, ShelfColors } from '../../common/utils/NightMode'

@Component
export struct readTabs{
  /** App 级深浅色：订阅只为深浅切换时触发重绘（取色走 `ShelfColors`） */
  @StorageLink(NightMode.KEY) nightOn: boolean = false


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
        .width("33%")
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
        }).size({width:"33%",height:30})
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
