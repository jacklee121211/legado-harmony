import { curves } from '@kit.ArkUI';

/**
 * UI 动效统一参数（2026-09-21，2026-09-23 增补弹簧令牌）。
 *
 * ── 为什么单独抽一个文件 ─────────────────────────────────────────────────
 * 动效参数（时长、曲线、缩放比）如果散落在几十个组件里，以后想统一调一次就得全工程搜。
 * 集中在这里，改一处即全局生效；不想要某个动效时，对应调用点删掉即可。
 *
 * ── `CLICK` 的依据（SDK 原文，`…\openharmony\ets\component\common.d.ts`）─────
 *   `clickEffect(value: ClickEffect | null): T;`（`:20575`，`@since 10`，`@crossplatform`）
 *   `declare interface ClickEffect { level: ClickEffectLevel; scale?: number; }`（`:15934`）
 *   `declare enum ClickEffectLevel { LIGHT = 0, MIDDLE = 1, HEAVY = 2 }`
 *     （`enums.d.ts:3756`，全局枚举，**无需 import**）
 *
 *   `scale` 的官方默认值：`LIGHT` → **0.90**；`MIDDLE` / `HEAVY` → **0.95**。
 *
 *   ⚠️ 官方 NOTE 里有两条必须守住的限制（原文）：
 *     · 「Avoid using this feature in scenarios where the component **size dynamically changes**.」
 *     · 「After the click feedback effect triggers scaling, **the touch point may fall outside the
 *        control, making the component unresponsive to gesture events**.」
 *   ⇒ 所以这里**不用官方的 0.90，而是收紧到 0.96**：视觉上仍是明确的按压反馈，
 *     但四周各只收缩约 2%，显著降低"边缘点击被吃掉"的风险。
 *   ⇒ 也只用在**尺寸固定**的图标/按钮/列表项上。
 */
export default class UiMotion {
  /** 统一的点击按压反馈（按压缩小到 96%） */
  static readonly CLICK: ClickEffect = { level: ClickEffectLevel.LIGHT, scale: 0.96 };

  /** 快速过渡（用于按压、选中态这类小动作），单位 ms */
  static readonly DUR_FAST: number = 220;

  /** 常规过渡（用于日夜/主题切换这类整体变化），单位 ms */
  static readonly DUR_NORMAL: number = 320;

  // ══════════════════════════════════════════════════════════════════════════
  // 页面转场（2026-09-22 新增，基于**官方内置** systemTransition）
  // ══════════════════════════════════════════════════════════════════════════
  //
  // ── 为什么现在才能做 ──────────────────────────────────────────────────────
  // 转场动画需要 Navigation + NavDestination 的路由体系（架构第 1~5 期已完成迁移），
  // 在那之前页面走 `router`，没有可挂载的转场 API。
  //
  // ── 为什么用官方内置而不是三方库 ──────────────────────────────────────────
  // `NavDestination.systemTransition(type)`（`nav_destination.d.ts:1065`，**@since 14**）
  // 提供 8 种系统转场，官方支持、零依赖、可按页独立设置。
  // （2026-09-22 曾评估三方库 `@hmanimations/ezcustomtransition` 做"一镜到底"，
  //   但那条路要改目标页背景色与避让、还依赖库的内部实现；
  //   而本方案只是给 `NavDestination` 加一个属性 → **零结构性风险**。）
  //
  // ── SDK 枚举原文（`nav_destination.d.ts:111`）─────────────────────────────
  //   DEFAULT = 0        「Default system transition animation.」
  //   NONE = 1           「No system transition animation.」
  //   TITLE = 2          「System transition animation of the title bar.」
  //   CONTENT = 3        「System transition animation of the content area.」
  //   FADE = 4           「Fade-type system transition animation.」        @since 15
  //   EXPLODE = 5        「Center-scale type system transition animation.」@since 15
  //   SLIDE_RIGHT = 6    「Right-slide type system transition animation.」 @since 15
  //   SLIDE_BOTTOM = 7   「Bottom-slide type system transition animation.」@since 15

  /**
   * **总开关（一键回退点）**。`false` ⇒ 所有页面回到系统默认转场（= 改造前）。
   */
  static readonly PAGE_TRANSITION_ENABLED: boolean = true;

  /** 进入「书籍详情」：右侧滑入（层级推进感） */
  static readonly T_DETAIL: NavigationSystemTransitionType =
    NavigationSystemTransitionType.SLIDE_RIGHT;
  /**
   * 进入「阅读页」：**中心缩放**（2026-09-24 由 `FADE` 改为 `EXPLODE`）。
   *
   * SDK 原文（`nav_destination.d.ts:162-171`）：
   *   「EXPLODE = 5 / Center-scale type system transition animation. / @since 15」
   * 语义：新页面**从中心放大铺满**（返回时反向收缩）—— 对应"点开一本书、整个人扎进去"的心智，
   * 比原来的纯淡入更有"进入"的方向感，且与返回书架构成对称的一进一出。
   *
   * ⚠️ 一键回退：把下一行改回 `NavigationSystemTransitionType.FADE` 即可
   *    （`FADE = 4 / Fade-type system transition animation.`，同文件 `:152-161`）。
   *    若要整体回退所有页面转场，把 `PAGE_TRANSITION_ENABLED` 改成 `false`。
   * 【待验证】真机观感（本机无设备，无法在此验证动画手感）。
   */
  static readonly T_READER: NavigationSystemTransitionType =
    NavigationSystemTransitionType.EXPLODE;
  /** 进入「搜索」：底部滑入（模态感，符合"搜索面板"心智） */
  static readonly T_SEARCH: NavigationSystemTransitionType =
    NavigationSystemTransitionType.SLIDE_BOTTOM;
  /** 进入「二级设置类页面」（我的设置 / 主题 / 统计 / 书架管理）：右侧滑入 */
  static readonly T_SETTING: NavigationSystemTransitionType =
    NavigationSystemTransitionType.SLIDE_RIGHT;

