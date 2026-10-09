/**
 * 朗读控制面板（唯一调用点：`ReaderPage3.openListenDialog()` 拉起的 `ReaderListenDialog`
 * —— 2026-09-23 起是 `@CustomDialog`，此前是 `bindSheet`）。
 * 对应 PC 版 ColorTxt 的 VoiceReadToolbar + SettingsVoiceReadPanel：
 * 播放控制、单/多角色、AI 男女声识别（含接口配置）、音色选择、语速/音调/音量/
 * 句末/句中停顿、引号风格、睡眠定时（章节数/时长）、本章进度跳转。
 * 顶部文本显示器可点击：回到阅读进度并收起面板；右上角"完成"同样先回正文。
 */
import { TtsEngine } from '../../tts/TtsEngine';
import { TtsPrefs, saveTtsPrefs, ALL_QUOTE_STYLES, QUOTE_STYLE_LABELS } from '../../tts/TtsPrefs';
import { EDGE_VOICES, voiceLabel, EdgeVoice } from '../../tts/EdgeVoices';
// ── 双引擎（2026-09-25）：本地引擎（Core Speech Kit）参数面板适配 ─────────────
// 音色（person）、语速（localRate）为本地专属；音调本地引擎无官方参数键 ⇒ 隐藏；
// 音量/句末停顿/句中停顿两套共用（本地停顿经 [pN] 文本标记实现，语义一致）。
import { LOCAL_VOICES, localVoiceLabel } from '../../tts/LocalVoices';
import {
  listLocalVoices, downloadLocalVoice, LocalVoiceRow, mergeDownloadedRows
} from '../../tts/LocalTtsClient';
import { ListenUnlock } from '../../common/utils/ListenUnlock';
// ── AI 听书（2026-10-09 新增）：用户自接入 TTS 的配置面板 ─────────────────────
import { AiProviderMeta, AiTtsConfig, AiVoiceOption, AiCancelToken, aiErrorText
} from '../../tts/ai/AiTtsTypes';
import { aiConfigReady, aiListVoices, aiProviderMetaList } from '../../tts/ai/AiTtsProviders';
import { aiVoiceLabel, aiVoiceOptionsFor } from '../../tts/ai/AiTtsVoices';
import { aiCatalogAgeText, aiCatalogStale, loadAiCatalog, saveAiCatalog
} from '../../tts/ai/AiVoiceCatalog';
import { AiProfile, applyAiProfile, parseAiProfiles, removeAiProfile, serializeAiProfiles,
  snapshotAiProfile, upsertAiProfile } from '../../tts/ai/AiProfile';
import { DEFAULT_SPEAK_FILTER_TEXT } from '../../tts/SpeakFilter';
import { audio } from '@kit.AudioKit';
import vibrator from '@ohos.vibrator';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
// ── 全局震动反馈（2026-09-25 新增：hapticTick 的总开关守卫）──────────────────
import { Haptics } from '../../common/utils/Haptics';
// 材质：面板底色用 MaterialColumnModifier（"让出背景"，材质走弹窗 options）；
// 面板内滑条**不设材质**（用户选 A：材质优先 —— 与"滑条光效"互斥，官方禁止材质嵌套）
import ImmersiveMaterialUtil, { MaterialColumnModifier } from '../../common/utils/ImmersiveMaterialUtil';
import UiMotion from '../../common/utils/UiMotion';

/** 面板滑杆定义（避免 @Builder 传函数参数的严格模式问题） */
interface SliderDef {
  key: string;   // rate | localRate | pitch | volume | pauseSentenceMs | pauseCommaMs
  label: string;
  min: number;
  max: number;
  step: number;
  unit: string;
}

interface ChipDef {
  label: string;
  value: number;
}

/** Edge 引擎滑杆（语速/音调/音量/句末停顿/句中停顿）—— SSML prosody + PCM 级插入 */
const TTS_SLIDERS_EDGE: SliderDef[] = [
  { key: 'rate', label: '语速', min: 0.5, max: 2.0, step: 0.1, unit: 'x' },
  { key: 'pitch', label: '音调', min: 0.5, max: 2.0, step: 0.1, unit: 'x' },
  { key: 'volume', label: '音量', min: 0, max: 1.0, step: 0.05, unit: '' },
  { key: 'pauseSentenceMs', label: '句末停顿', min: 0, max: 3000, step: 100, unit: 'ms' },
  { key: 'pauseCommaMs', label: '句中停顿', min: 0, max: 1800, step: 60, unit: 'ms' }
];

/**
 * 本地引擎滑杆：语速（extraParams<'speed'>）、音量（共用，PCM 增益）、句末/句中停顿
 * （官方文本标记 [pN] 注入，语义与 Edge 一致）。音调：SDK extraParams 无 pitch 键
 * （接口头注释提及但无文档键名/取值）⇒ 本地面板不渲染，避免无效参数。
 */
const TTS_SLIDERS_LOCAL: SliderDef[] = [
  { key: 'localRate', label: '语速', min: 0.5, max: 2.0, step: 0.1, unit: 'x' },
  { key: 'volume', label: '音量', min: 0, max: 1.0, step: 0.05, unit: '' },
  { key: 'pauseSentenceMs', label: '句末停顿', min: 0, max: 3000, step: 100, unit: 'ms' },
  { key: 'pauseCommaMs', label: '句中停顿', min: 0, max: 1800, step: 60, unit: 'ms' }
];

/**
 * AI 引擎滑杆：**只渲染真正生效的两项**（方案 §13.2 的三条 UI 规则）。
 *  · 语速：由 provider 映射进请求体（OpenAI 兼容走 speed），本工程口径 1.0=原速；
 *    面板沿用 0.5~2.0 的既有档位，provider 内部再按厂商范围 clamp（0.25~4.0）。
 *  · 音量：播放端 PCM 增益，**与是否有词级时间戳无关**（`applyPauses` 在无停顿点时
 *    也会调 `applyVolume`，证据 `PauseSplicer.ets:255-261`）⇒ AI 模式恒可用。
 * 不渲染：音调（OpenAI 兼容无此参数）、句末/句中停顿（无词级时间戳，方案 §6.3）。
 */
const TTS_SLIDERS_AI: SliderDef[] = [
  { key: 'rate', label: '语速', min: 0.5, max: 2.0, step: 0.1, unit: 'x' },
  { key: 'volume', label: '音量', min: 0, max: 1.0, step: 0.05, unit: '' }
];

/**
 * AI 引擎但**该服务商不支持语速**时（如阿里通义：参考实现根本不传 rate）
 * ⇒ 只渲染音量。依据：审查发现的"假控件"——滑杆能拖但请求里没有该参数。
 * 对齐参考项目的条件渲染（`SettingsVoiceReadPanel.vue:906-911` 的同类做法）。
 */
const TTS_SLIDERS_AI_NO_RATE: SliderDef[] = [
  { key: 'volume', label: '音量', min: 0, max: 1.0, step: 0.05, unit: '' }
];

const SLEEP_MINUTES: ChipDef[] = [  { label: '关', value: 0 },
  { label: '15分钟', value: 15 },
  { label: '30分钟', value: 30 },
  { label: '60分钟', value: 60 },
  { label: '90分钟', value: 90 }
];

const SLEEP_CHAPTERS: ChipDef[] = [
  { label: '关', value: 0 },
  { label: '1章', value: 1 },
  { label: '2章', value: 2 },
  { label: '3章', value: 3 },
  { label: '5章', value: 5 }
];

/**
 * 朗读文本框的**固定槽位高度**（vp）。
 *
 * ## 为什么需要它
 * 面板现在是 `@CustomDialog`（`ReaderListenDialog`）**两段高度**里的收起档：
 * `42% × 屏高`（原 `bindSheet` 的 `detents: ['42%','92%']` 第一个），
 * **半屏 = 固定 42% 高度**。面板 `Column().height('100%')` 内，`Scroll().layoutWeight(1)`
 * 只能拿"剩余空间"。文本框此前自适应高度（`maxLines(4)`）——文字一多就从 1 行涨到 4 行，
 * 顶部区域随之变高、`Scroll` 被压扁，滚动区首行的「本章」进度滑块被挤掉/卡住。
 *
 * ## 空间账（真机屏高 843.85vp）
 * ```
 * 半屏 42%            ≈ 354vp
 * 减面板内边距 12+16   = 326vp  ← 可用
 * 播放中顶部固定项：顶栏~24 + 章节~40 + 播放控制~40 + 停止朗读~20 + 分隔线~1 = 125vp
 * 6 个 Column 间距 ×14 = 84vp
 * ⇒ Scroll 剩余 = 326 − 125 − 84 − 文本框 = 117 − 文本框
 * ```
 * 而「本章」滑块本身约 34vp。所以：
 * | 文本框 | Scroll 剩余 | 滑块 |
 * |---|---|---|
 * | 1 行 ≈ 44 | 73 | 可见（旧行为，随文字长度漂移） |
 * | **2 行 = 64（本值）** | **53** | **可见且位置恒定** ✅ |
 * | 3 行 ≈ 84 | 33 | 被切 |
 * | 4 行 ≈ 104 | 13 | 完全被切（用户报告的故障态） |
 *
 * ⇒ 取 **2 行**：既能保证滑块可见且不再漂移，又不会把 Scroll 压没。
 * 若日后要显示更多行，必须同时把「停止朗读」挪出固定区（挪进顶栏可省 ~34vp），
 * 否则会把滑块再次挤掉。
 *
 * 取值依据：`fontSize(14)` 一行约 20vp；2 行 = 40vp；上下内边距 12+12 = 24vp；合计 64vp。
 * 改字号时请同步。
 */
const SEG_TEXT_SLOT_H: number = 64;
/** 文本框显示的**最大行数**，必须与 `SEG_TEXT_SLOT_H` 配套（见上表） */
const SEG_TEXT_MAX_LINES: number = 2;

@Component
export struct TtsControlPanel {
  // ★ D3 功耗门禁（2026-10-07）：`isShowListen` 变化时启停面板的 5s 刷新器。
  //   面板是「建一次」的 @CustomDialog 内容（见 ReaderListenDialog 头注释），关闭弹窗时
  //   `aboutToDisappear` **不一定触发** ⇒ 旧实现的 5s `setInterval` 会在面板关闭后继续跑
  //   （每 5s 唤醒主线程 + 改 `@State`），与官方低功耗口径「减少唤醒次数」相悖。
  @Link @Watch('onShowListenChanged') isShowListen: boolean;
  @Link prefs: TtsPrefs;
  @Prop ttsState: string = 'stopped';     // 'stopped' | 'playing' | 'paused'
  @Prop chapterTitle: string = '';
  @Prop segIndex: number = 0;
  @Prop segTotal: number = 0;
  @Prop segText: string = '';
  @Prop colorMode: number = 1;
  /**
   * 是否显示「睡眠定时」段（2026-09-22 新增）。
   *
   * 阅读页的内嵌听书面板传 `false` —— 该面板高度只需到"播放控件结束"为止，
   * 带上定时会出现"半截定时"（用户原话：「现在**定时显示一半**，不太美观」）。
   * 默认 `true`：不传该参数的老调用点行为完全不变（一键回退）。
   */
  @Prop showSleepTimer: boolean = true;
  onStart: () => void = (): void => {};
  onSeekChapter: (delta: number) => void = (_delta: number): void => {};
  /** 回到当前朗读处的正文位置（文本显示器/完成按钮触发） */
  onBackToReader: () => void = (): void => {};
  /**
   * 打开睡眠定时弹窗（2026-10-07：定时入口迁入本面板顶栏，居中）。
   * 页面侧做**父子弹窗协调**：本面板（父）暂收 → 定时弹窗（子）打开 → 子关父回。
   */
  onOpenSleepTimer: () => void = (): void => {};
  @State voiceSlot: number = 0;           // 0=旁白 1=对白 2=男生 3=女生
  @State showVoices: boolean = false;
  /**
   * 音色区**为哪个引擎配音色**的显式选择（2026-10-10 三修，用户反馈驱动）。
   * 取值：`'auto'`（跟随当前生效引擎）/ `'local'`（华为本地）/ `'ai'` / `'edge'`。
   *
   * 为什么必须显式：用户两次反馈"音色选择还是华为 tts 的"。隐式规则（跟随生效引擎）
   * 在"AI 配好了但开关没开"、"只想先给 AI 配音色"等场景必然让人困惑。
   * ⇒ 给一个来源选择器，"我在给谁配音色"一眼可见、随时可切。
   */
  @State voiceSourceExplicit: string = 'auto';
  // ── 本地引擎音色枚举/下载（2026-09-25，SDK @since 19 的 listVoices/downloadVoice）──
  @State localRows: LocalVoiceRow[] = [];  // 动态音色表（权威）；空=未加载/查询失败
  @State localVoiceQueryFailed: boolean = false; // 查询失败 ⇒ 回退静态 LOCAL_VOICES
  @State dlPerson: number = -1;            // 正在下载的音色（-1=无）
  @State dlProgress: string = '0%';        // 下载进度文案（服务端字符串口径）
  @State localHint: string = '';           // 音色区一行提示（查询中/下载失败原因等）
  @State showAiConfig: boolean = false;
  @State sleepMin: number = 0;
  @State sleepChap: number = 0;
  @State dragSeg: number = -1;            // 滑块拖动中的预览段下标（-1=未拖动）
  // ---------- D2 修复：AI 接口设置改为「草稿 + 显式保存 / 清空」 ----------
  // 旧实现只在 .onChange 里改内存、只在 .onSubmit（回车）里 commitPrefs，
  // 用户填完直接点「完成」或划走 sheet ⇒ 当场能用但**没落盘**，重启 App 全丢。
  @State aiBaseUrlDraft: string = '';
  @State aiApiKeyDraft: string = '';
  @State aiModelDraft: string = '';
  @State aiDirty: boolean = false;
  @State aiHint: string = '';
  // ---------- AI 听书（用户自接入 TTS，2026-10-09）----------
  // 与上面「AI 男女声」是**两套配置**：上面填对话大模型，下面填语音合成。
  @State showAiTts: boolean = false;        // 折叠「AI 语音」块
  @State showAiAdvanced: boolean = false;   // 折叠「高级（附加请求体/头）」
  @State aiVoiceSlot: number = 0;           // 0=旁白/单音色 1=对白 2=男声 3=女生
  @State aiTtsBaseUrlDraft: string = '';
  @State aiTtsApiKeyDraft: string = '';
  @State aiTtsModelDraft: string = '';
  @State aiFormatDraft: string = 'mp3';
  @State aiInstructionsDraft: string = '';
  @State aiExtraBodyDraft: string = '';
  @State aiExtraHeadersDraft: string = '';
  // ⚠️ 音色**不用草稿**（2026-10-10 修正「AI 开关与 AI 男女声冲突」）：
  //    音色只保留**一处**编辑（展开档「音色」区），直接落 prefs —— 与本地/Edge 既有行为一致；
  //    AI 也走同一条路（applyVoice → applyAiVoiceToPrefs）。此前 AI 音色用的是草稿
  //    且藏在「AI 语音」块里，造成"两处音色、两种提交语义"的冲突。
  @State aiVoiceCustomDraft: string = '';   // 手填音色 id（AI 引擎；本工程允许手填）
  // AI 音色清单：从服务商拉取后缓存到 Preferences（见 AiVoiceCatalog.ets）
  @State aiCatalogVoices: AiVoiceOption[] = [];
  @State aiVoiceFetching: boolean = false;
  @State aiCatalogInfo: string = '';
  // AI 配置方案（见 tts/ai/AiProfile.ets）
  @State aiProfiles: AiProfile[] = [];
  @State aiProfileNameDraft: string = '';
  // 朗读过滤（见 tts/SpeakFilter.ets）
  @State showFilterRules: boolean = false;
  @State speakFilterDraft: string = '';
  @State speakFilterDirty: boolean = false;
  @State speakFilterHint: string = '';
  @State aiTtsDirty: boolean = false;
  @State aiTtsHint: string = '';
  // 试听状态机：0=空闲 1=合成中 2=播放中（与参考项目的 previewPhase 语义一致，
  // 但文案与试听文本都是本工程自写，见方案 §14.3「表达类内容自己写」）
  @State aiPreviewPhase: number = 0;
  // ---------- D3 修复：睡眠定时回读 + 剩余量 ----------
  @State sleepStatus: string = '';
  /**
   * 面板高度**下限 / 上限**（vp），由调用方给（只有调用方知道屏幕高）。
   *
   * ── 为什么要有这两个（2026-09-23 用户要求）────────────────────────────────
   * 用户原话：「听书设置了两种比例…但是**在小比例中，我们总会出现内容被卡住，
   *   或者说在容器中溢出**，我们就没有智能方法吗？或者设置一个**浮动比例，根据内容
   *   进行高低调节**，比如说第一个比例 40% 那么就改成 **40%-50%**」。
   * 根因：面板根节点原来是 `.height('100%')`（撑满调用方给的固定高度）。
   *   听书弹窗收起档给的是固定的 42%，而面板内部固定项会随状态变多
   *   （展开"音色"、"AI 接口配置"等）⇒ `Scroll().layoutWeight(1)` 被挤到 0 ⇒ 内容被切。
   * ⇒ 改成**内容自适应 + 上下限**：
   *   · 内容比下限矮 ⇒ 取**下限**（面板不会缩成一条，观感与旧版一致）
   *   · 内容在上限之内 ⇒ 取**内容高度**（自动长高，不再切内容）★ 这就是"浮动比例"
   *   · 内容超过上限 ⇒ 取**上限**，多出来的交给内部 `Scroll` 滚动
   */
  @Prop panelMinHeight: number = 0;
  @Prop panelMaxHeight: number = 0;
  /**
   * **收起档（小比例）只渲染"核心行"**（2026-09-23 用户设计，原文）：
   *   「我们知道小比例下应该显示什么了…**直接定死，就是渲染这些内容**，
   *     并且这个弹窗的大小是**根据内容进行高低**的」
   * 核心行 = 未播放时的「方案」+「沉浸听读」，播放中的「本章 + 滑块 + 段百分比」。
   * 其余（音色 / AI 男女声 / 语速音量停顿 / 对白引号）只在展开档渲染
   * ⇒ 收起档内容刚好等于面板高度，**没有巨型空底边、也不用滚动**。
   */
  @Prop compactMode: boolean = false;

