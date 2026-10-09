/**
 * 朗读全部可调参数（与 PC 版 ColorTxt voiceReadProfiles 参数面对齐）+ clamp + 持久化。
 * scheme: single 单音色 / multi 多角色（旁白/对白分音色）
 * quoteStyles: 启用的对白引号风格下标（0="" 1='' 2=「」 3=『』）
 */
import { PreferencesUtil } from '@pura/harmony-utils';
import { DEFAULT_SPEAK_FILTER_TEXT } from './SpeakFilter';
import {
  EDGE_DEFAULT_NARRATION_VOICE, EDGE_DEFAULT_DIALOGUE_VOICE,
  EDGE_DEFAULT_DIALOGUE_MALE_VOICE, EDGE_DEFAULT_DIALOGUE_FEMALE_VOICE,
  EDGE_DEFAULT_SINGLE_VOICE
} from './EdgeVoices';
import {
  LOCAL_DEFAULT_SINGLE_PERSON, LOCAL_DEFAULT_NARRATION_PERSON,
  LOCAL_DEFAULT_DIALOGUE_MALE_PERSON, LOCAL_DEFAULT_DIALOGUE_FEMALE_PERSON,
  isLocalPersonValid
} from './LocalVoices';

export type TtsScheme = 'single' | 'multi';
/**
 * TTS 引擎选择：
 *  · 'local'（默认）：系统本地引擎（Core Speech Kit textToSpeech），端侧合成、无网可用、
 *    上架合规；单音色（聆小珊），无词级时间戳（停顿拼接/句级高亮精度降级）；
 *  · 'edge'：Edge TTS（云端合成、音色丰富、词级时间戳）——**暗门解锁后**才允许选择
 *    （TtsEngine.activeEngineId() 二次校验：未解锁一律回落 'local'）；
 *  · 'ai'（2026-10-09 新增）：**用户自接入的 AI 语音**（OpenAI 兼容 /v1/audio/speech 等），
 *    由听书面板顶栏开关 `aiTtsEnabled` 控制，不受暗门约束；
 *    ⚠️ 优先级为 **Edge > AI > local**（用户口径：「只要开启 edge，直接使用 edge」），
 *    见 docs/ai-voice-read-plan-2026-10-09.md §13.6.1。
 */
export type TtsEngineKind = 'local' | 'edge' | 'ai';

