/**
 * 阅读器「书签」弹窗（2026-10-13 从 `ReaderCatalogDialog` 拆出，用户要求）。
 *
 * ── 需求（用户原文）───────────────────────────────────────────────────────────
 * 「在阅读器中，目录和书签现在是共同一个按钮和一个弹窗，我的建议是分离出来，
 *   目录是目录，书签是书签。效果不变，搜索不变，只是分离成两个按钮两个弹窗。
 *   并且底部的顶部定位底部按钮两个弹窗都有，还有就是这个三按钮的竖向弹窗
 *   背景不够透明，增加些透明度。」
 *
 * ── 与目录弹窗的差异（刻意保留的差异）─────────────────────────────────────────
 * · **没有搜索栏**：搜索是针对目录章节名的（「搜索不变」= 目录里的搜索照旧）。
 *   书签只有几条，按书名过滤即可，再套一层关键词过滤只会让人以为"书签丢了"。
 * · **有右侧「顶部 / 定位 / 底部」竖向 dock**（用户明确要求两个弹窗都有）：
 *   这三个键在本弹窗里作用于**书签列表**，语义见 `BookmarkDock()` 的注释。
 * · 空态提示与改造前的书签页签**逐字一致**（「本书还没有书签」/「阅读时点右上角…」）。
 *
 * ── 数据流（与目录弹窗同款，且**严禁 `@Link` 跨级转发**）────────────────────────
 * · 书签由本组件自己 `BookmarksDao.list()` 后按**书名**过滤 —— 写入端 `toggleBookmark()`
 *   也是这个口径（`bookmarks` 表没有 bookId 列，书名是唯一关联键）。
 * · 之所以不让父页面异步加载后传进来：`@Prop`/普通成员只在构造时取一次值，
 *   异步加载完成后无法保证回灌到已经打开的弹窗里，本组件自持状态最稳。
 * · 点击跳转仍留在父页面（`jumpToBookmark`），本组件只回调。
 *
 * ── 面板外观（与目录弹窗共用同一套）──────────────────────────────────────────
 * 高度常量直接 import `ReaderCatalogDialog` 的导出值 ⇒ 两个弹窗高度永远一致，
 * 不会因为两处各写一份而慢慢飘开。材质走弹窗 options 的 `systemMaterial`（见
 * `ReaderPage3.openBookmarkDialog()`），内容层用 `MaterialColumnModifier(…, true)`
 * **不设任何 backgroundColor**。
 */
import { MaterialColumnModifier, MaterialDockModifier, default as ImmersiveMaterialUtil } from '../../../common/utils/ImmersiveMaterialUtil'
import { ThemeStorageKey } from '../../../common/constants/Theme'
import { ThemeItem } from '../../../common/model/Theme'
import { Haptics } from '../../../common/utils/Haptics'
import BookmarksDao, { BookmarkRow } from '../../../database/dao/BookmarksDao'
// ⚠️ 只 import 非输入态高度：本弹窗没有搜索框 ⇒ 永远不会进入「输入中」那一档。
//    （`CATALOG_PANEL_HEIGHT_TYPING` 只服务目录弹窗的键盘避让，见其常量注释。）
import { CATALOG_PANEL_HEIGHT } from './ReaderCatalogDialog'

/** 面板兜底色 —— 与目录弹窗**逐字一致**（0 = 夜间 ⇒ 深色；1 = 日间 ⇒ 浅色） */
const PANEL_BG_NIGHT: string = '#1F1F1F'
const PANEL_BG_DAY: string = 'rgba(248, 249, 250, 1)'

@CustomDialog
export struct ReaderBookmarkDialog {
  /** 由 `CustomDialogController` 注入（`@CustomDialog` 必需字段） */
  controller?: CustomDialogController

  /** 本书书名（书签按书名过滤的唯一关联键） */
  @Prop bookName: string = ''
  /** 当前阅读章节的**目录下标**（「定位」键用：滚到离当前进度最近的那条书签） */
  @Prop currentChapterIndex: number = 0
  /** 全书章节总数（书签进度百分比用，与「我的 → 书签」同口径） */
  @Prop totalChapterNum: number = 0
  /** 日/夜模式（**0 = 夜间**，1 = 日间；与父页面 `colorMode` 同义） */
  @Prop colorMode: number = 0
  /** 主题色（与目录弹窗 dock 同源：换主题时两处一起变） */
  @StorageProp(ThemeStorageKey.THEME) theme: ThemeItem = {} as ThemeItem

  /** 点某条书签：父页面负责 `jumpToBookmark(row)`（其内部含"章节已不存在"的早退分支） */
  onPickBookmark: (row: BookmarkRow) => void = (_row: BookmarkRow): void => {
  }