  /**
   * 取某页的系统转场类型；总开关关闭时返回 `DEFAULT`（等价于不设）。
   *
   * 用法（`pages/Index.ets` 的 `appRoutes()`）：
   *   `.systemTransition(UiMotion.pageTransition(UiMotion.T_READER))`
   */
  static pageTransition(type: NavigationSystemTransitionType): NavigationSystemTransitionType {
    return UiMotion.PAGE_TRANSITION_ENABLED ? type : NavigationSystemTransitionType.DEFAULT;
  }

  // ══════════════════════════════════════════════════════════════════════════
  // 弹簧动效令牌（2026-09-23 新增，用户拍板「弹簧为主」）
  // ══════════════════════════════════════════════════════════════════════════
  //
  // ── 官方依据 ──────────────────────────────────────────────────────────────
  // · 优先弹簧：官方动画曲线概述（skill 知识库 `05-animation/curve/arkts-curve-overview.md`）原文
  //   「相对于传统曲线，**弹簧曲线更符合用户的认知，更适用于创建自然流畅的动画效果，
  //     建议开发者优先使用弹簧曲线**」
  // · 三条曲线都来自官方 `@ohos.curves`（SDK `api/@ohos.curves.d.ts`）：
  //   `springMotion(response=0.55, dampingFraction=0.825, overlapDuration=0)`（:371）
  //   `responsiveSpringMotion(0.15, 0.86, 0.25)`（:398，springMotion 的特例，官方建议保持默认）
  //   `interpolatingSpring(velocity, mass, stiffness, damping)`（:438，**支持插值/可配时长**）
  //   ⚠️ 官方原文：springMotion 的时长「depends on the springMotion parameters and the previous
  //      velocity, **rather than the duration parameter** in animation/animateTo/pageTransition」
  //      ⇒ 用弹簧时写 `duration` 无效，而且**可打断、可从上一速度续接**（手势/开关场景天然合适）。
  // · 「只动 transform/opacity」：官方最佳实践《动画帧率优化》
  //   （documentId `最佳实践/性能优化/动画帧率优化/bpta-animation-frame`）原文：
  //   「使用**图形变换属性**变化组件，而**不是直接修改布局属性**，减少布局计算和重绘，降低丢帧率」
  // · 「多个属性需要相同动画参数时，推荐**使用同一个动画闭包**…统一更新状态变量」（同文档）

  /** **动效总开关（一键回退点）**：`false` ⇒ 所有 `motionParam()` 退化为"无动画"（时长 0）。 */
  static readonly MOTION_ENABLED: boolean = true;

  /** 标准弹簧：进出场、菜单栏、弹窗这类"有分量"的动作 */
  static readonly SPRING: ICurve = curves.springMotion();

  /** 快弹簧：小控件、高频操作（收敛更快、回弹更少） */
  static readonly SPRING_FAST: ICurve = curves.springMotion(0.35, 0.9);

  /** 跟手弹簧：连续变化/拖拽跟随场景（官方建议用 `responsiveSpringMotion` 并保持默认参数） */
  static readonly SPRING_FOLLOW: ICurve = curves.responsiveSpringMotion();

  /**
   * 统一取动效参数（**弹簧为主**）。所有阅读页动画都从这里取，改手感只改这一处。
   * 关闭总开关时返回 `{ duration: 0 }` ⇒ 立即到位、无动画（等价于改造前）。
   */
  static motionParam(curve: ICurve = UiMotion.SPRING): AnimateParam {
    if (!UiMotion.MOTION_ENABLED) {
      return { duration: 0 };
    }
    return { curve: curve };
  }

  /** 统一取**转场**动效参数（`TransitionEffect.animation()` 用） */
  static transitionParam(curve: ICurve = UiMotion.SPRING_FAST): AnimateParam {
    return UiMotion.motionParam(curve);
  }

  // ══════════════════════════════════════════════════════════════════════════
  // 底部页签（Tabs）切换曲线 —— 2026-09-23 新增
  // ══════════════════════════════════════════════════════════════════════════
  /**
   * **Tabs 页签切换曲线**（用在 `pages/Index.ets` 的底部 Tabs 上）。
   *
   * ── 为什么需要它 ──────────────────────────────────────────────────────────
   * 官方 SDK `component/tabs.d.ts:1207-1211`（`animationCurve(curve: Curve | ICurve)`，
   * `@since 20`）的默认值原文：
   *   「When pages are turned by **swiping** in **TabContent**, the default value is
   *     **interpolatingSpring(-1, 1, 228, 30)**. When pages are turned by **tapping tabs or
   *      calling the changeIndex API**, the default value is
   *     **cubicBezierCurve(0.2, 0.0, 0.1, 1.0)**. When a custom animation curve is set, it applies
   *      to all tab switching animations—whether triggered by swiping, tapping a tab, or calling
   *      the changeIndex API.」
   * ⇒ 本工程「书架 ↔ 我的」是**点底部页签**切的 ⇒ 走的是**三次贝塞尔**，不是弹簧
   *   （用户拍板「弹簧为主」，这是一处真缺口；滑动切换本来就是弹簧）。
   *
   * ── 为什么取这条弹簧（而不是 `springMotion()`）───────────────────────────
   * 这里逐字取**系统"滑动切换"那条默认弹簧** `interpolatingSpring(-1, 1, 228, 30)`：
   *   · 点击切换 → 从三次贝塞尔变成弹簧（达成目标）；
   *   · 左右滑动切换 → 曲线与原来**完全相同** ⇒ **零回归**。
   *   （若想更"弹"，把它换成 `curves.springMotion()` 即可 —— 官方推荐的默认弹簧，
   *     response 0.55 / dampingFraction 0.825，会**连同滑动切换一起**变软变慢。）
   *
   * ⚠️ 同文件 `:1223-1232` 原文：设置 spring 类曲线后 **`animationDuration` 不再起作用**
   *   （「…the duration is determined by the intrinsic parameters of the default curve」），
   *   所以不要再给这个 Tabs 加 `animationDuration`，会没有效果。
   *
   * 回退：删掉 `Index.ets` 里那一行 `.animationCurve(...)` 即可（恢复系统默认）。
   */
  /**
   * **备选**页签切换曲线（当前**未启用**，保留作为一键回退选项）。
   * 逐字取系统"滑动切换"那条弹簧 `interpolatingSpring(-1, 1, 228, 30)`。
   * 换成它意味着：点击切换也走弹簧，但**时长不可调**（依据见本文件
   * `TABS_ANIM_CURVE` 注释里 `tabs.d.ts:1228-1232` 那条"不受 animationDuration 影响"的约束）。
   */
  static readonly TABS_SWITCH: ICurve = curves.interpolatingSpring(-1, 1, 228, 30)

