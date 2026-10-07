/**
 * TTS 朗读引擎（对齐 PC 版管线：合成 → MP3 解码 → 标点停顿 PCM 拼接 → AudioRenderer 流播）。
 *
 * - 一条 run() 协程按"章 → 段"推进；pause/resume 只是播放器级操作，绝不重启协程；
 * - 800 字大块合成（请求数与 PC 一致），停顿在 PCM 内完成，零切换间隙；
 * - 面板"当前句"由 WordBoundary + 拼接后时间轴换算，句级更新；
 * - 只有 stop/seek 需要打断协程（sessionGen + abort）；
 * - 预取只预合成（写缓存），失败打日志不静默；AI 男女声识别每章一批。
 */
import { avSession as avSessionKit } from '@kit.AVSessionKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { wantAgent, common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { bookParser } from '@kit.ReaderKit';
import { util } from '@kit.ArkTS';
import { synthesizeOnce, hasSpeakableText, WordSpan } from './EdgeTtsClient';
import { splitParagraphIntoSegments, splitSegmentsIntoChunks, SpeakSegment } from './SentenceSplitter';
import { buildChapterNodes } from './ChapterNodes';
import { TtsPrefs } from './TtsPrefs';
import { classifyDialogueGenders, SpeakerItem } from './TtsSpeaker';
import { decodeMp3ToPcm, PcmDecodeResult } from './NativeDecoder';
import { synthesizeLocalWav, LOCAL_TTS_SAMPLE_RATE } from './LocalTtsClient';
import { ListenUnlock } from '../common/utils/ListenUnlock';
import { computePausePoints, applyPauses, buildSentenceTimeline, lookupOrigMs } from './PauseSplicer';
import { PcmPlayer, INTERRUPT_REBUILD_WHEN_STUCK } from './PcmPlayer';

const DOMAIN = 0x0001;
const TAG = 'TtsEngine';
/** 连续失败多少段后自动暂停 */
const FAIL_STREAK_PAUSE = 5;
/** 单章合成块上限，防御异常大章节 */
const MAX_CHUNKS_PER_CHAPTER = 300;

/**
 * ── T1-B 长时任务安全生命周期开关 ────────────────────────────────────────
 * **默认 false = 旧行为**（只用 `bgRunning` 做守卫）。后台/系统行为无法本地验证，
 * 故新路径默认关闭；真机验证通过后再改为 true。任何异常改回 false 即完全回退。
 *
 * **旧实现的竞态（代码级可证）**：
 *   `startBackground()` 的 `bgRunning = true` 写在 `startBackgroundRunning(...).then()` **里面**，
 *   即**异步完成后**才置位；而 `stopBackground()` 的守卫是 `if (!TtsEngine.bgRunning) return;`。
 *   ⇒ 在"启动链尚未落地"的窗口内调用 `stopBackground()`，会被**直接跳过**，
 *     随后 `bgRunning` 又被置为 `true` —— 应用**永久持有一个 AUDIO_PLAYBACK 长时任务**。
 *
 * **为什么必须修（官方原文）**：
 *   documentId `最佳实践/应用功耗优化/后台任务低功耗/后台软件资源合理使用/后台音频播放合理使用/bpta-reasonable-audio-playback-use`：
 *     "申请音频播放长时任务的应用退到后台后，**禁止不写入数据或写入静音数据等恶意行为**。"
 *     "**约束**：系统检测到应用后台行为时，将**挂起或清理应用**。"
 *   另 documentId `.../后台软件资源使用/standard-background-software` 同款表述。
 *
 * **新路径做法**：把整条启动链（`getWantAgent` + `startBackgroundRunning`）记进 `bgStarting`；
 *   `stopBackground()` 若发现启动仍在进行，则**等它落地后立刻取消**（无论成败），
 *   保证"停止"这一意图最终一定生效。
 *
 * 验证点（翻 true 后真机验证）：
 *  1. 播放后**立刻**停止 → 日志不应出现"长时任务残留"（可用 `devecocli log` 观察 backgroundTaskManager 相关日志），
 *     且退到后台后系统不再把应用视为持任务状态；
 *  2. 正常长时间后台朗读**不受影响**（不得出现播放中被挂起）；
 *  3. 自然读完（全书/定时章节数/睡眠定时）后长时任务确实被取消。
 */
const BG_TASK_SAFE_LIFECYCLE: boolean = false;

/**
 * ── T1-C1 长时任务「通知可见性」开关 ────────────────────────────────────────
 * **默认 false = 旧行为**（`startBackgroundRunning(ctx, BackgroundMode.AUDIO_PLAYBACK, agent)`，
 * 返回 `Promise<void>`，**拿不到 notificationId**）。
 * 新路径改用返回 `ContinuousTaskNotification` 的重载，把 notificationId 打进日志。
 *
 * 官方 SDK 证据（真机 SDK，非 ohpm 缓存）：
 *   `D:\Program Files\Huawei\DevEco Studio\sdk\default\openharmony\ets\api\@ohos.resourceschedule.backgroundTaskManager.d.ts`
 *   - L771 `function startBackgroundRunning(context: Context, bgModes: string[], wantAgent: WantAgent): Promise<ContinuousTaskNotification>;`（@since 12）
 *   - L314/340 `interface ContinuousTaskNotification { ... notificationId: number; }`（@since 12）
 *     其中 notificationId 的字段说明原文为 "ID of the continuous-task notification."
 *   - L153「Continuous task ID. **The default value is -1.**」⇒ `-1` 系官方语义中的"未赋值/无效"哨兵
 *   - L764 `@throws { BusinessError } 9800006 - Notification verification failed for a continuous task.`
 *
 * 真机日志线索（`日志.md`，tag `C01711/...CONTINUOUS_TASK` 经官方 FAQ
 * `FAQ/程序框架/后台任务开发_Background_Tasks/如何查询后台任务中短时任务_长时任务_延迟任务_后台代理提醒相关的系统日志/faqs-background-tasks-9`
 * 确认即"长时任务"）：
 *   L988   23:03:10.241 `[StartBackgroundRunningExecuteCB:306] notification 42,  continuousTaskId 280`  → 锁屏 2 分 22 秒未被杀
 *   L12401 23:06:07.128 `[StartBackgroundRunningExecuteCB:306] notification -1,  continuousTaskId 281`  → 停止后仅 13 秒即再次申请
 *   L19502 23:53:05.901 `[StartBackgroundRunningExecuteCB:306] notification 43,  continuousTaskId 282`
 * 且本文件自身 `bg task err` / `wantAgent err` 在 `日志.md` 中**零命中** ⇒ 旧重载 Promise 成功返回、
 * `notification -1` 发生在系统内部，应用侧**不可见**。
 *
 * `bgModes` 取值证据（documentId `开发指南/Background_Tasks_Kit_后台任务开发服务/长时任务_ArkTS/continuous-task`，
 * 「表1 长时任务类型」：`AUDIO_PLAYBACK` 对应**配置项** `audioPlayback`）。
 *
 * 验证点（翻 true 后真机验证）：
 *  1. 日志应出现 `bg task started notificationId=<>=0 的数> taskId=<>=0 的数>`；
 *  2. 若翻 true 后拿到 `notificationId=-1`，说明系统确实没给通知（问题复现），需转向提交工单；
 *  3. 若拿到正数且后台不再被杀，则根因确认为"通知未创建"。
 * 任何异常改回 false 即完全回退（旧重载，行为逐字不变）。
 */
const BG_TASK_NOTIFICATION_AWARE: boolean = false;

/**
 * ── T1-C2 长时任务「重复申请最小间隔」保护 ──────────────────────────────────
 * **默认 false = 旧行为**（立即申请，不做任何延时）。
 * 新路径：若距上次 `stopBackground()` 不足 `BG_TASK_MIN_RESTART_INTERVAL_MS`，
 * 则**延后**到间隔满足后再申请（而不是放弃申请——放弃会导致彻底没有后台保护）。
 *
 * 官方依据（documentId `开发指南/Background_Tasks_Kit_后台任务开发服务/Background_Tasks_Kit接入规范/bgtask-design-formula`，
 * 「长时任务使用基本原则」原文）：
 *   「**不得在用户主动停止（通过删除长时任务通知、删除AVSession通知等方式）并取消长时任务后，立即再次申请长时任务。**」
 *   「不得在系统检测到应用不合理使用长时任务，并取消/暂停长时任务后，立即再次申请长时任务。」
 * 真机日志对应：`日志.md` L11011 `23:05:54.527 [RequestStopBackgroundRunning:201] ... continuousTaskId: -1.`
 *   → L12401 `23:06:07.128`，间隔仅 **13.399 秒**。
 *
 * 验证点（翻 true 后真机验证）：
 *  1. 播放→停止→立刻再播放，日志应出现 `bg restart deferred <ms>`，且延时后才出现长时任务申请；
 *  2. 延时窗口内音频应正常播放（此时应用在前台，不依赖长时任务）；
 *  3. 正常"停止后隔很久再播"不受影响（间隔已满足，立即申请）。
 * 任何异常改回 false 即完全回退。
 */
const BG_TASK_RESTART_GUARD: boolean = false;
/** 最小重复申请间隔（毫秒）。取值依据：真机观测到的违规间隔为 13.399 秒，故取 15 秒留余量。 */
const BG_TASK_MIN_RESTART_INTERVAL_MS: number = 15000;

/**
 * ── T2 网络韧性新路径（2026-09-24）：熄屏/后台听书「卡死不恢复」修复 ─────────
 * **true = 新路径已启用**（2026-09-25 经用户确认开启：真机实测旧路径"疯狂跳段后暂停"
 * 不符合需求，垫片方案为其指定替代；此前 false 默认导致 09-24 18:17 实测仍走旧路径）。
 * 旧行为（逐字保留在代码里，改回 false 即恢复）：doSynth 固定 3 次重试(250/500/750ms
 * 退避)、循环层合成失败即跳句(`i++`)、连续 5 次失败转 paused 后只等人工恢复。
 *
 * 真机日志证据（`C:\Users\Administrator\Downloads\1.md`，2026-09-24 16:02–16:29）：
 *  · 16:04:50→16:06:07 与 16:13:19→16:25:23 两处进程级冻结（XCollie 心跳分别落后
 *    50s/465s），第二处冻结时音频仍在写 PCM ⇒ 熄屏挂起把整条链路冻住；
 *  · 16:29:36 `synth fail #1: 连接错误` 后直接跳句（该块文本被无声丢弃）。
 *
 * 官方依据（原文）：
 *  · `开发指南/Background_Tasks_Kit_后台任务开发服务/长时任务_ArkTS/continuous-task`
 *    「应用申请AUDIO_PLAYBACK类型长时任务，退至后台时，如果设备没有有效音频播放，
 *    应用可能被系统冻结。」
 *    ⇒ underrun（缓冲耗尽）即触发冻结，只能靠**更深的合成预取**加厚安全垫。
 *  · `最佳实践/应用功耗优化/…/网络资源低功耗建议/bpta-network-resources`
 *    「建议预加载的片源数量不超过5个以优化功耗。」⇒ 预取深度取 4。
 *
 * 新路径内容（各子开关只在本常量为 true 时生效）：
 *  1. 预取 2 → `NET_PREFETCH_AHEAD`(4) 块；
 *  2. doSynth 重试 3 → `NET_RETRY_ATTEMPTS`(4) 次，退避 500ms 指数递增（覆盖
 *     link-down 场景 ~3.2s 的握手失败墙钟，旧 250/500ms 退避 3 次约 10s 即烧光）；
 *  3. 循环层失败**原地重试同一块**，不再跳句丢内容；
 *  4. 网络暂停后每 `NET_PAUSE_PROBE_MS`(30s) 自动探活，成功即自动续播
 *     （熄屏挂起期间定时器冻结无妨：唤醒后第一轮探活即接上）；
 *  5. 注册 `backgroundTaskManager.on('continuousTaskSuspend'/'continuousTaskActive')`
 *     （SDK @since 20，`SYSTEM_SUSPEND_AUDIO_PLAYBACK_NOT_RUNNING=6` 即本场景），
 *     挂起/激活落日志，激活时立即触发一次探活。
 *
 * 真机验证（2026-09-25 00:35，pid 59556，用户实测通过，日志 `Downloads/1.md`）：
 *  · 断网 ~00:35:35，doSynth 4 次指数退避烧完（~16s 抗抖窗口）后转网络暂停路径；
 *  · `synth fail #1` 首次失败即进静音垫片（不跳句）；恢复后从同一 chunk=4 续播；
 *  · 与 TTS_SILENCE_KEEPALIVE 协同的完整行为记录（垫片全程顶上、零挂起）见下一开关注释；
 *  · 正常网络下块间无新增停顿。
 * 尚待长时验证：断网 1 小时极限场景。
 * 任何异常改回 false 即完全回退（三个子行为全部回到旧路径）。
 */
const TTS_NET_RESILIENCE: boolean = true;
/** 新路径预取深度（含当前块的后续块数）。官方功耗口径 ≤5，取 4。 */
const NET_PREFETCH_AHEAD: number = 4;
/** 新路径 doSynth 重试次数（旧路径 3 次）。 */
const NET_RETRY_ATTEMPTS: number = 4;
/** 新路径网络暂停后的自动探活周期（毫秒）。 */
const NET_PAUSE_PROBE_MS: number = 30000;
/**
 * 距最近一次网络失败不足该窗口 ⇒ 播放点跳过 doSynth 重试、直接进垫片。
 * 依据（09:51 实测）：断网后预取失败即实锤，若等到播放点再走 doSynth 的
 * 4 次退避重试（~8s），期间"渲染器已空 + 应用退避睡眠"= 冻结窗口——熄屏下
 * 3 秒即被系统挂起（gap 31s，垫片音乐迟迟不起）。跳过后垫片在书排干的瞬间
 * （~0.3s）接上，渲染器永不为空；网络是否恢复交给垫片内探活检测。
 */
const NET_SKIP_RETRY_MS: number = 120000;

/**
 * ── F4 网络失败重试退避（2026-09-29）：指数 0.5/1/2/4s → 0.3/0.6/1.2/2.4s ──────
 * 目的：**缩短探活一轮的墙钟**，从而缩短"网络已恢复但还没续播"的等待。
 *
 * 真机依据（`Downloads/2.md`，09-29 断网段 01:17:53 → 01:21:21）：
 *  · 20 轮 `silence keepalive: one probe round failed, keep padding`，间隔**不稳定**：
 *    多数 7.7~7.8s，但出现 6 次 13.8~14.3s（例：`01:18:09.453 → 01:18:23.756`）。
 *    原因正是 `doSynth` 内退避 7.5s（0.5+1+2+4）**叠加**实际握手墙钟（DNS NXDOMAIN 时
 *    NETSTACK 侧约 0.9~3.3s/次）⇒ 一轮最长可到 ~14s。
 *  · ⇒ 用户打开网络后，最坏情况要等**约 14 秒**才会重新出声。
 * 换成本数组后一轮退避 4.5s，同口径最长等待降到 ~6s 量级。
 *
 * 与旧路径的关系：`TTS_NET_RESILIENCE=false` 时仍走旧的 `250 * (attempt+1)`（250/500/750ms），
 * **旧行为逐字保留**，本常量只服务新路径。
 *
 * 回退：把 `NET_RETRY_BACKOFF_MS` 清空或改成长度 0 即回落旧公式（见 `doSynth` 分支）。
 */
const NET_RETRY_BACKOFF_MS: number[] = [300, 600, 1200, 2400];

/** 第 attempt 次失败后的退避时长。新路径查表（越界钳到末项），旧路径维持原公式。 */
function netRetryBackoffMs(attempt: number): number {
  if (!TTS_NET_RESILIENCE || NET_RETRY_BACKOFF_MS.length === 0) {
    return 250 * (attempt + 1);
  }
  const last: number = NET_RETRY_BACKOFF_MS.length - 1;
  return NET_RETRY_BACKOFF_MS[attempt > last ? last : attempt];
}

