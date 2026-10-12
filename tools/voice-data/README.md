# AI 听书音色数据（官方抓取归档）

> 本目录是**数据资产**，不是代码。用途：
> ① 核对我们内置精选音色表的每一项是否与官方一致；
> ② 将来 UI 做「更多音色」弹窗（Markdown 呈现）时直接用这里的数据；
> ③ 服务商更新音色时，重跑抓取脚本比对差异。

## 抓取时间与环境

| 项 | 值 |
|---|---|
| 抓取日期 | 2026-10-11 |
| 抓取脚本 | `tools/fetch-voice-data.ps1` |
| 抓取方式 | 直接 HTTP 取官方文档页 / 官方文档接口（本环境无 web_search 余额，用 `Invoke-WebRequest`） |

## 文件清单

> ⚠️ 2026-10-11 起，本目录同时收录**音色**与**模型**两类数据。
> 二者**强绑定**：官方原文（<https://help.aliyun.com/zh/model-studio/qwen-audio-tts-voice-list>）
> 「所选音色（voice）必须属于当前模型（model）支持的音色列表，**不能跨模型混用**。
> 音色不匹配时，服务会返回 `InvalidParameter` 错误」

### 模型清单（五家）

| 文件 | 服务商 | 内容 |
|---|---|---|
| `dashscope-models.json` | 通义 | 官方「模型列表」全部 **14** 个模型（含 API 形态、指令控制能力） |
| `volcengine-models.json` | 火山 | **3** 个（`seed-tts-2.0` / `-standard` / `seed-icl-2.0`） |
| `volcengine-models-official.md` | 火山 | 官方「模型列表」文档原始 Markdown |
| `minimax-models.json` | MiniMax | **8** 个（官方 OpenAPI enum，已确认） |
| `mimo-models.json` | MiMo | **3** 个（官方 API 文档，已确认） |
| `openai-models.json` | OpenAI 兼容 | **3** 个（`tts-1` / `tts-1-hd` / `gpt-4o-mini-tts`） |

**重要事实**：
- **通义**：官方现行模型名里**没有** `qwen3-tts-instruct-flash`（旧名，已不在清单）。
  支持「指令控制」的是 `qwen-audio-3.0-tts-plus` / `-flash` / `3.1-tts-flash` 与部分 CosyVoice。
- **火山**：模型通过 **`X-Api-Resource-Id` 请求头**传递，**不是** body 的 `model` 字段。
- **模型与音色不同表**：例如 `qwen3-tts-flash` 用 `qwen-tts-voice-list` 的 48 条音色，
  而 `qwen-audio-3.0-tts-*` 用**另一张** `qwen-audio-tts-voice-list` 表 ⇒ UI 切换模型必须联动音色。

### 阿里通义 DashScope（Qwen3-TTS）

| 文件 | 内容 | 条数 |
|---|---|---|
| `dashscope-voices-full.json` | 官方音色列表**全量**（去重后） | 48 |
| `dashscope-voices-clean.json` | 清洗后（去掉误串入的页面导航文字，抽出性别） | 48 |
| `dashscope-voices-picked.json` | 我们收录的**主流中文精选** | 16 |
| `dashscope-models.json` | 官方模型清单 | 14 |

- 音色来源：<https://help.aliyun.com/zh/model-studio/qwen-tts-voice-list>
- 模型来源：<https://help.aliyun.com/zh/model-studio/tts-model>
- 官方分三组：普通话 28 / 方言 10 / 多语种角色 10
- 全部音色均支持 10 种语言（含日语）——这是「中文书被念成日语」问题的背景
- ⚠️ 该服务商**无「列音色」接口** ⇒ 表只能内置或手工维护

### 火山引擎（豆包语音合成 2.0）

| 文件 | 内容 | 条数 |
|---|---|---|
| `volcengine-voices-full.json` | 官方音色列表**全量** | 433 |
| `volcengine-voices-picked.json` | 我们收录的**主流中文精选** | 24 |
| `volcengine-voices-official.md` | 官方文档**原始 Markdown**（含全部表格与说明） | 50 KB |
| `volcengine-models-official.md` | 官方「模型列表」原始 Markdown | 18 KB |

- 来源：<https://docs.volcengine.com/docs/6561/1257544>（标题「音色列表」）
- 官方接口取回：`GET /api/doc/getDocDetail?LibraryCode=DoubaoVoice&DocumentCode=Tonelist-1`
  （模型列表：`DocumentCode=model-list`）
- 官方 `UpdatedTime`：**2026-09-22**
- 官方分区：2.0 主表 294 条 + 外语音色 137 条（另有情感参数表 8 行，非音色，已剔除）
- ⚠️ 官方表**不提供音色描述列**（只有场景/语种/支持能力/标签）
  ⇒ 我们内置表的 `description` 用「场景 · 语种」原文，**不臆造**
- 「有声阅读」是官方为听书场景单列的分类，精选表优先收录

### 小米 MiMo

| 文件 | 内容 |
|---|---|
| `mimo-official-api.md` | **官方 API 文档原文**（用户手抄提供，17 KB） |
| `mimo-models.json` | 3 个模型 + 9 条音色（官方确认） |

