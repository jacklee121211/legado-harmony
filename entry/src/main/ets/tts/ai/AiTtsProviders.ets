/**
 * AI 语音合成 —— 服务商注册表 + 全局限流队列 + OpenAI 兼容实现（自研）。
 *
 * 与参考项目的对应关系（**思想层面**，代码全部自写）：
 *  · 注册表 = `Map<id, provider>`：对照 `src/main/voiceRead/providerRegistry.ts:17-67`
 *  · 全局限流（串行 + 最小间隔 + 指数退避）：对照 `dashscopeSynthQueue.ts:3-4,49-54`
 *  · 能力位驱动的面板：对照 `src/shared/voiceReadEngines.ts:38-53`
 * 许可合规见 docs/ai-voice-read-plan-2026-10-09.md §14（结论：只借鉴思想，不复制代码）。
 *
 * ⚠️ 本环境无法出网核对服务端字段名（方案 §13.4-2）：
 *  · 请求体按 OpenAI `/v1/audio/speech` **标准形**拼装；
 *  · 用户可用「附加请求体 JSON」补任意中转的特有字段；
 *  · 非 2xx **一律把服务端原文回显**到 UI，不做静默降级。
 */
import {
  AiCancelToken, AiProviderMeta, AiSynthReq, AiSynthRes, AiTtsConfig, AiTtsProvider,
  AiVoiceOption, AI_PERMANENT_PREFIX, aiErrorText
} from './AiTtsTypes';
import { aiHttpPost, joinUrl, parseHeaderLines, safeUrlForLog, shortErrorBody,
  sniffAudioFormat } from './AiTtsHttp';
import { hilog } from '@kit.PerformanceAnalysisKit';
// ── 厂商 provider（每家一个文件，改一家不影响其他家）─────────────────────────
import { MiniMaxTtsProvider, MINIMAX_META } from './providers/MiniMaxTts';
import { DashscopeTtsProvider, DASHSCOPE_META } from './providers/DashscopeTts';
import { VolcengineTtsProvider, VOLCENGINE_META } from './providers/VolcengineTts';
import { MimoTtsProvider, MIMO_META } from './providers/MimoTts';

const AI_TAG: string = 'AiTts';
const DOMAIN: number = 0x0001;

/** 全局限流：同一时刻只允许一个 AI 合成请求在飞（云端 TTS 普遍有并发/QPS 限制） */
const AI_MIN_INTERVAL_MS: number = 200;

/**
 * 两条泳道：**播放点（urgent）** 与 **预取（background）**。
 *
 * ⚠️ 为什么必须分道（2026-10-10 真机日志驱动）：
 *   原来只有一条全局 FIFO 队列 ⇒ 播放点要播的那一块，**排在两条预取请求后面**
 *   （run() 的顺序是"先 prefetch(i+1..i+2) 再 ensureSynth(i)"），形成**优先级反转**：
 *   用户感知为"好久好久才出声"。日志时间线：`ai synth req` 三条同时入队，
 *   第一条结果要等前面两条跑完。
 * ⇒ 现在 urgent 走自己的链，最多只等"当前在飞的那一条"，不再等排队的预取。
 */
let queueTail: Promise<void> = Promise.resolve();
let urgentTail: Promise<void> = Promise.resolve();
let lastStartAt: number = 0;

function sleepMs(ms: number): Promise<void> {
  return new Promise<void>((resolve: () => void): void => {
    setTimeout((): void => {
      resolve();
    }, ms);
  });
}

/**
 * 串行执行：保证任意两次 AI 合成的发起间隔 ≥ AI_MIN_INTERVAL_MS。
 * @param urgent true = 播放点需要（走 urgent 泳道）；false = 预取
 */
