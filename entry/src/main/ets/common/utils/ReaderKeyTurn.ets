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
 *   KEYCODE_VOLUME_DOWN=17（:128）；
 *   **智控键族（官方代号 DAGGER）**：KEYCODE_DAGGER_CLICK=3211（:2495）、
 *   KEYCODE_DAGGER_DOUBLE_CLICK=3212（:2502）、KEYCODE_DAGGER_LONG_PRESS=3213（:2509）
 *   —— 三者 @since 18；KEYCODE_FINGERPRINT_SLIDE_UP=3233（:2540）、
 *   KEYCODE_FINGERPRINT_SLIDE_DOWN=3234（:2552，@since 26.0.0，原文："The keys are not
 *   universal device keys. Before using them, check whether the current device supports
 *   the reporting of related key events."）⇒ 智控键先用 `inputDevice.supportKeysSync`
 *   （`@ohos.multimodalInput.inputDevice.d.ts`）查询设备支持性。
 *   ⚠️《优先响应系统功能键开发指导》只把**上滑/下滑**列为第三方可优先响应的功能键，
 *   且示例里明写「若不支持智控键上滑及智控键下滑按键，则关闭用户入口」。
 *
 * ── 2026-10-08 真机终局判定（Mate 80 Pro Max / API 26，证据三条）────────────
 * ① 平台**声明不支持**：`inputDevice.supportKeysSync(id, [3233,3234])` 对全部 9 个输入设备
 *    一律返回 `[false,false]` —— 见日志 `KeyTurn fpProbe devices=9 support=false
 *    detail=0:[false,false] 1:[false,false] … 8:[false,false]`。
 * ② DAGGER 族（3211/3212/3213 单击/双击/长按）**平台不允许订阅**，直接 401：
 *    `C02800/...RegisterModule E [|1878]Invalid pressKey [key:3211]` +
 *    `KeyTurn on 3211 failed: 401 Input for KeyPressedConfig is invalid`（3212/3213 同）。
 *    ⇒ 与《优先响应系统功能键开发指导》只开放"上滑/下滑"完全一致。
 * ③ 订阅 3233/3234 虽被平台接受（`Fingerprint slide key subscribed:1, focusedPid:<app>`），
 *    但**一个回调都没有**；系统侧事件位移恒 0（`totalMoveY: 0 ignore.` /
 *    `invalid case event:{"action":1,"distanceX":0,"distanceY":0}`）。
 * ⇒ 结论：**本机智控键不对第三方开放**。按官方示例「若不支持智控键上滑及智控键下滑按键，
 *    则关闭用户入口」⇒ 本类改为**探测为真才订阅**（见 `smartKeyUsable()`），
 *    探测为假时不再白接管系统手势；音量键路径不受影响。
 * ⚠️ 如需在别的机型上复跑 DAGGER 实验：把 3211/3212/3213 加回 `SMART_KEYS`，
 *    并把 dispatch() 里的三分支一起加回（两者在 commit 历史里各有一份）。
 * · 翻页动作：ReaderKit 手动翻页 `readerComponentController.flipPage(isNext: boolean)`
 *   （`@hms.core.readerservice.readerComponent.d.ets:257`，@since 5.0.4(16)）。
 * · 键位映射（官方 keypressed-guidelines 示例场景原话："音量加键向上翻页、音量减键向下
 *   翻页、智控键上滑向上翻页、智控键下滑向下翻页"）：向上翻页 = 上一页 = flipPage(false)。
 */
import inputConsumer from '@ohos.multimodalInput.inputConsumer';
import inputDevice from '@ohos.multimodalInput.inputDevice';
import { KeyCode } from '@ohos.multimodalInput.keyCode';
import { KeyEvent, Action } from '@ohos.multimodalInput.keyEvent';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { PreferencesUtil } from '@pura/harmony-utils';

/** 按键翻页开关的 Preferences / AppStorage 同名键（默认关） */
export const KEY_KEY_VOL_TURN: string = 'setKeyVolTurn';
export const KEY_KEY_FP_TURN: string = 'setKeyFpTurn';

export class ReaderKeyTurn {
  private static readonly TAG: string = 'testTag';

