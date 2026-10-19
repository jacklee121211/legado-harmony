/**
 * 「音量键翻页」默认值的一次性迁移（2026-10-19）。
 *
 * ── 背景（用户原话）────────────────────────────────────────────────────────
 * 「想让存量用户保持关，老用户这个需要尊重老用户的选择，因为不能每次版本更新，
 *  都让老用户的配置被覆盖。」
 * 即：`setKeyVolTurn` 的默认值由「关」改成「开」**只应作用于新装用户**；
 *     老用户（升级上来的）必须保持他们原来看到/体验到的「关」。
 *
 * ── 为什么不能靠"读不到就用默认值"──────────────────────────────────────────
 * `PreferencesUtil.getSync(key, defValue)` 在**键从未写入过**时返回 defValue。
 * 而绝大多数老用户从没点过这个开关（它以前默认关），本地**没有**这个键
 * ⇒ 直接改默认值会让他们一起变成"开"，正是用户要避免的"配置被覆盖"。
 * 反过来也不能一律写死 false —— 新装用户要的是"开"。
 *
 * ── 判定与处理（每个安装**只跑一次**）───────────────────────────────────────
 *   ① 标记 `keyVolDefaultMigratedV1` 已存在 ⇒ 直接返回（**以后每次版本更新都不再执行**）；
 *   ② `setKeyVolTurn` 键**已存在** ⇒ 用户自己动过这个开关 ⇒ 一律不动（尊重用户选择，
 *      包括"用户后来手动打开成开"的情形也要保住）；
 *   ③ 判定为**升级安装** ⇒ 写入 `false`（= 维持老版本的默认行为）；
 *   ④ 判定为**新装** ⇒ 不写，让 `ReaderKeyTurn.isVolOn()` 的默认 `true` 生效；
 *   ⑤ 最后写标记。失败则不写标记（下次启动重试），且绝不抛异常影响启动。
 *
 * ── 判定「升级安装」的口径与证据 ────────────────────────────────────────────
 * 用系统给的**首次安装时间**与**最后一次更新（本次安装）时间**对比：
 * 升级安装 ⇒ firstInstallTime 明显早于 updateTime；新装 ⇒ 两者是同一瞬间。
 * · `bundleManager.getBundleInfoForSelfSync(bundleFlags: number): BundleInfo`
 *   —— `sdk/default/openharmony/ets/api/@ohos.bundle.bundleManager.d.ts:1041`，@since 10，
 *   获取自身信息**不需要权限**（同文件 :1046 原文「No permission is required for obtaining
 *   the caller's own information.」），参数错误抛 401。
 * · `BundleInfo.firstInstallTime?: number`
 *   —— `sdk/.../ets/api/bundleManager/BundleInfo.d.ts:209`，@since 18，原文
 *   「Timestamp for the initial installation of the application package. It measures the
 *    milliseconds that have passed since the Unix epoch」。
 * · `BundleInfo.updateTime: number` —— 同文件 :181，@since 9，原文
 *   「Timestamp for the **last update** of the application package … in milliseconds」。
 * · 取值标志 `bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT = 0x00000000`
 *   —— `@ohos.bundle.bundleManager.d.ts:60`（@since 9）。这三个字段的注释里**都没有**
 *   "需传某个 GET_BUNDLE_INFO_WITH_… 标志"的要求（对比 `signatureInfo` :147-149 明确要
 *   GET_BUNDLE_INFO_WITH_SIGNATURE_INFO）⇒ 默认标志即可取到。
 * · `PreferencesUtil.hasSync(key)` —— `oh_modules/@pura/harmony-utils/src/main/ets/utils/
 *   PreferencesUtil.ets:195`（转发 `preferences.hasSync`，即"是否包含该键"）；
 *   `putSync` 同文件 :79-84，内部 `flush()` ⇒ 立即落盘。
 *
 * ⚠️ 取不到 `firstInstallTime`（可选字段/读取异常）时按**老用户**处理（写 false）——
 *    用户在需求里最不能接受的就是"老配置被覆盖"，两害相权取这一边。
 *
 * ── 一键回退 ───────────────────────────────────────────────────────────────
 * 把 `ENABLED` 改成 `false` ⇒ 完全不迁移（新默认值对所有人生效，含老用户）。
 * 已经迁移过的机器：删掉 Preferences 键 `keyVolDefaultMigratedV1` 与
 * `setKeyVolTurn` 后重启即回到"新装"状态（开发者调试用）。
 */
