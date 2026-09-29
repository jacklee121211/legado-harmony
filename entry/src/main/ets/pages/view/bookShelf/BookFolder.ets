import { it } from '@ohos/hypium'
import { Haptics } from '../../../common/utils/Haptics';
import BookOverlay from '../../../componets/bookDetail/BookOverlay'
import { showMessage } from '../../../componets/common/promptShow'
import { folderList } from '../../../componets/dataList/folderList'
import BookGroupsDao from '../../../database/dao/BookGroupsDao'
import booksDao from '../../../database/dao/BooksDao'
import { BookGroups } from '../../../database/entities/BookGroups'
import BookManageDialog from './components/dialog/BookManageDialog'
import FolderInfoDialog from './components/dialog/FolderInfoDialog'
import ImmersiveMaterialUtil from '../../../common/utils/ImmersiveMaterialUtil'
import UiMotion from '../../../common/utils/UiMotion'
import { shelfEntrance } from '../../../common/utils/EntranceWave'
import { NightMode, ShelfColors } from '../../../common/utils/NightMode'

/**
 * 文件夹
 */
@Component
export default struct BookFolder {
  @Prop EXHIBIT: string
  /** App 级夜间开关：只为触发重绘（取色走 `ShelfColors`） */
  @StorageLink(NightMode.KEY) nightOn: boolean = false
  currentIndex: number = 0
  @State changeNumber: number = 0
  @State isShowBookFolderInfoDialog: boolean = false
  @StorageLink('BOOK_IS_BOOK_GROUPS_REFRESHING') @Watch('getGroupList') BOOK_IS_BOOK_GROUPS_REFRESHING: number = 0

  // ── 渐次入场（2026-09-24 新增，需求第 5 / 7 点）──────────────────────────────
  /**
   * 每项的"已入场"标记。用数组而不是把项抽成子组件 —— 本文件的两套卡片都是
   * `@Builder` 内联出来的，抽组件会牵动布局；而 `@State` 对 Array 的**数组项赋值**
   * 是可观察的（官方状态管理 V1 文档：`@State` 装饰 Array 时「可以观察到数组本身的
   * 赋值和数组项的增删改」）⇒ 数组方案同样能逐项驱动动画。
   */
  @State enteredFlags: boolean[] = []
  /** 未到期的入场定时器句柄，`aboutToDisappear` 里统一清掉 */
  private enterTimers: number[] = []

  /**
   * 读取某一项是否已入场。
   * ⚠️ **必须容错**：`enteredFlags` 是按"上一次的数据条数"建的，若因任何原因越界
   * （父组件直接注入数据、条数变化早于 flags 重建），`undefined` 会被当成 falsy
   * ⇒ 整项永久透明。所以这里把 `undefined` 显式判成"已入场"。
   */
  private isEntered(index: number): boolean {
    const v: boolean | undefined = this.enteredFlags[index]
    return v === undefined ? true : v
  }

  /**
   * 开一波并重建标记数组。
   *
   * ⚠️ 调用顺序必须严格是 `replayEntrance(...)` → `this.groupList = val`：
   *    两行在同一同步块里，渲染只会发生一次，彼时 flags 已与数据等长，
   *    不会出现"数据已到、flags 还没建"的那一帧（那就是前面说的永久透明隐患）。
   */
  private replayEntrance(count: number): void {
    this.clearEnterTimers()
    shelfEntrance.begin()
    const flags: boolean[] = []
    for (let i = 0; i < count; i++) {
      const d: number = shelfEntrance.delayFor(i)
      if (d < 0) {
        // 波次已结束 ⇒ 直接终态，不播动画（需求第 7 点）
        flags.push(true)
      } else {
        flags.push(false)
        this.enterTimers.push(setTimeout(() => {
          this.enteredFlags[i] = true
        }, d))
      }
    }
    this.enteredFlags = flags
  }

  private clearEnterTimers(): void {
    for (const t of this.enterTimers) {
      clearTimeout(t)
    }
    this.enterTimers = []
  }

  aboutToDisappear(): void {
    this.clearEnterTimers()
  }

  aboutToAppear(): void {
    this.getGroupList()
  }

  @State groupList: BookGroups[] = []

