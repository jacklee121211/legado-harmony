/**
 * AI 对白说话人性别识别（对齐 PC 版 ColorTxt 的 voiceReadSpeakerIpc 机制）。
 * 调用 OpenAI 兼容 chat/completions 接口，把一章内的对白块批量标注为
 * male / female / unknown，引擎据此套用"男生音色/女生音色"。
 * 每章一次请求（≤50 条），失败静默回落到统一对白音色。
 */
import { http } from '@kit.NetworkKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG = 'TtsSpeaker';
const DOMAIN = 0x0001;
const MAX_BATCH = 50;

export type SpeakerKind = 'male' | 'female' | 'unknown';

export interface SpeakerItem {
  text: string;
  before: string;
  after: string;
}

const SYSTEM_PROMPT =
  '你是小说朗读的说话人识别助手。对给定的每条对白，判断说话人性别、可能的说话人名字、以及朗读语气。' +
  '只输出一个 JSON 对象：键是对白编号（字符串数字），值是一个对象：' +
  '{"kind":"male|female|unknown","speaker":"角色名或空串","emotion":"10~30字的语气描述或空串"}。' +
  '不要输出 JSON 以外的任何内容。';

/**
 * 一条对白的完整标注（2026-10-10 扩展）。
 * · kind：性别（原有能力，三引擎通用）
 * · speaker：**说话人名字**——用于"角色名 → 音色自动分配"（用户接受的低成本折中方案，
 *   不需要角色卡、不需要 AI 书籍分析）；
 * · emotion：**朗读语气**（自然语言）——仅对该服务商支持时透传（见 AiProviderMeta.supportsEmotion）。
 * ⚠️ 三者都从**同一次 LLM 调用**返回，不额外增加请求数。
 */
export interface SpeakerLabel {
  kind: SpeakerKind;
  speaker: string;
  emotion: string;
}

/** OpenAI 兼容请求体（显式接口，满足 ArkTS 对象字面量类型约束） */
interface ChatMessage {
  role: string;
  content: string;
}

interface ChatRequest {
  model: string;
  temperature: number;
  messages: ChatMessage[];
}

function buildUserPrompt(items: SpeakerItem[]): string {
  let sb = '请逐条判断下列对白的说话人性别、可能的说话人名字、以及朗读语气：\n';
  for (let i = 0; i < items.length; i++) {
    const it = items[i];
    sb += `[${i}] 对白：${it.text}`;
    if (it.before.length > 0) {
      sb += ` ｜上文：${it.before}`;
    }
    if (it.after.length > 0) {
      sb += ` ｜下文：${it.after}`;
    }
    sb += '\n';
  }
  sb += '提示：说话人名字只能来自上文/下文中出现的角色名，不确定就留空串，不要编造。';
  return sb;
}

/** 从模型输出中提取 JSON 对象（容忍 ```json 代码围栏） */
function extractJsonObject(content: string): Record<string, Object> | null {
  const start = content.indexOf('{');
  const end = content.lastIndexOf('}');
  if (start < 0 || end <= start) {
    return null;
  }
  try {
    return JSON.parse(content.substring(start, end + 1)) as Record<string, Object>;
  } catch (e) {
    return null;
  }
}

function kindOf(v: Object): SpeakerKind {
  if (typeof v === 'string') {
    const s = (v as string).trim().toLowerCase();
    if (s === 'male' || s === '男') {
      return 'male';
    }
    if (s === 'female' || s === '女') {
      return 'female';
    }
  }
  return 'unknown';
}

/**
 * 批量标注（性别 + 说话人 + 语气）。返回数组长度与 items 一致。
 *
 * **向后兼容**：模型若仍只回 `"0":"male"`（字符串形式），按"只有性别"解析，
 * 说话人与语气留空 —— 老行为不丢。
 *
 * @throws { Error } 网络请求失败 / 非 2xx / 响应无法解析时抛出，由调用方回落为 'unknown'
 */
export async function classifyDialogueLabels(baseUrl: string, apiKey: string,
  model: string, items: SpeakerItem[], wantEmotion: boolean): Promise<SpeakerLabel[]> {
  const out: SpeakerLabel[] = [];
  for (let i = 0; i < items.length; i++) {
    const l: SpeakerLabel = { kind: 'unknown', speaker: '', emotion: '' };
    out.push(l);
  }
  if (items.length === 0) {
    return out;
  }
  const batch = items.length > MAX_BATCH ? items.slice(0, MAX_BATCH) : items;

  const messages: ChatMessage[] = [
    { role: 'system', content: SYSTEM_PROMPT },
    { role: 'user', content: buildUserPrompt(batch) }
  ];
  const body: ChatRequest = {
    model: model,
    temperature: 0,
    messages: messages
  };

  const url = baseUrl.replace(/\/+$/, '') + '/chat/completions';
  const httpRequest = http.createHttp();
  try {
    const resp = await httpRequest.request(url, {
      method: http.RequestMethod.POST,
      header: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer ' + apiKey
      },
      extraData: JSON.stringify(body),
      expectDataType: http.HttpDataType.STRING,
      connectTimeout: 15000,
      readTimeout: 60000
    });
    if (resp.responseCode < 200 || resp.responseCode >= 300) {
      throw new Error(`HTTP ${resp.responseCode}`);
    }
    const raw = typeof resp.result === 'string' ? resp.result : String(resp.result);
    const outer = JSON.parse(raw) as Record<string, Object>;
    const choices = outer['choices'];
    if (!Array.isArray(choices) || choices.length === 0) {
      throw new Error('响应缺少 choices');
    }
    const first = choices[0] as Record<string, Object>;
    const message = first['message'] as Record<string, Object>;
    const content = typeof message['content'] === 'string' ? message['content'] as string : '';
    const map = extractJsonObject(content);
    if (map === null) {
      throw new Error('模型输出无法解析为 JSON');
    }
    for (let i = 0; i < batch.length; i++) {
      const v = map[i.toString()];
      if (v === undefined || v === null) {
        continue;
      }
      if (typeof v === 'string') {
        // 旧格式兼容：值直接是 "male"/"female"/"unknown"
        out[i].kind = kindOf(v);
        continue;
      }
      const o = v as Record<string, Object>;
      out[i].kind = kindOf(o['kind']);
      const sp = o['speaker'];
      if (typeof sp === 'string') {
        const s = (sp as string).trim();
        // 容忍模型把"无"写成 null 字符串
        if (s.length > 0 && s !== 'null' && s !== '无' && s !== 'unknown') {
          out[i].speaker = s.length > 20 ? s.substring(0, 20) : s;
        }
      }
      if (wantEmotion) {
        const em = o['emotion'];
        if (typeof em === 'string') {
          const e = (em as string).trim();
          if (e.length > 0 && e !== 'auto' && e !== 'null') {
            out[i].emotion = e.length > 40 ? e.substring(0, 40) : e;
          }
        }
      }
    }
    hilog.info(DOMAIN, TAG, 'classify ok items=%{public}d emotion=%{public}s',
      batch.length, String(wantEmotion));
    return out;
  } finally {
    httpRequest.destroy();
  }
}

/**
 * 批量标注（性别 + 说话人 + 语气），见 {@link classifyDialogueLabels}。
 * 旧的 `classifyDialogueGenders` 已删除（2026-10-10）：它只是新函数的薄封装，
 * 留着会触发 etsLint「函数可能抛异常」告警，且无人调用。
 */