  /**
   * **布局探针**（2026-09-23 临时诊断，用于解决"面板高度不对"的问题）。
   *
   * 为什么要有它：听书面板高度连续两轮没调对（收起档底部大空边 / 展开档少一行）。
   * 我查了官方 `layoutWeight` 原文（`component/common.d.ts:17447-17475`），它**只定义了
   * "父容器尺寸确定时"的分配规则**，对"父容器高度自适应"的情况**没有定义**
   * ⇒ 再靠推理就是猜。故按项目规则先取证：把面板根 / 滚动区 / 滚动内容三处的高度打出来，
   * 真机复现后看数字，谁高谁矮一目了然。
   * 日志过滤关键字：`ttsLayout`
   */
  private probe(tag: string, area: Area): void {
    hilog.info(0x0000, 'ttsLayout',
      '%{public}s h=%{public}d w=%{public}d (compact=%{public}s min=%{public}d max=%{public}d)',
      tag, Number(area.height), Number(area.width),
      String(this.compactMode), this.panelMinHeight, this.panelMaxHeight);
  }
  private sleepTicker: number = -1;
  /**
   * 面板底色（材质优先）。调用方（`ReaderListenDialog`）已通过
   * `CustomDialogControllerOptions.systemMaterial` 提供材质 ⇒ 传 `true` 让出背景：
   * 材质可用时**不设任何背景属性**，不可用时落回实底纯色（一键回退）。
   * 2026-09-23 用户拍板选 **A：材质优先** ⇒ 面板要真材质，面板内滑条**不设材质**。
   */
  private surface: MaterialColumnModifier = new MaterialColumnModifier('#1F1F1F', true);

  aboutToAppear(): void {
    // 底色兜底值随日夜模式（材质可用时用不到它）
    this.surface = new MaterialColumnModifier(
      this.colorMode == 0 ? '#1F1F1F' : 'rgba(248, 249, 250, 1)', true);
    // D2：进入面板时把**已保存**的接口配置填进草稿（下次进入直接显示之前的数据）
    this.aiBaseUrlDraft = this.prefs.aiBaseUrl;
    this.aiApiKeyDraft = this.prefs.aiApiKey;
    this.aiModelDraft = this.prefs.aiModel;
    this.aiDirty = false;
    this.aiHint = '';
    // AI 听书：把已保存的配置填进草稿（与上面 D2 同款做法，2026-10-09）
    this.fillAiTtsDrafts();
    this.refreshSilentMode(); // #3：进入面板先探一次静音状态
    // D3：回读引擎里的真实定时状态（旧实现只显示本地 @State，重开面板必显示「关」）
    this.syncSleepFromEngine();
    // D3 功耗门禁：只有面板**正在显示**时才起 5s 刷新器（见 isShowListen 注释）
    this.startSleepTicker();
  }

  aboutToDisappear(): void {
    this.stopSleepTicker();
    // 面板关闭：停掉可能还在响的 AI 试听（否则关窗后继续出声）
    TtsEngine.stopAiPreview();
  }

  /** 面板显示/隐藏切换 ⇒ 启停 5s 刷新器（隐藏时不刷新，避免无效唤醒） */
  private onShowListenChanged(): void {
    if (this.isShowListen) {
      this.syncSleepFromEngine(); // 补一次，避免显示的是几秒前的旧文案
      this.startSleepTicker();
    } else {
      this.stopSleepTicker();
    }
  }

  /** 起 5s 刷新器（幂等；面板隐藏时不起） */
  private startSleepTicker(): void {
    if (this.sleepTicker !== -1 || !this.isShowListen) {
      return;
    }
    this.sleepTicker = setInterval((): void => {
      this.syncSleepFromEngine();
    }, 5000);
  }

  /** 停 5s 刷新器（幂等） */
  private stopSleepTicker(): void {
    if (this.sleepTicker !== -1) {
      clearInterval(this.sleepTicker);
      this.sleepTicker = -1;
    }
  }

  /** D3：把引擎的定时状态同步到面板（档位高亮 + 剩余量文案） */
  private syncSleepFromEngine(): void {
    const reqChap = TtsEngine.getSleepChaptersReq();
    const reqMin = TtsEngine.getSleepMinutesReq();
    this.sleepChap = reqChap;
    this.sleepMin = reqMin;
    const stopMs = TtsEngine.getSleepStopMs();
    const stopChap = TtsEngine.getSleepStopChapter();
    const parts: string[] = [];
    if (stopMs >= 0) {
      // sleepStopMs 是**绝对截止时刻**（墙钟，2026-10-07 起），暂停也走表
      const leftMs = Math.max(0, stopMs - Date.now());
      const m = Math.floor(leftMs / 60000);
      const s = Math.floor((leftMs % 60000) / 1000);
      parts.push(`剩余 ${m} 分 ${s} 秒`);
    }
    if (stopChap >= 0) {
      const left = Math.max(0, stopChap - TtsEngine.currentChapter());
      parts.push(`读到第 ${left} 章末`);
    }
    this.sleepStatus = parts.length > 0 ? parts.join(' · ') : '未设定时';
  }

  /** D2：保存接口设置（落盘 + 更新引擎） */
  private saveAiConfig(): void {
    this.prefs.aiBaseUrl = this.aiBaseUrlDraft.trim();
    this.prefs.aiApiKey = this.aiApiKeyDraft.trim();
    this.prefs.aiModel = this.aiModelDraft.trim();
    this.commitPrefs();
    this.aiDirty = false;
    this.aiHint = '已保存';
  }

  /** D2：清空接口设置（含已存盘的数据） */
  private clearAiConfig(): void {
    this.aiBaseUrlDraft = '';
    this.aiApiKeyDraft = '';
    this.aiModelDraft = '';
    this.prefs.aiBaseUrl = '';
    this.prefs.aiApiKey = '';
    this.prefs.aiModel = '';
    this.commitPrefs();
    this.aiDirty = false;
    this.aiHint = '已清空并删除已存数据';
  }

  /**
   * D4 修复：AI 男女声关闭时，把悬空的槽位归一到「对白」。
   * 旧实现：选中「女生」（voiceSlot=3）后关掉 AI ⇒ 男生/女生 chip 消失，
   * 但 voiceSlot 仍为 3，`currentVoiceForSlot()` / `applyVoice()` 仍指向 female 槽
   * ——界面无任何选中态，点音色却仍写进 female 槽。
   */
  private normalizeVoiceSlot(): void {
    if (this.prefs.scheme !== 'multi' || !this.prefs.aiSpeakerRecognitionEnabled) {
      if (this.voiceSlot > 1) {
        this.voiceSlot = 1;
      }
    }
  }

  // ══════════════════════════════════════════════════════════════════════════
  // AI 听书（用户自接入 TTS，2026-10-09）
  // 设计：docs/ai-voice-read-plan-2026-10-09.md §13.3 / §13.6.1
  // ══════════════════════════════════════════════════════════════════════════

  /** 当前服务商的能力位（面板据此条件渲染参数行） */
  private aiMeta(): AiProviderMeta | null {
    const list: AiProviderMeta[] = aiProviderMetaList();
    for (let i = 0; i < list.length; i++) {
      if (list[i].id === this.prefs.aiProviderId) {
        return list[i];
      }
    }
    return list.length > 0 ? list[0] : null;
  }

  /** 把草稿装成配置对象（给 aiConfigReady 判可用性） */
  private aiDraftConfig(): AiTtsConfig {
    const cfg: AiTtsConfig = {
      providerId: this.prefs.aiProviderId,
      baseUrl: this.aiTtsBaseUrlDraft,
      apiKey: this.aiTtsApiKeyDraft,
      model: this.aiTtsModelDraft,
      format: this.aiFormatDraft,
      instructions: this.aiInstructionsDraft,
      extraBody: this.aiExtraBodyDraft,
      extraHeaders: this.aiExtraHeadersDraft
    };
    return cfg;
  }

  /** 从**已保存**的 prefs 构造配置（= 引擎口径，与 TtsEngine.aiConfigFrom 同源） */
  private aiPrefsConfig(): AiTtsConfig {
    const cfg: AiTtsConfig = {
      providerId: this.prefs.aiProviderId,
      baseUrl: this.prefs.aiTtsBaseUrl,
      apiKey: this.prefs.aiTtsApiKey,
      model: this.prefs.aiTtsModel,
      format: this.prefs.aiFormat,
      instructions: this.prefs.aiInstructions,
      extraBody: this.prefs.aiExtraBody,
      extraHeaders: this.prefs.aiExtraHeaders
    };
    return cfg;
  }

  /**
   * **引擎口径**的"配置就绪"。
   *
   * 2026-10-10 修正（审查发现的"丢西瓜捡芝麻"型不一致）：原来这里读**草稿**，
   * 于是出现"面板显示 AI 音色列表 / 开关可以开，但引擎实际仍走本地"的假状态
   * —— 因为 `TtsEngine.activeEngineId()` 读的是**已保存**的 prefs。
   * 现在拆成两个口径：
   *   · 本函数 = 已保存（引擎行为、顶栏开关、试听 用）；
   *   · {@link aiDraftsReady} = 草稿（"正在配置"的展示用，例如音色区自动切 AI）。
   */
  private aiTtsReady(): boolean {
    return aiConfigReady(this.aiPrefsConfig());
  }

  /** **草稿口径**：用户填完但可能还没点【保存】（仅用于展示判断，不代表引擎已切换） */
  private aiDraftsReady(): boolean {
    return aiConfigReady(this.aiDraftConfig());
  }

  /**
   * Edge 是否已接管（解锁 + 用户选了 edge）。
   * 用户口径：「只要开启 edge，直接使用 edge 不允许切换，需要切换则手动去设置中先关闭」
   * ⇒ 此状态下 AI 开关**置灰**并给引导文案（与 TtsEngine.activeEngineId 的优先级同源）。
   */
  private aiEdgeTakeover(): boolean {
    return ListenUnlock.isUnlocked() && this.prefs.ttsEngine === 'edge';
  }

  /** 顶栏 AI 开关能否操作：① 必须处于停止态（暂停也算未停止）② Edge 未接管 */
  private aiSwitchEnabled(): boolean {
    return this.ttsState === 'stopped' && !this.aiEdgeTakeover();
  }

  /** 顶栏 AI 开关的当前值：Edge 接管时显示为"关"（实际走 Edge） */
  private aiSwitchOn(): boolean {
    if (this.aiEdgeTakeover()) {
      return false;
    }
    return this.prefs.aiTtsEnabled;
  }

  /** 顶栏开关切换（关→开前先校验配置；不满足则提示且**不落盘**，避免"开了没声"） */
  private toggleAiTts(value: boolean): void {
    if (!this.aiSwitchEnabled()) {
      return;
    }
    if (value && !this.aiTtsReady()) {
      this.showAiTts = true;
      // 区分两种"没就绪"：① 压根没填 → 去填；② 填了但没保存 → 去保存
      // （2026-10-10 口径修正：开关要求**已保存**的配置，与 TtsEngine 读 prefs 一致）
      this.aiTtsHint = this.aiDraftsReady()
        ? '请先点【保存】把配置落盘，再打开 AI 听书'
        : '请先填写接口地址与 API Key，再打开 AI 听书';
      this.prefs.aiTtsEnabled = false;
      this.commitPrefs();
      return;
    }
    this.prefs.aiTtsEnabled = value;
    this.commitPrefs();
    this.aiTtsHint = value ? '已切换到 AI 听书（下一段生效）' : '已切换回华为本地 TTS';
  }

  /** 进入面板时把已保存的 AI 配置填进草稿（与 D2 的 AI 男女声同款做法） */
  private fillAiTtsDrafts(): void {
    this.aiTtsBaseUrlDraft = this.prefs.aiTtsBaseUrl;
    this.aiTtsApiKeyDraft = this.prefs.aiTtsApiKey;
    this.aiTtsModelDraft = this.prefs.aiTtsModel;
    this.aiFormatDraft = this.prefs.aiFormat.length > 0 ? this.prefs.aiFormat : 'mp3';
    this.aiInstructionsDraft = this.prefs.aiInstructions;
    this.aiExtraBodyDraft = this.prefs.aiExtraBody;
    this.aiExtraHeadersDraft = this.prefs.aiExtraHeaders;
    this.aiTtsDirty = false;
    this.aiTtsHint = '';
    // 音色清单：从本地缓存回填（同步、不联网）
    this.reloadAiCatalog();
    this.reloadAiProfiles();
    // 朗读过滤规则草稿（已保存值优先；空则填默认，避免用户面对空白框）
    this.speakFilterDraft = this.prefs.speakFilterText.length > 0
      ? this.prefs.speakFilterText : DEFAULT_SPEAK_FILTER_TEXT;
  }

