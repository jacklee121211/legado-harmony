import { WindowUtils } from './utils/WindowUtils'
import { window } from '@kit.ArkUI'
import { deviceInfo } from '@kit.BasicServicesKit'
import { AnimateCallback, CustomTransition} from './utils/CustomNavigationUtils';
import { ezCustomTransitionConstants, LongTakeTransitionType } from './Constants/ezCustomTransitionConstants';
import { ComponentAttrUtils } from './utils/ComponentAttrUtils';
import { LongTakeTransitionParam } from './utils/LongTakeTransitionParam';
import { CustomTransitionOptions, LongTakeTransitionOptions } from './utils/Options';
import { SnapShotImage } from './utils/SnapShotImage';
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG: string = 'ezCustomTransition';

export class ezCustomTransition {
  private static animationCountMap: Map<string, number> = new Map();

  /**
   * 一镜到底的**设备级开关**：只有手机为 `true`，tablet / 2in1 一律关闭（2026-10-23 用户决定）。
   *
   * ── 为什么从"只在横屏禁用"升级为"非手机全禁"（结构性原因，非体验偏好）──────
   *   `CardLongTakeDelegate.build()` 把阅读页包进一层**写死尺寸的裁切盒**
   *   （`CustomTransition/CardLongTakeDelegate.ets:160-215`）：
   *     `Stack{ Stack{ ReaderPage3 } .width(winWvp).height(winHvp).scale(...) }`
   *     `.width(bookW).height(bookH).clip(true)`
   *   而 `winWvp/winHvp` 只在 `LongTakeSession` 初始化时算一次
   *   （`sessions/LongTakeSession.ets:175-176`：`px2vp(WindowUtils.windowWidth_px)`），
   *   `onSizeChange` 里只写 `this.navDestSize = newSize`，**没有任何地方重算盒子尺寸**。
   *   ⇒ 只要走一镜到底，阅读页就住在一个"不会随窗口变化"的盒子里，
   *     只是转场结束后视觉上"铺满"了而已。
   *   ⇒ 平板旋转 / 2in1 自由窗口缩放时，`ReadPageComponent` 的排版尺寸
   *     与 XComponent surface 的分配尺寸必然分叉 ⇒ 内容被压进错尺寸的 surface
   *     （真机现象："溢出左侧/右侧空白/整页被压缩"，2026-10-23 复现）。
   *
   *   在生成入口直接拦掉 ⇒ 阅读页**不再被 Delegate 包裹**（`Index.ets:2122` 走 else
   *   分支，`ReaderPage3` 直接挂在 `NavDestination` 下），中间盒、`.clip()`、
   *   `.scale()` 全部不存在，尺寸天然来自真实窗口 —— 这就是"结构隔离"，
   *   比在运行时判断宽高再去修补更彻底。
   *
   * ── 影响面（返回 `false` 时，以下全部自动回落到系统原生方案）──────────────
   *   · `generateLongTakeParam*()` 返回 `undefined`；
   *   · **连封面快照都不截**（截图的 `getSync()` 在下面两行之后才执行）；
   *   · `AppRouter` 的 `longTakeTransitionParam` 为空 ⇒ `Index.ets:2122` 走 else；
   *   · `systemTransition` 由 `NavigationSystemTransitionType.NONE`
   *     回落到 `UiMotion.pageTransition(UiMotion.T_READER)`（`Index.ets:2171-2173`）；
   *   · txt 与 **PDF** 共用本开关，不会出现"txt 走默认、PDF 还在一镜到底"的割裂。
   *
   * ── 手机为什么完全不受影响 ────────────────────────────────────────────────
   *   `EntryAbility.initWindowProcess` 已把手机锁成 PORTRAIT，窗口尺寸恒定，
   *   上面那层固定盒子不会与真实窗口分叉；且本方法对 phone 恒返回 `true`。
   *
   * 回退：把本方法改成 `return true;` ⇒ 所有设备恢复一镜到底（代码路径全部保留）。
   */
  private static isLongTakeEnabledDevice(): boolean {
    const type: string = deviceInfo.deviceType;
    const on: boolean = type === 'phone';
    if (!on) {
      hilog.info(0x00, TAG,
        `longtake disabled on deviceType=${type} (phone-only), fallback to system transition`);
    }
    return on;
  }

