import { bookParser } from '@kit.ReaderKit'
import BasicDataSource from '../../../common/LazyIDataSource/BasicDataSource'
import { MaterialColumnModifier, MaterialDockModifier, default as ImmersiveMaterialUtil } from '../../../common/utils/ImmersiveMaterialUtil'
import { ThemeStorageKey } from '../../../common/constants/Theme'
import { ThemeItem } from '../../../common/model/Theme'
// ── 全局震动反馈（2026-09-25 新增）────────────────────────────────────────────
import { Haptics } from '../../../common/utils/Haptics'
// ⚠️ 2026-10-13 拆分：`BookmarksDao` / `BookmarkRow` 的 import 已随书签面板一起
//    搬到 `ReaderBookmarkDialog.ets`（本文件不再接触书签数据）。

/**
 * 阅读器「目录 / 书签」弹窗（2026-09-22 从 `bindSheet` 改成 `@CustomDialog`）。
 *
 * ── 为什么改（用户已拍板「既然能统一，那就全 @CustomDialog」）────────────────
 * 与放大镜浮窗（`ShelfSearchPanel.ets`）/ 睡眠定时弹窗（`SleepTimerDialog.ets`）同款：
 * · `@CustomDialog` 由 `CustomDialogControllerOptions` 直接给 `alignment`/`width`/`height`，
 *   **不受 sheet 的 `detents` 底部锚定**（`detents` 是"底部多段高度"语义，会把面板锚死在底部）；
 * · 只有走**弹窗 options 的 `systemMaterial`** 才能拿到真沉浸光感材质 ——
 *   `SheetOptions` 全部字段里**没有** `systemMaterial`。
 *   证据：`…\ets\component\custom_dialog_controller.d.ts:681`
 *   `systemMaterial?: SystemUiMaterial;`（@since 26.0.0）；
 *   官方「组件适配沉浸光感 → 弹出框（Dialog）」原文：
 *   「弹出框支持通过**弹出框 options 参数中的 `systemMaterial` 字段**设置沉浸光感效果，
 *     如 `CustomDialogControllerOptions`…」
 *   ⚠️ 前提是 `customStyle: false`：SDK `custom_dialog_controller.d.ts:130-134` 原文
 *   「When this parameter is set to **true**: 1. The rounded corner radius is 0,
 *     and **the background color is transparent**.」⇒ 材质无处附着。
 *
 * ── 数据流（**严禁 `@Link` 跨级转发**，见血泪教训）──────────────────────────
 * · 目录数据：父页面把 `CatalogList.getOriginDataArray()` 的**快照数组**传进来（只读）；
 *   过滤在本组件内部完成，`filteredSource` 是本组件自己的实例 ——
 *   这样它和父页面那条长生命周期的数据源**不共享监听器**，开一次弹窗不会往父数据源上累加。
 * · 实时刷新：`BasicDataSource.clear()` 会 `notifyDataReload()`
 *   （`BasicDataSource.ets:25-28` 原文：`clear(){ this.originDataArray = []; this.notifyDataReload(); }`）
 *   ⇒ 必须**复用同一实例**、用 `clear()` + `pushAllData()`，不能整体 new 一个再赋值。
 *   （⚠️ 父页面旧注释写的是"`pushAllData()` 内部会调 `notifyDataReload()`" ——
 *     实测源码 **不成立**：`BasicDataSource.ets:40-45` 的 `pushAllData` 只按条发 `notifyDataAdd`，
 *     真正触发"重载"的是 `clear()`。结论不变：clear + pushAllData 才是对的。）
 * · 书签：本组件自己 `BookmarksDao.list()` 后按**书名**过滤（与写入端 `toggleBookmark()` 同口径）。
 *   之所以不让父页面异步加载后传进来：`@Prop`/普通成员只在构造时取一次值，
 *   **异步加载完成后无法保证回灌到已经打开的弹窗里**，本组件自持状态最稳。
 * · 点击跳转仍留在父页面（`jumpToCatalogItem` / `jumpToBookmark`），本组件只回调。
 */

/**
 * 面板兜底色 —— 与改造前的 `backgroundColor(this.colorMode == 0 ? '#1F1F1F' : 'rgba(248,249,250,1)')`
 * **逐字一致**。
 * ⚠️ 命名别搞反：本页 `colorMode` 的 **0 = 夜间（深色）**、1 = 日间 —— 依据是日夜切换那一段
 *    （`ReaderPage3` 的切换闭包把 colorMode 取反后，`colorMode == 0` 分支里设
 *     `readerSetting.nightMode = true` + 黑底白字），且全文文字色都是
 *     `colorMode == 0 ? 'rgba(248,249,250,1)'（近白）: 'rgba(19,19,19,1)'（近黑）`。
 * ⇒ 深色底 `#1F1F1F` 属于**夜间**。
 */
