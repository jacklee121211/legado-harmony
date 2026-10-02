import { WindowUtils } from './utils/WindowUtils'
import { window } from '@kit.ArkUI'
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