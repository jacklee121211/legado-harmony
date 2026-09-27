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
  '你是小说朗读的说话人识别助手。对给定的每条对白，判断说话人的性别。' +
  '只输出一个 JSON 对象：键是对白编号（字符串数字），值只能是 "male"、"female" 或 "unknown"。' +
  '不要输出 JSON 以外的任何内容。';

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
  let sb = '请逐条判断下列对白的说话人性别：\n';
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
 * 批量标注性别。返回数组长度与 items 一致。
 * @throws { Error } 网络请求失败 / 非 2xx / 响应无法解析时抛出，由调用方回落为 'unknown'
 */
export async function classifyDialogueGenders(baseUrl: string, apiKey: string,
  model: string, items: SpeakerItem[]): Promise<SpeakerKind[]> {
  const kinds: SpeakerKind[] = [];
  for (let i = 0; i < items.length; i++) {
    kinds.push('unknown');
  }
  if (items.length === 0) {
    return kinds;
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
      if (v !== undefined && v !== null) {
        kinds[i] = kindOf(v);
      }
    }
    hilog.info(DOMAIN, TAG, 'classify ok items=%{public}d', batch.length);
    return kinds;
  } finally {
    httpRequest.destroy();
  }
}
