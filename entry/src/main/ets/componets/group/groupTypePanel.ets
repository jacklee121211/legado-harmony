import { ThemeStorageKey } from '../../common/constants/Theme'
import { Haptics } from '../../common/utils/Haptics';
import { ThemeItem } from '../../common/model/Theme'
import bookGroupUtil from '../../common/utils/bookGroupUtils'
import BookGroupsDao from '../../database/dao/BookGroupsDao'
import { BookGroups } from '../../database/entities/BookGroups'
import BookManageDialog from '../../pages/view/bookShelf/components/dialog/BookManageDialog'
import FolderInfoDialog from '../../pages/view/bookShelf/components/dialog/FolderInfoDialog'
import ImmersiveMaterialUtil, { MaterialColumnModifier } from '../../common/utils/ImmersiveMaterialUtil'
import { updateAppData } from '../../storage/appData'
import customizeDialogExample from '../common/customizeDialog'
import hideDialogExample from '../common/hideDialog'
import { showMessage } from '../common/promptShow'
import { NightMode } from '../../common/utils/NightMode'

@Component
export default struct groupTypePanel {
  /**
   * ⚠️ 2026-09-23：原来这里是 `@Link groupCoverShow: boolean`（面板直接把它置 false 来关自己）。
   * 现在本面板是 `@CustomDialog` 的**内容**（见 `GroupManageDialog.ets`），关窗必须走
   * `controller.close()`，所以改成**回调**，由调用方去关。
   */
  onClose: () => void = (): void => {}
  /**
   * 底色兜底 + 材质分支让位（工程既有实现，说明见 `ImmersiveMaterialUtil.ets:390-459`）。
   * · 材质可用 ⇒ 本方法**什么都不做**，背景由弹窗层（`systemMaterial`）画；
   * · 材质不可用 / 总开关关闭 ⇒ 落回 **白色实底**，绝不会"透明露底"。
   */
  private surface: MaterialColumnModifier = new MaterialColumnModifier(Color.White, true)
  @State isShowIcon: boolean = false
  @Prop showGroupList: BookGroups[] = []
  @State hideList: BookGroups[] = []
  @Prop currentIndex: number = 0
  @StorageProp('APP_INDEX_SCROLLABLE') APP_INDEX_SCROLLABLE: boolean = true
  @Prop clickGroup: BookGroups
  // 主题颜色
  @StorageProp(ThemeStorageKey.THEME) theme: ThemeItem = {} as ThemeItem
  /** App 级夜间开关：只为触发重绘（取色走下面的 `fgMain/fgSub/chipBg`），理由见 `IndexShelf` 同名字段 */
  @StorageLink(NightMode.KEY) nightOn: boolean = false

  /**
   * 主文字色 / 次级文字色 / 淡色块底 —— 夜间必须自己翻，否则是**黑字压深底**。
   *
   * 为什么不能靠 `$r('app.string.color_black_*')` 的 dark 限定词：本面板这两处用的是
   * **字面量** `rgba(0,0,0,…)`（不是资源），限定词目录管不到。
   * 本面板唯一的宿主是 `GroupManageDialog`（书架 → 分组管理）⇒ 恒属"书架深色档"，
   * 直接读全局夜间开关是安全的。
   */
  private fgMain(): string {
    return NightMode.isDarkSurface() ? 'rgba(248, 249, 250, 0.88)' : 'rgba(0, 0, 0, 0.88)';
  }

  private fgSub(): string {
    return NightMode.isDarkSurface() ? 'rgba(248, 249, 250, 0.45)' : 'rgba(0, 0, 0, 0.45)';
  }

  private chipBg(): string {
    return NightMode.isDarkSurface() ? 'rgba(255, 255, 255, 0.10)' : 'rgba(0, 0, 0, 0.04)';
  }

  aboutToAppear(): void {
    this.getGroupList()
  }

  getGroupList() {
    BookGroupsDao.searchHide({
      type: this.currentIndex,
      show: false
    }).then((val) => {
      this.hideList = val
    })
  }