const PANEL_BG_NIGHT: string = '#1F1F1F'
const PANEL_BG_DAY: string = 'rgba(248, 249, 250, 1)'

/**
 * 面板高度（vp）—— **高度写在内容层，不在 `CustomDialogControllerOptions` 里**。
 *
 * ── 为什么必须这样（2026-09-23 真机截图 + SDK 原文）─────────────────────────
 * 用户反馈（键盘弹起时截图）：「**顶部有点穿了**，输入的时候顶部太置顶了，会掩盖摄像头位置」。
 * 截图实测（1320×2848px，vpr 3.25 ⇒ 逻辑屏 876vp）：
 *   · 不输入：面板高 ≈ 1844px ≈ **567vp**（即 options 里的 560），顶部在 ~219vp 处 ✅
 *   · 输入中：键盘顶边 ≈ 1783px ≈ **548vp**，面板底边被系统顶到"键盘上方 16vp"，
 *     面板高仍是 560 ⇒ 顶边 = 548 − 16 − 560 ≈ **−28vp**（跑到屏幕外/压住摄像头）❌
 * SDK 原文（`component\custom_dialog_controller.d.ts:26-30`，`CustomDialogControllerOptions`
 * 的 class 级 NOTE）：
 *   「If the dialog box reaches its maximum allowable height on the screen when avoiding the
 *     soft keyboard, it reduces its height to fit. It should be noted that this height adjustment
 *     is applied to the outermost container. If a child component within this container has been
 *     assigned a larger fixed height, since the container does not clip its content by default,
 *     parts of the dialog box may still be displayed off-screen.」
 * ⇒ 系统的"避让"只保证**塞得下键盘**，不会替我们留顶部安全区；组件级 `KeyboardAvoidMode`
 *   也只有 `DEFAULT = 0`（「compresses the height when reaching the maximum limit」）与
 *   `NONE = 1`（「Does not avoid the soft keyboard」）两档（`component\common.d.ts:26918-26947`），
 *   **没有"缩到留边"这一档**。⇒ 只能我们自己收高度。
 *
 * 做法：弹窗高度交给**内容节点**决定（options 里不再写 height，见
 * `ReaderPage3.openCatalogDialog()`），根 Column 按"是否正在输入"给两个值：
 *   · 不输入 = `PANEL_HEIGHT`（560，用户已确认的观感，与改造前一致）
 *   · 输入中 = `PANEL_HEIGHT_TYPING`（收一档 ⇒ 顶边落在 ~92vp，摄像头/状态栏之上留出空间）
 * 输入态来自 `Search.onEditChange`（`component\search.d.ts:644`，@since 12）：
 *   「Called when the input state changes. The text box is in the editing state when it has the
 *     caret placed in it, and is in the non-editing state otherwise.」
 *
 * ⚠️ **唯一可调项**：`PANEL_HEIGHT_TYPING`。想顶部留更多 ⇒ 改小；想少留 ⇒ 改大
 *    （顶边 ≈ 548 − 16 − 该值）。
 */
const PANEL_HEIGHT: number = 560
const PANEL_HEIGHT_TYPING: number = 440

/**
 * ── 2026-10-13 拆分：目录 / 书签变成**两个按钮 + 两个弹窗**（用户要求）─────────
 * 本文件自此**只服务目录**；书签拆到同目录的 `ReaderBookmarkDialog.ets`。
 *
 * 拆分后保留的东西（用户原话「效果不变，搜索不变」）：
 *   · 搜索栏、目录过滤、当前章高亮、点击跳章 —— 全部原样；
 *   · 右侧「顶部 / 定位 / 底部」竖向 dock —— 两个弹窗**都有**（用户明确要求）。
 * 拆出去的东西：
 *   · 顶部「目录 / 书签」页签行（不再需要 —— 各进各的窗）；
 *   · `bmRows` / `loadBookmarks()` / `cdlPercent()` / `BookmarkListPane()` /
 *     `onPickBookmark` / `onTabChange` / `initTab`。
 *
 * ⚠️ 面板高度常量 `PANEL_HEIGHT` / `PANEL_HEIGHT_TYPING` 由两个弹窗**共用**，
 *    所以必须 `export` —— 书签弹窗 import 本文件的常量，避免两处各写一份而慢慢飘开。
 */
