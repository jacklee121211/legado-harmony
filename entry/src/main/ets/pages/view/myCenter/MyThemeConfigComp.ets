import { ThemeColor, ThemeStorageKey } from '../../../common/constants/Theme'
import { Haptics } from '../../../common/utils/Haptics';
import { ThemeItem } from '../../../common/model/Theme'
import { themeManager } from '../../../common/utils/ThemeManager'
import { JSON } from '@kit.ArkTS'
import { VipManager } from '../../../common/utils/VipManager'
import { VipDialog } from '../../../componets/myCenter/VipDialog'
import ThemeCustomEditorDialog from './ThemeCustomEditorDialog'
import ImmersiveMaterialUtil from '../../../common/utils/ImmersiveMaterialUtil'
import UiMotion from '../../../common/utils/UiMotion'
import { NightMode } from '../../../common/utils/NightMode'
// ── 个性化插件屏（2026-10-10 新增）───────────────────────────────────────────
import { PlugboardConfigDialog } from '../../../componets/plugboard/PlugboardConfigDialog'

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

  /**
   * 「自定义主题」编辑弹窗（2026-10-01 复活：取色器 + RGB + 方案管理，**VIP 特权**）。
   * 打开时新建 controller（规范：参数动态/统一范式；见 docs/标准-弹窗与按钮统一规范.md）。
   */
  private themeEditorDialog: CustomDialogController | null = null
  /** 「VIP 购买」弹窗（嵌套打开，与 ReaderFontDialog.openVip 同款） */
  private vipDialog: CustomDialogController | null = null

  /** 个性化配置弹窗（2026-10-10 新增） */
  private plugboardDialog: CustomDialogController | null = null

  private openPlugboard(): void {
    this.plugboardDialog = new CustomDialogController({
      builder: PlugboardConfigDialog({
        onClose: (): void => {
          this.plugboardDialog = null
        }
      }),
      autoCancel: true,
      alignment: DialogAlignment.Bottom,
      // 2026-10-10 改造：按 docs/标准-弹窗与按钮统一规范.md 套规范
      //  - 材质生效的必要条件：customStyle: false
      //  - systemMaterial 必须是 ImmersiveMaterialUtil.sheetMaterial()
      //  - 短确认/输入类：不给 height（自适应）
      width: '94%',
      cornerRadius: 24,
      customStyle: false,
      systemMaterial: ImmersiveMaterialUtil.sheetMaterial(),
      openAnimation: UiMotion.motionParam(UiMotion.SPRING_FAST),
      closeAnimation: UiMotion.motionParam(UiMotion.SPRING_FAST),
      cancel: (): void => {
        this.plugboardDialog = null
      }
    })
    this.plugboardDialog?.open()
  }

  private openVip(): void {
    this.vipDialog = new CustomDialogController({
      builder: VipDialog({
        dark: NightMode.isDarkSurface(),
        vipOwned: VipManager.isVip(),
        onClose: (): void => {
          this.vipDialog?.close()
          this.vipDialog = null
        }
      }),
      autoCancel: true,
      alignment: DialogAlignment.Center,
      width: '88%',
      cornerRadius: 20,
      customStyle: false,
      systemMaterial: ImmersiveMaterialUtil.sheetMaterial(),
      openAnimation: UiMotion.motionParam(UiMotion.SPRING_FAST),
      closeAnimation: UiMotion.motionParam(UiMotion.SPRING_FAST),
      cancel: (): void => {
        this.vipDialog = null
      }
    })
    this.vipDialog?.open()
  }

  /** 自定义主题入口（VIP 门控范式与导入字体/下载字体一致：非 VIP → VIP 弹窗） */
  private openThemeEditor(): void {
    if (!VipManager.isVip()) {
      this.openVip()
      return
    }
    this.themeEditorDialog = new CustomDialogController({
      builder: ThemeCustomEditorDialog({
        onClose: (): void => {
          this.themeEditorDialog = null
        }
      }),
      autoCancel: true,
      alignment: DialogAlignment.Center,
      width: '88%',
      cornerRadius: 20,
      customStyle: false,
      systemMaterial: ImmersiveMaterialUtil.sheetMaterial(),
      openAnimation: UiMotion.motionParam(UiMotion.SPRING_FAST),
      closeAnimation: UiMotion.motionParam(UiMotion.SPRING_FAST),
      cancel: (): void => {
        this.themeEditorDialog = null
      }
    })
    this.themeEditorDialog?.open()
  }

  /** 「+ 自定义主题」入口瓦片（VIP 金标提示；样式与主题色板瓦片同构） */
  @Builder
  addThemeTile() {
    Column({ space: 8 }) {
      Column({ space: 4 }) {
        SymbolGlyph($r('sys.symbol.plus'))
          .fontSize(26)
          .fontColor([this.theme.mainColor])
        Text('自定义主题')
          .fontSize(11)
          .fontColor(this.theme.mainColor)
        Text('VIP')
          .fontSize(8)
          .fontColor('#B8860B')
          .backgroundColor('rgba(255, 215, 0, 0.28)')
          .padding({ left: 5, right: 5, top: 1, bottom: 1 })
          .borderRadius(4)
          .fontWeight(600)
      }
      .width('100%')
      .height(77)
      .justifyContent(FlexAlign.Center)
      .border({
        width: 1,
        color: 'rgba(0,0,0,0.15)',
        style: BorderStyle.Dashed,
        radius: 8
      })

      Text(' ')
        .fontSize(14)
        .height(22)
        .lineHeight(22)
        .width('100%')
    }
    .width('100%')
    .height(107)
  }

  /** 个性化配置入口瓦片（2026-10-10 新增） */
  @Builder
  plugboardTile() {
    Column({ space: 8 }) {
      Column({ space: 4 }) {
        SymbolGlyph($r('sys.symbol.rectangle_3_group'))
          .fontSize(26)
          .fontColor([this.theme.mainColor])
        Text('个性化')
          .fontSize(11)
          .fontColor(this.theme.mainColor)
        Text('插件屏')
          .fontSize(8)
          .fontColor('#888')
          .fontWeight(400)
      }
      .width('100%')
      .height(77)
      .justifyContent(FlexAlign.Center)
      .border({
        width: 1,
        color: 'rgba(0,0,0,0.15)',
        style: BorderStyle.Dashed,
        radius: 8
      })

      Text(' ')
        .fontSize(14)
        .height(22)
        .lineHeight(22)
        .width('100%')
    }
    .width('100%')
    .height(107)
  }

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
        // 2026-10-01：自定义主题入口复活（此前 2026-09-25 按用户要求删除的是旧无极版入口；
        // 现按新方案重建：取色器 + RGB + 方案管理 + VIP 门控）。置于首位。
        GridItem() {
          this.addThemeTile()
        }
        .onClick(() => {
          Haptics.tap();
          this.openThemeEditor()
        })

        // ── 个性化配置入口（2026-10-10 新增）─────────────────────────────────
        GridItem() {
          this.plugboardTile()
        }
        .onClick(() => {
          Haptics.tap();
          this.openPlugboard()
        })

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