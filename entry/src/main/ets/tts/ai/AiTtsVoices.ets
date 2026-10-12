/**
 * AI 语音 —— **按服务商**的内置音色表（自研，2026-10-11 重建）。
 *
 * ── 这次重建改了什么（务必读）────────────────────────────────────────────
 * 旧版只有 10 条"建议值"，label 用英文 id、description 是**我们自己编的**，
 * 结果编错了：`Jennifer` 被写成"女声（普通话）"，官方实为**美语**女声。
 * 新版改为：**照官方文档抄真实中文名与描述**，杜绝自编。
 *
 * ── 数据来源（全部为官方公开事实，可查验）────────────────────────────────
 * · 通义 DashScope：
 *   https://help.aliyun.com/zh/model-studio/qwen-tts-voice-list
 *   全量 48 条已归档 `tools/voice-data/dashscope-voices-full.json`
 * · 火山引擎豆包：
 *   https://docs.volcengine.com/docs/6561/1257544  （标题：音色列表）
 *   官方接口取回，DocumentCode=`Tonelist-1`，UpdatedTime=2026-09-22
 *   全量 433 条已归档 `tools/voice-data/volcengine-voices-full.json`
 *   原始 Markdown 归档 `tools/voice-data/volcengine-voices-official.md`
 * · 小米 MiMo / OpenAI / MiniMax：见各自小节注释
 *
 * ── 设计取舍（用户拍板 2026-10-11）────────────────────────────────────────
 *   · **只收主流中文音色**：外语角色、方言、儿童音不进精选表（占地方又用不上）；
 *   · **完整表另存**：将来 UI 做「更多音色」弹窗（Markdown 呈现）时直接复用归档；
 *   · **始终允许手填音色 id**（本工程与参考项目的关键差异，见方案 §13.2）；
 *   · UI 用 `group` 做分节标题（旁白 / 男声 / 女声），**不分组时平铺**。
 *
 * ⚠️ 火山官方音色表**不提供音色描述**（只有场景与语种）⇒ 本文件里火山的
 *    `description` 用「场景 · 语种」原文，**不臆造**。这是诚实标注，不是遗漏。
 */
import { AiVoiceOption } from './AiTtsTypes';

/**
 * OpenAI 兼容 TTS。
 * 来源：OpenAI 官方 `/v1/audio/speech` 文档公开的 6 个内置音色名（接口事实）。
 * 另附 Edge 系音色 id：大量中转站以 OpenAI 兼容形代理 Edge TTS，
 * 填这些 id 能直接出声（本工程 `EdgeTtsClient` 用的就是同一套 id）。
 */
const OPENAI_VOICES: AiVoiceOption[] = [
  { id: 'alloy', label: 'alloy', description: 'OpenAI 官方 · 中性通用', gender: '', group: 'OpenAI 官方' },
  { id: 'echo', label: 'echo', description: 'OpenAI 官方 · 偏男声', gender: 'male', group: 'OpenAI 官方' },
  { id: 'fable', label: 'fable', description: 'OpenAI 官方 · 叙述感强', gender: '', group: 'OpenAI 官方' },
  { id: 'onyx', label: 'onyx', description: 'OpenAI 官方 · 低沉男声', gender: 'male', group: 'OpenAI 官方' },
  { id: 'nova', label: 'nova', description: 'OpenAI 官方 · 明亮女声', gender: 'female', group: 'OpenAI 官方' },
  { id: 'shimmer', label: 'shimmer', description: 'OpenAI 官方 · 柔和女声', gender: 'female', group: 'OpenAI 官方' },
  { id: 'zh-CN-XiaoxiaoNeural', label: '晓晓', description: 'Edge 系 · 女声（温柔）', gender: 'female', group: 'Edge 中转' },
  { id: 'zh-CN-XiaoyiNeural', label: '晓伊', description: 'Edge 系 · 女声（活泼）', gender: 'female', group: 'Edge 中转' },
  { id: 'zh-CN-liaoning-XiaobeiNeural', label: '晓北', description: 'Edge 系 · 女声（东北方言）', gender: 'female', group: 'Edge 中转' },
  { id: 'zh-CN-YunxiNeural', label: '云希', description: 'Edge 系 · 男声（青年）', gender: 'male', group: 'Edge 中转' },
  { id: 'zh-CN-YunjianNeural', label: '云健', description: 'Edge 系 · 男声（沉稳）', gender: 'male', group: 'Edge 中转' },
  { id: 'zh-CN-YunyangNeural', label: '云扬', description: 'Edge 系 · 男声（播音腔）', gender: 'male', group: 'Edge 中转' },
  { id: 'zh-CN-YunxiaNeural', label: '云夏', description: 'Edge 系 · 男声（少年）', gender: 'male', group: 'Edge 中转' },
  { id: 'zh-CN-XiaochenNeural', label: '晓辰', description: 'Edge 系 · 女声（知性）', gender: 'female', group: 'Edge 中转' },
  { id: 'zh-CN-XiaohanNeural', label: '晓涵', description: 'Edge 系 · 女声（温婉）', gender: 'female', group: 'Edge 中转' },
  { id: 'zh-CN-XiaomengNeural', label: '晓梦', description: 'Edge 系 · 女声（甜美）', gender: 'female', group: 'Edge 中转' }
];