export const CATALOG_PANEL_HEIGHT: number = PANEL_HEIGHT
export const CATALOG_PANEL_HEIGHT_TYPING: number = PANEL_HEIGHT_TYPING

@CustomDialog
export struct ReaderCatalogDialog {
  /** 由 `CustomDialogController` 注入（`@CustomDialog` 必需字段） */
  controller?: CustomDialogController

  /** 全书目录**快照**（父页面 `CatalogList.getOriginDataArray()` 的浅拷贝，本组件只读） */
  catalogItems: bookParser.CatalogItem[] = []
  /** 当前阅读章节的**目录下标**（高亮用） */
  @Prop currentChapterIndex: number = 0
  // （2026-10-13 拆分：原 `@Prop totalChapterNum` 只服务书签百分比 `cdlPercent()`，
  //   已随书签一起搬到 `ReaderBookmarkDialog`，本组件不再需要。）
  /** 日/夜模式（**0 = 夜间**，1 = 日间；与父页面 `colorMode` 同义） */
  @Prop colorMode: number = 0
  /**
   * ★ 2026-10-09 用户要求：「和书架 dock 一样，跟随主题色」。
   *   书架 dock 的颜色来自 `@StorageProp(ThemeStorageKey.THEME).mainColor`，
   *   这里用**同一个源** ⇒ 换主题时两处一起变。
   */
  @StorageProp(ThemeStorageKey.THEME) theme: ThemeItem = {} as ThemeItem
  // （2026-10-13 拆分：原 `@Prop bookName` 只服务书签按书名过滤，已搬到
  //   `ReaderBookmarkDialog`；本组件不再接触书签数据。）
  /** 初始搜索关键词 —— 父页面记忆上次输入 */
  @Prop initKeyword: string = ''

  /** 关键词变化（父页面记忆，下次打开回填） */
  onKeywordChange: (kw: string) => void = (_kw: string): void => {
  }
  /** 点某章：父页面负责 `durChapterIndex = index` + `jumpToCatalogItem(item)` + 关弹窗 */
  onPickCatalogItem: (item: bookParser.CatalogItem, index: number) => void =
    (_item: bookParser.CatalogItem, _index: number): void => {
    }

  /** 过滤后的目录数据源（LazyForEach 需要**稳定实例**） */
  @State filteredSource: BasicDataSource<bookParser.CatalogItem> = new BasicDataSource<bookParser.CatalogItem>()
  /** 搜索关键词 */
  @State keyword: string = ''
  /** 是否正在输入（搜索框有光标）—— 决定面板高度，见 `PANEL_HEIGHT_TYPING` 的注释 */
  @State typing: boolean = false

  private scrollerForList: Scroller = new Scroller()
  /**
   * 材质背板修饰器。构造时传"兜底色 + 已有 options 材质 = true"：
   * 材质可用 ⇒ 内容层**一个背景属性都不设**（设了反而把材质挡掉，官方原文见
   * `ImmersiveMaterialUtil.ets:353-395`）；材质不可用 ⇒ 落回改造前的实底纯色。
   */
  private surface: MaterialColumnModifier = new MaterialColumnModifier(PANEL_BG_NIGHT, true)

  aboutToAppear(): void {
    this.keyword = this.initKeyword
    // colorMode 0 = 夜间 ⇒ 深色兜底；1 = 日间 ⇒ 浅色兜底（与改造前 `backgroundColor` 的三元一致）
    this.surface = new MaterialColumnModifier(this.colorMode == 0 ? PANEL_BG_NIGHT : PANEL_BG_DAY, true)
    this.rebuildFilteredCatalog()
  }

  /** 按 `keyword` 重建 `filteredSource`（大小写不敏感，按章节名 includes） */
  private rebuildFilteredCatalog(): void {
    const kw = (this.keyword ?? '').trim().toLowerCase()
    let hit: bookParser.CatalogItem[] = this.catalogItems
    if (kw !== '') {
      hit = this.catalogItems.filter((it: bookParser.CatalogItem) => {
        return (it.catalogName ?? '').toLowerCase().includes(kw)
      })
    }
    this.filteredSource.clear()
    this.filteredSource.pushAllData(hit)
  }