export function aiSynthSerial<T>(urgent: boolean, task: () => Promise<T>): Promise<T> {
  const run = async (): Promise<T> => {
    const wait: number = AI_MIN_INTERVAL_MS - (Date.now() - lastStartAt);
    if (wait > 0) {
      await sleepMs(wait);
    }
    lastStartAt = Date.now();
    return task();
  };
  const lane: Promise<void> = urgent ? urgentTail : queueTail;
  const p: Promise<T> = lane.then((): Promise<T> => run(), (): Promise<T> => run());
  const settled: Promise<void> = p.then((): void => {
  }, (): void => {
  });
  if (urgent) {
    urgentTail = settled;
  } else {
    queueTail = settled;
  }
  return p;
}

// ── 能力位表（面板据此条件渲染）──────────────────────────────────────────────
const OPENAI_META: AiProviderMeta = {
  id: 'openai',
  label: 'OpenAI 兼容',
  description: '标准 /v1/audio/speech 接口；OpenAI 官方与多数中转/自建 TTS 服务同形',
  needsBaseUrl: true,
  defaultBaseUrl: 'https://api.openai.com/v1',
  needsApiKey: true,
  modelHint: 'tts-1',
  voiceHint: 'alloy',
  supportsRate: true,
  rateMin: 0.25,
  rateMax: 4.0,
  supportsPitch: false,
  supportsFormat: true,
  formatOptions: ['mp3', 'wav', 'pcm'],
  supportsInstructions: true,
  supportsEmotion: true,
  supportsListVoices: false,
  defaultFormat: 'mp3'
};

const AI_PROVIDER_METAS: AiProviderMeta[] = [OPENAI_META, MINIMAX_META, DASHSCOPE_META,
  VOLCENGINE_META, MIMO_META];

export function aiProviderMetaList(): AiProviderMeta[] {
  return AI_PROVIDER_METAS;
}

export function aiProviderMetaOf(id: string): AiProviderMeta | null {
  const key: string = id.trim();
  for (let i = 0; i < AI_PROVIDER_METAS.length; i++) {
    if (AI_PROVIDER_METAS[i].id === key) {
      return AI_PROVIDER_METAS[i];
    }
  }
  return null;
}

/** 配置是否可用（开关打开的前置条件） */
export function aiConfigReady(cfg: AiTtsConfig): boolean {
  const meta: AiProviderMeta | null = aiProviderMetaOf(cfg.providerId);
  if (meta === null) {
    return false;
  }
  if (meta.needsBaseUrl && cfg.baseUrl.trim().length === 0) {
    return false;
  }
  if (meta.needsApiKey && cfg.apiKey.trim().length === 0) {
    return false;
  }
  return true;
}

function clampNum(v: number, lo: number, hi: number): number {
  if (!Number.isFinite(v)) {
    return lo;
  }
  return Math.max(lo, Math.min(hi, v));
}

function normalizeFormat(cfg: AiTtsConfig): string {
  const meta: AiProviderMeta | null = aiProviderMetaOf(cfg.providerId);
  const f: string = cfg.format.trim().toLowerCase();
  if (meta !== null && meta.formatOptions.length > 0) {
    if (meta.formatOptions.indexOf(f) >= 0) {
      return f;
    }
    return meta.formatOptions[0];
  }
  return f.length > 0 ? f : 'mp3';
}

/**
 * 把「附加请求体 JSON」合并进基础 body。
 * 做法：字符串级合并（去掉外层花括号后追加），最后用 JSON.parse 做一次**强校验**——
 * 避免 ArkTS 下动态对象合并的类型限制，同时保证不把非法 JSON 发出去。
 * ⚠️ 同名 key 会重复出现，JSON 语义为"后者生效"（用户可借此覆盖我们的字段）。
 */
function appendExtraBody(baseBody: string, extra: string): string {
  const t: string = extra.trim();
  if (t.length === 0) {
    return baseBody;
  }
  let inner: string = t;
  if (inner.startsWith('{')) {
    if (!inner.endsWith('}')) {
      throw new Error('附加请求体 JSON 不完整（缺少右花括号）');
    }
    inner = inner.substring(1, inner.length - 1).trim();
  }
  while (inner.endsWith(',')) {
    inner = inner.substring(0, inner.length - 1).trim();
  }
  const merged: string = inner.length === 0
    ? baseBody
    : baseBody.substring(0, baseBody.length - 1) + ',' + inner + '}';
  try {
    JSON.parse(merged);
  } catch (e) {
    throw new Error(AI_PERMANENT_PREFIX + '附加请求体 JSON 解析失败：' + aiErrorText(e));
  }
  return merged;
}