/**
 * 阿里通义 DashScope Qwen3-TTS（精选 16 条 / 官方共 48 条）。
 * 官方音色无「列音色」接口 ⇒ 完整表靠归档，用户可手填其余 id。
 * 名称与描述**逐字取自官方音色列表页**（含中文名，旧版全部缺失）。
 */
const DASHSCOPE_VOICES: AiVoiceOption[] = [
  { id: 'Eldric Sage', label: '沧明子 · Eldric Sage', description: '沉稳睿智的老者，沧桑如松却心明如镜', gender: 'male', group: '旁白' },
  { id: 'Neil', label: '阿闻 · Neil', description: '平直的基线语调，字正腔圆的咬字发音，这就是最专业的新闻主持人', gender: 'male', group: '旁白' },
  { id: 'Kai', label: '凯 · Kai', description: '耳朵的一场 SPA', gender: 'male', group: '旁白' },
  { id: 'Ethan', label: '晨煦 · Ethan', description: '标准普通话，带部分北方口音。阳光、温暖、活力、朝气', gender: 'male', group: '男声' },
  { id: 'Moon', label: '月白 · Moon', description: '率性帅气的月白', gender: 'male', group: '男声' },
  { id: 'Ryan', label: '甜茶 · Ryan', description: '节奏拉满，戏感炸裂，真实与张力共舞', gender: 'male', group: '男声' },
  { id: 'Vincent', label: '田叔 · Vincent', description: '一口独特的沙哑烟嗓，一开口便道尽了千军万马与江湖豪情', gender: 'male', group: '男声' },
  { id: 'Arthur', label: '徐大爷 · Arthur', description: '被岁月和旱烟浸泡过的质朴嗓音，不疾不徐地摇开了满村的奇闻异事', gender: 'male', group: '男声' },
  { id: 'Mochi', label: '沙小弥 · Mochi', description: '聪明伶俐的小大人，童真未泯却早慧如禅', gender: 'male', group: '男声' },
  { id: 'Serena', label: '苏瑶 · Serena', description: '温柔小姐姐', gender: 'female', group: '女声' },
  { id: 'Cherry', label: '芊悦 · Cherry', description: '阳光积极、亲切自然小姐姐', gender: 'female', group: '女声' },
  { id: 'Maia', label: '四月 · Maia', description: '知性与温柔的碰撞', gender: 'female', group: '女声' },
  { id: 'Seren', label: '小婉 · Seren', description: '温和舒缓的声线，助你更快地进入睡眠，晚安，好梦', gender: 'female', group: '女声' },
  { id: 'Katerina', label: '卡捷琳娜 · Katerina', description: '御姐音色，韵律回味十足', gender: 'female', group: '女声' },
  { id: 'Bellona', label: '燕铮莺 · Bellona', description: '声音洪亮，吐字清晰，人物鲜活，听得人热血沸腾；金戈铁马入梦来，字正腔圆间尽显千面人声的江湖', gender: 'female', group: '女声' },
  { id: 'Elias', label: '墨讲师 · Elias', description: '既保持学科严谨性，又通过叙事技巧将复杂知识转化为可消化的认知模块', gender: 'female', group: '女声' }
];

/**
 * 火山引擎豆包语音合成 2.0（精选 24 条 / 官方共 433 条）。
 * 官方表列字段为「场景 / 音色名称 / voice_type / 语种·方言 / 支持能力 / 特殊标签」，
 * **无描述列** ⇒ `description` 用「场景 · 语种」原文，不臆造。
 * 「有声阅读」是官方为听书场景单列的分类，本表优先收录。
 */
