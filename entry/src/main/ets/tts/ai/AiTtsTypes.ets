/**
 * AI 语音合成（用户自接入 TTS）—— 类型契约（纯类型 + 纯函数，无外部依赖）。
 *
 * ── 设计来源与"自研"声明 ────────────────────────────────────────────────
 * 本文件与同目录其余文件**全部为自研实现**，不含参考项目（ColorTxt-main，MPL-2.0）
 * 的任何一行代码。我们只在"思想/接口形状"层面复刻了它验证过的抽象：
 *   · provider 契约（一个引擎 = 一个对象，只有 synthesize 必填）
 *   · 统一入参 text / voiceId / rate(1=原速) / pitch(1=原调) / cfg
 *   · 统一出参 data(ArrayBuffer) + format + sampleRate + channels
 * 证据（仅作"我们复刻了哪些能力位"的对照，非代码来源）：
 *   src/main/voiceRead/providers/types.ts:10-24
 *   src/shared/voiceReadSynthesis.ts:17-43
 * 许可合规结论见 docs/ai-voice-read-plan-2026-10-09.md §14。
 */

/** 取消令牌：ArkTS 无 DOM AbortSignal（SDK 里只有 taskpool 的 @arkts.utils AbortSignal<T>，
 *  无 addEventListener，证据 `ets/arkts/@arkts.utils.d.ets:311`），故自建。 */
export interface AiCancelToken {
  cancelled: boolean;
}

/** 音频容器格式。'pcm' = 裸 S16LE（无容器头）。 */
export type AiAudioFormat = 'mp3' | 'wav' | 'pcm';

/** 引擎连接与参数配置（运行期从 TtsPrefs 组装，不单独持久化） */
export interface AiTtsConfig {
  providerId: string;
  baseUrl: string;
  apiKey: string;
  model: string;
  format: string;
  /** 风格/语气提示词 → 透传为 instructions（仅支持的服务商渲染该输入框） */
  instructions: string;
  /** 附加请求体（JSON 片段，合并进 body） */
  extraBody: string;
  /** 附加请求头（行式 `Key: Value`，一行一条） */
  extraHeaders: string;
}

/** 一次合成请求 */
export interface AiSynthReq {
  text: string;
  /** 已由槽位解析好的音色 id（空串 ⇒ 由 provider 回落默认音色） */
  voiceId: string;
  /** 1.0 = 原速（与 TtsPrefs.rate 同口径） */
  rate: number;
  /** 1.0 = 原调（与 TtsPrefs.pitch 同口径） */
  pitch: number;
  cfg: AiTtsConfig;
}

/** 合成结果。sampleRate = 0 表示未知（调用方按 24000 兜底） */
export interface AiSynthRes {
  data: ArrayBuffer;
  format: string;
  sampleRate: number;
  channels: number;
}

/**
 * 服务商能力位 —— 决定面板**渲染哪些参数行**（不支持的参数不渲染，而不是置灰）。
 * 这是把「不同厂商面板不同」做成数据驱动的那一层。
 * 对照：参考项目 `src/shared/voiceReadEngines.ts:38-53` 的 VoiceReadEngineMeta（思想层面）。
 */
export interface AiProviderMeta {
  id: string;
  label: string;
  description: string;
  /** 是否需要用户填 baseUrl（OpenAI 兼容=true；固定地址的厂商=false） */
  needsBaseUrl: boolean;
  defaultBaseUrl: string;
  needsApiKey: boolean;
  modelHint: string;
  voiceHint: string;
  supportsRate: boolean;
  rateMin: number;
  rateMax: number;
  supportsPitch: boolean;
  supportsFormat: boolean;
  /** 可选输出格式（空数组 = 固定格式，面板不渲染该行） */
  formatOptions: string[];
  supportsInstructions: boolean;
  /**
   * 是否接受**自然语言语气**（instructions / context_texts）。
   * ⚠️ MiniMax 只吃固定枚举（happy/sad/…），传自然语言它**直接忽略** ⇒ 标 false，
   *    UI 隐藏情绪开关，避免"假控件"（与 §F5 同一教训）。
   */
  supportsEmotion: boolean;
  /** 该服务商是否提供「列音色」接口（true 时 UI 显示「拉取音色」按钮） */
  supportsListVoices: boolean;
  /** 输出音频的容器格式（用于 UI 提示与默认值；真实格式仍以字节嗅探为准） */
  defaultFormat: string;
}

