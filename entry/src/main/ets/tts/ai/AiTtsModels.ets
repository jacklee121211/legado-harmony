/**
 * AI 语音 —— **按服务商**的 TTS 模型表（自研，2026-10-11 新增）。
 *
 * 与 `AiTtsVoices.ets` 同构：内置定死、不联网、允许手填。
 * 用途：UI 用「模型」下拉（可选 + 可自行输入）替代裸 TextInput。
 *
 * ── 为什么必须同时掌握「模型」和「音色」两张表 ─────────────────────────────
 * 二者**强绑定**，不能独立选择。官方原文（阿里云百炼，来源
 * https://help.aliyun.com/zh/model-studio/qwen-audio-tts-voice-list ）：
 *   「所选音色（voice）必须属于当前模型（model）支持的音色列表，**不能跨模型混用**。
 *     音色不匹配时，服务会返回 InvalidParameter 错误」
 * ⇒ UI 切模型时必须联动校验/重置音色，否则必然触发 InvalidParameter。
 *
 * ── 数据来源（全部官方公开事实）────────────────────────────────────────────
 * · 通义  ：https://help.aliyun.com/zh/model-studio/tts-model （官方「模型列表」）
 *           全量 14 条已归档 `tools/voice-data/dashscope-models.json`
 * · 火山  ：https://docs.volcengine.com/docs/6561/1257544
 *           官方用 **`X-Api-Resource-Id` 请求头**传模型（不是 body 的 model 字段）
 * · MiniMax：阿里云百炼托管页列出 4 条；其余来自参考项目清单（官方站为 SPA）【待验证】
 * · MiMo  ：参考项目清单（官方站为 SPA）【待验证】
 * · OpenAI：官方 `/v1/audio/speech` 文档
 */
import { AiModelOption } from './AiTtsTypes';

/**
 * 阿里通义 DashScope。
 * ⚠️ 官方现行模型名里**没有** `qwen3-tts-instruct-flash`（那是旧名，见
 *    `DashscopeTts.ets` 里 modelHint 的修正注释）。支持「指令控制」的是
 *    Qwen-Audio-TTS 与部分 CosyVoice 系列。
 */
const DASHSCOPE_MODELS: AiModelOption[] = [
  {
    id: 'qwen3-tts-flash', label: 'Qwen3-TTS Flash', group: '推荐',
    description: 'HTTP · 48 条内置音色 · 不支持指令控制',
    supportsInstructions: false
  },
  {
    id: 'qwen3-tts-flash-realtime', label: 'Qwen3-TTS Flash Realtime', group: '其它',
    description: 'WebSocket 实时（本工程走 HTTP，暂不可用）',
    supportsInstructions: false
  },
  {
    id: 'qwen-audio-3.0-tts-plus', label: 'Qwen-Audio-TTS 3.0 Plus', group: '推荐',
    description: 'WebSocket/HTTP · 支持声音复刻/设计/指令控制',
    supportsInstructions: true
  },
  {
    id: 'qwen-audio-3.0-tts-flash', label: 'Qwen-Audio-TTS 3.0 Flash', group: '推荐',
    description: 'WebSocket/HTTP · 支持声音复刻/设计/指令控制',
    supportsInstructions: true
  },
  {
    id: 'qwen-audio-3.1-tts-flash', label: 'Qwen-Audio-TTS 3.1 Flash', group: '推荐',
    description: 'WebSocket/HTTP · 支持声音复刻/设计/指令控制（较新）',
    supportsInstructions: true
  },
  {
    id: 'cosyvoice-v3.5-plus', label: 'CosyVoice v3.5 Plus', group: '其它',
    description: 'WebSocket/HTTP · 支持指令控制',
    supportsInstructions: true
  },
  {
    id: 'cosyvoice-v3.5-flash', label: 'CosyVoice v3.5 Flash', group: '其它',
    description: 'WebSocket/HTTP · 支持指令控制',
    supportsInstructions: true
  },
  {
    id: 'cosyvoice-v3-flash', label: 'CosyVoice v3 Flash', group: '其它',
    description: 'WebSocket/HTTP · 支持指令控制',
    supportsInstructions: true
  },
  {
    id: 'cosyvoice-v3-plus', label: 'CosyVoice v3 Plus', group: '其它',
    description: 'WebSocket/HTTP · 不支持指令控制',
    supportsInstructions: false
  },
  {
    id: 'cosyvoice-v2', label: 'CosyVoice v2', group: '其它',
    description: 'WebSocket/HTTP · 旧版',
    supportsInstructions: false
  }
];

