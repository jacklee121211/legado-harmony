/**
 * PCM 流式播放器（AudioRenderer 写入模型，替代 AVPlayer）。
 * 同一 renderer 跨段复用：顺序写入即无缝衔接，段间不再有状态机切换间隙；
 * 暂停/继续是 renderer 原生 pause/start；stop 清队列。
 * 进度通过 getAudioTimeSync()（当前播放帧的表现时间戳，ns）换算。
 *
 * ⚠️ 已实测否决的改动（勿再尝试，2026-09-19）：
 *  把 `write()` 换成官方推荐的拉模式 `on('writeData')`（deprecated since 11 →
 *  @useinstead AudioRenderer#event:writeData）后，真机日志出现大量
 *    E {SetOutputBufferQueue} state invalid
 *    E {ProcessInputBuffer} ProcessInputBuffer failed -21
 *  音频链路不可用。原因：拉模式回调会在 renderer 队列尚未就绪时被拉起，
 *  与当前"每段 play 前 ensureRunning + 段间复用同一 renderer"的用法冲突。
 *  `write()` 虽已标记 deprecated，但在 API 16 上仍受支持、工作稳定 ——
 *  **保持推模式**，那条 severity-3 提示按"已知且接受"归档。
 *  同理，`AudioRenderer` 的"空闲 60s 自动 release"也一并回退：
 *  释放后重建会与上面的状态机问题叠加。
 */
import { audio } from '@kit.AudioKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG = 'PcmPlayer';
const DOMAIN = 0x0001;

/**
 * ── T1-A1 排水 / 进度模式开关 ──────────────────────────────────────────────
 * **默认 false = 保持旧实现（写入进度 ≈ 播放进度，只 sleep 一个 bufSize 排水）。**
 * 音频路径无法本地验证，故新路径默认关闭；真机验证通过后再改为 true。
 * 任何异常：把下面这一行改回 false，即完全回退到旧行为（无其它副作用）。
 *
 * 官方依据（原文）：
 *  · 文档 `开发指南/Audio_Kit_音频服务/音频播放/低功耗音频播放/power-saving-for-playback`：
 *     "流类型使用STREAM_USAGE_MUSIC、STREAM_USAGE_AUDIOBOOK、……系统默认为低功耗渲染器。"
 *     "低功耗渲染器缓冲区：亮屏场景下，最大1000ms；熄屏场景下，最大10000ms。"
 *     "应用数据写完不代表已经播完，需调用获取音频时间戳接口getAudioTimestampInfo……判断实际播放进度。"
 *     "播放数据量均会小于写入数据量。……已播放的数据量不等于写入数据量。"
 *  · FAQ `FAQ/音频和视频/音频_Audio/低功耗模式后台播放或息屏时_音频播放不完整/faqs-audio-62`：
 *     "……应用数据写完不代表已经播完，需要应用侧增加判断，否则会出现音频播放不完整的问题。"
 *     "……定时调用获取音频时间戳接口getAudioTimestampInfo……（建议大于200ms一次）……当2个周期内时间戳不变，即为播完。"
 *  · SDK `@ohos.multimedia.audio.d.ts:6170`：
 *     `getAudioTimestampInfo(): Promise<AudioTimestampInfo>;`   @since 19
 *     `@ohos.multimedia.audio.d.ts:5865` `interface AudioTimestampInfo { readonly framePos; readonly timestamp }` @since 19
 *     （注意：旧实现试过的 `getAudioTimeSync()` 是 `@ohos.multimedia.audio.d.ts:6148`，@since 10，
 *      文档串为 "nanoseconds from the Unix epoch"，**不含 framePos**，故确实不能用于排水判定；
 *      官方指定的排水 API 是上面这个 API 19 起的 `getAudioTimestampInfo`。）
 *
 * 验证点（翻 true 之后必须做的真机验证）：
 *  1. 熄屏听书 ≥5 分钟，观察高亮 / 句内前滚是否与语音同步；
 *  2. 日志 `pcm-ts:` 中 `framePos` 追上 `written` 之后才进入下一段；
 *  3. 来电打断 / 暂停 / 切段时无跳字漏句。
 */
const USE_TIMESTAMP_DRAIN: boolean = false;
/** 时间戳轮询周期；官方建议「大于200ms一次，以免影响系统性能」 */
const TS_POLL_MS: number = 250;

