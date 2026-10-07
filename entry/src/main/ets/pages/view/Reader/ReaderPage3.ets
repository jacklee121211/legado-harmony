import { display, router, LengthMetrics,
  CapsuleSegmentButtonV2, SegmentButtonV2Items, SegmentButtonV2ItemOptions } from '@kit.ArkUI';
// 2026-09-21 精简：以下三个 import 随其唯一使用处（底栏「换源/净化」注释块
// 与不可达的 `sourceView()`/`purificationView()`/`LayoutMoreDialog()` builder）一并移除。
import { bookParser, readerCore, ReadPageComponent } from '@kit.ReaderKit';
import { common, ConfigurationConstant } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError, emitter } from '@kit.BasicServicesKit';
import { fileIo as fs, fileUri } from '@kit.CoreFileKit';
import { ClickUtil, PreferencesUtil } from '@pura/harmony-utils';
import { Books } from '../../../database/entities/Books';
import { WindowAbility } from '../../../entryability/WindowAbility';
import { SleepTimerDialog } from './SleepTimerDialog'
// 目录 / 书签弹窗（2026-09-23 从 `bindSheet` 迁出成 @CustomDialog，理由见该文件头注释）
import { ReaderCatalogDialog } from './ReaderCatalogDialog'
// 听书面板（2026-09-23 从 `bindSheet` 迁出成 @CustomDialog，理由见该文件头注释）
import { ReaderListenDialog, LISTEN_DIALOG_BOTTOM_GAP } from './ReaderListenDialog'
import { ReaderSettingDialog, SETTING_DIALOG_BOTTOM_GAP } from './ReaderSettingDialog'
// 「保存此颜色方案」确认弹窗（2026-09-26 新增；配方与睡眠定时弹窗同款）
import { ReaderSaveSchemeDialog } from './ReaderSaveSchemeDialog'
import { showMessage } from '../../../componets/common/promptShow'
import BasicDataSource from '../../../common/LazyIDataSource/BasicDataSource';
import BrightnessUtil from '../../../../common/utils/BrightnessUtil';
import { TtsEngine, TtsState, TtsSegmentPos } from '../../../tts/TtsEngine';
import BookmarksDao, { BookmarkRow } from '../../../database/dao/BookmarksDao';
// 双端同步 v2（2026-10-05）：槽/水位/键名的唯一登记处（见 SyncConfig 头注释 + 设计文档）
import syncConfig, { SyncPos, SYNC_V2_ENABLED, ratioToIndex, normEx, excerptKey } from '../../../common/utils/SyncConfig';
import BooksDao from '../../../database/dao/BooksDao';
import CommonConstants from '../../../common/constants/CommonConstants';
import { TtsPrefs, loadTtsPrefs } from '../../../tts/TtsPrefs';
import ImmersiveMaterialUtil, { MaterialColumnModifier } from '../../../common/utils/ImmersiveMaterialUtil';
import AppRouter, { ReaderRouteParam } from '../../../common/router/AppRouter';
import UiMotion, { runJellyClick } from '../../../common/utils/UiMotion';
import { NightMode } from '../../../common/utils/NightMode';
import { TtsControlPanel } from '../../../components/tts/TtsControlPanel';
// ── 自定义背景色（2026-09-25 新增）─────────────────────────────────────────────
// `ReaderCustomBg`：色彩数学 + 按书/全局持久化（文件头有"背景色是渲染还是图片"的取证）；
// `ReaderBgPalette`：无极调色盘组件（纯 UI + 取色回调，不碰持久化）；
// `HapticTick`：滑条/调色盘的线性震动（与听书面板同源的已验证实现）。
import { ReaderCustomBg, ReaderBgRecord, SchemeV3,
  BG_BLUR_TIERS, BG_BLUR_RADIUS_DEFAULT } from '../../../common/utils/ReaderCustomBg';
import { ReaderTexture, ComposeResult } from '../../../common/utils/ReaderTexture';
import { ReaderTextureDialog } from './ReaderTextureDialog';
import { ReaderFontLib } from '../../../common/utils/ReaderFontLib';
import { ReaderFontDialog } from './ReaderFontDialog';
import { ReaderSchemeDialog } from './ReaderSchemeDialog';
// ── 按键翻页（2026-10-07）：音量键/智控键翻页，开关在 设置-按键翻页 ──────────
import { ReaderKeyTurn } from '../../../common/utils/ReaderKeyTurn';
// ── 防窥保护（2026-10-07）：顶栏眼睛图标开关，方案见 utils/AntiPeep.ets ───────
import { AntiPeep } from '../../../common/utils/AntiPeep';
// ── 会员化（2026-09-28）：免费用户点锁定功能 → VIP 弹窗 ─────────────────────
import { VipDialog } from '../../../componets/myCenter/VipDialog';
import { VipManager } from '../../../common/utils/VipManager';
import { ReaderBgPalette } from './ReaderBgPalette';
import { HapticTick } from '../../../common/utils/HapticTick';
// ── 全局震动反馈 + 听书入口解锁（2026-09-25 新增）─────────────────────────────
import { Haptics } from '../../../common/utils/Haptics';
import MySetConstants from '../../../common/constants/MySetConstants';
import { ListenUnlock } from '../../../common/utils/ListenUnlock';

interface ParamsObj {
  bookData: Books,
  clickBookCatalogId: number,
  /**
   * 桌面快捷方式「快速听书」带过来的标记（`pages/Index.ets` 的 `openLastReadBook()` 传入）。
   * `true` ⇒ 进入本页后自动开始朗读；`false`/缺省 ⇒ 只阅读（「快速阅读」或正常点书进来）。
   */
  quickListen?: boolean,
  /**
   * 「我的 → 书签」二级菜单点某条书签时带过来的**回跳目标**（2026-09-21 新增）。
   * `bmChapterIndex` = 书签的**目录号**（`bookmarks.chapterIndex`），
   * `bmNode` = 书签的**页首块节点号**（`bookmarks.chapterPos`）。
   * 缺省（undefined）⇒ 不跳转，按书籍自身进度打开。
   */
  bmChapterIndex?: number,
  bmNode?: number,
}

interface themeItem {
  fontColor: string,
  themeColor: string,
  themeBgImg: string,
  /**
   * `true` = 这一格是用户「保存方案」存下来的颜色（2026-09-26 新增），
   * `false` = 内置推荐色。
   * 只有前者会在**自定义开关打开时**显示右上角的小 X（可删除），
   * 开关关着时两者外观完全一致（用户原话：「不开自定义的时候与背景默认的背景无二」）。
   */
  saved: boolean,
  /**
   * 材质格专用（2026-09-25 新增）：非空 = 这一格是**材质**而非纯色，
   * `texId` 对应 `ReaderTexture` 的三位编号，预览图用 `texFile`（rawfile 名）居中裁切显示。
   * 纯色格不写这两个字段（undefined）。
   */
  texId?: number,
  texFile?: string,
  /** 自定义背景格专用（2026-09-27）：非空 = 这一格是用户导入的图片背景 */
  customId?: string,
  customPath?: string,
}

/** ReaderKit 一页的内容范围（ReaderKit 坐标：node 为 0 基块节点号，即 domPos 的 X-1） */
interface PageRange {
  spine: number;
  startNode: number;
  startChar: number;
  endNode: number;
  endChar: number;
}

/** 定位目标（ReaderKit 坐标） */
interface LocateTarget {
  spine: number;
  node: number;
  char: number;
  /** true = 自动跟随（不弹 toast） */
  silent: boolean;
  /**
   * true = **禁止"逐页逼近"兜底**（2026-09-21 新增）。
   *
   * 背景（真机反馈）：「我的 → 书签」点一条书签跳到阅读页后，**界面点不动、像有蒙版**。
   * 根因就是本文件的定位兜底：`startPlay` 没落到位时会走 `beginSearch` / `stepSearch`
   * **逐页翻页逼近**，上限 `s.flips >= 60`（最多连续重排 60 页）。这段时间里阅读器一直在
   * 重新分页，用户看到的就是"完全没反应"。
   *
   * 书签里存的 `chapterPos` 是**当时那一页的块节点号**，一旦与当前排版不符（旧书签尤其如此），
   * 就必然触发这条兜底 ⇒ 必须给它一个"宁可不准、也不要卡住"的档位。
   * 置 true 后：落不到目标就**停在当前章**（`finishLocate(target, false)`），不再翻页搜索。
   */
  noFallback?: boolean;
}

/** 翻页搜索兜底：startPlay 未把我们送到目标时，按 (节点,字符) 双坐标逐页逼近 */
interface FlipSearch {
  target: LocateTarget;
  dir: number;      // 1=向后翻 -1=向前翻
  flips: number;    // 已翻页数（上限保护）
  fixes: number;    // 已换向校正次数（上限保护）
  lastNode: number; // 最近一次 pageShow 的页首块节点号（去重防过期数据）
  lastChar: number; // 最近一次 pageShow 的页内字符偏移
}

/**
 * —— ReaderKit domPos 的 X 语义（真机日志 + 原书离线反推，已确证）——
 *
 * domPos 形如 "19=0#43;@;0"  →  X = 子节点索引(1 起)，Y = 节点内字符下标。
 * 对 TXT 书（神墓.txt）逐页观测：页首页尾的 X 全是奇数，且每段推进 2：
 *     1, 11, 17, 25, 31, 39, 47, 55, 63, 71, 81, 93, 101, 111 …
 * 同一章：我们模型 65 个可读段 → 该章观测到 maxDomX = 129 = 2×65 − 1。
 * 结论：**第 k 个渲染块（1 起）的 X = 2k − 1**；偶数 X 是不渲染的块间空节点。
 * （早先日志里"39 → 41 断号"就是这个偶数空节点，并非真的缺段。）
 *
 * 所以 node 与 X 的换算必须成对使用：node = (X−1)/2，X = 2·node + 1。
 */

/**
 * —— 朗读高亮叠加层几何参数 ——
 *
 * 【真机实测结论·2026-09-18】用隐藏 Text 把本页正文交给 ArkUI 排版后，
 * getLayoutManager().getLineMetrics(i) 直接给出了每行的真实度量（px）：
 *     行0(startIndex 0→16)  left=121.5  width=972.0   height=147
 *     行1(startIndex 16→34) left=0      width=1093.5  height=147
 *     行2(startIndex 34→52) left=0      width=1093.5  height=147
 *     行3(startIndex 52→60) left=0      width=486.0   height=147
 * 由此解出（不需要再猜）：
 *  · 字宽 = 972/16 = 60.75px ≈ **1em**（= fontSize×scaledDensity = 18×3.38 = 60.84）
 *    ⇒ 每行位数 = floor(文本宽 / 1em)，与字号严格成反比；
 *  · 文本宽 1137px 时：整行 **18 字**（19 字需 1156px 装不下），段首行因缩进只放 16 字；
 *  · 段首缩进 = **121.5px = 2em = 2 个字位** ✓
 *  · 整行 18 字 与 字号40 截图实测"整行 8 字" 完全自洽（1137/135 = 8.42 → 8）✓
 *  ⇒ 之前的 0.97 是多余的修正，正确值是 **1.0**；之前 cpl 算成 19 正是"对不齐"的根源
 *    （每段多算/少算 1 行，沿页面累积）。
 *
 * 【渲染管线】ReaderKit 的 ReadPageComponent 是原生组件：它用自己的排版引擎把整页
 * **栅格化成纹理**，再由渲染服务（OpenGL/RsSurface）贴出来，并按页缓存
 * （dataId 形如 readerDataId_<spine>_<页>__<全局页>，翻页只是换纹理）。
 * 所以：正文不是 ArkUI 文本节点、无法改字形，只能"叠加"；位置精度只能靠测量。
 *
 * 单位（鸿蒙 / ArkUI 的差别）：
 *  · ReaderKit 的 viewPortWidth / fontSize 是 **px**；ArkUI 的 position/width/height 是 **vp**
 *    ⇒ 按 px 算完再除以 densityPixels。
 *  · ArkUI 的 fontSize/lineHeight/textIndent 在 Text 上按 **fp** 解释，恰好等于
 *    "数值 × scaledDensity px"，与 ReaderKit 一致。
 */
/**
 * 标定模式（开发者开关）默认值：false = 正式模式（只有高亮）。
 * 打开后才会出现红标尺 / 紫色段号 / 参数读数 / 微调按钮；开关状态持久化。
 * 注意：几何**测量**（隐藏 Text + getLineMetrics）不受这个开关影响，始终运行——
 * 高亮本身就是测量驱动的。
 */
const HL_DEV_DEFAULT: boolean = false;

/** 每行位数 = 文本宽 / (字号px × 该系数)。实测字宽 = 1em ⇒ **1.0** */
const HL_ADVANCE_RATIO: number = 1.0;
/** 段首 text-indent 占几个字位：实测 121.5px = 2em ⇒ **2** */
const HL_INDENT_SLOTS: number = 2;

// —— 可微调项默认值 ——
const HL_DEF_TOP_PX: number = 230;          // 文本区首行顶部 y（px）
const HL_DEF_WIDTH_RATIO: number = 0.861;   // 文本区宽度 / 视口宽度（1137px）
const HL_DEF_LINE_MUL: number = 1.258;      // 行高系数默认（会被"实测容量自动校准"覆盖）
/** 自动校准采纳区间：超出即视为页高异常（实测页高会随系统避让区变化），弃用并回退手调/默认值 */
const HL_LINE_MUL_MIN: number = 1.05;
const HL_LINE_MUL_MAX: number = 1.60;
const HL_BOTTOM_RESERVED_PX: number = 0;    // 文本区下方预留（px）

// 排版档位（FONT_PRESETS / LINE_HEIGHT_PRESETS）2026-09-26 随「字号/行距」滑条
// 一并迁入「字体管理」弹窗（ReaderFontDialog.ets），此处不再需要。
const HL_CALIB_KEY: string = 'TtsHlCalibV3';

/**
 * `readerSetting` 迁移版本号。
 *
 * ⚠️ 今后任何「修改 readerSetting 默认值」都必须两步走：
 *   ① 把 RS_SETTING_VER +1；
 *   ② 在 `migrateReaderSetting()` 里补一段 `if (ver < N) { … }` 迁移。
 * 否则对「已读过」的书不生效 —— `readerSetting` 是按书持久化的，存量值会覆盖新默认值。
 * 依据：`ReaderPage3.ets` 原按书读写 `ReaderSetting_<书名>`；HANDOFF §4 坑 6 真机实测。
 * 另：`readerCore.ReaderSetting`（SDK `@hms.core.readerservice.readerComponent.d.ets:69-200`）
 * 的 13 个字段里**没有任何版本字段**，只能在对象外旁路存版本号。
 */
const RS_SETTING_VER: number = 1;

/** 沉浸听读：章节固定分页的页高预算已由 immersiveBudgetPx() 提供 */

/**
 * 目录 / 书签弹窗**底边离屏幕底边的留白**（vp）。
 *
 * 依据用户 2026-09-23 的选择：「改成偏下（离底边留一掌）」——
 * 即 `DialogAlignment.Bottom` 之后再用 `offset.dy` 整体上移这么多（见 `openCatalogDialog()`）。
 * 72 这个数不是随手写的：就是本应用**底部悬浮条**的预算
 * （`ImmersiveMaterialUtil.TAB_BAR_HEIGHT` 56 + `TAB_BAR_BOTTOM_MARGIN` 8 + 8 呼吸位 = 72，
 *  见 `ImmersiveMaterialUtil.ets:240-273`）⇒ 面板底边与底部悬浮胶囊落在同一条视觉基线上。
 * ⚠️ **唯一可调项**：真机觉得还要再高一掌就加大它，想更贴底就减小它（改一处即可）。
 */
const CATALOG_DIALOG_BOTTOM_GAP: number = 72;

/**
 * 阅读器底部**四图标页签条**的高度（vp）—— 与改造前自绘 `Grid` 的 `height(60)` 一致。
 * 依据：官方对沉浸光感的生效范围限定，底部栏想拿真材质只能做成**真 Tabs**
 * （详见 `build()` 里那段 `Tabs({ barPosition: BarPosition.End })` 的注释）。
 */
const READER_BAR_HEIGHT: number = 60;

/**
 * 阅读器底部页签条离**系统底部安全区**的额外留白（vp）—— 与改造前自绘胶囊的
 * `margin({ bottom: 10 })` 一致（悬浮条的留白现在由 `FloatingTabBarStyle.barBottomMargin` 表达）。
 */
const READER_BAR_BOTTOM_GAP: number = 10;

/**
 * 「自定义背景色」拖动时，ReaderKit `setPageConfig` 的**最小间隔**（ms）。
 *
 * 为什么需要节流：调色盘与 RGB 滑块是"无极"的，一次拖动每帧都会产生新颜色。
 * `setPageConfig` 会让 ReaderKit **重新排版整页并重出纹理**（见本文件头「渲染管线」注释），
 * 每帧调一次是浪费（真机上会拖慢面板自身的动画）。
 * ⇒ 状态与面板预览**每帧都更新**（所以肉眼是连续的），但真正下发排版最多 60ms 一次，
 *   抬手（`SliderChangeMode.End` / 调色盘 Up）时**强制**再下发一次保证最终色精确落地。
 * 回退：把这里改成 `0` 即恢复"每帧都下发"（与字号/行距滑条的现行做法一致）。
 */
const CUSTOM_BG_APPLY_GAP_MS: number = 60;

/**
 * 推荐字色（2026-09-25 新增，用户设计）。
 * 用户原话：「字体颜色放在现在材质混合现在这个位置，**一行五个，先来两行**，
 *   第一行为**亮色模式下推荐字体**，适应各种亮色，第二行为**暗色模式下推荐字体**，
 *   适应各种暗色。」⇒ 第一行 = 深色系字（在亮背景上清晰），第二行 = 浅色系字
 * （在暗背景上清晰）。点任一枚立即应用并停用自动对比（`applyFontColor`）。
 */
const FONT_ON_LIGHT: string[] = ['#000000', '#3C3C3C', '#4E342E', '#0D47A1', '#1B5E20'];
const FONT_ON_DARK: string[] = ['#FFFFFF', '#CFCFCF', '#F5E6C8', '#FFCC80', '#B3E5FC'];

/** 测量到的一行（px，相对所属段落的 Text 顶部） */
interface MeasuredLine {
  top: number;
  height: number;
  left: number;
  width: number;
}

/** 一个高亮色块（vp，相对阅读页） */
interface Band {
  x: number;
  y: number;
  w: number;
  h: number;
}

// 迁 Navigation 第 3 期：去掉 `@Entry`，并**必须**补 `export default`
// （被 `pages/Index.ets` import 当组件用时没有默认导出会编译报错，第 2 期已在详情页上撞到过）。
@Component
export default struct ReaderPage3 {
  /**
   * **入参**：由 `Index.appRoutes()` 的 NavDestination 构建器注入（替代原来的 `router.getParams()`）。
   *
   * 用普通字段接住、再在 `aboutToAppear` 里读，语义与原来完全一致（不做深拷贝，保持对象引用）。
   * 默认值只是兜底，正常路径一定会传。
   */
  initParam: ReaderRouteParam = { bookData: new Books() };
  /**
   * **组件是否已销毁**（2026-09-22 修复「快速开关第二次必黑屏」）。
   *
   * ── 为什么必须有它 ────────────────────────────────────────────────────────
   * `startPlay()` 是一条 **async 链**：
   *   `init(context)` + `bookParser.getDefaultHandler(path)` → `await Promise.all(...)`
   *   → `registerBookParser()` → `setPageConfig()` → `startPlay()`
   * 而 `aboutToDisappear()` 里的 `off(...)` / `releaseBook()` **不等这条链**。
   *
   * 真机日志（用户提供）里，快速开关时第 5 次会话的表现是：
   *   `openBook` → `✗ [bookparser] Directory does not exist or is not accessible`
   *   → 距进入仅 **86ms** 就退出，且**全程没有 `pageShow`**；
   *   此后再次打开**永远不再有 `pageShow`**（黑屏）。
   * ⇒ 也就是：**`releaseBook()` 已经跑完，而 await 之后的代码才继续执行**，
   *   对着已释放的控制器调 `registerBookParser`，把 ReaderKit 的原生状态搞坏。
   *
   * ── 修法 ──────────────────────────────────────────────────────────────────
   * 在 `await` 之后、动控制器之前检查本标志：已销毁就**什么都不做**。
   * 这样"快速退出"不会把加载截断在半路，也就不需要拦住用户的返回手势
   * （曾试过 `onBackPressed` 拦截，会让黑屏时连手势返回都没了，**已撤回**）。
   */
  private disposed: boolean = false;
  /** 进度同步 v1.1：toast 节流时间戳（2026-10-01） */
  private webSyncToastAt: number = 0
  /** 进度同步 v2.1：双锚写入节流时间戳（2.5s 内不重复取文本+写盘） */
  private webSyncLastWriteAt: number = 0
  /**
   * 进度同步 v1.1 的 emitter 监听回调句柄（2026-10-05，审计 P1-4）。
   * 存下来是为了在 `aboutToDisappear` 用**带回调的** `emitter.off(20261001, cb)` 精确解绑
   * ——只注册不解绑会让闭包连同整个阅读页实例一起驻留（每次开书漏一个）。
   */
  private webSyncListenerCb: ((event: emitter.EventData) => void) | null = null
  @StorageLink('windowWidth') windowWidth: number = 0;
  @StorageLink('windowHeight') windowHeight: number = 0;
  // ⚠️ 亮暗色重构（2026-09-23）：`colorMode` 从 `@StorageLink('colorMode')`（与系统深浅色
  // 共用一个 AppStorage 键，还会被系统回调竞态改写——冷启动后底栏不适配的根因）改为
  // **专用键 `readerColorMode`**：0=夜间、1=日间，仅由本书记忆值（aboutToAppear）和本页
  // 日夜键驱动，与 App 三档/系统深浅色彻底解耦。睡眠定时/听书两个弹窗同订这个键
  // （它们是"建一次"的控制器字段，不能走 @Prop）。全页几十处 `this.colorMode == 0` 无需改动。
  @StorageLink('readerColorMode') colorMode: ConfigurationConstant.ColorMode =
    ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT;
  @StorageLink('bottomRectHeight') bottomRectHeight: number = 0
  @StorageLink('topRectHeight') topRectHeight: number = 0
  // `ReaderPadding`（边距）已于 2026-09-21 删除：唯一消费者是 `LayoutMoreDialog()`
  // builder，而它在本文件里不可达（见该处的说明）；且官方 `ReaderSetting` 里
  // 也没有 margin/padding 字段，改它并不会传给 ReaderKit。
  @State isShowSetting: boolean = false
  /** 当前页是否已有书签（驱动顶部栏图标实心/空心） */
  @State isBookmarked: boolean = false
  /** 最近一次书签状态探测的位置，避免重复查询 */
  private bmProbeKey: string = ''

  /**
   * 取「当前页首行」文本 —— 存书签用，按用户口径截取**前 10 个字符**。
   *
   * 两个来源，按优先级：
   *  1) `TtsEngine.currentNodeTexts()` —— 正在朗读时现成的。
   *     ⚠️ 必须先确认它属于**本页所在的 spine**（`currentChapter() === r.spine`）。
   *     旧实现漏了这个判断：若用户在朗读 A 章时翻到 B 章存书签，会把 A 章的
   *     节点文本按 B 章的 `startNode` 取出来 ⇒ 张冠李戴。
   *  2) `TtsEngine.previewNodeTexts(...)` —— **旁路**按需读该章正文并建同一套块节点模型。
   *     这是**纯默读**（不开听书）时的唯一路径。旧实现没有它，所以 `bookText`
   *     恒为空、书签第二行只能退回章节名（真机表现为「第二行全是第一章名 preface」）。
   *
   * 两者返回的都是同一套「ReaderKit 块节点」模型，下标 = `pageRange.startNode`。
   */
  private async currentPageFirstLine(): Promise<string> {
    const r = this.pageRange
    if (r === null || r.startNode < 0) {
      return ''
    }
    try {
      let nodes = TtsEngine.currentNodeTexts()
      if (nodes === null || TtsEngine.currentChapter() !== r.spine) {
        nodes = await TtsEngine.previewNodeTexts(this.BookHandler ?? null, r.spine)
      }
      if (nodes === null || r.startNode >= nodes.length) {
        return ''
      }
      const line = (nodes[r.startNode] ?? '').replace(new RegExp('\\s{1,}', 'g'), ' ').trim()
      return line.length > 10 ? line.substring(0, 10) : line
    } catch (e) {
      return ''
    }
  }

  /** 上次写数据库的时刻（节流用，避免每次翻页都落库） */
  private lastPersistAt: number = 0

  /**
   * 把阅读进度落到 `books` 表（5 秒节流）。
   * 见 `BooksDao.stampReadProgress` 注释：这是当前阅读页**唯一的**进度落库点。
   * 没有它，「我的 → 读过」永远是 0、书架"最近阅读"排序也失效。
   */
  private persistReadProgress(): void {
    try {
      const id = this.bookData.id ?? 0
      if (id <= 0) {
        return // 无 id 的路径（如搜索→详情→直接阅读）无法按 id 更新，跳过
      }
      const now = Date.now()
      if (now - this.lastPersistAt < 5000) {
        return
      }
      this.lastPersistAt = now
      BooksDao.stampReadProgress(id, this.bookData.durChapterIndex ?? 0,
        this.bookData.durChapterTitle ?? '', this.bookData.totalChapterNum ?? 0)
    } catch (e) {
      // 忽略：落库失败不得影响阅读
    }
  }

  /**
   * 「读完」判定 —— 读到**最后一章**时写 `finishedTime`。
   *
   * 口径（2026-09-21 用户拍板）：「打开到最后一章就算读完」。
   * 为什么放宽：原实现额外要求 `TtsEngine.currentNodeTexts()` 非空、且
   * `TtsEngine.currentChapter() === durChapterIndex`，也就是**必须开着听书**才可能判定。
   * 但「读过/读完」的主体场景恰恰是**纯默读**，于是「读完」恒为 0。
   *
   * 为什么进度**会回退**却不能只看 `durChapterIndex`：读完后回第一章重看时
   * `durChapterIndex` 会变小。故写入走 `BooksDao.markFinished()`，其 SQL 带
   * `AND (finishedTime IS NULL OR finishedTime = 0)` —— **只写一次**，重复到达末章
   * 不会改时间、也不会重复计数。
   */
  private checkFinished(): void {
    try {
      const total = this.bookData.totalChapterNum ?? 0
      const idx = this.bookData.durChapterIndex ?? 0
      if (total <= 0 || idx < total - 1) {
        return
      }
      // 到了末章 ⇒ 标记读完（SQL 保证只写一次）
      const id = this.bookData.id ?? 0
      if (id > 0) {
        BooksDao.markFinished(id)
      }
    } catch (e) {
      // 忽略：读完判定失败不得影响翻页
    }
  }

  /**
   * 阅读会话结束 ⇒ **先落库最终进度，再广播书架刷新**（2026-10-07）。
   *
   * ── 缺口 ────────────────────────────────────────────────────────────────
   * 书架列表的唯一数据刷新通道是 AppStorage 键 `BOOK_IS_BOOK_REFRESHING`
   * （`BookContent` `@StorageLink+@Watch` ⇒ 重查数据库，排序 SQL 为
   * `isTop DESC, durChapterTime DESC`，见 `BooksDao.searchPage`）。本页写进度的
   * `persistReadProgress()` 只落库、从不广播；而阅读页是 NavDestination，
   * pop 回书架时宿主 `Index.onPageShow()` **不会触发**（Index.ets :331 注释已实证）
   * ⇒ 「看完书回书架，刚读的书不置顶、'读到第X章'停在旧值」，要手动下拉刷新。
   *
   * ── 为什么必须 await 落库完成后再广播 ────────────────────────────────────
   * `stampReadProgress` 是异步 UPDATE；先广播后落库的话，书架重查会读到**旧行**
   * （与 `BooksDao.ets` 「网络导入竞态」注释同一坑：信号到了、行还没写进去 ⇒
   * 界面不更新，要等下次）。所以这里 await 到 UPDATE 提交再自增广播键。
   *
   * ── 调用点 ──────────────────────────────────────────────────────────────
   * `aboutToDisappear()`（pop 转场结束、组件销毁时触发，见 Index.ets LTBOOK
   * 日志注记 onDisappear 晚于 transition finish）——此时书架刚可见，重查在落地后
   * 一两帧内完成，与下拉刷新同量级开销。兜底语义：即使 5 秒节流吞掉了最后一次
   * `persistReadProgress()`，退出前这里也会把最终进度补写进去。
   */
  private async flushReadProgressThenNotifyShelf(): Promise<void> {
    try {
      const id = this.bookData.id ?? 0
      if (id > 0) {
        // 无节流：aboutToDisappear 只走一次，把最后一次翻页后的进度补齐
        await BooksDao.stampReadProgress(id, this.bookData.durChapterIndex ?? 0,
          this.bookData.durChapterTitle ?? '', this.bookData.totalChapterNum ?? 0)
      }
    } catch (e) {
      // 落库失败不得阻塞退出流程
    }
    // 广播语义与 WifiBookServer.registerImportedBook（传书入库后）一致：自增刷新键
    const tick: number = (AppStorage.get<number>(CommonConstants.BOOK_IS_BOOK_REFRESHING) ?? 0) + 1;
    AppStorage.setOrCreate(CommonConstants.BOOK_IS_BOOK_REFRESHING, tick);
  }

  /** 待跳转的书签目标（-1 = 无）。来自 `readStatistics` 二级菜单点击书签时的 params。 */
  private bmJumpIndex: number = -1
  private bmJumpNode: number = -1
  private bmJumpDone: boolean = false

  /**
   * 书签回跳（2026-09-21 新增）。
   *
   * 为什么不能直接 `startPlay(spine, domPos)`：书签表里存的是
   * **目录号**（`bookmarks.chapterIndex`）+ **页首块节点号**（`bookmarks.chapterPos`），
   * 而 `startPlay` 要的是**正文号**（spine）。两者的换算全工程只有
   * `getResourceItemByCatalog()`（`ReaderPage3.ets:3221`）一处 —— 复用即可，
   * 不自己猜映射。
   *
   * 跳转本身复用现成的 `requestLocate()`：它自带
   * `startPlay(spine, domPos)` → 超时 → 逐页逼近兜底，是工程内已验证的定位路径。
   * `silent=true`：跳不到不弹 toast 打扰。
   *
   * 只尝试一次（`bmJumpDone`）：失败也不反复跳，避免和用户翻页打架。
   */
  private tryBookmarkJump(): void {
    if (this.bmJumpDone || this.bmJumpIndex < 0 || this.bmJumpNode < 0) {
      return
    }
    this.bmJumpDone = true
    try {
      const item = this.CatalogList.getData(this.bmJumpIndex)
      if (item === undefined || item === null) {
        hilog.warn(0x0000, 'testTag', 'bmJump: catalog %{public}d 不存在', this.bmJumpIndex)
        return
      }
      const spine = this.getResourceItemByCatalog(item).index
      hilog.info(0x0000, 'testTag', 'bmJump: catalog=%{public}d → spine=%{public}d node=%{public}d',
        this.bmJumpIndex, spine, this.bmJumpNode)
      this.requestLocate(spine, this.bmJumpNode, 0, true, true)
    } catch (e) {
      hilog.warn(0x0000, 'testTag', 'bmJump failed')
    }
  }

  /** 书签位置：用**当前页起始节点**作为章内位置。   *  说明：`bookmarks.chapterPos` 在原 Android Legado 里是"章内字符偏移"，
   *  但当前阅读页只保证 `pageRange.startNode`（页首块节点号）稳定可比。
   *  自用场景下取"节点号"即可满足"同页判定 + 列表定位"，
   *  且比拿一个不随翻页更新的 `durChapterPos` 正确得多。 */
  private bmPos(): number {
    const r = this.pageRange
    return r === null ? 0 : r.startNode
  }

  /** 同步书签图标状态（仅在位置变化时查库，避免每次翻页都查） */
  private async syncBookmarkState(): Promise<void> {
    const idx = this.bookData.durChapterIndex ?? 0
    const pos = this.bmPos()
    const key = `${this.bookData.bookName}|${idx}|${pos}`
    if (key === this.bmProbeKey) {
      return
    }
    this.bmProbeKey = key
    this.isBookmarked = await BookmarksDao.isBookmarked(this.bookData.bookName, idx, pos)
  }

  /** 顶部栏书签图标点击：有则删、无则存 */
  private async toggleBookmark(): Promise<void> {
    const idx = this.bookData.durChapterIndex ?? 0
    const pos = this.bmPos()
    const name = this.bookData.bookName
    if (this.isBookmarked) {
      await BookmarksDao.removeAt(name, idx, pos)
      this.isBookmarked = false
      this.getUIContext().getPromptAction().showToast({ message: '已移除书签' })
    } else {
      const chapterName = this.CatalogList.getData(idx)?.catalogName ?? ''
      // 第 7 个参数 `true` = **同位置去重**（2026-10-05）：`isBookmarked` 是内存缓存
      // （`bmProbeKey` 未变时直接返回、不查库，见 `syncBookmarkState`），缓存过期时
      // 旧实现会重复插行；DAO 层兜底后同一页只会有一条书签。
      const ok = await BookmarksDao.add(name, this.bookData.author ?? '', idx, pos, chapterName,
        await this.currentPageFirstLine(), true)
      this.isBookmarked = ok
      this.getUIContext().getPromptAction().showToast({ message: ok ? '已添加书签' : '添加失败' })
    }
    this.bmProbeKey = `${name}|${idx}|${pos}`  // 状态已知，避免立刻重复查库
  }

  // 2026-09-21 精简：`isShowDownload` / `isShowMoreLayout` / `ParagraphSpacing` /
  // `isShowSource` / `isShowPurification` 五个状态已删除（连同顶栏「刷新/下载/更多」
  // 与底栏「换源/净化」两个注释块）。其中 `ParagraphSpacing` 尤其值得一提：
  // 全文件只有声明、**无任何读写点**，且官方 `ReaderSetting`
  // （`@hms.core.readerservice.readerComponent.d.ets`）里**根本没有段间距字段**
  // ⇒ ReaderKit 不具备该能力，留着只会让人以为段距可调。
  @State isShowListen: boolean = false
  @State isShowContentSetting: boolean = false
  @State isLuminanceFollowSystem: boolean = false //亮度跟随系统
  @State isScreenState: boolean = true //屏幕是否常亮（2026-09-27 新用户默认开启）
  // 朗读（TTS）状态
  @State ttsState: TtsState = 'stopped'
  @State ttsPrefs: TtsPrefs = loadTtsPrefs()
  @State ttsChapterTitle: string = ''
  @State ttsSegIndex: number = 0
  @State ttsSegTotal: number = 0
  @State ttsSegText: string = ''
  @State ttsSpineIndex: number = 0
  /**
   * 听书面板控制器。
   *
   * ⚠️⚠️ **必须写成"成员初始化器"，不能改成在方法里 `new`** ——
   *   `$xxx` 是**链接语法**，只有"组件构造上下文"（build / @Builder / **成员初始化器**）
   *   才会被编译器转换成 `@Link` 绑定；写在普通方法里它就只是个**未定义的标识符**，
   *   真机崩溃原文（2026-09-22 日志）：
   *     `Reason:ReferenceError`
   *     `Error message:$isShowListen is not defined`
   *     `at builder entry (entry/src/main/ets/pages/view/Reader/ReaderPage3.ets:3282:23)`
   *     （堆栈里是 `OverlayManager::ShowDialog`）
   *   ⇒ 官方示例也是这个写法（`CustomDialogController` 作为成员字段 + `$xxx`）。
   *
   * · 7 个会变的值全部 `$` 绑成 `@Link`。依据：SDK `component/custom_dialog_controller.d.ts:59-60`
   *   对 `builder` 字段的 NOTE 原文：「To listen for data changes in the builder, use the
   *   **@Link or @Consume** decorator; other decorators, such as **@Prop and @ObjectLink,
   *   do not apply**.」⇒ 绑上之后值**一直保持同步**，不存在"构造时快照"的问题。
   * · 因此控制器**只建一次**、反复 `open()`；不要再"每次打开新建"（那样只能传快照）。
   * · `offset` 依赖 `bottomRectHeight`：真机上它进入阅读页时被**冻结**
   *   （日志 `avoidAreaChange(TYPE_NAVIGATION_INDICATOR) skipped: bottomRectHeight frozen`）
   *   ⇒ 构造时读到的值与整个会话一致，写在 options 里是安全的。
   */
  private listenDialog: CustomDialogController = new CustomDialogController({
    builder: ReaderListenDialog({
      isShowListen: $isShowListen,
      prefs: $ttsPrefs,
      ttsState: $ttsState,
      chapterTitle: $ttsChapterTitle,
      segIndex: $ttsSegIndex,
      segTotal: $ttsSegTotal,
      segText: $ttsSegText,
      onStart: (): void => {
        this.ttsStart();
      },
      onSeekChapter: (delta: number): void => {
        this.ttsSeekChapter(delta);
      },
      onBackToReader: (): void => {
        this.backToTtsAnchor();
      },
      onClosed: (): void => {
        // 语义等同改造前 sheet 的 `onDisappear`：任何关闭方式都回跳到当前朗读处
        this.backToTtsAnchor();
      },
      onOpenSleepTimer: (): void => {
        // 定时入口迁入听书面板（2026-10-07 用户设计）：听书=父窗，定时弹窗=子窗
        this.openSleepTimerDialog();
      }
    }),
    autoCancel: true,
    // 与底部页签条同一套底部留白：悬浮、不贴底（sheet 没有 offset 字段，永远贴底）
    alignment: DialogAlignment.Bottom,
    offset: { dx: 0, dy: -(this.bottomRectHeight + LISTEN_DIALOG_BOTTOM_GAP) },
    width: '92%',
    cornerRadius: 20,
    customStyle: false,
    // ── 材质（2026-09-23 用户拍板选 **A：材质优先**）────────────────────────────
    // 恢复弹窗的真材质（那一版用户评价"展开的效果非常好、大比例完美"）。
    // 代价：面板内滑条**不设材质** ⇒ 没有粒子光效 —— 这是官方硬规则决定的，二者不可共存：
    //   官方《沉浸光感功耗优化》原文「#### 避免材质嵌套 — 材质嵌套使用会导致效果被重复计算，
    //   既增加功耗，**视觉上又相互干扰**。同一子树中只需在**最外层**设置一次沉浸式系统材质，
    //   内层节点不应再设置。」
    //   真机实测：弹窗层有材质 + 内层滑条也设 ⇒ 滑条按住出现**黑色圆形蒙版**。
    systemMaterial: ImmersiveMaterialUtil.sheetMaterial(),
    // ── 弹窗出入场动效（2026-09-23，弹簧为主）────────────────────────────────
    // SDK `component/custom_dialog_controller.d.ts:205/226`：
    //   `openAnimation?: AnimateParam;` / `closeAnimation?: AnimateParam;`
    // ⚠️ 官方 NOTE（同文件 :32-35）原文：「During animation playback, the page **does not respond
    //   to touch, swipe, or click interactions**」⇒ 弹窗动效要"短" ⇒ 用 `SPRING_FAST`（收敛快）。
    openAnimation: UiMotion.motionParam(UiMotion.SPRING_FAST),
    closeAnimation: UiMotion.motionParam(UiMotion.SPRING_FAST),
  })

  /**
   * 阅读**设置**面板弹窗（2026-09-23 新增，用户真机反馈「设置没有效果，点击就是正常出现」）。
   *
   * ── 与 `listenDialog` 的两点同、两点不同 ────────────────────────────────────
   * 同：
   * · 控制器也是**成员字段**（`$` 只能用在组件构造上下文，写在方法里会 `ReferenceError`，
   *   真机崩溃原文见上面 `listenDialog` 的注释）——本弹窗虽然不传 `$`，但同理更安全。
   * · `systemMaterial` / `openAnimation` / `closeAnimation` 三项与听书**完全一致**
   *   （真材质 + 弹簧；官方 `custom_dialog_controller.d.ts:205/226`）。
   * 不同：
   * · 内容不走 `@Link`，而是把**页面自己的 `@Builder ReaderSettingContent()`** 以
   *   `@BuilderParam` 闭包传进去（官方 FAQ `faqs-arkui-826` 原文见
   *   `ReaderSettingDialog.ets` 文件头）⇒ 字号/行距/亮度的实时刷新仍由本页状态驱动。
   * · 高度**不设**：随内容自适应（`custom_dialog_controller.d.ts:126`）。
   *
   * 遮罩：不写 `maskColor` ⇒ 用默认 `0x33000000`（SDK `:158-169`），与目录/听书一致。
   */
  private settingDialog: CustomDialogController = new CustomDialogController({
    builder: ReaderSettingDialog({
      // ⚠️ 必须是箭头函数闭包，不能写 `content: this.ReaderSettingContent`
      //    （官方 FAQ `faqs-arkui-826` 的父子传法示例就是这个形式）。
      content: (): void => {
        this.ReaderSettingContent()
      }
    }),
    autoCancel: true,
    // 与听书/底部页签条同一套底部留白：悬浮、不贴底
    alignment: DialogAlignment.Bottom,
    offset: { dx: 0, dy: -(this.bottomRectHeight + SETTING_DIALOG_BOTTOM_GAP) },
    width: '92%',
    cornerRadius: 20,
    customStyle: false,
    // 真材质：内容区自绘节点拿不到真材质（官方生效范围见 `IndexShelf` 顶部注释），
    // 只有弹窗类能拿 ⇒ 这也是"改成弹窗"的核心收益之一。
    // ⚠️ 代价：面板内 3 个滑条（亮度/字号/行距）**不能**再设 `sliderMaterial()`，
    //   否则材质嵌套 ⇒ 按住出现黑色圆形蒙版（听书面板已实测踩坑）。
    //   注意「本章」滑块留在底栏胶囊里（不在本弹窗内）⇒ 它的光效**保留**。
    systemMaterial: ImmersiveMaterialUtil.sheetMaterial(),
    openAnimation: UiMotion.motionParam(UiMotion.SPRING_FAST),
    closeAnimation: UiMotion.motionParam(UiMotion.SPRING_FAST),
    cancel: (): void => {
      // 点遮罩 / 返回手势关掉时，把底栏图标收回"空心设置"
      this.isShowContentSetting = false
    },
  })
  // 朗读段落高亮叠加层（半透明色块 + 下划线；-1 = 不显示）
  @State hlLeft: number = 0
  @State hlTop: number = -1
  @State hlWidth: number = 0
  @State hlHeight: number = 0
  // 标定模式下的标尺（vp）：横向每条对应一个行位，另加左右文本边界
  @State calibLines: number[] = []
  @State calibLabel: string = ''
  @State calibLeft: number = 0
  @State calibWidth: number = 0
  // 标定：本页每个段落"算出"的起始行 y（vp），以及首个段落的节点号（用于打标号）
  @State calibMarks: number[] = []
  @State calibMarkBase: number = 0
  /** 本页各段"算出的行数"文本，如 "20:3 21:2 22:3"（用于跟真机逐段核对） */
  @State calibCounts: string = ''
  // —— 测量通道：把当前页正文按"一段一个 Text"喂给 ArkUI，读它真实的断行结果 ——
  @State measureParas: string[] = []
  private measureCtrls: TextController[] = []
  private measureSeq: number = 0
  /** 测量到的每段每行矩形（px）；下标 = pageRange.startNode + i */
  private measuredParas: MeasuredLine[][] = []
  private measuredKey: string = ''
  /** 每段的首行缩进（fp）；页首若为"半段延续"则为 0（ReaderKit 不给续段加缩进） */
  @State measureIndents: number[] = []
  // —— 自动校准：行高不再靠调，而是"页高 ÷ 实测每页行数" ——
  @State learnedCapacity: number = 0      // 实测每页行数（取满页最大值）
  @State autoLineMul: number = 0          // 由容量反推出的行高系数（0 = 尚未校准）
  private measurePending: string = ''     // 正在测量的失效键（防重入）
  /** 标定模式（开发者）：设置面板里的开关，持久化 */
  @State devMode: boolean = HL_DEV_DEFAULT
  /** 手动翻页后挂起自动跟随（音频继续读，页面留在你翻到的地方） */
  @State followSuspended: boolean = false
  // —— 悬浮条实时前滚 ——
  // 注意：这两个值只被 scrollMiniBar 读取，**不能是 @State**（每个字都变 ⇒ 整页 build 被反复触发，
  // 手势会被拖累）。用普通字段即可。
  private ttsCharInSentence: number = 0
  private ttsSentenceLen: number = 0
  @State miniTextW: number = 0            // 悬浮条文字宽度（vp）
  @State miniViewW: number = 0            // 悬浮条可视宽度（vp）
  private miniScroller: Scroller = new Scroller()
  /** 最近一次"由我们发起"的跳转时刻：用来区分程序翻页 vs 用户手动翻页 */
  private lastNavMs: number = 0

  /** 当前显示的沉浸页号（-1 = 未定） */
  @State immPageIdx: number = -1
  /** 手动翻页期间暂停自动跟随（8s 兜底；点「回到朗读」立即解除） */
  @State immManual: boolean = false
  private immManualAt: number = 0
  /** 可观察的"沉浸可渲染"标志：currentNodeTexts() 是静态字段，不放进状态里
   *  ArkUI 就不会重估 if 分支（表现为"必须点一下播放键才变沉浸"）。 */
  @State immReady: boolean = false
  /** 章节固定分页缓存：页 → 段列表（段 = [节点号, 起始字符, 结束字符]，可段中切断）/ 节点 → 页号 */
  private immPages: number[][][] = []
  private immPageOfNode: number[] = []
  private immPagesKey: string = ''
  /** 句序号：让"当前段"的 ForEach key 每句都变（否则 ArkUI 复用旧组件，高亮不会移动） */
  @State immSegSerial: number = 0
  /** 最近一次朗读位置（退出沉浸/停止时用来把阅读器同步过去） */
  private lastAudioPos: TtsSegmentPos | null = null
  private wasImmersive: boolean = false
  /** updateHighlight 重入保护（防止 requestLocate 的同步回调形成递归 → 爆栈闪退） */
  private inHighlight: boolean = false
  /** 遮罩色块（测量优先；无测量时回落到模型单块） */
  @State hlBands: Band[] = []
  // ---------- 睡眠定时弹窗（2026-09-22 新增，用户设计）------------------------
  // 图标在顶栏「书签」左侧；点击弹出光感弹窗（章节 1-99 / 时:分 + 取消重置确定）。
  // 底层到点暂停能力早已存在且未被改动：`TtsEngine.setSleepTimer/getSleepStopMs` 等。
  @State sleepStatusText: string = ''
  /**
   * 睡眠定时**是否已设定**（2026-09-25 新增）：驱动顶栏闹钟图标的实心/空心
   * （用户要求：「闹钟…正常设定之后，也应该变幻一下」）。
   * 口径与 `sleepStatusText` 一致：`chapters>0 || minutes>0`（回读引擎，不信本地）。
   */
  @State sleepTimerActive: boolean = false
  /** 剩余量刷新定时器句柄（-1 = 未启动） */
  private sleepTicker: number = -1
  /**
   * 应用是否在前台（`EntryAbility.onForeground/onBackground` 写入，2026-10-07 新增）。
   *
   * **用途：给两个 UI 刷新器做功耗门禁**。阅读页是 NavDestination，退后台/熄屏时组件**仍然存活**，
   * 而 `sleepTicker`(5s) / `infoTicker`(1s) 都是 `setInterval` ⇒ 旧实现会在熄屏后台继续唤醒主线程
   * 并改 `@State`（不可见重渲染）。官方低功耗口径要求「低功耗渲染器…**减少唤醒次数**」
   * （documentId `开发指南/Audio_Kit_音频服务/音频播放/低功耗音频播放/power-saving-for-playback`），
   * 故这两个刷新器只在**前台**跑；回前台时 `@Watch` 会立刻重启并补一次刷新。
   */
  @StorageLink('appForeground') @Watch('onAppForegroundChanged') appForeground: boolean = true
  /**
   * 听书入口是否已解锁（2026-09-25 新增，暗号改名解锁方案）。
   * false ⇒ 底栏只有 目录 / 日夜 / 设置 三个按钮（用户需求）；解锁后永久开放。
   * 改变它的唯一入口是「我的 → 改名」命中暗号（`ListenUnlock.tryUnlock`），
   * 通过 AppStorage（`ListenUnlock.STORAGE_KEY`）广播到这里。
   */
  @StorageLink('listenEntryUnlocked') @Watch('onListenUnlockChanged') listenUnlocked: boolean = false

  onListenUnlockChanged(): void {
    // 解锁位变化（2026-09-27 起**只**影响 Edge TTS 可用性与我的-设置引擎开关；
    // 底栏听书按钮已常驻，不再随解锁增减页签）。当前无需额外动作。
  }
  /**
   * 底栏每个图标的**Q弹缩放值**（2026-09-25 二次调优，借用参考工程 `runJellyClick`）。
   * 为什么不用系统内置 ScaleSymbolEffect：`symbolglyph.d.ts` 的 `symbolEffect`
   * 两个重载（:761/:777）都没有时长/曲线参数 ⇒ 内置节奏定死、真机实测太慢；
   * 自驱 `.scale()` 三段式（压下→过冲→回弹）手感跟手（见 `UiMotion.runJellyClick`）。
   */
  @State barScale: number[] = [1, 1, 1, 1]
  /** 顶栏书签图标的 Q弹缩放值（同上） */
  @State bookmarkScale: number = 1
  /** 顶栏防窥眼睛图标的 Q弹缩放值（同上） */
  @State antiPeepScale: number = 1
  /**
   * 防窥开关（2026-10-07）：AppStorage `antiPeepOn` 同名键驱动（顶栏眼睛图标用）。
   * 真值落盘与两层防护全在 `AntiPeep`（utils/AntiPeep.ets）；默认关。
   */
  @StorageLink('antiPeepOn') antiPeepOn: boolean = false

  // ── 阅读器信息窗（2026-10-07 用户设计）────────────────────────────────────
  // 全屏阅读（菜单栏隐藏）时右上角显示 防窥眼睛 + 定时实时信息。用户拍板：
  // ①非全屏不显示（顶栏已有三个图标）；②不可点击，"像和文字一样被渲染的内容"。
  // 实现性质是 ArkUI 玻璃层：不参与仿真翻页卷纸（翻页动画进行中的零点几秒元素原地不动，
  // 纸从其下方经过；无隧穿/丢内容——内容由状态驱动，任何一页都正确）。字色取
  // `readerSetting.fontColor`（与正文同源，自动跟随材质均色/日夜）。
  /** 设置-其他-「阅读器信息窗」开关（Preferences，进场读一次；开关只在设置页改） */
  @State infoWinOn: boolean = false
  /** 定时实时信息文案（时间型 = 秒级倒计时；章节型 = 剩余X章；两者可并存） */
  @State infoTimerText: string = ''
  /** 信息窗秒级刷新句柄（-1 = 未启动；仅信息窗开且定时在跑时启动，功耗门禁） */
  private infoTicker: number = -1
  /**
   * 弹窗控制器。**每次打开时新建** —— 因为 SDK 明确
   * 「Custom dialog box parameters **do not support dynamic updates**」
   * （`custom_dialog_controller.d.ts:756` 的 NOTE 原文），
   * 预先建一个再改 `initChapters/initMinutes/statusText` 是不会生效的。
   */
  private sleepDialog: CustomDialogController | null = null
  // 标定可微调项（持久化）
  @State calibTopPx: number = HL_DEF_TOP_PX
  @State calibWidthRatio: number = HL_DEF_WIDTH_RATIO
  @State calibLineMul: number = HL_DEF_LINE_MUL
  // 精确定位状态机（ReaderKit 坐标系：spine / 块节点 / 节点内字符）
  private pageRange: PageRange | null = null;
  private locateTarget: LocateTarget | null = null;
  private flipSearch: FlipSearch | null = null;
  private locateTimer: number = -1;
  private lastFollowNode: number = -1;
  /** 定位 toast 去抖（面板关闭同时走"完成按钮 + onDisappear"两条路径时避免重复提示） */
  private lastLocateToastMs: number = 0;
  //书籍解析用数据
  @State bookData: Books = new Books(); //书籍数据
  /**
   * ── Bug B 修复：阅读页自己消费桌面快捷方式意图 ──────────────────────────
   *
   * 旧实现只在 `pages/Index` 上挂 `@Watch('quickAction')`。但当阅读页已经打开时，
   * `Index` 被压在栈底 —— 它再 `pushUrl` 要么被忽略、要么叠出第二个阅读页，
   * 表现就是用户实测的「在快速阅读界面点快速听书 → 没反应，还是阅读界面」（反向同理）。
   *
   * 正确语义：**已经在读这本书了，就别跳转，就地切换模式** ——
   * 收到 `'listen'` ⇒ 开始朗读；收到 `'read'` ⇒ 停止朗读。
   * 首页 `Index.consumeQuickAction()` 检测到当前栈顶是本页时会直接 return，把消费权交给这里。
   */
  @StorageLink('quickAction') @Watch('onQuickActionInReader') quickAction: string = ''

  private onQuickActionInReader(): void {
    const action = this.quickAction;
    if (action !== 'listen' && action !== 'read') {
      return;
    }
    AppStorage.setOrCreate('quickAction', ''); // 先清标记，保证只消费一次
    if (action === 'listen') {
      if (this.ttsState === 'stopped') {
        // 复用与「快速听书」冷启动相同的"等就绪再播"逻辑
        this.autoStartListenWhenReady(0);
      }
    } else {
      if (this.ttsState !== 'stopped') {
        TtsEngine.stop('');
      }
    }
    // 睡眠定时剩余量：进入阅读页即开始刷新（回读引擎真实状态，不依赖本地状态）
    this.startSleepTicker();
  }

  // ── 睡眠定时（2026-09-22 新增，用户设计）────────────────────────────────
  //
  // 用户需求：「单独做个 symbol 式中图标，放在**书签左面**，点击之后是双滚轮选择
  //   （章节 1-99 / 时和分），真的可以实现功能，**到点暂停**…出现一个光感弹窗…
  //   底部是取消、重置和确定」。
  //
  // 底层能力**早已存在且未被改动**：`TtsEngine.setSleepTimer(chapters, minutes)`
  //   —— 语义（`:692-703`）：`chapters` = **再读 N 章**、`minutes` = **再读 N 分钟**，
  //   任一先到即停；两者都传 0 即取消定时。
  //   回读用 `getSleepChaptersReq()` / `getSleepMinutesReq()` / `getSleepStopMs()`。

  /**
   * 打开定时弹窗（2026-10-07 迁入听书面板：**听书=父窗，定时=子窗**）。
   * 父子协调与「更多材质/更多方案」同款：子进父退（先收听书面板），子关父回
   * （`onClosed` 三条按钮路径 + 控制器 `cancel`（点遮罩/返回键）都会走 reopen，
   * 两者在实际操作中互斥）。顺带 `refreshSleepStatus()` 把真实档位带给滚轮。
   */
  private openSleepTimerDialog(): void {
    this.refreshSleepStatus();
    this.listenDialog.close();
    this.sleepDialog = new CustomDialogController({
      builder: SleepTimerDialog({
        initChapters: TtsEngine.getSleepChaptersReq(),
        initMinutes: TtsEngine.getSleepMinutesReq(),
        statusText: this.sleepStatusText,
        onConfirm: (c: number, m: number): void => {
          this.applySleepTimer(c, m);
        },
        onCancel: (): void => {
        },
        onReset: (): void => {
          this.applySleepTimer(0, 0);
        },
        onClosed: (): void => {
          this.reopenListenDialog();
        }
      }),
      autoCancel: true,
      alignment: DialogAlignment.Center,
      width: '92%',
      cornerRadius: 20,
      customStyle: false,
      systemMaterial: ImmersiveMaterialUtil.sheetMaterial(),
      // 弹窗出入场：弹簧令牌（理由见 `listenDialog` 处的注释）
      openAnimation: UiMotion.motionParam(UiMotion.SPRING_FAST),
      closeAnimation: UiMotion.motionParam(UiMotion.SPRING_FAST),
      cancel: (): void => {
        // 点遮罩 / 返回键收起 ⇒ 同样"子退父回"
        this.reopenListenDialog();
      }
    });
    this.sleepDialog?.open();
  }

  /** 子弹窗（定时）关闭后重新拉起父窗（听书面板） */
  private reopenListenDialog(): void {
    this.listenDialog.open()
  }

  /** 把选择结果写进引擎（真正实现"到点暂停"），并刷新文案 */
  applySleepTimer(chapters: number, minutes: number): void {
    TtsEngine.setSleepTimer(chapters, minutes);
    this.refreshSleepStatus();
    if (chapters > 0 || minutes > 0) {
      showMessage(`定时已设：${chapters > 0 ? chapters + ' 章' : ''}${chapters > 0 && minutes > 0 ? ' / ' : ''}${minutes > 0 ? minutes + ' 分钟' : ''}`);
    } else {
      showMessage('定时已取消');
    }
  }

  /**
   * 刷新剩余量文案（回读引擎，**不信本地 `@State`**）。
   * 依据：`getSleepStopMs()` 是绝对截止时刻，`getPlayedMs()` 是已播时长。
   */
  refreshSleepStatus(): void {
    const chapters = TtsEngine.getSleepChaptersReq();
    const minutes = TtsEngine.getSleepMinutesReq();
    // 闹钟图标实心/空心与文案同一口径（2026-09-25：回读引擎，不信本地）
    this.sleepTimerActive = chapters > 0 || minutes > 0;
    if (chapters <= 0 && minutes <= 0) {
      this.sleepStatusText = '';
      return;
    }
    const parts: string[] = [];
    if (chapters > 0) {
      parts.push(`${chapters} 章`);
    }
    if (minutes > 0) {
      // sleepStopMs 是**绝对截止时刻**（墙钟，2026-10-07 起）：设定即定格 deadline，
      // 暂停/看书都走表——旧实现存"累计播放档位"却按绝对时刻展示，恒显"剩 0 分钟"。
      const stopMs = TtsEngine.getSleepStopMs();
      if (stopMs > 0) {
        const leftMs = Math.max(0, stopMs - Date.now());
        parts.push(`剩 ${Math.ceil(leftMs / 60000)} 分钟`);
      } else {
        parts.push(`${minutes} 分钟`);
      }
    }
    this.sleepStatusText = parts.join(' · ');
    // 信息窗秒级刷新的启停对账（定时设定/取消/到点都经这里）
    this.syncInfoTicker();
  }

  /** 每秒刷新一次剩余量（仅在已设定时时才有意义）——**仅前台**跑（功耗门禁，见 appForeground 注释） */
  private startSleepTicker(): void {
    if (this.sleepTicker !== -1 || !this.appForeground) {
      return;
    }
    this.sleepTicker = setInterval((): void => {
      this.refreshSleepStatus();
    }, 5000);
  }

  private stopSleepTicker(): void {
    if (this.sleepTicker !== -1) {
      clearInterval(this.sleepTicker);
      this.sleepTicker = -1;
    }
  }

  /**
   * 前/后台切换（`appForeground` 变化）：后台停刷新器、回前台重启并补一次立即刷新。
   * 两个刷新器都要过一遍 `syncInfoTicker()` —— 它的门禁里含 `appForeground`。
   */
  private onAppForegroundChanged(): void {
    if (this.appForeground) {
      this.refreshSleepStatus(); // 后台期间没刷，回前台先补一次真实剩余量
      this.startSleepTicker();
    } else {
      this.stopSleepTicker();
    }
    this.syncInfoTicker();
  }

  // ── 阅读器信息窗（2026-10-07）：定时实时信息（秒级）────────────────────────

  /** 组装信息窗的定时文案：时间型 = **墙钟独立倒计时**（时分秒，暂停/看书都走秒）；
   *  章节型 = 剩余X章；两者可并存。sleepStopMs 自 2026-10-07 起为绝对截止时刻。 */
  private computeInfoTimerText(): string {
    const parts: string[] = [];
    const chapters = TtsEngine.getSleepChaptersReq();
    if (chapters > 0) {
      // D4 修正（2026-10-07）：剩余章数**必须与引擎判定同源**。
      // 引擎在 `run()` 章界用「朗读的 spine」判定（`TtsEngine.ets` 的 `sleepStopChapter` 检查），
      // 旧实现在这里用的是**阅读器的当前章** `bookData.durChapterIndex` ⇒ 用户一边听一边翻到
      // 别的章看书时，信息窗的"剩X章"会与真实停止点漂开。面板侧早就是引擎口径
      // （`TtsControlPanel.syncSleepFromEngine` 用 `TtsEngine.currentChapter()`），此处对齐。
      const left = Math.max(0, TtsEngine.getSleepStopChapter() - TtsEngine.currentChapter());
      parts.push(`剩${left}章`);
    }
    const minutes = TtsEngine.getSleepMinutesReq();
    if (minutes > 0 && TtsEngine.getSleepStopMs() > 0) {
      const leftS = Math.max(0, Math.round((TtsEngine.getSleepStopMs() - Date.now()) / 1000));
      const h = Math.floor(leftS / 3600);
      const m = Math.floor((leftS % 3600) / 60);
      const s = leftS % 60;
      const pad2 = (n: number): string => (n < 10 ? '0' + n : '' + n);
      parts.push(`${pad2(h)}:${pad2(m)}:${pad2(s)}`);
    }
    return parts.join(' · ');
  }

  /**
   * 信息窗秒级刷新的启停对账：仅"开关开 + 定时在跑 + **前台**"时才转
   * （功耗门禁：熄屏后台 1s 唤醒一次是纯浪费；均无需时清空文案）。
   */
  private syncInfoTicker(): void {
    const need: boolean = this.infoWinOn && this.sleepTimerActive && this.appForeground;
    if (need && this.infoTicker === -1) {
      this.infoTimerText = this.computeInfoTimerText();
      this.infoTicker = setInterval((): void => {
        this.infoTimerText = this.computeInfoTimerText();
      }, 1000);
    } else if (!need) {
      this.stopInfoTicker();
    }
  }

  /** 停掉信息窗刷新器并清空文案（幂等） */
  private stopInfoTicker(): void {
    if (this.infoTicker !== -1) {
      clearInterval(this.infoTicker);
      this.infoTicker = -1;
    }
    this.infoTimerText = '';
  }

  @State CatalogList: BasicDataSource<bookParser.CatalogItem> = new BasicDataSource<bookParser.CatalogItem>(); //章节数据
  readerComponentController: readerCore.ReaderComponentController = new readerCore.ReaderComponentController();
  //阅读器设置
  /**
   * 「目录 / 书签」弹窗的记忆：**搜索关键词**（2026-09-22 用户要求）。
   * 「顶部增加搜索栏，**直接参考书籍详情里面的目录的搜索能力**，就够用了」
   * ⚠️ 2026-09-23 弹窗改成 `ReaderCatalogDialog`（@CustomDialog）后，
   *    目录过滤在弹窗自己的 `filteredSource` 里做（见该文件）；本页这份 `catalogKeyword`
   *    只剩"记住上次输入、下次打开回填"的作用（打开时当 `initKeyword` 传进去）。
   */
  @State catalogKeyword: string = ''
  /** 「目录 / 书签」弹窗的当前页签（0=目录 1=书签）—— 只作"记忆"，打开时当 `initTab` 回填 */
  @State cdlTab: number = 0
  /**
   * 目录 / 书签弹窗控制器。**每次打开时新建** —— 与 `sleepDialog` 同理：
   * SDK `custom_dialog_controller.d.ts:756` 的 NOTE 原文
   * 「Custom dialog box parameters **do not support dynamic updates**」
   * ⇒ 预先建好再改传入值不会生效；要传"当前章号 / 日夜模式 / 页签 / 关键词"就只能每次新建。
   */
  private readerCatalogDialog: CustomDialogController | null = null
  @State readerSetting: readerCore.ReaderSetting = {
    // ⚠️ 必须写真实字体族名。平台查询结果（UIContext.getFont().getFontByName）：
    //   'HarmonyOS Sans'    → /system/fonts/HarmonyOS_Sans.ttf     （仅拉丁字形，342KB）
    //   'HarmonyOS Sans SC' → /system/fonts/HarmonyOS_Sans_SC.ttf  family = **鸿蒙黑体**（20MB 全字库）
    // 之前传占位字面量 '系统字体'（归一化成 system）或 'HarmonyOS Sans'，中文都没有字形，
    // 只能走回退 → targetSdkVersion 19→26 后落到 **HarmonyOS Sans Condensed（窄体）**，
    // 表现就是"字体窄窄的"。这里直接指名系统中文黑体族名 **鸿蒙黑体**，并把真实文件路径一并给出。
    fontName: '鸿蒙黑体',
    fontPath: '/system/fonts/HarmonyOS_Sans_SC.ttf',
    fontSize: 18,
    fontColor: '#000000',
    fontWeight: 400,
    lineHeight: 1.9,
    nightMode: false,
    themeColor: 'rgba(248, 249, 250, 1)',
    themeBgImg: '',
    flipMode: '0',
    scaledDensity: display.getDefaultDisplaySync().scaledDensity > 0 ?
    display.getDefaultDisplaySync().scaledDensity :
      1,
    viewPortWidth: this.windowWidth,
    viewPortHeight: this.windowHeight
  };
  private screenDensityCallBack: Callback<number> | null = null;
  private BookHandler: bookParser.BookParserHandler | null = null;
  private scrollerForList: ListScroller = new ListScroller();
  @State themeList: themeItem[] = [
    { fontColor: '#000000', themeColor: '#FFFFFF', themeBgImg: '', saved: false },
    { fontColor: '#000000', themeColor: '#c6b6a4', themeBgImg: '', saved: false },
    { fontColor: '#000000', themeColor: '#C5E7CE', themeBgImg: '', saved: false },
    { fontColor: '#FFFFFF', themeColor: '#202224', themeBgImg: '', saved: false },
  ]
  /**
   * 用户「保存方案」存下来的颜色（`#RRGGBB`，**全软件共用**）。
   * 与 `themeList` 一起构成「背景」那一行；渲染顺序 = 4 个内置推荐色 + 这些。
   */
  /** 已保存方案（V3：背景家族 × 字色家族，见 `SchemeV3`；仅用于计数/回调后刷新） */
  @State savedSchemes: SchemeV3[] = []

  // ══════════════════════════════════════════════════════════════════════════
  // 自定义背景色（2026-09-25 新增，用户设计）
  //
  // 用户需求原文（要点）：「设置页里面有背景颜色…现有的背景这一行作为**推荐色**，
  //   然后下一行增加一个滑块——自定义背景色；打开开关后出现**无极调色盘**（左）
  //   与 **RGB 滑块**（右，0-255）；滑动时出**气泡**提示实时数字并**伴随线性震动**；
  //   焦点在于用户的设置…常态化存储与持久化；每本书互不干扰则在底部加『同步全局』，
  //   不点则本书生效，点了则全软件同步生效。」
  //
  // 数据放哪：**不进 `readerCore.ReaderSetting`**（那是 ReaderKit 的接口，只有 13 个
  //   字段，塞不进去也不能塞），改走旁路 Preferences：`ReaderBg_<书名>` + `ReaderBgGlobal`
  //   （见 `common/utils/ReaderCustomBg.ets` 文件头）。
  //   ⚠️ 与 `readerSetting` 一样是**按书**的 —— 这正是"每本书互不干扰"的来源
  //     （`ReaderSetting_<书名>`，本文件 `aboutToAppear` / `registerPageShow`）。
  // ══════════════════════════════════════════════════════════════════════════
  /**
   * 自定义背景色开关（true = **背景当前就是**自定义纯色）。
   *
   * ⚠️ 2026-10-06 语义拆分（用户实测："点击自定义颜色开关，开启后无论是什么背景，都会被
   *   强制改成自定义颜色背景，此处不对，我们明明有逻辑，用户手动取色之后，点击保存才生效"）：
   *   旧实现里本字段身兼两职 —— 既是"调色盘展开"，也是"背景=自定义色"，而开关一开就
   *   `enterFreeMode() → applyCustomBg(true)` **立刻换背景** ⇒ 材质/推荐色当场让位。
   *   现在拆成两个：
   *     · `customBgOn`   = **已应用**（只有按「保存」或底栏"自由"模式才为 true，会落盘）
   *     · `customEditOn` = **调色盘展开中**（纯 UI 态，不落盘、不碰引擎）
   *   开关 `isOn` 与各调色盘区块的显隐都按"两者之一"判。
   */
  @State customBgOn: boolean = false
  /**
   * 调色盘是否展开（**纯编辑态**：不持久化、不动背景）。
   * 开开关只把它置 true ⇒ 用户可以随便试色，按「保存」才真正生效（`commitCustomColor`）。
   * ⚠️ 它与"自由"模式（底栏三态按钮 → `enterFreeMode`）不是一回事：那个是**应用**语义。
   */
  @State customEditOn: boolean = false
  /** 自定义背景色的 R / G / B，各 0-255（与 RGB 滑块、调色盘、预览块同源） */
  @State customBgR: number = 255
  @State customBgG: number = 255
  @State customBgB: number = 255
  /** 开关打开那一刻的 `ReaderSetting` 原值（关掉时**原样还回去**） */
  private customBgPrevTheme: string = ''
  private customBgPrevFont: string = ''
  private customBgPrevNight: boolean = false
  /** 用户是否**真的动过**这个控件（决定退出时要不要落盘，避免给"没碰过的书"留下覆盖记录） */
  private customBgTouched: boolean = false
  /** 上次真正下发 `setPageConfig` 的时刻（节流用，见 `CUSTOM_BG_APPLY_GAP_MS`） */
  private customBgAppliedAt: number = 0
  /** RGB 滑条轨道的实测宽度（vp）—— 气泡按滑块位置定位用（普通字段即可：读取发生在重建时） */
  private bgSliderW: number = 0
  /** 当前正在拖动、需要显示气泡的通道（-1 = 不显示；0/1/2 = R/G/B） */
  @State bgTipCh: number = -1

  // ── 材质背景（2026-09-25 新增，同日按用户意见二次改造）──────────────────────
  // 用户原话：「取消材质混合，没用，直接取消，**自定义就是自定义，背景就是背景
  //   （包括材质），区分开**。」「点击材质，自定义背景色一定会被打开，这是为什么？」
  // ⇒ ①混合模式整体拆除（纹理管线只剩"居中裁切→themeBgImg"一条路）；
  //   ②材质划入**背景家族**：点材质 = 选背景，**不再**顺手打开自定义开关
  //     （自定义颜色开着时点材质 = 退出自定义颜色、落到该材质）；
  //   ③「更多材质」弹窗装下批量材质（rawfile 里 texture_三位.jpg 全量枚举）。
  /** 当前选中的材质编号（texture_001 ⇒ 1；0 = 未用材质，走纯色路径） */
  @State bgTexId: number = 0
  /** 当前选中的自定义背景 id（'' = 未用；与 bgTexId 互斥，都是空 = 纯色） */
  @State bgCustomId: string = ''
  /** 自定义背景库版本号：导入/删除后 +1，驱动色板 ForEach 键变化强制重建 */
  @State customTexSeq: number = 0

  // ── 背景模糊（2026-09-26 新增；同日真机推翻第一版）──────────────────────────
  // 需求：设置面板「自定义颜色」开关之上加「背景模糊」开关 + 强度拖动条，常态化持久化。
  //
  // ── 为什么第一版（引擎背景透明 + 页面底下垫模糊层）被真机否决 ────────────────
  // 背景与文字都由 ReaderKit 引擎内部渲染，ArkUI 插不进"引擎的背景与文字之间"；
  // 第一版让引擎背景画全透明、自己在引擎之下垫模糊层。真机日志（用户 2026-09-26
  // `2.md`）证明引擎画布**不透底**：每次开模糊 `interactive set themeColor {"colorA":0}`
  // （日志 1301/2179/2479 行）⇒ 黑屏；关掉恢复 `{"colorA":1}`（1735 行）⇒ 正常。
  // 真机实测 > 一切 ⇒ 该路径整条拆除。
  //
  // ── 现行方案：把高斯模糊"洗进"图里再交给引擎 ────────────────────────────────
  // 引擎按需来要背景图（resourceRequest），那就**在给图之前先模糊好**：
  // `applyTextureBg` 改用 `ReaderTexture.blurredPath()`（effectKit `Filter.blur`，
  // 官方明示用于"background blurring / frosted glass"）产出的缓存图，
  // 引擎照旧铺图、排字 ⇒ 字永远清晰，等效"模糊层垫在背景之上、文字之下"。
  // 效率（用户拍板）：**分档预生成** —— 强度只有 `BG_BLUR_TIERS` 5 档（0-30 均分），
  // 每档一张磁盘缓存 JPEG，生成一次永久命中；面板用 `CapsuleSegmentButtonV2` 档位
  // 控件选档（用户要求：不用拖块），切档 = 换一个已缓存的文件路径 + 一次引擎重排。
  // 纯色/自定义颜色：纯色模糊仍是同一纯色（数学性质），无需处理、不受影响。
  /** 背景模糊开关（true = 材质图先按当前档位高斯模糊再交给引擎；false = 原图） */
  @State bgBlurOn: boolean = false
  /** 背景模糊强度 = 高斯模糊半径（px，作用于 ≤1440px 的合成图上）。只在 5 档间取值 */
  @State bgBlurRadius: number = BG_BLUR_RADIUS_DEFAULT
  /**
   * 「背景模糊」档位控件的选项（段文本 = 各档半径值）。
   * 创建一次挂成员（V2 `@Param items` 收的是 `@ObservedV2` 对象，反复 new 会丢选中态）。
   */
  private bgBlurSegItems: SegmentButtonV2Items = new SegmentButtonV2Items(
    BG_BLUR_TIERS.map((r: number): SegmentButtonV2ItemOptions => {
      const item: SegmentButtonV2ItemOptions = { text: r.toFixed(0) };
      return item;
    })
  )

  /** 当前强度 → 档位下标（旧记录被 normalize 吸附过 ⇒ 必在表内；兜底回第 0 档） */
  private bgBlurTierIndex(): number {
    const i: number = BG_BLUR_TIERS.indexOf(this.bgBlurRadius)
    return i >= 0 ? i : 0
  }

  /**
   * 背景选择的**焦点**（2026-09-25 用户设计，同日改为"保存键"方案）。
   *
   * 用户的最终裁定：「之前的焦点方案，改成这个**保存按钮**方案」——
   * 自定义颜色**不再拖动即生效**，拖出来的只是草稿，按「保存」才真正应用。
   * ⇒ 圈标的是**最后一次被明确确认的东西**：点推荐色/材质/方案/字色 = 立即应用并落圈；
   *   自定义颜色必须按「保存」才落圈（`'custom'`，圈画在「自定义颜色」行的预览块上）。
   *
   * 取值：'preset' 推荐色 / 'tex' 材质 / 'scheme' 保存方案 / 'font' 推荐字色 /
   *       'custom' 自定义颜色（保存按钮）
   */
  @State bgFocus: string = ''
  /** 焦点落在已保存方案上时，记那条方案的背景色（仅纯色方案用；'scheme' 圈的匹配键之一） */
  private schemeFocusBg: string = ''
  /**
   * 焦点落在已保存方案上时的**方案键**（`ReaderCustomBg.schemeKeyV3`）。
   * V3 起方案可以是纯色/材质/自定义材质 ⇒ 光靠颜色 hex 认不出「用的是哪一条」
   * （旧实现 `schemeFocusBg` 只对纯色方案成立）。弹窗按它给对应卡片画橙圈。
   */
  private schemeFocusKey: string = ''

  // ── 自定义字色（2026-09-25 新增）──────────────────────────────────────────
  // 用户原话：「缺少自定义文字颜色，都是系统的判定，也不对，应该和背景一样，
  //   有**两排推荐颜色**…第一行为亮色模式下推荐字体，第二行为暗色模式下推荐字体，
  //   下面自定义背景颜色改为**自定义颜色**，然后**通过滑块进行切换成背景还是颜色**，
  //   开关前面增加个**保存按钮**。」
  /** 字色是否自动对比（true = 按背景亮度自动黑/白；用户手动选过字色后为 false） */
  @State fontAuto: boolean = true
  /** 调色盘当前编辑的目标：false = 背景色，true = 文字颜色（"背景/文字"滑块） */
  @State fontTarget: boolean = false
  /** 自定义**字色**草稿 R/G/B（0-255）。与背景共用同一个调色盘，按 `fontTarget` 切换 */
  @State customFontR: number = 0
  @State customFontG: number = 0
  @State customFontB: number = 0

  /**
   * 气泡左上角 x（相对滑条轨道左边缘，vp）。
   *
   * 算法照抄官方 FAQ `faqs-arkui-1198` 的 `calculateExactPosition`：
   *   滑块中心 = 百分比 × (轨道宽 − 滑块宽) + 滑块宽 / 2；
   *   气泡 x   = clamp(滑块中心 − 气泡宽 / 2, 0, 轨道宽 − 气泡宽)（夹在轨道内，不出界）。
   * 轨道宽还没测到（=0）时返回 0，气泡先贴在左端，下一帧测到就归位。
   */
  private bgTipX(value: number): number {
    const w = this.bgSliderW
    if (!(w > 0)) {
      return 0
    }
    const blockW = 22
    const tipW = 44
    const percent = ReaderCustomBg.clamp(value, 0, 255) / 255
    const center = percent * (w - blockW) + blockW / 2
    return Math.max(0, Math.min(center - tipW / 2, w - tipW))
  }

  /**
   * 三条 RGB 滑条的 `onChange` 收口：气泡显隐 + **草稿**更新 + 线性震动。
   *
   * · `Begin / Moving / Click` ⇒ 显示气泡（内容 = 当前数字，随 @State 实时刷新）；
   * · 2026-09-25 用户改版（保存键方案）：滑条**只改草稿**（背景草稿或字色草稿，
   *   按 `fontTarget` 分流），**不再直接生效** —— 按「保存」按钮才应用到引擎并落盘。
   *   这就是"焦点问题"的最终解：圈永远标着最后一次被「保存」的东西。
   */
  private onCustomBgSliderChange(mode: SliderChangeMode, channel: number): void {
    const dragging: boolean = mode === SliderChangeMode.Begin
      || mode === SliderChangeMode.Moving
      || mode === SliderChangeMode.Click
    this.bgTipCh = dragging ? channel : -1
    HapticTick.tick()
  }

  /** 当前自定义背景色的 HEX（预览块 / 落盘都用它） */
  private customBgHex(): string {
    return ReaderCustomBg.hexOf(ReaderCustomBg.make(this.customBgR, this.customBgG, this.customBgB))
  }

  /** 当前自定义**字色**草稿的 HEX（调色盘切到"文字"时编辑它，按「保存」应用） */
  private customFontHex(): string {
    return ReaderCustomBg.hexOf(ReaderCustomBg.make(this.customFontR, this.customFontG, this.customFontB))
  }

  // ── 调色盘草稿读写（2026-09-25 保存键方案）────────────────────────────────
  // 调色盘/RGB 滑条永远只写**草稿**（背景草稿 customBgRGB 或字色草稿 customFontRGB，
  // 按 `fontTarget` 分流）；引擎与持久化只认「保存」按钮的 `commitCustomColor()`。

  private draftR(): number {
    return this.fontTarget ? this.customFontR : this.customBgR
  }

  private draftG(): number {
    return this.fontTarget ? this.customFontG : this.customBgG
  }

  private draftB(): number {
    return this.fontTarget ? this.customFontB : this.customBgB
  }

  private setDraft(r: number, g: number, b: number): void {
    if (this.fontTarget) {
      this.customFontR = r
      this.customFontG = g
      this.customFontB = b
    } else {
      this.customBgR = r
      this.customBgG = g
      this.customBgB = b
    }
  }

  /**
   * 「保存」按钮（2026-09-25 用户设计）：把草稿变成正式选择。
   * · 文字目标：`readerSetting.fontColor = 字色草稿`、`fontAuto = false`（自动对比停手）、
   *   下发排版 + 落盘；· 背景目标：走 `applyCustomBg(true)`。
   * 焦点（保存键方案）：确认后圈落到「自定义颜色」行预览块。
   */
  private commitCustomColor(): void {
    Haptics.tap()
    if (this.fontTarget) {
      this.readerSetting.fontColor = this.customFontHex()
      this.fontAuto = false
      this.readerComponentController.setPageConfig(this.readerSetting)
      this.customBgTouched = true
      this.saveCustomBg()
      this.bgFocus = 'custom'
      showMessage('字色已应用')
      return
    }
    if (!this.customBgOn) {
      // 开关没开也能保存（保存 = 确认使用）：按手动开开关的完整流程走
      this.customBgPrevTheme = this.readerSetting.themeColor
      this.customBgPrevFont = this.readerSetting.fontColor
      this.customBgPrevNight = this.readerSetting.nightMode
      this.customBgOn = true
    }
    this.bgFocus = 'custom'
    this.applyCustomBg(true)
    showMessage('背景色已应用')
  }

  /**
   * 点了某个**推荐字色**（2026-09-25 新增）：立即生效 + `fontAuto = false`
   * （手动选过字色 ⇒ 自动对比停手，尊重用户的选择）+ 落盘 + 圈落到这一格。
   *
   * ⚠️ 2026-10-06 修复"字体颜色无法变更"：旧写法把本方法整体包进 `animateTo` 闭包
   *   （FontRow 的 onClick），而本方法内含 `setPageConfig`（触发 ReaderKit 重排）——
   *   工程明文规则（`dispatchBarAction` 日/夜切换注释）："setPageConfig 留在闭包外面，
   *   它触发 ReaderKit 重新排版，不该参与动画"。⇒ 现在拆成两段：会插值的 @State 改动
   *   包进动画闭包；引擎下发（`setPageConfig`）与落盘在闭包外同步执行。
   */
  private applyFontColor(hex: string): void {
    const rgb = ReaderCustomBg.parseColor(hex)
    if (rgb === null) {
      return
    }
    this.getUIContext().animateTo(UiMotion.motionParam(UiMotion.SPRING_FAST), () => {
      this.readerSetting.fontColor = ReaderCustomBg.hexOf(rgb)
      this.fontAuto = false
      this.customFontR = rgb.r
      this.customFontG = rgb.g
      this.customFontB = rgb.b
      this.bgFocus = 'font'
    })
    this.customBgTouched = true
    this.readerComponentController.setPageConfig(this.readerSetting)
    this.saveCustomBg()
  }

  /**
   * 「背景」那一行的全部格子 = 4 个内置**推荐色** + **材质格** + 用户「保存方案」存下来的颜色。
   *
  /**
   * 「背景」那一行的全部格子 = 4 个内置**推荐色** + **前 8 个材质**。
   *
   * 2026-09-25 用户改版：①保存方案**移出**背景行（挪到「保存方案」按钮下方自成一块，
   * 且升级为 背景+字色 成对方案）；②材质只进**前八个**（`texture_001..008`），
   * 其余在「更多材质」弹窗里（用户原话：「只要在 rawfile 目录下名字叫做 texture_xxx.jpg
   * 的文件都编译，只是**前八个**进入设置主页，其他的在更多里面」）。
   * ⇒ 4 + 8 = 12 = 正好三行四列，不再需要溢出横向行。
   */
  /**
   * 「背景」那一行里，某一格是否该画选中圈（橙框）。
   *
   * 焦点规则（2026-09-25 用户最终裁定）：**圈 = 最后一次被明确确认的东西**。
   * 自定义颜色必须按「保存」才算确认（'custom'，圈画在自定义行预览块上）；
   * 推荐色 / 材质 / 方案 / 推荐字色点击即应用即确认（圈各自落到对应格子上）。
   */
  private isPresetSelected(item: themeItem): boolean {
    // 自定义背景格：最后一次确认的是这张图
    if (item.customId !== undefined) {
      return this.bgFocus === 'tex' && this.bgCustomId === item.customId
    }
    // 材质选择器格子：最后一次确认的是这个材质
    if (item.texId !== undefined) {
      return this.bgFocus === 'tex' && this.bgTexId === item.texId
    }
    // 内置推荐色：最后一次确认的是它（ themeColor 一致即可判定是哪一枚）
    return this.bgFocus === 'preset' && this.readerSetting.themeColor == item.themeColor
      && this.readerSetting.themeBgImg == item.themeBgImg
  }

  /** 「自定义颜色」行此刻是否持焦（最后按了「保存」）——预览圆点亮橙圈用 */
  private isCustomBgFocused(): boolean {
    return this.bgFocus === 'custom'
  }

  /**
   * 「更多材质」按钮此刻是否该持圈（2026-09-25 用户二轮反馈）。
   * 用户原话：「如果在更多材质中选择预览的十二个背景中的材质，那么这个材质会有选中红圈…
   *   如果以后加入了更多材质，**不在这个预览中，那么这个红框应该框选更多材质这个按钮**」。
   * 判定：焦点在材质上（bgFocus='tex'）且当前材质**不在主页前 8 个预览里**
   * （前 8 个之外都只在「更多材质」弹窗里出现）⇒ 圈画到按钮上。
   */
  private isTexOverflowFocused(): boolean {
    if (this.bgFocus !== 'tex') {
      return false
    }
    // 自定义背景不在预览行里（2026-09-27 精简）⇒ 圈画在「更多材质」按钮上
    if (this.bgCustomId.length > 0) {
      return true
    }
    if (this.bgTexId <= 0) {
      return false
    }
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext
    const main = ReaderTexture.items(ctx)
    // 预览行只有材质 001-004（2026-09-27 精简）⇒ 之外的圈画到按钮上
    for (let i = 0; i < main.length && i < 4; i++) {
      if (main[i].id === this.bgTexId) {
        return false
      }
    }
    return true
  }

  // ── 背景格布局（2026-09-25 用户改版：一行四个、最多三行、超出横向拖拽）──────

  /** 前 12 个格子按**一行 4 个**分块（最多三行，用户指定） */
  private swatchRows(): themeItem[][] {
    // 2026-09-27 用户裁定：预览**只留两行** —— 第一行 4 个纯色，第二行材质 001-004；
    // 其余（自定义背景、更多材质、保存方案）一律只进各自弹窗，不再挤进预览
    //（自定义背景挤进 4×3 后布局崩了，顺势按新口径精简）。
    const rows: themeItem[][] = [this.themeList.slice()]
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext
    const all = ReaderTexture.items(ctx)
    const mats: themeItem[] = []
    for (let i = 0; i < 4 && i < all.length; i++) {
      mats.push({
        fontColor: '#000000',
        themeColor: '#9E9E9E',
        themeBgImg: '',
        saved: false,
        texId: all[i].id,
        texFile: all[i].file
      })
    }
    rows.push(mats)
    return rows
  }

  /** 第 13 个起的溢出格子（进横向拖拽行，无限追加） */

  /** ForEach 的 key：两类格子来源不同，必须带来源前缀防撞 */
  private swatchKey(item: themeItem): string {
    // 自定义背景（2026-09-27）：id 唯一（themeColor 全是 #9E9E9E，不加分支会全键碰撞）
    if (item.customId !== undefined) {
      return 'cu-' + item.customId
    }
    if (item.texId !== undefined) {
      return 'tx-' + item.texId
    }
    return 'ps-' + item.themeColor
  }

  /** 格子底图：材质格画 rawfile 纹理预览（**缓存同一 Resource 实例**，防反复解码闪烁），纯色格是空串 */
  private swatchBgImage(item: themeItem): ResourceStr {
    if (item.customId !== undefined && item.customPath !== undefined) {
      return 'file://' + item.customPath
    }
    if (item.texId !== undefined && item.texFile !== undefined) {
      return ReaderTexture.res(item.texFile)
    }
    return item.themeBgImg
  }

  // ── 顶栏/底栏图标的资源解析（2026-09-25）──────────────────────────────────
  // 三个方法的存在理由相同：IDE 资源检查器要求 `$r()` 的参数是**字符串字面量**，
  // 把三元塞进 `$r()` 会报「Unknown resource source '…'」（把状态值当成资源名的误报，
  // 不影响编译与运行）。状态读取发生在 build 期间 ⇒ 状态变化时方法重新求值，
  // 与原内联写法完全等价；`ReplaceSymbolEffect` 的触发绑定不受影响。

  /** 顶栏闹钟图标：设定了定时 = 实心 */
  /**
   * 顶栏防窥眼睛图标（2026-10-07 用户设计）：闭眼 = 防窥已开启，睁眼 = 未开启。
   * 符号名 `eye` / `eye_slash` 在 SDK 符号表
   * `…\sdk\default\openharmony\ets\build-tools\ets-loader\sysResource.js` 查得。
   */
  private antiPeepIcon(): Resource {
    return this.antiPeepOn ? $r('sys.symbol.eye_slash') : $r('sys.symbol.eye')
  }

  /** 防窥开关（2026-10-07）：切两层防护（窗口隐私 + DLP 窥视蒙层，能力不足自动降级） */
  private toggleAntiPeep(): void {
    AntiPeep.setEnabled(!this.antiPeepOn)
    showMessage(this.antiPeepOn ? '防窥已开启' : '防窥已关闭')
  }

  /** 顶栏书签图标：当前页有书签 = 实心 */
  private bookmarkIcon(): Resource {
    return this.isBookmarked ? $r('sys.symbol.bookmark_fill') : $r('sys.symbol.bookmark')
  }

  /** 底栏设置图标：面板开着 = 实心 */
  private gearIcon(): Resource {
    return this.isShowContentSetting
      ? $r('sys.symbol.gearshape_fill')
      : $r('sys.symbol.gearshape')
  }

  /**
   * 背景格的**公共渲染体**（2026-09-25 抽出）：纯色 / 材质选择格 / 颜色方案 / 材质方案
   * 四种格子共用一套外观（含选中橙圈与删除小 X）。
   * `inScroll` = 是否在横向滚动行里：滚动行固定 60 宽；网格行 `layoutWeight(1)` 等分四列。
   * ⚠️ 与 `FlipModeButton()` 同理：@Builder 里读的是页面自己的 @State（选中态、自定义开关），
   *    由父级重建驱动刷新，`item` 是普通对象参数（每次 allSwatches() 重建时随 key 更新）。
   */
  @Builder
  SwatchCore(item: themeItem, inScroll: boolean) {
    Stack({ alignContent: Alignment.TopEnd }) {
      // 底色层
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor(item.themeColor)
      if (item.texId !== undefined || item.customId !== undefined) {
        // 预览图层（2026-09-27 闪动修复）：`sourceSize` 把解码限制在 256px ——
        // 原来整图 1200px 直接解码，硬解失败回软解要 7~20ms（真机日志 09-27 01:00
        // JPEG HW -16/-1 ×4），打开设置页时最大的一张（004，626KB）肉眼可见闪一下。
        Image(this.swatchBgImage(item))
          .width('100%')
          .height('100%')
          .objectFit(ImageFit.Cover)
          .sourceSize({ width: 256, height: 256 })
      }
      // 边框层（盖在图片之上，与旧"背景图+边框同节点"观感一致）
      Column()
        .width('100%')
        .height('100%')
        .borderWidth(this.isPresetSelected(item) ? 1 : 2)
        .borderColor(this.isPresetSelected(item) ? '#ff6600' : item.themeColor)
        .borderRadius(20)
        .hitTestBehavior(HitTestMode.None)
    }
    .height(30)
    .width(inScroll ? 60 : '100%')
    .layoutWeight(inScroll ? 0 : 1)
    // ⚠️ 圆角必须配 clip（2026-09-29 修"八个预览背景是四直角"）：borderRadius 只圆
    // **自身**的背景/边框，**不裁子节点** —— 旧实现底色层与预览图层都是直角铺满 100%，
    // 从圆角轮廓处溢出去 ⇒ 格子看起来是四直角（只有边框层自己是圆的）。
    // SDK 依据（MCP hover `CommonMethod.clip` 原文）：「Sets whether to clip the areas of
    //   child components that extend beyond this component's bounds, that is, whether to
    //   perform clipping based on **the edge contour of the parent container**.」
    // ⇒ `clip(true)` 按"父容器边缘轮廓"（含 borderRadius 圆角）裁剪子节点。
    // 半径与内部"边框层"取同值 20，保证裁剪轮廓与边框完全重合（不露直角毛边）。
    .borderRadius(20)
    .clip(true)
    .borderStyle(BorderStyle.Solid)
    .onClick(() => {
      Haptics.tap();
      // ── 自定义背景格（2026-09-27，背景家族）：点它 = 应用这张图，同材质语义 ──
      if (item.customId !== undefined) {
        Haptics.tap();
        this.getUIContext().animateTo(UiMotion.motionParam(UiMotion.SPRING_FAST), () => {
          this.pickCustom(item.customId as string)
        })
        return
      }
      // ── 材质选择格（2026-09-25，背景家族）：点它 = 落到该材质，不碰自定义开关 ──
      if (item.texId !== undefined) {
        Haptics.tap();
        this.getUIContext().animateTo(UiMotion.motionParam(UiMotion.SPRING_FAST), () => {
          this.pickTexture(item.texId as number)
        })
        return
      }
      // ── 内置推荐色（背景家族）：点它 = 落到该色，材质标记清零 ──────────────
      Haptics.tap();
      // 焦点（2026-09-25 用户设计）：点了推荐色 ⇒ 圈落到这一格
      this.bgFocus = 'preset'
      // 材质/自定义背景标记清零（推荐色与它们同属背景家族，互斥）
      this.bgCustomId = ''
      this.bgTexId = 0
      // 主题切换过渡动效（2026-09-21）：选中圈三个值是 @State 一级属性，
      // 包进 animateTo 后 borderColor/borderWidth 会插值过渡（SDK 依据见日夜切换处）。
      this.getUIContext().animateTo(UiMotion.motionParam(UiMotion.SPRING_FAST), () => {
        this.readerSetting.fontColor = item.fontColor;
        this.readerSetting.themeColor = item.themeColor;
        this.readerSetting.themeBgImg = item.themeBgImg;
      })
      // ★ 点了推荐色 = 用户改选"默认背景" ⇒ 离开自定义颜色模式（色值一律保留）。
      //   ⚠️ 必须放在 animateTo 之后：闭包已把三个值改成刚点的推荐色，才能记成新回退点。
      //   ⚠️ 2026-10-06：条件补上 `customEditOn` —— 只是"展开调色盘试色"时点推荐色，
      //     同样要收起调色盘并把新底色记成回退点（否则之后关开关会还原成更旧的那套）。
      if (this.customBgOn || this.customEditOn) {
        this.presetPickedWhileCustomBg(item.themeColor, item.fontColor, this.readerSetting.nightMode)
      }
      this.publishLtPageBg()   // 七轮：发布内容页外观给飞行层（见该方法注释）
      this.readerComponentController.setPageConfig(this.readerSetting);
    })
  }

  // ── 推荐字色行（2026-09-25 新增，用户设计）────────────────────────────────

  /** 一行推荐字色：`caption` 说明适配哪类背景；点任一枚立即应用（`applyFontColor`） */
  @Builder
  FontRow(colors: string[], caption: string) {
    Row({ space: 12 }) {
      Text(caption)
        .fontSize(11)
        .width(72)
        .fontColor(this.colorMode == 0 ? 'rgba(248, 249, 250, 0.6)' : 'rgba(19, 19, 19, 0.6)')
      ForEach(colors, (c: string) => {
        Column()
          .width(30)
          .height(30)
          .borderRadius(15)
          .backgroundColor(c)
          .borderWidth(this.bgFocus === 'font' && this.readerSetting.fontColor === c ? 2 : 1)
          .borderColor(this.bgFocus === 'font' && this.readerSetting.fontColor === c
            ? '#ff6600'
            : (this.colorMode == 0 ? 'rgba(248, 249, 250, 0.35)' : 'rgba(0, 0, 0, 0.25)'))
          .onClick(() => {
            Haptics.tap();
            this.applyFontColor(c)
          })
          .clickEffect(UiMotion.CLICK)
      }, (c: string) => 'f-' + c)
    }
    .width('100%')
  }

  // ── 已保存方案区（2026-09-25 用户改版：背景+字色成对缩略图，挪到按钮行下方）──


  // ══════════════════════════════════════════════════════════════════════════
  // 阅读页三模式：日间(1) / 夜间(0) / **自由(2)**（2026-09-26 用户设计）
  //
  // 用户原话：「增加一个模式，日间，夜间，**自由**，这样就更好了」。
  // 起因：原来开着自定义背景时按日/夜会把自定义背景**让位**（上一轮定的规则），
  //   用户反馈「如果点击日间或者夜间切换，就没了，这次设置就丢了」。
  // ⇒ 现在把「用自定义色」提升成一个**与日夜平级的模式**，由底栏那个按钮三态循环：
  //      日间 → 夜间 → 自由 → 日间 …
  //   进「自由」= 用你调/存的那个颜色；离开「自由」= 回到标准白/黑，
  //   但**你调好的色值一直留在记录里**（`ReaderBg_<书名>` 的 r/g/b 不因切模式而清空），
  //   下次回到「自由」原样恢复 ⇒ 设置不再"丢"。
  //
  // 模式是**派生**的，不新增持久化字段：
  //   customBgOn ⇒ 自由；否则看 `readerSetting.nightMode`（true = 夜间）。
  //   这样与既有的按书持久化（`ReaderSetting_<书名>`）天然一致，也不会出现两套状态打架。
  // ══════════════════════════════════════════════════════════════════════════

  /** 0 = 夜间，1 = 日间，2 = 自由 */
  private readerMode(): number {
    if (this.customBgOn) {
      return 2
    }
    return this.readerSetting.nightMode ? 0 : 1
  }

  /**
   * 按一下底栏那一格会切到哪个模式：**日间(1) → 夜间(0) → 自由(2) → 日间(1)**
   * （顺序就是用户原话里的「日间，夜间，自由」）。
   *
   * ⚠️ 代价说清楚：三态循环意味着**总有一个方向要按两下**。这里选的是
   *   「日间→夜间 一下（多数人是入夜才切）、夜间→日间 两下（夜间 → 自由 → 日间）」。
   *   想换顺序只改本方法里的三行即可（例如换成 日间→自由→夜间→日间）。
   */
  private nextReaderMode(): number {
    const m = this.readerMode()
    if (m === 1) {
      return 0
    }
    if (m === 0) {
      return 2
    }
    return 1
  }

  /** 某个模式对应的底栏文案 */
  private readerModeName(mode: number): string {
    if (mode === 2) {
      return '自由'
    }
    return mode === 0 ? '夜间' : '日间'
  }

  /**
   * 切到标准日/夜（离开「自由」）。
   *
   * ⚠️ 关键：**只把 `on` 置 false，r/g/b 原样写回**（`customBgRecord()` 带的就是当前 rgb）
   *   ⇒ 用户调好的颜色留在记录里，回到「自由」就能原样恢复。
   *   这正是上一版"设置丢了"的根因：`toggleCustomBg(true)` 每次都从当前 `themeColor`
   *   重新取 RGB，而这里已经把 `themeColor` 改成了标准白/黑。
   */
  private setStandardMode(night: boolean): void {
    this.customBgOn = false
    // 明确的白/黑选择 = 调色盘一并收起（`customEditOn` 是纯编辑态，见其注释）
    this.customEditOn = false
    this.colorMode = night ? 0 : 1
    this.readerSetting.nightMode = night
    this.readerSetting.fontColor = night ? '#ffffff' : '#000000'
    this.readerSetting.themeColor = night ? '#202224' : '#FFFFFF'
    this.readerSetting.themeBgImg = ''
    // 回到标准白/黑 = 明确选了推荐色背景 ⇒ 材质标记清零（推荐色与材质同属背景家族，互斥）
    this.bgCustomId = ''
    this.bgTexId = 0
    // 焦点（2026-09-25 用户设计）：关掉自定义 = 回到标准色 ⇒ 圈落到命中的推荐色上
    this.bgFocus = 'preset'
    NightMode.setReaderNight(night)
    this.syncAbilityColorMode()
    this.publishLtPageBg()   // 七轮：发布内容页外观给飞行层（见该方法注释）
    this.readerComponentController.setPageConfig(this.readerSetting)
    this.customBgTouched = true
    this.saveCustomBg()
  }

  /** 切到「自定义颜色」模式：用记录里存着的（或当前看到的）颜色；材质让位（背景家族分离） */
  private enterFreeMode(): void {
    this.customBgOn = true
    this.customBgTouched = true
    // 优先用**记录里存着的**色值；没有记录（第一次进自由）才拿当前主题色当起点，
    // 这样色盘是从"你现在看到的颜色"出发，不会一进来就跳成纯白。
    // ⚠️ 2026-09-25 语义收窄：材质属**背景家族**，进自定义颜色 = 纯色渲染（themeBgImg=''）；
    //   `bgTexId` **不清零**（记录里留着的材质，关掉自定义时若还在就原样恢复）。
    const rec = this.storedCustomBg()
    if (rec !== null) {
      this.customBgR = rec.r
      this.customBgG = rec.g
      this.customBgB = rec.b
    }
    // 焦点：进入自定义颜色 ⇒ 圈落到「自定义颜色」行的预览块（保存键方案）
    this.bgFocus = 'custom'
    this.applyCustomBg(true)
  }

  /** 取"本书记录 → 全局记录"里那条（与进书恢复用同一个解析顺序） */
  private storedCustomBg(): ReaderBgRecord | null {
    const name: string = this.bookData.bookName
    if (name === undefined || name === null || name.length === 0) {
      return null
    }
    return ReaderCustomBg.resolve(name)
  }

  /**
   * 应用一条已保存方案 **V3**（背景家族 × 字色家族，用户原话「点它 = 使用该方案」）。
   *
   * 与 V2 的关键差别（2026-10-06 用户诉求："预设颜色、材质、自定义颜色、材质、预设字色、
   * 自定义字色，全能自由搭配，并且被保存成方案"）：
   *   · 背景按 `bgKind` 分别走 纯色 / 内置材质 / 自定义材质 三条**同源**管线 ——
   *     旧实现无条件 `bgTexId = 0; bgCustomId = ''`，方案一用材质必丢；
   *   · 模糊属背景家族 ⇒ 先摆好 `bgBlurOn/bgBlurRadius` 再下背景（否则会拿旧档位出图）；
   *   · 字色按 `fontKind` 覆盖或拨回自动对比。
   * 背景源不存在（材质文件被删）时**只提示、不动当前背景**，绝不静默换成别的样子。
   */
  /** 方案链路诊断日志（2026-10-07 排查「唯一方案点选不生效」临时埋点，统一 SCHEME 前缀） */
  private schemeLog(m: string): void {
    hilog.info(0x0000, 'testTag', 'SCHEME %{public}s', m)
  }

  private applyScheme(e: SchemeV3): void {
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext
    // 诊断：stateEqual=true 时 applyComposedBg 的幂等守卫会静默跳过下发（用户看到"点了没反应"）
    const curKey: string = ReaderCustomBg.schemeKeyV3(this.currentScheme())
    this.schemeLog('apply in=' + JSON.stringify(e) + ' inKey=' + ReaderCustomBg.schemeKeyV3(e)
      + ' curKey=' + curKey + ' stateEqual=' + (curKey === ReaderCustomBg.schemeKeyV3(e)))
    // 方案与当前样子完全一致 ⇒ 引擎侧幂等守卫会跳过重排（防闪，见 applyComposedBg），
    // 这里不重摆状态，只补"已生效"的回执 + 把橙圈落到该方案（2026-10-07 用户实测
    // "无论如何选择方案A都没有实际应用"的根因：应用是成功的，只是零反馈）。
    if (curKey === ReaderCustomBg.schemeKeyV3(e)) {
      this.bgFocus = 'scheme'
      this.schemeFocusKey = ReaderCustomBg.schemeKeyV3(e)
      Haptics.tap()
      showMessage('当前已是该方案')
      return
    }
    // 先验目标背景是否还在（自定义材质被删是最常见的失效）
    if (e.bgKind === ReaderCustomBg.BG_KIND_TEX) {
      if (ReaderTexture.byId(ctx, e.texId) === null) {
        this.schemeLog('apply abort: tex missing texId=' + e.texId)
        showMessage('这条方案的材质已不存在')
        return
      }
    } else if (e.bgKind === ReaderCustomBg.BG_KIND_CUSTOM) {
      if (ReaderTexture.customById(ctx, e.customTexId) === null) {
        this.schemeLog('apply abort: custom missing id=' + e.customTexId)
        showMessage('这条方案的自定义材质已被删除')
        return
      }
    } else if (ReaderCustomBg.parseColor(e.bgHex) === null) {
      this.schemeLog('apply abort: bad bgHex=' + e.bgHex)
      return
    }
    // ── 字色家族（先摆好：`applyComposedBg` 只在 fontAuto 时自动对比字色）──────────
    if (e.fontKind === ReaderCustomBg.FONT_KIND_HEX) {
      const f = ReaderCustomBg.parseColor(e.fontHex)
      if (f !== null) {
        this.readerSetting.fontColor = ReaderCustomBg.hexOf(f)
        this.fontAuto = false
      }
    } else {
      this.fontAuto = true
    }
    // ── 背景模糊（属背景家族，随方案一起还原）────────────────────────────────────
    this.bgBlurOn = e.blurOn
    this.bgBlurRadius = ReaderCustomBg.snapBlurTier(e.blurRadius)
    // ── 背景家族 ────────────────────────────────────────────────────────────────
    this.customBgOn = false
    this.customEditOn = false
    this.bgCustomId = ''
    this.bgTexId = 0
    this.customBgTouched = true
    // 焦点：点了方案 ⇒ 「更多方案」按钮持圈，且对应卡片画橙圈（键与列表同源）
    this.bgFocus = 'scheme'
    this.schemeFocusKey = ReaderCustomBg.schemeKeyV3(e)
    Haptics.tap()
    if (e.bgKind === ReaderCustomBg.BG_KIND_TEX) {
      this.bgTexId = e.texId
      this.schemeLog('apply branch TEX texId=' + e.texId + ' -> applyTextureBg')
      this.applyTextureBg()
      return
    }
    if (e.bgKind === ReaderCustomBg.BG_KIND_CUSTOM) {
      this.bgCustomId = e.customTexId
      this.schemeLog('apply branch CUSTOM id=' + e.customTexId + ' -> applyTextureBg')
      this.applyTextureBg()
      return
    }
    const rgb = ReaderCustomBg.parseColor(e.bgHex)
    if (rgb === null) {
      return
    }
    this.customBgR = rgb.r
    this.customBgG = rgb.g
    this.customBgB = rgb.b
    this.schemeFocusBg = ReaderCustomBg.hexOf(rgb)
    this.schemeLog('apply branch COLOR hex=' + ReaderCustomBg.hexOf(rgb) + ' -> applyCustomBg')
    this.applyCustomBg(true)
  }

  /**
   * 把"当前看到的样子"打包成一条 V3 方案（「保存方案」存的就是它）。
   *
   * 背景种类按**当前真正生效**的那个判（三者互斥，见 `pickTexture` / `pickCustom`）：
   * `customBgOn`（自定义纯色）> `bgCustomId`（自定义材质）> `bgTexId`（内置材质）> 纯色。
   * ⚠️ 材质在用时 `themeColor` 只是**整图均色近似**，绝不能拿它当背景色存（旧实现就是这么错的）。
   */
  private currentScheme(): SchemeV3 {
    let bgKind: number = ReaderCustomBg.BG_KIND_COLOR
    let bgHex: string = this.readerSetting.themeColor
    let texId: number = 0
    let customTexId: string = ''
    if (this.customBgOn) {
      bgKind = ReaderCustomBg.BG_KIND_COLOR
    } else if (this.bgCustomId.length > 0) {
      bgKind = ReaderCustomBg.BG_KIND_CUSTOM
      customTexId = this.bgCustomId
      bgHex = ''
    } else if (this.bgTexId > 0) {
      bgKind = ReaderCustomBg.BG_KIND_TEX
      texId = this.bgTexId
      bgHex = ''
    }
    return {
      bgKind: bgKind,
      bgHex: bgHex,
      texId: texId,
      customTexId: customTexId,
      blurOn: this.bgBlurOn,
      blurRadius: this.bgBlurRadius,
      fontKind: this.fontAuto ? ReaderCustomBg.FONT_KIND_AUTO : ReaderCustomBg.FONT_KIND_HEX,
      fontHex: this.fontAuto ? '' : this.readerSetting.fontColor
    }
  }

  /** 「保存方案」：问一句再存（存的是**背景家族 + 字色家族**整条，见 ReaderCustomBg V3 说明） */
  /**
   * 本次待存的方案快照（打开确认弹窗时生成）——
   * 保证"弹窗里预览什么，落盘的就是什么"，不受弹窗期间状态波动影响。
   */
  private pendingScheme: SchemeV3 | null = null
  private openSaveSchemeDialog(): void {
    // 快照"当前正在用的样子"：背景种类 + 模糊档位 + 字色（V3：不再拿材质均色冒充背景色）
    const s: SchemeV3 = this.currentScheme()
    this.pendingScheme = s
    this.schemeLog('saveDialog snapshot=' + JSON.stringify(s))
    const dlg = new CustomDialogController({
      builder: ReaderSaveSchemeDialog({
        bgKind: s.bgKind,
        bgHex: s.bgHex,
        texId: s.texId,
        customTexId: s.customTexId,
        blurOn: s.blurOn,
        blurRadius: s.blurRadius,
        fontHex: s.fontKind === ReaderCustomBg.FONT_KIND_HEX ? s.fontHex : '',
        onConfirm: (): void => {
          this.commitScheme()
          // ⚠️ 关闭权在页面侧（真机日志定位：弹窗内 controller?.close() 曾失灵，
          //   页面持有的 controller 从未失手，见弹窗文件内说明）
          this.saveSchemeDialog?.close()
        },
        onCancel: (): void => {
          this.saveSchemeDialog?.close()
        }
      }),
      autoCancel: true,
      alignment: DialogAlignment.Center,
      width: '86%',
      cornerRadius: 20,
      customStyle: false,
      systemMaterial: ImmersiveMaterialUtil.sheetMaterial(),
      openAnimation: UiMotion.motionParam(UiMotion.SPRING_FAST),
      closeAnimation: UiMotion.motionParam(UiMotion.SPRING_FAST),
    })
    this.saveSchemeDialog = dlg
    dlg.open()
  }

  /** 每次新建的控制器（与 `sleepDialog` 同理：弹窗参数不支持动态更新） */
  private saveSchemeDialog: CustomDialogController | null = null

  /** 「更多材质」弹窗控制器（2026-09-25 新增，每次打开新建，参数不支持动态更新） */
  private texDialog: CustomDialogController | null = null

  /** 打开「更多材质」弹窗（rawfile 里全部 texture_三位.jpg，见 ReaderTextureDialog） */
  private openTexDialog(): void {
    this.settingDialog.close()
    this.texDialog = new CustomDialogController({
      builder: ReaderTextureDialog({
        currentId: this.bgTexId,
        currentCustomId: this.bgCustomId,
        onPick: (id: number): void => {
          this.pickTexture(id)
        },
        onPickCustom: (id: string): void => {
          this.pickCustom(id)
        },
        onChanged: (): void => {
          this.customTexSeq++
          // 删除了正在用的自定义背景 ⇒ 回落纯色
          const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext
          if (this.bgCustomId.length > 0 && ReaderTexture.customById(ctx, this.bgCustomId) === null) {
            this.bgCustomId = ''
            this.readerSetting.themeBgImg = ''
            this.applyCustomBg(true)
          }
        },
        onClose: (): void => {
          this.texDialog?.close()
          this.texDialog = null
          this.reopenSettings()
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
        this.texDialog = null
        this.reopenSettings()
      }
    })
    this.texDialog?.open()
  }

  /** 「更多方案」弹窗控制器（2026-09-25 新增，每次打开新建，参数不支持动态更新） */
  private schemeDialog: CustomDialogController | null = null

  /** 打开「更多方案」弹窗（全部已存方案，四列网格，见 ReaderSchemeDialog） */
  private openSchemeDialog(): void {
    this.settingDialog.close()
    this.schemeLog('openDialog focus=' + this.bgFocus + ' key=' + this.schemeFocusKey
      + ' list=' + JSON.stringify(ReaderCustomBg.loadSchemesV3()))
    this.schemeDialog = new CustomDialogController({
      builder: ReaderSchemeDialog({
        focusKey: this.bgFocus === 'scheme' ? this.schemeFocusKey : '',
        onPick: (e: SchemeV3): void => {
          this.applyScheme(e)
        },
        onClose: (): void => {
          this.schemeDialog?.close()
          this.schemeDialog = null
          this.reopenSettings()
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
        this.schemeDialog = null
        this.reopenSettings()
      }
    })
    this.schemeDialog?.open()
  }

  /** 「VIP 购买」弹窗控制器（2026-09-28 会员化：免费点锁定功能 → 本弹窗） */
  private vipDialog: CustomDialogController | null = null

  /** 打开 VIP 弹窗（先收设置面板，关闭后 reopenSettings——与字体/材质弹窗同款协调） */
  private openVipDialog(): void {
    this.settingDialog.close()
    this.vipDialog = new CustomDialogController({
      builder: VipDialog({
        dark: this.colorMode == 0,
        vipOwned: VipManager.isVip(),
        onClose: (): void => {
          this.vipDialog?.close()
          this.vipDialog = null
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
        this.reopenSettings()
      }
    })
    this.vipDialog.open()
  }

  /** 「保存方案」确认后落盘（数据取 `openSaveSchemeDialog` 的快照，见 V3 说明） */
  private commitScheme(): void {
    const s: SchemeV3 | null = this.pendingScheme
    if (s === null) {
      return
    }
    const r: string = ReaderCustomBg.addSchemeV3(s)
    this.schemeLog('commit result=' + r + ' snapshot=' + JSON.stringify(s))
    if (r === 'ok') {
      this.refreshSavedSchemes()
      showMessage('方案已保存')
    } else if (r === 'dup') {
      showMessage('这个方案已经保存过了')
    } else {
      showMessage(`最多保存 ${ReaderCustomBg.MAX_SCHEMES} 个方案，请先删掉几个`)
    }
  }

  /** 删掉一个保存的方案（右上角小 X）。只删清单，**不动**当前正在用的背景 */
  private removeScheme(e: SchemeV3): void {
    ReaderCustomBg.deleteSchemeV3(e)
    this.refreshSavedSchemes()
    showMessage('已删除')
  }

  private refreshSavedSchemes(): void {
    this.savedSchemes = ReaderCustomBg.loadSchemesV3()
  }

  /** 组装一条持久化记录 */
  private customBgRecord(): ReaderBgRecord {
    return {
      on: this.customBgOn,
      r: this.customBgR,
      g: this.customBgG,
      b: this.customBgB,
      prevTheme: this.customBgPrevTheme,
      prevFont: this.customBgPrevFont,
      prevNight: this.customBgPrevNight,
      texId: this.bgTexId,
      fontAuto: this.fontAuto,
      blurOn: this.bgBlurOn,
      blurRadius: this.bgBlurRadius,
      customTexId: this.bgCustomId
    }
  }

  /** 按书落盘（书名取不到时**不写**，绝不写出一条没有归属的记录） */
  private saveCustomBg(): void {
    const name: string = this.bookData.bookName
    if (name === undefined || name === null || name.length === 0) {
      return
    }
    ReaderCustomBg.saveBook(name, this.customBgRecord())
  }

  // ══════════════════════════════════════════════════════════════════════════
  // 字体管理（2026-09-26 新增）：库 = ReaderFontLib，弹窗 = ReaderFontDialog。
  // 「当前用哪支字体」随 readerSetting.fontName/fontPath **按书**持久化（现有机制，
  // migrateReaderSetting 打开时纠正/注册）；加粗走官方 fontWeight（400/700，d.ets:93-99）。
  // ══════════════════════════════════════════════════════════════════════════

  /** 应用字体（弹窗回调）：写 readerSetting → 引擎重排 → 高亮标尺重算 */
  private applyFont(name: string, path: string): void {
    this.markFontOverride()
    this.readerSetting.fontName = name
    this.readerSetting.fontPath = path
    this.readerComponentController.setPageConfig(this.readerSetting)
    this.updateHighlight()
  }

  private applyFontSize(v: number): void {
    this.markFontOverride()
    this.readerSetting.fontSize = Math.round(v)
    this.readerComponentController.setPageConfig(this.readerSetting)
    this.updateHighlight()
  }

  private applyLineHeight(v: number): void {
    this.markFontOverride()
    this.readerSetting.lineHeight = Math.round(v * 10) / 10
    this.readerComponentController.setPageConfig(this.readerSetting)
    this.updateHighlight()
  }

  /**
   * 用户在本书动了排版（字体/字号/行距）⇒ 本书登记为"字体覆盖"：
   * 「同步全局」时登记表清空，所有书回落全局排版（与背景家族的覆盖表同语义）。
   * 每个页面实例只登记一次（滑条拖动是连续回调，不能每帧写盘）。
   */
  private fontOverrideMarked: boolean = false

  private markFontOverride(): void {
    if (this.fontOverrideMarked) {
      return
    }
    this.fontOverrideMarked = true
    const name: string = this.bookData.bookName
    if (name !== undefined && name !== null && name.length > 0) {
      ReaderFontLib.addFontOverride(name)
    }
  }

  /**
   * 弹窗协调（2026-09-26，用户需求）：开子弹窗先关父弹窗（设置面板），子弹窗关闭再
   * 恢复父弹窗 —— 避免"三层弹窗叠罗汉"。双方都用 SPRING_FAST 弹簧，出入场在同一种
   * 节奏里交接（独立 dialog controller 做不到逐帧 30% 对齐，这是框架边界，观感已协调）。
   */
  private reopenSettings(): void {
    this.settingDialog.open()
  }

  /** 字体管理弹窗：controller 每次新建（与「更多材质/保存方案」同款，参数不支持动态更新） */
  private fontDialog: CustomDialogController | null = null

  private openFontDialog(): void {
    if (this.fontDialog !== null) {
      this.fontDialog.close()
      this.fontDialog = null
    }
    this.settingDialog.close()
    this.fontDialog = new CustomDialogController({
      builder: ReaderFontDialog({
        initFontSize: Math.round(this.readerSetting.fontSize),
        initLineHeight: this.readerSetting.lineHeight,
        curFontName: this.readerSetting.fontName,
        onFontSize: (v: number): void => this.applyFontSize(v),
        onLineHeight: (v: number): void => this.applyLineHeight(v),
        onFont: (name: string, path: string): void => this.applyFont(name, path),
        onClose: (): void => {
          this.fontDialog?.close()
          this.fontDialog = null
          this.reopenSettings()
        }
      }),
      autoCancel: true,
      alignment: DialogAlignment.Center,
      width: '86%',
      cornerRadius: 20,
      customStyle: false,
      systemMaterial: ImmersiveMaterialUtil.sheetMaterial(),
      openAnimation: UiMotion.motionParam(UiMotion.SPRING_FAST),
      cancel: (): void => {
        this.fontDialog = null
        this.reopenSettings()
      }
    })
    this.fontDialog.open()
  }

  /**
   * 把「保存」按钮确认的背景色**真正生效**：写进 `ReaderSetting` 并让 ReaderKit 重排。
   *
   * 写哪些字段（官方文档 `…/修改阅读设置/自定义页面背景/reader-setting-background` 原文）：
   *   「单独设置背景色。如果有设置背景图片的情况下，背景色通常用于仿真翻页时背面主题色的绘制。
   *     **否则，背景色还会用于渲染阅读页的背景色。**」
   *   ⇒ `themeColor = 选中的颜色`、`themeBgImg = ''`（纯色渲染路径）。
   *
   * 字色 / 夜间模式：同文档原文「更改页面背景色，可能会涉及到字体颜色和深色模式的适配。…」
   *   ⇒ `nightMode` 永远按背景亮度摆正（日夜必须跟底色一致，否则仿真翻页错乱）；
   *     `fontColor` 只在 `fontAuto = true` 时自动对比 —— 用户手动选过字色（推荐字色行 /
   *     自定义字色保存）后 `fontAuto = false`，自动对比**停手**，尊重用户的选择。
   *
   * @param commit true = 按「保存」确认（落盘）；false = 进模式等内部收口（也落盘）
   */
  private applyCustomBg(commit: boolean): void {
    const rgb = ReaderCustomBg.make(this.customBgR, this.customBgG, this.customBgB)
    this.readerSetting.themeColor = ReaderCustomBg.hexOf(rgb)
    this.readerSetting.themeBgImg = ''
    const dark: boolean = ReaderCustomBg.isDarkBg(rgb)
    // 只有"日/夜真的翻了"才去动 Ability 配色：`NightMode.sync()` 会调
    // `ctx.setColorMode()`（一次系统级重涂），绝不能每帧调。
    const flipped: boolean = (this.colorMode === 0) !== dark
    if (this.fontAuto) {
      this.readerSetting.fontColor = ReaderCustomBg.contrastFont(rgb)
    }
    this.readerSetting.nightMode = dark
    this.colorMode = dark ? 0 : 1
    NightMode.setReaderNight(dark)
    if (flipped) {
      this.syncAbilityColorMode()
    }
    const now: number = Date.now()
    if (commit || now - this.customBgAppliedAt >= CUSTOM_BG_APPLY_GAP_MS) {
      this.customBgAppliedAt = now
      this.publishLtPageBg()   // 七轮：发布内容页外观给飞行层（见该方法注释）
      this.readerComponentController.setPageConfig(this.readerSetting)
    }
    if (commit) {
      this.customBgTouched = true
      this.saveCustomBg()
    }
  }

  // ══════════════════════════════════════════════════════════════════════════
  // 材质背景（2026-09-25）：**背景家族**的一员（纯材质，混合模式已按用户要求拆除）
  //
  // 用户原话：「取消材质混合，没用，直接取消，自定义就是自定义，背景就是背景
  //   （包括材质），区分开。」
  //
  // 生效路径（官方文档取证见 `ReaderTexture.ets` 文件头）：
  //   合成图（按屏幕比例居中裁切）→ 沙箱缓存 → `readerSetting.themeBgImg = 路径`
  //   → `setPageConfig`。`themeColor` 同步设为**整图均色**（官方原文：
  //   「设置背景图片。需要同时设置与背景图片相近的主题颜色，用于仿真翻页时背面主题色的绘制」）。
  //   `nightMode` 按均色亮度摆正；字色只在 `fontAuto` 时自动对比。
  // ══════════════════════════════════════════════════════════════════════════

  /**
   * 材质背景的真正生效入口（选中材质时走这里）。
   *
   * 幂等设计（治"每次进设置页闪一下"）：`themeBgImg` 已是目标缓存路径且配色没变时
   * **跳过 setPageConfig** —— 引擎重设同一张图会触发一次可见的重绘闪动。
   */
  private applyTextureBg(): void {
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext
    this.schemeLog('applyTextureBg bgTexId=' + this.bgTexId + ' bgCustomId=' + this.bgCustomId
      + ' customBgOn=' + this.customBgOn)
    // ── 自定义背景分支（2026-09-27）：来源=沙箱文件，合成/均色/模糊与材质同管线 ──
    if (this.bgCustomId.length > 0) {
      const src = ReaderTexture.customById(ctx, this.bgCustomId)
      if (src === null) {
        this.schemeLog('applyTextureBg custom missing -> 回落纯色')
        // 源图已被删除 ⇒ 回落纯色，绝不让页面挂死
        this.bgCustomId = ''
        this.readerSetting.themeBgImg = ''
        this.applyCustomBg(true)
        return
      }
      ReaderTexture.composedPathSrc(ctx, src.path, 'c' + this.bgCustomId,
        display.getDefaultDisplaySync().width, display.getDefaultDisplaySync().height)
        .then((res: ComposeResult): void => { this.applyComposedBg(ctx, res) })
      this.customBgTouched = true
      this.saveCustomBg()
      return
    }
    const tex = ReaderTexture.byId(ctx, this.bgTexId)
    if (tex === null || this.bgTexId <= 0) {
      this.readerSetting.themeBgImg = ''
      this.applyCustomBg(true)
      return
    }
    ReaderTexture.composedPath(ctx, this.bgTexId,
      display.getDefaultDisplaySync().width, display.getDefaultDisplaySync().height)
      .then((res: ComposeResult): void => { this.applyComposedBg(ctx, res) })
    this.customBgTouched = true
    this.saveCustomBg()
  }

  /**
   * 材质/自定义背景**共用的下游**（2026-09-27 从 applyTextureBg 抽出）：
   * 均色配色 → 字色/夜间联动 → （背景模糊：注入 CSS 版加粗同款分档缓存）
   * → 幂等检查 → setPageConfig → 后台预生成模糊档。
   */
  private async applyComposedBg(ctx: common.UIAbilityContext, res: ComposeResult): Promise<void> {
    if (this.disposed) {
      return
    }
    const avgHex = ReaderCustomBg.hexOf(res.avg)
    const dark: boolean = ReaderCustomBg.isDarkBg(res.avg)
    const flipped: boolean = (this.colorMode === 0) !== dark
    const nextFont = this.fontAuto
      ? ReaderCustomBg.contrastFont(res.avg)
      : this.readerSetting.fontColor
    // ── 背景模糊（2026-09-26）：把高斯模糊"洗进"图里再交给引擎 ──────────────
    // 真机实测引擎画布不透底（透明主题色 = 黑屏，见 bgBlurOn 注释），故在**给图
    // 之前**按当前档位模糊（分档磁盘缓存：命中零等待，未命中现场生成一次）。
    // 模糊失败回落原图 —— 绝不让页面黑屏。模糊不改变平均色 ⇒ 字色/夜间逻辑复用 res.avg。
    let finalPath: string = res.path
    if (res.path.length > 0 && this.bgBlurOn) {
      finalPath = await ReaderTexture.blurredPath(ctx, res.path, this.bgBlurRadius)
      if (finalPath.length === 0) {
        finalPath = res.path
      }
      // await 期间页面可能已销毁
      if (this.disposed) {
        return
      }
    }
    // 幂等：最终图路径 + 配色全都没变 ⇒ 不再下发 setPageConfig（防闪）
    this.schemeLog('composed in res=' + res.path + ' final=' + finalPath
      + ' avg=' + ReaderCustomBg.hexOf(res.avg) + ' nextFont=' + nextFont + ' dark=' + dark
      + ' | cur img=' + this.readerSetting.themeBgImg + ' color=' + this.readerSetting.themeColor
      + ' font=' + this.readerSetting.fontColor + ' night=' + this.readerSetting.nightMode)
    if (finalPath.length > 0 && this.readerSetting.themeBgImg === finalPath
      && this.readerSetting.themeColor === avgHex
      && this.readerSetting.fontColor === nextFont
      && this.readerSetting.nightMode === dark) {
      this.schemeLog('composed IDEMPOTENT-SKIP: 状态已等于目标（点方案时=该方案本已生效）')
      return
    }
    this.readerSetting.themeBgImg = finalPath
    this.readerSetting.themeColor = avgHex
    this.readerSetting.fontColor = nextFont
    this.readerSetting.nightMode = dark
    this.colorMode = dark ? 0 : 1
    NightMode.setReaderNight(dark)
    if (flipped) {
      this.syncAbilityColorMode()
    }
    this.publishLtPageBg()   // 七轮：发布内容页外观给飞行层（见该方法注释）
    this.readerComponentController.setPageConfig(this.readerSetting)
    // ── 后台预生成全部 5 档（含当前档，磁盘命中零成本）⇒ 之后拖动条切档零等待 ──
    if (this.bgBlurOn && finalPath.length > 0) {
      ReaderTexture.preGenerateTiers(ctx, res.path)
    }
  }

  /**
   * 用户点了一个材质格（背景家族）：**不再**顺手打开自定义颜色（用户质问的原话：
   * 「点击材质，自定义背景色一定会被打开，这是为什么？」）。若自定义颜色正开着，
   * 点材质 = 退出自定义颜色、落到该材质。
   */
  private pickTexture(id: number): void {
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext
    if (ReaderTexture.byId(ctx, id) === null) {
      return
    }
    this.bgCustomId = ''
    this.bgTexId = id
    if (this.customBgOn) {
      // 材质与自定义颜色互斥（同一时间背景只能是一种）：退出自定义，材质顶上
      this.customBgOn = false
    }
    // 点材质 = 明确选了背景 ⇒ 调色盘收起（纯编辑态）
    this.customEditOn = false
    this.customBgTouched = true
    // 焦点：点了材质 ⇒ 圈落到这一格
    this.bgFocus = 'tex'
    Haptics.tap()
    this.applyTextureBg()
  }

  /**
   * 点了自定义背景格（2026-09-27，背景家族）：应用这张图，语义与 pickTexture 完全一致
   * （退出自定义颜色、焦点落到格子、走同一合成管线）。
   */
  private pickCustom(id: string): void {
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext
    if (ReaderTexture.customById(ctx, id) === null) {
      return
    }
    this.bgCustomId = id
    this.bgTexId = 0
    if (this.customBgOn) {
      this.customBgOn = false
    }
    // 点自定义材质 = 明确选了背景 ⇒ 调色盘收起（纯编辑态）
    this.customEditOn = false
    this.customBgTouched = true
    this.bgFocus = 'tex'
    Haptics.tap()
    this.applyTextureBg()
  }

  /**
   * 设置面板里那个「自定义颜色」开关。
   *
   * ⚠️ 2026-10-06 修正（用户实测）：「点击自定义颜色开关，开启后无论是什么背景，都会被强制
   *   改成自定义颜色背景，此处不对，我们明明有逻辑，**用户手动取色之后，点击保存才生效**」。
   *   ⇒ 开开关**只展开调色盘**（`customEditOn = true`），背景一个字节都不动；
   *     真正生效只走「保存」（`commitCustomColor` → `applyCustomBg(true)` → `customBgOn = true`）。
   *   ⇒ 关开关 = 收起调色盘；若此前**已应用**过自定义色，再把背景原样还回去
   *     （材质 / 自定义材质顶回来，否则恢复"进入编辑前"的推荐色快照）。
   *   ⚠️ 唯一"开关一开即生效"的路径是底栏三态按钮的**自由模式**（`enterFreeMode`，
   *     那是用户明确要的"自由"语义），与这里的编辑开关不是一回事。
   */
  private toggleCustomBg(on: boolean): void {
    this.customBgTouched = true
    if (on) {
      this.customEditOn = true
      if (!this.customBgOn) {
        // 快照"进入编辑前"的背景：关掉时原样还回去（材质/推荐色都不丢）
        this.customBgPrevTheme = this.readerSetting.themeColor
        this.customBgPrevFont = this.readerSetting.fontColor
        this.customBgPrevNight = this.readerSetting.nightMode
      }
      // 草稿起点 = 记录里存着的色值（第一次进则沿用当前主题色，见 `restoreCustomBg`）
      const rec = this.storedCustomBg()
      if (rec !== null) {
        this.customBgR = rec.r
        this.customBgG = rec.g
        this.customBgB = rec.b
      }
      // ⚠️ 这里**不设 `bgFocus`**：圈 = 最后一次被明确确认的东西（见 `isPresetSelected`
      //   注释），仅仅展开调色盘不算确认 —— 按「保存」才落圈。
      return
    }
    this.customEditOn = false
    if (!this.customBgOn) {
      // 只是编辑态（从没保存过）⇒ 关掉无需还原任何东西：背景一直是原样
      return
    }
    this.customBgOn = false
    // ⚠️ 自定义材质（`bgCustomId`）也必须在这里顶回来 —— 旧写法只判 `bgTexId > 0`，
    //   用自定义材质时会掉进 `restorePrevBackground()`（它把 `themeBgImg` 清空）⇒ 材质丢。
    if (this.bgTexId > 0 || this.bgCustomId.length > 0) {
      // 关掉自定义颜色 ⇒ 上次选的材质（背景家族）顶回来（"设置不丢"）
      this.bgFocus = 'tex'
      this.applyTextureBg()
      return
    }
    // 2026-09-25 用户五轮反馈：「点击关闭自定义颜色，现在正在用的自定方案也会被重置，
    //   这个不对，不应该直接被杀死，因为**已经保存的方案是既定的**，不是随意支配的孩子」
    // ⇒ 不再跳标准白/黑，而是**恢复进入自定义之前的那套背景**（prev* 快照原样回来）。
    this.restorePrevBackground()
  }

  /**
   * 恢复「进入自定义颜色之前」的背景（toggleCustomBg(false) 专用）。
   *
   * 开自定义那一刻快照的 prev*（themeColor/fontColor/nightMode）原样还原：
   * 之前用的是保存方案就回到方案、是推荐色就回推荐色 —— 方案是"既定的成年人"，
   * 不被自定义开关随意支配（用户原话）。
   * ⚠️ 「日/夜」三模式按钮仍走 `setStandardMode`（那是明确的白/黑选择，不受影响）。
   */
  private restorePrevBackground(): void {
    const rgb = ReaderCustomBg.parseColor(this.customBgPrevTheme)
    if (rgb === null) {
      // 快照解析不了（极端脏数据）⇒ 退回旧兜底
      this.setStandardMode(this.customBgPrevNight)
      return
    }
    this.readerSetting.themeColor = ReaderCustomBg.hexOf(rgb)
    this.readerSetting.themeBgImg = ''
    this.readerSetting.nightMode = this.customBgPrevNight
    this.readerSetting.fontColor = this.fontAuto
      ? ReaderCustomBg.contrastFont(rgb)
      : this.customBgPrevFont
    this.colorMode = this.customBgPrevNight ? 0 : 1
    NightMode.setReaderNight(this.customBgPrevNight)
    this.syncAbilityColorMode()
    // 焦点：恢复色恰好是最后一次应用的方案 ⇒ 圈落回「更多方案」按钮；否则落推荐色
    this.bgFocus = (this.schemeFocusBg.length > 0
      && this.schemeFocusBg === ReaderCustomBg.hexOf(rgb)) ? 'scheme' : 'preset'
    this.publishLtPageBg()   // 七轮：发布内容页外观给飞行层（见该方法注释）
    this.readerComponentController.setPageConfig(this.readerSetting)
    this.customBgTouched = true
    this.saveCustomBg()
  }

  /**
   * 用户点了某个**推荐色** ⇒ 离开自定义颜色模式，落到该推荐色。
   * 材质标记清零（推荐色与材质同属背景家族，互斥）。
   */
  private presetPickedWhileCustomBg(bgTheme: string, fontColor: string, night: boolean): void {
    this.customBgOn = false
    // 点推荐色 = 明确选了背景 ⇒ 调色盘收起（纯编辑态）
    this.customEditOn = false
    this.bgCustomId = ''
    this.bgTexId = 0
    this.customBgTouched = true
    this.bgFocus = 'preset'
    this.customBgPrevTheme = bgTheme
    this.customBgPrevFont = fontColor
    this.customBgPrevNight = night
    const rgb = ReaderCustomBg.parseColor(bgTheme)
    if (rgb !== null) {
      const dark = ReaderCustomBg.isDarkBg(rgb)
      const flipped = (this.colorMode === 0) !== dark
      this.readerSetting.nightMode = dark
      this.colorMode = dark ? 0 : 1
      NightMode.setReaderNight(dark)
      if (flipped) {
        this.syncAbilityColorMode()
      }
    }
    this.saveCustomBg()
  }

  /**
   * 「同步全局」：把当前这条记录写成全软件默认，并清掉各书的覆盖。
   * 2026-09-27 拓展：排版三件套（字体/字号/行距）一并全局化 —— 语义与背景家族相同：
   * 全局记录 + 清空各书覆盖登记表，之后所有书打开时回落到这份全局排版。
   */
  private syncCustomBgGlobal(): void {
    const cleared: number = ReaderCustomBg.syncGlobal(this.customBgRecord())
    let fontCleared: number = 0
    const name: string = this.bookData.bookName
    if (name !== undefined && name !== null && name.length > 0) {
      ReaderFontLib.saveFontGlobal({
        fontName: this.readerSetting.fontName,
        fontPath: this.readerSetting.fontPath,
        fontSize: Math.round(this.readerSetting.fontSize),
        lineHeight: this.readerSetting.lineHeight
      })
      fontCleared = ReaderFontLib.clearFontOverrides()
      // 本书刚成为全局基准 ⇒ 不再算"覆盖"，之后的改动重新登记
      this.fontOverrideMarked = false
    }
    if (cleared === 0 && fontCleared === 0) {
      showMessage('已设为全部书籍的默认背景与字体排版')
    } else {
      showMessage(`已同步到全部书籍（背景覆盖清除 ${cleared} 本，字体排版覆盖清除 ${fontCleared} 本）`)
    }
  }

  /**
   * 进书恢复态若与某条已存方案**完全一致** ⇒ 焦点/橙圈落到「更多方案」按钮与该卡片
   * （V3 设计原文："当前正在使用的方案画橙圈"）。此前恢复一律落 `bgFocus='tex'/'preset'`，
   * 用户重新进书后打开「更多方案」看不到橙圈，会误以为方案没生效（2026-10-07 实测）。
   * 必须在 `bgTexId/bgCustomId/fontAuto/blur` 都已从记录读回**之后**调用（键依赖这些字段）。
   */
  private markSchemeFocusIfMatched(): void {
    const key: string = ReaderCustomBg.schemeKeyV3(this.currentScheme())
    const list: SchemeV3[] = ReaderCustomBg.loadSchemesV3()
    for (const x of list) {
      if (ReaderCustomBg.schemeKeyV3(x) === key) {
        this.bgFocus = 'scheme'
        this.schemeFocusKey = key
        this.schemeLog('restore matched scheme key=' + key)
        return
      }
    }
  }

  /**
   * 进书时恢复自定义背景色（在 `readerSetting` 载入 + 迁移**之后**、`startPlay` **之前**调用）。
   *
   * 解析顺序（`ReaderCustomBg.resolve`）：**本书记录 → 全局记录 → 都没有则维持推荐色**。
   * ⇒ 「不点同步全局则本书生效」：改这本书只会写 `ReaderBg_<本书>`；
   *   「点了则全软件同步生效」：全局记录 + 清空所有本书覆盖（见 `syncGlobal`）。
   */
  private restoreCustomBg(): void {
    const cur = ReaderCustomBg.parseColor(this.readerSetting.themeColor)
    if (cur !== null) {
      this.customBgR = cur.r
      this.customBgG = cur.g
      this.customBgB = cur.b
    }
    const name: string = this.bookData.bookName
    if (name === undefined || name === null || name.length === 0) {
      return
    }
    const rec = ReaderCustomBg.resolve(name)
    this.schemeLog('restore rec=' + (rec === null ? 'null' : JSON.stringify(rec)))
    if (rec === null) {
      // 本书从没动过背景 ⇒ 维持推荐色，圈落到命中的推荐色
      this.bgFocus = 'preset'
      return
    }
    this.customBgOn = rec.on
    this.customBgR = rec.r
    this.customBgG = rec.g
    this.customBgB = rec.b
    this.customBgPrevTheme = rec.prevTheme
    this.customBgPrevFont = rec.prevFont
    this.customBgPrevNight = rec.prevNight
    // 材质状态（2026-09-25）：记录里的三位编号读回（材质属背景家族，on=false 也渲染）
    this.bgTexId = rec.texId
    // 字色自动对比开关读回（2026-09-25：用户手动选过字色的书不再被自动覆盖）
    this.fontAuto = rec.fontAuto
    // 背景模糊读回（2026-09-26）：开关 + 强度。旧记录没有这两个字段，
    // `normalize` 已按"默认关 + 默认强度"补齐（AGENTS.md：改默认值必须同时迁移旧值）。
    // ⚠️ 必须在下面任何 `return` 之前赋值 —— 材质/推荐色分支提前返回时也要带上模糊状态
    //   （模糊属于背景家族，与"自定义颜色是否开着"无关）。
    this.bgBlurOn = rec.blurOn
    this.bgBlurRadius = rec.blurRadius
    // 自定义背景读回（2026-09-27）：与材质同属背景家族（on=false 也渲染）
    this.bgCustomId = rec.customTexId
    if (!rec.on) {
      if (rec.customTexId.length > 0) {
        this.bgFocus = 'tex'
        this.markSchemeFocusIfMatched()
        this.applyTextureBg()
        return
      }
      if (rec.texId > 0) {
        // 记录是"本书选了材质"（背景家族）⇒ 照常恢复材质
        this.bgFocus = 'tex'
        this.markSchemeFocusIfMatched()
        this.applyTextureBg()
        return
      }
      // 记录只是"本书显式选了推荐色" ⇒ 不能去动 `readerSetting`，
      // 否则会把用户在推荐色那一行自己挑的颜色覆盖掉。焦点：圈落到命中的推荐色
      this.bgFocus = 'preset'
      return
    }
    // 自定义颜色模式 ⇒ 圈落在「自定义颜色」行（保存键方案）
    this.bgFocus = 'custom'
    const rgb = ReaderCustomBg.make(rec.r, rec.g, rec.b)
    this.readerSetting.themeColor = ReaderCustomBg.hexOf(rgb)
    this.readerSetting.themeBgImg = ''
    if (this.fontAuto) {
      this.readerSetting.fontColor = ReaderCustomBg.contrastFont(rgb)
    }
    this.readerSetting.nightMode = ReaderCustomBg.isDarkBg(rgb)
    // `colorMode` 由 `aboutToAppear` 后面那句 `this.readerSetting.nightMode ? 0 : 1` 统一收口，
    // 这里不重复写（避免两处口径）。
  }

  /**
   * 把「内容页长什么样」发布给书架→阅读器一镜到底的飞行层（七轮 2026-09-30）。
   *
   * ── 为什么需要 ────────────────────────────────────────────────────────────
   * 真机日志（`Downloads\2.md`）实证：返回一开始 NavDestination 就进 `onHidden`
   * （22:07:16.894），而我们的自定义转场 22:07:16.895 才起 ⇒ 阅读器的 RS surface
   * 那一层不再合成（截图逐像素也证明：飞行书盒子内部能看到书架自己的黑色标题字）
   * ⇒ 飞行层裁剪层是"空的"，没被封面盖住的地方直接漏出书架定格图
   * （用户原话："原位有一本书在，然后我们的书关闭动画缩放完又落在上面了"）。
   * 飞行层拿不到 `readerSetting`（它是本页私有状态）⇒ 由本页把页面外观发布到 AppStorage，
   * 飞行层照它铺一层底衬（见 `Index.ets` 飞行分支的裁剪层 / `UiMotion.LT_PAGE_BG`）。
   *
   * ── 调用点 ────────────────────────────────────────────────────────────────
   * 每个**真正改页面外观**的地方，紧挨着既有的 `setPageConfig(...)`：
   * 推荐色、自定义颜色、材质/纹理背景、日夜标准色、`aboutToAppear` 首次下发。
   * 幂等、无副作用（只写两个 AppStorage 字符串）。
   */
  private publishLtPageBg(): void {
    if (!UiMotion.LT_PAGE_BG) {
      return
    }
    // 背景图：`themeBgImg` 是**沙箱路径**（见 applyTextureBg / applyComposedBg）；
    // ⚠️ `Image` **不接受裸沙箱路径**，必须转成沙箱 URI —— 官方 FAQ
    // `FAQ/UI框架/组件使用/Image组件如何读入沙箱内的图片/faqs-arkui-154` 原文：
    //   「Image组件**不能直接传入应用沙箱路径**，需要传入应用沙箱URI。…调用
    //    `fileUri.getUriFromPath` 方法将沙箱路径转化为沙箱 URI，传入之后即可正常显示沙箱图片。」
    // （API：`fileUri.getUriFromPath(path: string): string`，SDK `@ohos.file.fileuri.d.ts`，
    //   @since 15，会抛 401 ⇒ 必须包 try/catch。）
    // 非绝对路径（例如 themeBgImg 里存的是 rawfile 名）一律不发布图片，只留纯色底。
    const raw: string = this.readerSetting.themeBgImg ?? ''
    let img: string = ''
    if (raw.startsWith('/')) {
      try {
        img = fileUri.getUriFromPath(raw)
      } catch (e) {
        img = ''
        hilog.info(0x0000, 'testTag', 'LTBOOK publish page bg img uri failed: %{public}s',
          (e as BusinessError)?.message ?? 'error')
      }
    }
    AppStorage.setOrCreate(UiMotion.LT_PAGE_BG_KEY, this.readerSetting.themeColor ?? '')
    AppStorage.setOrCreate(UiMotion.LT_PAGE_IMG_KEY, img)
    hilog.info(0x0000, 'testTag', 'LTBOOK publish page bg color=%{public}s img=%{public}s',
      this.readerSetting.themeColor ?? '', img)
  }

  async aboutToAppear() {
    // ★ 组件重新进入 ⇒ 清掉"已销毁"标志（同一次进入里的异步链据此判断是否该继续）。
    this.disposed = false;
    // 听书入口解锁位（2026-09-25）：AppStorage 里还没有这个键（冷启动）时从 Preferences 回填。
    this.listenUnlocked = ListenUnlock.isUnlocked()
    // 睡眠定时：进页先回读一次引擎真实状态（闹钟图标实心/空心、剩余量文案），
    // 并启动每 5s 的刷新 —— 定时自然到点后图标自动变回空心。
    this.refreshSleepStatus();
    this.startSleepTicker();
    this.isScreenState = PreferencesUtil.getSync(`isScreenState`, this.isScreenState) as boolean
    // ── 亮度 / 常亮 的冷启动恢复（2026-09-21 修复两处真机 bug）──────────────
    // ① 亮度**不持久**：`BrightnessUtil.brightnessMap` 是纯内存 Map
    //    （`common/utils/BrightnessUtil.ets:15-16`，全文件无落盘），
    //    而 `getBrightness()` 拿不到就 `?? -1`（`:35`）。冷启动 Map 必为空 ⇒
    //    下面旧代码恒判为"随系统"，且滑杆被 `HitTestMode.None` 禁用 ⇒
    //    **用户手调的亮度每次重启都丢**。故改为从 Preferences 读回并重新施加。
    // ② 常亮**重启不生效**：`isScreenState` 虽在 aboutToDisappear 落盘，
    //    旧代码只把它读回 @State，**从不调用** `setScreenState` ⇒
    //    开关显示"开"但窗口 keep-screen-on 并未生效。
    const savedBright = PreferencesUtil.getSync('ReaderBrightness', -1) as number
    if (savedBright === -1) {
      this.isLuminanceFollowSystem = true
    } else {
      this.isLuminanceFollowSystem = false
    }
    BrightnessUtil.setBrightness('reader', savedBright)
    BrightnessUtil.setScreenState(this.isScreenState)
    // 诊断（临时）：量同一段中文在不同字体族下的宽度 —— 用于客观判定"哪个族 == ArkUI 默认"
    // （普通模式偏窄 = 所选字体比 ArkUI 默认更窄；沉浸模式用 ArkUI 默认所以是对的）
    try {
      const mu = this.getUIContext().getMeasureUtils();
      const sample = '声声龙吼，震荡天地';
      const defSize = mu.measureTextSize({ textContent: sample, fontSize: 18 });
      const def = defSize;
      hilog.info(0x0000, 'testTag', 'fontwidth default = %{public}s (width=%{public}s)',
        JSON.stringify(def), String(def.width));
      const fams: string[] = ['鸿蒙黑体', 'HarmonyOS Sans', '书宋-简', 'Noto Serif', 'HarmonyOS Sans SC'];
      for (let i = 0; i < fams.length; i++) {
        const m = mu.measureTextSize({ textContent: sample, fontSize: 18, fontFamily: fams[i] });
        
        hilog.info(0x0000, 'testTag', 'fontwidth %{public}s = width %{public}s',
          fams[i], String(m.width));
      }
    } catch (e) {
      hilog.warn(0x0000, 'testTag', 'fontwidth 测量失败: %{public}s',
        e instanceof Error ? e.message : String(e));
    }
    this.registerScreenDensityChange();
    this.registerListener();
    this.registerTtsCallbacks();
    // 诊断（临时）：打印平台认定的系统字体清单 —— 用于确定"系统字体"的准确族名，
    // 避免继续靠模糊匹配（此前 '系统字体' 被匹配成了 Condensed 窄体）。
    try {
      const fonts = this.getUIContext().getFont();
      const list = fonts.getSystemFontList();
      hilog.info(0x0000, 'testTag', 'sysfonts(%{public}d): %{public}s',
        list.length, JSON.stringify(list));
      const info = fonts.getFontByName('HarmonyOS Sans');
      hilog.info(0x0000, 'testTag', 'fontinfo HarmonyOS Sans: %{public}s', JSON.stringify(info));
      const infoSC = fonts.getFontByName('HarmonyOS Sans SC');
      hilog.info(0x0000, 'testTag', 'fontinfo HarmonyOS Sans SC: %{public}s', JSON.stringify(infoSC));
    } catch (e) {
      hilog.warn(0x0000, 'testTag', 'sysfonts 查询失败: %{public}s',
        e instanceof Error ? e.message : String(e));
    }
    // 亮暗色重构 + 屏闪修复（2026-09-23）：原来这里**立刻**冻结顶部避让 + 隐藏系统栏，
    // 与下面的 Ability 配色翻转一起，都发生在入场转场进行中 ⇒ 系统级重涂 + 避让跳变
    // = 用户看到的"打开书籍时底部一闪"（书与 App 异色时最明显）。
    // ⇒ 三件事全部**推迟到入场转场结束后**（见 aboutToAppear 尾部的 setTimeout）；
    //   冻结必须仍先于隐藏（顺序不能反，理由见下）。

    const temp: ReaderRouteParam = this.initParam
    this.bookData = temp.bookData
    this.bookData = PreferencesUtil.getSync(`BookCurrentData_${this.bookData.bookName}`, this.bookData) as Books
    // 书签回跳目标（见 ParamsObj.bmChapterIndex 注释）；缺省 -1 = 不跳转。
    // 真正的跳转要等 ReaderKit 就绪并产生第一次 pageShow（见 tryBookmarkJump）。
    this.bmJumpIndex = temp.bmChapterIndex ?? -1
    this.bmJumpNode = temp.bmNode ?? -1
    this.readerSetting = PreferencesUtil.getSync(`ReaderSetting_${this.bookData.bookName}`,
      this.readerSetting) as readerCore.ReaderSetting;
    // ⚠️ readerSetting 是**按书持久化**的 ⇒ 存量值会覆盖上面的新默认值。
    //    所有字段级纠正统一走 migrateReaderSetting()（版本化迁移 + scaledDensity 刷新），
    //    不要再在这里散落 ad-hoc 修正。
    this.migrateReaderSetting();
    // ── 自定义背景色的恢复（2026-09-25）──────────────────────────────────────
    // 必须在 `migrateReaderSetting()` **之后**（要读迁移后的 themeColor 当初始值）、
    // 在下面 `startPlay()` **之前**（`startPlay` 里的 `setPageConfig(readerSetting)`
    // 就带着恢复出来的自定义色，第一帧即正确，不会先闪一下推荐色）。
    this.restoreCustomBg();
    // 「保存方案」存下来的颜色清单（全局，一次读入；增删时再刷）
    this.refreshSavedSchemes();
    // ── 按键翻页（2026-10-07）：阅读页存活期间才订阅（官方要求"确定响应时才激活"），
    //    音量上=上一页、下=下一页；智控键仅支持的机型生效。退订在 aboutToDisappear。
    ReaderKeyTurn.attachReader((isNext: boolean): void => {
      try {
        this.readerComponentController.flipPage(isNext)
      } catch (e) {
        // 引擎未就绪（开场转场中）时忽略本次按键
      }
    });
    // ── 防窥保护（2026-10-07）：取窗口 + 恢复上次开关状态（眼睛图标随 AppStorage 同步）
    AntiPeep.ensureInit(this.getUIContext().getHostContext() as common.UIAbilityContext);
    // ── 阅读器信息窗（2026-10-07）：开关只在设置页改，进场读一次即可
    this.infoWinOn = PreferencesUtil.getSync(MySetConstants.SET_INFO_WIN, false) as boolean;
    this.syncInfoTicker();
    // 标定值要在 readerSetting 载入之后再读（自动行高系数依赖字号/行距）
    this.loadCalib();
    this.startPlay(this.bookData.bookUrl ?? '', this.bookData.localBookDurChapterPos?.resourceIndex ?? 0,
      this.bookData.localBookDurChapterPos?.startDomPos ?? '');
    // 桌面快捷方式「快速听书」：等就绪后自动开播（见 autoStartListenWhenReady）
    if (temp.quickListen === true) {
      this.autoStartListenWhenReady(0);
    }
    //修改为设置的主题，需要在初始化阅读器后设置
    // 诊断（临时）：确认 aboutToAppear 的尾部真的执行到了
    hilog.info(0x0000, 'testTag', 'reader: aboutToAppear tail, nightMode=%{public}s',
      String(this.readerSetting.nightMode));
    this.colorMode = this.readerSetting.nightMode ? 0 : 1
    // ★ 顺序不能反：先把"阅读器在栈顶"立起来，再写夜间开关 ——
    //   `NightMode.desiredDark()` 用 `readerActive` 判断"该走阅读器分支"，
    //   反过来的话（先写开关）会让 `Main` 的 Watch 用"书架页签"的规则算错一次。
    NightMode.setReaderActive(true);
    // 立刻**记录**阅读器的日/夜间（`desiredDark()` 随时可能被问，比如系统配置回调）；
    // 真正的 Ability 配色翻转在下面的延迟块里。
    NightMode.setReaderNight(this.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK);
    // ── 屏闪修复（2026-09-23）────────────────────────────────────────────────
    // 系统级三件事推迟到**入场转场结束后**（长take 560ms / 系统转场≈600ms ⇒ 取 620ms）：
    //   ① 冻结顶部避让 → ② 隐藏系统栏（顺序不能反：先冻结再隐藏，否则 avoidAreaChange
    //      会把 topRectHeight 改成 0，主页所有页面都用它做顶部避让 ⇒ 主页上下跳 38.81vp）；
    //   ③ Ability 配色按书的日/夜间翻转（材质/弹窗跟随书页）。
    // 原缺陷：push 当帧就做这三件事 ⇒ 转场中途世界发生系统级重涂与避让跳变（屏闪）。
    setTimeout((): void => {
      if (this.disposed) {
        // 用户在转场期间就退出了：不再进入沉浸态，系统栏保持原样。
        return;
      }
      WindowAbility.getInstance().freezeTopRect();
      WindowAbility.getInstance().toggleWindowSystemBar([], this.getUIContext().getHostContext());
      this.syncAbilityColorMode();
    }, UiMotion.LT_ENTER_DUR + 60);
  }

  private async startPlay(path: string, resourceIndex: number, domPos: string) {
    try {
      let context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      let initPromise: Promise<void> = this.readerComponentController.init(context);
      let defaultHandler: Promise<bookParser.BookParserHandler> = bookParser.getDefaultHandler(path);
      let result: [bookParser.BookParserHandler, void] = await Promise.all([defaultHandler, initPromise]);
      // ★★ 关键守卫（2026-09-22 修复黑屏）★★
      // `init` / `getDefaultHandler` 是异步的，等待期间用户完全可能已经退出阅读页
      // ⇒ `aboutToDisappear` 里的 `releaseBook()` 已经跑过了。
      // 此时若继续往下调 `registerBookParser` 等，就是在操作**已释放的控制器**，
      // 真机表现为 `[bookparser] Directory does not exist or is not accessible`
      // 并且此后**永远不再产生 `pageShow`**（黑屏）。
      // 所以这里必须先确认组件还活着。详见 `disposed` 字段注释。
      if (this.disposed) {
        hilog.info(0x0000, 'testTag',
          'startPlay: 组件已销毁（快速退出），跳过 registerBookParser/startPlay，避免损坏 ReaderKit 状态');
        return;
      }
      this.BookHandler = result[0];
      // 换书 ⇒ 正文号↔目录号 的映射缓存作废（见 catalogIndexForSpine）
      this.spineToCatalog = null;
      // ⚠️ 必须直注册默认 handler（2026-09-27 回退）：委托型 handler（加粗 CSS 注入）
      //   在**第二次进阅读器**时会让引擎策略层停摆（内容排版/截图完成但
      //   onPageDataNeedUpdate 不再触发 ⇒ Draw Cur Page 不执行 ⇒ XComponent 无帧黑屏，
      //   真机日志 2026-09-27 01:57）。加粗（正文）暂无安全注入点，诚实搁置。
      this.readerComponentController.registerBookParser(this.BookHandler);
      this.publishLtPageBg()   // 七轮：发布内容页外观给飞行层（见该方法注释）
      this.readerComponentController.setPageConfig(this.readerSetting);
      this.readerComponentController.startPlay(resourceIndex || 0, domPos);
      this.CatalogList.pushAllData(this.BookHandler?.getCatalogList() || []); //获取目录列表
      // 单源目录（M3，2026-10-05）：把手机端目录**标题**发布成快照，供电脑端 `GET /toc` 用。
      // 电脑端拿这份标题列表，在**与 /book 完全同一串解码文本**上按顺序定位 ⇒ 两端章号/百分比
      // 首次真正对齐（旧实现各切各的，只能靠 12~20 字模糊匹配）。字符偏移由服务端算（见
      // WifiBookServer.locateToc），因为只有服务端同时持有"目录标题"和"正在下发的正文串"。
      this.publishBookToc();
      // 注：目录过滤数据源已随弹窗改造搬到 `ReaderCatalogDialog` 内部 ——
      //     它在每次打开时从 `CatalogList.getOriginDataArray()` 重新构建，这里不需要再同步。
      hilog.info(0x0000, 'testTag', 'catalog list length: ' + this.CatalogList.totalCount());
      this.checkWebSyncAnchor(resourceIndex || 0);   // 进度同步 v1（2026-10-01）：web 端锚点检查
      this.registerWebSyncListener();                // v1.1：阅读中电脑翻章 → toast 知会
    } catch (err) {
      hilog.error(0x0000, 'testTag', `failed to startPlay, Code is ${err.code}, message is ${err.message}`);
    }
  }

  /**
   * 进度同步 v1（章节级，2026-10-01 专项）：开书后检查 web 端写回的阅读锚点。
   *
   * 数据流：web 阅读器翻章时 POST /sync → WifiBookServer 写 `WebSync_<书名>`
   * （JSON {title, ts}）→ 本方法在开书 1.2s 后（引擎与目录已就绪）读取：
   * ts 比 `WebSyncSeen_<书名>`（已处理标记）新 ⇒ AlertDialog 询问"跳转到该章？"。
   * 跳转 = 在目录列表按标题匹配章节 index → `startPlay(index, 0)`（引擎现成 API）。
   * 用户忽略 ⇒ 写入 Seen 标记，同一锚点不再打扰。
   * 整链 try/catch 包死：任何异常静默（阅读主流程零回归风险）。
   * 精度说明：v1 章节级（标题匹配）；页级需 domPos↔字符偏移换算（v2）。
   */
  /**
   * 进度同步 v1.1（2026-10-01）：手机**正开着这本书**时，电脑翻章的即时知会。
   * WifiBookServer 收到 web /sync 写锚点后同进程 emitter.emit(20261001)；
   * 此处监听 → 匹配当前书名 → toast 知会（30s 节流，不打断阅读——
   * 用户想跳转：重新打开本书走锚点弹窗，或直接用目录）。
   * 页级/双向跳转的完整互通在 v2（domPos↔字符偏移换算）。
   */
  private registerWebSyncListener(): void {
    try {
      // ⚠️ 2026-10-05（审计 P1-4）：`emitter.on` 是**进程级**全局监听（SDK
      // `@ohos.events.emitter.d.ts:31-35`「global event subscription and publishing
      // capabilities **within a process**」），原来**只注册不解绑** ⇒ 每次开书都多一个
      // 监听，闭包持有整个阅读页实例（含 CatalogList / anchorNodeCache 整章节点文本）
      // ⇒ 内存与句柄随开书次数累积。
      // 现在把回调存进字段，`aboutToDisappear` 里用 **带回调的 off** 精确解绑
      // （`off(eventId)` 那种重载会把**其他**还活着的阅读页监听一起摘掉，
      //  签名见 `@ohos.events.emitter.d.ts:182 off(eventId: number, callback: Callback<EventData>)`）。
      if (this.webSyncListenerCb !== null) {
        return
      }
      const ev: emitter.InnerEvent = { eventId: 20261001 }
      const cb = (event: emitter.EventData): void => {
        try {
          if (this.disposed) {
            return
          }
          const p = (event.data ?? {}) as Record<string, string>
          if (p === null || p === undefined) {
            return
          }
          const name: string = p['name'] ?? ''
          const title: string = p['title'] ?? ''
          if (name === '' || name !== (this.bookData?.bookName ?? '')) {
            return
          }
          // v2：先过"值不值得提示"的判定（水位 + 同章阈值都在 SyncConfig 里）——
          // 电脑只是同章内挪了不到一页 ⇒ 这里直接返回（顺带推进水位），不打扰阅读。
          if (SYNC_V2_ENABLED) {
            const ownTitle: string = this.bookData?.durChapterTitle ?? ''
            const node: number = this.pageRange?.startNode ?? 0
            const ownRatio: number = this.anchorNodeCount > 0 ? node / this.anchorNodeCount : -1
            if (syncConfig.pendingWebPos(name, ownTitle, ownRatio) === null) {
              return
            }
          }
          const now: number = Date.now()
          if (now - this.webSyncToastAt < 30000) {
            return
          }
          this.webSyncToastAt = now
          this.getUIContext().getPromptAction().showToast({
            message: `电脑读到了「${title.slice(0, 16)}」章`
          })
        } catch (e) {
          hilog.error(0x0000, 'testTag', `webSync listener failed: ${(e as Error).message}`)
        }
      }
      this.webSyncListenerCb = cb
      emitter.on(ev, cb)
    } catch (err) {
      hilog.error(0x0000, 'testTag', `webSync listener setup failed: ${(err as Error).message}`)
    }
  }

  /** 解绑同步监听（`aboutToDisappear` 调用；必须用带回调的 off，见 registerWebSyncListener 注释） */
  private unregisterWebSyncListener(): void {
    if (this.webSyncListenerCb === null) {
      return
    }
    try {
      emitter.off(20261001, this.webSyncListenerCb)
    } catch (err) {
      hilog.error(0x0000, 'testTag', `webSync listener off failed: ${(err as Error).message}`)
    }
    this.webSyncListenerCb = null
  }

  /**
   * 双锚提取（进度同步 v2）：按 pageRange 取「页首行 / 页末行」各约 40 字摘录。
   * 文本来源与 currentPageFirstLine 同款两级：TtsEngine.currentNodeTexts()
   * （朗读中且同章）→ previewNodeTexts 旁路（默读）。摘录做空白规整，
   * 与 web 端 normEx 同口径 ⇒ 两端可互查定位。
   */
  /**
   * v3.21 优化：节点文本**按章缓存**（`anchorNodeCache`）——默读时旧实现每次翻页
   * 都走 previewNodeTexts 旁路重解析整章（重且异步竞态：连续翻页时旧请求后返回
   * 覆盖新锚 ⇒ 锚停留在很早的位置，用户实测"总出现第三章"）。现在同章翻页
   * 直接复用缓存（零旁路开销、无竞态），跨章才重建。
   */
  private anchorNodeCacheSpine: number = -1
  private anchorNodeCache: string[] | null = null
  /**
   * 本章块节点总数（双端同步 v2 用）：与 `pageRange.startNode` 一起算 **章内位置比例 posRatio**
   * ⇒ 跨端定位时文本锚匹配不到，还能按比例落到大致同一位置（设计文档 §3 R4）。
   */
  private anchorNodeCount: number = 0

  private async webSyncAnchors(): Promise<string[]> {
    const r = this.pageRange
    if (r === null || r.startNode < 0) {
      return ['', '']
    }
    try {
      let nodes = TtsEngine.currentNodeTexts()
      if (nodes === null || TtsEngine.currentChapter() !== r.spine) {
        if (this.anchorNodeCacheSpine === r.spine && this.anchorNodeCache !== null) {
          nodes = this.anchorNodeCache
        } else {
          nodes = await TtsEngine.previewNodeTexts(this.BookHandler ?? null, r.spine)
          this.anchorNodeCacheSpine = r.spine
          this.anchorNodeCache = nodes
        }
      }
      if (nodes === null || nodes.length === 0) {
        return ['', '']
      }
      // v2：记下本章节点总数（算 posRatio 用；两端都用"比例"而不是各自的索引）
      this.anchorNodeCount = nodes.length
      // 摘录长度 40，与网页端 `pageAnchors()`（`top.slice(0,40)`）对齐；
      // v2 规定"规整化"口径两端一致 = 去**全部**空白（web 端 `normEx` 同款），
      // 手机这里保留单空格仅用于**显示**，匹配时统一走 `SyncConfig.normEx`。
      const norm = (s: string): string => s.replace(new RegExp('\\s{1,}', 'g'), ' ').trim()
      const startNode: string = nodes[Math.min(r.startNode, nodes.length - 1)] ?? ''
      const endNode: string = nodes[Math.min(r.endNode, nodes.length - 1)] ?? ''
      const topRaw = startNode.slice(r.startChar, r.startChar + 40)
      const botRaw = endNode.slice(Math.max(0, r.endChar - 40), r.endChar + 2)
      return [norm(topRaw), norm(botRaw)]
    } catch (e) {
      return ['', '']
    }
  }

  /**
   * 发布目录标题快照（M3 单源目录，2026-10-05）。
   *
   * 目的：让电脑端与手机端**用同一份章节划分**（现在两端各切各的：手机 ReaderKit、
   * 网页空行+标题正则 ⇒ 章号/百分比/书签位置全都对不上，只能靠文本模糊匹配）。
   *
   * 为什么只发布"标题"而字符偏移交给服务端算：详见 WifiBookServer.locateToc 注释 ——
   * 只有在服务端才能在**正在下发的那一串解码文本**上定位，避免"两端口径不同 ⇒ 偏移全错"。
   * 只在标题数组变化时写盘（开书高频，避免每次都写）。
   */
  private publishBookToc(): void {
    try {
      const name: string = this.bookData?.bookName ?? ''
      if (name === '') {
        return
      }
      const n: number = this.CatalogList.totalCount()
      if (n <= 0) {
        return
      }
      const titles: string[] = []
      for (let i = 0; i < n; i++) {
        titles.push(this.CatalogList.getData(i)?.catalogName ?? '')
      }
      const key: string = `BookToc_${name}`
      const next: string = JSON.stringify(titles)
      let prev = ''
      try {
        prev = PreferencesUtil.getSync(key, '') as string
      } catch (e) {
        prev = ''
      }
      if (prev !== next) {
        PreferencesUtil.putSync(key, next)
        hilog.info(0x0000, 'testTag', 'bookToc published: %{public}d titles', n)
      }
    } catch (e) {
      hilog.error(0x0000, 'testTag', `publishBookToc failed: ${(e as Error).message}`)
    }
  }

  /**
   * pageShow 挂点：把手机当前位置写进**手机自己的位置槽**（v2 双端同步，见 SyncConfig）。
   * v3.21 两点加固：
   * ① **2.5s 节流**——pageShow 高频触发，旧实现每页都异步取文本+写盘（重且竞态）；
   * ② **ts 单调**——slot.ts 取 max(now, 存量 ts)：即使竞态让旧请求后落盘，
   *    也不会把时间戳拉回去（旧锚永远赢不了新锚的 seen 比对）。
   */
  private writeWebSyncAnchors(): void {
    const now: number = Date.now()
    if (now - this.webSyncLastWriteAt < 2500) {
      return
    }
    this.webSyncLastWriteAt = now
    this.webSyncAnchors().then((a: string[]): void => {
      try {
        if (a[0] === '' && a[1] === '') {
          return
        }
        const name: string = this.bookData?.bookName ?? ''
        if (name === '') {
          return
        }
        // ── 双端同步 v2（2026-10-05）：写**手机自己的槽**，不再与电脑共用键 ──────────
        // v1 的 `WebSync_<书名>` 是"一槽两用"：手机写、电脑也写 ⇒ 谁后写谁赢、
        // 对方的待消费提示被顶掉（审计 H1）。v2 各写各的槽：
        //   `SyncPos_phone_<书名>`（本方法） / `SyncPos_web_<书名>`（服务端代网页写）
        const chCount: number = this.CatalogList.totalCount()
        const chIndex: number = this.bookData.durChapterIndex ?? 0
        const nodeCount: number = this.anchorNodeCount
        // ts 单调（v2 单写者也要）：`webSyncAnchors()` 是异步的，连续翻页时**旧请求可能后返回**，
        // 若直接写 `Date.now()`，槽的 ts 会回退 ⇒ 网页侧的"已消费水位"（记的是较新的 ts）
        // 会把随后真正的更新误判为"已消费"而不提示。
        const prevTs: number = syncConfig.readPhonePos(name).ts
        const pos: SyncPos = {
          v: 2,
          // 序号由 `syncConfig.writePhonePos` → `stamp()` 统一分配（手机进程全局单调）
          seq: 0,
          chTitle: this.bookData.durChapterTitle ?? '',
          chIndex: chIndex,
          chCount: chCount,
          ratio: chCount > 0 ? chIndex / chCount : -1,
          topEx: a[0],
          botEx: a[1],
          posRatio: nodeCount > 0 ? (this.pageRange?.startNode ?? 0) / nodeCount : -1,
          ts: Math.max(Date.now(), prevTs),
          writer: 'phone'
        }
        if (SYNC_V2_ENABLED) {
          syncConfig.writePhonePos(name, pos)
        } else {
          // 回退路径（开关关闭）：保持 v1 行为不变，便于一键比较/回退
          let ts: number = pos.ts
          try {
            const prevRaw = PreferencesUtil.getSync(`WebSync_${name}`, '') as string
            if (prevRaw !== '' && prevRaw !== null) {
              const prev = JSON.parse(prevRaw) as Record<string, number | string>
              ts = Math.max(ts, Number(prev['ts'] ?? 0))
            }
          } catch (e) {
            // 存量读不到就用 now
          }
          const payload: Record<string, number | string> = {
            'topEx': a[0],
            'botEx': a[1],
            'title': pos.chTitle,
            'chapterIndex': chIndex,
            'ts': ts,
            'src': 'phone'
          }
          PreferencesUtil.putSync(`WebSync_${name}`, JSON.stringify(payload))
          PreferencesUtil.putSync(`WebSyncSeen_${name}`, ts)
        }
      } catch (e) {
        hilog.error(0x0000, 'testTag', `webSync anchor write failed: ${(e as Error).message}`)
      }
    })
  }

  /**
   * 按章节标题在目录里找**目录下标**（数字优先："第N章"；标题互含兜底）。
   * 与 `anchorJump` 的章定位同口径，抽出来给两处共用。
   *
   * 用途：**电脑端书签/锚点**。网页端的 `chapterIndex` 是它自己按空行分段 + 标题正则
   * 切出来的章下标（`WifiBookServer.ets:723-727`），与手机端目录下标是两套坐标系
   * （审计 H3）⇒ 只能按标题匹配，不能当索引用。
   *
   * @returns 目录下标；找不到返回 -1
   */
  private catalogIndexByTitle(title: string): number {
    const t0: string = (title ?? '').trim()
    if (t0 === '') {
      return -1
    }
    const total: number = this.CatalogList.totalCount()
    const numM = t0.match(/第(\d+)[章节回卷]/)
    const wantNum = numM !== null ? parseInt(numM[1]) : -1
    if (wantNum >= 0) {
      for (let i = 0; i < total; i++) {
        const t: string = this.CatalogList.getData(i)?.catalogName ?? ''
        if (t === '') {
          continue
        }
        const tm = t.match(/第(\d+)[章节回卷]/)
        if (tm !== null && parseInt(tm[1]) === wantNum) {
          return i
        }
      }
    }
    // 标题互含兜底：网页传的 `chapterName` 是"该章首段正文前 30 字"（通常是标题行本身），
    // 手机目录名是 ReaderKit 的 catalogName ⇒ 取前 8 字双向包含判断
    const key: string = t0.slice(0, 8)
    for (let i = 0; i < total; i++) {
      const t: string = this.CatalogList.getData(i)?.catalogName ?? ''
      if (t === '') {
        continue
      }
      if (t.indexOf(key) >= 0 || key.indexOf(t.slice(0, 8)) >= 0) {
        return i
      }
    }
    return -1
  }

  /**
   * 摘录 → 引擎位置（node/char）：在目标章块节点文本中做规整化子串匹配，
   * 命中后经 domPosFor 还原引擎 domPos ⇒ startPlay 精确落位（行级）。
   * 章定位：数字优先（"第N章"），标题互含兜底。
   *
   * ⚠️ 2026-10-05 修（审计 H4）：这里原先把**目录下标**直接当 **spine 号**用
   * （`spine = i` → `previewNodeTexts(spine)` / `startPlay(spine, …)`）。官方文档
   * 原文（documentId `API参考/Reader_Kit_阅读服务/ArkTS_API/bookParser_书籍解析能力/reader-book-parser`）：
   *   「CatalogItem 对应一个目录节点，而 SpineItem 对应一个内容资源文件，**两者并不总是一一对应的**」
   * ⇒ epub/多级目录书会跳到错误的章。现改为与 `jumpToCatalogItem`（`:6301`）、
   *   `jumpToBookmark`（`:6341`）同款的 `getResourceItemByCatalog(item).index` 换算。
   */
  private async anchorJump(excerpt: string, title: string, ratio: number = -1,
    posRatio: number = -1): Promise<void> {
    // 匹配键 12 → **20 字**（2026-10-05 收紧：键太短时重复句子会命中错处；显示仍用短摘录）
    const key = excerptKey(excerpt, 20)
    const total: number = this.CatalogList.totalCount()
    // ① 章定位：标题匹配优先（数字优先 + 前 8 字互含）
    let catalogIdx: number = this.catalogIndexByTitle(title)
    // ② 章定位兜底：跨端比例（两端切分不同，索引不可用，比例可换算）
    if (catalogIdx < 0 && ratio >= 0 && total > 0) {
      catalogIdx = ratioToIndex(ratio, total)
    }
    if (catalogIdx < 0) {
      this.getUIContext().getPromptAction().showToast({ message: '未能定位该进度' })
      return
    }
    const catalogItem = this.CatalogList.getData(catalogIdx)
    if (catalogItem === undefined || catalogItem === null) {
      this.getUIContext().getPromptAction().showToast({ message: '未能定位该进度' })
      return
    }
    // 目录下标 → spine 号（二者不总一一对应，必须换算）
    const spine: number = this.getResourceItemByCatalog(catalogItem).index
    const nodes = await TtsEngine.previewNodeTexts(this.BookHandler ?? null, spine)
    if (nodes === null || nodes.length === 0) {
      this.readerComponentController.startPlay(spine, `${spine}`)
      return
    }
    // ③ 章内定位：文本锚优先（行级最准）；**多个命中时取离"比例推算位置"最近的那个**
    //    （2026-10-05 收紧：旧实现取首个命中，重复句子会落到本章靠前的位置）
    const targetNode: number = posRatio >= 0 ? ratioToIndex(posRatio, nodes.length) : -1
    let bestNode: number = -1
    let bestChar: number = 0
    let bestDist: number = -1
    if (key !== '') {
      for (let n = 0; n < nodes.length; n++) {
        const normed = normEx(nodes[n] ?? '')
        const hit = normed.indexOf(key)
        if (hit < 0) {
          continue
        }
        const dist: number = targetNode >= 0 ? Math.abs(n - targetNode) : 0
        if (bestNode < 0 || dist < bestDist) {
          bestNode = n
          bestChar = hit
          bestDist = dist
          if (targetNode >= 0 && dist === 0) {
            break
          }
        }
      }
    }
    if (bestNode >= 0) {
      // 规整化偏移 ≈ 原文偏移（差异仅为被压缩的空白，行级可接受）
      this.readerComponentController.startPlay(spine, this.domPosFor(bestNode, bestChar))
      return
    }
    // ④ 章内兜底：跨端章内比例 → 块节点号
    if (posRatio >= 0) {
      this.readerComponentController.startPlay(spine, this.domPosFor(ratioToIndex(posRatio, nodes.length), 0))
      return
    }
    this.readerComponentController.startPlay(spine, `${spine}`)
  }

  private checkWebSyncAnchor(defaultIndex: number): void {
    try {
      const name: string = this.bookData?.bookName ?? ''
      if (name === '') {
        return
      }
      setTimeout((): void => {
        try {
          // ── v2 路径（2026-10-05，用户确认的结构化方案）────────────────────────
          // 判据全部交给 `SyncConfig.pendingWebPos`：水位按 **webId** 分别记（多台电脑互不干扰）、
          // 同章且位置差 < 一页则不打扰（只推进水位），手机自己的槽结构上不可能自弹。
          if (SYNC_V2_ENABLED) {
            this.checkWebSyncAnchorV2(name)
            return
          }
          // ── v1 回退路径（开关关闭时保持原行为，便于一键比较/回退）────────────
          const raw = PreferencesUtil.getSync(`WebSync_${name}`, '') as string
          if (raw === '' || raw === null) {
            return
          }
          const obj = JSON.parse(raw) as Record<string, number | string>
          const ts: number = Number(obj['ts'] ?? 0)
          const title: string = String(obj['title'] ?? '')
          // v3.20 双锚：web/手机同写的"页首行、页末行"摘录（行级定位键）
          const topEx: string = String(obj['topEx'] ?? '')
          const botEx: string = String(obj['botEx'] ?? '')
          // ── 写者判定（2026-10-05 修"幽灵弹窗"，审计 H2/P0-1）────────────────
          // `src` 由手机写锚点时写死为 'phone'（`:2619`），服务端写网页锚点时记为 'web'。
          // 这里**必须先判写者**：手机自己刚写回去的锚点不该弹"电脑端阅读进度"。
          // （`ts > seen` 那道水位只保证"没提示过"，它拦不住自写自读。）
          const src: string = String(obj['src'] ?? '')
          if (src === 'phone') {
            return
          }
          const seen = Number(PreferencesUtil.getSync(`WebSyncSeen_${name}`, 0) as number)
          if (ts <= seen || (topEx === '' && botEx === '' && title === '')) {
            return
          }
          const nl: string = String.fromCharCode(10)
          const ui = this.getUIContext()
          ui.showAlertDialog({
            title: '电脑端阅读进度',
            // v3.20 双锚（用户设计）：电脑页首/页末各显示一句，用户手动选跳哪个
            message: `电脑读到：${title !== '' ? `「${title.slice(0, 16)}」` : ''}` +
              `${topEx !== '' ? `${nl}页首：${topEx.slice(0, 18)}` : ''}` +
              `${botEx !== '' ? `${nl}页末：${botEx.slice(0, 18)}` : ''}`,
            primaryButton: {
              value: topEx !== '' ? '跳到页首' : '知道了',
              action: (): void => {
                PreferencesUtil.putSync(`WebSyncSeen_${name}`, ts)
                if (topEx !== '') {
                  this.anchorJump(topEx, title)
                }
              }
            },
            secondaryButton: {
              value: botEx !== '' ? '跳到页末' : '取消',
              action: (): void => {
                PreferencesUtil.putSync(`WebSyncSeen_${name}`, ts)
                if (botEx !== '') {
                  this.anchorJump(botEx, title)
                }
              }
            },
            cancel: (): void => {
              PreferencesUtil.putSync(`WebSyncSeen_${name}`, ts)
            }
          })
        } catch (e) {
          hilog.error(0x0000, 'testTag', `webSync check failed: ${(e as Error).message}`)
        }
      }, 1200)
    } catch (err) {
      hilog.error(0x0000, 'testTag', `webSync anchor setup failed: ${(err as Error).message}`)
    }
  }

  /**
   * 双端同步 v2：开书时的"电脑端阅读进度"提示（设计文档 §3 R2/R3）。
   * 判据与水位都在 `SyncConfig.pendingWebPos()`；这里只负责**展示**与**跳转**。
   * 跳转优先级：① `topEx/botEx` 文本锚（`anchorJump` 内）→ ② `ratio` 定位章
   * → ③ `posRatio` 定位章内位置（见 `anchorJump`）。
   */
  private checkWebSyncAnchorV2(name: string): void {
    const ownTitle: string = this.bookData?.durChapterTitle ?? ''
    const node: number = this.pageRange?.startNode ?? 0
    const ownPosRatio: number = this.anchorNodeCount > 0 ? node / this.anchorNodeCount : -1
    const pending = syncConfig.pendingWebPos(name, ownTitle, ownPosRatio)
    if (pending === null || pending === undefined) {
      return
    }
    const pos: SyncPos = pending.pos
    const id: string = pending.id
    const nl: string = String.fromCharCode(10)
    /**
     * 三按钮（2026-10-05 用户反馈"没有忽略按钮"）：
     * 原来用 `AlertDialogParamWithButtons`（**只有** primary/secondary 两个按钮，SDK
     * `alert_dialog.d.ts:965-1000`），忽略只能靠右上角 ✕/返回 ⇒ 用户根本看不到"忽略"。
     * 改用 `AlertDialogParamWithOptions.buttons: Array<AlertDialogButtonOptions>`
     * （SDK `alert_dialog.d.ts:1006` + `:1016`，`@since 10`）⇒ 三个并列按钮；
     * 官方注释也写明"超过两个按钮建议用 auto 方向（自动竖向排布）"（`:1017-1021`），
     * 故 `buttonDirection` 用默认 AUTO。
     */
    this.getUIContext().showAlertDialog({
      title: '电脑端阅读进度',
      message: `电脑读到：${pos.chTitle !== '' ? `「${pos.chTitle.slice(0, 16)}」` : ''}` +
        `${pos.topEx !== '' ? `${nl}页首：${pos.topEx.slice(0, 18)}` : ''}` +
        `${pos.botEx !== '' ? `${nl}页末：${pos.botEx.slice(0, 18)}` : ''}`,
      buttons: [
        {
          value: '跳到页首',
          action: (): void => {
            syncConfig.setWatermark(name, id, pos.seq)
            this.anchorJump(pos.topEx, pos.chTitle, pos.ratio, pos.posRatio)
          }
        },
        {
          value: '跳到页末',
          action: (): void => {
            syncConfig.setWatermark(name, id, pos.seq)
            this.anchorJump(pos.botEx, pos.chTitle, pos.ratio, pos.posRatio)
          }
        },
        {
          value: '忽略',
          action: (): void => {
            // 忽略 = 消费这一版（水位推进到该 seq）。语义（用户确认）：
            // "对方**再有新的**进展会再提示一次"，而不是永久静默 —— 否则手机永远不知道
            // 电脑后来读到了 100 章，同步等于失效。
            syncConfig.setWatermark(name, id, pos.seq)
            hilog.info(0x0000, 'testTag', 'webSync ignored: seq=%{public}d', pos.seq)
          }
        }
      ],
      cancel: (): void => {
        // 点弹窗外/返回键：同样按"忽略"处理（否则会出现"没选任何按钮但水位没推进"的悬空态，
        // 下次进来又弹同一个）
        syncConfig.setWatermark(name, id, pos.seq)
      }
    })
  }

  /**
   * `readerSetting` 的字段级纠正与版本迁移（按书）。
   *
   * **为什么必须有这个函数**：`readerSetting` 用 `ReaderSetting_<书名>` 按书持久化，
   * 读取时 `getSync(key, 默认值)` 是**存量值优先于新默认值** ⇒ 只要本地存过一份，
   * 代码里改默认值就永远不会作用到这本老书（HANDOFF §4 坑 6 真机实测：
   * 卸载重装才正常）。而 `readerCore.ReaderSetting` 的 13 个字段里没有版本字段，
   * 只能在对象外旁路存版本号。
   *
   * 两件事：
   *  ① `scaledDensity` **每次都从系统刷新** —— 它是系统/设备属性（文本缩放因子），
   *     不是用户偏好，持久化它本身就是错的：系统缩放变化后旧值会把新值盖回去。
   *     官方文档 `开发指南/Reader_Kit_阅读服务/书籍内容排版/修改阅读设置/监听文本缩放因子变化/reader-setting-scaled-density`
   *     要求「更新 ReaderSetting 的 scaledDensity 属性，触发 setPageConfig 重新进行页面排版」。
   *  ② 版本化迁移：`ver < RS_SETTING_VER` 时按序补齐。
   */
  private migrateReaderSetting(): void {
    let changed = false;

    // ① scaledDensity：以系统当前值为准（设备属性，不随书持久化）
    const sysScaled = display.getDefaultDisplaySync().scaledDensity;
    if (sysScaled > 0 && this.readerSetting.scaledDensity !== sysScaled) {
      hilog.info(0x0000, 'testTag', 'rs-migrate: scaledDensity %{public}s -> %{public}s',
        String(this.readerSetting.scaledDensity), String(sysScaled));
      this.readerSetting.scaledDensity = sysScaled;
      changed = true;
    }

    // ② 版本化迁移
    const verKey = `ReaderSettingVer_${this.bookData.bookName}`;
    const ver = PreferencesUtil.getSync(verKey, 0) as number;
    if (ver < RS_SETTING_VER) {
      // v0 → v1：字体族名占位字面量 → 真实族名。
      // 旧值 '系统字体' / 'system' / 'HarmonyOS Sans' 会被排版引擎模糊匹配成
      // HarmonyOS Sans Condensed（窄体）。全项目 grep 确认 UI **不提供**
      // fontName / fontPath 自定义入口（只有 fontSize/lineHeight/主题/翻页/nightMode 可改），
      // 故此处纠正不会覆盖任何用户选择。
      if (ver < 1) {
        const fn = this.readerSetting.fontName;
        // ⚠️ 'HarmonyOS Sans' 已是字体管理弹窗里的合法系统字体（2026-09-26），不再当占位值重置
        if (fn === undefined || fn === null || fn.length === 0 || fn === '系统字体'
          || fn === 'system') {
          this.readerSetting.fontName = '鸿蒙黑体';
          this.readerSetting.fontPath = '/system/fonts/HarmonyOS_Sans_SC.ttf';
          changed = true;
          hilog.info(0x0000, 'testTag', 'rs-migrate: v0->v1 fontName -> 鸿蒙黑体');
        }
      }
      PreferencesUtil.putSync(verKey, RS_SETTING_VER);
    }

    // ④ 全局排版回填（2026-09-27「同步全局」拓展）：本书不在字体覆盖登记表里
    //    且存在全局排版记录 ⇒ 应用全局的 字体/字号/行距。背景家族由 ReaderBgGlobal
    //    在 restoreCustomBg 里管，两者互不掺和。必须在下方 ensureRegistered 之前
    //    （回填进来的沙箱字体也要注册到 ArkUI 测量通道）。
    const bookName: string = this.bookData.bookName
    if (bookName !== undefined && bookName !== null && bookName.length > 0
      && !ReaderFontLib.fontInOverride(bookName)) {
      const g = ReaderFontLib.loadFontGlobal()
      if (g !== null) {
        this.readerSetting.fontName = g.fontName
        this.readerSetting.fontPath = g.fontPath
        this.readerSetting.fontSize = g.fontSize
        this.readerSetting.lineHeight = g.lineHeight
        changed = true;
      }
    }

    // 字体管理（2026-09-26）：本书若用沙箱导入字体，先注册到 ArkUI 侧
    // （高亮测量通道 / 沉浸层按 fontName 渲染，走 @ohos.font；引擎侧走 resourceRequest 不依赖此）
    ReaderFontLib.ensureRegistered(this.getUIContext(), this.readerSetting.fontName, this.readerSetting.fontPath);

    // ③ 有改动才回写（pageShow 也会写，这里保证"打开即纠正"能落地）
    if (changed) {
      PreferencesUtil.putSync(`ReaderSetting_${this.bookData.bookName}`, this.readerSetting);
    }
  }

  /**
   * [已删除 2026-09-23] `colorModeChange()` Watch —— 它原来挂在 `@StorageLink('colorMode')`
   * 与系统深浅色共用的键上，是"冷启动后切夜间底栏不适配"竞态的根源。
   * 现在本页 `colorMode` 为私有状态：持久化由 `dispatchBarAction(2)`（日夜键）与
   * `aboutToAppear`（进书恢复）直接负责；Ability 配色由 `syncAbilityColorMode()` 负责。
   */

  /**
   * 阅读页 4 条 Slider（底栏「本章」+ 设置面板「亮度/字号/行距」）的**已选段颜色**。
   *
   * 原先是写死的 `'rgba(0, 0, 0, 0.04)'`（一层极淡的黑，用来"让轨道几乎贴在材质上"）。
   * 它**不在** `syncAbilityColorMode()` 能管的范围内 —— `selectedColor` 是我们显式设的，
   * 系统不会替我们做深浅色适配 ⇒ 夜间（深底）下等于不可见。
   * ⇒ 夜里换成同量级的**淡白**，亮暗两档观感对称。
   * 未选段（轨道）颜色我们没设 ⇒ 跟随系统配色，`syncAbilityColorMode()` 已经把它带成深色。
   */
  private sliderSelectedColor(): string {
    return this.colorMode == 0 ? 'rgba(255, 255, 255, 0.16)' : 'rgba(0, 0, 0, 0.04)';
  }

  /**
   * 把「本页日夜模式」下发给 **App 级夜间开关 + UIAbility 配色** —— 唯一的收口点。
   *
   * ── 为什么必须有（真机截图 + SDK/官方原文，完整取证见 `common/utils/NightMode.ets`）──
   * 阅读页夜间时，只有 `backgroundColor` 三元的节点会变色，**"系统画的底色"不会**：
   *   · 进度胶囊（多一层 `backgroundBlurStyle(COMPONENT_ULTRA_THICK)`）⇒ 浅底白字 ❌
   *   · 底部四页签 / 目录弹窗（沉浸光感 `systemMaterial`）      ⇒ 浅底白字 ❌
   * 因为 `BlurStyleOptions.colorMode` 默认 `ThemeColorMode.SYSTEM`
   * （SDK `…\ets\component\common.d.ts:7058-7071`），而 `ImmersiveOptions`
   * （SDK `…\ets\api\@ohos.arkui.uiMaterial.d.ts:306-429`）**六个字段里没有 colorMode**
   * ⇒ 只能靠 `UIAbilityContext.setColorMode()` 这一个官方开关把整个 Ability 带成深色
   *   （官方 documentId `最佳实践/深色模式适配/bpta-dark-mode-adaptation`：
   *    「应用内提供手动控制深浅色的开关供用户自行选择：…调用 setColorMode() 方法将
   *      ColorMode 设置为 COLOR_MODE_DARK…COLOR_MODE_LIGHT，这样就可以完成对应用
   *      深浅色的手动控制。」）。
   *
   * ⚠️ 2026-09-23 起**不再由本页独占**：用户追加要求「夜间模式下书架的背景还是白色」
   *   ⇒ 夜间开关升级成 **App 级**（`NightMode`），书架页也要跟着深色。
   *   本页只负责两件事：① 把"读者此刻的日夜选择"写进 `NightMode`；
   *   ② 声明"阅读器在栈顶"。真正下发什么配色由 `NightMode.desiredDark()` 统一算。
   */

  private syncAbilityColorMode(): void {
    // 亮暗色重构（2026-09-23）：阅读器日/夜间**只**声明到 NightMode 的阅读器分支，
    // 不再写 App 级夜间开关（旧的 `NightMode.set()` 已删除）——书架跟不跟，由三档裁决。
    NightMode.setReaderNight(this.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK);
    NightMode.sync(this.getUIContext().getHostContext() as common.UIAbilityContext);
  }

  /**
   * 注册屏幕密度变化回调。
   */
  registerScreenDensityChange() {
    this.screenDensityCallBack = (data: number) => {
      let displaySync = display.getDefaultDisplaySync();
      let scaledDensity = displaySync.scaledDensity;
      if (scaledDensity !== this.readerSetting.scaledDensity) {
        AppStorage.setOrCreate('isDensityChange', true);
        AppRouter.pop();
      }
    }
    display.on('change', this.screenDensityCallBack);
  }

  private registerPageShow(): void {
    this.readerComponentController.on('pageShow', (data: readerCore.PageDataInfo): void => {
      this.bookData.localBookDurChapterPos = data;
      this.bookData.durChapterTitle = this.CatalogList.getData(this.bookData.durChapterIndex)?.catalogName ?? this.bookData.durChapterTitle;
      this.bookData.totalChapterNum = this.CatalogList.totalCount();
      // ── 空书名守卫（2026-10-05，审计 H12）───────────────────────────────────
      // 这几个键都以书名为后缀：书名为空时键会退化成 `BookCurrentData_`（无后缀），
      // **多本空名书会共用同一份进度/设置**。`WebSync_` 那两处本来就有守卫，这里补齐。
      // ⚠️ 只守**落盘**，不 return —— pageShow 后半段还有书签状态/目录号同步/读完判定，
      //    跳过它们会让阅读器自身状态错乱（`writeWebSyncAnchors` 内部已有自己的空名守卫）。
      const bkName: string = this.bookData.bookName ?? ''
      if (bkName !== '') {
        // 保存书籍数据。
        PreferencesUtil.putSync(`BookCurrentData_${bkName}`, this.bookData)
        // ★「最后阅读的书」标记 —— 桌面快捷方式「快速听书 / 快速阅读」据此定位目标书。
        //   为什么不用数据库的 `durChapterTime`：**当前阅读页从不写该字段**
        //   （本文件对 durChapterTime 的引用数为 0，只有旧阅读页 ReaderPage2 会写），
        //   实测导致快捷方式永远取不到书。这里在每次翻页时顺手记两个键，读的时候回查 books 表。
        //   同时记 name + url，避免同名不同源的书串台。
        PreferencesUtil.putSync('LastReadBookName', bkName)
        PreferencesUtil.putSync('LastReadBookUrl', this.bookData.bookUrl ?? '')
        //  保存阅读器设置。
        PreferencesUtil.putSync(`ReaderSetting_${bkName}`, this.readerSetting)
      } else {
        hilog.warn(0x0000, 'testTag', 'pageShow: bookName is empty, skip per-book persist')
      }
      // ── 进度同步 v2（2026-10-01，用户设计）：页首/页末双锚写给 web 端 ──
      this.writeWebSyncAnchors();
      // ReaderKit 页内容范围（唯一坐标来源）：startDomPos/endDomPos 是字符级的页内容映射
      const s = this.parseDomPos(data.startDomPos);
      const e = this.parseDomPos(data.endDomPos);
      const endAfter = e[0] > s[0] || (e[0] === s[0] && e[1] >= s[1]);
      const range: PageRange = {        spine: data.resourceIndex,
        startNode: s[0],
        startChar: s[1],
        endNode: endAfter ? e[0] : s[0],
        endChar: endAfter ? e[1] : s[1]
      };
      this.pageRange = range;
      // ★ 目录号必须跟随**真实翻页**（2026-09-21 真机日志取证）。
      //   在此之前 `syncCatalogIndex()` 全工程只有**一个**调用点 —— `:852` 的
      //   TTS `onChapter` 回调。也就是说**纯默读时目录号永不推进**，
      //   `durChapterIndex` 一直停在打开这本书时的值 ⇒ 书签记到旧章（真机表现为
      //   第二行显示第一章名 "preface"）、进度百分比与「读完」判定全错。
      //   日志证据：`pageShow: spine=0 …` → `pageShow: spine=1 …`（spine 在推进），
      //   而 `catalog list length: 765` 说明目录本身是有 765 项的。
      this.syncCatalogIndex(range.spine);
      // 目录号刚变过 ⇒ 章节名也要跟着刷新（否则 `:651` 用的是本页 startPlay 之前的旧值）
      this.bookData.durChapterTitle =
        this.CatalogList.getData(this.bookData.durChapterIndex)?.catalogName ?? this.bookData.durChapterTitle;
      // 翻页后刷新书签图标状态（实心/空心）。用 pageRange 的真实位置而不是
      // `bookData.durChapterPos`（后者未必随翻页更新）。
      this.syncBookmarkState();
      // 从「我的 → 书签」点进来时的回跳（只尝试一次，见 tryBookmarkJump）
      this.tryBookmarkJump();
      // 「读完」判定（2026-09-21）：读到**最后一章的最后一页**即写入 `finishedTime`。
      this.checkFinished();
      // ★ 补写「阅读进度 + 最后阅读时间」到数据库（5 秒节流）。
      //   当前阅读页此前**从不写** `books.durChapterTime` ⇒「我的 → 读过」恒为 0、
      //   书架"最近阅读"排序失效。详见 `BooksDao.stampReadProgress` 的注释。
      this.persistReadProgress();
      // 节点模型一致性自检：只统计"当前朗读章"的观测，避免上一章的 pageShow 污染
      if (range.spine === TtsEngine.currentChapter()) {
        TtsEngine.reportObservedMaxNode(range.endNode);
      }
      hilog.info(0x0000, 'testTag', 'pageShow: spine=%{public}d %{public}s..%{public}s | %{public}s',
        range.spine, data.startDomPos, data.endDomPos, TtsEngine.parityHint());
      // 【T2-1 取证】PageDataInfo.state 一直未被读取。SDK 声明它带四态
      // （@hms.core.readerservice.readerComponent.d.ets:496-533
      //   PAGE_WAITING=1 / PAGE_LOADING=2 / PAGE_ON_SHOW=3 / OPEN_BOOK_FAIL=4），
      // 而官方文档《阅读进度通知》说 on('pageShow')「在页面排版成功展示后触发」。
      // 两者表述有张力 → 先加观测取证，不改行为；真机上确认实际出现的取值后再定策略。
      hilog.info(0x0000, 'testTag', 'pageShow-state: state=%{public}d nodeType=%{public}s offset=%{public}d',
        data.state, data.nodeType, data.pageOffset);
      // 手动翻页检测：这次 pageShow 不是我们发起的跳转/搜索 ⇒ 是用户自己翻的。
      // ⚠️ 只靠 locateTarget/flipSearch 判断会误判：跳转超时(700ms)会先清掉 locateTarget，
      // 等 pageShow 迟到时就变成"没请求过" ⇒ 误挂起跟随、而且一挂就不再解除（页面定死）。
      // 所以再加一道"最近 2.5s 内我们发起过跳转"的时间窗。
      const requested = this.locateTarget !== null || this.flipSearch !== null
        || (Date.now() - this.lastNavMs < 2500);
      this.updateHighlight();
      this.onPageShowLocate(range);
      if (!requested && TtsEngine.getState() === 'playing' && !this.followSuspended) {
        const seg = TtsEngine.currentSegment();
        if (seg !== null && seg.spineIndex === range.spine
          && !this.rangeCovers(range, seg.nodeIndex, seg.charStart)) {
          this.followSuspended = true;
          hilog.info(0x0000, 'testTag',
            'follow: suspended by manual turn (page=[%{public}d#%{public}d..%{public}d#%{public}d], audio=node %{public}d)',
            range.startNode, range.startChar, range.endNode, range.endChar, seg.nodeIndex);
        }
      } else if (this.followSuspended) {
        // 页面又落回朗读位置 ⇒ 自动解除挂起（避免一旦误判就永久定死）
        const seg2 = TtsEngine.currentSegment();
        if (seg2 !== null && seg2.spineIndex === range.spine
          && this.rangeCovers(range, seg2.nodeIndex, seg2.charStart)) {
          this.followSuspended = false;
          hilog.info(0x0000, 'testTag', 'follow: resumed (page covers audio again)');
        }
      }
      // 验证用：把本页正文交给 ArkUI 重新排版，与 ReaderKit 的页边界对账
      this.refreshMeasure(range);
    });
  }

  private registerListener(): void {
    this.registerPageShow();
    // ⚠️ 必须注册「自定义字体」资源回调（官方文档《修改阅读设置/自定义字体》）：
    // 一旦设置了 fontPath，排版引擎会判定为自定义字体场景，并通过该接口向应用索要字体字节；
    // 此前只 off 未 on ⇒ 引擎拿不到字体 ⇒ 回退到默认字体（API 26 下正是 Condensed 窄体）。
    try {
      this.readerComponentController.on('resourceRequest', this.resourceRequest);
    } catch (e) {
      hilog.warn(0x0000, 'testTag', 'on(resourceRequest) 注册失败: %{public}s',
        e instanceof Error ? e.message : String(e));
    }
    WindowAbility.getInstance().onWindowSizeChange(() => {
      if (this.readerSetting.viewPortWidth != this.windowWidth ||
        this.readerSetting.viewPortHeight != this.windowHeight) {
        // 当窗口大小更改时，更新当前页面视区大小。
        this.readerSetting.viewPortWidth = this.windowWidth;
        this.readerSetting.viewPortHeight = this.windowHeight;
        try {
          this.readerComponentController.setPageConfig(this.readerSetting);
        } catch (e) {
          console.error('onWindowSizeChange, error ' + JSON.stringify(e));
        }
      }
    });
  }

  /**
   * ReaderKit 资源回调（官方实现范式）。
   * 排版引擎按路径索取资源时，这里把字节还给它：
   *  · **字体**（.ttf/.otf/.woff2）：① rawfile（工程内字体）② 沙箱/绝对路径
   *    （本工程指向系统字体 /system/fonts/HarmonyOS_Sans_SC.ttf）
   *  · **背景图**（.jpg/.jpeg/.png，2026-09-25 材质功能新增）：
   *    ⚠️ 根因修复 —— 旧版这里 `!isFont` 直接回空字节，引擎要背景图时拿到的就是空
   *    ⇒ 材质背景全部回落成纯色（用户实测「每个都变成纯色了」）。
   *    现在图片请求：① 先试 rawfile（`themeBgImg` 直接传 rawfile 名的场景）
   *    ② 再按请求的绝对/沙箱路径读（材质合成图就存在沙箱缓存里）。
   *    ⚠️ 注意图片分支用的是**请求参数 filePath**（每次请求各不相同），
   *       不能像字体分支那样读 `readerSetting.fontPath`（那是单字体的历史巧合）。
   */
  private resourceRequest: bookParser.CallbackRes<string, ArrayBuffer> =
    (filePath: string): ArrayBuffer => {
      hilog.info(0x0000, 'testTag', 'resourceRequest: %{public}s', filePath);
      if (filePath.length === 0) {
        return new ArrayBuffer(0);
      }
      const lower = filePath.toLowerCase();
      const isFont = lower.indexOf('.ttf') !== -1 || lower.indexOf('.otf') !== -1
        || lower.indexOf('.woff2') !== -1;
      const isImage = lower.indexOf('.jpg') !== -1 || lower.indexOf('.jpeg') !== -1
        || lower.indexOf('.png') !== -1;
      if (!isFont && !isImage) {
        return new ArrayBuffer(0);
      }
      // ── 背景图分支（2026-09-25）：按请求路径给字节 ──────────────────────────
      if (isImage) {
        // ① rawfile（themeBgImg 传 rawfile 文件名的场景）
        try {
          const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
          const v: Uint8Array = ctx.resourceManager.getRawFileContentSync(filePath);
          if (v.byteLength > 0) {
            hilog.info(0x0000, 'testTag', 'resourceRequest: img rawfile ok %{public}d bytes',
              v.byteLength);
            return v.buffer as ArrayBuffer;
          }
        } catch (e) {
          // rawfile 里没有：继续走绝对/沙箱路径
        }
        // ② 沙箱 / 绝对路径（材质合成图）
        try {
          const st = fs.statSync(filePath);
          const f = fs.openSync(filePath, fs.OpenMode.READ_ONLY);
          const buf = new ArrayBuffer(st.size);
          fs.readSync(f.fd, buf);
          fs.closeSync(f);
          hilog.info(0x0000, 'testTag', 'resourceRequest: img file ok %{public}d bytes (%{public}s)',
            st.size, filePath);
          return buf;
        } catch (e) {
          hilog.error(0x0000, 'testTag', 'resourceRequest: 读取背景图失败 %{public}s (%{public}s)',
            e instanceof Error ? e.message : String(e), filePath);
          return new ArrayBuffer(0);
        }
      }
      // ── 字体分支（保持真机验证过的原状）──────────────────────────────────
      // ① rawfile
      try {
        const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
        const v: Uint8Array = ctx.resourceManager.getRawFileContentSync(this.readerSetting.fontPath);
        if (v.byteLength > 0) {
          hilog.info(0x0000, 'testTag', 'resourceRequest: rawfile ok %{public}d bytes', v.byteLength);
          return v.buffer as ArrayBuffer;
        }
      } catch (e) {
        // 工程里没有该字体：继续走绝对路径
      }
      // ② 沙箱 / 绝对路径
      try {
        const st = fs.statSync(this.readerSetting.fontPath);
        const f = fs.openSync(this.readerSetting.fontPath, fs.OpenMode.READ_ONLY);
        const buf = new ArrayBuffer(st.size);
        fs.readSync(f.fd, buf);
        fs.closeSync(f);
        hilog.info(0x0000, 'testTag', 'resourceRequest: file ok %{public}d bytes (%{public}s)',
          st.size, this.readerSetting.fontPath);
        return buf;
      } catch (e) {
        hilog.error(0x0000, 'testTag', 'resourceRequest: 读取字体失败 %{public}s',
          e instanceof Error ? e.message : String(e));
        return new ArrayBuffer(0);
      }
    };

  aboutToDisappear(): void {
    // ★ 退出阅读 ⇒ 最终进度落库 + 广播书架刷新（2026-10-07）：
    //   书架只认 `BOOK_IS_BOOK_REFRESHING` 广播重查，而本页原先只写库不广播、
    //   宿主 Index 的 onPageShow 又不因 NavDestination pop 触发 ⇒ 回书架不重排。
    //   await 落库后再广播的原因见 flushReadProgressThenNotifyShelf 注释。
    this.flushReadProgressThenNotifyShelf();
    // ★ 页面销毁：两个 UI 刷新器必须显式停掉（2026-10-07）。
    //   旧实现只在「退出听书」(`exitListening`) 里停 sleepTicker，而 `aboutToDisappear`
    //   既没停 sleepTicker 也没停 infoTicker ⇒ 组件销毁后回调仍可能打到已销毁页面上。
    this.stopSleepTicker();
    this.stopInfoTicker();
    // ★ 恢复系统状态栏 / 导航栏（2026-09-22 真机反馈修复：**退出阅读页后状态栏不回来**）
    //
    // ── 症状 ────────────────────────────────────────────────────────────────
    // 用户报告：「一旦进入某一本书，整个页面就会上移…返回到书架书架也被上移了，状态栏没了」
    //
    // ── 根因（迁 Navigation 之后 API 不再被调用）─────────────────────────────
    // 进入阅读页时在 `aboutToAppear` 里隐藏了系统栏：
    //   `WindowAbility.getInstance().toggleWindowSystemBar([], …)`（本文件 :609）
    // 而对应的**恢复**调用原本寄生在 `pages/Index.ets` 的 `onPageShow()`
    // （`Index.ets:148` 与 `:176`）：
    //   `toggleWindowSystemBar(['status', 'navigation'], …)`
    //
    // ⚠️ 但第 3 期把阅读页迁成了 `NavDestination`（`Index.ets:328` 的
    //    `NavDestination(){ ReaderPage3(...) }`）。`Index` 是 `@Entry` 根页面，
    //    `NavDestination` 压栈时它**不会被隐藏** ⇒ **`Index.onPageShow()` 再也不会触发**
    //    （`onPageShow` 是 `@Entry` 页面专属生命周期，只有页面级显示/隐藏才回调）。
    //    `aboutToAppear` 也只在 `Index` 首次创建时跑一次。
    //    ⇒ 隐藏生效、**恢复永远不执行**，状态栏一去不回。
    //
    // 为何"整页上移"：`EntryAbility.ets:195-203` 注册了 `avoidAreaChange` 监听 ——
    // 系统栏隐藏后 `TYPE_SYSTEM` 的 `topRect.height` 变成 0，被写进 `topRectHeight`
    // （`AppStorage`），而各页面正是用 `topRectHeight` 做顶部避让
    // （`ComponetModifier.ColumnModifier:12`、`IndexShelf:165`、`Header:104`…）
    // ⇒ 避让归零，内容整体上移、顶到屏幕最上沿。
    // 窗口本身一直是全屏（`EntryAbility.ets:161` 启动即 `setWindowLayoutFullScreen(true)`），
    // 所以避让**完全依赖** `topRectHeight` 这个值 —— 它归零就必然上移。
    //
    // ── 为什么恢复系统栏 + 还回避让值（2026-09-22 二次修正：改为存旧值）────────
    // 最初只调 `setWindowSystemBarEnable(['status','navigation'])`，指望系统派发
    // `avoidAreaChange` 让它用真实高度重算 `topRectHeight`。功能上可行，但有两个毛病：
    //   ① 那个事件是**异步**的，退出动画期间避让还没纠正完 ⇒ 用户看到"先跳一下再归位"；
    //   ② 主页因此会上下跳 38.81vp（用户原话：「明显有个上下跳的感觉很割裂」）。
    // 现在改成：进入时 `freezeTopRect()` 存下旧值，这里原样还回去 —— **不做重算**
    // ⇒ 与 `EntryAbility.toVp()` 的 px→vp 算法零偏差，也没有异步窗口期。
    // 同时 `EntryAbility` 的 `avoidAreaChange` 监听会在沉浸期跳过更新（否则会打破冻结）。
    //
    // ── 屏闪修复（2026-09-23）：系统栏恢复 + 顶部避让解冻**已迁出**本方法 ────────
    // 原来在这里（= 返回转场开始的那一刻）就恢复系统栏并解冻避让 ⇒ 退出动画进行中
    // 世界发生系统级跳变（用户实测：书与 App 异色时"关闭书籍回位"的屏闪更明显）。
    // 现在推迟到 `pages/Index.ets` 阅读分支 NavDestination 的 `onDisAppear`
    // （返回转场结束、页面真正销毁之后）执行，与 Ability 配色还原同批；
    // 冻结/恢复的设计依据（存旧值原样还回、不做重算）保持不变。
    PreferencesUtil.putSync(`isScreenState`, this.isScreenState)
    // 自定义背景色的**兜底落盘**（2026-09-25）：正常路径上每次抬手都已经写过一次
    // （`applyCustomBg(true)`），这里只覆盖"拖到一半直接退出/被系统杀"的极端情况。
    // `customBgTouched` 保证**没碰过这个控件的书不会留下覆盖记录** ——
    // 否则每本书都会有一条 `{on:false}`，把"同步全局"的效果挡在门外。
    if (this.customBgTouched) {
      this.saveCustomBg()
    }
    // 亮度落盘（见 aboutToAppear 的说明）：随系统时 getBrightness 返回 -1，正好是"跟随系统"的哨兵值。
    PreferencesUtil.putSync('ReaderBrightness', BrightnessUtil.getBrightness('reader'))
    // ★ 退出阅读页后把**窗口亮度**交还给系统（`-1` = 跟随系统）。
    //   与上面状态栏恢复是**同一个根因**：这行原本寄生在 `Index.onPageShow()`
    //   （`Index.ets:146`），而阅读页迁成 NavDestination 后 Index 不再隐藏、
    //   `onPageShow` 不再触发 ⇒ 阅读页里调过的亮度会一直残留到整个 App。
    //   落盘（上一行）与交还窗口亮度是两件事，**都要做**：
    //   落盘保住用户的选择，交还窗口让书架/我的等页面回到系统亮度。
    BrightnessUtil.setBrightness('default', -1)
    // ★★ 第一件事就置"已销毁"，让正在等待的 `startPlay()` 异步链立刻失效 ★★
    // 必须在任何 `releaseBook()` 之前 —— 否则那条链可能在释放之后才继续执行，
    // 对着已释放的控制器调 `registerBookParser`，正是黑屏的成因。见 `disposed` 注释。
    this.disposed = true;
    // 按键翻页退订（2026-10-07）：退书立即交还系统音量键（官方要求"确定响应时才激活"）
    ReaderKeyTurn.detachReader();
    // 信息窗秒级刷新停止（2026-10-07）
    if (this.infoTicker !== -1) {
      clearInterval(this.infoTicker);
      this.infoTicker = -1;
    }
    // 解绑进度同步的进程级监听（2026-10-05，审计 P1-4）：`emitter.on` 不解绑会让
    // 闭包连同本实例（CatalogList / anchorNodeCache）一起驻留，开书次数越多漏得越多。
    // 放在 `disposed = true` 之后：即使有事件在途，回调体也会先被 `disposed` 拦掉。
    this.unregisterWebSyncListener();
    // ── 屏闪修复（2026-09-23）：Ability 配色还原**已迁出**本方法 ────────────────
    // 原来在这里（返回转场开始）就 `setReaderActive(false)+sync` ⇒ 退出动画中途
    // Ability 配色翻转，正在缩回的深色书面被系统级重涂闪成浅色（用户实测明显）。
    // 现在 `setReaderActive(false)` + `NightMode.sync()` 推迟到 Index 阅读分支的
    // `onDisAppear`（返回转场结束后）执行；`restoreAbilityColorMode()` 已删除。
    display.off('change', this.screenDensityCallBack);
    // 控制器未完成初始化（`BookHandler` 尚未拿到）时，`off`/`releaseBook` 都是对
    // 一个**尚未就绪**的控制器操作，容易把原生状态机带进非法状态 ⇒ 跳过。
    // 这种情况下 `startPlay()` 的异步链会因为上面 `disposed = true` 而自行退出，
    // 不会留下半初始化状态。
    if (this.BookHandler) {
      this.readerComponentController.off('pageShow');
      this.readerComponentController.off('resourceRequest');
      this.readerComponentController.releaseBook();
    } else {
      hilog.info(0x0000, 'testTag',
        'aboutToDisappear: 书籍尚未加载完成（快速退出），跳过 off/releaseBook');
    }
    if (this.locateTimer >= 0) {
      clearTimeout(this.locateTimer);
      this.locateTimer = -1;
    }
    // 离开阅读页时结束朗读（避免回调引用已销毁页面；后台收听留待后续版本）
    TtsEngine.stop('');
  }

  // ---------- 朗读（TTS）接线 ----------
  private registerTtsCallbacks(): void {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    TtsEngine.init(context);
    // 阅读器当前位置提供者：开始/恢复播放时锚定"当前页页首"（ReaderKit 坐标）
    TtsEngine.setReaderPositionProvider((): TtsSegmentPos | null => {
      const r = this.pageRange;
      if (r === null) {
        return null;
      }
      const pos: TtsSegmentPos = {
        spineIndex: r.spine,
        nodeIndex: r.startNode,
        charStart: r.startChar
      };
      return pos;
    });
    TtsEngine.setCallbacks({
      onState: (s: TtsState): void => {
        this.ttsState = s;
        if (s === 'stopped') {
          this.ttsSegText = '';
          this.ttsSegTotal = 0;
          this.immPageIdx = -1;
          this.immPagesKey = '';
          this.immReady = false;
          this.followSuspended = false;
        }
        this.updateHighlight();
      },
      onChapter: (spineIndex: number, title: string): void => {
        this.ttsSpineIndex = spineIndex;
        this.ttsChapterTitle = title;
        this.immPageIdx = -1; // 换章：重新分页并重新锚定
        this.immPagesKey = '';
        this.immReady = TtsEngine.currentNodeTexts() !== null; // 让沉浸层立刻出现（可观察状态）
        // 只同步目录下标；真正的翻章（startPlay）由定位流程按精确坐标执行
        this.syncCatalogIndex(spineIndex);
      },
      onSegment: (segIndex: number, total: number, text: string): void => {
        this.ttsSegIndex = segIndex;
        this.ttsSegTotal = total;
        this.ttsSegText = text;
        this.ttsCharInSentence = 0;
        this.ttsSentenceLen = text.length;
        this.immSegSerial++;
        if (!this.immReady && TtsEngine.currentNodeTexts() !== null) {
          this.immReady = true;
        }
        const cur = TtsEngine.currentSegment();
        if (cur !== null) {
          this.lastAudioPos = cur;
        }
        this.scrollMiniBar(0);
        this.syncImmersivePage();
        this.updateHighlight();
        // 页级自动跟随：朗读推进到当前页之外时才翻页（silent，不弹 toast）
        this.autoFollowTts();
      },
      onProgress: (charInSentence: number, sentenceLen: number): void => {
        this.ttsCharInSentence = charInSentence;
        this.ttsSentenceLen = sentenceLen;
        this.scrollMiniBar(sentenceLen > 0 ? charInSentence / sentenceLen : 0);
      },
      onToast: (msg: string): void => {
        this.getUIContext().getPromptAction().showToast({ message: msg });
      }
    });
  }

  // ---------- 沉浸听读：**章节固定分页** ----------
  // "一页"必须是确定的：用当前排版参数把整章预先切成固定页；
  // 朗读只负责"跳到包含当前段的那一页"，页面内容不随朗读漂移。
  // （之前的"滑动窗口 + 锚点"会让页边界随朗读变化 ⇒ 用户说不清自己在第几页、
  //   从本页开始时上面还会多冒出一段"上一页衔接"。）
  private ensureImmersivePages(): void {
    const nodes = TtsEngine.currentNodeTexts();
    if (nodes === null) {
      this.immPages = [];
      this.immPageOfNode = [];
      this.immPagesKey = '';
      return;
    }
    const key = `${TtsEngine.currentChapter()}:${this.readerSetting.fontSize}`
      + `:${this.readerSetting.lineHeight.toFixed(1)}:${this.effectiveLineMul().toFixed(3)}`
      + `:${this.calibWidthRatio.toFixed(3)}`;
    if (key === this.immPagesKey && this.immPages.length > 0) {
      return;
    }
    const g = this.geom();
    const cpl = this.cplFor(
      Math.max(1, (this.readerSetting.viewPortWidth > 0 ? this.readerSetting.viewPortWidth : this.windowWidth)
        * this.calibWidthRatio), g[2]);
    const maxLines = Math.max(1, Math.floor(this.immersiveBudgetPx() / Math.max(1, g[3])));
    // ★ 行粒度分页（与 ReaderKit 一致：可在段落中间断页）
    //   此前按"整段"切页：当"已用行数 + 整段行数 > 上限"时只能提前关页，
    //   大段落会白白浪费半页（实测 estLines=6/12 = 50%），观感就是每页占屏比例乱跳。
    //   改成按行填满：每页精确 maxLines 行，只有本章末页才会不满。
    const pages: number[][][] = [];
    const map: number[] = [];
    for (let i = 0; i < nodes.length; i++) {
      map.push(-1);
    }
    let curPage: number[][] = [];
    let used = 0;
    for (let i = 0; i < nodes.length; i++) {
      const t = nodes[i];
      if (t.trim().length === 0) {
        continue;
      }
      const len = t.length;
      let from = 0;
      while (from < len) {
        const indent = from === 0 ? HL_INDENT_SLOTS : 0;
        const nl = Math.max(1, Math.ceil((len - from + indent) / cpl));
        const room = maxLines - used;
        if (nl <= room) {
          if (map[i] < 0) {
            map[i] = pages.length; // 该节点起始页
          }
          curPage.push([i, from, len]);
          used += nl;
          from = len;
        } else if (room <= 0) {
          pages.push(curPage);
          curPage = [];
          used = 0;
        } else {
          // 本页剩余空间放不下整段 ⇒ 按行切：本页放 room 行，余下到下一页
          const takeChars = Math.max(1, room * cpl - indent);
          const to = Math.min(len, from + takeChars);
          if (map[i] < 0) {
            map[i] = pages.length;
          }
          curPage.push([i, from, to]);
          from = to;
          pages.push(curPage);
          curPage = [];
          used = 0;
        }
      }
    }
    if (curPage.length > 0) {
      pages.push(curPage);
    }
    this.immPages = pages;
    this.immPageOfNode = map;
    this.immPagesKey = key;
    hilog.info(0x0000, 'testTag', 'imm: pages=%{public}d maxLines=%{public}d cpl=%{public}d 行高=%{public}spx',
      pages.length, maxLines, cpl, g[3].toFixed(1));
    for (let pi = 0; pi < pages.length && pi < 40; pi++) {
      const pg = pages[pi];
      let est = 0;
      let chars = 0;
      for (let k = 0; k < pg.length; k++) {
        const sg = pg[k];
        const tx = nodes[sg[0]].substring(sg[1], sg[2]);
        chars += tx.length;
        est += Math.max(1, Math.ceil((tx.length + (sg[1] === 0 ? HL_INDENT_SLOTS : 0)) / cpl));
      }
      hilog.info(0x0000, 'testTag', 'imm-page %{public}d: segs=%{public}d estLines=%{public}d chars=%{public}d',
        pi + 1, pg.length, est, chars);
    }
  }

  /** 当前显示的页的段列表（段 = [节点号, 起始字符, 结束字符]） */
  private immCurPage(): number[][] {
    this.ensureImmersivePages();
    const p = this.immPageIdx;
    return p >= 0 && p < this.immPages.length ? this.immPages[p] : [];
  }

  /** 朗读所在的页号（-1 = 未知） */
  private immAudioPage(): number {
    const seg = TtsEngine.currentSegment();
    if (seg === null || this.immPageOfNode.length === 0) {
      return -1;
    }
    const n = seg.nodeIndex;
    return n >= 0 && n < this.immPageOfNode.length ? this.immPageOfNode[n] : -1;
  }

  /** 跟随：只有朗读跑出当前页时才翻到朗读所在页（页是固定的，不会漂） */
  private syncImmersivePage(): void {
    if (!this.ttsPrefs.immersiveListen) {
      return;
    }
    this.ensureImmersivePages();
    const ap = this.immAudioPage();
    if (ap < 0) {
      return;
    }
    if (this.immPageIdx < 0) {
      this.immPageIdx = ap;
      return;
    }
    if (this.immManual) {
      // 手动翻页期间**不**把视图拽回朗读位置（此前重构时丢了这段保护，
      // 导致"一翻页、下一句就被拉回"）；①朗读回到当前页 或 ②手动浏览超时 ⇒ 恢复跟随。
      if (ap === this.immPageIdx) {
        this.immManual = false;
      } else if (Date.now() - this.immManualAt > 8000) {
        this.immManual = false;
        hilog.info(0x0000, 'testTag', 'imm: auto-resume following (manual browse timeout)');
      }
      if (this.immManual) {
        return;
      }
    }
    if (ap !== this.immPageIdx) {
      this.immPageIdx = ap;
      hilog.info(0x0000, 'testTag', 'imm: follow page=%{public}d total=%{public}d',
        ap, this.immPages.length);
    }
  }

  /** 沉浸模式下手动翻页（点左侧=上一页 / 右侧=下一页），步长正好一页 */
  private immPage(dir: number): void {
    this.ensureImmersivePages();
    if (this.immPages.length === 0) {
      return;
    }
    const cur = this.immPageIdx < 0 ? 0 : this.immPageIdx;
    const next = Math.max(0, Math.min(this.immPages.length - 1, cur + dir));
    if (next === cur) {
      return;
    }
    this.immPageIdx = next;
    this.immManual = true; // 手动翻页后暂停自动跟随（8s 兜底 / 或点「回到朗读」解除）
    this.immManualAt = Date.now();
    hilog.info(0x0000, 'testTag', 'imm: manual page=%{public}d/%{public}d', next + 1, this.immPages.length);
  }

  /** 回到朗读所在页 */
  private immBackToAudio(): void {
    const ap = this.immAudioPage();
    this.immManual = false;
    if (ap >= 0) {
      this.immPageIdx = ap;
    }
    this.updateHighlight();
  }

  /** 退出听书：停止朗读（沉浸层随之消失，回到普通阅读模式；下次进听书仍是沉浸） */
  private exitListening(): void {
    this.followSuspended = false;
    this.immPageIdx = -1;
    TtsEngine.stop('');
    // 停掉「睡眠定时剩余量」的刷新定时器（避免销毁后回调引用已销毁页面）
    this.stopSleepTicker();
  }

  /** #1：上次悬浮条滚动动画的发起时刻（ms），用于让动画时长贴合字符回调的真实间隔 */
  private miniScrollAt: number = 0;

  /**
   * 悬浮条按句内字符进度前滚。
   *
   * **#1 修复（"滚动动画生硬/诡异"）**
   * 旧实现固定 `duration: 160, Curve.Linear`。而进度回调来自
   * `TtsEngine` 的**逐字符**回传（`onProgress`，仅在句内字符变化时触发），
   * 间隔约 170~300ms 且随字词长度/语速抖动。
   * ⇒ 固定 160ms 的动画总是**先跑完、再静止等待**下一次回调，
   *    观感就是"走一小段 → 停一下 → 再走"的顿挫（用户描述的"生硬、诡异"）。
   *
   * 修法：**让本次动画时长等于距上次调用的真实间隔**（夹在 80~500ms）。
   * 这样动画恰好持续到下一次回调到来，逐段首尾相接 ⇒ 连续匀速滚动。
   * 曲线仍用 `Curve.Linear` —— 因为真实运动本来就是匀速（语速恒定），
   * 用缓动反而会在每个字符步进处产生"急起急停"。
   * 换句时调用方传 `ratio = 0`，此时不补间（`duration: 0`）立即归位，
   * 并重置节奏基准，避免把上一句的间隔带过来。
   */
  private scrollMiniBar(ratio: number): void {
    const maxOff = this.miniTextW - this.miniViewW;
    if (maxOff <= 0) {
      return;
    }
    const r = Math.max(0, Math.min(1, ratio));
    const now = Date.now();
    let dur = 160;
    if (r <= 0 || this.miniScrollAt === 0) {
      dur = 0;                                   // 换句/首次：立即归位，不要拖
    } else {
      const gap = now - this.miniScrollAt;
      dur = Math.max(80, Math.min(500, gap));    // 贴合真实回调间隔
    }
    this.miniScrollAt = now;
    try {
      this.miniScroller.scrollTo({
        xOffset: r * maxOff,
        yOffset: 0,
        animation: { duration: dur, curve: Curve.Linear }
      });
    } catch (e) {
      // 滚动器尚未绑定
    }
  }

  /** 悬浮条主按钮：已翻走 ⇒ 一下「从此页开始」；否则 暂停/续播/开播 */
  private miniBarPrimary(): void {
    if (this.followSuspended) {
      this.playFromCurrentPage();
      return;
    }
    if (this.ttsState === 'playing') {
      TtsEngine.pause();
      return;
    }
    if (this.ttsState === 'paused') {
      TtsEngine.resume();
      return;
    }
    // ★ stopped 分支（2026-10-07 补）：旧实现写成 `else → TtsEngine.resume()`，而
    //   `TtsEngine.resume()` 在**非 paused** 状态会直接 `return`（`TtsEngine.ets:988-1001`）
    //   ⇒ 表现为"点了没反应"。这条路径原先就存在（全书读完 / 播控中心停止后再按悬浮条），
    //   本轮的睡眠定时到点（暂停中被停）让它**更容易撞上**，故一并修掉。
    //   语义与听书面板对齐：面板在 stopped 时走 `onStart`（`TtsControlPanel.ets:807-816`），
    //   这里同样按"从阅读器当前页页首开始朗读"处理。
    this.ttsStart();
  }

  /** 从阅读器当前页页首重新开始朗读（停掉旧流，重新合成播放） */
  private playFromCurrentPage(): void {
    this.followSuspended = false;
    // 沉浸模式：用户看到的"这一页"是我们自绘的固定页，取它的第一段。
    // 被盖住的 ReaderKit 页会被自动跟随保持在**朗读位置**上，拿它当"本页"就会永远跳回正在读的那句。
    if (this.immersiveActive()) {
      const pg = this.immCurPage();
      if (pg.length > 0) {
        const a = pg[0][0]; // 本页第一个段的节点号（从本页开始读）
        this.lastNavMs = Date.now();
        this.lastFollowNode = a;
        hilog.info(0x0000, 'testTag', 'play-from-page(immersive): spine=%{public}d node=%{public}d char=%{public}d page=%{public}d',
          TtsEngine.currentChapter(), a, pg[0][1], this.immPageIdx + 1);
        TtsEngine.seekToChapter(TtsEngine.currentChapter(), a, pg[0][1]);
        return;
      }
    }
    const r = this.pageRange;
    if (r === null) {
      this.ttsStart();
      return;
    }
    if (TtsEngine.getState() === 'stopped') {
      this.ttsStart();
      return;
    }
    hilog.info(0x0000, 'testTag', 'play-from-page: spine=%{public}d node=%{public}d char=%{public}d',
      r.spine, r.startNode, r.startChar);
    this.lastFollowNode = r.startNode;
    this.lastNavMs = Date.now();
    TtsEngine.seekToChapter(r.spine, r.startNode, r.startChar);
  }

  /**
   * spine 号 → 目录号 的映射缓存（懒建一次）。`null` = 尚未建立。
   * 换书时（`startPlay` 重新拿到 `BookHandler`）必须重置。
   */
  private spineToCatalog: Map<number, number> | null = null

  /**
   * 正文号（spine）→ 目录号 的换算。
   *
   * 两者是**不同坐标系**：目录项靠 `catalogItem.resourceFile` 与 `spineItem.href`
   * 关联，全工程原有的换算只有反方向的 `getResourceItemByCatalog()`。
   *
   * 为什么必须缓存：`syncCatalogIndex()` 自 2026-09-21 起被 `pageShow`
   * **每翻一页**调用一次，而原实现每次都要 `getSpineList()` 并遍历整个目录
   * （真机日志：`catalog list length: 765`）⇒ 每页重复分配/解析整个目录数组。
   * 而这个映射在一本书内是常量，建一次即可。
   *
   * 匹配语义与旧实现**完全一致**：同一 spine 取**目录中第一个**匹配的项。
   */
  private catalogIndexForSpine(spineIndex: number): number {
    if (this.spineToCatalog === null) {
      const m = new Map<number, number>()
      try {
        const spines = this.BookHandler?.getSpineList() ?? []
        const catalog = this.BookHandler?.getCatalogList() ?? []
        const hrefToSpine = new Map<string, number>()
        for (let s = 0; s < spines.length; s++) {
          const h = spines[s].href ?? ''
          if (h.length > 0 && !hrefToSpine.has(h)) {
            hrefToSpine.set(h, s)
          }
        }
        for (let i = 0; i < catalog.length; i++) {
          const h = catalog[i].resourceFile ?? ''
          const s = h.length > 0 ? hrefToSpine.get(h) : undefined
          if (s !== undefined && !m.has(s)) {
            m.set(s, i)
          }
        }
      } catch (e) {
        // 忽略：建不出映射就退化为"不同步目录号"（与旧实现未匹配时行为一致）
      }
      this.spineToCatalog = m
    }
    return this.spineToCatalog.get(spineIndex) ?? -1
  }

  /**
   * 同步目录下标（章节滑杆/标题用）。
   * 调用点：① 朗读换章（`onChapter`）；② **每次 `pageShow`**（2026-09-21 新增，
   * 修复"纯默读时目录号永不推进"⇒ 书签/进度/读完判定全部失准）。
   */
  private syncCatalogIndex(spineIndex: number): void {
    try {
      const i = this.catalogIndexForSpine(spineIndex)
      if (i >= 0) {
        this.bookData.durChapterIndex = i
      }
    } catch (e) {
      // 忽略
    }
  }

  // ---------- 精确定位（ReaderKit 坐标系：spine / 块节点 / 节点内字符） ----------
  /**
   * "19=0#43;@;0" → [块节点下标(0 基), 节点内字符偏移]。
   * 官方 FAQ：domPos = 章节标识=子节点索引=子孙节点索引#文字索引;@;进度；
   * 本工程实际形态 "<子节点索引>=0#<字符下标>"，且 X 段序号满足 X = 2k−1
   * （见文件头注释：偶数 X 是不渲染的块间空节点）。
   * 因此 node = floor((X−1)/2)；遇到偶数 X 也归到它前面那个渲染块。
   */
  private parseDomPos(domPos: string): number[] {
    const eq = domPos.indexOf('=');
    const hash = domPos.indexOf('#');
    const semi = hash >= 0 ? domPos.indexOf(';', hash) : -1;
    const x = eq > 0 ? parseInt(domPos.substring(0, eq)) : NaN;
    const y = hash >= 0 && semi > hash ? parseInt(domPos.substring(hash + 1, semi)) : 0;
    if (!Number.isFinite(x)) {
      return [0, 0];
    }
    const node = Math.max(0, Math.floor((Math.max(1, x) - 1) / 2));
    return [node, Number.isFinite(y) ? Math.max(0, y) : 0];
  }

  /** [块节点下标(0 基), 节点内字符偏移] → domPos（与 pageShow 回报同构） */
  private domPosFor(node: number, char: number): string {
    return `${2 * Math.max(0, node) + 1}=0#${char};@;0`;
  }

  /** 当前页范围是否覆盖目标位置（含边界字符级校验） */
  private rangeCovers(r: PageRange, node: number, char: number): boolean {
    const startOk = r.startNode < node || (r.startNode === node && r.startChar <= char);
    const endOk = r.endNode > node || (r.endNode === node && r.endChar >= char);
    return startOk && endOk;
  }

  private rangeText(): string {
    const r = this.pageRange;
    if (r === null) {
      return 'none';
    }
    return `spine=${r.spine} [${r.startNode}#${r.startChar}..${r.endNode}#${r.endChar}]`;
  }

  /** 定位提示（600ms 去抖，避免同一次关闭动作弹两次） */
  private toastLocate(msg: string): void {
    const now = Date.now();
    if (now - this.lastLocateToastMs < 600) {
      return;
    }
    this.lastLocateToastMs = now;
    this.getUIContext().getPromptAction().showToast({ message: msg });
  }

  /**
   * 定位到目标位置（ReaderKit 坐标）。
   * 三级策略：
   *   1) startPlay(spine, domPos) —— 官方"恢复阅读进度"的用法，支持段中位置；
   *   2) 若未产生 pageShow 或在超时内没落到位 → 翻页搜索兜底（按 (节点,字符) 逐页逼近）；
   *   3) 搜索到上限即如实告知"未精确对齐"，绝不假报成功。
   */
  private requestLocate(spine: number, node: number, char: number, silent: boolean,
    noFallback: boolean = false): void {
    const n = Math.max(0, node);
    const c = Math.max(0, char);
    const cur = this.locateTarget;
    if (cur !== null && cur.spine === spine && cur.node === n && cur.char === c) {
      return; // 同一目标已在定位中，重复触发直接忽略
    }
    this.flipSearch = null;
    const target: LocateTarget = {
      spine: spine, node: n, char: c, silent: silent, noFallback: noFallback
    };
    // 目标已经在当前页可见：不重排页面（避免无谓跳动），直接确认
    const cur0 = this.pageRange;
    if (cur0 !== null && cur0.spine === spine && this.rangeCovers(cur0, n, c)) {
      this.updateHighlight();
      if (!silent) {
        this.toastLocate(`已定位到第 ${n + 1} 段`);
      }
      return;
    }
    this.locateTarget = target;
    this.lastNavMs = Date.now();
    hilog.info(0x0000, 'testTag', 'locate: → spine=%{public}d node=%{public}d char=%{public}d cur=%{public}s',
      spine, n, c, this.rangeText());
    this.startPlayAt(spine, this.domPosFor(n, c));
    this.armLocateTimeout(target);
  }

  private startPlayAt(spine: number, domPos: string): void {
    try {
      this.readerComponentController.startPlay(spine, domPos)
        .then((): void => {
          hilog.info(0x0000, 'testTag', 'locate: startPlay ok spine=%{public}d pos=%{public}s', spine, domPos);
        })
        .catch((e: BusinessError): void => {
          hilog.warn(0x0000, 'testTag', 'locate: startPlay rejected %{public}s', JSON.stringify(e));
        });
    } catch (e) {
      hilog.warn(0x0000, 'testTag', 'locate: startPlay throw');
    }
  }

  /** startPlay 可能被引擎忽略（同章/段中位置不重排）而不产生 pageShow：超时转兜底 */
  private armLocateTimeout(target: LocateTarget): void {
    if (this.locateTimer >= 0) {
      clearTimeout(this.locateTimer);
    }
    this.locateTimer = setTimeout((): void => {
      this.locateTimer = -1;
      if (this.locateTarget !== target) {
        return;
      }
      this.locateTarget = null;
      if (target.noFallback) {
        // 便利定位（如「我的 → 书签」回跳）不做逐页逼近：
        // 连续重排几十页会让界面长时间无法操作（真机表现为"点不动、像有蒙版"）。
        hilog.info(0x0000, 'testTag', 'locate: startPlay 未落位且 noFallback ⇒ 停在当前章');
        this.finishLocate(target, false);
        return;
      }
      const r = this.pageRange;
      hilog.warn(0x0000, 'testTag', 'locate: startPlay 未落位，转翻页搜索 (%{public}s)', this.rangeText());
      if (r !== null) {
        this.beginSearch(target, r);
      } else if (!target.silent) {
        this.toastLocate('暂无法获取阅读位置，请稍后重试');
      }
    }, 700);
  }

  /** pageShow 驱动定位状态机 */
  private onPageShowLocate(r: PageRange): void {
    const t = this.locateTarget;
    if (t !== null) {
      if (r.spine === t.spine && this.rangeCovers(r, t.node, t.char)) {
        // 诊断：目标落在页首/页中/页尾——用于确知 startPlay 的落点语义
        const where = r.startNode === t.node
          ? (r.startChar === t.char ? 'HEAD' : 'HEAD-partial')
          : (r.endNode === t.node ? 'TAIL' : 'MIDDLE');
        this.locateTarget = null;
        hilog.info(0x0000, 'testTag', 'locate: landed node=%{public}d char=%{public}d at %{public}s in %{public}s',
          t.node, t.char, where, this.rangeText());
        this.finishLocate(t, true);
        return;
      }
      // startPlay 没把我们送到目标位置 → 逐页逼近（便利定位则直接放弃，避免卡住界面）
      this.locateTarget = null;
      if (t.noFallback) {
        hilog.info(0x0000, 'testTag', 'locate: 未落位且 noFallback ⇒ 停在当前章');
        this.finishLocate(t, false);
        return;
      }
      this.beginSearch(t, r);
      return;
    }
    if (this.flipSearch !== null) {
      this.stepSearch(r);
    }
  }

  private beginSearch(t: LocateTarget, r: PageRange): void {
    const after = t.node > r.endNode || (t.node === r.endNode && t.char > r.endChar);
    if (!after && r.startNode <= 0 && r.startChar <= 0) {
      // 已在章首仍要往前：不存在
      this.finishLocate(t, false);
      return;
    }
    const s: FlipSearch = {
      target: t, dir: after ? 1 : -1, flips: 0, fixes: 0,
      lastNode: r.startNode, lastChar: r.startChar
    };
    this.flipSearch = s;
    this.flipOnce();
  }

  private stepSearch(r: PageRange): void {
    const s = this.flipSearch;
    if (s === null) {
      return;
    }
    if (r.startNode === s.lastNode && r.startChar === s.lastChar) {
      return; // 页位置未变化：渲染还没落位，等下一次 pageShow
    }
    s.lastNode = r.startNode;
    s.lastChar = r.startChar;
    if (r.spine === s.target.spine && this.rangeCovers(r, s.target.node, s.target.char)) {
      this.flipSearch = null;
      this.finishLocate(s.target, true);
      return;
    }
    if (s.flips >= 60 || s.fixes >= 3) {
      this.flipSearch = null;
      this.finishLocate(s.target, false);
      return;
    }
    const after = s.target.node > r.endNode
      || (s.target.node === r.endNode && s.target.char > r.endChar);
    const dir = after ? 1 : -1;
    if (dir !== s.dir) {
      s.fixes++;
    }
    s.dir = dir;
    this.flipOnce();
  }

  private flipOnce(): void {
    const s = this.flipSearch;
    if (s === null) {
      return;
    }
    s.flips++;
    this.lastNavMs = Date.now();
    setTimeout((): void => {
      if (this.flipSearch !== s) {
        return;
      }
      try {
        this.readerComponentController.flipPage(s.dir > 0);
      } catch (e) {
        this.flipSearch = null;
      }
    }, 120);
  }

  private finishLocate(t: LocateTarget, ok: boolean): void {
    if (ok) {
      // 定位成功（含"点文本框回到朗读处"）⇒ 解除手动翻页的挂起，恢复自动跟随
      this.followSuspended = false;
    }
    if (this.locateTimer >= 0) {
      clearTimeout(this.locateTimer);
      this.locateTimer = -1;
    }
    this.updateHighlight();
    if (t.silent) {
      return;
    }
    if (ok) {
      this.toastLocate(`已定位到第 ${t.node + 1} 段`);
    } else {
      this.toastLocate('未精确对齐，已停在朗读附近');
    }
  }

  /**
   * 面板"完成"/点文本显示器/手势返回/点遮罩：回到当前朗读处。
   * 锚定优先用文本框内容在当前章节点里就地匹配（文本框就是"用户看到的这一句"），
   * 失败时回落到引擎记录的句级坐标。
   */
  private backToTtsAnchor(): void {
    if (TtsEngine.getState() === 'stopped') {
      return;
    }
    let seg = TtsEngine.currentSegment();
    if (seg === null) {
      return;
    }
    const shown = this.ttsSegText.trim();
    if (shown.length > 0) {
      const located = TtsEngine.locateText(shown, seg.nodeIndex, seg.charStart);
      if (located !== null) {
        seg = located;
      }
    }
    this.requestLocate(seg.spineIndex, seg.nodeIndex, seg.charStart, false);
  }

  /** 句级自动跟随：目标离开当前页范围才翻页 */
  /** 自动跟随被跳过的原因（只在原因变化时打一条日志，方便一次定位"为什么不跟随"） */
  private followSkipReason: string = ''

  private noteFollowSkip(reason: string): void {
    if (this.followSkipReason !== reason) {
      this.followSkipReason = reason;
      hilog.info(0x0000, 'testTag', 'follow: skipped (%{public}s)', reason);
    }
  }

  private autoFollowTts(): void {
    if (!this.ttsPrefs.autoFollow) {
      this.noteFollowSkip('设置里“跟随翻页”是关的');
      return;
    }
    if (this.followSuspended) {
      this.noteFollowSkip('已被手动翻页挂起');
      return; // 用户手动翻走了：不再把它拽回朗读位置（想看朗读处点 sheet 文本框，想从此页读点浮条按钮）
    }
    const seg = TtsEngine.currentSegment();
    if (seg === null) {
      this.noteFollowSkip('还没有朗读位置');
      return;
    }
    const r = this.pageRange;
    if (r !== null && r.spine === seg.spineIndex && this.rangeCovers(r, seg.nodeIndex, seg.charStart)) {
      this.lastFollowNode = seg.nodeIndex;
      this.noteFollowSkip('');
      return; // 已在当前页，无需翻页
    }
    if (this.locateTarget !== null || this.flipSearch !== null) {
      this.noteFollowSkip('上一次定位还在进行');
      return;
    }
    if (r !== null && r.spine === seg.spineIndex && seg.nodeIndex === this.lastFollowNode) {
      this.noteFollowSkip('同一节点重复回调');
      return;
    }
    this.followSkipReason = '';
    this.lastFollowNode = seg.nodeIndex;
    this.requestLocate(seg.spineIndex, seg.nodeIndex, seg.charStart, true);
  }

  /** 面板"开始朗读"：从阅读器当前页页首开始（ReaderKit 坐标） */
  /**
   * 桌面快捷方式「快速听书」的自动开播等待器。
   *
   * 为什么需要等待：`ttsStart()` 首行是 `if (this.BookHandler === null) { toast('书籍尚未解析完成'); return; }`，
   * 而书籍解析是异步的 —— 在 `aboutToAppear` 里直接调用会白弹一次 toast 且不播。
   * 这里每 300ms 重试，最多约 10 秒（33 次）；超时**静默放弃**，
   * 用户仍可手动点悬浮条的播放按钮（不打扰）。
   *
   * 同时也要求 `pageRange` 就绪，否则 `ttsStart()` 会退回到"从上次章节开头读"，
   * 与"从上次位置继续"的预期不符。
   */
  private autoStartListenWhenReady(attempt: number): void {
    if (this.ttsState !== 'stopped') {
      return; // 已在播（用户抢先手动开始）
    }
    if (this.BookHandler !== null && this.pageRange !== null) {
      this.ttsStart();
      return;
    }
    if (attempt >= 33) {
      return; // 超时：静默放弃
    }
    setTimeout(() => {
      this.autoStartListenWhenReady(attempt + 1);
    }, 300);
  }

  private ttsStart(): void {
    if (this.BookHandler === null) {
      this.getUIContext().getPromptAction().showToast({ message: '书籍尚未解析完成' });
      return;
    }
    this.followSuspended = false;
    let spineIndex: number;
    let startNode = -1;
    let startChar = 0;
    const r = this.pageRange;
    if (r !== null) {
      spineIndex = r.spine;
      startNode = r.startNode;
      startChar = r.startChar;
    } else {
      const item = this.CatalogList.getData(this.bookData.durChapterIndex);
      if (item === null || item === undefined) {
        this.getUIContext().getPromptAction().showToast({ message: '章节信息异常，请重新进入本书' });
        return;
      }
      spineIndex = this.getResourceItemByCatalog(item).index;
    }
    this.ttsSpineIndex = spineIndex;
    this.lastFollowNode = startNode;
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    TtsEngine.start(context, this.BookHandler, spineIndex, this.ttsPrefs,
      this.bookData.bookName, startNode, startChar)
      .catch((e: Object) => {
        hilog.error(0x0000, 'testTag', 'tts start failed: %{public}s', JSON.stringify(e));
      });
  }

  /** 面板上一章/下一章 */
  private ttsSeekChapter(delta: number): void {
    if (TtsEngine.getState() === 'stopped') {
      return;
    }
    const target = Math.max(0, TtsEngine.currentChapter() + delta);
    TtsEngine.seekToChapter(target);
  }

  // ---------- 朗读段落高亮（叠加层，ReaderKit 无高亮 API） ----------
  /**
   * 依据"当前页字符区间 + 当前朗读节点/字符"推算段落在本页的行区间：
   * 逐字符模拟 ReaderKit 的排版（块节点强制换行，每行 cpl 个字符），
   * 得到目标节点的首行与被页尾截断的末行，换算成叠加色块的 y/height。
   * cpl 与文本区顶部偏移由真机截图标定（见 HL_* 常量）。
   */
  /**
   * 标定标尺：与 updateHighlight 用完全相同的换算，把"我们认为的行位"画出来，
   * 与 ReaderKit 实际渲染的文字对照，一张截图即可反解出三个几何常量。
   * 同时把全部输入参数写在左上角，所以截图本身自带证据（不依赖日志）。
   */
  // ---------- 测量通道：用 ArkUI 自己量断行，和 ReaderKit 的页边界对账 ----------
  /**
   * 把当前页的正文按"一段一个 Text"重建后丢给隐藏 Text 去排版，
   * 再读 getLayoutManager() 的真实行数与每行字符区间。
   * 这一步只做**验证**：判断 ArkUI 的断行规律与 ReaderKit 是否同源。
   */
  private refreshMeasure(r: PageRange): void {
    const nodes = TtsEngine.currentNodeTexts();
    if (nodes === null || r.endNode < r.startNode || TtsEngine.currentChapter() !== r.spine) {
      // 没有文本（TTS 尚未启动）或 TTS 章与当前页不是同一章 ⇒ 无法测量
      this.measureParas = [];
      this.measureCtrls = [];
      this.measureIndents = [];
      return;
    }
    const paras: string[] = [];
    for (let n = r.startNode; n <= r.endNode && n < nodes.length; n++) {
      const text = nodes[n];
      const from = n === r.startNode ? r.startChar : 0;
      const to = n === r.endNode ? Math.min(r.endChar, text.length - 1) : text.length - 1;
      paras.push(from <= to ? text.substring(from, to + 1) : '');
    }
    const ctrls: TextController[] = [];
    for (let i = 0; i < paras.length; i++) {
      ctrls.push(new TextController());
    }
    // 段首缩进：只有"从该段第 0 字开始"的段才有；页首若是半段延续则没有缩进。
    // （之前对每一段都加缩进 ⇒ 续段多出一行 ⇒ 整页下半部被压下一行，正是观察到的现象）
    const indents: number[] = [];
    for (let i = 0; i < paras.length; i++) {
      const isContinuation = i === 0 && r.startChar > 0;
      indents.push(isContinuation ? 0 : this.readerSetting.fontSize * HL_INDENT_SLOTS);
    }
    this.measureParas = paras;
    this.measureCtrls = ctrls;
    this.measureIndents = indents;
    const seq = ++this.measureSeq;
    // 等 ArkUI 完成本帧排版后再读布局结果
    setTimeout((): void => {
      if (seq !== this.measureSeq) {
        return;
      }
      this.readMeasure(r, seq);
    }, 120);
  }

  /** 测量用文本区宽度（vp） */
  private textAreaWidthVp(): number {
    const disp = display.getDefaultDisplaySync();
    const densityPx = disp.densityPixels > 0 ? disp.densityPixels : 1;
    const vw = this.readerSetting.viewPortWidth > 0 ? this.readerSetting.viewPortWidth : this.windowWidth;
    return Math.max(1, vw * this.calibWidthRatio) / densityPx;
  }

  private readMeasure(r: PageRange, seq: number): void {
    const nodes = TtsEngine.currentNodeTexts();
    if (nodes === null || this.measureCtrls.length !== this.measureParas.length) {
      return;
    }
    const g = this.geom();
    const fontPx = g[2];
    const lh = g[3];
    const vw = this.readerSetting.viewPortWidth > 0 ? this.readerSetting.viewPortWidth : this.windowWidth;
    const textW = Math.max(1, vw * this.calibWidthRatio);
    const cpl = this.cplFor(textW, fontPx);
    // 我们模型的逐段行数
    const sim = this.simulatePage(nodes, r, cpl);
    const arkCnt: number[] = [];
    let arkTotal = 0;
    let simTotal = 0;
    for (let i = 0; i < this.measureCtrls.length; i++) {
      const lm = this.measureCtrls[i].getLayoutManager();
      const c = lm !== undefined && lm !== null ? lm.getLineCount() : -1;
      arkCnt.push(c);
      if (c > 0) {
        arkTotal += c;
      }
      const s = sim[i * 2 + 1] - sim[i * 2] + 1;
      simTotal += s;
      if (c > 0 && c !== s) {
        hilog.info(0x0000, 'testTag',
          'measure-diff: node=%{public}d ark=%{public}d sim=%{public}d len=%{public}d head=%{public}s',
          r.startNode + i, c, s, this.measureParas[i].length, this.measureParas[i].substring(0, 14));
      }
    }
    hilog.info(0x0000, 'testTag',
      'measure: spine=%{public}d page=[%{public}d#%{public}d..%{public}d#%{public}d] cpl=%{public}d '
        + 'ark=%{public}s sim=%{public}s arkTot=%{public}d simTot=%{public}d',
      r.spine, r.startNode, r.startChar, r.endNode, r.endChar, cpl,
      JSON.stringify(arkCnt), this.calibCounts, arkTotal, simTotal);
    // 末段的逐行字符区间：用来判断页尾到底断在行首还是行中
    const last = this.measureCtrls.length - 1;
    if (last >= 0) {
      const lm = this.measureCtrls[last].getLayoutManager();
      if (lm !== undefined && lm !== null) {
        const cnt = lm.getLineCount();
        const parts: string[] = [];
        for (let i = 0; i < cnt; i++) {
          parts.push(JSON.stringify(lm.getLineMetrics(i)));
        }
        hilog.info(0x0000, 'testTag', 'measure-last: node=%{public}d lines=%{public}d %{public}s',
          r.endNode, cnt, parts.join(' | '));
      }
    }
    // 缓存每段每行的真实矩形 —— 遮罩不再自己数行
    const measured: MeasuredLine[][] = [];
    for (let i = 0; i < this.measureCtrls.length; i++) {
      const lm = this.measureCtrls[i].getLayoutManager();
      const lines: MeasuredLine[] = [];
      if (lm !== undefined && lm !== null) {
        const cnt = lm.getLineCount();
        for (let j = 0; j < cnt; j++) {
          const m = lm.getLineMetrics(j);
          const ln: MeasuredLine = {
            top: m.topHeight, height: m.height, left: m.left, width: m.width
          };
          lines.push(ln);
        }
      }
      measured.push(lines);
    }
    this.measuredParas = measured;
    this.measuredKey = this.measureKeyFor(r);
    // —— 自动校准行高：行高 = 页高 ÷ 实测每页行数 ——
    // 满页的行数就是当前排版下的每页容量；取观察到的最大值（单调递增，坏页不会把它拉小）。
    if (arkTotal > this.learnedCapacity) {
      this.learnedCapacity = arkTotal;
      this.recomputeAutoPitch();
      this.saveCalib();
      // 行高变了 ⇒ 用新行高重排一次再读（第二遍 derived 与现值相等，不会循环）
      this.measurePending = '';
      this.refreshMeasure(r);
      return;
    }
    this.measurePending = '';
    // 用真实矩形重算遮罩
    this.updateHighlight();
  }

  /**
   * 用 ArkUI 报的每行真实矩形生成遮罩色块（逐行贴合文字，含标点压缩/避头尾的真值）。
   * @returns true = 已用测量值覆盖了遮罩
   */
  private applyMeasuredHighlight(r: PageRange, seg: TtsSegmentPos): boolean {
    const mp = this.measuredParas;
    if (this.measuredKey.length === 0 || mp.length === 0) {
      return false;
    }
    const i = seg.nodeIndex - r.startNode;
    if (i < 0 || i >= mp.length) {
      return false;
    }
    const lines = mp[i];
    if (lines.length === 0) {
      return false;
    }
    // 该段之前所有段落的累计高度（px）
    let before = 0;
    for (let k = 0; k < i; k++) {
      const ls = mp[k];
      if (ls.length > 0) {
        const lastLine = ls[ls.length - 1];
        before += lastLine.top + lastLine.height;
      }
    }
    const disp = display.getDefaultDisplaySync();
    const densityPx = disp.densityPixels > 0 ? disp.densityPixels : 1;
    const vw = this.readerSetting.viewPortWidth > 0 ? this.readerSetting.viewPortWidth : this.windowWidth;
    const textW = Math.max(1, vw * this.calibWidthRatio);
    // 文本区左边界（px）—— 必须加上它！之前漏了 ⇒ 色块整体左移，"左侧顶格"
    const leftPx = Math.max(0, (vw - textW) / 2);
    const vh = this.readerSetting.viewPortHeight > 0 ? this.readerSetting.viewPortHeight : this.windowHeight;
    const bands: Band[] = [];
    for (let j = 0; j < lines.length; j++) {
      const ln = lines[j];
      const yPx = this.calibTopPx + before + ln.top;
      if (yPx + ln.height > vh) {
        break; // 超出页面底部不再画
      }
      const b: Band = {
        x: (leftPx + ln.left) / densityPx,
        y: yPx / densityPx,
        w: ln.width / densityPx,
        h: ln.height / densityPx
      };
      bands.push(b);
    }
    if (bands.length === 0) {
      return false;
    }
    this.hlBands = bands;
    hilog.info(0x0000, 'testTag',
      'hl(measured): node=%{public}d lines=%{public}d first=(%{public}s,%{public}s) h=%{public}s',
      seg.nodeIndex, bands.length, bands[0].x.toFixed(1), bands[0].y.toFixed(1), bands[0].h.toFixed(1));
    return true;
  }

  private updateCalibRuler(): void {
    if (!this.devMode) {
      this.calibLines = [];
      this.calibMarks = [];
      this.calibCounts = '';
      this.calibLabel = '';
      return;
    }
    const g = this.geom();
    const densityPx = g[0];
    const scale = g[1];
    const fontPx = g[2];
    const lh = g[3];
    const vw = this.readerSetting.viewPortWidth > 0 ? this.readerSetting.viewPortWidth : this.windowWidth;
    const vh = this.readerSetting.viewPortHeight > 0 ? this.readerSetting.viewPortHeight : this.windowHeight;
    const textW = Math.max(1, vw * this.calibWidthRatio);
    const cpl = this.cplFor(textW, fontPx);
    const leftPx = Math.max(0, (vw - textW) / 2);
    const topPx = this.calibTopPx;
    const usable = Math.max(lh, vh - HL_BOTTOM_RESERVED_PX - topPx);
    const capacity = Math.max(1, Math.floor(usable / lh));
    const count = Math.min(64, capacity);
    const lines: number[] = [];
    for (let i = 0; i <= count; i++) {
      lines.push((topPx + i * lh) / densityPx);
    }
    this.calibLines = lines;
    this.calibLeft = leftPx / densityPx;
    this.calibWidth = textW / densityPx;
    // 本页每个段落"算出"的起始行 y —— 用来对照"标号该落在哪一段的第一行"
    const r = this.pageRange;
    const nodes = TtsEngine.currentNodeTexts();
    const marks: number[] = [];
    let base = 0;
    let counts = '';
    if (r !== null && nodes !== null && r.endNode >= r.startNode) {
      const pairs = this.simulatePage(nodes, r, cpl);
      const n = Math.floor((pairs.length - 1) / 2);
      for (let i = 0; i < n; i++) {
        marks.push((topPx + pairs[i * 2] * lh) / densityPx);
        counts += `${r.startNode + i}:${pairs[i * 2 + 1] - pairs[i * 2] + 1} `;
      }
      base = r.startNode;
      hilog.info(0x0000, 'testTag', 'calib page lines=%{public}d counts=%{public}s',
        pairs[pairs.length - 1], counts);
    }
    this.calibMarks = marks;
    this.calibMarkBase = base;
    this.calibCounts = counts;
    this.calibLabel = `字号 ${this.readerSetting.fontSize}  行距 ${this.readerSetting.lineHeight.toFixed(1)}`
      + `  dens ${densityPx.toFixed(2)}  scale ${scale.toFixed(2)}\n`
      + `font ${fontPx.toFixed(1)}px  line ${lh.toFixed(1)}px  每行 ${cpl} 字`
      + `  实测每页 ${this.learnedCapacity > 0 ? this.learnedCapacity : '—'} 行\n`
      + `左 ${leftPx.toFixed(0)}  宽 ${textW.toFixed(0)}  顶 ${topPx.toFixed(0)}`
      + `  行高系数 ${this.effectiveLineMul().toFixed(3)}`
      + (this.autoLineMul > 0 ? '(自动)' : '(手调)') + `  宽比 ${this.calibWidthRatio.toFixed(3)}`;
  }

  /** 生效的行高系数：优先用自动校准值 */
  private effectiveLineMul(): number {
    return this.autoLineMul > 0 ? this.autoLineMul : this.calibLineMul;
  }

  /** 测量/几何的失效键：页区间 + 排版参数，任一变化都要重新测量 */
  private measureKeyFor(r: PageRange): string {
    return `${r.spine}:${r.startNode}:${r.startChar}:${r.endNode}:${r.endChar}`
      + `:${this.readerSetting.fontSize}:${this.readerSetting.lineHeight.toFixed(1)}`
      + `:${this.effectiveLineMul().toFixed(3)}:${this.calibWidthRatio.toFixed(3)}`;
  }

  /** 由"实测每页行数"反推行高系数：行高 = 页高 / 每页行数 */
  private recomputeAutoPitch(): void {
    if (this.learnedCapacity <= 0) {
      return;
    }
    const g = this.geomSelfContained();
    const vh = this.readerSetting.viewPortHeight > 0 ? this.readerSetting.viewPortHeight : this.windowHeight;
    const targetPitch = (vh - this.calibTopPx) / this.learnedCapacity;
    const derived = targetPitch / Math.max(1, this.readerSetting.lineHeight * g);
    // ⚠️ 护栏（2026-09-20 实测）：阅读器可用页高会被系统/避让区改变（实测从 2848px 掉到 2150px），
    // 此时"页高÷行数"会把系数压到 0.79 一类的不合理值 → 行距被压塌、整页只占一半、底部大片空白。
    // 因此只在**合理区间**内采纳自动校准，超出则回退到手调值/默认值。
    if (derived >= HL_LINE_MUL_MIN && derived <= HL_LINE_MUL_MAX) {
      this.autoLineMul = derived;
      hilog.info(0x0000, 'testTag',
        'autocalib: capacity=%{public}d pitch=%{public}spx lineMul=%{public}s (采纳)',
        this.learnedCapacity, targetPitch.toFixed(1), derived.toFixed(3));
    } else {
      this.autoLineMul = 0;
      hilog.info(0x0000, 'testTag',
        'autocalib: capacity=%{public}d pitch=%{public}spx lineMul=%{public}s 超出合理区间[%{public}s,%{public}s] → 弃用，回退 %{public}s',
        this.learnedCapacity, targetPitch.toFixed(1), derived.toFixed(3),
        HL_LINE_MUL_MIN.toFixed(2), HL_LINE_MUL_MAX.toFixed(2), this.calibLineMul.toFixed(3));
    }
  }

  /** 字号px（不含行高系数），供 recomputeAutoPitch 使用 */
  private geomSelfContained(): number {
    const scale = this.readerSetting.scaledDensity > 0 ? this.readerSetting.scaledDensity : 1;
    return Math.max(1, this.readerSetting.fontSize) * scale;
  }

  /**
   * 确保当前页已有测量数据；没有就发起一次测量。
   * 之前只在 pageShow 里发起 ⇒ "打开书后直接按播放、没翻页"时永远不测量，
   * 色块回落到模型单块（行高偏大 19% ⇒ 第二段起覆盖到下一段）。
   */
  private ensureMeasured(r: PageRange): void {
    const key = this.measureKeyFor(r);
    if (this.measuredParas.length > 0 && this.measuredKey === key) {
      return;
    }
    if (this.measurePending === key) {
      return;
    }
    this.measurePending = key;
    this.refreshMeasure(r);
  }

  /** [densityPx, scale, fontPx, linePx] —— 高亮与标尺共用的几何基准 */
  private geom(): number[] {
    const disp = display.getDefaultDisplaySync();
    const densityPx = disp.densityPixels > 0 ? disp.densityPixels : 1;
    const scale = this.readerSetting.scaledDensity > 0 ? this.readerSetting.scaledDensity : 1;
    const fontPx = Math.max(1, this.readerSetting.fontSize) * scale;
    const lh = Math.max(1, this.readerSetting.lineHeight) * fontPx * this.effectiveLineMul();
    return [densityPx, scale, fontPx, lh];
  }

  /** 每行字数：按"中文实际字宽 = 字号px × HL_ADVANCE_RATIO"折算 */
  private cplFor(textWPx: number, fontPx: number): number {
    return Math.max(4, Math.floor(textWPx / Math.max(1, fontPx * HL_ADVANCE_RATIO)));
  }

  // ---------- 标定值持久化 + 微调 ----------
  private loadCalib(): void {
    try {
      const raw = PreferencesUtil.getSync(HL_CALIB_KEY, '') as Object;
      if (typeof raw !== 'string' || (raw as string).length === 0) {
        return;
      }
      const o = JSON.parse(raw as string) as Record<string, Object>;
      const t = o['topPx'];
      const w = o['widthRatio'];
      const m = o['lineMul'];
      const c = o['cap'];
      if (typeof t === 'number' && Number.isFinite(t as number)) {
        this.calibTopPx = t as number;
      }
      if (typeof w === 'number' && Number.isFinite(w as number)) {
        this.calibWidthRatio = w as number;
      }
      if (typeof m === 'number' && Number.isFinite(m as number)) {
        this.calibLineMul = m as number;
      }
      if (typeof c === 'number' && Number.isFinite(c as number) && (c as number) > 0) {
        this.learnedCapacity = Math.round(c as number); // 上次实测的每页行数
      }
      const d = o['dev'];
      if (typeof d === 'number') {
        this.devMode = (d as number) > 0;
      }
      this.recomputeAutoPitch();
      hilog.info(0x0000, 'testTag', 'calib loaded: topPx=%{public}s widthRatio=%{public}s lineMul=%{public}s',
        this.calibTopPx.toFixed(0), this.calibWidthRatio.toFixed(3), this.calibLineMul.toFixed(3));
    } catch (e) {
      // 用默认值
    }
  }

  private saveCalib(): void {
    const t = Math.round(this.calibTopPx);
    const w = Math.round(this.calibWidthRatio * 1000) / 1000;
    const m = Math.round(this.calibLineMul * 1000) / 1000;
    const json = `{"topPx":${t},"widthRatio":${w},"lineMul":${m},"cap":${this.learnedCapacity},`
      + `"dev":${this.devMode ? 1 : 0}}`;
    PreferencesUtil.putSync(HL_CALIB_KEY, json);
    hilog.info(0x0000, 'testTag', 'calib saved: %{public}s', json);
    this.updateHighlight();
  }

  /** 微调：top=首行锚点(px) / w=文本宽比例 / line=行高系数 */
  private nudge(what: string, delta: number): void {
    if (what === 'top') {
      this.calibTopPx = Math.max(0, Math.round(this.calibTopPx + delta));
    } else if (what === 'w') {
      this.calibWidthRatio = Math.min(1, Math.max(0.5,
        Math.round((this.calibWidthRatio + delta) * 1000) / 1000));
    } else {
      this.calibLineMul = Math.min(1.5, Math.max(0.7,
        Math.round((this.calibLineMul + delta) * 1000) / 1000));
    }
    this.saveCalib(); // 立即持久化并重算
  }

  private resetCalib(): void {
    this.calibTopPx = HL_DEF_TOP_PX;
    this.calibWidthRatio = HL_DEF_WIDTH_RATIO;
    this.calibLineMul = HL_DEF_LINE_MUL;
    this.saveCalib();
  }

  private updateHighlight(): void {
    // 重入保护：updateHighlight ←→ requestLocate/finishLocate 之间有同步回调，
    // 一旦形成环就会爆栈（真机日志：RangeError: Stack overflow! → PROCESS_KILL）。
    if (this.inHighlight) {
      return;
    }
    this.inHighlight = true;
    try {
      this.updateHighlightInner();
    } finally {
      this.inHighlight = false;
    }
  }

  private updateHighlightInner(): void {
    this.updateCalibRuler();
    // 沉浸 → 普通 的切换：把阅读器同步到当前朗读位置。
    // ⚠️ 必须**先**更新 wasImmersive 再触发 requestLocate，否则 requestLocate 里的同步
    //    回调会再次进入这里、判定条件依旧成立 ⇒ 无限递归。
    const nowImm = this.immersiveActive();
    const justLeftImmersive = this.wasImmersive && !nowImm;
    this.wasImmersive = nowImm;
    if (justLeftImmersive && this.lastAudioPos !== null) {
      const p = this.lastAudioPos;
      hilog.info(0x0000, 'testTag', 'immersive off: sync reader to spine=%{public}d node=%{public}d',
        p.spineIndex, p.nodeIndex);
      this.requestLocate(p.spineIndex, p.nodeIndex, p.charStart, true);
    }
    const r = this.pageRange;
    if (r === null || this.ttsState === 'stopped') {
      this.clearHighlight();
      return;
    }
    const seg = TtsEngine.currentSegment();
    const nodes = TtsEngine.currentNodeTexts();
    if (seg === null || nodes === null || seg.spineIndex !== r.spine
      || !this.rangeCovers(r, seg.nodeIndex, seg.charStart)) {
      this.clearHighlight();
      return;
    }
    // 首选：用 ArkUI 报的每行真实矩形（含标点压缩/避头尾），逐行贴合
    if (this.applyMeasuredHighlight(r, seg)) {
      this.hlTop = -1;
      this.hlHeight = 0;
      return;
    }
    // 还没有测量数据（例如"打开书直接按播放、从未翻页"）⇒ 主动发起测量
    this.ensureMeasured(r);
    this.hlBands = [];
    const g = this.geom();
    const densityPx = g[0];
    const scale = g[1];
    const fontPx = g[2];
    const lh = g[3];
    const vw = this.readerSetting.viewPortWidth > 0 ? this.readerSetting.viewPortWidth : this.windowWidth;
    const textW = Math.max(1, vw * this.calibWidthRatio);
    const cpl = this.cplFor(textW, fontPx);
    const pairs = this.simulatePage(nodes, r, cpl);
    const idx = seg.nodeIndex - r.startNode;
    if (idx < 0 || idx * 2 + 1 >= pairs.length) {
      this.clearHighlight();
      return;
    }
    const top = pairs[idx * 2];
    let bottom = pairs[idx * 2 + 1];
    if (top < 0 || bottom < top) {
      this.clearHighlight();
      return;
    }
    // 每页最多能放几行（由文本区高 / 行高决定）——超出即裁到页内，避免"遮罩溢出页面"
    const vh0 = this.readerSetting.viewPortHeight > 0 ? this.readerSetting.viewPortHeight : this.windowHeight;
    const capacity = Math.max(1,
      Math.floor((vh0 - this.calibTopPx - HL_BOTTOM_RESERVED_PX) / Math.max(1, lh)));
    if (top >= capacity) {
      this.clearHighlight();
      return;
    }
    if (bottom >= capacity) {
      bottom = capacity - 1;
    }
    const yPx = this.calibTopPx + top * lh;
    let hPx = (bottom - top + 1) * lh;
    const vh = vh0;
    const maxY = vh - HL_BOTTOM_RESERVED_PX;
    if (yPx + hPx > maxY && maxY > yPx) {
      hPx = maxY - yPx;
    }
    // px → vp：ArkUI 的 position / width / height 数字单位是 vp
    this.hlLeft = Math.max(0, (vw - textW) / 2) / densityPx;
    this.hlWidth = textW / densityPx;
    this.hlTop = yPx / densityPx;
    this.hlHeight = Math.max(lh, hPx) / densityPx;
    hilog.info(0x0000, 'testTag',
      'hl: node=%{public}d char=%{public}d line=%{public}d..%{public}d cpl=%{public}d '
        + 'font=%{public}s lh=%{public}s topPx=%{public}s dens=%{public}s scale=%{public}s '
        + 'lineMul=%{public}s wRatio=%{public}s topVp=%{public}s hVp=%{public}s',
      seg.nodeIndex, seg.charStart, top, bottom, cpl,
      fontPx.toFixed(1), lh.toFixed(1), this.calibTopPx.toFixed(0),
      densityPx.toFixed(2), scale.toFixed(2),
      this.calibLineMul.toFixed(3), this.calibWidthRatio.toFixed(3),
      this.hlTop.toFixed(1), this.hlHeight.toFixed(1));
  }

  /**
   * 逐字模拟本页排版（块级节点强制换行 + 段首 text-indent）。
   * @returns 扁平数组：i*2 = 第 (startNode+i) 个节点的起始行，i*2+1 = 结束行；
   *          最后一项 = 本页总行数。
   */
  private simulatePage(nodes: string[], r: PageRange, cpl: number): number[] {
    const pairs: number[] = [];
    let line = 0;
    let col = 0;
    for (let n = r.startNode; n <= r.endNode && n < nodes.length; n++) {
      const text = nodes[n];
      const from = n === r.startNode ? r.startChar : 0;
      const to = n === r.endNode ? Math.min(r.endChar, text.length - 1) : text.length - 1;
      if (from === 0 && col === 0) {
        col = HL_INDENT_SLOTS; // ReaderKit 给块级元素加的段首缩进
      }
      const startLine = line;
      let endLine = line;
      for (let i = from; i <= to; i++) {
        endLine = line;
        col++;
        if (col >= cpl) {
          col = 0;
          line++;
        }
      }
      pairs.push(startLine, endLine);
      if (col !== 0) {
        col = 0; // 块节点结束：强制换行
        line++;
      }
    }
    pairs.push(line);
    return pairs;
  }

  private clearHighlight(): void {
    if (this.hlTop !== -1) {
      this.hlTop = -1;
    }
    if (this.hlHeight !== 0) {
      this.hlHeight = 0;
    }
    if (this.hlBands.length !== 0) {
      this.hlBands = [];
    }
  }

  // 2026-09-24 记录：这里**一度**放过一套自绘的"一镜到底返回"逻辑（配合封面层与
  // 共享元素转场）。两次真机尝试均不成立 ⇒ **已全部撤除**，返回仍是原来那一句
  // `AppRouter.pop()`。想做的效果与两次失败的取证另见
  // `docs/shelf-to-reader-longtake-spec.md`（供后续重做）。

  build() {
    Stack() {
      // 不可见测量通道：一段一个 Text，交给 ArkUI 真实排版，只用于读断行结果（getLayoutManager）。
      // ⚠️ 必须放在 ReadPageComponent **之前**（z 序之下）：HitTestMode.None 只让容器自身退出命中
      // 测试，它的**子节点仍会参与**——之前放在上面，这些隐藏 Text 把左右点击/滑动都吃掉了，
      // 导致"左右点/滑翻页失效"（日志里表现为命中链路只到 Stack、到不了 XComponent）。
      if (this.measureParas.length > 0) {
        Column() {
          ForEach(this.measureParas, (p: string, i: number) => {
            Text(p, { controller: this.measureCtrls[i] })
              .fontSize(this.readerSetting.fontSize)
              // 字体管理（2026-09-26）：测量通道必须与引擎渲染同字体，否则换字体后
              // 高亮/沉浸层的行高测量错位。导入字体由 migrateReaderSetting 里的
              // ensureRegistered 注册到 ArkUI（@ohos.font）。
              .fontFamily(this.readerSetting.fontName)
              .fontWeight(this.readerSetting.fontWeight)
              .lineHeight(this.readerSetting.lineHeight * this.readerSetting.fontSize * this.effectiveLineMul())
              .textIndent(this.measureIndents.length > i ? this.measureIndents[i] : 0)
              .width('100%')
              .fontColor(Color.Transparent)
              .hitTestBehavior(HitTestMode.None)
          }, (p: string, i: number) => `mp-${this.measureSeq}-${i}`)
        }
        .width(this.textAreaWidthVp())
        .position({ x: this.calibLeft, y: 0 })
        .opacity(0)
        .hitTestBehavior(HitTestMode.None)
      }

      ReadPageComponent({
        controller: this.readerComponentController,
        readerCallback: (err: BusinessError, data: readerCore.ReaderComponentController) => {
          this.readerComponentController = data;
        }
      }).width('100%').height('100%')

      // 朗读段落高亮：首选"逐行真实矩形"（由 ArkUI getLayoutMetrics 测得）
      if (this.hlBands.length > 0) {
        ForEach(this.hlBands, (b: Band, i: number) => {
          Column()
            .width(b.w)
            .height(b.h)
            .backgroundColor('rgba(0, 125, 255, 0.16)')
            .border({ width: { bottom: 2 }, color: 'rgba(0, 125, 255, 0.8)' })
            .borderRadius(3)
            .position({ x: b.x, y: b.y })
            .hitTestBehavior(HitTestMode.None)
        }, (b: Band, i: number) => `hb-${i}-${b.y.toFixed(1)}`)
      } else if (this.hlTop >= 0 && this.hlHeight > 0) {
        // 回落：没有测量数据时用模型单块
        Column()
          .width(this.hlWidth)
          .height(this.hlHeight)
          .backgroundColor('rgba(0, 125, 255, 0.16)')
          .border({ width: { bottom: 2 }, color: 'rgba(0, 125, 255, 0.8)' })
          .borderRadius(4)
          .position({ x: this.hlLeft, y: this.hlTop })
          .hitTestBehavior(HitTestMode.None)
      }

      // 沉浸听读层（可选）：自绘本页 + 句内高亮画在文字内部；整层穿透触摸
      if (this.immersiveActive()) {
        this.ImmersiveListenLayer()
      }

      // 几何标定标尺（HL_CALIB_MODE）：红线=我们认为的每个行位，绿线=我们认为的文本左右边界。
      // 与真实文字对照即可反解 top / 左右留白 / 行高；左上角文字是本次全部输入参数。
      if (this.devMode && this.calibLines.length > 0) {
        Column().width(1).height('100%').backgroundColor('rgba(0,200,0,0.9)')
          .position({ x: this.calibLeft, y: 0 }).hitTestBehavior(HitTestMode.None)
        Column().width(1).height('100%').backgroundColor('rgba(0,200,0,0.9)')
          .position({ x: this.calibLeft + this.calibWidth, y: 0 }).hitTestBehavior(HitTestMode.None)
        ForEach(this.calibLines, (y: number, idx: number) => {
          Column()
            .width(this.calibWidth)
            .height(1)
            .backgroundColor(idx % 5 === 0 ? 'rgba(255,0,0,0.95)' : 'rgba(255,0,0,0.45)')
            .position({ x: this.calibLeft, y: y })
            .hitTestBehavior(HitTestMode.None)
        }, (y: number, idx: number) => `calib-${idx}-${y}`)
        // 段落标号：每个标号画在"我们算出的该段第一行"位置，标号数字 = 真实节点号。
        // 对齐正确时，标号应压在对应段落首行的左侧。
        ForEach(this.calibMarks, (y: number, idx: number) => {
          Text(`${this.calibMarkBase + idx}`)
            .fontSize(11)
            .fontColor('rgba(200,0,200,1)')
            .backgroundColor('rgba(255,255,255,0.7)')
            .position({ x: Math.max(0, this.calibLeft - 26), y: y - 14 })
            .hitTestBehavior(HitTestMode.None)
        }, (y: number, idx: number) => `mark-${idx}-${y}`)
        Text(this.calibLabel)
          .fontSize(9)
          .fontColor('rgba(255,0,0,1)')
          .backgroundColor('rgba(255,255,255,0.75)')
          .padding(2)
          .position({ x: 2, y: 2 })
          .hitTestBehavior(HitTestMode.None)
      }

      // ── 阅读器信息窗（2026-10-07 用户设计）：仅全屏（菜单栏隐藏）且开关开启时显示 ──
      // 右上角：定时实时信息（时间型=秒级倒计时 / 章节型=剩余X章，可并存）+ 防窥眼睛。
      // 用户拍板：①非全屏不显示（顶栏已有三个图标）；②不可点击（"像和文字一样被渲染
      //   的内容"）⇒ 整层与全部子节点逐个 HitTestMode.None（工程已知坑：None 只穿透
      //   自身，子节点照样吃触摸）。字色随正文（readerSetting.fontColor 与正文同源）。
      // 位置与顶栏图标同一视觉基线（topRectHeight+12，右 20）。
      if (!this.isShowSetting && this.infoWinOn) {
        Row({ space: 8 }) {
          if (this.infoTimerText.length > 0) {
            Text(this.infoTimerText)
              .fontSize(13)
              .fontColor(this.readerSetting.fontColor)
              .opacity(0.9)
              .hitTestBehavior(HitTestMode.None)
          }
          SymbolGlyph(this.antiPeepIcon())
            .fontSize(16)
            .fontColor([this.readerSetting.fontColor])
            .opacity(0.9)
            .hitTestBehavior(HitTestMode.None)
        }
        .justifyContent(FlexAlign.End)
        // ⚠️ 必须显式撑满高度 + 顶部对齐：Stack 子元素默认垂直居中（2026-10-07 真机实测：
        //   信息窗曾跑到屏幕右侧正中），撑满后内容钉在顶部。
        .alignItems(VerticalAlign.Top)
        .width('100%')
        .height('100%')
        .padding({ top: this.topRectHeight + 12, right: 20 })
        .hitTestBehavior(HitTestMode.None)
      }

      // 朗读迷你条：面板关闭时仍可见/可控（点文本回面板，点按钮暂停/续播）
      if (this.ttsState !== 'stopped') {
        this.TtsMiniBar()
      }

      Column() {
        if (this.isShowSetting) { // 阅读器-上方弹框
          Column() {
            Row({ space: 8 }) {
              Image($r("app.media.ic_public_return_left"))
                .fillColor(this.colorMode == 0 ? 'rgba(248, 249, 250, 1)' : 'rgba(19, 19, 19, 1.00)')
                .width(24)
                .onClick(() => {
                  Haptics.tap();
                  // 入栈/出栈必须成对：本页现在由 NavPathStack 推入（见 Index.appRoutes）
                  AppRouter.pop()                })

              Text(`${this.CatalogList.getData(this.bookData.durChapterIndex ?? 0)?.catalogName ?? ''}`
                .replace(new RegExp('\\s{1,}', 'g'), ' ')
                .replaceAll('=', ''))
                .layoutWeight(1).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                .fontColor(this.colorMode == 0 ? 'rgba(248, 249, 250, 1)' : 'rgba(19, 19, 19, 1.00)')

              // ── 防窥入口（2026-10-07 用户设计）：顶栏依次 防窥/书签 ──────────────
              // 睁眼 = 未开启，闭眼 = 已开启；点击切换两层防护（窗口隐私 + DLP 窥视蒙层，
              // 方案见 utils/AntiPeep.ets）。规格与书签完全同款：SymbolGlyph 22、
              // ReplaceSymbolEffect 形变动效、runJellyClick Q弹缩放。
              // ⚠️ 定时入口已迁入听书面板顶栏（2026-10-07 用户设计：与听书功能同源，
              //   面板=父窗、定时弹窗=子窗），顶栏不再保留闹钟图标。
              SymbolGlyph(this.antiPeepIcon())
                .fontSize(22)
                .fontColor([this.colorMode == 0 ? 'rgba(248, 249, 250, 1)' : 'rgba(19, 19, 19, 1.00)'])
                .symbolEffect(new ReplaceSymbolEffect(), this.antiPeepOn ? 1 : 0)
                .scale({ x: this.antiPeepScale, y: this.antiPeepScale })
                .margin({ right: 12 })
                .onClick(() => {
                  Haptics.tap();
                  runJellyClick((v: number) => {
                    this.antiPeepScale = v
                  })
                  this.toggleAntiPeep();
                })

              // ── 书签入口（2026-09-21）──────────────────────────────────────
              // 位置按用户要求：顶部栏**最右侧**（章节名之后）。搜索图标后续加在它左侧。
              // 实心 = 当前页已有书签；点击切换（有则删、无则存）。
              // 存的 `bookText` = **当前页首行前 10 个字符**，取自
              //   `TtsEngine.currentNodeTexts()[pageRange.startNode]`（页首节点文本）。
              SymbolGlyph(this.bookmarkIcon())
                .fontSize(22)
                .fontColor([this.colorMode == 0 ? 'rgba(248, 249, 250, 1)' : 'rgba(19, 19, 19, 1.00)'])
                // 符号形变动效（2026-09-21）。SDK 原文（`…\ets\component\symbolglyph.d.ts`）：
                //   `symbolEffect(symbolEffect: SymbolEffect, triggerValue?: number)`（`:777`，`@since 12`）
                //   `@param { number } [triggerValue] - Value that, when changed, initiates the
                //    animation of the SymbolGlyph component.`
                //   `ReplaceEffectType.SEQUENTIAL` 原文：「The current symbol disappears before a
                //    new symbol appears. This is the default symbol replacement effect type.」
                // ⚠️ 为什么不用 `isActive`：官方对 isActive 的说明是「**true**: playing.
                //    **false**: not playing. Default value: **false**」——不传就永远不播。
                //    所以这里走 triggerValue 重载，并直接绑一个**由状态派生**的数字：
                //    收藏状态一变这个数就变，动效自然触发，且不需要额外状态。
                .symbolEffect(new ReplaceSymbolEffect(), this.isBookmarked ? 1 : 0)
                .scale({ x: this.bookmarkScale, y: this.bookmarkScale })
                .onClick(() => {
                  Haptics.tap();
                  runJellyClick((v: number) => {
                    this.bookmarkScale = v
                  })
                  this.toggleBookmark();
                })

              // 顶栏「刷新 / 下载 / 更多」三个按钮已于 2026-09-21 删除。
              // 原因（三重）：① 整块本来就是 `/* */` 注释掉的**死代码**；
              //   ② 即使去掉注释，`refresh` 与 `more` 的 `onClick` 也是**空函数体**；
              //   ③ 它们下游的 `DownloadDialog()` / `DownloadSettingDialog` 是**假下载**
              //      （Checkbox 无绑定、「取消」无 onClick、「确定」只弹 1 秒 toast），
              //      且全工程 grep `downloadFile|DownloadTask|@ohos.request.download` 零命中。
            }
            .padding({
              top: 12,
              left: 20,
              right: 20,
              bottom: 12
            })
            .width("100%")

            // `NetworkInput()` 输入框已于 2026-09-21 删除（原本就是整块注释掉的死代码）。

            // ★ 原这里有一条 `Divider()`（2026-09-22 用户反馈「顶栏的**底边有个黑条**」）。
            //   顶栏改成**有边界的悬浮胶囊**之后，这条默认色实心分隔线就多余了 ——
            //   胶囊自己的圆角边界已经足够表达分隔，这条线反而成了"黑条"。
            //   （与底栏同样的处理：底栏那条 Divider 也已移除，见下方注释。）
          }
          .padding({ top: this.topRectHeight == 0 ? 40 : 0 })
          // 顶栏改「悬浮胶囊」（2026-09-22 用户选 A）。
          //   · 宽度 80% + 四圆角 16 ⇒ 居中悬浮，两侧露出阅读内容
          //   · clip(true) 必须，否则子内容溢出圆角
          //
          // ⚠️ 2026-09-22 修正：上一版我把这里写成
          //   `.attributeModifier(new MaterialColumnModifier(Color.Transparent, true))`
          //   ⇒ 顶栏变成**完全透明**，用户反馈「太透明了，完全不对」。
          //   原因：该修饰器在材质分支里**什么都不做**（它设计给"弹窗内容层"，
          //   指望调用方的 `CustomDialogControllerOptions.systemMaterial` 提供材质）。
          //   阅读页顶栏**不是弹窗**，没有那一层 ⇒ 结果纯透明。
          //
          // ⚠️ 更根本：官方「开启沉浸光感」原文
          //   「沉浸光感开启后，除了弹窗类组件或方法、Slider、Toggle，其他组件
          //    **仅在以下区域中生效**：Navigation/NavDestination **标题栏**，
          //    或横向 Tabs 中 barPosition 为 BarPosition.End 的底部 TabBar 中。」
          //   ⇒ 阅读页这条件自绘顶栏**不在生效范围**（真机日志会打
          //     `Material inactive: out of scope. Use component in navigation title bar or Tabbar.`）
          //   ⇒ 这里**拿不到**真材质，只能用**半透明底色**模拟悬浮胶囊观感：
          //     既有明确边界、又能透出下方正文。
          .width('90%')
          .borderRadius(16)
          .clip(true)
          .backgroundColor(this.colorMode == 0
            ? 'rgba(31, 31, 31, 0.86)'
            : 'rgba(250, 250, 250, 0.90)')
          .margin({ top: this.topRectHeight == 0 ? 24 : 8 })
          // ── 菜单栏出入场：弹簧曲线（2026-09-23 用户拍板「弹簧为主」）──────────────
          // 原来是写死的 `{ duration: 500 }`；现在统一从 `UiMotion` 取（一处改全局生效）：
          //   `TransitionEffect.move` = **位移（transform）**，符合官方《动画帧率优化》原文
          //   「使用**图形变换属性**变化组件，而**不是直接修改布局属性**…降低丢帧率」。
          // 回退：`UiMotion.MOTION_ENABLED = false` ⇒ 参数变 `{ duration: 0 }`（无动画）。
          .transition(TransitionEffect.move(TransitionEdge.TOP).animation(UiMotion.transitionParam()))

          Blank(1).onClick(() => {
            Haptics.tap();
            this.isShowSetting = false
            // ★ 2026-09-23 用户反馈修复：「设置页点开之后，点击阅读器主屏幕，消失，再点主屏幕
            //   **还是设置页**，这个逻辑不对」。原因：关闭菜单时只置了 `isShowSetting`，
            //   设置面板的展开态 `isShowContentSetting` 一直留着 ⇒ 再打开菜单时它还是展开的。
            //   ⇒ 关菜单的同时把设置面板也收起（要看得重新点「设置」）。
            // ⚠️ 2026-09-23 二次修改：设置面板现在是 `@CustomDialog`（`settingDialog`）
            //   ⇒ 光置 false 不够，**必须同时 close()**，否则菜单关了弹窗还浮在上面。
            if (this.isShowContentSetting) {
              this.isShowContentSetting = false
              this.settingDialog?.close()
            }
          })

          // 阅读器-下方弹框
          Column({ space: 20 }) {
            // 原来这里有一条 `Divider()` 横贯整条底栏。2026-09-21 底栏改成**悬浮胶囊**后，
            // 这条默认色的实心分隔线显得很突兀 —— 真机截图反馈「听书点开后有个黑色线条」
            // （面板打开时底栏露出来，这条线就特别明显）。
            // 胶囊自己的圆角边界已经足够表达分隔，故移除。

            // 底栏「换源 / 净化」两个按钮已于 2026-09-21 删除。它们整块是 `/* */` 注释掉的
            // **死代码**，而 `sourceView()` / `purificationView()` 两个 builder 的**唯一调用点**
            // 就在这段注释里（删掉后它们也不可达，已一并移除）。
            // 顺带说明为什么不该恢复「换源」：`sourceView.ets` 里「共搜索到24个书源」与
            // 6 张卡片的书名/评分/最新章节全是写死的；「净化」连数据层都不存在
            // （全工程无净化规则表/DAO）。

            Row({ space: 16 }) {
              Text("上一章")
                .fontColor(this.colorMode == 0 ? 'rgba(248, 249, 250, 1)' : 'rgba(19, 19, 19, 1.00)')
                .onClick(() => {
                  Haptics.tap();
                  if (this.bookData.durChapterIndex > 0) {
                    this.bookData.durChapterIndex--
                    this.jumpToCatalogItem(this.CatalogList.getData(this.bookData.durChapterIndex))
                  }
                })

              Slider({
                value: this.bookData.durChapterIndex,
                // ⚠️ max 最低钳到 0：目录未加载完成时 totalCount()=0 ⇒ max=-1 且 min=0，
                //   非法配置会让 onChange 吐出越界值写进 durChapterIndex —— 单章节书
                //   （catalog list length: 1）拖进度条崩溃（jscrash 2026-09-26 16:11，
                //   "Cannot read property catalogName of undefined"）的源头就在这。
                max: Math.max(0, this.CatalogList.totalCount() - 1),
                min: 0,
                step: 1,
                style: SliderStyle.InSet
              })
                .selectedColor(this.sliderSelectedColor())
                .blockSize({ width: 30, height: 30 })
                // 沉浸光感（2026-09-23 二次定案，滑条用 `sliderMaterial()`）。
                // 官方《沉浸式系统材质视效》原文：「沉浸式系统材质支持设置**交互形变**和
                // **点光源**效果…点光源…手指触摸组件时会产生**流光跟随**效果」；
                // 「沉浸式系统材质**默认自带阴影效果（applyShadow 为 true）**，优先于 shadow 通用属性」。
                // ⇒ 原来 `controlMaterial()` 开了 `interactive:true`（弹性形变）+ 默认阴影 true
                //   = 拖动时形变 + 一团暗影（用户说的"裤子反穿"）；现在三项显式写死：
                //   `applyShadow:false` + `interactive:false` + `lightEffect:{}`（只留流光）。
                // 另注：材质的"底/框"去不掉（官方：材质**接管组件的背景、边框、阴影**）。
                .systemMaterial(ImmersiveMaterialUtil.sliderMaterial())
                // ★ 材质那层"底"是滑条自己的框画的 ⇒ 做成圆角胶囊 + 左右内缩，
                //   让它看起来就是"轨道本身"（见 sliderMaterial() 的注释）
                .borderRadius(20)
                .padding({ left: 8, right: 8 })
                .layoutWeight(1)
                .onChange((value, mode) => {
                  //结束滑动后再跳转到对应章节
                  if (mode == SliderChangeMode.End) {
                    Haptics.tick();
                    // 夹取到合法章节区间（目录未加载/单章节时 value 可能越界，见上方 max 钳制注释）
                    const total = this.CatalogList.totalCount();
                    const v = Math.max(0, Math.min(Math.round(value), total - 1));
                    if (total <= 0 || v === this.bookData.durChapterIndex) {
                      return;
                    }
                    this.bookData.durChapterIndex = v
                    const item = this.CatalogList.getData(v)
                    if (item === undefined || item === null) {
                      this.getUIContext().getPromptAction().showToast({ message: '章节信息异常，请重新进入本书' });
                      return;
                    }
                    this.jumpToCatalogItem(item)
                  }
                })

              Text("下一章")
                .fontColor(this.colorMode == 0 ? 'rgba(248, 249, 250, 1)' : 'rgba(19, 19, 19, 1.00)')
                .onClick(() => {
                  Haptics.tap();
                  if (this.bookData.durChapterIndex < this.CatalogList.totalCount() - 1) {
                    this.bookData.durChapterIndex++
                    this.jumpToCatalogItem(this.CatalogList.getData(this.bookData.durChapterIndex))
                  }
                })
            }
            .padding({
              // ⚠️ 2026-09-23 修正：原来这里是 `bottom: '10%'` —— 那是给"下面还有四图标
              //   Grid"留的间距。四图标搬去真 Tabs 之后，这个百分比内边距就把整行
              //   **顶到了胶囊最上面**（用户反馈「内容向上对齐」）⇒ 改成上下对称的固定内边距。
              left: 24, right: 24, top: 12, bottom: 12
            })
            .width("100%")

          }
          // ── 这块自绘胶囊现在**只剩「进度行」**（四图标已搬去下面的真 Tabs；
          //    「设置内容」2026-09-23 已搬进 `@CustomDialog`，见 `settingDialog`）──────────
          // ⚠️ 它**仍然拿不到真材质**：官方 FAQ 原文「位于 Navigation **内容区**中的 **Column**
          //   组件…**不生效**沉浸光感效果」（日志 `Material inactive: out of scope.`）
          //   ⇒ 只能继续用官方 FAQ `faqs-arkui-1101` 场景四的「重叠 + 毛玻璃」模拟：
          //     半透明底色 + `backgroundBlurStyle` + 圆角 + 轻投影 + 四周留白。
          //   ⇒ 拿不到真材质（做成 @CustomDialog 的话，遮罩会盖住顶栏的返回/定时/书签
          //     ⇒ 不能套目录那套）。用户 2026-09-23 选 A：**用通用属性调到最像**。
          // ★ 2026-09-23「向材质面板看齐」（用户选 A：用通用属性模拟到最像）──────────
          // 取色依据 —— 用户真机截图（1320×2848）实测像素：
          //   · 目录弹窗（**真材质**）内部空白区 = R235 ~ R241
          //   · 旧自绘胶囊（改动前）= **R198 ~ R199** ⇒ 明显偏灰偏暗，这就是"效果不统一"
          //   · 阅读页底色 ≈ R249
          // ⇒ 材质面板 ≈ 底色上盖一层**接近不透明**的浅色 + 强模糊：
          //   本次把底色 alpha 0.72 → **0.92**、模糊档 ULTRA_THIN → **ULTRA_THICK**，
          //   渲染结果从 R198 抬到 ≈R240，与材质面板同档。
          //   官方依据（FAQ「组件不在沉浸光感生效范围」）给的替代方案正是这条：
          //   「若无法满足生效范围要求，可改用 backgroundColor 等通用属性替代材质效果。」
          //   `BlurStyle` 枚举取值见 `component/common.d.ts:6614-6755`
          //   （`COMPONENT_ULTRA_THIN = 8` … `COMPONENT_ULTRA_THICK = 12`，@since 11）。
          .backgroundColor(this.colorMode == 0 ? 'rgba(28, 28, 30, 0.92)' : 'rgba(248, 249, 250, 0.92)')
          .backgroundBlurStyle(BlurStyle.COMPONENT_ULTRA_THICK)
          .borderRadius(24)
          .margin({ left: 12, right: 12, bottom: 10 })
          // 轻投影（`shadow` 是通用属性）。刻意比材质自带阴影淡很多 ——
          // 用户反馈过底部阴影太重，见 `ImmersiveMaterialUtil.tabBarMaterial()` 里的 applyShadow:false。
          .shadow({ radius: 18, color: 'rgba(0, 0, 0, 0.10)', offsetX: 0, offsetY: 4 })
          // 出入场统一走 UiMotion 弹簧令牌（原 `{ duration: 500 }`）
          .transition(TransitionEffect.move(TransitionEdge.BOTTOM).animation(UiMotion.transitionParam()))
          // ── 底部四图标：**真 Tabs**（2026-09-23 重构，用户点名要求）──────────────
          // 【为什么必须换成 Tabs】官方对沉浸光感的生效范围有硬性限定（documentId
          // `开发指南/ArkUI_方舟UI框架/…/沉浸光感/…/开启沉浸光感/arkts-immersive-light-sense-enable`）原文：
          //   「沉浸光感开启后，除了弹窗类组件或方法、Slider、Toggle，其他组件**仅在**以下区域中生效：
          //     Navigation/NavDestination 标题栏，或**横向 Tabs 中 barPosition 为 BarPosition.End
          //     的底部 TabBar** 中。」
          // 官方 FAQ 还给了反例原文：「位于 Navigation **内容区**中的 **Column** 组件…**不生效**
          // 沉浸光感效果」，真机日志为
          // `Material inactive: out of scope. Use component in navigation title bar or Tabbar.`
          // ⇒ 原来这条自绘 Column + Grid 的"悬浮胶囊"**永远拿不到真材质**（只能毛玻璃模拟）。
          //   官方唯一给"底部栏"开的口子，就是把它做成**真正的 Tabs 底部页签**。
          //
          // 【配方】与主页面底部页签逐条对齐（`pages/Index.ets:236-295`，已真机验证）：
          //   · 悬浮样式生效三条件（官方原文）：「barOverlap 为 true、vertical 为 false、
          //     barPosition 为 BarPosition.End，三个条件需同时满足，否则 systemMaterial 设置不生效。」
          //   · 「设置悬浮材质后，**不建议**再通过 barBackgroundColor、barBackgroundBlurStyle
          //      为 TabBar 设置背景色或背景模糊，避免遮挡材质效果」⇒ 本块**一个背景属性都不设**。
          //   · 「TabContent 不支持设置沉浸光感」⇒ 材质只挂在 Tabs 上，TabContent 是空壳。
          //   · 越界回弹会"扯出白区"⇒ `edgeEffect(EdgeEffect.None)`（与 Index.ets 同款修复）。
          //
          // 【4 个页签 = 4 个动作】**动作由每个图标自己的 `onClick` 派发**
          //   （见 `ReaderBarItem()`；Tabs 在这里**只**当材质背板 + 提供悬浮几何）。
          //   ⚠️ 真机实测：一次点击 `onTabBarClick` 会派发多次、且**第一个 index 恒为 0**
          //   ⇒ 曾经出现"点听书/设置都弹目录"，所以这里**故意不挂** `onTabBarClick`。
          //   内容区不可见，故禁掉左右滑动。
          //
          // 【听书入口（2026-09-27 回归常驻）】4 个页签对所有人可见：目录/听书/日夜/设置。
          //   新用户点听书 = 华为本地 TTS（`TtsEngine.activeEngineId` 双重校验：未解锁一律
          //   回落本地）；暗号解锁（我的→改名命中 我爱李杰克/我爱小妖）只影响两件事：
          //   ① 默认可切 Edge TTS；② 我的-设置里出现引擎开关。引擎口径见 TtsControlPanel.isLocal。
          //   `ReaderBarItem(action, pos)` 第一个参数是**动作 id**（0=目录 1=听书 2=日夜 3=设置），
          //   第二个是**页签位置**（驱动动效计数），
          //   ⚠️ 两套编号不能混：`dispatchBarAction` 永远收**动作 id**。
          Tabs({ barPosition: BarPosition.End }) {
            TabContent() {
              Column()
            }.tabBar(this.ReaderBarItem(0, 0))
            TabContent() {
              Column()
            }.tabBar(this.ReaderBarItem(1, 1))
            TabContent() {
              Column()
            }.tabBar(this.ReaderBarItem(2, 2))
            TabContent() {
              Column()
            }.tabBar(this.ReaderBarItem(3, 3))
          }
          // ⚠️ 这里**故意不挂 `.onTabBarClick()`** —— 动作由每个图标自己的 `onClick` 派发
          //   （见 `ReaderBarItem()`）：真机实测一次点击 `onTabBarClick` 会派发多次、
          //   且**第一个 index 恒为 0** ⇒ 点"听书/设置"弹出来的都是目录。
          .scrollable(false)
          .edgeEffect(EdgeEffect.None)
          .barHeight(READER_BAR_HEIGHT)
          // 沉浸光感三条件：barPosition = End（构造参数）✓ / barOverlap(true) ✓ / vertical 默认 false ✓
          .barOverlap(ImmersiveMaterialUtil.isOn())
          // 悬浮几何（左右 + 底部留白）由 `FloatingTabBarStyle` 给：
          //   · `barSideMargin`（util 里是 16，原自绘胶囊是 margin 12）
          //   · `barBottomMargin` = 系统底部安全区 + `READER_BAR_BOTTOM_GAP`（原自绘胶囊 margin.bottom = 10）
          .barFloatingStyle(ImmersiveMaterialUtil.tabsFloatingStyle(this.bottomRectHeight + READER_BAR_BOTTOM_GAP))
          .width('100%')
          // 容器高度 = 条高 + 底部留白 + 安全区：悬浮条被 `barBottomMargin` 顶起来，容器必须给够高度
          .height(READER_BAR_HEIGHT + READER_BAR_BOTTOM_GAP + this.bottomRectHeight)
          // 与上面那条"设置胶囊"同款入场动效（整条菜单一起从底部滑入，弹簧令牌统一）
          .transition(TransitionEffect.move(TransitionEdge.BOTTOM).animation(UiMotion.transitionParam()))
        }
      }.width("100%").height("100%").enabled(this.isShowSetting).padding({
        top: this.topRectHeight,
      })
    }.width('100%').height('100%').onClick(() => {
      Haptics.tap();
      // 点击拉起菜单栏功能
      this.isShowSetting = true
    })
  }

  /**
   * 阅读设置面板的**内容**（2026-09-23 从"底栏胶囊内换内容"搬出来的，代码逐字搬移）。
   *
   * ── 为什么搬 ──────────────────────────────────────────────────────────────
   * 用户反馈：「听书的效果不错，但是设置没有效果，点击就是正常出现」+「听书除了弹窗以外
   * 会有个全局变暗的遮罩，但是设置不会」。
   * 根因：设置原本不是"出入场"，只是同一个底栏胶囊里把**进度行换成设置行**
   * （旧代码 `if (!this.isShowContentSetting) { 进度行 } else { 设置行 }`）⇒ 只能是硬切，
   * 而且页内节点永远拿不到真材质。
   * ⇒ 现在改成 `@CustomDialog`（`settingDialog`），与目录/听书完全一致：
   *   **真材质 + 默认遮罩（0x33000000）+ 弹簧出入场**。
   *
   * ── 为什么 UI 代码不用搬状态 ───────────────────────────────────────────────
   * 本 @Builder 由 `ReaderSettingDialog` 用 `@BuilderParam` 接收（写法 `content: () => {
   * this.ReaderSettingContent() }`）。官方 FAQ（documentId
   * `FAQ/UI框架/组件使用/BuilderParam如何接收父组件的状态变量/faqs-arkui-826`）原文：
   *   「使用 @BuilderParam 装饰器接收父组件传递过来的自定义构建函数，并且在子组件中调用
   *    this.customView() 就能看到父组件的自定义内容，**状态变量改变时也能更新**。」
   * ⇒ 字号/行距/亮度的实时刷新仍由**本页**的状态驱动，不需要任何 @Link 透传。
   *
   * ⚠️ 与听书面板的关键差异：听书面板是**独立组件**，它的数据必须走 `@Link`
   *   （SDK `custom_dialog_controller.d.ts:59-60`：builder 里 `@Prop`/`@ObjectLink` 不生效）。
   *   这里 UI 挂在**本页**的 @Builder 上，不是弹窗自己的参数字段 ⇒ 不受该限制。
   */
  @Builder
  ReaderSettingContent() {
    Column({ space: 12 }) {
      Row({ space: 5 }) {
        Text('亮度')
        Slider({
          value: BrightnessUtil.getBrightness('reader'),
          max: 1,
          min: 0,
          step: 0.01,
          style: SliderStyle.InSet
        })
          .selectedColor(this.sliderSelectedColor())
          .blockSize({ width: 30, height: 30 })
        // 沉浸光感（2026-09-21）。官方原文（`…/组件适配沉浸光感/…`「滑动条（Slider）」）：
        //   「传入的材质参数**仅作为开启沉浸光感的开关标记**，不影响实际视觉效果，
        //     实际使用组件内部预设的视觉参数，主要影响滑块大小、滑块样式、阴影等；
        //     传入 undefined 时沉浸光感不生效，恢复为原先的 Slider 样式。」
        // ★ 滑条**不设材质**：本面板现在是 @CustomDialog 的真材质层，官方《沉浸光感功耗优化》
        //   原文「同一子树中只需在**最外层**设置一次沉浸式系统材质，内层节点不应再设置」
        //   ⇒ 真机实测内层滑条再设会出现黑色圆形蒙版（听书面板踩过同一个坑）。
        .borderRadius(20)
        .padding({ left: 8, right: 8 })
          .layoutWeight(1)
          .hitTestBehavior(this.isLuminanceFollowSystem ? HitTestMode.None : HitTestMode.Default)
          .onChange((value) => {
            Haptics.tick();
            if (!this.isLuminanceFollowSystem) {
              BrightnessUtil.setBrightness('reader', value)
            }
          })
        Text('随系统')
        Toggle({ type: ToggleType.Switch, isOn: $$this.isLuminanceFollowSystem })
          .onChange((value) => {
            Haptics.tap();
            this.isLuminanceFollowSystem = value
            BrightnessUtil.setBrightness('reader', value ? -1 : 0.3)
          })
        Text('常亮')
        Toggle({ type: ToggleType.Switch, isOn: $$this.isScreenState })
          .onChange((value) => {
            Haptics.tap();
            this.isScreenState = value
            BrightnessUtil.setScreenState(value)
          })
      }

      // 「字号/行距」滑条与档位 2026-09-26 迁入「字体管理」弹窗（ReaderFontDialog）。

      // 「字体管理」入口 + 「更多材质」「更多方案」按钮（2026-09-26 用户改版）：
      // 「把字体甚至原有的字号、间距都提取到一个新的弹窗中，新的入口就在标定模式这一行，
      //   替换标定模式的位置，叫做字体管理」；标定模式开关移到 我的-设置（解锁后可见，
      //   见 MySetPage），devMode 仍控制本面板的标定功能区（下方 if (this.devMode) 原样）。
      Row({ space: 16 }) {
        Button('字体管理')
          .fontSize(13)
          .fontColor(this.colorMode == 0 ? 'rgba(248, 249, 250, 1)' : 'rgba(19, 19, 19, 1.00)')
          .backgroundColor(this.colorMode == 0
            ? 'rgba(248, 249, 250, 0.16)'
            : 'rgba(19, 19, 19, 0.06)')
          .borderRadius(18)
          .height(34)
          .padding({ left: 14, right: 14 })
          .clickEffect(UiMotion.CLICK)
          .onClick(() => {
            Haptics.tap();
            this.openFontDialog()
          })

        Button('更多材质')
          .fontSize(13)
          .fontColor(this.isTexOverflowFocused() ? '#ff6600'
            : (this.colorMode == 0 ? 'rgba(248, 249, 250, 1)' : 'rgba(19, 19, 19, 1.00)'))
          .backgroundColor(this.colorMode == 0
            ? 'rgba(248, 249, 250, 0.16)'
            : 'rgba(19, 19, 19, 0.06)')
          // ── 焦点规则（2026-09-25 用户二轮反馈）：当前选中的材质不在主页前 8 个
          //    预览里 ⇒ 材质格圈不到它，橙圈改框在「更多材质」按钮上。
          .borderWidth(this.isTexOverflowFocused() ? 1.5 : 0)
          .borderColor('#ff6600')
          .borderRadius(18)
          .height(34)
          .padding({ left: 14, right: 14 })
          .clickEffect(UiMotion.CLICK)
          .onClick(() => {
            Haptics.tap();
            // 会员化（2026-09-28）：「更多材质」为 VIP 特权，免费用户 → VIP 弹窗
            if (!VipManager.isVip()) {
              this.openVipDialog()
              return
            }
            this.openTexDialog()
          })

        Button('更多方案')
          .fontSize(13)
          .fontColor(this.bgFocus === 'scheme' ? '#ff6600'
            : (this.colorMode == 0 ? 'rgba(248, 249, 250, 1)' : 'rgba(19, 19, 19, 1.00)'))
          .backgroundColor(this.colorMode == 0
            ? 'rgba(248, 249, 250, 0.16)'
            : 'rgba(19, 19, 19, 0.06)')
          // ── 焦点规则（2026-09-25 用户三轮反馈）：应用中的方案在这批已存方案里
          //    （方案全部住在弹窗里）⇒ 橙圈框在「更多方案」按钮上。
          .borderWidth(this.bgFocus === 'scheme' ? 1.5 : 0)
          .borderColor('#ff6600')
          .borderRadius(18)
          .height(34)
          .padding({ left: 14, right: 14 })
          .clickEffect(UiMotion.CLICK)
          .onClick(() => {
            Haptics.tap();
            // 会员化（2026-09-28）：「更多方案」为 VIP 特权，免费用户 → VIP 弹窗
            if (!VipManager.isVip()) {
              this.openVipDialog()
              return
            }
            this.openSchemeDialog()
          })
      }
      .width('100%')
      .justifyContent(FlexAlign.Center)
      .alignItems(VerticalAlign.Center)

      // 我们算出来的几何（标定模式）：与截图/日志逐项对照
      if (this.devMode) {
        Text(this.calibLabel.length > 0 ? this.calibLabel : '几何标定中…')
          .fontSize(11)
          .fontColor('#D24A00')
          .width('100%')
          .maxLines(3)

        // 本页逐段行数（节点号:行数）——用于直接跟屏幕上数出来的行数核对
        Text(`逐段行数 ${this.calibCounts.length > 0 ? this.calibCounts : '—'}`)
          .fontSize(11)
          .fontColor('#0A6E0A')
          .width('100%')
          .maxLines(3)

        Row({ space: 6 }) {
          Text('首行').fontSize(12).width(28)
          Text('-8').fontSize(13).padding({ left: 9, right: 9, top: 4, bottom: 4 })
            .borderRadius(10).backgroundColor('rgba(0,125,255,0.12)')
            .onClick(() => { Haptics.tap(); this.nudge('top', -8) })
          Text('+8').fontSize(13).padding({ left: 9, right: 9, top: 4, bottom: 4 })
            .borderRadius(10).backgroundColor('rgba(0,125,255,0.12)')
            .onClick(() => { Haptics.tap(); this.nudge('top', 8) })
          Text('行高').fontSize(12).width(28)
          Text('-.02').fontSize(13).padding({ left: 7, right: 7, top: 4, bottom: 4 })
            .borderRadius(10).backgroundColor('rgba(0,125,255,0.12)')
            .onClick(() => { Haptics.tap(); this.nudge('line', -0.02) })
          Text('+.02').fontSize(13).padding({ left: 7, right: 7, top: 4, bottom: 4 })
            .borderRadius(10).backgroundColor('rgba(0,125,255,0.12)')
            .onClick(() => { Haptics.tap(); this.nudge('line', 0.02) })
        }

        Row({ space: 6 }) {
          Text('宽比').fontSize(12).width(28)
          Text('-.005').fontSize(13).padding({ left: 7, right: 7, top: 4, bottom: 4 })
            .borderRadius(10).backgroundColor('rgba(0,125,255,0.12)')
            .onClick(() => { Haptics.tap(); this.nudge('w', -0.005) })
          Text('+.005').fontSize(13).padding({ left: 7, right: 7, top: 4, bottom: 4 })
            .borderRadius(10).backgroundColor('rgba(0,125,255,0.12)')
            .onClick(() => { Haptics.tap(); this.nudge('w', 0.005) })
          Text(`首行${this.calibTopPx.toFixed(0)} 行高×${this.calibLineMul.toFixed(3)} 宽比${this.calibWidthRatio.toFixed(3)}`)
            .fontSize(11).fontColor('#D24A00').layoutWeight(1).maxLines(2)
          Text('重置').fontSize(12).fontColor('#D24A00')
            .padding({ left: 8, right: 8, top: 4, bottom: 4 })
            .borderRadius(10).backgroundColor('rgba(210,74,0,0.12)')
            .onClick(() => { Haptics.tap(); this.resetCalib() })
        }
      }

      // ══ 背景选择（2026-09-25 用户改版）══════════════════════════════════════
      // 用户原话：「取消背景这两个字，**一行四个，最多三行**，如果方案超过 3*4，
      //   那么**最后一行**按照当前这个左右可以拖拽无限数量的方式。」
      // ⇒ 去掉「背景」标签；前 12 格 = 一行四个、最多三行（`swatchRows()` 分块）；
      //   第 13 格起 = 横向滚动行（`swatchOverflow()`，无限追加）。
      //   格子顺序不变：纯色（推荐色）→ 材质 → 保存的方案（颜色方案 → 材质方案）。
      Column({ space: 8 }) {
        ForEach(this.swatchRows(), (row: themeItem[], ri: number) => {
          Row({ space: 8 }) {
            ForEach(row, (item: themeItem) => {
              this.SwatchCore(item, false)
            }, (item: themeItem): string => this.swatchKey(item))
          }
          .width('100%')
        }, (row: themeItem[], ri: number): string => 'brow' + ri + '-' + this.customTexSeq)
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)

      // ══ 推荐字色（2026-09-25 新增，用户设计）════════════════════════════════
      // 位置：原「材质混合」开关处（用户指定）。两行 × 5 枚 = 一行五个（用户指定）。
      // 点任一枚 = 立即应用 + `fontAuto=false`（自动对比停手）+ 圈落到这一格。
      Column({ space: 6 }) {
        this.FontRow(FONT_ON_LIGHT, '日间字色推荐')
        this.FontRow(FONT_ON_DARK, '夜间字色推荐')
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)

      // ══ 背景模糊（2026-09-26 定稿：0-30 五档 + CapsuleSegmentButtonV2 档位控件）══
      // 用户需求：「在自定义颜色开关之上，增加背景模糊功能开关，样式对齐自定义颜色…
      //   常态化存储及持久化」；强度「限制 0-30，五个档位平均一点」，控件「不用拖块，
      //   用那种档位滑块」。
      // 实现：模糊"洗进"材质图里再交给引擎（引擎画布不透底，真机实测见 bgBlurOn 注释）；
      //   强度 5 档（6/12/18/24/30）每档一张磁盘缓存图（首次未命中现场生成一次，
      //   其余档后台预生成），选档 = 换一个缓存文件 + 一次引擎重排。
      // 控件取证：`CapsuleSegmentButtonV2`（SDK `@ohos.arkui.advanced.SegmentButtonV2.d.ets:1110`，
      //   @since 18，工程 API 26 覆盖；官方文档
      //   `API参考/ArkUI_方舟UI框架/ArkTS组件/系统预置UI组件库/SegmentButtonV2/
      //   ohos-arkui-advanced-segmentbuttonv2`：调用点为
      //   `{ items, selectedIndex, $selectedIndex?, onItemClicked? }`）。
      //   ⚠️ 不用 V1 `SegmentButton`：其 `options` 是 `@ObjectLink`，而本面板挂在
      //   `@CustomDialog` 的 `@BuilderParam` 上 —— SDK `custom_dialog_controller.d.ts:57-60`
      //   原文「To listen for data changes in the builder, use the @Link or @Consume
      //   decorator; other decorators, such as @Prop and @ObjectLink, do not apply.」
      //   ⇒ V1 版在弹窗 builder 里绑定不生效，V2 全普通参数 + 回调，无此限制。
      // 行结构 / 标签字色 / Toggle 样式（'#007DFF'）与下面「自定义颜色」行完全一致。
      // 纯色/自定义颜色：纯色模糊仍是同一纯色，无需换图（texId=0 时开关只改状态）。
      // 回退：关掉开关即回原图路径；磁盘缓存在 cacheDir/readerbg/blur，可整体删除。
      Column({ space: 8 }) {
        Row({ space: 10 }) {
          Text('背景模糊')
            .fontColor(this.colorMode == 0 ? 'rgba(248, 249, 250, 1)' : 'rgba(19, 19, 19, 1.00)')
          Toggle({ type: ToggleType.Switch, isOn: this.bgBlurOn })
            .selectedColor('#007DFF')
            .onChange((value: boolean) => {
              Haptics.tap();
              this.bgBlurOn = value
              // 材质背景要换图（模糊版 ⇄ 原图）；纯色模糊 = 原样，无需动引擎。
              // ⚠️ 2026-10-06 修复（用户实测："用自定义材质时档位失效、关掉也无效"）：
              //   条件必须**同时**判自定义材质（`bgCustomId`）—— 自定义材质走的是
              //   `bgCustomId` + `bgTexId = 0`（见 `pickCustom`），旧写法只判 `bgTexId > 0`
              //   ⇒ 用自定义材质时开关进不了 `applyTextureBg()`。
              //   真机日志证据（`Downloads\2.md`）：预设材质依次生成并发布了
              //   `blur/t1_1320x2848_r30|r18|r12|r6.jpg` 四张缓存图，而自定义材质只有
              //   `blur/cu1791301678558_1320x2848_r6.jpg` 一张，之后再无任何
              //   `LTBOOK publish page bg` ⇒ 档位/关开都没有重新下发。
              if (this.bgTexId > 0 || this.bgCustomId.length > 0) {
                this.applyTextureBg()
              }
              this.saveCustomBg()
            })
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)

        if (this.bgBlurOn) {
          Row({ space: 10 }) {
            Text('强度')
              .fontSize(12)
              .fontColor(this.colorMode == 0 ? 'rgba(248, 249, 250, 0.6)' : 'rgba(19, 19, 19, 0.6)')
            CapsuleSegmentButtonV2({
              items: this.bgBlurSegItems,
              selectedIndex: this.bgBlurTierIndex(),
              $selectedIndex: (index: number) => {
                Haptics.tap();
                this.bgBlurRadius = BG_BLUR_TIERS[index]
                // 选档即换图（磁盘缓存命中零等待；未命中的档现场生成一次）
                // ⚠️ 同开关：必须同时判自定义材质（`bgCustomId`），否则用自定义材质时
                //   选档不会重新下发（2026-10-06 用户实测修复，详见上面开关处注释）。
                if (this.bgTexId > 0 || this.bgCustomId.length > 0) {
                  this.applyTextureBg()
                }
                this.saveCustomBg()
              }
            })
              .layoutWeight(1)
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)
        }
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)

      // ══ 自定义颜色（2026-09-25 用户改版：保存键方案 + 背景/文字滑块）══════════
      // 三轮布局反馈：「颜色预览和编号放到现在保存的位置，开关放在自定义颜色后面，
      //   保存放在现在开关的位置，删除保存后面的说明…**还是两边对齐**」。
      // 四轮反馈：「**自定义颜色关闭的时候，颜色预览以及保存按钮都没被隐藏**」
      // ⇒ 第二行（预览+色值+保存）与"背景/文字"滑块都是**自定义模式的配套件**，
      //   开关关着时一并隐藏（调色盘本来就藏着，留着它们只会误导）。
      Column({ space: 8 }) {
        Row({ space: 10 }) {
          Text('自定义颜色')
            .fontColor(this.colorMode == 0 ? 'rgba(248, 249, 250, 1)' : 'rgba(19, 19, 19, 1.00)')
          // ── 自定义颜色开关（进入/退出自定义颜色模式），紧贴标签（用户指定）────
          if (VipManager.isVip()) {
            Toggle({ type: ToggleType.Switch, isOn: this.customBgOn || this.customEditOn })
              .selectedColor('#007DFF')
              .onChange((value: boolean) => {
                Haptics.tap();
                this.toggleCustomBg(value)
              })
          } else {
            // 会员化（2026-09-28）：免费用户看到锁定样式的假开关，点击 → VIP 弹窗
            //（不用真 Toggle：避免"点了先弹开又弹回"的视觉回弹问题）
            Stack({ alignContent: Alignment.End }) {
              Row()
                .width(40)
                .height(22)
                .borderRadius(11)
                .backgroundColor('rgba(128, 128, 128, 0.45)')
              Row()
                .width(18)
                .height(18)
                .borderRadius(9)
                .backgroundColor(Color.White)
                .margin({ right: 2 })
            }
            .onClick(() => {
              Haptics.tap();
              this.openVipDialog()
            })
          }
          // 调色盘相关区块的显隐：**已应用**或**展开编辑中**都显示（见 customEditOn 注释）
          if (this.customBgOn || this.customEditOn) {
            Blank()
            // ── "背景 / 文字"滑块：切调色盘的编辑目标（用户口中的"通过滑块切换"）────
            Text('背景')
              .fontSize(12)
              .fontColor(!this.fontTarget ? '#007DFF'
                : (this.colorMode == 0 ? 'rgba(248, 249, 250, 0.6)' : 'rgba(19, 19, 19, 0.6)'))
            Toggle({ type: ToggleType.Switch, isOn: this.fontTarget })
              .selectedColor('#007DFF')
              .onChange((value: boolean) => {
                Haptics.tap();
                this.fontTarget = value
              })
            Text('文字')
              .fontSize(12)
              .fontColor(this.fontTarget ? '#007DFF'
                : (this.colorMode == 0 ? 'rgba(248, 249, 250, 0.6)' : 'rgba(19, 19, 19, 0.6)'))
          }
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)

        if (this.customBgOn || this.customEditOn) {
          Row({ space: 10 }) {
          // ── 预览块 = 当前编辑目标（背景/文字）的草稿色；「保存」确认后持橙圈 ──
          Column()
            .width(22)
            .height(22)
            .borderRadius(11)
            .backgroundColor(this.fontTarget ? this.customFontHex() : this.customBgHex())
            .borderWidth(this.isCustomBgFocused() ? 2 : 1)
            .borderColor(this.isCustomBgFocused()
              ? '#ff6600'
              : (this.colorMode == 0 ? 'rgba(248, 249, 250, 0.35)' : 'rgba(0, 0, 0, 0.25)'))
          Text(this.fontTarget ? this.customFontHex() : this.customBgHex())
            .fontSize(12)
            .fontColor(this.isCustomBgFocused()
              ? '#ff6600'
              : (this.colorMode == 0 ? 'rgba(248, 249, 250, 0.6)' : 'rgba(19, 19, 19, 0.6)'))
            Blank()
            // ── 保存按钮（用户指定放右端）：确认草稿 = 应用 + 落盘 + 持焦 ─────────
            Button('保存')
              .fontSize(13)
              .fontColor(Color.White)
              .backgroundColor('#007DFF')
              .borderRadius(18)
              .height(34)
              .padding({ left: 14, right: 14 })
              .clickEffect(UiMotion.CLICK)
              .onClick(() => {
                Haptics.tap();
                this.commitCustomColor()
              })
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)
        }
      }
      .width('100%')

      if (this.customBgOn || this.customEditOn) {
        // 左：无极调色盘（横向色相 × 纵向明暗的连续色域，任意点都能取到确定颜色）
        // 右：R / G / B 三条 0-255 滑块（与字号/行距同款 Slider，带气泡 + 线性震动）
        // ⚠️ 2026-09-25 保存键方案：调色盘/滑条**只写草稿**（按 fontTarget 分流），
        //    不碰引擎 —— 按「保存」才应用。草稿存哪（背景 or 文字）由 setDraft 收口。
        Row({ space: 14 }) {
          ReaderBgPalette({
            paletteR: this.draftR(),
            paletteG: this.draftG(),
            paletteB: this.draftB(),
            onPick: (r: number, g: number, b: number): void => {
              this.setDraft(r, g, b)
            },
            onCommit: (): void => {
              // 抬手不做任何"生效"—— 确认权在「保存」按钮（用户最终裁定）
            }
          })

          Column({ space: 4 }) {
            // ── 气泡：为什么**不用**系统 `Slider.showTips(true, …)` ────────────────
            // 官方 FAQ 原文（documentId
            //   `FAQ/UI框架/组件使用/Slider组件自定义气泡开发/faqs-arkui-1198`）：
            //   「**场景二**：动态内容更新需求。如何实现一个带刻度的 Slider 组件，
            //     **在滑块滑动过程中，Slider 气泡可动态更新 UI 内容**？」
            //   解决思路原文：「气泡实现方式：可使用 `showTips(false)` **关闭系统气泡**，
            //     选择系统 Popup 组件或自定义组件比如 Text 模拟气泡。」
            //     「关键增强：将气泡实现方式升级为 Popup 组件，通过 @Builder 自定义丰富的气泡内容；
            //      在 Slider 的 onChange 回调中，**实时同步更新气泡内容**，实现 UI 的动态刷新。」
            // ⇒ 官方把"滑动中气泡内容实时更新"明确归为**需要自己实现**的场景
            //   ⇒ 所以这里按官方方案自己画：`Stack` 层叠 + `Text` 模拟气泡 + `position` 定位
            //     + `SliderChangeMode` 控显隐；位置沿用官方 `calculateExactPosition` 的思路
            //     （滑块中心 − 气泡半宽，再夹进轨道范围内）。
            // ── R ──────────────────────────────────────────────────────────
            Row({ space: 6 }) {
              Text('R')
                .fontSize(12)
                .width(14)
                .fontColor(this.colorMode == 0 ? 'rgba(248, 249, 250, 1)' : 'rgba(19, 19, 19, 1.00)')
              Stack() {
                Slider({
                  value: this.draftR(),
                  min: 0,
                  max: 255,
                  step: 1,
                  style: SliderStyle.InSet
                })
                  .selectedColor(this.sliderSelectedColor())
                  .blockSize({ width: 22, height: 22 })
                  .borderRadius(20)
                  .padding({ left: 6, right: 6 })
                  .width('100%')
                  .showTips(false)
                  // 取轨道实测宽度（vp）给气泡定位用；`Area.width` 的官方说明见
                  // `…\ets\component\common.d.ts:20062`（`onAreaChange`）。
                  .onAreaChange((oldArea: Area, newArea: Area) => {
                    this.bgSliderW = Number(newArea.width)
                  })
                  .onChange((value: number, mode: SliderChangeMode) => {
                    Haptics.tick();
                    this.setDraft(Math.round(value), this.draftG(), this.draftB())
                    this.onCustomBgSliderChange(mode, 0)
                  })
                if (this.bgTipCh === 0) {
                  Text(`${this.draftR()}`)
                    .fontSize(12)
                    .fontColor('#FFFFFF')
                    .backgroundColor('#007DFF')
                    .borderRadius(6)
                    .width(44)
                    .textAlign(TextAlign.Center)
                    .padding({ top: 3, bottom: 3 })
                    .position({ x: this.bgTipX(this.draftR()), y: -26 })
                    // 气泡只负责显示，绝不能吃掉落手指（否则滑条拖不动）
                    .hitTestBehavior(HitTestMode.None)
                }
              }
              .layoutWeight(1)
              Text(`${this.draftR()}`)
                .fontSize(12)
                .width(30)
                .textAlign(TextAlign.End)
                .fontColor('#007DFF')
            }
            .width('100%')
            .alignItems(VerticalAlign.Center)

            // ── G ──────────────────────────────────────────────────────────
            Row({ space: 6 }) {
              Text('G')
                .fontSize(12)
                .width(14)
                .fontColor(this.colorMode == 0 ? 'rgba(248, 249, 250, 1)' : 'rgba(19, 19, 19, 1.00)')
              Stack() {
                Slider({
                  value: this.draftG(),
                  min: 0,
                  max: 255,
                  step: 1,
                  style: SliderStyle.InSet
                })
                  .selectedColor(this.sliderSelectedColor())
                  .blockSize({ width: 22, height: 22 })
                  .borderRadius(20)
                  .padding({ left: 6, right: 6 })
                  .width('100%')
                  .showTips(false)
                  .onChange((value: number, mode: SliderChangeMode) => {
                    Haptics.tick();
                    this.setDraft(this.draftR(), this.draftG(), this.draftB())
                    this.onCustomBgSliderChange(mode, 1)
                  })
                if (this.bgTipCh === 1) {
                  Text(`${this.draftG()}`)
                    .fontSize(12)
                    .fontColor('#FFFFFF')
                    .backgroundColor('#007DFF')
                    .borderRadius(6)
                    .width(44)
                    .textAlign(TextAlign.Center)
                    .padding({ top: 3, bottom: 3 })
                    .position({ x: this.bgTipX(this.draftG()), y: -26 })
                    .hitTestBehavior(HitTestMode.None)
                }
              }
              .layoutWeight(1)
              Text(`${this.draftG()}`)
                .fontSize(12)
                .width(30)
                .textAlign(TextAlign.End)
                .fontColor('#007DFF')
            }
            .width('100%')
            .alignItems(VerticalAlign.Center)

            // ── B ──────────────────────────────────────────────────────────
            Row({ space: 6 }) {
              Text('B')
                .fontSize(12)
                .width(14)
                .fontColor(this.colorMode == 0 ? 'rgba(248, 249, 250, 1)' : 'rgba(19, 19, 19, 1.00)')
              Stack() {
                Slider({
                  value: this.draftB(),
                  min: 0,
                  max: 255,
                  step: 1,
                  style: SliderStyle.InSet
                })
                  .selectedColor(this.sliderSelectedColor())
                  .blockSize({ width: 22, height: 22 })
                  .borderRadius(20)
                  .padding({ left: 6, right: 6 })
                  .width('100%')
                  .showTips(false)
                  .onChange((value: number, mode: SliderChangeMode) => {
                    Haptics.tick();
                    this.setDraft(this.draftR(), this.draftG(), Math.round(value))
                    this.onCustomBgSliderChange(mode, 2)
                  })
                if (this.bgTipCh === 2) {
                  Text(`${this.draftB()}`)
                    .fontSize(12)
                    .fontColor('#FFFFFF')
                    .backgroundColor('#007DFF')
                    .borderRadius(6)
                    .width(44)
                    .textAlign(TextAlign.Center)
                    .padding({ top: 3, bottom: 3 })
                    .position({ x: this.bgTipX(this.draftB()), y: -26 })
                    .hitTestBehavior(HitTestMode.None)
                }
              }
              .layoutWeight(1)
              Text(`${this.draftB()}`)
                .fontSize(12)
                .width(30)
                .textAlign(TextAlign.End)
                .fontColor('#007DFF')
            }
            .width('100%')
            .alignItems(VerticalAlign.Center)
          }
          .layoutWeight(1)
          // 与左侧色盘同高（色盘 = 116vp），三行在高度内均分 ⇒ 视觉上对齐
          .height(116)
          .justifyContent(FlexAlign.SpaceBetween)
        }
        .width('100%')
        .alignItems(VerticalAlign.Top)

      }

      // ── 底部按钮行（2026-09-25 用户四轮反馈统一）：同步全局**不再隐藏** ─────────
      // 用户原话：「全局同步不再隐藏，在自定义颜色没有开启的时候，与翻页按钮并存，
      //   此时…布局是居中对齐，如果开启自定义颜色，则按钮对齐保存方案按钮，三个按钮居中对齐」
      // ⇒ 一个居中 Flex：关 = [同步全局][翻页]；开 = [同步全局][翻页][保存方案]。
      // ⚠️ 2026-10-06（V3）：**「保存方案」改为常显** —— 方案已能表达材质/自定义材质
      //   （`SchemeV3`），而"材质背景 + 任意字色"这种搭配恰恰要在**没开自定义颜色**时保存；
      //   旧条件（只在 customBgOn/customEditOn 时显示）等于把这条路堵死（用户实测反馈）。
      Flex({
        wrap: FlexWrap.Wrap,
        alignItems: ItemAlign.Center,
        justifyContent: FlexAlign.Center
      }) {
        Button('同步全局')
          .fontSize(13)
          .fontColor(this.colorMode == 0 ? 'rgba(248, 249, 250, 1)' : 'rgba(19, 19, 19, 1.00)')
          .backgroundColor(this.colorMode == 0
            ? 'rgba(248, 249, 250, 0.16)'
            : 'rgba(19, 19, 19, 0.06)')
          .borderRadius(18)
          .height(34)
          .padding({ left: 12, right: 12 })
          .margin({ right: 10, top: 4, bottom: 4 })
          .clickEffect(UiMotion.CLICK)
          .onClick(() => {
            Haptics.tap();
            this.syncCustomBgGlobal()
          })
        this.FlipModeButton()
        Button('保存方案')
          .fontSize(13)
          .fontColor(this.colorMode == 0 ? 'rgba(248, 249, 250, 1)' : 'rgba(19, 19, 19, 1.00)')
          .backgroundColor(this.colorMode == 0
            ? 'rgba(248, 249, 250, 0.16)'
            : 'rgba(19, 19, 19, 0.06)')
          .borderRadius(18)
          .height(34)
          .padding({ left: 12, right: 12 })
          .margin({ right: 10, top: 4, bottom: 4 })
          .clickEffect(UiMotion.CLICK)
          .onClick(() => {
            Haptics.tap();
            this.openSaveSchemeDialog()
          })
      }
      .width('100%')
    }.padding({
      left: 20, right: 20,
      // ★ 2026-09-23 用户：「（仿真翻页按钮）与容器贴底，加一点点间距」
      bottom: 12
    })
  }

  /**
   * 「翻页：仿真 / 横滑」胶囊按钮（2026-09-23 重做，2026-09-26 抽成 @Builder）。
   *
   * 历史：原来直接用系统默认 Button（自带主题色底 + 默认圆角/内边距），放在这个自绘胶囊里
   * 显得很突兀 ⇒ 改成与胶囊同色系的**半透明胶囊按钮**，并让文案直接反映**当前**翻页模式
   * （原来恒定写「仿真翻页」，而模式可能是"横滑"，属于会误导人的静态标签）。
   *
   * ⚠️ 为什么抽成 @Builder：开启自定义背景后它要跟「同步全局 / 保存方案」同处一行，
   *   而关闭自定义时又要留在原来的独立行 —— 同一个按钮出现在两个位置，只能有一份定义。
   *   本 @Builder **不带参数**（按值传参的 @Builder 在参数变化时不保证刷新，
   *   这里读的是页面自己的 `@State readerSetting.flipMode`，由父级重建驱动，没有这个隐患）。
   */
  @Builder
  FlipModeButton() {
    Button(this.readerSetting.flipMode == '0' ? '翻页：仿真' : '翻页：横滑')
      .fontSize(13)
      .fontColor(this.colorMode == 0 ? 'rgba(248, 249, 250, 1)' : 'rgba(19, 19, 19, 1.00)')
      .backgroundColor(this.colorMode == 0
        ? 'rgba(248, 249, 250, 0.16)'
        : 'rgba(19, 19, 19, 0.06)')
      .borderRadius(18)
      .height(34)
      .padding({ left: 12, right: 12 })
      .margin({ right: 10, top: 4, bottom: 4 })
      .clickEffect(UiMotion.CLICK)
      .onClick(() => {
        Haptics.tap();
        if (this.readerSetting.flipMode == '0') {
          this.readerSetting.flipMode = '1';
          this.getUIContext().getPromptAction().showToast({ message: '横滑' })
        } else {
          this.readerSetting.flipMode = '0';
          this.getUIContext().getPromptAction().showToast({ message: '仿真' })
        }
        this.readerComponentController.setPageConfig(this.readerSetting);
        // 翻页模式是 `readerSetting` 的字段，本页只在 pageShow 时落盘；
        // 这里立刻写一次，避免"改完马上退出"导致这次选择丢失。
        const name: string = this.bookData.bookName
        if (name !== undefined && name !== null && name.length > 0) {
          PreferencesUtil.putSync(`ReaderSetting_${name}`, this.readerSetting)
        }
      })
  }

  /**
   * 打开「目录 / 书签」弹窗（2026-09-23 从 `bindSheet` 改成 `@CustomDialog`）。
   *
   * ⚠️ **每次打开都新建控制器**：`CustomDialogControllerOptions` 的参数**不支持动态更新**，
   *    SDK `custom_dialog_controller.d.ts:756` 的 NOTE 原文
   *    「Custom dialog box parameters **do not support dynamic updates**」
   *    ⇒ 预先建好再改传入值不会生效；要传"当前章号 / 日夜模式 / 页签 / 关键词"就只能每次新建。
   *    （本页 `openSleepTimerDialog()` 是同款做法。）
   * 关闭动作：关自己一律走 `this.readerCatalogDialog?.close()`；点章节 / 书签由下面两个回调按
   *    **改造前的原始顺序**收尾（先跳转、后关窗；书签那条"章节已不存在"的早退分支**不关窗**）。
   */
  openCatalogDialog(): void {
    this.readerCatalogDialog = new CustomDialogController({
      builder: ReaderCatalogDialog({
        // 目录数据：传**浅拷贝**（元素仍是同一批对象引用，弹窗里靠引用相等判断"当前章"）
        catalogItems: this.CatalogList.getOriginDataArray().slice(),
        currentChapterIndex: this.bookData.durChapterIndex,
        totalChapterNum: this.bookData.totalChapterNum,
        colorMode: this.colorMode,
        bookName: this.bookData.bookName,
        initTab: this.cdlTab,
        initKeyword: this.catalogKeyword,
        onKeywordChange: (kw: string): void => {
          this.catalogKeyword = kw
        },
        onTabChange: (t: number): void => {
          this.cdlTab = t
        },
        onPickCatalogItem: (item: bookParser.CatalogItem, index: number): void => {
          // 顺序与改造前的 `ListItem.onClick` 完全一致：
          // ① 记当前章号（**全书目录**下标，不是过滤后的序号）② 跳章 ③ 关弹窗
          this.bookData.durChapterIndex = index
          this.jumpToCatalogItem(item)
          this.readerCatalogDialog?.close()
        },
        onPickBookmark: (row: BookmarkRow): void => {
          // `jumpToBookmark()` 内部自带"章节已不存在"的早退分支（早退时**不关**弹窗），
          // 关窗动作也留在那边，保证与改造前行为一致。
          this.jumpToBookmark(row)
        }
      }),
      autoCancel: true,
      // ── 位置：偏下但**不贴底**（2026-09-23 用户选择「改成偏下（离底边留一掌）」）──────────
      // 证据：`alignment?: DialogAlignment`（`custom_dialog_controller.d.ts:104`，@since 7），
      //   枚举原文「Vertical bottom alignment.」= `DialogAlignment.Bottom`；
      //   `offset?: Offset`（同文件 @since 7）官方原文
      //   「Offset of the dialog box relative to the alignment position.」
      //   ⇒ 底部对齐后再把整个面板上移 `CATALOG_DIALOG_BOTTOM_GAP` vp（留白见该常量注释）。
      alignment: DialogAlignment.Bottom,
      offset: { dx: 0, dy: -CATALOG_DIALOG_BOTTOM_GAP },
      width: '92%',
      // ⚠️ **刻意不写 height**：弹窗高度改由**内容节点**决定
      //    （`ReaderCatalogDialog` 根 Column 的 `.height(...)`：不输入 560 / 输入中 440），
      //    这样键盘弹起时才能把面板**收矮**，给顶部留出摄像头安全区。
      //    证据①：`custom_dialog_controller.d.ts:126`「If the width and height of the dialog box
      //      are not set, the dialog box automatically adapts its width to the grid system and its
      //      height to the custom content node.」
      //    证据②：同文件 :26-30 的 class 级 NOTE —— 系统键盘避让只保证"塞得进键盘上方"
      //      （「it reduces its height to fit」），**不会**替我们留顶部安全区。
      //      真机截图实测（2026-09-23）：面板固定 560vp + 键盘弹起 ⇒ 顶边 ≈ −28vp，压住摄像头。
      cornerRadius: 20,
      customStyle: false,
      systemMaterial: ImmersiveMaterialUtil.sheetMaterial(),
      // 弹窗出入场：弹簧令牌（理由见 `listenDialog` 处的注释）
      openAnimation: UiMotion.motionParam(UiMotion.SPRING_FAST),
      closeAnimation: UiMotion.motionParam(UiMotion.SPRING_FAST),
    })
    this.readerCatalogDialog?.open()
  }

  /**
   * 打开听书面板。
   *
   * ⚠️ 这里**只负责"置位 + open()"**：控制器建在 `listenDialog` 字段的初始化器里，
   *   原因见那段注释（`$xxx` 在普通方法里不会变成 @Link，会直接崩）。
   */
  openListenDialog(): void {
    this.isShowListen = true
    this.listenDialog.open()
  }

  /**
   * 底部页签条的**单个页签内容**（真 Tabs 的 `tabBar` builder）。
   *
   * `action` = **动作 id**（0=目录 1=听书 2=日/夜/自由 3=设置），
   * `pos` = **页签位置**（未解锁时听书格缺失，pos 与 action 不再相等）。
   * 点按由每个图标自己的 `onClick` → `dispatchBarAction(action)` 派发（见下）。
   *
   * ── 2026-09-25 全部换成 SymbolGlyph（用户要求「四个图标不全都是 symbol，请使用 symbol」）──
   * 符号名全部在 SDK 符号表
   *   `…\Sdk\23\previewer\common\resources\entry\resources.txt` 查得（沿用本工程
   *   "表里的 name == `sys.symbol.<name>` 后缀" 的核名规则，不猜名字）：
   *   `list_bullet`(目录) / `book_badge_speaker`(听书：书+喇叭) /
   *   `sun_max`(日) `moon`(夜) `paintpalette`(自由，工程已用) / `gearshape`/`gearshape_fill`(设置)。
   * ── 点击动效 ──
   *   `.scale()` + `runJellyClick` 三段式Q弹（2026-09-25 二次调优：系统内置
   *   ScaleSymbolEffect 节奏定死、真机实测太慢，借参考工程同款实现，见 UiMotion）。
   *   设置格保留 `gearshape ↔ gearshape_fill` 的替换动效表达"面板开着"（状态语义）。
   */
  @Builder
  ReaderBarItem(action: number, pos: number) {
    Column() {
      if (action === 0) {
        SymbolGlyph($r('sys.symbol.list_bullet'))
          .fontSize(24)
          .fontColor([this.colorMode == 0 ? 'rgba(248, 249, 250, 1)' : 'rgba(19, 19, 19, 1.00)'])
          .scale({ x: this.barScale[pos], y: this.barScale[pos] })
      } else if (action === 1) {
        SymbolGlyph($r('sys.symbol.book_badge_speaker'))
          .fontSize(24)
          .fontColor([this.colorMode == 0 ? 'rgba(248, 249, 250, 1)' : 'rgba(19, 19, 19, 1.00)'])
          .scale({ x: this.barScale[pos], y: this.barScale[pos] })
      } else if (action === 2) {
        // ── 三模式图标（2026-09-26 用户要求加「自由」）────────────────────────
        // 沿用改造前的**「显示目标」**约定（见下段注释）：日间时显示「夜间」、
        // 夜间时显示「自由」、自由时显示「日间」。想改成"显示当前模式"
        // 只需把 `nextReaderMode()` 换成 `readerMode()`（一处两行）。
        if (this.nextReaderMode() === 2) {
          SymbolGlyph($r('sys.symbol.paintpalette'))
            .fontSize(24)
            .fontColor([this.colorMode == 0 ? 'rgba(248, 249, 250, 1)' : 'rgba(19, 19, 19, 1.00)'])
            .scale({ x: this.barScale[pos], y: this.barScale[pos] })
        } else if (this.nextReaderMode() === 1) {
          SymbolGlyph($r('sys.symbol.moon'))
            .fontSize(24)
            .fontColor([this.colorMode == 0 ? 'rgba(248, 249, 250, 1)' : 'rgba(19, 19, 19, 1.00)'])
            .scale({ x: this.barScale[pos], y: this.barScale[pos] })
        } else {
          SymbolGlyph($r('sys.symbol.sun_max'))
            .fontSize(24)
            .fontColor([this.colorMode == 0 ? 'rgba(248, 249, 250, 1)' : 'rgba(19, 19, 19, 1.00)'])
            .scale({ x: this.barScale[pos], y: this.barScale[pos] })
        }
      } else {
        // 设置格：保留"面板开着 = 实心"的状态表达（对齐改造前 fill 图标行为），
        // 动效走 ReplaceSymbolEffect（状态一变播替换动画），点击另有 Q弹缩放。
        SymbolGlyph(this.gearIcon())
          .fontSize(24)
          .fontColor([this.colorMode == 0 ? 'rgba(248, 249, 250, 1)' : 'rgba(19, 19, 19, 1.00)'])
          .symbolEffect(new ReplaceSymbolEffect(), this.isShowContentSetting ? 1 : 0)
          .scale({ x: this.barScale[pos], y: this.barScale[pos] })
      }
      Text(this.readerBarLabel(action))
        .fontColor(this.colorMode == 0 ? 'rgba(248, 249, 250, 1)' : 'rgba(19, 19, 19, 1.00)')
    }
    .justifyContent(FlexAlign.Center)
    .height('100%')
    .clickEffect(UiMotion.CLICK)
    // ★★ 动作**由每个图标自己派发**（2026-09-23 真机修复）★★
    //   不要改回 `Tabs.onTabBarClick()`：真机实测一次点击它**会派发多次，且第一个
    //   派发的 index 恒为 0** ⇒ 点"听书/设置"弹出来的都是目录（用户两轮反馈）。
    //   为什么 builder 内部收得到点击：本工程 `pages/Index.ets:207-212` 就在 tabBar
    //   builder 里挂了 `LongPressGesture` 且真机有效 ⇒ 命中测试正常到达 builder 内容。
    .onClick(() => {
      Haptics.tap();
      // Q弹缩放只弹被点的这一格（数组整体重赋值确保 @State 观察到变化）
      runJellyClick((v: number) => {
        const s = this.barScale.slice();
        s[pos] = v;
        this.barScale = s;
      })
      this.dispatchBarAction(action)
    })
  }

  /**
   * 底部页签条文案（与改造前 `Grid` 里的 `Text` 一致）。
   *
   * ⚠️ 入参是**动作 id**（不是页签位置）：第 2 格（日/夜/自由）沿用改造前的
   * **「显示目标」**约定 —— 日间时写「夜间」、夜间时写「自由」、自由时写「日间」。
   */
  private readerBarLabel(action: number): string {
    if (action === 0) {
      return '目录'
    }
    if (action === 1) {
      return '听书'
    }
    if (action === 2) {
      return this.readerModeName(this.nextReaderMode())
    }
    return '设置'
  }

  /**
   * 底部页签条的**动作分发**（0=目录 1=听书 2=日夜 3=设置）。
   *
   * 逻辑**原样搬自**改造前那四个 `GridItem` 的 `onClick`（行为未改）。
   * ⚠️ 调用方**只有** `ReaderBarItem()` 里每个图标自己的 `onClick` ——
   *    **不要**改回 `Tabs.onTabBarClick()`：真机实测（2026-09-22 两轮反馈）：
   *    一次点击 `onTabBarClick` 会派发多次，且**第一个派发的 index 恒为 0**，
   *    ⇒ 点"听书/设置"弹出来的都是目录。
   */
  private dispatchBarAction(index: number): void {
    hilog.info(0x0000, 'testTag', 'readerBarAction: index=%{public}d', index)
    if (index === 0) {
      // 目录（含书签页签）—— 2026-09-23 起是 @CustomDialog
      this.openCatalogDialog()
    } else if (index === 1) {
      // 听书面板（@CustomDialog，见 `openListenDialog()`）
      this.openListenDialog()
    } else if (index === 2) {
      // ── 三模式循环：日间 → 夜间 → 自由 → 日间（2026-09-26 用户要求加「自由」）────
      // 起因（用户原话）：「我们设置一个背景色之后…如果点击日间或者夜间切换，就没了，
      //   这次设置就丢了」；解决方案是用户提的：「增加一个模式，日间，夜间，**自由**」。
      // ⇒ 切到日/夜时**只把模式切走**，你调好的色值留在 `ReaderBg_<书名>` 里
      //   （`setStandardMode()` 写的是 `{on:false}` + **当前 rgb**），按到「自由」原样回来。
      //
      // 过渡动效依据（保留改造前的取证）：`animateTo(value: AnimateParam, event: () => void)`
      //   （`…\ets\api\@ohos.arkui.UIContext.d.ts:4703`，`@since 10`）官方 @param 原文：
      //   「Closure function that displays the animation. The system automatically inserts
      //     the transition animation if the state changes in the closure function.」
      // 本页大量 `.fontColor(this.colorMode == 0 ? … : …)` / `.fillColor(…)` 都由 `colorMode` 派生，
      // 包进闭包后**颜色会插值过渡**。
      // `setPageConfig` 留在闭包外面（它触发 ReaderKit 重新排版，不该参与动画）——
      // 由 `setStandardMode()` / `applyCustomBg()` 各自负责调用。
      const next = this.nextReaderMode()
      if (next === 2) {
        // 自由：用记录里存着的颜色（首次没记录就以当前主题色为起点）。
        // ⚠️ 这一支**刻意不包 `animateTo`**：`enterFreeMode()` 里会 `setPageConfig`
        //   （ReaderKit 重排版）与 `syncAbilityColorMode()`（`ctx.setColorMode()`
        //   一次**系统级重涂**）。把系统级重涂放进动画闭包里正是本工程反复记过的
        //   "屏闪"成因（见 `ReaderPage3.aboutToAppear` 尾部的延迟块注释）
        //   ⇒ 底色本来就是整页换，硬切反而干净。
        this.customBgPrevTheme = this.readerSetting.themeColor
        this.customBgPrevFont = this.readerSetting.fontColor
        this.customBgPrevNight = this.readerSetting.nightMode
        this.enterFreeMode()
      } else {
        // 日/夜：颜色会插值过渡（`.fontColor/.fillColor` 都由 `colorMode` 派生）。
        // `setPageConfig` 留在闭包外面：它触发 ReaderKit 重新排版，不该参与动画。
        this.getUIContext().animateTo(UiMotion.motionParam(), () => {
          this.colorMode = next === 0 ? 0 : 1
          this.readerSetting.nightMode = next === 0
          this.readerSetting.fontColor = next === 0 ? '#ffffff' : '#000000'
          this.readerSetting.themeColor = next === 0 ? '#202224' : '#FFFFFF'
        })
        // 收口：落盘（`{on:false}` + **当前 rgb**，色值不丢）、
        // Ability 配色、`setPageConfig` 都在这里，且都在动画闭包之外。
        this.setStandardMode(next === 0)
      }
    } else {
      // 设置面板（@CustomDialog，见 `settingDialog` 字段 + `openSettingDialog()`）
      this.toggleSettingDialog()
    }
  }

  /**
   * 「设置」开关（2026-09-23 从"翻 `isShowContentSetting` 换胶囊内容"改成"开/关弹窗"）。
   *
   * 改造前：`this.isShowContentSetting = !this.isShowContentSetting`
   *   ⇒ 只是把底栏胶囊里的**进度行换成设置行** ⇒ 没有出入场、没有遮罩（用户真机反馈）。
   * 现在：设置内容搬进 `@CustomDialog`（真材质 + 默认遮罩 + 弹簧），
   *   `isShowContentSetting` 退化为**纯图标态**（实心/空心），不再影响布局。
   */
  private toggleSettingDialog(): void {
    if (this.isShowContentSetting) {
      this.isShowContentSetting = false
      this.settingDialog?.close()
    } else {
      this.isShowContentSetting = true
      this.settingDialog?.open()
    }
  }

  // `sourceView()` / `purificationView()` / `DialogString()` 三个 @Builder 已于 2026-09-21 删除 ——
  // 它们的**唯一调用点**在底栏「换源 / 净化」注释块里，随该块一起移除后即为不可达代码。

  // ---------- 沉浸听读（可选模式）：自绘章节窗口 + 句内高亮在文字内部 ----------
  /**
   * 沉浸听读**不跟 ReaderKit 的"页"走，而是跟章节走**：
   * 以当前朗读段为锚点连续渲染一串段落（窗口），朗读往前走窗口跟着走。
   * 这样①底部永远有字填满、②高亮永不丢失、③根本不需要翻页。
   */
  private immersiveActive(): boolean {
    return this.ttsPrefs.immersiveListen && this.ttsState !== 'stopped' && this.immReady;
  }

  private immNodeText(nodeIdx: number): string {
    const nodes = TtsEngine.currentNodeTexts();
    return nodes !== null && nodeIdx < nodes.length ? nodes[nodeIdx] : '';
  }

  /** 段的渲染文本（sg = [节点号, 起始, 结束]，可段中切断） */
  private immSegText(sg: number[]): string {
    return this.immNodeText(sg[0]).substring(sg[1], sg[2]);
  }

  /** 该段若属于"当前朗读段"，返回句子在**该段渲染文本**中的字符区间；否则 [-1,-1] */
  private immSegRange(sg: number[]): number[] {
    const seg = TtsEngine.currentSegment();
    if (seg === null || seg.nodeIndex !== sg[0]) {
      return [-1, -1];
    }
    const p = this.immSegText(sg);
    const s = this.ttsSegText.trim();
    if (p.length === 0 || s.length === 0) {
      return [-1, -1];
    }
    const guess = Math.max(0, Math.min(seg.charStart - sg[1], p.length));
    let at = p.indexOf(s, Math.max(0, guess - 6));
    if (at < 0) {
      at = p.indexOf(s);
    }
    if (at < 0) {
      at = guess;
    }
    return [at, Math.min(p.length, at + s.length)];
  }

  private immBefore(sg: number[]): string {
    const rg = this.immSegRange(sg);
    return rg[0] < 0 ? '' : this.immSegText(sg).substring(0, rg[0]);
  }

  private immHl(sg: number[]): string {
    const rg = this.immSegRange(sg);
    return rg[0] < 0 ? '' : this.immSegText(sg).substring(rg[0], rg[1]);
  }

  private immAfter(sg: number[]): string {
    const rg = this.immSegRange(sg);
    return rg[0] < 0 ? '' : this.immSegText(sg).substring(rg[1]);
  }

  /**
   * 沉浸听读层：整屏不透明底（连阅读器的页脚装饰一起盖掉）+ 章节窗口文字 + 句内高亮。
   * 整层（含每个子节点）HitTestMode.None ⇒ 翻页/菜单手势照旧穿透到下层阅读器。
   */
  @Builder
  ImmersiveListenLayer() {
    Stack() {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor(this.readerSetting.themeColor)
        .hitTestBehavior(HitTestMode.None)

      Column() {
        ForEach(this.immCurPage(), (sg: number[]) => {
          if (this.immSegRange(sg)[0] >= 0) {
            Text() {
              Span(this.immBefore(sg))
              Span(this.immHl(sg))
                .textBackgroundStyle({ color: 'rgba(0, 125, 255, 0.20)', radius: 4 })
              Span(this.immAfter(sg))
            }
            .fontSize(this.readerSetting.fontSize)
            .lineHeight(this.readerSetting.lineHeight * this.readerSetting.fontSize * this.effectiveLineMul())
            .textIndent(sg[1] === 0 ? this.readerSetting.fontSize * HL_INDENT_SLOTS : 0)
            .fontColor(this.readerSetting.fontColor)
            .fontFamily(this.readerSetting.fontName)
            .fontWeight(this.readerSetting.fontWeight)
            .width('100%')
            .hitTestBehavior(HitTestMode.None)
          } else {
            Text(this.immSegText(sg))
              .fontSize(this.readerSetting.fontSize)
              .lineHeight(this.readerSetting.lineHeight * this.readerSetting.fontSize * this.effectiveLineMul())
              .textIndent(sg[1] === 0 ? this.readerSetting.fontSize * HL_INDENT_SLOTS : 0)
              .fontColor(this.readerSetting.fontColor)
              .fontFamily(this.readerSetting.fontName)
              .fontWeight(this.readerSetting.fontWeight)
              .width('100%')
              .hitTestBehavior(HitTestMode.None)
          }
        }, (sg: number[]) => this.immSegRange(sg)[0] >= 0
          ? `imm-${sg[0]}-${sg[1]}-s${this.immSegSerial}`
          : `imm-${sg[0]}-${sg[1]}`)
      }
      .width(this.textAreaWidthVp())
      .height(this.immersiveBudgetPx() / this.densityVp())
      .clip(true)
      .position({
        x: this.textAreaLeftVp(),
        y: this.calibTopPx / this.densityVp()
      })
      .hitTestBehavior(HitTestMode.None)

      // 手势层：沉浸模式下**由我们接管**手势。
      // 下层阅读器虽然也在翻页，但它被不透明层盖住 ⇒ 用户看不到任何变化（这就是"点了没反应"）。
      // 左/右 = 窗口前后翻一屏；中间 = 打开听书面板。
      Row() {
        Column()
          .width('32%')
          .height('100%')
          .onClick(() => {
            Haptics.tap();
            this.immPage(-1);
          })
        Column()
          .width('36%')
          .height('100%')
          .onClick(() => {
            Haptics.tap();
            // 中间区域 = 打开听书面板
            this.openListenDialog();
          })
        Column()
          .width('32%')
          .height('100%')
          .onClick(() => {
            Haptics.tap();
            this.immPage(1);
          })
      }
      .width('100%')
      .height('100%')
      // ★ 内容保护内边距（2026-09-22，与听书面板同一处问题）：
      //   本 sheet 内容层有 `borderRadius` + `clip`（见 bindSheet options 与
      //   内容层样式），不设 padding 时贴边的列表项会被圆弧切掉。
      //   留出左右 16 / 底部 16，让内容全部落在圆角之内。
      .padding({ left: 16, right: 16, bottom: 16 })
    }
    .width('100%')
    .height('100%')
  }

  private densityVp(): number {
    const d = display.getDefaultDisplaySync();
    return d.densityPixels > 0 ? d.densityPixels : 1;
  }

  /** 文本区左边界（vp）——独立计算，不能依赖标定模式（calibLeft 只在标定模式下才被赋值） */
  private textAreaLeftVp(): number {
    const densityPx = this.densityVp();
    const vw = this.readerSetting.viewPortWidth > 0 ? this.readerSetting.viewPortWidth : this.windowWidth;
    const textW = Math.max(1, vw * this.calibWidthRatio);
    return Math.max(0, (vw - textW) / 2) / densityPx;
  }

  /** 沉浸听读可见高度（px）：**按整屏**算，不按阅读器自身高度。
   *  实测（2026-09-20）：阅读器的 web 视图只有 2150px，而窗口是 2848px；
   *  若用阅读器高度算预算，沉浸层只占上方 3/4，底部空出一大块（截图为证）。 */
  private immersiveBudgetPx(): number {
    const disp = display.getDefaultDisplaySync();
    const fullPx = disp.height > 0 ? disp.height : this.windowHeight;
    const reserveVp = 24 + this.bottomRectHeight + 46; // 浮条下距 + 浮条高度 + 2vp 余量
    return Math.max(120, fullPx - this.calibTopPx - reserveVp * this.densityVp());
  }

  /** 若当前朗读段落在可见区之下，需要把整层上移多少 px（对齐整行，避免半行被切） */
  private immersiveShiftPx(): number {
    const r = this.pageRange;
    const seg = TtsEngine.currentSegment();
    if (r === null || seg === null || this.measuredParas.length === 0) {
      return 0;
    }
    const curIdx = seg.nodeIndex - r.startNode;
    if (curIdx < 0) {
      return 0;
    }
    let bottom = 0;
    for (let k = 0; k <= curIdx && k < this.measuredParas.length; k++) {
      const ls = this.measuredParas[k];
      if (ls.length > 0) {
        const last = ls[ls.length - 1];
        bottom += last.top + last.height;
      }
    }
    const budget = this.immersiveBudgetPx();
    if (bottom <= budget) {
      return 0;
    }
    const linePx = Math.max(1, this.geom()[3]);
    return Math.ceil((bottom - budget) / linePx) * linePx;
  }

  /** 朗读迷你条：底部悬浮，当前句（随语速前滚）+ 播放/暂停（已翻走时变「从此页开始」）+ 展开面板 */
  @Builder
  TtsMiniBar() {
    Row({ space: 10 }) {
      // 主按钮：已手动翻走 ⇒ 一次点击就从当前页开始；否则 暂停/续播
      if (this.followSuspended) {
        SymbolGlyph($r('sys.symbol.play_fill'))
          .fontSize(22)
          .fontColor(['#FFFFFF'])
          .onClick(() => {
            Haptics.tap();
            this.miniBarPrimary();
          })
      } else if (this.ttsState === 'playing') {
        SymbolGlyph($r('sys.symbol.pause_fill'))
          .fontSize(22)
          .fontColor(['#FFFFFF'])
          .onClick(() => {
            Haptics.tap();
            this.miniBarPrimary();
          })
      } else {
        SymbolGlyph($r('sys.symbol.play_fill'))
          .fontSize(22)
          .fontColor(['#FFFFFF'])
          .onClick(() => {
            Haptics.tap();
            this.miniBarPrimary();
          })
      }

      if (this.followSuspended) {
        Text('从此页开始')
          .fontSize(11)
          .fontColor('rgba(255,255,255,0.85)')
          .backgroundColor('rgba(255,255,255,0.18)')
          .padding({ left: 6, right: 6, top: 2, bottom: 2 })
          .borderRadius(8)
          .onClick(() => {
            Haptics.tap();
            this.miniBarPrimary();
          })
      } else if (this.immPageIdx >= 0 && this.immPageIdx !== this.immAudioPage()) {
        // 沉浸模式手动翻屏后：一键回到正在朗读的位置
        Text('回到朗读')
          .fontSize(11)
          .fontColor('rgba(255,255,255,0.85)')
          .backgroundColor('rgba(255,255,255,0.18)')
          .padding({ left: 6, right: 6, top: 2, bottom: 2 })
          .borderRadius(8)
          .onClick(() => {
            Haptics.tap();
            this.immBackToAudio();
          })
      }

      // 当前句：横向 Scroll + 按句内字符进度自动前滚
      Scroll(this.miniScroller) {
        Text(this.ttsSegText.length > 0 ? this.ttsSegText : '正在朗读')
          .fontSize(13)
          .fontColor('#FFFFFF')
          .maxLines(1)
          .onAreaChange((_o: Area, n: Area) => {
            const w = Number(n.width);
            if (Number.isFinite(w) && Math.abs(w - this.miniTextW) > 0.5) {
              this.miniTextW = w;
            }
          })
      }
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.None)
      .layoutWeight(1)
      .onAreaChange((_o: Area, n: Area) => {
        const w = Number(n.width);
        if (Number.isFinite(w) && Math.abs(w - this.miniViewW) > 0.5) {
          this.miniViewW = w;
        }
      })
      .onClick(() => {
        Haptics.tap();
        // 点迷你条 → 打开听书面板
        this.openListenDialog();
      })

      // 「从本页」：从当前正在看的这一页开始读（原箭头位置，改为大一点的文字按钮，更好点）
      Text('从本页')
        .fontSize(11)
        .fontColor('rgba(255,255,255,0.9)')
        .padding({ left: 8, right: 8, top: 4, bottom: 4 })
        .borderRadius(10)
        .backgroundColor('rgba(255,255,255,0.18)')
        .onClick(() => {
          Haptics.tap();
          this.playFromCurrentPage();
        })

      // 退出听书：停止朗读 → 沉浸层消失，回到普通阅读模式
      SymbolGlyph($r('sys.symbol.xmark'))
        .fontSize(16)
        .fontColor(['rgba(255,255,255,0.85)'])
        .onClick(() => {
          Haptics.tap();
          this.exitListening();
        })
    }
    .padding({ left: 16, right: 16, top: 10, bottom: 10 })
    .borderRadius(24)
    // ── 2026-09-23 用户第二轮要求：「听书悬浮窗**恢复之前版本**（纯蓝），
    //    再加点高光/阴影之类的质感就行」──────────────────────────────────────
    // 上一版做的"磨砂蓝"（半透明 + 强模糊）用户不要了 ⇒ 恢复原来的实蓝 0.88；
    // 质感改用**阴影 + 边缘高光**表达（不再改底色与模糊）：
    //   · 蓝色投影：让悬浮条"浮"在正文之上
    //   · 0.5vp 淡白描边：模拟材质边缘的那道高光
    .backgroundColor(this.colorMode == 0 ? 'rgba(0, 110, 235, 0.88)' : 'rgba(0, 125, 255, 0.88)')
    .border({ width: 0.5, color: 'rgba(255, 255, 255, 0.35)' })
    .shadow({ radius: 18, color: 'rgba(0, 96, 220, 0.42)', offsetX: 0, offsetY: 5 })
    .width('86%')
    .position({ bottom: 24 + this.bottomRectHeight, left: '7%' })
    // ── 迷你条的出入场（2026-09-23 新增，弹簧为主）─────────────────────────────
    // 它由 `if (this.ttsState !== 'stopped')` 控制显隐 ⇒ 加转场即可；
    // 用**透明度 + 8vp 位移**（都是 transform/opacity，符合官方《动画帧率优化》
    // 「使用图形变换属性…不是直接修改布局属性」）。
    .transition(TransitionEffect.asymmetric(
      TransitionEffect.opacity(0).combine(TransitionEffect.translate({ y: 12 })),
      TransitionEffect.opacity(0)
    ).animation(UiMotion.transitionParam()))
  }

  // `DownloadDialog()` / `LayoutMoreDialog()` 两个 @Builder 已于 2026-09-21 删除 ——
  // 前者唯一调用点在顶栏「下载」注释块里、且 `DownloadSettingDialog` 是假下载；
  // 后者全工程 `grep "this.LayoutMoreDialog()"` **零命中**（唯一调用点在另一个页面 ReaderPage2）。

  /**
   * 去掉页面过渡动画，加快阅读器的页面访问速度
   */
  pageTransition() {
    PageTransitionEnter({ duration: 0, curve: Curve.Sharp });
    PageTransitionExit({ duration: 0, curve: Curve.Sharp });
  }

  /**
   * 跳转到指定的章节
   *
   * @param catalogItem 书籍目录节点
   */
  private async jumpToCatalogItem(catalogItem: bookParser.CatalogItem) {
    // 入口判空（2026-09-26）：滑块/上下章在目录未就绪时可能拿到 undefined item，
    // 直接走到 getResourceItemByCatalog 会读 undefined.resourceFile 二次崩溃。
    if (catalogItem === undefined || catalogItem === null) {
      this.getUIContext().getPromptAction().showToast({ message: '章节信息异常，请重新进入本书' });
      return;
    }
    // 根据目录项获取章节的索引
    const resourceIndex = this.getResourceItemByCatalog(catalogItem).index;
    // 跳转到指定章节。
    // ⚠️ 改走 `startPlayAt()`：`startPlay` 返回 Promise，官方声明会抛 BusinessError
    // （如 `1016910001 Invalid spine item`，见
    // `@hms.core.readerservice.readerComponent.d.ets`），直接调用会产生**未捕获的 rejection**。
    // `startPlayAt()` 是工程内已有的带 `.catch` 封装（精确定位流程同款），行为等价、只多一条日志。
    // 【待验证/未改】匹配不上时 `getResourceItemByCatalog()`（本文件末尾）会**静默**回退
    // `spineList[0]`（第 1 章）⇒ 点第 300 章可能跳到第 1 章且无提示。
    // 这属于行为变更，需用户确认后再改（见审计报告）。
    this.startPlayAt(resourceIndex, '');
    // 朗读中手动跳章：朗读跟随阅读
    if (TtsEngine.getState() !== 'stopped') {
      TtsEngine.seekToChapter(resourceIndex);
    }
  }

  /**
   * 点书签 → 跳到该位置并关闭弹窗。
   *
   * 复用现成的**精确跳转链路**：目录号 →（`getResourceItemByCatalog`）→ 正文号 →
   * `requestLocate(spine, node, char, silent)`（自带 `startPlay` + 超时翻页逼近兜底）。
   * 与「我的 → 书签」点击走的是同一套坐标、同一条链路，保证两处行为一致。
   *
   * 由 `ReaderCatalogDialog` 的 `onPickBookmark` 回调进来（书签列表本身也由弹窗自己加载）。
   * ⚠️ 关窗放在**这里**（而不是回调方）：`item` 不存在时上面会 `return`（早退、只弹 toast），
   *    改造前就是这个语义 —— 早退时弹窗**不关**。
   */
  private jumpToBookmark(row: BookmarkRow): void {
    let idx = row.chapterIndex ?? 0
    let pos = row.chapterPos ?? 0
    // ── 电脑端书签（chapterIndex/chapterPos = -1，坐标系未知，审计 H3/H6）──────────
    // 网页端的章号是它自己的切分口径，原样当目录下标会**跳到错误的章**甚至越界
    // （`:6313` 旧实现）；现在改按 `chapterName`（网页传的是该章首段正文）做标题匹配。
    if (idx < 0) {
      idx = this.catalogIndexByTitle(String(row.chapterName ?? ''))
      pos = 0
      if (idx < 0) {
        this.getUIContext().getPromptAction().showToast({
          message: '这条书签来自电脑端，手机端未能匹配到章节'
        })
        return
      }
    }
    const item = this.CatalogList.getData(idx)
    if (item === undefined || item === null) {
      this.getUIContext().getPromptAction().showToast({ message: '章节已不存在' })
      return
    }
    const spine = this.getResourceItemByCatalog(item).index
    hilog.info(0x0000, 'testTag', 'bmJump(dialog): catalog=%{public}d → spine=%{public}d node=%{public}d',
      idx, spine, pos)
    this.readerCatalogDialog?.close()
    this.requestLocate(spine, pos, 0, false)
  }

  /**
   * 根据目录项获取章节位置信息
   *
   * @param catalogItem 书籍目录节点
   * @returns 返回找到的章节位置信息或默认的空章节位置信息
   */
  private getResourceItemByCatalog(catalogItem: bookParser.CatalogItem): bookParser.SpineItem {
    // 获取目录项中的内容文件引用，如果没有则默认为空字符串
    let resourceFile = catalogItem.resourceFile || '';

    // 获取默认处理程序中的书脊内容列表，如果没有则默认为空数组
    let spineList: bookParser.SpineItem[] = this.BookHandler?.getSpineList() || []

    // 过滤书脊内容列表，找出href与内容文件引用匹配的章节位置信息
    let resourceItemArr = spineList.filter(item => item.href === resourceFile);

    // 如果找到了匹配的章节位置信息，则返回第一个匹配的章节位置信息
    if (resourceItemArr.length > 0) {
      hilog.info(0x0000, 'testTag', 'getResourceItemByCatalog get resource ', resourceItemArr[0]);
      let resourceItem = resourceItemArr[0];
      return resourceItem;
      // 如果没有找到匹配的章节位置信息，但书脊内容列表有项，则返回书脊内容列表的第一项
    } else if (spineList.length > 0) {
      hilog.info(0x0000, 'testTag', 'getResourceItemByCatalog get resource in resourceList', spineList[0]);
      return spineList[0];
      // 如果书脊内容列表为空，则返回一个空的章节位置信息对象
    } else {
      hilog.info(0x0000, 'testTag', 'getResourceItemByCatalog get resource in escape');
      return {
        idRef: '',
        index: 0,
        href: '',
        properties: ''
      };
    }
  }
}