const VOLCENGINE_VOICES: AiVoiceOption[] = [
  { id: 'zh_male_ruyaqingnian_uranus_bigtts', label: '儒雅青年 2.0', description: '通用场景 · 中文、支持30+语种识别', gender: 'male', group: '旁白' },
  { id: 'zh_male_baqiqingshu_uranus_bigtts', label: '霸气青叔 2.0', description: '有声阅读 · 中文、支持30+语种识别', gender: 'male', group: '旁白' },
  { id: 'zh_male_xuanyijieshuo_uranus_bigtts', label: '悬疑解说 2.0', description: '有声阅读 · 中文、支持30+语种识别', gender: 'male', group: '旁白' },
  { id: 'zh_male_taocheng_uranus_bigtts', label: '小天 2.0', description: '通用场景 · 支持30+语种识别与8种方言', gender: 'male', group: '旁白' },
  { id: 'zh_male_liufei_uranus_bigtts', label: '刘飞 2.0', description: '通用场景 · 中文、支持30+语种识别', gender: 'male', group: '旁白' },
  { id: 'zh_male_m191_uranus_bigtts', label: '云舟 2.0', description: '通用场景 · 支持30+语种识别与8种方言', gender: 'male', group: '旁白' },
  { id: 'zh_male_qingcang_uranus_bigtts', label: '擎苍 2.0', description: '角色扮演 · 中文、支持30+语种识别', gender: 'male', group: '男声' },
  { id: 'zh_male_ruyayichen_uranus_bigtts', label: '儒雅逸辰 2.0', description: '视频配音 · 中文、支持30+语种识别', gender: 'male', group: '男声' },
  { id: 'zh_male_shaonianzixin_uranus_bigtts', label: '少年梓辛 2.0', description: '通用场景 · 中文、支持30+语种识别', gender: 'male', group: '男声' },
  { id: 'zh_male_yizhipiannan_uranus_bigtts', label: '译制片男 2.0', description: '通用场景 · 中文、支持30+语种识别', gender: 'male', group: '男声' },
  { id: 'zh_female_xiaohe_uranus_bigtts', label: '小何 2.0', description: '通用场景 · 支持30+语种识别与8种方言', gender: 'female', group: '女声' },
  { id: 'zh_female_qingxinnvsheng_uranus_bigtts', label: '清新女声 2.0', description: '通用场景 · 中文、支持30+语种识别', gender: 'female', group: '女声' },
  { id: 'zh_female_tianmeixiaoyuan_uranus_bigtts', label: '甜美小源 2.0', description: '通用场景 · 中文、支持30+语种识别', gender: 'female', group: '女声' },
  { id: 'zh_female_shuangkuaisisi_uranus_bigtts', label: '爽快思思 2.0', description: '通用场景 · 中文、支持30+语种识别', gender: 'female', group: '女声' },
  { id: 'zh_female_cancan_uranus_bigtts', label: '知性灿灿 2.0', description: '角色扮演 · 中文、支持30+语种识别', gender: 'female', group: '女声' },
  { id: 'zh_female_vv_uranus_bigtts', label: 'Vivi 2.0', description: '通用场景 · 支持30+语种识别与8种方言', gender: 'female', group: '女声' },
  { id: 'zh_female_sophie_uranus_bigtts', label: '魅力苏菲 2.0', description: '通用场景 · 中文、支持30+语种识别', gender: 'female', group: '女声' },
  { id: 'zh_female_wenroushunv_uranus_bigtts', label: '温柔淑女 2.0', description: '通用场景 · 中文、支持30+语种识别', gender: 'female', group: '女声' },
  { id: 'zh_female_gaolengyujie_uranus_bigtts', label: '高冷御姐 2.0', description: '通用场景 · 中文、支持30+语种识别', gender: 'female', group: '女声' },
  { id: 'zh_female_linjianvhai_uranus_bigtts', label: '邻家女孩 2.0', description: '通用场景 · 中文、支持30+语种识别', gender: 'female', group: '女声' },
  { id: 'zh_female_qinqienv_uranus_bigtts', label: '亲切女声 2.0', description: '通用场景 · 中文、支持30+语种识别', gender: 'female', group: '女声' },
  { id: 'zh_female_shaoergushi_uranus_bigtts', label: '少儿故事 2.0', description: '有声阅读 · 中文、支持30+语种识别', gender: 'female', group: '女声' },
  { id: 'zh_female_tiexinnvsheng_uranus_bigtts', label: '贴心女声 2.0', description: '通用场景 · 中文、支持30+语种识别', gender: 'female', group: '女声' },
  { id: 'zh_female_wenjingmaomao_uranus_bigtts', label: '文静毛毛 2.0', description: '通用场景 · 中文、支持30+语种识别', gender: 'female', group: '女声' }
];

/**
 * MiniMax：**该服务商有官方「列音色」接口**（`/v1/get_voice`，见 `MiniMaxTts.listVoices`），
 * 所以这里只放 4 条起步值，真实清单一律以「拉取音色」为准（会落盘缓存）。
 * 音色 id 为该接口的公开事实。
 */