/**
 * ── T2 子开关：网络失败时「静音垫片保活」（假水池 / silence padding）──────────
 * **true = 已启用**（2026-09-25 经用户确认；此前 false 默认导致 09-24 18:17 实测仍走
 * 旧路径"疯狂跳段后暂停"）。仅 TTS_NET_RESILIENCE=true 时生效。
 * 改回 false = 回到"paused + 30s 探活"次选路径（无垫片）。
 *
 * 原理：合成断供时不暂停渲染器，而是持续写入本地生成的全零 PCM（与 Edge 输出同采样率
 * 24000Hz）。系统"一致性校验"看到的是**数据流持续、渲染器 RUNNING** ⇒ 长时任务维持，
 * 进程不被冻结；网络恢复后块边界无缝切回真实音频。
 *
 * 官方依据（原文）：
 *  · `开发指南/…/长时任务_ArkTS/continuous-task`：「若音频在后台播放时被打断（例如：
 *    焦点打断），系统会自行检测并冻结或者取消长时任务。」——口径是**焦点/数据流**，
 *    全部公开文档未见"内容级静音检测"取消长时任务的条款。
 *  · `最佳实践/…/音乐播放场景低功耗规则/bpta-music-playback-scenarios`：「音乐类应用
 *    **静音时**关闭音效处理算法」「为了避免**静音播放**时冗余音效处理算法导致的快速
 *    耗电……」——官方将静音播放视为**合法、被预期的播放场景**（若静音=无效播放，
 *    不会存在此优化建议）。
 *  · 【真机验证：36s 通过，但 ~60s 校验识破（2026-09-25 两轮实测，pid 59556）】
 *    第一轮 00:35（垫 36s）：全程零挂起、恢复 3.3s ⇒ 通过。当时结论"已验证"**下早了**。
 *    第二轮 01:12（断网全程 2m19s，缓存播完 77s 后垫片接力）：垫片本身健康扛到 01:13:33，
 *    但进程在 ~01:13:35（**静音开始后 ~58-60s**）被系统冻结（2.md XCollie 心跳滞后 164s，
 *    日志停滞即冻结），亮屏进 app 才恢复（01:16:19）→ 恢复机制正常（4s 出声）。
 *    我们注册的监听抓到现行：`continuous task suspended id=40 reason=-1`（-1 非 SDK
 *    枚举值，系统内部码）；音频服务自身有静音监测日志（`ProcessVolumeData slient`）。
 *    ⇒ **结论：系统以 ~60s 周期校验「有效音频播放」，静音输出不被认账**——渲染器
 *    RUNNING + 数据流持续只能骗过校验间隙，骗不过校验本身。00:35 通过纯属时长
 *    （36s）短于校验周期。官方文档（continuous-task）只写"音频不在播放会被挂起"，
 *    未公开静音判定细节 ⇒ 纯静音垫片仅对 <~60s 的断网抖动有效。
 *    另：01:16:32 播控中心下发暂停命令（command 1）→ 暂停 + 后台 ~60s 后再次挂起
 *    （01:17:32）并静音流（01:17:38 SetMute）——与官方"暂停时应取消长时任务，否则
 *    系统会自行检测并冻结"一致，属预期行为。
 *
 * 设计约束：探活（ensureSynth 一轮 ~20s）必须与垫静音**并行**——串行探活的空窗会把
 * 熄屏缓冲（官方上限 10000ms）抽干，冻结照样发生。
 *
 * 功耗：静音为纯本地内存写入（无 TLS/无解码），低于 Edge TTS 路径；熄屏下数据写满
 * 缓冲后 CPU 照常休眠（官方低功耗口径）。可选优化：静音期间
 * `setAudioEffectMode(EFFECT_NONE)` 关闭音效算法（本轮未实现，保持改动最小）。
 *
 * 回退：改回 false 即回到"paused+探活"路径，无其他残留。
 */
const TTS_SILENCE_KEEPALIVE: boolean = true;
/**
 * 静音垫片单块时长（秒）。短块 ⇒ 网络恢复后切换延迟 ≤ 该时长——**仅亮屏成立**
 * （亮屏渲染器缓冲 ~250ms）。熄屏下渲染器排队静音可达官方缓冲上限 10000ms，
 * 恢复后真实音频要排在队列静音之后 ⇒ 恢复延迟可达 ~10s（01:12 实测推断，
 * 【待真机确认】）。候选优化（未实现）：恢复成功瞬间 stop/flush 渲染器丢弃排队
 * 静音，把熄屏恢复延迟也压回秒级。
 */
const SILENCE_CHUNK_SEC: number = 2;

/**
 * ── T2 子开关：垫片改用「低音量可听噪声」而非纯静音（B1 实验，2026-09-25）────
 * **true = 已启用**（用户拍板 5% 幅度）。false = 纯静音——已被实测否决为"仅 ~60s 内有效"。
 *
 * 证据链（1.md/2.md，pid 59556）：
 *  · 音频服务对输出流逐缓冲做静音分类：`[ProcessVolumeData][RendererInClient] slient`
 *    ⇔ `not slien[t]`——垫纯静音被归为 slient；
 *  · 系统以 ~60s 周期校验 AUDIO_PLAYBACK「有效音频播放」，静音 ⇒ 挂起长时任务
 *    （`continuous task suspended id=40`，XCollie 心跳滞后 164s，亮屏才恢复）；
 *  · 非全零 PCM 翻转该分类 ⇒【真机已验证】(2026-09-25 01:59–02:04，pid 20834)：
 *    垫片启动后 79ms，音频服务日志实锤翻转——`slient 38frames change to not slient`
 *    (02:01:08.909)；此后 **206 秒垫片（26 轮探活）流持续 not slient、零分类回翻**
 *    （下一次翻转在垫片结束的过渡间隙，`not slient 10300frames change to slient`）。
 *    全程 `continuous task suspended` 0 次、XCollie 零滞后、无 ≥15s 空洞——对照纯静音
 *    轮 ~58s 即被挂起，本命题成立。恢复时序不变：OnOpen → synth ok 0.9s → 垫片收尾，
 *    同 chunk 续播。1 小时极限场景由该机制外推应成立（校验读的是流的持续可听态），
 *    如需盖章可拉长测。若嫌 5% 底噪偏响：分类口径实为"逐帧非全零"，幅度可降（2-3%
 *    理论上同样翻转），改 PAD_NOISE_LEVEL 即可。
 *
 * 合规面：强制阶梯（官方）只有挂起/冻结/静音流，无"封禁"；接入规范要求任务类型
 * 与实际行为一致——AUDIO_PLAYBACK + 在播音频（垫片内容）成立。功耗与纯静音完全
 * 相同（同写入同唤醒、零射频）。
 *
 * 听感：白噪过单极低通 ⇒ 柔和粉噪（近似远处风雨声），5% 幅度安静环境可闻不扰人。
 * 回退：改回 false = 纯静音垫片（60s 内抖动仍有效，无其他残留）。
 */
const TTS_PAD_AUDIBLE: boolean = true;
/** 垫片噪声幅度（满刻度比例）。5% ≈ -26dBFS；用户拍板取 5% 而非 2%（阈值未知，取稳）。 */
const PAD_NOISE_LEVEL: number = 0.05;

/**
 * ── T2 子开关：垫片自定义音频（rawfile/pad.mp3，2026-09-25）────────────────
 * **文件即开关**：rawfile/pad.mp3 存在 ⇒ 用它当垫片（用户已确认所选片段无静音段）；
 * 删除/缺失/解码失败 ⇒ 自动回退 TTS_PAD_AUDIBLE 粉噪 ⇒ 纯静音。三级自动降级。
 *
 * 自动处理链（对用户透明，任意来源 mp3 皆可）：
 *  立体声折叠 → 重采样 24k 单声道（与 TTS 输出一致，避免垫片⇄语音切换重建渲染器）
 *  → 软上限 60s 截断 → 峰值归一 PAD_CLIP_PEAK(15% FS) → 接缝 8ms 淡入淡出
 *  → 近零段扫描（仅告警，不混噪声底）。
 *
 * 【按用户要求：自定义片段不垫噪声底】此前垫 1.5% 底是为防安静段被音频服务按帧
 * 计数翻回 slient（2.md `not slient 10300frames change to slient` 实证）；用户选定
 * 的片段保证无静音 ⇒ 撤底垫。加载时扫描最长近零段并落日志：>200ms 告警（可能
 * 触发 slient 回翻 → ~60s 挂起），选材有坑日志立刻可见。
 * 8ms 接缝淡出经真机验证安全（206s/百次接缝零回翻，粉噪路径同款处理）。
 *
 * 选材建议：24k 单声道可省重采样；60s 内；首尾与内部避免大段安静（扫描会告警）。
 */
const PAD_CLIP_RAWFILE: string = 'pad.mp3';
/** 垫片片段峰值归一（满刻度比例）：任意来源 mp3 拉到同一响度。 */
const PAD_CLIP_PEAK: number = 0.15;
/** 近零段告警阈值（毫秒）：片段内连续低于 0.1% FS 的区间超过该值 ⇒ 日志告警。 */
const PAD_CLIP_SILENT_WARN_MS: number = 200;
/** 静音采样率：与 Edge 输出 `audio-24khz-48kbitrate-mono-mp3` 一致（渲染器匹配）。 */
const SILENCE_SAMPLE_RATE: number = 24000;

/**
 * ── F5 垫片素材时长上限（2026-09-29）：60s → 120s ────────────────────────────
 * 原上限 60s 会把素材**静默截断**。真机日志实证（`Downloads/2.md` 09-29 01:17:48）：
 *   `pad clip too long 60081.625000ms -> truncate 60s`
 * 用户素材实际 60081.6ms，**只差 81.6ms 就被砍掉尾部**。放宽到 120s 后该截断不再发生。
 *
 * 代价（内存）：24kHz × 单声道 × S16LE × 120s ≈ **5.76MB** Int16Array。
 * 一次性构建、全程缓存复用（`padSlices`），断网第二次起零成本。
 * 回退：改回 60 即恢复原行为。
 */
const PAD_CLIP_MAX_SEC: number = 120;

/**
 * ── F1 垫片 PCM 构建「主线程让出」间隔（2026-09-29，真机日志驱动）────────────
 * 数值 = 每次 `await sleep(0)` 之间处理的**样本数**。按 24k 输出样本计，
 * 16384 样本 ≈ 683ms 音频，单次同步片约 0.5~3ms，让出一次 ⇒ 主线程保持可响应。
 *
 * 为什么必须做 —— 真机物证（`Downloads/2.md`，09-29，pid 23297）：
 *  · `01:17:53.276 XCollie MainThread TraceCollector ... Duration Time: 11881 ms`
 *    `01:17:53.276 BlockMonitor event name: DecodeMp3, Duration Time: 11881 ms`
 *    ⇒ 垫片 PCM 处理把**主线程堵死 11.88 秒**；
 *  · `01:17:45.526 AppDfr ... THREAD_BLOCK_3S` + `NotifyAppFault:THREAD_BLOCK_3S`
 *    ⇒ 触发系统冻结告警（这正是"日常掉后台"的物证）；
 *  · `01:17:53.277 [DfxWriteInterval] write interval too long cost 13556`
 *    ⇒ 同期渲染器 13.5 秒没收到任何数据，音频彻底断流；
 *  · 断流区间内 `IncSoundData` **零命中**（该计数仅在"有声音数据"时打印）。
 *
 * 阻塞源：`pad.mp3` 的解码虽是异步 NAPI（`ttsdec.cpp:381 napi_queue_async_work`），
 * 但**解码之后的全部重活都是同步 ArkTS 大循环**——立体声折叠、线性重采样、
 * 峰值扫描、逐样本归一+淡入淡出、近零段扫描、切片。
 * 60s / 44.1kHz / 立体声素材 ⇒ 源样本 264.9 万，重采样后 144 万，多趟循环合计**数百万次迭代**，
 * 中间没有任何 `await` ⇒ 主线程完全不可响应。
 *
 * 本常量把上述每一趟循环都切成 ≤16384 样本的片，片间 `await TtsEngine.sleep(0)` 让出事件循环。
 * **计算结果逐位不变**（同样的输入→同样的输出），只改变调度，故无音频行为风险。
 * 让出总开销 ≈ (144万×4 + 265万)/16384 ≈ 515 次 × ~4ms ≈ 2s 墙钟（仅首次断网一次，之后走缓存）。
 *
 * ── 2026-09-29 第二次真机取证：16384 → 65536（熄屏后台定时器节流）──────────────
 * 新日志（`Downloads/2.md` 16:11:54–16:11:59，pid 36723，**锁屏 + 后台**）实测对比：
 *  · 亮屏前台（pid 4088，01:43:15）：`decodeMs=382 yieldMs=1208 wallMs=1607`，零冻结告警；
 *  · 熄屏后台（pid 36723，16:11:59）：`decodeMs=735 **yieldMs=4314** wallMs=5079`
 *    + `XCollie BlockMonitor event name: **uvLoopTask, Duration Time: 4146 ms**`
 *    + `AppDfr NotifyAppFault:THREAD_BLOCK_3S` + 额外的 `MAIN_THREAD_JANK_…txt`。
 * ⇒ 让出总耗时从 1.2s 涨到 4.3s：**515 次让出里至少有一次被系统压了 4.1 秒**
 *   （让出本身不阻塞，但熄屏后台下 `setTimeout(0)` 会被节流/延后，等效于一次 4.1s 停顿）。
 *   这不是 JS 大循环（已被切片到毫秒级），而是系统调度延迟。
 *
 * 对策：**减少让出次数**。65536 样本 ≈ 2.73 秒音频，单次最重的片（立体声折叠，
 * 65536 次读交错数组）约 2~3ms，仍远低于 XCollie 的 3s 阈值；
 * 让出次数 515 → ≈150 次，削减约 3.5 倍，被节流放大的机会同步减少。
 * 让出间隔 = 同步片耗时的上千倍，主线程可响应性不受影响。
 * 音频侧本就不受影响（垫片已由 F2 预热，实测断网前 19 秒即构建完毕）。
 *
 * 回退：设成 `Number.MAX_SAFE_INTEGER` 即等价于"永不切分"（回到旧的单趟大循环行为）；
 *       设回 16384 即回到本轮之前的取值。
 */
const PAD_BUILD_YIELD_SAMPLES: number = 65536;

/**
 * ── F1 辅助：垫片构建期间的让出点 ────────────────────────────────────────────
 * `setTimeout(0)` 归还事件循环（与 `TtsEngine.sleep` 同款实现，只是不引入类依赖）。
 * 每片处理 65536 个输出样本 ≈ 2.73 秒音频，最重的一趟同步耗时约 2~3ms，
 * 让出后主线程可正常处理输入/渲染/定时器。
 * ⚠️ 熄屏后台下 `setTimeout(0)` 本身可能被系统压到秒级（见上面 65536 的取证），
 *    故让出次数越少越好 —— 这是本常量取值偏大的唯一原因。
 */
async function padYield(): Promise<void> {
  await new Promise<void>((resolve: () => void): void => {
    setTimeout(resolve, 0);
  });
}

/**
 * ── T1-A4 AVSession 完整接入开关 ──────────────────────────────────────────
 * **默认 false = 旧行为**（只设 metadata + 注册 play/pause/stop）。
 * 系统播控行为无法本地验证，故新路径默认关闭；真机验证通过后再改为 true。
 * 任何异常改回 false 即完全回退。
 *
 * 官方依据（原文）：
 *  · 最佳实践 `最佳实践/音频和视频/音频播放系列开发实践/基于AudioRenderer播放PCM音频/bpta-playing-pcm-audio-based-audiorenderer`
 *    §接入播控中心：
 *      步骤 3：`this.aVSession.setLaunchAbility(agent);`
 *        （`wantAgentInfo` 用 `operationType: wantAgent.OperationType.START_ABILITIES`）
 *      步骤 4：注册 `on('play'|'pause'|'playNext'|'playPrevious'|'seek'|'setLoopMode'|'toggleFavorite')`
 *  · SDK `@ohos.multimedia.avsession.d.ts`：
 *      `:434 setLaunchAbility(ability: WantAgent): Promise<void>`
 *      `:897 on(type: 'playNext', callback: () => void): void`
 *      `:927 on(type: 'playPrevious', callback: () => void): void`
 *      `:1236 on(type: 'seek', callback: (time: number) => void): void`
 *      `:3443 AVPlaybackState.position?: PlaybackPosition`
 *      `:3542 interface PlaybackPosition { elapsedTime: number; updateTime: number; }`（单位 ms）
 *  · 官方 FAQ `faqs-avsession-15` 场景三：「应用未正确注册播控中心通知回调，
 *    或者未及时将应用状态上报播控中心，导致后台播放状态异常。」

 * **本轮只做两件语义无歧义的事**（其余见下方"不做"说明）：
 *  ① `setLaunchAbility` —— 从播控中心点按可拉起应用；
 *  ② `playNext` / `playPrevious` —— 映射到**下一章 / 上一章**（复用 `seekToChapter`，
 *     与面板 `ReaderPage3.ttsSeekChapter` **完全同逻辑**）。
 *
 * **本轮刻意不做（已在审计 §1 T1-A4 记录理由）**：
 *  - `duration`：TTS 是流式合成，**章的音频总时长事先不可知**；填一个估算值会让进度条撒谎。
 *  - `position` + `on('seek')`：官方 FAQ `faqs-avsession-2` 明确"进度显示和控制"需要
 *    **时长 + seek 回调**配套；缺 duration 时单报 position 无意义。
 *  - `setLoopMode` / `toggleFavorite`：与本应用语义不符。
 *
 * 验证点（翻 true 后真机验证）：
 *  1. 播控中心出现"上一首/下一首"按钮，点按能切章且**章节标题跟着变**；
 *  2. 退出应用后，从播控中心点按能**拉起应用**；
 *  3. 原有 播放/暂停/停止 三个按钮行为不变。
 */
const AVSESSION_FULL_CONTROL: boolean = false;

export type TtsState = 'stopped' | 'playing' | 'paused';

export interface TtsCallbacks {
  onState: (state: TtsState) => void;
  /** 朗读章节推进（spine 下标 + 章节名），UI 据此跟随跳章 */
  onChapter: (spineIndex: number, title: string) => void;
  /** 章内进度：第 segIndex/total 块 + 当前句文本（拼接后时间轴换算） */
  onSegment: (segIndex: number, total: number, text: string) => void;
  /** 句内字符进度：已读到该句第 charInSentence 个字（共 sentenceLen），供浮条实时前滚 */
  onProgress: (charInSentence: number, sentenceLen: number) => void;
  onToast: (msg: string) => void;
}

interface QueueChunk {
  text: string;
  isDialogue: boolean;
  endsSentence: boolean;
  /** ReaderKit 块节点下标（0 基，即 domPos 的 X-1）——唯一的段落坐标系 */
  nodeIndex: number;
  /** 节点内字符偏移（即 domPos 的 Y） */
  charStart: number;
  voiceId: string;   // 本块使用的音色（AI 识别后按男/女改写）
  words: WordSpan[]; // 合成返回的词级时间戳（停顿拼接/句级显示用）
  cachePath: string; // '' 表示无可读内容，直接跳过
}