  /** **本书**的书签列表 */
  @State bmRows: BookmarkRow[] = []

  /** 书签列表滚动器（「顶部 / 定位 / 底部」三个键操作它） */
  private bmScroller: Scroller = new Scroller()

  /**
   * 材质背板修饰器。构造时传"兜底色 + 已有 options 材质 = true"：
   * 材质可用 ⇒ 内容层**一个背景属性都不设**（设了反而把材质挡掉，官方原文见
   * `ImmersiveMaterialUtil.ets:353-395`）；材质不可用 ⇒ 落回实底纯色。
   */
  private surface: MaterialColumnModifier = new MaterialColumnModifier(PANEL_BG_NIGHT, true)

  aboutToAppear(): void {
    // colorMode 0 = 夜间 ⇒ 深色兜底；1 = 日间 ⇒ 浅色兜底
    this.surface = new MaterialColumnModifier(this.colorMode == 0 ? PANEL_BG_NIGHT : PANEL_BG_DAY, true)
    this.loadBookmarks()
  }

  /**
   * 拉取**本书**的书签。
   * `BookmarksDao.list()` 返回全部书的书签，这里按 `bookName` 过滤 ——
   * `bookmarks` 表没有 bookId 列，书名是唯一关联键（与写入端 `toggleBookmark()` 一致）。
   */
  private async loadBookmarks(): Promise<void> {
    try {
      const all = await BookmarksDao.list()
      this.bmRows = all.filter((r: BookmarkRow) => (r.bookName ?? '') === this.bookName)
    } catch (e) {
      this.bmRows = []
    }
  }

  /**
   * 书签进度百分比（与「我的 → 书签」口径一致：章下标 / 总章数）。
   * 点击某条书签的**跳转**不在这里做 —— 由父页面 `jumpToBookmark()` 复用现成的
   * 精确跳转链路（目录号 → `getResourceItemByCatalog` → 正文号 → `requestLocate`），
   * 保证与「我的 → 书签」两处行为一致。
   */
  private cdlPercent(row: BookmarkRow): number {
    const total = this.totalChapterNum ?? 0
    const idx = row.chapterIndex ?? 0
    // 电脑端书签 chapterIndex = -1（网页章号≠手机目录下标，见审计 H3）⇒ 不显示百分比
    if (total <= 0 || idx < 0) {
      return 0
    }
    return Math.max(0, Math.min(100, Math.round((idx + 1) / total * 100)))
  }

  /** 选中文字色（跟随日/夜模式） */
  private activeColor(): string {
    return this.colorMode == 0 ? 'rgba(248, 249, 250, 1)' : 'rgba(19, 19, 19, 1.00)'
  }

  /** 次要文字色 */
  private subColor(): string {
    return 'rgba(136, 136, 136, 1.00)'
  }

  /**
   * 「定位」键的落点：**离当前阅读进度最近**的那条书签。
   *
   * 为什么不是"滚到当前章"：书签列表里没有"当前章"这一行 —— 只有用户自己插的若干条。
   * 「定位」在这里最合理的语义是"带我回到离现在当前位置最近的书签"。
   * 规则：取第一条 `chapterIndex >= 当前章` 的书签；都更早 ⇒ 落到最后一条。
   * 百分比口径与列表展示一致（`cdlPercent`），避免"定位到的行和显示的不一致"。
   */
  private nearestBookmarkIndex(): number {
    const cur: number = this.currentChapterIndex ?? 0
    for (let i = 0; i < this.bmRows.length; i++) {
      const idx: number = this.bmRows[i].chapterIndex ?? 0
      if (idx < 0) {
        // 电脑端书签章号未知（-1）⇒ 跳过：拿它做定位会随机落在列表某处
        continue
      }
      if (idx >= cur) {
        return i
      }
    }
    return this.bmRows.length > 0 ? this.bmRows.length - 1 : 0
  }