/**
 * ── T1-A2 音频打断完整处理开关 ────────────────────────────────────────────
 * **默认 false = 只处理 `INTERRUPT_HINT_PAUSE`（旧行为）。**
 * 音频路径无法本地验证，故新路径默认关闭；真机验证通过后再改为 true。
 * 任何异常：把下面这一行改回 false，即完全回退（无其它副作用）。
 *
 * 官方依据（原文）：
 *  · SDK `@ohos.multimedia.audio.d.ts:1677-1747` `enum InterruptHint`：
 *      `INTERRUPT_HINT_RESUME = 1`  "indicating that the audio stream is restored"
 *      `INTERRUPT_HINT_PAUSE  = 2`  "indicating that the audio stream is paused and the audio focus is lost temporarily"
 *      `INTERRUPT_HINT_STOP   = 3`  "indicating that the audio stream **stops and the audio focus is lost**"
 *      `INTERRUPT_HINT_DUCK   = 4` / `UNDUCK = 5`（@since 8）/ `MUTE = 6` / `UNMUTE = 7`（@since 20）
 *  · SDK `@ohos.multimedia.audio.d.ts:1790-1818` `interface InterruptEvent { eventType; forceType; hintType }`
 *  · 文档 `开发指南/Audio_Kit_音频服务/音频焦点和音频会话管理/音频焦点介绍/audio-playback-concurrency` 伪代码：
 *      `case INTERRUPT_HINT_STOP:` "此分支表示系统已将音频流停止（永久失去焦点），
 *        **为保持状态一致，应用需切换至音频暂停状态**。永久失去焦点：后续不会再收到任何音频焦点事件"
 *      `case INTERRUPT_HINT_RESUME:` "此分支表示临时失去焦点后被暂停的音频流此时可以继续播放，
 *        **建议应用继续播放**，切换至音频播放状态。（属 INTERRUPT_SHARE，应用可选择忽略）"
 *  · 同页「典型场景」表：音乐→音乐 时「先播音乐**停止播放，UI 变成停止播放状态**」，
 *    适配方案是「接收到 INTERRUPT_HINT_STOP 事件时，停止音乐播放，并更新UI界面」。
 *
 * 旧行为的问题：系统已强制停流，而 `TtsEngine.state` 仍为 `'playing'` ⇒ 应用状态与系统状态不一致。
 *
 * 验证点（翻 true 之后必须做的真机验证）：
 *  1. 播放中用另一个音乐 App 抢占 → 本应用应显示"已停止/暂停"且不再假装在播；
 *  2. 来电/闹铃打断 → 结束后是否自动续播（`RESUME` 分支）；
 *  3. 手动暂停时收到 RESUME **不得**自动续播（已用 `interruptedBySystem` 标记区分）。
 */
const INTERRUPT_FULL_HANDLING: boolean = true;

/**
 * ── T1-D1 打断时同步播放器自身状态（修复"点继续没用"）───────────────────────
 * **默认 true**（用户已确认选择修复）。改回 false 即完全回退到本开关引入前的行为。
 *
 * 真机故障链（2026-09-21 00:53 日志，进程 57857）：
 *  1. `00:53:19.038 audioInterrupt hint=2 force=0 event=1`（系统**强制**暂停，`INTERRUPT_FORCE`）
 *     → 本文件 `INTERRUPT_HINT_PAUSE` 分支此前**只调 `onInterrupted()`，没有调 `this.pause()`**
 *     ⇒ `pausedFlag` 仍为 `false`，`r.pause()` 从未执行，渲染器客户端状态留在 `STATE_RUNNING`。
 *  2. `00:53:20.018 audioInterrupt hint=1 force=1 event=2`（`RESUME`，`INTERRUPT_SHARE`）
 *     → `TtsEngine.resume()` **确实执行了**（证据：`00:53:20.020 AVSession name=SetAVPlayback`；
 *       若走旧路径 `hint=1` 会被完全忽略，不会有这条）。
 *  3. 但 `resume()` 里的守卫是 `if (r.state === audio.AudioState.STATE_PAUSED) r.start();`
 *     ⇒ 状态非 `STATE_PAUSED` ⇒ **`r.start()` 从未被调用**。
 *     证据：整份日志 `Renderer::Start` 仅 4 次（00:53:14.441 / 00:53:45.999 / 00:54:12.092 /
 *     00:54:13.899），**两次 RESUME 之后都没有**；且本文件 `renderer resume err` **零命中**
 *     ⇒ 不是"调了失败"，是**根本没调**。
 *  4. 用户随后点了 3 次播放（日志 `SetAVPlayback` 呈三组：00:53:26.965/27.807、32.576/33.751、
 *     35.529/36.595），但引擎状态已在第 2 步被置为 `playing` ⇒ `TtsEngine.resume()` 开头的
 *     `if (!TtsEngine.isPaused()) return;` **直接返回，什么都不做**。
 *  5. 只有重建管线才恢复：`00:53:44.488 Renderer::Stop` → `00:53:44.509 TtsEngine chapter:` →
 *     `00:53:45.999 Renderer::Start`（即用户按"从本页"）。00:54:13.843/.899 同型。
 *
 * 副作用（同一条根因）：`pausedFlag` 为 false ⇒ 写循环继续往已死的流灌数据 ⇒
 *   `[WriteArrayBufferToNative]Write length < 0,break.` 在该日志中出现 **461 次**
 *   （00:52 有 217、00:53 有 242、00:54 仅 1 次，此后 5 分钟 0 次——因为那次 Stop+Start 洗清了状态）。
 *
 * 修法：`INTERRUPT_HINT_PAUSE` 分支补一次 `this.pause()`，使 `pausedFlag=true` 且
 *   （若客户端状态仍为 `STATE_RUNNING`）真正执行 `r.pause()`，把状态推进到 `STATE_PAUSED`，
 *   从而让第 3 步的守卫成立、`resume()` 能真正 `r.start()`。
 *
 * 验证点（真机）：
 *  1. 播放中用音乐 App / 微信语音抢占，对方放开后应**自动续播**（不自动则看日志）；
 *  2. 日志中 `Write length < 0` 应在被打断后**停止增长**；
 *  3. 打断后手动点播放（悬浮条与系统播控卡片各试一次）应能恢复；
 *  4. 日志应出现 `resume: renderer state=<n>`，用于确认 `r.state` 的真实取值。
 */
const INTERRUPT_SYNC_PLAYER_STATE: boolean = true;

