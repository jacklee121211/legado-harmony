/**
 * PuraX 外屏「极简阅读」形态判定（2026-10-24 新增）。
 *
 * ── 需求（用户原话要点）──────────────────────────────────────────────────
 *   「我想适配 puraX 外屏展示…我需要的是一种在外屏阅读的适配，不需要有全量的功能，
 *     比如书架，而是可以快速进入阅读器，在外屏的正方形屏幕上阅读…
 *     最好是 purax 外屏走单独的隔离的方案，能够一键开关，
 *     确保不造成毁灭性的灾难，对于商业软件来说，这才是重中之重。」
 *
 * ── 本文件的唯一职责：把「现在是不是外屏」算成一个布尔 ────────────────────
 * 业务侧（Index / ReaderPage3）**一律只订阅** `AppStorage('outerMinimal')`，
 * 不要在别处再写第二套形态判断 —— 工程已有教训（`docs/AGENTS.md` 第 7 节：
 * 「曾经出现过两套并存且不等价的判断，正是这类'按形态打补丁'造成了排查混乱」）。
 *
 * ── 判定依据（全部可取证，不猜）───────────────────────────────────────────
 * ① SDK `@ohos.display.d.ts:200-209` `isFoldable()` 原文：
 *    「For small-screen foldable devices where the outer screen serves only as an
 *      auxiliary display (**and cannot be customized by applications**), the return
 *      value is always **false**. For other foldable devices, the return value is
 *      always **true**.」
 *    ⇒ PuraX 属「阔折叠」，返回 true，外屏**可被应用定制**。
 * ② SDK `@ohos.display.d.ts:801-812` `FoldDisplayMode` 原文：
 *    「For foldable devices where **both the inner and outer screens can serve as the
 *      primary screen** — like large or **wide-folding models** — the inner screen's
 *      display mode is **FOLD_DISPLAY_MODE_FULL**, and the outer screen's display mode
 *      is **FOLD_DISPLAY_MODE_MAIN**.」
 * ③ PuraX 屏幕规格（官方 `最佳实践/手机/阔折叠_阔直板应用开发/bpta-purax-guide`
 *    的「屏幕规格信息」表）：
 *      折叠态（**外屏**）：1:1    326×326 vp / 980×980 px，断点 sm*md
 *      展开态（内屏）    ：16:10  440×707 vp / 1320×2120 px，断点 sm*lg
 *
 * ── 为什么**不能**只看 `FoldDisplayMode.MAIN` ──────────────────────────────
 *   依据 ② 原文：Mate X 系列「双折叠」的**内屏**也是 `FOLD_DISPLAY_MODE_MAIN`
 *   ⇒ 只看它会把「Mate X 的内屏」误判成「PuraX 的外屏」。
 *   所以本文件用**几何比例**做主判据（PuraX 外屏恰好 1:1），折叠态做辅判据。
 *
 * ── 为什么**不**增设设置页开关（用户 2026-10-24 拍板）────────────────────
 *   用户原话：「我建议不增设开关，直接就是开着」。
 *   ⇒ 无 Preferences、无设置行；回退只靠本文件的 `ENABLED` 编译期总闸。
 *
 * ── 一键回退 ──────────────────────────────────────────────────────────────
 *   把 `OuterScreen.ENABLED` 改成 `false` ⇒ `compute()` 恒返回 false
 *   ⇒ `outerMinimal` 恒 false ⇒ 全应用回到改动前行为。
 *   回退后必须验证：① 手机冷启动进书架；② 阅读器 5 格 dock / 顶栏 / 进度条齐全；
 *                  ③ 平板 2in1 布局不变。
 */
import { display } from '@kit.ArkUI';
import { window } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG: string = 'OuterScreen';

/** AppStorage 键：当前是否处于「外屏极简」形态（各页 @StorageProp / @StorageLink 订阅此键） */
export const KEY_OUTER_MINIMAL: string = 'outerMinimal';

/**
 * AppStorage 键：**调试强制位**（默认不设 = 走真实检测）。
 *
 * 为什么需要：外屏形态只出现在真 PuraX 折叠态，而模拟器的折叠/展开只能在窗口里手点、
 * 脚本驱动不了（`devecocli ui` 没有折叠命令）。没有这个位，就无法在现有手机上验证
 * 精简版 UI 与"内屏零回归"。
 *
 * 用法（零 UI 侵入，不留任何界面痕迹）：
 *   hdc shell aa start -a EntryAbility -b com.jk.reader --ps outerMinimalDebug true
 * 取消：杀进程重开即可（AppStorage 是内存态，不落盘）。
 */
