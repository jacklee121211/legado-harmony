/**
 * 本地 TTS（Core Speech Kit textToSpeech）音色表 —— 与 EdgeVoices 平行的本地侧定义。
 *
 * 官方证据（SDK `@hms.ai.textToSpeech.d.ts`，`CreateEngineParams.person` 注释原文）：
 *  「For Chinese, **13** indicates Ling Xiaoshan female voice (**13** is recommended and
 *    **0** can also be used) and **21** indicates Ling Feizhe male voice (download required).
 *    For English, **8** indicates Laura female voice for English (US) (download required).」
 * 音色是**引擎级**参数（创建引擎时指定 person），本地多音色 = 多引擎实例
 * （全设备上限 3 个 ⇒ LocalTtsClient 池上限 2，够覆盖 男/女 两路）。
 * 需下载音色：`VoiceInfo.status`（@since 5.1.1(19)）'GA'=可下载 / 'INSTALLED'=已下载 /
 * 'EOM'=不可用（FAQ core-speech-7：GA 未下载时 speak 失败）。
 */
export interface LocalVoice {
  person: number;
  label: string;
  description: string;
  lang: string;
  gender: string;
  needsDownload: boolean;
}

export const LOCAL_VOICES: LocalVoice[] = [
  {
    person: 13, label: '聆小珊', description: '女声 · 简体中文（内置）', lang: 'zh-CN',
    gender: '女', needsDownload: false
  },
  {
    person: 21, label: '凌飞哲', description: '男声 · 简体中文（首次需下载音色模型）', lang: 'zh-CN',
    gender: '男', needsDownload: true
  },
  {
    person: 8, label: '劳拉', description: '女声 · 英语美国（首次需下载音色模型）', lang: 'en-US',
    gender: '女', needsDownload: true
  }
];

export const LOCAL_DEFAULT_SINGLE_PERSON: number = 13;
export const LOCAL_DEFAULT_NARRATION_PERSON: number = 13;
export const LOCAL_DEFAULT_DIALOGUE_MALE_PERSON: number = 21;
export const LOCAL_DEFAULT_DIALOGUE_FEMALE_PERSON: number = 13;

export function isLocalPersonValid(person: number): boolean {
  for (let i = 0; i < LOCAL_VOICES.length; i++) {
    if (LOCAL_VOICES[i].person === person) {
      return true;
    }
  }
  return false;
}

export function localVoiceLabel(person: number): string {
  for (let i = 0; i < LOCAL_VOICES.length; i++) {
    if (LOCAL_VOICES[i].person === person) {
      return LOCAL_VOICES[i].label;
    }
  }
  return '聆小珊';
}