/**
 * ── T1-D2 「状态显示在播、管线其实已死」兜底重建 ─────────────────────────────
 * **默认 true**（用户已确认选择修复）。改回 false 即完全回退。
 *
 * 用途：即使 T1-D1 没覆盖到的情形（例如引擎状态已是 `playing`、用户再次点播放），
 * 只要检测到写失败，就**按"从本页"的语义重建整条管线**，而不是"点了没反应"。
 *
 * 检测依据（SDK 原文）：
 *   `@ohos.multimedia.audio.d.ts:6116 write(buffer: ArrayBuffer): Promise<number>;`
 *   「@returns { Promise<number> } Promise used to return the **number of written bytes**.」
 *   ⇒ 返回值 `<= 0` 即写失败。真机日志 `[WriteArrayBufferToNative]Write length < 0,break.` 与之对应。
 *
 * 阈值取 3：真机观测到的失败是**连续密集**的（毫秒级连发），3 次足以判定，且能避开偶发单次抖动。
 *
 * 验证点（真机）：
 *  1. 出现"状态在播但没声音"时点播放 → 日志应出现
 *     `resume: stream dead while state=playing -> force rebuild`，随后有新的 `Renderer::Stop`/`Start`；
 *  2. 正常播放中误触不应触发该分支（`writeFailStreak` 应恒为 0）。
 */
export const INTERRUPT_REBUILD_WHEN_STUCK: boolean = true;
/** 连续写失败达到该次数即判定"流已死"。见 T1-D2 说明。 */
const STREAM_DEAD_FAIL_STREAK: number = 3;

/**
 * ── P1 功耗自检日志开关 ─────────────────────────────────────────────────────
 * **默认 true。这是一个纯日志开关，不改变任何行为**（只增加 hilog 调用 + 若干只读查询）。
 * 改回 false 即完全停止输出。
 *
 * 目的：判定官方"低功耗渲染器"是否真的生效。当前存在一处**文档与真机日志的冲突**：
 *  · 官方 documentId `开发指南/Audio_Kit_音频服务/音频播放/低功耗音频播放/power-saving-for-playback`：
 *    「流类型使用 `STREAM_USAGE_MUSIC`…**系统默认为低功耗渲染器**」
 *    「低功耗渲染器缓冲区：**亮屏场景下，最大 1000ms；熄屏场景下，最大 10000ms**」
 *  · 真机日志 `Untitled-1.txt` 17/17 次：
 *    `[GetBufferSize]Buffer size is 960, mode is RENDER_MODE_NORMAL`
 *    960 字节 ÷ 2 ÷ 24000Hz ≈ **20ms**，与"最大 1000/10000ms"相差约 50 倍。
 *
 * **判定原理（本开关输出的核心指标）**：
 *   设本块 PCM 的音频时长为 `pcmMs`、实际写循环耗时 `writeMs`、渲染器缓冲容量为 `B`(ms)。
 *   写循环必须等播放腾出空间，故 `writeMs ≈ max(0, pcmMs − B)`，于是
 *       `slack = pcmMs − writeMs ≈ min(pcmMs, B)`
 *   ⇒ **`slack` 直接反映有效缓冲容量**（上限被本块时长截断）：
 *     · `slack ≈ 20~40ms`  ⇒ 有效缓冲只有几十毫秒 = **普通渲染器**
 *     · `slack ≈ 1000ms`   ⇒ 亮屏低功耗缓冲
 *     · `slack ≈ pcmMs`（即 `writeMs ≈ 0`）⇒ 整块被一次吞下 = **缓冲 ≥ 本块时长**，低功耗生效
 *
 * **能力查询**（`@since 26.0.0`，本工程 compileSdkVersion 即 26.0.0）：
 *   `@ohos.multimedia.audio.d.ts` `interface AudioStreamManager`（L2981-3363）：
 *     `:3316 isOffloadPlaybackSupported(streamInfo: AudioStreamInfo, usage: StreamUsage): boolean;`
 *     `:3328 isDirectPlaybackSupported(streamInfo: AudioStreamInfo, usage: StreamUsage): boolean;`
 *     （另 `isFastPlaybackSupported`，同为 @since 26.0.0）
 *   获取路径均为**同步**：`getAudioManager(): AudioManager`(L124) → `getStreamManager(): AudioStreamManager`(L2425)。
 *   `@syscap SystemCapability.Multimedia.Audio.Core`、`@stagemodelonly`。
 *   注意：这三项查的是**设备能力**，不等于"我们实际拿到了低功耗渲染器"；实际结果以上面的 `slack` 为准。
 *
 * 验证点（跑一次听书后看日志）：
 *  1. `power: create …` 一次性打印流参数与三项能力查询结果；
 *  2. 每块一条 `power: chunk …`，重点看 `slack=`；
 *  3. 熄屏后再看一轮：若低功耗生效，熄屏时应出现 `slack` 显著变大或 `writeMs≈0`。
 */
const POWER_SELFCHECK: boolean = true;

