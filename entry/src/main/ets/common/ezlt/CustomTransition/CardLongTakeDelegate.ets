import { LongTakeSession } from '../sessions/LongTakeSession';
import { CustomTransition } from '../utils/CustomNavigationUtils';
import { curves } from '@kit.ArkUI';
import UiMotion from '../../../common/utils/UiMotion';

const MIN_SCALE_VALUE: number = 0.5;

const RETURN_TO_PRE_PAGE_SCALE_VALUE: number = 0.85;

/**
 * 卡片一镜到底 Delegate —— **fork 重写 v4（2026-10-03，书盒四边独立插值）**。
 *
 * ── 与官方原版的区别（本 fork 的全部视觉 diff）────────────────────────────────
 * 官方：根 Stack 等比缩放（scaleValue），内含 [内容(交叉淡化)] + [卡片快照(等比拉大)]，
 *       观感 = "一张卡片被拉大"；全库没有 `rotate`（无 3D、无翻折）⇒ 做不出"书打开"。
 * 本工程：**书盒 (x,y,w,h) 四边各自单调插值** + 两个同盒图层：
 *   ① 内容层：真阅读器（整窗布局 → 等比缩到盒宽 → 被盒 clip）—— 全程 opacity=1；
 *   ② 封面层：与盒同盒 ⇒ 书脊（左缘）天然对齐、等高，绕左缘 3D 翻折（左低右高）。
 *
 * ── 为什么盒高必须独立插值（v4 的由来）───────────────────────────────────────
 * v3 用 `scale + 书脸高` 合成盒子的高度（height = clipH(u)·s(u)，u 的二次函数），
 * 底边会 `(ty0 + cardH) + (490.95 − ty0)·u + 272.9·u²` —— **封面槽位越靠下
 * （ty0 > 490.95vp），底边越先上漂再回落**，回落时露出书架原位那本书的下缘
 * （用户 2026-10-03："上面三本很好，越往下越明显、对不齐"）。
 * v4 四条边都是"卡片矩形 → 整窗"的线性插值 ⇒ 四个方向都单调 ⇒
 * 飞行中的书**恒包含**被点击的那本书的矩形（且恒在窗内）⇒ 任意位置都遮得住。
 */
@Component
export struct CardLongTakeDelegate {
  @BuilderParam contentBuilder: () => void;
  @ObjectLink longTakeSession: LongTakeSession;

  private rectWidth: number = 0;
  private scaleValue: number = 0;
  private animationCount: number = 0;

  unRegisterNavParam(): void {
    // ⚠️ 不能传 `getNavDestinationId()`：session 被所有阅读页实例共用，快速开关时它已指向
    //    新页面 ⇒ 会把新页面的转场注册删掉（真机日志 `custom transition is invalid` 5 次）。
    //    改为按注册顺序出队（FIFO），见 LongTakeSession.registeredIds 注释。
    this.longTakeSession.unregisterOldestRegistered();
  }

  private isGestureDisabled(): boolean {
    return (((this.longTakeSession.getTransitionParam().options?.isGestureEnabled != undefined)
      && (!this.longTakeSession.getTransitionParam().options?.isGestureEnabled))
      || (this.longTakeSession.getTransitionParam().snapShotComponentId != undefined))
  }

