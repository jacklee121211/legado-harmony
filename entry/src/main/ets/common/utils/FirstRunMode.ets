/**
 * 首次安装「全量 / 离线」模式选择（2026-10-13 新增，用户需求）。
 *
 * ── 需求（用户原文）───────────────────────────────────────────────────────────
 * 「首次安装的用户在第一次进入的时候，流程正常启动，但是进入软件后，整个屏幕会是
 *   呈现灰色的遮罩，屏幕中间有一个四圆角矩形弹窗（材质在我们的 docs 中有详细规范）
 *   居中对齐，上下有两个按钮，上面为全量模式，下面为离线模式，点击后会被红色边框框选，
 *   点击不生效，点击选择后，再次点击确定才生效，弹窗底部写好，后续可在设置页进行更改模式。
 *   默认框选全量模式，本选项与设置页的离线/全量模式开关天然同步。
 *   并且这个模块，天然支持一键开关（给我们，也就是开发者保留天然开关）」
 *
 * ── 本文件只负责「首启标记」这件事 ─────────────────────────────────────────
 * 模式值本身**不**在这里存 —— 唯一真源是 `OfflineMode.ets` 的 `offlineMode`
 * （同一个 Preferences 键）。这样「首次弹窗选的」与「设置页开关拨的」**天然是同一份数据**，
 * 不存在两个状态互相覆盖的问题（用户明确要求"天然同步"）。
 *
 * ── 为什么用 Preferences 而不是 AppStorage ─────────────────────────────────
 * 首启标记必须**跨启动存活**（否则每次冷启都弹）。
 * `PreferencesUtil.getSync/putSync` 是本工程既有的落盘通道
 * （同款用法见 `OfflineMode.ets:50,67`、`MySetPage.ets:125`）。
 *
 * ── 开发者一键开关（用户明确要求"给我们保留天然开关"）────────────────────────
 *   ① 编译期总闸：把下面 `ENABLED` 改成 `false` ⇒ 全工程**永不弹**首启引导
 *      （`shouldShow()` 恒返回 false），已装机的用户也不受影响。这是给开发者的主开关。
 *   ② 运行期单次重放：`debugReset()` 抹掉首启标记 ⇒ 下次冷启重新弹一次
 *      （调试用，可挂在任意暗门入口上）。
 *   ③ 调试期忽略标记：把 `IGNORE_FLAG_FOR_DEBUG` 改成 `true` ⇒ 忽略落盘标记、
 *      **每次冷启都弹**（纯调试用，**不要**提交为 true）。
 */
import { PreferencesUtil } from '@pura/harmony-utils';

/** Preferences 键：首启引导是否**已完成**（用户点过「确定」）。默认 false = 没弹过 */
export const KEY_FIRST_RUN_DONE: string = 'firstRunModeChosen';

export class FirstRunMode {
  /**
   * ★ 一键开关（开发者总闸）★
   * `false` ⇒ `shouldShow()` 恒 false，首启引导模块整体失效，行为与本改动前完全一致。
   *
   * ⚠️ 2026-10-13 用户拍板：**暂时屏蔽**首启「全量/精简」模式选择弹窗
   *    （原话「感觉意义不大，先屏蔽掉选择模式弹窗吧」）。
   *    ⇒ 置 `false`。弹窗代码、样式、回调全部保留，随时可翻回 `true` 恢复，
   *      无需改动 `Index.ets` / `FirstRunModeDialog.ets` 任何一行。
   *
   * 副作用说明（刻意接受）：
   *   · 新装机不再弹引导 ⇒ 直接进主界面，`offlineMode` 保持默认 `false`（全量模式）；
   *   · 精简模式仍可通过「我的 → 设置 → 功能 → 离线模式」手动开启
   *     （2026-10-19：原「其他」分组改名为「功能」，离线模式改放防截屏/录屏下面），
   *     方案 A 的边界调整（阅读增强类保留可见）在那里继续生效，不受本开关影响。
   */
  static readonly ENABLED: boolean = false;

  /**
   * 调试用：忽略落盘标记，每次冷启都弹一次。
   * ⚠️ 提交前必须保持 `false`。
   */
  static readonly IGNORE_FLAG_FOR_DEBUG: boolean = false;

  /** 首启引导是否已完成（读过 = 用户点过确定） */
  static isDone(): boolean {
    try {
      return PreferencesUtil.getSync(KEY_FIRST_RUN_DONE, false) === true;
    } catch (e) {
      // 读不到就当作"已完成"，绝不因为存储异常把引导又弹一次
      return true;
    }
  }

  /**
   * 本次启动是否应当弹出首启引导。
   * 三重判定：总闸开 → 非调试忽略模式则查落盘标记。
   */
  static shouldShow(): boolean {
    if (!FirstRunMode.ENABLED) {
      return false;
    }
    if (FirstRunMode.IGNORE_FLAG_FOR_DEBUG) {
      return true;
    }
    return !FirstRunMode.isDone();
  }

  /**
   * 标记首启引导**已完成**（用户点了「确定」时调用一次）。
   * 调用后本模块永久静默，直到用户重装或开发者调 `debugReset()`。
   */
  static markDone(): void {
    try {
      PreferencesUtil.putSync(KEY_FIRST_RUN_DONE, true);
    } catch (e) {
      // 落盘失败不影响本次会话：本次弹窗已经关掉了。
      // 代价是下次冷启会再弹一次（可接受，绝不因此崩溃）。
    }
  }

  /** 开发者用：抹掉首启标记 ⇒ 下次冷启重新弹一次（调试重放） */
  static debugReset(): void {
    try {
      PreferencesUtil.putSync(KEY_FIRST_RUN_DONE, false);
    } catch (e) {
      // 忽略：调试接口失败无副作用
    }
  }
}