  // ══════════════════════════════════════════════════════════════════════════
  // 底部页签「书架 ↔ 我的」切换动画 —— 2026-09-24（当天返工两次，结论在最后）
  // ══════════════════════════════════════════════════════════════════════════
  //
  // ── 三次改版的经过（避免以后有人重走弯路）────────────────────────────────
  // ① **淡入淡出**（`customContentTransition` 驱动 TabContent 的 opacity/scale）——
  //    用户否掉：「书架到我的**不能淡入淡出**，这样会很奇怪」。
  // ② **两页各自平移拼接**（`customContentTransition` 驱动 TabContent 的 translate）——
  //    用户否掉：「来回点了几次…动效很**割裂**，就像书架和我的**中间有白色连接**一样」。
  // ③ **回到官方内置平移，只调曲线与时长**（当前版本）—— 见下面的依据。
  //
  // ── 为什么 ② 必然出缝（官方原文直接否掉）──────────────────────────────────
  // documentId `FAQ/UI框架/UI界面/如何设置TabContent切换动画/faqs-arkui-1112`
  //   场景二（"点击页签，TabContent 有左右切换效果，A、B、C 三个页面…"）原文：
  //   「**Tabs组件无法实现页面拼接。**」
  //   官方替代方案是 `Scroll` + `scrollSnap` —— 那是**页面宽度不等**才需要的。
  //   只要两页还挂在 Tabs 里、各自动 `translate`，就等于手写拼接，是官方明说不成立的做法。
  //
  // ── ③ 的依据：官方对内置动画的定性 + 它是连续内容带 ────────────────────────
  // documentId `开发指南/ArkUI_方舟UI框架/…/选项卡_Tabs/arkts-navigation-tabs`
  //   「TabContent切换动画」小节原文：
  //   「**Tabs 自带的页签切换动画为平移动画。**若开发者需实现更高级的动画效果，
  //      可通过 Tabs 提供的 API 实现自定义动画。」
  //   ⇒ 用户要的"平移"，**内置动画本来就是**；而且它由 Tabs 分页器**整体搬运一条连续的内容带**，
  //     两个页签由同一个机制同步位移 ⇒ **结构上不可能出现两页之间的缝**。
  //   ⇒ 所以本版**删掉了自定义转场**，只调内置平移的曲线与时长。
  //
  // ── 曲线/时长的可调性（SDK `component/tabs.d.ts` 原文）──────────────────────
  //   `:1219 animationCurve(curve: Curve | ICurve): TabsAttribute;`（@since 20）
  //     默认值原文：「When pages are turned by **swiping** in TabContent, the default value is
  //       **interpolatingSpring(-1, 1, 228, 30)**. When pages are turned by **tapping tabs or
  //       calling the changeIndex API**, the default value is **cubicBezierCurve(0.2, 0.0, 0.1, 1.0)**.
  //       When a custom animation curve is set, it applies to **all** tab switching animations
  //       — whether triggered by swiping, tapping a tab, or calling the changeIndex API.」
  //   `:1246 animationDuration(value: number): TabsAttribute;`
  //     默认值原文：「API version 11 and later versions: If this parameter is set to an invalid value
  //       or is not set, the default value is **0** when the tab bar is set to **BottomTabBarStyle**
  //       and **300** when the tab bar is set to any other style.」
  //   ⚠️ 关键约束原文（`:1228-1232`）：「For details about curves **unaffected by animationDuration**,
  //     see Interpolation Calculation. These curves include curves of type **springMotion**,
  //     **responsiveSpringMotion**, and **interpolatingSpring**.」
  //   ⇒ **弹簧曲线下 `animationDuration` 是死参数**。本工程原来用的正是
  //     `curves.interpolatingSpring(-1, 1, 228, 30)`（见上方 `TABS_SWITCH`），所以那时根本调不了时长。
  //     换成具名曲线 `Curve.FastOutSlowIn` 后，`animationDuration` 才真正生效。

