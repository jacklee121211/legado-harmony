/*
 * Copyright (c) 2022 Huawei Device Co., Ltd.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

/**
 * Common constants for all features.
 *
 * ── 已删键归档（2026-10-08 全清，**别再加回来**）─────────────────────────────
 * 这些键在文件里只剩"定义"、全仓**零消费点**，对应的设置项早已删除或从未实现；
 * 它们的共同特征是：`@StorageLink` 内存态、没有 `putSync` ⇒ 用户关掉、重启即复原，
 * 属于**误导用户的假开关**。
 *  · 假开关（开关 + UI 都还在，但什么都没连）：`SET_REFRESH`(setRefresh 自动刷新)、
 *    `SET_JUMP`(setJump 自动跳转最近阅读 —— 真实跳转只服务桌面快捷方式，
 *    见 `Index.consumeQuickAction`)、`SET_REPLACE`(setReplace 替换净化 —— 净化功能已删)、
 *    `SET_TIP`(setTip 返回时提示放入书架 —— 无任何实现)、
 *    `SET_HEAD`(setHead 耳机按键 —— 全仓无耳机按键处理)、
 *    `SET_SEARCH`(setSearch 正文长按搜索 —— 阅读页只有目录搜索)。
 *    逐条证据见 `MySetPage.ets` 的 bookSetList 上方注释。
 *  · 纯残渣（UI 早已删除，只剩常量定义）：`SET_IMG_ANTI`(setImgAnti)、
 *    `SET_BOOK_SAVE`(setBookSave)、`SET_PRE_DOWNLOAD`(setPreDownload)、
 *    `SET_IMG_CACHE`(setImgCache)、`SET_WEB_PORT`(setWebPort)、
 *    `SET_CLEAR_WEB`(setClearWeb)、`SET_USER_AGENT`(setUserAgent)、
 *    `SET_LANGUAGE`(setLanguage)。
 *  · `SET_AWAKEN`(setAwaken)：更早删除（只有 UI 翻转、无功能；"关闭它之后被杀后台"
 *    实为时间巧合，日志证据：第一段锁屏 2 分 22 秒未杀、长时任务 `notification 42`
 *    正常；第二段被杀、`notification -1` 异常）。
 */
export default class MySetConstants {
  /**
   * 震动反馈开关（2026-09-25 新增，全局震动方案）。
   * ⚠️ 与旧 SET_* 不同：这个键**真正落盘**（Preferences `HapticsEnabled`，
   * 见 `common/utils/Haptics.ets`）。
   * 默认值 = **开**（权威单点：`Haptics.isEnabled()` 的 `getSync(KEY_ENABLED, true)`；
   * `MySetPage` 的 `@StorageLink(SET_HAPTICS) setHaptics = true` 与之对齐）。2026-10-19 用户口径确认。
   */
  static readonly SET_HAPTICS: string = 'setHaptics';

  /**
   * 听书引擎切换（2026-09-25 双引擎架构）。⚠️ 仅暗门解锁后可见/可点
   * （ListenUnlock.isUnlocked()）；切换真正落盘到 TtsPrefs.ttsEngine。
   */
  static readonly SET_EDGE_TTS: string = 'setEdgeTts';
  /** 标定模式（开发者）开关（2026-09-26）：解锁后在我的-设置出现，读写 TtsHlCalibV3 的 dev 字段 */
  static readonly SET_CALIB_DEV: string = 'setCalibDev';
  /** 书架书名是否显示文件拓展名（2026-09-27，默认关=隐藏 .txt 等后缀；Preferences 落盘） */
  static readonly SET_EXT_NAME: string = 'setExtName';

  /**
   * 按键翻页（2026-10-07 新增；Preferences 同名键持久化，见 utils/ReaderKeyTurn.ets）。
   * 音量键翻页订阅会拦截系统音量调节（官方 `inputConsumer.on('keyPressed')` 原文），
   * 故仅在阅读页存活时生效，退书即恢复系统音量。
   * ⚠️ 2026-10-19 两处口径变更：
   *   ① **默认开**（用户：「音量键翻页…都是默认开启的」）—— 权威默认值在
   *      `ReaderKeyTurn.isVolOn()`（`getSync(KEY_KEY_VOL_TURN, true)`）与
   *      `MySetPage.aboutToAppear` / `@StorageLink` 初值，三处必须一致；
   *   ② **独立的「按键翻页」组已删除** —— 音量键翻页并入设置页「功能」组第一行
   *      （原「其他」组，改名为「功能」并提到正页最顶端）。键名不变。
   */
  static readonly SET_KEY_VOL: string = 'setKeyVolTurn';
  /**
   * 智控键（侧边指纹键）上/下滑翻页；仅支持该按键的机型生效（KEYCODE_FINGERPRINT_SLIDE_*，@since 26）。
   * ⚠️ 2026-10-19：设置页的「智控键翻页」**整行已按用户要求删除**，本常量随之**无 UI 引用**；
   *    保留只为兼容 `utils/ReaderKeyTurn.ets`（底层按用户选择未删，常量名与 Preferences 键保持一致）。
   */
  static readonly SET_KEY_FP: string = 'setKeyFpTurn';

