/**
 * 阿里云通义（DashScope）Qwen3-TTS（自研实现）。
 *
 * 协议要点（**事实来源：参考项目 `providers/dashscopeProvider.ts` 的实现**，
 * 其作者经实战验证；本环境无法出网核对官方文档，故以实现为准并在此标注）：
 *  · URL：`https://dashscope.aliyuncs.com/api/v1/services/aigc/multimodal-generation/generation`
 *  · 头：`Authorization: Bearer <key>` + **`X-DashScope-SSE: enable`**
 *  · 体：`{"model":..., "input":{"text":...,"voice":...}}`（模型支持时加 `input.instructions`）
 *  · 响应：**SSE 文本流**，逐行 `data: {...}`，音频在 `output.audio.data`（base64 PCM）
 *  · 音频：`pcm_s16le` / 24000Hz（参考实现内置常量）
 *  · 失败形态：非 SSE 的 `{"code":"...","message":"..."}`
 *
 * ⚠️ 我们**不做**流式边收边播（本工程 P0 是"整段拿回再播"）；
 *    由于 `http.request` 会等响应结束才 resolve，这里把全部 `data:` 行解析后一次性返回。
 * ⚠️ 参考实现**不传 rate/pitch**（引擎元数据也声明 supportsRate:true 但 provider 未用）；
 *    我们照此办理，并在 UI 上把"语速"对这家隐藏（见 AiProviderMeta.supportsRate=false）。
 */
import { AiCancelToken, AiProviderMeta, AiSynthReq, AiSynthRes, AiTtsConfig, AiTtsProvider,
  AiVoiceOption } from '../AiTtsTypes';
import { aiHttpPost, concatBytes, decodeBase64, shortErrorBody } from '../AiTtsHttp';
import { baseUrlOf, bearerHeaders, applyExtraHeaders, appendExtraBody } from './AiProviderCommon';
import { hilog } from '@kit.PerformanceAnalysisKit';

const AI_TAG: string = 'AiTts';
const DOMAIN: number = 0x0001;

export const DASHSCOPE_META: AiProviderMeta = {
  id: 'dashscope',
  label: '阿里通义',
  description: 'Qwen3-TTS 云端合成（SSE 返回 base64 PCM；语速/音调由模型自行决定）',
  needsBaseUrl: false,
  defaultBaseUrl: 'https://dashscope.aliyuncs.com/api/v1/services/aigc/multimodal-generation/generation',
  needsApiKey: true,
  // 2026-10-11 改：默认模型对齐官方「instruct」款。
  // 依据：只有 qwen3-tts-instruct-flash 支持自然语言语气控制（input.instructions）；
  //   qwen3-tts-flash **不支持**，传了会被忽略（参考项目
  //   voiceReadDashscopeModels.ts:28-30 的 dashscopeTtsModelSupportsInstructions 即按模型名判断）。
  modelHint: 'qwen3-tts-instruct-flash',
  // 2026-10-11 改：默认音色改「沧明子」（适合旁白的老者音），
  //   与参考项目 voiceReadEngineDefaults.ts:46 的默认一致；旧值 Cherry 是明亮女声。
  voiceHint: 'Eldric Sage',
  supportsRate: false,
  rateMin: 1.0,
  rateMax: 1.0,
  supportsPitch: false,
  supportsFormat: false,
  formatOptions: [],
  supportsInstructions: true,
  supportsEmotion: true,
  supportsListVoices: false,
  defaultFormat: 'pcm'
};

/**
 * 该模型是否支持 `input.instructions`（自然语言语气控制）。
 * 官方文档：仅 *-instruct* 系列支持。
 * 证据：https://help.aliyun.com/zh/model-studio/qwen-tts-（"Instruct 支持自然语言语气控制"）
 *   参考实现：ColorTxt-main/src/shared/voiceReadDashscopeModels.ts:28-30
 * ⚠️ 传了不支持的模型不会报错，而是**静默忽略** ⇒ 必须由我们这边判，不能指望服务端。
 */
export function dashscopeSupportsInstructions(model: string): boolean {
  return model.toLowerCase().indexOf('instruct') >= 0;
}

/**
 * 合成模型兜底值（用户清空「模型」输入框时用它）。
 * ⚠️ 必须与 {@link DASHSCOPE_META}.modelHint 保持一致，否则会出现
 *   「元数据说支持 instructions、实际回落到不支持 instruct 的模型」的静默不一致。
 *   2026-10-11：跟随 modelHint 一并改为 instruct 款。
 */