  /**
   * 页签内容切换动画曲线。
   *
   * **与参考项目 `xiaowei` 逐字一致** —— `entry/src/main/ets/pages/Index.ets:77-82` 的 `pageTransition`：
   *   `PageTransitionEnter/Exit({ …, curve: Curve.FastOutSlowIn }).slide(SlideEffect.…)`
   *
   * ⚠️ 副作用（说清楚）：官方原文「it applies to **all** tab switching animations」⇒ 这条曲线
   *    **同时**作用于"解锁标签栏后的左右滑动"。原来是滑动走 `interpolatingSpring(-1, 1, 228, 30)`
   *    （弹簧），现在也变成 `FastOutSlowIn`。因为滑动默认是**关闭**的（`APP_INDEX_SCROLLABLE` 默认 true
   *    ⇒ `.scrollable(false)`），只有长按页签解锁后才会用到，影响面很小。
   *    想只保留原弹簧、放弃时长可调：把这里改回
   *    `curves.interpolatingSpring(-1, 1, 228, 30)`，并删掉 `Index.ets` 上的 `.animationDuration(...)`。
   */
  static readonly TABS_ANIM_CURVE: Curve = Curve.FastOutSlowIn;

  /**
   * 页签内容切换动画时长（ms）—— 只在曲线非弹簧时生效（见上面的关键约束）。
   *
   * 参考项目 `xiaowei` 的默认值是 **521ms**（`xiaowei/common/TransitionManager.ets`：滑杆默认
   * 28/50，按 100~2000ms 指数映射得 521）。这里取 **420ms**：同一手感方向，底部页签是高频
   * 来回点的操作，比整页 push 略干脆一点。想完全贴近 `xiaowei` 就改成 `520`。
   */
  static readonly TABS_ANIM_DUR: number = 420;

  // ══════════════════════════════════════════════════════════════════════════
  // 列表 / 宫格「渐次入场」动画参数 —— 2026-09-24 新增
  // ══════════════════════════════════════════════════════════════════════════
  //
  // ── 为什么只动 opacity / translate / scale ────────────────────────────────
  // 官方最佳实践《动画帧率优化》（documentId `最佳实践/性能优化/动画帧率优化/bpta-animation-frame`）原文：
  //   「使用**图形变换属性**变化组件，而**不是直接修改布局属性**，减少布局计算和重绘，降低丢帧率」
  // opacity / translate / scale 三者都是图形变换，不触发重新布局 ⇒ 适合长列表逐项入场。
  //
  // ── 为什么曲线用 `Curve.Friction` ────────────────────────────────────────
  // 与参考项目 `catonlineSP2`（`pages/Index.ets:106-125` 的 `ENTRANCE_ANIMATION`）一致，
  // 也与官方渐次出现示例（`arkts-enter-exit-transition`：`curve: Curve.Friction`）一致。
  // 这里**不用** `springMotion`：弹簧时长不可控（官方原文见本文件 `:101-103`），
  // 而列表入场需要"可预期的结束时刻"，否则波次窗口没法收口。

  /** 单项入场：Y 方向位移初值（vp，正值 = 从下方浮上来）。 */
  static readonly ITEM_ENTER_TRANSLATE_Y: number = 12;

  /** 单项入场：缩放初值。 */
  static readonly ITEM_ENTER_SCALE_FROM: number = 0.98;

  /**
   * 单项入场的动画参数（挂在列表项的 `.animation()` 上）。
   *
   * ⚠️ 调用约定：**只有当 `EntranceWave.delayFor()` 返回 `>= 0` 时才需要它**。
   *    返回 `-1` 时调用方应把已入场标记**在首次 build 之前**就置为 `true`，
   *    这样属性从未处于"未入场"状态 ⇒ 即使挂了本参数也**不会产生任何动画帧**。
   */
  static itemEnterParam(): AnimateParam {
    if (!UiMotion.MOTION_ENABLED) {
      return { duration: 0 };
    }
    return { duration: UiMotion.ITEM_ENTER_DUR, curve: Curve.Friction };
  }

  /**
   * 单项入场动画时长（ms）。与 `EntranceWave.DUR_MS` **必须保持一致**（波次总时长按它算）。
   * ⚠️ 2026-09-24 调参：用户真机反馈「波浪动画非常好，就是太快了，稍微调慢一点」⇒ **280 → 380**。
   */
  static readonly ITEM_ENTER_DUR: number = 380

  // ══════════════════════════════════════════════════════════════════════════
  // 一镜到底（书架 → 阅读器）令牌 —— 2026-09-23
  // ══════════════════════════════════════════════════════════════════════════
  //
  // ── 技术路线（探针真机已验证 4/4，见 docs/shelf-to-reader-longtake-spec.md）──
  // 官方 `NavDestination.customTransition`（nav_destination.d.ts:1189，@since 15）自绘：
  //   delegate 里同步设起始帧，返回的 transition 只做"点火"，
  //   真正编排用显式 animateTo 串行驱动（对齐官方示例2的写法）。
  //   探针结论：阅读器正文（ReaderKit surface）服从祖先 opacity / clip，
  //   且能跟随 rotate({y}) 的 3D 透视 —— 四个前提全部成立，才有了这条实现。
  //
  // ── 为什么不用弹簧曲线 ────────────────────────────────────────────────────
  // 弹簧时长不可控（本文件 :101-103 引过官方原文）。掀开动画是多段编排
  // （飞行/掀开/淡出要按时刻表对齐），必须用**时长确定**的曲线 ⇒ 全段用 `Curve.Friction`
  // （与书架渐次入场一致，用户已认可这条曲线的手感）。
  //
  // ── 节奏（四轮 2026-09-23：按用户口述的"打开一本书"模型重做）──────────────
  // 用户原话要点：点击后整本书放大向左侧靠拢；封面绕左缘打开（左侧两角小幅度、
  // 右侧两角大幅度向左翻）；书脊右侧始终连着**内容页**（高度=书脊高度=左边两点一边高），
  // 封面掀到哪内容页就从右边露到哪；随着放大内容页变成全屏 = 阅读器页。
  // ⇒ 结构：[内容页=阅读器裁到"书脸"] 与 [封面] 在书脊相连，同一包络里一起放大左移；
  //   封面从 80ms 就开始掀（透视下投影逐渐收窄，内容页从右往左渐进露出）。
  //   背景为点击瞬间的书架定格快照（五轮，取代变暗层）—— 全程静止、无缝、无黑遮罩。

