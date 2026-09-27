import { showMessage } from '../componets/common/promptShow'
import { hostContext } from '../common/utils/HostContextUtil'
import ReadShow from '../componets/common/ReadShow'
import { NavItem } from '../componets/dataList/type'
import { initAppData } from '../storage/appData'
import BookShelf from './view/BookShelf'
import MyCenter from './view/myCenter/MyCenter'
// T29-④（Round 40）：依赖名统一改成合规的小写 `colorlibrary`（见 entry/oh-package.json5 注释）
import { testGetColorFunction } from 'colorlibrary'
import { BusinessError, emitter } from '@kit.BasicServicesKit'
import { JSON } from '@kit.ArkTS'
import { image } from '@kit.ImageKit'
import { ThemeStorageKey } from '../common/constants/Theme'
import { ThemeItem } from '../common/model/Theme'
import { WindowAbility } from '../entryability/WindowAbility'
import BrightnessUtil from '../../common/utils/BrightnessUtil'
import { router } from '@kit.ArkUI'
import BooksDao from '../database/dao/BooksDao'
import { Books } from '../database/entities/Books'
import ImmersiveMaterialUtil from '../common/utils/ImmersiveMaterialUtil'
import AppRouter, { RouteName } from '../common/router/AppRouter'
import UiMotion from '../common/utils/UiMotion'
import BookDetailPage from './view/BookDetailPage'
import ReaderPage3 from './view/Reader/ReaderPage3'
import {
  ReaderRouteParam,
  ReadStatisticsRouteParam,
  BookManageRouteParam,
} from '../common/router/AppRouter'
// ── 迁 Navigation 第 4 期：5 个真实可达页 ────────────────────────────────────
import BookManagePage from './view/bookShelf/Manage/BookManagePage'
import ReadStatistics from './view/myCenter/readStatistics'
import MyThemeConfig from './view/myCenter/MyThemeConfig'
import MySetPage from './view/myCenter/MySetPage'
import CreateCustomTheme from './view/myCenter/CreateCustomTheme'
import { common } from '@kit.AbilityKit'
import { NightMode } from '../common/utils/NightMode'
// ── 全局震动反馈（2026-09-25 新增）────────────────────────────────────────────
import { Haptics } from '../common/utils/Haptics'
import { LongTakeFlightData, LongTakeGeom } from '../common/utils/LongTakeBook'

@Entry
@Component
struct Main {
  @State showReadShow: boolean = true
  @State currentTabIndex: number = 0
  /**
   * App 级夜间开关（书架深色档的总闸）。
   *
   * 为什么主页面也要订它：底部页签条（自绘 `TabBuilder`）与整个 Ability 的配色
   * 都由本页负责下发 —— 规则见 `NightMode.desiredDark()`：
   *   · 停在**书架**页签且夜间开着 ⇒ 深色（书架已做深色适配）
   *   · 停在**我的**页签          ⇒ 浅色（该页未适配，绝不能被带成深色）
   * `@Watch` 保证"在阅读器里切了夜间、返回书架"时本页会重新下发一次。
   */
  @StorageLink(NightMode.KEY) @Watch('onNightModeChanged') nightOn: boolean = false
  @State isShow: boolean = true
  @StorageLink('bottomRectHeight') bottomRectHeight: number = 0
  @StorageLink('topRectHeight') topRectHeight: number = 0
  @State ShowBar: boolean = true
  tabController: TabsController = new TabsController()

  // ══════════════════════════════════════════════════════════════════════════
  // 一镜到底（书架 → 阅读器）运行态 —— 2026-09-23
  // ══════════════════════════════════════════════════════════════════════════
  // 数据流：书架点击 → `LongTakeFlightData.capture()` 拍封面几何放进路由参数（rp.longTake）
  //   并置臂旗 ltArm → READER 分支按 ltArm 建成「飞行分支」（挂 customTransition）
  //   → delegate 用 rp.longTake 推导几何（LongTakeGeom）并同步设起始帧 → 三段 animateTo 编排。
  // 为什么需要臂旗：customTransition 是飞行分支 NavDestination 的属性 —— 分支必须**先**建成、
  //   delegate 才存在；而"是不是书架点的"只有点击侧知道 ⇒ 点击侧在 push 前置位。
  //   详情页 / 快捷方式 / 书签回跳不置臂 ⇒ 走 else 普通分支 ⇒ EXPLODE 原样保留（反馈缺口A）。
  // 回退：UiMotion.LONGTAKE_ENABLED = false ⇒ 点击侧整体旁路（不再置臂、不再捕获）。
  /** 臂旗：书架点击在 push 前置位 ⇒ 本次 READER 建成「飞行分支」。弹栈后由 onDisappear 解除。 */
  @StorageLink('ltArm') ltArm: boolean = false
  /** 本次 READER 是否在演一镜到底（delegate 依据路由参数最终裁决） */
  @State ltActive: boolean = false
  /** 飞行层动画值：缩放（锚点取内容 (0,0)） */
  @State ltScale: number = 1
  /** 飞行层动画值：平移（vp，首帧 = 封面左上角在窗口里的位置；终态 = 屏幕左上角 = 参考效果的"铰链落点"） */
  @State ltTx: number = 0
  @State ltTy: number = 0
  /**
   * 「内容页/书脸」的裁切窗口高度（vp）= 封面高度：封面与内容页在书脊处**等高相连**
   * （用户口述："内容页高度和左侧两个点一边高"）。飞行中从封面纵横比（clipH0）
   * 长到全屏纵横比（clipH1）—— 内容页随放大变成全屏阅读器。
   * 初值 0 = 保险丝：万一 delegate 的同步起始帧没赶上首帧，最多闪一帧空白，
   * 绝不会闪出一整页阅读器（spec 验收标准 1）。
   */
  @State ltClipH: number = 0
  /** 封面层：绕左缘（书脊）旋转角 / 透明度 / 本地圆角 / 图源（与书架同源 ⇒ 命中图片缓存） */
  @State ltCoverAngle: number = 0
  @State ltCoverOpacity: number = 1
  @State ltCoverRadius: number = 0
  @State ltCoverUrl: string = ''
  /**
   * 书架定格快照（五轮 2026-09-23，取代原"变暗层"）。点击瞬间截的整个书架（'main'），
   * 垫在飞行书底下当"世界"：系统会中途隐藏/恢复书架 NavBar，原先露出来的是黑虚空
   * （用户反馈"动画右侧有黑色区域，像遮罩"）——现在露出的是与真书架像素级一致的定格图。
   * t=0 与真书架逐像素重合（无衔接感）；返回落地后 onDisAppear 清空、换回真书架。
   * null = 快照失败 ⇒ 保留底下那层纯黑兜底（回到四轮前的观感）。
   */
  @State ltBackdrop: image.PixelMap | null = null
  /** 当前这次飞行的数据/几何（非 @State：只在 delegate 里读写，不参与渲染） */
  private ltFlight: LongTakeFlightData | null = null
  private ltGeom: LongTakeGeom | null = null
  /**
   * 飞行代际：delegate 每次武装新飞行时 +1（致命卡死修复，2026-09-24）。
   * 用途见飞行分支 onDisAppear 清理块的「代际守卫」：清理定时器（+80ms）到点时
   * 若代际已变（用户快速连点、新飞行已开始），本次清理整体让位——否则会把
   * 新飞行的 ltArm/ltFlight/ltGeom/ltBackdrop 抹掉，导致转场进行中
   * NavDestination 被撕掉重建（真机实锤：手势全失效、返回 `backEvent is null`
   * 派发失败直接回桌面）。
   */
  private ltFlightGen: number = 0