/**
 * ── T13/D-19 SysCap（系统能力）预判开关 ─────────────────────────────────────
 * **默认 false = 旧行为**（不预判，直接调用 audio API）。
 * 音频路径无法本地验证，故新路径默认关闭；真机验证通过后再改为 true。
 * 任何异常：把下面这一行改回 false，即完全回退（无其它副作用）。
 *
 * 为什么需要它 —— 官方依据（原文）：
 *  · 编译器告警 **16 条** `The system capacity of this api 'audio' is not supported on all devices`，
 *    全部落在本文件（`docs/build-warnings-2026-09-20.csv`：L113/114/115/118/122/129/136/140/144/
 *    163×2/164/307/319/335×2）。
 *  · SDK `@ohos.multimedia.audio.d.ts` 的 `@syscap` 归属（逐符号核对）：
 *      `SystemCapability.Multimedia.Audio.Core`     ← `enum AudioChannel`(L929) /
 *          `enum AudioSampleFormat`(L866) / `enum AudioEncodingType`(L1169) / `enum StreamUsage`(L1261) /
 *          `enum AudioState`(L242) / `interface AudioTimestampInfo`(L5865)
 *      `SystemCapability.Multimedia.Audio.Renderer` ← `interface AudioRenderer`(L5929) /
 *          `interface AudioRendererOptions`(L1510) / `enum InterruptHint`(L1677) /
 *          `interface InterruptEvent`(L1790) / `createAudioRenderer` / `write` / `start` / `pause` /
 *          `stop` / `release` / `getAudioTimestampInfo`
 *  · 官方《系统能力SystemCapability使用指南》（`API参考/系统能力SystemCapability使用指南/syscap`）：
 *    「使用 `canIUse` 接口判断 SysCap 对应的 API 集合是否可调用：true 表示可调用，
 *      **false 表示不可调用**（该 SysCap 在对应设备类型中未包含）」；
 *    官方示例即 `if (canIUse("SystemCapability.Location.Location.Core")) { … }`。
 *  · `canIUse` 是**全局函数**，无需 import —— 声明见
 *    `…\ets\api\@internal\full\global.d.ts:374` `export declare function canIUse(syscap: string): boolean;`
 *    与编译器自带 `…\ets\build-tools\ets-loader\declarations\global.d.ts:389`（同签名）。
 *  · 本项目已有先例：旧阅读器 HAR（`readerLibrary`，2026-09-22 已随死代码清理删除）
 *    的 `view/Reader.ets` 曾用 `canIUse('SystemCapability.Graphics.Drawing')` 15 次。
 *
 * 失败时的行为：**抛错**（不改语义地走 `TtsEngine` 既有的
 * `catch { onToast('一段播放失败，已跳过') }` 分支，见 `TtsEngine.ets:682-690`），
 * 而不是静默返回 —— 静默返回会让 UI 继续"假装在播"。
 *
 * 验证点（翻 true 之后必须做的真机验证）：
 *  1. 正常手机：日志出现 `syscap-audio core=true renderer=true`，听书全流程与旧行为**逐字一致**；
 *  2. 若某设备返回 false：应看到 `syscap-audio unavailable` + 「一段播放失败，已跳过」，
 *     而**不是** `createAudioRenderer` 抛出的原始异常（6800101 之类）。
 */
const SYSCAP_AUDIO_PRECHECK: boolean = false;
/** 上面两项 SysCap 的名称，按 SDK `@syscap` 原文照抄（拼错会静默返回 false，务必勿改） */
const SYSCAP_AUDIO_CORE: string = 'SystemCapability.Multimedia.Audio.Core';
const SYSCAP_AUDIO_RENDERER: string = 'SystemCapability.Multimedia.Audio.Renderer';

/**
 * ── F3 听书流用途开关（2026-09-29，真机日志驱动）─────────────────────────────
 * **默认 false = 旧行为**（`STREAM_USAGE_MUSIC`，线上已实测功耗可接受）。
 * 音频通路/焦点/功耗策略属**不可本地验证**改动，故新路径默认关闭；
 * 真机对照实测（同一本书、同样时长、同屏幕状态）确认不掉电、不断流后再翻 true。
 * 任何异常：把下面这一行改回 false，即完全回退（行为逐字不变）。
 *
 * 官方依据（原文）：
 *  · SDK `@ohos.multimedia.audio.d.ts:1380-1388`
 *      `STREAM_USAGE_AUDIOBOOK = 12,`  @since 10
 *      注释原文：「Audiobooks (including crosstalks and storytelling), news radio, and podcasts.」
 *    （`@ohos.multimedia.audio.d.ts:1291` `STREAM_USAGE_MUSIC = 1,` @since 7）
 *  · 文档 `开发指南/Audio_Kit_音频服务/音频播放/选择合适的播放流类型/using-right-streamusage-for-playback`：
 *      `STREAM_USAGE_AUDIOBOOK`「**适用于播放有声读物、新闻、播客等。**」
 *      同页「低功耗播放通路」表：「通过大缓存减少与硬件交互，以降低功耗。| **长时间播放音乐、有声读物等。**」
 *  · 文档 `开发指南/Audio_Kit_音频服务/音频播放/低功耗音频播放/power-saving-for-playback`：
 *      「流类型使用 STREAM_USAGE_MUSIC、**STREAM_USAGE_AUDIOBOOK**……系统默认为低功耗渲染器。」
 *      「低功耗渲染器缓冲区：**亮屏场景下，最大 1000ms；熄屏场景下，最大 10000ms**。」
 *
 * 为什么值得一试 —— 真机实测的瓶颈（`Downloads/2.md`，09-29 01:08–01:21，pid 23297）：
 *  · `[GetBufferSize]Buffer size is 960, mode is RENDER_MODE_NORMAL` —— **162/162 次全部如此**
 *    ⇒ 960 字节 ÷ 2 ÷ 24000Hz = **有效缓冲仅 20ms**，与文档"最大 1000/10000ms"差 50~500 倍；
 *  · 同一次会话 57 个真实语音块的 `power: chunk` 实测：`pcmMs` 平均 9803ms、
 *    `writeMs` 平均 9405ms，其中 **14 块 slack 为负**（最差 `slack=-5418`）
 *    ⇒ 主线程任何 >20ms 的停顿都会立刻变成音频空洞。
 *
 * ⚠️ 反过来也要记住：当前普通渲染器下**写入被实时背压节流**，CPU 大部分时间在休眠，
 *   实测整机功耗已经不高。换成大缓冲后是"一口气灌满再睡更久"，**不保证更省电** ——
 *   这正是本开关默认 false、必须真机 A/B 实测（重点看熄屏 30 分钟平均电流）的原因。
 *
 * 验证点（翻 true 后）：
 *  1. 日志 `power: create … usage=12`，且 `[GetBufferSize]` 应显著变大（或 mode 变化）；
 *  2. `power: chunk … slack=` 应趋近 `pcmMs`（整块被一次吞下）；
 *  3. 熄屏听书 30 分钟：平均电流不得高于 MUSIC 基线，且不得出现新的空洞/冻结；
 *  4. 音量行为不变（两者音量类型同为媒体音量 MEDIA）。
 */