  private static getTransitionKey(from: NavContentInfo, to: NavContentInfo, operation: NavigationOperation): string {
    return `${from.navDestinationId}_${to.navDestinationId}_${operation}`;
  }

  public static init(windowStage: window.WindowStage) {
    WindowUtils.init(windowStage);
  }

  public static onConfigurationChanged(): void {
    AppStorage.setOrCreate(ezCustomTransitionConstants.CONFIGURATION_UPDATE, Date.now());
  }

  public static generateLongTakeParam(uiContext: UIContext, cardId: string, cornerRadius: number,
    options?: LongTakeTransitionOptions): LongTakeTransitionParam | undefined {
    // 仅手机启用一镜到底；tablet / 2in1 直接不生成参数（见 `isLongTakeEnabledDevice()` 注释）
    // ⚠️ 必须放在**截图之前**：这里返回后不再执行 `getComponentSnapshot().getSync()`，
    //    平板/2in1 因此连一次封面快照都不会拍（省掉无用的整卡截图开销）。
    if (!ezCustomTransition.isLongTakeEnabledDevice()) {
      return undefined;
    }
    if (!uiContext || !cardId) {
      hilog.error(0x00, TAG, 'generateLongTakeParam error, cardId is invalid');
      return undefined;
    }

    try {
      let pixelMap = uiContext.getComponentSnapshot().getSync(cardId);
      hilog.info(0x00, TAG, `get ${cardId} snapshot sync success!`);
      SnapShotImage.pixelMap = pixelMap;
    } catch (e) {
      hilog.error(0x00, TAG, `getSync ${cardId} failed, code is ${e.code}, message is ${e.message}`);
      return undefined;
    }

    let cardRectInfo = ComponentAttrUtils.getRectInfoById(uiContext, cardId, cornerRadius);
    if (!cardRectInfo) {
      return undefined;
    }
    hilog.info(0x00, TAG, `getRectInfoById result is ${JSON.stringify(cardRectInfo)}`);
    let transitionParam: LongTakeTransitionParam = new LongTakeTransitionParam(cardRectInfo, options);
    transitionParam.componentId = cardId;
    transitionParam.transitionType = options?.type ?? LongTakeTransitionType.CardLongTake;
    return transitionParam;
  }

  public static generateLongTakeParamByRegion(uiContext: UIContext, longTakeCardId: string, snapshotComponentId: string,
    cornerRadius: number, options?: LongTakeTransitionOptions): LongTakeTransitionParam | undefined {
    // 同 `generateLongTakeParam`：非手机设备在**任何参数校验/截图之前**就退出，
    // 保证"结构隔离"对所有入口一致（见 `isLongTakeEnabledDevice()` 注释）。
    if (!ezCustomTransition.isLongTakeEnabledDevice()) {
      return undefined;
    }
    if (!uiContext || !longTakeCardId) {
      hilog.error(0x00, TAG, 'generateLongTakeParam error, input param is invalid');
      return undefined;
    }

    if (!snapshotComponentId) {
      hilog.error(0x00, TAG, 'generateLongTakeParam error, snapshotComponentId is undefined');
      return ezCustomTransition.generateLongTakeParam(uiContext, longTakeCardId, cornerRadius, options);
    }

    let snapshotRectInfo = ComponentAttrUtils.getRectInfoById(uiContext, snapshotComponentId, 0);
    hilog.info(0x00, TAG, `snapshotRectInfo is ${JSON.stringify(snapshotRectInfo)}`);
    if (!snapshotRectInfo) {
      return ezCustomTransition.generateLongTakeParam(uiContext, longTakeCardId, cornerRadius, options);
    }
    let cardRectInfo = ComponentAttrUtils.getRectInfoById(uiContext, longTakeCardId, cornerRadius);
    hilog.info(0x00, TAG, `cardRectInfo is ${JSON.stringify(cardRectInfo)}`);
    if (!cardRectInfo) {
      return undefined;
    }

    try {
      let snapTop = Math.max(cardRectInfo.top - snapshotRectInfo.top, 0);
      let snapLeft = Math.max(cardRectInfo.left - snapshotRectInfo.left, 0);
      let snapRight = Math.min(cardRectInfo.left - snapshotRectInfo.left + cardRectInfo.width, snapshotRectInfo.width);
      let snapBottom = Math.min(cardRectInfo.top - snapshotRectInfo.top + cardRectInfo.height, snapshotRectInfo.height);
      let pixelMap = uiContext.getComponentSnapshot().getSync(snapshotComponentId, { region: {
        top: snapTop,
        left: snapLeft,
        right: snapRight,
        bottom: snapBottom,
      } });
      cardRectInfo.left = snapLeft + snapshotRectInfo.left;
      cardRectInfo.top = snapTop + snapshotRectInfo.top ;
      cardRectInfo.width = snapRight - snapLeft;
      cardRectInfo.height = snapBottom - snapTop;
      hilog.info(0x00, TAG, `get ${snapshotComponentId} snapshot sync success!`);
      SnapShotImage.pixelMap = pixelMap;
    } catch (e) {
      hilog.error(0x00, TAG, `getSync ${snapshotComponentId} failed, code is ${e.code}, message is ${e.message}`);
      return undefined;
    }

    let transitionParam: LongTakeTransitionParam = new LongTakeTransitionParam(cardRectInfo, options);
    transitionParam.componentId = longTakeCardId;
    transitionParam.snapShotComponentId = snapshotComponentId;
    transitionParam.transitionType = options?.type ?? LongTakeTransitionType.CardLongTake;
    return transitionParam;
  }