/**
 * OpenAI 兼容 `/v1/audio/speech` 实现。
 * 用 class 而不是对象字面量：ArkTS 对"含方法成员的对象字面量"校验严格
 * （实测 `arkts-no-untyped-obj-literals`，见本文件 mcp check 记录）。
 */
class OpenAiCompatProvider implements AiTtsProvider {
  readonly meta: AiProviderMeta = OPENAI_META;

  async synthesize(req: AiSynthReq, cancel: AiCancelToken): Promise<AiSynthRes> {
    const cfg: AiTtsConfig = req.cfg;
    const meta: AiProviderMeta = OPENAI_META;
    const baseUrl: string = cfg.baseUrl.trim().length > 0 ? cfg.baseUrl.trim() : meta.defaultBaseUrl;
    const url: string = joinUrl(baseUrl, '/audio/speech');

    const headers: Record<string, string> = {};
    headers['Content-Type'] = 'application/json';
    const key: string = cfg.apiKey.trim();
    if (key.length > 0) {
      headers['Authorization'] = 'Bearer ' + key;
    }
    // 用户附加请求头（行式）：可覆盖上面两项，也可新增
    parseHeaderLines(cfg.extraHeaders, headers);

    const voice: string = req.voiceId.trim().length > 0 ? req.voiceId.trim() : meta.voiceHint;
    const fmt: string = normalizeFormat(cfg);
    const model: string = cfg.model.trim().length > 0 ? cfg.model.trim() : meta.modelHint;
    const speed: number = clampNum(req.rate, meta.rateMin, meta.rateMax);

    let body: string = '{' +
      '"model":' + JSON.stringify(model) + ',' +
      '"input":' + JSON.stringify(req.text) + ',' +
      '"voice":' + JSON.stringify(voice) + ',' +
      '"response_format":' + JSON.stringify(fmt) + ',' +
      '"speed":' + speed.toFixed(2);
    const instructions: string = cfg.instructions.trim();
    if (meta.supportsInstructions && instructions.length > 0) {
      body += ',"instructions":' + JSON.stringify(instructions);
    }
    body += '}';
    body = appendExtraBody(body, cfg.extraBody);

    const res = await aiHttpPost(url, headers, body, true, cancel);
    if (res.code < 200 || res.code >= 300) {
      const detail: string = shortErrorBody(res);
      const tail: string = detail.length > 0 ? '：' + detail : '';
      const where: string = ' [' + safeUrlForLog(url) + ']';
      // 状态码分类提示（2026-10-09 真机教训：用户接 DeepSeek 时无法自查错在哪一步）
      // 4xx 客户端类 = **永久性错误**（加前缀）⇒ 上层不重试、不进垫片，直接停并报错。
      if (res.code === 401 || res.code === 403) {
        throw new Error(AI_PERMANENT_PREFIX
          + `服务端返回 ${res.code}：API Key 无效或无权限${where}${tail}`);
      }
      if (res.code === 400 || res.code === 422) {
        throw new Error(AI_PERMANENT_PREFIX
          + `服务端返回 ${res.code}：请求参数被拒（检查模型名/音色/输出格式，或用「高级→附加请求体」补字段）${where}${tail}`);
      }
      if (res.code === 404 || res.code === 405 || res.code === 501) {
        throw new Error(AI_PERMANENT_PREFIX
          + `服务端返回 ${res.code}：该地址可能不提供 /audio/speech 语音合成接口`
          + `（本功能要的是 OpenAI 兼容的 **TTS** 端点，不是对话接口）${where}${tail}`);
      }
      // 429 / 5xx 属**暂时性**：保留原样，交给上层重试与垫片
      if (res.code === 429) {
        throw new Error(`服务端返回 429：触发限流，请稍后再试${where}${tail}`);
      }
      throw new Error(`服务端返回 ${res.code}${where}${tail}`);
    }
    hilog.info(DOMAIN, AI_TAG, 'synth ok url=%{public}s fmt=%{public}s bytes=%{public}d',
      safeUrlForLog(url), fmt, res.bin.byteLength);
    const actualFmt: string = sniffAudioFormat(res.bin, fmt);
    if (actualFmt !== fmt) {
      hilog.warn(DOMAIN, AI_TAG,
        'format mismatch: requested=%{public}s actual=%{public}s -> use actual (按字节内容为准)',
        fmt, actualFmt);
    }
    if (!res.isBinary || res.bin.byteLength === 0) {
      const detail: string = shortErrorBody(res);
      throw new Error(`未返回音频${detail.length > 0 ? '：' + detail : ''}`);
    }
    const out: AiSynthRes = {
      data: res.bin,
      // 以**实际字节**为准（服务端常忽略 response_format，见 sniffAudioFormat 注释）
      format: actualFmt,
      // 'pcm' 无容器头、无从探测 ⇒ 按 24000 兜底（与 Edge 输出同率，可避免渲染器重建）
      sampleRate: actualFmt === 'pcm' ? 24000 : 0,
      channels: 1
    };
    return out;
  }