const HL_STREAM_USAGE_AUDIOBOOK: boolean = false;
/** 实际下发给渲染器的 usage。切换只改这一个函数，不做散落分支。 */
function hlStreamUsage(): audio.StreamUsage {
  return HL_STREAM_USAGE_AUDIOBOOK
    ? audio.StreamUsage.STREAM_USAGE_AUDIOBOOK
    : audio.StreamUsage.STREAM_USAGE_MUSIC;
}

export class PcmPlayer {
  private renderer: audio.AudioRenderer | null = null;
  private rendererRate: number = 0;
  private pausedFlag: boolean = false;
  private abortFlag: boolean = false;
  /**
   * T1-D2：连续写失败次数（`write()` 返回 <= 0 即失败，见 `STREAM_DEAD_FAIL_STREAK` 注释）。
   * 每次成功写入归零；达到阈值即认为底层流已死，供 `TtsEngine` 触发兜底重建。
   */
  private writeFailStreak: number = 0;
  /** T1-D2：是否已就"流已死"打过日志（避免刷屏） */
  private streamDeadLogged: boolean = false;
  /** 音频打断（来电等）：由引擎决定如何响应 */
  onInterrupted: () => void = (): void => {};
  /** 系统**永久**停止音频流（`INTERRUPT_HINT_STOP`）；仅 INTERRUPT_FULL_HANDLING 开启时被调用 */
  onStopped: () => void = (): void => {};
  /** 焦点恢复提示（`INTERRUPT_HINT_RESUME`，属 INTERRUPT_SHARE）；仅 INTERRUPT_FULL_HANDLING 开启时被调用 */
  onResumeHint: () => void = (): void => {};

  /**
   * T13/D-19：SysCap 预判。
   * 开关关闭时**直接返回 true 且完全不调用 `canIUse`** ⇒ 与旧行为逐字一致（零副作用）。
   */
  private syscapAudioOk(): boolean {
    if (!SYSCAP_AUDIO_PRECHECK) {
      return true;
    }
    const core: boolean = canIUse(SYSCAP_AUDIO_CORE);
    const renderer: boolean = canIUse(SYSCAP_AUDIO_RENDERER);
    hilog.info(DOMAIN, TAG, 'syscap-audio core=%{public}s renderer=%{public}s',
      core ? 'true' : 'false', renderer ? 'true' : 'false');
    return core && renderer;
  }

  async ensureRenderer(sampleRate: number): Promise<void> {
    if (this.renderer !== null && this.rendererRate === sampleRate) {
      return;
    }
    if (this.renderer !== null) {
      try {
        await this.renderer.release();
      } catch (e) {
        // 忽略
      }
      this.renderer = null;
    }
    const options: audio.AudioRendererOptions = {
      streamInfo: {
        samplingRate: sampleRate,
        channels: audio.AudioChannel.CHANNEL_1,
        sampleFormat: audio.AudioSampleFormat.SAMPLE_FORMAT_S16LE,
        encodingType: audio.AudioEncodingType.ENCODING_TYPE_RAW
      },
      rendererInfo: {
        usage: hlStreamUsage(),
        rendererFlags: 0
      }
    };
    const r = await audio.createAudioRenderer(options);
    if (POWER_SELFCHECK) {
      this.logPowerCapability(options);
    }
    r.on('audioInterrupt', (event: audio.InterruptEvent) => {
      // 观测（纯增量，两条路径都记）：真机取证用，便于确认实际收到的 hint/force 组合
      hilog.info(DOMAIN, TAG, 'audioInterrupt hint=%{public}d force=%{public}d event=%{public}d',
        event.hintType, event.forceType, event.eventType);
      if (!INTERRUPT_FULL_HANDLING) {
        // ---------- 旧路径（默认）----------
        if (event.hintType === audio.InterruptHint.INTERRUPT_HINT_PAUSE) {
          this.onInterrupted();
        }
        return;
      }
      // ---------- 新路径：按官方口径对 hintType 分流 ----------
      switch (event.hintType) {
        case audio.InterruptHint.INTERRUPT_HINT_PAUSE:
          // 临时失焦；系统已暂停流（FORCE）。
          // T1-D1：必须**同时**把本地状态同步过去 —— 否则 `pausedFlag` 仍为 false，
          //   写循环会继续往已死的流灌数据（真机 461 次 `Write length < 0`），
          //   且 `resume()` 的 `r.state === STATE_PAUSED` 守卫不成立 ⇒ "点继续没用"。
          if (INTERRUPT_SYNC_PLAYER_STATE) {
            this.pause();
          }
          this.onInterrupted();
          break;
        case audio.InterruptHint.INTERRUPT_HINT_STOP:
          // 永久失焦：系统已停流，且后续不会再收到任何焦点事件。
          // T1-D4 取证日志（不改变行为）：确认永久失焦后渲染器的真实状态。
          hilog.warn(DOMAIN, TAG, 'interrupt STOP: renderer state=%{public}d pausedFlag=%{public}s',
            this.renderer === null ? -2 : this.renderer.state, this.pausedFlag ? 'true' : 'false');
          this.onStopped();
          break;
        case audio.InterruptHint.INTERRUPT_HINT_RESUME:
          // 仅 INTERRUPT_SHARE：是否续播由引擎决定
          this.onResumeHint();
          break;
        default:
          // DUCK / UNDUCK / MUTE / UNMUTE：音量由系统代劳（INTERRUPT_FORCE），无需动作
          break;
      }
    });
    this.renderer = r;
    this.rendererRate = sampleRate;
  }

