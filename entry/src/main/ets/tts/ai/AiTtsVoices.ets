/**
 * AI 语音 —— **按服务商**的内置建议音色（自研）。
 *
 * 定位（务必理解，否则会误以为是"权威清单"）：
 *   · 这里只是**建议值**，目的是"用户第一次就能出声"；
 *   · **服务商真实音色清单**应通过「拉取音色」获得（见 `AiVoiceCatalog.ets`）；
 *   · 因此本工程**始终允许手填音色 id**（与参考项目"不允许手填"不同，方案 §13.2）。
 *
 * 来源说明（合规，见方案 §14.3）：
 *   · 各条目的 **id 是厂商公开的接口事实**（不受版权保护）；
 *   · **label / description 均为本项目自写**（不复制参考项目的音色汇编表与描述文案）；
 *   · 每家只列 3~6 条**常用**值，不搬参考项目的 444/48/43 行整表。
 */
import { AiVoiceOption } from './AiTtsTypes';

/** OpenAI 兼容（官方 + 多数镜像 Edge 的中转） */
const OPENAI_SUGGESTED: AiVoiceOption[] = [
  { id: 'alloy', label: 'alloy', description: 'OpenAI 系 · 中性通用', gender: '' },
  { id: 'echo', label: 'echo', description: 'OpenAI 系 · 偏男声', gender: '' },
  { id: 'fable', label: 'fable', description: 'OpenAI 系 · 叙述感强', gender: '' },
  { id: 'onyx', label: 'onyx', description: 'OpenAI 系 · 低沉男声', gender: '' },
  { id: 'nova', label: 'nova', description: 'OpenAI 系 · 明亮女声', gender: '' },
  { id: 'shimmer', label: 'shimmer', description: 'OpenAI 系 · 柔和女声', gender: '' },
  { id: 'zh-CN-XiaoxiaoNeural', label: '晓晓', description: 'Edge 系 · 女声（温柔）', gender: 'female' },
  { id: 'zh-CN-XiaoyiNeural', label: '晓伊', description: 'Edge 系 · 女声（活泼）', gender: 'female' },
  { id: 'zh-CN-YunxiNeural', label: '云希', description: 'Edge 系 · 男声（青年）', gender: 'male' },
  { id: 'zh-CN-YunjianNeural', label: '云健', description: 'Edge 系 · 男声（沉稳）', gender: 'male' },
  { id: 'zh-CN-YunyangNeural', label: '云扬', description: 'Edge 系 · 男声（播音腔）', gender: 'male' },
  { id: 'zh-CN-liaoning-XiaobeiNeural', label: '晓北', description: 'Edge 系 · 女声（东北方言）', gender: 'female' }
];

/**
 * MiniMax：只给 4 条最常用的作为"起步值"。
 * ✅ 该服务商**支持拉取完整音色清单** ⇒ 点「拉取音色」才是正道。
 */
const MINIMAX_SUGGESTED: AiVoiceOption[] = [
  { id: 'Chinese (Mandarin)_Male_Announcer', label: '男声·播报', description: '建议值 · 适合旁白', gender: 'male' },
  { id: 'Chinese (Mandarin)_Unrestrained_Young_Man', label: '不羁青年', description: '建议值 · 适合男主对白', gender: 'male' },
  { id: 'chunzhen_xuedi', label: '纯真学弟', description: '建议值 · 少年对白', gender: 'male' },
  { id: 'danya_xuejie', label: '淡雅学姐', description: '建议值 · 女声对白', gender: 'female' }
];

/**
 * 阿里通义 Qwen3-TTS：10 条常用音色。
 * ⚠️ label 用**厂商的 id 原文**（id 是公开接口事实）；description 是本项目自写。
 * 该服务商无「列音色」接口 ⇒ 这是"能看得见"的全部，其余请手填。
 */
const DASHSCOPE_SUGGESTED: AiVoiceOption[] = [
  { id: 'Cherry', label: 'Cherry', description: '通义 · 女声（普通话）', gender: 'female' },
  { id: 'Serena', label: 'Serena', description: '通义 · 女声（普通话，温柔）', gender: 'female' },
  { id: 'Jennifer', label: 'Jennifer', description: '通义 · 女声（普通话）', gender: 'female' },
  { id: 'Maia', label: 'Maia', description: '通义 · 女声（普通话，知性）', gender: 'female' },
  { id: 'Chelsie', label: 'Chelsie', description: '通义 · 女声（普通话）', gender: 'female' },
  { id: 'Ethan', label: 'Ethan', description: '通义 · 男声（普通话）', gender: 'male' },
  { id: 'Ryan', label: 'Ryan', description: '通义 · 男声（普通话）', gender: 'male' },
  { id: 'Moon', label: 'Moon', description: '通义 · 男声（普通话，帅气）', gender: 'male' },
  { id: 'Kai', label: 'Kai', description: '通义 · 男声（普通话，适合旁白）', gender: 'male' },
  { id: 'Eldric Sage', label: 'Eldric Sage', description: '通义 · 男声（普通话，叙述感强）', gender: 'male' }
];

