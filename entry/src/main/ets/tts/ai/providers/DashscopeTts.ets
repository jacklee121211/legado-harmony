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
import { baseUrlOf, bearerHeaders } from './AiProviderCommon';

export const DASHSCOPE_META: AiProviderMeta = {
  id: 'dashscope',
  label: '阿里通义',
  description: 'Qwen3-TTS 云端合成（SSE 返回 base64 PCM；语速/音调由模型自行决定）',
  needsBaseUrl: false,
  defaultBaseUrl: 'https://dashscope.aliyuncs.com/api/v1/services/aigc/multimodal-generation/generation',
  needsApiKey: true,
  modelHint: 'qwen3-tts-flash',
  voiceHint: 'Cherry',
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

const DEFAULT_MODEL: string = 'qwen3-tts-flash';
const SAMPLE_RATE: number = 24000;

/** 解析 SSE 正文里所有 `data:` 行的音频分片 */
function collectAudioParts(text: string): Uint8Array[] {
  const parts: Uint8Array[] = [];
  const lines: string[] = text.split('\n');
  for (let i = 0; i < lines.length; i++) {
    let t: string = lines[i].trim();
    if (!t.startsWith('data:')) {
      continue;
    }
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
      const u8 = new Uint8Array(decodeBase64(b64 as string));
      parts.push(u8);
    }
  }
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
    const model: string = cfg.model.trim().length > 0 ? cfg.model.trim() : DEFAULT_MODEL;
    const voice: string = req.voiceId.trim().length > 0 ? req.voiceId.trim() : DASHSCOPE_META.voiceHint;
    let input: string = '{"text":' + JSON.stringify(req.text) + ',"voice":' + JSON.stringify(voice);
    const ins: string = cfg.instructions.trim();
    if (ins.length > 0) {
      input += ',"instructions":' + JSON.stringify(ins);
    }
    input += '}';
    const body: string = '{"model":' + JSON.stringify(model) + ',"input":' + input + '}';

    const res = await aiHttpPost(url, headers, body, false, cancel);
    const biz: string = errorBodyMessage(res.text);
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