  /**
   * 阅读器信息窗（2026-10-07 新增；Preferences 同名键持久化）。
   * 开启后：全屏阅读（菜单栏隐藏）时显示 左侧系统时间 + 右侧 防窥眼睛/定时实时信息/书签
   * （玻璃层，不参与仿真翻页卷纸、不可点击——用户明确拍板），字色随正文。
   *
   * ⚠️ **默认值 = 开启**（2026-10-13 用户要求「阅读器信息窗默认打开，新用户默认关闭」）。
   *    权威默认值由 `MySetPage.ets` 的 `PreferencesUtil.getSync(SET_INFO_WIN, true)` 单点给出；
   *    阅读页 `ReaderPage3.aboutToAppear` 回读时必须用**同一个默认值**，
   *    否则「设置页显示开、阅读页却不显示」。
   *    存量用户不受影响：`getSync(key, defValue)` 只在本地**从未存过**该键时返回默认值
   *    （harmony-utils `PreferencesUtil.ets:105-108` 直接转发 `preferences.getSync`）。
   */
  static readonly SET_INFO_WIN: string = 'setReaderInfoWin';

  /**
   * 阅读器信息窗的**元素子开关**（2026-10-19 新增，用户需求：
   * 「显示阅读器信息窗」变成主开关，打开后下面每行空两格列出全部元素，各自可开关）。
   *
   * 全部为**全局** Preferences 键。**默认值（2026-10-19 用户定稿）**：
   *   · 时间显示 `SET_INFO_WIN_TIME`：**三档**（0=关 / 1=`时:分` / 2=`时:分:秒`），默认 **1**（`时:分`）；
   *   · 电量 `SET_INFO_WIN_BATTERY`：**三档**（0=关 / 1=仅图标 / 2=图标+百分比），默认 **1**（仅图标）；
   *   · 书签 `SET_INFO_WIN_BOOKMARK`、防窥 `SET_INFO_WIN_ANTIPEEP`、
   *     定时 `SET_INFO_WIN_TIMER`：布尔，默认 **开**。
   * ⚠️ 默认值的**权威单点**在本文件的注释 + 两处读取点（`MySetPage.aboutToAppear` 与
   *    `ReaderPage3.aboutToAppear`）的 `getSync` 默认实参 —— 三处必须一致。
   * ⚠️ 子开关只在主开关「显示阅读器信息窗」打开时出现在设置页；
   *    主开关关掉**不清**子开关的值（用户下次打开还是原样）。
   */
  static readonly SET_INFO_WIN_TIME: string = 'setReaderInfoWinTime';
  static readonly SET_INFO_WIN_BATTERY: string = 'setReaderInfoWinBattery';
  static readonly SET_INFO_WIN_BOOKMARK: string = 'setReaderInfoWinBookmark';
  static readonly SET_INFO_WIN_ANTIPEEP: string = 'setReaderInfoWinAntiPeep';
  static readonly SET_INFO_WIN_TIMER: string = 'setReaderInfoWinTimer';

  /**
   * 书架顶栏「三段开关 + 三图标胶囊」是否融合成一条（2026-10-21 新增）。
   *
   * 用户原话：「两种都做，然后在设置页定时显示开关下面，增加一个
   *   三段开关+三按钮胶囊融合开关，进行切换显示效果。」
   * · 开 = 两者拼成一整条连续玻璃胶囊；
   * · 关（**默认**）= 分开两段、中间留空隙。
   * 落盘由 `ShelfPrefs.setHeaderMerged()` 负责（与书架其它偏好同一个 Preferences 文件）。
   */
  static readonly SET_HEADER_MERGED: string = 'setShelfHeaderMerged';

