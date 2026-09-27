import confirmDialogExample from '../../../../componets/common/confirmDialog'
import { Haptics } from '../../../../common/utils/Haptics';
import { showMessage } from '../../../../componets/common/promptShow'
import { WorksLists } from '../../../../database/entities/WorksLists'
import WorksBookListGrid from './WorksBookListGrid'
import worksBookInfoDialog from '../../dialog/worksBookInfoDialog'
import WorksBookListInfo from './WorksBookListInfo'
import worksListsDao from '../../../../database/dao/WorksListsDao'
import newBookShelf from '../Manage/bookManage/newBookShelf'
import ImmersiveMaterialUtil from '../../../../common/utils/ImmersiveMaterialUtil'
import UiMotion from '../../../../common/utils/UiMotion'
import { shelfEntrance } from '../../../../common/utils/EntranceWave'
import { NightMode, ShelfColors } from '../../../../common/utils/NightMode'

/**
 * 书单
 */
@Component
export default struct WorksBookLists {
  @Link checkGroup: Record<number, boolean>
  @Prop EXHIBIT: string
  @Prop currentIndex: number
  @Prop worksLists: WorksLists[] = []
  @Prop isShowCheck: boolean = false
  /** App 级夜间开关：只为触发重绘（取色走 ShelfColors） */
  @StorageLink(NightMode.KEY) nightOn: boolean = false
  @State worksBook: WorksLists = new WorksLists()
  @StorageLink('BOOK_IS_BOOK_WORKS_BOOK_LIST') @Watch('getWorkLists') isWorksBookListRefreshing: number = 0
  onSelect: Function = () => {
  }

  // ── 渐次入场（2026-09-24 新增，需求第 5 / 7 点）──────────────────────────────
  // 与 `BookFolder.ets` 同一套做法（`@State` 数组逐项驱动 + 定时器 + 越界容错），
  // 详细依据见那边的注释。
  @State enteredFlags: boolean[] = []
  private enterTimers: number[] = []

  private isEntered(index: number): boolean {
    const v: boolean | undefined = this.enteredFlags[index]
    return v === undefined ? true : v
  }

  private replayEntrance(count: number): void {
    this.clearEnterTimers()
    shelfEntrance.begin()
    const flags: boolean[] = []
    for (let i = 0; i < count; i++) {
      const d: number = shelfEntrance.delayFor(i)
      if (d < 0) {
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
    if (this.worksLists.length === 0) {
      this.getWorkLists()
    }
  }

  @State workBookListStatus: number = 1

  getWorkLists() {
    worksListsDao.search({
      type: this.currentIndex
    }).then((val) => {
      this.replayEntrance(val.length)
      this.worksLists = val
    })
  }

  build() {
    Column() {
      GridRow({
        columns: this.EXHIBIT === '宫格' ? 3 : 1
      }) {
        ForEach(this.worksLists, (item: WorksLists, index: number) => {
          GridCol() {
            if (this.EXHIBIT === '宫格') {
              WorksBookListGrid({
                work: item,
                isShowCheck: this.isShowCheck,
                checkGroup: this.checkGroup,
                onSelect: () => {
                  this.onSelect()
                }
              }).width('33%')
                .gesture(
                  LongPressGesture({ repeat: false, duration: 500 })
                    .onAction((event: GestureEvent) => {
                        Haptics.tap();
                        this.worksBook = item
                        this.shelfInfoDialog?.open()
                    }))
                .onClick(() => {
                    Haptics.tap();
                    this.worksBook = item
                    this.isShowEditBook = true
                })

            } else {
              WorksBookListInfo({
                work: item,
                isShowCheck: this.isShowCheck,
                checkGroup: this.checkGroup,
                onSelect: () => {
                  this.onSelect()
                }
              })
                .gesture(
                  LongPressGesture({ repeat: false, duration: 500 })
                    .onAction((event: GestureEvent) => {
                      Haptics.tap();
                      this.worksBook = item
                      this.shelfInfoDialog?.open()
                    }))
                .onClick(() => {
                  Haptics.tap();
                  this.worksBook = item
                  this.isShowEditBook = true
                })
            }
          }
          // ── 渐次入场（2026-09-24，需求第 5 / 7 点）──────────────────────────
          // 只动图形变换属性（opacity / scale / translate），不触发重新布局；
          // `.animation()` 放最后（它作用于**它之前**的属性）。
          .opacity(this.isEntered(index) ? 1 : 0)
          .scale({
            x: this.isEntered(index) ? 1 : UiMotion.ITEM_ENTER_SCALE_FROM,
            y: this.isEntered(index) ? 1 : UiMotion.ITEM_ENTER_SCALE_FROM
          })
          .translate({ y: this.isEntered(index) ? 0 : UiMotion.ITEM_ENTER_TRANSLATE_Y })
          .animation(UiMotion.itemEnterParam())
        })
      }

      Flex()
        .bindContentCover($$this.isShowEditBook, this.showEditBook(), {
          modalTransition: ModalTransition.DEFAULT,
          onDisappear: () => {
            this.isShowEditBook = false;
          }
        })
    }
  }

  @State isShowEditBook: boolean = false

  @Builder
  showEditBook() {
    Column() {
      newBookShelf({
        currentIndex: this.currentIndex,
        changeShowNumber: () => {
          this.isShowEditBook = false
          setTimeout(() => {
            this.getWorkLists()
          }, 200)
        },
        returnClose: true,
        workBookListStatus: this.workBookListStatus,
        lastWorkBookList: this.worksBook
      })
    }
    .backgroundColor(ShelfColors.card())
  }

  shelfInfoDialog: CustomDialogController | null = new CustomDialogController({
    builder: worksBookInfoDialog({
      works: this.worksBook,
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
    setTimeout(() => {
      this.getWorkLists()
    }, 100)
  }

  @State delCache: boolean = false
  shelfInfoDel: CustomDialogController | null = new CustomDialogController({
    builder: confirmDialogExample({
      cancel: () => {
        this.onCancel()
      },
      confirm: () => {
        this.onAccept()
      },
      delCache: this.delCache
    }),
    cancel: this.exitApp,
    autoCancel: true,
    alignment: DialogAlignment.Center,
    gridCount: 4,
    customStyle: false,
    cornerRadius: 25,
  })

  onCancel() {
    //this.isClear = false
  }

  onAccept() {
    this.delShelf()
  }

  delShelf() {
    showMessage('删除成功')
  }

  exitApp() {
    // this.isClear = false
  }
}