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
