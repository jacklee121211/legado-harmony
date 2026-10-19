/**
 * 实时电量（2026-10-19 新增，用户需求：信息窗左侧在系统时间之后显示当前电量，
 * 用 symbol 图标 + 百分比 + 充电状态）。
 *
 * ── 为什么不能只读 `batteryInfo.batterySOC` ────────────────────────────────
 * `@ohos.batteryInfo.d.ts` 里 `batteryInfo` **只有常量与枚举**（该文件成员清单：
 *   `batterySOC` / `chargingStatus` / `healthStatus` / `pluggedType` / `voltage` /
 *   `technology` / `batteryTemperature` / `isBatteryPresent` / `batteryCapacityLevel` /
 *   `nowCurrent` 共 10 个 const + 5 个 enum），**没有任何 `on()/off()`**
 * ⇒ 想"实时"（插拔充电器、掉 1% 就刷新）必须订阅公共事件。
 *
 * ── 订阅方式（SDK 原文取证）────────────────────────────────────────────────
 * · `commonEventManager.Support.COMMON_EVENT_BATTERY_CHANGED = 'usual.event.BATTERY_CHANGED'`
 *   —— `@ohos.commonEventManager.d.ts:257`（**@since 9**，块内没有 `@permission` ⇒ 订阅无需权限）。
 *   该事件原文说明覆盖"电池电量 / 温度 / 健康 / 充电器类型 / 充电状态 / 充电次数…"任一项变化。
 * · `commonEventManager.createSubscriberSync(subscribeInfo)` —— 同文件 `:153`（同步建订阅者）。
 * · `commonEventManager.subscribe(subscriber, callback)` —— 同文件 `:170`（AsyncCallback 版）。
 * · `commonEventManager.unsubscribe(subscriber, callback?)` —— 同文件（退订）。
 * · 事件携带的参数键（`@ohos.batteryInfo.d.ts:300+` 的 `CommonEventBatteryChangedKey`）：
 *     `EXTRA_SOC = 'soc'`（剩余电量百分比）、`EXTRA_CHARGE_STATE = 'chargeState'`（充电状态）。
 * · `CommonEventData.parameters?: { [key: string]: any }`
 *   —— `api/commonEvent/commonEventData.d.ts:85`。ArkTS 不允许直接按 any 索引
 *   ⇒ 本文件统一 `as Record<string, Object>` 再取值（与 `MySetPage.calibDevRead()` 同款写法）。
 * · 充放电枚举 `batteryInfo.BatteryChargeState`（同文件 `:146`）：
 *     `NONE`(未知) / `ENABLE`(充电中) / `DISABLE`(未充电) / `FULL`(已充满)
 *   —— 原文："The battery is being charged." / "The battery is fully charged."。
 *
 * ── 设计约束 ───────────────────────────────────────────────────────────────
 * · **全局单订阅**：多处（阅读页信息窗、将来的其它界面）共用一份订阅与缓存，
 *   用引用计数 `refs` 保证最后一家退出时才退订（`unsubscribe` 漏掉会让回调闭包驻留）。
 * · 首值兜底：事件到来前先读一次 `batteryInfo.batterySOC` / `chargingStatus` 给初值。
 * · 全过程 try/catch：拿不到电量只是不显示，绝不影响阅读页。
 */
import commonEventManager from '@ohos.commonEventManager';
import batteryInfo from '@ohos.batteryInfo';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG: string = 'testTag';

/** 电量变化回调：soc = 0~100（-1 = 未知）；charging = 是否在充电（含已充满） */
export type BatteryListener = (soc: number, charging: boolean) => void;

export class BatteryStatus {
  private static subscriber: commonEventManager.CommonEventSubscriber | null = null;
  /** 引用计数：有多少个使用方在听（最后一个退订时真正 unsubscribe） */
  private static refs: number = 0;
  private static soc: number = -1;
  private static charging: boolean = false;
  private static listener: BatteryListener | null = null;
  private static loggedRaw: boolean = false;

  /** 当前电量百分比（0~100；-1 = 还没拿到） */
  static getSoc(): number {
    return BatteryStatus.soc;
  }

  /** 当前是否在充电（充电中或已充满） */
  static isCharging(): boolean {
    return BatteryStatus.charging;
  }