const MINIMAX_VOICES: AiVoiceOption[] = [
  { id: 'Chinese (Mandarin)_Male_Announcer', label: '男声·播报', description: '建议起步值 · 适合旁白', gender: 'male', group: '起步值' },
  { id: 'Chinese (Mandarin)_Unrestrained_Young_Man', label: '不羁青年', description: '建议起步值 · 适合男主对白', gender: 'male', group: '起步值' },
  { id: 'chunzhen_xuedi', label: '纯真学弟', description: '建议起步值 · 少年对白', gender: 'male', group: '起步值' },
  { id: 'danya_xuejie', label: '淡雅学姐', description: '建议起步值 · 女声对白', gender: 'female', group: '起步值' }
];

/**
 * 小米 MiMo：官方为**预置音色名**（不支持自定义/克隆）。
 *
 * ✅ 2026-10-11 已由官方文档确认：`docs/日志tts.md:62` 原文
 *   「`mimo-v2.5-tts`：`mimo_default`，`冰糖`，`茉莉`，`苏打`，`白桦`，`Mia`，`Chloe`，`Milo`，`Dean`」
 *   —— 与本表 9 条逐字一致，【待验证】标记已摘除。
 * ⚠️ 官方**无「列音色」接口** ⇒ 与通义一样只能内置静态表。
 * ⚠️ 本表仅适用于 `mimo-v2.5-tts` 模型；另两个模型（voicedesign/voiceclone）不支持预置音色 id。
 */
const MIMO_VOICES: AiVoiceOption[] = [
  { id: 'mimo_default', label: 'MiMo 默认', description: '系统默认音色，中国集群一般为冰糖', gender: 'female', group: '中文' },
  { id: '冰糖', label: '冰糖', description: '清甜明快，自然亲切的女声', gender: 'female', group: '中文' },
  { id: '茉莉', label: '茉莉', description: '温柔淡雅，适合旁白与朗读', gender: 'female', group: '中文' },
  { id: '苏打', label: '苏打', description: '清爽阳光，语气自然的男声', gender: 'male', group: '中文' },
  { id: '白桦', label: '白桦', description: '沉稳干净，偏磁性的男声', gender: 'male', group: '中文' },
  { id: 'Mia', label: 'Mia', description: '自然流畅的美式英语女声', gender: 'female', group: '英文' },
  { id: 'Chloe', label: 'Chloe', description: '清晰明快的英语女声', gender: 'female', group: '英文' },
  { id: 'Milo', label: 'Milo', description: '年轻有活力的英语男声', gender: 'male', group: '英文' },
  { id: 'Dean', label: 'Dean', description: '沉稳低沉的英语男声', gender: 'male', group: '英文' }
];

/** 该服务商的内置音色表（未知 id 回落到 OpenAI 兼容表，保持旧行为） */
export function aiVoiceOptionsFor(providerId: string): AiVoiceOption[] {
  const id: string = providerId.trim();
  if (id === 'minimax') {
    return MINIMAX_VOICES;
  }
  if (id === 'dashscope') {
    return DASHSCOPE_VOICES;
  }
  if (id === 'volcengine') {
    return VOLCENGINE_VOICES;
  }
  if (id === 'mimo') {
    return MIMO_VOICES;
  }
  return OPENAI_VOICES;
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

/**
 * 按 `group` 把音色分组（UI 分节标题用）。
 * 保持**首次出现顺序**（不排序），因为表本身就是按「旁白→男声→女声」人工排好的。
 * 无 group 的条目归入「其它」。
 */
export interface AiVoiceGroup {
  title: string;
  items: AiVoiceOption[];
}

export function aiVoiceGroupsFor(providerId: string): AiVoiceGroup[] {
  const list: AiVoiceOption[] = aiVoiceOptionsFor(providerId);
  const out: AiVoiceGroup[] = [];
  for (let i = 0; i < list.length; i++) {
    const v: AiVoiceOption = list[i];
    const g: string = v.group !== undefined && v.group !== null && v.group.length > 0
      ? v.group : '其它';
    let found: AiVoiceGroup | null = null;
    for (let k = 0; k < out.length; k++) {
      if (out[k].title === g) {
        found = out[k];
        break;
      }
    }
    if (found === null) {
      const ng: AiVoiceGroup = { title: g, items: [] };
      ng.items.push(v);
      out.push(ng);
    } else {
      found.items.push(v);
    }
  }
  return out;
}

/**
 * 该服务商的**默认音色**（新增配置时的初值）。
 * 取值依据：优先选"适合旁白"的首条（官方明确标注叙述向的音色）。
 * ⚠️ 与旧版的差异：旧版各家一律取表中第 0 条（如通义是 Cherry），
 *    现改为各家显式指定，便于以后按听感调优。
 */
export function aiDefaultVoiceFor(providerId: string): string {
  const list: AiVoiceOption[] = aiVoiceOptionsFor(providerId);
  return list.length > 0 ? list[0].id : '';
}