  /** 保存 AI 配置（显式保存：附加 JSON 先校验，非法则拒绝落盘并给原文） */
  private saveAiTtsConfig(): void {
    const body: string = this.aiExtraBodyDraft.trim();
    if (body.length > 0) {
      try {
        JSON.parse(body);
      } catch (e) {
        this.aiTtsHint = '附加请求体不是合法 JSON：' + aiErrorText(e);
        return;
      }
    }
    this.prefs.aiTtsBaseUrl = this.aiTtsBaseUrlDraft.trim();
    this.prefs.aiTtsApiKey = this.aiTtsApiKeyDraft.trim();
    this.prefs.aiTtsModel = this.aiTtsModelDraft.trim();
    this.prefs.aiFormat = this.aiFormatDraft;
    this.prefs.aiInstructions = this.aiInstructionsDraft.trim();
    this.prefs.aiExtraBody = this.aiExtraBodyDraft;
    this.prefs.aiExtraHeaders = this.aiExtraHeadersDraft;
    // 配置改了但开关开着却不满足条件 ⇒ 自动回落，避免"开着但走的是本地引擎"的假状态
    if (this.prefs.aiTtsEnabled && !aiConfigReady(this.aiPrefsConfig())) {
      this.prefs.aiTtsEnabled = false;
      this.aiTtsHint = '配置不完整，已自动关闭 AI 听书';
    } else {
      this.aiTtsHint = '已保存';
    }
    this.commitPrefs();
    this.aiTtsDirty = false;
    // 接口地址可能变了 ⇒ 清单指纹变化，重新回填
    this.reloadAiCatalog();
  }

  /** 清空 AI 配置（含已存盘数据；同时关掉开关） */
  private clearAiTtsConfig(): void {
    this.aiTtsBaseUrlDraft = '';
    this.aiTtsApiKeyDraft = '';
    this.aiTtsModelDraft = '';
    this.aiFormatDraft = 'mp3';
    this.aiInstructionsDraft = '';
    this.aiExtraBodyDraft = '';
    this.aiExtraHeadersDraft = '';
    this.prefs.aiTtsBaseUrl = '';
    this.prefs.aiTtsApiKey = '';
    this.prefs.aiTtsModel = '';
    this.prefs.aiFormat = 'mp3';
    this.prefs.aiInstructions = '';
    this.prefs.aiExtraBody = '';
    this.prefs.aiExtraHeaders = '';
    this.prefs.aiTtsEnabled = false;
    this.commitPrefs();
    this.aiTtsDirty = false;
    this.aiTtsHint = '已清空并关闭 AI 听书';
  }

  /** 当前槽位的 AI 音色（**直接读 prefs**，不再是草稿） */
  private aiVoiceForSlotFromPrefs(slot: number): string {
    if (this.prefs.scheme === 'single') {
      return this.prefs.aiSingleVoiceId;
    }
    if (slot === 1) {
      return this.prefs.aiDialogueVoiceId;
    }
    if (slot === 2) {
      return this.prefs.aiDialogueMaleVoiceId;
    }
    if (slot === 3) {
      return this.prefs.aiDialogueFemaleVoiceId;
    }
    return this.prefs.aiNarrationVoiceId;
  }

  /**
   * 写入选中的 AI 音色槽位（列表点选与手填共用）——**直接落盘**，
   * 与本地/Edge 的 `applyVoice` 语义一致：音色全工程**只此一处**编辑。
   */
  private applyAiVoiceToPrefs(id: string): void {
    const v: string = id.trim();
    if (v.length === 0) {
      return;
    }
    if (this.prefs.scheme === 'single') {
      this.prefs.aiSingleVoiceId = v;
    } else if (this.aiVoiceSlot === 1) {
      this.prefs.aiDialogueVoiceId = v;
    } else if (this.aiVoiceSlot === 2) {
      this.prefs.aiDialogueMaleVoiceId = v;
    } else if (this.aiVoiceSlot === 3) {
      this.prefs.aiDialogueFemaleVoiceId = v;
    } else {
      this.prefs.aiNarrationVoiceId = v;
    }
    this.commitPrefs();
    this.aiTtsHint = '音色已保存';
  }

  /**
   * 音色区是否按 **AI** 显示（2026-10-10 二次修正）。
   *
   * 上一版只用 `isAiEngine()`（= 开关已开且配置就绪）⇒ 造成死锁：
   * **要配 AI 音色就必须先打开 AI 开关，可没配音色又听不出男女声效果**（用户实测反馈：
   * 「音色里面还是华为 tts 的音色，而且 ai 男女声似乎没用」）。
   * ⇒ 改为：**当前生效是 AI** 或 **用户正在配置 AI（AI 块展开且配置已就绪）** 都显示 AI 音色。
   *    这样"填完接口地址与 Key（草稿即算就绪）→ 音色区自动切 AI → 配四个槽位"一气呵成。
   */
  private isAiVoiceUi(): boolean {
    if (this.isAiEngine()) {
      return true;
    }
    return this.showAiTts && this.aiDraftsReady();
  }

  /**
   * 音色区**当前在为哪个引擎配音色**（三修，2026-10-10）。
   *
   * 判定顺序：
   *  ① 用户显式选的来源（`voiceSourceExplicit`）优先，但做可用性校验
   *     （AI 未配置就忽略、Edge 未解锁就忽略）；
   *  ② 否则跟随"当前生效引擎"，或"正在展开配置 AI"（`isAiVoiceUi()`）。
   *
   * @returns `'ai'` | `'local'` | `'edge'`
   */
  private voiceKind(): string {
    if (this.voiceSourceExplicit === 'local') {
      return 'local';
    }
    if (this.voiceSourceExplicit === 'ai' && this.aiDraftsReady()) {
      return 'ai';
    }
    if (this.voiceSourceExplicit === 'edge' && !this.isLocal()) {
      return 'edge';
    }
    // ⚠️ 这里必须调 `isAiVoiceUi()`，**不能**调 `voiceKind()`（会自我递归 ⇒ 爆栈）。
    //    2026-10-10 踩过：一次批量替换把本行也换成了 `voiceKind()`。
    if (this.isAiVoiceUi()) {
      return 'ai';
    }
    return this.isLocal() ? 'local' : 'edge';
  }

  /** 音色来源的中文名（给用户一眼看清"我在给谁配音色"） */
  private voiceKindLabel(): string {
    const k: string = this.voiceKind();
    if (k === 'ai') {
      return 'AI 语音（服务商：' + this.prefs.aiProviderId + '）';
    }
    if (k === 'edge') {
      return 'Edge TTS';
    }
    return '华为本地 TTS';
  }

  /** 当前引擎是否是 AI（决定哪些参数行该渲染） */
  private isAiEngine(): boolean {
    if (this.isLocal() || this.prefs.ttsEngine === 'edge') {
      return false;
    }
    // 与 TtsEngine.activeEngineId 同口径：开关开着 **且** 配置就绪才算 AI 生效
    return this.prefs.aiTtsEnabled && this.aiTtsReady();
  }

  // ── 能力位读取（供 build() 条件渲染；避免在 build 里做类型断言）──────────────
  private aiMetaNeedsBaseUrl(): boolean {
    const m: AiProviderMeta | null = this.aiMeta();
    return m !== null && m.needsBaseUrl;
  }

  private aiMetaNeedsApiKey(): boolean {
    const m: AiProviderMeta | null = this.aiMeta();
    return m !== null && m.needsApiKey;
  }

  private aiMetaSupportsInstructions(): boolean {
    const m: AiProviderMeta | null = this.aiMeta();
    return m !== null && m.supportsInstructions;
  }

  /** 该服务商是否有「列音色」接口（决定 UI 是否显示「拉取音色」） */
  private aiMetaSupportsListVoices(): boolean {
    const m: AiProviderMeta | null = this.aiMeta();
    return m !== null && m.supportsListVoices;
  }

  /** 该服务商是否接受自然语言语气（决定 UI 是否显示「AI 语气」开关，防假控件） */
  private aiMetaSupportsEmotion(): boolean {
    const m: AiProviderMeta | null = this.aiMeta();
    return m !== null && m.supportsEmotion;
  }

  /**
   * 切换服务商时**自动重置四个音色槽位**（2026-10-10 用户拍板："需要自动重置"）。
   *
   * 为什么必须：不同厂商的音色 id **不通用**，留着上一家的 id 会被服务商
   * **静默回落**成同一个默认音色 —— 用户实测踩过（"AI 男女声似乎没用"，
   * 日志里 `role=zh-CN-YunxiNeural voice=onyx` 就是证据）。
   *
   * 策略：按该服务商建议值的**性别**挑：旁白/男声取第一个男声、对白取第二个男声、
   * 女生取第一个女声、单音色取第一条；挑不到就都指向第一条（保证不空）。
   */
  private resetAiVoiceSlotsForProvider(providerId: string): void {
    const list: AiVoiceOption[] = aiVoiceOptionsFor(providerId);
    if (list.length === 0) {
      return;
    }
    const males: string[] = [];
    const females: string[] = [];
    for (let i = 0; i < list.length; i++) {
      const g: string = list[i].gender;
      if (g === 'male') {
        males.push(list[i].id);
      } else if (g === 'female') {
        females.push(list[i].id);
      }
    }
    const first: string = list[0].id;
    const m0: string = males.length > 0 ? males[0] : first;
    const m1: string = males.length > 1 ? males[1] : m0;
    const f0: string = females.length > 0 ? females[0] : first;
    this.prefs.aiSingleVoiceId = first;
    this.prefs.aiNarrationVoiceId = m0;
    this.prefs.aiDialogueVoiceId = m1;
    this.prefs.aiDialogueMaleVoiceId = m0;
    this.prefs.aiDialogueFemaleVoiceId = f0;
    this.commitPrefs();
    hilog.info(0x0000, 'TtsPanel',
      'ai voice slots reset for %{public}s: single=%{public}s narration=%{public}s dialogue=%{public}s male=%{public}s female=%{public}s',
      providerId, first, m0, m1, m0, f0);
  }

  private aiMetaFormatOptions(): string[] {
    const m: AiProviderMeta | null = this.aiMeta();
    return m === null ? [] : m.formatOptions;
  }

  private aiMetaDesc(): string {
    const m: AiProviderMeta | null = this.aiMeta();
    return m === null ? '' : m.description;
  }

  /** 当前引擎该渲染哪些滑杆（抽成方法：ForEach 首参写三元表达式会触发"参数未被读取"的误报） */
  private sliderDefs(): SliderDef[] {
    if (this.isAiEngine()) {
      // 按**服务商能力位**裁剪：不支持语速的服务商不渲染语速行（防"假控件"，见常量注释）
      const m: AiProviderMeta | null = this.aiMeta();
      if (m !== null && !m.supportsRate) {
        return TTS_SLIDERS_AI_NO_RATE;
      }
      return TTS_SLIDERS_AI;
    }
    return this.isLocal() ? TTS_SLIDERS_LOCAL : TTS_SLIDERS_EDGE;
  }

  /** 内置建议音色（列表里没有的 id 也可以手填，见 aiVoiceCustomDraft） */
  private aiVoiceList(): AiVoiceOption[] {
    // 有服务商清单就用它（更权威、更新）；否则回落内置建议值
    if (this.aiCatalogVoices.length > 0) {
      return this.aiCatalogVoices;
    }
    return aiVoiceOptionsFor(this.prefs.aiProviderId);
  }

  // ── AI 配置方案（2026-10-10）─────────────────────────────────────────────
  // 只覆盖 AI 段（用户拍板）：小说/散文各一套音色、A/B 两个服务商不用重填。
  // 密钥按用户决定明文存本机、不加密、不上传。

  private reloadAiProfiles(): void {
    this.aiProfiles = parseAiProfiles(this.prefs.aiProfiles);
  }

  private persistAiProfiles(list: AiProfile[]): void {
    this.aiProfiles = list;
    this.prefs.aiProfiles = serializeAiProfiles(list);
    this.commitPrefs();
  }

  /** 当前设置是否就是某个方案（用于高亮；只比"连接四要素"，音色改动不算切换） */
  private isActiveAiProfile(p: AiProfile): boolean {
    return this.prefs.aiProviderId === p.providerId
      && this.aiTtsBaseUrlDraft.trim() === p.baseUrl
      && this.aiTtsApiKeyDraft === p.apiKey
      && this.aiTtsModelDraft.trim() === p.model;
  }

  private onSaveAiProfile(): void {
    const name: string = this.aiProfileNameDraft.trim();
    if (name.length === 0) {
      this.aiTtsHint = '请先填方案名';
      return;
    }
    // 快照的是**用户当前看到的值**（草稿），不要求先点【保存】——避免"存的不是看到的"
    const p: AiProfile = snapshotAiProfile('p' + Date.now(), name,
      this.prefs.aiProviderId, this.aiTtsBaseUrlDraft.trim(), this.aiTtsApiKeyDraft,
      this.aiTtsModelDraft.trim(), this.aiInstructionsDraft, this.prefs);
    this.persistAiProfiles(upsertAiProfile(this.aiProfiles, p));
    this.aiProfileNameDraft = '';
    this.aiTtsHint = '已保存方案「' + name + '」（含密钥，仅存本机）';
  }

  private onApplyAiProfile(p: AiProfile): void {
    applyAiProfile(this.prefs, p);
    this.commitPrefs();
    // 同步草稿，否则界面还显示旧值（"点了没反应"观感）
    this.fillAiTtsDrafts();
    this.reloadAiCatalog();
    this.aiTtsHint = '已套用方案「' + p.name + '」';
  }

  private onDeleteAiProfile(id: string): void {
    this.persistAiProfiles(removeAiProfile(this.aiProfiles, id));
    this.aiTtsHint = '已删除方案';
  }

  /** 从本地缓存回填音色清单（同步、不联网） */
  private reloadAiCatalog(): void {    const cfg: AiTtsConfig = this.aiDraftConfig();
    this.aiCatalogVoices = loadAiCatalog(cfg);
    const stale: boolean = aiCatalogStale(cfg);
    this.aiCatalogInfo = aiCatalogAgeText(cfg)
      + (this.aiCatalogVoices.length > 0 ? '（' + this.aiCatalogVoices.length + ' 个音色）' : '')
      + (stale && this.aiCatalogVoices.length > 0 ? ' · 建议刷新' : '');
  }

  /**
   * 拉取音色清单（**只在用户点击时联网**，符合"用户主动发起"的合规口径）。
   * 成功后落盘缓存；失败原样提示（不改动已有列表）。
   */
  private async onFetchAiVoices(): Promise<void> {
    if (this.aiVoiceFetching) {
      return;
    }
    const meta: AiProviderMeta | null = this.aiMeta();
    if (meta === null || !meta.supportsListVoices) {
      this.aiCatalogInfo = '该服务商没有「列音色」接口，请手填音色 id';
      return;
    }
    if (!this.aiDraftsReady()) {
      this.aiCatalogInfo = '请先填写接口地址与 API Key';
      return;
    }
    this.aiVoiceFetching = true;
    this.aiCatalogInfo = '拉取中…';
    const cfg: AiTtsConfig = this.aiDraftConfig();
    const token: AiCancelToken = { cancelled: false };
    try {
      const list: AiVoiceOption[] = await aiListVoices(cfg, token);
      if (list.length === 0) {
        this.aiCatalogInfo = '服务商返回空清单（可能该账号无可用音色）';
      } else {
        saveAiCatalog(cfg, list);
        this.reloadAiCatalog();
        this.aiCatalogInfo = '已更新：' + aiCatalogAgeText(cfg) + '（' + list.length + ' 个音色）';
      }
    } catch (e) {
      this.aiCatalogInfo = '拉取失败：' + aiErrorText(e);
    } finally {
      this.aiVoiceFetching = false;
    }
  }