  /**
   * 开始监听（幂等，可多处调用）。
   * @param cb 每次电量/充电状态变化都会回调；注册时**立刻**回调一次当前缓存值
   */
  static start(cb: BatteryListener): void {
    BatteryStatus.refs++;
    BatteryStatus.listener = cb;
    // 首值兜底：事件到来前先把当前值读出来（插着充电器进阅读页时首帧就是对的）
    BatteryStatus.readConsts();
    cb(BatteryStatus.soc, BatteryStatus.charging);
    if (BatteryStatus.subscriber !== null) {
      return;
    }
    try {
      const info: commonEventManager.CommonEventSubscribeInfo = {
        events: [commonEventManager.Support.COMMON_EVENT_BATTERY_CHANGED]
      };
      const sub: commonEventManager.CommonEventSubscriber =
        commonEventManager.createSubscriberSync(info);
      BatteryStatus.subscriber = sub;
      commonEventManager.subscribe(sub,
        (err: BusinessError, data: commonEventManager.CommonEventData) => {
          if (err) {
            hilog.warn(0x0000, TAG, 'BatteryStatus: subscribe callback err=%{public}d', err.code ?? 0);
            return;
          }
          BatteryStatus.applyEvent(data);
        });
      hilog.info(0x0000, TAG, 'BatteryStatus: subscribed BATTERY_CHANGED, soc=%{public}d charging=%{public}s',
        BatteryStatus.soc, String(BatteryStatus.charging));
    } catch (e) {
      const err = e as BusinessError;
      hilog.warn(0x0000, TAG, 'BatteryStatus: subscribe failed %{public}d %{public}s',
        err.code ?? 0, err.message ?? '');
    }
  }

  /** 停止监听（引用计数归零才真正退订） */
  static stop(): void {
    if (BatteryStatus.refs > 0) {
      BatteryStatus.refs--;
    }
    if (BatteryStatus.refs > 0) {
      return;
    }
    BatteryStatus.listener = null;
    const sub = BatteryStatus.subscriber;
    BatteryStatus.subscriber = null;
    if (sub === null) {
      return;
    }
    try {
      commonEventManager.unsubscribe(sub);
      hilog.info(0x0000, TAG, 'BatteryStatus: unsubscribed');
    } catch (e) {
      // 退订失败不阻断（订阅者对象随之丢弃）
    }
  }

  /** 解析 `usual.event.BATTERY_CHANGED` 的 parameters 并通知 */
  private static applyEvent(data: commonEventManager.CommonEventData): void {
    let changed: boolean = false;
    try {
      const params = data.parameters as Record<string, Object> | undefined;
      if (params !== undefined) {
        const rawSoc: Object | undefined = params[batteryInfo.CommonEventBatteryChangedKey.EXTRA_SOC];
        if (rawSoc !== undefined) {
          const n: number = Number(rawSoc);
          if (!isNaN(n) && n >= 0 && n <= 100 && n !== BatteryStatus.soc) {
            BatteryStatus.soc = n;
            changed = true;
          }
        }
        const rawState: Object | undefined =
          params[batteryInfo.CommonEventBatteryChangedKey.EXTRA_CHARGE_STATE];
        if (rawState !== undefined) {
          const charging: boolean = BatteryStatus.isChargingState(Number(rawState));
          if (charging !== BatteryStatus.charging) {
            BatteryStatus.charging = charging;
            changed = true;
          }
        }
      }
      if (!BatteryStatus.loggedRaw && data.parameters !== undefined) {
        // 只打一次原始参数，方便真机核对真正的键名/取值（键名文档见文件头）
        BatteryStatus.loggedRaw = true;
        hilog.info(0x0000, TAG, 'BatteryStatus: first event params=%{public}s',
          JSON.stringify(data.parameters));
      }
    } catch (e) {
      // 解析失败 ⇒ 用常量兜底
      BatteryStatus.readConsts();
      changed = true;
    }
    if (changed && BatteryStatus.listener !== null) {
      BatteryStatus.listener(BatteryStatus.soc, BatteryStatus.charging);
    }
  }

  /** 读一次系统常量（首值兜底 / 解析失败兜底） */
  private static readConsts(): void {
    try {
      const soc: number = batteryInfo.batterySOC;
      if (typeof soc === 'number' && soc >= 0 && soc <= 100) {
        BatteryStatus.soc = soc;
      }
      BatteryStatus.charging = BatteryStatus.isChargingState(batteryInfo.chargingStatus as number);
    } catch (e) {
      // 读不到就保持原值（-1 = 不显示）
    }
  }

  /** `BatteryChargeState` → 是否在充电（ENABLE = 充电中，FULL = 已充满，都算"接着电"） */
  private static isChargingState(state: number): boolean {
    return state === batteryInfo.BatteryChargeState.ENABLE
      || state === batteryInfo.BatteryChargeState.FULL;
  }
}