/**
 * 火山引擎豆包。
 * ⚠️ 火山的"模型"通过 **`X-Api-Resource-Id` 请求头**传递，**不是** body 的 model 字段。
 *    `VolcengineTts.ets` 已按此实现（常量 `RESOURCE_ID`），用户手填时需改该头
 *    （可用「高级 → 附加请求头」覆盖，逃生口已打通）。
 */
const VOLCENGINE_MODELS: AiModelOption[] = [
  {
    id: 'seed-tts-2.0', label: '豆包语音合成大模型 2.0', group: '推荐',
    description: 'X-Api-Resource-Id 头 · 主表 294 条音色 · 支持语音指令',
    supportsInstructions: true
  },
  {
    id: 'seed-tts-2.0-standard', label: '豆包 TTS 2.0（标准版）', group: '其它',
    description: '官方说明：默认值',
    supportsInstructions: true
  },
  {
    id: 'seed-icl-2.0', label: '豆包声音复刻大模型 2.0', group: '其它',
    description: '只能用声音复刻接口注册的音色（本工程未做复刻功能）',
    supportsInstructions: true
  }
];

/**
 * MiniMax（独立厂商）。
 * ✅ 2026-10-11 已由官方 OpenAPI 确认：`docs/日志.md:204-211` 的 `model` enum 原文
 *    就是这 8 个，【待验证】标记已摘除。
 * ⚠️ 官方另有 `language_boost` 参数（见 `MiniMaxTts.ets`），与本表无关。
 */
const MINIMAX_MODELS: AiModelOption[] = [
  {
    id: 'speech-2.8-hd', label: 'speech-2.8-hd', group: '推荐',
    description: '最新高清版 · 音质最佳、延迟略高',
    supportsInstructions: false
  },
  {
    id: 'speech-2.8-turbo', label: 'speech-2.8-turbo', group: '推荐',
    description: '最新极速版 · 本工程默认',
    supportsInstructions: false
  },
  {
    id: 'speech-2.6-hd', label: 'speech-2.6-hd', group: '其它',
    description: '上一代高清版',
    supportsInstructions: false
  },
  {
    id: 'speech-2.6-turbo', label: 'speech-2.6-turbo', group: '其它',
    description: '上一代极速版',
    supportsInstructions: false
  },
  {
    id: 'speech-02-hd', label: 'speech-02-hd', group: '其它',
    description: '早期高清版',
    supportsInstructions: false
  },
  {
    id: 'speech-02-turbo', label: 'speech-02-turbo', group: '其它',
    description: '早期极速版',
    supportsInstructions: false
  },
  {
    id: 'speech-01-hd', label: 'speech-01-hd', group: '其它',
    description: '初代高清版（官方注：speech-01/02 系列不支持 Persian、Filipino、Tamil 三语种）',
    supportsInstructions: false
  },
  {
    id: 'speech-01-turbo', label: 'speech-01-turbo', group: '其它',
    description: '初代极速版',
    supportsInstructions: false
  }
];

