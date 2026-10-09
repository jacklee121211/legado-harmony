/**
 * AI 配置方案（Profile）—— 自研，**只覆盖 AI 听书**（2026-10-10 用户拍板）。
 *
 * 取舍说明：参考项目是"全引擎 12 个方案"（含 local/edge/AI + 密钥按 profileId 存），
 * 我们**只做 AI 一段**，理由：
 *   · 我们的设置分散在三个引擎（local person / Edge 4 槽 / AI 4 槽+连接参数），
 *     全量快照复杂且容易在"编辑态/激活态"上出错（参考项目那套就有这个坑）；
 *   · 用户真实需求是"小说用一套音色、散文用另一套、A/B 两个服务商"——都属于 AI 段。
 *
 * 存储：序列化成 JSON 放在 `TtsPrefs.aiProfiles`（与其它设置同源，卸载即清）。
 * 安全口径：**按用户决定，密钥明文存本地、不做加密、不上传**（见方案 §7.3）。
 */
import { TtsPrefs } from '../TtsPrefs';

export interface AiProfile {
  id: string;
  name: string;
  providerId: string;
  baseUrl: string;
  apiKey: string;
  model: string;
  format: string;
  instructions: string;
  singleVoiceId: string;
  narrationVoiceId: string;
  dialogueVoiceId: string;
  dialogueMaleVoiceId: string;
  dialogueFemaleVoiceId: string;
}

/** 最多保留多少个方案（每个含密钥，控制 Preferences 体积） */
export const AI_PROFILE_MAX: number = 12;

function asStr(v: Object | undefined, dflt: string): string {
  return typeof v === 'string' ? v as string : dflt;
}

/** 解析失败一律返回空数组（设置读取绝不因为脏数据崩） */
export function parseAiProfiles(raw: string): AiProfile[] {
  const out: AiProfile[] = [];
  if (raw.trim().length === 0) {
    return out;
  }
  try {
    const arr = JSON.parse(raw) as Object;
    if (!Array.isArray(arr)) {
      return out;
    }
    const src = arr as Array<Object>;
    for (let i = 0; i < src.length; i++) {
      const o = src[i] as Record<string, Object>;
      const name = o['name'];
      if (typeof name !== 'string' || (name as string).length === 0) {
        continue;
      }
      const p: AiProfile = {
        id: asStr(o['id'], 'p' + i),
        name: name as string,
        providerId: asStr(o['providerId'], 'openai'),
        baseUrl: asStr(o['baseUrl'], ''),
        apiKey: asStr(o['apiKey'], ''),
        model: asStr(o['model'], ''),
        format: asStr(o['format'], 'mp3'),
        instructions: asStr(o['instructions'], ''),
        singleVoiceId: asStr(o['singleVoiceId'], ''),
        narrationVoiceId: asStr(o['narrationVoiceId'], ''),
        dialogueVoiceId: asStr(o['dialogueVoiceId'], ''),
        dialogueMaleVoiceId: asStr(o['dialogueMaleVoiceId'], ''),
        dialogueFemaleVoiceId: asStr(o['dialogueFemaleVoiceId'], '')
      };
      out.push(p);
    }
  } catch (e) {
    return [];
  }
  return out;
}

export function serializeAiProfiles(list: AiProfile[]): string {
  return JSON.stringify(list);
}

/** 把当前设置快照成一个方案 */
export function snapshotAiProfile(id: string, name: string, providerId: string,
  baseUrl: string, apiKey: string, model: string, instructions: string,
  prefs: TtsPrefs): AiProfile {
  const p: AiProfile = {
    id: id,
    name: name,
    providerId: providerId,
    baseUrl: baseUrl,
    apiKey: apiKey,
    model: model,
    format: prefs.aiFormat,
    instructions: instructions,
    singleVoiceId: prefs.aiSingleVoiceId,
    narrationVoiceId: prefs.aiNarrationVoiceId,
    dialogueVoiceId: prefs.aiDialogueVoiceId,
    dialogueMaleVoiceId: prefs.aiDialogueMaleVoiceId,
    dialogueFemaleVoiceId: prefs.aiDialogueFemaleVoiceId
  };
  return p;
}

/** 把方案写回设置（**只写 AI 段字段**，不触碰其它引擎） */
export function applyAiProfile(prefs: TtsPrefs, p: AiProfile): void {
  prefs.aiProviderId = p.providerId;
  prefs.aiTtsBaseUrl = p.baseUrl;
  prefs.aiTtsApiKey = p.apiKey;
  prefs.aiTtsModel = p.model;
  if (p.format.length > 0) {
    prefs.aiFormat = p.format;
  }
  prefs.aiInstructions = p.instructions;
  prefs.aiSingleVoiceId = p.singleVoiceId;
  prefs.aiNarrationVoiceId = p.narrationVoiceId;
  prefs.aiDialogueVoiceId = p.dialogueVoiceId;
  prefs.aiDialogueMaleVoiceId = p.dialogueMaleVoiceId;
  prefs.aiDialogueFemaleVoiceId = p.dialogueFemaleVoiceId;
}

/**
 * 插入或覆盖同名方案（同名视为"更新"）。
 * 超过 {@link AI_PROFILE_MAX} 时淘汰**最旧**（数组头部）。
 */
export function upsertAiProfile(list: AiProfile[], p: AiProfile): AiProfile[] {
  const out: AiProfile[] = [];
  for (let i = 0; i < list.length; i++) {
    if (list[i].name !== p.name) {
      out.push(list[i]);
    }
  }
  out.push(p);
  while (out.length > AI_PROFILE_MAX) {
    out.shift();
  }
  return out;
}

export function removeAiProfile(list: AiProfile[], id: string): AiProfile[] {
  const out: AiProfile[] = [];
  for (let i = 0; i < list.length; i++) {
    if (list[i].id !== id) {
      out.push(list[i]);
    }
  }
  return out;
}
