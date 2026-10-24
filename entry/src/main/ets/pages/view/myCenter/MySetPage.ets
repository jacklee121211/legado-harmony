import MySetConstants from '../../../common/constants/MySetConstants'
import { Attribute } from '../../../common/utils/Attribute'
// ── 加入 QQ 群（2026-10-21 新增）：跳转走系统 openLink ────────────────────────
import { common } from '@kit.AbilityKit'
import { BusinessError, deviceInfo } from '@kit.BasicServicesKit'
import { hilog } from '@kit.PerformanceAnalysisKit'
// 2026-10-24：QQ 群入口改用 `forward/url`，需要 base64 编码官方邀请链接（url_prefix）
import { util } from '@kit.ArkTS'
import { SetList, SetGroupList } from '../../../componets/dataList/SetListGroup'
import { SetListView } from '../../../componets/myset/SetListView'
// 首页三段按钮排序控件（2026-10-21 新增）
import { ChipOrderSetting } from '../../../componets/myset/ChipOrderSetting'
import { TabHeader } from '../../../componets/common/TabHeader'
// 2026-10-13：「关于我们」入口从「我的」页迁到本页最底部，需要路由门面
import AppRouter, { RouteName } from '../../../common/router/AppRouter'
// ── 全局震动反馈（2026-09-25 新增）────────────────────────────────────────────
// （2026-10-21：曾为「书架顶栏融合」开关引入 ShelfPrefs，该开关已移除 ⇒ import 一并删除）
import { Haptics } from '../../../common/utils/Haptics'
import { PreferencesUtil } from '@pura/harmony-utils'
// ── 听书双引擎（2026-09-25 新增）──────────────────────────────────────────────
// 默认=系统本地引擎（Core Speech Kit，离线可用）；Edge TTS 仅暗门解锁后出现在此切换。
import { ListenUnlock } from '../../../common/utils/ListenUnlock'
import { loadTtsPrefs, saveTtsPrefs } from '../../../tts/TtsPrefs'
// 听书会话（2026-10-12）：「显示文件拓展名」开关一变就强制刷新迷你栏书名
import { ListenSession } from '../../../tts/ListenSession'
import { NightMode, ShelfColors } from '../../../common/utils/NightMode'
import { CalibMode } from '../../../common/utils/CalibMode'
import { ThemeStorageKey } from '../../../common/constants/Theme'
import { ThemeItem } from '../../../common/model/Theme'
// ── 测试账号（2026-09-28 迁入）：登录下线后，测试登录+彩蛋解锁入口迁到本页顶部 ──
import UiMotion, { runJellyClick } from '../../../common/utils/UiMotion'
import ImmersiveMaterialUtil from '../../../common/utils/ImmersiveMaterialUtil'
// ── 宫格列数（2026-10-23 多端适配新增）：手机以外设备可手动调整「一行显示几本」
import ShelfPrefs from '../../../common/utils/ShelfPrefs'
import { TestAccountDialog } from '../../../componets/myCenter/TestAccountDialog'
// ── 字号阶梯（2026-10-06 统一标准，见 FontConstants「语义阶梯」段；本页文字只取这四档）──
import FontConstants from '../../../common/constants/FontConstants'
// ── 按键翻页（2026-10-07 新增；2026-10-19 智控键翻页入口删除，只剩音量键）：订阅调度见 utils/ReaderKeyTurn.ets ──
import { ReaderKeyTurn, KEY_KEY_VOL_TURN } from '../../../common/utils/ReaderKeyTurn'
// ── 防窥两层开关（2026-10-08 新增，VIP 特权）：真值/下沉逻辑全在 utils/AntiPeep.ets ──
import { AntiPeep, KEY_ANTI_PEEP_CAPTURE, KEY_ANTI_PEEP_DLP } from '../../../common/utils/AntiPeep'
import { VipManager } from '../../../common/utils/VipManager'
// ── 离线模式（2026-10-13 新增）：手动「全量/离线」切换，隐藏依赖网络的入口 ──
import { OfflineMode, STORAGE_KEY_OFFLINE_MODE } from '../../../common/utils/OfflineMode'
// ── 首次安装模式选择（2026-10-13 新增）：本页只用到「开发者重放」入口 ──────────
import { FirstRunMode } from '../../../common/utils/FirstRunMode'
import { VipDialog } from '../../../componets/myCenter/VipDialog'
// 2026-10-19：「书架动画速度」滑块按用户要求**整项删除**（连 `shelfAnimSpeed` 读写一起去掉）
// ⇒ 不再 import EntranceWave；书架入场波次回归 `EntranceWave` 内置默认档（level 3 = 0.75x）。

// ── 喵阅官方 QQ 群（2026-10-21 新增；2026-10-22 首改；2026-10-24 二次改，见下）──────
//
// 三级链路：**① 让 QQ 打开官方邀请链接 → ② 邀请链接（浏览器/H5）→ ③ 群号兜底**。
//
// ⚠️ 2026-10-24 换通道的实证依据（MatePad Pro MRO-W00 / HarmonyOS 6.1 / QQ 9.2.71）：
//   旧方案 ① 是 `mqqapi://card/show_pslcard?...&card_type=group`，**冷启动必卡「加载中」**
//   （实测 40s 不恢复；热启动正常）。QQ 日志证明卡点在 QQ 自己那侧：
//     `JumpService: sourceJumpUrl:mqqapi://card/show_pslcard?...`   ← 已收到
//     `ProfileCardOIDBHelper: sendOIDBRequest: success, retCode=0`   ← 群资料已拉回
//   但页面始终不渲染、loading 层不撤 ⇒ 我们这侧无法修，只能换通道。
//   对照实验（同一台设备、同一个群）：
//     · `card/show_pslcard`           → 冷启动卡死（40s 仍卡）／热启动正常
//     · 裸 https 邀请链接              → 冷启动进浏览器官方群资料页，底部「申请加群」
//     · **`forward/url` + url_prefix** → 冷启动 **2/2 直接进 QQ 原生群资料页**，不卡 ✅
//     · `im/chat?...&chat_type=group`  → 冷启动不卡，直接进群聊（仅对已入群者有意义）
//
// ⚠️ 为什么弃用 `card/show_pslcard`：它是 QQ 的**内部私有 scheme**，不在任何官方文档里
//   ——QQ互联 HarmonyOS SDK（V1.0.4）公开接口只有 login / share / isQQInstalled /
//   addCustomLogger，Android SDK 功能列表同样**没有加群 / 群资料能力**。
//   即「第三方 App 拉起 QQ 加群」腾讯从未提供官方 API，私有 scheme 的 bug 自然无人修。
//
// ① 官方语义下的加群载体是**群分享链接 / 二维码**（QQ 群设置里生成），即下面 `QQ_GROUP_URL`：
//   `busi_data` 解出来是 `{"groupCode":"526836555","token":"…","uin":"…"}`，由 QQ 自己签发。
//   官方期望的用法是「当普通网页链接打开 → H5 里点『申请加群』→ 由 H5 拉起 QQ」。
//   `forward/url` 就是让 QQ **自己**去打开这条官方链接（QQ 内置浏览器加载后自动跳原生群资料页），
//   语义上仍走官方 H5 通道，只是把 H5 放在了 QQ 里 ⇒ 既守规范、又免掉浏览器那一跳。
//
// ② 兜底：`forward/url` 抛错（QQ 未安装 / 老版本不认该 scheme）时，退回 `openLink(邀请链接)`，
//   由系统浏览器打开官方 H5 群资料页。
//   （`bm dump -n com.tencent.mqq` 显示 QQ 声明的 https host 只有 `qm.qq.com` 与
//    `qqso.qianbao.qq.com`，**不含 `qun.qq.com`** ⇒ 走 openLink 必然落到浏览器。）
//
// ③ 群号 `526836555`：前两级都失败时按钮下方常驻展示，用户可手动搜索加群。
const QQ_GROUP_CODE: string = '526836555'

/** ② 官方群分享链接（用户给定，原样保留 percent-encoded 的 `%2B`/`%2F` 与 base64 的 busi_data） */
const QQ_GROUP_URL: string = 'https://qun.qq.com/universal-share/share?ac=1&authKey=d5vyZIDihejxMq67Ib9Ae05s1scbFNo4yvjkoNqcoGgnHOX0Lkf%2BabPN/bIEuAi1&busi_data=eyJncm91cENvZGUiOiI1MjY4MzY1NTUiLCJ0b2tlbiI6IlN0K0p0L3o1NWwwdEEvTEdKc0IvNXF5UGQrTDEvczUwbmxSNklXL0NGK0duWEJRVWhaeEFBVlMzTEN0anlHeUwiLCJ1aW4iOiIxNzMzODIyODc3In0=&data=uZnXBzbs3rpves1K30ISR1NR7hDg8V5OeQJ4wKxXtAklswbrdGD99qm8H5Sr-UW3FknXRZksOM8gssRqKN2leg&svctype=4&tempid=h5_group_info'

/**
 * ① 「让 QQ 自己打开官方邀请链接」的 Deep Link。
 *
 * `url_prefix` 是 **base64(UTF-8)** 的完整 URL —— 这是 QQ `forward/url` 的既有约定。
 * 证据：QQ 自己下发的插件数据里就有同款（2026-10-24 真机 hilog，`QQKMPPluginDataManager` 的 jumpUrl）：
 *   `mqqapi://forward/url?src_type=internal&plg_dev=0&plg_auth=1&version=1&style=home&url_prefix=aHR0cHM6…`
 *
 * 用**运行时编码**而不是写死 base64 串：`QQ_GROUP_URL` 一旦改动不会忘记同步
 * （写死过一次就必然踩：改了链接、忘了改 base64，表现为 QQ 打开一个 404 页）。
 */
function buildQqGroupScheme(): string {
  const prefix: string = new util.Base64Helper().encodeToStringSync(new util.TextEncoder().encodeInto(QQ_GROUP_URL))
  return `mqqapi://forward/url?src_type=internal&version=1&plg_auth=1&plg_dev=0&url_prefix=${prefix}`
}

const QQ_GROUP_SCHEME: string = buildQqGroupScheme()

// ── 信息窗「时间显示」三档的显示文案（2026-10-19 新增）────────────────────────// 值的口径与阅读页一致（`ReaderPage3` 的 `infoWinTimeMode`）：0 = 关、1 = 时:分、2 = 时:分:秒。
const INFO_TIME_MODE_LABELS: string[] = ['关闭', '时:分', '时:分:秒']
export function infoTimeLabel(mode: number): string {
  const i: number = mode < 0 ? 0 : (mode > 2 ? 2 : mode)
  return INFO_TIME_MODE_LABELS[i]
}

/** 信息窗「电量显示」三档的显示文案（2026-10-19）：0 = 关闭、1 = 仅图标、2 = 图标+百分比 */
const INFO_BATTERY_MODE_LABELS: string[] = ['关闭', '仅图标', '图标+百分比']
export function infoBatteryLabel(mode: number): string {
  const i: number = mode < 0 ? 0 : (mode > 2 ? 2 : mode)
  return INFO_BATTERY_MODE_LABELS[i]
}

// 迁 Navigation 第 4 期：去掉 `@Entry` + 补 `export default`（被 Index.ets import 当组件用）。
@Component
export default struct MySetPage{
  // 2026-09-21 精简（用户决定）：随「缓存下载」「网络」两组与「语言」一起删除的状态 ——
  // `isShowPreDon` / `isShowLanguage` / `setImgAnti` / `select` / `selectLanguage` /
  // `tempNum` / `preDow` / `fruits` / `languageList`，以及对应的两个半模态
  // `preDowSheet()` / `languageSheet()`。
  // 2026-10-08 再精简（用户决定：「全删了就完了」）：以下 6 项**全仓零消费点**的假开关移除 ——
  //  · 自动刷新 `setRefresh`：书源/联网取书路径已整体删除（`database/index.ets:17`），无数据源；
  //  · 自动跳转最近阅读 `setJump`：真实跳转只服务桌面快捷方式（`Index.consumeQuickAction`
  //    要求 quickAction = 'read'/'listen'），与开关无关；
  //  · 默认启用替换净化 `setReplace`：净化功能已删（`ReaderPage3.ets:6001-6006` 无规则表/DAO）；
  //  · 返回时提示放入书架 `setTip`：全仓无任何实现；
  //  · 全程响应耳机按键 `setHead`：全仓无耳机按键处理（只在注释里出现过）；
  //  · 文字操作显示搜索 `setSearch`：阅读页没有正文长按菜单/搜索（只有目录搜索）。
  //  ⚠️ 这 6 个还都是 `@StorageLink`（内存态、无 putSync）⇒ 关掉重启即复原，本就形同虚设。
  /** 书架书名显示拓展名（2026-09-27，本项目自研功能：默认关；Preferences 持久化） */
  @StorageLink(MySetConstants.SET_EXT_NAME) setExtName: boolean = false
  /**
   * 阅读页「显示系统状态栏」（2026-10-19 新增，全局；默认关）。
   * 开启后阅读页把状态栏设成全透明 + 保留显示（真穿透），且信息窗左侧时间/电量隐藏。
   */
  @StorageLink(MySetConstants.SET_READER_STATUS_BAR) showReaderStatusBar: boolean = false