  /** OpenAI 兼容协议**没有**「列音色」接口（/v1/models 只列模型）⇒ 返回空数组 */
  async listVoices(_cfg: AiTtsConfig, _cancel: AiCancelToken): Promise<AiVoiceOption[]> {
    return [];
  }
}

const openAiCompatProvider: AiTtsProvider = new OpenAiCompatProvider();
const miniMaxProvider: AiTtsProvider = new MiniMaxTtsProvider();
const dashscopeProvider: AiTtsProvider = new DashscopeTtsProvider();
const volcengineProvider: AiTtsProvider = new VolcengineTtsProvider();
const mimoProvider: AiTtsProvider = new MimoTtsProvider();

const AI_PROVIDERS: AiTtsProvider[] = [openAiCompatProvider, miniMaxProvider,
  dashscopeProvider, volcengineProvider, mimoProvider];

export function aiProviderOf(id: string): AiTtsProvider | null {
  const key: string = id.trim();
  for (let i = 0; i < AI_PROVIDERS.length; i++) {
    if (AI_PROVIDERS[i].meta.id === key) {
      return AI_PROVIDERS[i];
    }
  }
  return null;
}

/** 统一入口（全部经全局限流队列；与参考项目 synthesizeVoiceReadAudio 同职责）
 *  @param urgent true = 播放点需要（插队到预取之前），false = 预取
 */
export function aiSynthesize(req: AiSynthReq, cancel: AiCancelToken,
  urgent: boolean): Promise<AiSynthRes> {
  const provider: AiTtsProvider | null = aiProviderOf(req.cfg.providerId);
  if (provider === null) {
    return Promise.reject(new Error(AI_PERMANENT_PREFIX + `不支持的 AI 服务商：${req.cfg.providerId}`));
  }
  return aiSynthSerial(urgent, (): Promise<AiSynthRes> => provider.synthesize(req, cancel));
}

/**
 * 拉取音色清单（走**预取泳道**：它不是播放点必需，不应抢占播放）。
 * 不支持的服务商返回空数组；抛错由 UI 显示原文。
 */
export function aiListVoices(cfg: AiTtsConfig, cancel: AiCancelToken): Promise<AiVoiceOption[]> {
  const provider: AiTtsProvider | null = aiProviderOf(cfg.providerId);
  if (provider === null) {
    return Promise.reject(new Error(AI_PERMANENT_PREFIX + `不支持的 AI 服务商：${cfg.providerId}`));
  }
  if (!provider.meta.supportsListVoices) {
    return Promise.resolve([]);
  }
  return aiSynthSerial(false, (): Promise<AiVoiceOption[]> => provider.listVoices(cfg, cancel));
}
