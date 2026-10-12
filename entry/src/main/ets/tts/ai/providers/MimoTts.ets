/**
 * 小米 MiMo（把 TTS 塞进 chat/completions）—— 自研实现。
 *
 * 协议要点（**事实来源：小米 MiMo 官方 API 文档**，用户于 2026-10-11 手抄提供，
 * 原文留存 `docs/日志tts.md`；此前为参考项目实现，现已按官方原文复核）：
 *  · URL：`{base}/v1/chat/completions`
 *  · 头：**`api-key: <key>`**（官方「API Key 鉴权」；另支持 Bearer）
 *  · 体：`{"model":..., "messages":[{role:"user",content:<风格描述>?},
 *         {role:"assistant",content:<**待朗读文本**>}], "audio":{"format":"wav","voice":...}}`
 *    ⇒ 待读文本放在 **assistant 角色**（官方原文：「必须添加一条 role 为 assistant 的消息，
 *      该消息需指定用于音频合成的文本」）
 *  · 响应：`choices[0].message.audio.data`（**Base64**）→ 官方示例为 wav
 *
 * 官方关键约束（`docs/日志tts.md` 原文行号）：
 *  · `model`（L37）：可选 `mimo-v2.5-tts` / `mimo-v2.5-tts-voicedesign` / `mimo-v2.5-tts-voiceclone`
 *  · `audio.format`（L44-47）：默认 `wav`；**`stream:true` 时为 `pcm`**；
 *      可选 `wav` / `mp3` / `pcm` / `pcm16`（传 `pcm` 与 `pcm16` 均表示 pcm16）
 *  · `audio.voice`（L57-60）：预置音色 id **或音频样本 base64**，按模型而异 ——
 *      `mimo-v2.5-tts`          ：可选，只能用预置音色，默认 `mimo_default`
 *      `mimo-v2.5-tts-voiceclone`：必填，且**只能传音频样本 base64**（mp3/wav）
 *      `mimo-v2.5-tts-voicedesign`：**不支持该字段**
 *  · `audio.optimize_text_preview`（L48-54）：仅 voicedesign 支持；为 true 时
 *      **可省略 assistant 消息**，模型自行生成/润色播报文本
 *
 * ⚠️ 参考项目对 Base URL 有"按 Key 前缀推导域名"的逻辑（tp- 走另一域名）；
 *    我们简化为**用户自己填 baseUrl**（我们本就是"用户自带接口"的定位），
 *    默认 `https://api.xiaomimimo.com/v1`。
 */
import { AiCancelToken, AiProviderMeta, AiSynthReq, AiSynthRes, AiTtsConfig, AiTtsProvider,
  AiVoiceOption } from '../AiTtsTypes';
import { aiHttpPost, decodeBase64, shortErrorBody } from '../AiTtsHttp';
import { apiKeyHeader, baseUrlOf, v1Join, applyExtraHeaders, appendExtraBody } from './AiProviderCommon';

export const MIMO_META: AiProviderMeta = {
  id: 'mimo',
  label: '小米 MiMo',
  description: '云端 TTS（chat/completions 形态，返回 base64 WAV）',
  needsBaseUrl: true,
  defaultBaseUrl: 'https://api.xiaomimimo.com/v1',
  needsApiKey: true,
  modelHint: 'mimo-v2.5-tts',
  voiceHint: '冰糖',
  supportsRate: false,
  rateMin: 1.0,
  rateMax: 1.0,
  supportsPitch: false,
  supportsFormat: false,
  formatOptions: [],
  supportsInstructions: true,
  supportsEmotion: true,
  supportsListVoices: false,
  defaultFormat: 'wav'
};

const DEFAULT_MODEL: string = 'mimo-v2.5-tts';
/** 官方默认输出格式（`audio.format` 不传时）。 */
const DEFAULT_FORMAT: string = 'wav';

/** 该模型是否是「声音复刻」—— 它的 `audio.voice` 必须传样本 base64，不能用预置音色 id。 */
export function mimoIsVoiceCloneModel(model: string): boolean {
  return model.trim().toLowerCase() === 'mimo-v2.5-tts-voiceclone';
}

/** 该模型是否是「声音设计」—— 它**不支持** `audio.voice` 字段。 */
export function mimoIsVoiceDesignModel(model: string): boolean {
  return model.trim().toLowerCase() === 'mimo-v2.5-tts-voicedesign';
}

/**
 * 归一化输出格式。
 * 官方（`docs/日志tts.md:44-47`）：可选 `wav` / `mp3` / `pcm` / `pcm16`，
 * 且「传入 `pcm` 或 `pcm16`，均表示指定使用 pcm16 格式」。
 * 归一化结果用于：① 拼请求体；② **解析返回值时的兜底格式**（真实格式仍以字节嗅探为准）。
 */
function normalizeMimoFormat(raw: string): string {
  const f: string = raw.trim().toLowerCase();
  if (f === 'mp3') {
    return 'mp3';
  }
  if (f === 'pcm' || f === 'pcm16') {
    return 'pcm';
  }
  return 'wav';
}

export class MimoTtsProvider implements AiTtsProvider {
  readonly meta: AiProviderMeta = MIMO_META;