/** 音色条目（内置建议值 + 允许手填） */
export interface AiVoiceOption {
  id: string;
  label: string;
  description: string;
  /** 'male' | 'female' | ''（未知） */
  gender: string;
}

/** 一个 AI TTS 服务商 */
export interface AiTtsProvider {
  readonly meta: AiProviderMeta;
  synthesize(req: AiSynthReq, cancel: AiCancelToken): Promise<AiSynthRes>;
  /**
   * 拉取该服务商的音色清单。
   * ⚠️ 声明为**必填**而不是可选：ArkTS 下"可选方法"的空值判定易踩坑，
   *    不支持的服务商返回空数组即可，UI 是否显示按钮由 `meta.supportsListVoices` 决定。
   * 对照：参考项目 `providers/types.ts:16-19` 用的是 `listVoices?`（可选），我们改用显式契约。
   */
  listVoices(cfg: AiTtsConfig, cancel: AiCancelToken): Promise<AiVoiceOption[]>;
}

/**
 * 配置指纹：并入缓存键。
 * ⚠️ 为什么必须有它（审查第 3 遍发现的实现级隐患）：
 *   `TtsEngine.cachePathFor` 的键里只有 `chunk.voiceId`，而 AI 模式下 `voiceId` 是
 *   **角色标签**（旁白/对白/男声/女声），用户改「AI 旁白音色」时标签不变 ⇒ 键不变 ⇒
 *   会命中上一次音色的旧音频文件（表现为"改了没用"）。
 *   ⇒ AI 引擎的缓存键必须额外并入「解析后的音色 + 服务商 + 模型 + 格式 + 提示词 + 附加体」。
 * 注意：**不含 apiKey 明文**，只取长度做弱区分。
 * 对照：参考项目 `voiceReadEngineConfig.ts:106-129` 的"指纹不落 Key"（思想层面）。
 */
export function aiConfigFingerprint(cfg: AiTtsConfig, resolvedVoiceId: string): string {
  const keyMark: string = cfg.apiKey.trim().length > 0 ? '#' + cfg.apiKey.trim().length : '';
  return [
    cfg.providerId.trim(),
    cfg.baseUrl.trim(),
    keyMark,
    cfg.model.trim(),
    cfg.format.trim(),
    resolvedVoiceId.trim(),
    cfg.instructions.trim(),
    cfg.extraBody.trim(),
    cfg.extraHeaders.trim()
  ].join('|');
}

/** 供 UI 显示的一句话错误（把 Error 收敛成可读文本） */
export function aiErrorText(e: Object): string {
  if (e instanceof Error) {
    return e.message;
  }
  return String(e);
}

/**
 * ── AI「永久性失败」标记（2026-10-10 新增，真机日志驱动）─────────────────────
 * 由来：真机日志 `日志.md` L2782-2783 实证——
 *   `synth fail #1: 服务端返回 404…` 紧跟着 `silence keepalive start (net down) chunk=7`，
 *   之后 `silence keepalive: one probe round failed, keep padding` **无限循环垫音**。
 *   即：**接口不存在/鉴权失败这类永久错误，被当成"断网"进了静音垫片**，
 *   用户既听不到内容、也看不到任何报错。
 *
 * 判据（哪些算永久）：
 *   · HTTP 400 / 401 / 403 / 404 / 405 / 501 —— 改网络也没用，重试与垫片都是纯浪费；
 *   · 用户配置类错误（JSON 非法、地址为空、不支持的服务商）。
 * 哪些**不算**永久（仍走原有重试 + 垫片 + 探活）：连接超时、DNS 失败、5xx、429。
 *
 * 实现方式：**消息前缀**而不是自定义 Error 子类 ——
 *   ArkTS 下继承内建 `Error` 的 `instanceof` 行为不宜依赖，前缀匹配最稳（与 AI_CANCELLED_MSG 同思路）。
 */
export const AI_PERMANENT_PREFIX: string = '⛔AI永久错误：';

export function isAiPermanentError(msg: string): boolean {
  return msg.startsWith(AI_PERMANENT_PREFIX);
}

/** 去掉前缀后的可读详情（给 UI/toast 用） */
export function aiPermanentDetail(msg: string): string {
  return isAiPermanentError(msg) ? msg.substring(AI_PERMANENT_PREFIX.length) : msg;
}