  // ══════════════════════════════════════════════════════════════════════════
  // 「书架 ↔ 我的」切换动画（2026-09-24，需求第 2 项）—— 当天返工两次，最终版在下面
  // ══════════════════════════════════════════════════════════════════════════
  //
  // ── 三次改版的经过 ────────────────────────────────────────────────────────
  // ① **淡入淡出**（`customContentTransition` 驱动 opacity/scale）—— 用户否掉：
  //    「书架到我的**不能淡入淡出**，这样会很奇怪，有没有更好的切换方式，**平移**吧，
  //      我给你个参考 D:\Arkts\xiaowei 你看一下，他的平移动画就很好。」
  // ② **两页各自平移拼接**（`customContentTransition` 驱动 translate，旧页 `0→-D`、新页 `+D→0`）
  //    —— 用户否掉：「来回点了几次，我发现动效很**割裂**，就像是书架和我的**中间有白色连接**一样。」
  // ③ **本版：删掉自定义转场，回到官方内置平移，只调曲线与时长**。
  //
  // ── 为什么 ② 必然出缝 ─────────────────────────────────────────────────────
  // documentId `FAQ/UI框架/UI界面/如何设置TabContent切换动画/faqs-arkui-1112`
  //   场景二（"点击页签，TabContent 有左右切换效果…"）原文：
  //   「**Tabs组件无法实现页面拼接。**」
  //   ⇒ 让两个 TabContent 各自 `translate`、靠宽度精确对齐去"拼接"，正是官方明说不成立的做法；
  //     对不齐的那部分就露出底色 —— 就是用户看到的那条白缝。
  //
  // ── ③ 的依据 ──────────────────────────────────────────────────────────────
  // documentId `开发指南/ArkUI_方舟UI框架/…/选项卡_Tabs/arkts-navigation-tabs`
  //   「TabContent切换动画」小节原文：
  //   「**Tabs 自带的页签切换动画为平移动画。**若开发者需实现更高级的动画效果，
  //      可通过 Tabs 提供的 API 实现自定义动画。」
  //   ⇒ 用户要的"平移"，**内置动画本来就是**；而且由 Tabs 分页器**整体搬运一条连续的内容带**，
  //     两个页签由同一机制同步位移 ⇒ **结构上不可能出现两页之间的缝**。
  //   ⇒ 所以本版不再自绘，只改内置平移的两颗旋钮：`animationCurve` / `animationDuration`。
  //
  // ── 参数来源（参考项目 `xiaowei`）─────────────────────────────────────────
  // `D:\Arkts\xiaowei\entry\src\main\ets\pages\Index.ets:77-82`（各页同款 `pageTransition`）：
  //   PageTransitionEnter/Exit({ type: RouteType.Push/Pop, duration, **curve: Curve.FastOutSlowIn** })
  //     .slide(SlideEffect.Right/Left)
  // ⇒ 曲线取 `Curve.FastOutSlowIn`（见 `UiMotion.TABS_ANIM_CURVE`）；
  //   时长取 `UiMotion.TABS_ANIM_DUR`（`xiaowei` 默认 521ms，本工程取 420ms）。
  //   两颗旋钮都写在 `UiMotion.ets`，改一处即全局生效。
  /**
   * Navigation 的页面栈（2026-09-21 起）。
   * 通过 `AppRouter.attach()` 交给路由门面，供后续迁移的页面入栈/出栈。
   */
  pageStack: NavPathStack = new NavPathStack()
  // 主题颜色
  @StorageProp(ThemeStorageKey.THEME) theme: ThemeItem = {} as ThemeItem
  // ---------- 桌面快捷方式（快速听书 / 快速阅读）----------
  /**
   * 由 `EntryAbility.captureQuickAction()` 写入，值 `'listen'` | `'read'`。
   * 用 `@StorageLink + @Watch` 而不只靠 `onPageShow`：这样**应用已在后台时**
   * 点快捷方式（走 `onNewWant`）也能立刻响应，而不必等页面重新显示。
   */
  @StorageLink('quickAction') @Watch('onQuickActionChanged') quickAction: string = ''

  onQuickActionChanged(): void {
    this.consumeQuickAction();
  }

  /**
   * 消费快捷方式意图 → 打开「**真正最后一次阅读**」的书。
   *
   * 数据来源 `BooksDao.getLastReadBook()`：纯 `durChapterTime DESC` 取第一条，
   * 且过滤掉 `durChapterTime = 0`（从未读过）的书 —— 所以拿到的一定是**真的最后读过**那一本，
   * 而不是"置顶书"或"随便一本未读书"。
   *
   * **先同步清空标记、再异步查询**：`@Watch` 与 `onPageShow` 谁先到都可能，
   * 清空在前可保证只跳一次。
   */
  private consumeQuickAction(attempt: number = 0): void {
    const action = this.quickAction;
    if (action !== 'listen' && action !== 'read') {
      return;
    }
    // ── 等启动就绪标记 ───────────────────────────────────────────────────
    // 历史原因：欢迎页 `onPageHide()` 会 `router.clear()`，与本页 `onPageShow` 抢时序
    //   ⇒ 真机日志实测 `clear router stack` 紧跟 `pushUrl ReaderPage3`，阅读页成了栈里
    //     唯一页面 ⇒ **返回直接回桌面**。当时的修法是等 `startupStackCleared`。
    // 2026-09-23：欢迎页已删除（用户要求去掉启动页），**不再有任何 `router.clear()`**，
    //   该标记现在由本页 `aboutToAppear()` 直接置位 ⇒ 这段等待逻辑保留但不再回退重试。
    if (attempt === 0 && !(AppStorage.get<boolean>('startupStackCleared') ?? false)) {
      if (attempt < 25) {
        setTimeout(() => {
          this.consumeQuickAction(attempt + 1);
        }, 200);
      }
      return;
    }
    // ── Bug B 修复：已经在阅读页上时，不再 push，交给阅读页就地切换模式 ──
    // 否则表现为"点了没反应"或叠出第二个阅读页（用户实测：阅读页里点快速听书无效）。
    try {
      // 迁 Navigation 第 3 期：阅读页现在是 NavDestination，**不再出现在 router 的状态里**，
      // 所以改问路由门面的栈顶（`AppRouter.topName()`）。若仍查 router，会判断不出
      // "已经在阅读页"，于是叠出第二个阅读页（正是这段代码当初要修的问题）。
      if (AppRouter.topName() === RouteName.READER) {
        return; // 由 ReaderPage3 自己的 quickAction 监听消费
      }
    } catch (e) {
      // 取不到状态就按正常流程走
    }
    AppStorage.setOrCreate('quickAction', '');
    this.openLastReadBook(action === 'listen');
  }

