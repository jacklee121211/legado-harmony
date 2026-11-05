/**
 * ══════════════════════════════════════════════════════════════════════════════
 * 「公告」模块 · 什么时候弹 + 一键开关
 * ══════════════════════════════════════════════════════════════════════════════
 *
 * 需求（用户原话归纳）：
 *   ①「用户在新下载软件，或者更新版本后出现，且在版本号未变化时不再重复出现第二次」
 *     ⇒ 判定 = **上次展示过的版本号 ≠ 当前版本号**；相等 ⇒ 不弹。
 *   ②「这个模块可以一键开关，这样部分版本不需要开启模块，就关掉，不会影响用户」
 *     ⇒ 下面 `ENABLED` 一个常量，`false` 即整体失效。
 *
 * ── 三条判定（`shouldShow()`，顺序即优先级）──────────────────────────────────
 *   ① `ENABLED === false` ⇒ 永不弹（开发者总闸；已装机的用户也不受影响）；
 *   ② 内容数组为空（`GONGGAO_ITEMS.length === 0`）⇒ 永不弹（等于"本版不发公告"）；
 *   ③ 取不到当前版本号 ⇒ 永不弹（宁可漏弹，也不能因为读不到版本号就每次冷启都弹）；
 *   ④ 本地没有"已展示版本"记录 ⇒ 弹（= 新装第一次进入）；
 *   ⑤ 记录 ≠ 当前版本号 ⇒ 弹（= 升级后的第一次进入）；
 *   ⑥ 记录 === 当前版本号 ⇒ 不弹（= 同一个版本内只弹一次）。
 *
 * ── 落盘通道与取证（与工程既有模块同一套，不另造）────────────────────────────
 *   · `PreferencesUtil.getSync / putSync / hasSync / deleteSync`
 *     —— `oh_modules/@pura/harmony-utils/src/main/ets/utils/PreferencesUtil.ets`
 *        `:105 static getSync(key, defValue, preferenceName = defaultPreferenceName)`
 *        `:79  static putSync(key, value, ...)`（内部 `flush()`，:83 ⇒ 立即落盘）
 *        `:195 static hasSync(key, ...)`、`:216 static deleteSync(key, ...)`
 *     与 `FirstRunMode.ets:62,89` / `ReadPromo.ets` / `VipManager.ets` 同一通道。
 *   · 版本号 `bundleManager.getBundleInfoForSelfSync(...).versionName`
 *     —— SDK `sdk/default/openharmony/ets/api/bundleManager/BundleInfo.d.ts:67-75`
 *        `readonly versionName: string;`（@since 9，原文「Version description of the
 *        application package. It corresponds to the **versionName** field in app.json5」）
 *     取值标志 `BundleFlag.GET_BUNDLE_INFO_DEFAULT`；同款用法见 `AboutPage.ets:64-72`、
 *     `KeyVolDefaultMigration.ets:124-145`。**读取自身信息不需要权限**。
 *
 * ── 为什么用 versionName 而不是 versionCode 作判据 ──────────────────────────
 *   用户的原话是「版本号未变化时不再重复出现」。版本号就是用户能在「关于我们」看到的
 *   `versionName`（`AboutPage` 显示的也是它）；两者在 `.githooks` 里由同一笔提交同步
 *   ⇒ 语义上等价，选**用户能看见的那个**，出问题时能对着版本日志直接核对。
 *
 * ── 一键回退 / 调试 ─────────────────────────────────────────────────────────
 *   · 关模块：`ENABLED = false` ⇒ 永不弹（不动 `Index.ets`、不动界面文件）；
 *   · 本版不发公告：把 `GonggaoData.ets` 的 `GONGGAO_ITEMS` 改成 `[]`；
 *   · 想看弹窗：临时 `IGNORE_FLAG_FOR_DEBUG = true`（每次冷启都弹，**提交前必须改回 false**），
 *     或调一次 `Gonggao.debugReset()`（抹掉"已展示版本"记录 ⇒ 下次冷启重新弹）。
 */
import { bundleManager } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { PreferencesUtil } from '@pura/harmony-utils';
import { GONGGAO_ITEMS } from './GonggaoData';

const TAG: string = 'Gonggao';

/**
 * Preferences 键：上一次**已经展示过公告**的版本号。
 * 不存在 = 本机从未展示（新装）；存在且等于当前版本号 = 本版已弹过。
 */
const KEY_SEEN_VERSION: string = 'gonggaoSeenVersion';

export class Gonggao {
  /**
   * ★ 一键开关（开发者总闸）★
   * `false` ⇒ `shouldShow()` 恒 false ⇒ 公告模块整体失效：
   *   不读版本号、不读盘、不弹窗，行为与本改动前**完全一致**，已装机用户也不受影响。
   */
  static readonly ENABLED: boolean = true;