  /**
   * 章在**全书目录**里的下标。
   *
   * ⚠️ 为什么不能用 `LazyForEach` 的 `index`：搜索过滤后 `index` 是**过滤数组**的下标，
   * 而 `bookData.durChapterIndex` / `CatalogList` 全程是**全书目录**的下标。
   * 改造前 `ListItem.onClick` 直接写 `this.bookData.durChapterIndex = index`，
   * 一旦带着关键词点章节，就会把"过滤后的序号"当成"全书章号"记进去
   * （现象：目录高亮错位、进度百分比错）。这里改为回查真实下标。
   */
  private catalogIndexOf(item: bookParser.CatalogItem): number {
    const i = this.catalogItems.indexOf(item)
    return i >= 0 ? i : 0
  }

  /**
   * 该目录项是不是"当前正在读的那一章"。
   * 用**对象引用**比对（`catalogItems` 与过滤结果里是同一批对象），O(1)，且过滤状态下也正确。
   */
  private isCurrentChapter(item: bookParser.CatalogItem): boolean {
    const idx = this.currentChapterIndex
    if (idx < 0 || idx >= this.catalogItems.length) {
      return false
    }
    return this.catalogItems[idx] === item
  }

  // （2026-10-13 拆分：原 `activeColor()` 只被书签面板用，已随书签一起搬到
  //   `ReaderBookmarkDialog.ets`；本文件目录列表用内联三元，不依赖它。）

  build() {
    Column() {
      // ── 目录搜索栏（2026-09-22 用户要求）──────────────────────────────
      // 「顶部增加搜索栏，直接参考书籍详情里面的目录的搜索能力，就够用了」。
      // 搜索栏收窄（用户反馈「那个灰色的搜索栏太宽了…没质感」）：左右各留 40，高度 34→32。
      Search({ placeholder: '搜索目录', value: this.keyword })
        .height(32)
        .width('100%')
        .padding({ left: 40, right: 40, bottom: 8 })
        .onChange((v: string) => {
          this.keyword = v
          this.onKeywordChange(v)
          this.rebuildFilteredCatalog()
        })
        .onSubmit((v: string) => {
          this.keyword = v
          this.onKeywordChange(v)
          this.rebuildFilteredCatalog()
        })
        // 输入态 ⇒ 面板收高度，让顶边落在摄像头/状态栏之下（证据见 `PANEL_HEIGHT_TYPING` 注释）
        .onEditChange((isEditing: boolean) => {
          this.typing = isEditing
        })
      // ── 2026-10-13 拆分：页签行已删除 ─────────────────────────────────────
      // 原「目录 / 书签」两个页签合在一个弹窗里；现在各是一个按钮 + 一个弹窗
      // （书签见 `ReaderBookmarkDialog.ets`）⇒ 本弹窗进来就是目录，不需要页签。
      // ⚠️ 搜索栏留在**目录弹窗**（用户原话「搜索不变」）；书签弹窗没有搜索。
      this.CatalogListPane()
    }
    // ★ 悬浮外观由**弹窗 options** 提供（`width: '92%'` + `cornerRadius` + `systemMaterial`），
    //   所以内容层**不能**再写左右 margin（同时写 `width('100%')` + 左右 margin 会让总宽超出容器，
    //   表现就是"贴右侧 + 内容残缺 + 底部溢出"）。
    //   这里只写 `width('100%')`、不写任何 margin ⇒ 宽度 = 弹窗宽度，宽度语义单一，不会再溢出。
    .width('100%')
    // ★ 高度写在**内容层**（options 里不写 height ⇒ 弹窗高度 = 本节点高度，见
    //   `custom_dialog_controller.d.ts:126`：「If the width and height of the dialog box are not
    //   set, the dialog box … adapts its height to the custom content node.」）。
    //   分两档是为了键盘弹起时顶部不"穿"（详见 `PANEL_HEIGHT_TYPING` 的注释）。
    .height(this.typing ? PANEL_HEIGHT_TYPING : PANEL_HEIGHT)
    .borderRadius(20)
    .clip(true)
    // ★ 内保护边距：顶部/底部/定位那条浮动按钮由 `CatalogListPane()` 内部绘制（Stack 右下角），
    //   不设内保护时它贴到面板最下沿、被裁掉一半（用户 2026-09-22 反馈"太靠下"）。
    .padding({ left: 16, right: 16, bottom: 72 })
    // 材质优先 / 兜底实底（详见 `MaterialColumnModifier` 的注释）
    .attributeModifier(this.surface)
  }

