/**
 * 阅读器「按键翻页」调度（2026-10-07 新增，用户需求：音量键翻页 + 智控键滑动翻页，
 * 开关在 设置-按键翻页 组，默认关闭）。
 *
 * ── SDK 取证 ──────────────────────────────────────────────────────────────
 * · `inputConsumer.on('keyPressed', KeyPressedConfig, cb)`：`@ohos.multimodalInput.
 *   inputConsumer.d.ts:182`，@since 16。订阅成功后系统默认行为（音量调节）被拦截
 *   （同文件 :167-169 原文："the system's default response to the key event will be
 *   intercepted... To restore the system response, call off"）⇒ 必须只在阅读页存活且
 *   开关开启时订阅，退书即退订（官方指南 keypressed-guidelines："应用需要确保只有在
 *   确定响应时才激活该功能"；且仅前台焦点窗口生效）。
 * · `off(type, callback?)`（:197）**没有按键级参数** ⇒ 退订只能按 callback 整体退，
 *   故本类用单一共享回调 + 「全退再按需重订」的对账策略。
 * · `KeyPressedConfig{key, action, isRepeat}`（:76，@since 16；action=1 按下）。
 * · 键值（`@ohos.multimodalInput.keyCode.d.ts`）：KEYCODE_VOLUME_UP=16（:121）、
 *   KEYCODE_VOLUME_DOWN=17（:128）；KEYCODE_FINGERPRINT_SLIDE_UP=3233（:2540）、
 *   KEYCODE_FINGERPRINT_SLIDE_DOWN=3234（:2552，@since 26.0.0，原文："The keys are not
 *   universal device keys. Before using them, check whether the current device supports
 *   the reporting of related key events."）⇒ 智控键先用 `inputDevice.supportKeysSync`
 *   （`@ohos.multimodalInput.inputDevice.d.ts:511`）查询设备支持性。
 * · 翻页动作：ReaderKit 手动翻页 `readerComponentController.flipPage(isNext: boolean)`
 *   （`@hms.core.readerservice.readerComponent.d.ets:257`，@since 5.0.4(16)）。
 * · 键位映射（官方 keypressed-guidelines 示例场景原话："音量加键向上翻页、音量减键向下
 *   翻页、智控键上滑向上翻页、智控键下滑向下翻页"）：向上翻页 = 上一页 = flipPage(false)。
 */
import inputConsumer from '@ohos.multimodalInput.inputConsumer';
import inputDevice from '@ohos.multimodalInput.inputDevice';
import { KeyCode } from '@ohos.multimodalInput.keyCode';
import { KeyEvent } from '@ohos.multimodalInput.keyEvent';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { PreferencesUtil } from '@pura/harmony-utils';

/** 按键翻页开关的 Preferences / AppStorage 同名键（默认关） */
export const KEY_KEY_VOL_TURN: string = 'setKeyVolTurn';
export const KEY_KEY_FP_TURN: string = 'setKeyFpTurn';

export class ReaderKeyTurn {
  private static readonly TAG: string = 'testTag';

  /** 阅读页注册的翻页执行器（flipPage）；null = 阅读页不在 */
  private static flipHandler: ((isNext: boolean) => void) | null = null;
  /** 当前在订的键 → 对应回调（`on()` 文档要求"不同按键使用不同回调，否则订阅不生效"，
   *  `off()` 按 callback 退订 ⇒ 每键独立回调并用 Map 配对保存） */
  private static subscribed: Map<number, (event: KeyEvent) => void> = new Map();
  /** 智控键支持性缓存（null = 未查询；查询异步，完成后触发一次再对账） */
  private static fpSupported: boolean | null = null;

  static isVolOn(): boolean {
    try {
      return PreferencesUtil.getSync(KEY_KEY_VOL_TURN, false) === true;
    } catch (e) {
      return false;
    }
  }

  static isFpOn(): boolean {
    try {
      return PreferencesUtil.getSync(KEY_KEY_FP_TURN, false) === true;
    } catch (e) {
      return false;
    }
  }

