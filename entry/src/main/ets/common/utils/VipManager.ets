import { PreferencesUtil } from '@pura/harmony-utils';

/**
 * 会员（VIP）/ 登录态 状态层（2026-09-28 新增）。
 *
 * ── 职责边界 ──────────────────────────────────────────────────────────────
 * · VIP 的**事实源**是华为 IAP 服务器：非消耗型商品 `miaoyue_vip_permanent`
 *   （9.9 元永久），阶段2 接入后以 `iap.queryPurchases(CURRENT_ENTITLEMENT)`
 *   查询为准；本地 Preferences 只缓存最近一次结果，加速启动。
 * · 登录态只负责「我的」页头像昵称展示，与 VIP 判定**解耦**——
 *   IAP 记账跟的是设备上的华为账号，不强制先登录 app 内账号。
 * · 隐藏功能（EdgeTTS / 标定模式 / 听书入口）走既有 `ListenUnlock`，与本类无关；
 *   解锁入口已从「我的」页改名迁到测试账户表单（见 TestAccountDialog）。
 */
export class VipManager {
  /** 沙盒商品 ID（AGC 非消耗型商品，9.9 元永久） */
  static readonly PRODUCT_ID: string = 'miaoyue_vip_permanent';

  /** Preferences 键：VIP 解锁缓存位（事实源在 IAP） */
  private static readonly KEY_VIP: string = 'VipUnlocked';
  /** AppStorage 键：VIP 状态变化广播（@StorageLink 的键要求编译期字面量，勿改字符串） */
  static readonly STORAGE_KEY: string = 'vipUnlocked';

  /** 登录类型：'' = 未登录 / 'test' = 测试账号 / 'huawei' = 华为账号（阶段3） */
  private static readonly KEY_LOGIN_TYPE: string = 'AccountLoginType';
  /** AppStorage 键：登录态变化广播 */
  static readonly LOGIN_STORAGE_KEY: string = 'accountLoginType';

  /** 测试账号固定凭证（2026-09-28 用户指定） */
  static readonly TEST_USER: string = 'huaweiceshi';
  static readonly TEST_PASS: string = 'huaweiceshi1234';

  /**
   * ⚠️ 上架 release 前必改 false：测试账号自动授予 VIP。
   * 仅用于 IAP 接入前的锁定/解锁 UI 联调；阶段2 接入 IAP 后改由
   * 沙盒环境判定（iap.Environment.SANDBOX），本开关置 false 并删除。
   */
  static readonly TEST_ACCOUNT_VIP_GRANT: boolean = true;

  /** 彩蛋解锁码（测试账户页输入 → 解锁隐藏功能，**不登录**），2026-09-28 用户指定。
   *  密码改用纯字母 woaixiaoyao：密码框是 InputType.Password，系统安全键盘不支持中文输入 */
  static readonly EGG_USER: string = '我爱李杰克';
  static readonly EGG_PASS: string = 'woaixiaoyao';

  /** VIP 是否已解锁（读缓存位；阶段2 后由 refreshFromIap 刷新） */
  static isVip(): boolean {
    return PreferencesUtil.getSync(VipManager.KEY_VIP, false) as boolean;
  }

  /** 写 VIP 缓存位并广播 */
  static setVip(v: boolean): void {
    PreferencesUtil.putSync(VipManager.KEY_VIP, v);
    AppStorage.setOrCreate(VipManager.STORAGE_KEY, v);
  }

  static loginType(): string {
    return PreferencesUtil.getSync(VipManager.KEY_LOGIN_TYPE, '') as string;
  }

  static isLoggedIn(): boolean {
    return VipManager.loginType() !== '';
  }

  /** 测试账号登录（凭证匹配才生效；昵称沿用「我的」页现有昵称体系） */
  static loginTest(user: string, pass: string): boolean {
    if (user !== VipManager.TEST_USER || pass !== VipManager.TEST_PASS) {
      return false;
    }
    PreferencesUtil.putSync(VipManager.KEY_LOGIN_TYPE, 'test');
    AppStorage.setOrCreate(VipManager.LOGIN_STORAGE_KEY, 'test');
    if (VipManager.TEST_ACCOUNT_VIP_GRANT) {
      VipManager.setVip(true);
    }
    return true;
  }

  /**
   * 退出登录（2026-09-28 用户需求：点头像 → 确认登出）。
   * 测试账号的「赠送 VIP」随登出收回（仅联调期行为，见 TEST_ACCOUNT_VIP_GRANT）；
   * 阶段2 接入 IAP 后，真实购买以 queryPurchases 为准，登出不影响已购权益。
   */
  static logout(): void {
    if (VipManager.loginType() === 'test' && VipManager.TEST_ACCOUNT_VIP_GRANT) {
      VipManager.setVip(false);
    }
    PreferencesUtil.putSync(VipManager.KEY_LOGIN_TYPE, '');
    AppStorage.setOrCreate(VipManager.LOGIN_STORAGE_KEY, '');
  }
}