  private openLastReadBook(autoListen: boolean): void {
    BooksDao.getLastReadBook().then((book: Books | null) => {
      if (book === null) {
        // 兜底：不留静默失败
        showMessage('还没有阅读记录，先去书架挑一本吧');
        return;
      }
      // 迁 Navigation 第 3 期：阅读页已改为 NavDestination，改走路由门面。
      // 参数必须用**显式类型**（ArkTS 的 arkts-no-untyped-obj-literals）。
      const rp: ReaderRouteParam = { bookData: book, quickListen: autoListen };
      if (!AppRouter.push(RouteName.READER, rp)) {
        showMessage('打开失败：页面栈尚未就绪');
      }
    }).catch((e: BusinessError) => {
      showMessage('读取阅读记录失败：' + e.message);
    });
  }

  /**
   * 夜间开关变化 ⇒ 重新下发 Ability 配色（书架深 / 我的浅，规则见 `NightMode.desiredDark()`）。
   * ⚠️ 阅读器打开时本页**不会**也不该抢这个方向盘：`desiredDark()` 里
   * `readerActive` 优先，两边算出来是同一个答案，谁调都不会打架。
   */
  onNightModeChanged(): void {
    NightMode.setMainTab(this.currentTabIndex)
    NightMode.sync(this.getUIContext().getHostContext() as common.UIAbilityContext)
  }

  onPageShow(): void {
    // 冷启动场景：@Watch 只在"绑定之后发生变化"时触发，
    // 快捷方式在 onCreate 里就写好了标记，所以这里也消费一次（幂等，见 consumeQuickAction）。
    this.consumeQuickAction();
    // ★ 回前台/回到本页时重新对一次配色（例如用户是在阅读器里切的夜间，返回时本页可能没被重建）
    NightMode.setMainTab(this.currentTabIndex)
    NightMode.sync(this.getUIContext().getHostContext() as common.UIAbilityContext)
    // 退出阅读页面后恢复系统亮度
    BrightnessUtil.setBrightness('default', -1)
    // 退出阅读页面后显示状态栏。
    // ⚠️ 2026-09-22 真机反馈修复：**这一处已经不再是主要恢复点了**。
    //    阅读页迁成 `NavDestination` 后（见本文件 :328），`Index` 压栈时**不会被隐藏**
    //    ⇒ `onPageShow` 不会因"从阅读页返回"而触发，这行实际上不执行。
    //    真正的恢复点已移到 `ReaderPage3.aboutToDisappear()`
    //    （与它 `aboutToAppear` 里的隐藏**成对**，依据见那里的详细注释）。
    //    这里保留是为了覆盖"`Index` 自身真的经历显示周期"的场景（如从后台回前台），无害。
    WindowAbility.getInstance().toggleWindowSystemBar(['status', 'navigation'], this.getUIContext().getHostContext());
    // initBookListData()
    setTimeout(() => {
      this.showReadShow = false
      this.isShow = false
    }, 5000)

    // T13/D-17：`getContext()`（@deprecated since 18）→ `UIContext.getHostContext()`（确定性取值）
    console.debug('res1', this.bottomRectHeight)
  }

  screenShot() {
    // 切换回首页
    let index = this.currentTabIndex
    this.tabController.changeIndex(0)
    this.getUIContext().getComponentSnapshot().get('main', ((err: Error, pixmap: image.PixelMap) => {
      if (err) {
        console.log("error: " + JSON.stringify(err))
        return
      }
      AppStorage.setOrCreate('screen_shot', pixmap)
    }))
    // 恢复当前页
    this.tabController.changeIndex(index)
  }

  /**
   * 启动初始化（2026-09-23 从**已删除的 `welcomePage`** 搬过来，合并进原有的 aboutToAppear）。
   *
   * 原流程：`EntryAbility.loadContent('pages/welcomePage')` → 欢迎页 `onPageShow` 里
   * `initAppData()` + 1.5s 后 `router.replaceUrl('pages/Index')`。
   * 用户要求「直接去掉启动动画页，毫无意义」⇒ `EntryAbility` 现在**直接加载本页**，
   * 初始化搬到本方法开头：早于首次 `build()`，书架不会先渲染成空；
   * 页面上下文里 `getContext()` 可用（与原来在欢迎页调用等价）。
   */
  aboutToAppear(): void {
    // ★ 启动数据初始化（原来在 welcomePage 里做）
    initAppData();
    // 现在**不存在** `router.clear()`（欢迎页已删）⇒ 这个"等清栈"标记不再有竞态，
    // 直接置位；`consumeQuickAction()` 首次调用即可通过（原来要等欢迎页 replaceUrl）。
    AppStorage.setOrCreate('startupStackCleared', true);
    // 退出阅读页面后显示状态栏。
    // ⚠️ 2026-09-22：这只在 `Index` **首次创建**时跑一次，无法覆盖"从阅读页返回"。
    //    恢复点见 `ReaderPage3.aboutToDisappear()`。保留此处无害（幂等）。
    WindowAbility.getInstance().toggleWindowSystemBar(['status', 'navigation'], this.getUIContext().getHostContext());
    // 注册监听截图事件 用于我的页面下主题设置预览
    emitter.on('screen_shot', () => {
      this.screenShot()
    })
    //测试颜色模块
    testGetColorFunction();
    // ★ 首帧前就把配色对齐（冷启动时夜间开关可能已经是持久化的 true）
    NightMode.setMainTab(this.currentTabIndex)
    NightMode.sync(this.getUIContext().getHostContext() as common.UIAbilityContext)
  }

  /**
   * 底部页签**未选中**态的颜色。
   * 原来是写死的 `'#000000'`；书架做了深色适配后，深色档下必须翻成浅色，
   * 否则「我的」那格会是黑字压在深色悬浮条上（材质已跟随应用配色变深）。
   */
  private tabIdleColor(): string {
    return NightMode.isDarkSurface() ? 'rgba(248, 249, 250, 0.72)' : '#000000'
  }

  @Builder
  TabBuilder(index = 0, name: string, icon_select: Resource, unselected: Resource) {
    Column() {
      Flex({
        direction: FlexDirection.Column,
        alignItems: ItemAlign.Center,
        justifyContent: FlexAlign.Center
      }) {
        Image(this.currentTabIndex === index ? icon_select : unselected).height(25)
          .draggable(false)
          .fillColor(this.currentTabIndex === index ? this.theme.mainColor : this.tabIdleColor())
        Text(name).fontSize(11).margin(5).fontColor(this.currentTabIndex === index ? this.theme.mainColor : this.tabIdleColor())
      }
    }
    .width('100%')
    .margin({ top: 4 })
    .height("100%")
  }

