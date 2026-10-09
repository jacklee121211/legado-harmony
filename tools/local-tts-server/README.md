# 本机 TTS 服务（零成本验证「AI 听书」）

> 目的：**没有付费 API Key** 也能把「AI 听书」全链路跑通。
> 做法：在你自己的 PC 上起一个 OpenAI 兼容的 `/v1/audio/speech` 服务，手机走局域网连它。
> 这不是"绕过"什么——它就是你**自己的**接口，正是本功能设计的用法（用户自带 API）。

## 0. 为什么它可以零成本

| 后端 | 成本 | 联网 | 输出 | 依赖 |
|---|---|---|---|---|
| `edge`（默认） | **0 元、无 Key** | 需要 | mp3 | `pip install edge-tts` |
| `sapi`（离线兜底） | **0 元、无 Key** | **完全不需要** | wav | 无（Windows 自带） |

App 侧已支持 **mp3 / wav / pcm** 三种容器并按**字节内容**嗅探真实格式，
所以服务端返回哪种都能播（服务端忽略 `response_format` 也不会出错）。

## 1. 跑起来（PC）

```powershell
# 方式 A：免费在线音色（推荐，音色多、质量好）
pip install edge-tts
python tools\local-tts-server\local_tts_server.py

# 方式 B：完全离线（中文 Windows 自带音色，什么都不用装）
python tools\local-tts-server\local_tts_server.py --backend sapi

# 方式 C：走代理（edge 后端连不上微软时，例如 Cannot connect to host speech.platform.bing.com）
python tools\local-tts-server\local_tts_server.py --proxy http://127.0.0.1:7890

# 方式 D：[调试] 强制输出 44.1kHz 立体声 WAV，用来压 App 侧「立体声折叠 + 重采样」分支
#         （仅 wav 后端有效；App 里的「输出格式」要选 wav）
python tools\local-tts-server\local_tts_server.py --backend sapi --force-44k-stereo
```

> 启动时会**自检**：edge 后端先试合成一个字，把"微软能不能连上"的结论直接打在控制台
> （`[OK] 自检通过` / `[FAIL] 自检失败` + 三条解法）。连不上就先加 `--proxy`，或改用 `--backend sapi`。

启动后会打印手机要填的地址，形如：

```
[14:22:01] 手机端「接口地址」请填（同一 Wi-Fi）：
[14:22:01]     http://192.168.3.100:8880/v1
```

- 首次运行 Windows 防火墙会弹窗 → **必须勾选「专用网络」并允许**；
- 手机与 PC 必须**同一 Wi-Fi**；
- 自检（PC 上）：`curl http://127.0.0.1:8880/v1/models` 应返回一段 JSON。

## 2. App 里怎么填

阅读器 → 听书 → 展开档 → **AI 语音 → 接入设置**：

| 字段 | 填什么 |
|---|---|
| 服务商 | OpenAI 兼容 |
| 接口地址 | `http://<PC内网IP>:8880/v1`（服务启动时打印的那个） |
| API Key | `local` ← **随便填，不能留空**（本服务不校验；App 只要求非空） |
| 模型 | `tts-1`（本服务忽略） |
| 输出格式 | `mp3`（sapi 后端会自动按 wav 处理，不用改） |
| 音色 | 见下表。App 的「音色」区**允许手填任意 id** |

点 **保存** → 点 **试听**。听到声音就说明链路通了。

## 3. 音色 id 怎么填

**edge 后端**（`--list-voices` 可查全部）：

| 用途 | id |
|---|---|
| 旁白（男） | `zh-CN-YunjianNeural` |
| 对白（男·青年） | `zh-CN-YunxiNeural` |
| 对白（女） | `zh-CN-XiaoxiaoNeural` |
| 女声备选 | `zh-CN-XiaoyiNeural` |
| 方言 | `zh-CN-liaoning-XiaobeiNeural` / `zh-CN-shaanxi-XiaoniNeural` |

**sapi 后端**：先列本机音色（PowerShell）：

```powershell
Add-Type -AssemblyName System.Speech
(New-Object System.Speech.Synthesis.SpeechSynthesizer).GetInstalledVoices() | %{ $_.VoiceInfo.Name }
```

中文系统通常有 `Microsoft Huihui Desktop` / `Microsoft Yaoyao Desktop`（女声），
有的还有 `Microsoft Kangkang`（男声）。填进 App 的「音色」区即可。

> 认不出来的 id（例如 App 默认的 `alloy`/`onyx`/`nova`）服务端会**自动回落到默认音色**并打日志，
> 所以第一次就填 `alloy` 也不会报错——但音色会统一，多角色就分不出来了。

## 4. 与「AI 男女声」配合（这才是完整效果）

「AI 男女声」是**独立的辅助开关**，走**对话大模型**（不是 TTS）：

- 面板 →「AI 男女声」→ 接口设置：填任意 OpenAI 兼容的**对话**接口
  （DeepSeek 就行：`https://api.deepseek.com/v1` + 你的 key + `deepseek-chat`）；
- 打开它之后，旁白/对白/男声/女声四个槽位在本机 TTS 上同样生效
  （把上面表里的 id 分别填进四个槽位即可听到三种声音）。

## 5. 排查

服务端控制台会打印每次合成（字数/格式/大小/耗时/音色）。
App 侧的日志：

```powershell
devecocli log --keyword AiTts --from 5m --tail 300 --bundle-name com.jk.reader
```

| 日志 | 含义 |
|---|---|
| `AiTts synth ok url=… fmt=… bytes=…` | 服务端通了、拿到音频 |
| `AiTts format mismatch: requested=… actual=…` | 服务端忽略了你选的格式 → **已自动按实际内容处理** |
| `AiTtsHttp post fail url=… code=…` | 连不上（检查 IP/端口/防火墙/同一 Wi-Fi） |
| `ai pcm: fmt=… in=…Hz/…ch … out=24000Hz` | 音频规格归一化结果（立体声/异采样率处理器） |
| `AI 语音失败：服务端返回 404…`（toast） | 接口路径不对（服务端不是 OpenAI 兼容形状） |

## 6. 明文 HTTP 要不要额外配置？

**不用。** 官方 FAQ 原文（`documentId` `FAQ/网络/网络_Network/Stage模型如何配置支持http明文传输/faqs-network-16`）：

> 无需配置，支持HTTP明文传输数据。

（本工程是标准 Stage 模型，证据：`entry/src/main/module.json5` 的 `EntryAbility`。）