  /**
   * 「布局」组 → 首页三段按钮排序（2026-10-21 新增）。
   *
   * 用户原话：「这个新设置没法融入到信息里面去，那就隔开，叫做布局，
   *   我们开一个布局的新区域。」
   * 该行只是**载体**（`hideControl: true`，不画箭头/Toggle）；
   * 真正的交互是自绘的 `ChipOrderSetting` 组件，落盘走 `ShelfPrefs.setChipOrder()`。
   */
  static readonly SET_CHIP_ORDER: string = 'setShelfChipOrder';

  /**
   * 「电量显示」三档模式的**取值归一化**（2026-10-19 二次改造）。
   *
   * 历史：这个键最初是布尔（true = 显示图标+百分比 / false = 不显示），
   * 用户后来要求改成和时间一样的**三档循环**：`0 = 关闭`、`1 = 仅图标`、`2 = 图标+百分比`。
   * 老机器里存的可能是 `boolean` ⇒ 读出来必须先归一化，否则 `true` 被当数字用会出错：
   *   `true` → 2（= 原来的"图标+百分比"），`false` → 0（= 原来的"不显示"）。
   * @param raw Preferences 里读到的原始值（number 或 boolean 或其它）
   * @returns 0 / 1 / 2（**无法识别时回落 1 = 仅图标**，与用户 2026-10-19 定稿的默认值一致）
   */
  static infoBatteryMode(raw: Object): number {
    if (typeof raw === 'boolean') {
      return raw === true ? 2 : 0;
    }
    if (typeof raw === 'number') {
      const n: number = Math.round(raw);
      return n < 0 ? 0 : (n > 2 ? 2 : n);
    }
    return 1;
  }

  /**
   * 阅读页「显示系统状态栏」（2026-10-19 新增，用户需求；**全局**设置，Preferences 同名键）。
   *
   * 开启后：阅读页不再隐藏状态栏，而是**真穿透** ——
   *   ① `WindowAbility.toggleWindowSystemBar(['status'])`（names = 要**显示**的栏）；
   *   ② `setWindowSystemBarProperties({ statusBarColor: '#00000000', statusBarContentColor })`
   *      把状态栏底色设成全透明，窗口本身早就是 `setWindowLayoutFullScreen(true)`
   *      （`EntryAbility.ets:278`）⇒ 状态栏区域露出的是**我们自己的阅读背景**。
   *      依据：`@ohos.window.d.ts:442-450` 原文「Background color of the status bar. The value is
   *      a hexadecimal RGB **or ARGB** color code … The default value is **'#66000000'**」
   *      （默认值本身带 alpha ⇒ ARGB 的透明度生效）。
   * 关闭后：维持旧行为 `toggleWindowSystemBar([])` 全隐藏。
   * ⚠️ 开启时信息窗**左侧（时间 + 电量）不再显示**（用户拍板：与状态栏重复），右侧书签/定时/防窥保留。
   * 默认值 **关**（`false`），保持老用户的全屏观感；存量用户无需迁移。
   */
  static readonly SET_READER_STATUS_BAR: string = 'setReaderStatusBar';

  /**
   * 防窥第 2 层「阅读防窥」开关（2026-10-08 拆层，默认开；VIP 特权）。
   * ⚠️ 与其它 SET_* 不同：**真正落盘**到 Preferences（键见 `utils/AntiPeep.ets` 的
   * KEY_ANTI_PEEP_DLP = 'antiPeepDlpOn'），AppStorage 同名键存的是**有效值**。
   */
  static readonly SET_ANTI_PEEP_DLP: string = 'setAntiPeepDlp';

  /**
   * 防窥第 1 层「防截屏/录屏」开关（2026-10-08 拆层，默认关；VIP 特权）。
   * 落盘键见 `utils/AntiPeep.ets` 的 KEY_ANTI_PEEP_CAPTURE = 'antiPeepCaptureOn'。
   */
  static readonly SET_ANTI_PEEP_CAPTURE: string = 'setAntiPeepCapture';

  /**
   * 离线模式开关（2026-10-13 新增，默认关 = 全量模式）。
   * 开启后隐藏依赖网络的入口（Web服务/测试账号/防窥/AI听书/字体材质方案/自定义主题）。
   * ⚠️ 真正落盘到 Preferences（键见 `utils/OfflineMode.ets` 的 KEY_OFFLINE_MODE = 'offlineMode'），
   * AppStorage 同名键 `offlineModeOn` 存当前值供各页 `@StorageLink` 订阅。
   */
  static readonly SET_OFFLINE_MODE: string = 'setOfflineMode';
}