  /**
   * 智控键支持性探测（**仅诊断**，2026-10-07 真机实证：某机型上按官方同款探测
   * （getDeviceList + supportKeysSync）返回"不支持"，但智控键实际可用——探测结果
   * 不可靠，故不再作为订阅闸门：开关开即订阅，不支持的机型订阅只是永不触发，无副作用。
   * 官方指南（keypressed-guidelines）要求"使用前判断设备是否支持"，此处以日志满足取证，
   * UI 侧不做隐藏。结果缓存，首次查询异步。
   */
  static queryFpSupported(): void {
    if (ReaderKeyTurn.fpSupported !== null) {
      return;
    }
    inputDevice.getDeviceList().then((list: Array<number>): void => {
      let sup = false;
      const detail: string[] = [];
      for (const id of list) {
        try {
          const r: Array<boolean> = inputDevice.supportKeysSync(id,
            [KeyCode.KEYCODE_FINGERPRINT_SLIDE_UP, KeyCode.KEYCODE_FINGERPRINT_SLIDE_DOWN]);
          detail.push(`${id}:[${r.join(',')}]`);
          if (r.length >= 2 && r[0] && r[1]) {
            sup = true;
          }
        } catch (e) {
          detail.push(`${id}:ERR`);
        }
      }
      ReaderKeyTurn.fpSupported = sup;
      hilog.info(0x0000, ReaderKeyTurn.TAG,
        'KeyTurn fpSupported=%{public}s devices=%{public}d support=%{public}s',
        String(sup), list.length, detail.join(' '));
      ReaderKeyTurn.refresh();
    }).catch((e: BusinessError): void => {
      hilog.warn(0x0000, ReaderKeyTurn.TAG, 'KeyTurn getDeviceList failed: %{public}d',
        e.code ?? 0);
      ReaderKeyTurn.fpSupported = false;
      ReaderKeyTurn.refresh();
    });
  }

  /** 阅读页进场注册（aboutToAppear）；重复注册以最后一次为准 */
  static attachReader(handler: (isNext: boolean) => void): void {
    ReaderKeyTurn.flipHandler = handler;
    ReaderKeyTurn.queryFpSupported();
    ReaderKeyTurn.refresh();
  }

  /** 阅读页退场注销（aboutToDisappear）：整体退订，系统音量行为恢复 */
  static detachReader(): void {
    ReaderKeyTurn.flipHandler = null;
    ReaderKeyTurn.refresh();
  }

  /** 开关变化 / 阅读页进出场后统一对账：目标键集与在订键集不一致 ⇒ 退掉多余、补订新键。
   *  ⚠️ 智控键不做支持性闸门（见 queryFpSupported 注释）：开关开即订阅。 */
  static refresh(): void {
    const active: boolean = ReaderKeyTurn.flipHandler !== null;
    const want: number[] = [];
    if (active) {
      if (ReaderKeyTurn.isVolOn()) {
        want.push(KeyCode.KEYCODE_VOLUME_UP, KeyCode.KEYCODE_VOLUME_DOWN);
      }
      if (ReaderKeyTurn.isFpOn()) {
        want.push(KeyCode.KEYCODE_FINGERPRINT_SLIDE_UP, KeyCode.KEYCODE_FINGERPRINT_SLIDE_DOWN);
      }
    }
    // ── 退掉不再需要的键 ─────────────────────────────────────────────────────
    const keys = Array.from(ReaderKeyTurn.subscribed.keys());
    for (const k of keys) {
      if (want.indexOf(k) === -1) {
        const cb = ReaderKeyTurn.subscribed.get(k) as (event: KeyEvent) => void;
        try {
          inputConsumer.off('keyPressed', cb);
        } catch (e) {
          // 退订失败不阻断重订
        }
        ReaderKeyTurn.subscribed.delete(k);
      }
    }
    // ── 补订新增的键（每键独立回调，官方要求）─────────────────────────────────
    for (const k of want) {
      if (ReaderKeyTurn.subscribed.has(k)) {
        continue;
      }
      const cb = (event: KeyEvent): void => {
        ReaderKeyTurn.dispatch(event);
      };
      try {
        const cfg: inputConsumer.KeyPressedConfig = {
          key: k,
          action: 1,     // 仅按下触发（@since 16；API 20 及以前仅支持 1）
          isRepeat: false
        };
        inputConsumer.on('keyPressed', cfg, cb);
        ReaderKeyTurn.subscribed.set(k, cb);
      } catch (e) {
        const err = e as BusinessError;
        hilog.error(0x0000, ReaderKeyTurn.TAG, 'KeyTurn on %{public}d failed: %{public}d %{public}s',
          k, err.code ?? 0, err.message ?? '');
      }
    }
    hilog.info(0x0000, ReaderKeyTurn.TAG, 'KeyTurn subscribed [%{public}s]',
      Array.from(ReaderKeyTurn.subscribed.keys()).join(','));
  }

  private static dispatch(event: KeyEvent): void {
    const flip = ReaderKeyTurn.flipHandler;
    if (flip === null) {
      return;
    }
    const code: KeyCode = event.key.code;
    if (code === KeyCode.KEYCODE_VOLUME_DOWN
      || code === KeyCode.KEYCODE_FINGERPRINT_SLIDE_DOWN) {
      flip(true);   // 音量减 / 智控键下滑 = 下一页
    } else if (code === KeyCode.KEYCODE_VOLUME_UP
      || code === KeyCode.KEYCODE_FINGERPRINT_SLIDE_UP) {
      flip(false);  // 音量加 / 智控键上滑 = 上一页
    }
  }
}
