import { LongTakeTransitionType } from '../Constants/ezCustomTransitionConstants';
import { LongTakeTransitionParam } from '../utils/LongTakeTransitionParam';
import { ComponentAttrUtils, RectInfo_px } from '../utils/ComponentAttrUtils';
import { WindowUtils } from '../utils/WindowUtils';
import { CustomTransition } from '../utils/CustomNavigationUtils';
import { LongTakeSessionOptions } from '../utils/Options';
import { SnapShotImage } from '../index';
import { hilog } from '@kit.PerformanceAnalysisKit';
import UiMotion from '../../../common/utils/UiMotion';

const TAG: string = 'EZLT';

// 书脸兜底色：阅读器主题色（ReaderPage3.publishLtPageBg）尚未发布时的过渡色
const FALLBACK_PAGE_BG: ResourceColor = '#F8F9FA';

// 手势返回时缩放的下限（官方契约同款）：拖到 0.5 即视为已充分返回
const GESTURE_MIN_SCALE: number = 0.5;

/**
 * 一镜到底会话（`@hmanimations/ezcustomtransition` v1.3.0 受控 fork）。
 *
 * ── 契约层（官方原样，勿动）────────────────────────────────────────────────
 * Navigation 注册/回调、enabled 闸配合、手势返回框架（PanGesture + 阈值判定 +
 * cancelTransition）、timeout 1000 框架保底、session 生命周期。
 *
 * ── 效果层：**一本打开的书** ───────────────────────────────────────────────
 * 用户口述模型（`docs/shelf-to-reader-longtake-spec.md:490-505`）：
 * 「点击一本书，书放大向左侧靠拢；封面从右向左打开——左侧两个上下点小幅度、
 *   右侧两个上下点大幅度向左翻页；但得有内容页，内容页高度和左侧两个点一边高，
 *   是书籍的右侧；随着放大内容页变成全屏，内容页就是阅读器页。」
 *
 * 结构 = **一个可见盒 + 两个同盒图层**：
 *   [书盒] (x,y,w,h) 四条边各自单调插值，clip(true)
 *     ├─ [内容层] 真阅读器（整窗布局，等比缩到盒宽）—— 全程 opacity=1，被盒"揭开"
 *     └─ [封面] 与盒**同盒**（书脊=左缘天然对齐、等高），绕左缘 3D 翻折
 *
 * ── 三条关键真相（都带证据，别再凭经验调）──────────────────────────────────
 * ① **翻折角必须是负角**：`UiMotion.LT_FLIP_ANGLE = -92`，真机两次定案
 *    （`UiMotion.ets:344-349`、`:490-497`）；坐标系依据：官方术语「如果为三维坐标系，
 *    则由屏幕向外为z正轴」（`arkui-glossary` 组件坐标系）⇒ 负角让封面自由边朝观察者
 *    掀来、投影比书脊高 = **左低右高**（用户 2026-10-02 确认）。
 * ② **perspective 必须 0（系统自算）**。SDK：`RotateOptions.perspective` = 相机到 z=0
 *    平面的距离、**单位 px**（`component/common.d.ts:4857-4879`）；封面自由边最大 z 位移
 *    = 封面宽(px)（全屏 1320px）⇒ 写死小于它的值会让自由边穿过相机平面、投影奇异
 *    （旧 fork 的 `perspective: 1200` 就是这么坏的）。真机两组截图定案 0 最凶、
 *    -3000 太温（`UiMotion.ets:490-497`）。
 * ③ **盒高必须单独插值，不能是"缩放×书脸高"**（2026-10-03 修复）：
 *    旧写法 height = clipH(u)·s(u) 是 **u 的二次函数**，底边
 *      bottom(u) = (ty0 + cardH) + (490.95 − ty0)·u + 272.9·u²   （本机实测系数，vp）
 *    ⇒ 当封面槽位 `ty0 > 490.95vp`（书架第 3 本往下）时底边**先上漂再回落**，
 *      回落过程中会露出书架原位那本书的下缘（用户："越往下越明显，对不齐"）。
 *    现在 x/y/w/h 四条边都从"被点击那本书的矩形"线性插值到"整窗"：
 *      x(u)=lerp(tx0,0,u)、y(u)=lerp(ty0,0,u)、
 *      w(u)=lerp(cardW,winW,u)、h(u)=lerp(cardH,winH,u)
 *    四条边都单调 ⇒ 飞行中的书**恒包含**被点击的那本书的矩形（且恒在窗内）
 *    ⇒ 任意位置的回落都不会露出原位封面。盒内内容按 `bookScale = w/winW` **等比**缩放，
 *      所以阅读器不拉伸；缩放后的内容高 `winH·s` 恒 ≥ 盒高（两条直线在 u=1 相交）
 *      ⇒ 盒内永远被内容页填满，不会漏出书架。
 *
 * ── 回退 ──────────────────────────────────────────────────────────────────
 * `UiMotion.LONGTAKE_ENABLED = false` ⇒ 点击侧整体旁路，回到系统 EXPLODE 转场。
 */