  // 底部导航（2026-09-21 精简）：**只留「书架」和「我的」**。
  // 原「发现」与「订阅源」两个 Tab 已整块移除（用户决定），所以索引从 4 个变成 2 个、
  // 「我的」由 3 变成 1；下面 `onAnimationStart` 里刷新计数的条件也同步改成 1。
  nav: NavItem[] = [
    new NavItem(0, $r("app.media.HOME_theme"), $r('app.media.HOME_line'), '书架'),
    new NavItem(1, $r('app.media.MINE_theme'), $r('app.media.MINE_line'), '我的')
  ]

  build() {
    // ── Navigation 宿主（2026-09-21 第 1 期：只搭骨架，零行为变化）──────────────
    // 官方两处硬前提都要求 Navigation 而不是 router：
    //   ① 标题栏沉浸光感生效范围：「其他组件**仅在** Navigation/NavDestination 标题栏，
    //      或横向 Tabs 中 barPosition 为 BarPosition.End 的底部 TabBar 中生效」；
    //   ② 一镜到底（skill `hmos-arkui-longtake-transition`）：「应用必须基于
    //      Navigation + NavDestination 的路由体系，**而非 Router**」。
    // 本期 `appRoutes()` 匹配不到任何 name ⇒ 所有页面仍走 router，视觉与行为不变。
    Navigation(this.pageStack) {
    Column() {
      Tabs({
        index: this.currentTabIndex,
        barPosition: BarPosition.End,
        controller: this.tabController
      }) {
        ForEach(this.nav, (item: NavItem) => {
          TabContent() {
            Column() {
              if (item.index === 0) {
                BookShelf()
              } else if (item.index === 1) {
                MyCenter()
              }
            }
          }.tabBar(
            this.TabBuilder(item.index, item.title, item.selectImg, item.unselected)
          )
          // 内容区延伸到状态栏区域（2026-09-21）。
          // 官方参考实现（documentId `…/沉浸光感典型场景/arkts-immersive-light-sample`）原文把
          // `.expandSafeArea([SafeAreaType.SYSTEM])` **同时**挂在 Tabs 和每个 TabContent 上，并在
          // 步骤说明里写明理由：「设置底部 Tabs 悬浮并为 Tabs 组件开启沉浸光感，同时使用
          // ExpandSafeArea 将显示内容延伸至状态栏区域，使应用整体体验更加一致。」
          // 本工程页面内部仍按 `topRectHeight` 自行避让文字，所以这里只是让**背景**铺到状态栏下，
          // 不会造成内容与状态栏重叠。
          .expandSafeArea([SafeAreaType.SYSTEM])
        })
      }
      .barHeight(this.ShowBar ? 56 : 0)
      // ══════════════════════════════════════════════════════════════════════
      // 页签切换动画（2026-09-24 最终版）：**用官方内置平移，只调曲线与时长**
      // ══════════════════════════════════════════════════════════════════════
      // 为什么不再自绘：官方 FAQ `faqs-arkui-1112` 场景二原文「**Tabs组件无法实现页面拼接。**」
      //   ⇒ 上一版让两个 TabContent 各自 `translate` 去拼接，必然在接缝处露出底色（用户看到的白缝）。
      //   而官方指南（documentId `…/选项卡_Tabs/arkts-navigation-tabs`）原文：
      //   「**Tabs 自带的页签切换动画为平移动画。**」—— 内置动画由分页器**整体搬运连续内容带**，
      //   结构上不可能出缝。
      //
      // ── `animationCurve` ─────────────────────────────────────────────────
      // SDK `component/tabs.d.ts:1219`（@since 20）。默认值原文：
      //   「When pages are turned by **swiping**, the default value is **interpolatingSpring(-1, 1, 228, 30)**.
      //     When pages are turned by **tapping tabs or calling the changeIndex API**, the default value is
      //     **cubicBezierCurve(0.2, 0.0, 0.1, 1.0)**. When a custom animation curve is set, it applies to
      //     **all** tab switching animations…」
      // ⇒ 2026-09-23 曾把它设成系统那条"滑动弹簧"（`UiMotion.TABS_SWITCH`）让"点击也变弹簧"；
      //   本次按用户对参考项目 `xiaowei` 的偏好改为 `Curve.FastOutSlowIn`（`xiaowei` 的
      //   `pageTransition` 用的就是这条）。
      // ⚠️ 连带影响（说清楚）：官方原文「it applies to **all** tab switching animations」⇒
      //   **解锁标签栏后的左右滑动**也会从弹簧变成 `FastOutSlowIn`。滑动默认关闭
      //   （`APP_INDEX_SCROLLABLE` 默认 true ⇒ `.scrollable(false)`），影响面很小。
      .animationCurve(UiMotion.TABS_ANIM_CURVE)
      // ── `animationDuration` ──────────────────────────────────────────────
      // SDK `component/tabs.d.ts:1246`。默认值原文：「API version 11 and later versions: …
      //   the default value is **0** when the tab bar is set to **BottomTabBarStyle** and **300**
      //   when the tab bar is set to any other style.」（本工程用的是自绘 `TabBuilder` ⇒ 非
      //   BottomTabBarStyle ⇒ 默认 300。）
      // ⚠️ 关键约束（同文件 `:1228-1232`）原文：「For details about curves **unaffected by
      //   animationDuration**… These curves include **springMotion**, **responsiveSpringMotion**,
      //   and **interpolatingSpring**.」⇒ 弹簧曲线下这个参数**完全无效**；这也正是 2026-09-23
      //   那版 `TABS_SWITCH` 弹簧"改了时长没反应"的原因。现在曲线换成了具名曲线，它才生效。
      // 回退：删掉这两行 ⇒ 回到系统默认（点击 `cubicBezierCurve(0.2,0,0.1,1)` / 300ms）。
      .animationDuration(UiMotion.TABS_ANIM_DUR)
      // ★ 禁用手势滑动切换（2026-09-24 用户要求）：「书架和我的不再允许通过手势左右滑动
      //   切换，只能通过底部按钮」。原实现 `.scrollable(!APP_INDEX_SCROLLABLE)`，
      //   而 `APP_INDEX_SCROLLABLE` 默认 false（`storage/appData.ets:10`）⇒ 实际一直可滑。
      //   现在钉死 `false`；TabBuilder 上的长按解锁手势已一并删除。
      //   （`APP_INDEX_SCROLLABLE` 键保留，仍由「标签锁」开关控制**书架内部分类页签**的
      //   滑动 —— `IndexShelf.ets` 的 `.scrollable()`，与主页签无关。）
      // 回退：改回 `.scrollable(true)` 即恢复手势滑动。
      .scrollable(false)
      // ★ 关掉「拉到边界时的过滚动回弹」（2026-09-22 用户反馈修复）。
      //   用户原话：「书架和我的能左右滑动切换…但是不能往另一个方向滑动，
      //   现在往另一个方向滑动会有拉扯出白色区域」。
      //   SDK 依据（`tabs.d.ts:1282` 的 `edgeEffect(edgeEffect: Optional<EdgeEffect>)`）：
      //     「Sets the edge effect used when the boundary of the scrolling area is reached.
      //       Default value: **EdgeEffect.Spring**」
      //   ⇒ 默认 `Spring` 会在滑到第一个/最后一个页签之外时"拉出"一段空白再弹回，
      //     真机看就是"扯出一块白"。改成 `None`：到边界即停，不再拉白。
      //   `EdgeEffect = { Spring, Fade, None }`（`enums.d.ts`，全局枚举）。
      //   注意：这只影响**越界回弹**，不改变页签之间正常的左右滑动切换。
      .edgeEffect(EdgeEffect.None)
      // ── 沉浸光感悬浮页签（2026-09-21）────────────────────────────────────
      // 官方硬性约束（documentId `…/沉浸光感开发指导/组件适配沉浸光感/…`）原文：
      //   「悬浮样式仅在 barOverlap 为 true、vertical 为 false、barPosition 为
      //     BarPosition.End 时生效，三个条件需同时满足，否则 systemMaterial 设置不生效。」
      // 本组件：`barPosition: BarPosition.End` ✓、`vertical` 未设（默认 false）✓，
      // 所以这里补上 `barOverlap(true)` 就凑齐了三条件。
      //
      // 另外两条官方提醒也都遵守了：
      //   · 「设置悬浮材质后，不建议再通过 barBackgroundColor、barBackgroundBlurStyle
      //      为 TabBar 设置背景色或背景模糊，避免遮挡材质效果」——本文件没有设置这两个属性。
      //   · 「TabContent 不支持设置沉浸光感」——没有在 TabContent 上设材质。
      //
      // ⚠️ 布局连带变化：悬浮后页签条是**浮在内容之上**的，所以系统底部安全区避让
      //    从"给 Tabs 加 padding"改成"给悬浮条加 barBottomMargin"，否则两处叠加会把条顶太高。
      //    关闭沉浸光感时（`ImmersiveMaterialUtil.ENABLED = false`）两个表达式都会回到原样。
      .barOverlap(ImmersiveMaterialUtil.isOn())
      .barFloatingStyle(ImmersiveMaterialUtil.tabsFloatingStyle(this.bottomRectHeight + 8))
      .padding({ bottom: ImmersiveMaterialUtil.isOn() ? 0 : this.bottomRectHeight })
      // 同 TabContent 上的说明：官方参考实现给 Tabs 也挂了 expandSafeArea。
      .expandSafeArea([SafeAreaType.SYSTEM])
      .onAnimationStart((index, targetIndex) => {
        // 全局震动方案（2026-09-25）：底部页签切换给一次反馈。
        // 本工程 `.scrollable(false)`（见下方注释）⇒ 走到这里只会是"点了页签"，
        // 左右滑动已被禁，不存在"滑动切页也震"的误触。
        Haptics.tap();
        this.currentTabIndex = targetIndex
        // ★ 页签变了 ⇒ 重新算配色并下发：书架（0）= 深色档、我的（1）= 浅色档。
        //   规则与依据见 `NightMode.desiredDark()`。
        NightMode.setMainTab(targetIndex)
        NightMode.sync(this.getUIContext().getHostContext() as common.UIAbilityContext)
        // 切到「我的」（精简后 index = 1）时通知 `MyCenter` 重拉三个计数（读过/读完/书签）。
        // 为什么必须在这里做：`MyCenter` 是**子组件**、没有 `onPageShow`，
        // 而"读完一本书 → 返回 → 切到我的"正是不刷新就看不到新数字的主场景。
        // 机制见 `MyCenter.ets` 的 `@StorageLink('myCenterTick')`。
        if (targetIndex === 1) {
          AppStorage.setOrCreate('myCenterTick', Date.now())
        }
      })

      if (this.showReadShow) {
        ReadShow({ showReadShow: this.showReadShow }).offset({ y: -150 - this.bottomRectHeight })
      }
    }
    .width("100%")
    .height("100%")
    .id('main')
    }
    .hideTitleBar(true)
    // ★ 书架 NavBar 可见性变化 ⇒ 记录书架层可见性（保留键位）。
    //   ⚠️ 2026-09-24 屏闪修复：这里**不能再调 `NightMode.sync()`**。
    //   真机日志（2026-09-23 日志2）实证：push 阅读器时 `NavBar Visible State Change
    //   true -> false`（28.411）与 `SetAbilityColorMode colorMode: 1`（28.412）同帧 ——
    //   此回调在转场**开始那一帧**触发，sync 会把整个 Ability 翻成书的日间配色，
    //   暗色书架在 560ms 入场动画里被全窗重涂成亮色 ⇒ 开书必闪。
    //   对非阅读页它本来就是视觉 no-op（`desiredDark()` 不读 HOME_KEY，
    //   见 NightMode.ets「保留键位，暂不参与裁决」注释）⇒ 删掉只去 bug、不改行为。
    //   阅读器的配色翻转已由 `ReaderPage3.aboutToAppear` 的延迟块（转场结束后）负责。
    .onNavBarStateChange((isVisible: boolean) => {
      NightMode.setHomeVisible(isVisible)
    })
    .navDestination(this.appRoutes)
    .onAppear(() => {
      // 把 Navigation 的页面栈交给路由门面：后续迁移的页面通过 `AppRouter` 入栈/出栈。
      AppRouter.attach(this.pageStack)
    })
    .width('100%')
    .height('100%')
  }