export interface TtsPrefs {
  ttsEngine: TtsEngineKind; // 双引擎选择（默认 local；edge 仅解锁后生效）
  // ── 本地引擎专属参数（Core Speech Kit；与 Edge 参数互相独立）──────────────
  localSinglePerson: number;        // 单音色方案音色（引擎级 person，13=聆小珊）
  localNarrationPerson: number;     // 多角色：旁白音色
  localDialogueMalePerson: number;  // 多角色：对白/男生音色（默认 21=凌飞哲）
  localDialogueFemalePerson: number; // 多角色：女生音色
  localRate: number;                // 语速 0.5 ~ 2.0（extraParams<'speed'>）
  // （音量复用全局 volume：以 PCM 增益统一施加，两引擎口径一致；
  //   音调本地引擎无官方参数键（SDK extraParams 未定义 pitch）⇒ 面板隐藏）
  scheme: TtsScheme;
  singleVoiceId: string;
  narrationVoiceId: string;
  dialogueVoiceId: string;
  dialogueMaleVoiceId: string;
  dialogueFemaleVoiceId: string;
  quoteStyles: number[];
  rate: number;            // 0.5 ~ 2.0
  pitch: number;           // 0.5 ~ 2.0
  volume: number;          // 0 ~ 1
  pauseSentenceMs: number; // 0 ~ 1200
  pauseCommaMs: number;    // 0 ~ 600
  autoFollow: boolean;     // 朗读推进时阅读器跟随跳章
  immersiveListen: boolean; // 沉浸听读：自绘当前页，句子高亮画在文字内部（像素级精确）
  aiSpeakerRecognitionEnabled: boolean; // AI 识别对白说话人性别（男/女分音色）
  /**
   * AI 情绪标注（2026-10-10）：与男女声**同一次 LLM 调用**返回语气，
   * 透传成该服务商的风格参数（instructions / context_texts）。
   * 仅当服务商 `supportsEmotion` 时 UI 才显示；不支持的厂商（如 MiniMax 只吃固定枚举）隐藏。
   */
  aiEmotionEnabled: boolean;
  /**
   * AI 配置方案（JSON 数组，见 `tts/ai/AiProfile.ets`）。空串 = 没有方案。
   * ⚠️ 含密钥，但按用户决定**明文存本地、不加密、不上传**。
   */
  aiProfiles: string;
  /**
   * 朗读过滤（2026-10-10，对齐参考项目能力）
   * · enabled：总开关；关闭后行为与改动前逐字一致（可一键回退）；
   * · text：一行一条规则，`~` 前缀=字面量，`#` 前缀=注释（见 `SpeakFilter.ets`）。
   * 机制是**等长空格掩码** ⇒ 高亮偏移/行号不受影响。
   */
  speakFilterEnabled: boolean;
  speakFilterText: string;
  aiBaseUrl: string;       // OpenAI 兼容接口，如 https://api.deepseek.com/v1
  aiApiKey: string;
  aiModel: string;         // 如 deepseek-chat
  // ── AI 听书（用户自接入 TTS，2026-10-09 新增；与上面的大模型接口是**两套配置**）──────
  // ⚠️ 上面 aiBaseUrl/aiApiKey/aiModel 服务「AI 男女声识别」（对话大模型）；
  //    下面 aiTts* 服务「AI 语音合成」（TTS）。UI 必须分块显示，否则用户必然填串。
  aiTtsEnabled: boolean;   // 顶栏开关：默认 false；仅 ttsState==='stopped' 时可切换
  aiProviderId: string;    // 服务商 id（见 tts/ai/AiTtsProviders，当前仅 'openai'）
  aiTtsBaseUrl: string;    // TTS 接口地址（OpenAI 兼容形，如 https://api.openai.com/v1）
  aiTtsApiKey: string;     // TTS 密钥
  aiTtsModel: string;      // TTS 模型名，如 tts-1
  aiFormat: string;        // 输出格式：'mp3' | 'wav' | 'pcm'
  aiInstructions: string;  // 风格/语气提示词（透传为 instructions，仅支持的服务商）
  aiExtraBody: string;     // 附加请求体 JSON 片段（合并进 body）
  aiExtraHeaders: string;  // 附加请求头（行式 `Key: Value`）
  aiSingleVoiceId: string;
  aiNarrationVoiceId: string;
  aiDialogueVoiceId: string;
  aiDialogueMaleVoiceId: string;
  aiDialogueFemaleVoiceId: string;
}

export const RATE_MIN = 0.5;
export const RATE_MAX = 2.0;
export const PITCH_MIN = 0.5;
export const PITCH_MAX = 2.0;
export const VOLUME_MIN = 0.0;
export const VOLUME_MAX = 1.0;
export const PAUSE_SENTENCE_MIN = 0;
export const PAUSE_SENTENCE_MAX = 3000;
export const PAUSE_COMMA_MIN = 0;
export const PAUSE_COMMA_MAX = 1800;

export const ALL_QUOTE_STYLES: number[] = [0, 1, 2, 3];
export const QUOTE_STYLE_LABELS: string[] = ['\u201C\u201D', '\u2018\u2019', '\u300C\u300D', '\u300E\u300F'];

export function defaultTtsPrefs(): TtsPrefs {
  const d: TtsPrefs = {
    ttsEngine: 'local',
    localSinglePerson: LOCAL_DEFAULT_SINGLE_PERSON,
    localNarrationPerson: LOCAL_DEFAULT_NARRATION_PERSON,
    localDialogueMalePerson: LOCAL_DEFAULT_DIALOGUE_MALE_PERSON,
    localDialogueFemalePerson: LOCAL_DEFAULT_DIALOGUE_FEMALE_PERSON,
    localRate: 1.0,
    scheme: 'multi',
    singleVoiceId: EDGE_DEFAULT_SINGLE_VOICE,
    narrationVoiceId: EDGE_DEFAULT_NARRATION_VOICE,
    dialogueVoiceId: EDGE_DEFAULT_DIALOGUE_VOICE,
    dialogueMaleVoiceId: EDGE_DEFAULT_DIALOGUE_MALE_VOICE,
    dialogueFemaleVoiceId: EDGE_DEFAULT_DIALOGUE_FEMALE_VOICE,
    quoteStyles: [0, 1, 2, 3],
    rate: 1.0,
    pitch: 1.0,
    volume: 1.0,
    pauseSentenceMs: 700,
    pauseCommaMs: 540,
    autoFollow: true,
    immersiveListen: true,
    aiSpeakerRecognitionEnabled: false,
    aiEmotionEnabled: true,
    aiProfiles: '',
    speakFilterEnabled: true,
    speakFilterText: DEFAULT_SPEAK_FILTER_TEXT,
    aiBaseUrl: '',
    aiApiKey: '',
    aiModel: '',
    // ── AI 听书默认值（全部"关/空"，老用户升级后行为与今天完全一致）──────────
    aiTtsEnabled: false,
    aiProviderId: 'openai',
    aiTtsBaseUrl: '',
    aiTtsApiKey: '',
    aiTtsModel: 'tts-1',
    aiFormat: 'mp3',
    aiInstructions: '',
    aiExtraBody: '',
    aiExtraHeaders: '',
    aiSingleVoiceId: 'alloy',
    aiNarrationVoiceId: 'onyx',
    aiDialogueVoiceId: 'nova',
    aiDialogueMaleVoiceId: 'onyx',
    aiDialogueFemaleVoiceId: 'nova'
  };
  return d;
}