@Observed
export class LongTakeSession {
  // ── 契约层字段（官方原样）──────────────────────────────────────────────────
  public options: LongTakeSessionOptions | undefined = undefined;

  public type: LongTakeTransitionType = LongTakeTransitionType.CardLongTake;

  public snapshotImage: PixelMap | undefined = undefined;

  private transitionParam: LongTakeTransitionParam = new LongTakeTransitionParam(new RectInfo_px());

  private navDestinationId: string = '';

  private navPathStack: NavPathStack = new NavPathStack();

  private animationCount: number = 0;

  /**
   * 本 session 注册过的 navDestinationId（**FIFO**）。
   * 为什么需要（2026-10-04 真机定位）：`Index.ets` 只有**一个** session 对象被所有
   * 阅读页实例共用，而 delegate 的 `onDisAppear` 只能拿到"session 当前的 id"——
   * 快速开关时，旧页面的 delegate 会在**新页面已 init 之后**才销毁，于是它把**新页面**的
   * 转场注册删掉了 ⇒ 框架日志 `custom transition is invalid, do default animation`（5 次），
   * 返回变成系统默认转场。改为按注册顺序出队：销毁顺序在实践上就是创建顺序。
   */
  private registeredIds: string[] = [];

  private cardItemInfo_px: RectInfo_px = new RectInfo_px();

  // ── 效果层视觉字段（CardLongTakeDelegate 消费；全部 @Observed 驱动重绘）────
  /** 书体块底色（阅读器页底色同源，ReaderPage3.publishLtPageBg 持续发布） */
  public pageBodyColor: ResourceColor = FALLBACK_PAGE_BG;

  /** 书体块背景图（阅读器自定义材质，沙箱 URI；空 = 纯色） */
  public pageBodyImg: string = '';

  /** 封面绕左缘翻折角（deg）：0 = 合上正对，`LT_FLIP_ANGLE` = 掀到底（侧立不可见） */
  public coverAngle: number = 0;

  /** 翻折透视深度（rotate.perspective，单位 px；0 = 系统自算，见类头 ②） */
  public coverPerspective: number = UiMotion.LT_COVER_PERSPECTIVE;

  /** 封面圆角（vp）：从卡片圆角 → 0（**vp 直给**，封面盒已是绝对坐标） */
  public coverRadius: number = 0;

  /** 书盒左上角（vp，绝对坐标）：封面槽位左上 → (0,0) */
  public bookX: number = 0;
  public bookY: number = 0;

  /** 书盒尺寸（vp）：封面尺寸 → 整窗（**四条边各自插值**，见类头 ③） */
  public bookW: number = 0;
  public bookH: number = 0;

  /** 盒内内容等比缩放 = bookW / winW（阅读器按整窗布局后等比缩，绝不拉伸） */
  public bookScale: number = 1;

  /**
   * 「起手」进度 0→1（2026-10-02 用户反馈"起飞太突兀"）：
   * 0 = 平躺在书架上的书；1 = 被拿起来的书（微微放大 + 抬起 + 影子分离）。
   * 进场最前面 `LT_LIFT_DUR` 内补上，返回最后 `LT_LIFT_DUR` 内收回。
   */
  public lift: number = 0;

  /** 窗口尺寸（vp，盒内内容布局基准） */
  public winWvp: number = 0;
  public winHvp: number = 0;

  /** NavDestination 尺寸（onSizeChange 同步，官方契约保留） */
  public navDestSize: SizeOptions = { width: '100%', height: '100%' };