/**
 * 小米 MiMo。官方三个模型（`docs/日志tts.md:37` 原文：
 * 「可选值：mimo-v2.5-tts，mimo-v2.5-tts-voicedesign，mimo-v2.5-tts-voiceclone」）。
 *
 * ⚠️ 后两个**本工程暂不支持**，原因来自官方对 `audio.voice` 的规定（`docs/日志tts.md:57-60`）：
 *   · `mimo-v2.5-tts-voiceclone`：`voice` **必填且只能是音频样本的 base64**（mp3/wav），
 *      即需要"上传样本→复刻"的完整流程，本工程无此 UI。
 *   · `mimo-v2.5-tts-voicedesign`：**不支持** `voice` 字段，且需 `user` 消息描述音色
 *      （`optimize_text_preview` 可与 assistant 二选一），本工程无此 UI。
 * ⇒ 表里保留它们（用户可能自填、或将来补 UI），但 `group` 标为「本工程不支持」，
 *    UI 选中时可给出明确提示，而不是让用户撞上服务端报错。
 */
const MIMO_MODELS: AiModelOption[] = [
  {
    id: 'mimo-v2.5-tts', label: 'MiMo v2.5 TTS', group: '推荐',
    description: '预置音色（9 条内置音色，本工程默认）；voice 可选，默认 mimo_default',
    supportsInstructions: true
  },
  {
    id: 'mimo-v2.5-tts-voicedesign', label: 'MiMo v2.5 声音设计', group: '本工程不支持',
    description: '不支持 voice 字段，需 user 消息描述音色（本工程无此 UI）',
    supportsInstructions: true
  },
  {
    id: 'mimo-v2.5-tts-voiceclone', label: 'MiMo v2.5 声音复刻', group: '本工程不支持',
    description: 'voice 必填且只能是音频样本 base64（本工程无上传样本 UI）',
    supportsInstructions: true
  }
];

/** OpenAI 兼容（官方 + 多数中转/自建） */
const OPENAI_MODELS: AiModelOption[] = [
  {
    id: 'tts-1', label: 'tts-1', group: '推荐',
    description: '标准质量 · 延迟低',
    supportsInstructions: false
  },
  {
    id: 'tts-1-hd', label: 'tts-1-hd', group: '推荐',
    description: '高质量 · 延迟略高',
    supportsInstructions: false
  },
  {
    id: 'gpt-4o-mini-tts', label: 'gpt-4o-mini-tts', group: '其它',
    description: '较新 · 支持 instructions 语气控制',
    supportsInstructions: true
  }
];

/** 该服务商的模型候选表（未知 id 回落 OpenAI 兼容表，与音色表同策略） */
export function aiModelOptionsFor(providerId: string): AiModelOption[] {
  const id: string = providerId.trim();
  if (id === 'dashscope') {
    return DASHSCOPE_MODELS;
  }
  if (id === 'volcengine') {
    return VOLCENGINE_MODELS;
  }
  if (id === 'minimax') {
    return MINIMAX_MODELS;
  }
  if (id === 'mimo') {
    return MIMO_MODELS;
  }
  return OPENAI_MODELS;
}

/**
 * 按 `group` 分组（UI 下拉的分节用）。保持首次出现顺序。
 */
export interface AiModelGroup {
  title: string;
  items: AiModelOption[];
}

export function aiModelGroupsFor(providerId: string): AiModelGroup[] {
  const list: AiModelOption[] = aiModelOptionsFor(providerId);
  const out: AiModelGroup[] = [];
  for (let i = 0; i < list.length; i++) {
    const m: AiModelOption = list[i];
    const g: string = m.group !== undefined && m.group !== null && m.group.length > 0
      ? m.group : '其它';
    let found: AiModelGroup | null = null;
    for (let k = 0; k < out.length; k++) {
      if (out[k].title === g) {
        found = out[k];
        break;
      }
    }
    if (found === null) {
      const ng: AiModelGroup = { title: g, items: [] };
      ng.items.push(m);
      out.push(ng);
    } else {
      found.items.push(m);
    }
  }
  return out;
}