  @Styles
  ExitGestureStyle() {
    .gesture(
      PanGesture({ direction: PanDirection.Right })
        .onActionStart((event: GestureEvent) => {
          if (this.isGestureDisabled()) {
            return;
          }
          CustomTransition.getInstance().interactive = true;
          this.longTakeSession.setTransitioning(true);
          this.longTakeSession.preBackAnimation();
          this.longTakeSession.options?.pop();
          this.rectWidth = event.target.area.width as number;
          this.longTakeSession.options?.onBackGestureStart?.();
          let deltaX = event.offsetX;
          let deltaY = event.offsetY;
          this.scaleValue =
            Math.max(1 - (1 - MIN_SCALE_VALUE) * Math.abs(deltaX) / this.rectWidth, MIN_SCALE_VALUE);
          // fork·跟手：拖动起点即进入"书被合上"的姿态（盒四边/内容缩放/翻折角全部跟手）
          this.longTakeSession.applyInteractiveProgress(deltaX, deltaY, this.scaleValue);
          animateTo({
            curve: curves.responsiveSpringMotion()
          }, () => {
            this.longTakeSession.applyInteractiveProgress(deltaX, deltaY, this.scaleValue);
          })
          ++this.animationCount;
        })
        .onActionUpdate((event: GestureEvent) => {
          if (this.isGestureDisabled()) {
            return;
          }
          if (CustomTransition.getInstance().interactive) {
            let deltaX = event.offsetX;
            let deltaY = event.offsetY;
            this.scaleValue =
              Math.max(1 - (1 - MIN_SCALE_VALUE) * Math.abs(deltaX) / this.rectWidth, MIN_SCALE_VALUE);
            this.longTakeSession.applyInteractiveProgress(deltaX, deltaY, this.scaleValue);
          }
        })
        .onActionEnd((event: GestureEvent) => {
          if (this.isGestureDisabled()) {
            return;
          }
          if (CustomTransition.getInstance().interactive) {
            let currentTransitionProxy = CustomTransition.getInstance().proxy;
            let deltaX = event.offsetX;
            this.scaleValue =
              Math.max(1 - (1 - MIN_SCALE_VALUE) * Math.abs(deltaX) / this.rectWidth, MIN_SCALE_VALUE);
            if (this.scaleValue > RETURN_TO_PRE_PAGE_SCALE_VALUE) {
              // 未达返回阈值 ⇒ 弹回全屏阅读（封面回侧立、内容页仍可见）
              this.longTakeSession.options?.onRecoverStart?.();
              let animationCount = ++this.animationCount;
              animateTo({
                curve: curves.springMotion(),
                onFinish: () => {
                  if (currentTransitionProxy?.cancelTransition) {
                    currentTransitionProxy?.cancelTransition();
                  }
                  if (animationCount === this.animationCount) {
                    this.longTakeSession.options?.onRecoverEnd?.();
                  }
                }
              }, () => {
                this.longTakeSession.recoverToReading();
              })
            } else {
              this.longTakeSession.doBackAnimation(currentTransitionProxy);
            }
            CustomTransition.getInstance().interactive = false;
          }
        })
        .onActionCancel(() => {
          // fork·中断自愈：手势取消 ⇒ 全部视觉量弹回阅读器姿态（含翻折角）
          this.longTakeSession.recoverToReading();
          CustomTransition.getInstance().proxy?.cancelTransition?.();
          CustomTransition.getInstance().interactive = false;
        })
    )
  }