  /**
   * 智控键订阅集：**只放平台允许订阅的键**（3211/3212/3213 会被 401 拒，见文件头证据②）。
   * ⚠️ 复跑 DAGGER 实验就在这里加回三行（同时恢复 dispatch 的三分支）。
   */
  private static readonly SMART_KEYS: number[] = [
    KeyCode.KEYCODE_FINGERPRINT_SLIDE_UP,  // 3233 上滑
    KeyCode.KEYCODE_FINGERPRINT_SLIDE_DOWN // 3234 下滑
  ];

  /**
   * 强制订阅闸门（默认 false）。
   * 为什么要有：`supportKeysSync` 存在"声明不支持、实际可用"的可能（本工程 2026-10-07
   * 记录过一次）；默认按官方示例「不支持则关闭用户入口」**不订阅**，若现场要验证可置 true。
   */
  private static readonly FORCE_SMART_KEY: boolean = false;

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

  /** 智控键是否可用：探测为真（或强制开关打开）。探测为 null(未完成)/false ⇒ 不订阅 */
  static smartKeyUsable(): boolean {
    return ReaderKeyTurn.FORCE_SMART_KEY || ReaderKeyTurn.fpSupported === true;
  }

  /** 本机是否**明确**不支持智控键（设置页据此置灰；FORCE_SMART_KEY 时永远返回 false） */
  static smartKeyUnsupported(): boolean {
    return !ReaderKeyTurn.FORCE_SMART_KEY && ReaderKeyTurn.fpSupported === false;
  }

  /** 设置页文案提示：'' = 未探测完成或可用（用默认文案） */
  static smartKeyHint(): string {
    if (ReaderKeyTurn.smartKeyUnsupported()) {
      return '本机不支持智控键键值上报，已自动不接管（音量键翻页不受影响）';
    }
    return '';
  }