/** 模型展示名（表里没有的自定义 id 原样返回） */
export function aiModelLabel(providerId: string, modelId: string): string {
  const id: string = modelId.trim();
  if (id.length === 0) {
    return '未指定';
  }
  const list: AiModelOption[] = aiModelOptionsFor(providerId);
  for (let i = 0; i < list.length; i++) {
    if (list[i].id === id) {
      return list[i].label;
    }
  }
  return id;
}

/**
 * 该模型是否支持自然语言语气控制。
 *
 * ⚠️ 用途：UI 据此决定**是否渲染「风格提示词」输入框**（不支持的渲染就是假控件）。
 * 表里查不到的（用户手填的模型名）返回 `false` —— 宁可不显示，
 * 也不给用户一个填了不起作用的框。
 */
export function aiModelSupportsInstructions(providerId: string, modelId: string): boolean {
  const id: string = modelId.trim().toLowerCase();
  if (id.length === 0) {
    return false;
  }
  const list: AiModelOption[] = aiModelOptionsFor(providerId);
  for (let i = 0; i < list.length; i++) {
    if (list[i].id.toLowerCase() === id) {
      return list[i].supportsInstructions;
    }
  }
  return false;
}

/**
 * **一致性自检**：各 provider 的 `modelHint` 必须能在本表里查到。
 *
 * 为什么需要：2026-10-11 我犯过一次——把 `DASHSCOPE_META.modelHint` 改成
 * `qwen3-tts-instruct-flash`，而该模型**不在官方清单里**（是旧名）。
 * 这类"元数据与真实可选项脱节"的错误在编译期完全无声，只有真机报错才暴露。
 *
 * 用法：由 UI 在面板初始化时调用一次（或开发者自检入口），把返回值打到日志。
 * 返回空数组 = 全部一致。
 */
export function aiModelHintMismatches(providerIds: string[],
  hintOf: (providerId: string) => string): string[] {
  const bad: string[] = [];
  for (let i = 0; i < providerIds.length; i++) {
    const pid: string = providerIds[i];
    const hint: string = hintOf(pid).trim();
    if (hint.length === 0) {
      continue;
    }
    const list: AiModelOption[] = aiModelOptionsFor(pid);
    let found: boolean = false;
    for (let k = 0; k < list.length; k++) {
      if (list[k].id === hint) {
        found = true;
        break;
      }
    }
    if (!found) {
      bad.push(pid + ' 的 modelHint="' + hint + '" 不在模型表中');
    }
  }
  return bad;
}

/**
 * 该服务商的**官方音色列表页**（给「更多音色」入口用；空串 = 无公开页面）。
 *
 * ── 设计取舍（用户 2026-10-12 拍板）────────────────────────────────────────
 * 用户原话：「这个更多音色，不如给用户一个链接……这玩意儿越简单越好，
 *   基本上不属于我们主要提供的功能……只能说我们有，但是不主要。」
 * ⇒ 本工程**不自建音色浏览器**（433 条渲染/搜索/分组全是维护成本），
 *    只给一个跳转入口，由**系统浏览器**打开官方页面（用户选 A 方案）。
 *    链接均为已实测可访问的官方地址（抓取记录见 `tools/voice-data/README.md`）。
 *
 * 返回空串的情形：
 *  · MiniMax —— 它有「列音色」接口，本工程已实现 App 内一键拉取，
 *    拿到的就是该账号真实可用的全部音色，**比看文档更准**，无需跳转；
 *  · MiMo —— 官方无公开音色列表页（文档站是纯前端 SPA，音色仅 9 条固定）。
 */
export function aiVoiceListUrlFor(providerId: string): string {
  const id: string = providerId.trim();
  if (id === 'dashscope') {
    return 'https://help.aliyun.com/zh/model-studio/qwen-tts-voice-list';
  }
  if (id === 'volcengine') {
    return 'https://docs.volcengine.com/docs/6561/1257544';
  }
  if (id === 'openai') {
    return 'https://platform.openai.com/docs/guides/text-to-speech';
  }
  return '';
}
