import { ThemeColor, ThemeStorageKey } from '../../../common/constants/Theme'
import { Haptics } from '../../../common/utils/Haptics';
import { ThemeItem } from '../../../common/model/Theme'
import { themeManager } from '../../../common/utils/ThemeManager'
import { JSON } from '@kit.ArkTS'

// 个性主题组件模块
@Component
export struct MyThemeConfigComp {
  @StorageProp(ThemeStorageKey.THEMEINDEX)
  activeIndex: number = 0 // 被选中的主题
  @State longPressGestureIndex: number = 0 // 长按选中主题

  @StorageProp(ThemeStorageKey.THEMELIST)
  themeList: ThemeItem[] = []

  // 主题颜色
  @StorageProp(ThemeStorageKey.THEME) theme: ThemeItem = {} as ThemeItem

  dialog: CustomDialogController = new CustomDialogController({
    builder: this.dialogBuilder,
    customStyle: true,
    alignment: DialogAlignment.Center,
    autoCancel: false
  })

  // 构建自定义弹窗
  @Builder
  dialogBuilder() {
    Column({space: 24}) {
      Text('确定要删除吗？')
        .fontSize(18)
        .fontWeight(FontWeight.Bold)

      Row({space: 12}) {
        Button('取消')
          .fontSize(14)
          .fontColor(this.theme.mainColor)
          .backgroundColor(this.theme.secondColor)
          .onClick(() => {
            Haptics.tap();
            this.dialog.close()
          })
          .width(112)
          .height(38)
        Button('确定')
          .fontSize(14)
          .fontColor(Color.White)
          .backgroundColor(this.theme.mainColor)
          .onClick(() => {
            Haptics.tap();
            if (this.themeList.length > 1) {
              themeManager.deleteTheme(this.longPressGestureIndex)
            } else {
              // T13/D-17（Round 37）：@useinstead ohos.arkui.UIContext.PromptAction#showToast
              this.getUIContext().getPromptAction().showToast({message: "删除失败，至少需要保留一个主题"})
            }
            this.dialog.close()
          })
          .width(112)
          .height(38)
      }
      .justifyContent(FlexAlign.Center)

    }
    .padding(24)
    .width(284)
    .height(136)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .backgroundColor($r('app.color.card_bg'))
    .borderRadius(32)
  }

  // 构建个性主题下列表元素
  @Builder
  themeItemBuilder(item: ThemeItem, index: number) {
    Column({space: 8}) {
      Column() {
        if (this.activeIndex == index) {
          Text('使用中')
            .fontSize(9)
            .fontColor('#fff')
            .backgroundColor('#ef4444')
            .textAlign(TextAlign.Center)
            .lineHeight(14)
            .width(39)
            .height(14)
            .borderRadius({
              topRight: 8,
              bottomLeft: 8
            })
            .position({right: 0, top: 0})
        }
      }
      .width('100%')
      .height(77)
      .borderRadius(8)
      .backgroundColor(item.mainColor)

      Text(item.text)
        .fontSize(14)
        .height(22)
        .lineHeight(22)
        .width('100%')
    }
    .width('100%')
    .height(107)
  }

  build() {
    Column() {
      Grid() {
        // 2026-09-25 用户要求：「自定义主题（直接删除）」—— 入口整块移除。
        ForEach(this.themeList, (item: ThemeItem, index) => {
          GridItem() {
            this.themeItemBuilder(item, index)
          }
          .onClick(() => {
            Haptics.tap();
            this.activeIndex = index
            themeManager.setTheme(this.themeList[index], index)
          })
          .gesture(
            LongPressGesture()
              .onAction(() => {
                Haptics.tap();
                this.dialog.open()
                this.longPressGestureIndex = index
              })
          )
        })
      }
      .columnsTemplate('1fr 1fr')
      .columnsGap(12)
      .rowsGap(12)
      // 2026-09-25 用户要求：两侧收紧，与上面三段开关同 90% 宽
      .width('90%')
      .height('100%')
    }
    .width('100%')
    .height('100%')
  }
}