  // ── 几何（initGeometry 计算；进/出共用同一份）──────────────────────────────
  /** 书盒横向缩放初值 = 封面宽 / 窗宽（仅用于 bookScale 起点） */
  public s0: number = 1;
  /** 封面槽位左上角（vp） */
  public tx0: number = 0;
  public ty0: number = 0;
  /** 封面尺寸（vp） */
  public cardWvp: number = 0;
  public cardHvp: number = 0;
  /** 封面圆角（vp） */
  public coverRadius0: number = 0;

  /**
   * 几何初值（左上角锚定）。公式与 `docs/shelf-to-reader-longtake-spec.md:312-318`
   * 同源（那份公式已用真机日志逐位验证 5/5），只是把"缩放+书脸高"换成绝对盒。
   */
  private initGeometry(): void {
    if (!WindowUtils.windowWidth_px || !WindowUtils.windowHeight_px) {
      hilog.error(0x0000, TAG, 'initGeometry failed: WindowUtils not init (ezCustomTransition.init 未调用?)');
      return;
    }
    if (this.cardItemInfo_px.width <= 0 || this.cardItemInfo_px.height <= 0) {
      hilog.error(0x0000, TAG, 'initGeometry failed: card rect is empty');
      return;
    }
    this.winWvp = px2vp(WindowUtils.windowWidth_px);
    this.winHvp = px2vp(WindowUtils.windowHeight_px);
    this.cardWvp = px2vp(this.cardItemInfo_px.width);
    this.cardHvp = px2vp(this.cardItemInfo_px.height);
    this.s0 = this.cardItemInfo_px.width / WindowUtils.windowWidth_px;
    this.tx0 = px2vp(this.cardItemInfo_px.left);
    this.ty0 = px2vp(this.cardItemInfo_px.top);
    // ⚠️ cornerRadius 的单位是 **vp**（官方语义：它不经换算直接进 `.borderRadius()`，
    //    见官方 LongTakeSession `initParams`：`radius = cornerRadius / initScale`）。
    //    这里**不能**再 px2vp —— 旧写法 px2vp(4)=1.185vp，导致首帧圆角比书架封面小 3 倍。
    this.coverRadius0 = this.cardItemInfo_px.cornerRadius;
    this.logProbe('geom');
  }

  /** 取证日志（`UiMotion.LT_BOOK_LOG` 控制；只打时间戳与关键量，零负担时可关） */
  private logProbe(stage: string): void {
    if (!UiMotion.LT_BOOK_LOG) {
      return;
    }
    hilog.info(0x0000, TAG,
      `probe ${stage} t=${Date.now()} s0=${this.s0} card=(${this.tx0},${this.ty0} ${this.cardWvp}x${this.cardHvp}) ` +
        `r0=${this.coverRadius0} box=(${this.bookX},${this.bookY} ${this.bookW}x${this.bookH}) ` +
        `scale=${this.bookScale} angle=${this.coverAngle} lift=${this.lift}`);
  }

  /** 标记/清除"一镜到底转场进行中"（点击侧的闸读它，见 `UiMotion.LT_FLAG_TRANSITIONING`） */
  public setTransitioning(on: boolean): void {
    AppStorage.setOrCreate(UiMotion.LT_FLAG_TRANSITIONING, on);
  }

  /**
   * 出队一个本 session 注册过的 navDestinationId 并注销（FIFO，见 `registeredIds` 注释）。
   * delegate 的 `onDisAppear` 调它 —— **不要**再直接传 `getNavDestinationId()`：
   * 那个值在快速开关时已经指向新页面了。
   */
  public unregisterOldestRegistered(): void {
    if (this.registeredIds.length === 0) {
      return;
    }
    const id: string | undefined = this.registeredIds.shift();
    if (id !== undefined && id !== '') {
      CustomTransition.getInstance().unRegisterNavParam(id);
    }
  }

  public doAnimation(isPush: boolean, isExit: boolean, transitionProxy: NavigationTransitionProxy): void {
    if (isPush && !isExit) {
      this.doEnterAnimation(transitionProxy);
    } else if (!isPush && isExit) {
      this.doBackAnimation(transitionProxy);
    }
  }

  /** 合上的书停在槽位（进场首帧 / 返回末帧）——与书架封面逐位重合 */
  private applyClosedAtSlot(): void {
    this.bookX = this.tx0;
    this.bookY = this.ty0;
    this.bookW = this.cardWvp;
    this.bookH = this.cardHvp;
    this.bookScale = this.s0;
    this.coverAngle = 0;
    this.coverRadius = this.coverRadius0;
  }