const DEFAULT_MODEL: string = 'qwen3-tts-instruct-flash';
const SAMPLE_RATE: number = 24000;
/**
 * 合成语种（官方 `input.language_type`）。
 * 官方可选值：Chinese English German Italian Portuguese Spanish Japanese Korean French Russian。
 * 默认 Chinese 的理由：本工程目标用户读中文书为主；不传 = Auto = 官方明说"无法保证完全精准"。
 * 【待验证】英文/多语种书需要把它做成可配置项（当前是编译期常量）。
 */
const DASHSCOPE_LANGUAGE: string = 'Chinese';

/** 解析 SSE 正文里所有 `data:` 行的音频分片 */
function collectAudioParts(text: string): Uint8Array[] {
  const parts: Uint8Array[] = [];
  const lines: string[] = text.split('\n');
  // ── 取证统计（2026-10-11 新增，只读不改行为）────────────────────────────
  // 目的：区分「服务端只发了 1 片」与「多片但累计字节少」与「根本没发音频」。
  let dataLines: number = 0;      // 所有以 data: 开头的行
  let jsonLines: number = 0;      // 其中能解析成 JSON 的
  let audioLines: number = 0;     // 其中带 output.audio.data 的
  let b64Chars: number = 0;       // base64 字符总数（未解码）
  const partsBytes: number[] = []; // 每片解码后的字节数
  let firstEvt: string = '';      // 首个事件原文（判断是不是真 SSE）
  for (let i = 0; i < lines.length; i++) {
    let t: string = lines[i].trim();
    if (!t.startsWith('data:')) {
      continue;
    }
    dataLines++;
    t = t.substring(5).trim();
    if (t.length === 0 || t === '[DONE]') {
      continue;
    }
    let evt: Record<string, Object>;
    try {
      evt = JSON.parse(t) as Record<string, Object>;
    } catch (e) {
      continue; // 非 JSON 的 data 行（心跳等）跳过
    }
    jsonLines++;
    if (firstEvt.length === 0) {
      firstEvt = t.length > 160 ? t.substring(0, 160) : t;
    }
    const outObj = evt['output'];
    if (outObj === undefined || outObj === null) {
      continue;
    }
    const audioObj = (outObj as Record<string, Object>)['audio'];
    if (audioObj === undefined || audioObj === null) {
      continue;
    }
    const b64 = (audioObj as Record<string, Object>)['data'];
    if (typeof b64 === 'string' && (b64 as string).length > 0) {
      const raw: string = b64 as string;
      audioLines++;
      b64Chars += raw.length;
      const u8 = new Uint8Array(decodeBase64(raw));
      parts.push(u8);
      partsBytes.push(u8.byteLength);
    }
  }
  const detail: string = partsBytes.length > 0 ? partsBytes.join(',') : 'none';
  hilog.info(DOMAIN, AI_TAG,
    'dashscope sse: textLen=%{public}d dataLines=%{public}d jsonLines=%{public}d audioLines=%{public}d b64Chars=%{public}d partBytes=[%{public}s] firstEvt=%{public}s',
    text.length, dataLines, jsonLines, audioLines, b64Chars, detail, firstEvt);
  return parts;
}

/** 非 SSE 的错误体：`{"code":"...","message":"..."}` */
function errorBodyMessage(text: string): string {
  try {
    const root = JSON.parse(text) as Record<string, Object>;
    const code = root['code'];
    const msg = root['message'];
    if (code !== undefined || msg !== undefined) {
      return String(code) + (typeof msg === 'string' ? ' ' + (msg as string) : '');
    }
  } catch (e) {
    // 不是 JSON ⇒ 交给调用方按原文处理
  }
  return '';
}

export class DashscopeTtsProvider implements AiTtsProvider {
  readonly meta: AiProviderMeta = DASHSCOPE_META;