  /**
   * 调试用：忽略"已展示"记录，**每次冷启动都弹一次**。
   * ⚠️ 提交前必须保持 `false`（与 `FirstRunMode.IGNORE_FLAG_FOR_DEBUG` 同款约定）。
   */
  static readonly IGNORE_FLAG_FOR_DEBUG: boolean = false;

  /**
   * 当前安装包的版本号（`AppScope/app.json5` 的 `versionName`，如 `3.0.13`）。
   * 读取失败返回空串 —— 调用方据此**不弹**（见 `shouldShow()` 第 ③ 条）。
   */
  static currentVersion(): string {
    try {
      const info: bundleManager.BundleInfo = bundleManager.getBundleInfoForSelfSync(
        bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT);
      const name: string = info.versionName;
      return (typeof name === 'string') ? name : '';
    } catch (e) {
      hilog.warn(0x0000, TAG, 'currentVersion failed: %{public}s', String(e));
      return '';
    }
  }

  /**
   * 本次进入软件是否应当弹公告。判定表见文件头（四条闸门 + 三态）。
   * 纯查询、无副作用：调用多少次都不会改盘。
   */
  static shouldShow(): boolean {
    if (!Gonggao.ENABLED) {
      return false;
    }
    // 没内容就别弹（等于"本版不发公告"，也是一种不必发版的关停方式）
    if (GONGGAO_ITEMS.length === 0) {
      return false;
    }
    const current: string = Gonggao.currentVersion();
    if (current.length === 0) {
      // 取不到版本号：宁可漏弹一次，也不能每次冷启都弹（那会变成骚扰）
      hilog.warn(0x0000, TAG, 'shouldShow: versionName unavailable -> skip');
      return false;
    }
    if (Gonggao.IGNORE_FLAG_FOR_DEBUG) {
      return true;
    }
    try {
      if (PreferencesUtil.hasSync(KEY_SEEN_VERSION) !== true) {
        hilog.info(0x0000, TAG, 'shouldShow: fresh install, current=%{public}s', current);
        return true;
      }
      const seen: string = PreferencesUtil.getSync(KEY_SEEN_VERSION, '') as string;
      const changed: boolean = seen !== current;
      hilog.info(0x0000, TAG,
        'shouldShow: seen=%{public}s current=%{public}s changed=%{public}s',
        seen, current, String(changed));
      return changed;
    } catch (e) {
      // 读盘异常 ⇒ 不弹（失败方向选"不打扰用户"，与 FirstRunMode 的取舍一致）
      hilog.warn(0x0000, TAG, 'shouldShow: read flag failed: %{public}s', String(e));
      return false;
    }
  }

  /**
   * 标记「当前版本号已经展示过公告」。
   *
   * ⚠️ 2026-11-05 真机事故后定的口径：**只能在"用户把它关掉"时调用**
   *   （「我知道了」→ `Index.closeGonggaoDialog()`；点遮罩 / 返回键 → options 的 `cancel`），
   *   **不能**在 `open()` 之后立刻调。
   *   原因：首装首次启动时「应用市场的系统隐私协议弹窗」会盖在应用之上（真机证据见
   *   `pages/Index.ets` 里「公告」那节的注释），公告会开在它下面、用户根本看不到；
   *   若此时就记账，这个版本号的公告**永久丢失**（用户实测「重装后没见公告」正是这个）。
   *   ⇒ "开出来" ≠ "用户看到了"，记账要绑在**用户动作**上。
   * 幂等：重复调用只是把同一个版本号再写一遍。
   */
  static markShown(): void {
    const current: string = Gonggao.currentVersion();
    if (current.length === 0) {
      hilog.warn(0x0000, TAG, 'markShown: versionName unavailable, skip writing flag');
      return;
    }
    try {
      PreferencesUtil.putSync(KEY_SEEN_VERSION, current);
      hilog.info(0x0000, TAG, 'markShown: version=%{public}s', current);
    } catch (e) {
      // 写盘失败 ⇒ 下次冷启会再弹一次（可接受，绝不因此崩溃）
      hilog.warn(0x0000, TAG, 'markShown failed: %{public}s', String(e));
    }
  }

  /**
   * 开发者用：抹掉"已展示版本"记录 ⇒ 下次冷启重新弹一次（调试重放）。
   * **不新增任何设置页入口**（用户未要求；需要时自行在临时改动的调用点调一次）。
   */
  static debugReset(): void {
    try {
      PreferencesUtil.deleteSync(KEY_SEEN_VERSION);
      hilog.info(0x0000, TAG, 'debugReset done, gonggaoSeenVersion removed');
    } catch (e) {
      hilog.warn(0x0000, TAG, 'debugReset failed: %{public}s', String(e));
    }
  }
}

export default Gonggao;