  // ═══ 一镜到底：转场 delegate 与进/出两段编排 ═══════════════════════════════
  // 写法对齐官方示例2（documentId `API参考/ArkUI_方舟UI框架/ArkTS组件/导航与切换/
  // NavDestination/ts-basic-components-navdestination` 示例2）：
  // 起始帧在 delegate 里【同步】设好；返回的 transition 只做「点火」，
  // 真正编排由 event 里的显式 animateTo 串行驱动（探针已验证该机制真机成立）。

  /**
   * READER「飞行分支」的 customTransition delegate。
   * 只有飞行分支会挂它 ⇒ 走到这里就意味着本次是书架点击进入（rp.longTake 必有值）。
   */
  private ltDelegate(op: NavigationOperation, isEnter: boolean, rp: ReaderRouteParam)
    : Array<NavDestinationTransition> | undefined {
    console.info('LTBOOK', `delegate op=${op} isEnter=${isEnter} arm=${this.ltArm}`)
    if (op === NavigationOperation.PUSH && isEnter) {
      const f = rp.longTake !== undefined ? rp.longTake : null
      this.ltFlight = f
      this.ltActive = f !== null
      if (f === null) {
        // 兜底：臂旗在但飞行数据不在（理论不可达）⇒ 交回系统默认
        return undefined
      }
      // ★ 新飞行开始：代际 +1 —— 在途的上一次清理定时器到点时据此让位
      // （快速连点场景：上一次关书的 80ms 清理会迟到到本次开书之后才触发）
      this.ltFlightGen++
      const g = LongTakeGeom.from(f, this.getUIContext())
      this.ltGeom = g
      // 起始帧：同步设置（此刻目标页尚未渲染首帧 —— 探针已验证此机制生效）
      this.ltScale = g.s0
      this.ltTx = g.tx0
      this.ltTy = g.ty0
      this.ltClipH = g.clipH0
      this.ltCoverRadius = g.coverRadius
      this.ltCoverAngle = 0
      this.ltCoverOpacity = 1
      this.ltCoverUrl = f.coverUrl
      this.ltBackdrop = f.backdrop
      const trans: Array<NavDestinationTransition> = [{
        duration: UiMotion.LT_ENTER_DUR,
        curve: Curve.Linear,
        event: (): void => {
          this.ltRunEnter()
        },
        onTransitionEnd: (): void => {
          console.info('LTBOOK', 'enter transition end')
        }
      }]
      return trans
    }
    if (op === NavigationOperation.POP && !isEnter) {
      if (this.ltFlight === null || this.ltGeom === null) {
        return undefined
      }
      const trans: Array<NavDestinationTransition> = [{
        duration: UiMotion.LT_POP_DUR,
        curve: Curve.Linear,
        event: (): void => {
          this.ltRunPop()
        },
        onTransitionEnd: (): void => {
          console.info('LTBOOK', 'pop transition end')
          // ★ 配色还原·兜底点①（2026-09-24 第三轮起降级为兜底）：主还原点已前移到
          //   两个 READER 分支的 `onWillDisappear`（返回**转场开始前**，见
          //   `restoreReaderColorMode()` 注释）。真机日志2 证明本回调在转场结束
          //   （30.431）才触发、晚于真书架可渲染的时机，作为主还原点会留 13ms+ 的
          //   错色首帧窗口 ⇒ 保留只为幂等兜底（onWillDisappear 因异常未触发时补还原）。
          this.restoreReaderColorMode()
        }
      }]
      return trans
    }
    return undefined
  }

