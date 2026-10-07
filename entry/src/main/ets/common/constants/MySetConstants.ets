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
 */
export default class MySetConstants {
  /**
   * 自动刷新
   */
  static readonly SET_REFRESH: string = 'setRefresh';

  /**
   * 自动跳转最近阅读
   */
  static readonly SET_JUMP: string = 'setJump';

  /**
   * 默认启用替换净化
   */
  static readonly SET_REPLACE: string = 'setReplace';

  /**
   *返回时提示放入书架
   */
  static readonly SET_TIP: string = 'setTip';

  /**
   *图片抗锯齿
   */
  static readonly SET_IMG_ANTI: string = 'setImgAnti';

  // T31（本次对话）：已删除 `SET_AWAKEN`（'setAwaken'，"Webservice唤醒锁"）。
  // 删除原因：该开关在代码里**只有 UI 翻转、没有任何功能**（全仓 5 处引用全为定义/绑定/显示/翻转），
  // 属于**误导用户**的假开关 —— 用户实测"关闭它之后被杀后台"实为时间巧合
  // （日志证据：第一段锁屏 2 分 22 秒未杀，长时任务 `notification 42` 正常；
  //   第二段被杀，长时任务 `notification -1` 异常）。

  /**
   *全程响应耳机按键
   */
  static readonly SET_HEAD: string = 'setHead';

  /**
   *文字操作显示搜索
   */
  static readonly SET_SEARCH: string = 'setSearch';


  static readonly SET_BOOK_SAVE: string = 'setBookSave';

  static readonly SET_PRE_DOWNLOAD: string = 'setPreDownload';

  static readonly SET_IMG_CACHE: string = 'setImgCache';

  static readonly SET_WEB_PORT: string = 'setWebPort';

  static readonly SET_CLEAR_WEB: string = 'setClearWeb';

  static readonly SET_USER_AGENT: string = 'setUserAgent';

  static readonly SET_LANGUAGE: string = 'setLanguage';

  /**
   * 震动反馈开关（2026-09-25 新增，全局震动方案）。
   * ⚠️ 与其他 SET_* 不同：这个键**真正落盘**（Preferences `HapticsEnabled`，
   * 见 `common/utils/Haptics.ets`）—— 旧 SET_* 键只存在 AppStorage、重启即丢。
   */
  static readonly SET_HAPTICS: string = 'setHaptics';

  /**
   * 听书引擎切换（2026-09-25 双引擎架构）。⚠️ 仅暗门解锁后可见/可点
   * （ListenUnlock.isUnlocked()）；切换真正落盘到 TtsPrefs.ttsEngine。
   */
  static readonly SET_EDGE_TTS: string = 'setEdgeTts';
  /** 标定模式（开发者）开关（2026-09-26）：解锁后在我的-设置出现，读写 TtsHlCalibV3 的 dev 字段 */
  static readonly SET_CALIB_DEV: string = 'setCalibDev';
  /** 书架书名是否显示文件拓展名（2026-09-27 新增，默认关=隐藏 .txt 等后缀） */
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
}