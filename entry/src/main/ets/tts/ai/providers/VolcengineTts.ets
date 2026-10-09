/**
 * 火山引擎（豆包语音合成大模型 2.0）—— 自研实现。
 *
 * 协议要点（**事实来源：参考项目 `providers/volcengineProvider.ts` 的实现**，
 * 其作者经实战验证；本环境无法出网核对官方文档，故以实现为准并在此标注）：
 *  · URL：`https://openspeech.bytedance.com/api/v3/tts/unidirectional`
 *  · 头：`X-Api-Key` + `X-Api-Resource-Id: seed-tts-2.0` + `X-Api-Request-Id: <uuid>`
 *  · 体：`{"req_params":{"text","speaker","audio_params":{"format":"pcm","sample_rate","speech_rate"},
 *         "additions":"<**二次序列化**的 JSON 字符串>"}}`
 *  · 响应：**NDJSON**（每行一个 JSON）：`code===0` 为音频分片（`data` base64）；
 *         `code===20000000` 为完成；其他 code 为业务错误
 *  · 参数换算：`speech_rate = round((clamp(rate,0.5,2)-1)*100)` ⇒ [-50,100]
 *
 * ⚠️ 限流：参考项目对本厂商用了「全局串行 + 最小间隔 280ms + 5 次指数退避」；
 *    我们的 `aiSynthSerial` 已提供全局串行 + 200ms 间隔（同一思路），故不再叠加。
 */
import { AiCancelToken, AiProviderMeta, AiSynthReq, AiSynthRes, AiTtsConfig, AiTtsProvider,
  AiVoiceOption } from '../AiTtsTypes';
import { aiHttpPost, concatBytes, decodeBase64, shortErrorBody } from '../AiTtsHttp';
import { baseUrlOf, clampNum, uuidLike } from './AiProviderCommon';

export const VOLCENGINE_META: AiProviderMeta = {
  id: 'volcengine',
  label: '火山豆包',
  description: '豆包语音合成大模型 2.0；NDJSON 返回 base64 PCM，音色最全',
  needsBaseUrl: false,
  defaultBaseUrl: 'https://openspeech.bytedance.com/api/v3/tts/unidirectional',
  needsApiKey: true,
  modelHint: 'seed-tts-2.0',
  voiceHint: 'zh_male_ruyayichen_uranus_bigtts',
  supportsRate: true,
  rateMin: 0.5,
  rateMax: 2.0,
  supportsPitch: false,
  supportsFormat: false,
  formatOptions: [],
  supportsInstructions: true,
  supportsEmotion: true,
  supportsListVoices: false,
  defaultFormat: 'pcm'
};

const RESOURCE_ID: string = 'seed-tts-2.0';
const SAMPLE_RATE: number = 24000;
/** 完成事件码（见参考实现） */
const CODE_DONE: number = 20000000;

export class VolcengineTtsProvider implements AiTtsProvider {
  readonly meta: AiProviderMeta = VOLCENGINE_META;

  async synthesize(req: AiSynthReq, cancel: AiCancelToken): Promise<AiSynthRes> {
    const cfg: AiTtsConfig = req.cfg;
    const url: string = baseUrlOf(cfg, VOLCENGINE_META);
    const headers: Record<string, string> = {};
    headers['Content-Type'] = 'application/json';
    headers['X-Api-Key'] = cfg.apiKey.trim();
    headers['X-Api-Resource-Id'] = RESOURCE_ID;
    headers['X-Api-Request-Id'] = uuidLike();

    const speaker: string = req.voiceId.trim().length > 0 ? req.voiceId.trim() : VOLCENGINE_META.voiceHint;
    const speechRate: number = Math.round((clampNum(req.rate, 0.5, 2.0) - 1) * 100);
    let reqParams: string = '{"text":' + JSON.stringify(req.text) +
      ',"speaker":' + JSON.stringify(speaker) +
      ',"audio_params":{"format":"pcm","sample_rate":' + SAMPLE_RATE +
      ',"speech_rate":' + speechRate + '}';
    const ins: string = cfg.instructions.trim();
    if (ins.length > 0) {
      // 官方要求 additions 是**二次序列化的字符串**
      const additionsObj: string = '{"context_texts":[' + JSON.stringify(ins) + ']}';
      reqParams += ',"additions":' + JSON.stringify(additionsObj);
    }
    reqParams += '}';
    const body: string = '{"req_params":' + reqParams + '}';

    const res = await aiHttpPost(url, headers, body, false, cancel);
    if (res.code < 200 || res.code >= 300) {
      throw new Error(`火山返回 ${res.code}：` + shortErrorBody(res));
    }
    const parts: Uint8Array[] = [];
    let total: number = 0;
    let bizErr: string = '';
    const lines: string[] = res.text.split('\n');
    for (let i = 0; i < lines.length; i++) {
      const t: string = lines[i].trim();
      if (t.length === 0) {
        continue;
      }
      let evt: Record<string, Object>;
      try {
        evt = JSON.parse(t) as Record<string, Object>;
      } catch (e) {
        continue; // 非 JSON 行（空行/心跳）跳过
      }
      const code = evt['code'];
      if (typeof code !== 'number') {
        continue;
      }
      if (code === CODE_DONE) {
        break;
      }
      if (code === 0) {
        const d = evt['data'];
        if (typeof d === 'string' && (d as string).length > 0) {
          const u8 = new Uint8Array(decodeBase64(d as string));
          parts.push(u8);
          total += u8.byteLength;
        }
        continue;
      }
      // 业务错误：记录首条并停止
      const msg = evt['message'];
      bizErr = '火山错误码 ' + code + (typeof msg === 'string' ? '：' + (msg as string) : '');
      break;
    }
    if (bizErr.length > 0) {
      throw new Error(bizErr);
    }
    if (parts.length === 0) {
      throw new Error('火山未返回音频数据：' + shortErrorBody(res));
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
    // 该服务商无「列音色」接口（参考项目用的是内置 293+151 条静态表）
    return [];
  }
}
