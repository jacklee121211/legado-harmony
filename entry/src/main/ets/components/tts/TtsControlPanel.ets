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
import { audio } from '@kit.AudioKit';
import vibrator from '@ohos.vibrator';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
// ── 全局震动反馈（2026-09-25 新增：hapticTick 的总开关守卫）──────────────────
import { Haptics } from '../../common/utils/Haptics';
// 材质：面板底色用 MaterialColumnModifier（"让出背景"，材质走弹窗 options）；
// 面板内滑条**不设材质**（用户选 A：材质优先 —— 与"滑条光效"互斥，官方禁止材质嵌套）
import ImmersiveMaterialUtil, { MaterialColumnModifier } from '../../common/utils/ImmersiveMaterialUtil';

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
  @Link isShowListen: boolean;
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
  @State voiceSlot: number = 0;           // 0=旁白 1=对白 2=男生 3=女生
  @State showVoices: boolean = false;
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
    this.refreshSilentMode(); // #3：进入面板先探一次静音状态
    // D3：回读引擎里的真实定时状态（旧实现只显示本地 @State，重开面板必显示「关」）
    this.syncSleepFromEngine();
    // 防重入：若上一次的刷新器还在（aboutToDisappear 未触发等情形），先清掉再起新的
    if (this.sleepTicker !== -1) {
      clearInterval(this.sleepTicker);
      this.sleepTicker = -1;
    }
    this.sleepTicker = setInterval((): void => {
      this.syncSleepFromEngine();
    }, 5000);
  }

  aboutToDisappear(): void {
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
      const leftMs = Math.max(0, stopMs - TtsEngine.getPlayedMs());
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
    if (this.isLocal()) {
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
    if (this.isLocal()) {
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
    if (this.isLocal()) {
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
      // 顶栏
      Row() {
        Text('朗读')
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.fg())
        Blank()
        Text('完成')
          .fontSize(16)
          .fontColor(this.accent())
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
              if (this.isLocal()) {
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
            if (this.isLocal() && this.localHint.length > 0) {
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
              if (this.isLocal()) {
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

          // 语速 / 音调 / 音量 / 停顿 —— **收起档不渲染**（细节行，展开档才看）
          // 双引擎：本地=语速(localRate)/音量/句末停顿/句中停顿（无音调）；Edge=原 5 项
          if (!this.compactMode) {
            ForEach(this.isLocal() ? TTS_SLIDERS_LOCAL : TTS_SLIDERS_EDGE, (d: SliderDef) => {
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