  /**
   * **总开关（一键回退点）**。`false` ⇒ 点击捕获与转场 delegate 全部旁路，
   * 书架→阅读器回到 `T_READER`（EXPLODE）内置转场，与非书架入口一致。
   */
  static readonly LONGTAKE_ENABLED: boolean = true

  /** 进场/返回总时长（ms），两段对称 */
  static readonly LT_ENTER_DUR: number = 560
  static readonly LT_POP_DUR: number = 560

  /** 封面开始掀开的时刻（ms）：早掀 —— 透视下投影渐窄，内容页从右侧渐进露出 */
  static readonly LT_FLIP_DELAY: number = 80
  /** 封面掀开时长（ms）：LT_FLIP_DELAY + LT_FLIP_DUR = LT_ENTER_DUR（同时到位） */
  static readonly LT_FLIP_DUR: number = 480
  /**
   * 封面掀开角度（°），绕**左边缘/书脊**（centerX=0）的 y 轴旋转。
   * ✅ 方向已真机定案（2026-09-23 用户实测）：**负角 = 向外翻**（封面右缘朝读者掀来、
   *   翻过书脊落到左侧，翻开后"左面高、右面低"——用户口述的正确形态）；
   *   正角 = 向内翻（右缘立起来往书里扣，"右面高左面低"，已被否）。
   *   SDK 未定义绕 y 轴的朝向语义（common.d.ts 只说正角=顺时针），只能真机定。
   */
  static readonly LT_FLIP_ANGLE: number = -92
  /** 封面淡出开始时刻（ms）：盖住 >90° 时背面镜像的穿帮（spec §5.2） */
  static readonly LT_FADE_DELAY: number = 480
  /** 封面淡出时长（ms）：LT_FADE_DELAY + LT_FADE_DUR = LT_ENTER_DUR */
  static readonly LT_FADE_DUR: number = 80

  /** 返回：封面淡入时长（ms，从掀开态立即回来） */
  static readonly LT_POP_FADEIN_DUR: number = 80
  // 五轮（2026-09-23）：删除变暗层令牌（LT_SCRIM_IN_DUR / LT_POP_SCRIM_DELAY / LT_POP_SCRIM_DUR）。
  // 用户反馈"动画右侧有黑色区域，像遮罩"—— 那就是变暗层+系统藏书架后的虚空。
  // 改为点击瞬间截书架定格快照垫底（LongTakeFlightData.backdrop），
  // 全程背景=定格书架，与真书架像素级一致，无需任何淡入淡出。

  // ══════════════════════════════════════════════════════════════════════════
  // 七轮（2026-09-30）：治「关闭动画底部空洞 / 原位封面盖不住」——两个可一键回退的开关
  // ══════════════════════════════════════════════════════════════════════════
  // ── 现象（用户原话，不得改写）────────────────────────────────────────────
  //   ①「关闭动画的时候，书籍封页在向回缩放的时候，底部多出来一块，这一块不确定是一个
  //      透明的蒙版还是一圈线条，这个块的底边和左右两边均是平行与书籍封页，内里是透明的」
  //   ②「列表模式下，第三个回落还很完美，第四个就不行了，遮不住了」
  // ── 取证 ─────────────────────────────────────────────────────────────────
  //   · **落点公式没错**（真机日志 `Downloads\2.md`）：
  //       `LTBOOK capture id=ltCoverL4 book=邪龙道.txt cover=(83,2145 202.5x270) r=13.5 win=1320x2848`
  //       `LTBOOK geom book=邪龙道.txt s0=0.1534090909090909 t=(24.59259259259259,635.5555555555555)`
  //     由 s0/clipH0 推出的落点 = (83,2145) + (202.5×270)px，与 cover 逐位相同。
  //   · **截图逐像素（用户 2026-09-29 截图，1320×2848）**：封面粉色在 y≈1100 结束，
  //     之下是书架自己的内容——书架那本"神墓"的黑色标题字（最暗均值 33）出现在
  //     **飞行书盒子内部**（y=1140/1150 有 54/13 个 <120 的暗像素，y≥1160 为 0）
  //     ⇒ 盒子底部那一条**没人画**，直接漏出 `ltBackdrop`（书架定格图）。
  // ── 根因 ─────────────────────────────────────────────────────────────────
  //   ① 飞行封面层的**盒子高度 = ltClipH**（从封面纵横比 0.75 长到整屏纵横比 0.4635），
  //      而 `Image(src)` 的图源只按自己的纵横比铺（默认封面走 alt：
  //      `commons/colorLibrary/.../icon_book_default_cover_one.svg:1` 的 `90×120` = 0.75）
  //      ⇒ 除最后一帧（ltClipH 收到 521.48）外，盒子底部恒留一条空洞。
  //   ② 返回一开始 NavDestination 就进 onHidden（同上日志 `22:07:16.894 onHidden`，
  //      而自定义转场 `16.895` 才起）⇒ 阅读器的 RS surface 那一层不再合成、裁剪层是空的
  //      ⇒ 空洞里漏出的是书架定格图（而不是"内容页"）。
  //   ③ 为什么"第三个还行、第四个开始遮不住"：底带顶边与目标封面顶边之差
  //      Δ(p) = 521.48·(1−0.846591p) − ty0·(1−p)（vp）
  //      ⇒ ty0 越大（书越靠下）Δ 越小，Δ<封面高(80vp) 时目标封面下缘就从底带里露出来。
  //      代入日志：L2 ty0=416.59 → Δ≈87vp（临界，用户说"第三个还很完美"）；
  //                L3 ty0=525.93 → Δ≈55vp；L4 ty0=635.56 → Δ≈22vp（"第四个就不行了"）。
  /**
   * 一镜到底·**封面位图化**（治①）——总开关。
   *
   * 做法：点击瞬间把封面卡片截成位图（`getSync(id,{scale:4})`，202.5×270px → 810×1080px），
   * 飞行层用 `Image(pixelMap)` + `ImageFit.Fill` ⇒ **位图一定铺满盒子**
   * （不吃 SVG 的 preserveAspectRatio，也不吃 objectFit 对 SVG 的未定义行为）。
   * 依据：`SnapshotOptions.scale` 存在且默认 1（SDK `@ohos.arkui.componentSnapshot.d.ts`
   * `interface SnapshotOptions { scale?: number; }`），文档同时提醒"别截超过屏幕尺寸的大图"
   * ⇒ 封面很小，scale 4 安全。
   * 回退：置 `false` ⇒ `LongTakeFlightData` 不再截图，飞行层回到 `Image(coverUrl)` 老路径
   * （空洞复现，无其它副作用）。
   */
  static readonly LT_COVER_SNAPSHOT: boolean = true
  /**
   * 一镜到底·**关闭时给内容页铺底**（治②，兜底）——总开关。
   *
   * 做法：`ReaderPage3` 把"内容页长什么样"（`themeColor` / `themeBgImg`）发布到 AppStorage，
   * 飞行层的裁剪层铺同色底 + 同图 ⇒ 返回时没被封面盖到的地方露出的是**内容页**而不是书架。
   * 回退：置 `false` ⇒ 裁剪层不铺底（回到现状）。
   */
  static readonly LT_PAGE_BG: boolean = true
  /**
   * 内容页底色 / 背景图 的 AppStorage 键。
   * ⚠️ `Index.ets` 的 `@StorageLink` 装饰器参数必须是字符串字面量，那边写的是同样的字面量，
   * 改这里必须同步改那边（两处都有注释互相指路）。
   */
  static readonly LT_PAGE_BG_KEY: string = 'ltReaderPageBg'
  static readonly LT_PAGE_IMG_KEY: string = 'ltReaderPageImg'