  // ── 信息窗元素子开关（2026-10-19 新增，用户需求）─────────────────────────────
  // ⚠️ 声明位置必须在行表（`infoBaseList`）**之前**：行表初始化时会读这些状态。
  // **默认值（2026-10-19 用户定稿）**：时间 = `时:分`、电量 = `仅图标`、
  // 书签/防窥/定时 = 开；「显示系统状态栏」= 关（见 `showReaderStatusBar`）。
  // ⚠️ 与 `ReaderPage3.aboutToAppear` 的 `getSync(...)` 默认实参必须逐一一致。
  /** 时间显示：0 = 关，1 = 时:分，2 = 时:分:秒 */
  @State infoWinTimeMode: number = 1
  /** 电量显示：0 = 关，1 = 仅图标，2 = 图标+百分比 */
  @State infoWinBatteryMode: number = 1
  @State infoWinBookmarkShow: boolean = true
  @State infoWinAntiPeepShow: boolean = true
  @State infoWinTimerShow: boolean = true
  // （2026-10-21 删除 `headerMergedOn`：融合开关已按用户要求移除，顶栏固定分离式）
  /** 阅读器信息窗（2026-10-07）：全屏阅读时的系统时间 + 防窥/定时实时信息；Preferences 持久化，默认开 */
  // ⚠️ 2026-10-19 默认值对齐（用户口径：新装默认开）：初值给 `true`，
  //    与 `aboutToAppear` 的 `getSync(SET_INFO_WIN, true)`、`ReaderPage3` 的回读三方一致。
  @StorageLink(MySetConstants.SET_INFO_WIN) setInfoWin: boolean = true

  // ── 防窥两层开关（2026-10-08 拆层，VIP 特权）──────────────────────────────
  // ⚠️ 这两个 @StorageLink 绑的是**有效值**（非 VIP 恒 false、第 2 层还要求系统防窥开关已开），
  //    由 AntiPeep 在启动 / 本页进场时写入；用户意图（Preferences）另存，见 AntiPeep 文件头。
  /** 第 2 层 阅读防窥（默认开） */
  @StorageLink('antiPeepDlpOn') @Watch('syncAntiPeepRows') setAntiPeepDlp: boolean = false
  /** 第 1 层 防截屏/录屏（默认关） */
  @StorageLink('antiPeepCaptureOn') @Watch('syncAntiPeepRows') setAntiPeepCapture: boolean = false
  /** VIP 开通成功后要补开的那个开关（'' = 无待办；用户第 4 点要求） */
  private pendingAntiPeep: string = ''
  /** 「VIP 购买」弹窗控制器（范式与 MyThemeConfigComp.openVip 一致） */
  private vipDialog: CustomDialogController | null = null

  @StorageLink('bottomRectHeight') bottomRectHeight: number = 0
  @StorageLink('topRectHeight') topRectHeight: number = 0
  /** 主题颜色（2026-10-01：测试账号胶囊按钮的 symbol 取色用） */
  @StorageProp(ThemeStorageKey.THEME) theme: ThemeItem = {} as ThemeItem
  /** App 级夜间开关：测试账号弹窗深浅适配用（2026-09-28） */
  @StorageLink(NightMode.KEY) nightOn: boolean = false
  /**
   * 登录态（2026-10-13）：@StorageLink 绑 VipManager 广播的**同一键**（VipManager.ets:27），
   * 由 loginTest/logout 写入 'test'/''。用途：**只有**测试账号登录成功后，隐藏「测试账号」入口。
   * 为什么必须绑 AppStorage 而不是在 onClick 里改局部 @State：
   *   登出（VipManager.logout）发生在「我的」页，设置页可能已在 Navigation 栈里缓存
   *   ⇒ 只改局部 state 的话登出后入口不会自己回来。绑广播键两端都自动同步。
   */
  @StorageLink(VipManager.LOGIN_STORAGE_KEY) loginType: string = ''
  /**
   * 离线模式（2026-10-13 新增，用户需求）：true = 离线模式（隐藏依赖网络的入口）。
   * 绑 AppStorage 广播键（OfflineMode.STORAGE_KEY_OFFLINE_MODE）⇒ 开关一拨，
   * 设置页自身 + 其它页（阅读器/主题页/我的）全部立即重渲染。
   * ⚠️ `@Watch` 是必需的：本页的「功能」分组（2026-10-19 前叫「其他」）是**数组驱动**，光改状态不会重建数组
   *    ⇒ 防窥两行不会消失。见 onOfflineModeChanged()。
   */
  @StorageLink(STORAGE_KEY_OFFLINE_MODE) @Watch('onOfflineModeChanged') offlineOn: boolean = false

  // ── 全局震动反馈（2026-09-25 新增，用户需求）────────────────────────────────
  // 开关 + 0-500 强度滑块（每 50 一档）。真正落盘到 Preferences（键 HapticsEnabled /
  // HapticsStrength），与 Haptics 模块共用 —— 旧 SET_* 键只存 AppStorage、重启即丢，
  // 本组设置必须跨启动生效，所以单独走 PreferencesUtil。
  @StorageLink(MySetConstants.SET_HAPTICS) setHaptics: boolean = true
  @State hapticStrength: number = Haptics.STRENGTH_DEFAULT
  /** 震感模式滑块值 0-500（每 50 一档 → 10 种官方预置效果拼配，见 Haptics.MODE_TABLE） */
  @State hapticMode: number = Haptics.MODE_DEFAULT
  /** 记录上次滑块所在档位（用于"跨档才震动一次"） */
  private lastStrengthStep: number = Haptics.STRENGTH_DEFAULT / Haptics.STRENGTH_STEP
  /** 记录上次模式滑块所在档位 */
  private lastModeStep: number = Haptics.MODE_DEFAULT / Haptics.STRENGTH_STEP

  // ── 书架宫格「一行显示几本」（2026-10-23 多端适配新增）────────────────────
  /**
   * 用户手动设定的宫格列数；`0` = **自动**（跟随屏幕断点）。
   *
   * 用 `@StorageLink` 而不是 `@State`：书架 `BookContent` 用
   * `@StorageProp('shelfGridColumns')` 订阅同一个键 ⇒ 拖完滑块书架立刻重排，
   * 不需要退出设置页再进书架。
   *
   * ⚠️ 只有**手机以外**的设备显示这个滑块（`showGridColumnsRow()`）：
   *   手机屏幕窄，3 列已是实测最优，给出滑块只会让用户把封面调得看不清书名。
   */
  @StorageLink(ShelfPrefs.KEY_GRID_COLUMNS_STORAGE) gridColumns: number = 0

  /** 当前横向断点（用于滑块「自动」档时显示实际生效的列数） */
  @StorageProp('currentBreakpoint') currentBreakpoint: string = 'sm'

  /**
   * 是否显示「一行显示书籍数」滑块 —— **仅手机以外的设备**。
   *
   * 用户原话（2026-10-23）：「我们在手机以外的设备的设置页，布局这一区域可以增加
   *   一个调整滑块，手动调整一行显示的书籍数，也给用户一个自己定义的机会。」
   */
  private showGridColumnsRow(): boolean {
    return deviceInfo.deviceType !== 'phone'
  }

  /** 滑块当前应显示的列数：用户手动值优先，否则取自动档（跟随断点） */
  private gridColumnsShown(): number {
    return ShelfPrefs.effectiveColumns(this.gridColumns, this.currentBreakpoint)
  }

  // ── 听书双引擎（2026-09-25 新增）────────────────────────────────────────────
  // 整组仅在暗门解锁后出现（listenEntryUnlocked）；开关=切 Edge/本地引擎，
  // 落盘 TtsPrefs.ttsEngine（TtsEngine.activeEngineId() 还有解锁二次校验兜底）。
  @StorageLink('listenEntryUnlocked') listenUnlocked: boolean = false
  @State edgeTtsOn: boolean = false
  /** 标定模式（开发者）开关（2026-09-26 迁入，仅解锁后随组出现） */
  @State calibDevOn: boolean = false

  /**
   * 离开设置页时**兜底清掉震动预览值**（2026-10-25）。
   *
   * 正常路径下松手（`SliderChangeMode.End`）就已经 `clearPreview()` 了；
   * 这里只防极端情况（拖动中页面被销毁 / 手势被打断没收到 End）——
   * 一旦预览值残留，全 App 后续的震动都会用它而不是用户落盘的值。
   */
  aboutToDisappear(): void {
    Haptics.clearPreview()
  }

