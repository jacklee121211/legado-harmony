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
 * ⚠️ 2026-10-22：本文件现在承载**两个**迁移 —— `KeyVolDefaultMigration`（音量键翻页）
 *    与文件末尾的 `HapticsDefaultMigration`（震动强度 / 震感模式），两者共用末尾的
 *    模块级 `isUpgradeInstall()` 判定与 `UPGRADE_TOLERANCE_MS` 容差，各自有独立标记键。
 */
import { bundleManager } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { PreferencesUtil } from '@pura/harmony-utils';
import { KEY_KEY_VOL_TURN } from './ReaderKeyTurn';
// 「震动强度 / 震感模式」默认值迁移共用同一套升级判定（见文件末尾的 HapticsDefaultMigration）
import { Haptics } from './Haptics';

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
      const upgrade: boolean = isUpgradeInstall();
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
}
/**
 * 本次安装是否是「从旧版本升级上来」（= 老用户）。
 *
 * 抽成**模块级函数**（2026-10-22）供本文件里的多个迁移共用 ——
 * 判定口径与证据见 `KeyVolDefaultMigration.isUpgradeInstall` 上方注释
 * （`BundleInfo.firstInstallTime` / `updateTime`，容差 60s，读不到按老用户）。
 *
 * @returns true = 老用户（升级/读不到信息，保守按老用户处理）；false = 新装
 */
function isUpgradeInstall(): boolean {
  try {
    const info: bundleManager.BundleInfo =
      bundleManager.getBundleInfoForSelfSync(bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT);
    const first: number | undefined = info.firstInstallTime;
    const updated: number = info.updateTime;
    if (first === undefined || first <= 0) {
      // 取不到首次安装时间（可选字段）⇒ 保守判为老用户
      hilog.warn(0x0000, TAG, 'defaultMigrate: firstInstallTime unavailable -> treat as upgrade');
      return true;
    }
    const delta: number = updated - first;
    hilog.info(0x0000, TAG,
      'defaultMigrate: firstInstallTime=%{public}s updateTime=%{public}s delta=%{public}s',
      String(first), String(updated), String(delta));
    return delta > UPGRADE_TOLERANCE_MS;
  } catch (e) {
    // 读取失败 ⇒ 保守判为老用户
    hilog.warn(0x0000, TAG, 'defaultMigrate: getBundleInfoForSelfSync threw -> treat as upgrade');
    return true;
  }
}

/**
 * 「震动强度 / 震感模式」默认值的一次性迁移（2026-10-22 新增，上架前定稿）。
 *
 * ── 用户原话 ──────────────────────────────────────────────────────────────
 * 「新安装用户的…震动强度 500，震感第三档」。
 * 用户随后确认（2026-10-22 追问）：**只对新装生效** ——
 * 「与音量键翻页一致」，老用户若从未动过滑块不能被一起改掉。
 *
 * ── 为什么必须显式写旧默认值 ──────────────────────────────────────────────
 * 两个键的默认值已改成 `Haptics.STRENGTH_DEFAULT = 500` /
 * `Haptics.MODE_DEFAULT = 100`（见 `Haptics.ets`；2026-10-25 由 150 再改为 100 = 第 2 档）。
 * 而 `PreferencesUtil.getSync(key, defValue)` 在**键从未写入过**时返回 `defValue`
 * （`oh_modules/@pura/harmony-utils/.../PreferencesUtil.ets:105-109` 转发
 * `preferences.getSync`）⇒ 绝大多数老用户从没拖过滑块、本地**没有**这两个键
 * ⇒ 直接改默认值会让他们一起变成 500/第 2 档，正是用户要避免的"手感被改"。
 *
 * ── 处理（每个安装**只跑一次**）─────────────────────────────────────────────
 *   ① 标记 `hapticsDefaultMigratedV1` 已存在 ⇒ 直接返回（以后版本更新不再执行）；
 *   ② 某键**已存在**（用户自己调过）⇒ 一律不动，尊重用户选择；
 *   ③ 判定为**升级安装** ⇒ 给缺失的键显式写入**旧默认值**
 *      （强度 250 / 震感 250，即改造前的 `STRENGTH_DEFAULT` / `MODE_DEFAULT`）；
 *   ④ 判定为**新装** ⇒ 不写，让 `Haptics` 里的新默认值（500 / 100）生效；
 *   ⑤ 最后写标记。失败则不写标记（下次启动重试），且绝不抛异常影响启动。
 *
 * ── 一键回退 ───────────────────────────────────────────────────────────────
 * 把 `ENABLED` 改成 `false` ⇒ 完全不迁移（新默认值对所有人生效）。
 * 已迁移过的机器：删掉 Preferences 键 `hapticsDefaultMigratedV1` 与
 * `HapticsStrength` / `HapticsMode` 后重启即回到"新装"状态（开发者调试用）。
 */