  /** 整屏阅读（进场末帧 / 返回首帧）：封面侧立不可见，内容页铺满 */
  private applyReadingFull(): void {
    this.bookX = 0;
    this.bookY = 0;
    this.bookW = this.winWvp;
    this.bookH = this.winHvp;
    this.bookScale = 1;
    this.coverAngle = UiMotion.LT_FLIP_ANGLE;
    this.coverRadius = 0;
  }

  /**
   * 进场（`LT_ENTER_DUR` ms，四段同时起跑 → 一镜到底）：
   * ① **起手**（0→`LT_LIFT_DUR`）：书被"拿起来"——微放大 + 抬升 + 影子分离；
   * ② 书盒：四条边 槽位→整窗；
   * ③ 封面：晚 `LT_FLIP_DELAY` 起、与飞行同时到位，angle 0 → LT_FLIP_ANGLE
   *    （绕左缘掀开、左低右高），压在下面的内容页从右边渐进露出，到最大即整屏阅读器。
   */
  public doEnterAnimation(transitionProxy?: NavigationTransitionProxy): void {
    this.initGeometry();
    if (this.s0 <= 0 || this.cardWvp <= 0) {
      // 几何不可用（window 未初始化 / 槽位为空）：不接管本次转场，交回框架
      hilog.error(0x0000, TAG, 'enter: geometry invalid, skip custom animation');
      this.transitionParam.options?.onEnterTransitionStart?.();
      this.transitionParam.options?.onEnterTransitionEnd?.();
      transitionProxy?.finishTransition();
      return;
    }

    // ── 起始帧：一本合着的书，平放在书架封面的那个槽位 ──
    this.applyClosedAtSlot();
    this.coverPerspective = UiMotion.LT_COVER_PERSPECTIVE;
    this.lift = 0;
    // 书体块取阅读器真实底色/材质（ReaderPage3.publishLtPageBg 持续发布到 AppStorage）
    this.pageBodyColor = AppStorage.get<ResourceColor>(UiMotion.LT_PAGE_BG_KEY) ?? FALLBACK_PAGE_BG;
    this.pageBodyImg = AppStorage.get<string>(UiMotion.LT_PAGE_IMG_KEY) ?? '';
    this.transitionParam.options?.onEnterTransitionStart?.();
    this.setTransitioning(true);
    this.logProbe('enter-start');

    let animationCount = ++this.animationCount;

    // ① 起手：先"把书拿起来"（之后一直保持"在手里"的姿态）
    animateTo({
      duration: UiMotion.LT_LIFT_DUR,
      curve: Curve.FastOutSlowIn
    }, () => {
      this.lift = 1;
    })

    // ② 整本书（盒）飞向全屏
    animateTo({
      duration: UiMotion.LT_ENTER_DUR,
      curve: Curve.EaseInOut,
      onFinish: () => {
        // ⚠️ 只有"当前这一条动画"才有权结束转场：被后来者顶掉的旧动画若也去
        // finishTransition()，框架会报 `not support to finish custom animation more than once`
        //（真机日志 35 次），并可能把转场状态机搅乱。
        if (animationCount === this.animationCount) {
          this.animationCount = 0;
          this.setTransitioning(false);
          this.transitionParam.options?.onEnterTransitionEnd?.();
          this.logProbe('enter-end');
          if (transitionProxy) {
            transitionProxy.finishTransition();
          }
        }
      }
    }, () => {
      this.bookX = 0;
      this.bookY = 0;
      this.bookW = this.winWvp;
      this.bookH = this.winHvp;
      this.bookScale = 1;
      this.coverRadius = 0;
    })

    // ③ 封面绕书脊（左缘）掀开
    animateTo({
      delay: UiMotion.LT_FLIP_DELAY,
      duration: Math.max(1, UiMotion.LT_ENTER_DUR - UiMotion.LT_FLIP_DELAY),
      curve: Curve.EaseInOut
    }, () => {
      this.coverAngle = UiMotion.LT_FLIP_ANGLE
    })

    // ④ 落定：末段把"起手"收回 —— **阅读态必须 lift=0**
    //   （2026-10-04 用户："阅读器里顶部的四圆角组件比例都变了、右侧溢出了"：
    //    进场结束后 lift 一直是 1 ⇒ 整层被 ×1.09 且上移 18vp，顶栏胶囊（width 90%）
    //    因此右溢出屏幕 ~14vp。现在双保险：这里收回 + Delegate 里按"离地权重"缩放效果。）
    animateTo({
      delay: Math.max(0, UiMotion.LT_ENTER_DUR - UiMotion.LT_LIFT_DUR),
      duration: UiMotion.LT_LIFT_DUR,
      curve: Curve.FastOutSlowIn
    }, () => {
      this.lift = 0
    })
  }