  private async ensureRunning(): Promise<void> {
    const r = this.renderer;
    if (r === null) {
      return;
    }
    const s = r.state;
    if (s === audio.AudioState.STATE_PREPARED || s === audio.AudioState.STATE_STOPPED
      || s === audio.AudioState.STATE_PAUSED) {
      try {
        await r.start();
      } catch (e) {
        hilog.error(DOMAIN, TAG, 'renderer start err %{public}s', JSON.stringify(e));
      }
    }
  }

  /**
   * 读取当前播放帧位置与官方时间戳（T1-A1 新路径专用）。
   * 仅在可读状态下有值；否则返回 null（错误码 6800103 Operation not permit at current state）。
   */
  private readTs(): audio.AudioTimestampInfo | null {
    const r = this.renderer;
    if (r === null) {
      return null;
    }
    try {
      return r.getAudioTimestampInfoSync();
    } catch (e) {
      return null;
    }
  }

  /**
   * 播放整段 PCM。两条路径由 USE_TIMESTAMP_DRAIN 选择：
   *  · false（默认 = 旧实现）：写循环被 audio server 以实时速率背压节流，"写完即近似播完"；
   *      onPos(ms) 汇报**写入进度**；排空只等最后一个缓冲的时长。
   *  · true （官方口径）    ：onPos(ms) 汇报**真实播放进度**（getAudioTimestampInfoSync 的 framePos）；
   *      排空按官方"2 个周期内帧位不变即播完"判定（见文件头 T1-A1 依据）。
   * @throws 设备缺少音频 SysCap（`SystemCapability.Multimedia.Audio.Core` /
   *     `…Audio.Renderer`）时抛出 —— **仅当 `SYSCAP_AUDIO_PRECHECK` 开启**；
   *     以及 `createAudioRenderer` / `AudioRenderer.write` 自身的失败。
   *     `TtsEngine.ets:682-690` 已 catch 并提示「一段播放失败，已跳过」。
   */
  async play(pcm: Int16Array, sampleRate: number, onPos: (ms: number) => void): Promise<void> {
    // T13/D-19：SysCap 预判（默认关闭）。关闭时此分支不执行，行为与旧实现完全一致。
    if (!this.syscapAudioOk()) {
      hilog.error(DOMAIN, TAG, 'syscap-audio unavailable -> abort playback (T13/D-19)');
      throw new Error('audio SysCap not supported on this device');
    }
    await this.ensureRenderer(sampleRate);
    const r = this.renderer!;
    this.abortFlag = false;
    // T1-D2：新一轮播放重新计数（旧一轮的失败不应污染本轮判定）
    this.writeFailStreak = 0;
    this.streamDeadLogged = false;
    await this.ensureRunning();
    const bytes = pcm.length * 2;
    const totalMs = bytes / 2 / sampleRate * 1000;
    let bufSize = 4096;
    try {
      bufSize = await r.getBufferSize();
    } catch (e) {
      // 用默认块大小
    }
    const queueDrainMs = bufSize / 2 / sampleRate * 1000 + 120;
    let off = 0;

    if (USE_TIMESTAMP_DRAIN) {
      // ---------- 新路径：真实播放进度 + 官方口径排水 ----------
      // 同一 renderer 跨段复用 ⇒ framePos 单调累加；记段起点做差即"本段已播帧数"
      let baseFrame = -1;
      let lastFrame = -1;
      let running = true;
      const t0 = this.readTs();
      if (t0 !== null) {
        baseFrame = t0.framePos;
        lastFrame = t0.framePos;
      }
      // 进度轮询：帧位增量 → 本段已播 ms
      const pollProgress = async (): Promise<void> => {
        while (running) {
          await this.sleep(TS_POLL_MS);
          if (!running) {
            return;
          }
          if (this.pausedFlag) {
            continue; // 暂停时帧位不推进：既不是进度，也不是"播完"
          }
          const ts = this.readTs();
          if (ts === null) {
            continue;
          }
          if (baseFrame < 0) {
            baseFrame = ts.framePos; // 首次拿到有效帧位时定基准
            lastFrame = ts.framePos;
            continue;
          }
          if (onPos !== null && ts.framePos >= baseFrame) {
            onPos(Math.max(0, Math.min(totalMs, (ts.framePos - baseFrame) / sampleRate * 1000)));
          }
        }
      };
      const poller = pollProgress();
      // 写循环：保持推模式 write（拉模式 writeData 已实测不可用，见文件头说明）
      while (off < bytes && !this.abortFlag) {
        if (this.pausedFlag) {
          await this.sleep(100);
          continue;
        }
        const n = Math.min(bufSize, bytes - off);
        this.trackWrite(await r.write(pcm.buffer.slice(off, off + n)));
        off += n;
      }
      // 排水：写完不代表播完 —— 连续 2 个周期帧位不变即播完。
      // 兜底：即使帧位一直推进，也最多等 totalMs + 3s（防死循环）。
      const drainDeadline = Date.now() + totalMs + 3000;
      while (!this.abortFlag && Date.now() < drainDeadline) {
        if (this.pausedFlag) {
          lastFrame = -1; // 暂停期间帧位静止，重置判定基准，恢复后重新计 2 个周期
          await this.sleep(100);
          continue;
        }
        const ts = this.readTs();
        if (ts !== null) {
          if (lastFrame >= 0 && ts.framePos === lastFrame) {
            break;
          }
          lastFrame = ts.framePos;
        }
        await this.sleep(TS_POLL_MS);
      }
      running = false;
      await poller;
      return;
    }

    // ---------- 旧路径（默认）----------
    // P1 功耗自检：计时写循环。`pausedMs` 扣除暂停等待，避免污染 writeMs 判据。
    const pwT0: number = Date.now();
    let pwPausedMs: number = 0;
    let pwWrites: number = 0;
    while (off < bytes && !this.abortFlag) {
      if (this.pausedFlag) {
        const ps: number = Date.now();
        await this.sleep(100);
        pwPausedMs += Date.now() - ps;
        continue;
      }
      const n = Math.min(bufSize, bytes - off);
      // Int16Array 底层 buffer 按 2 字节/样本，直接切 ArrayBuffer 写入
      this.trackWrite(await r.write(pcm.buffer.slice(off, off + n)));
      pwWrites++;
      off += n;
      if (onPos !== null) {
        onPos(Math.max(0, Math.min(totalMs, off / bytes * totalMs)));
      }
    }
    if (POWER_SELFCHECK) {
      this.logPowerChunk(totalMs, Date.now() - pwT0 - pwPausedMs, bufSize, pwWrites);
    }
    // 排空队列中最后不到一个缓冲的残留（写循环已被实时背压节流，无需轮询位置）
    if (!this.abortFlag) {
      while (this.pausedFlag && !this.abortFlag) {
        await this.sleep(100);
      }
      await this.sleep(queueDrainMs);
    }
  }