  build() {
    Column({
      space: 15
    }) {
      Flex({
        justifyContent: FlexAlign.SpaceBetween,
        alignItems: ItemAlign.End
      }) {
        Row({ space: 12 }) {
          Text('显示分组').fontSize(16).fontWeight(500).lineHeight(24).fontColor(this.fgMain())
          Text('点击进入').fontSize(12).fontWeight(400).lineHeight(20).fontColor(this.fgSub())
        }.alignItems(VerticalAlign.Bottom)

        Row({ space: 12 }) {
          Text(this.isShowIcon ? '完成' : '管理')
            .fontSize(12)
            .fontWeight(400)
            .lineHeight(20)
            .fontColor(this.theme.mainColor)
            .onClick(() => {
              Haptics.tap();
              this.isShowIcon = !this.isShowIcon
            })
          // v3.20：关闭 X 换 SymbolGlyph + 主题色——原 `app.media.close` 位图为固定深色，
          // 深色模式下不可观测（用户反馈）。`xmark` 经 SDK 符号表核实存在。
          SymbolGlyph($r('sys.symbol.xmark'))
            .fontSize(20)
            .fontColor([this.theme.mainColor])
            .onClick(() => {
              Haptics.tap();
              this.onClose()
              this.isShowIcon = false
            })
        }
      }

      Flex({
        direction: FlexDirection.Row, wrap: FlexWrap.Wrap,
        justifyContent: FlexAlign.Start
      }) {
        ForEach(this.showGroupList, (item: BookGroups, index: number) => {
          if (item.show) {
            Row() {
              if (index === 0) {
                this.GroupTypeColor(item.groupName)
              } else {
                this.GroupType(item.groupName)
              }
              if (this.isShowIcon) {
                Image(!item.isSystem ? $r('app.media.clear') : $r('app.media.sort'))
                  .width(12)
                  .height(12)
                  .offset({ x: -20, y: -20 })
                  .onClick(() => {
                    Haptics.tap();
                    if (!item.isSystem && item.groupId) {
                      this.isHide = true
                      this.checkListNumber = item.groupId
                      this.clickHideDialog?.open()
                    }
                  })
              }
            }
            .width('25%')
            .onTouch((event: TouchEvent) => {
              if (event.type === TouchType.Down) {
                this.dragIndex = index // 获取当前拖拽子组件的索引
                // T10-3（Round 29）：官方规则 `@performance/high-frequency-log-check`
                // 「不建议在高频函数中使用 Hilog。高频函数包括：onTouch、onItemDragMove、onDragMove、
                //   onMouse、onVisibleAreaChange、onAreaChange、onScroll（已废弃）、onWillScroll」。
                // 原 `console.info('onTouch' + this.dragIndex)` 为调试日志（无字段前缀、无诊断用途），已删除。
              }
            })
            .draggable(this.isShowIcon)
            .onDragStart(() => {
              console.log('onDragStart')
            })
            .onDrop((event: DragEvent, extraParams: string) => {
              console.log('onDrop')
              this.changeIndex(this.dragIndex, index, 0)
            })
            .onClick(() => {
              Haptics.tap();
              this.clickGroup = item
              this.isShowBookFolderInfoDialog = true
            })
          }
        }, (item: BookGroups): string => item.groupId !== undefined ? 'g' + item.groupId : item.groupName)
      }

      Flex({
        justifyContent: FlexAlign.SpaceBetween,
        alignItems: ItemAlign.End
      }) {
        Row({ space: 12 }) {
          Text('隐藏分组').fontSize(16).fontWeight(500).lineHeight(24).fontColor(this.fgMain())
          Text('点击进入,长按编辑').fontSize(12).fontWeight(400).lineHeight(20).fontColor(this.fgSub())
        }.alignItems(VerticalAlign.Bottom)

        Row({ space: 8 }) {
          Image($r('app.media.help')).width(20).height(20).onClick(() => {
            Haptics.tap();
            this.tagLockDialog?.open()
          })
          Text('标签锁').fontSize(16).fontWeight(500).lineHeight(24).fontColor(this.fgSub())
          Toggle({ type: ToggleType.Switch, isOn: $$this.APP_INDEX_SCROLLABLE })
            .selectedColor(this.theme.mainColor).hoverEffect(HoverEffect.None)
            .onChange(() => {
              updateAppData(this.APP_INDEX_SCROLLABLE)
              showMessage(this.APP_INDEX_SCROLLABLE ? '标签栏锁已开启' : '标签栏已解锁')
            })
        }.alignItems(VerticalAlign.Bottom).justifyContent(FlexAlign.End)
      }

      if (this.hideList.length > 0) {
        Flex({
          direction: FlexDirection.Row, wrap: FlexWrap.Wrap, alignContent: FlexAlign.Center
        }) {
          ForEach(this.hideList, (item: BookGroups, index: number) => {
            Row() {
              this.GroupType(item.groupName)
              if (this.isShowIcon) {
                Image($r('app.media.add_new_fill')).width(12).height(12).offset({ x: -20, y: -20 })
                  .onClick(() => {
                    Haptics.tap();
                    if (item.groupId) {
                      this.isHide = false
                      this.checkListNumber = item.groupId
                    }
                    this.clickHideDialog?.open()
                  })
              }
            }
            .onTouch((event: TouchEvent) => {
              if (event.type === TouchType.Down) {
                this.dragIndex = index // 获取当前拖拽子组件的索引
                // T10-3（Round 29）：官方规则 `@performance/high-frequency-log-check`
                // 「不建议在高频函数中使用 Hilog。高频函数包括：onTouch、onItemDragMove、onDragMove、
                //   onMouse、onVisibleAreaChange、onAreaChange、onScroll（已废弃）、onWillScroll」。
                // 原 `console.info('onTouch' + this.dragIndex)` 为调试日志（无字段前缀、无诊断用途），已删除。
              }
            })
            .draggable(this.isShowIcon)
            .onDragStart(() => {
              console.log('onDragStart')
            })
            .onDrop((event: DragEvent, extraParams: string) => {
              console.log('onDrop')
              this.changeIndex(this.dragIndex, index, 1)
            })
            .onClick(() => {
              Haptics.tap();
              this.clickGroup = item
              this.isShowBookFolderInfoDialog = true
            })
            .gesture(
              LongPressGesture({ repeat: false, duration: 500 })
                .onAction((event: GestureEvent) => {
                  this.dialogGroupData = item
                  // this.group = item
                  this.changeNumber = 1
                  this.groupInfoDialog?.open()
                }))
            .width('25%')
          }, (item: BookGroups): string => item.groupId !== undefined ? 'g' + item.groupId : item.groupName)
        }
      } else {
        Flex({
          justifyContent: FlexAlign.Center
        }) {
          Text('暂无隐藏分组').fontSize(12).fontWeight(400).fontColor(this.fgSub())
        }
        .borderRadius(4)
        .width('100%')
        .backgroundColor(this.chipBg())
        .padding({ top: 6, bottom: 6 })

      }
      Flex()
        .bindSheet($$this.isShowBookFolderInfoDialog, this.bookFolderInfoDialog(), {
          detents: [SheetSize.MEDIUM, SheetSize.LARGE, 200],
          showClose: false,
          dragBar: true,
          maskColor: 'rgba(0,0,0,0.6)',
          onDisappear: () => {
            console.log('隐藏')
          }
        })

    }
    .borderRadius({ bottomLeft: 20, bottomRight: 20 })
    .padding({
      left: 15,
      right: 15,
      top: 12,
      bottom: 20
    })
    .width('100%')
    // ⚠️ 2026-09-23：原来这里是 `.backgroundColor(Color.White)` —— **写死纯白**，
    //   这就是用户说的「这个模块没有沉浸光感材质」的直接原因：
    //   ① 它原本只是 Stack 里的一个自绘 Column，**不在沉浸光感的生效范围内**；
    //   ② 而且写死的背景色会把材质层整个盖住（官方 FAQ「背景色或背景模糊遮挡材质效果」原文：
    //      「沉浸光感的视觉层级位于组件的 backgroundColor、backgroundBlurStyle 等属性**之下**。
    //        如果同时设置了不透明的背景色或背景模糊样式，这些属性会覆盖在材质层之上」）。
    //   ⇒ 现在材质由弹窗层 options 提供（`GroupManageDialog` 的 `systemMaterial`），
    //     本层交给 `MaterialColumnModifier`：材质可用时不设任何背景，不可用时回落白色实底。
    .attributeModifier(this.surface)
  }