  /**
   * 右侧竖向三按钮 dock（顶部 / 定位 / 底部）—— 与目录弹窗**同款同位置**。
   *
   * ⚠️ 本弹窗里这三键作用于**书签列表**（用户要求两个弹窗都有这组按钮）：
   *   · 「顶部」= 滚到第一条书签；
   *   · 「定位」= 滚到离当前阅读进度最近的那条（见 `nearestBookmarkIndex()`）；
   *   · 「底部」= 滚到最后一条。
   * 空列表时三个键都是空操作（`scrollToIndex` 会被 `bmRows.length` 判定挡住）。
   */
  @Builder
  BookmarkDock() {
    Column() {
      Column() {
        Image($r('app.media.top'))
          .width(20)
          .height(20)
        Text('顶部')
          .fontSize(12)
      }
      .padding(5)
      .onClick(() => {
        Haptics.tap();
        if (this.bmRows.length > 0) {
          this.bmScroller.scrollToIndex(0)
        }
      })

      Column() {
        Text() {
          SymbolSpan($r("sys.symbol.position"))
        }

        Text('定位')
          .fontSize(12)
      }
      .padding(5)
      .onClick(() => {
        Haptics.tap();
        if (this.bmRows.length > 0) {
          this.bmScroller.scrollToIndex(this.nearestBookmarkIndex())
        }
      })

      Column() {
        Image($r('app.media.down'))
          .width(20)
          .height(20)
        Text('底部')
          .fontSize(12)
      }
      .padding(5)
      .onClick(() => {
        Haptics.tap();
        if (this.bmRows.length > 0) {
          this.bmScroller.scrollToIndex(this.bmRows.length - 1)
        }
      })
    }
    .padding(5)
    // ★ 与目录弹窗 dock 完全同款：跟随主题色的**半透明**材质背板。
    // ⚠️ 2026-10-13 用户反馈「背景不够透明，增加些透明度」⇒ 不透明度 0.82 → 0.55
    //   （alpha 直接写进 `#AARRGGBB` 首字节，见 `ImmersiveMaterialUtil.tint` :233-238）。
    //   回退：把 `0.55` 改回 `0.82`。**改这里时必须同步改 `ReaderCatalogDialog` 的 dock**
    //   —— 两个弹窗的观感必须一致，否则来回切换会明显"一个透一个不透"。
    .attributeModifier(new MaterialDockModifier(
      ImmersiveMaterialUtil.tint(this.theme.mainColor !== undefined ? this.theme.mainColor : '#007DFF', 0.55)))
    .borderRadius(20)
    .position({ bottom: '10%', right: '5%' })
  }

  build() {
    Column() {
      // ── 标题行（本弹窗没有搜索栏，用一个标题占位保持视觉层次）──────────────
      Row() {
        Text(this.bmRows.length > 0 ? `书签 ${this.bmRows.length}` : '书签')
          .fontSize(15)
          .fontWeight(600)
          .fontColor(this.activeColor())
      }
      .width('100%')
      .justifyContent(FlexAlign.Center)
      .padding({ top: 12, bottom: 10 })

      // ── 列表 / 空态（空态文案与拆分前**逐字一致**）────────────────────────
      Stack() {
        if (this.bmRows.length === 0) {
          Column({ space: 8 }) {
            Text('本书还没有书签')
              .fontSize(14)
              .fontColor(this.subColor())
            Text('阅读时点右上角的书签图标即可添加')
              .fontSize(12)
              .fontColor(this.subColor())
          }
          .width('100%')
          .height('100%')
          .justifyContent(FlexAlign.Center)
        } else {
          List({ space: 0, scroller: this.bmScroller }) {
            ForEach(this.bmRows, (row: BookmarkRow) => {
              ListItem() {
                Column({ space: 4 }) {
                  Text(row.chapterName ?? '（无章节名）')
                    .fontSize(14)
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .width('100%')
                    .fontColor(this.activeColor())
                  Text(`${(row.bookText ?? '').length > 0 ? row.bookText : '—'}    ${this.cdlPercent(row)}%`)
                    .fontSize(12)
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .width('100%')
                    .fontColor(this.subColor())
                }
                .alignItems(HorizontalAlign.Start)
                .padding({ left: 16, right: 16, top: 10, bottom: 10 })
                .width('100%')
              }
              .onClick(() => {
                Haptics.tap();
                this.onPickBookmark(row)
              })
            }, (row: BookmarkRow) => `${row.time}`)
          }
          .width('100%')
          .height('100%')
          .scrollBar(BarState.Off)
          .divider({
            strokeWidth: 0.8,
            color: this.colorMode == 0 ? 'rgba(248, 249, 250, 0.25)' : 'rgba(136, 136, 136, 1.00)',
            startMargin: 12,
            endMargin: 12
          })
        }

        this.BookmarkDock()
      }
      .width('100%')
      .layoutWeight(1)
    }
    // ★ 宽度/高度语义与目录弹窗完全一致（详见 `ReaderCatalogDialog` 的同名注释）：
    //   options 不写 height ⇒ 弹窗高度 = 本节点高度；高度常量从目录弹窗 import ⇒ 两窗等高。
    .width('100%')
    .height(CATALOG_PANEL_HEIGHT)
    .borderRadius(20)
    .clip(true)
    // 内保护边距：底部给 dock 留位（dock 是绝对定位在 Stack 右下角，不留会被裁一半）
    .padding({ left: 16, right: 16, bottom: 72 })
    .attributeModifier(this.surface)
  }
}
