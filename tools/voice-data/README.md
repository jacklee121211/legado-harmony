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

### 阿里通义 DashScope（Qwen3-TTS）

| 文件 | 内容 | 条数 |
|---|---|---|
| `dashscope-voices-full.json` | 官方音色列表**全量**（去重后） | 48 |
| `dashscope-voices-clean.json` | 清洗后（去掉误串入的页面导航文字，抽出性别） | 48 |
| `dashscope-voices-picked.json` | 我们收录的**主流中文精选** | 16 |

- 来源：<https://help.aliyun.com/zh/model-studio/qwen-tts-voice-list>
- 官方分三组：普通话 28 / 方言 10 / 多语种角色 10
- 全部音色均支持 10 种语言（含日语）——这是「中文书被念成日语」问题的背景
- ⚠️ 该服务商**无「列音色」接口** ⇒ 表只能内置或手工维护

### 火山引擎（豆包语音合成 2.0）

| 文件 | 内容 | 条数 |
|---|---|---|
| `volcengine-voices-full.json` | 官方音色列表**全量** | 433 |
| `volcengine-voices-picked.json` | 我们收录的**主流中文精选** | 24 |
| `volcengine-voices-official.md` | 官方文档**原始 Markdown**（含全部表格与说明） | 50 KB |

- 来源：<https://docs.volcengine.com/docs/6561/1257544>（标题「音色列表」）
- 官方接口取回：`GET /api/doc/getDocDetail?LibraryCode=DoubaoVoice&DocumentCode=Tonelist-1`
- 官方 `UpdatedTime`：**2026-09-22**
- 官方分区：2.0 主表 294 条 + 外语音色 137 条（另有情感参数表 8 行，非音色，已剔除）
- ⚠️ 官方表**不提供音色描述列**（只有场景/语种/支持能力/标签）
  ⇒ 我们内置表的 `description` 用「场景 · 语种」原文，**不臆造**
- 「有声阅读」是官方为听书场景单列的分类，精选表优先收录

### 小米 MiMo

- 【待验证】官方文档站 `platform.xiaomimimo.com` 是**纯前端 SPA**，
  正文靠 JS 渲染，`Invoke-WebRequest` 只能取到 18 字节的壳页 ⇒ **本次未能抓取**
- 当前内置的 9 条沿用参考项目已验证清单
  （其注释：「描述来源：小米 MiMo 官方文档 + Studio 试听印象」）
- 待能访问官方文档时补抓，并复核这 9 条

### MiniMax

- **该服务商有官方「列音色」接口**：`POST {base}/v1/get_voice`，body `{"voice_type":"all"}`
- 因此**不做静态全表**：内置 4 条起步值，真实清单由 App 内「拉取音色」按钮获得，
  并按指纹（`providerId|baseUrl`）落盘缓存 7 天（见 `AiVoiceCatalog.ets`）
- 实现：`entry/src/main/ets/tts/ai/providers/MiniMaxTts.ets` 的 `listVoices`

### OpenAI 兼容

- OpenAI 官方 `/v1/audio/speech` 公开的内置音色名（`alloy`/`echo`/`fable`/`onyx`/`nova`/`shimmer`）
- 另收录 Edge 系音色 id：大量中转站以 OpenAI 兼容形代理 Edge TTS，填这些 id 可直接出声

## 复现方式

```powershell
pwsh -File tools/fetch-voice-data.ps1
```

脚本会重新抓取通义与火山并写入本目录（MiMo 因 SPA 限制会跳过并提示）。

## 合规说明

- **音色 id、官方中文名、官方描述**属于厂商公开接口事实与文档内容，可自由使用；
- 本目录**不包含**参考项目（ColorTxt-main, MPL-2.0）的任何代码或自撰文案；
- 代码中的表结构与本工程精选逻辑均为自研。