  public static customNavContentTransition(from: NavContentInfo, to: NavContentInfo,
    operation: NavigationOperation, options?: CustomTransitionOptions): NavigationAnimatedTransition | undefined {
    if (!from || !to) {
      return undefined;
    }
    from.navDestinationId = from.navDestinationId ?? '-1';
    to.navDestinationId = to.navDestinationId ?? '-1';

    // 针对点击按钮A走自定义转场点击按钮B走默认转场的场景，需要对是否注册了animation进行判断，来决定是否走自定义转场
    let fromParam: AnimateCallback = CustomTransition.getInstance().getAnimateParam(from.navDestinationId);
    let toParam: AnimateCallback = CustomTransition.getInstance().getAnimateParam(to.navDestinationId);

    CustomTransition.getInstance().operation = operation;
    if (CustomTransition.getInstance().interactive) {
      let customAnimation: NavigationAnimatedTransition = {
        onTransitionEnd: (isSuccess: boolean) => {
          options?.onTransitionEnd?.();
          CustomTransition.getInstance().proxy = undefined;
        },
        transition: (transitionProxy: NavigationTransitionProxy) => {
          options?.onTransitionStart?.();
          CustomTransition.getInstance().proxy = transitionProxy;
          let targetIndex: string | undefined = operation == NavigationOperation.PUSH ?
            (to.navDestinationId) : (from.navDestinationId);
          if (targetIndex) {
            CustomTransition.getInstance().fireInteractiveAnimation(targetIndex, operation);
          }
        },
        isInteractive: CustomTransition.getInstance().interactive
      }
      return customAnimation;
    }

    if (operation === NavigationOperation.PUSH && !toParam.animation) {
      return undefined;
    } else if (operation === NavigationOperation.POP && !fromParam.animation) {
      return undefined;
    }
    let transitionKey: string = ezCustomTransition.getTransitionKey(from, to, operation);
    let animationCount: number = (ezCustomTransition.animationCountMap.get(transitionKey) ?? 0) + 1;
    ezCustomTransition.animationCountMap.set(transitionKey, animationCount);
    let currCount: number = animationCount;
    let customAnimation: NavigationAnimatedTransition = {
      onTransitionEnd: (isSuccess: boolean) => {
        if (currCount === ezCustomTransition.animationCountMap.get(transitionKey)) {
          ezCustomTransition.animationCountMap.delete(transitionKey);
          options?.onTransitionEnd?.();
          hilog.info(0x00, TAG, `current custom transition result is ${isSuccess}`);
        }
      },
      timeout: 1000,
      transition: (transitionProxy: NavigationTransitionProxy) => {
        options?.onTransitionStart?.();
        hilog.info(0x00, TAG, 'trigger custom transition callback');
        if (fromParam.animation) {
          fromParam.animation(operation == NavigationOperation.PUSH, true, transitionProxy);
        }
        if (toParam.animation) {
          toParam.animation(operation == NavigationOperation.PUSH, false, transitionProxy);
        }
      }
    };
    return customAnimation;
  }
}