/**
 * 火山豆包 2.0：10 条常用中文音色（男 5 / 女 5）。
 * label 取 id 中段的拼音（**不臆造中文名** —— 官方中文名我没法核实，见 §0 取证纪律）。
 * 该服务商无「列音色」接口；官方文档共 293+151 条，需要其它音色请手填 id。
 */
const VOLCENGINE_SUGGESTED: AiVoiceOption[] = [
  { id: 'zh_male_taocheng_uranus_bigtts', label: 'taocheng', description: '火山 · 男声（普通话）', gender: 'male' },
  { id: 'zh_male_liufei_uranus_bigtts', label: 'liufei', description: '火山 · 男声（普通话）', gender: 'male' },
  { id: 'zh_male_ruyayichen_uranus_bigtts', label: 'ruyayichen', description: '火山 · 男声（儒雅，适合旁白）', gender: 'male' },
  { id: 'zh_male_shaonianzixin_uranus_bigtts', label: 'shaonianzixin', description: '火山 · 男声（少年，适合对白）', gender: 'male' },
  { id: 'zh_male_yizhipiannan_uranus_bigtts', label: 'yizhipiannan', description: '火山 · 男声（普通话）', gender: 'male' },
  { id: 'zh_female_xiaohe_uranus_bigtts', label: 'xiaohe', description: '火山 · 女声（普通话）', gender: 'female' },
  { id: 'zh_female_qingxinnvsheng_uranus_bigtts', label: 'qingxinnvsheng', description: '火山 · 女声（清新）', gender: 'female' },
  { id: 'zh_female_tianmeixiaoyuan_uranus_bigtts', label: 'tianmeixiaoyuan', description: '火山 · 女声（甜美）', gender: 'female' },
  { id: 'zh_female_shuangkuaisisi_uranus_bigtts', label: 'shuangkuaisisi', description: '火山 · 女声（爽快）', gender: 'female' },
  { id: 'zh_female_cancan_uranus_bigtts', label: 'cancan', description: '火山 · 女声（普通话）', gender: 'female' }
];

/**
 * 小米 MiMo：9 条（该厂商全部预置音色名 —— 名字本身就是厂商公开的音色标识）。
 * label 用厂商音色名；description 本项目自写。
 */
const MIMO_SUGGESTED: AiVoiceOption[] = [
  { id: 'mimo_default', label: 'MiMo 默认', description: 'MiMo · 系统默认（中国集群通常为冰糖）', gender: '' },
  { id: '冰糖', label: '冰糖', description: 'MiMo · 清甜女声', gender: 'female' },
  { id: '茉莉', label: '茉莉', description: 'MiMo · 温柔女声（适合旁白）', gender: 'female' },
  { id: '苏打', label: '苏打', description: 'MiMo · 阳光男声', gender: 'male' },
  { id: '白桦', label: '白桦', description: 'MiMo · 磁性男声', gender: 'male' },
  { id: 'Mia', label: 'Mia', description: 'MiMo · 美式英语女声', gender: 'female' },
  { id: 'Chloe', label: 'Chloe', description: 'MiMo · 英语女声', gender: 'female' },
  { id: 'Milo', label: 'Milo', description: 'MiMo · 英语男声（年轻）', gender: 'male' },
  { id: 'Dean', label: 'Dean', description: 'MiMo · 英语男声（低沉）', gender: 'male' }
];

export function aiVoiceOptionsFor(providerId: string): AiVoiceOption[] {
  const id: string = providerId.trim();
  if (id === 'minimax') {
    return MINIMAX_SUGGESTED;
  }
  if (id === 'dashscope') {
    return DASHSCOPE_SUGGESTED;
  }
  if (id === 'volcengine') {
    return VOLCENGINE_SUGGESTED;
  }
  if (id === 'mimo') {
    return MIMO_SUGGESTED;
  }
  return OPENAI_SUGGESTED;
}

/** 音色展示文案（列表里没有的自定义 id 也原样显示） */
export function aiVoiceLabel(providerId: string, voiceId: string): string {
  const id: string = voiceId.trim();
  if (id.length === 0) {
    return '未选择';
  }
  const list: AiVoiceOption[] = aiVoiceOptionsFor(providerId);
  for (let i = 0; i < list.length; i++) {
    if (list[i].id === id) {
      return list[i].label + ' · ' + list[i].description;
    }
  }
  return id;
}
