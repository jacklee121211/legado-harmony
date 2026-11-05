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
// 系统隐私声明（隐私政策）的签署状态 —— 公告门禁（2026-11-05 新增，见下方 privacyConsentReady）
import { privacyManager } from '@kit.AppGalleryKit';
import { BusinessError } from '@kit.BasicServicesKit';
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
   * ★ 系统隐私声明门禁开关（2026-11-05 新增）★
   *
   * `true`（当前默认，用户明确要求：「接系统的隐私声明确认状态做门禁，这个体验绝对是最好的」）
   *  ⇒ 用户还没同意系统隐私声明前**不弹**公告（否则会被那个系统确认框盖住，等于白弹一次）。
   * `false` ⇒ 退回旧行为（不查系统状态，按 900ms + 重试直接弹）。
   *
   * ⚠️ **本路径尚未真机验证**（实现完成后两台设备同时离线）。
   *    失败方向要说清：若在真机上这个接口在本机一直返回"未同意"，公告会**一直不弹**
   *    （每 3s 复查、60s 后放弃本次，下次冷启动再来）。遇到这种情况立刻把它改成 `false`。
   *    验证步骤见 `docs/待办-统一清单-2026-11-03.md` §101.13。
   */
  static readonly PRIVACY_GATE_ENABLED: boolean = true;

  /**
   * 系统「隐私声明 / 用户协议」是否**已经同意** —— 公告的**门禁**（2026-11-05 新增）。
   *
   * ── 为什么需要它（真机事故，完整证据见 `pages/Index.ets` 公告那节 + 施工记录 §101.12）
   * 新装首次启动时，**应用市场（AppGallery）会给用户弹一次系统隐私声明确认框**
   * （真机日志：`AG/AppGallery [NavigateDisposePrivacyDialog]:aboutToAppear com.jk.reader`）。
   * 它盖在应用之上：公告这时弹出来用户看不见，而一旦记账就永久丢失这个版本的一次机会。
   * ⇒ 正确做法不是"猜延时"，而是**问系统"用户同意了没有"**，没同意就先不弹。
   *
   * ── 官方接口（SDK 原文，`sdk/default/hms/ets/api/@hms.core.appgalleryservice.privacyManager.d.ts`）
   *   · `:325 function getAppPrivacyResult(): AppPrivacyResult[];`（@since 5.0.0(12)）
   *     原文「Queries the privacy agreement signing status.」
   *   · `:59-87 enum AppPrivacyResultType { DISAGREED = 0, FULL_MODE_AGREED = 1,
   *     REQUIRE_RESIGNING_VERSION_UPDATE = 2 }`（原文「The user has not agreed…」/
   *     「The user has agreed…」/「The agreement has changed and needs to be signed again.」）
   *   · `:124-143 enum AppPrivacyType { PRIVACY_AGREEMENT = 1, USER_AGREEMENT = 2 }`
   *   · 错误码 `1006700003 - The application does not use privacy manager service.`
   *   · 模块导出：`@kit.AppGalleryKit.d.ts:18` 的 export 列表里含 `privacyManager`
   *   · 能力：`SystemCapability.AppGalleryService.PrivacyManager`（`canIUse` 判定；
   *     `canIUse(syscap: string): boolean` 见 `openharmony/ets/api/@internal/full/global.d.ts:374`）
   *
   * ── 三条兜底（宁可放行，也不让公告被永久压死）
   *   ① 设备没有该 syscap ⇒ 不会有系统协议框 ⇒ 放行；
   *   ② 结果里没有 `PRIVACY_AGREEMENT` 这一项 ⇒ 本应用没声明协议 ⇒ 放行；
   *   ③ 接口抛错（含 1006700003 未接入隐私管理服务）⇒ 放行，只记日志。
   * 只有"明确查到了 PRIVACY_AGREEMENT 且不是 FULL_MODE_AGREED"才返回 false（= 等用户同意）。
   */
  static privacyConsentReady(): boolean {
    if (!Gonggao.PRIVACY_GATE_ENABLED) {
      return true;
    }
    try {
      if (!canIUse('SystemCapability.AppGalleryService.PrivacyManager')) {
        return true;
      }
      const results: privacyManager.AppPrivacyResult[] = privacyManager.getAppPrivacyResult();
      for (const one of results) {
        if (one.type === privacyManager.AppPrivacyType.PRIVACY_AGREEMENT) {
          const agreed: boolean = one.result === privacyManager.AppPrivacyResultType.FULL_MODE_AGREED;
          hilog.info(0x0000, TAG,
            `privacyConsentReady: result=${one.result} agreed=${agreed}`);
          return agreed;
        }
      }
      // ⚠️ 2026-11-05 真机纠正（实机日志原文，签署前/签署后对比）：
      //   签署前：`[PrivacyManager] QueryPrivacyResult success, **no rows**`（查不到任何行）
      //   签署后：`[PrivacyManager] set privacy result … [{"type":1,…,"result":1,…},{"type":2,…}]`
      // ⇒ **空数组不是"没声明协议"，而是"还没签"**（首次安装就是这个状态）。
      //   原来这里 `return true`（放行）导致公告在系统协议窗下面弹出来、然后被销毁 —— 白弹一次。
      //   "应用没用这套托管服务"的情况由下面的 catch（错误码 1006700003）兜，不靠空数组判。
      hilog.info(0x0000, TAG, 'privacyConsentReady: no rows -> treat as NOT signed yet');
      return false;
    } catch (e) {
      const err = e as BusinessError;
      // 1006700003 = 应用未接入隐私管理服务（= 不存在系统协议框）⇒ 放行
      hilog.warn(0x0000, TAG, `privacyConsentReady failed: code=${err.code}, treat as ready`);
      return true;
    }
  }

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
