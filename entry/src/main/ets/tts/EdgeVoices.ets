/**
 * Edge-TTS 音色表（与 PC 版 ColorTxt voiceReadEdgeTtsVoices.ts 同步，43 个启用音色）。
 * lang 供 SSML xml:lang 使用；label 供选择器展示；gender 供多角色推荐。
 */

export type EdgeVoiceGender = 'female' | 'male';

export interface EdgeVoice {
  id: string;
  lang: string;
  gender: EdgeVoiceGender;
  name: string;
  label: string;
  description: string;
}

export const EDGE_VOICES: EdgeVoice[] = [
  { id: 'zh-CN-XiaoxiaoNeural', lang: 'zh-CN', gender: 'female', name: 'Xiaoxiao', label: '晓晓 (Xiaoxiao)', description: '温暖 · 新闻、小说' },
  { id: 'zh-CN-XiaoyiNeural', lang: 'zh-CN', gender: 'female', name: 'Xiaoyi', label: '晓伊 (Xiaoyi)', description: '活泼 · 卡通、小说' },
  { id: 'zh-CN-YunjianNeural', lang: 'zh-CN', gender: 'male', name: 'Yunjian', label: '云健 (Yunjian)', description: '激情 · 体育、小说' },
  { id: 'zh-CN-YunxiaNeural', lang: 'zh-CN', gender: 'male', name: 'Yunxia', label: '云夏 (Yunxia)', description: '可爱 · 卡通、小说' },
  { id: 'zh-CN-YunxiNeural', lang: 'zh-CN', gender: 'male', name: 'Yunxi', label: '云希 (Yunxi)', description: '活泼、阳光 · 小说' },
  { id: 'zh-CN-YunyangNeural', lang: 'zh-CN', gender: 'male', name: 'Yunyang', label: '云扬 (Yunyang)', description: '专业、可靠 · 新闻' },
  { id: 'zh-CN-liaoning-XiaobeiNeural', lang: 'zh-CN-liaoning', gender: 'female', name: 'Xiaobei', label: '晓北 (Xiaobei)', description: '幽默 · 方言' },
  { id: 'zh-CN-shaanxi-XiaoniNeural', lang: 'zh-CN-shaanxi', gender: 'female', name: 'Xiaoni', label: '晓妮 (Xiaoni)', description: '明亮 · 方言' },
  { id: 'zh-HK-HiuGaaiNeural', lang: 'zh-HK', gender: 'female', name: 'HiuGaai', label: '晓佳 (HiuGaai)', description: '友善、积极 · 通用' },
  { id: 'zh-HK-HiuMaanNeural', lang: 'zh-HK', gender: 'female', name: 'HiuMaan', label: '晓曼 (HiuMaan)', description: '友善、积极 · 通用' },
  { id: 'zh-HK-WanLungNeural', lang: 'zh-HK', gender: 'male', name: 'WanLung', label: '云龙 (WanLung)', description: '友善、积极 · 通用' },
  { id: 'zh-TW-HsiaoChenNeural', lang: 'zh-TW', gender: 'female', name: 'HsiaoChen', label: '晓臻 (HsiaoChen)', description: '友善、积极 · 通用' },
  { id: 'zh-TW-HsiaoYuNeural', lang: 'zh-TW', gender: 'female', name: 'HsiaoYu', label: '晓雨 (HsiaoYu)', description: '友善、积极 · 通用' },
  { id: 'zh-TW-YunJheNeural', lang: 'zh-TW', gender: 'male', name: 'YunJhe', label: '云哲 (YunJhe)', description: '友善、积极 · 通用' },
  { id: 'en-US-AnaNeural', lang: 'en-US', gender: 'female', name: 'Ana', label: 'Ana', description: 'Cute · Cartoon, Conversation' },
  { id: 'en-US-AriaNeural', lang: 'en-US', gender: 'female', name: 'Aria', label: 'Aria', description: 'Positive, Confident · News, Novel' },
  { id: 'en-US-AvaNeural', lang: 'en-US', gender: 'female', name: 'Ava', label: 'Ava', description: 'Expressive, Caring · Conversation' },
  { id: 'en-US-AvaMultilingualNeural', lang: 'en-US', gender: 'female', name: 'AvaMultilingual', label: 'Ava Multilingual', description: 'Expressive, Caring · Multilingual' },
  { id: 'en-US-EmmaNeural', lang: 'en-US', gender: 'female', name: 'Emma', label: 'Emma', description: 'Cheerful, Clear · Conversation' },
  { id: 'en-US-EmmaMultilingualNeural', lang: 'en-US', gender: 'female', name: 'EmmaMultilingual', label: 'Emma Multilingual', description: 'Cheerful, Clear · Multilingual' },
  { id: 'en-US-JennyNeural', lang: 'en-US', gender: 'female', name: 'Jenny', label: 'Jenny', description: 'Friendly, Considerate · General' },
  { id: 'en-US-MichelleNeural', lang: 'en-US', gender: 'female', name: 'Michelle', label: 'Michelle', description: 'Friendly, Pleasant · News, Novel' },
  { id: 'en-US-AndrewNeural', lang: 'en-US', gender: 'male', name: 'Andrew', label: 'Andrew', description: 'Warm, Confident · Conversation' },
  { id: 'en-US-AndrewMultilingualNeural', lang: 'en-US', gender: 'male', name: 'AndrewMultilingual', label: 'Andrew Multilingual', description: 'Warm, Confident · Multilingual' },
  { id: 'en-US-BrianNeural', lang: 'en-US', gender: 'male', name: 'Brian', label: 'Brian', description: 'Approachable, Casual · Conversation' },
  { id: 'en-US-BrianMultilingualNeural', lang: 'en-US', gender: 'male', name: 'BrianMultilingual', label: 'Brian Multilingual', description: 'Approachable, Casual · Multilingual' },
  { id: 'en-US-ChristopherNeural', lang: 'en-US', gender: 'male', name: 'Christopher', label: 'Christopher', description: 'Reliable, Authority · News, Novel' },
  { id: 'en-US-EricNeural', lang: 'en-US', gender: 'male', name: 'Eric', label: 'Eric', description: 'Rational · News, Novel' },
  { id: 'en-US-GuyNeural', lang: 'en-US', gender: 'male', name: 'Guy', label: 'Guy', description: 'Passion · News, Novel' },
  { id: 'en-US-RogerNeural', lang: 'en-US', gender: 'male', name: 'Roger', label: 'Roger', description: 'Lively · News, Novel' },
  { id: 'en-US-SteffanNeural', lang: 'en-US', gender: 'male', name: 'Steffan', label: 'Steffan', description: 'Rational · News, Novel' },
  { id: 'en-GB-LibbyNeural', lang: 'en-GB', gender: 'female', name: 'Libby', label: 'Libby', description: 'Friendly, Positive · General' },
  { id: 'en-GB-MaisieNeural', lang: 'en-GB', gender: 'female', name: 'Maisie', label: 'Maisie', description: 'Friendly, Positive · General' },
  { id: 'en-GB-SoniaNeural', lang: 'en-GB', gender: 'female', name: 'Sonia', label: 'Sonia', description: 'Friendly, Positive · General' },
  { id: 'en-GB-RyanNeural', lang: 'en-GB', gender: 'male', name: 'Ryan', label: 'Ryan', description: 'Friendly, Positive · General' },
  { id: 'en-GB-ThomasNeural', lang: 'en-GB', gender: 'male', name: 'Thomas', label: 'Thomas', description: 'Friendly, Positive · General' },
  { id: 'en-HK-SamNeural', lang: 'en-HK', gender: 'male', name: 'Sam', label: 'Sam', description: 'Friendly, Positive · General' },
  { id: 'en-HK-YanNeural', lang: 'en-HK', gender: 'female', name: 'Yan', label: 'Yan', description: 'Friendly, Positive · General' },
  { id: 'ja-JP-NanamiNeural', lang: 'ja-JP', gender: 'female', name: 'Nanami', label: 'Nanami', description: 'Friendly, Positive · General' },
  { id: 'ja-JP-KeitaNeural', lang: 'ja-JP', gender: 'male', name: 'Keita', label: 'Keita', description: 'Friendly, Positive · General' },
  { id: 'ko-KR-SunHiNeural', lang: 'ko-KR', gender: 'female', name: 'SunHi', label: 'SunHi', description: 'Friendly, Positive · General' },
  { id: 'ko-KR-InJoonNeural', lang: 'ko-KR', gender: 'male', name: 'InJoon', label: 'InJoon', description: 'Friendly, Positive · General' },
  { id: 'ko-KR-HyunsuMultilingualNeural', lang: 'ko-KR', gender: 'male', name: 'HyunsuMultilingual', label: 'Hyunsu Multilingual', description: 'Friendly, Positive · Multilingual' }
];

