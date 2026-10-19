/**
 * 离线模式（2026-10-13 新增，用户需求）。
 *
 * ── 需求（用户原文）───────────────────────────────────────────────────────
 * 「在设置页新增一个切换开关，全量模式和离线模式。」
 * 离线模式 = 把一堆**依赖网络的功能入口整体隐藏**，避免上架审核时出现
 * 「功能存在但不可用」而被判定失败。
 *
 * ── 为什么是手动开关，而不是自动识别网络 ──────────────────────────────────
 * 用户原方案是自动检测网络后切换；实测取证后弃用（本文件刻意不留自动检测代码）：
 *  · `hasDefaultNetSync()` 不能判「能否真正访问互联网」——官方 FAQ
 *    （documentId `FAQ/网络/网络_Network/应用网络类型与显示状态不匹配/faqs-network-110`）原文：
 *    「启动应用时没有网络连接（没有连接WIFI和蜂窝数据，**连接一个没有联网的WIFI也不行**）」
 *    ⇒ 门户 WiFi 下它仍返回 true ⇒ **漏判**。
 *  · 改用 `NET_CAPABILITY_VALIDATED` 判「真能上网」又会**误判**——SDK
 *    `@ohos.net.connection.d.ts:1979-1983` 原文：「如果网络管理模块连接华为云地址失败，
 *    该标志不在网络能力中，**但这并不意味着完全无法访问互联网**」
 *    ⇒ 国外网络/部分企业网会被误判成离线，把能用的功能藏掉（正是要避免的审核失败）。
 *  · 另有验证窗口期：`NET_CAPABILITY_CHECKING_CONNECTIVITY`（`d.ts:2000-2003`）原文
 *    「连通性验证进行中。**此期间 VALIDATED 的值可能不正确**」⇒ 刚联网瞬间会抖动。
 * ⇒ 结论：自动识别在两个方向上都有真实误判风险，**改为用户手动切换**（可控、可复现、
 *   审核员自己就能切回来）。
 *
 * ── 状态归属（与 AntiPeep / VipManager 同款范式）────────────────────────────
 * Preferences 存**用户意图**（`offlineMode`，默认 false = 全量模式）；
 * AppStorage 同名键存**当前值**供各页面 `@StorageLink` 订阅，切换后全应用立即刷新。
 *
 * ── 隐藏范围（用户拍板的 6 类，仅隐藏入口，不动任何已有开关状态）─────────────
 *  1. Web服务整卡（`MyCenter.ets`）
 *  2. 测试账号入口（`MySetPage.ets`）
 *  3. 防窥两开关（`MySetPage.ets`）+ 阅读器两处小眼睛（`ReaderPage3.ets`）
 *  4. AI 听书 / AI 语音配置区 / AI 语气 / AI 男女声（`TtsControlPanel.ets`）
 *  5. 字体管理 / 更多材质 / 更多方案（`ReaderPage3.ets`）+ 保存方案
 *  6. 自定义主题入口（`MyThemeConfigComp.ets` + `Index.ets`）
 * ⚠️ 刻意**只隐藏 UI**：防窥的已开启状态、已选中的字体/材质/主题一律不动
 *   （用户明确要求），避免"切个模式把用户的安全设置悄悄关掉"。
 */
import { PreferencesUtil } from '@pura/harmony-utils';
import { Haptics } from './Haptics';

/** Preferences 键：用户意图（默认 false = 全量模式） */
export const KEY_OFFLINE_MODE: string = 'offlineMode';
/** AppStorage 键：当前值（各页 @StorageLink 订阅此键） */
export const STORAGE_KEY_OFFLINE_MODE: string = 'offlineModeOn';

export class OfflineMode {
  /** 读取当前是否处于离线模式（写 UI 常量用；渲染侧请用 @StorageLink 订阅 STORAGE_KEY） */
  static isOn(): boolean {
    try {
      return PreferencesUtil.getSync(KEY_OFFLINE_MODE, false) === true;
    } catch (e) {
      return false;
    }
  }

  /** 应用启动时调用一次：把落盘意图灌进 AppStorage，供全应用订阅 */
  static init(): void {
    AppStorage.setOrCreate(STORAGE_KEY_OFFLINE_MODE, OfflineMode.isOn());
  }

  /**
   * 精简模式下**是否仍显示「阅读增强」类入口**（2026-10-13 方案 A，用户拍板）。
   *
   * ── 为什么要改（商业口径）───────────────────────────────────────────────
   * 旧实现按「看起来高级」隐藏，把 VIP 的 7 项权益里的 6 项也一起藏了，
   * 而它们**根本不需要网络**：
   *   导入字体 / 更多材质 / 更多方案 / 自定义颜色 / 自定义主题 / 防窥保护
   * 唯一真联网的是「下载字体文件」（`ReaderFontDialog.ets:22` import `http`）。
   * 后果：精简模式用户看得到「开通 VIP」卡片（`MyCenter.ets:282` 不受 offlineOn 影响），
   * 却看不到任何权益入口 ⇒ **买点消失**，无法转化。
   *
   * ── 新口径 ──────────────────────────────────────────────────────────────
   * 精简模式只藏「**真的需要网络**」的入口；阅读增强类（本地能力）全部保留可见。
   * 与精简模式自身定位自洽 —— 它的介绍就是「保证**极致阅读**的极简主义」。
   *
   * ⚠️ 一键回退（本工程惯例）：把返回值改成 `false` ⇒ 这批入口**全线隐藏**
   *    （比旧行为更保守）。回退后要验证：
   *    ① 精简模式下阅读器设置面板不再出现「字体管理/更多材质/更多方案」；
   *    ② 「我的 → 主题」不再出现「自定义主题」瓦片；
   *    ③ 「我的 → 设置 → 功能」不再出现防窥两行（2026-10-19：原「其他」分组改名「功能」）。
   */
  static showReadingEnhancements(): boolean {
    return true;
  }

  /**
   * 设置离线模式（设置页开关唯一入口）。
   * 落盘 + 广播同一份值 ⇒ 所有订阅页立即重渲染。
   */
  static set(on: boolean): void {
    try {
      PreferencesUtil.putSync(KEY_OFFLINE_MODE, on);
    } catch (e) {
      // 落盘失败不影响本次会话
    }
    AppStorage.setOrCreate(STORAGE_KEY_OFFLINE_MODE, on);
  }

  /** 切换（设置页 Toggle 用；带一次轻震） */
  static toggle(): boolean {
    const next: boolean = !OfflineMode.isOn();
    Haptics.tap();
    OfflineMode.set(next);
    return next;
  }
}