  aboutToAppear(): void {
    // 冷启动回填：AppStorage 的 setHaptics 初值与 Preferences 对齐
    this.setHaptics = Haptics.isEnabled()
    this.hapticStrength = Haptics.getStrength()
    this.lastStrengthStep = Math.round(this.hapticStrength / Haptics.STRENGTH_STEP)
    this.hapticMode = Haptics.getMode()
    this.lastModeStep = Math.round(this.hapticMode / Haptics.STRENGTH_STEP)
    // 听书引擎开关初值（未解锁恒为关=本地引擎）
    this.edgeTtsOn = ListenUnlock.isUnlocked() && loadTtsPrefs().ttsEngine === 'edge'
    // 标定模式开关初值（2026-09-26 迁入：读 TtsHlCalibV3 的 dev 字段，与阅读页同一存储）
    this.calibDevOn = this.calibDevRead()
    // 书架拓展名开关初值（2026-09-27，默认关=隐藏后缀）
    // ⚠️ 2026-10-19：这一行已从「书架」组并入「功能」组（阅读器信息窗下面）
    //    ⇒ 行状态在下面 rebuildOtherList 之后统一回填（不再有 bookSetList）。
    this.setExtName = PreferencesUtil.getSync('setExtName', false) as boolean
    // 2026-10-19：书架动画速度整项删除 ⇒ 这里不再读写 `shelfAnimSpeed`
    // （AppStorage 里若还留着老值，`EntranceWave.speedMultiplier()` 仍会读到 —— 见下方说明）。
    // 按键翻页开关初值（2026-10-07；**2026-10-19 用户口径：新装默认开启**）
    // Preferences 持久化，订阅调度在 ReaderKeyTurn（`isVolOn()` 的默认值必须同步为 true）。
    // ⚠️ 2026-10-19：智控键翻页整行删除 ⇒ 只剩音量键一项，且它已并入「功能」组
    //    ⇒ 行状态改由 findSetRow 回填（**必须**放在下面 rebuildOtherList 之后）。
    this.setKeyVolTurn = PreferencesUtil.getSync(KEY_KEY_VOL_TURN, true) as boolean
    // 阅读器信息窗开关初值（2026-10-13 起**默认开**；用户要求"信息窗默认打开"）
    // ⚠️ 这里是默认值的**权威单点**，`ReaderPage3.aboutToAppear` 的回读用同一个 true。
    this.setInfoWin = PreferencesUtil.getSync(MySetConstants.SET_INFO_WIN, true) as boolean
    // ── 书架宫格列数（2026-10-23）：从 Preferences 回填到 AppStorage ─────────────
    // ⚠️ 为什么必须在这里做：`BookContent` 用 `@StorageProp('shelfGridColumns')` 订阅，
    //   而 AppStorage 是**内存态**、冷启动为空。若只靠 `setUserColumns()` 写入，
    //   用户设过的列数在重启后就丢了（书架回落自动档）。
    //   这里在设置页打开时补一次回填；`ShelfPrefs.getUserColumns()` 内部已做范围钳制。
    //   （用户不打开设置页也不会错：`BookContent` 的 `@StorageProp` 默认值 0 = 自动档。）
    if (this.gridColumns !== ShelfPrefs.getUserColumns()) {
      this.gridColumns = ShelfPrefs.getUserColumns()
    }
    // ── 离线模式（2026-10-13）：先按落盘意图重建「功能」组 ──────────────────────
    // ⚠️ 必须早于下面 findSetRow 的写回：rebuildOtherList 决定本组渲染哪些行。
    // 顺序：先同步 offlineOn（防 EntryAbility.init 尚未跑到 / 页面被直接拉起），
    // 再 rebuild，最后才回填各行 toggleStatus。
    this.offlineOn = OfflineMode.isOn()
    this.rebuildOtherList()
    // 「信息」组同样要重建一次：构造时 `setGroupList` 里挂的是空的 `infoSetList`，
    // 不重建这一组就整块不渲染（2026-10-19 新增）
    this.rebuildInfoList()
    // 音量键翻页（2026-10-19 迁入「功能」组第一行）：回填行状态
    const volRow: SetList | null = this.findSetRow(MySetConstants.SET_KEY_VOL)
    if (volRow !== null) { volRow.toggleStatus = this.setKeyVolTurn }
    // 显示文件拓展名（2026-10-19 迁入「功能」组第 3 行）：回填行状态
    const extRow: SetList | null = this.findSetRow(MySetConstants.SET_EXT_NAME)
    if (extRow !== null) { extRow.toggleStatus = this.setExtName }
    // 显示系统状态栏（2026-10-19 新增；默认关，读 Preferences 落盘值）
    this.showReaderStatusBar = PreferencesUtil.getSync(MySetConstants.SET_READER_STATUS_BAR, false) as boolean
    const statusBarRow: SetList | null = this.findSetRow(MySetConstants.SET_READER_STATUS_BAR)
    if (statusBarRow !== null) { statusBarRow.toggleStatus = this.showReaderStatusBar }
    // ── 信息窗元素子开关（2026-10-19）：各读各的 Preferences，行状态随之回填 ────
    this.infoWinTimeMode =
      PreferencesUtil.getSync(MySetConstants.SET_INFO_WIN_TIME, 1) as number
    // 电量是三档（老机器里可能还是 boolean ⇒ 用 MySetConstants.infoBatteryMode 归一化）
    this.infoWinBatteryMode = MySetConstants.infoBatteryMode(
      PreferencesUtil.getSync(MySetConstants.SET_INFO_WIN_BATTERY, 1))
    this.infoWinBookmarkShow =
      PreferencesUtil.getSync(MySetConstants.SET_INFO_WIN_BOOKMARK, true) as boolean
    this.infoWinAntiPeepShow =
      PreferencesUtil.getSync(MySetConstants.SET_INFO_WIN_ANTIPEEP, true) as boolean
    this.infoWinTimerShow =
      PreferencesUtil.getSync(MySetConstants.SET_INFO_WIN_TIMER, true) as boolean
    this.syncInfoWinChildRows()
    // （2026-10-21 删除顶栏融合的回填：开关已移除）
    // 离线模式（2026-10-19 移入「关于」组第一行；findSetRow 会同时查两张表）
    const offlineRow: SetList | null = this.findSetRow(MySetConstants.SET_OFFLINE_MODE)
    if (offlineRow !== null) { offlineRow.toggleStatus = this.offlineOn }
    const infoWinRow: SetList | null = this.findSetRow(MySetConstants.SET_INFO_WIN)
    if (infoWinRow !== null) { infoWinRow.toggleStatus = this.setInfoWin }
    // 防窥两层开关初值（2026-10-08）：先让 AntiPeep 复算（写 AppStorage 的**有效值**），
    // 再回填行状态；第 2 层的系统防窥开关是异步对账，稍后由 @StorageLink 自动刷新。
    // ⚠️ 2026-10-13 离线模式：这两行可能已被过滤掉 ⇒ 用 findSetRow + 判空，不再用下标。
    const dlpRow: SetList | null = this.findSetRow(MySetConstants.SET_ANTI_PEEP_DLP)
    const capRow: SetList | null = this.findSetRow(MySetConstants.SET_ANTI_PEEP_CAPTURE)
    if (dlpRow !== null) { dlpRow.vipMark = true }
    if (capRow !== null) { capRow.vipMark = true }
    AntiPeep.refresh()
    this.setAntiPeepDlp = AppStorage.get<boolean>(KEY_ANTI_PEEP_DLP) ?? false
    this.setAntiPeepCapture = AppStorage.get<boolean>(KEY_ANTI_PEEP_CAPTURE) ?? false
    if (dlpRow !== null) { dlpRow.toggleStatus = this.setAntiPeepDlp }
    if (capRow !== null) { capRow.toggleStatus = this.setAntiPeepCapture }
    if (ListenUnlock.isUnlocked()) {
      this.engineSetList = [
        new SetList(false, '使用 Edge TTS 引擎', this.edgeTtsOn, '',
          '联网云端合成，音色更丰富、句级进度更准；关闭=系统本地引擎（离线可用）。仅供学习测试，禁止商用',
          MySetConstants.SET_EDGE_TTS),
        // 标定模式（2026-09-26 从阅读器-设置迁来）：开 = 阅读器-设置里出现几何标定那一套
        new SetList(false, '打开标定模式', this.calibDevOn, '',
          '阅读器-设置里出现首行标定/行高系数等开发者工具（HL 高亮对齐用）',
          MySetConstants.SET_CALIB_DEV)
      ]
      this.setGroupList = this.setGroupList.concat(
        [new SetGroupList('听书引擎（进阶）', this.engineSetList)])
    }
  }

  /**
   * 防窥两行的开关状态跟随 AppStorage 的**有效值**（2026-10-08）。
   * 为什么必须挂 @Watch：第 2 层要异步问系统防窥开关 —— 用户没开、又在系统页里取消，
   * 有效值会回弹为 false，行状态必须跟着回弹；阅读页眼睛图标改的也是同一份有效值。
   */
  private syncAntiPeepRows(): void {
    const dlpRow: SetList | null = this.findSetRow(MySetConstants.SET_ANTI_PEEP_DLP)
    const capRow: SetList | null = this.findSetRow(MySetConstants.SET_ANTI_PEEP_CAPTURE)
    if (dlpRow !== null) { dlpRow.toggleStatus = this.setAntiPeepDlp }
    if (capRow !== null) { capRow.toggleStatus = this.setAntiPeepCapture }
  }

  /**
   * ⚠️ 2026-10-19 删除：`applySmartKeyHint()` 与 `animSpeedLabel()`。
   *   · 前者只服务「智控键翻页」那一行（整行已按用户要求删除）；
   *   · 后者只服务「书架动画速度」滑块的右侧倍率文字（整项已按用户要求删除）。
   *   底层能力未动：`ReaderKeyTurn` 的智控键订阅/探测代码保持原样（只是设置页没有入口了）。
   */

  /**
   * 标定模式（开发者）标志读写 —— 与 `ReaderPage3` 的 `saveCalib()/loadCalib()` 共用
   * 同一个键（`TtsHlCalibV3`，HL_CALIB_KEY），**读改写**保留 topPx/widthRatio 等其他字段。
   * ⚠️ 键为字面量重复（ReaderPage3.ets 的模块常量不跨页导出），改键时两处必须同步。
   */
  private calibDevRead(): boolean {
    try {
      const raw = PreferencesUtil.getSync('TtsHlCalibV3', '') as string
      if (typeof raw !== 'string' || raw.length === 0) {
        return false
      }
      const o = JSON.parse(raw) as Record<string, Object>
      const d = o['dev']
      return typeof d === 'number' && (d as number) > 0
    } catch (e) {
      return false
    }
  }

  private calibDevWrite(v: boolean): void {
    try {
      let o: Record<string, Object> = {}
      const raw = PreferencesUtil.getSync('TtsHlCalibV3', '') as string
      if (typeof raw === 'string' && raw.length > 0) {
        const p = JSON.parse(raw) as Record<string, Object>
        if (p !== null && p !== undefined) {
          o = p
        }
      }
      o['dev'] = v ? 1 : 0
      PreferencesUtil.putSync('TtsHlCalibV3', JSON.stringify(o))
    } catch (e) {
      // 落盘失败不阻断 UI
    }
  }


  // 2026-09-21 精简（用户决定）：
  //  · 「缓存下载」整组删除 —— 4 项里「书籍保存位置」「图片缓存」的 switch 分支本来就是
  //    **空 break**，「预下载」只改一个显示文案、「图片抗锯齿」只翻转一个布尔，全都不落盘、
  //    不影响任何行为；
  //  · 「网络」整组删除 —— 「Web端口」文案写死「当前端口1122」但全工程没有任何服务端实现、
  //    「清除webview数据」「用户代理」的 case 都是空 break；
  //  · 「其他」里的「语言」删除 —— `languageSheet` 只有 4 行不可点的 Text，选完没有任何效果。
  // ── 2026-10-19 删除：「书架」组（`bookSetList`）────────────────────────────────
  // 用户口径："显示文件拓展名放在阅读器信息窗下面。此时音量键翻页、阅读器信息窗、
  // 显示文件拓展名、阅读防窥、防截屏 组成了功能区。"
  // ⇒ 本组唯一一行（显示文件拓展名）已并入「功能」组（见 `otherBaseList`，消费者不变：
  //   `BookInfos.ets:28` 书架显示 + `TtsEngine.ets:3068` 听书标题）。

  // ── 音量键翻页（2026-10-07 新增；2026-10-19 迁入「功能」组第一行、**默认改为开启**）────
  // 仅阅读页存活时订阅生效（官方要求"确定响应时才激活"，否则音量键失灵），
  // 落盘 + 调度全部走 ReaderKeyTurn。
  // ⚠️ 声明位置必须在 `otherBaseList` **之前** —— 下面的行表初始化时会读它。
  // ⚠️ 2026-10-19 默认值对齐（用户口径：音量键翻页新装默认开）：初值 `true`，
  //    与 `aboutToAppear` 的 `getSync(KEY_KEY_VOL_TURN, true)`、`ReaderKeyTurn.isVolOn()` 三方一致。
  @StorageLink(MySetConstants.SET_KEY_VOL) setKeyVolTurn: boolean = true

  /**
   * 「功能」分组的**基础**行表（全量 = 全部渲染；离线 = 滤掉防窥两行）。
   *
   * 行顺序（2026-10-19 用户最终指定）：
   *   音量键翻页 → 显示文件拓展名 → 阅读防窥 → 防截屏/录屏。
   *   · 「音量键翻页」原先在独立的「按键翻页」组（该组已按用户要求删除，
   *     智控键翻页整行一并删除）。
   *   · 「显示文件拓展名」原在独立的「书架」组（该组已删）⇒ 并入本组。
   *   · 「离线模式」已移到「关于」组（`aboutSetList`）。
   *   · **信息窗与「显示系统状态栏」已整体移到新的「信息」组**（`infoBaseList`）——
   *     用户原话：「现有的功能区保留，我们新做一个信息区，在功能区下面…
   *     因为都放在功能区里面，太拥挤了」。
   *
   * ⚠️ 2026-10-13 离线模式：防窥两行会在离线时被滤掉 —— 因此本表的访问一律改用
   *     `findSetRow(storageName)` 按 `storageName` 查找，
   *     **禁止再用 `otherSetList[1]` / `[2]` 这种下标**（过滤后下标整体前移，
   *     会把 toggleStatus 错写到别的行上）。
   */
  private readonly otherBaseList: SetList[] = [
    // 音量键翻页（2026-10-19 从「按键翻页」组迁入，本组第一行）
    new SetList(false,'音量键翻页',this.setKeyVolTurn,'','阅读页内音量上/下键翻页；翻页时临时接管音量调节，退出阅读页即恢复',MySetConstants.SET_KEY_VOL),
    // 显示文件拓展名（2026-10-19 从删掉的「书架」组并入）
    new SetList(false,'显示文件拓展名',this.setExtName,'','书架上书名是否显示 .txt 等后缀',MySetConstants.SET_EXT_NAME),
    // ── 防窥两层（2026-10-08 新增，均 VIP 特权；用户设计：两个独立开关，可只开其一）──
    // 第 2 层默认开（系统能力不足/系统防窥开关未开时自动显示为关，见 AntiPeep）；
    // 第 1 层默认关。阅读页顶栏眼睛图标 = 第 2 层的第二个入口（同键同源）。
    new SetList(false,'阅读防窥',this.setAntiPeepDlp,'','检测到旁人注视屏幕时，用系统蒙层遮住当前窗口（阅读页顶栏眼睛图标同源）',MySetConstants.SET_ANTI_PEEP_DLP),
    new SetList(false,'防截屏/录屏',this.setAntiPeepCapture,'','开启后本应用不可被截屏录屏，退到后台时最近任务卡片也会显示白屏/隐私蒙层',MySetConstants.SET_ANTI_PEEP_CAPTURE),
  ]

  /** 「功能」组**当前渲染**的行（离线时不含防窥两行；由 rebuildOtherList() 重建） */
  @State otherSetList: SetList[] = []