export const KEY_DEBUG_FORCE: string = 'outerMinimalDebug';

/**
 * 几何闸门（单位 vp）。
 *
 * 高宽比 `w/h` 的取值来源：
 *   · PuraX 折叠态（目标）    ：326/326 = **1.00**
 *   · PuraX 展开态（内屏）    ：440/707 = 0.62  ⇒ 被下限 0.85 排除
 *   · PuraX Max 折叠态        ：459/672 = 0.68  ⇒ 被下限排除（用户只要 PuraX 那个正方形屏）
 *   · PuraX Max 展开态        ：939/664 = 1.41  ⇒ 被上限排除
 *   · 普通直板手机            ：≈ 0.47          ⇒ 被下限排除
 * ⇒ [0.85, 1.18] 这个窗口既容得下 PuraX 的 1:1，也不会误伤上面任何一档。
 */
const MIN_ASPECT: number = 0.85;
const MAX_ASPECT: number = 1.18;

/**
 * 短边上限（vp）：326vp（PuraX 外屏）+ 余量。
 * 作用：兜住 2in1 上用户把窗口拖成正方形（例如 600×600）的误判场景。
 */
const MAX_MIN_SIDE_VP: number = 480;

export class OuterScreen {
  /**
   * **总开关（一键回退点）**。`false` ⇒ 判定恒为 false，全应用回到改动前行为。
   * 见文件头「一键回退」。
   */
  static readonly ENABLED: boolean = true;

  /** 主窗口引用（`refresh()` 用它读实时几何；为空时回落到 AppStorage 的 windowWidth/Height） */
  private static win: window.Window | null = null;

  /** `foldStatusChange` 是否已注册（只允许注册一次） */
  private static foldBound: boolean = false;

  /**
   * 启动时调用一次（`EntryAbility.onWindowStageCreate` 的 `getMainWindow` 回调里）。
   *
   * @param win 主窗口。用于读实时 `windowRect`（px）—— 比 AppStorage 更及时，
   *            且不受 `WindowAbility` 150ms 防抖影响。
   */
  static init(win: window.Window): void {
    OuterScreen.win = win;
    OuterScreen.refresh();
    OuterScreen.bindFoldStatus();
  }

  /**
   * 重算并写入 `AppStorage('outerMinimal')`（幂等；值没变时不写，避免无谓重渲染）。
   *
   * 调用点：
   *   ① `init()` 启动算一次；
   *   ② `EntryAbility` 已注册的 `windowClass.on('windowSizeChange')` 里（折叠/展开/旋转/2in1 拖拽）；
   *   ③ `display.on('foldStatusChange')` 里（含两次延迟补算，见 `bindFoldStatus`）。
   */
  static refresh(): void {
    let on: boolean = false;
    try {
      on = OuterScreen.compute();
    } catch (e) {
      // 任何异常都按"不是外屏"处理 —— 绝不能因为判定失败影响正常启动/阅读。
      hilog.warn(0x0000, TAG, 'compute failed: %{public}s',
        e instanceof Error ? e.message : String(e));
      on = false;
    }
    const prev: boolean = AppStorage.get<boolean>(KEY_OUTER_MINIMAL) ?? false;
    if (prev === on) {
      return;
    }
    AppStorage.setOrCreate<boolean>(KEY_OUTER_MINIMAL, on);
    hilog.info(0x0000, TAG, 'outerMinimal %{public}s -> %{public}s',
      prev ? 'true' : 'false', on ? 'true' : 'false');
  }

  /**
   * 渲染侧便捷读取（**写 UI 常量/分支判断**用）。
   * ⚠️ 组件内请用 `@StorageProp(KEY_OUTER_MINIMAL)` 订阅，才能随折叠实时刷新；
   *    直接调本方法只在"调用那一刻"有效。
   */
  static isOn(): boolean {
    return (AppStorage.get<boolean>(KEY_OUTER_MINIMAL) ?? false) === true;
  }

  /**
   * 设置调试强制位（`EntryAbility` 解析 want 参数后调用）。
   * @param on true = 强制进入外屏态；false = 清除强制，回到真实检测
   */
  static setDebugForce(on: boolean): void {
    AppStorage.setOrCreate<boolean>(KEY_DEBUG_FORCE, on);
    hilog.info(0x0000, TAG, 'debug force = %{public}s', on ? 'true' : 'false');
    OuterScreen.refresh();
  }