  /**
   * P1：对一组流参数查询三种通路支持情况。
   *
   * 官方措辞（documentId `API参考/Audio_Kit_音频服务/ArkTS_API/ohos_multimedia_audio_音频管理_/
   * Interface_AudioStreamManager/arkts-apis-audio-audiostreammanager`，均 @since 26.0.0）：
   *  · `isOffloadPlaybackSupported` —— 「查询指定音频流信息和使用场景下是否支持**低功耗通路播放**」
   *  · `isDirectPlaybackSupported`  —— 「…是否支持**直通播放**」
   *  · `isFastPlaybackSupported`    —— 「…是否支持**低时延播放**」（与时延有关，**与省电相反**）
   *
   * 真机首测（2026-09-21 02:04:10，Mate 80 Pro Max）我们的参数
   * `rate=24000 ch=1 fmt=S16LE enc=RAW usage=MUSIC` 三项全 **N**。
   * `AudioEncodingType` 只有 `INVALID=-1` / `RAW=0`（`.d.ts:1178-1187`），**没有压缩类型**，
   * 故 offload 不是由编码格式决定的。⇒ 用下面的矩阵定位到底哪个参数卡住了低功耗通路。
   */
  private probeCapability(si: audio.AudioStreamInfo, usage: audio.StreamUsage, label: string): void {
    try {
      const mgr: audio.AudioStreamManager = audio.getAudioManager().getStreamManager();
      const offload: boolean = mgr.isOffloadPlaybackSupported(si, usage);
      const direct: boolean = mgr.isDirectPlaybackSupported(si, usage);
      const fast: boolean = mgr.isFastPlaybackSupported(si, usage);
      hilog.info(DOMAIN, TAG,
        'power: probe[%{public}s] rate=%{public}d ch=%{public}d -> offload=%{public}s direct=%{public}s fast=%{public}s',
        label, si.samplingRate, si.channels,
        offload ? 'Y' : 'N', direct ? 'Y' : 'N', fast ? 'Y' : 'N');
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'power: probe[%{public}s] failed %{public}s', label,
        e instanceof Error ? e.message : String(e));
    }
  }

  /** P1：构造一组探测用流信息（全部 S16LE / RAW）。 */
  private probeStreamInfo(rate: audio.AudioSamplingRate, ch: audio.AudioChannel): audio.AudioStreamInfo {
    const si: audio.AudioStreamInfo = {
      samplingRate: rate,
      channels: ch,
      sampleFormat: audio.AudioSampleFormat.SAMPLE_FORMAT_S16LE,
      encodingType: audio.AudioEncodingType.ENCODING_TYPE_RAW
    };
    return si;
  }

  /**
   * P1：一次性打印流参数 + 设备低功耗能力查询结果 + **参数矩阵**。
   * 全程 try/catch —— 任何查询失败都不得影响播放（这是纯诊断）。
   *
   * 矩阵目的：定位"低功耗通路"被哪个参数卡住。
   *  · 若换成 48000/44100 变 Y ⇒ 24000Hz 是瓶颈（Edge TTS 输出 24kHz），
   *    可评估"重采样到 48k 换取硬件低功耗通路"是否划算；
   *  · 若换立体声变 Y ⇒ 声道数是瓶颈；
   *  · 若全 N ⇒ 本机型/本 usage 组合下低功耗通路不可用，优化重心转向网络与调度。
   */
  private logPowerCapability(options: audio.AudioRendererOptions): void {
    try {
      const si: audio.AudioStreamInfo = options.streamInfo;
      const usage: audio.StreamUsage = options.rendererInfo.usage;
      const flags: number = options.rendererInfo.rendererFlags;
      hilog.info(DOMAIN, TAG,
        'power: create rate=%{public}d ch=%{public}d fmt=%{public}d enc=%{public}d usage=%{public}d flags=%{public}d',
        si.samplingRate, si.channels, si.sampleFormat, si.encodingType, usage, flags);
      // 我们实际使用的参数
      this.probeCapability(si, usage, 'actual');
      // 参数矩阵（S16LE / RAW / 同一 usage）
      this.probeCapability(this.probeStreamInfo(audio.AudioSamplingRate.SAMPLE_RATE_48000,
        audio.AudioChannel.CHANNEL_1), usage, '48k/mono');
      this.probeCapability(this.probeStreamInfo(audio.AudioSamplingRate.SAMPLE_RATE_48000,
        audio.AudioChannel.CHANNEL_2), usage, '48k/stereo');
      this.probeCapability(this.probeStreamInfo(audio.AudioSamplingRate.SAMPLE_RATE_44100,
        audio.AudioChannel.CHANNEL_2), usage, '44.1k/stereo');
      this.probeCapability(this.probeStreamInfo(audio.AudioSamplingRate.SAMPLE_RATE_16000,
        audio.AudioChannel.CHANNEL_1), usage, '16k/mono');
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'power: capability query failed %{public}s',
        e instanceof Error ? e.message : String(e));
    }
  }

  /**
   * P1：每块播放打印一次"有效缓冲"判据。
   * `slack = pcmMs - writeMs ≈ min(pcmMs, 有效缓冲容量)`，判读见 `POWER_SELFCHECK` 注释。
   */
  private logPowerChunk(pcmMs: number, writeMs: number, bufSize: number, writes: number): void {
    const r = this.renderer;
    hilog.info(DOMAIN, TAG,
      'power: chunk pcmMs=%{public}d writeMs=%{public}d slack=%{public}d bufSize=%{public}d writes=%{public}d state=%{public}d',
      Math.round(pcmMs), Math.round(writeMs), Math.round(pcmMs - writeMs), bufSize, writes,
      r === null ? -2 : r.state);
  }

  /**
   * T1-D2：记录一次写入结果。`write()` 官方返回"写入字节数"，`<= 0` 即失败。
   * 连续失败达 `STREAM_DEAD_FAIL_STREAK` 次即判定流已死（只打一次日志，避免刷屏）。
   */
  private trackWrite(written: number): void {
    if (!INTERRUPT_REBUILD_WHEN_STUCK) {
      return; // 开关关闭时完全不介入（零副作用）
    }
    if (written > 0) {
      this.writeFailStreak = 0;
      this.streamDeadLogged = false;
      return;
    }
    this.writeFailStreak = this.writeFailStreak + 1;
    if (this.writeFailStreak >= STREAM_DEAD_FAIL_STREAK && !this.streamDeadLogged) {
      this.streamDeadLogged = true;
      hilog.warn(DOMAIN, TAG, 'stream dead: %{public}d consecutive writes returned <= 0', this.writeFailStreak);
    }
  }

  /** T1-D2：底层音频流是否已判定为死（供 `TtsEngine` 决定是否兜底重建）。 */
  streamDead(): boolean {
    return INTERRUPT_REBUILD_WHEN_STUCK && this.writeFailStreak >= STREAM_DEAD_FAIL_STREAK;
  }

  /**
   * T1-D4：渲染器是否处于「可原地续播」的暂停态。
   *
   * 真机证据（2026-09-21 01:13 日志，进程 19666）：
   *  · 微信场景（`hint=2` 临时失焦 → 本类 `pause()`）：
   *    `01:13:40.728 resume: renderer state=5 pausedFlag=false` ⇒ `STATE_PAUSED=5`
   *    ⇒ 原地 `start()` 成功，`01:13:40.729 Renderer::Start` ⇒ **无缝续播**。
   *  · 抖音/汽水音乐场景（`hint=3` **永久**失焦）：渲染器不是暂停态
   *    ⇒ 原地续播不成立，必须重建管线（`TtsEngine.resume()` 据此分流）。
   *
   * 官方枚举取值：`@ohos.multimedia.audio.d.ts:242-298`
   *   `STATE_INVALID=-1 / STATE_PREPARED=1 / STATE_RUNNING=2 / STATE_STOPPED=3 /
   *    STATE_RELEASED=4 / STATE_PAUSED=5`
   */
  canResumeInPlace(): boolean {
    const r = this.renderer;
    return r !== null && r.state === audio.AudioState.STATE_PAUSED;
  }

  pause(): void {
    this.pausedFlag = true;
    const r = this.renderer;
    if (r !== null && r.state === audio.AudioState.STATE_RUNNING) {
      try {
        r.pause();
      } catch (e) {
        // 忽略
      }
    }
  }

  resume(): void {
    // 先存 pausedFlag 前值：原实现里日志字段在 this.pausedFlag=false 之后打印，
    // 永远只看到 'false'，误把"AVSession on('play') / on('pause') 派发"判成"应用不知道被暂停了"。
    const prePaused: boolean = this.pausedFlag;
    this.pausedFlag = false;
    this.writeFailStreak = 0;
    this.streamDeadLogged = false;
    const r = this.renderer;
    // T1-D1 取证日志：真机确认 r.state 的真实取值（不改变行为）
    hilog.info(DOMAIN, TAG, 'resume: renderer state=%{public}d prePaused=%{public}s',
      r === null ? -2 : r.state, prePaused ? 'true' : 'false');
    if (r !== null && r.state === audio.AudioState.STATE_PAUSED) {
      try {
        r.start();
      } catch (e) {
        hilog.warn(DOMAIN, TAG, 'renderer resume err %{public}s', JSON.stringify(e));
      }
    }
  }

  /** 停止当前段（清空队列）；下一段 play 时重新 start */
  stop(): void {
    this.abortFlag = true;
    this.pausedFlag = false;
    const r = this.renderer;
    if (r !== null) {
      const s = r.state;
      if (s === audio.AudioState.STATE_RUNNING || s === audio.AudioState.STATE_PAUSED) {
        try {
          r.stop();
        } catch (e) {
          // 忽略
        }
      }
    }
  }

  private sleep(ms: number): Promise<void> {
    return new Promise<void>((resolve: () => void) => {
      setTimeout(resolve, ms);
    });
  }
}