  build() {
    // ── 一本打开的书：书盒（四个边各自插值）内含 内容层裁切盒 + 封面层（同盒、兄弟）──
    //    ⛔ 书盒**绝对不能 clip**：封面是绕左缘转的平面，强透视下投影会"扑出盒外"
    //       （左脊边等高、自由边被放大更长）——那正是梯形透视本身。一旦把封面放进
    //       clip 层，溢出的斜边被切掉，剩下的盒内部分看起来就是**矩形**
    //       （2026-10-03 用户："翻页变成矩形了，没有梯形透视"）。裁切只给内容层。
    Stack({ alignContent: Alignment.TopStart }) {
      Stack({ alignContent: Alignment.TopStart }) {
        // ① 内容层：外层 = **裁切盒**（可见范围 = 书脸：卡片矩形 → 整窗，把真阅读器揭开）；
        //    内层 = 整窗尺寸的内容整体（⇒ 全程不重排），整体**等比**缩到盒宽，绝不拉伸。
        //    ⚠️ 裁切与缩放必须分两层：`width/height` 后写的会覆盖先写的，写在一层上
        //       会让阅读器按"书脸尺寸"重排（内容会重排/抖动）。
        Stack({ alignContent: Alignment.TopStart }) {
          Stack({ alignContent: Alignment.TopStart }) {
            // 内容页底色/材质（阅读器主题色同源）——真阅读器下方的兜底，防首帧露书架
            if (this.longTakeSession.pageBodyColor !== '') {
              Column()
                .width('100%')
                .height('100%')
                .backgroundColor(this.longTakeSession.pageBodyColor)
            }
            if (this.longTakeSession.pageBodyImg !== '') {
              Image(this.longTakeSession.pageBodyImg)
                .width('100%')
                .height('100%')
                .objectFit(ImageFit.Cover)
                .draggable(false)
            }
            Stack() {
              this.contentBuilder()
            }
            .width('100%')
            .height('100%')
          }
          .width(this.longTakeSession.winWvp)
          .height(this.longTakeSession.winHvp)
          .scale({
            x: this.longTakeSession.bookScale,
            y: this.longTakeSession.bookScale,
            centerX: 0,
            centerY: 0
          })
        }
        .width(this.longTakeSession.bookW)
        .height(this.longTakeSession.bookH)
        .borderRadius(this.longTakeSession.coverRadius)
        .clip(true)

        // ② 封面（同盒、书脊=左缘对齐、**与内容裁切盒平级**）：绕左缘 3D 翻折，投影可自由扑出盒外。
        //    ⚠️ 封面必须**不透明**（2026-10-02 用户："封面一开始就是半透明的，遮不住底下的内容层"）：
        //    快照位图带 alpha（默认封面 SVG = 白底 + 0.2~0.8 透明度的红色渐变），
        //    这里在**同一个旋转平面内**垫一层不透明底（子节点一定会被画进去）⇒ 实心书皮。
        Stack() {
          Column()
            .width('100%')
            .height('100%')
            .backgroundColor(UiMotion.LT_COVER_BACK_COLOR)
          Image(this.longTakeSession.snapshotImage)
            .width('100%')
            .height('100%')
            // Fill：整张封面铺满书盒（纵横比从卡片长到整窗的过程中**不裁切**，
            // 保证"飞起来的是这本书的封面"整张，而不是封面中段）
            .objectFit(UiMotion.LT_COVER_FIT_CROP ? ImageFit.Cover : ImageFit.Fill)
            .syncLoad(true)
        }
        .width(this.longTakeSession.bookW)
        .height(this.longTakeSession.bookH)
        .borderRadius(this.longTakeSession.coverRadius)
        // perspective=0（系统自算，见 LongTakeSession 类头 ②）：SDK 明确其单位为 px，
        // 写死小于封面宽的数值会让自由边穿过相机平面 ⇒ 投影奇异。
        .rotate({
          y: 1,
          centerX: 0,
          angle: this.longTakeSession.coverAngle,
          perspective: this.longTakeSession.coverPerspective
        })
        // 影子是"离地高度"的视觉语言：起手/飞行时变大变远，落位时收回贴地。
        // ⚠️ 一律用 `liftEffect()`（带"离地权重"）而不是 `lift`：阅读态权重为 0，
        //    保证转场结束后不会残留放大/抬升/大影子（2026-10-04 阅读器顶栏溢出问题）。
        .shadow({
          radius: UiMotion.LT_COVER_SHADOW_RADIUS
            + (UiMotion.LT_LIFT_SHADOW_RADIUS - UiMotion.LT_COVER_SHADOW_RADIUS)
            * this.longTakeSession.liftEffect(),
          color: 'rgba(0, 0, 0, 0.22)',
          offsetX: 0,
          offsetY: UiMotion.LT_COVER_SHADOW_OFFSET_Y
            + (UiMotion.LT_LIFT_SHADOW_OFFSET_Y - UiMotion.LT_COVER_SHADOW_OFFSET_Y)
            * this.longTakeSession.liftEffect()
        })
        .draggable(false)
        .enabled(false)
        .hitTestBehavior(HitTestMode.None)
      }
      // ★ 书盒：四条边（x/y/w/h）各自单调插值 —— 飞行中的书恒包含被点击那本书的矩形。
      //   ⛔ 这里**不 clip**（见 build 首行注释）；裁切交给 ① 的内容层裁切盒。
      .width(this.longTakeSession.bookW)
      .height(this.longTakeSession.bookH)
      .translate({
        x: this.longTakeSession.bookX,
        // "起手/收手"的额外抬升（vp，带离地权重）：书离开书架一点点，落位时收回 ⇒ 落点不变
        y: this.longTakeSession.bookY - UiMotion.LT_LIFT_Y * this.longTakeSession.liftEffect()
      })
      // 起手的额外放大（围绕书盒左上角 ⇒ 只向右下长，仍然遮得住卡片）——同样带离地权重
      .scale({
        x: 1 + (UiMotion.LT_LIFT_SCALE - 1) * this.longTakeSession.liftEffect(),
        y: 1 + (UiMotion.LT_LIFT_SCALE - 1) * this.longTakeSession.liftEffect(),
        centerX: 0,
        centerY: 0
      })
    }
    .width('100%')
    .height('100%')
    // 沉浸式：向上扩到状态栏、向下扩到导航条（几何以窗口左上角为原点）
    .expandSafeArea([SafeAreaType.SYSTEM])
    .onDisAppear(() => {
      this.unRegisterNavParam();
    })
    .ExitGestureStyle()
  }
}