  /**
   * 返回前置：重测封面槽位（书架可能已滚动），几何全部重算。
   * （官方原样保留 —— ComponentAttrUtils 按 componentId 重测。）
   */
  public preBackAnimation(): void {
    let uiContext = WindowUtils.window.getUIContext();
    let newRectInfo: RectInfo_px | undefined = ComponentAttrUtils.getRectInfoById(uiContext,
      this.transitionParam.componentId, this.cardItemInfo_px.cornerRadius);
    if (newRectInfo) {
      this.cardItemInfo_px = newRectInfo;
      this.initGeometry();
    }
  }

  /**
   * 返回（`LT_POP_DUR` ms，**进场的精确时间镜像**）：
   * ① 书盒四条边 整窗→槽位（封面仍侧立 ⇒ 阅读器从"最大"开始一起缩，不会瞬间变半屏）；
   * ② 封面在镜像窗口内翻回正对；
   * ③ 末段"收手"：抬升/放大/影子收回 ⇒ 像把书放回书架，落位即平放、与书架封面逐位重合。
   * 曲线与进场同为 `EaseInOut`（官方：低速开始和结束）——旧版用 `FastOutSlowIn`
   * （官方：标准曲线，起步快）⇒ 返回一开头被"拽"一下，观感比进场差（用户 2026-10-03 反馈）。
   */
  public doBackAnimation(transitionProxy?: NavigationTransitionProxy): void {
    this.transitionParam.options?.onBackTransitionStart?.();
    if (!CustomTransition.getInstance().interactive) {
      this.preBackAnimation();
    }
    if (this.s0 <= 0 || this.cardWvp <= 0) {
      hilog.error(0x0000, TAG, 'back: geometry invalid, skip custom animation');
      this.transitionParam.options?.onBackTransitionEnd?.();
      transitionProxy?.finishTransition();
      return;
    }

    // ── 起始帧：整屏阅读（封面侧立不可见、内容页全程可见）──
    this.applyReadingFull();
    this.lift = 1;
    this.setTransitioning(true);
    this.logProbe('pop-start');

    let animationCount = ++this.animationCount;

    // ① 书盒缩回槽位
    animateTo({
      duration: UiMotion.LT_POP_DUR,
      curve: UiMotion.LT_POP_SHRINK_CURVE,
      onFinish: () => {
        if (animationCount === this.animationCount) {
          this.animationCount = 0;
          this.setTransitioning(false);
          this.transitionParam.options?.onBackTransitionEnd?.();
          this.logProbe('pop-end');
          if (transitionProxy) {
            transitionProxy.finishTransition();
          }
        }
      }
    }, () => {
      this.bookX = this.tx0;
      this.bookY = this.ty0;
      this.bookW = this.cardWvp;
      this.bookH = this.cardHvp;
      this.bookScale = this.s0;
      this.coverRadius = this.coverRadius0;
    })

    // ② 封面翻回盖住页面：窗口 = 进场翻折窗口的时间镜像
    //    [LT_POP_DUR - LT_ENTER_DUR, LT_POP_DUR - LT_FLIP_DELAY]
    animateTo({
      delay: Math.max(0, UiMotion.LT_POP_DUR - UiMotion.LT_ENTER_DUR),
      duration: Math.max(1, UiMotion.LT_ENTER_DUR - UiMotion.LT_FLIP_DELAY),
      curve: Curve.EaseInOut
    }, () => {
      this.coverAngle = 0;
    })

    // ③ 收手：末段把"拿起来"的位移/放大/影子收回去（= 进场起手的镜像）
    animateTo({
      delay: Math.max(0, UiMotion.LT_POP_DUR - UiMotion.LT_LIFT_DUR),
      duration: UiMotion.LT_LIFT_DUR,
      curve: Curve.FastOutSlowIn
    }, () => {
      this.lift = 0;
    })
  }