export class HapticsDefaultMigration {
  /** 一键回退开关（`false` = 不迁移，新默认值对所有人生效） */
  static readonly ENABLED: boolean = true;

  /** 一次性迁移标记（唯一阻止重复执行的闸门） */
  static readonly KEY_MIGRATED_V1: string = 'hapticsDefaultMigratedV1';

  /**
   * 改造**之前**的默认值 —— 老用户缺键时要写回这两个值。
   * ⚠️ 必须写成**字面量**，不能引用 `Haptics.STRENGTH_DEFAULT`（那已经是新值 500）：
   *    这里表达的是"历史默认"，与当前默认值是两件事。
   */
  private static readonly LEGACY_STRENGTH: number = 250;
  private static readonly LEGACY_MODE: number = 250;

  // ══════════════════════════════════════════════════════════════════════════
  // V2（2026-10-25）：把"仍停在旧默认值上"的存量配置升级到新默认
  // ══════════════════════════════════════════════════════════════════════════
  /**
   * 是否执行 V2 升级 —— **两种口径的总开关**。
   *
   * ── 用户给的两个方案（原话）──────────────────────────────────────────────
   *   ①「不覆盖老用户现有设置，只为新用户实现这个默认数据」；
   *   ②「这个版本全员使用这个参数，但是用户如果自行修改了，下个版本则不再覆盖这个参数了，
   *      而是集成老用户修改过的参数」。
   *
   * ── 取值 ──────────────────────────────────────────────────────────────────
   *   `true`（**当前默认，2026-10-25 用户拍板选方案②**）= 方案②的安全版：
   *      **只把"值仍精确等于旧默认 250/250"的键**升级到新默认 500/100；
   *      任何其它值（= 用户自己拖过的）**一律不动**。
   *      ⇒ 这样"全员用上新参数"的同时，真正的用户选择一个都不会被覆盖。
   *   `false` = 方案①：V1 已经把老用户的旧默认 250/250 显式写进本地，V2 什么都不做
   *      ⇒ 存量用户手感**一律不变**，只有新装用户拿到 500/100。
   *      （一键回退点：把本常量改回 `false` 即可。）
   *
   * ── 为什么方案②要按"值是否等于旧默认"来判定，而不是简单全员覆盖 ──────────
   *   250/250 这个组合在**没有用户偏好信息**时与"用户手动设成 250/250"不可区分；
   *   但它绝大多数情况下是我们 V1 迁移写进去的（用户从没碰过滑块）。
   *   ⇒ 只升级这个"无信息"的值，是能同时满足两句话的唯一判据。
   *   ⚠️ 唯一代价：恰好手动设成 250/250 的极少数用户会被一起改掉。
   *
   * ── 想切回方案① ──────────────────────────────────────────────────────────
   *   把本常量改成 `false` 即可（无需其它改动）。V2 标记**只在真正执行时才写**，
   *   所以保持 `false` 不影响将来再开启（开启后仍会在各机器上跑一次）。
   */
  static readonly UPGRADE_LEGACY_DEFAULTS: boolean = true;

  /** V2 一次性标记：只在**真正执行过**升级时写，保证"以后版本不再覆盖" */
  static readonly KEY_MIGRATED_V2: string = 'hapticsDefaultMigratedV2';