/** 当前朗读位置（ReaderKit 坐标系：spine / 块节点 / 节点内字符） */
export interface TtsSegmentPos {
  spineIndex: number;
  nodeIndex: number;
  charStart: number;
}

export class TtsEngine {
  private static context: common.UIAbilityContext | null = null;
  private static handler: bookParser.BookParserHandler | null = null;
  private static spineCount: number = 0;
  private static prefs: TtsPrefs | null = null;
  private static cb: TtsCallbacks | null = null;

  private static state: TtsState = 'stopped';
  private static sessionGen: number = 0;
  private static chapterIndex: number = 0;
  private static failStreak: number = 0;
  /** 仅 TTS_NET_RESILIENCE 新路径：本次 paused 是否由网络失败造成（true ⇒ 循环自动探活续播） */
  private static pausedByNetwork: boolean = false;
  /** 仅 TTS_NET_RESILIENCE 新路径：下次网络探活时间戳（continuousTaskActive 唤醒时置 0 立即探测） */
  private static netProbeDueAt: number = 0;
  /** 仅 TTS_NET_RESILIENCE 新路径：长时任务挂起/激活监听是否已注册（全局事件，只注册一次） */
  private static bgListenersRegistered: boolean = false;
  /** 当前是否停在"段播放中"（决定 resume 是否直接续播音频） */
  private static playingMidFile: boolean = false;
  /** 仅 TTS_SILENCE_KEEPALIVE：垫片切片队列（buildPadPcm 结果按 SILENCE_CHUNK_SEC 切片） */
  private static padSlices: Int16Array[] | null = null;
  /** 垫片当前切片下标（循环播放游标） */
  private static padSliceIdx: number = 0;
  /**
   * ── F2：垫片构建的**单飞**句柄 ───────────────────────────────────────────
   * 旧实现：`playSilenceChunk()` 里 `if (padSlices === null) padSlices = await build()`
   * ⇒ 没有任何去重。垫片循环每轮 `await playSilenceChunk()`，而构建期间主线程被占满，
   * 一旦让出（F1 之后）就可能出现**多个并发构建**，各自解码同一份 1.4MB mp3、各占 5.76MB。
   * 现在：构建只允许一份在飞，所有调用方 await 同一个 Promise；构建成功即缓存到 `padSlices`。
   *
   * 真机依据（`Downloads/2.md` 09-29）：第一轮垫片窗口（01:17:39.872 → 01:17:53.888）
   * **一条 `power: chunk pcmMs=2000`（垫片切片）都没有** —— 因为 `buildPadSlices()`
   * 把主线程占满 11.88 秒，`playSilenceChunk()` 根本没轮到执行，垫音完全没发出去。
   * 详见 PAD_BUILD_YIELD_SAMPLES 注释。
   */
  private static padBuildPromise: Promise<Int16Array[]> | null = null;
  /**
   * ── F2：垫片**预热**开关（2026-09-29）────────────────────────────────────
   * **true = 新路径**：一旦检测到网络失败（预取 catch / 兜底探活失败），
   * 就在后台开始构建垫片 PCM，**不等**播放循环真正走到垫片分支。
   *
   * 为什么要预热：`Downloads/2.md` 实证——首次预取失败（01:17:17.641）到真正进入垫片
   * （01:17:39.872）之间有 **22 秒**。这段时间书还在播（渲染器有数据），
   * 完全够把垫片建好（F1 让出后构建墙钟约 2s）。预热后进入垫片时 `padSlices` 已就绪，
   * 首片可以在 0ms 内发出，**不再出现"断网后十几秒空洞"**。
   *
   * 回退：改回 false 即回到"进垫片时才构建"（与改动前一致，只是构建本身已被 F1 切成不阻塞）。
   */
  private static readonly PAD_PREWARM: boolean = true;
  /** 最近一次网络失败时间戳（预取失败刷新/预取成功清零）。播放点据此跳过已知必败的 doSynth 重试。 */
  private static lastNetFailAt: number = 0;
  /** 正在播放的块下标（供 prevSegment 回退） */
  private static playingSegIndex: number = 0;
  /** 当前朗读的章节/块节点/节点内字符位置（回跳阅读器用，ReaderKit 坐标系） */
  private static playingSpine: number = -1;
  private static playingNode: number = -1;
  private static playingChar: number = 0;
  /** ≥0 表示段循环应跳转到该下标（prevSegment/seekToSegment 用） */
  private static segTarget: number = -1;

  private static player: PcmPlayer | null = null;

  private static synthInFlight: Map<string, Promise<number>> = new Map();
  /** 当前章的合成块队列（seekToSegment 立即更新锚点用） */
  private static currentChunks: QueueChunk[] | null = null;
  /** 当前章的 ReaderKit 块节点文本（下标 = domPos 的 X-1；文本框全文匹配定位用） */
  private static currentNodes: string[] | null = null;
  /** 观测到的最大块节点号（pageShow 自检用，0 表示尚未观测） */
  private static observedMaxNode: number = 0;
  /**
   * **旁路**章节节点缓存（2026-09-21 新增，供"书签取页首前 10 字"用）。
   *
   * 为什么不复用上面的 `currentNodes`：那是朗读高亮几何的**唯一**数据源，
   * 且按设计「未开始朗读时返回 null」（见 `currentNodeTexts()` 注释）。
   * 存书签的主体场景恰恰是**纯默读**（不开听书）⇒ `currentNodes` 恒为 null。
   * 若让书签路径去写 `currentNodes`，就会在朗读中污染高亮 ⇒ 必须分开存。
   */
  private static previewNodes: string[] | null = null;
  /** 上面那份旁路缓存对应的 spine 号（-1 = 空） */
  private static previewSpine: number = -1;
  /** 阅读器当前位置提供者（pageShow 坐标），开始/恢复播放时锚定当前页 */
  private static readerPosProvider: (() => TtsSegmentPos | null) | null = null;
  /** 暂停时刻的阅读器位置快照（判断暂停期间是否翻过页） */
  private static pausePagePos: TtsSegmentPos | null = null;
  /**
   * 本次暂停是否由**系统音频打断**造成（T1-A2）。
   * 只在 `PcmPlayer.INTERRUPT_FULL_HANDLING` 开启时被 `onResumeHint` 读取；
   * 关闭时该标记无人消费 ⇒ 行为与改动前完全一致。
   * 用于区分"系统打断后的自动续播"与"用户主动暂停不得自动恢复"。
   */
  private static interruptedBySystem: boolean = false;
  private static bgRunning: boolean = false;
  /**
   * T1-B：正在进行中的长时任务**启动链**（`getWantAgent` + `startBackgroundRunning`）。
   * 仅 `BG_TASK_SAFE_LIFECYCLE` 开启时被记录/读取；关闭时为 `null`、无人消费。
   * 用途：`stopBackground()` 若发现启动尚未落地，需等它完成后再取消，
   * 否则"启动后立刻停止"会永久泄漏一个 `AUDIO_PLAYBACK` 长时任务。
   */
  private static bgStarting: Promise<void> | null = null;
  /**
   * T1-C2：上次成功下发 `stopBackgroundRunning` 的时刻（`Date.now()` 毫秒）。
   * 仅 `BG_TASK_RESTART_GUARD` 开启时被写入/读取；关闭时恒为 0、无人消费。
   * 用途：避免落进官方明令禁止的「停止长时任务后立即再次申请」。
   */
  private static bgLastStopAt: number = 0;
  /**
   * T1-C2：被"最小间隔"推迟的长时任务申请定时器句柄（`-1` 表示无）。
   * 仅 `BG_TASK_RESTART_GUARD` 开启时被写入/读取。
   */
  private static bgRestartTimer: number = -1;
  private static avSession: avSessionKit.AVSession | null = null;
  private static bookTitle: string = '';
  /** 当前章标题（`notifyChapter` 维护；AVSession 歌词/歌手栏共用） */
  private static curChapterTitle: string = '';
  /** 当前章 spine 下标（AVSession assetId 按章区分 ⇒ 换章时歌词页整体重载） */
  private static curSpineIndex: number = -1;
  /**
   * 本章增量 LRC 行（`[mm:ss.xx]句子`）。
   * 播控中心歌词页**只认** `AVMetadata.lyric` 的标准 LRC —— 官方 FAQ 原文
   * （documentId `FAQ/音频和视频/音视频播控_AVSession/如何在播控中心显示歌词/faqs-avsession-5`）：
   * 「歌词格式必须为标准的lyric格式，其他格式不支持。」此前推的 `singleLyricText`
   * 不被该页面消费（真机实测仍显示"无歌词，请欣赏"）。
   */
  private static chapterLrcLines: string[] = [];
  /** 已追加进 LRC 的块数（首播守卫：重播/回退不重复追加） */
  private static lrcAppendedChunks: number = 0;
  /** 本章时间轴基准：已首播块的实际拼接时长累计（ms）＝下一块首句的 LRC 绝对时间 */
  private static chapterElapsedBase: number = 0;
  /** 本章已首播块数（章时长估算用） */
  private static chapterPlayedCount: number = 0;
  /** 本章块总数（playChunk 的 total；章时长估算用） */
  private static chapterTotalChunks: number = 0;
  /**
   * 章时长估算（ms，单调不减）：平均块时长 × 块总数。
   * AVMetadata.duration 的 SDK 注释原文："used to automatically calculate playback
   * position" —— 系统的 position/进度路径依赖它；TTS 无整章音频文件可探测，
   * 只能随播放逐步逼近（真机日志：不带 duration 的 position 推送在服务侧
   * `syncExecutor timeout`，歌词页因此拿不到播放位置、不滚动）。
   */
  private static chapterDurationEst: number = 0;

  // 睡眠定时（会话级，不持久化）
  private static sleepStopChapter: number = -1; // 播到该 spine 下标（不含）即停
  // ⚠️ 绝对截止时刻（墙钟，2026-10-07 用户拍板"独立倒计时"）：定时设定即定格 deadline，
  // 与播放/暂停无关——暂停也走表，到点即停。旧实现存的是"累计播放档位"（暂停表停）。
  private static sleepStopMs: number = -1;
  private static playedMs: number = 0;          // 仅播放期累计（暂停不计；LRC/统计用）
  /** 章节定时的锚点章（setSleepTimer 时的 chapterIndex）；run() 开播时发现与起点不符 ⇒ 重锚 */
  private static sleepAnchorChapter: number = -1;

  /** 定时到点后的**自清理**：残留的过期 deadline 会让下一次开播立即再停（墙钟语义特有） */
  private static clearSleepTimer(): void {
    TtsEngine.sleepStopChapter = -1;
    TtsEngine.sleepStopMs = -1;
    TtsEngine.sleepChaptersReq = 0;
    TtsEngine.sleepMinutesReq = 0;
    TtsEngine.sleepAnchorChapter = -1;
    TtsEngine.playedMs = 0;
    hilog.info(DOMAIN, TAG, 'sleep timer fired & cleared');
  }

  static init(context: common.UIAbilityContext): void {
    TtsEngine.context = context;
  }

  static getState(): TtsState {
    return TtsEngine.state;
  }

  static currentChapter(): number {
    return TtsEngine.chapterIndex;
  }

  /** 当前朗读位置（章节 + 块节点 + 节点内字符），供 UI 构造阅读器 domPos 回跳 */
  static currentSegment(): TtsSegmentPos | null {
    if (TtsEngine.state === 'stopped' || TtsEngine.playingSpine < 0 || TtsEngine.playingNode < 0) {
      return null;
    }
    const pos: TtsSegmentPos = {
      spineIndex: TtsEngine.playingSpine,
      nodeIndex: TtsEngine.playingNode,
      charStart: TtsEngine.playingChar
    };
    return pos;
  }

  /** 当前章的块节点文本（高亮几何计算用）。未开始朗读时返回 null。 */
  static currentNodeTexts(): string[] | null {
    return TtsEngine.currentNodes;
  }

