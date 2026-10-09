/**
 * MiniMax 语音合成（自研实现）。
 *
 * 协议要点（**事实来源：参考项目 `providers/minimaxProvider.ts` 的实现**，
 * 该实现经其作者实战验证；我出不了网，无法核对官方文档，故以实现为准并在此标注）：
 *  · URL：`{base}/v1/t2a_v2`（列音色：`{base}/v1/get_voice`）
 *  · 鉴权：`Authorization: Bearer <key>`
 *  · 请求体：`{model, text, stream:false, voice_setting:{voice_id,speed,vol,pitch}, audio_setting:{sample_rate,format}}`
 *  · 响应：**一次性 JSON**，音频在 `data.audio`，可能是 **hex 也可能是 base64**（两种都试）
 *  · 业务错误：`base_resp.status_code !== 0`（HTTP 200 也可能是业务失败）
 *  · 音色：`/v1/get_voice {voice_type:"all"}` → system_voice / voice_cloning / voice_generation 三组
 *
 * 与参考项目的差异（我们不做的事）：不复制它的情绪枚举映射表与音色性别推断正则
 * （属其表达层，见方案 §14.3）；情绪走我们自己的「风格提示词」透传。
 */
import { AiCancelToken, AiProviderMeta, AiSynthReq, AiSynthRes, AiTtsConfig, AiTtsProvider,
  AiVoiceOption, AI_PERMANENT_PREFIX } from '../AiTtsTypes';
import { aiHttpPost, decodeAudioSmart, shortErrorBody } from '../AiTtsHttp';
import { baseUrlOf, bearerHeaders, clampNum, v1Join } from './AiProviderCommon';

export const MINIMAX_META: AiProviderMeta = {
  id: 'minimax',
  label: 'MiniMax',
  description: '云端 TTS，音色丰富；支持从服务商拉取音色清单',
  needsBaseUrl: true,
  defaultBaseUrl: 'https://api.minimaxi.com/v1',
  needsApiKey: true,
  modelHint: 'speech-2.8-turbo',
  voiceHint: 'Chinese (Mandarin)_Male_Announcer',
  supportsRate: true,
  rateMin: 0.5,
  rateMax: 2.0,
  supportsPitch: false,
  supportsFormat: false,
  formatOptions: [],
  supportsInstructions: false,
  // ⚠️ MiniMax 的 emotion 只吃固定枚举（参考实现：worried→fearful、2.8 丢弃 whisper）；
  //    我们不做枚举映射 ⇒ 标 false，UI 隐藏情绪开关（防"假控件"）
  supportsEmotion: false,
  supportsListVoices: true,
  defaultFormat: 'mp3'
};

const DEFAULT_MODEL: string = 'speech-2.8-turbo';
const SAMPLE_RATE: number = 32000;

/** 业务错误（HTTP 200 但 base_resp.status_code != 0）也算**永久错误**：重试无意义 */
function businessError(root: Record<string, Object>): string {
  const br = root['base_resp'];
  if (br === undefined || br === null) {
    return '';
  }
  const code = (br as Record<string, Object>)['status_code'];
  if (typeof code !== 'number' || code === 0) {
    return '';
  }
  const msg = (br as Record<string, Object>)['status_msg'];
  return 'MiniMax 业务错误 ' + code + (typeof msg === 'string' ? '：' + (msg as string) : '');
}

export class MiniMaxTtsProvider implements AiTtsProvider {
  readonly meta: AiProviderMeta = MINIMAX_META;