  // ══════════════════════════════════════════════════════════════════════════
  // 八轮（2026-09-30）：按"真书"的顺序重排两段转场 —— **先飞大/缩小，后开盖/合盖**
  // ══════════════════════════════════════════════════════════════════════════
  // ── 用户口述（本轮，设计判断）──────────────────────────────────────────────
  //   打开：「让阅读器与左面对齐，这样整个阅读器是直接隐藏在封页的下面，当封页完全展开，
  //          那么正好阅读器也加载完了，直接呈现，这样也更像是一本真正的书籍。」
  //   关闭：「阅读器（第一帧）还是全屏，但（第二帧）一下就变成半屏…阅读器始终保持矩形，
  //          只是跟随动画缩放，但是封页的右边会变化…他俩应该是整体。」
  // ── 旧编排为什么会"变半屏"（真机日志 `Downloads\2.md` 实证）──────────────
  //   旧：包络（scale/translate/clipH）0→560ms ∥ 封面合上 0→480ms —— 两段**同时**从 0 开始。
  //   于是回落一开始裁切窗口（ltClipH）就在缩小 ⇒ 阅读器被"切"成窗口大小，而不是整本书
  //   一起缩小（真机日志：`LTBOOK cover node 1320x1760 …` 出现在 pop 开始后 **24ms**，
  //   而 1760px 是 560ms 动画的**终值** ⇒ 观感就是"阅读器瞬间变半屏"）。
  //   对比同一日志里的 pop 结束值：`pop shrink done` 在 560ms 后才出现 ⇒ 动画本身没跑完
  //   就已被判成"到位"，形态不连续。
  // ── 新编排（本组令牌控制）────────────────────────────────────────────────
  //   打开：① 0→LT_GROW_DUR 整本书（封面**合着**，把内容页盖住）飞大到位；
  //         ② LT_GROW_DUR→+LT_FLIP2_DUR 封面绕书脊掀开，露出（此时已加载好的）阅读器。
  //   关闭：① 0→LT_POP_FADEIN_DUR 封面先不透明；② 封面合上（盖住全屏阅读器，此阶段
  //         **不动** scale/clip ⇒ 阅读器保持全屏、不被裁）；③ +LT_FLIP2_DUR 起整本书缩回原位。
  //   ⇒ 两个方向都是"整本书作为一个整体缩放"，符合用户的"他俩应该是整体"。
  /**
   * 转场顺序：**先飞大/缩小，后开盖/合盖**（true = 八轮试过的分两拍；false = 一镜到底，**默认**）。
   *
   * ⚠️ 用户已**否决** true：原话「现在变成了先放大好，再翻页，那意义在哪儿？应该是边飞边放大，
   * 非常丝滑的动画。一镜到底的效果」⇒ 默认 false（`ltRunEnter`/`ltRunPop` 的 else 分支 =
   * 包络与翻盖**同时**从 0ms 起跑）。true 分支保留，仅作对照用。
   */
  static readonly LT_COVER_FIRST: boolean = false
  /**
   * 「整本书缩放」这一段时长（ms）。仅在 `LT_COVER_FIRST = true`（已被否决的分两拍版本）里使用。
   */
  static readonly LT_GROW_DUR: number = 300
  /**
   * 「封面开/合」这一段时长（ms）。仅在 `LT_COVER_FIRST = true` 时使用。
   */
  static readonly LT_FLIP2_DUR: number = 260
  /**
   * **关闭时封面合上的时长（ms）**——刻意比缩小（560ms）**快得多**，但**同时起跑**：
   * 一镜到底的观感不变，而等窗口明显缩小时内容页已经被封面盖住，
   * 于是"阅读器被裁成半屏"那一下根本看不见。
   *
   * ── 为什么需要（真机日志 + 用户逐帧截图）────────────────────────────────
   * 旧编排里封面合上是 `LT_FLIP_DELAY + LT_FLIP_DUR = 480ms`，比缩小的前段还慢：
   * 回落开始 ~100ms 时窗口已缩到约 55%（`Curve.Friction` 起步极快），
   * 而封面因为还没合上（`angle` 才转到约 -46°，投影只盖住左侧约 69%）
   * ⇒ 右侧露出"被切掉下半部分的阅读器"，用户描述为「第二帧阅读器一下就变成半屏」。
   * 改成 180ms 后：~100ms 时封面已盖住约九成，窗口只缩到约 97%（曲线也换成起步慢的
   * `FastOutSlowIn`）⇒ 切页过程被藏住，观感是"整本书一起缩小回落"。
   */
  static readonly LT_POP_FLIP_DUR: number = 180
  /**
   * 关闭时「整本书缩小」用的曲线。
   * 为什么不用 `Curve.Friction`（= cubic-bezier(0.2,0,0.2,1)，起步极快）：560ms 的回落在
   * 头 100ms 就走掉一半行程，逐帧看就是"一下就变一半"。`Curve.FastOutSlowIn`
   * （= cubic-bezier(0.4,0,0.2,1)，起步慢、中段快、收尾缓）在 100ms 只走约 3%~8%，
   * 与"封面先合上"配合后，整段是连续可读的一次动作。
   * 依据：本工程已用同名曲线（`TABS_ANIM_CURVE`，见本文件 :246），且用户对参考工程
   * `xiaowei` 的偏好就是它（`Index.ets` :420 注释）。
   */
  static readonly LT_POP_SHRINK_CURVE: Curve = Curve.FastOutSlowIn
  /**
   * 封面 3D 翻折的**观看距离**（`rotate({ y:1, centerX:0, angle, perspective })`，单位 px）。
   *
   * SDK 原文（`component/common.d.ts` `RotateOptions.perspective`）：
   *   「Z-axis coordinate of the camera. The value indicates the **viewing distance**…
   *     **When perspective is set to 0, the system automatically calculates a proper camera
   *     Z-axis position. The value is negative.**」——自算相**机位很近** ⇒ 近端放大极狠。
   *
   * ── 十二轮 v3.2（2026-09-30）恢复 **0（系统自算）**，用户两组截图一锤定音 ──────
   *   · 旧版（9-29 23:44 录屏，perspective=0）：梯形**扑出矩形之外**——右缘比书脊高一大截、
   *     顶角冲向屏幕上缘，用户认可"真的有透视感"的效果就是它；
   *   · v3.1（-3000，我取的"安全值"）：梯形只比盒子大一点，翻折像"被套在灰色矩形里"
   *     （用户 9-30 09:58 录屏，本轮"束缚感"投诉的直接原因）——**力度不足，否决**。
   *   · 结论：这个参数只有"够近"和"不够近"的区别，宁近勿远。v3 架构下封面投影即使
   *     大幅越出书脸盒，越出部分压在书架快照/书体块上，都是合法画面，无暴露风险。
   * 调参：想再凶一点没法比 0 更近（0 即自算极值）；想收敛取负值（-1500 起步，-3000 已证太温）。
   */
  static readonly LT_COVER_PERSPECTIVE: number = 0
  /**
   * 转场探针（排查用；2026-09-30 十一轮起默认关 = 零日志）。
   * ⚠️ 它读的是 **JS 状态变量**：animateTo 闭包同步执行 ⇒ t=0 永远读到终值，
   * 既证明不了"跳变"也证明不了"平滑"；`getRectangleById` 返回布局终值同理。
   * 真正的时长证据 = animateTo onFinish 时间戳（`pop shrink done` 等）。需要时再置 true。
   */
  static readonly LT_PROBE: boolean = false