  /**
   * 「信息」分组的**基础**行表（2026-10-19 新增，用户需求）。
   *
   * 用户原话：「现有的功能区保留，我们新做一个信息区，在功能区下面，信息区里面第一条是
   * 显示系统状态栏，然后第二条就是信息窗。…因为都放在功能区里面，太拥挤了」
   * ⇒ 抽成独立一张卡片，位置在「功能」组**下面**、`震动反馈` 组上面。
   *
   * 行顺序：**显示系统状态栏（第 1 条）→ 阅读器信息窗（第 2 条，主开关）→ 5 个元素子项**。
   *   · 子项只在主开关打开时渲染（`isRowVisible` 按 `setInfoWin` 过滤），
   *     标题带「- 」前缀 + 缩进 20vp（层级感），见 `SetListGroup.SetList` 的 indent。
   *   · 「时间显示」「电量显示」是多档值行 ⇒ `hideControl = true`（只右侧值 + 下划线）。
   *   · 电量三档语义：0 = 关 / 1 = 仅图标 / 2 = 图标+百分比（`MySetConstants.infoBatteryMode`）。
   */
  private readonly infoBaseList: SetList[] = [
    // ① 显示系统状态栏（全局、默认关）：阅读页把状态栏设成全透明 ⇒ 露出阅读背景
    new SetList(false,'显示系统状态栏',this.showReaderStatusBar,'','阅读页内显示系统状态栏；状态栏背景与阅读背景融合。开启后信息窗左侧的时间与电量将隐藏',MySetConstants.SET_READER_STATUS_BAR),
    // ② 阅读器信息窗（主开关，默认开）
    // ⚠️ 第 1 个实参是 `showArrow`（见 SetListGroup.ets 构造签名），**不是**开关初值！
    //    传 true 会渲染成箭头 `>` ⇒ 整行变成可点击跳转样式（2026-10-13 用户实测发现）。
    new SetList(false,'阅读器信息窗',this.setInfoWin,'','开启后，全屏阅读时左侧显示当前系统时间，右侧显示书签、定时与防窥的实时信息',MySetConstants.SET_INFO_WIN),
    // ③ 元素子项（主开关打开时才出现）
    new SetList(false,'- 时间显示',false,infoTimeLabel(this.infoWinTimeMode),'',
      MySetConstants.SET_INFO_WIN_TIME, true, true),
    new SetList(false,'- 电量显示',false,infoBatteryLabel(this.infoWinBatteryMode),'',
      MySetConstants.SET_INFO_WIN_BATTERY, true, true),
    new SetList(false,'- 书签显示',this.infoWinBookmarkShow,'','',MySetConstants.SET_INFO_WIN_BOOKMARK, true),
    new SetList(false,'- 防窥显示',this.infoWinAntiPeepShow,'','',MySetConstants.SET_INFO_WIN_ANTIPEEP, true),
    new SetList(false,'- 定时显示',this.infoWinTimerShow,'','',MySetConstants.SET_INFO_WIN_TIMER, true),
    // ── 2026-10-21：曾加过「书架顶栏融合」开关，后按用户口径**删除** ──────────
    // 用户原话：「点击书架顶栏融合开关没用，而且看来也融合不了，索性去掉开关，不融合了。」
    // ⇒ 开关行、`SET_HEADER_MERGED` 常量、`headerMergedOn` 状态、switch 分支全部移除；
    //   书架顶栏固定为**分离式**（两段独立胶囊 + 中间留空隙）。
  ]

  /** 「信息」组**当前渲染**的行（子项随主开关显隐；由 rebuildInfoList() 重建） */
  @State infoSetList: SetList[] = []

  /**
   * 按 storageName 取**任意**一行的对象（行状态回填的**唯一**合法方式）。
   *
   * 查三张**基础表**（始终含全部行，与渲染过滤无关）：
   *   ① `otherBaseList`（「功能」组：音量键翻页 / 显示文件拓展名 / 防窥两层）；
   *   ② `infoBaseList`（「信息」组：显示系统状态栏 / 阅读器信息窗 + 5 个元素子项）；
   *   ③ `aboutSetList`（「关于」组：离线模式 / 关于我们）。
   * ⇒ 即使某行当前没被渲染（如离线时被滤掉的防窥两行、主开关关掉时的信息窗子项），
   *   也能安全写它的 toggleStatus / rightText，不会因过滤而指向错误的行。
   *
   * ⚠️ 三张表是**分开的**（渲染上分属三个 ListItemGroup）⇒ 新增行时必须登记到正确的表，
   *    否则这里查不到（返回 null，调用处已全部判空）。
   */
  private findSetRow(storageName: string): SetList | null {
    for (let i = 0; i < this.otherBaseList.length; i++) {
      if (this.otherBaseList[i].storageName === storageName) {
        return this.otherBaseList[i]
      }
    }
    for (let i = 0; i < this.infoBaseList.length; i++) {
      if (this.infoBaseList[i].storageName === storageName) {
        return this.infoBaseList[i]
      }
    }
    for (let i = 0; i < this.aboutSetList.length; i++) {
      if (this.aboutSetList[i].storageName === storageName) {
        return this.aboutSetList[i]
      }
    }
    return null
  }

  /**
   * 把信息窗 5 个子项的行状态/右侧文案与页面状态对齐（2026-10-19 新增）。
   * 四个布尔子项写 `toggleStatus`；「时间显示」是三档 ⇒ 走 `hideControl` 只显示 `rightText`。
   * 主开关关掉时**只隐藏行、不重置子项值**（用户下次打开还是原样）。
   */
  private syncInfoWinChildRows(): void {
    const tRow: SetList | null = this.findSetRow(MySetConstants.SET_INFO_WIN_TIME)
    if (tRow !== null) { tRow.rightText = infoTimeLabel(this.infoWinTimeMode) }
    const bRow: SetList | null = this.findSetRow(MySetConstants.SET_INFO_WIN_BATTERY)
    if (bRow !== null) { bRow.rightText = infoBatteryLabel(this.infoWinBatteryMode) }
    const bkRow: SetList | null = this.findSetRow(MySetConstants.SET_INFO_WIN_BOOKMARK)
    if (bkRow !== null) { bkRow.toggleStatus = this.infoWinBookmarkShow }
    const apRow: SetList | null = this.findSetRow(MySetConstants.SET_INFO_WIN_ANTIPEEP)
    if (apRow !== null) { apRow.toggleStatus = this.infoWinAntiPeepShow }
    const tmRow: SetList | null = this.findSetRow(MySetConstants.SET_INFO_WIN_TIMER)
    if (tmRow !== null) { tmRow.toggleStatus = this.infoWinTimerShow }
  }

  /**
   * 某一行在当前形态下**是否可见**（2026-10-13 离线模式）。
   *
   * 为什么把判定放在**渲染层**、而不是靠替换数据源：
   *   `SetGroupList` 是普通 class（**没有** `@Observed`，见 `SetListGroup.ets:3`；
   *   只有 `SetList` 有 `@Observed`）。官方原文 —— `arkts-state.md:103`
   *   「对嵌套对象的属性直接赋值**无法被框架观察到**，因此不会触发UI刷新」、
   *   `:110`「数组项中嵌套的属性赋值无法观察」。
   *   ⇒ 只把 `setGroupList` 整体换成新数组时，外层 ForEach 的 key 仍是 `'功能'`（未变），
   *     ArkUI **复用**旧的 ListItemGroup 组件，其内部 `setList` 的替换观察不到
   *     ⇒ 被滤掉的防窥两行**照旧渲染**（真机实测：两行没消失）。
   *   故改为：数据源保持全量，在遍历时跳过不可见行。
   *
   * ── 2026-10-13 方案 A（用户拍板）────────────────────────────────────────
   * 隐藏标准由「看起来高级」改成「**是否真的需要网络**」。防窥两层是**纯系统能力**
   * （`AntiPeep.ets:38-43` 只依赖 DeviceSecurityKit / ArkUI / AbilityKit，无任何网络 Kit）
   * ⇒ 离线可用，且是 VIP 权益 ⇒ 精简模式下**保留可见**，否则等于把这项权益藏起来不卖。
   * 开关见 `OfflineMode.showReadingEnhancements()`（改 false 可一键全部隐藏）。
   */
  private isRowVisible(item: SetList): boolean {
    // ── 信息窗元素子项（2026-10-19 新增）：只在主开关「显示阅读器信息窗」打开时出现 ──
    // 用户口径：「显示阅读器信息窗需要增强，现在他作为主开关，点击之后，下面每行开头空两格，
    // 列出所有元素」。主开关关掉 ⇒ 子项整批收起（值不丢，见 syncInfoWinChildRows 注释）。
    if (MySetPage.isInfoWinChild(item.storageName) && !this.setInfoWin) {
      return false
    }
    if (!this.offlineOn || OfflineMode.showReadingEnhancements()) {
      return true
    }
    // 回退档（showReadingEnhancements() === false）：防窥两层整体不渲染
    return item.storageName !== MySetConstants.SET_ANTI_PEEP_DLP
      && item.storageName !== MySetConstants.SET_ANTI_PEEP_CAPTURE
  }

  /** 某个 storageName 是否属于「信息窗元素子项」（2026-10-19） */
  private static isInfoWinChild(name: string): boolean {
    return name === MySetConstants.SET_INFO_WIN_TIME
      || name === MySetConstants.SET_INFO_WIN_BATTERY
      || name === MySetConstants.SET_INFO_WIN_BOOKMARK
      || name === MySetConstants.SET_INFO_WIN_ANTIPEEP
      || name === MySetConstants.SET_INFO_WIN_TIMER
  }

  /**
   * 某分组在当前形态下**实际可见**的行（供圆角判断用）。
   * 必须用它而不是 `group.setList` —— 后者在离线时仍含被隐藏的行，
   * 会让 `length === 1` / `indexOf === 0` / `length - 1` 三个圆角分支全部算错。
   */
  private visibleRowsOf(group: SetGroupList): SetList[] {
    const out: SetList[] = []
    for (let i = 0; i < group.setList.length; i++) {
      if (this.isRowVisible(group.setList[i])) {
        out.push(group.setList[i])
      }
    }
    return out
  }

  /**
   * 重建「功能」组的渲染表。
   * ⚠️ 2026-10-13 修正：本方法**不再承担"隐藏防窥两行"的职责**（那改由渲染层的
   *    `isRowVisible` 负责，原因见该方法的注释）。这里只做「按基础表刷新一次数组」，
   *    保证 `otherSetList` 与 `otherBaseList` 同步（新增行时不至于漏渲染）。
   *
   *    仍然保留 `setGroupList` 的整体替换：它能让**行数变化**（如以后增删行）被感知，
   *    且对 `SetList` 自身的 `@Observed` 属性刷新没有副作用。
   * ⚠️ 2026-10-19：组名「其他」→「功能」（用户要求改字样并提到正页最顶端），
   *    这里的 groupValue 必须同步改，否则整体替换会**丢掉改名后的那一组**。
   */
  private rebuildOtherList(): void {
    const out: SetList[] = this.otherBaseList.slice()
    this.otherSetList = out
    const nextGroups: SetGroupList[] = []
    for (let i = 0; i < this.setGroupList.length; i++) {
      const g: SetGroupList = this.setGroupList[i]
      nextGroups.push(g.groupValue === '功能' ? new SetGroupList('功能', out) : g)
    }
    this.setGroupList = nextGroups
  }

  /**
   * 离线模式开关一变：重建「功能」组（刷新数组以驱动重渲染）+ 回填本行状态。
   *
   * ⚠️ 2026-10-13 修正：真正让防窥两行消失的是**渲染层的 `isRowVisible`**，
   *    本回调的作用是**触发一次重渲染**（`@Watch` 已由 `offlineOn` 变化触发，
   *    这里再动一次数组是为了确保 `ForEach` 的 itemGenerator 重新执行）。
   */
  private onOfflineModeChanged(): void {
    this.rebuildOtherList()
    const row: SetList | null = this.findSetRow(MySetConstants.SET_OFFLINE_MODE)
    if (row !== null) {
      row.toggleStatus = this.offlineOn
    }
  }

  /**
   * 重建「信息」组的渲染表（2026-10-19 新增）。
   * 用途与 `rebuildOtherList()` 同构：把 `infoSetList` 与 `infoBaseList` 对齐，并整体替换
   * `setGroupList` 里那一组 —— 主开关「阅读器信息窗」一拨，5 个子项要立刻显/隐。
   * ⚠️ 组名 `'信息'` 必须与 `setGroupList` 里的字符串**完全一致**，否则替换会落空。
   */
  private rebuildInfoList(): void {
    const out: SetList[] = this.infoBaseList.slice()
    this.infoSetList = out
    const nextGroups: SetGroupList[] = []
    for (let i = 0; i < this.setGroupList.length; i++) {
      const g: SetGroupList = this.setGroupList[i]
      nextGroups.push(g.groupValue === '信息' ? new SetGroupList('信息', out) : g)
    }
    this.setGroupList = nextGroups
  }

  /** 震动反馈组（2026-09-25 新增）：开关项；强度滑块单独渲染（见 build 末尾的自绘卡片） */
  @State hapticSetList: SetList[]=[
    new SetList(false,'震动反馈',this.setHaptics,'','按键与滑动时的物理震动反馈',MySetConstants.SET_HAPTICS),
  ]