  /**
   * 智控键支持性探测（2026-10-08 起**它就是订阅闸门**，见 `smartKeyUsable()`）。
   * 历史：2026-10-07 曾因"某机型探测说不支持、实际可用"而不把它当闸门；2026-10-08 在
   * Mate 80 Pro Max 上实测到**反面伤害** —— 探测 support=false 时订阅 3233/3234 会让系统
   * 把默认行为（指纹滑动下拉通知栏）让出、而应用又收不到事件，两头空（证据见文件头
   * "终局判定"）。故按官方示例「不支持则关闭用户入口」改回**闸门**；万一遇到误报机型，
   * 用 `FORCE_SMART_KEY = true` 强制订阅即可。
   *
   * ── 2026-10-08 重写：改用**回调版** getDeviceList（原 promise 版真机 never settled）──
   * 证据：16:05 那份日志里 `KeyTurn fpSupported=…` **一次都没出现**，
   *   `.then()` 与 `.catch()` 都没跑 ⇒ `inputDevice.getDeviceList(): Promise` 在本机不回调。
   * 官方示例（keypressed-guidelines 原文代码）用的就是回调版：
   *   `inputDevice.getDeviceList((error: BusinessError, ids: Array<Number>) => {…})`
   * 现在改成回调版，并补：① 调用前 START 日志；② 1.5s 看门狗（回调仍不来就如实记一条
   * TIMEOUT，避免再次"静默失败"）。签名依据：`inputDevice.d.ts:417`（callback，@since 9）。
   */
  static queryFpSupported(): void {
    if (ReaderKeyTurn.fpSupported !== null) {
      return;
    }
    hilog.info(0x0000, ReaderKeyTurn.TAG, 'KeyTurn fpProbe start');
    setTimeout((): void => {
      if (ReaderKeyTurn.fpSupported === null) {
        hilog.warn(0x0000, ReaderKeyTurn.TAG,
          'KeyTurn fpProbe TIMEOUT: getDeviceList callback never fired');
      }
    }, 1500);
    try {
      inputDevice.getDeviceList((err: BusinessError, list: Array<number>): void => {
        if (err) {
          hilog.warn(0x0000, ReaderKeyTurn.TAG, 'KeyTurn fpProbe getDeviceList failed: %{public}d',
            err.code ?? 0);
          ReaderKeyTurn.fpSupported = false;
          ReaderKeyTurn.refresh();
          return;
        }
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
          'KeyTurn fpProbe devices=%{public}d support=%{public}s detail=%{public}s',
          list.length, String(sup), detail.join(' '));
        ReaderKeyTurn.refresh();
      });
    } catch (e) {
      const err = e as BusinessError;
      hilog.warn(0x0000, ReaderKeyTurn.TAG, 'KeyTurn fpProbe threw: %{public}d', err.code ?? 0);
      ReaderKeyTurn.fpSupported = false;
      ReaderKeyTurn.refresh();
    }
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
      if (ReaderKeyTurn.isFpOn() && ReaderKeyTurn.smartKeyUsable()) {
        // 智控键：**探测为真才订阅**（2026-10-08 起，依据见文件头"终局判定"）
        for (const k of ReaderKeyTurn.SMART_KEYS) {
          want.push(k);
        }
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
        // action 语义（SDK `inputConsumer.d.ts:102-112` 原文）：**1 = 只订阅按下**；
        // **2 = 按下与抬起都订阅**（API 21 起支持 2；API ≤20 只能是 1）。
        // 智控键全族用 2（2026-10-08 实验）：该族是"非设备通用键值"，存在只上报抬起
        // 而不上报按下的可能；用 2 才能同时看到两种，日志里 `action=` 可直接判定。
        // 翻页仍只在 `Action.DOWN` 时执行（见 dispatch），所以不会一次动作翻两页。
        const cfg: inputConsumer.KeyPressedConfig = {
          key: k,
          action: ReaderKeyTurn.SMART_KEYS.indexOf(k) >= 0 ? 2 : 1,
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
    const code: KeyCode = event.key.code;
    // ── 诊断日志（2026-10-08 新增，真机排查必需）──────────────────────────────
    // 为什么必须有：`on('keyPressed')` 的回调**自身不产生任何日志**，翻页成败只有 ReaderKit
    // 侧那行 `ReaderKitView: flipPage success isNext xx`。2026-10-08 15:57 真机排查中
    // 「界面上像是没反应、日志里其实翻了一页又翻回来」⇒ 必须把
    // 「按了哪个键 → 我们翻了哪个方向」打出来，才能区分三种情况：
    //   ① 根本没订阅到；② 键值/方向映射反了；③ 一次滑动上报了两个键（净位移为 0）。
    // 依据：`KeyEvent{ action, key: { code, pressedTime, deviceId } }`
    //   （SDK `@ohos.multimodalInput.keyEvent.d.ts:99/:107/:73/:81/:89`）；
    //   键值 3233=智控键上滑 / 3234=下滑（`keyCode.d.ts:2540/:2552`）。
    if (flip === null) {
      hilog.warn(0x0000, ReaderKeyTurn.TAG,
        'KeyTurn key=%{public}d action=%{public}d dropped: reader inactive',
        code, event.action as number);
      return;
    }
    hilog.info(0x0000, ReaderKeyTurn.TAG,
      'KeyTurn raw key=%{public}d action=%{public}d dev=%{public}d',
      code, event.action as number, event.key.deviceId);
    // 只认"按下"（`Action.DOWN = 1`，`keyEvent.d.ts:47`）；抬起（UP = 2）只记录不翻页，
    // 避免智控键用 action=2 订阅后一次滑动触发两页。
    if (event.action !== Action.DOWN) {
      return;
    }
    if (code === KeyCode.KEYCODE_VOLUME_DOWN
      || code === KeyCode.KEYCODE_FINGERPRINT_SLIDE_DOWN) {
      hilog.info(0x0000, ReaderKeyTurn.TAG,
        'KeyTurn key=%{public}d dev=%{public}d -> next', code, event.key.deviceId);
      flip(true);   // 音量减 / 智控键下滑 = 下一页
    } else if (code === KeyCode.KEYCODE_VOLUME_UP
      || code === KeyCode.KEYCODE_FINGERPRINT_SLIDE_UP) {
      hilog.info(0x0000, ReaderKeyTurn.TAG,
        'KeyTurn key=%{public}d dev=%{public}d -> prev', code, event.key.deviceId);
      flip(false);  // 音量加 / 智控键上滑 = 上一页
    } else {
      hilog.warn(0x0000, ReaderKeyTurn.TAG, 'KeyTurn key=%{public}d unmapped', code);
    }
  }
}