  /** 槽位标题（单音色方案只有一个槽） */
  private aiSlotLabel(slot: number): string {
    if (this.prefs.scheme === 'single') {
      return '音色';
    }
    if (slot === 1) {
      return '对白';
    }
    if (slot === 2) {
      return '男生';
    }
    if (slot === 3) {
      return '女生';
    }
    return '旁白';
  }

  /** 当前槽位的音色是否被选中（列表打勾用） */
  private aiVoiceSelected(id: string): boolean {
    return this.aiVoiceForSlotFromPrefs(this.aiVoiceSlot) === id;
  }

  /** 当前槽位的音色展示文案 */
  private aiVoiceLabelForSlot(): string {
    return aiVoiceLabel(this.prefs.aiProviderId, this.aiVoiceForSlotFromPrefs(this.aiVoiceSlot));
  }

  /**
   * 检测「四个槽位撞名」并点名（2026-10-10 新增，防呆）。
   *
   * 由来：用户实测"AI 男女声似乎没用"，而日志证明分类是成功的（`classify ok items=44`）——
   * 真因是**四个槽位都回落成同一个音色**。撞名是最常见的前兆（例如默认值旁白=onyx、
   * 男生=onyx 就同名），所以这里直接算出来告诉他，比让他去猜日志快得多。
   * @returns 空串 = 没撞名
   */
  private aiVoiceCollisionHint(): string {
    if (this.prefs.scheme !== 'multi') {
      return '';
    }
    const names: string[] = ['旁白', '对白', '男生', '女生'];
    const vals: string[] = [
      this.prefs.aiNarrationVoiceId.trim(),
      this.prefs.aiDialogueVoiceId.trim(),
      this.prefs.aiDialogueMaleVoiceId.trim(),
      this.prefs.aiDialogueFemaleVoiceId.trim()
    ];
    const dup: string[] = [];
    for (let i = 0; i < vals.length; i++) {
      if (vals[i].length === 0) {
        continue;
      }
      for (let j = i + 1; j < vals.length; j++) {
        if (vals[i] === vals[j]) {
          dup.push(names[i] + '=' + names[j] + '（' + vals[i] + '）');
        }
      }
    }
    if (dup.length === 0) {
      return '';
    }
    return '⚠ 槽位撞名：' + dup.join('、') + ' —— 这几个角色会听出同一个声音。';
  }

  // ── 试听（2026-10-09，P0）────────────────────────────────────────────────
  /**
   * 试听文本：**本工程自写**（不照搬参考项目的示例台词，见方案 §14.3「表达类内容自己写」）。
   */
  private aiPreviewText(): string {
    return '这是一段试听文本，用来确认这个音色的语气、语速和停顿是否合适。';
  }

  /** 试听按钮点击：空闲⇒开始；合成中/播放中⇒停止 */
  private async onAiPreviewClick(): Promise<void> {
    if (this.aiPreviewPhase !== 0) {
      TtsEngine.stopAiPreview();
      this.aiPreviewPhase = 0;
      this.aiTtsHint = '已停止试听';
      return;
    }
    if (!this.aiTtsReady()) {
      this.aiTtsHint = '请先填写接口地址与 API Key（点【保存】后再试听）';
      return;
    }
    const voice: string = this.aiVoiceForSlotFromPrefs(this.aiVoiceSlot);
    if (voice.trim().length === 0) {
      this.aiTtsHint = '请先选择或填写音色';
      return;
    }
    this.aiPreviewPhase = 1;
    this.aiTtsHint = '合成中…（用已保存的配置与音色）';
    try {
      await TtsEngine.previewAiSpeech(this.aiPreviewText(), voice, (): void => {
        this.aiPreviewPhase = 2;
        this.aiTtsHint = '播放中…（再点一次可停止）';
      });
      if (this.aiPreviewPhase !== 0) {
        this.aiPreviewPhase = 0;
        this.aiTtsHint = '试听结束';
      }
    } catch (e) {
      this.aiPreviewPhase = 0;
      this.aiTtsHint = '试听失败：' + aiErrorText(e);
    }
  }

  private aiPreviewLabel(): string {
    if (this.aiPreviewPhase === 1) {
      return '合成中…';
    }
    if (this.aiPreviewPhase === 2) {
      return '停止';
    }
    return '试听';
  }

  /**
   * D1 修复：停止状态下「上一章 / 下一章 / 上一段 / 下一段」不可用。
   * 旧实现：这 4 个控件**没有任何状态守卫**，而它们的后端全都在 stopped 时直接 return
   *   （`ReaderPage3:1285 ttsSeekChapter` 首行 `if (getState()==='stopped') return;`；
   *    `TtsEngine:prevSegment/nextSegment` 同型），
   *   于是用户看到 4 个看着能点的按钮，点了**完全没反应、也无任何提示**。
   * 面板在停止状态是可打开的（顶部会显示"点击下方按钮开始朗读当前章节"），所以这个状态真实存在。
   * 与既有做法保持一致：进度滑块用 `ttsState !== 'stopped'`、停止按钮同。
   */
  private navEnabled(): boolean {
    return this.ttsState !== 'stopped';
  }

  /**
   * 主按钮的播放/暂停图标（2026-09-25 从 `$r(三元)` 挪出来）：
   * `$r()` 的参数必须是**字符串字面量**，否则 IDE 资源检查器报
   * 「Unknown resource source '…'」（静态解析不了三元表达式，误报，不影响编译/运行）。
   * 状态读取发生在 build 期间 ⇒ `ttsState` 变化时这里会重新求值，与原写法等价。
   */
  private playPauseIcon(): Resource {
    return this.ttsState === 'playing'
      ? $r('sys.symbol.pause_fill')
      : $r('sys.symbol.play_fill');
  }

  // ---------- #3 滑块震动反馈 ----------
  /** 静音模式缓存：true = 系统静音 ⇒ 滑块不震动 */
  private silentMode: boolean = false;
  private silentProbedAt: number = 0;
  private lastHapticAt: number = 0;

  /**
   * 刷新「静音模式」判定。
   *
   * **官方依据**（documentId `FAQ/硬件/传感器_Sensor_Service/关闭系统设置_使用vibrator模块设置的振动规则会失效/faqs-sensor-service-3`）：
   *   「Q：系统静音模式下调用 startVibration，设备未振动。
   *     A：检查 startVibration 接口中的 usage 参数值…usage 参数值为 unknown、touch、media、
   *        physicalFeedback、simulateReality 时，受**触感开关**管控。
   *        **在触感开关开启时，即使系统处于静音模式，也会振动。**」
   * ⇒ `usage='touch'` 本身**不会**因静音而不振，所以必须自己判静音并主动跳过。
   *
   * 判定接口：`AudioVolumeGroupManager.isMute(AudioVolumeType.RINGTONE)`
   *   —— SDK `@ohos.multimedia.audio.d.ts:4636`，`@since 9`，`@syscap ...Audio.Volume`，**无 @permission**；
   *   同步取管理器用 `getVolumeGroupManagerSync(groupId)`（同文件 `:4294`）。
   * 失败时**保持上一次判定**，绝不抛错影响 UI。
   */
  private refreshSilentMode(): void {
    const now = Date.now();
    if (now - this.silentProbedAt < 3000) {
      return;
    }
    this.silentProbedAt = now;
    try {
      const mgr = audio.getAudioManager().getVolumeManager().getVolumeGroupManagerSync(0);
      mgr.isMute(audio.AudioVolumeType.RINGTONE).then((m: boolean) => {
        this.silentMode = m;
      }).catch((_e: BusinessError) => {
        // 忽略：保持上一次判定
      });
    } catch (e) {
      // 忽略
    }
  }

  /** 滑块步进震动：静音跳过；80ms 内不重复（避免高频拖动的连续抖） */
  private hapticTick(): void {
    // ── 2026-09-25 全局震动方案接入（唯一改动，其余逐字保留）──────────────────
    // 用户要求震动开关管住全软件。本方法属"不可本地验证的听书链路已验证路径"
    //（文件头与 `HapticTick.ets` 的注释都约定过不动它的实现），所以只加**守卫**：
    // 设置页关掉震动反馈 / 强度调到 0 ⇒ 这里的滑块震动也停。
    // 自身的静音判定、80ms 节流、time/20ms 参数全部保持原样（真机验证过的手感）。
    // 回退：删掉下面这一行 return 即回到 2026-09-25 之前的行为。
    if (!Haptics.globallyEnabled()) {
      return;
    }
    this.refreshSilentMode();
    if (this.silentMode) {
      return;
    }
    const now = Date.now();
    if (now - this.lastHapticAt < 80) {
      return;
    }
    this.lastHapticAt = now;
    try {
      // 用「按指定时长触发」而非 effectId：官方 FAQ 示例即此写法，
      // 且无需担心预设效果 id 取值（SDK 注释仅列出 haptic.clock / haptic.effect / haptic.notice）。
      vibrator.startVibration(
        { type: 'time', duration: 20 },
        { id: 0, usage: 'touch' }
      ).catch((_e: BusinessError) => {
        // 忽略：设备不支持或被系统拦截
      });
    } catch (e) {
      // 忽略
    }
  }

  fg(): string {
    return this.colorMode == 0 ? 'rgba(248, 249, 250, 1)' : 'rgba(19, 19, 19, 1.00)';
  }

  fgSub(): string {
    return this.colorMode == 0 ? 'rgba(248, 249, 250, 0.65)' : 'rgba(19, 19, 19, 0.65)';
  }

  chipBg(): string {
    return this.colorMode == 0 ? 'rgba(255, 255, 255, 0.08)' : 'rgba(0, 0, 0, 0.06)';
  }

  accent(): string {
    return '#007DFF';
  }

  private commitPrefs(): void {
    saveTtsPrefs(this.prefs);
    TtsEngine.updateConfig(this.prefs);
  }

  /** 当前生效引擎（与 TtsEngine.activeEngineId 同口径：edge 需解锁，否则一律本地） */
  private isLocal(): boolean {
    return !(this.prefs.ttsEngine === 'edge' && ListenUnlock.isUnlocked());
  }

  private currentVoiceForSlot(): string {
    // ⚠️ AI 必须先判，且**必须在 isLocal() 之前**（2026-10-10 修正）：
    //    isLocal() 只区分 local/edge，对 AI 会误判成"本地" ⇒ 音色区显示华为音色、
    //    选中态打在 local person 上。这正是用户报的「AI 开关与 AI 男女声冲突」的根因。
    if (this.voiceKind() === 'ai') {
      return this.aiVoiceForSlotFromPrefs(this.voiceSlot);
    }
    if (this.voiceKind() === 'local') {
      return String(this.currentLocalPersonForSlot());
    }
    if (this.prefs.scheme === 'single') {
      return this.prefs.singleVoiceId;
    }
    if (this.voiceSlot === 1) {
      return this.prefs.dialogueVoiceId;
    }
    if (this.voiceSlot === 2) {
      return this.prefs.dialogueMaleVoiceId;
    }
    if (this.voiceSlot === 3) {
      return this.prefs.dialogueFemaleVoiceId;
    }
    return this.prefs.narrationVoiceId;
  }

  /** 本地引擎：当前槽位的音色 person（槽位语义与 Edge 一致：旁白/对白/男生/女生） */
  private currentLocalPersonForSlot(): number {
    if (this.prefs.scheme === 'single') {
      return this.prefs.localSinglePerson;
    }
    if (this.voiceSlot === 1) {
      return this.prefs.localDialogueMalePerson;
    }
    if (this.voiceSlot === 2) {
      return this.prefs.localDialogueMalePerson;
    }
    if (this.voiceSlot === 3) {
      return this.prefs.localDialogueFemalePerson;
    }
    return this.prefs.localNarrationPerson;
  }

  private applyVoice(id: string): void {
    // 同上：AI 先判，否则点 AI 音色会被 `Number(id)` 变成 NaN 写进 local person
    if (this.voiceKind() === 'ai') {
      this.applyAiVoiceToPrefs(id);
      return;
    }
    if (this.voiceKind() === 'local') {
      this.applyLocalVoice(Math.floor(Number(id)));
      return;
    }
    if (this.prefs.scheme === 'single') {
      this.prefs.singleVoiceId = id;
    } else if (this.voiceSlot === 1) {
      this.prefs.dialogueVoiceId = id;
    } else if (this.voiceSlot === 2) {
      this.prefs.dialogueMaleVoiceId = id;
    } else if (this.voiceSlot === 3) {
      this.prefs.dialogueFemaleVoiceId = id;
    } else {
      this.prefs.narrationVoiceId = id;
    }
    this.commitPrefs();
  }

  private applyLocalVoice(person: number): void {
    if (this.prefs.scheme === 'single') {
      this.prefs.localSinglePerson = person;
    } else if (this.voiceSlot === 1) {
      this.prefs.localDialogueMalePerson = person;
    } else if (this.voiceSlot === 2) {
      this.prefs.localDialogueMalePerson = person;
    } else if (this.voiceSlot === 3) {
      this.prefs.localDialogueFemalePerson = person;
    } else {
      this.prefs.localNarrationPerson = person;
    }
    this.commitPrefs();
  }

  /** 加载本地音色动态表（listVoices 权威枚举，@since 19）；失败回退静态表并提示 */
  private loadLocalVoices(): void {
    if (this.localRows.length > 0 || this.localVoiceQueryFailed) {
      return;
    }
    this.localHint = '音色查询中…';
    listLocalVoices().then((rows: LocalVoiceRow[]): void => {
      // 与"已下载记忆名单"合并：已下载的钉为可用、枚举缺席的保留显示（不被覆盖）
      this.localRows = mergeDownloadedRows(rows);
      this.localHint = this.localRows.length === 0 ? '设备未枚举到可用音色' : '';
    }).catch((e: Error): void => {
      this.localVoiceQueryFailed = true;
      this.localHint = '音色枚举不可用，已显示内置音色';
      hilog.warn(0x0000, 'TtsPanel', 'listVoices fail: %{public}s', e.message);
    });
  }

  /** 渲染行：动态表优先；查询失败回退静态表（无状态徽标、不可下载，与旧行为一致） */
  private localRenderRows(): LocalVoiceRow[] {
    if (this.localRows.length > 0) {
      return this.localRows;
    }
    const rows: LocalVoiceRow[] = [];
    for (let i = 0; i < LOCAL_VOICES.length; i++) {
      const v = LOCAL_VOICES[i];
      rows.push({
        person: v.person, language: v.lang, style: '', gender: v.gender,
        label: v.label, description: v.description, status: ''
      });
    }
    return rows;
  }

  /** 下载音色：进度经 DownloadResponse 'progress' 事件回传；完成后自动选用并刷新状态 */
  private startVoiceDownload(row: LocalVoiceRow): void {
    if (this.dlPerson !== -1) {
      return; // 已有下载进行中（串行，避免并发下载冲突）
    }
    this.dlPerson = row.person;
    this.dlProgress = '0%';
    this.localHint = `正在下载「${row.label}」…`;
    downloadLocalVoice(row, (p: string): void => {
      this.dlProgress = p;
    }).then((): void => {
      this.dlPerson = -1;
      this.applyLocalVoice(row.person); // 下载完成自动选用
      this.localHint = `「${row.label}」下载完成（系统级存储，永久可用）`;
      // 重新枚举刷新状态徽标
      this.localRows = [];
      this.localVoiceQueryFailed = false;
      this.loadLocalVoices();
    }).catch((e: Error): void => {
      this.dlPerson = -1;
      this.localHint = e.message;
    });
  }

