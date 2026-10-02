import { LongTakeSession } from '../sessions/LongTakeSession';
import { LongTakeTransitionType } from '../Constants/ezCustomTransitionConstants';
import { CardLongTakeDelegate } from './CardLongTakeDelegate';

/**
 * 一镜到底 Delegate 分发器（官方原样，2026-10-02 fork 微调）：
 * 本工程恒用 CardLongTake（卡片打开）⇒ ImageLongTake 分支整块退役
 *（其依赖的 session.scaleValue 等字段已随三层书模型重构移除）。
 */
@Component
export struct LongTakeTransitionDelegate{
  @BuilderParam contentBuilder: () => void;

  @ObjectLink longTakeSession: LongTakeSession;

  build() {
    CardLongTakeDelegate({
      longTakeSession: this.longTakeSession,
      contentBuilder: (): void => {
        this.contentBuilder();
      }
    })
  }
}