  // ── 2026-10-19 删除：独立的「按键翻页」组（`keyTurnSetList`）──────────────────
  // 用户口径：
  //   · 「智控键翻页直接删除，只保留音量键翻页」⇒ 智控键那一行整行删除
  //     （连同 `setKeyFpTurn` 状态、`SET_KEY_FP` 的点击分支、`applySmartKeyHint()` 置灰逻辑）；
  //   · 「音量键翻页开关放在阅读器信息窗上面」⇒ 音量键翻页已并入「功能」组第一行，
  //     行表在 `otherBaseList`（`SET_KEY_VOL`），状态由 `findSetRow` 回填。
  //   ⚠️ 底层**保留不动**（用户选择）：`ReaderKeyTurn` 里智控键的探测/订阅代码原样存在，
  //      只是设置页不再有任何入口 ⇒ 新用户永远开不起来。

  /** 听书引擎组（2026-09-25 新增）：仅解锁后在 aboutToAppear 里填充并追加到分组列表 */
  @State engineSetList: SetList[]=[]

  /**
   * 「关于」组（2026-10-13 新增）：**从「我的」页迁来的「关于我们」入口**。
   *
   * 用户要求：放设置页**最底部**，且"材质和显示效果以及矩形宽度样式都需要和设置页的其他元素对齐"。
   * ⇒ 做法是**做成一个标准设置组**（SetList + SetListView），而不是自绘一张卡片 ——
   *   这样宽度（外层 `padding 20` + `card_bg`）、圆角（20）、行高、字号（ITEM + CAPTION 副说明）
   *   全部自动继承其它行，只有一套样式。
   *
   * ⚠️ 2026-10-19 用户口径：「离线模式放在关于我们上面，和关于我们放在一个区域」
   *   ⇒ 本表变成两行，顺序 = **离线模式（开关行）→ 关于我们（箭头行）**，
   *     两张行拼成一张卡片（首行上圆角 / 末行下圆角，见 build 里该 ListItemGroup 的圆角分支）。
   *   · 离线模式**从「功能」组搬来**（原在功能组末行）；行状态回填走 `findSetRow`（两张表都查）。
   *   · 本组不参与离线过滤（`isRowVisible` 只作用于「功能」组）⇒ 离线时这一行**必须**仍在，
   *     否则用户没有出口切回全量模式。
   */
  private readonly aboutSetList: SetList[] = [
    // 离线模式开关（2026-10-13 新增；2026-10-19 从「功能」组搬到这里，用户要求放在关于我们上面）
    new SetList(false,'离线模式',this.offlineOn,'',
      '开启后隐藏依赖网络的功能入口（Web服务 / 测试账号 / 防窥 / AI听书 / 字体与材质方案 / 自定义主题）；关闭恢复全量模式',
      MySetConstants.SET_OFFLINE_MODE),
    // 关于我们（showArrow = true ⇒ 箭头行，点击跳 AppRouter.push(RouteName.ABOUT)）
    new SetList(true, '关于我们', false, '',
      '联系我们 / 更新日志 / 隐私协议 / 开源许可', 'aboutUs'),
  ]

  /**
   * 「布局」组（2026-10-21 新增）。
   *
   * 用户原话：「这个新设置没法融入到信息里面去，那就隔开，叫做布局，
   *   我们开一个布局的新区域。」
   *
   * 为什么用一行 `SetList` 作载体：`ListItemGroup` 需要 `setList` 非空才会渲染那一组，
   * 而本组真正的内容是自绘的 `ChipOrderSetting`（见 build 里 `groupValue === '布局'` 分支）。
   * 这一行设 `hideControl: true` ⇒ 只显示标题、不画箭头/Toggle，纯占位。
   */
  @State layoutSetList: SetList[] = [
    // 参数顺序：showArrow, value, toggleStatus, rightText, bottomText,
    //          storageName, indent, hideControl
    new SetList(false, '首页三段按钮排序', false, '', '',
      MySetConstants.SET_CHIP_ORDER, false, true),
  ]

  // 分组顺序（2026-10-19 用户最终形态）：功能 → 信息 → 布局 → 震动反馈
  //   （「听书引擎（进阶）」解锁后 concat 到末尾；「关于」与「登录」在 build 里按固定顺序排在最后）
  //   · 「功能」＝ 音量键翻页 / 显示文件拓展名 / 阅读防窥 / 防截屏录屏；
  //   · 「信息」＝（2026-10-19 用户新增）显示系统状态栏 / 阅读器信息窗 + 5 个元素子项
  //     —— 用户原话「现有的功能区保留，我们新做一个信息区，在功能区下面…太拥挤了」；
  //   · 「布局」＝（2026-10-21 用户新增）首页三段按钮排序（三按钮 + 子气泡选排列）；
  //   · 原「按键翻页」组、「书架」组均已删除；「书架动画速度」滑块整项删除；
  //   · 「离线模式」在「关于」组（`aboutSetList` 第一行）。
  @State setGroupList: SetGroupList[] = [
    new SetGroupList('功能',this.otherSetList),
    new SetGroupList('信息',this.infoSetList),
    new SetGroupList('布局',this.layoutSetList),
    new SetGroupList('震动反馈',this.hapticSetList)
  ]

  // 定义分组设置头部（**说明级** 12 号：小标题不跟条目抢视觉，见 FontConstants 语义阶梯）
  @Builder itemHead(text: string) {
    Text(text)
      .fontSize(FontConstants.CAPTION)
      .fontColor($r('app.color.text_tertiary'))
      .width('100%')
      .padding({left:40,right:40,top:16,bottom:8})
  }


  // ── 测试账号（2026-09-28 迁入）────────────────────────────────────────────
  // 登录从「我的」页下线后，测试账号表单（登录 + 彩蛋解锁双职能）迁到本页顶部。
  private testAccountDialog: CustomDialogController | null = null

  /**
   * 「加入QQ群」按钮的 Q 弹缩放值（2026-10-21 新增）。
   * 按「按钮三件套」规范自驱 `.scale()`，配方与 `webServiceItem` 同款（runJellyClick）。
   */
  @State qqScale: number = 1

  /**
   * 加入喵阅官方 QQ 群（2026-10-21 新增；2026-10-24 改走 `forward/url`）。
   *
   * 三级链路（前一级失败才走下一级）：
   *   ① `startAbility` + `mqqapi://forward/url?...&url_prefix=<base64(官方邀请链接)>`
   *      → QQ 冷/热启动都能直接进群资料页（实测见文件头注释）
   *   ② `openLink(官方邀请链接)` → 系统浏览器打开官方 H5 群资料页（QQ 没装 / scheme 无效时）
   *   ③ 都失败 → 按钮下方常驻的「QQ群号」让用户手动搜
   *
   * ── 为什么 ① 用 `startAbility` 隐式 Want（官方依据）────────────────────────
   *   `开发指南/Ability_Kit_程序框架服务/应用间跳转/拉起指定应用/使用Deep_Linking实现应用间跳转/deep-linking-startup`
   *   原文：「startAbility() 接口是将应用链接放入 Want 中，通过调用隐式 Want 匹配的方法触发应用跳转。」
   *   示例：`let want: Want = { uri: 'link://www.example.com' }; context.startAbility(want)`
   *   ⇒ scheme 由系统在本地已安装应用的 skills.uris 里匹配，命中 `mqqapi` 即拉起 QQ。
   *
   * ── 为什么不再走 `mqqapi://card/show_pslcard`（2026-10-24 换掉）──────────────
   *   冷启动 100% 卡「加载中」且永不恢复（40s 实测），热启动正常。
   *   QQ 日志显示 URL 已被 `JumpService` 消费、群资料 OIDB 也成功返回，是 QQ 侧页面不渲染
   *   ⇒ 我们无法修，只能换成「让 QQ 自己打开官方邀请链接」的 `forward/url`。
   *   详细对照实验与官方 API 调研见本文件头部「喵阅官方 QQ 群」注释块。
   *
   * ── 为什么不再补发（原 1.5s/4s 两档）──────────────────────────────────────
   *   补发是旧通道的绕行手段：晚补发确实能救回，但代价是热启动每次多压一层群页
   *   （用户要多按几次返回），且依赖 QQ 初始化耗时，时序不稳。
   *   换通道后冷启动一次到位 ⇒ 补发整段删除，行为回到「只发一次」。
   *
   * 全部失败只提示、不抛 —— 它只是个可选入口。
   */
  private async openQqGroup(): Promise<void> {
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext
    // ① 让 QQ 自己打开官方邀请链接
    try {
      await ctx.startAbility({ uri: QQ_GROUP_SCHEME })
    } catch (e) {
      const err = e as BusinessError
      // 16000019 No matching ability（QQ 未安装）等 ⇒ 落到第 ② 级
      hilog.info(0x0000, 'MySetPage', `qq forward/url failed, code=${err.code}, try browser`)
      this.openQqGroupInBrowser(ctx)
    }
  }

  /** ② 浏览器兜底：打开 QQ 群邀请页；再失败则提示群号 */
  private openQqGroupInBrowser(ctx: common.UIAbilityContext): void {
    ctx.openLink(QQ_GROUP_URL).catch((err: BusinessError) => {
      hilog.warn(0x0000, 'MySetPage', `qq url failed, code=${err.code}`)
      // ③ 群号兜底（按钮下方常驻，这里只补一句提示）
      this.toast(`打开失败，请手动搜索 QQ群：${QQ_GROUP_CODE}`)
    })
  }