  /**
   * 取指定 spine 的「ReaderKit 块节点」文本数组 —— **旁路**：不启动播放、不写朗读状态。
   *
   * 用途：存书签时取"当前页首行前 10 个字符"。旧实现只从 `currentNodeTexts()` 取，
   * 而那个值在**不开听书**时恒为 null（真机表现为书签第二行只能退回章节名）。
   *
   * 与朗读走**完全相同**的建块函数 `buildChapterNodes()`（`:730`），所以节点下标与
   * `ReaderPage3.pageRange.startNode` 同一坐标系 —— 后者本身就是从 ReaderKit 的
   * `startDomPos` 按同一套"块节点"规则换算出来的。
   *
   * ⚠️ handler 必须由调用方传入：`TtsEngine.handler` 只在 `TtsEngine.start()`（`:462`）
   * 里被赋值，纯阅读路径下它是 null，不能靠它。
   */
  static async previewNodeTexts(handler: bookParser.BookParserHandler | null,
    spineIndex: number): Promise<string[] | null> {
    if (handler === null || spineIndex < 0) {
      return null;
    }
    if (TtsEngine.previewSpine === spineIndex && TtsEngine.previewNodes !== null) {
      return TtsEngine.previewNodes; // 同章命中缓存，不重复解析
    }
    try {
      const content = await handler.getSpineItemContent(spineIndex);
      const nodes = buildChapterNodes(content).nodes;
      TtsEngine.previewNodes = nodes;
      TtsEngine.previewSpine = spineIndex;
      hilog.info(DOMAIN, TAG, 'previewNodes: spine=%{public}d nodes=%{public}d',
        spineIndex, nodes.length);
      return nodes;
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'previewNodeTexts %{public}d failed: %{public}s',
        spineIndex, e instanceof Error ? e.message : String(e));
      return null;
    }
  }

  /**
   * 一致性自检：ReaderPage3 在 pageShow 里回报该章观测到的最大块节点号（domPos 的 X），
   * 与本引擎的节点数比对。数值不符即说明节点模型与 ReaderKit 不一致，
   * 此时定位会退化到翻页搜索兜底——用它来在真机上第一时间定位问题。
   */
  static reportObservedMaxNode(x: number): void {
    if (x > TtsEngine.observedMaxNode) {
      TtsEngine.observedMaxNode = x;
    }
  }

  static parityHint(): string {
    const nodes = TtsEngine.currentNodes;
    if (nodes === null) {
      return 'nodes=?';
    }
    // observedMaxNode 已是换算后的 0 基块下标；合法范围 0..nodes.length-1
    const maxNode = TtsEngine.observedMaxNode;
    const flag = maxNode >= nodes.length ? ' MISMATCH' : '';
    return `nodes=${nodes.length} maxNode=${maxNode}${flag}`;
  }

  static setCallbacks(cb: TtsCallbacks): void {
    TtsEngine.cb = cb;
  }

  /** 注册阅读器当前位置提供者（阅读页 pageShow 坐标），用于"从当前页播放/继续" */
  static setReaderPositionProvider(provider: () => TtsSegmentPos | null): void {
    TtsEngine.readerPosProvider = provider;
  }

  /** 在块队列中找到第一个 (节点, 字符) ≥ (node, char) 的块下标 */
  private static chunkIndexForPosition(chunks: QueueChunk[], node: number,
    char: number): number {
    for (let k = 0; k < chunks.length; k++) {
      const c = chunks[k];
      if (c.nodeIndex > node || (c.nodeIndex === node && c.charStart >= char)) {
        return k;
      }
    }
    return chunks.length - 1;
  }

  /** 面板参数改动后同步：尚未合成的块立即生效（音量/停顿在下一次拼接时生效） */
  static updateConfig(prefs: TtsPrefs): void {
    TtsEngine.prefs = prefs;
  }

  private static isPlaying(): boolean {
    return TtsEngine.state === 'playing';
  }

  private static isPaused(): boolean {
    return TtsEngine.state === 'paused';
  }

  private static alive(gen: number): boolean {
    return gen === TtsEngine.sessionGen && TtsEngine.state === 'playing';
  }

  private static fileExists(path: string): boolean {
    try {
      return fs.accessSync(path);
    } catch (e) {
      return false;
    }
  }

  // ---------- TTS 磁盘缓存整理（审查发现：此前只写不删，会无限增长）----------
  /** 缓存总上限 */
  private static readonly CACHE_MAX_BYTES: number = 200 * 1024 * 1024;
  /** 两次整理的最小间隔（避免频繁扫描） */
  private static readonly CACHE_PRUNE_INTERVAL_MS: number = 60000;
  /** 最近这段时间内的文件不删（可能正在播放/排队） */
  private static readonly CACHE_PROTECT_MS: number = 5 * 60 * 1000;
  private static cacheCheckedAt: number = 0;

  /** 请求整理缓存：时间节流 + 异步执行，绝不阻塞朗读 */
  static scheduleCachePrune(): void {
    const now = Date.now();
    if (now - TtsEngine.cacheCheckedAt < TtsEngine.CACHE_PRUNE_INTERVAL_MS) {
      return;
    }
    TtsEngine.cacheCheckedAt = now;
    setTimeout((): void => {
      TtsEngine.pruneTtsCache();
    }, 0);
  }

  /** 超过上限时按 mtime 从旧到新删除（.mp3 与其 .json 词表 sidecar 一起删） */
  private static pruneTtsCache(): void {
    const ctx = TtsEngine.context;
    if (ctx === null) {
      return;
    }
    const dir = ctx.cacheDir + '/tts';
    try {
      const names = fs.listFileSync(dir);
      const paths: string[] = [];
      const sizes: number[] = [];
      const times: number[] = [];
      let total = 0;
      const now = Date.now();
      for (let i = 0; i < names.length; i++) {
        if (!names[i].endsWith('.mp3')) {
          continue;
        }
        const p = dir + '/' + names[i];
        try {
          const st = fs.statSync(p);
          const mt = st.mtime * 1000;
          if (now - mt < TtsEngine.CACHE_PROTECT_MS) {
            continue; // 最近用过的先不删
          }
          paths.push(p);
          sizes.push(st.size);
          times.push(mt);
          total += st.size;
        } catch (e) {
          // 单个文件异常：跳过
        }
      }
      if (total <= TtsEngine.CACHE_MAX_BYTES) {
        return;
      }
      // 插入排序（文件数量级不大）：按 mtime 升序 = 最旧的先删
      for (let i = 1; i < times.length; i++) {
        const t = times[i];
        const p = paths[i];
        const s = sizes[i];
        let j = i - 1;
        while (j >= 0 && times[j] > t) {
          times[j + 1] = times[j];
          paths[j + 1] = paths[j];
          sizes[j + 1] = sizes[j];
          j--;
        }
        times[j + 1] = t;
        paths[j + 1] = p;
        sizes[j + 1] = s;
      }
      let removed = 0;
      for (let i = 0; i < paths.length && total > TtsEngine.CACHE_MAX_BYTES; i++) {
        try {
          fs.unlinkSync(paths[i]);
          const side = paths[i] + '.json';
          if (TtsEngine.fileExists(side)) {
            fs.unlinkSync(side);
          }
          total -= sizes[i];
          removed++;
        } catch (e) {
          // 单个文件删不掉：继续
        }
      }
      hilog.info(DOMAIN, TAG, 'cache prune removed=%{public}d leftMB=%{public}d',
        removed, Math.round(total / 1048576));
    } catch (e) {
      // 目录不存在等：忽略
    }
  }

  /**
   * 开始朗读。startNode/startChar ≥ 0 时从起始章的该位置开始（阅读器当前页，
   * ReaderKit 坐标系），后续章节仍从章首；默认 -1 = 从章首开始。
   */
  static async start(context: common.UIAbilityContext, handler: bookParser.BookParserHandler,
    spineIndex: number, prefs: TtsPrefs, bookTitle: string,
    startNode: number = -1, startChar: number = 0): Promise<void> {
    TtsEngine.context = context;
    TtsEngine.handler = handler;
    TtsEngine.prefs = prefs;
    TtsEngine.bookTitle = bookTitle;
    try {
      TtsEngine.spineCount = handler.getSpineList().length;
    } catch (e) {
      TtsEngine.cb?.onToast('书籍解析失败，无法朗读');
      return;
    }
    try {
      const dir = context.cacheDir + '/tts';
      if (!TtsEngine.fileExists(dir)) {
        fs.mkdirSync(dir, true);
      }
    } catch (e) {
      // 目录已存在
    }
    TtsEngine.scheduleCachePrune(); // 会话开始顺带整理一次缓存
    if (TtsEngine.state !== 'stopped') {
      TtsEngine.stopInternal('');
    }
    try {
      await TtsEngine.beginPlaybackEnv();
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'beginPlaybackEnv err %{public}s', e instanceof Error ? e.message : String(e));
      TtsEngine.cb?.onToast('播放器初始化失败');
      return;
    }
    TtsEngine.setState('playing');
    const gen = ++TtsEngine.sessionGen;
    await TtsEngine.run(gen, spineIndex, startNode, startChar);
  }

  /** 暂停：只动播放器与状态标志，协程原地挂起（恢复后从原位继续，不重读）。
   *  阅读器位置快照统一在 setState('paused') 里采集，网络失败等自动暂停路径同样有效。 */
  static pause(): void {
    if (!TtsEngine.isPlaying()) {
      return;
    }
    // 用户/引擎主动暂停 ⇒ 清除系统打断标记（避免陈旧标记导致后续误自动续播）
    TtsEngine.interruptedBySystem = false;
    TtsEngine.setState('paused');
    if (TtsEngine.playingMidFile && TtsEngine.player !== null) {
      TtsEngine.player.pause();
    }
  }

  /**
   * 恢复播报：
   * - 暂停期间阅读器仍在同一位置 → 原进度无缝续播（音频缓存继续用，不停顿）；
   * - 暂停期间阅读器换了页/换了章 → 以"当前所在页"为准重新锚定并合成播放，
   *   绝不续播旧位置的缓存（对齐"不同页面就在该页所在位置重新播放"的语义）。
   */
  static resume(): void {
    let forceRebuild: boolean = false;
    if (!TtsEngine.isPaused()) {
      // ---------- T1-D2 兜底：状态显示"在播"，但音频管线其实已死 ----------
      // 真机场景：打断后引擎状态被置成 playing，用户再点播放时 `resume()` 会在此
      // 直接 return（"点了没反应"）。改为：检测到写失败就按"从本页"的语义重建管线。
      if (INTERRUPT_REBUILD_WHEN_STUCK && TtsEngine.isPlaying()
        && TtsEngine.player !== null && TtsEngine.player.streamDead()) {
        hilog.info(DOMAIN, TAG, 'resume: stream dead while state=playing -> force rebuild');
        forceRebuild = true;
        // 先归一到 paused，让 `pausePagePos` 记下当前位置，并真正停掉旧渲染器
        TtsEngine.setState('paused');
        TtsEngine.player.stop();
      } else {
        return;
      }
    }
    // 无论自动还是手动恢复，系统打断标记都失效
    TtsEngine.interruptedBySystem = false;
    // 手动恢复 ⇒ 取消网络自动探活（避免与用户操作竞态后重复置状态）
    TtsEngine.pausedByNetwork = false;
    const now = TtsEngine.readerPosProvider !== null ? TtsEngine.readerPosProvider() : null;
    const snap = TtsEngine.pausePagePos;
    let flipped = forceRebuild || (now !== null && (snap === null
      || now.spineIndex !== snap.spineIndex
      || now.nodeIndex !== snap.nodeIndex
      || now.charStart !== snap.charStart));
    // ---------- T1-D4：不能原地续播时必须重建，禁止"什么都不做" ----------
    // 真机故障（2026-09-21 01:13，进程 19666）：抖音/汽水音乐走 `INTERRUPT_HINT_STOP`
    //   （**永久**失焦，官方口径"后续不会再收到任何焦点事件"）⇒ 写失败把播放循环打散
    //   ⇒ `playingMidFile=false`。此时用户按播放，旧代码落进下方
    //   `if (TtsEngine.playingMidFile && …)` 的空分支，**静默什么都不做**
    //   （日志表现为 `SetAVPlaybackState:2` 已切换、却无 `Renderer::Start`）。
    // 判据：只有渲染器确实停在 `STATE_PAUSED` 才允许原地 `start()`；
    //   微信场景（hint=2）实测 `state=5` 可原地续播，故不受影响。
    const canResumeInPlace: boolean = TtsEngine.playingMidFile
      && TtsEngine.player !== null && TtsEngine.player.canResumeInPlace();
    if (!canResumeInPlace) {
      flipped = true;
      hilog.info(DOMAIN, TAG,
        'resume: cannot resume in place (playingMidFile=%{public}s) -> force re-anchor',
        TtsEngine.playingMidFile ? 'true' : 'false');
    }
    TtsEngine.setState('playing');
    if (flipped && now !== null) {
      hilog.info(DOMAIN, TAG,
        'resume: reader moved to spine=%{public}d node=%{public}d char=%{public}d → re-anchor',
        now.spineIndex, now.nodeIndex, now.charStart);
      if (now.spineIndex !== TtsEngine.chapterIndex || TtsEngine.currentChunks === null) {
        TtsEngine.seekToChapter(now.spineIndex, now.nodeIndex, now.charStart);
      } else {
        TtsEngine.seekToSegment(
          TtsEngine.chunkIndexForPosition(TtsEngine.currentChunks, now.nodeIndex, now.charStart));
      }
      return;
    }
    if (TtsEngine.playingMidFile && TtsEngine.player !== null) {
      TtsEngine.player.resume();
    }
  }

  static stop(reason: string): void {
    TtsEngine.stopInternal(reason);
    TtsEngine.stopBackground();
    TtsEngine.deactivateSession();
  }

  /** 朗读中跳章（UI 目录/上一章/下一章），可带章内起始位置（ReaderKit 坐标） */
  static seekToChapter(spineIndex: number, startNode: number = -1, startChar: number = 0): void {
    if (TtsEngine.state === 'stopped' || TtsEngine.handler === null) {
      return;
    }
    const gen = ++TtsEngine.sessionGen;
    TtsEngine.abortPlay();
    TtsEngine.setState('playing');
    TtsEngine.run(gen, spineIndex, startNode, startChar).catch((e: Error): void => {
      hilog.error(DOMAIN, TAG, 'seek run err %{public}s', e.message);
    });
  }

  /**
   * 播控中心「下一首 / 上一首」→ **下一章 / 上一章**（T1-A4）。
   * 与面板 `ReaderPage3.ttsSeekChapter` **完全同逻辑**（`stopped` 守卫 + `Math.max(0, …)` 下界），
   * 复用 `seekToChapter`，不另写一套跳章路径。
   */
  static skipChapter(delta: number): void {
    if (TtsEngine.state === 'stopped') {
      return;
    }
    const target = Math.max(0, TtsEngine.currentChapter() + delta);
    TtsEngine.seekToChapter(target);
  }

  /**
   * 下一段：提前结束当前块（run 循环自然 i++ 推进）。
   *
   * ── F6（2026-09-29）修「垫片期间点下一段没反应」────────────────────────────
   * 旧实现只调 `abortPlay()`（= `player.stop()`，仅把 PcmPlayer 的 `abortFlag` 置位）。
   * 但垫片分支的循环每轮都调 `playSilenceChunk()`，而 `play()` 开头会
   * `this.abortFlag = false`（`PcmPlayer.ets:383`）⇒ 该标志被复位，
   * 垫片照常续播下一片、`i` 不动 ⇒ **用户的"下一段"被静默吞掉**。
   * 改为复用既有跳段通道 `seekToSegment(i+1)`：
   *  · 立即更新面板锚点（与滑杆同一语义）；
   *  · 置 `segTarget` ⇒ 垫片循环的 `segTarget >= 0` 守卫会让出到外层块循环消费，
   *    同时 `seekToSegment` 内部的 `abortPlay()` 负责打断当前垫片切片。
   * 回退：改回 `TtsEngine.abortPlay();` 一行即可（无其它残留）。
   */
  static nextSegment(): void {
    if (TtsEngine.state === 'stopped') {
      return;
    }
    TtsEngine.seekToSegment(TtsEngine.playingSegIndex + 1);
  }

  /** 上一块：段循环回到上一块重播（缓存+解码，即时响应） */
  static prevSegment(): void {
    if (TtsEngine.state === 'stopped') {
      return;
    }
    TtsEngine.seekToSegment(TtsEngine.playingSegIndex - 1);
  }

  /** 跳到本章第 index 块（面板进度滑杆用）。锚点坐标与文本框立即更新，
   *  不等合成——快速拖动时反馈实时，音频由引擎在后台追赶。 */
  static seekToSegment(index: number): void {
    if (TtsEngine.state === 'stopped') {
      return;
    }
    const chunks = TtsEngine.currentChunks;
    const target = Math.max(0, index);
    if (chunks !== null && target < chunks.length) {
      const c = chunks[target];
      TtsEngine.playingSegIndex = target;
      TtsEngine.playingSpine = TtsEngine.chapterIndex;
      TtsEngine.playingNode = c.nodeIndex;
      TtsEngine.playingChar = c.charStart;
      TtsEngine.cb?.onSegment(target, chunks.length, c.text);
    }
    TtsEngine.segTarget = target;
    TtsEngine.abortPlay();
  }

  /**
   * 睡眠定时：从当前章起再读 chapters 章（0=不限）、累计播放 minutes 分钟（0=不限）。
   * 两个都传 0 表示清除定时。
   */
  static setSleepTimer(chapters: number, minutes: number): void {
    TtsEngine.sleepStopChapter = chapters > 0 ? TtsEngine.chapterIndex + chapters : -1;
    // 锚点章随锚记录：定时在**未播放**时设置的话 chapterIndex 是上一场次残留，
    // run() 开播发现起点与锚点不符会按本次起点重锚（见 run() 开头）
    TtsEngine.sleepAnchorChapter = chapters > 0 ? TtsEngine.chapterIndex : -1;
    // 墙钟语义：定格**绝对截止时刻**（2026-10-07 用户要求"设置好就独立倒计时"，
    // 暂停/看书都走表）。旧实现存"累计播放档位"（暂停表停，且与展示层"绝对时刻"
    // 的假设矛盾——顶栏弹窗一直显示"剩 0 分钟"的根因）。
    TtsEngine.sleepStopMs = minutes > 0 ? Date.now() + minutes * 60 * 1000 : -1;
    TtsEngine.playedMs = 0;
    // D3：记住原始档位，供面板回显（见 sleepChaptersReq 注释）
    TtsEngine.sleepChaptersReq = chapters;
    TtsEngine.sleepMinutesReq = minutes;
    if (chapters > 0 || minutes > 0) {
      hilog.info(DOMAIN, TAG, 'sleep timer set: chapters=%{public}d minutes=%{public}d',
        chapters, minutes);
    }
  }

  /**
   * D3 修复：用户**当初选的档位**（0=不限）。
   * `sleepStopChapter` 是绝对章号（当前章+chapters），会随播放推进而变化，
   * 无法反推用户选的是"3章"还是"5章"；故额外记住原始档位，供面板回显高亮。
   */
  private static sleepChaptersReq: number = 0;
  private static sleepMinutesReq: number = 0;

  static getSleepChaptersReq(): number {
    return TtsEngine.sleepChaptersReq;
  }

  static getSleepMinutesReq(): number {
    return TtsEngine.sleepMinutesReq;
  }

  /**
   * ── D3 修复：睡眠定时状态回读 ─────────────────────────────────────────────
   * 面板原先只用本地 `@State sleepMin/sleepChap`（初值 0）显示档位，**从不反向读引擎**。
   * sheet 关闭后组件重建、`@State` 归零 ⇒ 再打开显示「关」，而引擎里的定时其实还在跑。
   * 下面三个 getter 供面板在 `aboutToAppear` 与定时刷新时回读，从而：
   *   1. 重新打开面板能显示**真实档位**；
   *   2. 能显示**剩余时长 / 剩余章数**（用户明确要求"睡眠定时要好用"）。
   */
  static getSleepStopChapter(): number {
    return TtsEngine.sleepStopChapter;
  }

  static getSleepStopMs(): number {
    return TtsEngine.sleepStopMs;
  }

  static getPlayedMs(): number {
    return TtsEngine.playedMs;
  }

  // 睡眠定时检查内联在 run 循环中（章界 + 块界两处）

  // ---------- 主循环 ----------
  private static async run(gen: number, spineIndex: number,
    startNode: number = -1, startChar: number = 0): Promise<void> {
    if (TtsEngine.handler === null || TtsEngine.prefs === null) {
      return;
    }
    TtsEngine.chapterIndex = spineIndex;
    // 章节定时锚点校正：定时若在**未播放**时设置，锚点章是上一场次的残留；
    // 本次开播起点与锚点不符 ⇒ 按"再读 N 章"以**本次开播章**重新锚定。
    if (TtsEngine.sleepStopChapter >= 0 && TtsEngine.sleepChaptersReq > 0
      && TtsEngine.sleepAnchorChapter !== spineIndex) {
      TtsEngine.sleepStopChapter = spineIndex + TtsEngine.sleepChaptersReq;
      TtsEngine.sleepAnchorChapter = spineIndex;
      hilog.info(DOMAIN, TAG, 'sleep chapter re-anchor: stop=%{public}d',
        TtsEngine.sleepStopChapter);
    }
    // 墙钟定时若在上一次会话已过期但未清理 ⇒ 本次开播立刻就停。防御性清理：
    // 到点触发路径会自清理（见 clearSleepTimer），这里兜底处理"到点时根本没在播放"的情况。
    if (TtsEngine.sleepStopMs >= 0 && Date.now() >= TtsEngine.sleepStopMs) {
      TtsEngine.clearSleepTimer();
    }
    while (TtsEngine.alive(gen)) {
      // 睡眠定时：到章节数边界即停
      if (TtsEngine.sleepStopChapter >= 0 && spineIndex >= TtsEngine.sleepStopChapter) {
        TtsEngine.clearSleepTimer();
        TtsEngine.stopInternal('已读完定时设定的章节数');
        TtsEngine.stopBackground();
        TtsEngine.deactivateSession();
        return;
      }
      if (spineIndex < 0 || spineIndex >= TtsEngine.spineCount) {
        TtsEngine.stopInternal('全书朗读完毕');
        TtsEngine.stopBackground();
        TtsEngine.deactivateSession();
        return;
      }
      // 1. 取章节文本（与阅读器同一数据源）
      let content = '';
      try {
        content = await TtsEngine.handler.getSpineItemContent(spineIndex);
      } catch (e) {
        hilog.error(DOMAIN, TAG, 'getSpineItemContent %{public}d failed: %{public}s',
          spineIndex, e instanceof Error ? e.message : String(e));
        TtsEngine.cb?.onToast('本章内容读取失败，已跳过');
        spineIndex++;
        TtsEngine.chapterIndex = spineIndex;
        continue;
      }
      // 1. 建"ReaderKit 块节点模型"（与阅读器 DOM 块节点 1:1，唯一坐标系）
      const nodes = buildChapterNodes(content).nodes;
      const chunks = TtsEngine.buildQueue(nodes);
      TtsEngine.currentChunks = chunks;
      TtsEngine.currentNodes = nodes;
      TtsEngine.observedMaxNode = 0;
      hilog.info(DOMAIN, TAG, 'chapter: spine=%{public}d nodes=%{public}d chunks=%{public}d',
        spineIndex, nodes.length, chunks.length);
      if (!TtsEngine.alive(gen)) {
        return;
      }
      // AI 说话人识别（多角色 + 已配置时）：对白块按男/女分音色
      if (TtsEngine.prefs.scheme === 'multi'
        && TtsEngine.prefs.aiSpeakerRecognitionEnabled
        && TtsEngine.prefs.aiBaseUrl.length > 0 && TtsEngine.prefs.aiApiKey.length > 0) {
        await TtsEngine.applySpeakerRecognition(chunks, nodes);
        if (!TtsEngine.alive(gen)) {
          return;
        }
      }
      TtsEngine.failStreak = 0;
      TtsEngine.notifyChapter(spineIndex);
    TtsEngine.scheduleCachePrune(); // 换章是自然的缓存整理边界
      if (chunks.length === 0) {
        spineIndex++;
        TtsEngine.chapterIndex = spineIndex;
        startNode = -1; // 起始位置仅对第一章生效
        continue;
      }
      // 2. 块循环（起始位置仅第一章生效：从阅读器当前页的块节点开始）
      let i = 0;
      if (startNode >= 0) {
        i = TtsEngine.chunkIndexForPosition(chunks, startNode, startChar);
        startNode = -1;
      }
      while (TtsEngine.alive(gen) && i < chunks.length) {
        // ---------- D5 修复 ----------
        // 段跳转（面板进度条 / 上一段·下一段）必须在【暂停检查之前】消费。
        // 旧顺序是「先判暂停再判 segTarget」⇒ 暂停期间拖动进度条时，`seekToSegment`
        // 已立即更新了文本框与段落号，但 `segTarget` 一直悬着，音频要等恢复播放才跳
        // ——用户看到「文字跳了、声音没动」，像坏了。
        if (TtsEngine.segTarget >= 0) {
          const target = TtsEngine.segTarget;
          TtsEngine.segTarget = -1;
          if (target < chunks.length) {
            i = Math.max(0, target);
          }
          continue;
        }
        if (TtsEngine.isPaused()) {
          // ---------- T2 新路径：网络暂停自动探活 ----------
          // 熄屏挂起期间定时器冻结（官方低功耗口径），唤醒后本轮 sleep(150) 结束即会
          // 走到这里，用"上次失败的同一块"做探活合成；成功 ⇒ 自动续播，无需用户亮屏。
          if (TTS_NET_RESILIENCE && TtsEngine.pausedByNetwork) {
            if (Date.now() >= TtsEngine.netProbeDueAt) {
              TtsEngine.netProbeDueAt = Date.now() + NET_PAUSE_PROBE_MS;
              try {
                await TtsEngine.ensureSynth(chunks[i]);
                if (!TtsEngine.alive(gen)) {
                  return;
                }
                TtsEngine.failStreak = 0;
                TtsEngine.pausedByNetwork = false;
                TtsEngine.setState('playing');
                hilog.info(DOMAIN, TAG, 'net probe ok -> auto resume at chunk %{public}d', i);
                TtsEngine.cb?.onToast('网络已恢复，继续朗读');
                continue;
              } catch (e) {
                hilog.warn(DOMAIN, TAG, 'net probe fail: %{public}s',
                  e instanceof Error ? e.message : String(e));
              }
            }
          }
          await TtsEngine.sleep(150);
          continue;
        }
        // 睡眠定时：墙钟到点即停（sleepStopMs 是绝对截止时刻，暂停也走表）
        if (TtsEngine.sleepStopMs >= 0 && Date.now() >= TtsEngine.sleepStopMs) {
          // ⚠️ 到点自清理：残留的过期 deadline 会让下一次开播立即再停
          TtsEngine.clearSleepTimer();
          TtsEngine.stopInternal('睡眠定时结束，已自动停止');
          TtsEngine.stopBackground();
          TtsEngine.deactivateSession();
          return;
        }
        TtsEngine.playingSegIndex = i;
        TtsEngine.playingSpine = spineIndex;
        TtsEngine.playingNode = chunks[i].nodeIndex;
        TtsEngine.playingChar = chunks[i].charStart;
        TtsEngine.cb?.onSegment(i, chunks.length, chunks[i].text);
        // 预取后续块的合成（只写缓存，不解码）
        // T2 新路径：预取 2 → NET_PREFETCH_AHEAD(4) 块，加厚熄屏挂起期间的安全垫
        //（官方口径：连续 5 次失败才转 paused；underrun 即可能被系统冻结，见 TTS_NET_RESILIENCE 注释）
        const prefetchAhead: number = TTS_NET_RESILIENCE ? NET_PREFETCH_AHEAD : 2;
        for (let k = 1; k <= prefetchAhead; k++) {
          TtsEngine.prefetch(chunks, i + k);
        }
        try {
          // T2：断网在预取阶段已实锤（lastNetFailAt 新鲜）⇒ 播放点跳过 doSynth 的
          // 4 次退避重试——那 ~8s 是"渲染器已空 + 应用退避睡眠"的冻结窗口（09:51 实测
          // 熄屏下 3s 即被挂起 31s，垫片音乐迟迟不起）。直接进垫片：书排干瞬间（~0.3s）
          // 渲染器续上音乐；网络是否恢复由垫片内探活检测（首轮探活成功即无缝续播）。
          // 【缓存守卫，10:11 实测教训】当前块已缓存可播时绝不能抛——否则探活命中缓存
          // 报"已恢复"→ 出垫片 → 又被本守卫拦回 → 无限震荡（286 次/9.5min），
          // 可播块被饿死成纯音乐。守卫只对"未缓存 + 断网新鲜"的块生效。
          const cached: boolean = chunks[i].cachePath.length > 0 && chunks[i].words.length > 0
            && TtsEngine.fileExists(chunks[i].cachePath);
          if (TTS_NET_RESILIENCE && TTS_SILENCE_KEEPALIVE && !cached
            && Date.now() - TtsEngine.lastNetFailAt < NET_SKIP_RETRY_MS) {
            throw new Error('net down (prefetch)');
          }
          await TtsEngine.ensureSynth(chunks[i]);
          if (!TtsEngine.alive(gen)) {
            return;
          }
          TtsEngine.failStreak = 0;
        } catch (e) {
          TtsEngine.failStreak++;
          hilog.error(DOMAIN, TAG, 'synth fail #%{public}d: %{public}s', TtsEngine.failStreak,
            e instanceof Error ? e.message : String(e));
          // ---------- T2 静音垫片保活：首次失败立即进入（不等 failStreak 累积到暂停阈值）----------
          // 不 setState('paused')：渲染器保持 RUNNING + 持续数据流（静音 PCM），
          // 系统"一致性校验"看到的是正常播放 ⇒ 不触发"无有效音频播放"冻结。
          // 真机复盘（2026-09-24 18:17，pid 48422）：垫片未启用时走的仍是
          // "跳句×5 → 暂停"旧路径（用户实测"疯狂跳段后暂停"）⇒ 垫片必须首次失败即接管，
          // failStreak 1..4 的旧窗口本身就是跳句/断供窗口。
          if (TTS_NET_RESILIENCE && TTS_SILENCE_KEEPALIVE) {
              hilog.warn(DOMAIN, TAG, 'silence keepalive start (net down) chunk=%{public}d', i);
              TtsEngine.cb?.onToast('网络不佳，静音等待恢复…');
              // ── F2（2026-09-29）：先保底垫音，再谈探活 ─────────────────────────
              // 旧顺序是「先启动探活 → 再 await playSilenceChunk()」，本意是并行；
              // 但 playSilenceChunk 内部第一步要构建垫片 PCM，而旧构建是**同步大循环**，
              // 主线程被占满 11.88 秒 ⇒ 探活的 Promise 回调根本没机会跑，
              // **整个第一轮垫片窗口一片垫音都没发出去**。
              // 真机实证（`Downloads/2.md`）：01:17:39.872 进垫片 → 01:17:53.888 才退出，
              // 这 14.01 秒内 `power: chunk pcmMs=2000`（垫片切片）**零命中**，
              // 同时 `[DfxWriteInterval] write interval too long cost 13556`
              // + 该区间 `IncSoundData` 零命中 ⇒ 音频彻底断流 13.5 秒。
              // 现顺序：先拿（可能已预热好的）垫片切片并发出首片，再并行探活。
              // 预热命中时首片在毫秒级发出；未命中时构建已被 F1 切成不阻塞，也不会再出现空洞。
              const slices0 = await TtsEngine.ensurePadSlices();
              if (slices0.length > 0) {
                await TtsEngine.playSilenceChunk();
                if (!TtsEngine.alive(gen)) {
                  return;
                }
              } else {
                hilog.warn(DOMAIN, TAG, 'silence keepalive: no pad slices yet, probe first');
              }
              let recovered = false;
              // F6：`segTarget >= 0`（用户点了下一段/上一段/进度条）时立即让出，
              // 由外层块循环消费跳转意图；否则 `play()` 会复位 abortFlag 把垫片续播下去，
              // 用户的跳段操作被静默吞掉。
              while (TtsEngine.alive(gen) && !TtsEngine.isPaused() && !recovered
                && TtsEngine.segTarget < 0) {
                // 探活与垫静音并行：串行探活空窗会抽干熄屏缓冲（≤10000ms）再次触发冻结
                const probeOnce = async (): Promise<boolean> => {
                  try {
                    await TtsEngine.ensureSynth(chunks[i]);
                    return true;
                  } catch (e) {
                    return false;
                  }
                };
                const probe: Promise<boolean> = probeOnce();
                let settled = false;
                probe.then((): void => {
                  settled = true;
                }, (): void => {
                  settled = true;
                });
                while (!settled && TtsEngine.alive(gen) && !TtsEngine.isPaused()
                  && TtsEngine.segTarget < 0) {
                  await TtsEngine.playSilenceChunk();
                }
                recovered = await probe;
                if (!recovered && TtsEngine.segTarget < 0) {
                  hilog.info(DOMAIN, TAG, 'silence keepalive: one probe round failed, keep padding');
                }
              }
              // F6：跳段意图优先于"网络恢复"提示（避免误报"网络已恢复"）
              if (TtsEngine.segTarget >= 0) {
                hilog.info(DOMAIN, TAG, 'silence keepalive end (segment jump) chunk=%{public}d', i);
                continue;
              }
              if (!TtsEngine.alive(gen)) {
                return;
              }
              if (recovered) {
                TtsEngine.failStreak = 0;
                hilog.info(DOMAIN, TAG, 'silence keepalive end (net recovered) chunk=%{public}d', i);
                TtsEngine.cb?.onToast('网络已恢复，继续朗读');
                continue;
              }
              // 用户手动暂停 → 交给循环顶部暂停分支（pausedByNetwork=false，不自动探活）
              continue;
          }
          if (TtsEngine.failStreak >= FAIL_STREAK_PAUSE) {
            // T2 新路径（垫片关闭时的次选）：标记网络暂停（循环自动探活续播）；
            // 旧路径维持"等人工恢复"
            TtsEngine.pausedByNetwork = TTS_NET_RESILIENCE;
            if (TTS_NET_RESILIENCE) {
              TtsEngine.netProbeDueAt = Date.now() + NET_PAUSE_PROBE_MS;
            }
            TtsEngine.setState('paused');
            TtsEngine.cb?.onToast('网络异常，已暂停朗读');
            continue;
          }
          if (TTS_NET_RESILIENCE) {
            // T2 新路径：原地重试同一块（doSynth 内已含指数退避），不跳句丢内容
            continue;
          }
          TtsEngine.cb?.onToast('一句合成失败，已跳过');
          i++;
          continue;
        }
        const chunk = chunks[i];
        if (chunk.cachePath.length === 0 || !TtsEngine.fileExists(chunk.cachePath)) {
          i++;
          continue;
        }
        // 3. 解码 + 停顿拼接 + PCM 播放（completed 或被打断时 resolve）
        try {
          await TtsEngine.playChunk(chunk, i, chunks.length);
        } catch (e) {
          hilog.error(DOMAIN, TAG, 'playChunk err: %{public}s',
            e instanceof Error ? e.message : String(e));
          TtsEngine.cb?.onToast('一段播放失败，已跳过');
          i++;
          continue;
        }
        if (!TtsEngine.alive(gen)) {
          return;
        }
        i++;
      }
      if (!TtsEngine.alive(gen)) {
        return;
      }
      spineIndex++;
      TtsEngine.chapterIndex = spineIndex;
    }
  }

  /**
   * 块节点数组 → 合成块队列。
   * nodeIndex 直接用 ReaderKit 块节点下标（空节点占号但无块），
   * charStart 是"原始节点文本"内的字符偏移——即 domPos 的 Y，
   * 因此这里**不能 trim**（trim 会让 Y 整体前移，定位就会偏）。
   */
  private static buildQueue(nodes: string[]): QueueChunk[] {
    const prefs = TtsEngine.prefs!;
    const chunks: QueueChunk[] = [];
    let carry = false;
    for (let p = 0; p < nodes.length && chunks.length < MAX_CHUNKS_PER_CHAPTER; p++) {
      const raw = nodes[p];
      if (raw.length === 0 || !hasSpeakableText(raw)) {
        continue;
      }
      const segs: SpeakSegment[] = splitParagraphIntoSegments(p, raw, carry, prefs.quoteStyles);
      carry = segs.length > 0 && segs[segs.length - 1].isDialogue && !segs[segs.length - 1].endsSentence;
      for (let s = 0; s < segs.length; s++) {
        const parts = splitSegmentsIntoChunks(segs[s]);
        for (let k = 0; k < parts.length; k++) {
          const seg = parts[k];
          const chunk: QueueChunk = {
            text: seg.text,
            isDialogue: seg.isDialogue,
            endsSentence: seg.endsSentence,
            nodeIndex: seg.nodeIndex,
            charStart: seg.charStart,
            voiceId: seg.isDialogue ? prefs.dialogueVoiceId : prefs.narrationVoiceId,
            words: [],
            cachePath: ''
          };
          chunks.push(chunk);
        }
      }
    }
    return chunks;
  }

  /**
   * 文本框内容 → 真实位置：在块节点数组里就地搜索（合成块永远不跨节点），
   * 优先从当前朗读位置向后找（规避重复句），返回 ReaderKit 坐标。
   */
  static locateText(text: string, fromNode: number, fromChar: number): TtsSegmentPos | null {
    const nodes = TtsEngine.currentNodes;
    if (nodes === null || nodes.length === 0) {
      return null;
    }
    const needle = text.trim();
    if (needle.length === 0) {
      return null;
    }
    const start = Math.max(0, Math.min(fromNode, nodes.length - 1));
    for (let n = start; n < nodes.length; n++) {
      const from = n === start ? Math.max(0, fromChar) : 0;
      const at = nodes[n].indexOf(needle, from);
      if (at >= 0) {
        const hit: TtsSegmentPos = {
          spineIndex: TtsEngine.chapterIndex, nodeIndex: n, charStart: at
        };
        return hit;
      }
    }
    for (let n = 0; n < nodes.length; n++) {
      const at = nodes[n].indexOf(needle);
      if (at >= 0) {
        const hit2: TtsSegmentPos = {
          spineIndex: TtsEngine.chapterIndex, nodeIndex: n, charStart: at
        };
        return hit2;
      }
    }
    return null;
  }

  /**
   * 当前生效的引擎（双引擎架构，2026-09-25）：默认本地（Core Speech Kit）；
   * 'edge' 仅在【暗门解锁 且 prefs 选择 edge】时生效 —— 双重校验，未解锁一律回落本地。
   * 缓存键/扩展名随引擎隔离（.wav=local / .mp3=edge），切换引擎互不串缓存。
   */
  private static activeEngineId(): string {
    const prefs = TtsEngine.prefs;
    if (prefs !== null && ListenUnlock.isUnlocked() && prefs.ttsEngine === 'edge') {
      return 'edge';
    }
    return 'local';
  }

  /**
   * 本地引擎音色映射：把 Edge 体系的角色 voiceId 翻译成本地引擎的 person。
   * 角色 → 本地音色的对应：旁白→localNarrationPerson；对白/男生→localDialogueMalePerson；
   * 女生→localDialogueFemalePerson；单音色方案→localSinglePerson；未命中→旁白音色。
   * （voiceId 本身只作角色标签用，本地模式不联网取 Edge 音色。）
   */
  private static localPersonFor(voiceId: string, prefs: TtsPrefs): number {
    if (prefs.scheme === 'single') {
      return prefs.localSinglePerson;
    }
    if (voiceId === prefs.dialogueMaleVoiceId) {
      return prefs.localDialogueMalePerson;
    }
    if (voiceId === prefs.dialogueFemaleVoiceId) {
      return prefs.localDialogueFemalePerson;
    }
    if (voiceId === prefs.dialogueVoiceId) {
      return prefs.localDialogueMalePerson;
    }
    return prefs.localNarrationPerson;
  }

  private static cachePathFor(chunk: QueueChunk): string {
    const prefs = TtsEngine.prefs!;
    const engineId: string = TtsEngine.activeEngineId();
    const isLocal: boolean = engineId === 'local';
    const rate: number = isLocal ? prefs.localRate : prefs.rate;
    const person: number = isLocal ? TtsEngine.localPersonFor(chunk.voiceId, prefs) : 0;
    const key = engineId + '|' + person + '|' + chunk.voiceId + '|' + rate.toFixed(2) + '|' + prefs.pitch.toFixed(2) + '|' + chunk.text;
    let hash = 0x811c9dc5;
    for (let i = 0; i < key.length; i++) {
      hash ^= key.charCodeAt(i);
      hash = (hash * 0x01000193) >>> 0;
    }
    const ext: string = isLocal ? '.wav' : '.mp3';
    return TtsEngine.context !== null ? TtsEngine.context.cacheDir + '/tts/' + hash.toString(16) + ext : '';
  }

  /**
   * AI 说话人识别（对齐 PC 版机制）：对对白块批量标注 male/female/unknown，
   * 分别套用 男生音色/女生音色/对白音色。失败静默回落（保持统一对白音色）。
   */
  private static async applySpeakerRecognition(chunks: QueueChunk[], nodes: string[]): Promise<void> {
    const prefs = TtsEngine.prefs!;
    const items: SpeakerItem[] = [];
    const itemChunks: QueueChunk[] = [];
    for (let i = 0; i < chunks.length && items.length < 50; i++) {
      const c = chunks[i];
      if (!c.isDialogue) {
        continue;
      }
      // 以所属块节点前后各一个节点作上下文（对齐 PC 版"扩到非纯对白行"的简化版）
      const before = c.nodeIndex > 0 && c.nodeIndex - 1 < nodes.length ? nodes[c.nodeIndex - 1] : '';
      const after = c.nodeIndex + 1 < nodes.length ? nodes[c.nodeIndex + 1] : '';
      const item: SpeakerItem = { text: c.text, before: before, after: after };
      items.push(item);
      itemChunks.push(c);
    }
    if (items.length === 0) {
      return;
    }
    try {
      const kinds = await classifyDialogueGenders(
        prefs.aiBaseUrl, prefs.aiApiKey, prefs.aiModel, items);
      for (let i = 0; i < itemChunks.length; i++) {
        const kind = i < kinds.length ? kinds[i] : 'unknown';
        if (kind === 'male') {
          itemChunks[i].voiceId = prefs.dialogueMaleVoiceId;
        } else if (kind === 'female') {
          itemChunks[i].voiceId = prefs.dialogueFemaleVoiceId;
        }
      }
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'speaker recognition failed: %{public}s',
        e instanceof Error ? e.message : String(e));
    }
  }

  /** 合成（3 次重试 + 缓存）；同块并发只跑一次（按 cachePath 去重）
   * @throws 合成 3 次均失败时抛出
   */
  private static async ensureSynth(chunk: QueueChunk): Promise<void> {
    if (chunk.cachePath.length > 0 && chunk.words.length > 0
      && TtsEngine.fileExists(chunk.cachePath)) {
      return;
    }
    const path = TtsEngine.cachePathFor(chunk);
    if (path.length === 0) {
      return;
    }
    // 缓存命中要求 mp3 + 词表 sidecar 双文件（词表是停顿拼接/句级显示的原料）
    if (TtsEngine.fileExists(path) && TtsEngine.fileExists(path + '.json')) {
      chunk.cachePath = path;
      return;
    }
    const running = TtsEngine.synthInFlight.get(path);
    if (running !== undefined) {
      const r = await running;
      if (r === 1) {
        chunk.cachePath = path;
      }
      return;
    }
    const task = TtsEngine.doSynth(chunk, path);
    TtsEngine.synthInFlight.set(path, task);
    try {
      const r = await task;
      if (r === 1) {
        chunk.cachePath = path;
      }
    } finally {
      TtsEngine.synthInFlight.delete(path);
    }
  }

  /** @returns 1=已写缓存文件；0=无可读内容（空块）；合成失败抛异常 */
  private static async doSynth(chunk: QueueChunk, path: string): Promise<number> {
    const prefs = TtsEngine.prefs!;
    const voice = chunk.voiceId;
    const engineId: string = TtsEngine.activeEngineId();
    let lastErr: Error = new Error('未知错误');
    // T2 新路径：重试 3 → NET_RETRY_ATTEMPTS(4) 次，退避 500ms 指数递增。
    // 依据：真机日志 link-down 场景每次握手失败墙钟 ~3.2s，旧退避(250/500/750ms)
    // 3 次机会约 10s 即烧光，指数退避把单次 doSynth 的抗抖窗口拉到 ~20s。
    const attempts: number = TTS_NET_RESILIENCE ? NET_RETRY_ATTEMPTS : 3;
    for (let attempt = 0; attempt < attempts; attempt++) {
      try {
        let audioData: ArrayBuffer;
        if (engineId === 'local') {
          // 本地引擎（Core Speech Kit）：端侧合成、无网可用；输出 WAV(16k/单声道/S16LE)。
          // 无词级时间戳 ⇒ words 空（停顿拼接/句级时间轴自动降级），停顿改由
          // LocalTtsClient 以官方文本标记 [pN] 注入（句末/句中独立可调）。
          const person: number = TtsEngine.localPersonFor(voice, prefs);
          audioData = await synthesizeLocalWav(chunk.text, prefs.localRate, person,
            prefs.pauseSentenceMs, prefs.pauseCommaMs);
          chunk.words = [];
        } else {
          const r = await synthesizeOnce(chunk.text, voice, prefs.rate, prefs.pitch);
          audioData = r.mp3;
          chunk.words = r.words;
        }
        if (audioData.byteLength === 0) {
          // 空块（无可读内容）视为成功，cachePath 留空即跳过
          return 0;
        }
        const f = fs.openSync(path, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
        fs.writeSync(f.fd, audioData);
        fs.closeSync(f.fd);
        // 词表随音频落盘（跨会话恢复停顿拼接/句级显示所需；本地引擎为空词表）
        TtsEngine.writeWordsSidecar(path, chunk.words);
        return 1;
      } catch (e) {
        lastErr = e instanceof Error ? e : new Error(String(e));
        // F4：新路径查 NET_RETRY_BACKOFF_MS 表（300/600/1200/2400ms）；
        // 旧路径仍是 250/500/750ms（netRetryBackoffMs 内部分流，旧行为逐字保留）
        await TtsEngine.sleep(netRetryBackoffMs(attempt));
      }
    }
    throw lastErr;
  }

  /** 词表 sidecar：<hash>.mp3.json */
  private static writeWordsSidecar(path: string, words: WordSpan[]): void {
    try {
      const arr: string[] = [];
      for (let i = 0; i < words.length; i++) {
        const w = words[i];
        const esc = w.text.replace(/\\/g, '\\\\').replace(/"/g, '\\"');
        arr.push(`{"text":"${esc}","startMs":${w.startMs},"endMs":${w.endMs}}`);
      }
      const json = '{"words":[' + arr.join(',') + ']}';
      const f = fs.openSync(path + '.json', fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      fs.writeSync(f.fd, json);
      fs.closeSync(f.fd);
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'write sidecar err %{public}s', e instanceof Error ? e.message : String(e));
    }
  }

  /** 缓存命中时从 sidecar 恢复词表 */
  private static loadWordsSidecar(chunk: QueueChunk): void {
    if (chunk.words.length > 0 || chunk.cachePath.length === 0) {
      return;
    }
    try {
      const path = chunk.cachePath + '.json';
      if (!TtsEngine.fileExists(path)) {
        return;
      }
      const stat = fs.statSync(path);
      const buf = new ArrayBuffer(stat.size);
      const f = fs.openSync(path, fs.OpenMode.READ_ONLY);
      fs.readSync(f.fd, buf);
      fs.closeSync(f.fd);
      const text = util.TextDecoder.create('utf-8').decodeToString(new Uint8Array(buf));
      const root = JSON.parse(text) as Record<string, Object>;
      const rawArr = root['words'];
      if (!Array.isArray(rawArr)) {
        return;
      }
      const arrSrc = rawArr as Array<Object>;
      const words: WordSpan[] = [];
      for (let i = 0; i < arrSrc.length; i++) {
        const o = arrSrc[i] as Record<string, Object>;
        const t = o['text'];
        const s = o['startMs'];
        const e2 = o['endMs'];
        if (typeof t === 'string' && typeof s === 'number' && typeof e2 === 'number') {
          const w: WordSpan = { text: t as string, startMs: s as number, endMs: e2 as number };
          words.push(w);
        }
      }
      chunk.words = words;
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'load sidecar err %{public}s', e instanceof Error ? e.message : String(e));
    }
  }

  private static prefetch(chunks: QueueChunk[], index: number): void {
    if (index >= chunks.length) {
      return;
    }
    const c = chunks[index];
    if (c.cachePath.length > 0) {
      return;
    }
    if (!hasSpeakableText(c.text)) {
      return;
    }
    const path = TtsEngine.cachePathFor(c);
    if (path.length === 0
      || (TtsEngine.fileExists(path) && TtsEngine.fileExists(path + '.json'))
      || TtsEngine.synthInFlight.has(path)) {
      return;
    }
    const task = TtsEngine.doSynth(c, path).then((r: number): number => {
      if (r === 1) {
        c.cachePath = path;
        TtsEngine.lastNetFailAt = 0; // 合成成功 ⇒ 网络在通，清除断网标记
      }
      return r;
    }).catch((e: Error): number => {
      TtsEngine.lastNetFailAt = Date.now(); // 断网实锤（此时书还在播 ⇒ 应用不可冻结）
      hilog.warn(DOMAIN, TAG, 'prefetch fail: %{public}s', e.message);
      // F2：断网第一时间预热垫片。真机窗口（`Downloads/2.md`）：首次预取失败 01:17:17.641
      // → 真正进入垫片 01:17:39.872，中间有 22 秒书还在播 ⇒ 足够把垫片建好（F1 后约 2s）。
      TtsEngine.prewarmPad();
      return -1;
    });
    TtsEngine.synthInFlight.set(path, task);
    task.finally((): void => {
      TtsEngine.synthInFlight.delete(path);
    });
  }

  // ---------- 解码 + 拼接 + 播放 ----------
  /**
   * 创建播放器与后台环境
   * @throws 播放器创建失败时抛出
   */
  private static async beginPlaybackEnv(): Promise<void> {
    if (TtsEngine.player === null) {
      const p = new PcmPlayer();
      p.onInterrupted = (): void => {
        // 系统打断（来电等）：引擎整体暂停，用户手动继续
        if (TtsEngine.isPlaying()) {
          TtsEngine.setState('paused');
          // 标记"这次暂停是系统造成的"（必须在 setState 之后）
          TtsEngine.interruptedBySystem = true;
          TtsEngine.cb?.onToast('播放被打断（来电或其他应用）');
        }
      };
      // 以下两个回调**只在** PcmPlayer 的 INTERRUPT_FULL_HANDLING 开启时才会被触发
      p.onStopped = (): void => {
        // 系统已强制停流（永久失焦）：按官方口径"切换至音频暂停状态"以保持状态一致
        if (TtsEngine.isPlaying()) {
          TtsEngine.setState('paused');
          TtsEngine.cb?.onToast('播放已停止（音频被其他应用占用）');
        }
      };
      p.onResumeHint = (): void => {
        // 仅当"本次暂停由系统打断造成"时才自动续播；用户主动暂停不自动恢复
        if (TtsEngine.isPaused() && TtsEngine.interruptedBySystem) {
          TtsEngine.resume();
        }
      };
      TtsEngine.player = p;
    }
    TtsEngine.startBackground();
    await TtsEngine.ensureSession();
  }

  /**
   * 解码缓存 MP3 → 计算停顿点 → 拼接 PCM → 流式播放（句级进度回传）。
   * @throws 解码/装载失败
   */
  private static async playChunk(chunk: QueueChunk, index: number, total: number): Promise<void> {
    const prefs = TtsEngine.prefs!;
    const player = TtsEngine.player;
    if (player === null) {
      return;
    }
    // 缓存命中的块：从 sidecar 恢复词表（停顿拼接与句级显示的原料）
    TtsEngine.loadWordsSidecar(chunk);
    // 读缓存音频（双引擎：local=.wav 直读 PCM；edge=.mp3 走解码）
    const stat = fs.statSync(chunk.cachePath);
    let decoded: PcmDecodeResult;
    if (chunk.cachePath.endsWith('.wav')) {
      const f = fs.openSync(chunk.cachePath, fs.OpenMode.READ_ONLY);
      const wav = new ArrayBuffer(stat.size);
      fs.readSync(f.fd, wav);
      fs.closeSync(f.fd);
      // 44 字节标准 WAV 头（LocalTtsClient.pcmToWav 写入）后即 16k/单声道/S16LE PCM
      decoded = {
        pcm: wav.slice(44),
        sampleRate: LOCAL_TTS_SAMPLE_RATE,
        channels: 1
      };
    } else {
      const mp3 = new ArrayBuffer(stat.size);
      const f = fs.openSync(chunk.cachePath, fs.OpenMode.READ_ONLY);
      fs.readSync(f.fd, mp3);
      fs.closeSync(f.fd);
      decoded = await decodeMp3ToPcm(mp3);
    }
    if (decoded.pcm.byteLength === 0) {
      return;
    }
    const pcm = new Int16Array(decoded.pcm);
    // 停顿点 + 拼接（语速缩放 + 音量）
    const points = computePausePoints(chunk.text, chunk.words);
    const spliced = applyPauses(pcm, decoded.sampleRate, points,
      prefs.pauseSentenceMs, prefs.pauseCommaMs, prefs.rate, prefs.volume);
    // 诊断：定位"停顿不生效"——若 words>0 而 points=0，必为词表与文本未对齐
    hilog.info(DOMAIN, TAG,
      'splice: words=%{public}d pts=%{public}d src=%{public}d out=%{public}d sent=%{public}d comm=%{public}d rate=%{public}s',
      chunk.words.length, points.length, pcm.length, spliced.pcm.length,
      prefs.pauseSentenceMs, prefs.pauseCommaMs, prefs.rate.toFixed(2));
    if (points.length === 0 && chunk.words.length > 0) {
      hilog.info(DOMAIN, TAG, 'splice-miss text[0..24]=%{public}s w0=%{public}s w1=%{public}s w2=%{public}s',
        chunk.text.substring(0, 24),
        chunk.words[0]?.text ?? '', chunk.words[1]?.text ?? '', chunk.words[2]?.text ?? '');
    }
    const timeline = buildSentenceTimeline(chunk.text, chunk.words, spliced.timeMap);
    // ── 增量 LRC（播控中心歌词页，2026-09-24）────────────────────────────────
    // 句级时间轴在块解码时才产生（buildSentenceTimeline）⇒ 按块增量追加：首播块把
    // 整块逐句写成 `[mm:ss.xx]文本` 行（时间 = 本章时间轴绝对值），随 setAVMetadata
    // 推给系统。重播/回退的块不重复追加（lrcAppendedChunks 首播守卫）。
    const chunkStartMs = TtsEngine.chapterElapsedBase;
    TtsEngine.chapterTotalChunks = total;
    const isFirstPlay = index >= TtsEngine.lrcAppendedChunks;
    if (isFirstPlay) {
      for (let m = 0; m < timeline.length; m++) {
        if (timeline[m].text.length === 0) {
          continue;
        }
        TtsEngine.chapterLrcLines.push(TtsEngine.formatLrcTime(chunkStartMs + timeline[m].startAdjMs)
          + timeline[m].text);
      }
      TtsEngine.lrcAppendedChunks = index + 1;
      TtsEngine.pushSessionLyric();
    }
    // 播放：句级文本 + 句内字符进度回传
    TtsEngine.playingMidFile = true;
    let lastMark = -1;
    let lastCharInSentence = -1;
    await player.play(spliced.pcm, spliced.sampleRate, (ms: number): void => {
      for (let m = timeline.length - 1; m >= 0; m--) {
        if (ms >= timeline[m].startAdjMs) {
          if (m !== lastMark) {
            lastMark = m;
            lastCharInSentence = -1;
            // 句级位置：块内偏移 + 本句在块内的字符起点 → ReaderKit 的 (节点, 字符)
            TtsEngine.playingSpine = TtsEngine.chapterIndex;
            TtsEngine.playingNode = chunk.nodeIndex;
            TtsEngine.playingChar = chunk.charStart + timeline[m].charStart;
            TtsEngine.cb?.onSegment(index, total, timeline[m].text);
            // 歌词滚动锚点：播控中心按 position 与 LRC 时间标签对齐 ⇒ **换行时**推送
            // （2026-09-24 由秒级节流改为换行推送：秒级推送在服务侧大面积
            //   `syncExecutor timeout`，降频后既保滚动跟手又避开超时）
            TtsEngine.pushSessionPosition(chunkStartMs + timeline[m].startAdjMs);
          }
          // 句内字符进度（用 Edge 词级时间戳反算，浮条据此实时前滚）
          const len = timeline[m].text.length;
          if (len > 0) {
            const origMs = lookupOrigMs(spliced.timeMap, ms);
            const offInChunk = TtsEngine.charOffsetAtMs(chunk, origMs);
            let rel = offInChunk - timeline[m].charStart;
            if (rel < 0) {
              rel = 0;
            }
            if (rel > len) {
              rel = len;
            }
            if (rel !== lastCharInSentence) {
              lastCharInSentence = rel;
              TtsEngine.cb?.onProgress(rel, len);
            }
          }
          break;
        }
      }
    });
    TtsEngine.playingMidFile = false;
    // 睡眠定时的播放时长累计（停顿已在 PCM 内）。
    // ⚠️ pcm 是 Int16Array（16k 单声道，见 :1780 与 LocalTtsClient 注释）：时长 ms =
    // 样本数 / 采样率 × 1000。旧写法多乘 2（把样本当字节）⇒ 播放时长**翻倍累计**，
    // 30 分钟档约 15 分钟即停、倒计时 2 倍速跑（2026-10-07 定时有效性排查定位）。
    TtsEngine.playedMs += spliced.pcm.length / spliced.sampleRate * 1000;
    // 本章时间轴：仅**首播**块累计（重播/回退不重复计），下一块首句的 LRC 绝对时间由此而来
    if (isFirstPlay) {
      const durMs = spliced.pcm.length / spliced.sampleRate * 1000;
      TtsEngine.chapterElapsedBase += durMs;
      TtsEngine.chapterPlayedCount += 1;
      // 章时长估算（单调不减）：平均块时长 × 块总数，随播放逐步逼近真实值
      if (TtsEngine.chapterTotalChunks > 0 && TtsEngine.chapterPlayedCount > 0) {
        const est = TtsEngine.chapterElapsedBase / TtsEngine.chapterPlayedCount * TtsEngine.chapterTotalChunks;
        TtsEngine.chapterDurationEst = Math.max(TtsEngine.chapterDurationEst, est);
      }
    }
  }

  /**
   * 仅 TTS_SILENCE_KEEPALIVE：播放一块垫片切片（真实播完才返回，节奏由排水逻辑保证）。
   * 【切片是恢复延迟的关键】垫片循环每播完一块才检查一次探活结果 ⇒ 块越长，
   * 网络恢复后的交接延迟越长（实测 60s 整段：探活成功后音乐继续响满剩余 ~28s，
   * 用户被迫手动干预；粉噪 2s 块则 ≤2s 交接）。故按 SILENCE_CHUNK_SEC(2s) 切片
   * 逐片播放：音乐连续循环不变，恢复信号检查频率与粉噪版同级。
   * 内容优先级（buildPadPcm）：pad.mp3 片段 → TTS_PAD_AUDIBLE 粉噪 → 纯静音。
   * 非全零 ⇒ `ProcessVolumeData` 静音分类保持 not slient ⇒ ~60s 校验认账（真机已验证）。
   * playingMidFile 置位 ⇒ 用户按暂停时 player.pause() 生效，垫片排水循环节流等待。
   */
  private static async playSilenceChunk(): Promise<void> {
    const player = TtsEngine.player;
    if (player === null) {
      return;
    }
    // F2：走单飞构建（并发调用共用同一份 Promise），构建完成即落 `padSlices` 缓存
    const slices = await TtsEngine.ensurePadSlices();
    if (slices.length === 0) {
      return; // 理论不可达（buildPadSlices 至少兜底一片）
    }
    const slice = slices[TtsEngine.padSliceIdx];
    TtsEngine.padSliceIdx = (TtsEngine.padSliceIdx + 1) % slices.length;
    TtsEngine.playingMidFile = true;
    try {
      await player.play(slice, SILENCE_SAMPLE_RATE, (_ms: number): void => {
      });
    } catch (e) {
      // 渲染器异常不外抛（否则会打断整个 run 协程）：垫不上就由外层下一轮再试
      hilog.warn(DOMAIN, TAG, 'silence play err: %{public}s',
        e instanceof Error ? e.message : String(e));
    } finally {
      TtsEngine.playingMidFile = false;
    }
  }

  /**
   * ── F2：垫片切片「单飞 + 预热」入口 ─────────────────────────────────────────
   *  · 已缓存 ⇒ 直接返回（零成本）；
   *  · 有构建在飞 ⇒ 复用同一 Promise（不重复解码 1.4MB mp3、不重复占 5.76MB）；
   *  · 否则启动构建。`PAD_PREWARM` 开启时由预取失败路径提前调用（见 `prewarmPad`）。
   *
   * 失败降级：构建抛异常时清空句柄并返回空数组 ⇒ 调用方本轮跳过，下一轮重试，
   * 绝不会打断 run 协程（垫片路径的硬约束）。
   */
  private static async ensurePadSlices(): Promise<Int16Array[]> {
    const cached = TtsEngine.padSlices;
    if (cached !== null) {
      return cached;
    }
    const pending = TtsEngine.padBuildPromise !== null
      ? TtsEngine.padBuildPromise
      : TtsEngine.buildPadSlices();
    TtsEngine.padBuildPromise = pending;
    let built: Int16Array[];
    try {
      built = await pending;
    } catch (e) {
      TtsEngine.padBuildPromise = null; // 允许下一轮重试
      hilog.warn(DOMAIN, TAG, 'pad build failed: %{public}s',
        e instanceof Error ? e.message : String(e));
      return [];
    }
    // 成功：落地缓存并释放句柄（此后所有调用走上面的 cache 快路径）
    TtsEngine.padSlices = built;
    TtsEngine.padSliceIdx = 0;
    TtsEngine.padBuildPromise = null;
    return built;
  }

  /**
   * ── F2：垫片预热（fire-and-forget，不阻塞调用方、不改变任何播放状态）──────────
   * 网络失败的第一时间调用（预取 catch / 兜底探活失败），把垫片 PCM 提前建好。
   * 真机依据见 `PAD_PREWARM` 注释：首次预取失败到进入垫片之间有 22 秒可用窗口。
   */
  private static prewarmPad(): void {
    if (!TTS_SILENCE_KEEPALIVE || !TtsEngine.PAD_PREWARM) {
      return;
    }
    if (TtsEngine.padSlices !== null || TtsEngine.padBuildPromise !== null) {
      return; // 已有缓存或在飞：不重复
    }
    hilog.info(DOMAIN, TAG, 'pad prewarm: start');
    TtsEngine.padBuildPromise = TtsEngine.buildPadSlices();
    // 预热是旁路：成功留给 ensurePadSlices 消费；失败只落日志（下一轮再试）
    TtsEngine.padBuildPromise.catch((e: Error): void => {
      TtsEngine.padBuildPromise = null;
      hilog.warn(DOMAIN, TAG, 'pad prewarm failed: %{public}s', e.message);
    });
  }

  /**
   * 构建垫片 PCM 并按 SILENCE_CHUNK_SEC(2s) 切片（一次性，缓存进 padSlices）。
   * 切片理由见 playSilenceChunk 注释：恢复信号检查频率 = 切片时长。
   * 优先级：rawfile/pad.mp3（用户自定义环境音）→ TTS_PAD_AUDIBLE 粉噪 → 纯静音。
   * 片段缺失/解码失败自动回退，不抛异常（垫片路径绝不能打断 run 协程）。
   */
  private static async buildPadSlices(): Promise<Int16Array[]> {
    const t0: number = Date.now();
    const pcm = await TtsEngine.buildPadPcm();
    const sliceN: number = SILENCE_SAMPLE_RATE * SILENCE_CHUNK_SEC;
    const slices: Int16Array[] = [];
    for (let off = 0; off < pcm.length; off += sliceN) {
      const end: number = Math.min(off + sliceN, pcm.length);
      if (end > off) {
        slices.push(pcm.slice(off, end)); // slice() 产生独立 buffer，PcmPlayer 按 buffer 起点写
      }
    }
    if (slices.length === 0) {
      slices.push(new Int16Array(sliceN)); // 兜底：全零 2s（理论不可达）
    }
    hilog.info(DOMAIN, TAG,
      'pad build done: slices=%{public}d sliceSec=%{public}d totalMs=%{public}d wallMs=%{public}d',
      slices.length, SILENCE_CHUNK_SEC, Math.round(pcm.length * 1000 / SILENCE_SAMPLE_RATE),
      Date.now() - t0);
    return slices;
  }

  /**
   * 构建垫片 PCM（被 buildPadSlices 消费）。
   * 优先级：rawfile/pad.mp3（用户自定义环境音）→ TTS_PAD_AUDIBLE 粉噪 → 纯静音。
   * 片段缺失/解码失败自动回退，不抛异常（垫片路径绝不能打断 run 协程）。
   */
  private static async buildPadPcm(): Promise<Int16Array> {
    const clip = await TtsEngine.loadPadClipPcm();
    if (clip !== null) {
      return clip;
    }
    const n: number = SILENCE_SAMPLE_RATE * SILENCE_CHUNK_SEC;
    const pcm = new Int16Array(n);
    if (TTS_PAD_AUDIBLE) {
      // 白噪过单极低通 ⇒ 低频占优的柔和粉噪（听感近似远处风雨声，非刺耳嘶声）。
      const amp: number = Math.round(32767 * PAD_NOISE_LEVEL);
      let lp: number = 0;
      for (let i = 0; i < n; i++) {
        lp = lp + 0.08 * (Math.random() * 2 - 1 - lp);
        const v: number = Math.round(lp * amp);
        pcm[i] = v < -32768 ? -32768 : (v > 32767 ? 32767 : v);
      }
      hilog.info(DOMAIN, TAG, 'pad pcm: audible noise level=%{public}s amp=%{public}d',
        PAD_NOISE_LEVEL.toFixed(2), amp);
    }
    // TTS_PAD_AUDIBLE=false 时 new Int16Array(n) 按规范零填充，即纯静音
    return pcm;
  }

  /**
   * 加载 rawfile/pad.mp3 → 24k 单声道 Int16 PCM；任何失败返回 null（回退粉噪）。
   * 处理链：立体声折叠 → 线性重采样 24k → 软上限 PAD_CLIP_MAX_SEC 截断 → 峰值归一 →
   * 循环接缝 8ms 淡入淡出 → 近零段扫描（不垫噪声底——用户保证片段无静音；
   * 扫描只为把选材坑暴露在日志里，>200ms 告警）。
   *
   * ── F1（2026-09-29）：每一趟循环都按 PAD_BUILD_YIELD_SAMPLES 切片并让出主线程 ──
   * 真机物证：旧实现（单趟同步大循环）把主线程堵死 11.88 秒，触发 `THREAD_BLOCK_3S`
   * 冻结告警，同时渲染器 13.5 秒收不到数据（详见 PAD_BUILD_YIELD_SAMPLES 注释）。
   * 本实现**只改调度不改数值**：同样的输入产生逐位相同的输出。
   */
  private static async loadPadClipPcm(): Promise<Int16Array | null> {
    if (TtsEngine.context === null) {
      return null;
    }
    let mp3: ArrayBuffer;
    try {
      const u8 = await TtsEngine.context.resourceManager.getRawFileContent(PAD_CLIP_RAWFILE);
      mp3 = u8.buffer.slice(u8.byteOffset, u8.byteOffset + u8.byteLength);
    } catch (e) {
      return null; // 文件不存在 ⇒ 常态路径，静默回退
    }
    try {
      const t0: number = Date.now();
      const decoded = await decodeMp3ToPcm(mp3);
      const yieldStart: number = Date.now();
      let src = new Int16Array(decoded.pcm);
      // 立体声（交错）折叠单声道
      if (decoded.channels >= 2) {
        const monoLen: number = Math.floor(src.length / 2);
        const mono = new Int16Array(monoLen);
        for (let off = 0; off < monoLen; off += PAD_BUILD_YIELD_SAMPLES) {
          const end: number = Math.min(off + PAD_BUILD_YIELD_SAMPLES, monoLen);
          for (let i = off; i < end; i++) {
            mono[i] = Math.round((src[i * 2] + src[i * 2 + 1]) / 2);
          }
          await padYield(); // F1：让出主线程
        }
        src = mono;
      }
      // 线性重采样到 24k（与 TTS 输出一致，避免垫片⇄语音切换时渲染器重建）
      let s: Int16Array = src;
      if (decoded.sampleRate !== SILENCE_SAMPLE_RATE && decoded.sampleRate > 0) {
        const outN: number = Math.round(src.length * SILENCE_SAMPLE_RATE / decoded.sampleRate);
        const rs = new Int16Array(outN);
        const step: number = decoded.sampleRate / SILENCE_SAMPLE_RATE;
        const lastIdx: number = src.length - 1;
        for (let off = 0; off < outN; off += PAD_BUILD_YIELD_SAMPLES) {
          const end: number = Math.min(off + PAD_BUILD_YIELD_SAMPLES, outN);
          for (let i = off; i < end; i++) {
            const pos: number = i * step;
            const i0: number = Math.floor(pos);
            const frac: number = pos - i0;
            const a: number = i0 <= lastIdx ? src[i0] : src[lastIdx];
            const b: number = i0 + 1 <= lastIdx ? src[i0 + 1] : a;
            rs[i] = Math.round(a + (b - a) * frac);
          }
          await padYield(); // F1：让出主线程
        }
        s = rs;
      }
      // F5：软上限 120s（原 60s 会把 60081.6ms 的素材静默砍掉尾部 81.6ms，真机日志实证）
      const maxN: number = SILENCE_SAMPLE_RATE * PAD_CLIP_MAX_SEC;
      if (s.length > maxN) {
        hilog.warn(DOMAIN, TAG, 'pad clip too long %{public}dms -> truncate %{public}ds',
          s.length * 1000 / SILENCE_SAMPLE_RATE, PAD_CLIP_MAX_SEC);
        s = s.slice(0, maxN);
      }
      if (s.length === 0) {
        return null;
      }
      // 峰值归一（任意来源 mp3 拉到同一响度）
      let peak: number = 0;
      const total: number = s.length;
      for (let off = 0; off < total; off += PAD_BUILD_YIELD_SAMPLES) {
        const end: number = Math.min(off + PAD_BUILD_YIELD_SAMPLES, total);
        for (let i = off; i < end; i++) {
          const a: number = s[i] < 0 ? -s[i] : s[i];
          if (a > peak) {
            peak = a;
          }
        }
        await padYield(); // F1：让出主线程
      }
      if (peak === 0) {
        return null; // 全零文件
      }
      const gain: number = 32767 * PAD_CLIP_PEAK / peak;
      const out = new Int16Array(total);
      const fadeN: number = Math.round(SILENCE_SAMPLE_RATE * 0.008);
      for (let off = 0; off < total; off += PAD_BUILD_YIELD_SAMPLES) {
        const end: number = Math.min(off + PAD_BUILD_YIELD_SAMPLES, total);
        for (let i = off; i < end; i++) {
          let v: number = Math.round(s[i] * gain);
          v = v < -32768 ? -32768 : (v > 32767 ? 32767 : v);
          // 循环接缝 8ms 淡入淡出（去咔哒；真机验证 206s/百次接缝零 slient 回翻）
          if (i < fadeN) {
            v = Math.round(v * i / fadeN);
          } else if (i >= total - fadeN) {
            v = Math.round(v * (total - 1 - i) / fadeN);
          }
          out[i] = v;
        }
        await padYield(); // F1：让出主线程
      }
      // 近零段扫描：最长连续 |v| ≤ 0.1% FS 的区间（不干预，仅日志哨兵）
      const nearZero: number = Math.round(32767 * 0.001);
      let run: number = 0;
      let maxRun: number = 0;
      for (let off = 0; off < total; off += PAD_BUILD_YIELD_SAMPLES) {
        const end: number = Math.min(off + PAD_BUILD_YIELD_SAMPLES, total);
        for (let i = off; i < end; i++) {
          const a: number = out[i] < 0 ? -out[i] : out[i];
          if (a <= nearZero) {
            run++;
            if (run > maxRun) {
              maxRun = run;
            }
          } else {
            run = 0;
          }
        }
        await padYield(); // F1：让出主线程（run/maxRun 为跨片连续状态，不受切分影响）
      }
      const maxRunMs: number = Math.round(maxRun * 1000 / SILENCE_SAMPLE_RATE);
      if (maxRunMs > PAD_CLIP_SILENT_WARN_MS) {
        hilog.warn(DOMAIN, TAG, 'pad clip near-zero run %{public}dms > %{public}dms — 可能让音频服务判 slient（→挂起风险），建议换无静音片段',
          maxRunMs, PAD_CLIP_SILENT_WARN_MS);
      }
      hilog.info(DOMAIN, TAG,
        'pad pcm: clip %{public}s inRate=%{public}d ch=%{public}d durMs=%{public}d peak→%{public}s nearZeroRun=%{public}dms decodeMs=%{public}d yieldMs=%{public}d',
        PAD_CLIP_RAWFILE, decoded.sampleRate, decoded.channels,
        Math.round(total * 1000 / SILENCE_SAMPLE_RATE),
        PAD_CLIP_PEAK.toFixed(2), maxRunMs,
        yieldStart - t0, Date.now() - yieldStart);
      return out;
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'pad clip decode err -> noise fallback: %{public}s',
        e instanceof Error ? e.message : String(e));
      return null;
    }
  }

  private static abortPlay(): void {
    // PcmPlayer 内部 abortFlag 使写循环退出并清空队列；下一次 play() 自动复位
    if (TtsEngine.player !== null) {
      TtsEngine.player.stop();
    }
  }

  private static stopInternal(reason: string): void {
    TtsEngine.sessionGen++;
    TtsEngine.state = 'stopped';
    TtsEngine.interruptedBySystem = false;
    TtsEngine.pausedByNetwork = false;
    TtsEngine.playingMidFile = false;
    TtsEngine.abortPlay();
    if (TtsEngine.player !== null) {
      TtsEngine.player.stop();
    }
    TtsEngine.cb?.onState('stopped');
    if (reason.length > 0) {
      TtsEngine.cb?.onToast(reason);
    }
  }

  /**
   * 原始时刻 → 该块文本内的字符偏移（句内字符进度用）。
   * 依据 Edge 的词级时间戳：落在某个词里就按时间比例插值。
   */
  private static charOffsetAtMs(chunk: QueueChunk, origMs: number): number {
    let cursor = 0;
    for (let i = 0; i < chunk.words.length; i++) {
      const w = chunk.words[i];
      if (w.text.length === 0) {
        continue;
      }
      const at = chunk.text.indexOf(w.text, cursor);
      if (at < 0) {
        continue;
      }
      cursor = at + w.text.length;
      if (origMs < w.startMs) {
        return at;
      }
      if (origMs <= w.endMs) {
        const frac = w.endMs > w.startMs ? (origMs - w.startMs) / (w.endMs - w.startMs) : 1;
        return at + Math.round(frac * w.text.length);
      }
    }
    return chunk.text.length;
  }

  private static notifyChapter(spineIndex: number): void {
    // 换章 ⇒ 增量 LRC 状态整体重置（assetId 按章区分，歌词页整体重载）
    TtsEngine.curSpineIndex = spineIndex;
    TtsEngine.chapterLrcLines = [];
    TtsEngine.lrcAppendedChunks = 0;
    TtsEngine.chapterElapsedBase = 0;
    TtsEngine.chapterPlayedCount = 0;
    TtsEngine.chapterTotalChunks = 0;
    TtsEngine.chapterDurationEst = 0;
    let title = '';
    if (TtsEngine.handler !== null) {
      try {
        const catalog = TtsEngine.handler.getCatalogList();
        // 目录与书脊多对一，取资源文件匹配的目录名（找不到就留空）
        const spines = TtsEngine.handler.getSpineList();
        const href = spineIndex < spines.length ? spines[spineIndex].href : '';
        for (let i = 0; i < catalog.length; i++) {
          if (href.length > 0 && catalog[i].resourceFile === href) {
            title = catalog[i].catalogName;
            break;
          }
        }
      } catch (e) {
        // 忽略
      }
    }
    TtsEngine.cb?.onChapter(spineIndex, title);
    TtsEngine.updateSessionMeta(title);
  }

  private static setState(s: TtsState): void {
    TtsEngine.state = s;
    // 任何进入暂停的路径都采集阅读器位置快照（resume 判断是否换页重锚的依据）
    if (s === 'paused' && TtsEngine.readerPosProvider !== null) {
      TtsEngine.pausePagePos = TtsEngine.readerPosProvider();
    }
    TtsEngine.cb?.onState(s);
    TtsEngine.updateSessionState();
  }

  private static sleep(ms: number): Promise<void> {
    return new Promise<void>((resolve: () => void) => {
      setTimeout(resolve, ms);
    });
  }

  // ---------- 长时任务（后台朗读） ----------
  /**
   * 仅 TTS_NET_RESILIENCE：注册长时任务挂起/激活监听（全局事件，只注册一次）。
   * 官方口径（continuous-task 文档原文）：AUDIO_PLAYBACK 长时任务退后台且无有效音频
   * 播放时，应用可能被系统冻结；`SYSTEM_SUSPEND_AUDIO_PLAYBACK_NOT_RUNNING=6` 即本场景
   * （SDK `@ohos.resourceschedule.backgroundTaskManager.d.ts:1731-1738`，@since 20）。
   * 激活事件（回前台重新激活）时把探活时间戳清零，缩短网络暂停后的自动恢复时延。
   */
  private static registerBgTaskListeners(): void {
    if (!TTS_NET_RESILIENCE || TtsEngine.bgListenersRegistered) {
      return;
    }
    TtsEngine.bgListenersRegistered = true;
    try {
      backgroundTaskManager.on('continuousTaskSuspend',
        (info: backgroundTaskManager.ContinuousTaskSuspendInfo): void => {
          hilog.warn(DOMAIN, TAG, 'continuous task suspended id=%{public}d reason=%{public}d',
            info.continuousTaskId, info.suspendReason);
        });
      backgroundTaskManager.on('continuousTaskActive',
        (info: backgroundTaskManager.ContinuousTaskActiveInfo): void => {
          hilog.info(DOMAIN, TAG, 'continuous task active id=%{public}d', info.id);
          if (TtsEngine.pausedByNetwork) {
            TtsEngine.netProbeDueAt = 0; // 唤醒后立即探活
          }
        });
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'bg listeners err %{public}s',
        e instanceof Error ? e.message : String(e));
    }
  }

  private static startBackground(): void {
    if (TtsEngine.bgRunning || TtsEngine.context === null) {
      return;
    }
    if (BG_TASK_SAFE_LIFECYCLE && TtsEngine.bgStarting !== null) {
      return; // 启动链仍在进行，避免并发重复启动
    }
    if (BG_TASK_RESTART_GUARD && TtsEngine.bgLastStopAt > 0) {
      // ---------- 新路径（T1-C2）：避开官方禁止的"停止后立即再次申请" ----------
      const waited: number = Date.now() - TtsEngine.bgLastStopAt;
      const remain: number = BG_TASK_MIN_RESTART_INTERVAL_MS - waited;
      if (remain > 0) {
        hilog.info(DOMAIN, TAG, 'bg restart deferred %{public}d ms (last stop %{public}d ms ago)',
          remain, waited);
        if (TtsEngine.bgRestartTimer !== -1) {
          clearTimeout(TtsEngine.bgRestartTimer);
        }
        TtsEngine.bgRestartTimer = setTimeout((): void => {
          TtsEngine.bgRestartTimer = -1;
          TtsEngine.startBackground();
        }, remain);
        return;
      }
    }
    try {
      const wantInfo: wantAgent.WantAgentInfo = {
        wants: [{
          bundleName: TtsEngine.context.abilityInfo.bundleName,
          abilityName: 'EntryAbility'
        }],
        operationType: wantAgent.OperationType.START_ABILITY,
        requestCode: 0,
        wantAgentFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
      };
      // T1-B：让 `chain` 覆盖到 `startBackgroundRunning` 落地为止（旧写法只到 getWantAgent 返回）。
      // 对旧路径无任何可观测影响 —— `chain` 在旧路径下无人消费，且内层已有自己的 catch。
      const chain: Promise<void> = wantAgent.getWantAgent(wantInfo).then((agent: object): Promise<void> | void => {
        if (TtsEngine.context === null) {
          return;
        }
        if (BG_TASK_NOTIFICATION_AWARE) {
          // ---------- 新路径（T1-C1）：用返回 ContinuousTaskNotification 的重载 ----------
          // `bgModes` 取值 `'audioPlayback'` 来自官方「表1 长时任务类型」的**配置项**列。
          return backgroundTaskManager.startBackgroundRunning(
            TtsEngine.context, ['audioPlayback'], agent)
            .then((info: backgroundTaskManager.ContinuousTaskNotification): void => {
              const taskId: number = info.continuousTaskId === undefined ? -1 : info.continuousTaskId;
              hilog.info(DOMAIN, TAG, 'bg task started notificationId=%{public}d taskId=%{public}d',
                info.notificationId, taskId);
              TtsEngine.bgRunning = true;
            }).catch((e: BusinessError): void => {
              hilog.warn(DOMAIN, TAG, 'bg task err %{public}s', JSON.stringify(e));
            });
        }
        // ---------- 旧路径（默认，行为逐字保留）----------
        return backgroundTaskManager.startBackgroundRunning(
          TtsEngine.context, backgroundTaskManager.BackgroundMode.AUDIO_PLAYBACK, agent)
          .then((): void => {
            TtsEngine.bgRunning = true;
            TtsEngine.registerBgTaskListeners();
          }).catch((e: BusinessError): void => {
            hilog.warn(DOMAIN, TAG, 'bg task err %{public}s', JSON.stringify(e));
          });
      }).catch((e: BusinessError): void => {
        hilog.warn(DOMAIN, TAG, 'wantAgent err %{public}s', JSON.stringify(e));
      });
      if (BG_TASK_SAFE_LIFECYCLE) {
        TtsEngine.bgStarting = chain;
        chain.then((): void => {
          TtsEngine.bgStarting = null;
        }, (): void => {
          TtsEngine.bgStarting = null;
        });
      }
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'bg task err %{public}s', JSON.stringify(e));
    }
  }

  private static stopBackground(): void {
    if (TtsEngine.context === null) {
      return;
    }
    if (BG_TASK_RESTART_GUARD && TtsEngine.bgRestartTimer !== -1) {
      // T1-C2：有"延后申请"尚未落地 → 用户已要求停止，取消它
      const pendingTimer: number = TtsEngine.bgRestartTimer;
      TtsEngine.bgRestartTimer = -1;
      clearTimeout(pendingTimer);
    }
    if (BG_TASK_SAFE_LIFECYCLE) {
      // ---------- 新路径（T1-B）：以"最终一定停"为准 ----------
      const ctx = TtsEngine.context;
      const doStop = (): void => {
        if (BG_TASK_RESTART_GUARD) {
          TtsEngine.bgLastStopAt = Date.now();
        }
        backgroundTaskManager.stopBackgroundRunning(ctx).then((): void => {
          TtsEngine.bgRunning = false;
        }).catch((): void => {
          TtsEngine.bgRunning = false;
        });
      };
      const pending = TtsEngine.bgStarting;
      if (pending !== null) {
        // 启动链还没落地：等它结束（无论成败）立刻取消，避免"泄漏一个长时任务"
        pending.then(doStop, doStop);
        return;
      }
      if (TtsEngine.bgRunning) {
        doStop();
      }
      return;
    }
    // ---------- 旧路径（默认，行为逐字保留）----------
    if (!TtsEngine.bgRunning) {
      return;
    }
    if (BG_TASK_RESTART_GUARD) {
      TtsEngine.bgLastStopAt = Date.now();
    }
    backgroundTaskManager.stopBackgroundRunning(TtsEngine.context).then((): void => {
      TtsEngine.bgRunning = false;
    }).catch((): void => {
      TtsEngine.bgRunning = false;
    });
  }

  // ---------- AVSession（锁屏/通知栏控制） ----------
  private static async ensureSession(): Promise<void> {
    if (TtsEngine.avSession !== null || TtsEngine.context === null) {
      return;
    }
    try {
      const session = await avSessionKit.createAVSession(TtsEngine.context, 'legado_tts', 'audio');
      await session.setAVMetadata({
        assetId: 'legado_tts_' + TtsEngine.bookTitle,
        title: TtsEngine.bookTitle.length > 0 ? TtsEngine.bookTitle : '朗读',
        artist: '开源阅读 · 朗读'
      });
      session.on('play', () => {
        TtsEngine.resume();
      });
      session.on('pause', () => {
        TtsEngine.pause();
      });
      session.on('stop', () => {
        TtsEngine.stop('');
      });
      if (AVSESSION_FULL_CONTROL) {
        // ① 播控中心点按可拉起应用（官方最佳实践 §接入播控中心 步骤 3）
        const wantInfo: wantAgent.WantAgentInfo = {
          wants: [{
            bundleName: TtsEngine.context.abilityInfo.bundleName,
            abilityName: TtsEngine.context.abilityInfo.name
          }],
          operationType: wantAgent.OperationType.START_ABILITIES,
          requestCode: 0,
          wantAgentFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
        };
        wantAgent.getWantAgent(wantInfo).then((agent: object): void => {
          session.setLaunchAbility(agent).catch((e: BusinessError): void => {
            hilog.warn(DOMAIN, TAG, 'setLaunchAbility err %{public}s', JSON.stringify(e));
          });
        }).catch((e: BusinessError): void => {
          hilog.warn(DOMAIN, TAG, 'setLaunchAbility wantAgent err %{public}s', JSON.stringify(e));
        });
        // ② 下一章 / 上一章（复用 seekToChapter，与面板 ttsSeekChapter 同逻辑）
        session.on('playNext', () => {
          TtsEngine.skipChapter(1);
        });
        session.on('playPrevious', () => {
          TtsEngine.skipChapter(-1);
        });
      }
      await session.activate();
      TtsEngine.avSession = session;
      TtsEngine.updateSessionState();
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'avsession err %{public}s', JSON.stringify(e));
    }
  }

  private static async updateSessionState(): Promise<void> {
    try {
      await TtsEngine.avSession?.setAVPlaybackState({
        state: TtsEngine.state === 'playing'
          ? avSessionKit.PlaybackState.PLAYBACK_STATE_PLAY
          : avSessionKit.PlaybackState.PLAYBACK_STATE_PAUSE,
        speed: 1.0
      });
    } catch (e) {
      // 忽略
    }
  }

  private static async updateSessionMeta(chapter: string): Promise<void> {
    try {
      if (TtsEngine.avSession === null) {
        return;
      }
      TtsEngine.curChapterTitle = chapter;
      // assetId 按章区分 ⇒ 换章时系统视为新曲目，歌词页整体重载（LRC 已在
      // notifyChapter 重置，随后由 playChunk 按块增量追加）
      await TtsEngine.avSession.setAVMetadata({
        assetId: 'legado_tts_' + TtsEngine.bookTitle + '_' + TtsEngine.curSpineIndex,
        title: TtsEngine.bookTitle.length > 0 ? TtsEngine.bookTitle : '朗读',
        artist: chapter.length > 0 ? chapter : '朗读中'
      });
    } catch (e) {
      // 忽略
    }
  }

  /**
   * 把本章增量 LRC 推给系统歌词页（2026-09-24 修复「无歌词，请欣赏」）。
   *
   * 依据（官方 FAQ，devecocli docs，documentId
   * `FAQ/音频和视频/音视频播控_AVSession/如何在播控中心显示歌词/faqs-avsession-5`）原文：
   *   「创建AVSession后，设置AVMetadata的歌词内容。**歌词格式必须为标准的lyric格式，
   *     其他格式不支持**。」
   * ⇒ 播控中心歌词页只消费 `AVMetadata.lyric`（标准 LRC）；此前推送的
   *   `singleLyricText` 不被该页面消费（真机实测歌词页仍显示"无歌词，请欣赏"）。
   * 桌面歌词组件文档同口径：「填入LRC格式的歌词数据，包含时间标签及对应的歌词文本。
   * 不符合LRC格式的歌词数据，系统可能存在解析异常导致无法展示歌词内容。」
   * （documentId `开发指南/AVSession_Kit_音视频播控服务/本地媒体会话/应用接入歌词组件/
   *   avsession-desktop-lyrics`）
   *
   * fire-and-forget：歌词是增强能力，失败静默（不能影响朗读主链路）。
   */
  private static pushSessionLyric(): void {
    if (TtsEngine.avSession === null) {
      return;
    }
    // duration：已有时长估算则带上（position/进度计算依赖它，SDK 原文见
    // chapterDurationEst 注释）；首个块尚未播完时无估算依据，不带该字段
    // （duration:0 会让进度除零，比缺省更糟）。
    if (TtsEngine.chapterDurationEst > 0) {
      TtsEngine.avSession.setAVMetadata({
        assetId: 'legado_tts_' + TtsEngine.bookTitle + '_' + TtsEngine.curSpineIndex,
        title: TtsEngine.bookTitle.length > 0 ? TtsEngine.bookTitle : '朗读',
        artist: TtsEngine.curChapterTitle.length > 0 ? TtsEngine.curChapterTitle : '朗读中',
        lyric: TtsEngine.chapterLrcLines.join('\n'),
        duration: Math.floor(TtsEngine.chapterDurationEst)
      }).catch((): void => {
        // 忽略
      });
    } else {
      TtsEngine.avSession.setAVMetadata({
        assetId: 'legado_tts_' + TtsEngine.bookTitle + '_' + TtsEngine.curSpineIndex,
        title: TtsEngine.bookTitle.length > 0 ? TtsEngine.bookTitle : '朗读',
        artist: TtsEngine.curChapterTitle.length > 0 ? TtsEngine.curChapterTitle : '朗读中',
        lyric: TtsEngine.chapterLrcLines.join('\n')
      }).catch((): void => {
        // 忽略
      });
    }
  }

  /**
   * 歌词滚动锚点：播控中心按 `position` 与 LRC 时间标签对齐来滚动/高亮，
   * TTS 不是系统可探测的音频文件 ⇒ 必须由应用秒级回传章内播放位置。
   */
  private static pushSessionPosition(elapsedMs: number): void {
    if (TtsEngine.avSession === null) {
      return;
    }
    TtsEngine.avSession.setAVPlaybackState({
      state: TtsEngine.state === 'playing'
        ? avSessionKit.PlaybackState.PLAYBACK_STATE_PLAY
        : avSessionKit.PlaybackState.PLAYBACK_STATE_PAUSE,
      speed: 1.0,
      position: { elapsedTime: Math.max(0, Math.floor(elapsedMs)), updateTime: Date.now() }
    }).catch((): void => {
      // 忽略
    });
  }

  /** ms → 标准 LRC 时间标签 `[mm:ss.xx]`（百分秒） */
  private static formatLrcTime(ms: number): string {
    const totalSec = Math.floor(ms / 1000);
    const m = Math.floor(totalSec / 60);
    const s = totalSec % 60;
    const cs = Math.floor((ms % 1000) / 10);
    return `[${m.toString().padStart(2, '0')}:${s.toString().padStart(2, '0')}.${cs.toString().padStart(2, '0')}]`;
  }

  private static deactivateSession(): void {
    const s = TtsEngine.avSession;
    TtsEngine.avSession = null;
    if (s === null) {
      return;
    }
    s.deactivate().then(async (): Promise<void> => {
      try {
        await s.destroy();
      } catch (e) {
        // 忽略
      }
    }).catch((): void => {
      // 忽略
    });
  }
}