  /**
   * 手势返回的**跟手帧**（官方手势框架驱动）。
   * scaleValue：手势驱动的缩放（官方同款公式），内部换算跟手进度 p：
   *   0 = 全屏阅读，1 = 落回槽位。全部视觉量线性跟手；**阅读器始终可见**。
   */
  public applyInteractiveProgress(deltaX: number, deltaY: number, scaleValue: number): void {
    const p: number = Math.min(1, Math.max(0, (1 - scaleValue) / (1 - GESTURE_MIN_SCALE)));
    this.bookX = this.tx0 * p + deltaX * (1 - p);
    this.bookY = this.ty0 * p + deltaY * (1 - p);
    this.bookW = this.winWvp + (this.cardWvp - this.winWvp) * p;
    this.bookH = this.winHvp + (this.cardHvp - this.winHvp) * p;
    this.bookScale = 1 - (1 - this.s0) * p;
    this.coverAngle = UiMotion.LT_FLIP_ANGLE * (1 - p);
    this.coverRadius = this.coverRadius0 * p;
    this.lift = 1 - p;
  }

  /** 手势取消/未达阈值：回到全屏阅读姿态（封面侧立、内容页仍可见） */
  public recoverToReading(): void {
    this.applyReadingFull();
    this.lift = 1;
    this.setTransitioning(false);
  }

  /**
   * **起手效果的"离地权重"** 0~1（CardLongTakeDelegate 渲染用）：
   *   w = (1 - bookScale) / (1 - s0)
   * ⇒ 书缩到卡片大小（bookScale = s0）时 w = 1（起手效果满量）；
   *   书铺满整窗（bookScale = 1，即**阅读态**）时 w = 0（起手效果归零）。
   * 为什么需要它（2026-10-04 真机问题）：起手的放大/抬升曾直接挂在整层上，
   * 进场结束后 `lift` 仍为 1 ⇒ 阅读器被整体 ×1.09 并上移 18vp，
   * 顶栏胶囊（`ReaderPage3.ets:4763` `width('90%')` 居中）右溢出屏幕约 14vp。
   * 有了权重，**阅读态在数学上不可能被起手影响**（不依赖"记得把 lift 收回"）。
   */
  public liftEffect(): number {
    if (this.s0 <= 0 || this.s0 >= 1) {
      return this.lift;
    }
    const w: number = (1 - this.bookScale) / (1 - this.s0);
    const clamped: number = w < 0 ? 0 : (w > 1 ? 1 : w);
    return this.lift * clamped;
  }

  public setNewSize(newSize: SizeOptions): void {
    this.navDestSize = newSize;
  }

  public getNavDestinationId(): string {
    return this.navDestinationId;
  }

  public getPathStack(): NavPathStack {
    return this.navPathStack;
  }

  public getTransitionParam(): LongTakeTransitionParam {
    return this.transitionParam;
  }

  public updateSnapshotComponentId(newSnapshotComponentId: string): void {
    hilog.info(0x0000, TAG, `updateSnapshotComponentId, new id is ${newSnapshotComponentId}`);
    this.transitionParam.componentId = newSnapshotComponentId;
  }

  public init(context: NavDestinationContext, param: LongTakeTransitionParam, options: LongTakeSessionOptions): void {
    this.navPathStack = context?.pathStack;
    if (!context || !param || !context.navDestinationId || !param.componentRectInfo || !options) {
      hilog.info(0x0000, TAG, `init param is invalid!`);
      return;
    }
    if (param.componentRectInfo.width == 0 || param.componentRectInfo.height == 0) {
      return;
    }

    try {
      this.transitionParam = param;
      this.cardItemInfo_px = param.componentRectInfo;
      this.options = options;
      this.navDestinationId = context.navDestinationId;
      this.type = param.options?.type ?? LongTakeTransitionType.CardLongTake;
      this.snapshotImage = SnapShotImage.pixelMap;
      // 先算一次几何并落到"合上的书停在槽位"：init 早于转场回调时，首帧就已经正确
      this.initGeometry();
      this.applyClosedAtSlot();
      this.lift = 0;

      CustomTransition.getInstance().registerNavParam(context.navDestinationId,
        (isPush: boolean, isExit: boolean, transitionProxy: NavigationTransitionProxy) => {
          this.doAnimation(isPush, isExit, transitionProxy);
        }, undefined);
      this.registeredIds.push(context.navDestinationId);
      return;
    } catch (e) {
      hilog.error(0x0000, TAG, `initLongTakeTransition failed, code is ${e.code}, message is ${e.message}`);
      return;
    }
  }
}