  private onVoiceRowClick(row: LocalVoiceRow): void {
    Haptics.tap();
    if (row.status === 'INSTALLED' || row.status === '') {
      // 已下载（或状态未知的老行为）：直接选用
      this.applyLocalVoice(row.person);
      return;
    }
    if (row.status === 'GA') {
      this.startVoiceDownload(row);
      return;
    }
    this.localHint = `「${row.label}」当前不可用`;
  }

  private sliderValue(key: string): number {
    if (key === 'localRate') {
      return this.prefs.localRate;
    }
    if (key === 'rate') {
      return this.prefs.rate;
    }
    if (key === 'pitch') {
      return this.prefs.pitch;
    }
    if (key === 'volume') {
      return this.prefs.volume;
    }
    if (key === 'pauseSentenceMs') {
      return this.prefs.pauseSentenceMs;
    }
    return this.prefs.pauseCommaMs;
  }

  private applySlider(key: string, v: number): void {
    // 全局震动方案（2026-09-25 用户反馈补齐）：语速/音调/音量/句末/句中滑条跨档反馈
    // （Haptics.tick 内部有 80ms 节流，拖动时"一档一跳"）
    Haptics.tick();
    if (key === 'localRate') {
      this.prefs.localRate = Math.round(v * 10) / 10;
    } else if (key === 'rate') {
      this.prefs.rate = Math.round(v * 10) / 10;
    } else if (key === 'pitch') {
      this.prefs.pitch = Math.round(v * 10) / 10;
    } else if (key === 'volume') {
      this.prefs.volume = Math.round(v * 100) / 100;
    } else if (key === 'pauseSentenceMs') {
      this.prefs.pauseSentenceMs = Math.round(v);
    } else {
      this.prefs.pauseCommaMs = Math.round(v);
    }
    this.commitPrefs();
  }

  private toggleQuoteStyle(idx: number): void {
    const at = this.prefs.quoteStyles.indexOf(idx);
    const next: number[] = [];
    if (at >= 0) {
      if (this.prefs.quoteStyles.length <= 1) {
        return; // 至少保留一种
      }
      for (let k = 0; k < this.prefs.quoteStyles.length; k++) {
        if (this.prefs.quoteStyles[k] !== idx) {
          next.push(this.prefs.quoteStyles[k]);
        }
      }
    } else {
      for (let k = 0; k < this.prefs.quoteStyles.length; k++) {
        next.push(this.prefs.quoteStyles[k]);
      }
      next.push(idx);
      next.sort((a: number, b: number): number => a - b);
    }
    this.prefs.quoteStyles = next;
    this.commitPrefs();
  }

  private backAndClose(): void {
    this.onBackToReader();
    this.isShowListen = false;
  }

  private voiceSummary(): string {
    if (this.voiceKind() === 'ai') {
      const p: string = this.prefs.aiProviderId;
      if (this.prefs.scheme === 'multi') {
        const ai2: string = this.prefs.aiSpeakerRecognitionEnabled
          ? ` · 男 ${aiVoiceLabel(p, this.prefs.aiDialogueMaleVoiceId)} / 女 ${aiVoiceLabel(p, this.prefs.aiDialogueFemaleVoiceId)}`
          : '';
        return `AI 旁白 ${aiVoiceLabel(p, this.prefs.aiNarrationVoiceId)} · 对白 ${aiVoiceLabel(p, this.prefs.aiDialogueVoiceId)}${ai2}`;
      }
      return `AI ${aiVoiceLabel(p, this.prefs.aiSingleVoiceId)}`;
    }
    if (this.voiceKind() === 'local') {
      if (this.prefs.scheme === 'multi') {
        const ai = this.prefs.aiSpeakerRecognitionEnabled
          ? ` · 男 ${localVoiceLabel(this.prefs.localDialogueMalePerson)} / 女 ${localVoiceLabel(this.prefs.localDialogueFemalePerson)}`
          : '';
        return `旁白 ${localVoiceLabel(this.prefs.localNarrationPerson)} · 对白 ${localVoiceLabel(this.prefs.localDialogueMalePerson)}${ai}`;
      }
      return localVoiceLabel(this.prefs.localSinglePerson);
    }
    if (this.prefs.scheme === 'multi') {
      const ai = this.prefs.aiSpeakerRecognitionEnabled
        ? ` · 男 ${voiceLabel(this.prefs.dialogueMaleVoiceId)} / 女 ${voiceLabel(this.prefs.dialogueFemaleVoiceId)}`
        : '';
      return `旁白 ${voiceLabel(this.prefs.narrationVoiceId)} · 对白 ${voiceLabel(this.prefs.dialogueVoiceId)}${ai}`;
    }
    return voiceLabel(this.prefs.singleVoiceId);
  }

  /**
   * 当前朗读文本（点击回到正文）。
   * 抽成 @Builder 是因为它要被用在两个分支里（播放=固定槽位 / 未播放=自适应），
   * 避免复制两份导致日后改一处漏一处。
   */
  @Builder
  SegTextBox() {
    Text(this.segText.length > 0 ? this.segText : '点击下方按钮开始朗读当前章节')
      .fontSize(14)
      .fontColor(this.fgSub())
      .maxLines(SEG_TEXT_MAX_LINES)
      .textOverflow({ overflow: TextOverflow.Ellipsis })
      .width('100%')
      .padding(12)
      .borderRadius(12)
      .backgroundColor(this.chipBg())
      .onClick(() => {
        Haptics.tap();
        this.backAndClose();
      })
  }