  /**
   * 进场编排（四轮定型的"打开一本书"模型；五轮仅把背景从变暗层换成书架定格快照）：
   * ① 包络 0→TOTAL：整本书（封面+内容页连体）放大、铰链从封面原位漂移到屏幕左缘；
   *   内容页裁切窗口同步从封面纵横比长到全屏 —— "内容页随放大变成全屏阅读器"
   * ② 封面绕书脊掀开 80→560ms：左侧两角（书脊）小幅度、右侧两角大幅度向左扫，
   *   透视下投影渐窄 ⇒ 内容页从右侧渐进露出
   * ③ 封面淡出 480→560ms：盖住 >90° 背面镜像穿帮
   * 背景（快照垫层）全程静止不动 —— 与真书架像素级一致，无衔接感。
   */
  private ltRunEnter(): void {
    const g = this.ltGeom
    if (g === null) {
      return
    }
    const ui = this.getUIContext()
    // ① 包络：书整体放大向左靠拢，内容页（裁切窗口）同步长到全屏（全是图形变换，正文不重排）
    ui.animateTo({
      duration: UiMotion.LT_ENTER_DUR,
      curve: Curve.Friction,
      onFinish: (): void => {
        console.info('LTBOOK', 'enter flight done')
      }
    }, (): void => {
      this.ltScale = 1
      this.ltTx = 0
      this.ltTy = 0
      this.ltClipH = g.clipH1
    })
    // ② 封面绕书脊掀开（方向语义见 UiMotion.LT_FLIP_ANGLE 注释；真机上若方向反了改那个符号）
    ui.animateTo({
      delay: UiMotion.LT_FLIP_DELAY,
      duration: UiMotion.LT_FLIP_DUR,
      curve: Curve.Friction
    }, (): void => {
      this.ltCoverAngle = UiMotion.LT_FLIP_ANGLE
    })
    // ③ 封面淡出：盖住 >90° 时背面镜像的穿帮（spec §5.2）
    ui.animateTo({
      delay: UiMotion.LT_FADE_DELAY,
      duration: UiMotion.LT_FADE_DUR
    }, (): void => {
      this.ltCoverOpacity = 0
    })
    // 诊断（五轮）：飞行中段量一次书架根节点 'main' 的实际宽度 ——
    // 若小于窗口宽 ⇒ 证实"系统把 NavBar 缩宽"（右侧黑条的另一候选根因），留给下轮排查
    setTimeout((): void => {
      try {
        const m = ui.getComponentUtils().getRectangleById('main')
        console.info('LTBOOK',
          `diag main mid-flight: ${JSON.stringify(m.size)} offset=${JSON.stringify(m.windowOffset)}`)
      } catch (e) {
        console.info('LTBOOK', `diag main mid-flight failed: ${(e as Error).message}`)
      }
    }, 300)
  }

  /**
   * 返回编排（进场的镜像）：
   * ① 封面立即淡入 0→80ms → ② 包络倒放 0→560ms（整本缩回封面原位，内容页缩回书脸）
   *   ∥ 封面合上 0→480ms；背景（快照垫层）全程不动，落地 onDisAppear 时换回真书架。
   */
  private ltRunPop(): void {
    const g = this.ltGeom
    if (g === null) {
      return
    }
    const ui = this.getUIContext()
    // ① 封面先恢复不透明
    ui.animateTo({
      duration: UiMotion.LT_POP_FADEIN_DUR
    }, (): void => {
      this.ltCoverOpacity = 1
    })
    // ②a 包络倒放：整本书缩回书架封面原位原尺寸
    ui.animateTo({
      duration: UiMotion.LT_POP_DUR,
      curve: Curve.Friction,
      onFinish: (): void => {
        console.info('LTBOOK', 'pop shrink done')
      }
    }, (): void => {
      this.ltScale = g.s0
      this.ltTx = g.tx0
      this.ltTy = g.ty0
      this.ltClipH = g.clipH0
    })
    // ②b 封面合上（0→480ms，与包络同步，进场掀开的镜像）
    ui.animateTo({
      duration: UiMotion.LT_FLIP_DELAY + UiMotion.LT_FLIP_DUR,
      curve: Curve.Friction
    }, (): void => {
      this.ltCoverAngle = 0
    })
  }

  /**
   * 阅读页返回时的「**App 配色还原**」（只做配色，不动系统栏/避让）。
   *
   * 关闭书籍屏闪修复（2026-09-24 第三轮，真机日志2 取证）：
   * 用户实测「App 暗色 + 书日间，关闭书籍后整个软件闪一下亮色再回暗色」。
   * 前两轮（09-23 迁出 aboutToDisappear、09-24 onTransitionEnd）都以为自己在
   * "转场开始/结束的安全点"还原，但真机日志证明：`aboutToDisappear`/`onDisAppear`
   * 都在**转场结束之后**才触发（日志2：transition finish 30.431 → onDisappear 30.440），
   * `onTransitionEnd`（30.431）与 Ace 主题重涂（30.444）之间真书架已按**书的配色**
   * 渲染了首帧 ⇒ 落位即闪。
   *
   * 现在 `sync()` 的还原点收敛为：
   *   ① **主还原点**：两个 READER 分支的 `onWillDisappear`（返回**转场开始前**，
   *      日志2：onWillDisappear 29.869 < animateTo 29.870）—— 收缩动画全程书架已是
   *      正确深浅色，落位帧零重涂；
   *   ② 兜底：`onTransitionEnd` + 两分支 `onDisAppear` 同步段（幂等短路，不再翻转）。
   *
   * 回退：删掉两个 `onWillDisappear` 里的 `restoreReaderColorMode()` 调用，
   * 即回到 09-24 第二轮行为（还原点只剩转场结束后）。
   */
  private restoreReaderColorMode(): void {
    NightMode.setReaderActive(false)
    NightMode.sync(this.getUIContext().getHostContext() as common.UIAbilityContext)
  }