  async synthesize(req: AiSynthReq, cancel: AiCancelToken): Promise<AiSynthRes> {
    const cfg: AiTtsConfig = req.cfg;
    const url: string = baseUrlOf(cfg, DASHSCOPE_META);
    const headers: Record<string, string> = bearerHeaders(cfg);
    headers['X-DashScope-SSE'] = 'enable';
    // 用户自定义请求头（2026-10-11 修复：旧版这一家不读 extraHeaders ⇒ 假控件）
    applyExtraHeaders(cfg, headers);
    const model: string = cfg.model.trim().length > 0 ? cfg.model.trim() : DEFAULT_MODEL;
    const voice: string = req.voiceId.trim().length > 0 ? req.voiceId.trim() : DASHSCOPE_META.voiceHint;
    let input: string = '{"text":' + JSON.stringify(req.text) + ',"voice":' + JSON.stringify(voice);
    // ── language_type（2026-10-11 修复：中文书被念成日语）────────────────────
    // 官方文档原文（https://help.aliyun.com/zh/model-studio/qwen-tts-api）：
    //   「language_type string（可选）合成音频的语种。默认为 Auto。
    //     Auto：适用于文本包含多种语言或语种不确定的场景。模型自动为不同语言片段
    //           匹配发音，但无法保证完全精准。
    //     指定语种：适用于单一语种文本。指定具体语种能显著提升合成质量，效果通常优于 Auto。
    //     可选值：Chinese English German Italian Portuguese Spanish Japanese Korean French Russian」
    // 真机证据（logs/aitts-probe-20261011.log）：不传该字段时，6~8 字的短块被念成**日语**；
    //   而 31 字的长块 msPerChar=191（符合中文语速）⇒ 与官方"Auto 无法保证完全精准"一致，
    //   且**块越短越容易识别错**（本工程实测把每章切成 67 块，短块 6~8 字极常见）。
    // ⚠️ 这里**刻意不在 panel 上暴露**：先以固定值验证根因（一次只改一个变量）。
    //    后续若要支持英文/多语种书，再把它升级为可配置项（见 TODO）。
    input += ',"language_type":' + JSON.stringify(DASHSCOPE_LANGUAGE);
    const ins: string = cfg.instructions.trim();
    // ⚠️ 仅在模型支持时传 instructions（2026-10-11 修复）。
    // 旧实现对任何模型都塞 instructions，而 qwen3-tts-flash 会**静默忽略**它
    // ⇒ 用户填了风格提示词却毫无效果，且无从察觉（"假控件"）。
    if (ins.length > 0 && dashscopeSupportsInstructions(model)) {
      input += ',"instructions":' + JSON.stringify(ins);
    }
    input += '}';
    let body: string = '{"model":' + JSON.stringify(model) + ',"input":' + input + '}';
    // 用户附加请求体（2026-10-11 修复：旧版这一家不读 extraBody ⇒ 假控件）
    // 逃生口用法示例：把语种改成英文 ⇒ `{"input":{"language_type":"English"}}`
    //   注意同名键"后者生效"，但 language_type 嵌在 input 对象里，
    //   这里按官方文档的**外层同名覆盖**语义追加（服务端取后者）。
    body = appendExtraBody(body, cfg.extraBody);

    const res = await aiHttpPost(url, headers, body, false, cancel);
    const biz: string = errorBodyMessage(res.text);
    // ── 取证（2026-10-11）：响应整体形状 ────────────────────────────────────
    hilog.info(DOMAIN, AI_TAG,
      'dashscope resp: code=%{public}d textLen=%{public}d model=%{public}s voice=%{public}s lang=%{public}s reqChars=%{public}d',
      res.code, res.text.length, model, voice, DASHSCOPE_LANGUAGE, req.text.length);
    if (res.code < 200 || res.code >= 300) {
      throw new Error(`通义返回 ${res.code}：` + (biz.length > 0 ? biz : shortErrorBody(res)));
    }
    if (biz.length > 0) {
      throw new Error('通义错误：' + biz);
    }
    const parts: Uint8Array[] = collectAudioParts(res.text);
    if (parts.length === 0) {
      throw new Error('通义未返回音频数据：' + shortErrorBody(res));
    }
    let total: number = 0;
    for (let i = 0; i < parts.length; i++) {
      total += parts[i].byteLength;
    }
    // ── 取证（2026-10-11）：把「文本长度 → 音频时长」的换算写进日志 ──────────
    // 判据：中文正常语速约 200~250ms/字。
    //   若 msPerChar 明显偏小（如 30~80ms）⇒ 音频被截断或语种不对，不是播放问题。
    const msTotal: number = Math.round(total / 2 / SAMPLE_RATE * 1000);
    const msPerChar: number = req.text.length > 0 ? Math.round(msTotal / req.text.length) : 0;
    hilog.info(DOMAIN, AI_TAG,
      'dashscope pcm: parts=%{public}d bytes=%{public}d ms=%{public}d chars=%{public}d msPerChar=%{public}d',
      parts.length, total, msTotal, req.text.length, msPerChar);
    const out: AiSynthRes = {
      data: concatBytes(parts, total),
      format: 'pcm',
      sampleRate: SAMPLE_RATE,
      channels: 1
    };
    return out;
  }

  async listVoices(_cfg: AiTtsConfig, _cancel: AiCancelToken): Promise<AiVoiceOption[]> {
    // 该服务商无「列音色」接口（参考项目用的是内置 48 条静态表）
    return [];
  }
}