  @State tagLockContent: string = '长按底部tab栏书架图标可锁定分组标签栏，再次长按解锁，锁定后左右滑动将直接切换小说，漫画，有声书分组大类。'
  tagLockDialog: CustomDialogController | null = new CustomDialogController({
    builder: customizeDialogExample({
      confirm: () => {
        this.onAccept()
      },
      title: '标签锁',
      content: this.tagLockContent
    }),
    width: '90%',
    autoCancel: true,
    alignment: DialogAlignment.Center,
    // offset: { dx: 0, dy: '-40%' },
    gridCount: 4,
    customStyle: false,
    cornerRadius: 25
  })

  onAccept() {
    this.tagLockDialog?.close()
  }

  @State dragIndex: number = 0

  changeIndex(index1: number, index2: number, type: number = 2) { // 交换数组位置
    if (!this.isShowIcon) {
      showMessage('请在管理状态下拖到改变顺序')
      return
    }
    console.log('changeIndex' + index1 + ',' + index2)
    //TODO 更新排序顺序到数据库中sort
  }

  @Builder
  GroupTypeColor(title: string) {
    Column() {
      Row() {
        Text(title)
          .fontWeight(500)
          .fontSize(12)
          .textOverflow({
            overflow: TextOverflow.Ellipsis
          })
          .ellipsisMode(EllipsisMode.END)
          .maxLines(1)
          .fontColor(this.theme.mainColor)
          .textAlign(TextAlign.Center)
      }
      .margin({ right: 16, bottom: 16 })
      .justifyContent(FlexAlign.Center)
      .alignItems(VerticalAlign.Center)
      .width(68)
      .backgroundColor(this.theme.secondColor)
      .padding({
        left: 16,
        right: 16,
        top: 6,
        bottom: 6
      })
    }
  }