/** 与 PC 版 voiceReadEngineDefaults.ts 的 edge 默认值一致 */
export const EDGE_DEFAULT_NARRATION_VOICE = 'zh-CN-YunjianNeural';
export const EDGE_DEFAULT_DIALOGUE_VOICE = 'zh-CN-YunxiNeural';
export const EDGE_DEFAULT_DIALOGUE_MALE_VOICE = 'zh-CN-YunxiNeural';
export const EDGE_DEFAULT_DIALOGUE_FEMALE_VOICE = 'zh-CN-XiaoxiaoNeural';
export const EDGE_DEFAULT_SINGLE_VOICE = 'zh-CN-YunjianNeural';

export function findEdgeVoice(voiceId: string): EdgeVoice | null {
  for (let i = 0; i < EDGE_VOICES.length; i++) {
    if (EDGE_VOICES[i].id === voiceId) {
      return EDGE_VOICES[i];
    }
  }
  return null;
}

/** 由 voiceId 推断 SSML 语言（zh-CN-liaoning-XiaobeiNeural → zh-CN-liaoning） */
export function langOfVoice(voiceId: string): string {
  const v = findEdgeVoice(voiceId);
  if (v !== null) {
    return v.lang;
  }
  const parts = voiceId.split('-');
  if (parts.length >= 3 && parts[0] === 'zh') {
    return parts[0] + '-' + parts[1] + '-' + parts[2];
  }
  if (parts.length >= 2) {
    return parts[0] + '-' + parts[1];
  }
  return 'zh-CN';
}

/** 音色展示文案（列表里没有的自定义 id 也能显示） */
export function voiceLabel(voiceId: string): string {
  const v = findEdgeVoice(voiceId);
  return v !== null ? v.label : voiceId;
}