  /** showToast 会抛异常 ⇒ 按本页既有写法包 try/catch（同 `devResetFirstRun`） */
  private toast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message })
    } catch (e) {
      // 提示失败不影响主流程
    }
  }

  /**
   * 开发者入口：重放首启引导弹窗（2026-10-13 新增）。
   *
   * 用户要求「这个模块天然支持一键开关（给我们，也就是开发者保留天然开关）」
   * ⇒ 提供三级开关，这里是最常用的那级（运行期重放）：
   *   ① 编译期总闸 `FirstRunMode.ENABLED = false` ⇒ 全工程永不弹（主开关）；
   *   ② 本方法 `FirstRunMode.debugReset()` ⇒ 抹掉首启标记，**下次冷启**重新弹一次；
   *   ③ 调试期 `FirstRunMode.IGNORE_FLAG_FOR_DEBUG = true` ⇒ 每次冷启都弹。
   *
   * 挂载点：**长按**「离线模式」那一行（`SET_OFFLINE_MODE`）触发，见 `itemOnLongPress`。
   * 为什么用长按而不是新增可见入口：这是开发者能力，不该出现在用户可见的设置列表里。
   */
  private devResetFirstRun(): void {
    Haptics.success()
    FirstRunMode.debugReset()
    const t = FirstRunMode.shouldShow() ? '已重置：下次冷启动会重新弹出首启引导' : '已重置首启标记'
    // showToast 会抛异常 ⇒ 按本页既有写法包 try/catch（同 `onLoginOk` / `onInviteRedeemed`）
    try {
      this.getUIContext().getPromptAction().showToast({ message: t })
    } catch (e) {
      // 提示失败不影响重置本身
    }
  }

  /**
   * 设置行**长按**（开发者暗门，2026-10-13 新增）。
   * 目前只有「离线模式」一行挂了它 —— 用于重放首启引导。
   * 普通点击仍走 `itemOnclick`（保持用户交互不变）。
   */
  itemOnLongPress(value: string): void {
    if (value === MySetConstants.SET_OFFLINE_MODE) {
      this.devResetFirstRun()
    }
  }

  private openTestAccountDialog(): void {
    this.testAccountDialog = new CustomDialogController({
      builder: TestAccountDialog({
        dark: this.nightOn, // 深浅适配（2026-09-28 用户反馈：黑底黑字修复）
        onClose: (): void => {
          this.testAccountDialog?.close()
          this.testAccountDialog = null
        },
        onUnlocked: (): void => {
          // ⚠️ 先 close 再清引用：只置 null 不 close 会留下关不掉的孤儿弹窗
          this.testAccountDialog?.close()
          this.testAccountDialog = null
          this.showUnlockAlert()
        },
        onLoginOk: (): void => {
          this.testAccountDialog?.close()
          this.testAccountDialog = null
          this.getUIContext().getPromptAction().showToast({ message: '登录成功' })
        },
        onInviteRedeemed: (): void => {
          this.testAccountDialog?.close()
          this.testAccountDialog = null
          this.getUIContext().getPromptAction().showToast({ message: '邀请码激活成功，VIP 已解锁！' })
        }
      }),
      autoCancel: true,
      alignment: DialogAlignment.Center,
      width: '88%',
      cornerRadius: 20,
      customStyle: false,
      systemMaterial: ImmersiveMaterialUtil.sheetMaterial(),
      openAnimation: UiMotion.motionParam(UiMotion.SPRING_FAST),
      closeAnimation: UiMotion.motionParam(UiMotion.SPRING_FAST),
      cancel: (): void => {
        this.testAccountDialog = null
      }
    })
    this.testAccountDialog.open()
  }

  /** 彩蛋解锁成功弹窗（原「改名解锁」文案，2026-09-28 随入口迁入） */
  private showUnlockAlert(): void {
    Haptics.success();
    this.getUIContext().showAlertDialog({
      title: '🎉 解锁成功',
      // 免责声明（2026-09-25 用户要求）：解锁面参数明用途边界——学习测试可用、禁商用。
      message: `你已永久解锁隐藏功能！\n「我的-设置」里会出现 Edge TTS 引擎与标定模式开关，阅读界面底部也能看到「听书」按钮。\n\n【免责声明】\n· 本功能（含 Edge TTS 云端合成）仅供个人学习与技术测试；\n· 严禁用于任何商业用途；\n· 音频内容的合规性由使用者自行负责；\n· 本应用与微软、华为无隶属或合作关系。`,
      autoCancel: false,
      confirm: {
        value: '太好了',
        action: () => {
          Haptics.tap();
        }
      }
    })
  }

  build() {
    Column(){
      // 2026-10-01：统一页签头 TabHeader（标题改「设置」；SetHead 自带返回箭头，
      // 页签语境没有返回目标会弹空 Navigation 栈，故弃用）
      TabHeader({ title: '设置' })

      List(){
        ForEach(this.setGroupList,(group:SetGroupList)=>{
          //分组头部
          ListItemGroup({header:this.itemHead(group.groupValue)}){

            if(group.setList){
              ForEach(group.setList,(item:SetList)=>{
                // ⚠️ 2026-10-21：「布局」组**不走通用行渲染**。
                //   该组的 `layoutSetList` 只是一行**占位载体**（ListItemGroup 需要非空才渲染），
                //   真正的内容是下方自绘的 `ChipOrderSetting`。
                //   若这里不跳过，会多渲染一行只有标题的空行（与自绘卡片重复）。
                if (group.groupValue === '布局') {
                  // 空分支：跳过（内容由下方专门分支渲染）
                } else if (!this.isRowVisible(item)) {
                  // ⚠️ 2026-10-13 离线模式：不可见行**在渲染层跳过**。
                  //    为什么不靠"替换数据源"实现：`SetGroupList` 没有 `@Observed`
                  //    （见 `SetListGroup.ets:3`），其内部 `setList` 的替换观察不到 ——
                  //    官方 `arkts-state.md:103/:110` 明写「数组项中嵌套的属性赋值无法观察」，
                  //    且外层 ForEach 的 key（'功能'）不变 ⇒ 组件被复用、不会重读 `setList`。
                  //    真机实测：只替换数组时防窥两行**不消失**。
                  // 空分支：此处不能写 `return`（ArkUI 的 itemGenerator 里 return 会破坏结构）
                } else {
                ListItem(){//设置内容，首尾裁剪
                  // 2026-10-08：单行分组（如删剩一项且无后续自绘滑块的）要**四角全圆**；
                  // 「震动反馈」例外 —— 它下面还接一条自绘滑块行（占下圆角），
                  // 这里必须只给上圆角，否则两块拼不出完整卡片。
                  // ⚠️ 2026-10-19：现在只剩「功能」/「震动反馈」两个分组 ——
                  //    「书架」组已删除（其唯一一行并入「功能」组）⇒ 原先给「书架」的例外随之取消。
                  // ⚠️ 2026-10-13 离线模式：改用 `visibleRowsOf(group)` 判首尾/单行 ——
                  //    直接用 `group.setList` 会把它算成"含被隐藏行"的长度与下标，
                  //    导致离线时圆角画错行。
                  if (this.visibleRowsOf(group).length === 1
                    && group.groupValue !== '震动反馈'){
                    SetListView({setList:item,topLeft:20,topRight:20,bottomLeft:20,bottomRight:20})
                      .onClick(()=>{Haptics.tap(); this.itemOnclick(item.storageName)})
                      .gesture(LongPressGesture().onAction(()=>{ this.itemOnLongPress(item.storageName) }))
                  }else if (this.visibleRowsOf(group).indexOf(item) == 0){
                    SetListView({setList:item,topLeft:20,topRight:20})
                      .onClick(()=>{Haptics.tap(); this.itemOnclick(item.storageName)})
                      .gesture(LongPressGesture().onAction(()=>{ this.itemOnLongPress(item.storageName) }))

                  }else if (this.visibleRowsOf(group).indexOf(item) == this.visibleRowsOf(group).length - 1){
                    SetListView({setList:item,bottomLeft:20,bottomRight:20})
                      .onClick(()=>{Haptics.tap(); this.itemOnclick(item.storageName)})
                      .gesture(LongPressGesture().onAction(()=>{ this.itemOnLongPress(item.storageName) }))
                  }else {
                    SetListView({setList:item})
                      .onClick(()=>{Haptics.tap(); this.itemOnclick(item.storageName)})
                      .gesture(LongPressGesture().onAction(()=>{ this.itemOnLongPress(item.storageName) }))
                  }
                }.padding({left:20,right:20})
                }
              }, (item: SetList): string => item.value)

              // ── 2026-10-19 删除：「书架动画速度」滑块（`group.groupValue === '书架'` 的整块）──
              // 用户口径："直接删除这个选项吧，不要了，这个书架动画速度不要了"
              // ⇒ 连 `shelfAnimSpeed` 的 Preferences / AppStorage 读写一起去掉（见 aboutToAppear 注释）。
              // ⚠️ 书架入场波次本身没动：`EntranceWave.speedMultiplier()` 读不到 AppStorage 键时
              //    回退内置默认档 3（= 0.75x），见 `common/utils/EntranceWave.ets:78`。

              // ── 2026-10-21：首页三段按钮排序已迁到独立的「布局」分组 ──────────────
              // 用户原话：「这个新设置没法融入到信息里面去，那就隔开，叫做布局，
              //   我们开一个布局的新区域。」
              // ⇒ 已从「信息」组移出，见下方 `group.groupValue === '布局'` 分支。

              // ══ 布局组：首页三段按钮排序（2026-10-21 新增）══════════════════════════
              // 用户原话：「…那就隔开，叫做**布局**，我们开一个布局的新区域。」
              //
              // 本组只有这一项，且是**自绘控件**（`ChipOrderSetting`：三按钮 + 子气泡选排列）——
              // `SetList` 只支持"标题 + Toggle/箭头/右文字"，装不下这种交互。
              //
              // 卡片圆角：本组只有一行，所以**四角全圆**（20）。
              // 标题行与控件放在同一张卡片里（`card_bg`），与「震动强度」滑块行同一套视觉语言。
              if (group.groupValue === '布局'){
                // ── 一整张胶囊里装两项（2026-10-23 用户要求合并）────────────────────
                // 用户原话：「这个调节器在布局中和上面的胶囊紧挨着，稍微给点距离，
                //   也比较好看，或者直接融入成一个胶囊，我建议是融入一个胶囊，如果可以的话。」
                // ⇒ 把「首页三段按钮排序」与「一行显示书籍数」放进**同一个 Column / 同一张
                //   card_bg 卡片**，中间用一条 `Divider` 分隔（而不是两个独立卡片贴在一起）。
                //   这样既解决了"紧挨着"的观感问题，也不会出现两条胶囊叠在一起的厚重感。
                ListItem(){
                  Column(){
                    // ① 首页三段按钮排序
                    Column({ space: 12 }){
                      Row(){
                        Text('首页三段按钮排序').fontSize(FontConstants.ITEM)
                        Blank()
                      }.width('100%')
                      ChipOrderSetting()
                    }
                    .width('100%')
                    .padding({ left: 16, right: 16, top: 14, bottom: 14 })

                    // ② 一行显示书籍数（仅手机以外设备；见 `showGridColumnsRow()`）
                    if (this.showGridColumnsRow()){
                      // 分隔线：左右各让 16（与上面内容的左右内边距对齐），不画到卡片边缘
                      Divider()
                        .color($r('app.color.divider'))
                        .margin({ left: 16, right: 16 })
                      Column({ space: 8 }){
                        Row(){
                          Text('一行显示书籍数').fontSize(FontConstants.ITEM)
                          Blank()
                          // 右侧值：手动档显示数字；自动档显示「自动（N）」，
                          // 让用户一眼看出"现在是跟随屏幕"，而不是以为滑块坏了
                          Text(this.gridColumns > 0
                            ? `${this.gridColumns}`
                            : `自动（${this.gridColumnsShown()}）`)
                            .fontSize(FontConstants.CAPTION)
                            .fontColor($r('app.color.text_tertiary'))
                        }.width('100%')
                        Slider({
                          // 自动档时滑块停在"当前实际生效列数"上，
                          // 用户一拖就切到手动档（值即列数）
                          value: this.gridColumnsShown(),
                          min: ShelfPrefs.COLUMNS_MIN,
                          max: ShelfPrefs.COLUMNS_MAX,
                          step: 1,
                          style: SliderStyle.InSet
                        })
                          .width('100%')
                          // 落盘只在松手（End）/点击（Click）时做，避免拖动过程频繁 flush
                          // （与「震动强度」滑块同一口径）
                          .onChange((value: number, mode: SliderChangeMode) => {
                            const n: number = Math.round(value)
                            this.gridColumns = n
                            if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) {
                              ShelfPrefs.setUserColumns(n)
                            }
                          })
                        // 「恢复自动」：不提供的话用户一旦拖过就**再也回不到**跟随屏幕的状态
                        // （滑块最小只能到 2，无法表达"自动"）。
                        if (this.gridColumns > 0) {
                          Row(){
                            Blank()
                            Text('恢复自动')
                              .fontSize(FontConstants.CAPTION)
                              .fontColor($r('app.color.text_tertiary'))
                              .onClick(() => {
                                Haptics.tap()
                                this.gridColumns = 0
                                ShelfPrefs.setUserColumns(0)
                              })
                          }.width('100%')
                        }
                      }
                      .width('100%')
                      .padding({ left: 16, right: 16, top: 14, bottom: 14 })
                    }
                  }
                  .width('100%')
                  .backgroundColor($r('app.color.card_bg'))
                  .borderRadius(20)
                }.padding({left:20,right:20})
              }

              // ── 震动强度滑块行（2026-09-25 新增）──────────────────────────────
              // 用户需求：「0-500 无极调整滑块（每 50 一个档，自由调节震动强度）」。
              // 只有「震动反馈」组有这一行；开关关着时整行禁用 + 变淡。
              // SetListView 只支持 文案+Toggle/箭头，滑块行只能自绘（卡片样式对齐上面各行的
              // `card_bg` + 20 圆角：开关行占上圆角、本行占下圆角，拼成一张完整卡片）。
              if (group.groupValue === '震动反馈'){
                ListItem(){
                  Column({ space: 4 }){
                    Row(){
                      // ⚠️ 2026-10-06 字号统一：本行标题曾写 16，比上面 SetListView 的行标题（14）
                      //   大一号，与「震动反馈」上下相邻 ⇒ 明显不和谐（用户实测反馈）。
                      //   现在取 `FontConstants.ITEM`，右侧当前值同 `SetListView.rightText` 取 12。
                      Text('震动强度').fontSize(FontConstants.ITEM)
                      Blank()
                      Text(`${this.hapticStrength}`)
                        .fontSize(FontConstants.CAPTION)
                        .fontColor($r('app.color.text_tertiary'))
                    }.width('100%')
                    Slider({
                      value: this.hapticStrength,
                      min: 0,
                      max: Haptics.STRENGTH_MAX,
                      step: Haptics.STRENGTH_STEP,
                      style: SliderStyle.InSet
                    })
                      .width('100%')
                      .enabled(this.setHaptics)
                      .opacity(this.setHaptics ? 1 : 0.4)
                      // 滑动时每**跨一档**（50）震一次（Haptics 内部还有 80ms 节流兜底）；
                      // 落盘只在松手（End）/点击（Click）时做，避免拖动过程频繁 flush。
                      //
                      // ⚠️ 2026-10-25 修「拖动时感觉不到强弱变化」（用户反馈）：
                      //   根因是 `Haptics.tick()` 内部读 `getStrength()` → Preferences，
                      //   而 Preferences 只在松手才写 ⇒ 拖动全程都按**旧强度**震。
                      //   ⇒ 现在每帧先把"手指位置的实时值"塞进 `Haptics.setPreview()`，
                      //     试震与文案都按实时值走；松手落盘后 `clearPreview()` 复位。
                      .onChange((value: number, mode: SliderChangeMode) => {
                        this.hapticStrength = Math.round(value)
                        // ① 先同步预览（必须早于 tick，否则这一声还是旧强度）
                        Haptics.setPreview(this.hapticStrength, this.hapticMode)
                        // ② 跨档才震一次（同一档内连续移动不重复震）
                        const step = Math.round(this.hapticStrength / Haptics.STRENGTH_STEP)
                        if (step !== this.lastStrengthStep) {
                          this.lastStrengthStep = step
                          Haptics.tick()
                        }
                        // ③ 松手/点击才落盘，落盘后清预览
                        if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) {
                          PreferencesUtil.putSync(Haptics.KEY_STRENGTH, this.hapticStrength)
                          Haptics.clearPreview()
                        }
                      })

                    Row(){
                      Text('震感模式').fontSize(FontConstants.ITEM)
                      Blank()
                      // ⚠️ 2026-10-25：改用 `modeNameOf(this.hapticMode)` —— 原来的
                      //   `modeName()` 读 Preferences（松手才更新）⇒ 拖动时字样一直不变。
                      //   现在跟随 `@State hapticMode` 实时刷新。
                      Text(`${Haptics.modeNameOf(this.hapticMode)}`)
                        .fontSize(FontConstants.CAPTION)
                        .fontColor($r('app.color.text_tertiary'))
                    }.width('100%')
                    Slider({
                      value: this.hapticMode,
                      min: 0,
                      max: Haptics.STRENGTH_MAX,
                      step: Haptics.STRENGTH_STEP,
                      style: SliderStyle.InSet
                    })
                      .width('100%')
                      .enabled(this.setHaptics)
                      .opacity(this.setHaptics ? 1 : 0.4)
                      // 滑动跨档即以**新模式**试震一次（即时对比手感）；落盘只在松手/点击时
                      // ⚠️ 2026-10-25：同「震动强度」—— 先 `setPreview` 再 `tick`，
                      //   否则试震用的还是落盘里的旧档位（听起来完全一样）。
                      .onChange((value: number, mode: SliderChangeMode) => {
                        this.hapticMode = Math.round(value)
                        Haptics.setPreview(this.hapticStrength, this.hapticMode)
                        const step = Math.round(this.hapticMode / Haptics.STRENGTH_STEP)
                        if (step !== this.lastModeStep) {
                          this.lastModeStep = step
                          Haptics.tick()
                        }
                        if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) {
                          PreferencesUtil.putSync(Haptics.KEY_MODE, this.hapticMode)
                          Haptics.clearPreview()
                        }
                      })
                  }
                  .width('100%')
                  .padding({ left: 20, right: 20, top: 12, bottom: 12 })
                  .backgroundColor(ShelfColors.surface())
                  .backgroundBlurStyle(BlurStyle.COMPONENT_REGULAR, { colorMode: ThemeColorMode.SYSTEM })
                  .borderRadius({ bottomLeft: 20, bottomRight: 20 })
                  .opacity(this.setHaptics ? 1 : 0.55)
                }.padding({left:20,right:20})
              }
            }

          }
        }, (group: SetGroupList): string => group.groupValue)

        // ── 「关于」组（2026-10-13 新增）：从「我的」页迁来的入口 ───────────────────
        // 位置（用户第二次修正）：**在「登录」胶囊之上** —— 「登录」才是整页最下面那一项。
        // 所以「关于」没有进 `setGroupList`（那个数组在登录之前整体渲染，且离线时会重建），
        // 而是在这里按固定顺序单独渲染：…其它设置组 → 关于 → 登录。
        // 对齐说明：用标准 `ListItemGroup` + `SetListView`（与「功能/震动反馈」组同一组件）
        // ⇒ 宽度（外层 padding 20 + surface 底）、圆角 20、材质（backgroundBlurStyle）、
        //    字号（ITEM + CAPTION 副说明）全部与其它元素完全一致，不存在自绘样式。
        //
        // ⚠️ 2026-10-19：本组由**单行**变**两行**（离线模式 → 关于我们，用户要求"放在一个区域"）
        //   ⇒ 不能再写死四角全圆（那会让两行各自都是一张圆角卡片、中间断开）。
        //   改为与上面「功能」组同一套首/中/尾圆角判定：首行只给上圆角、末行只给下圆角。
        //   行数用 `aboutSetList.length`（本组无离线过滤 ⇒ 无需 visibleRowsOf）。
        ListItemGroup({ header: this.itemHead('关于') }) {
          ForEach(this.aboutSetList, (item: SetList, index: number) => {
            ListItem() {
              if (this.aboutSetList.length === 1) {
                SetListView({ setList: item, topLeft: 20, topRight: 20, bottomLeft: 20, bottomRight: 20 })
                  .onClick(() => {
                    Haptics.tap();
                    this.itemOnclick(item.storageName)
                  })
                  .gesture(LongPressGesture().onAction(() => { this.itemOnLongPress(item.storageName) }))
              } else if (index === 0) {
                SetListView({ setList: item, topLeft: 20, topRight: 20 })
                  .onClick(() => {
                    Haptics.tap();
                    this.itemOnclick(item.storageName)
                  })
                  .gesture(LongPressGesture().onAction(() => { this.itemOnLongPress(item.storageName) }))
              } else if (index === this.aboutSetList.length - 1) {
                SetListView({ setList: item, bottomLeft: 20, bottomRight: 20 })
                  .onClick(() => {
                    Haptics.tap();
                    this.itemOnclick(item.storageName)
                  })
                  .gesture(LongPressGesture().onAction(() => { this.itemOnLongPress(item.storageName) }))
              } else {
                SetListView({ setList: item })
                  .onClick(() => {
                    Haptics.tap();
                    this.itemOnclick(item.storageName)
                  })
                  .gesture(LongPressGesture().onAction(() => { this.itemOnLongPress(item.storageName) }))
              }
            }.padding({ left: 20, right: 20 })
          }, (item: SetList) => item.value)
        }

        // ── 测试账号入口（2026-10-01 重设计 → 2026-10-08 用户要求**移到列表最下面**）──
        // 居中胶囊按钮（圆角 + 卡底 + 淡阴影），文案前加 person symbol（SDK 符号表核实）；
        // 放最后一项：随内容滚动，滚到底才出现。底部让位由 List 的 `contentEndOffset` 负责。
        //
        // ⚠️ 2026-10-13 用户口径修正（上架被拒项）：
        //   「只有登录 huaweiceshi 这个账户，登录后这个测试账户按钮才会消失，其他账户或者时机均不消失」
        //   ⇒ 严格按 `loginType === 'test'` 判定（VipManager.loginTest 只认 huaweiceshi/huaweiceshi1234，
        //     写 'test'；彩蛋码走 ListenUnlock **不写登录态**、邀请码只送 VIP 也不写登录态
        //     ⇒ 这两种时机入口**照旧显示**，符合"其他时机不消失"）。
        //   ⚠️ 不能用 `VipManager.isVip()` 当条件 —— 邀请码/购机 IAP 都会置 VIP，会误藏入口。
        //   ⚠️ 2026-10-13 离线模式：再叠加 `!this.offlineOn`（用户要求离线时隐藏测试账号入口）。
        //
        // ── 2026-10-21：本行改**双胶囊**（用户需求）────────────────────────────
        // 「加入QQ群」放「登录」左侧，两个胶囊整体在行内居中（大小不强求一致）。
        //   · 外层的 `!this.offlineOn` 是本行总闸（离线模式整行隐藏，与测试账号同口径）；
        //   · 「登录」仍按 `loginType !== 'test'` 单独判隐 —— 测试账号登录后只藏登录，
        //     QQ群按钮照旧显示（用户口径："其他时机均不消失"）。
        if (!this.offlineOn) {
          ListItem() {
            Column({ space: 10 }) {
              Row({ space: 12 }) {
                // ── 加入QQ群 ──────────────────────────────────────────────────
                // ⚠️ 图标用 `app.media.QQ_blue`（真企鹅 SVG，24×24，fill #188BFF）而不是
                //    `sys.symbol.*`：**系统符号表里没有 QQ/企鹅**（实测 sysResource.js 的
                //    `symbol` 段共 4043 个符号名，按 `qq|penguin|tencent` 检索 0 命中；
                //    只有 `wechat` / `wechat_fill`）⇒ 这是本项目「三件套」中唯一可用
                //    的图标来源，其余两件（Haptics + runJellyClick + clickEffect）照旧齐全。
                Row({ space: 6 }) {
                  Image($r('app.media.QQ_blue'))
                    .width(18)
                    .height(18)
                    .scale({ x: this.qqScale, y: this.qqScale })
                  Text('加入QQ群')
                    .fontSize(FontConstants.VALUE)
                    .fontWeight(FontConstants.W_TITLE)
                    .fontColor($r('app.color.text_primary'))
                }
                .padding({ left: 20, right: 20, top: 12, bottom: 12 })
                .borderRadius(22)
                .backgroundColor($r('app.color.card_bg'))
                .shadow({ radius: 12, color: 'rgba(0, 0, 0, 0.06)', offsetX: 0, offsetY: 4 })
                .clickEffect(UiMotion.CLICK)
                .onClick(() => {
                  Haptics.tap()
                  runJellyClick((v: number): void => { this.qqScale = v })
                  this.openQqGroup()
                })

                // ── 登录（测试账号入口，条件同 2026-10-13 口径）────────────────
                if (this.loginType !== 'test') {
                  Row({ space: 8 }) {
                    SymbolGlyph($r('sys.symbol.person'))
                      .fontSize(18)
                      .fontColor([this.theme.mainColor])
                    Text('登录')
                      .fontSize(FontConstants.ITEM)
                      .fontWeight(FontConstants.W_TITLE)
                      .fontColor($r('app.color.text_primary'))
                  }
                  .padding({ left: 28, right: 28, top: 12, bottom: 12 })
                  .borderRadius(22)
                  .backgroundColor($r('app.color.card_bg'))
                  .shadow({ radius: 12, color: 'rgba(0, 0, 0, 0.06)', offsetX: 0, offsetY: 4 })
                  .clickEffect(UiMotion.CLICK)
                  .onClick(() => {
                    Haptics.tap();
                    this.openTestAccountDialog()
                  })
                }
              }
              .width('100%')
              .justifyContent(FlexAlign.Center)

              // ── QQ群号（2026-10-21 用户要求）────────────────────────────────
              // 兜底：跳转失败（没装 QQ / 无网 / 链接过期）时，用户至少能手动搜索加群。
              Text(`QQ群号：${QQ_GROUP_CODE}`)
                .fontSize(FontConstants.CAPTION)
                .fontColor($r('app.color.text_tertiary'))
            }
          }
          .width('100%')
          .padding({ top: 16, bottom: 4 })
        }

      }.width('100%')
      .height('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      // 底部 dock 让位（2026-10-01）：最后一个设置组/测试账号滚到底要停在悬浮 dock 之上。
      // ⚠️ 这里已经含 `bottomRectHeight`（手势区实测值）——见 `dockContentEndOffset()`，
      //    所以**根 Column 不能再垫一次底部 padding**（否则底部多出一条没有内容、只有底色的
      //    空白带，真机表现为手势条区域"白条 + 蒙版"）。2026-10-08 修正。
      .contentEndOffset(ImmersiveMaterialUtil.dockContentEndOffset(this.bottomRectHeight))
    }
    // 顶部照旧避让状态栏；**底部不再留 padding** —— 底色一路铺到屏幕最底（与书架页/主题页
    // 同款「直接贯穿」），手势/导航条区域的让位交给上面 List 的 contentEndOffset。
    // ⚠️ 依据：同页签的 `MyThemeConfig.ets:90-97` 就是同款结构，其注释记着同一类反馈
    //    （「主题格子下面还有个白色蒙版 ⇒ 去掉卡片底色，背景一色」）。
    .padding({ top: this.topRectHeight })
    .height('100%')
    .width('100%')
    .linearGradient({
      direction: GradientDirection.Bottom,
      colors: [[ShelfColors.gradientStart(this.theme.mainColor), 0],
        [ShelfColors.gradientEnd(this.theme.secondColor), 0.2]]
    })
  }



  // `preDowSheet()`（预下载）与 `languageSheet()`（语言）两个半模态已于 2026-09-21 删除 ——
  // 它们服务的两个设置项都已移除。顺带记一笔原实现的问题：
  // 「语言」半模态里只有 4 行**不可点击**的 `Text`，选完没有任何效果；
  // 「预下载」只把数字写进一个 `@State` 和一处显示文案，全工程无人消费。

  /**
   * 设置列表点击事件
   * @param value
   */
  itemOnclick(value:string){
    // 全局震动方案（2026-09-25）：每个设置项点击都给一次反馈。
    // 顺序说明：先 tap 再翻转 —— 关闭震动反馈时还能感受到"最后一下"。
    Haptics.tap();
    switch (value){
      // ── 关于我们（2026-10-13 新增）─────────────────────────────────────────
      // 从「我的」页迁来的入口（用户要求放设置页最底部）。行是 showArrow 型（非开关），
      // 所以在 `setGroupList` 里以标准 SetList 注册、这里只负责跳转。
      case 'aboutUs':
        AppRouter.push(RouteName.ABOUT)
        break;
      // 2026-10-08：`SET_REFRESH / SET_JUMP / SET_REPLACE / SET_TIP / SET_HEAD / SET_SEARCH`
      // 六个 case 已随假开关一起删除（全仓零消费点，理由见本文件 `otherBaseList` 上方的注释）。
      // ── 离线模式（2026-10-13 新增；2026-10-19 行移到「关于」组）────────────────
      // 落盘 + 广播：OfflineMode.set 写 Preferences 与 AppStorage 同键，
      // 本页的 @StorageLink(offlineOn) 随之触发 onOfflineModeChanged() 重建「功能」组
      // （防窥两行是否渲染由 `isRowVisible` 决定；本行自己在「关于」组，不受影响）。
      // ⚠️ 与首启引导弹窗（`componets/common/FirstRunModeDialog.ets`）**同一入口**
      //    ⇒ 两处天然同步（首启选的模式 = 这里显示的开关状态），不存在两份状态互相覆盖。
      case MySetConstants.SET_OFFLINE_MODE:
        OfflineMode.set(!this.offlineOn)
        break;
      case MySetConstants.SET_INFO_WIN:
        // 阅读器信息窗（2026-10-07）：Preferences 持久化；阅读页进场时读一次，
        // 开关只在设置页改 ⇒ 无需跨页广播。
        // ⚠️ 2026-10-13：改用 findSetRow（离线时下标会前移，原来写死的 [0] 会错位）。
        this.setInfoWin = !this.setInfoWin
        const infoRow: SetList | null = this.findSetRow(MySetConstants.SET_INFO_WIN)
        if (infoRow !== null) { infoRow.toggleStatus = this.setInfoWin }
        PreferencesUtil.putSync(MySetConstants.SET_INFO_WIN, this.setInfoWin)
        // 2026-10-19：本行现在是**主开关** —— 一开一关要连带 5 个元素子项的显隐 ⇒
        //   重建「信息」组数组（`isRowVisible` 按 setInfoWin 过滤子项）。
        //   ⚠️ 主开关自己也在「信息」组里（不是「功能」组），所以重建的是 info 那一组。
        this.rebuildInfoList()
        break;
      // ── 信息窗元素子项（2026-10-19 新增）────────────────────────────────────
      // 四个布尔 + 一个三档；均为全局 Preferences，阅读页进场各读一次。
      case MySetConstants.SET_INFO_WIN_TIME: {
        // 三档循环：关(0) → 时:分(1) → 时:分:秒(2) → 关 …
        this.infoWinTimeMode = (this.infoWinTimeMode + 1) % 3
        PreferencesUtil.putSync(MySetConstants.SET_INFO_WIN_TIME, this.infoWinTimeMode)
        const timeRow: SetList | null = this.findSetRow(MySetConstants.SET_INFO_WIN_TIME)
        if (timeRow !== null) { timeRow.rightText = infoTimeLabel(this.infoWinTimeMode) }
        break;
      }
      case MySetConstants.SET_INFO_WIN_BATTERY:
        // 三档循环（环序固定：图标+百分比(2) → 关闭(0) → 仅图标(1) → 图标+百分比 …
        // 即 `(mode + 1) % 3`）。用户原话：「点击依次是图标+百分比，图标，关闭」。
        // ⚠️ 默认档由用户 2026-10-19 定稿为 **1 = 仅图标**，所以从默认值点一下是"图标+百分比"。
        this.infoWinBatteryMode = (this.infoWinBatteryMode + 1) % 3
        PreferencesUtil.putSync(MySetConstants.SET_INFO_WIN_BATTERY, this.infoWinBatteryMode)
        this.syncInfoWinChildRows()
        break;
      case MySetConstants.SET_INFO_WIN_BOOKMARK:
        this.infoWinBookmarkShow = !this.infoWinBookmarkShow
        PreferencesUtil.putSync(MySetConstants.SET_INFO_WIN_BOOKMARK, this.infoWinBookmarkShow)
        this.syncInfoWinChildRows()
        break;
      case MySetConstants.SET_INFO_WIN_ANTIPEEP:
        this.infoWinAntiPeepShow = !this.infoWinAntiPeepShow
        PreferencesUtil.putSync(MySetConstants.SET_INFO_WIN_ANTIPEEP, this.infoWinAntiPeepShow)
        this.syncInfoWinChildRows()
        break;
      case MySetConstants.SET_INFO_WIN_TIMER:
        this.infoWinTimerShow = !this.infoWinTimerShow
        PreferencesUtil.putSync(MySetConstants.SET_INFO_WIN_TIMER, this.infoWinTimerShow)
        this.syncInfoWinChildRows()
        break;
      // （2026-10-21 删除 `SET_HEADER_MERGED` 分支：融合开关已移除）
      // ── 防窥两层（2026-10-08，VIP 特权）────────────────────────────────────
      // 非 VIP：开关不动，弹 VIP 弹窗并记下待办；开通成功后 onClose 里补开（用户第 4 点）。
      // 已开通：把**目标值**下发给 AntiPeep（第 2 层由它异步对账系统防窥开关）。
      //
      // ⚠️ 2026-10-13 修（上架被拒项 ③「首次拉起授权窗没点，之后点不开」）：
      //   旧写法 `AntiPeep.setDlp(!this.setAntiPeepDlp)` 依赖**有效值**取反。
      //   第 2 层的有效值在系统防窥开关没开时恒为 false（AntiPeep.ets 的 @StorageLink 回写）
      //   ⇒ 用户首次点击拉起系统页、没点就返回 ⇒ 有效值仍是 false ⇒ 再点还是 `!false = true`
      //   ⇒ 每次都**重新拉起系统页**，连点几次就是连着弹几次，观感就是"点了没反应/点不开"。
      //   改成显式意图：点「开」走可重入的 `requestDlpOn()`（保证带引导 + 去重）；
      //   点「关」才走 `setDlp(false)`。判定依据用**意图**（Preferences）而非有效值。
      case MySetConstants.SET_ANTI_PEEP_DLP: {
        if (!VipManager.isVip()) {
          this.pendingAntiPeep = KEY_ANTI_PEEP_DLP
          this.openVip()
          break
        }
        if (this.setAntiPeepDlp) {
          AntiPeep.setDlp(false)
        } else {
          AntiPeep.requestDlpOn()
        }
        break
      }
      case MySetConstants.SET_ANTI_PEEP_CAPTURE: {
        if (!VipManager.isVip()) {
          this.pendingAntiPeep = KEY_ANTI_PEEP_CAPTURE
          this.openVip()
          break
        }
        AntiPeep.setCapture(!this.setAntiPeepCapture)
        break
      }
      case MySetConstants.SET_HAPTICS:
        this.setHaptics = !this.setHaptics
        this.hapticSetList[0].toggleStatus = this.setHaptics;
        // 真正落盘（旧 SET_* 键不落盘是历史现状，震动开关必须跨启动生效）
        PreferencesUtil.putSync(Haptics.KEY_ENABLED, this.setHaptics)
        break;
      case MySetConstants.SET_EDGE_TTS:
        // 听书引擎切换（仅解锁后可见；TtsEngine.activeEngineId() 另有解锁二次校验）。
        // 立即落盘；正在播放的句子播完后，下一块合成即走新引擎（缓存键含引擎名，互不污染）。
        this.edgeTtsOn = !this.edgeTtsOn
        this.engineSetList[0].toggleStatus = this.edgeTtsOn
        const prefs = loadTtsPrefs()
        prefs.ttsEngine = this.edgeTtsOn ? 'edge' : 'local'
        saveTtsPrefs(prefs)
        break;
      case MySetConstants.SET_KEY_VOL:
        // 音量键翻页（2026-10-07）：落盘 + 立即对账订阅（阅读页不在时 refresh 只记账不订阅）
        // ⚠️ 2026-10-19：本行已并入「功能」组 ⇒ 行状态改用 findSetRow（不再用 keyTurnSetList[0]）。
        this.setKeyVolTurn = !this.setKeyVolTurn
        const volRow: SetList | null = this.findSetRow(MySetConstants.SET_KEY_VOL)
        if (volRow !== null) { volRow.toggleStatus = this.setKeyVolTurn }
        PreferencesUtil.putSync(KEY_KEY_VOL_TURN, this.setKeyVolTurn)
        ReaderKeyTurn.refresh()
        break;
      // ── 2026-10-19 删除 case MySetConstants.SET_KEY_FP ────────────────────────
      // 「智控键翻页」整行已按用户要求删除（只保留音量键翻页）⇒ 本页不再有任何行会点到
      // 这个分支。底层 `ReaderKeyTurn` 的智控键逻辑按用户选择**保留**（无入口 ⇒ 不可达）。
      case MySetConstants.SET_EXT_NAME:
        // 书架书名拓展名（2026-09-27）：AppStorage（@StorageLink）即时驱动书架刷新，
        // Preferences 持久化跨启动（aboutToAppear 回读）。
        // ⚠️ 2026-10-19：本行已并入「功能」组 ⇒ 行状态改用 findSetRow（原来按下标 [0] 取 bookSetList）。
        this.setExtName = !this.setExtName
        const extRow: SetList | null = this.findSetRow(MySetConstants.SET_EXT_NAME)
        if (extRow !== null) { extRow.toggleStatus = this.setExtName }
        PreferencesUtil.putSync('setExtName', this.setExtName)
        // ★ 2026-10-12：**开关一变就强制刷新听书迷你栏的书名**。
        //   背景：`ListenSession.begin()` 只在起播那一刻算过一次显示名，
        //   听书进行中去设置页拨开关时，`listenTitle` 不会自己重算 ⇒ 用户看到旧文件名。
        //   `refreshTitle()` 从 `listenTitleRaw`（始终带拓展名的原始书名）重算并写回
        //   `listenTitle`，`ListenTitleBar` 的 @StorageLink 随即重绘。
        //   ⚠️ 必须传**刚落盘的新值**，不能让它自己再读一次 Preferences
        //   （putSync 与 getSync 之间存在时序窗口，读到的可能还是旧值）。
        ListenSession.refreshTitle(this.setExtName)
        break;
      case MySetConstants.SET_READER_STATUS_BAR:
        // 显示系统状态栏（2026-10-19 新增）：全局开关，Preferences 持久化；
        // 阅读页进场读一次（与「阅读器信息窗」同款：不需要跨页实时广播）。
        this.showReaderStatusBar = !this.showReaderStatusBar
        const statusBarRow: SetList | null = this.findSetRow(MySetConstants.SET_READER_STATUS_BAR)
        if (statusBarRow !== null) { statusBarRow.toggleStatus = this.showReaderStatusBar }
        PreferencesUtil.putSync(MySetConstants.SET_READER_STATUS_BAR, this.showReaderStatusBar)
        break;
      case MySetConstants.SET_CALIB_DEV:
        // 标定模式（2026-09-26 从阅读器-设置迁来）：写 TtsHlCalibV3 的 dev 字段，
        // 阅读页 loadCalib 打开时照读 ⇒ 开 = 阅读器-设置出现标定功能区。
        // 2026-10-10 改造：走 CalibMode 工具类，同时同步广播 AppStorage('devMode')，
        // 书架/我的/PlugboardZone 订阅后即可画经纬线 + 红边。
        this.calibDevOn = !this.calibDevOn
        this.engineSetList[1].toggleStatus = this.calibDevOn
        CalibMode.setOn(this.calibDevOn)
        break;
    }
  }

  /** 「VIP 购买」弹窗（2026-10-08 新增；范式抄 MyThemeConfigComp.openVip） */
  private openVip(): void {
    this.vipDialog = new CustomDialogController({
      builder: VipDialog({
        dark: NightMode.isDarkSurface(),
        vipOwned: VipManager.isVip(),
        onClose: (): void => {
          this.vipDialog?.close()
          this.vipDialog = null
          // VipDialog 没有"成功回调"语义 ⇒ 关窗后查一次事实源（IAP 写缓存位），
          // 买成了就把用户刚才点的那一层补开（用户 2026-10-08 第 4 点要求）。
          this.applyPendingAntiPeep()
        }
      }),
      autoCancel: true,
      alignment: DialogAlignment.Center,
      width: '88%',
      cornerRadius: 20,
      customStyle: false,
      systemMaterial: ImmersiveMaterialUtil.sheetMaterial(),
      openAnimation: UiMotion.motionParam(UiMotion.SPRING_FAST),
      closeAnimation: UiMotion.motionParam(UiMotion.SPRING_FAST),
      cancel: (): void => {
        this.vipDialog = null
      }
    })
    this.vipDialog?.open()
  }

  /** VIP 开通成功后补开用户刚点的那一层（未开通 / 用户取消 = 什么都不做） */
  private applyPendingAntiPeep(): void {
    const p: string = this.pendingAntiPeep
    this.pendingAntiPeep = ''
    if (p.length === 0 || !VipManager.isVip()) {
      return
    }
    if (p === KEY_ANTI_PEEP_DLP) {
      // 2026-10-13：这里也是"用户主动要开"，必须走带引导的可重入路径
      // （旧 `setDlp(true)` 同样会在系统页被返回后陷入"每次点都重弹"）
      AntiPeep.requestDlpOn()
    } else {
      AntiPeep.setCapture(true)
    }
  }
}
