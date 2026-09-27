import { pickerAvatar } from '../../../../../common/utils/photoViewPicker'
import { Haptics } from '../../../../../common/utils/Haptics';
import { NightMode } from '../../../../../common/utils/NightMode'
import coverInfoImageShow from '../../../coverInfoImageShow'
import { BookGroups } from '../../../../../database/entities/BookGroups'
import { showMessage } from '../../../../../componets/common/promptShow'
import buttonCommon from '../../../../../componets/common/buttonCommon'
import bookGroupUtil from '../../../../../common/utils/bookGroupUtils'
import { ThemeItem } from '../../../../../common/model/Theme'
import { ThemeStorageKey } from '../../../../../common/constants/Theme'
import { MaterialColumnModifier } from '../../../../../common/utils/ImmersiveMaterialUtil'

@CustomDialog
/**
 * 封面弹窗
 */
@Preview
export default struct coverInfoDialog{
  controller?: CustomDialogController

  /**
   * 弹窗背板（2026-09-21 接入沉浸光感）。底部面板、高度不大，
   * 不属官方点名的「接近全屏的超大面积」。用修饰器的原因见
   * `MaterialColumnModifier` 注释 —— 这行白底会把 Dialog 的**自动沉浸**挡掉。
   */
  private surface: MaterialColumnModifier = new MaterialColumnModifier(Color.White)
  //推送提醒
  @Prop itemData:BookGroups
  @State coverImages:string = ''
  @StorageLink('BOOK_IS_BOOK_GROUPS_REFRESHING') BOOK_IS_BOOK_GROUPS_REFRESHING: number = 0
  cancel: () => void = () => {
  }
  aboutToAppear(): void {
    this.coverImages = this.itemData.coverUrl??''
  }
  @State coverFolder:boolean = false
  // 主题颜色
  @StorageProp(ThemeStorageKey.THEME) theme: ThemeItem = {} as ThemeItem
  build() {
    Column(){
      Flex({
        justifyContent:FlexAlign.SpaceBetween,
        alignItems:ItemAlign.Center
      }){
        Column(){
          Text(this.itemData.groupName).fontColor(NightMode.isDarkSurface() ? 'rgba(248, 249, 250, 0.88)' : 'rgba(0, 0, 0, 0.88)').fontSize(16).fontWeight(500).lineHeight(24)
          Text(`共${0}本`).fontColor(NightMode.isDarkSurface() ? 'rgba(248, 249, 250, 0.45)' : 'rgba(0, 0, 0, 0.45)').fontWeight(400).lineHeight(20).fontSize(12)
        }
        Row(){
          Text('仅用于当前分组')
          Toggle({ type: ToggleType.Switch, isOn: this.itemData.coverOnly})
            .selectedColor("#F60").hoverEffect(HoverEffect.None)
            .onChange((val)=>{
              Haptics.tap();
              this.itemData.coverOnly = val
            })
        }
      }.padding(20)
      Divider().strokeWidth(0.5)
      Flex({
        direction: FlexDirection.Row,
        justifyContent:FlexAlign.SpaceBetween
      }){
        coverInfoImageShow({
          coverCount:1,
          image:this.itemData.coverUrl,
          selectImage:this.itemData.coverType??0,
          onSelectImageNumber:(number:number)=>{
            this.itemData.coverType = number
          }
        })
        coverInfoImageShow({
          coverCount:2,
          imageString:this.coverImages,
          selectImage:this.itemData.coverType??0,
          onSelectImageNumber:(number:number)=>{
            this.itemData.coverType = number
          }
        }).onClick(()=>{
          Haptics.tap();
          this.setCoverImages()
        })
        coverInfoImageShow({
          coverCount:3,
          imageString:this.coverImages,
          selectImage:this.itemData.coverType??0,
          onSelectImageNumber:(number:number)=>{
            this.itemData.coverType = number
          }
        }).onClick(()=>{
          Haptics.tap();
          this.setCoverImages()
        })
      }.padding(20)
      Divider().strokeWidth(0.5).padding({bottom:16})
      Column(){
        Flex({
          justifyContent:FlexAlign.SpaceBetween
        }) {
          Column(){
            Text('取消').fontSize(16).fontWeight(400).fontColor(this.theme.mainColor)
              .lineHeight(24)
              .padding({left:32,right:32,bottom:8,top:8})
          }
          .onClick(()=>{
            Haptics.tap();
            this.cancel()
          })
          .width('49%')
          .borderRadius(20)
          .alignItems(HorizontalAlign.Center)
          .backgroundColor(this.theme.secondColor)
          Column(){
            Text('确定')
              .fontSize(16)
              .fontWeight(400)
              .fontColor(Color.White)
              .lineHeight(24)
              .padding({left:32,right:32,bottom:8,top:8})
              .onClick(async ()=>{
                bookGroupUtil.updatePartialGroup(this.itemData)
                setTimeout(()=>{
                  this.BOOK_IS_BOOK_GROUPS_REFRESHING++
                  this.controller?.close()
                  showMessage('修改成功!')
                },100)
              })
          }
          .width('49%')
          .borderRadius(20)
          .alignItems(HorizontalAlign.Center)
          .backgroundColor(this.theme.mainColor)
        }
      }
      .alignItems(HorizontalAlign.Center)
      .padding({right:20,left:20,bottom:16})
    }
    .borderRadius({topLeft:20,topRight:20})
    .attributeModifier(this.surface)
    .width('100%')
  }

  async setCoverImages(){
    // T13/D-18（Round 38）：`pickerAvatar()` 的返回契约从「整个 PhotoSelectResult」收敛为「URI 列表」，
    // 这样新旧两条实现才能共用同一签名（两者的 Result 类型不同、不可互相赋值）。
    // 行为与旧代码 `imageUrl?.photoUris[0] || ''` 完全等价：未选择 → `''`（即清空封面）。
    const uris: string[] = await pickerAvatar();
    this.coverImages = uris.length > 0 ? uris[0] : '';
    this.itemData.coverUrl = this.coverImages
  }
}