  async synthesize(req: AiSynthReq, cancel: AiCancelToken): Promise<AiSynthRes> {
    const cfg: AiTtsConfig = req.cfg;
    const url: string = v1Join(baseUrlOf(cfg, MINIMAX_META), '/t2a_v2');
    const headers: Record<string, string> = bearerHeaders(cfg);
    const model: string = cfg.model.trim().length > 0 ? cfg.model.trim() : DEFAULT_MODEL;
    const voice: string = req.voiceId.trim().length > 0 ? req.voiceId.trim() : MINIMAX_META.voiceHint;
    const speed: number = clampNum(req.rate, 0.5, 2.0);
    const body: string = '{' +
      '"model":' + JSON.stringify(model) + ',' +
      '"text":' + JSON.stringify(req.text) + ',' +
      '"stream":false,' +
      '"voice_setting":{"voice_id":' + JSON.stringify(voice) + ',"speed":' + speed.toFixed(2) + '},' +
      '"audio_setting":{"sample_rate":' + SAMPLE_RATE + ',"format":"mp3","channel":1}' +
      '}';

    const res = await aiHttpPost(url, headers, body, false, cancel);
    if (res.code < 200 || res.code >= 300) {
      throw new Error(AI_PERMANENT_PREFIX + `MiniMax 返回 ${res.code}：` + shortErrorBody(res));
    }
    const root = JSON.parse(res.text) as Record<string, Object>;
    const biz: string = businessError(root);
    if (biz.length > 0) {
      throw new Error(AI_PERMANENT_PREFIX + biz);
    }
    const dataObj = root['data'];
    if (dataObj === undefined || dataObj === null) {
      throw new Error(`MiniMax 未返回音频：` + shortErrorBody(res));
    }
    const audio = (dataObj as Record<string, Object>)['audio'];
    if (typeof audio !== 'string' || (audio as string).length === 0) {
      throw new Error(`MiniMax 未返回音频数据：` + shortErrorBody(res));
    }
    // ⚠️ MiniMax 的音频字段**可能是 hex 也可能是 base64**（参考实现两种都试）。
    //    这里用 `decodeAudioSmart`：解出来像 MP3 的那个方案优先，避免短 base64 被误判成 hex。
    const buf = decodeAudioSmart(audio as string);
    const out: AiSynthRes = {
      data: buf,
      format: 'mp3',
      sampleRate: SAMPLE_RATE,
      channels: 1
    };
    return out;
  }

  async listVoices(cfg: AiTtsConfig, cancel: AiCancelToken): Promise<AiVoiceOption[]> {    const url: string = v1Join(baseUrlOf(cfg, MINIMAX_META), '/get_voice');
    const res = await aiHttpPost(url, bearerHeaders(cfg), '{"voice_type":"all"}', false, cancel);
    if (res.code < 200 || res.code >= 300) {
      throw new Error(`MiniMax 查询音色返回 ${res.code}：` + shortErrorBody(res));
    }
    const root = JSON.parse(res.text) as Record<string, Object>;
    const biz: string = businessError(root);
    if (biz.length > 0) {
      throw new Error(biz);
    }
    const out: AiVoiceOption[] = [];
    // 三组音色：系统音色 / 快速复刻 / 文生音色
    const groups: string[] = ['system_voice', 'voice_cloning', 'voice_generation'];
    const groupLabel: string[] = ['系统音色', '快速复刻', '文生音色'];
    for (let g = 0; g < groups.length; g++) {
      const arr = root[groups[g]];
      if (!Array.isArray(arr)) {
        continue;
      }
      const src = arr as Array<Object>;
      for (let i = 0; i < src.length; i++) {
        const o = src[i] as Record<string, Object>;
        const id = o['voice_id'];
        if (typeof id !== 'string' || (id as string).length === 0) {
          continue;
        }
        const nm = o['voice_name'];
        const ds = o['description'];
        const item: AiVoiceOption = {
          id: id as string,
          label: typeof nm === 'string' && (nm as string).length > 0 ? (nm as string) : (id as string),
          description: groupLabel[g] + (typeof ds === 'string' && (ds as string).length > 0
            ? ' · ' + (ds as string) : ''),
          gender: ''
        };
        out.push(item);
      }
    }
    return out;
  }
}
