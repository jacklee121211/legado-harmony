/**
 * 朗读全部可调参数（与 PC 版 ColorTxt voiceReadProfiles 参数面对齐）+ clamp + 持久化。
 * scheme: single 单音色 / multi 多角色（旁白/对白分音色）
 * quoteStyles: 启用的对白引号风格下标（0="" 1='' 2=「」 3=『』）
 */
import { PreferencesUtil } from '@pura/harmony-utils';
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
 * TTS 引擎选择（2026-09-25 双引擎架构）：
 *  · 'local'（默认）：系统本地引擎（Core Speech Kit textToSpeech），端侧合成、无网可用、
 *    上架合规；单音色（聆小珊），无词级时间戳（停顿拼接/句级高亮精度降级）；
 *  · 'edge'：Edge TTS（云端合成、音色丰富、词级时间戳）——**暗门解锁后**才允许选择
 *    （TtsEngine.activeEngineId() 二次校验：未解锁一律回落 'local'）。
 */
export type TtsEngineKind = 'local' | 'edge';

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
  aiBaseUrl: string;       // OpenAI 兼容接口，如 https://api.deepseek.com/v1
  aiApiKey: string;
  aiModel: string;         // 如 deepseek-chat
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
    aiBaseUrl: '',
    aiApiKey: '',
    aiModel: ''
  };
  return d;
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
  const p: TtsPrefs = {
    ttsEngine: engineRaw === 'edge' ? 'edge' : 'local',
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
    aiBaseUrl: asString(o['aiBaseUrl'], d.aiBaseUrl),
    aiApiKey: asString(o['aiApiKey'], d.aiApiKey),
    aiModel: asString(o['aiModel'], d.aiModel)
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
