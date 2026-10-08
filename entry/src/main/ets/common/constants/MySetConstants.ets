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
   * 按键翻页组（2026-10-07 新增，默认关；Preferences 同名键持久化，见 utils/ReaderKeyTurn.ets）。
   * 音量键翻页订阅会拦截系统音量调节（官方 `inputConsumer.on('keyPressed')` 原文），
   * 故仅在阅读页存活时生效，退书即恢复系统音量。
   */
  static readonly SET_KEY_VOL: string = 'setKeyVolTurn';
  /** 智控键（侧边指纹键）上/下滑翻页；仅支持该按键的机型生效（KEYCODE_FINGERPRINT_SLIDE_*，@since 26） */
  static readonly SET_KEY_FP: string = 'setKeyFpTurn';

  /**
   * 阅读器信息窗（2026-10-07 新增，默认关；Preferences 同名键持久化）。
   * 开启后：全屏阅读（菜单栏隐藏）时右上角显示 防窥眼睛 + 定时实时信息（玻璃层，
   * 不参与仿真翻页卷纸、不可点击——用户明确拍板），字色随正文。
   */
  static readonly SET_INFO_WIN: string = 'setReaderInfoWin';

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
}
