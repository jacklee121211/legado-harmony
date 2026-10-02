import { UIContext } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG = 'ComponentAttrUtils';

export class ComponentAttrUtils {
  // 根据组件的id获取组件的位置信息
  public static getRectInfoById(context: UIContext, id: string, cornerRadius: number): RectInfo_px | undefined {
    if (!context || !id) {
      return undefined;
    }
    let node = context.getAttachedFrameNodeById(id);
    if (!node) {
      hilog.error(0x00, TAG, `getRectInfoById failed, cannot get node by id ${id}`);
      return undefined;
    }

    let sizeValue = node.getMeasuredSize();
    let widthValue = sizeValue.width;
    let heightValue = sizeValue.height;
    if (widthValue == 0 || heightValue == 0) {
      hilog.error(0x00, TAG, `size might be 0, width is ${widthValue}, height is ${heightValue}`);
      return undefined;
    }

    let positionValue = node.getPositionToWindowWithTransform();
    let leftPosition = context.vp2px(positionValue.x);
    let topPosition = context.vp2px(positionValue.y);
    return {
      left: leftPosition,
      top: topPosition,
      width: widthValue,
      height: heightValue,
      cornerRadius: cornerRadius ?? 0,
    }
  }
}

export class RectInfo_px {
  left: number = 0;
  top: number = 0;
  width: number = 0;
  height: number = 0;
  cornerRadius: number = 0;
}