  // ══════════════════════════════════════════════════════════════════════════
  // 十二轮 v3（2026-09-30 深夜）：**快照飞行层** —— 飞行层里只有图片，零活组件
  // ══════════════════════════════════════════════════════════════════════════
  // ── 为什么推倒重来（架构级根因，十一轮 v1/v2 真机证伪链）────────────────────
  //   v1（梯形遮罩跟随）与 v2（书脸高度同步 + clip(true)）都没能治住"漏/黑/折断"，
  //   用户原话「还是一样的效果，还是漏」。把十轮→十一轮的全部 bug 对账后收敛到
  //   **一个架构级根因**：我们把**活的阅读器**（XComponent，独立 RS surface，
  //   真机日志 `RSSurfaceNode::Create name: interactiveSurface`）塞进了动画层里飞——
  //   它在转场期间：surface 停止合成（变黑）、不理会祖先裁剪、布局值瞬间报终值，
  //   这些行为 ArkTS 侧完全不可控。十轮以来所有怪象（底部空洞/黑块/瞬间半屏/
  //   拦腰折断/长出20%黑边）全部源于此。参数调不好不是手艺问题，是地基问题。
  // ── 正规架构（取自 `hmos-arkui-longtake-transition` skill 的生态范式）───────
  //   一镜到底的通行做法是**飞行层只飞"照片"，真页面垫底、落地才呈现**：
  //   `@hmanimations/ezcustomtransition`（本工程九轮前试过、因时长硬编码 250ms/
  //   封面 50ms/截图糊被否——否决有效）的 LongTakeTransitionDelegate 就是这个模型。
  //   我们采纳**架构**、保留自研**编排**（560ms/边飞边放大/梯形翻折/书脊对齐全是自己的）。
  // ── v3 结构 ─────────────────────────────────────────────────────────────
  //   NavDestination(飞行分支)
  //   └─ Stack
  //      ├─ ReaderPage3            ← 真阅读器**垫底**：全程不参与动画、不被裁剪、
  //      │                            飞行期间被覆盖层挡住（它加载它的，落地即呈现）
  //      └─ if (ltFlightOverlay)   ← 飞行覆盖层：**全部是图片**
  //         ├─ 黑底兜底 + 书架定格快照（照旧）
  //         └─ 包络(translate/scale/书脸clip)
  //            ├─ 页色书体块（LT_PAGE_BG 底衬，照旧）
  //            └─ 封面位图（翻折，照旧）
  //   · 进场：覆盖层挡住一切，560ms 飞完 → onTransitionEnd 撤覆盖层 ⇒ 阅读器"直接呈现"
  //     （背景色与书体块同源 = themeColor/材质图，交换瞬间只有文字出现，无跳底色）。
  //   · 返回：ltRunPop 首帧同步重建覆盖层盖住阅读器（surface 变黑也看不见），
  //     整本书（书体块+封面）缩回落位 → NavDestination 销毁。
  // ── 顺带的简化 ──────────────────────────────────────────────────────────
  //   · "书脸"高度同步（v2 的 .height(ltClipH)+.clip(true)）保留：书体块必须与封面
  //     同步缩放（clip(Rect) 参数不随隐式动画插值——v2 取证仍成立）。
  //   · v2 的 LT_AUTO_COVER/LT_AUTO_COVER_PERSPECTIVE 开关删除：活阅读器出动画层后
  //     不再需要双路径，透视统一走 LT_COVER_PERSPECTIVE(-3000)。
  // ── 回退 ────────────────────────────────────────────────────────────────
  //   git checkout 92932fc -- entry/src/main/ets   （回到十轮检查点，活阅读器在动画层的老路径）
  /**
   * 飞行封面位图的铺放方式（治"封面画被拉伸变形"）：
   * false = `ImageFit.Fill`（检查点现状：一定铺满盒子，但盒子纵横比从 0.75 变到 0.4635
   *         的过程中封面画最多被竖向拉 ~1.62 倍）；
   * true  = `ImageFit.Cover`（保比例裁切铺放：数学上同样盖满盒子（七轮空洞的根源是
   *         SVG 图源不吃 objectFit，位图源正常），且不变形；代价是纵横比差得远时
   *         只显示封面画中段——**【待验证】**真机确认观感）。
   */
  static readonly LT_COVER_FIT_CROP: boolean = false
}