  @Builder
  CatalogListPane() {
    Stack() {
      List({ space: 10, scroller: this.scrollerForList }) {
        LazyForEach(this.filteredSource, (item: bookParser.CatalogItem) => {
          ListItem() {
            Column() {
              Row() {
                Text(item.catalogName)
                  .fontSize(14)
                  .fontColor(this.colorMode == 0 ?
                    (this.isCurrentChapter(item) ? 'rgba(129, 231, 126, 1.00)' :
                      'rgba(248, 249, 250, 1)') :
                    (this.isCurrentChapter(item) ? 'rgba(129, 231, 126, 1.00)' : 'rgba(19, 19, 19, 1.00)'))
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .padding({ top: 8, bottom: 8 })
                  .layoutWeight(1)
              }
              .width('100%')
            }
            .padding({
              left: item.catalogLevel ? item.catalogLevel * 26 : 16,
              right: 16,
            })
          }
          .onClick(() => {
            Haptics.tap();
            // 真实章号由本组件换算（不能直接用过滤后的 `index`），跳转本身仍由父页面做
            this.onPickCatalogItem(item, this.catalogIndexOf(item))
          })
        })
      }
      .divider({
        strokeWidth: 0.8,
        // ⚠️ 夜间那段原先是 `'rgba(248, 249, 250, 1)'`（**全不透明**近白）——
        //    比日间的 `rgba(136,136,136,1)` 还亮，每一行之间都是一道刺眼白线。
        //    改成同色系的**半透明**：与正文同为 #F8F9FA，但只留 25% 不透明度。
        //    回退：把 `0.25` 改回 `1`（或整段换回 `'rgba(136, 136, 136, 1.00)'`）。
        color: this.colorMode == 0 ? 'rgba(248, 249, 250, 0.25)' : 'rgba(136, 136, 136, 1.00)',
        startMargin: 12,
        endMargin: 12
      })
      .width('100%')
      .height('100%')
      .onAppear(() => {
        this.scrollerForList.scrollToIndex(this.currentChapterIndex)
      })

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
          this.scrollerForList.scrollToIndex(0)
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
          this.scrollerForList.scrollToIndex(this.currentChapterIndex)
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
          this.scrollerForList.scrollToIndex(this.catalogItems.length - 1)
        })
      }
      .padding(5)
      // ★★ 2026-10-09 用户要求：「适配和书架一样的 dock」★★
      //   改造前是一块**写死的蓝色实底**（2026-09-25 用户反馈「不喜欢绿色」时换的）。
      //   现在改成与书架 dock 同源的**沉浸光感材质**：
      //     · 书架那条走 HDS 的 `systemMaterialEffect`；
      //     · 这组普通按钮没有 HDS 容器 ⇒ 走**组件级** `systemMaterial`
      //       （官方：「普通ArkUI组件通过应用级开启或者组件级开启方式开启沉浸光感」）。
      //   ⚠️ 材质与 `backgroundColor` **互斥**（官方：「已主动设置背景色、背景模糊等自定义
      //      样式属性，则不呈现沉浸光感效果」）⇒ **不能**用三元表达式，必须交给
      //      `MaterialDockModifier` 二选一（开材质时一个背景属性都不设）。
      //   一键回退：`ImmersiveMaterialUtil.ENABLED = false` ⇒ 自动落回原来那块蓝。
      // ★ 跟随主题色（半透明 —— 毛玻璃要透出后面的目录文字，不能是实底）
      // ⚠️ 2026-10-13 用户反馈：「这个三按钮的竖向弹窗背景不够透明，增加些透明度」
      //   ⇒ 不透明度 0.82 → 0.55。`tint(hex, alpha)` 的 alpha 直接决定 perceived 透明
      //      （`ImmersiveMaterialUtil.ets:233-238` 把 alpha 写进 `#AARRGGBB` 的首字节）。
      //   0.55 仍保证按钮字可读（底下是目录列表，透出的是暗色文字/深底）。
      //   回退：把 `0.55` 改回 `0.82`。
      .attributeModifier(new MaterialDockModifier(
        ImmersiveMaterialUtil.tint(this.theme.mainColor !== undefined ? this.theme.mainColor : '#007DFF', 0.55)))
      .borderRadius(20)
      .position({ bottom: '10%', right: '5%' })
    }
    // 弹窗高度是**固定**的（options 里的 height）⇒ 让这个 Stack 吃掉"搜索栏 + 页签"之外的
    // 剩余高度（`layoutWeight` 官方原文：子组件分配父容器**剩余空间**，`common.d.ts:17475`）。
    // 改造前（sheet 版）Stack 自己不设高度、靠内部 `List.height('100%')` 撑，
    // 在"内容层有 padding + 兄弟节点"的情况下百分比高度会跟父容器打架（底部溢出）。
    .width('100%')
    .layoutWeight(1)
  }

}