  @Builder
  GroupType(title: string) {
    Column() {
      Row() {
        Text(title)
          .fontWeight(500)
          .fontSize(12)
          .textOverflow({
            overflow: TextOverflow.Ellipsis
          })
          .ellipsisMode(EllipsisMode.END)
          .maxLines(1)
          .fontColor(this.fgMain())
          .textAlign(TextAlign.Center)
      }
      .margin({ right: 16, bottom: 16 })
      .justifyContent(FlexAlign.Center)
      .alignItems(VerticalAlign.Center)
      .width(68)
      .backgroundColor(this.chipBg())
      .padding({
        left: 16,
        right: 16,
        top: 6,
        bottom: 6
      })
    }
  }

  @State changeNumber: number = 0
  @State dialogGroupData: BookGroups = new BookGroups()
  groupInfoDialog: CustomDialogController | null = new CustomDialogController({
    builder: FolderInfoDialog({
      itemData: this.dialogGroupData,
      cancel: () => {
        this.exitDialog()
      }
    }),
    cancel: this.exitDialog,
    autoCancel: true,
    // 2026-09-25 用户反馈：长按编辑弹窗与全局统一 —— 居中 + 四圆角 + 标准宽
    // （原 Bottom/100%/customStyle:true 是贴底老款式）。customStyle:false 时弹窗层
    // 才有背景，systemMaterial 才有处附着（工程 2026-09-22 真机结论）。
    width: '80%',
    alignment: DialogAlignment.Center,
    customStyle: false,
    cornerRadius: 20,
    systemMaterial: ImmersiveMaterialUtil.sheetMaterial(),

  })

  //退出弹框
  exitDialog() {
    this.changeNumber = 0
    this.getGroupList()
    this.groupInfoDialog?.close()
  }

  @State isShowBookFolderInfoDialog: boolean = false

  @Builder
  bookFolderInfoDialog() {
    Column() {
      BookManageDialog({
        title: this.clickGroup.groupName,
        currentIndex: this.currentIndex,
        bookTypeNumber: this.clickGroup.groupId,
      })
    }
  }

  //需要显示的Id
  @State checkListNumber: number = 0
  @State isHide: boolean = false
  @StorageLink('BOOK_IS_BOOK_GROUPS_REFRESHING') BOOK_IS_BOOK_GROUPS_REFRESHING: number = 0
  //是否隐藏分组弹窗
  clickHideDialog: CustomDialogController | null = new CustomDialogController({
    builder: hideDialogExample({
      confirm: () => {
        this.clickHideAccept()
      },
      isHide: this.isHide
    }),
    autoCancel: true,
    alignment: DialogAlignment.Center,
    gridCount: 4,
    customStyle: false,
    cornerRadius: 25,
  })

  //隐藏操作
  clickHideAccept() {
    bookGroupUtil.updateGroupShow(this.checkListNumber, !this.isHide)
    setTimeout(() => {
      this.getGroupList()
      this.BOOK_IS_BOOK_GROUPS_REFRESHING++
      showMessage('显示成功')
    }, 500)
    this.checkListNumber = 0
    this.isHide = false
  }
}
