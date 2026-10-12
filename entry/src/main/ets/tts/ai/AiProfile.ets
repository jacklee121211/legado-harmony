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

/* ══════════════════════════════════════════════════════════════════════════
 * AI 男女声（说话人识别）方案 —— 2026-10-12 新增
 *
 * ── 为什么与 {@link AiProfile} **分开存、且不含音色**（用户 2026-10-12 拍板）──
 * 用户原话（冲突场景）：
 *   「比如我有 2 个服务商，现在用 A 的 tts，记录了一个方案，是 A 的 tts 和 A 的
 *     男女声音色分配，此时我的男女生分辨服务商也是 A。此时我换了 B 服务商的 tts，
 *     然后我又想用为 A 服务时候的那个服务商做音色识别，我点击了 A 方案，就会发生冲突」
 * ⇒ 若识别方案里带音色，切"识别方案"会**顺手改掉 TTS 音色** ⇒ 用户被静默改配置。
 *
 * 故本方案**只存三个连接要素**：接口地址 / API Key / 模型名。
 * 用户口径：「我们存的接口地址、api、模型名不就是服务商吗？总是这三个数据保存是方案」
 *   ⇒ 不加"服务商"字段，填了这三项即等于选定了服务商。
 *
 * 与 TTS 的关系：**完全解耦**。它只负责"拿文本问 LLM 这句话是谁说的"，
 * 与 TTS 音色无关；因此切换它**绝不触碰任何音色槽**。
 * ══════════════════════════════════════════════════════════════════════════ */

/** AI 男女声（说话人识别）方案：**仅三要素**，不含音色 */
export interface AiSpeakerProfile {
  id: string;
  name: string;
  baseUrl: string;
  apiKey: string;
  model: string;
}

/** 最多保留多少个识别方案（每个含密钥，控制 Preferences 体积） */
export const AI_SPEAKER_PROFILE_MAX: number = 12;

/** 解析失败一律返回空数组（设置读取绝不因为脏数据崩） */
export function parseAiSpeakerProfiles(raw: string): AiSpeakerProfile[] {
  const out: AiSpeakerProfile[] = [];
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
      const p: AiSpeakerProfile = {
        id: asStr(o['id'], 'sp' + i),
        name: name as string,
        baseUrl: asStr(o['baseUrl'], ''),
        apiKey: asStr(o['apiKey'], ''),
        model: asStr(o['model'], '')
      };
      out.push(p);
    }
  } catch (e) {
    return [];
  }
  return out;
}

export function serializeAiSpeakerProfiles(list: AiSpeakerProfile[]): string {
  return JSON.stringify(list);
}

/** 把当前识别三要素快照成一个方案 */
export function snapshotAiSpeakerProfile(id: string, name: string,
  baseUrl: string, apiKey: string, model: string): AiSpeakerProfile {
  const p: AiSpeakerProfile = {
    id: id,
    name: name,
    baseUrl: baseUrl,
    apiKey: apiKey,
    model: model
  };
  return p;
}

/**
 * 把方案写回设置。
 * ⚠️ **只写这三个字段**（`aiBaseUrl` / `aiApiKey` / `aiModel`），
 *    绝不触碰 `aiTts*` 与任何音色槽 —— 这是本类型存在的全部意义。
 *    （调用方仍需自行 `commitPrefs()` 落盘。）
 */
export function applyAiSpeakerProfile(prefs: TtsPrefs, p: AiSpeakerProfile): void {
  prefs.aiBaseUrl = p.baseUrl;
  prefs.aiApiKey = p.apiKey;
  prefs.aiModel = p.model;
}

/** 插入或覆盖同名方案（同名视为"更新"）；超上限淘汰最旧（数组头部） */
export function upsertAiSpeakerProfile(list: AiSpeakerProfile[],
  p: AiSpeakerProfile): AiSpeakerProfile[] {
  const out: AiSpeakerProfile[] = [];
  for (let i = 0; i < list.length; i++) {
    if (list[i].name !== p.name) {
      out.push(list[i]);
    }
  }
  out.push(p);
  while (out.length > AI_SPEAKER_PROFILE_MAX) {
    out.shift();
  }
  return out;
}

export function removeAiSpeakerProfile(list: AiSpeakerProfile[],
  id: string): AiSpeakerProfile[] {
  const out: AiSpeakerProfile[] = [];
  for (let i = 0; i < list.length; i++) {
    if (list[i].id !== id) {
      out.push(list[i]);
    }
  }
  return out;
}