  async synthesize(req: AiSynthReq, cancel: AiCancelToken): Promise<AiSynthRes> {
    const cfg: AiTtsConfig = req.cfg;
    const url: string = v1Join(baseUrlOf(cfg, MIMO_META), '/chat/completions');
    const headers: Record<string, string> = apiKeyHeader(cfg, 'api-key');
    // 用户自定义请求头（2026-10-11 修复：旧版这一家不读 extraHeaders ⇒ 假控件）
    applyExtraHeaders(cfg, headers);
    const model: string = cfg.model.trim().length > 0 ? cfg.model.trim() : DEFAULT_MODEL;
    const voice: string = req.voiceId.trim().length > 0 ? req.voiceId.trim() : MIMO_META.voiceHint;
    const isDesign: boolean = mimoIsVoiceDesignModel(model);
    const isClone: boolean = mimoIsVoiceCloneModel(model);

    // ── 输出格式（2026-10-11 修复 Bug 1）──────────────────────────────────
    // 旧实现把 `"format":"wav"` 与返回值的 `format:'wav'` 双双写死 ⇒
    //   用户用「附加请求体」改成 mp3/pcm 时，我们会**按 wav 解析 mp3 字节** ⇒ 满耳噪音。
    // 现在：请求用配置值归一化；返回值用同一归一化值做兜底
    //   （真实格式仍以 `sniffAudioFormat` 的字节嗅探为准，见 AiTtsProviders 的同类做法）。
    const fmt: string = normalizeMimoFormat(cfg.format.length > 0 ? cfg.format : DEFAULT_FORMAT);

    // ── messages（2026-10-11 修复 Bug 2）─────────────────────────────────
    // 官方（`docs/日志tts.md:53`）：「`optimize_text_preview` 为 true 时，
    //   **可省略**传入用于指定音频合成内容的 assistant 消息。仅支持 voicedesign 模型。」
    // 旧实现**无条件**塞 assistant ⇒ 与该参数冲突。
    // ⚠️ 但本工程是「用户给文本、我们朗读」，**必须由我们指定文本**，
    //    所以这里**不启用** optimize_text_preview（不传该字段，默认 false），
    //    assistant 消息始终保留。用户若自行通过「附加请求体」打开该参数，
    //    属于高级用法，出错时服务端原文会回显到 UI。
    let messages: string = '[';
    const ins: string = cfg.instructions.trim();
    if (ins.length > 0) {
      messages += '{"role":"user","content":' + JSON.stringify(ins) + '},';
    }
    // 待朗读文本放 assistant（官方明文要求，见文件头注释）
    messages += '{"role":"assistant","content":' + JSON.stringify(req.text) + '}]';

    // ── audio 对象 ────────────────────────────────────────────────────────
    // 官方（`:57-60`）：voice 字段按模型而异 ——
    //   voicedesign **不支持**该字段（传了可能报错）；voiceclone **必须**是样本 base64。
    let audio: string = '{"format":' + JSON.stringify(fmt);
    if (isDesign) {
      // 不支持 voice ⇒ 不传
    } else {
      audio += ',"voice":' + JSON.stringify(voice);
    }
    audio += '}';

    let body: string = '{"model":' + JSON.stringify(model) + ',"messages":' + messages +
      ',"audio":' + audio + '}';
    // 用户附加请求体（2026-10-11 修复：旧版这一家不读 extraBody ⇒ 假控件）
    body = appendExtraBody(body, cfg.extraBody);

    // 取证：voiceclone 用预置音色 id 是常见误用（官方要求 base64 样本），提前给可读提示
    if (isClone && voice.length > 0 && voice.indexOf('data:') !== 0 && voice.indexOf('base64,') < 0) {
      throw new Error('小米 MiMo 声音复刻模型的音色必须传音频样本的 base64（如 data:audio/wav;base64,…），'
        + '当前填的是预置音色 id「' + voice + '」。请改用 mimo-v2.5-tts 模型，或改填样本 base64。');
    }

    const res = await aiHttpPost(url, headers, body, false, cancel);
    if (res.code < 200 || res.code >= 300) {
      throw new Error(`小米 MiMo 返回 ${res.code}：` + shortErrorBody(res));
    }
    const root = JSON.parse(res.text) as Record<string, Object>;
    const choices = root['choices'];
    if (!Array.isArray(choices) || (choices as Array<Object>).length === 0) {
      throw new Error('小米 MiMo 响应缺少 choices：' + shortErrorBody(res));
    }
    const first = (choices as Array<Object>)[0] as Record<string, Object>;
    const msgObj = first['message'];
    if (msgObj === undefined || msgObj === null) {
      throw new Error('小米 MiMo 响应缺少 message：' + shortErrorBody(res));
    }
    const audioObj = (msgObj as Record<string, Object>)['audio'];
    if (audioObj === undefined || audioObj === null) {
      throw new Error('小米 MiMo 未返回 audio：' + shortErrorBody(res));
    }
    const b64 = (audioObj as Record<string, Object>)['data'];
    if (typeof b64 !== 'string' || (b64 as string).length === 0) {
      throw new Error('小米 MiMo 未返回音频数据：' + shortErrorBody(res));
    }
    const out: AiSynthRes = {
      data: decodeBase64(b64 as string),
      // 2026-10-11 修复 Bug 1：不再写死 'wav'，改用与请求一致的归一化格式。
      // ⚠️ 官方 `audio.data` 是 Base64（`docs/日志tts.md:97` 明文），解码用 decodeBase64 正确。
      //    `pcm` 无容器头、无从探测 ⇒ sampleRate 只能兜底 0（由调用方按 24000 处理）。
      format: fmt,
      sampleRate: 0,
      channels: 0
    };
    return out;
  }

  async listVoices(_cfg: AiTtsConfig, _cancel: AiCancelToken): Promise<AiVoiceOption[]> {
    // 该服务商无「列音色」接口（参考项目仅在预置模型下返回静态表）
    return [];
  }
}