  /**
   * 订阅折叠状态变化。
   *
   * ⚠️ 为什么要「立刻 + 两次延迟」：
   *   SDK `@ohos.display.d.ts` 对 `foldStatusChange` 的说明原文是
   *   「In terms of timing, the fold status changes first, and the bottom layer matches
   *     the display mode status based on the fold status.」
   *   ⇒ 事件到达时**窗口尺寸可能还没切换完**（那时算出来的还是旧几何）。
   *   所以立刻算一次（覆盖"尺寸已就绪"的情况），再在 120ms / 400ms 各补一次
   *   （覆盖"尺寸晚到"的情况）。`refresh()` 幂等，多算几次无副作用。
   *
   * ⚠️ 已知限制：官方 FAQ `faqs-arkui-1589` 明确「云调试环境下，
   *   `display.on('foldStatusChange')` 无法监听折叠屏屏幕状态的变化」
   *   ⇒ 真机才有这个事件。因此 `windowSizeChange` 才是**主信号**（见 `EntryAbility`），
   *     本事件只作辅助。
   */
  private static bindFoldStatus(): void {
    if (OuterScreen.foldBound) {
      return;
    }
    OuterScreen.foldBound = true;
    try {
      display.on('foldStatusChange', (status: display.FoldStatus) => {
        hilog.info(0x0000, TAG, 'foldStatusChange = %{public}d', status);
        OuterScreen.refresh();
        setTimeout((): void => {
          OuterScreen.refresh();
        }, 120);
        setTimeout((): void => {
          OuterScreen.refresh();
        }, 400);
      });
    } catch (e) {
      // 注册失败不影响主信号（windowSizeChange）
      hilog.warn(0x0000, TAG, 'bind foldStatusChange failed: %{public}s',
        e instanceof Error ? e.message : String(e));
    }
  }

  /**
   * 核心判定。
   *
   * 顺序：编译期总闸 → 调试强制位 → 可折叠 → 折叠态 → 几何比例 → 短边上限。
   */
  private static compute(): boolean {
    if (!OuterScreen.ENABLED) {
      return false;
    }
    // 调试强制位优先（验收用；默认未设置）
    if ((AppStorage.get<boolean>(KEY_DEBUG_FORCE) ?? false) === true) {
      return true;
    }
    // ① 必须是可折叠设备（PuraX 返回 true；小折叠等"外屏不可定制"的机型返回 false）
    let foldable: boolean = false;
    try {
      foldable = display.isFoldable();
    } catch (e) {
      return false;
    }
    if (!foldable) {
      return false;
    }
    // ② 必须处于折叠态（PuraX 折叠 = FOLD_STATUS_FOLDED = 2）
    try {
      if (display.getFoldStatus() !== display.FoldStatus.FOLD_STATUS_FOLDED) {
        return false;
      }
    } catch (e) {
      return false;
    }
    // ③ 几何：读实时窗口尺寸（px）→ 换算 vp → 判比例与短边
    let wPx: number = 0;
    let hPx: number = 0;
    const win: window.Window | null = OuterScreen.win;
    if (win !== null) {
      try {
        const rect: window.Rect = win.getWindowProperties().windowRect;
        wPx = rect.width;
        hPx = rect.height;
      } catch (e) {
        wPx = 0;
        hPx = 0;
      }
    }
    if (wPx <= 0 || hPx <= 0) {
      // 回落：`WindowAbility` 写入的 px 值（见 `WindowAbility.initWindowSize`）
      wPx = AppStorage.get<number>('windowWidth') ?? 0;
      hPx = AppStorage.get<number>('windowHeight') ?? 0;
    }
    if (wPx <= 0 || hPx <= 0) {
      return false;
    }
    let wVp: number = 0;
    let hVp: number = 0;
    try {
      if (win !== null) {
        const ctx: UIContext = win.getUIContext();
        wVp = ctx.px2vp(wPx);
        hVp = ctx.px2vp(hPx);
      } else {
        wVp = px2vp(wPx);
        hVp = px2vp(hPx);
      }
    } catch (e) {
      // 与 `EntryAbility.updateBreakpoint` 同款兜底：取不到 UIContext 就退回全局换算
      wVp = px2vp(wPx);
      hVp = px2vp(hPx);
    }
    if (wVp <= 0 || hVp <= 0) {
      return false;
    }
    const aspect: number = wVp / hVp;
    if (aspect < MIN_ASPECT || aspect > MAX_ASPECT) {
      return false;
    }
    const minSide: number = wVp < hVp ? wVp : hVp;
    if (minSide > MAX_MIN_SIDE_VP) {
      return false;
    }
    return true;
  }
}

export default OuterScreen;