  /**
   * 启动时调用一次（`EntryAbility.onWindowStageCreate` 里，紧跟 `runOnce()`）。
   *
   * 与 V1 的分工：V1 负责"新装 vs 升级"的分流（新装什么都不写，升级写回旧默认）；
   * V2 负责"把写回去的旧默认再升到新默认"（仅当 `UPGRADE_LEGACY_DEFAULTS = true`）。
   * 两者各有独立标记键，互不干扰，且都是**幂等**的。
   */
  static runOnceV2(): void {
    if (!HapticsDefaultMigration.ENABLED) {
      return;
    }
    if (!HapticsDefaultMigration.UPGRADE_LEGACY_DEFAULTS) {
      // 方案①：完全不动存量配置，也**不写标记**（将来切成 true 仍能生效）
      return;
    }
    try {
      if (PreferencesUtil.hasSync(HapticsDefaultMigration.KEY_MIGRATED_V2) === true) {
        return;
      }
      const strength: number = PreferencesUtil.getSync(Haptics.KEY_STRENGTH,
        Haptics.STRENGTH_DEFAULT) as number;
      const mode: number = PreferencesUtil.getSync(Haptics.KEY_MODE,
        Haptics.MODE_DEFAULT) as number;
      let changed: boolean = false;
      if (Math.round(strength) === HapticsDefaultMigration.LEGACY_STRENGTH) {
        PreferencesUtil.putSync(Haptics.KEY_STRENGTH, Haptics.STRENGTH_DEFAULT);
        changed = true;
      }
      if (Math.round(mode) === HapticsDefaultMigration.LEGACY_MODE) {
        PreferencesUtil.putSync(Haptics.KEY_MODE, Haptics.MODE_DEFAULT);
        changed = true;
      }
      hilog.info(0x0000, TAG,
        'hapticsMigrateV2: legacy defaults upgraded=%{public}s (strength=%{public}d mode=%{public}d)',
        String(changed), Haptics.STRENGTH_DEFAULT, Haptics.MODE_DEFAULT);
      PreferencesUtil.putSync(HapticsDefaultMigration.KEY_MIGRATED_V2, true);
    } catch (e) {
      // 失败不写标记 ⇒ 下次启动重试；绝不阻断启动
      hilog.warn(0x0000, TAG, 'hapticsMigrateV2 failed, will retry next launch');
    }
  }

  /**
   * 启动时调用一次（`EntryAbility.onWindowStageCreate` 里，与音量键翻页迁移并排）。
   * 幂等：已迁移过的机器直接返回，**不会**因为版本更新再覆盖用户配置。
   */
  static runOnce(): void {
    if (!HapticsDefaultMigration.ENABLED) {
      return;
    }
    try {
      // ① 标记已在 ⇒ 本机迁移过，永久跳过
      if (PreferencesUtil.hasSync(HapticsDefaultMigration.KEY_MIGRATED_V1) === true) {
        return;
      }
      // ③④ 判定老/新用户（新装 ⇒ 什么都不写，直接用新默认值）
      const upgrade: boolean = isUpgradeInstall();
      if (upgrade) {
        // ② 逐个键判断：用户调过的**不覆盖**
        if (PreferencesUtil.hasSync(Haptics.KEY_STRENGTH) !== true) {
          PreferencesUtil.putSync(Haptics.KEY_STRENGTH, HapticsDefaultMigration.LEGACY_STRENGTH);
        }
        if (PreferencesUtil.hasSync(Haptics.KEY_MODE) !== true) {
          PreferencesUtil.putSync(Haptics.KEY_MODE, HapticsDefaultMigration.LEGACY_MODE);
        }
        hilog.info(0x0000, TAG,
          'hapticsMigrate: upgrade install -> legacy defaults written (strength=%{public}d mode=%{public}d)',
          HapticsDefaultMigration.LEGACY_STRENGTH, HapticsDefaultMigration.LEGACY_MODE);
      } else {
        hilog.info(0x0000, TAG,
          'hapticsMigrate: fresh install -> keep new defaults (strength=%{public}d mode=%{public}d)',
          Haptics.STRENGTH_DEFAULT, Haptics.MODE_DEFAULT);
      }
      PreferencesUtil.putSync(HapticsDefaultMigration.KEY_MIGRATED_V1, true);
    } catch (e) {
      // 迁移失败**不写标记** ⇒ 下次启动重试；任何情况下都不阻断启动
      hilog.warn(0x0000, TAG, 'hapticsMigrate failed, will retry next launch');
    }
  }
}