/**
 * 宽松字符串读取：**允许空串**（与上面的 asString 不同）。
 * 为什么需要：AI 的 baseUrl / apiKey / 附加 JSON 都允许为空，
 * 若用 asString 会被"空串回落默认值"的逻辑覆盖成非空默认值。
 */
function asText(v: Object, fb: string): string {
  if (typeof v === 'string') {
    return v as string;
  }
  return fb;
}

function asString(v: Object, fb: string): string {
  if (typeof v === 'string') {
    const s = v as string;
    return s.trim().length > 0 ? s.trim() : fb;
  }
  return fb;
}

function asNumber(v: Object, min: number, max: number, fb: number): number {
  if (typeof v === 'number') {
    const n = v as number;
    return Number.isFinite(n) ? Math.max(min, Math.min(max, n)) : fb;
  }
  return fb;
}

function asBool(v: Object, fb: boolean): boolean {
  return typeof v === 'boolean' ? v as boolean : fb;
}

/** 任意来源的对象 → 合法 TtsPrefs（读偏好/动态回填时使用） */
function asPerson(v: Object, fb: number): number {
  if (typeof v === 'number') {
    const n = Math.floor(v as number);
    if (isLocalPersonValid(n)) {
      return n;
    }
  }
  return fb;
}

export function normalizeTtsPrefs(raw: object): TtsPrefs {
  const d = defaultTtsPrefs();
  if (raw === null || raw === undefined) {
    return d;
  }
  const o = raw as Record<string, Object>;
  let styles = d.quoteStyles;
  const rawStyles = o['quoteStyles'];
  if (Array.isArray(rawStyles)) {
    const arrSrc = rawStyles as Array<Object>;
    const arr: number[] = [];
    for (let i = 0; i < arrSrc.length; i++) {
      const v = arrSrc[i];
      if (typeof v === 'number') {
        const n = Math.floor(v as number);
        if (n >= 0 && n <= 3 && arr.indexOf(n) < 0) {
          arr.push(n);
        }
      }
    }
    if (arr.length > 0) {
      arr.sort((a: number, b: number): number => a - b);
      styles = arr;
    }
  }
  const schemeRaw = asString(o['scheme'], '');
  const engineRaw = asString(o['ttsEngine'], 'local');
  const fmtRaw = asText(o['aiFormat'], d.aiFormat).trim().toLowerCase();
  const p: TtsPrefs = {
    ttsEngine: engineRaw === 'edge' ? 'edge' : (engineRaw === 'ai' ? 'ai' : 'local'),
    localSinglePerson: asPerson(o['localSinglePerson'], d.localSinglePerson),
    localNarrationPerson: asPerson(o['localNarrationPerson'], d.localNarrationPerson),
    localDialogueMalePerson: asPerson(o['localDialogueMalePerson'], d.localDialogueMalePerson),
    localDialogueFemalePerson: asPerson(o['localDialogueFemalePerson'], d.localDialogueFemalePerson),
    localRate: asNumber(o['localRate'], RATE_MIN, RATE_MAX, d.localRate),
    scheme: schemeRaw === 'single' ? 'single' : (schemeRaw === 'multi' ? 'multi' : d.scheme),
    singleVoiceId: asString(o['singleVoiceId'], d.singleVoiceId),
    narrationVoiceId: asString(o['narrationVoiceId'], d.narrationVoiceId),
    dialogueVoiceId: asString(o['dialogueVoiceId'], d.dialogueVoiceId),
    dialogueMaleVoiceId: asString(o['dialogueMaleVoiceId'], d.dialogueMaleVoiceId),
    dialogueFemaleVoiceId: asString(o['dialogueFemaleVoiceId'], d.dialogueFemaleVoiceId),
    quoteStyles: styles,
    rate: asNumber(o['rate'], RATE_MIN, RATE_MAX, d.rate),
    pitch: asNumber(o['pitch'], PITCH_MIN, PITCH_MAX, d.pitch),
    volume: asNumber(o['volume'], VOLUME_MIN, VOLUME_MAX, d.volume),
    pauseSentenceMs: asNumber(o['pauseSentenceMs'], PAUSE_SENTENCE_MIN, PAUSE_SENTENCE_MAX, d.pauseSentenceMs),
    pauseCommaMs: asNumber(o['pauseCommaMs'], PAUSE_COMMA_MIN, PAUSE_COMMA_MAX, d.pauseCommaMs),
    autoFollow: asBool(o['autoFollow'], d.autoFollow),
    immersiveListen: asBool(o['immersiveListen'], d.immersiveListen),
    aiSpeakerRecognitionEnabled: asBool(o['aiSpeakerRecognitionEnabled'], d.aiSpeakerRecognitionEnabled),
    aiEmotionEnabled: asBool(o['aiEmotionEnabled'], d.aiEmotionEnabled),
    aiProfiles: asString(o['aiProfiles'], d.aiProfiles),
    speakFilterEnabled: asBool(o['speakFilterEnabled'], d.speakFilterEnabled),
    speakFilterText: asString(o['speakFilterText'], d.speakFilterText),
    aiBaseUrl: asString(o['aiBaseUrl'], d.aiBaseUrl),
    aiApiKey: asString(o['aiApiKey'], d.aiApiKey),
    aiModel: asString(o['aiModel'], d.aiModel),
    // ── AI 听书（宽松读取：允许空串）────────────────────────────────────────
    aiTtsEnabled: asBool(o['aiTtsEnabled'], d.aiTtsEnabled),
    aiProviderId: asString(o['aiProviderId'], d.aiProviderId),
    aiTtsBaseUrl: asText(o['aiTtsBaseUrl'], d.aiTtsBaseUrl),
    aiTtsApiKey: asText(o['aiTtsApiKey'], d.aiTtsApiKey),
    aiTtsModel: asString(o['aiTtsModel'], d.aiTtsModel),
    // 白名单：只认三种，其余回落默认（防止手改 Preferences 塞进奇怪扩展名）
    aiFormat: (fmtRaw === 'mp3' || fmtRaw === 'wav' || fmtRaw === 'pcm') ? fmtRaw : d.aiFormat,
    aiInstructions: asText(o['aiInstructions'], d.aiInstructions),
    aiExtraBody: asText(o['aiExtraBody'], d.aiExtraBody),
    aiExtraHeaders: asText(o['aiExtraHeaders'], d.aiExtraHeaders),
    aiSingleVoiceId: asString(o['aiSingleVoiceId'], d.aiSingleVoiceId),
    aiNarrationVoiceId: asString(o['aiNarrationVoiceId'], d.aiNarrationVoiceId),
    aiDialogueVoiceId: asString(o['aiDialogueVoiceId'], d.aiDialogueVoiceId),
    aiDialogueMaleVoiceId: asString(o['aiDialogueMaleVoiceId'], d.aiDialogueMaleVoiceId),
    aiDialogueFemaleVoiceId: asString(o['aiDialogueFemaleVoiceId'], d.aiDialogueFemaleVoiceId)
  };
  return p;
}

const PREFS_KEY = 'TtsPrefs';

export function loadTtsPrefs(): TtsPrefs {
  try {
    const raw = PreferencesUtil.getSync(PREFS_KEY, '') as Object;
    if (typeof raw === 'string') {
      const s = raw as string;
      if (s.length === 0) {
        return defaultTtsPrefs();
      }
      return normalizeTtsPrefs(JSON.parse(s) as object);
    }
    // 兼容直接存对象的情况
    return normalizeTtsPrefs(raw as object);
  } catch (e) {
    return defaultTtsPrefs();
  }
}

export function saveTtsPrefs(prefs: TtsPrefs): void {
  PreferencesUtil.putSync(PREFS_KEY, JSON.stringify(prefs));
}