import { bundleManager } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { PreferencesUtil } from '@pura/harmony-utils';
import { KEY_KEY_VOL_TURN } from './ReaderKeyTurn';

/** 一次性迁移标记：true = 本机已执行过本迁移（**唯一**阻止重复执行的闸门） */
export const KEY_MIGRATED_V1: string = 'keyVolDefaultMigratedV1';

/** 升级判定的时间容差：同一瞬间的新装，两个时间戳可能差几毫秒 ⇒ 给足 60s */
const UPGRADE_TOLERANCE_MS: number = 60 * 1000;

const TAG: string = 'testTag';

export class KeyVolDefaultMigration {
  /** 一键回退开关（`false` = 不迁移，新默认对所有人生效） */
  static readonly ENABLED: boolean = true;

  /**
   * 启动时调用一次（`EntryAbility.onWindowStageCreate` 里，早于首屏渲染）。
   * 幂等：已迁移过的机器直接返回，**不会**因为版本更新再覆盖用户配置。
   */
  static runOnce(): void {
    if (!KeyVolDefaultMigration.ENABLED) {
      return;
    }
    try {
      // ① 标记已在 ⇒ 本机迁移过，永久跳过（这条保证"每次版本更新不重复覆盖配置"）
      if (PreferencesUtil.hasSync(KEY_MIGRATED_V1) === true) {
        return;
      }
      // ② 用户自己动过开关 ⇒ 尊重用户选择，原值不动
      if (PreferencesUtil.hasSync(KEY_KEY_VOL_TURN) === true) {
        const cur: boolean = PreferencesUtil.getSync(KEY_KEY_VOL_TURN, true) === true;
        hilog.info(0x0000, TAG,
          'keyVolMigrate: user value exists=%{public}s, keep as is', String(cur));
        PreferencesUtil.putSync(KEY_MIGRATED_V1, true);
        return;
      }
      // ③④⑤ 判定老/新用户
      const upgrade: boolean = KeyVolDefaultMigration.isUpgradeInstall();
      if (upgrade) {
        // 老用户：显式写入 false，等价于"维持老版本的默认关"。
        // 同步 AppStorage（键名与 Preferences 键同名），避免首帧按新默认 true 渲染一下。
        PreferencesUtil.putSync(KEY_KEY_VOL_TURN, false);
        AppStorage.setOrCreate(KEY_KEY_VOL_TURN, false);
        hilog.info(0x0000, TAG,
          'keyVolMigrate: upgrade install -> setKeyVolTurn=false (old default kept)');
      } else {
        hilog.info(0x0000, TAG, 'keyVolMigrate: fresh install -> keep new default (on)');
      }
      PreferencesUtil.putSync(KEY_MIGRATED_V1, true);
    } catch (e) {
      // 迁移失败**不写标记** ⇒ 下次启动重试；任何情况下都不阻断启动
      hilog.warn(0x0000, TAG, 'keyVolMigrate failed, will retry next launch');
    }
  }

  /**
   * 本次安装是否是「从旧版本升级上来」（= 老用户）。
   * @returns true = 老用户（升级/读不到信息，保守按老用户处理）；false = 新装
   */
  private static isUpgradeInstall(): boolean {
    try {
      const info: bundleManager.BundleInfo =
        bundleManager.getBundleInfoForSelfSync(bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT);
      const first: number | undefined = info.firstInstallTime;
      const updated: number = info.updateTime;
      if (first === undefined || first <= 0) {
        // 取不到首次安装时间（可选字段）⇒ 保守判为老用户
        hilog.warn(0x0000, TAG, 'keyVolMigrate: firstInstallTime unavailable -> treat as upgrade');
        return true;
      }
      const delta: number = updated - first;
      hilog.info(0x0000, TAG,
        'keyVolMigrate: firstInstallTime=%{public}s updateTime=%{public}s delta=%{public}s',
        String(first), String(updated), String(delta));
      return delta > UPGRADE_TOLERANCE_MS;
    } catch (e) {
      // 读取失败 ⇒ 保守判为老用户
      hilog.warn(0x0000, TAG, 'keyVolMigrate: getBundleInfoForSelfSync threw -> treat as upgrade');
      return true;
    }
  }
}