  /**
   * 拉分组列表（2026-09-29 修审核问题④「未分组的书未存放在未分组组别」）。
   *
   * 「未分组」是系统分组（isSystem=true），而 build() 过去把系统分组**全部**过滤掉
   * ⇒ 文件夹视图里根本没有"未分组"这个文件夹，默认 bookGroup=3（未分组）的书
   * 在文件夹视图里无家可归（「全部 / 未分组」两个页签能看到，文件夹视图看不到）。
   * ① 放行名为「未分组」的系统分组（按名字认，不按 groupId 认 —— 系统分组由
   *    `initGroupData` 按固定顺序插入，老库 groupId 可能漂移，名字才是稳定标识）；
   * ② 它的 `bookIds` **库里恒空**（默认入架的书从不走 updateAddBookIds）⇒
   *    这里按 `books.bookGroup === 未分组.groupId` **现算**，封面角标"共N本"才真实。
   * 点进文件夹走 BookManageDialog，查询口径同样是 `bookGroup = groupId`，天然一致。
   */
  async getGroupList() {
    try {
      const val = await BookGroupsDao.search({
        type: this.currentIndex
      })
      const ungrouped = val.find((g: BookGroups) => g.isSystem && g.groupName === '未分组')
      if (ungrouped && ungrouped.groupId !== undefined) {
        try {
          const books = await booksDao.search({ bookGroup: ungrouped.groupId })
          ungrouped.bookIds = books.map((b) => String(b.id ?? ''))
        } catch (e) {
          console.log('BookFolder 未分组bookIds现算失败: ', JSON.stringify(e))
        }
      }
      this.replayEntrance(val.length)
      this.groupList = val
    } catch (e) {
      console.log('BookFolder getGroupList, Error, ', JSON.stringify(e))
    }
  }