// ══════════════════════════════════════════════════════════════════════════════
// 图标 / 按钮「Q弹」点击动效（2026-09-25 引入，**逐字借鉴**参考工程
// `D:\Arkts\catonlineSP2\entry\src\main\ets\common\PerformanceOptimization.ets:125`
// 的 `runJellyClick`，用户点名"能借鉴就借鉴"）。
//
// ── 为什么不用系统内置的 ScaleSymbolEffect ──────────────────────────────────
// SDK `component/symbolglyph.d.ts`（全文 876 行）的 `symbolEffect` 只有两个重载
//   （`(effect, isActive?)` :761、`(effect, triggerValue?)` :777，@since 12），
//   全文 grep `duration / curve / AnimationSpecification` **零命中**
//   ⇒ 内置符号动效的节奏系统定死、无法调快（用户真机实测"太慢、不灵动"）。
// ⇒ 改为自驱 `.scale()`：`scale` 是图形变换属性，符合官方《动画帧率优化》
//   "用图形变换而非布局属性"的要求（本文件上方同款引用）。
//
// ── 节奏（三段式，与参考工程一致）──────────────────────────────────────────
//   压下 70ms 到 0.88（Curve.EaseOut）→ 过冲 220ms 到 1.08（Curve.Friction）
//   → 回弹 140ms 落回 1（Curve.EaseOut）。总时长 ~430ms，但 70ms 就有明确反馈，
//   "跟手"的是第一段，后两段是惯性——这正是"Q弹"手感（参考工程真机验证）。
// 配套的 glow（光晕阴影）参考工程有；图标类场景**不传** `setGlow` 即可跳过。
export interface JellyClickConfig {
  shrinkScale: number
  overshootScale: number
  shrinkDurationMs: number
  overshootDurationMs: number
  settleDurationMs: number
  glowHoldMs: number
  glowRadius: number
}

export function runJellyClick(
  setScale: (value: number) => void,
  setGlow?: (value: number) => void,
  config?: Partial<JellyClickConfig>
): void {
  const cfg: JellyClickConfig = {
    shrinkScale: config?.shrinkScale ?? 0.88,
    overshootScale: config?.overshootScale ?? 1.08,
    shrinkDurationMs: config?.shrinkDurationMs ?? 70,
    overshootDurationMs: config?.overshootDurationMs ?? 220,
    settleDurationMs: config?.settleDurationMs ?? 140,
    glowHoldMs: config?.glowHoldMs ?? 160,
    glowRadius: config?.glowRadius ?? 18,
  }

  if (setGlow) {
    setGlow(cfg.glowRadius)
  }
  animateTo({ duration: cfg.shrinkDurationMs, curve: Curve.EaseOut }, () => {
    setScale(cfg.shrinkScale)
  })

  setTimeout(() => {
    animateTo({ duration: cfg.overshootDurationMs, curve: Curve.Friction }, () => {
      setScale(cfg.overshootScale)
    })

    setTimeout(() => {
      animateTo({ duration: cfg.settleDurationMs, curve: Curve.EaseOut }, () => {
        setScale(1)
      })
      if (setGlow) {
        setGlow(0)
      }
    }, cfg.glowHoldMs)
  }, cfg.shrinkDurationMs)
}