- ✅ **2026-10-11 已由官方文档确认**（此前为参考项目二手数据）
- 官方原文（`mimo-official-api.md`）关键行：
  - **L37 模型**：「可选值：mimo-v2.5-tts，mimo-v2.5-tts-voicedesign，mimo-v2.5-tts-voiceclone」
  - **L62 音色**：「mimo-v2.5-tts：mimo_default，冰糖，茉莉，苏打，白桦，Mia，Chloe，Milo，Dean」
  - **L44-47 格式**：默认 `wav`；`stream:true` 时为 `pcm`；可选 `wav`/`mp3`/`pcm`/`pcm16`
  - **L57-60 voice 规则**：按模型而异 —— 预置可选 / 复刻必填样本 base64 / 设计不支持该字段
- ⚠️ 官方**无「列音色」接口** ⇒ 只能内置静态表（与通义同）
- ⚠️ 后两个模型（voicedesign / voiceclone）**本工程不支持**（缺上传样本与音色设计的 UI）

### MiniMax

| 文件 | 内容 |
|---|---|
| `minimax-official-openapi.md` | **官方 OpenAPI 规范原文**（用户手抄提供，253 KB） |
| `minimax-models.json` | 8 个模型（官方确认）+ 示例音色 |

- ✅ **2026-10-11 已由官方 OpenAPI 确认**（此前 4 条来自阿里云托管页、4 条标【待验证】）
- 官方原文（`minimax-official-openapi.md`）关键行：
  - **L204-211 模型 enum**：`speech-2.8-hd` / `-turbo` / `speech-2.6-hd` / `-turbo` /
    `speech-02-hd` / `-turbo` / `speech-01-hd` / `-turbo`（**恰好 8 个**）
  - **L5632 `/v1/get_voice`**：查询可用音色 ID，请求体 `{"voice_type":"all"}`
    （enum：`system` / `voice_cloning` / `voice_generation` / `all`）
  - **L5075+ `language_boost`**：与通义 `language_type` 同类参数（enum 30+ 语种，
    粤语需用特殊值 `Chinese,Yue`）
  - **L491 `voice_id`**：官方列了部分示例音色（`Chinese (Mandarin)_Lyrical_Voice` 等）
- ✅ **有「列音色」接口** ⇒ 本工程已实现动态拉取 + 落盘缓存（见下）

#### MiniMax 音色查询与缓存机制（已实现）

| 环节 | 位置 |
|---|---|
| 服务商声明 | `MINIMAX_META.supportsListVoices = true`（唯一一家） |
| HTTP 调用 | `MiniMaxTts.listVoices()` → `POST /v1/get_voice`，体 `{"voice_type":"all"}` |
| 缓存落盘 | `AiVoiceCatalog.ets`（指纹 = `providerId\|baseUrl`，TTL 7 天，LRU 5 个） |
| UI 入口 | `TtsControlPanel` 的「拉取音色」/「刷新音色」按钮 |

⚠️ **已知解析坑（2026-10-11 已修）**：官方 `description` 字段是**字符串数组**
（`SystemVoiceInfo.description: { type: array, items: { type: string } }`），
旧代码按字符串处理 ⇒ **音色描述永远为空**。现兼容数组/字符串两种形态。

### 旧记录（已解决）

- ~~官方文档站 `platform.xiaomimimo.com` 是纯前端 SPA，`Invoke-WebRequest` 只能取到
  18 字节壳页 ⇒ 未能抓取~~ ⇒ **用户以浏览器打开并手抄，已解决**
- ~~MiniMax 与 MiMo 的模型/音色为参考项目二手数据~~ ⇒ **已由官方文档确认**

### OpenAI 兼容

- OpenAI 官方 `/v1/audio/speech` 公开的内置音色名（`alloy`/`echo`/`fable`/`onyx`/`nova`/`shimmer`）
- 另收录 Edge 系音色 id：大量中转站以 OpenAI 兼容形代理 Edge TTS，填这些 id 可直接出声

## 复现方式

```powershell
pwsh -File tools/fetch-voice-data.ps1
```

脚本会自动抓取：通义（音色 48 + 模型 14）、火山（音色 433 + 模型列表文档）。

**MiMo 与 MiniMax 需人工手抄**（官方站是纯前端 SPA，HTTP 直取拿不到正文）：

1. 浏览器打开官方文档站；
2. 全选复制正文，存成 Markdown；
3. 放到本目录，命名 `mimo-official-api.md` / `minimax-official-openapi.md`；
4. 在 `* -models.json` 里记录来源行号（便于日后复核）。

> 2026-10-11 实测有效：这两份文档就是这样拿到的（253 KB + 17 KB）。

## 合规说明

- **音色 id、官方中文名、官方描述**属于厂商公开接口事实与文档内容，可自由使用；
- 本目录**不包含**参考项目（ColorTxt-main, MPL-2.0）的任何代码或自撰文案；
- 代码中的表结构与本工程精选逻辑均为自研。