  /**
   * 阅读页返回**转场结束后**的系统级收尾（两个入口分支的 `onDisAppear` 共用）。
   *
   * 亮暗色/屏闪重构（2026-09-23）：这三件事原来都在 `ReaderPage3.aboutToDisappear`
   * （= 返回转场开始）执行 ⇒ 转场中途系统栏恢复 + 避让解冻 + Ability 配色翻转，
   * 世界在动画里发生系统级跳变（用户实测的"关闭书籍屏闪"）⇒ 全部推迟到这里。
   * 设计依据（存旧值原样还回、不做重算）见 `WindowAbility.restoreTopRect()`。
   * ⚠️ 2026-09-24：其中的配色还原已**提前**到 `restoreReaderColorMode()` 的两个还原点
   * （见其注释）；这里保留同一份调用只作幂等兜底，实际不会再翻转。
   */
  private releaseReaderImmersive(): void {
    WindowAbility.getInstance().restoreTopRect();
    WindowAbility.getInstance().toggleWindowSystemBar(['status', 'navigation'],
      this.getUIContext().getHostContext());
    NightMode.setReaderActive(false);
    NightMode.sync(this.getUIContext().getHostContext() as common.UIAbilityContext);
  }

  /**
   * NavDestination 路由表。
   *
   * **第 1 期为空**：所有页面仍走 `router`，这里匹配不到任何 name，行为与改造前一致。
   * 后续每迁一个页面：在 `RouteName` 加常量 → 在这里加分支 → 把该页面的
   * 「入栈 / 返回」一起改成 `AppRouter.push()` / `AppRouter.pop()`
   * （**必须成对改**：走 pathStack 进来的页面若调 `router.back()`，会把整个 Index 弹掉、直接回桌面）。
   */
  @Builder
  appRoutes(name: string, param: object) {
    if (name === RouteName.BOOK_DETAIL) {
      // ── 第 2 期：书籍详情页 ────────────────────────────────────────────
      // 原 `pages/view/BookDetailPage`（@Entry）已去掉 @Entry，参数经下面的 `@Prop bookData` 注入。
      // `.hideTitleBar(true)`：该页**自带标题栏**（原 @Entry 页面同样没有系统标题栏），保持外观一致。
      NavDestination() {
        BookDetailPage({ initBook: param as Books })
      }
      .hideTitleBar(true)
      .systemTransition(UiMotion.pageTransition(UiMotion.T_DETAIL))
    } else if (name === RouteName.READER) {
      // ── 第 3 期：阅读页 ────────────────────────────────────────────────
      // 参数含 `bookData` / `clickBookCatalogId` / `quickListen` / `bmChapterIndex` / `bmNode`，
      // 统一经显式声明的 `ReaderRouteParam` 传入
      // （ArkTS 的 `arkts-no-untyped-obj-literals` 禁止无类型字面量传给 `object` 参数）。
      // 2026-09-23：一镜到底正式版。`ltArm` 臂旗由书架点击在 push 前置位（见上方字段区注释）：
      //   置位 ⇒ 建成「飞行分支」（挂 customTransition，演一镜到底）；
      //   未置位（详情页 / 快捷方式 / 书签回跳）⇒ 走 else 普通分支，EXPLODE 原样保留。
      // 几何模型见 `LongTakeBook.ets` 头注释；编排参数见 `UiMotion.LT_*` 令牌。
      if (this.ltArm) {
        // 五轮结构（2026-09-23）—— z 序从下到上：
        //   [纯黑兜底] → [书架定格快照] → [包络：[内容页=阅读器裁到书脸] + [封面] ]
        // 快照垫层的由来：系统会中途隐藏/恢复书架 NavBar，包络四周原先露出的是黑虚空
        // （用户反馈"动画右侧有黑色区域，像遮罩"）；现在露出的是与真书架像素级一致的
        // 定格图 —— t=0 无缝、飞行中自然、返回落地 onDisAppear 时换回真书架。
        NavDestination() {
          Stack() {
            // 兜底黑底：仅快照失败（ltBackdrop=null）时可见
            Column()
              .width('100%')
              .height('100%')
              .backgroundColor(Color.Black)
              .hitTestBehavior(HitTestMode.None)
            if (this.ltBackdrop !== null) {
              Image(this.ltBackdrop)
                .width('100%')
                .height('100%')
                .hitTestBehavior(HitTestMode.None)
            }
            // ── 书的包络（六轮修正 2026-09-23）────────────────────────────────
            // 三层嵌套各司其职（由外到内）：translate（铰链漂移）→ scale（放大，锚点 (0,0)）
            // → clip（裁出"书脸"）。translate 必须在这一层（只包住"书"），绝不能挂到外层
            // 根节点——根节点上还有定格快照/黑底，挂上去整个"世界"会被书拖着平移
            //（用户实测：右侧复刻出一个被拉着缩放的书架页、关闭时下移消失）。
            Stack() {
              Stack() {
                Stack() {
                  // 内容页：真阅读器，裁到"书脸"（高度=书脊高度，与封面等高相连）
                  ReaderPage3({ initParam: param as ReaderRouteParam })
                }
                .width('100%')
                .height('100%')
                .clip(new Rect({ width: '100%', height: this.ltClipH }))
                // ⚠️ Rect 原点恒为组件左上角（SDK `rect.d.ts` 的 RectOptions 没有 x/y）
                // 封面：与书架封面同图源（命中缓存，首帧即显）；高度=内容页高度（书脊等高）。
                // ⚠️ 它是裁切层的**兄弟层**（同在 scale 层里）：掀开时要扫出"书"的边界，
                // 放进裁切层会被 clip 切掉 3D 感。
                Image(this.ltCoverUrl)
                  .draggable(false)
                  .alt($r('app.media.icon_book_default_cover_one'))
                  .width('100%')
                  .height(this.ltClipH)
                  .borderRadius(this.ltCoverRadius)
                  .shadow({ radius: 12, color: 'rgba(0, 0, 0, 0.22)', offsetX: 0, offsetY: 5 })
                  .rotate({ y: 1, centerX: 0, angle: this.ltCoverAngle })
                  .opacity(this.ltCoverOpacity)
                  // 纯视觉层：rest 态下它是一张铺满全屏的透明图，若不退出命中测试，
                  // 会把正文的点击/翻页手势全吃掉（Image 无子节点，AGENTS.md 的"子节点照样吃触摸"不适用）
                  .hitTestBehavior(HitTestMode.None)
              }
              .width('100%')
              .height('100%')
              .alignContent(Alignment.TopStart)
              .scale({ x: this.ltScale, y: this.ltScale, centerX: 0, centerY: 0 })
            }
            .width('100%')
            .height('100%')
            .translate({ x: this.ltTx, y: this.ltTy })
            // None 只让容器自身退出命中，子节点（阅读器）照样吃触摸（AGENTS.md 实测结论）
            .hitTestBehavior(HitTestMode.None)
          }
        }
        .hideTitleBar(true)
        // 飞行/返回期间让书架透出来（书从列表里起飞、降落回列表）；
        // 阅读期正文自身满屏底色，透明背景不影响阅读。
        .backgroundColor(Color.Transparent)
        // customTransition 生效性与分支绑死：普通分支不挂它 ⇒ EXPLODE 完全不受影响
        .customTransition((op: NavigationOperation, isEnter: boolean)
          : Array<NavDestinationTransition> | undefined => {
          return this.ltDelegate(op, isEnter, param as ReaderRouteParam)
        })
        // ⚠️ 通用事件名是 `onDisAppear`（common.d.ts:20001，组件移出树时触发 ⇒ 返回转场之后）；
        //    NavDestinationAttribute 上没有 onDisappear 拼法（编译器实测纠正）。
        // ★ 配色还原·主还原点（2026-09-24 屏闪修复第三轮）：
        //   `onWillDisappear`（SDK `nav_destination.d.ts:949`，@since 12）在返回**转场开始前**
        //   触发（真机日志2：onWillDisappear 29.869 < animateTo 29.870 < 转场结束 30.431）。
        //   在这里把 Ability 配色还原成三档裁决值 ⇒ 收缩动画全程书架已是正确深浅色、
        //   落位帧**零重涂**，不再有「落位后闪一下亮色再变暗」。
        //   （此前两轮把还原放在 onTransitionEnd/onDisAppear —— 真机日志证明它们都在
        //   转场结束**之后**才触发：真书架先按书的配色渲染了首帧，再被全窗重涂成
        //   三档配色 —— 这正是用户看到的落位闪屏。）
        .onWillDisappear(() => {
          this.restoreReaderColorMode()
        })
        .onDisAppear(() => {
          // ★ 配色还原·兜底点②：同步执行（不能进 setTimeout —— 那是给切分支保险用的，
          //   配色压在里面会产生「真书架已显示却还是书的配色」的 80ms 亮/暗闪窗）。
          //   主还原点在 onWillDisappear（转场开始前），这里幂等短路。
          this.restoreReaderColorMode()
          // 弹栈完成后解除臂旗（下次非书架入口回到普通分支）+ 阅读页系统级收尾。
          // setTimeout 保险：若 onDisAppear 在返回转场尚未完全收尾时先行触发，
          // 立刻切分支会把飞行层在转场里拆掉。
          // ★ 代际守卫（2026-09-24 致命卡死修复）：清理定时器到点时若已有**新飞行**
          //   开始（快速连点：关书后 80ms 内又点开下一本），本次清理必须整体让位。
          //   旧实现无差别清空 ltArm/ltFlight/ltGeom/ltBackdrop ⇒ 新飞行的臂旗被抹，
          //   appRoutes 的 if(this.ltArm) 在**转场进行中**把飞行 NavDestination 撕掉
          //   重建 ⇒ Navigation 栈/转场状态错乱（真机日志实锤：12.533 新飞行 delegate
          //   → 12.538 旧清理抹状态 → 12.543 新建的目的地 11699 被销毁 → 13.326 返回
          //   `backEvent is null` 派发失败直接回桌面、手势全失效）。
          //   让位后不清理也安全：新飞行的 delegate 已覆写全部数据字段，且新飞行自己
          //   的 onDisAppear 会安排属于自己的清理（自愈）；系统栏/避让由新飞行的
          //   aboutToAppear 延迟块（+620ms）重新冻结+隐藏。
          const genAtDisappear = this.ltFlightGen
          setTimeout((): void => {
            if (this.ltFlightGen !== genAtDisappear) {
              console.info('LTBOOK', 'cleanup skipped: superseded by newer flight')
              return
            }
            this.releaseReaderImmersive()
            this.ltArm = false
            this.ltActive = false
            this.ltFlight = null
            this.ltGeom = null
            this.ltBackdrop = null
            console.info('LTBOOK', 'arm released')
          }, 80)
        })
      } else {
        NavDestination() {
          ReaderPage3({ initParam: param as ReaderRouteParam })
        }
        .hideTitleBar(true)
        .systemTransition(UiMotion.pageTransition(UiMotion.T_READER))
        // ★ 配色还原·主还原点（普通分支同飞行分支，见上方 onWillDisappear 注释）：
        //   返回转场开始前还原 ⇒ EXPLODE 动画全程书架已是正确深浅色，落位帧零重涂。
        .onWillDisappear(() => {
          this.restoreReaderColorMode()
        })
        // 阅读页系统级收尾（详情页等入口同样需要）：返回转场结束后恢复系统栏/避让/配色。
        .onDisAppear(() => {
          // ★ 配色还原·兜底点②（主还原点在 onWillDisappear，这里幂等短路）。
          this.restoreReaderColorMode()
          setTimeout((): void => {
            this.releaseReaderImmersive()
          }, 80)
        })
      }
    } else if (name === RouteName.NONE) {
      // 占位分支，永不匹配；避免空 @Builder 的编译告警
      Column()
    } else if (name === RouteName.BOOK_MANAGE) {
      // ── 第 4 期：书架管理页 ────────────────────────────────────────────
      // 参数沿用原 `routerParams` 的三个字段（见 `BookManageRouteParam`）。
      NavDestination() {
        BookManagePage({ routeParam: param as BookManageRouteParam })
      }
      .hideTitleBar(true)
      .systemTransition(UiMotion.pageTransition(UiMotion.T_SETTING))
    } else if (name === RouteName.READ_STATISTICS) {
      // ── 第 4 期：读过/读完/书签 ────────────────────────────────────────
      NavDestination() {
        ReadStatistics({ routeParam: param as ReadStatisticsRouteParam })
      }
      .hideTitleBar(true)
      .systemTransition(UiMotion.pageTransition(UiMotion.T_SETTING))
    } else if (name === RouteName.THEME_CONFIG) {
      // ── 第 4 期：主题配置 ─────────────────────────────────────────────
      NavDestination() {
        MyThemeConfig()
      }
      .hideTitleBar(true)
      .systemTransition(UiMotion.pageTransition(UiMotion.T_SETTING))
    } else if (name === RouteName.CUSTOM_THEME) {
      // ── 第 4 期：自定义主题 ───────────────────────────────────────────
      NavDestination() {
        CreateCustomTheme()
      }
      .hideTitleBar(true)
      .systemTransition(UiMotion.pageTransition(UiMotion.T_SETTING))
    } else if (name === RouteName.MY_SET) {
      // ── 第 4 期：我的设置 ─────────────────────────────────────────────
      NavDestination() {
        MySetPage()
      }
      .hideTitleBar(true)
      .systemTransition(UiMotion.pageTransition(UiMotion.T_SETTING))
    }
  }
}