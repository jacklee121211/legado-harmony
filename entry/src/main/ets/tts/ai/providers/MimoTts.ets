/**
 * 小米 MiMo（把 TTS 塞进 chat/completions）—— 自研实现。
 *
 * 协议要点（**事实来源：参考项目 `providers/mimoProvider.ts` 的实现**，
 * 其作者经实战验证；本环境无法出网核对官方文档，故以实现为准并在此标注）：
 *  · URL：`{base}/v1/chat/completions`
 *  · 头：**`api-key: <key>`**（不是 Bearer）
 *  · 体：`{"model":..., "messages":[{role:"user",content:<风格描述>?},
 *         {role:"assistant",content:<**待朗读文本**>}], "audio":{"format":"wav","voice":...}}`
 *    ⇒ 待读文本放在 **assistant 角色**（这点很反直觉，但这就是它的协议）
 *  · 响应：`choices[0].message.audio.data`（base64）→ **wav**
 *
 * ⚠️ 参考项目对 Base URL 有"按 Key 前缀推导域名"的逻辑（tp- 走另一域名）；
 *    我们简化为**用户自己填 baseUrl**（我们本就是"用户自带接口"的定位），
 *    默认 `https://api.xiaomimimo.com/v1`。
 */
import { AiCancelToken, AiProviderMeta, AiSynthReq, AiSynthRes, AiTtsConfig, AiTtsProvider,
  AiVoiceOption } from '../AiTtsTypes';
import { aiHttpPost, decodeBase64, shortErrorBody } from '../AiTtsHttp';
import { apiKeyHeader, baseUrlOf, v1Join } from './AiProviderCommon';

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

export class MimoTtsProvider implements AiTtsProvider {
  readonly meta: AiProviderMeta = MIMO_META;

  async synthesize(req: AiSynthReq, cancel: AiCancelToken): Promise<AiSynthRes> {
    const cfg: AiTtsConfig = req.cfg;
    const url: string = v1Join(baseUrlOf(cfg, MIMO_META), '/chat/completions');
    const headers: Record<string, string> = apiKeyHeader(cfg, 'api-key');
    const model: string = cfg.model.trim().length > 0 ? cfg.model.trim() : DEFAULT_MODEL;
    const voice: string = req.voiceId.trim().length > 0 ? req.voiceId.trim() : MIMO_META.voiceHint;

    let messages: string = '[';
    const ins: string = cfg.instructions.trim();
    if (ins.length > 0) {
      messages += '{"role":"user","content":' + JSON.stringify(ins) + '},';
    }
    // ⚠️ 待朗读文本放 assistant（该协议的怪点，照参考实现）
    messages += '{"role":"assistant","content":' + JSON.stringify(req.text) + '}]';
    const body: string = '{"model":' + JSON.stringify(model) + ',"messages":' + messages +
      ',"audio":{"format":"wav","voice":' + JSON.stringify(voice) + '}}';

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
      format: 'wav',
      sampleRate: 0,   // 由 WAV 头在播放时解析
      channels: 0
    };
    return out;
  }

  async listVoices(_cfg: AiTtsConfig, _cancel: AiCancelToken): Promise<AiVoiceOption[]> {
    // 该服务商无「列音色」接口（参考项目仅在预置模型下返回静态表）
    return [];
  }
}