  build() {
    Column({ space: 14 }) {
      // 顶栏（2026-10-07：定时入口从阅读器顶栏迁入本面板；2026-10-09：改 4 元素）
      // 布局：`[朗读] [闹钟(左移)] —— [AI 听书 开关] [完成]`
      // 证据：用户 2026-10-09 口径「将现有的闹钟图标左移，然后右侧放一个开关，
      //   默认关闭，打开为 ai 听书」「听书状态下，这个按钮不可用，只有停止听书才可以切换」
      Row() {
        Text('朗读')
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.fg())
        // ── 睡眠定时入口（左移：紧贴标题；子窗口，点它拉起定时弹窗）──
        // 空心/实心 = 是否已设定时（口径 sleepChap>0 || sleepMin>0，与 syncSleepFromEngine 同源）
        SymbolGlyph((this.sleepChap > 0 || this.sleepMin > 0)
          ? $r('sys.symbol.alarm_fill') : $r('sys.symbol.alarm'))
          .fontSize(20)
          .fontColor([this.accent()])
          .margin({ left: 10 })
          .onClick(() => {
            Haptics.tap();
            this.onOpenSleepTimer()
          })
          .clickEffect(UiMotion.CLICK)
        Blank()
        // ── AI 听书开关（2026-10-09 新增）──
        // 只在 ttsState==='stopped' 时可切（暂停也算未停止）；Edge 接管时置灰并提示。
        Text('AI 听书')
          .fontSize(14)
          .fontColor(this.aiSwitchEnabled() ? this.fg() : this.fgSub())
          .opacity(this.aiSwitchEnabled() ? 1 : 0.4)
        Toggle({ type: ToggleType.Switch, isOn: this.aiSwitchOn() })
          .selectedColor(this.accent())
          .enabled(this.aiSwitchEnabled())
          .opacity(this.aiSwitchEnabled() ? 1 : 0.4)
          .onChange((value: boolean) => {
            Haptics.tap();
            this.toggleAiTts(value);
          })
        Text('完成')
          .fontSize(16)
          .fontColor(this.accent())
          .margin({ left: 12 })
          .onClick(() => {
            Haptics.tap();
            this.backAndClose();
          })
      }.width('100%')

      // 章节与进度
      Column({ space: 4 }) {
        Text(this.chapterTitle.length > 0 ? this.chapterTitle : '未开始')
          .fontSize(15)
          .fontColor(this.fg())
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(this.segTotal > 0 ? `本章 ${this.segIndex + 1}/${this.segTotal} 段` : ' ')
          .fontSize(12)
          .fontColor(this.fgSub())
      }.width('100%')

      // 当前朗读文本（点击回到正文）
      // ── 布局修复：文本框固定槽位、底部对齐 ──────────────────────────────
      // 播放时用固定高度槽位并把文字贴底 ⇒ 文字从下往上生长，
      // 顶部区域总高恒定，下方「本章」进度滑块位置不再被文字长度推挤。
      // 未播放时保持原样（自适应一行），因为那时显示效果本来就是对的。
      if (this.ttsState !== 'stopped') {
        Column() {
          this.SegTextBox()
        }
        .width('100%')
        .height(SEG_TEXT_SLOT_H)
        .justifyContent(FlexAlign.End)
      } else {
        this.SegTextBox()
      }

      // 播放控制
      // D1：停止状态下 4 个跳转控件置灰且不可点（此前可点但静默无反应）
      Row() {
        Text('上一章')
          .fontSize(14)
          .fontColor(this.navEnabled() ? this.fg() : this.fgSub())
          .opacity(this.navEnabled() ? 1 : 0.4)
          .enabled(this.navEnabled())
          .onClick(() => {
            Haptics.tap();
            this.onSeekChapter(-1);
          })

        Blank()

        SymbolGlyph($r('sys.symbol.backward_end_fill'))
          .fontSize(24)
          .fontColor([this.navEnabled() ? this.fg() : this.fgSub()])
          .opacity(this.navEnabled() ? 1 : 0.4)
          .enabled(this.navEnabled())
          .onClick(() => {
            Haptics.tap();
            TtsEngine.prevSegment();
          })

        Blank()

        // 主按钮：开始 / 播放 / 暂停
        // 2026-09-21 动效升级：原来是三个 if/else 分支各画一个 SymbolGlyph，
        // 切状态时是**节点销毁重建**（直接跳变）。现在合并成**一个** SymbolGlyph，
        // 图标由 `ttsState` 三元派生 + `ReplaceSymbolEffect` ⇒ 播放/暂停之间会有形变过渡。
        // ⚠️ 行为完全不变：三个分支各自的 onClick 动作（pause / resume / onStart）原样保留。
        // 动效依据见 ReaderPage3 书签图标处的 SDK 原文注释。
        // 2026-09-25：三元从 `$r()` 里挪到 `playPauseIcon()` —— IDE 资源检查器要求
        // `$r()` 的参数是**字符串字面量**，塞三元它会报
        // 「Unknown resource source 'playing'」（把表达式里的状态值当成了资源名）；
        // 运行时 `$r(动态串)` 本来就能解析，这只是静态检查的口子。
        SymbolGlyph(this.playPauseIcon())
          .fontSize(40)
          .fontColor([this.accent()])
          .symbolEffect(new ReplaceSymbolEffect(),
            this.ttsState === 'playing' ? 1 : (this.ttsState === 'paused' ? 2 : 0))
          .onClick(() => {
            Haptics.tap();
            if (this.ttsState === 'playing') {
              TtsEngine.pause();
            } else if (this.ttsState === 'paused') {
              TtsEngine.resume();
            } else {
              this.onStart();
            }
          })

        Blank()

        SymbolGlyph($r('sys.symbol.forward_end_fill'))
          .fontSize(24)
          .fontColor([this.navEnabled() ? this.fg() : this.fgSub()])
          .opacity(this.navEnabled() ? 1 : 0.4)
          .enabled(this.navEnabled())
          .onClick(() => {
            Haptics.tap();
            TtsEngine.nextSegment();
          })

        Blank()

        Text('下一章')
          .fontSize(14)
          .fontColor(this.navEnabled() ? this.fg() : this.fgSub())
          .opacity(this.navEnabled() ? 1 : 0.4)
          .enabled(this.navEnabled())
          .onClick(() => {
            Haptics.tap();
            this.onSeekChapter(1);
          })
      }
      .width('100%')

      // 「停止朗读」这一行**已删**（2026-09-23 用户原话：「这四个字删掉，没意义」）。
      // 需要停止时：播放中再点一次播放键即暂停；退出听书/退回正文仍会停（见 ReaderPage3）。

      Divider().color(this.chipBg())

      Scroll() {
        Column({ space: 14 }) {
          // 本章进度（朗读中可拖动跳段；拖动时实时显示段数）
          if (this.ttsState !== 'stopped' && this.segTotal > 1) {
            Row({ space: 12 }) {
              Text('本章').fontSize(14).fontColor(this.fg()).width(70)
              Slider({
                value: this.dragSeg >= 0 ? this.dragSeg : this.segIndex,
                min: 0,
                max: this.segTotal - 1,
                step: 1,
                style: SliderStyle.InSet
              })
                .selectedColor(this.accent())
                .blockSize({ width: 22, height: 22 })
                // ⚠️ 2026-09-23 用户拍板选 **A：材质优先** ⇒ 本面板（挂在有真材质的弹窗里）
                //   滑条**不设材质**。原因（官方原文 + 真机实测）：
                //   官方《沉浸光感功耗优化》「#### 避免材质嵌套 — …**视觉上又相互干扰**。
                //   同一子树中只需在**最外层**设置一次沉浸式系统材质，内层节点不应再设置。」
                //   真机实测：弹窗层有材质 + 内层滑条也设 ⇒ 滑条按住是**黑色圆形蒙版**。
                //   （阅读页/设置页那些滑条有光效，是因为那边**没有材质祖先**。）
                .layoutWeight(1)
                .onChange((v: number, mode: SliderChangeMode) => {
                  Haptics.tick();
                  // #3：每跨一个段位给一次震动反馈（静音模式下 hapticTick 内部会自动跳过）
                  if (Math.round(v) !== this.dragSeg) {
                    this.hapticTick();
                  }
                  if (mode === SliderChangeMode.End) {
                    this.dragSeg = -1;
                    TtsEngine.seekToSegment(Math.round(v));
                  } else {
                    this.dragSeg = Math.round(v);
                  }
                })
              Text(this.dragSeg >= 0 ? `第 ${this.dragSeg + 1} 段` : `${this.segIndex + 1}/${this.segTotal}`)
                .fontSize(12)
                .fontColor(this.dragSeg >= 0 ? this.accent() : this.fgSub())
                .width(60)
                .textAlign(TextAlign.End)
            }.width('100%')
          }

          // 睡眠定时：按时长 / 按章节数（档位自动换行，始终限制在面板宽度内）
          // #4：按用户使用习惯，紧跟在「本章」进度滑块下面（原来在最底部）
          //
          // ★ 可隐藏（2026-09-22 用户要求）：「听书这个 sheet 再低一点，
          //   保留到播放下面没东西为止，现在定时显示一半，不太美观」。
          //   阅读页内嵌面板传 `showSleepTimer: false`，高度即可收到播放控件结束处。
          if (this.showSleepTimer) {
          Column({ space: 8 }) {
            Column({ space: 6 }) {
              Text('定时（时长）').fontSize(13).fontColor(this.fg()).width('100%')
              Flex({ wrap: FlexWrap.Wrap }) {
                ForEach(SLEEP_MINUTES, (c: ChipDef) => {
                  Text(c.label)
                    .fontSize(13)
                    .fontColor(this.sleepMin === c.value ? this.accent() : this.fgSub())
                    .padding({ left: 10, right: 10, top: 5, bottom: 5 })
                    .margin({ right: 8, bottom: 6 })
                    .borderRadius(14)
                    .backgroundColor(this.sleepMin === c.value ? this.chipBg() : Color.Transparent)
                    .onClick(() => {
                      Haptics.tap();
                      this.sleepMin = c.value;
                      TtsEngine.setSleepTimer(this.sleepChap, this.sleepMin);
                      this.syncSleepFromEngine(); // D3：立即回读，显示真实档位与剩余量
                    })
                }, (c: ChipDef) => c.label)
              }.width('100%')
            }.width('100%')

            Column({ space: 6 }) {
              Text('定时（章节）').fontSize(13).fontColor(this.fg()).width('100%')
              Flex({ wrap: FlexWrap.Wrap }) {
                ForEach(SLEEP_CHAPTERS, (c: ChipDef) => {
                  Text(c.label)
                    .fontSize(13)
                    .fontColor(this.sleepChap === c.value ? this.accent() : this.fgSub())
                    .padding({ left: 10, right: 10, top: 5, bottom: 5 })
                    .margin({ right: 8, bottom: 6 })
                    .borderRadius(14)
                    .backgroundColor(this.sleepChap === c.value ? this.chipBg() : Color.Transparent)
                    .onClick(() => {
                      Haptics.tap();
                      this.sleepChap = c.value;
                      TtsEngine.setSleepTimer(this.sleepChap, this.sleepMin);
                      this.syncSleepFromEngine(); // D3：立即回读
                    })
                }, (c: ChipDef) => c.label)
              }.width('100%')
              // D3：实时剩余量（每 5 秒刷新）——旧实现完全看不到"还剩多久"
              Row({ space: 6 }) {
                Text(this.sleepStatus)
                  .fontSize(12)
                  .fontColor(this.sleepStatus === '未设定时' ? this.fgSub() : this.accent())
                  .layoutWeight(1)
                  .maxLines(2)
                if (this.sleepStatus !== '未设定时') {
                  Text('取消定时')
                    .fontSize(12)
                    .fontColor(this.fgSub())
                    .onClick(() => {
                      Haptics.tap();
                      this.sleepMin = 0;
                      this.sleepChap = 0;
                      TtsEngine.setSleepTimer(0, 0);
                      this.syncSleepFromEngine();
                    })
                }
              }.width('100%')
              Text('读完定时章节数 / 播满时长后自动停止（两者可同时设，任一先到即停）')
                .fontSize(11)
                .fontColor(this.fgSub())
                .width('100%')
                .maxLines(2)
            }.width('100%')
          }
          .width('100%')
          .padding(10)
          .borderRadius(10)
          .backgroundColor(this.chipBg())
          }

          // 方案切换 + 跟随开关
          //
          // ★ 2026-09-22 用户反馈：「跟随翻页后面的**开关有一半被压住了**，能否缩进
          //   方案、单音色、多角色中间的间距，然后这一行底部增加一个间距，不用太多」。
          //   根因是**这一行横向空间不够**（不是垂直问题）：
          //   「方案 + 单音色 + 多角色 + 跟随翻页 + Switch」总宽超出可用宽度，
          //   Switch 被挤到边界外、再被面板圆角裁掉一半。
          //   ⇒ 缩两处横向占用：行间距 10→6、两个 chip 的左右内边距 12→8
          //     （chip 仅在选中态有底色，收到 8 仍不局促）。
          //   另按用户要求给这一行加一点底部间距（6vp）。
          Row({ space: 6 }) {
            Text('方案').fontSize(14).fontColor(this.fg())
            Text('单音色')
              .fontSize(14)
              .fontColor(this.prefs.scheme === 'single' ? this.accent() : this.fgSub())
              .padding({ left: 8, right: 8, top: 6, bottom: 6 })
              .borderRadius(16)
              .backgroundColor(this.prefs.scheme === 'single' ? this.chipBg() : Color.Transparent)
              .onClick(() => {
                Haptics.tap();
                if (this.prefs.scheme !== 'single') {
                  this.prefs.scheme = 'single';
                  this.commitPrefs();
                  this.normalizeVoiceSlot(); // D4：单音色方案下槽位无意义，归一
                }
              })
            Text('多角色')
              .fontSize(14)
              .fontColor(this.prefs.scheme === 'multi' ? this.accent() : this.fgSub())
              .padding({ left: 8, right: 8, top: 6, bottom: 6 })
              .borderRadius(16)
              .backgroundColor(this.prefs.scheme === 'multi' ? this.chipBg() : Color.Transparent)
              .onClick(() => {
                Haptics.tap();
                if (this.prefs.scheme !== 'multi') {
                  this.prefs.scheme = 'multi';
                  this.commitPrefs();
                }
              })
            Blank()
            Row({ space: 6 }) {
              Text('跟随翻页').fontSize(14).fontColor(this.fg())
              Toggle({ type: ToggleType.Switch, isOn: this.prefs.autoFollow })
                .selectedColor(this.accent())
                .onChange((value: boolean) => {
                  Haptics.tap();
                  this.prefs.autoFollow = value;
                  this.commitPrefs();
                })
            }
          }.width('100%').padding({ top: 6, bottom: 6 })
          // ★ 收起档 + 播放中：这两行让位给「本章 + 滑块」（用户 2026-09-23 设计）
          .visibility(this.compactMode && this.ttsState !== 'stopped' ? Visibility.None : Visibility.Visible)

          // 沉浸听读：听书时自绘当前页，句子高亮画在文字内部（像素级精确；代价是听书时看不到翻页动画）
          Row({ space: 10 }) {
            Text('沉浸听读').fontSize(14).fontColor(this.fg())
            Toggle({ type: ToggleType.Switch, isOn: this.prefs.immersiveListen })
              .selectedColor(this.accent())
              .onChange((value: boolean) => {
                Haptics.tap();
                this.prefs.immersiveListen = value;
                this.commitPrefs();
              })
            Text('自绘这一页，句子高亮在文字内部 · 更精确但听书时不显示翻页动画')
              .fontSize(11)
              .fontColor(this.fgSub())
              .layoutWeight(1)
              .maxLines(2)
          }.width('100%')
          // 同「方案」行：收起档 + 播放中不显示（让位给本章滑块）
          .visibility(this.compactMode && this.ttsState !== 'stopped' ? Visibility.None : Visibility.Visible)

          // 音色选择
          if (this.showVoices && !this.compactMode) {
            // ── 音色**来源**（三修，2026-10-10）────────────────────────────────
            // 用户两次反馈"音色选择还是华为 tts 的" ⇒ 给一个显式来源选择器：
            // "我在给哪个引擎配音色"一眼可见、随时可切，不再靠隐式推断。
            Row({ space: 8 }) {
              Text('来源').fontSize(13).fontColor(this.fgSub())
              Text('自动')
                .fontSize(13)
                .fontColor(this.voiceSourceExplicit === 'auto' ? this.accent() : this.fgSub())
                .padding({ left: 10, right: 10, top: 4, bottom: 4 })
                .borderRadius(12)
                .backgroundColor(this.voiceSourceExplicit === 'auto' ? this.chipBg() : Color.Transparent)
                .onClick(() => {
                  Haptics.tap();
                  this.voiceSourceExplicit = 'auto';
                })
              Text('华为本地')
                .fontSize(13)
                .fontColor(this.voiceSourceExplicit === 'local' ? this.accent() : this.fgSub())
                .padding({ left: 10, right: 10, top: 4, bottom: 4 })
                .borderRadius(12)
                .backgroundColor(this.voiceSourceExplicit === 'local' ? this.chipBg() : Color.Transparent)
                .onClick(() => {
                  Haptics.tap();
                  this.voiceSourceExplicit = 'local';
                })
              if (this.aiDraftsReady()) {
                Text('AI 语音')
                  .fontSize(13)
                  .fontColor(this.voiceSourceExplicit === 'ai' ? this.accent() : this.fgSub())
                  .padding({ left: 10, right: 10, top: 4, bottom: 4 })
                  .borderRadius(12)
                  .backgroundColor(this.voiceSourceExplicit === 'ai' ? this.chipBg() : Color.Transparent)
                  .onClick(() => {
                    Haptics.tap();
                    this.voiceSourceExplicit = 'ai';
                  })
              }
              if (!this.isLocal()) {
                Text('Edge')
                  .fontSize(13)
                  .fontColor(this.voiceSourceExplicit === 'edge' ? this.accent() : this.fgSub())
                  .padding({ left: 10, right: 10, top: 4, bottom: 4 })
                  .borderRadius(12)
                  .backgroundColor(this.voiceSourceExplicit === 'edge' ? this.chipBg() : Color.Transparent)
                  .onClick(() => {
                    Haptics.tap();
                    this.voiceSourceExplicit = 'edge';
                  })
              }
              Blank()
            }.width('100%')
            Text('当前在为「' + this.voiceKindLabel() + '」配音色')
              .fontSize(11).fontColor(this.fgSub()).width('100%').maxLines(1)

            Row({ space: 10 }) {
              Text('选择').fontSize(14).fontColor(this.fg())
              if (this.prefs.scheme === 'multi') {
                Text('旁白')
                  .fontSize(14)
                  .fontColor(this.voiceSlot === 0 ? this.accent() : this.fgSub())
                  .padding({ left: 12, right: 12, top: 6, bottom: 6 })
                  .borderRadius(16)
                  .backgroundColor(this.voiceSlot === 0 ? this.chipBg() : Color.Transparent)
                  .onClick(() => {
                    Haptics.tap();
                    this.voiceSlot = 0;
                  })
                Text('对白')
                  .fontSize(14)
                  .fontColor(this.voiceSlot === 1 ? this.accent() : this.fgSub())
                  .padding({ left: 12, right: 12, top: 6, bottom: 6 })
                  .borderRadius(16)
                  .backgroundColor(this.voiceSlot === 1 ? this.chipBg() : Color.Transparent)
                  .onClick(() => {
                    Haptics.tap();
                    this.voiceSlot = 1;
                  })
                if (this.prefs.aiSpeakerRecognitionEnabled) {
                  Text('男生')
                    .fontSize(14)
                    .fontColor(this.voiceSlot === 2 ? this.accent() : this.fgSub())
                    .padding({ left: 12, right: 12, top: 6, bottom: 6 })
                    .borderRadius(16)
                    .backgroundColor(this.voiceSlot === 2 ? this.chipBg() : Color.Transparent)
                    .onClick(() => {
                      Haptics.tap();
                      this.voiceSlot = 2;
                    })
                  Text('女生')
                    .fontSize(14)
                    .fontColor(this.voiceSlot === 3 ? this.accent() : this.fgSub())
                    .padding({ left: 12, right: 12, top: 6, bottom: 6 })
                    .borderRadius(16)
                    .backgroundColor(this.voiceSlot === 3 ? this.chipBg() : Color.Transparent)
                    .onClick(() => {
                      Haptics.tap();
                      this.voiceSlot = 3;
                    })
                }
              }
              Blank()
              Text('收起')
                .fontSize(14)
                .fontColor(this.fgSub())
                .onClick(() => {
                  Haptics.tap();
                  this.showVoices = false;
                })
            }.width('100%')

            List({ space: 4 }) {
              if (this.voiceKind() === 'ai') {
                // ── AI 引擎音色（2026-10-10 新增分支）──────────────────────────
                // 这里是**唯一**的 AI 音色编辑处；选中即落盘（applyAiVoiceToPrefs）。
                // 允许手填 id：内置表只是"建议值"，不是权威清单（见 AiTtsVoices 头注释）。
                ForEach(this.aiVoiceList(), (v: AiVoiceOption) => {
                  ListItem() {
                    Row() {
                      Column({ space: 2 }) {
                        Text(v.label).fontSize(14).fontColor(this.fg())
                        Text(v.description).fontSize(11).fontColor(this.fgSub())
                      }
                      .alignItems(HorizontalAlign.Start)
                      .layoutWeight(1)
                      if (this.aiVoiceSelected(v.id)) {
                        SymbolGlyph($r('sys.symbol.checkmark'))
                          .fontSize(18)
                          .fontColor([this.accent()])
                      }
                    }
                    .width('100%')
                    .padding({ left: 12, right: 12, top: 8, bottom: 8 })
                    .borderRadius(10)
                    .backgroundColor(this.aiVoiceSelected(v.id) ? this.chipBg() : Color.Transparent)
                    .onClick(() => {
                      Haptics.tap();
                      this.applyAiVoiceToPrefs(v.id);
                    })
                  }
                }, (v: AiVoiceOption) => v.id)
              } else if (this.voiceKind() === 'local') {
                // 本地引擎音色：listVoices 动态枚举（权威）+ 状态徽标 + 点击下载（含进度）
                ForEach(this.localRenderRows(), (v: LocalVoiceRow) => {
                  ListItem() {
                    Row() {
                      Column({ space: 2 }) {
                        Row({ space: 6 }) {
                          Text(v.label).fontSize(14).fontColor(this.fg())
                          if (v.status === 'INSTALLED') {
                            Text('已下载').fontSize(10).fontColor(this.fgSub())
                          } else if (v.status === 'GA') {
                            Text('未下载').fontSize(10).fontColor(this.accent())
                          } else if (v.status === 'EOM') {
                            Text('不可用').fontSize(10).fontColor(this.fgSub())
                          }
                        }
                        Text(v.description).fontSize(11).fontColor(this.fgSub())
                      }
                        .alignItems(HorizontalAlign.Start)
                        .layoutWeight(1)
                      if (this.dlPerson === v.person) {
                        Text(`下载中 ${this.dlProgress}`)
                          .fontSize(12).fontColor(this.accent())
                      } else if (v.person === this.currentLocalPersonForSlot()) {
                        SymbolGlyph($r('sys.symbol.checkmark'))
                          .fontSize(18)
                          .fontColor([this.accent()])
                      } else if (v.status === 'GA') {
                        Text('点击下载')
                          .fontSize(12).fontColor(this.accent())
                      }
                    }
                    .width('100%')
                    .padding({ left: 12, right: 12, top: 8, bottom: 8 })
                    .borderRadius(10)
                    .backgroundColor(v.person === this.currentLocalPersonForSlot() ? this.chipBg() : Color.Transparent)
                    .opacity(v.status === 'EOM' ? 0.4 : 1)
                    .onClick(() => {
                      Haptics.tap();
                      this.onVoiceRowClick(v);
                    })
                  }
                }, (v: LocalVoiceRow) => `${v.person}|${v.status}|${this.dlPerson === v.person ? this.dlProgress : ''}`)
              } else {
                ForEach(EDGE_VOICES, (v: EdgeVoice) => {
                ListItem() {
                  Row() {
                    Column({ space: 2 }) {
                      Text(v.label).fontSize(14).fontColor(this.fg())
                      Text(v.description).fontSize(11).fontColor(this.fgSub())
                    }
                      .alignItems(HorizontalAlign.Start)
                      .layoutWeight(1)
                    if (v.id === this.currentVoiceForSlot()) {
                      SymbolGlyph($r('sys.symbol.checkmark'))
                        .fontSize(18)
                        .fontColor([this.accent()])
                    }
                  }
                  .width('100%')
                  .padding({ left: 12, right: 12, top: 8, bottom: 8 })
                  .borderRadius(10)
                  .backgroundColor(v.id === this.currentVoiceForSlot() ? this.chipBg() : Color.Transparent)
                  .onClick(() => {
                    Haptics.tap();
                    this.applyVoice(v.id);
                  })
                }
              }, (v: EdgeVoice) => v.id)
              }
            }
            .height(220)
            .width('100%')
            .scrollBar(BarState.Auto)
            // ⚠️ 提示行必须在 List **外**（List 只允许 ListItem 系子组件，Text 内嵌编译报错）
            if (this.voiceKind() === 'ai') {
              // ── 从服务商拉取音色（仅当该服务商有「列音色」接口）──────────────
              // 设计：拉取 → 落盘缓存（带时间戳+服务商指纹）→ 变更/过期再更新。
              // **只在用户点击时联网**（合规：用户主动发起）。
              if (this.aiMetaSupportsListVoices()) {
                Row({ space: 8 }) {
                  Text(this.aiCatalogVoices.length > 0 ? '刷新音色' : '拉取音色')
                    .fontSize(13)
                    .fontColor(this.aiVoiceFetching ? this.fgSub() : this.accent())
                    .padding({ left: 12, right: 12, top: 6, bottom: 6 })
                    .borderRadius(14)
                    .borderWidth(1)
                    .borderColor(this.aiVoiceFetching ? this.fgSub() : this.accent())
                    .onClick(() => {
                      Haptics.tap();
                      this.onFetchAiVoices();
                    })
                  Text(this.aiVoiceFetching ? '拉取中…' : this.aiCatalogInfo)
                    .fontSize(11)
                    .fontColor(this.fgSub())
                    .layoutWeight(1)
                    .maxLines(2)
                }.width('100%')
              } else {
                Text('该服务商没有「列音色」接口 ⇒ 请手填音色 id（下面那行）')
                  .fontSize(11).fontColor(this.fgSub()).width('100%').maxLines(2)
              }
              // AI 音色允许手填（内置表只是建议值）；填完点「填入」即落盘
              Row({ space: 8 }) {
                TextInput({ text: this.aiVoiceCustomDraft, placeholder: '或直接填音色 id（本服务商支持的任意值）' })
                  .fontSize(12)
                  .layoutWeight(1)
                  .backgroundColor(this.chipBg())
                  .fontColor(this.fg())
                  .placeholderColor(this.fgSub())
                  .onChange((v: string) => {
                    this.aiVoiceCustomDraft = v;
                  })
                Text('填入')
                  .fontSize(13)
                  .fontColor(this.accent())
                  .onClick(() => {
                    Haptics.tap();
                    this.applyAiVoiceToPrefs(this.aiVoiceCustomDraft);
                    this.aiVoiceCustomDraft = '';
                  })
              }.width('100%')
              Text('当前 ' + this.aiSlotLabel(this.prefs.scheme === 'single' ? 0 : this.voiceSlot)
                + '：' + this.aiVoiceLabelForSlot())
                .fontSize(11).fontColor(this.fgSub()).width('100%').maxLines(1)
              // 防呆（2026-10-10 用户实测踩过）：音色名由服务商定义，填错会**静默回落**，
              // 四个槽位全落同一个音色 ⇒ 男女声"听起来没用"。
              Text('提示：音色名由服务商定义。填了它不认识的 id 会回落到服务商的默认音色 —— '
                + '那样旁白/男/女会变成同一个声音。请确认四个槽位填的是该服务商真实存在的音色。')
                .fontSize(11).fontColor('#E6A23C').width('100%').maxLines(3)
              if (this.aiVoiceCollisionHint().length > 0) {
                Text(this.aiVoiceCollisionHint())
                  .fontSize(11).fontColor('#E6A23C').width('100%').maxLines(2)
              }
            }
            if (this.voiceKind() === 'local' && this.localHint.length > 0) {
              Text(this.localHint)
                .fontSize(11)
                .fontColor(this.fgSub())
                .width('100%')
                .padding({ left: 12, right: 12, top: 4 })
            }
          } else if (!this.compactMode) {
            Row() {
              Text('音色').fontSize(14).fontColor(this.fg())
              Blank()
              Text(this.voiceSummary())
                .fontSize(13)
                .fontColor(this.fgSub())
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .constraintSize({ maxWidth: '70%' })
              SymbolGlyph($r('sys.symbol.chevron_forward'))
                .fontSize(14)
                .fontColor([this.fgSub()])
            }
            .width('100%')
            .padding({ top: 8, bottom: 8 })
            .onClick(() => {
              Haptics.tap();
              this.showVoices = true;
              // 本地引擎：展开时才枚举音色（listVoices 权威动态表，含下载状态）
              if (this.voiceKind() === 'local') {
                this.loadLocalVoices();
              }
            })
          }

          // AI 男女声识别（多角色方案）—— 收起档不渲染（细节行，展开档才看）
          if (this.prefs.scheme === 'multi' && !this.compactMode) {
            Row({ space: 10 }) {
              Text('AI 男女声').fontSize(14).fontColor(this.fg())
              Toggle({ type: ToggleType.Switch, isOn: this.prefs.aiSpeakerRecognitionEnabled })
                .selectedColor(this.accent())
                .onChange((value: boolean) => {
                  Haptics.tap();
                  this.prefs.aiSpeakerRecognitionEnabled = value;
                  this.commitPrefs();
                  this.normalizeVoiceSlot(); // D4：关掉 AI 时把「男生/女生」槽位归一
                })
              Text('识别对白说话人性别并分音色')
                .fontSize(11)
                .fontColor(this.fgSub())
                .layoutWeight(1)
              Text(this.showAiConfig ? '收起接口' : '接口设置')
                .fontSize(13)
                .fontColor(this.accent())
                .onClick(() => {
                  Haptics.tap();
                  this.showAiConfig = !this.showAiConfig;
                })
            }.width('100%')

            // AI 情绪/语气（2026-10-10 新增）—— 与男女声**同一次 LLM 调用**返回，
            // 不额外增加请求数；⚠️ 只在**该服务商真支持自然语言语气**时显示
            // （MiniMax 只吃固定枚举，显示=假控件，见 AiProviderMeta.supportsEmotion）。
            if (this.aiMetaSupportsEmotion()) {
              Row({ space: 10 }) {
                Text('AI 语气').fontSize(14).fontColor(this.fg())
                Toggle({ type: ToggleType.Switch, isOn: this.prefs.aiEmotionEnabled })
                  .selectedColor(this.accent())
                  .onChange((value: boolean) => {
                    Haptics.tap();
                    this.prefs.aiEmotionEnabled = value;
                    this.commitPrefs();
                  })
                Text('按剧情给语气（需先开「AI 男女声」）')
                  .fontSize(11)
                  .fontColor(this.fgSub())
                  .layoutWeight(1)
              }.width('100%')
            }

            if (this.showAiConfig) {
              Column({ space: 8 }) {
                // D2：输入框绑定**草稿**，不直接改 prefs —— 只有点【保存】才落盘
                TextInput({ text: this.aiBaseUrlDraft, placeholder: '接口地址（OpenAI 兼容），如 https://api.deepseek.com/v1' })
                  .fontSize(13)
                  .backgroundColor(this.chipBg())
                  .fontColor(this.fg())
                  .placeholderColor(this.fgSub())
                  .onChange((v: string) => {
                    this.aiBaseUrlDraft = v;
                    this.aiDirty = true;
                    this.aiHint = '';
                  })
                TextInput({ text: this.aiApiKeyDraft, placeholder: 'API Key' })
                  .fontSize(13)
                  .type(InputType.Password)
                  .backgroundColor(this.chipBg())
                  .fontColor(this.fg())
                  .placeholderColor(this.fgSub())
                  .onChange((v: string) => {
                    this.aiApiKeyDraft = v;
                    this.aiDirty = true;
                    this.aiHint = '';
                  })
                TextInput({ text: this.aiModelDraft, placeholder: '模型名，如 deepseek-chat' })
                  .fontSize(13)
                  .backgroundColor(this.chipBg())
                  .fontColor(this.fg())
                  .placeholderColor(this.fgSub())
                  .onChange((v: string) => {
                    this.aiModelDraft = v;
                    this.aiDirty = true;
                    this.aiHint = '';
                  })
                // D2：显式保存 / 清空
                Row({ space: 10 }) {
                  Text('保存')
                    .fontSize(13)
                    .fontColor(Color.White)
                    .padding({ left: 16, right: 16, top: 7, bottom: 7 })
                    .borderRadius(14)
                    .backgroundColor(this.accent())
                    .onClick(() => {
                      Haptics.tap();
                      this.saveAiConfig();
                    })
                  Text('清空')
                    .fontSize(13)
                    .fontColor(this.fgSub())
                    .padding({ left: 16, right: 16, top: 7, bottom: 7 })
                    .borderRadius(14)
                    .borderWidth(1)
                    .borderColor(this.fgSub())
                    .onClick(() => {
                      Haptics.tap();
                      this.clearAiConfig();
                    })
                  Text(this.aiHint.length > 0 ? this.aiHint : (this.aiDirty ? '有未保存的修改' : ''))
                    .fontSize(11)
                    .fontColor(this.aiDirty ? '#E6A23C' : this.fgSub())
                    .layoutWeight(1)
                    .maxLines(2)
                }.width('100%')
                Text('每章批量识别一次对白性别；未配置或失败时回落到统一对白音色。修改后请点【保存】，否则重启后丢失。')
                  .fontSize(11)
                  .fontColor(this.fgSub())
                  .width('100%')
                  .maxLines(3)
              }
              .width('100%')
              .padding(10)
              .borderRadius(10)
              .backgroundColor(this.chipBg())
            }
          }

          // ══ AI 语音（用户自接入 TTS，2026-10-09 新增）══════════════════════════
          // ⚠️ 与上面「AI 男女声」是**两套配置**：上面填对话大模型（说话人识别），
          //    这里填语音合成接口。分块 + 文案写清，避免用户填串（方案 §5.8）。
          // 参数行由**服务商能力位**条件渲染：没能力的参数不出现（方案 §13.3）。
          if (!this.compactMode) {
            Row({ space: 10 }) {
              Text('AI 语音').fontSize(14).fontColor(this.fg())
              Text(this.prefs.aiTtsEnabled ? '已开启' : '未开启')
                .fontSize(11)
                .fontColor(this.prefs.aiTtsEnabled ? this.accent() : this.fgSub())
              Blank()
              Text(this.showAiTts ? '收起' : '接入设置')
                .fontSize(13)
                .fontColor(this.accent())
                .onClick(() => {
                  Haptics.tap();
                  this.showAiTts = !this.showAiTts;
                })
            }.width('100%')

            if (this.aiEdgeTakeover()) {
              Text('Edge TTS 已开启并优先接管。如需 AI 听书，请先到「我的-设置」关闭 Edge TTS。')
                .fontSize(11).fontColor('#E6A23C').width('100%').maxLines(2)
            } else if (this.ttsState !== 'stopped') {
              Text('朗读进行中不可切换引擎：请先停止听书，再开/关 AI 听书。')
                .fontSize(11).fontColor(this.fgSub()).width('100%').maxLines(2)
            }

            if (this.showAiTts) {
              Column({ space: 8 }) {
                // ── 服务商（5 家；Flex 换行防溢出 —— 窄屏下 Row 会挤爆）────────────
                Flex({ wrap: FlexWrap.Wrap, alignItems: ItemAlign.Center }) {
                  Text('服务商').fontSize(13).fontColor(this.fg()).margin({ right: 8, bottom: 6 })
                  ForEach(aiProviderMetaList(), (m: AiProviderMeta) => {
                    Text(m.label)
                      .fontSize(13)
                      .fontColor(this.prefs.aiProviderId === m.id ? this.accent() : this.fgSub())
                      .padding({ left: 10, right: 10, top: 5, bottom: 5 })
                      .borderRadius(14)
                      .margin({ right: 8, bottom: 6 })
                      .backgroundColor(this.prefs.aiProviderId === m.id ? this.chipBg() : Color.Transparent)
                      .onClick(() => {
                        Haptics.tap();
                        const changed: boolean = this.prefs.aiProviderId !== m.id;
                        this.prefs.aiProviderId = m.id;
                        if (this.aiTtsBaseUrlDraft.trim().length === 0) {
                          this.aiTtsBaseUrlDraft = m.defaultBaseUrl;
                        }
                        if (this.aiTtsModelDraft.trim().length === 0) {
                          this.aiTtsModelDraft = m.modelHint;
                        }
                        if (changed) {
                          // ⚠️ 音色 id 跨厂商不通用 ⇒ 换服务商必须重置槽位，
                          // 否则会静默回落成同一个声音（用户拍板："需要自动重置"）
                          this.resetAiVoiceSlotsForProvider(m.id);
                        }
                        this.aiTtsDirty = true;
                        // 换服务商 ⇒ 音色清单指纹变了：重新回填缓存
                        this.reloadAiCatalog();
                        this.aiTtsHint = changed
                          ? '已切换服务商，音色槽位已按该服务商重置'
                          : '有未保存的修改';
                      })
                  }, (m: AiProviderMeta) => m.id)
                }.width('100%')
                Text(this.aiMetaDesc())
                  .fontSize(11).fontColor(this.fgSub()).width('100%').maxLines(2)

                // ── AI 配置方案（2026-10-10）：小说/散文各一套、A/B 两个服务商不用重填 ──
                Flex({ wrap: FlexWrap.Wrap, alignItems: ItemAlign.Center }) {
                  Text('方案').fontSize(13).fontColor(this.fg()).margin({ right: 8, bottom: 6 })
                  ForEach(this.aiProfiles, (p: AiProfile) => {
                    Row({ space: 2 }) {
                      Text(p.name)
                        .fontSize(13)
                        .fontColor(this.isActiveAiProfile(p) ? this.accent() : this.fgSub())
                        .onClick(() => {
                          Haptics.tap();
                          this.onApplyAiProfile(p);
                        })
                      Text('×')
                        .fontSize(14)
                        .fontColor(this.fgSub())
                        .padding({ left: 4, right: 4 })
                        .onClick(() => {
                          Haptics.tap();
                          this.onDeleteAiProfile(p.id);
                        })
                    }
                    .padding({ left: 10, right: 8, top: 5, bottom: 5 })
                    .borderRadius(14)
                    .margin({ right: 8, bottom: 6 })
                    .backgroundColor(this.isActiveAiProfile(p) ? this.chipBg() : Color.Transparent)
                  }, (p: AiProfile) => p.id)
                  if (this.aiProfiles.length === 0) {
                    Text('（暂无，先在下面填好再存）')
                      .fontSize(11).fontColor(this.fgSub()).margin({ bottom: 6 })
                  }
                }.width('100%')
                Row({ space: 8 }) {
                  TextInput({ text: this.aiProfileNameDraft, placeholder: '方案名，如「小说·沉稳男声」' })
                    .fontSize(13)
                    .layoutWeight(1)
                    .backgroundColor(this.chipBg())
                    .fontColor(this.fg())
                    .placeholderColor(this.fgSub())
                    .onChange((v: string) => {
                      this.aiProfileNameDraft = v;
                    })
                  Text('存为方案')
                    .fontSize(13)
                    .fontColor(this.accent())
                    .padding({ left: 12, right: 12, top: 6, bottom: 6 })
                    .borderRadius(14)
                    .borderWidth(1)
                    .borderColor(this.accent())
                    .onClick(() => {
                      Haptics.tap();
                      this.onSaveAiProfile();
                    })
                }.width('100%')

                // ── 连接参数（按能力位渲染）──────────────────────────────────
                if (this.aiMetaNeedsBaseUrl()) {
                  TextInput({ text: this.aiTtsBaseUrlDraft, placeholder: '接口地址（openai.com 在国内不可达；建议填中转或自建服务）' })
                    .fontSize(13)
                    .backgroundColor(this.chipBg())
                    .fontColor(this.fg())
                    .placeholderColor(this.fgSub())
                    .onChange((v: string) => {
                      this.aiTtsBaseUrlDraft = v;
                      this.aiTtsDirty = true;
                      this.aiTtsHint = '有未保存的修改';
                    })
                }
                if (this.aiMetaNeedsApiKey()) {
                  TextInput({ text: this.aiTtsApiKeyDraft, placeholder: 'API Key' })
                    .fontSize(13)
                    .type(InputType.Password)
                    .backgroundColor(this.chipBg())
                    .fontColor(this.fg())
                    .placeholderColor(this.fgSub())
                    .onChange((v: string) => {
                      this.aiTtsApiKeyDraft = v;
                      this.aiTtsDirty = true;
                      this.aiTtsHint = '有未保存的修改';
                    })
                }
                TextInput({ text: this.aiTtsModelDraft, placeholder: '模型名，如 tts-1' })
                  .fontSize(13)
                  .backgroundColor(this.chipBg())
                  .fontColor(this.fg())
                  .placeholderColor(this.fgSub())
                  .onChange((v: string) => {
                    this.aiTtsModelDraft = v;
                    this.aiTtsDirty = true;
                    this.aiTtsHint = '有未保存的修改';
                  })

                // ── 输出格式（能力位提供可选项；不强制的服务商不渲染）────────
                if (this.aiMetaFormatOptions().length > 0) {
                  Row({ space: 8 }) {
                    Text('输出格式').fontSize(13).fontColor(this.fg())
                    ForEach(this.aiMetaFormatOptions(), (f: string) => {
                      Text(f)
                        .fontSize(13)
                        .fontColor(this.aiFormatDraft === f ? this.accent() : this.fgSub())
                        .padding({ left: 10, right: 10, top: 5, bottom: 5 })
                        .borderRadius(14)
                        .backgroundColor(this.aiFormatDraft === f ? this.chipBg() : Color.Transparent)
                        .onClick(() => {
                          Haptics.tap();
                          this.aiFormatDraft = f;
                          this.aiTtsDirty = true;
                          this.aiTtsHint = '有未保存的修改';
                        })
                    }, (f: string) => f)
                    Blank()
                    Text('mp3 最通用（本机解码器只认 mp3）')
                      .fontSize(11).fontColor(this.fgSub())
                  }.width('100%')
                }

                // ── 风格提示词（能力位支持才渲染）────────────────────────────
                if (this.aiMetaSupportsInstructions()) {
                  TextInput({ text: this.aiInstructionsDraft, placeholder: '风格提示词（可选），如：语气温和、语速平缓' })
                    .fontSize(13)
                    .backgroundColor(this.chipBg())
                    .fontColor(this.fg())
                    .placeholderColor(this.fgSub())
                    .onChange((v: string) => {
                      this.aiInstructionsDraft = v;
                      this.aiTtsDirty = true;
                      this.aiTtsHint = '有未保存的修改';
                    })
                }

                // ── 音色：**不在这里选**（2026-10-10 修正）────────────────────
                // 用户模型（原话）：「AI 男女声只是个辅助功能…只要能听书，无论哪种 tts
                // 都天然享受 AI 男女生的红利」。⇒ 音色只保留**一处**编辑：展开档上方的
                // 「音色」区，它会按当前引擎自动切换列表（AI 引擎时显示 AI 音色）。
                // 这里只给一句指引，避免此前"两处音色、两种提交语义（草稿/直存）"的冲突。
                Text('音色 → 在上方「音色」区选择：**展开本块后**音色区会自动切成 AI 音色列表，'
                  + '旁白/对白/男生/女生 四个槽位都在那里设，选完即生效。')
                  .fontSize(11).fontColor(this.fgSub()).width('100%').maxLines(3)

                // ── 高级：附加请求体 / 附加请求头（兼容任意中转的逃生口）──────
                Row({ space: 8 }) {
                  Text('高级').fontSize(13).fontColor(this.fg())
                  Blank()
                  Text(this.showAiAdvanced ? '收起' : '展开')
                    .fontSize(13)
                    .fontColor(this.accent())
                    .onClick(() => {
                      Haptics.tap();
                      this.showAiAdvanced = !this.showAiAdvanced;
                    })
                }.width('100%')
                if (this.showAiAdvanced) {
                  Text('附加请求体（JSON 片段，会合并进请求；同名键后者生效）')
                    .fontSize(11).fontColor(this.fgSub()).width('100%')
                  TextArea({ text: this.aiExtraBodyDraft, placeholder: '{"language_boost":"auto"}' })
                    .fontSize(12)
                    .height(64)
                    .backgroundColor(this.chipBg())
                    .fontColor(this.fg())
                    .placeholderColor(this.fgSub())
                    .onChange((v: string) => {
                      this.aiExtraBodyDraft = v;
                      this.aiTtsDirty = true;
                      this.aiTtsHint = '有未保存的修改';
                    })
                  Text('附加请求头（每行一条 `Key: Value`）')
                    .fontSize(11).fontColor(this.fgSub()).width('100%')
                  TextArea({ text: this.aiExtraHeadersDraft, placeholder: 'X-Organization: xxx' })
                    .fontSize(12)
                    .height(52)
                    .backgroundColor(this.chipBg())
                    .fontColor(this.fg())
                    .placeholderColor(this.fgSub())
                    .onChange((v: string) => {
                      this.aiExtraHeadersDraft = v;
                      this.aiTtsDirty = true;
                      this.aiTtsHint = '有未保存的修改';
                    })
                }

                // ── 保存 / 清空 ───────────────────────────────────────────────
                Row({ space: 10 }) {
                  // 试听（P0，2026-10-09）：用已保存的配置与当前槽位音色合成一句话
                  Text(this.aiPreviewLabel())
                    .fontSize(13)
                    .fontColor(Color.White)
                    .padding({ left: 16, right: 16, top: 7, bottom: 7 })
                    .borderRadius(14)
                    .backgroundColor(this.aiPreviewPhase === 0 ? this.accent() : '#E6A23C')
                    .onClick(() => {
                      Haptics.tap();
                      this.onAiPreviewClick();
                    })
                  Text('保存')
                    .fontSize(13)
                    .fontColor(Color.White)
                    .padding({ left: 16, right: 16, top: 7, bottom: 7 })
                    .borderRadius(14)
                    .backgroundColor(this.accent())
                    .onClick(() => {
                      Haptics.tap();
                      this.saveAiTtsConfig();
                    })
                  Text('清空')
                    .fontSize(13)
                    .fontColor(this.fgSub())
                    .padding({ left: 16, right: 16, top: 7, bottom: 7 })
                    .borderRadius(14)
                    .borderWidth(1)
                    .borderColor(this.fgSub())
                    .onClick(() => {
                      Haptics.tap();
                      this.clearAiTtsConfig();
                    })
                  Text(this.aiTtsHint.length > 0 ? this.aiTtsHint
                    : (this.aiTtsDirty ? '有未保存的修改' : ''))
                    .fontSize(11)
                    .fontColor(this.aiTtsDirty ? '#E6A23C' : this.fgSub())
                    .layoutWeight(1)
                    .maxLines(2)
                }.width('100%')

                Text('隐私：本功能不使用我们的服务器，也不收集任何信息。'
                  + '只有你手动打开上方开关后，正文才会发送到你自己填写的接口。'
                  + '密钥仅保存在本机。')
                  .fontSize(11).fontColor(this.fgSub()).width('100%').maxLines(3)
              }
              .width('100%')
              .padding(10)
              .borderRadius(10)
              .backgroundColor(this.chipBg())
            }
          }

          // 语速 / 音调 / 音量 / 停顿 —— **收起档不渲染**（细节行，展开档才看）
          // 双引擎：本地=语速(localRate)/音量/句末停顿/句中停顿（无音调）；Edge=原 5 项
          if (!this.compactMode) {
            ForEach(this.sliderDefs(), (d: SliderDef) => {
              Row({ space: 12 }) {
                Text(d.label).fontSize(14).fontColor(this.fg()).width(70)
                Slider({
                  value: this.sliderValue(d.key),
                  min: d.min,
                  max: d.max,
                  step: d.step,
                  style: SliderStyle.InSet
                })
                  .selectedColor(this.accent())
                  .blockSize({ width: 22, height: 22 })
                  // ⚠️ 不设材质（用户选 A：材质优先；材质嵌套会互相干扰，见上面「本章」滑块注释）
                  .layoutWeight(1)
                  .onChange((v: number) => {
                    this.applySlider(d.key, v);
                  })
                Text(`${this.sliderValue(d.key)}${d.unit}`)
                  .fontSize(12)
                  .fontColor(this.fgSub())
                  .width(60)
                  .textAlign(TextAlign.End)
              }.width('100%')
            }, (d: SliderDef) => d.key)
          }

          // 朗读过滤（2026-10-10 新增）—— **收起档不渲染**（细节行）
          // 能力对齐参考项目：命中片段换成**等长空格**（不删字）⇒ 高亮偏移/行号不变。
          if (!this.compactMode) {
            Row({ space: 10 }) {
              Text('朗读过滤').fontSize(14).fontColor(this.fg())
              Toggle({ type: ToggleType.Switch, isOn: this.prefs.speakFilterEnabled })
                .selectedColor(this.accent())
                .onChange((value: boolean) => {
                  Haptics.tap();
                  this.prefs.speakFilterEnabled = value;
                  this.commitPrefs();
                  this.showFilterRules = value ? this.showFilterRules : false;
                })
              Text('跳过括号注释、章末噪音等（不朗读，但正文照常显示）')
                .fontSize(11)
                .fontColor(this.fgSub())
                .layoutWeight(1)
              Text(this.showFilterRules ? '收起规则' : '编辑规则')
                .fontSize(13)
                .fontColor(this.accent())
                .onClick(() => {
                  Haptics.tap();
                  this.showFilterRules = !this.showFilterRules;
                })
            }.width('100%')

            if (this.showFilterRules) {
              Column({ space: 8 }) {
                Text('一行一条规则：默认按正则；~ 开头按字面量；# 开头是注释')
                  .fontSize(11).fontColor(this.fgSub()).width('100%').maxLines(2)
                TextArea({ text: this.speakFilterDraft, placeholder: '例如：[(（〔﹝][^)）〕﹞]{0,60}[)）〕﹞]' })
                  .fontSize(12)
                  .height(120)
                  .backgroundColor(this.chipBg())
                  .fontColor(this.fg())
                  .placeholderColor(this.fgSub())
                  .onChange((v: string) => {
                    this.speakFilterDraft = v;
                    this.speakFilterDirty = true;
                  })
                Row({ space: 10 }) {
                  Text('保存规则')
                    .fontSize(13)
                    .fontColor(this.accent())
                    .padding({ left: 12, right: 12, top: 6, bottom: 6 })
                    .borderRadius(14)
                    .borderWidth(1)
                    .borderColor(this.accent())
                    .onClick(() => {
                      Haptics.tap();
                      this.prefs.speakFilterText = this.speakFilterDraft;
                      this.commitPrefs();
                      this.speakFilterDirty = false;
                      this.speakFilterHint = '已保存（下一段生效）';
                    })
                  Text('恢复默认')
                    .fontSize(13)
                    .fontColor(this.fgSub())
                    .onClick(() => {
                      Haptics.tap();
                      this.speakFilterDraft = DEFAULT_SPEAK_FILTER_TEXT;
                      this.speakFilterDirty = true;
                      this.speakFilterHint = '已填入默认规则，记得点【保存规则】';
                    })
                  Blank()
                  Text(this.speakFilterHint).fontSize(11).fontColor(this.fgSub())
                }.width('100%')
              }.width('100%')
            }
          }

          // 引号风格（多角色时有效）—— **收起档不渲染**（细节行）
          if (!this.compactMode) {
            Row({ space: 10 }) {
              Text('对白引号').fontSize(14).fontColor(this.fg())
              ForEach(ALL_QUOTE_STYLES, (idx: number) => {
                Text(QUOTE_STYLE_LABELS[idx])
                  .fontSize(14)
                  .fontColor(this.prefs.quoteStyles.indexOf(idx) >= 0 ? this.accent() : this.fgSub())
                  .padding({ left: 12, right: 12, top: 6, bottom: 6 })
                  .borderRadius(16)
                  .backgroundColor(this.prefs.quoteStyles.indexOf(idx) >= 0 ? this.chipBg() : Color.Transparent)
                  .onClick(() => {
                    Haptics.tap();
                    this.toggleQuoteStyle(idx);
                  })
              }, (idx: number) => idx.toString())
              Blank()
              if (this.prefs.scheme !== 'multi') {
                Text('多角色时生效').fontSize(11).fontColor(this.fgSub())
              }
            }.width('100%')
          }

        }
        .width('100%')
        // 探针：滚动**内容**高度（内容永远按自身尺寸量，可作"自然高度"基准）
        .onAreaChange((_o: Area, n: Area) => {
          this.probe('scrollContent', n);
        })
      }
      // ⚠️ 2026-09-23：**收起档不参与权重分配**（`layoutWeight(0)`）。
      //   官方 `layoutWeight` 原文（common.d.ts:17447-17475）只定义了"父容器尺寸确定"时的分配；
      //   父容器高度自适应时行为未定义 —— 真机上表现为"内容只有几行，面板却被撑到上限"
      //   （用户截图：收起档底部一大片空边）。收起档内容本来就等于全部内容、不需要滚动，
      //   所以直接不加权重；展开档仍用权重（需要在超上限时滚动）。
      .layoutWeight(this.compactMode ? 0 : 1)
      .width('100%')
      .scrollBar(BarState.Off)
      .align(Alignment.Top)
      // 探针：滚动区高度
      .onAreaChange((_o: Area, n: Area) => {
        this.probe('scroll', n);
      })
    }
    .padding({ left: 20, right: 20, top: 12, bottom: 16 })
    .width('100%')
    // ── 高度：**内容自适应 + 上下限**（2026-09-23，详见 `panelMinHeight` 的注释）──────
    .constraintSize({
      minHeight: this.panelMinHeight,
      maxHeight: this.panelMaxHeight > 0 ? this.panelMaxHeight : '100%'
    })
    // ── 底色：**材质优先**（2026-09-23 用户拍板选 A）────────────────────────────
    // 交给 `MaterialColumnModifier(fallback, true)`：材质可用时**一个背景属性都不设**，
    // 露出调用方（`ReaderListenDialog`）通过 `CustomDialogControllerOptions.systemMaterial`
    // 提供的**真材质**；材质不可用（`ImmersiveMaterialUtil.ENABLED = false`）自动落回实底纯色。
    // ⚠️ 与"滑条光效"是二选一（官方《沉浸光感功耗优化》「避免材质嵌套…视觉上又相互干扰」）：
    //   用户选 A ⇒ 面板要真材质，面板内滑条**不设材质**（见两处滑条的注释）。
    // ⚠️ 不要在这里调 `.systemMaterial()`：弹窗的材质必须走 options。
    .attributeModifier(this.surface)
    // 探针：面板根（最终高度）
    .onAreaChange((_o: Area, n: Area) => {
      this.probe('panel', n);
    })
  }
}