  build() {
    GridRow({
      columns: this.EXHIBIT === '宫格' ? 3 : 1
    }) {
      ForEach(this.groupList, (item: BookGroups, index: number) => {
        // ⚠️ 放行「未分组」系统分组（2026-09-29，审核问题④）：其余系统分组
        // （分组/全部/本地/书单）不是"装书的地方"，维持排除。
        if (item.show && (!item.isSystem || item.groupName === '未分组')) {
          GridCol() {
            Column() {
              if (this.EXHIBIT === '宫格') {
                this.bookInfoGrid(item)
              } else {
                this.bookFolderInfo(item)
              }
            }
          }
          .gesture(
            LongPressGesture({ repeat: false, duration: 500 })
              .onAction((event: GestureEvent) => {
                Haptics.tap();
                this.dialogGroupData = item
                this.changeNumber = 1
                this.groupInfoDialog?.open()
              }))
          .onClick(() => {
            Haptics.tap();
            this.isShowBookFolderInfoDialog = true
            this.clickGroup = item
          })
          // ── 渐次入场（2026-09-24，需求第 5 / 7 点）────────────────────────
          // 只动图形变换属性（opacity / scale / translate），不触发重新布局 ——
          // 官方最佳实践《动画帧率优化》原文：「使用图形变换属性变化组件，而不是直接
          // 修改布局属性，减少布局计算和重绘，降低丢帧率」。
          // ⚠️ `.animation()` 放最后：它作用于**它之前**的属性。
          .opacity(this.isEntered(index) ? 1 : 0)
          .scale({
            x: this.isEntered(index) ? 1 : UiMotion.ITEM_ENTER_SCALE_FROM,
            y: this.isEntered(index) ? 1 : UiMotion.ITEM_ENTER_SCALE_FROM
          })
          .translate({ y: this.isEntered(index) ? 0 : UiMotion.ITEM_ENTER_TRANSLATE_Y })
          .animation(UiMotion.itemEnterParam())
        }
      })
    }
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

  // D-12（Round 28）：**不采纳** lint 的 @ObjectLink 建议，改为语义正确的 @State。
  // 依据：① 本变量在 L59 被本地整体赋值 `this.clickGroup = item`，而官方限制「@ObjectLink 装饰的变量是
  //          只读的，不能被赋值，否则会有运行时报错 Cannot set property when setter is undefined」
  //          （devecocli docs read arkts-observed-and-objectlink 限制条件 6）→ 改 @ObjectLink 会运行时报错；
  //      ② 唯一调用点 BookContentRefresh.ets:72 只传 EXHIBIT/currentIndex，从不传 clickGroup，
  //          而 @ObjectLink「禁止本地初始化，必须从父组件初始化」→ 同样不成立；
  //      ③ 故它本就是「组件本地可变状态」，@State 才是正确装饰器（顺带消除 clickGroup 初始为 undefined 的隐患）。
  @State clickGroup: BookGroups = new BookGroups()

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

  @Builder
  bookInfoGrid(item: BookGroups) {
    Column({
      space: 5
    }) {
      Column() {
        Column() {
          Stack() {
            Stack() {
              Stack() {
                if (item.isTop) {
                  Text('置顶')
                    .fontColor(Color.White)
                    .fontWeight(300)
                    .fontSize(8)
                    .padding(3)
                    .borderRadius(5)
                    .backgroundColor('rgba(0, 0, 0, 0.45)')
                    .zIndex(1)
                }
                Image(item.coverUrl)
                  .draggable(false)
                  .alt($r('app.media.icon_book_default_cover_one'))
                  .width(88)
                  .height(120)
              }.alignContent(Alignment.BottomStart)
            }
            .zIndex(2)

            if (item.coverType !== 2) {
              Row() {
                Image($r('app.media.occlusion1')).draggable(false)
              }
              .zIndex(1)
              .width(95).height(110)

              Row() {
                Image($r('app.media.occlusion2'))
              }.zIndex(0)
              .width(100).height(100)
            }
          }
          .align(Alignment.BottomStart)
        }

        Row().width(100).height(20).backgroundColor(ShelfColors.skeleton()).borderRadius(10)
      }

      Text(item.groupName)
        .fontSize(15)
        .fontWeight(700)
        .textOverflow({
          overflow: TextOverflow.Ellipsis
        })
        .ellipsisMode(EllipsisMode.END)
        .maxLines(2)
      Text(`共${item.bookIds?.length || 0}本`)
        .fontSize(12)
        .fontColor('rgb(174,174,174)')
        .textOverflow({
          overflow: TextOverflow.Ellipsis
        })
        .ellipsisMode(EllipsisMode.END)
        .fontWeight(500)
        .maxLines(1)
    }
    .borderRadius(8)
    .alignItems(HorizontalAlign.Start)
    .padding({
      left: 8,
      right: 8,
      bottom: 5,
      top: 5
    })
  }

  @Builder
  bookFolderInfo(group: BookGroups) {
    Flex(
      {
        alignItems: ItemAlign.Center,
        justifyContent: FlexAlign.SpaceBetween
      }
    ) {
      Row({
        space: 20
      }) {
        BookOverlay({
          bookImage: group.coverUrl,
          isTop: group.isTop,
          coverType: group.coverType
        })
        Column({
          space: 24
        }) {
          Text(group.groupName)
            .fontWeight(700)
          Column() {
            Text(`共${group.bookIds?.length || 0}本`)
              .fontSize(12)
              .fontColor('rgb(174,174,174)')
              .textOverflow({
                overflow: TextOverflow.Ellipsis
              })
              .ellipsisMode(EllipsisMode.END)
              .fontWeight(400)
              .maxLines(1)
              .lineHeight(20)
            // Text(group.newUpdateBook?group.newUpdateBook:'暂无更新')
            //   .fontSize(12)
            //   .fontWeight(400)
            //   .textOverflow({
            //     overflow:TextOverflow.Ellipsis
            //   })
            //   .ellipsisMode(EllipsisMode.END)
            //   .maxLines(1)
            //   .lineHeight(20)
          }
          .width('60%')
          .alignItems(HorizontalAlign.Start)
        }
        .alignItems(HorizontalAlign.Start)
      }
    }
    .padding(10)
    .borderRadius(10)
  }

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
    // ★ 悬空四圆角 + 系统真材质（2026-09-22）。与书架其它长按弹窗保持同一观感。
    //   `customStyle: false` 是材质生效的**必要条件**；options 无 margin 字段，
    //   左右边距靠 width，上下靠 offset。逐条依据见 `BookInfos.ets` 同处注释。
    width: '92%',
    alignment: DialogAlignment.Bottom,
    offset: { dx: 0, dy: -16 },
    cornerRadius: 20,
    customStyle: false,
    // 弹窗材质走官方 options 渠道（依据见 BookInfos.ets 同处注释）
    systemMaterial: ImmersiveMaterialUtil.sheetMaterial(),

  })

  //退出弹框
  exitDialog() {
    this.changeNumber = 0
    this.groupInfoDialog?.close()
  }
}