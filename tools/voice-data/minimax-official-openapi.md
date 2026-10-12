> ## Documentation Index
> Fetch the complete documentation index at: https://platform.minimaxi.com/docs/llms.txt
> Use this file to discover all available pages before exploring further.

# 同步语音合成

> 通过 HTTP 请求一次提交完整文本并返回合成音频，支持流式输出。

华北地区建议接入地址见 [同步语音合成 · 接入地址](/docs/guides/speech-t2a-websocket#接入地址)。


## OpenAPI

````yaml api-reference/speech/t2a/api/openapi.json POST /v1/t2a_v2
openapi: 3.1.0
info:
  title: MiniMax T2A API
  description: >-
    MiniMax Text-to-Audio API with support for streaming and non-streaming
    output
  license:
    name: MIT
  version: 1.0.0
servers:
  - url: https://api.minimax.cn
security:
  - bearerAuth: []
paths:
  /v1/t2a_v2:
    post:
      tags:
        - Text to Audio
      summary: Text to Audio V2
      operationId: t2aV2
      parameters:
        - name: Content-Type
          in: header
          required: true
          description: 请求体的媒介类型，请设置为 `application/json`，确保请求数据的格式为 JSON
          schema:
            type: string
            enum:
              - application/json
            default: application/json
      requestBody:
        description: ''
        content:
          application/json:
            schema:
              $ref: '#/components/schemas/T2aV2Req'
            examples:
              非流式:
                value:
                  model: speech-2.8-hd
                  text: 今天是不是很开心呀(laughs)，当然了！
                  stream: false
                  voice_setting:
                    voice_id: male-qn-qingse
                    speed: 1
                    vol: 1
                    pitch: 0
                    emotion: happy
                  pronunciation_dict:
                    tone:
                      - 处理/(chu3)(li3)
                      - 危险/dangerous
                  audio_setting:
                    sample_rate: 32000
                    bitrate: 128000
                    format: mp3
                    channel: 1
                  subtitle_enable: false
              流式:
                value:
                  model: speech-2.8-hd
                  text: 今天是不是很开心呀(laughs)，当然了！
                  stream: true
                  voice_setting:
                    voice_id: male-qn-qingse
                    speed: 1
                    vol: 1
                    pitch: 0
                    emotion: happy
                  pronunciation_dict:
                    tone:
                      - 处理/(chu3)(li3)
                      - 危险/dangerous
                  audio_setting:
                    sample_rate: 32000
                    bitrate: 128000
                    format: mp3
                    channel: 1
                  subtitle_enable: false
        required: true
      responses:
        '200':
          description: ''
          content:
            application/json:
              schema:
                $ref: '#/components/schemas/T2aV2Resp'
              examples:
                非流式:
                  value:
                    data:
                      audio: <hex编码的audio>
                      status: 2
                    extra_info:
                      audio_length: 9900
                      audio_sample_rate: 32000
                      audio_size: 160323
                      bitrate: 128000
                      word_count: 52
                      invisible_character_ratio: 0
                      usage_characters: 26
                      audio_format: mp3
                      audio_channel: 1
                    trace_id: 01b8bf9bb7433cc75c18eee6cfa8fe21
                    base_resp:
                      status_code: 0
                      status_msg: success
                流式:
                  value:
                    - data:
                        audio: hex编码的audio_chunk1
                        status: 1
                      trace_id: 01b8bf9bb7433cc75c18eee6cfa8fe21
                      base_resp:
                        status_code: 0
                        status_msg: ''
                    - data:
                        audio: hex编码的audio_chunk2
                        status: 1
                      trace_id: 01b8bf9bb7433cc75c18eee6cfa8fe21
                      base_resp:
                        status_code: 0
                        status_msg: ''
                    - data:
                        audio: hex编码的audio
                        status: 2
                      extra_info:
                        audio_length: 6931
                        audio_sample_rate: 32000
                        audio_size: 111789
                        bitrate: 128000
                        word_count: 112
                        invisible_character_ratio: 0
                        usage_characters: 112
                        audio_format: mp3
                        audio_channel: 1
                      trace_id: 04ece790375f3ca2edbb44e8c4c200bf
                      base_resp:
                        status_code: 0
                        status_msg: success
            text/event-stream:
              schema:
                $ref: '#/components/schemas/T2aV2Resp'
              examples:
                流式:
                  value:
                    - data:
                        audio: hex编码的audio_chunk1
                        status: 1
                      trace_id: 01b8bf9bb7433cc75c18eee6cfa8fe21
                      base_resp:
                        status_code: 0
                        status_msg: ''
                    - data:
                        audio: hex编码的audio_chunk2
                        status: 1
                      trace_id: 01b8bf9bb7433cc75c18eee6cfa8fe21
                      base_resp:
                        status_code: 0
                        status_msg: ''
                    - data:
                        audio: hex编码的audio
                        status: 2
                      extra_info:
                        audio_length: 6931
                        audio_sample_rate: 32000
                        audio_size: 111789
                        bitrate: 128000
                        word_count: 112
                        invisible_character_ratio: 0
                        usage_characters: 112
                        audio_format: mp3
                        audio_channel: 1
                      trace_id: 04ece790375f3ca2edbb44e8c4c200bf
                      base_resp:
                        status_code: 0
                        status_msg: success
components:
  schemas:
    T2aV2Req:
      type: object
      required:
        - model
        - text
      properties:
        model:
          type: string
          description: 请求的模型版本
          enum:
            - speech-2.8-hd
            - speech-2.8-turbo
            - speech-2.6-hd
            - speech-2.6-turbo
            - speech-02-hd
            - speech-02-turbo
            - speech-01-hd
            - speech-01-turbo
        text:
          type: string
          description: >-
            需要合成语音的文本，长度限制小于 10000 字符，若文本长度大于 3000 字符，推荐使用流式输出

            - 段落切换用换行符标记

            - 停顿控制：支持自定义文本之间的语音时间间隔，以实现自定义文本语音停顿时间的效果。使用方式：在文本中增加`<#x#>`标记，`x`
            为停顿时长（单位：秒），范围 [0.01,
            99.99]，最多保留两位小数。文本间隔时间需设置在两个可以语音发音的文本之间，不可连续使用多个停顿标记

            - 行内发音替换：将普通话拼音（带声调数字 `1–5`）或 IPA 音标或粤语拼音（带声调数字
            `1–6`）用英文小括号包裹，可临时覆盖有问题的单词或者多音汉字的发音。
              - `"The word live is pronounced (lɪv) as a verb and (laɪv) as an adjective."`
              - `"This is (he2)平, not (huo4)面."`
              - `"去街市買啲(sung3)。"`
            - 语气词标签：仅当模型选择 `speech-2.8-hd` 或 `speech-2.8-turbo`
            时，支持在文本中插入语气词标签。支持的语气词：`(laughs)`（笑声）、`(chuckle)`（轻笑）、`(coughs)`（咳嗽）、`(clear-throat)`（清嗓子）、`(groans)`（呻吟）、`(breath)`（正常换气）、`(pant)`（喘气）、`(inhale)`（吸气）、`(exhale)`（呼气）、`(gasps)`（倒吸气）、`(sniffs)`（吸鼻子）、`(sighs)`（叹气）、`(snorts)`（喷鼻息）、`(burps)`（打嗝）、`(lip-smacking)`（咂嘴）、`(humming)`（哼唱）、`(hissing)`（嘶嘶声）、`(emm)`（嗯）、`(sneezes)`（喷嚏）
        stream:
          type: boolean
          description: 控制是否流式输出。默认 false，即不开启流式
        stream_options:
          $ref: '#/components/schemas/T2AStreamOption'
        voice_setting:
          $ref: '#/components/schemas/T2AVoiceSetting'
        audio_setting:
          $ref: '#/components/schemas/T2AAudioSetting'
        pronunciation_dict:
          $ref: '#/components/schemas/PronunciationDict'
        timbre_weights:
          type: array
          items:
            $ref: '#/components/schemas/TimbreWeights'
        language_boost:
          type: string
          description: |-
            是否增强对指定的小语种和方言的识别能力。默认值为 `null`，可设置为 `auto` 让模型自主判断。

            注意：speech-01 和 speech-02 系列模型暂不支持 Persian、Filipino、Tamil 这三个语种。
          enum:
            - Chinese
            - Chinese,Yue
            - English
            - Arabic
            - Russian
            - Spanish
            - French
            - Portuguese
            - German
            - Turkish
            - Dutch
            - Ukrainian
            - Vietnamese
            - Indonesian
            - Japanese
            - Italian
            - Korean
            - Thai
            - Polish
            - Romanian
            - Greek
            - Czech
            - Finnish
            - Hindi
            - Bulgarian
            - Danish
            - Hebrew
            - Malay
            - Persian
            - Slovak
            - Swedish
            - Croatian
            - Filipino
            - Hungarian
            - Norwegian
            - Slovenian
            - Catalan
            - Nynorsk
            - Tamil
            - Afrikaans
            - auto
          default: null
        text_normalization_mode:
          type: string
          description: >-
            文本归一化模式。`basic` 使用快速的规则归一化；`quality` 采用 LLM +
            规则的混合方案，归一化质量更高，但会增加一定延迟。详见[文本归一化](/guides/speech-t2a-websocket#文本归一化)。


            注意：

            - `quality` 目前仅对非流式请求（`stream=false`）生效，且仅支持
            `speech-2.8-hd`、`speech-2.8-turbo`、`speech-2.6-hd`、`speech-2.6-turbo`；流式请求或其他模型传入
            `quality` 时按 `basic` 处理，不会报错

            - 传入本参数后，`voice_setting.text_normalization` 不再生效；不传时沿用
            `voice_setting.text_normalization` 的设置（默认关闭）
          enum:
            - basic
            - quality
          x-mint:
            post:
              - updated
        voice_modify:
          $ref: '#/components/schemas/VoiceModify'
        subtitle_enable:
          type: boolean
          description: >-
            控制是否开启字幕服务，默认值为 false。仅对 `speech-2.8-hd`, `speech-2.8-turbo`,
            `speech-2.6-hd`, `speech-2.6-turbo`, `speech-02-hd`,
            `speech-02-turbo`, `speech-01-hd`, `speech-01-turbo` 模型有效
          default: false
        subtitle_type:
          type: string
          description: >-
            字幕粒度，默认值为 `sentence`。可选值：

            - `sentence`：句级别时间戳

            - `word`：词级别时间戳

            - `word_streaming`：流式优化的词级别时间戳，仅在 `stream=true` 时有效


            流式（`stream=true`）下字幕通过 `data.subtitle` 随音频下发，不返回 `subtitle_file`：

            - `sentence` / `word`：每个分段只在该分段最后一个音频片段中返回一次完整字幕，`sentence` 不含
            `timestamped_words`

            - `word_streaming`：每个音频片段都返回当前分段截至目前的累计字幕（`timestamped_words` 与
            `time_end` 持续增长），客户端应以最新一条覆盖同一分段的旧结果；`text_begin` 变化表示进入下一个分段


            非流式下字幕以文件形式通过 `subtitle_file` 返回
          enum:
            - sentence
            - word
            - word_streaming
          default: sentence
        output_format:
          type: string
          description: >-
            控制输出结果形式的参数，可选值范围为[`url`, `hex`]，默认值为 `hex` 。该参数仅在非流式场景生效，流式场景仅支持返回
            hex 形式。返回的 url 有效期为 24 小时
          enum:
            - url
            - hex
          default: hex
        aigc_watermark:
          type: boolean
          description: 控制在合成音频的末尾添加音频节奏标识，默认值为 False。该参数仅对非流式合成生效
          default: false
    T2aV2Resp:
      type: object
      properties:
        data:
          type: object
          description: 返回的合成数据对象，可能为 null，需进行非空判断
          properties:
            audio:
              type: string
              description: 合成后的音频数据，采用 hex 编码，格式与请求中指定的输出格式一致
            subtitle_file:
              type: string
              description: >-
                合成的字幕下载链接。音频文件对应的字幕，精确到句（不超过 50 字），单位为毫秒，格式为
                json。仅非流式（`stream=false`）返回；流式请使用 `subtitle` / `subtitles`
            subtitle:
              description: >-
                流式（`stream=true`）且开启字幕时返回，携带当前分段的字幕，随对应的音频片段下发。返回时机取决于
                `subtitle_type`：`sentence` / `word`
                在分段最后一个音频片段返回一次；`word_streaming` 在每个音频片段返回当前分段的累计结果
              allOf:
                - $ref: '#/components/schemas/T2ASubtitle'
            subtitles:
              type: array
              description: 流式（`stream=true`）且开启字幕时，在最后一个数据包（`status=2`）中返回，汇总本次请求所有分段的字幕
              items:
                $ref: '#/components/schemas/T2ASubtitle'
            status:
              type: integer
              description: 当前音频流状态：1 表示合成中，2 表示合成结束
        trace_id:
          type: string
          description: 本次会话的 id，用于在咨询/反馈时帮助定位问题
        extra_info:
          type: object
          description: 音频的附加信息
          properties:
            audio_length:
              type: integer
              format: int64
              description: 音频时长（毫秒）
            audio_sample_rate:
              type: integer
              format: int64
              description: 音频采样率
            audio_size:
              type: integer
              format: int64
              description: 音频文件大小（字节）
            bitrate:
              type: integer
              format: int64
              description: 音频比特率
            audio_format:
              type: string
              description: 生成音频文件的格式。取值范围 `[mp3, pcm, flac]`
              enum:
                - mp3
                - pcm
                - flac
            audio_channel:
              type: integer
              format: int64
              description: 生成音频声道数,1：单声道，2：双声道
            invisible_character_ratio:
              type: number
              format: float64
              description: 非法字符占比.非法字符不超过 10%（包含 10%），音频会正常生成,并返回非法字符占比数据；如超过 10% 将进行报错
            usage_characters:
              type: integer
              format: int64
              description: 计费字符数
            usage_voice_count:
              type: integer
              format: int64
              description: 本次请求计费的音色数量（音色首次使用时计费），仅在产生音色费用时返回
            word_count:
              type: integer
              format: int64
              description: 合成文本的字符数（含标点和空格），仅供参考，不用于计费；计费字符数请以 `usage_characters` 为准
            norm_text_char_count:
              type: integer
              format: int64
              description: >-
                本次经高质量文本归一化处理的字符数（按 Unicode 字符计）。仅在非流式请求且
                `text_normalization_mode=quality` 时返回；为 `0`
                表示本次未执行高质量归一化（例如所用模型不支持）。仅供参考，暂不用于计费
        base_resp:
          type: object
          description: 本次请求的状态码和详情
          properties:
            status_code:
              type: integer
              format: int64
              description: |-
                状态码。

                 您可在header中获取本次会话的trace_id，用于在咨询/反馈时帮助定位问题 

                - `0`: 请求结果正常
                - `1000`: 未知错误
                - `1001`: 超时
                - `1002`: 触发限流
                - `1004`: 鉴权失败
                - `1039`: 触发 TPM 限流
                - `1042`: 非法字符超过 10%
                - `2013`: 输入参数信息不正常

                更多内容可查看 [错误码查询列表](/api-reference/errorcode) 了解详情
            status_msg:
              type: string
              description: 状态详情
    T2AStreamOption:
      type: object
      properties:
        exclude_aggregated_audio:
          type: boolean
          description: >-
            设置最后一个 chunk 是否包含拼接后的语音 hex 数据。默认值为 False，即最后一个 chunk 中包含拼接后的完整语音
            hex 数据
    T2AVoiceSetting:
      type: object
      required:
        - voice_id
      properties:
        voice_id:
          type: string
          description: "合成音频的音色编号。若需要设置混合音色，请设置 timbre_weights 参数，本参数设置为空值。支持系统音色、复刻音色以及文生音色三种类型，以下是部分最新的系统音色（ID），可查看 [系统音色列表](/faq/system-voice-id) 或使用 [查询可用音色 API](/api-reference/voice-management-get) 查询系统支持的全部音色\n\n - **中文**:\n\t- moss_audio_ce44fc67-7ce3-11f0-8de5-96e35d26fb85\n\t- moss_audio_aaa1346a-7ce7-11f0-8e61-2e6e3c7ee85d\n\t- Chinese (Mandarin)_Lyrical_Voice\n\t- Chinese (Mandarin)_HK_Flight_Attendant\n- **英文**:\n\t- English_Graceful_Lady\n\t- English_Insightful_Speaker\n\t- English_radiant_girl\n\t- English_Persuasive_Man\n\t- moss_audio_6dc281eb-713c-11f0-a447-9613c873494c\n\t- moss_audio_570551b1-735c-11f0-b236-0adeeecad052\n\t- moss_audio_ad5baf92-735f-11f0-8263-fe5a2fe98ec8\n\t- English_Lucky_Robot\n- **日文**:\n\t- Japanese_Whisper_Belle\n\t- moss_audio_24875c4a-7be4-11f0-9359-4e72c55db738\n\t- moss_audio_7f4ee608-78ea-11f0-bb73-1e2a4cfcd245\n\t- moss_audio_c1a6a3ac-7be6-11f0-8e8e-36b92fbb4f95\n- **粤语**（需将 `language_boost` 参数设置为 `Chinese,Yue`）:\n\t- Cantonese_GentleLady\n\t- Cantonese_podacast_host_1"
        speed:
          type: number
          format: float
          description: 合成音频的语速，取值越大，语速越快。取值范围 `[0.5,2]`，默认值为1.0
          minimum: 0.5
          maximum: 2
          default: 1
        vol:
          type: number
          format: float
          description: 合成音频的音量，取值越大，音量越高。取值范围 `(0,10]`，默认值为 1.0
          exclusiveMinimum: 0
          maximum: 10
          default: 1
        pitch:
          type: integer
          description: 合成音频的语调，取值范围 `[-12,12]`，默认值为 0，其中 0 为原音色输出
          minimum: -12
          maximum: 12
          default: 0
        emotion:
          type: string
          description: "控制合成语音的情绪，参数范围 `[\"happy\", \"sad\", \"angry\", \"fearful\", \"disgusted\", \"surprised\", \"calm\", \"fluent\", \"whisper\"]`，分别对应 8 种情绪：高兴，悲伤，愤怒，害怕，厌恶，惊讶，中性，生动，低语 \r\n- 模型会根据输入文本自动匹配合适的情绪，一般无需手动指定  \r\n- 该参数仅对 `speech-2.8-hd`, `speech-2.8-turbo`, `speech-2.6-hd`, `speech-2.6-turbo`, `speech-02-hd`, `speech-02-turbo`, `speech-01-hd`, `speech-01-turbo` 模型生效 \r\n- 选项 `fluent`, `whisper` 仅对 `speech-2.6-turbo`, `speech-2.6-hd` 模型生效，`speech-2.8-hd`, `speech-2.8-turbo` 模型不支持 `whisper`"
          enum:
            - happy
            - sad
            - angry
            - fearful
            - disgusted
            - surprised
            - calm
            - fluent
            - whisper
        text_normalization:
          type: boolean
          description: >-
            废弃参数，请使用请求体一级参数 `text_normalization_mode`：本参数为 `true` 等价于
            `text_normalization_mode=basic`；为 `false` 或不传等价于不传
            `text_normalization_mode`。两者同时传入时以 `text_normalization_mode` 为准


            是否启用中文、英语文本规范化，开启后可提升数字阅读场景的性能，但会略微增加延迟，默认值为 false
          default: false
          deprecated: true
        latex_read:
          type: boolean
          description: >-
            控制是否朗读 latex 公式，默认为 false

            **需注意**:

            - 仅支持中文，开启该参数后，`language_boost` 参数会被设置为 `Chinese`

            - 请求中的公式需要在公式的首尾加上 `$$`

            - 请求中公式若有 `"\"`，需转义成 `"\\"`.


            示例：一元二次方程根的基本公式

            ![The quadratic
            formula](https://filecdn.minimax.chat/public/d6f62e9a-cd3f-4f55-a237-257eef531683.png)


            应表示为 `$$x = \\frac{-b \\pm \\sqrt{b^2 - 4ac}}{2a}$$`
          default: false
    T2AAudioSetting:
      type: object
      properties:
        sample_rate:
          type: integer
          format: int64
          description: 生成音频的采样率。可选范围`[8000，16000，22050，24000，32000，44100]`，默认为 `32000`
        bitrate:
          type: integer
          format: int64
          description: >-
            生成音频的比特率。可选范围`[32000，64000，128000，256000]`，默认值为 `128000`。该参数仅对 `mp3`
            格式的音频生效
        format:
          type: string
          description: >-
            生成音频的格式。`pcmu_raw` 与 `pcmu_wav` 为 G.711 μ-law 编码（采样率 8
            kHz；`pcmu_raw` 为无文件头裸数据，`pcmu_wav` 封装在 WAV 容器中）。`opus` 为 Ogg/Opus 编码
          enum:
            - mp3
            - pcm
            - flac
            - wav
            - pcmu_raw
            - pcmu_wav
            - opus
          default: mp3
        channel:
          type: integer
          format: int64
          description: 生成音频的声道数。可选范围：`[1,2]`，其中 `1` 为单声道，`2` 为双声道，默认值为 1
        force_cbr:
          type: boolean
          description: |-
            对于音频恒定比特率（cbr）控制，可选 `false`、 `true`。当此参数设置为 `true`，将以恒定比特率方式进行音频编码。
            注意：本参数仅当音频设置为**流式**输出，且音频格式为 `mp3` 时生效。
          default: false
    PronunciationDict:
      type: object
      properties:
        tone:
          type: array
          description: >-
            定义自定义发音规则，格式为 `原文/替换内容`。替换内容可以是纯文本、括号包裹的拼音（带声调数字）、括号包裹的 IPA
            音标，或日语假名（平假名、片假名、罗马音 —— 可混用）。多条规则会同时生效。


            示例：

            ```json dark

            "pronunciation_dict": {
              "tone": [
                "resume/(rɪˈzjuːm)",
                "read/(riːd)",
                "处理/(chu3)(li3)",
                "郑栅洁/(zheng4)(shan1)杰",
                "20日/はつか",
                "4桁/よんけた",
                "東京/トウキョウ",
                "omg/oh my god",
                "の/no"
              ]
            }

            ```


            该示例展示了：英文多音词的 IPA
            注音、中文的拼音+声调注音、拼音与汉字混合、日语假名表示数量词与汉字读音、文本到文本的展开替换、符号替换。


            中文声调：`1` = 一声，`2` = 二声，`3` = 三声，`4` = 四声，`5` = 轻声。
          items:
            type: string
    TimbreWeights:
      type: object
      required:
        - voice_id
        - weight
      properties:
        voice_id:
          type: string
          description: >-
            合成音频的音色编号，须和weight参数同步填写。支持系统音色、复刻音色以及文生音色三种类型。系统支持的全部音色可查看
            [系统音色列表](/faq/system-voice-id)，也可使用 [查询可用音色
            API](/api-reference/voice-management-get) 查询系统支持的全部音色
        weight:
          type: integer
          format: int64
          description: >-
            合成音频各音色所占的权重，须与 voice_id 同步填写。可选值范围为[1, 100]，最多支持 4
            种音色混合，单一音色取值占比越高，合成音色与该音色相似度越高.


            ```json dark

            "timbre_weights": [
              {
                "voice_id": "female-chengshu",
                "weight": 30
              },
              {
                "voice_id": "female-tianmei",
                "weight": 70
              }
            ]

            ```
          minimum: 1
          maximum: 100
    VoiceModify:
      type: object
      description: |-
        声音效果器设置，该参数支持的音频格式：
        - 非流式：`mp3`, `wav`, `flac`
        - 流式：`mp3`
      properties:
        pitch:
          type: integer
          description: >-
            音高调整（低沉/明亮），范围 [-100,100]，数值接近 -100，声音更低沉；接近 100，声音更明亮


            ![pitch
            adjustment](https://filecdn.minimax.chat/public/5d210c47-4236-4e81-893b-16cc1ef0302d.png)
          minimum: -100
          maximum: 100
        intensity:
          type: integer
          description: >-
            强度调整（力量感/柔和），范围 [-100,100]，数值接近 -100，声音更刚劲；接近 100，声音更轻柔


            ![intensity
            adjustment](https://filecdn.minimax.chat/public/862d493e-71d5-4d1f-b7c3-9ac51890631b.png)
          minimum: -100
          maximum: 100
        timbre:
          type: integer
          description: >-
            音色调整（磁性/清脆），范围 [-100,100]，数值接近 -100，声音更浑厚；数值接近 100，声音更清脆


            ![timbre
            adjustment](https://filecdn.minimax.chat/public/5f0e6cae-363a-452b-8d42-fbc4ef5a0510.png)
          minimum: -100
          maximum: 100
        sound_effects:
          type: string
          description: |-
            音效设置，单次仅能选择一种，可选值：
            1. spacious_echo（空旷回音）
            2. auditorium_echo（礼堂广播）
            3. lofi_telephone（电话失真）
            4. robotic（电音）
          enum:
            - spacious_echo
            - auditorium_echo
            - lofi_telephone
            - robotic
    T2ASubtitle:
      type: object
      description: 分段字幕。合成引擎会把文本切成若干分段（通常为一句），每个分段对应一条字幕
      properties:
        text:
          type: string
          description: 分段文本
        text_begin:
          type: integer
          format: int64
          description: 分段在本次合成文本中的起始字符位置（含）
        text_end:
          type: integer
          format: int64
          description: 分段在本次合成文本中的结束字符位置（不含）
        time_begin:
          type: number
          description: 分段起始时间，单位毫秒，相对本次合成音频的起点
        time_end:
          type: number
          description: 分段结束时间，单位毫秒，相对本次合成音频的起点
        timestamped_words:
          type: array
          description: >-
            词级时间戳，仅 `subtitle_type` 为 `word` / `word_streaming` 时返回，`sentence`
            时为 `null`
          items:
            $ref: '#/components/schemas/T2ASubtitleWord'
    T2ASubtitleWord:
      type: object
      description: 词级时间戳
      properties:
        word:
          type: string
          description: 词文本
        word_begin:
          type: integer
          format: int64
          description: 该词在本次合成文本中的起始字符位置（含）
        word_end:
          type: integer
          format: int64
          description: 该词在本次合成文本中的结束字符位置（不含）
        time_begin:
          type: number
          description: 该词起始时间，单位毫秒
        time_end:
          type: number
          description: 该词结束时间，单位毫秒
  securitySchemes:
    bearerAuth:
      type: http
      scheme: bearer
      bearerFormat: JWT
      description: |-
        `HTTP: Bearer Auth`
         - Security Scheme Type: http
         - HTTP Authorization Scheme: Bearer API_key，用于验证账户信息，可在 [账户管理>接口密钥](https://platform.minimax.cn/user-center/basic-information/interface-key) 中查看。

````







> ## Documentation Index
> Fetch the complete documentation index at: https://platform.minimaxi.com/docs/llms.txt
> Use this file to discover all available pages before exploring further.

# 同步语音合成

> 通过 WebSocket 连接由客户端按句发送文本，流式返回合成音频，适合低延迟的实时播报。



## AsyncAPI

````yaml api-reference/speech/t2a/api/asyncapi.json t2a_v2_websocket
id: t2a_v2_websocket
title: T2a_v2_websocket
description: ''
servers:
  - id: production
    protocol: wss
    host: api.minimax.cn
    bindings: []
    variables: []
address: /ws/v1/t2a_v2
parameters: []
bindings: []
operations:
  - &ref_2
    id: sendMessage
    title: Send message
    description: ''
    type: receive
    messages:
      - &ref_4
        id: send_task_start
        contentType: application/json
        payload:
          - name: 任务开始
            description: |-
              发送`任务开始`事件则正式开始合成任务，当服务端返回的 `task_started` 事件时，标志着任务已成功开始。
              只有在接收到该事件后，才能向服务器发送 `task_continue` 事件或 `task_finish` 事件。
            type: object
            properties:
              - name: event
                type: string
                description: 控制发送的指令，当前环节应填写： `task_start`
                enumValues:
                  - task_start
                required: true
              - name: model
                type: string
                description: 请求的模型版本
                enumValues:
                  - speech-2.8-hd
                  - speech-2.8-turbo
                  - speech-2.6-hd
                  - speech-2.6-turbo
                  - speech-02-hd
                  - speech-02-turbo
                  - speech-01-hd
                  - speech-01-turbo
                required: true
              - name: voice_setting
                type: object
                required: true
                properties:
                  - name: voice_id
                    type: string
                    description: "合成音频的音色编号。若需要设置混合音色，请设置 timbre_weights 参数，本参数设置为空值。支持系统音色、复刻音色以及文生音色三种类型，以下是部分最新的系统音色（ID），可查看 [系统音色列表](/faq/system-voice-id) 或使用 [查询可用音色 API](/api-reference/voice-management-get) 查询系统支持的全部音色\n\n - **中文**:\n\t- moss_audio_ce44fc67-7ce3-11f0-8de5-96e35d26fb85\n\t- moss_audio_aaa1346a-7ce7-11f0-8e61-2e6e3c7ee85d\n\t- Chinese (Mandarin)_Lyrical_Voice\n\t- Chinese (Mandarin)_HK_Flight_Attendant\n- **英文**:\n\t- English_Graceful_Lady\n\t- English_Insightful_Speaker\n\t- English_radiant_girl\n\t- English_Persuasive_Man\n\t- moss_audio_6dc281eb-713c-11f0-a447-9613c873494c\n\t- moss_audio_570551b1-735c-11f0-b236-0adeeecad052\n\t- moss_audio_ad5baf92-735f-11f0-8263-fe5a2fe98ec8\n\t- English_Lucky_Robot\n- **日文**:\n\t- Japanese_Whisper_Belle\n\t- moss_audio_24875c4a-7be4-11f0-9359-4e72c55db738\n\t- moss_audio_7f4ee608-78ea-11f0-bb73-1e2a4cfcd245\n\t- moss_audio_c1a6a3ac-7be6-11f0-8e8e-36b92fbb4f95"
                    required: true
                  - name: speed
                    type: number
                    description: 合成音频的语速，取值越大，语速越快。取值范围 `[0.5,2]`，默认值为1.0
                    required: false
                  - name: vol
                    type: number
                    description: 合成音频的音量，取值越大，音量越高。取值范围 `(0,10]`，默认值为 1.0
                    required: false
                  - name: pitch
                    type: integer
                    description: 合成音频的语调，取值范围 `[-12,12]`，默认值为 0，其中 0 为原音色输出
                    required: false
                  - name: emotion
                    type: string
                    description: "控制合成语音的情绪，参数范围 `[\"happy\", \"sad\", \"angry\", \"fearful\", \"disgusted\", \"surprised\", \"calm\", \"fluent\", \"whisper\"]`，分别对应 8 种情绪：高兴，悲伤，愤怒，害怕，厌恶，惊讶，中性，生动，低语 \r\n- 模型会根据输入文本自动匹配合适的情绪，一般无需手动指定  \r\n- 该参数仅对 `speech-2.8-hd`, `speech-2.8-turbo`, `speech-2.6-hd`, `speech-2.6-turbo`, `speech-02-hd`, `speech-02-turbo`, `speech-01-hd`, `speech-01-turbo` 模型生效 \r\n- 选项 `fluent`, `whisper` 仅对 `speech-2.6-turbo`, `speech-2.6-hd` 模型生效，`speech-2.8-hd`, `speech-2.8-turbo` 模型不支持 `whisper`"
                    enumValues:
                      - happy
                      - sad
                      - angry
                      - fearful
                      - disgusted
                      - surprised
                      - calm
                      - fluent
                      - whisper
                    required: false
                  - name: english_normalization
                    type: boolean
                    description: >-
                      废弃参数，请使用 `task_start` 事件的一级参数
                      `text_normalization_mode`：本参数为 `true` 等价于
                      `text_normalization_mode=basic`；为 `false` 或不传等价于不传
                      `text_normalization_mode`。两者同时传入时以
                      `text_normalization_mode` 为准


                      该参数支持英语文本规范化，可提升数字阅读场景的性能，但会略微增加延迟，默认值为 `false`
                    deprecated: true
                    required: false
                  - name: text_normalization
                    type: boolean
                    description: >-
                      废弃参数，请使用 `task_start` 事件的一级参数
                      `text_normalization_mode`：本参数为 `true` 等价于
                      `text_normalization_mode=basic`；为 `false` 或不传等价于不传
                      `text_normalization_mode`。两者同时传入时以
                      `text_normalization_mode` 为准


                      是否启用中文、英语文本规范化，开启后可提升数字阅读场景的性能，但会略微增加延迟，默认值为 `false`。与
                      `english_normalization` 同时传入时以本参数为准
                    deprecated: true
                    required: false
                  - name: latex_read
                    type: boolean
                    description: >-
                      控制是否朗读 latex 公式，默认为 `false`

                      **需注意**:

                      - 仅支持中文，开启该参数后，`language_boost` 参数会被设置为 `Chinese`

                      - 请求中的公式需要在公式的首尾加上 `$$`

                      - 请求中公式若有 `"\"`，需转义成 `"\\"`.


                      示例：一元二次方程根的基本公式

                      ![The quadratic
                      formula](https://filecdn.minimax.chat/public/d6f62e9a-cd3f-4f55-a237-257eef531683.png)


                      应表示为 `$$x = \\frac{-b \\pm \\sqrt{b^2 - 4ac}}{2a}$$`
                    required: false
              - name: audio_setting
                type: object
                required: false
                properties:
                  - name: sample_rate
                    type: integer
                    description: >-
                      生成音频的采样率。可选范围 `[8000，16000，22050，24000，32000，44100]`，默认为
                      `32000`
                    required: false
                  - name: bitrate
                    type: integer
                    description: >-
                      生成音频的比特率。可选范围 `[32000，64000，128000，256000]`，默认值为
                      `128000`。该参数仅对 `mp3` 格式的音频生效
                    required: false
                  - name: format
                    type: string
                    description: >-
                      生成音频的格式。`pcmu_raw` 与 `pcmu_wav` 为 G.711 μ-law 编码（采样率 8
                      kHz；`pcmu_raw` 为无文件头裸数据，`pcmu_wav` 封装在 WAV 容器中）。`opus` 为
                      Ogg/Opus 编码；流式模式下音频 chunk 需按到达顺序拼接后再解码
                    enumValues:
                      - mp3
                      - pcm
                      - flac
                      - wav
                      - pcmu_raw
                      - pcmu_wav
                      - opus
                    required: false
                  - name: channel
                    type: integer
                    description: 生成音频的声道数。可选范围：`[1,2]`，其中 `1` 为单声道，`2` 为双声道，默认值为 1
                    required: false
              - name: pronunciation_dict
                type: object
                required: false
                properties:
                  - name: tone
                    type: array
                    description: |-
                      定义需要特殊标注的文字或符号对应的注音或发音替换规则。在中文文本中，声调用数字表示：
                      一声为 1，二声为 2，三声为 3，四声为 4，轻声为 5
                      示例如下：
                      `["燕少飞/(yan4)(shao3)(fei1)", "omg/oh my god"]`
                    required: false
                    properties:
                      - name: item
                        type: string
                        required: false
              - name: timbre_weights
                type: object
                required: false
                properties:
                  - name: voice_id
                    type: string
                    description: >-
                      合成音频的音色编号，须和weight参数同步填写。支持系统音色、复刻音色以及文生音色三种类型。系统支持的全部音色可查看
                      [系统音色列表](/faq/system-voice-id)，也可使用 [查询可用音色
                      API](/api-reference/voice-management-get) 查询系统支持的全部音色
                    required: false
                  - name: weight
                    type: integer
                    description: >-
                      合成音频各音色所占的权重，须与 voice_id 同步填写。可选值范围为[1, 100]，最多支持 4
                      种音色混合，单一音色取值占比越高，合成音色与该音色相似度越高.


                      ```json dark

                      "timbre_weights": [
                        {
                          "voice_id": "female-chengshu",
                          "weight": 30
                        },
                        {
                          "voice_id": "female-tianmei",
                          "weight": 70
                        }
                      ]

                      ```
                    required: false
              - name: language_boost
                type: string
                description: >-
                  是否增强对指定的小语种和方言的识别能力，设置后可以提升在指定小语种/方言场景下的语音表现。默认值为
                  `null`，如果不明确小语种类型，可设置为 `auto`，模型将自主判断小语种类型

                  可选值范围： 

                  [`Chinese`, `Chinese,Yue`, `English`, `Arabic`, `Russian`,
                  `Spanish`, `French`, `Portuguese`, `German`, `Turkish`,
                  `Dutch`, `Ukrainian`, `Vietnamese`, `Indonesian`, `Japanese`,
                  `Italian`, `Korean`, `Thai`, `Polish`, `Romanian`, `Greek`,
                  `Czech`, `Finnish`, `Hindi`, `Bulgarian`, `Danish`, `Hebrew`,
                  `Malay`, `Persian`, `Slovak`, `Swedish`, `Croatian`,
                  `Filipino`, `Hungarian`, `Norwegian`, `Slovenian`, `Catalan`,
                  `Nynorsk`, `Tamil`, `Afrikaans`, `auto`]


                  注意：speech-01 和 speech-02 系列模型暂不支持 Persian、Filipino、Tamil
                  这三个语种。
                enumValues:
                  - Chinese
                  - Chinese,Yue
                  - English
                  - Arabic
                  - Russian
                  - Spanish
                  - French
                  - Portuguese
                  - German
                  - Turkish
                  - Dutch
                  - Ukrainian
                  - Vietnamese
                  - Indonesian
                  - Japanese
                  - Italian
                  - Korean
                  - Thai
                  - Polish
                  - Romanian
                  - Greek
                  - Czech
                  - Finnish
                  - Hindi
                  - Bulgarian
                  - Danish
                  - Hebrew
                  - Malay
                  - Persian
                  - Slovak
                  - Swedish
                  - Croatian
                  - Filipino
                  - Hungarian
                  - Norwegian
                  - Slovenian
                  - Catalan
                  - Nynorsk
                  - Tamil
                  - Afrikaans
                  - auto
                required: false
              - name: text_normalization_mode
                type: string
                description: >-
                  文本归一化模式。`basic` 使用快速的规则归一化；`quality` 采用 LLM +
                  规则的混合方案，归一化质量更高，但会增加一定延迟。详见[文本归一化](/guides/speech-t2a-websocket#文本归一化)。


                  注意：

                  - `quality` 目前仅对非流式 HTTP 请求生效；WebSocket 为流式合成，传入 `quality` 时按
                  `basic` 处理，不会报错

                  - 传入本参数后，`voice_setting.text_normalization` 与
                  `voice_setting.english_normalization` 不再生效；不传时沿用这两个参数的设置（默认关闭）
                enumValues:
                  - basic
                  - quality
                required: false
              - name: voice_modify
                type: object
                description: 声音效果器设置
                required: false
                properties:
                  - name: pitch
                    type: integer
                    description: >-
                      音高调整（低沉/明亮），范围 [-100,100]，数值接近 -100，声音更低沉；接近 100，声音更明亮


                      ![pitch
                      adjustment](https://filecdn.minimax.chat/public/5d210c47-4236-4e81-893b-16cc1ef0302d.png)
                    required: false
                  - name: intensity
                    type: integer
                    description: >-
                      强度调整（力量感/柔和），范围 [-100,100]，数值接近 -100，声音更刚劲；接近 100，声音更轻柔


                      ![intensity
                      adjustment](https://filecdn.minimax.chat/public/862d493e-71d5-4d1f-b7c3-9ac51890631b.png)
                    required: false
                  - name: timbre
                    type: integer
                    description: >-
                      音色调整（磁性/清脆），范围 [-100,100]，数值接近 -100，声音更浑厚；数值接近 100，声音更清脆


                      ![timbre
                      adjustment](https://filecdn.minimax.chat/public/5f0e6cae-363a-452b-8d42-fbc4ef5a0510.png)
                    required: false
                  - name: sound_effects
                    type: string
                    description: |-
                      音效设置，单次仅能选择一种，可选值：
                      1. spacious_echo（空旷回音）
                      2. auditorium_echo（礼堂广播）
                      3. lofi_telephone（电话失真）
                      4. robotic（电音）
                    enumValues:
                      - spacious_echo
                      - auditorium_echo
                      - lofi_telephone
                      - robotic
                    required: false
              - name: subtitle_enable
                type: boolean
                description: >-
                  控制是否开启字幕服务，默认值为 `false`。仅对 `speech-2.8-hd`,
                  `speech-2.8-turbo`, `speech-2.6-hd`, `speech-2.6-turbo`,
                  `speech-02-hd`, `speech-02-turbo`, `speech-01-hd`,
                  `speech-01-turbo` 模型有效
                required: false
              - name: subtitle_type
                type: string
                description: >-
                  字幕粒度，默认值为 `sentence`。可选值：

                  - `sentence`：句级别时间戳

                  - `word`：词级别时间戳

                  - `word_streaming`：流式优化的词级别时间戳


                  字幕通过 `task_continued` 事件的 `data.subtitle` 随音频下发，不提供字幕文件：

                  - `sentence` / `word`：每个分段只在该分段最后一个音频片段中返回一次完整字幕，`sentence` 不含
                  `timestamped_words`

                  - `word_streaming`：每个音频片段都返回当前分段截至目前的累计字幕（`timestamped_words`
                  与 `time_end` 持续增长），客户端应以最新一条覆盖同一分段的旧结果；`text_begin`
                  变化表示进入下一个分段


                  `is_final` 为 `true` 的消息不含字幕，请在每条 `task_continued` 消息中检查
                  `data.subtitle`
                enumValues:
                  - sentence
                  - word
                  - word_streaming
                required: false
              - name: continuous_sound
                type: boolean
                description: |-
                  控制模型侧文本切分策略，仅对 `speech-2.8-hd`、`speech-2.8-turbo` 模型有效。
                  - `true`：模型侧不切分文本，连续推理生成音频（长文本韵律更自然）
                  - `false`：模型侧切分文本，并发推理生成音频（延迟更低）

                  默认值为 `false`
                required: false
        headers: []
        jsonPayloadSchema:
          type: object
          required:
            - event
            - model
            - voice_setting
          properties:
            event:
              type: string
              enum:
                - task_start
              default:
                - task_start
              description: 控制发送的指令，当前环节应填写： `task_start`
              x-parser-schema-id: <anonymous-schema-6>
            model:
              type: string
              description: 请求的模型版本
              enum:
                - speech-2.8-hd
                - speech-2.8-turbo
                - speech-2.6-hd
                - speech-2.6-turbo
                - speech-02-hd
                - speech-02-turbo
                - speech-01-hd
                - speech-01-turbo
              x-parser-schema-id: <anonymous-schema-7>
            voice_setting:
              type: object
              required:
                - voice_id
              properties:
                voice_id:
                  type: string
                  description: "合成音频的音色编号。若需要设置混合音色，请设置 timbre_weights 参数，本参数设置为空值。支持系统音色、复刻音色以及文生音色三种类型，以下是部分最新的系统音色（ID），可查看 [系统音色列表](/faq/system-voice-id) 或使用 [查询可用音色 API](/api-reference/voice-management-get) 查询系统支持的全部音色\n\n - **中文**:\n\t- moss_audio_ce44fc67-7ce3-11f0-8de5-96e35d26fb85\n\t- moss_audio_aaa1346a-7ce7-11f0-8e61-2e6e3c7ee85d\n\t- Chinese (Mandarin)_Lyrical_Voice\n\t- Chinese (Mandarin)_HK_Flight_Attendant\n- **英文**:\n\t- English_Graceful_Lady\n\t- English_Insightful_Speaker\n\t- English_radiant_girl\n\t- English_Persuasive_Man\n\t- moss_audio_6dc281eb-713c-11f0-a447-9613c873494c\n\t- moss_audio_570551b1-735c-11f0-b236-0adeeecad052\n\t- moss_audio_ad5baf92-735f-11f0-8263-fe5a2fe98ec8\n\t- English_Lucky_Robot\n- **日文**:\n\t- Japanese_Whisper_Belle\n\t- moss_audio_24875c4a-7be4-11f0-9359-4e72c55db738\n\t- moss_audio_7f4ee608-78ea-11f0-bb73-1e2a4cfcd245\n\t- moss_audio_c1a6a3ac-7be6-11f0-8e8e-36b92fbb4f95"
                  x-parser-schema-id: <anonymous-schema-8>
                speed:
                  type: number
                  format: float
                  description: 合成音频的语速，取值越大，语速越快。取值范围 `[0.5,2]`，默认值为1.0
                  minimum: 0.5
                  maximum: 2
                  default: 1
                  x-parser-schema-id: <anonymous-schema-9>
                vol:
                  type: number
                  format: float
                  description: 合成音频的音量，取值越大，音量越高。取值范围 `(0,10]`，默认值为 1.0
                  exclusiveMinimum: 0
                  maximum: 10
                  default: 1
                  x-parser-schema-id: <anonymous-schema-10>
                pitch:
                  type: integer
                  description: 合成音频的语调，取值范围 `[-12,12]`，默认值为 0，其中 0 为原音色输出
                  minimum: -12
                  maximum: 12
                  default: 0
                  x-parser-schema-id: <anonymous-schema-11>
                emotion:
                  type: string
                  description: "控制合成语音的情绪，参数范围 `[\"happy\", \"sad\", \"angry\", \"fearful\", \"disgusted\", \"surprised\", \"calm\", \"fluent\", \"whisper\"]`，分别对应 8 种情绪：高兴，悲伤，愤怒，害怕，厌恶，惊讶，中性，生动，低语 \r\n- 模型会根据输入文本自动匹配合适的情绪，一般无需手动指定  \r\n- 该参数仅对 `speech-2.8-hd`, `speech-2.8-turbo`, `speech-2.6-hd`, `speech-2.6-turbo`, `speech-02-hd`, `speech-02-turbo`, `speech-01-hd`, `speech-01-turbo` 模型生效 \r\n- 选项 `fluent`, `whisper` 仅对 `speech-2.6-turbo`, `speech-2.6-hd` 模型生效，`speech-2.8-hd`, `speech-2.8-turbo` 模型不支持 `whisper`"
                  enum:
                    - happy
                    - sad
                    - angry
                    - fearful
                    - disgusted
                    - surprised
                    - calm
                    - fluent
                    - whisper
                  x-parser-schema-id: <anonymous-schema-12>
                english_normalization:
                  type: boolean
                  description: >-
                    废弃参数，请使用 `task_start` 事件的一级参数 `text_normalization_mode`：本参数为
                    `true` 等价于 `text_normalization_mode=basic`；为 `false`
                    或不传等价于不传 `text_normalization_mode`。两者同时传入时以
                    `text_normalization_mode` 为准


                    该参数支持英语文本规范化，可提升数字阅读场景的性能，但会略微增加延迟，默认值为 `false`
                  default: false
                  deprecated: true
                  x-parser-schema-id: <anonymous-schema-13>
                text_normalization:
                  type: boolean
                  description: >-
                    废弃参数，请使用 `task_start` 事件的一级参数 `text_normalization_mode`：本参数为
                    `true` 等价于 `text_normalization_mode=basic`；为 `false`
                    或不传等价于不传 `text_normalization_mode`。两者同时传入时以
                    `text_normalization_mode` 为准


                    是否启用中文、英语文本规范化，开启后可提升数字阅读场景的性能，但会略微增加延迟，默认值为 `false`。与
                    `english_normalization` 同时传入时以本参数为准
                  default: false
                  deprecated: true
                  x-parser-schema-id: <anonymous-schema-14>
                latex_read:
                  type: boolean
                  description: >-
                    控制是否朗读 latex 公式，默认为 `false`

                    **需注意**:

                    - 仅支持中文，开启该参数后，`language_boost` 参数会被设置为 `Chinese`

                    - 请求中的公式需要在公式的首尾加上 `$$`

                    - 请求中公式若有 `"\"`，需转义成 `"\\"`.


                    示例：一元二次方程根的基本公式

                    ![The quadratic
                    formula](https://filecdn.minimax.chat/public/d6f62e9a-cd3f-4f55-a237-257eef531683.png)


                    应表示为 `$$x = \\frac{-b \\pm \\sqrt{b^2 - 4ac}}{2a}$$`
                  default: false
                  x-parser-schema-id: <anonymous-schema-15>
              x-parser-schema-id: VoiceSetting
            audio_setting:
              type: object
              properties:
                sample_rate:
                  type: integer
                  format: int64
                  description: >-
                    生成音频的采样率。可选范围 `[8000，16000，22050，24000，32000，44100]`，默认为
                    `32000`
                  x-parser-schema-id: <anonymous-schema-16>
                bitrate:
                  type: integer
                  format: int64
                  description: >-
                    生成音频的比特率。可选范围 `[32000，64000，128000，256000]`，默认值为
                    `128000`。该参数仅对 `mp3` 格式的音频生效
                  x-parser-schema-id: <anonymous-schema-17>
                format:
                  type: string
                  description: >-
                    生成音频的格式。`pcmu_raw` 与 `pcmu_wav` 为 G.711 μ-law 编码（采样率 8
                    kHz；`pcmu_raw` 为无文件头裸数据，`pcmu_wav` 封装在 WAV 容器中）。`opus` 为
                    Ogg/Opus 编码；流式模式下音频 chunk 需按到达顺序拼接后再解码
                  enum:
                    - mp3
                    - pcm
                    - flac
                    - wav
                    - pcmu_raw
                    - pcmu_wav
                    - opus
                  default: mp3
                  x-parser-schema-id: <anonymous-schema-18>
                channel:
                  type: integer
                  format: int64
                  description: 生成音频的声道数。可选范围：`[1,2]`，其中 `1` 为单声道，`2` 为双声道，默认值为 1
                  x-parser-schema-id: <anonymous-schema-19>
              x-parser-schema-id: AudioSetting
            pronunciation_dict:
              type: object
              properties:
                tone:
                  type: array
                  items:
                    type: string
                    x-parser-schema-id: <anonymous-schema-21>
                  description: |-
                    定义需要特殊标注的文字或符号对应的注音或发音替换规则。在中文文本中，声调用数字表示：
                    一声为 1，二声为 2，三声为 3，四声为 4，轻声为 5
                    示例如下：
                    `["燕少飞/(yan4)(shao3)(fei1)", "omg/oh my god"]`
                  x-parser-schema-id: <anonymous-schema-20>
              x-parser-schema-id: PronunciationDict
            timbre_weights:
              type: object
              properties:
                voice_id:
                  type: string
                  description: >-
                    合成音频的音色编号，须和weight参数同步填写。支持系统音色、复刻音色以及文生音色三种类型。系统支持的全部音色可查看
                    [系统音色列表](/faq/system-voice-id)，也可使用 [查询可用音色
                    API](/api-reference/voice-management-get) 查询系统支持的全部音色
                  x-parser-schema-id: <anonymous-schema-22>
                weight:
                  type: integer
                  format: int64
                  description: >-
                    合成音频各音色所占的权重，须与 voice_id 同步填写。可选值范围为[1, 100]，最多支持 4
                    种音色混合，单一音色取值占比越高，合成音色与该音色相似度越高.


                    ```json dark

                    "timbre_weights": [
                      {
                        "voice_id": "female-chengshu",
                        "weight": 30
                      },
                      {
                        "voice_id": "female-tianmei",
                        "weight": 70
                      }
                    ]

                    ```
                  minimum: 1
                  maximum: 100
                  x-parser-schema-id: <anonymous-schema-23>
              x-parser-schema-id: TimbreWeights
            language_boost:
              type: string
              description: >-
                是否增强对指定的小语种和方言的识别能力，设置后可以提升在指定小语种/方言场景下的语音表现。默认值为
                `null`，如果不明确小语种类型，可设置为 `auto`，模型将自主判断小语种类型

                可选值范围： 

                [`Chinese`, `Chinese,Yue`, `English`, `Arabic`, `Russian`,
                `Spanish`, `French`, `Portuguese`, `German`, `Turkish`, `Dutch`,
                `Ukrainian`, `Vietnamese`, `Indonesian`, `Japanese`, `Italian`,
                `Korean`, `Thai`, `Polish`, `Romanian`, `Greek`, `Czech`,
                `Finnish`, `Hindi`, `Bulgarian`, `Danish`, `Hebrew`, `Malay`,
                `Persian`, `Slovak`, `Swedish`, `Croatian`, `Filipino`,
                `Hungarian`, `Norwegian`, `Slovenian`, `Catalan`, `Nynorsk`,
                `Tamil`, `Afrikaans`, `auto`]


                注意：speech-01 和 speech-02 系列模型暂不支持 Persian、Filipino、Tamil 这三个语种。
              enum:
                - Chinese
                - Chinese,Yue
                - English
                - Arabic
                - Russian
                - Spanish
                - French
                - Portuguese
                - German
                - Turkish
                - Dutch
                - Ukrainian
                - Vietnamese
                - Indonesian
                - Japanese
                - Italian
                - Korean
                - Thai
                - Polish
                - Romanian
                - Greek
                - Czech
                - Finnish
                - Hindi
                - Bulgarian
                - Danish
                - Hebrew
                - Malay
                - Persian
                - Slovak
                - Swedish
                - Croatian
                - Filipino
                - Hungarian
                - Norwegian
                - Slovenian
                - Catalan
                - Nynorsk
                - Tamil
                - Afrikaans
                - auto
              x-parser-schema-id: <anonymous-schema-24>
            text_normalization_mode:
              type: string
              description: >-
                文本归一化模式。`basic` 使用快速的规则归一化；`quality` 采用 LLM +
                规则的混合方案，归一化质量更高，但会增加一定延迟。详见[文本归一化](/guides/speech-t2a-websocket#文本归一化)。


                注意：

                - `quality` 目前仅对非流式 HTTP 请求生效；WebSocket 为流式合成，传入 `quality` 时按
                `basic` 处理，不会报错

                - 传入本参数后，`voice_setting.text_normalization` 与
                `voice_setting.english_normalization` 不再生效；不传时沿用这两个参数的设置（默认关闭）
              enum:
                - basic
                - quality
              x-mint:
                post:
                  - updated
              x-parser-schema-id: <anonymous-schema-25>
            voice_modify:
              type: object
              description: 声音效果器设置
              properties:
                pitch:
                  type: integer
                  description: >-
                    音高调整（低沉/明亮），范围 [-100,100]，数值接近 -100，声音更低沉；接近 100，声音更明亮


                    ![pitch
                    adjustment](https://filecdn.minimax.chat/public/5d210c47-4236-4e81-893b-16cc1ef0302d.png)
                  minimum: -100
                  maximum: 100
                  x-parser-schema-id: <anonymous-schema-26>
                intensity:
                  type: integer
                  description: >-
                    强度调整（力量感/柔和），范围 [-100,100]，数值接近 -100，声音更刚劲；接近 100，声音更轻柔


                    ![intensity
                    adjustment](https://filecdn.minimax.chat/public/862d493e-71d5-4d1f-b7c3-9ac51890631b.png)
                  minimum: -100
                  maximum: 100
                  x-parser-schema-id: <anonymous-schema-27>
                timbre:
                  type: integer
                  description: >-
                    音色调整（磁性/清脆），范围 [-100,100]，数值接近 -100，声音更浑厚；数值接近 100，声音更清脆


                    ![timbre
                    adjustment](https://filecdn.minimax.chat/public/5f0e6cae-363a-452b-8d42-fbc4ef5a0510.png)
                  minimum: -100
                  maximum: 100
                  x-parser-schema-id: <anonymous-schema-28>
                sound_effects:
                  type: string
                  description: |-
                    音效设置，单次仅能选择一种，可选值：
                    1. spacious_echo（空旷回音）
                    2. auditorium_echo（礼堂广播）
                    3. lofi_telephone（电话失真）
                    4. robotic（电音）
                  enum:
                    - spacious_echo
                    - auditorium_echo
                    - lofi_telephone
                    - robotic
                  x-parser-schema-id: <anonymous-schema-29>
              x-parser-schema-id: VoiceModify
            subtitle_enable:
              type: boolean
              description: >-
                控制是否开启字幕服务，默认值为 `false`。仅对 `speech-2.8-hd`, `speech-2.8-turbo`,
                `speech-2.6-hd`, `speech-2.6-turbo`, `speech-02-hd`,
                `speech-02-turbo`, `speech-01-hd`, `speech-01-turbo` 模型有效
              default: false
              x-parser-schema-id: <anonymous-schema-30>
            subtitle_type:
              type: string
              description: >-
                字幕粒度，默认值为 `sentence`。可选值：

                - `sentence`：句级别时间戳

                - `word`：词级别时间戳

                - `word_streaming`：流式优化的词级别时间戳


                字幕通过 `task_continued` 事件的 `data.subtitle` 随音频下发，不提供字幕文件：

                - `sentence` / `word`：每个分段只在该分段最后一个音频片段中返回一次完整字幕，`sentence` 不含
                `timestamped_words`

                - `word_streaming`：每个音频片段都返回当前分段截至目前的累计字幕（`timestamped_words` 与
                `time_end` 持续增长），客户端应以最新一条覆盖同一分段的旧结果；`text_begin` 变化表示进入下一个分段


                `is_final` 为 `true` 的消息不含字幕，请在每条 `task_continued` 消息中检查
                `data.subtitle`
              enum:
                - sentence
                - word
                - word_streaming
              default: sentence
              x-parser-schema-id: <anonymous-schema-31>
            continuous_sound:
              type: boolean
              description: |-
                控制模型侧文本切分策略，仅对 `speech-2.8-hd`、`speech-2.8-turbo` 模型有效。
                - `true`：模型侧不切分文本，连续推理生成音频（长文本韵律更自然）
                - `false`：模型侧切分文本，并发推理生成音频（延迟更低）

                默认值为 `false`
              default: false
              x-parser-schema-id: <anonymous-schema-32>
          x-parser-schema-id: SendTaskStartEvent
        title: 任务开始
        description: |-
          发送`任务开始`事件则正式开始合成任务，当服务端返回的 `task_started` 事件时，标志着任务已成功开始。
          只有在接收到该事件后，才能向服务器发送 `task_continue` 事件或 `task_finish` 事件。
        example: |-
          {
            "event": "task_start",
            "model": "speech-2.8-turbo",
            "language_boost": "Chinese",
            "voice_setting": {
              "voice_id": "male-qn-qingse",
              "speed": 1,
              "vol": 1,
              "pitch": 0
            },
            "pronunciation_dict": {
              "tone": [
                "处理/(chu3)(li3)",
                "危险/dangerous"
              ]
            },
            "audio_setting": {
              "sample_rate": 32000,
              "bitrate": 128000,
              "format": "mp3",
              "channel": 1
            }
          }
        bindings: []
        extensions:
          - id: x-parser-unique-object-id
            value: send_task_start
      - &ref_5
        id: send_task_continue
        contentType: application/json
        payload:
          - name: 任务继续
            description: >-
              当收到服务端返回的 `task_started` 事件后，任务正式开始，可通过发送 `task_continue`
              事件发送要合成的文本，支持顺序发送多个 `task_continue` 事件。

              当最后一次收到服务端返回结果后超过 120s 没有发送新事件时，webSocket 连接自动断开。
            type: object
            properties:
              - name: event
                type: string
                description: 表示会话事件类型，当前环节应填写 `task_continue`
                enumValues:
                  - task_continue
                required: true
              - name: text
                type: string
                description: >-
                  需要合成语音的文本，长度限制小于 10,000 字符

                  - 段落切换用换行符标记

                  - 停顿控制：支持自定义文本之间的语音时间间隔。使用方式：在文本中增加 `<#x#>` 标记，`x`
                  为停顿时长（单位：秒），范围 **[0.01,
                  99.99]**，最多保留两位小数。文本间隔时间需设置在两个可以语音发音的文本之间，不可连续使用多个停顿标记

                  - 语气词标签：仅当模型选择 `speech-2.8-hd` 或 `speech-2.8-turbo`
                  时，支持在文本中插入语气词标签。支持的语气词：`(laughs)`（笑声）、`(chuckle)`（轻笑）、`(coughs)`（咳嗽）、`(clear-throat)`（清嗓子）、`(groans)`（呻吟）、`(breath)`（正常换气）、`(pant)`（喘气）、`(inhale)`（吸气）、`(exhale)`（呼气）、`(gasps)`（倒吸气）、`(sniffs)`（吸鼻子）、`(sighs)`（叹气）、`(snorts)`（喷鼻息）、`(burps)`（打嗝）、`(lip-smacking)`（咂嘴）、`(humming)`（哼唱）、`(hissing)`（嘶嘶声）、`(emm)`（嗯）、`(sneezes)`（喷嚏）
                required: true
        headers: []
        jsonPayloadSchema:
          type: object
          required:
            - event
            - text
          properties:
            event:
              type: string
              description: 表示会话事件类型，当前环节应填写 `task_continue`
              enum:
                - task_continue
              default:
                - task_continue
              x-parser-schema-id: <anonymous-schema-38>
            text:
              type: string
              description: >-
                需要合成语音的文本，长度限制小于 10,000 字符

                - 段落切换用换行符标记

                - 停顿控制：支持自定义文本之间的语音时间间隔。使用方式：在文本中增加 `<#x#>` 标记，`x`
                为停顿时长（单位：秒），范围 **[0.01,
                99.99]**，最多保留两位小数。文本间隔时间需设置在两个可以语音发音的文本之间，不可连续使用多个停顿标记

                - 语气词标签：仅当模型选择 `speech-2.8-hd` 或 `speech-2.8-turbo`
                时，支持在文本中插入语气词标签。支持的语气词：`(laughs)`（笑声）、`(chuckle)`（轻笑）、`(coughs)`（咳嗽）、`(clear-throat)`（清嗓子）、`(groans)`（呻吟）、`(breath)`（正常换气）、`(pant)`（喘气）、`(inhale)`（吸气）、`(exhale)`（呼气）、`(gasps)`（倒吸气）、`(sniffs)`（吸鼻子）、`(sighs)`（叹气）、`(snorts)`（喷鼻息）、`(burps)`（打嗝）、`(lip-smacking)`（咂嘴）、`(humming)`（哼唱）、`(hissing)`（嘶嘶声）、`(emm)`（嗯）、`(sneezes)`（喷嚏）
              x-parser-schema-id: <anonymous-schema-39>
          x-parser-schema-id: SendTaskContinueEvent
        title: 任务继续
        description: >-
          当收到服务端返回的 `task_started` 事件后，任务正式开始，可通过发送 `task_continue`
          事件发送要合成的文本，支持顺序发送多个 `task_continue` 事件。

          当最后一次收到服务端返回结果后超过 120s 没有发送新事件时，webSocket 连接自动断开。
        example: |-
          {
            "event": "task_continue",
            "text": "真正的危险不是计算机开始像人一样思考(sighs)，而是人开始像计算机一样思考。计算机只是可以帮我们处理一些简单事务。"
          }
        bindings: []
        extensions:
          - id: x-parser-unique-object-id
            value: send_task_continue
      - &ref_6
        id: send_task_finish
        contentType: application/json
        payload:
          - name: 任务结束
            description: 服务端收到 `task_finish` 事件后，会等待当前队列中所有合成任务完成后，关闭 WebSocket 连接并结束任务。
            type: object
            properties:
              - name: event
                type: string
                description: 表示会话事件类型，当前环节应填写 `task_finish`
                enumValues:
                  - task_finish
                required: true
        headers: []
        jsonPayloadSchema:
          type: object
          required:
            - event
          properties:
            event:
              type: string
              enum:
                - task_finish
              default:
                - task_finish
              description: 表示会话事件类型，当前环节应填写 `task_finish`
              x-parser-schema-id: <anonymous-schema-71>
          x-parser-schema-id: SendTaskFinishEvent
        title: 任务结束
        description: 服务端收到 `task_finish` 事件后，会等待当前队列中所有合成任务完成后，关闭 WebSocket 连接并结束任务。
        example: |-
          {
            "event": "task_finish"
          }
        bindings: []
        extensions:
          - id: x-parser-unique-object-id
            value: send_task_finish
    bindings: []
    extensions: &ref_1
      - id: x-parser-unique-object-id
        value: t2a_v2_websocket
  - &ref_3
    id: receiveMessage
    title: Receive message
    type: send
    messages:
      - &ref_7
        id: receive_connected_success
        contentType: application/json
        payload:
          - name: 建连成功
            description: 成功建立连接后会返回 `connected_success` 事件
            type: object
            properties:
              - name: session_id
                type: string
                description: 表示整个会话的 id
                required: false
              - name: event
                type: string
                description: 表示会话事件类型，建连成功后会返回`connected_success`
                required: false
              - name: trace_id
                type: string
                description: 表示会话中单次请求的 id，用于在咨询/反馈时帮助定位问题
                required: false
              - name: base_resp
                type: object
                required: false
                properties:
                  - name: status_code
                    type: integer
                    description: |-
                      状态码，`0`代表建连成功.
                      更多状态码信息请参考 [错误码查询列表](/api-reference/errorcode)
                    required: false
                  - name: status_msg
                    type: string
                    description: 该请求对应的状态码和详情
                    required: false
        headers: []
        jsonPayloadSchema:
          type: object
          properties:
            session_id:
              type: string
              description: 表示整个会话的 id
              x-parser-schema-id: <anonymous-schema-1>
            event:
              type: string
              const: connected_success
              description: 表示会话事件类型，建连成功后会返回`connected_success`
              x-parser-schema-id: <anonymous-schema-2>
            trace_id:
              type: string
              description: 表示会话中单次请求的 id，用于在咨询/反馈时帮助定位问题
              x-parser-schema-id: <anonymous-schema-3>
            base_resp:
              type: object
              properties:
                status_code:
                  type: integer
                  description: |-
                    状态码，`0`代表建连成功.
                    更多状态码信息请参考 [错误码查询列表](/api-reference/errorcode)
                  x-parser-schema-id: <anonymous-schema-4>
                status_msg:
                  type: string
                  description: 该请求对应的状态码和详情
                  x-parser-schema-id: <anonymous-schema-5>
              x-parser-schema-id: BaseResp
          x-parser-schema-id: ReceiveConnectedSuccessEvent
        title: 建连成功
        description: 成功建立连接后会返回 `connected_success` 事件
        example: |-
          {
            "session_id": "xxxx",
            "event": "connected_success",
            "trace_id": "0303a2882bf18235ae7a809ae0f3cca7",
            "base_resp": {
              "status_code": 0,
              "status_msg": "success"
            }
          }
        bindings: []
        extensions:
          - id: x-parser-unique-object-id
            value: receive_connected_success
      - &ref_8
        id: receive_task_started
        contentType: application/json
        payload:
          - name: 任务开始
            description: 服务端返回 `task_started` 事件，标志着任务已成功开始
            type: object
            properties:
              - name: session_id
                type: string
                description: 表示整个会话的 id
                required: false
              - name: event
                type: string
                description: 表示会话事件类型，当前环节成功后会返回 `task_started`
                required: false
              - name: trace_id
                type: string
                description: 表示会话中单次请求的 id，用于在咨询/反馈时帮助定位问题
                required: false
              - name: base_resp
                type: object
                description: 该请求对应的状态码和详情
                required: false
                properties:
                  - name: status_code
                    type: integer
                    description: |-
                      状态码。
                      - 0: 表示发送成功
                      - 2202: 表示非法事件
                      更多内容可查看 [错误码查询列表](/api-reference/errorcode) 了解详情
                    required: false
                  - name: status_msg
                    type: string
                    description: 状态详情
                    required: false
        headers: []
        jsonPayloadSchema:
          type: object
          properties:
            session_id:
              type: string
              description: 表示整个会话的 id
              x-parser-schema-id: <anonymous-schema-33>
            event:
              type: string
              const: 表示会话事件类型，当前环节成功后会返回 `task_started`
              x-parser-schema-id: <anonymous-schema-34>
            trace_id:
              type: string
              description: 表示会话中单次请求的 id，用于在咨询/反馈时帮助定位问题
              x-parser-schema-id: <anonymous-schema-35>
            base_resp: &ref_0
              type: object
              description: 该请求对应的状态码和详情
              properties:
                status_code:
                  type: integer
                  description: |-
                    状态码。
                    - 0: 表示发送成功
                    - 2202: 表示非法事件
                    更多内容可查看 [错误码查询列表](/api-reference/errorcode) 了解详情
                  x-parser-schema-id: <anonymous-schema-36>
                status_msg:
                  type: string
                  description: 状态详情
                  x-parser-schema-id: <anonymous-schema-37>
              x-parser-schema-id: TaskStartFinishBaseResp
          x-parser-schema-id: ReceiveTaskStartedEvent
        title: 任务开始
        description: 服务端返回 `task_started` 事件，标志着任务已成功开始
        example: |-
          {
            "session_id": "xxxx",
            "event": "task_started",
            "trace_id": "0303a2882bf18235ae7a809ae0f3cca7",
            "base_resp": {
              "status_code": 0,
              "status_msg": "success"
            }
          }
        bindings: []
        extensions:
          - id: x-parser-unique-object-id
            value: receive_task_started
      - &ref_9
        id: receive_task_continued
        contentType: application/json
        payload:
          - name: 任务继续
            description: 服务端返回 `task_continued` 事件，标志着任务已成功继续
            type: object
            properties:
              - name: data
                type: object
                description: '`data` 可能返回为 `null`，参考示例代码时，注意进行非空判断'
                required: false
                properties:
                  - name: audio
                    type: string
                    description: 合成后的音频片段，采用 `hex` 编码，按照输入定义的格式进行生成（mp3/pcm/flac）
                    required: false
                  - name: subtitle
                    type: object
                    description: >-
                      开启字幕时返回，携带当前分段的字幕，随对应的音频片段下发，返回时机见 `task_start` 的
                      `subtitle_type`。`is_final` 为 `true` 的消息不含该字段
                    required: false
                    properties:
                      - name: text
                        type: string
                        description: 分段文本
                        required: false
                      - name: text_begin
                        type: integer
                        description: 分段在本次合成文本中的起始字符位置（含）
                        required: false
                      - name: text_end
                        type: integer
                        description: 分段在本次合成文本中的结束字符位置（不含）
                        required: false
                      - name: time_begin
                        type: number
                        description: 分段起始时间，单位毫秒，相对本次合成音频的起点
                        required: false
                      - name: time_end
                        type: number
                        description: 分段结束时间，单位毫秒，相对本次合成音频的起点
                        required: false
                      - name: timestamped_words
                        type: array
                        description: >-
                          词级时间戳，仅 `subtitle_type` 为 `word` / `word_streaming`
                          时返回，`sentence` 时为 `null`
                        required: false
                        properties:
                          - name: word
                            type: string
                            description: 词文本
                            required: false
                          - name: word_begin
                            type: integer
                            description: 该词在本次合成文本中的起始字符位置（含）
                            required: false
                          - name: word_end
                            type: integer
                            description: 该词在本次合成文本中的结束字符位置（不含）
                            required: false
                          - name: time_begin
                            type: number
                            description: 该词起始时间，单位毫秒
                            required: false
                          - name: time_end
                            type: number
                            description: 该词结束时间，单位毫秒
                            required: false
              - name: trace_id
                type: string
                description: 表示会话中单次请求的 id，用于在咨询/反馈时帮助定位问题。
                required: false
              - name: session_id
                type: string
                description: 表示整个会话的 id。
                required: false
              - name: event
                type: string
                description: 表示会话类型，当前环节成功后会返回 task_continued`
                required: false
              - name: is_final
                type: boolean
                description: 该请求返回是否完结
                required: false
              - name: extra_info
                type: object
                description: 相关额外信息
                required: false
                properties:
                  - name: audio_length
                    type: integer
                    description: 音频时长，精确到毫秒
                    required: false
                  - name: audio_sample_rate
                    type: integer
                    description: 音频采样率
                    required: false
                  - name: audio_size
                    type: integer
                    description: 音频文件大小，单位为字节
                    required: false
                  - name: bitrate
                    type: integer
                    description: 音频比特率
                    required: false
                  - name: audio_format
                    type: string
                    description: 生成音频文件的格式。取值范围 mp3/pcm/flac
                    required: false
                  - name: audio_channel
                    type: integer
                    description: 生成音频声道数。1：单声道，2：双声道
                    required: false
                  - name: invisible_character_ratio
                    type: integer
                    description: 非法字符占比。非法字符不超过 10%（包含 10%），音频会正常生成并返回非法字符占比，超过进行报错
                    required: false
                  - name: usage_characters
                    type: integer
                    description: 计费字符数。本次语音生成的计费字符数
                    required: false
                  - name: usage_voice_count
                    type: integer
                    description: 本次请求计费的音色数量（音色首次使用时计费），仅在产生音色费用时返回
                    required: false
                  - name: word_count
                    type: integer
                    description: 合成文本的字符数（含标点和空格），仅供参考，不用于计费；计费字符数请以 `usage_characters` 为准
                    required: false
              - name: base_resp
                type: object
                description: 本次请求的状态码和详情
                required: false
                properties:
                  - name: status_code
                    type: integer
                    description: |-
                      状态码
                      - 0: 请求结果正常
                      - 1000: 未知错误
                      - 1001: 请求超时
                      - 1002: 触发限流
                      - 1004: 鉴权失败
                      - 1039: 触发 TPM 限流
                      - 1042: 非法字符超过 10%
                      - 2013: 输入参数信息不正常
                      - 2201: 超时断开连接
                      - 2202: 非法事件
                      - 2203: 空文本，跳过
                      - 2204: 超出字符限制，跳过
                      - 2205: 请求超限
                      更多内容可查看 [错误码查询列表](/api-reference/errorcode) 了解详情
                    required: false
                  - name: status_msg
                    type: string
                    description: 状态详情
                    required: false
        headers: []
        jsonPayloadSchema:
          type: object
          properties:
            data:
              type: object
              description: '`data` 可能返回为 `null`，参考示例代码时，注意进行非空判断'
              properties:
                audio:
                  type: string
                  description: 合成后的音频片段，采用 `hex` 编码，按照输入定义的格式进行生成（mp3/pcm/flac）
                  x-parser-schema-id: <anonymous-schema-41>
                subtitle:
                  type: object
                  description: >-
                    开启字幕时返回，携带当前分段的字幕，随对应的音频片段下发，返回时机见 `task_start` 的
                    `subtitle_type`。`is_final` 为 `true` 的消息不含该字段
                  properties:
                    text:
                      type: string
                      description: 分段文本
                      x-parser-schema-id: <anonymous-schema-43>
                    text_begin:
                      type: integer
                      format: int64
                      description: 分段在本次合成文本中的起始字符位置（含）
                      x-parser-schema-id: <anonymous-schema-44>
                    text_end:
                      type: integer
                      format: int64
                      description: 分段在本次合成文本中的结束字符位置（不含）
                      x-parser-schema-id: <anonymous-schema-45>
                    time_begin:
                      type: number
                      description: 分段起始时间，单位毫秒，相对本次合成音频的起点
                      x-parser-schema-id: <anonymous-schema-46>
                    time_end:
                      type: number
                      description: 分段结束时间，单位毫秒，相对本次合成音频的起点
                      x-parser-schema-id: <anonymous-schema-47>
                    timestamped_words:
                      type: array
                      description: >-
                        词级时间戳，仅 `subtitle_type` 为 `word` / `word_streaming`
                        时返回，`sentence` 时为 `null`
                      items:
                        type: object
                        properties:
                          word:
                            type: string
                            description: 词文本
                            x-parser-schema-id: <anonymous-schema-50>
                          word_begin:
                            type: integer
                            format: int64
                            description: 该词在本次合成文本中的起始字符位置（含）
                            x-parser-schema-id: <anonymous-schema-51>
                          word_end:
                            type: integer
                            format: int64
                            description: 该词在本次合成文本中的结束字符位置（不含）
                            x-parser-schema-id: <anonymous-schema-52>
                          time_begin:
                            type: number
                            description: 该词起始时间，单位毫秒
                            x-parser-schema-id: <anonymous-schema-53>
                          time_end:
                            type: number
                            description: 该词结束时间，单位毫秒
                            x-parser-schema-id: <anonymous-schema-54>
                        x-parser-schema-id: <anonymous-schema-49>
                      x-parser-schema-id: <anonymous-schema-48>
                  x-parser-schema-id: <anonymous-schema-42>
              x-parser-schema-id: <anonymous-schema-40>
            trace_id:
              type: string
              description: 表示会话中单次请求的 id，用于在咨询/反馈时帮助定位问题。
              x-parser-schema-id: <anonymous-schema-55>
            session_id:
              type: string
              description: 表示整个会话的 id。
              x-parser-schema-id: <anonymous-schema-56>
            event:
              type: string
              description: 表示会话类型，当前环节成功后会返回 task_continued`
              x-parser-schema-id: <anonymous-schema-57>
            is_final:
              type: boolean
              description: 该请求返回是否完结
              x-parser-schema-id: <anonymous-schema-58>
            extra_info:
              type: object
              description: 相关额外信息
              properties:
                audio_length:
                  type: integer
                  format: int64
                  description: 音频时长，精确到毫秒
                  x-parser-schema-id: <anonymous-schema-59>
                audio_sample_rate:
                  type: integer
                  format: int64
                  description: 音频采样率
                  x-parser-schema-id: <anonymous-schema-60>
                audio_size:
                  type: integer
                  format: int64
                  description: 音频文件大小，单位为字节
                  x-parser-schema-id: <anonymous-schema-61>
                bitrate:
                  type: integer
                  format: int64
                  description: 音频比特率
                  x-parser-schema-id: <anonymous-schema-62>
                audio_format:
                  type: string
                  description: 生成音频文件的格式。取值范围 mp3/pcm/flac
                  x-parser-schema-id: <anonymous-schema-63>
                audio_channel:
                  type: integer
                  format: int64
                  description: 生成音频声道数。1：单声道，2：双声道
                  x-parser-schema-id: <anonymous-schema-64>
                invisible_character_ratio:
                  type: integer
                  format: float
                  description: 非法字符占比。非法字符不超过 10%（包含 10%），音频会正常生成并返回非法字符占比，超过进行报错
                  x-parser-schema-id: <anonymous-schema-65>
                usage_characters:
                  type: integer
                  format: int64
                  description: 计费字符数。本次语音生成的计费字符数
                  x-parser-schema-id: <anonymous-schema-66>
                usage_voice_count:
                  type: integer
                  format: int64
                  description: 本次请求计费的音色数量（音色首次使用时计费），仅在产生音色费用时返回
                  x-parser-schema-id: <anonymous-schema-67>
                word_count:
                  type: integer
                  format: int64
                  description: 合成文本的字符数（含标点和空格），仅供参考，不用于计费；计费字符数请以 `usage_characters` 为准
                  x-parser-schema-id: <anonymous-schema-68>
              x-parser-schema-id: ExtraInfo
            base_resp:
              type: object
              description: 本次请求的状态码和详情
              properties:
                status_code:
                  type: integer
                  description: |-
                    状态码
                    - 0: 请求结果正常
                    - 1000: 未知错误
                    - 1001: 请求超时
                    - 1002: 触发限流
                    - 1004: 鉴权失败
                    - 1039: 触发 TPM 限流
                    - 1042: 非法字符超过 10%
                    - 2013: 输入参数信息不正常
                    - 2201: 超时断开连接
                    - 2202: 非法事件
                    - 2203: 空文本，跳过
                    - 2204: 超出字符限制，跳过
                    - 2205: 请求超限
                    更多内容可查看 [错误码查询列表](/api-reference/errorcode) 了解详情
                  x-parser-schema-id: <anonymous-schema-69>
                status_msg:
                  type: string
                  description: 状态详情
                  x-parser-schema-id: <anonymous-schema-70>
              x-parser-schema-id: TaskContinueBaseResp
          x-parser-schema-id: ReceiveTaskContinuedEvent
        title: 任务继续
        description: 服务端返回 `task_continued` 事件，标志着任务已成功继续
        example: |-
          {
            "data": {
              "audio": "xxx"
            },
            "extra_info": {
              "audio_channel": 1,
              "audio_format": "mp3",
              "audio_length": 9914,
              "audio_sample_rate": 32000,
              "audio_size": 157869,
              "bitrate": 128000,
              "invisible_character_ratio": 0,
              "usage_characters": 158,
              "word_count": 158
            },
            "is_final": true,
            "session_id": "301871346491491",
            "trace_id": "04ee3794e2c9e4a6d5f99e77742f06fd",
            "base_resp": {
              "status_code": 0,
              "status_msg": "success"
            }
          }
        bindings: []
        extensions:
          - id: x-parser-unique-object-id
            value: receive_task_continued
      - &ref_10
        id: receive_task_finished
        contentType: application/json
        payload:
          - name: 任务结束
            description: 服务端返回 `task_finished` 事件，标志着任务已成功结束
            type: object
            properties:
              - name: trace_id
                type: string
                description: 表示会话中单次请求的 id，用于在咨询/反馈时帮助定位问题
                required: false
              - name: session_id
                type: string
                description: 表示整个会话的 id
                required: false
              - name: event
                type: string
                description: 表示会话类型，当前环节成功后会返回 `task_finished`
                required: false
              - name: base_resp
                type: object
                description: 该请求对应的状态码和详情
                required: false
                properties:
                  - name: status_code
                    type: integer
                    description: |-
                      状态码。
                      - 0: 表示发送成功
                      - 2202: 表示非法事件
                      更多内容可查看 [错误码查询列表](/api-reference/errorcode) 了解详情
                    required: false
                  - name: status_msg
                    type: string
                    description: 状态详情
                    required: false
        headers: []
        jsonPayloadSchema:
          type: object
          properties:
            trace_id:
              type: string
              description: 表示会话中单次请求的 id，用于在咨询/反馈时帮助定位问题
              x-parser-schema-id: <anonymous-schema-72>
            session_id:
              type: string
              description: 表示整个会话的 id
              x-parser-schema-id: <anonymous-schema-73>
            event:
              type: string
              description: 表示会话类型，当前环节成功后会返回 `task_finished`
              x-parser-schema-id: <anonymous-schema-74>
            base_resp: *ref_0
          x-parser-schema-id: ReceiveTaskFinishedEvent
        title: 任务结束
        description: 服务端返回 `task_finished` 事件，标志着任务已成功结束
        example: |-
          {
            "session_id": "xxxx",
            "event": "task_finished",
            "trace_id": "0303a2882bf18235ae7a809ae0f3cca7",
            "base_resp": {
              "status_code": 0,
              "status_msg": "success"
            }
          }
        bindings: []
        extensions:
          - id: x-parser-unique-object-id
            value: receive_task_finished
      - &ref_11
        id: receive_task_failed
        contentType: application/json
        payload:
          - name: 任务失败
            description: 如果接收到 `task_failed` 事件，表示任务失败。此时需要关闭 WebSocket 连接并处理错误。
            type: object
            properties:
              - name: trace_id
                type: string
                description: 表示会话中单次请求的 id，用于在咨询/反馈时帮助定位问题
                required: false
              - name: session_id
                type: string
                description: 表示整个会话的 id
                required: false
              - name: event
                type: string
                description: 表示会话类型，任务失败会返回 `task_failed`
                required: false
              - name: base_resp
                type: object
                description: 本次请求的状态码和详情
                required: false
                properties:
                  - name: status_code
                    type: integer
                    description: |-
                      状态码
                      - `1000`: 未知错误
                      - `1001`: 超时
                      - `1002`: 触发限流
                      - `1004`: 鉴权失败
                      - `1039`: 触发 TPM 限流
                      - `1042`: 非法字符超过 10%
                      - `2013`: 输入参数信息不正常
                      - `2201`: 超时断开连接
                      更多内容可查看 [错误码查询列表](/api-reference/errorcode) 了解详情
                    required: false
                  - name: status_msg
                    type: string
                    description: 状态详情
                    required: false
        headers: []
        jsonPayloadSchema:
          type: object
          properties:
            trace_id:
              type: string
              description: 表示会话中单次请求的 id，用于在咨询/反馈时帮助定位问题
              x-parser-schema-id: <anonymous-schema-75>
            session_id:
              type: string
              description: 表示整个会话的 id
              x-parser-schema-id: <anonymous-schema-76>
            event:
              type: string
              description: 表示会话类型，任务失败会返回 `task_failed`
              x-parser-schema-id: <anonymous-schema-77>
            base_resp:
              type: object
              description: 本次请求的状态码和详情
              properties:
                status_code:
                  type: integer
                  description: |-
                    状态码
                    - `1000`: 未知错误
                    - `1001`: 超时
                    - `1002`: 触发限流
                    - `1004`: 鉴权失败
                    - `1039`: 触发 TPM 限流
                    - `1042`: 非法字符超过 10%
                    - `2013`: 输入参数信息不正常
                    - `2201`: 超时断开连接
                    更多内容可查看 [错误码查询列表](/api-reference/errorcode) 了解详情
                  x-parser-schema-id: <anonymous-schema-78>
                status_msg:
                  type: string
                  description: 状态详情
                  x-parser-schema-id: <anonymous-schema-79>
              x-parser-schema-id: TaskFailedBaseResp
          x-parser-schema-id: ReceiveTaskFailedEvent
        title: 任务失败
        description: 如果接收到 `task_failed` 事件，表示任务失败。此时需要关闭 WebSocket 连接并处理错误。
        example: |-
          {
            "session_id": "xxxx",
            "event": "task_failed",
            "trace_id": "0303a2882bf18235ae7a809ae0f3cca7",
            "base_resp": {
              "status_code": 1004,
              "status_msg": "XXXXXXX"
            }
          }
        bindings: []
        extensions:
          - id: x-parser-unique-object-id
            value: receive_task_failed
    bindings: []
    extensions: *ref_1
sendOperations:
  - *ref_2
receiveOperations:
  - *ref_3
sendMessages:
  - *ref_4
  - *ref_5
  - *ref_6
receiveMessages:
  - *ref_7
  - *ref_8
  - *ref_9
  - *ref_10
  - *ref_11
extensions:
  - id: x-parser-unique-object-id
    value: t2a_v2_websocket
securitySchemes: []

````

> ## Documentation Index
> Fetch the complete documentation index at: https://platform.minimaxi.com/docs/llms.txt
> Use this file to discover all available pages before exploring further.

# 双向流式语音合成

> 通过 WebSocket 连接按任意粒度（含逐字）流式发送文本，由服务端自动攒句合成，适合对接大模型流式输出。

## 与 `/ws/v1/t2a_v2` 的区别

本接口面向**文本流式输入**场景：把大模型的流式输出直接逐 token 转成语音。

| | [`/ws/v1/t2a_v2`](/docs/api-reference/speech-t2a-websocket) | `/ws/v1/t2a_v2_bidi`（本接口） |
| - | - | - |
| 攒句责任 | **客户端**自行判断句子边界 | **服务端**自动攒句 |
| 逐字发送文本 | 每个字触发一次合成，音频碎裂 | 攒成完整句子后再合成 |
| 打断 | 不支持，只能断开连接 | `task_cancel`，打断后可继续 |
| 句边界事件 | 无 | `sentence_start` / `sentence_end` |
| `task_finish` | 立即关闭连接 | 先合成缓冲区残留再关闭 |
| 催出残留但不结束会话 | 无 | `task_flush` |

`task_start` 的音色、音频、发音字典等参数与 `/ws/v1/t2a_v2` **完全一致**，已有接入可直接复用。

## 事件流程

1. 建立连接，收到 `connected_success`
2. 发送 `task_start`，收到 `task_started`
3. 发送 `task_continue`（**可按任意粒度，包括单个字符**），服务端攒句后开始合成
   * 每句合成开始返回 `sentence_start`
   * 音频通过 `task_continued` 分块返回
   * 该句结束返回 `sentence_end`
4. 需要打断时发送 `task_cancel`，收到 `task_canceled` 后可继续发送 `task_continue`
5. 一轮说完、希望立刻拿到尾句音频时发送 `task_flush`，收到 `task_flushed` 后会话继续
6. 发送 `task_finish`，服务端合成完残留文本后返回 `task_finished` 并关闭连接

<Note>
  三层结束语义不要混用：`is_final` 表示本次请求的音频结束，`sentence_end` 表示当前句结束，`task_finished` 表示整个会话结束。
</Note>

<Note>
  一条连接同时只能有一个合成会话。任务已开始后重复发送 `task_start` 会返回 `2206`（事件顺序非法）并关闭连接。
</Note>

## 攒句与延迟

服务端按标点判断句子边界，因此**你发送的文本中的标点会直接影响音频的自然度**：

| 文本情况 | 服务端行为 |
| - | - |
| 以句末标点（`。！？…!?.` 及换行）结尾 | **立即**送去合成，不引入额外延迟 |
| 出现次级标点（`，、；：,;:`） | 已攒文本达到一定长度才切句，避免切出过短的碎片 |
| 长文本完全没有标点 | 达到长度上限时强制切断，此时句边界与语义无关，听感会断裂 |
| 尾部不带标点，但已攒够长度 | 等待一个短暂的静默窗口后兜底送出 |
| 尾部不带标点且很短 | **继续等待**，不会为了低延迟把半个词送去合成 |

<Warning>
  最后一条对多轮对话场景有实际影响。

  如果一轮说完时残留的文本既很短、又不带句末标点，它不会被那个短静默窗口立刻送出，而要等一个更长的兜底窗口。有两个办法避免这段等待：**给最后一片文本补上句末标点**，或者**发送 `task_flush`** 主动催出。

  注意不能用 `task_finish` 代替——它会关闭连接，在一条连接上跑多轮对话时用不了。
</Warning>

<Warning>
  如果你的程序在转发大模型输出前会清洗文本，**请保留原始标点**。缺少标点会让服务端退化为按长度机械切分，停顿位置与语义不符，音频明显不自然。
</Warning>

<Note>
  上游（如大模型）出现较长停顿时，音频中会出现相应的空白，这无法避免。服务端不会为了填补空白而把攒了一半的句子提前送出——那样只会让听众先听到半个词再等待。
</Note>

## 连接保活

连接空闲超过约 120 秒会被服务端关闭并返回 `2201`。「空闲」指服务端既没有收到上行事件，也没有在下发音频。

<Warning>
  服务端**不会主动发送** WebSocket ping 帧。如果你的会话存在较长静默期（例如等待用户说话），请由客户端定期发送 ping —— 服务端会回复 pong 并刷新活跃时间。仅靠 TCP 连接存活不足以避免 `2201`。
</Warning>

## 发送速率与重试

收到 `2205` 表示服务端排队待合成的文本过多，通常是发送速度超过了合成速度。

<Note>
  `2205` **不是配额限流**，也是软失败：连接和会话都不会关闭。稍后重新发送该条 `task_continue` 即可，**不需要重连、也不需要重新 `task_start`**。
</Note>

单条 `task_continue` 文本超过 10,000 字符会返回 `2204`，该条被跳过，连接与会话同样保持。


## AsyncAPI

````yaml api-reference/speech/t2a/api/asyncapi-bidi.json t2a_v2_bidi_websocket
id: t2a_v2_bidi_websocket
title: T2a_v2_bidi_websocket
description: ''
servers:
  - id: production
    protocol: wss
    host: api.minimax.cn
    bindings: []
    variables: []
address: /ws/v1/t2a_v2_bidi
parameters: []
bindings: []
operations:
  - &ref_3
    id: sendMessage
    title: Send message
    description: ''
    type: receive
    messages:
      - &ref_5
        id: send_task_start
        contentType: application/json
        payload:
          - name: 任务开始
            description: |-
              发送`任务开始`事件则正式开始合成任务，当服务端返回的 `task_started` 事件时，标志着任务已成功开始。
              只有在接收到该事件后，才能向服务器发送 `task_continue` 事件或 `task_finish` 事件。
            type: object
            properties:
              - name: event
                type: string
                description: 控制发送的指令，当前环节应填写： `task_start`
                enumValues:
                  - task_start
                required: true
              - name: model
                type: string
                description: 请求的模型版本
                enumValues:
                  - speech-2.8-hd
                  - speech-2.8-turbo
                  - speech-2.6-hd
                  - speech-2.6-turbo
                  - speech-02-hd
                  - speech-02-turbo
                  - speech-01-hd
                  - speech-01-turbo
                required: true
              - name: voice_setting
                type: object
                required: true
                properties:
                  - name: voice_id
                    type: string
                    description: "合成音频的音色编号。若需要设置混合音色，请设置 timbre_weights 参数，本参数设置为空值。支持系统音色、复刻音色以及文生音色三种类型，以下是部分最新的系统音色（ID），可查看 [系统音色列表](/faq/system-voice-id) 或使用 [查询可用音色 API](/api-reference/voice-management-get) 查询系统支持的全部音色\n\n - **中文**:\n\t- moss_audio_ce44fc67-7ce3-11f0-8de5-96e35d26fb85\n\t- moss_audio_aaa1346a-7ce7-11f0-8e61-2e6e3c7ee85d\n\t- Chinese (Mandarin)_Lyrical_Voice\n\t- Chinese (Mandarin)_HK_Flight_Attendant\n- **英文**:\n\t- English_Graceful_Lady\n\t- English_Insightful_Speaker\n\t- English_radiant_girl\n\t- English_Persuasive_Man\n\t- moss_audio_6dc281eb-713c-11f0-a447-9613c873494c\n\t- moss_audio_570551b1-735c-11f0-b236-0adeeecad052\n\t- moss_audio_ad5baf92-735f-11f0-8263-fe5a2fe98ec8\n\t- English_Lucky_Robot\n- **日文**:\n\t- Japanese_Whisper_Belle\n\t- moss_audio_24875c4a-7be4-11f0-9359-4e72c55db738\n\t- moss_audio_7f4ee608-78ea-11f0-bb73-1e2a4cfcd245\n\t- moss_audio_c1a6a3ac-7be6-11f0-8e8e-36b92fbb4f95"
                    required: true
                  - name: speed
                    type: number
                    description: 合成音频的语速，取值越大，语速越快。取值范围 `[0.5,2]`，默认值为1.0
                    required: false
                  - name: vol
                    type: number
                    description: 合成音频的音量，取值越大，音量越高。取值范围 `(0,10]`，默认值为 1.0
                    required: false
                  - name: pitch
                    type: integer
                    description: 合成音频的语调，取值范围 `[-12,12]`，默认值为 0，其中 0 为原音色输出
                    required: false
                  - name: emotion
                    type: string
                    description: "控制合成语音的情绪，参数范围 `[\"happy\", \"sad\", \"angry\", \"fearful\", \"disgusted\", \"surprised\", \"calm\", \"fluent\", \"whisper\"]`，分别对应 8 种情绪：高兴，悲伤，愤怒，害怕，厌恶，惊讶，中性，生动，低语 \r\n- 模型会根据输入文本自动匹配合适的情绪，一般无需手动指定  \r\n- 该参数仅对 `speech-2.8-hd`, `speech-2.8-turbo`, `speech-2.6-hd`, `speech-2.6-turbo`, `speech-02-hd`, `speech-02-turbo`, `speech-01-hd`, `speech-01-turbo` 模型生效 \r\n- 选项 `fluent`, `whisper` 仅对 `speech-2.6-turbo`, `speech-2.6-hd` 模型生效，`speech-2.8-hd`, `speech-2.8-turbo` 模型不支持 `whisper`"
                    enumValues:
                      - happy
                      - sad
                      - angry
                      - fearful
                      - disgusted
                      - surprised
                      - calm
                      - fluent
                      - whisper
                    required: false
                  - name: english_normalization
                    type: boolean
                    description: >-
                      废弃参数，请使用 `task_start` 事件的一级参数
                      `text_normalization_mode`：本参数为 `true` 等价于
                      `text_normalization_mode=basic`；为 `false` 或不传等价于不传
                      `text_normalization_mode`。两者同时传入时以
                      `text_normalization_mode` 为准


                      该参数支持英语文本规范化，可提升数字阅读场景的性能，但会略微增加延迟，默认值为 `false`
                    deprecated: true
                    required: false
                  - name: text_normalization
                    type: boolean
                    description: >-
                      废弃参数，请使用 `task_start` 事件的一级参数
                      `text_normalization_mode`：本参数为 `true` 等价于
                      `text_normalization_mode=basic`；为 `false` 或不传等价于不传
                      `text_normalization_mode`。两者同时传入时以
                      `text_normalization_mode` 为准


                      是否启用中文、英语文本规范化，开启后可提升数字阅读场景的性能，但会略微增加延迟，默认值为 `false`。与
                      `english_normalization` 同时传入时以本参数为准
                    deprecated: true
                    required: false
                  - name: latex_read
                    type: boolean
                    description: >-
                      控制是否朗读 latex 公式，默认为 `false`

                      **需注意**:

                      - 仅支持中文，开启该参数后，`language_boost` 参数会被设置为 `Chinese`

                      - 请求中的公式需要在公式的首尾加上 `$$`

                      - 请求中公式若有 `"\"`，需转义成 `"\\"`.


                      示例：一元二次方程根的基本公式

                      ![The quadratic
                      formula](https://filecdn.minimax.chat/public/d6f62e9a-cd3f-4f55-a237-257eef531683.png)


                      应表示为 `$$x = \\frac{-b \\pm \\sqrt{b^2 - 4ac}}{2a}$$`
                    required: false
              - name: audio_setting
                type: object
                required: false
                properties:
                  - name: sample_rate
                    type: integer
                    description: >-
                      生成音频的采样率。可选范围 `[8000，16000，22050，24000，32000，44100]`，默认为
                      `32000`
                    required: false
                  - name: bitrate
                    type: integer
                    description: >-
                      生成音频的比特率。可选范围 `[32000，64000，128000，256000]`，默认值为
                      `128000`。该参数仅对 `mp3` 格式的音频生效
                    required: false
                  - name: format
                    type: string
                    description: >-
                      生成音频的格式。`pcmu_raw` 与 `pcmu_wav` 为 G.711 μ-law 编码（采样率 8
                      kHz；`pcmu_raw` 为无文件头裸数据，`pcmu_wav` 封装在 WAV 容器中）。`opus` 为
                      Ogg/Opus 编码；流式模式下音频 chunk 需按到达顺序拼接后再解码
                    enumValues:
                      - mp3
                      - pcm
                      - flac
                      - wav
                      - pcmu_raw
                      - pcmu_wav
                      - opus
                    required: false
                  - name: channel
                    type: integer
                    description: 生成音频的声道数。可选范围：`[1,2]`，其中 `1` 为单声道，`2` 为双声道，默认值为 1
                    required: false
              - name: pronunciation_dict
                type: object
                required: false
                properties:
                  - name: tone
                    type: array
                    description: |-
                      定义需要特殊标注的文字或符号对应的注音或发音替换规则。在中文文本中，声调用数字表示：
                      一声为 1，二声为 2，三声为 3，四声为 4，轻声为 5
                      示例如下：
                      `["燕少飞/(yan4)(shao3)(fei1)", "omg/oh my god"]`
                    required: false
                    properties:
                      - name: item
                        type: string
                        required: false
              - name: timbre_weights
                type: object
                required: false
                properties:
                  - name: voice_id
                    type: string
                    description: >-
                      合成音频的音色编号，须和weight参数同步填写。支持系统音色、复刻音色以及文生音色三种类型。系统支持的全部音色可查看
                      [系统音色列表](/faq/system-voice-id)，也可使用 [查询可用音色
                      API](/api-reference/voice-management-get) 查询系统支持的全部音色
                    required: false
                  - name: weight
                    type: integer
                    description: >-
                      合成音频各音色所占的权重，须与 voice_id 同步填写。可选值范围为[1, 100]，最多支持 4
                      种音色混合，单一音色取值占比越高，合成音色与该音色相似度越高.


                      ```json dark

                      "timbre_weights": [
                        {
                          "voice_id": "female-chengshu",
                          "weight": 30
                        },
                        {
                          "voice_id": "female-tianmei",
                          "weight": 70
                        }
                      ]

                      ```
                    required: false
              - name: language_boost
                type: string
                description: >-
                  是否增强对指定的小语种和方言的识别能力，设置后可以提升在指定小语种/方言场景下的语音表现。默认值为
                  `null`，如果不明确小语种类型，可设置为 `auto`，模型将自主判断小语种类型

                  可选值范围： 

                  [`Chinese`, `Chinese,Yue`, `English`, `Arabic`, `Russian`,
                  `Spanish`, `French`, `Portuguese`, `German`, `Turkish`,
                  `Dutch`, `Ukrainian`, `Vietnamese`, `Indonesian`, `Japanese`,
                  `Italian`, `Korean`, `Thai`, `Polish`, `Romanian`, `Greek`,
                  `Czech`, `Finnish`, `Hindi`, `Bulgarian`, `Danish`, `Hebrew`,
                  `Malay`, `Persian`, `Slovak`, `Swedish`, `Croatian`,
                  `Filipino`, `Hungarian`, `Norwegian`, `Slovenian`, `Catalan`,
                  `Nynorsk`, `Tamil`, `Afrikaans`, `auto`]


                  注意：speech-01 和 speech-02 系列模型暂不支持 Persian、Filipino、Tamil
                  这三个语种。
                enumValues:
                  - Chinese
                  - Chinese,Yue
                  - English
                  - Arabic
                  - Russian
                  - Spanish
                  - French
                  - Portuguese
                  - German
                  - Turkish
                  - Dutch
                  - Ukrainian
                  - Vietnamese
                  - Indonesian
                  - Japanese
                  - Italian
                  - Korean
                  - Thai
                  - Polish
                  - Romanian
                  - Greek
                  - Czech
                  - Finnish
                  - Hindi
                  - Bulgarian
                  - Danish
                  - Hebrew
                  - Malay
                  - Persian
                  - Slovak
                  - Swedish
                  - Croatian
                  - Filipino
                  - Hungarian
                  - Norwegian
                  - Slovenian
                  - Catalan
                  - Nynorsk
                  - Tamil
                  - Afrikaans
                  - auto
                required: false
              - name: text_normalization_mode
                type: string
                description: >-
                  文本归一化模式。`basic` 使用快速的规则归一化；`quality` 采用 LLM +
                  规则的混合方案，归一化质量更高，但会增加一定延迟。详见[文本归一化](/guides/speech-t2a-websocket#文本归一化)。


                  注意：

                  - `quality` 目前仅对非流式 HTTP 请求生效；WebSocket 为流式合成，传入 `quality` 时按
                  `basic` 处理，不会报错

                  - 传入本参数后，`voice_setting.text_normalization` 与
                  `voice_setting.english_normalization` 不再生效；不传时沿用这两个参数的设置（默认关闭）
                enumValues:
                  - basic
                  - quality
                required: false
              - name: voice_modify
                type: object
                description: 声音效果器设置
                required: false
                properties:
                  - name: pitch
                    type: integer
                    description: >-
                      音高调整（低沉/明亮），范围 [-100,100]，数值接近 -100，声音更低沉；接近 100，声音更明亮


                      ![pitch
                      adjustment](https://filecdn.minimax.chat/public/5d210c47-4236-4e81-893b-16cc1ef0302d.png)
                    required: false
                  - name: intensity
                    type: integer
                    description: >-
                      强度调整（力量感/柔和），范围 [-100,100]，数值接近 -100，声音更刚劲；接近 100，声音更轻柔


                      ![intensity
                      adjustment](https://filecdn.minimax.chat/public/862d493e-71d5-4d1f-b7c3-9ac51890631b.png)
                    required: false
                  - name: timbre
                    type: integer
                    description: >-
                      音色调整（磁性/清脆），范围 [-100,100]，数值接近 -100，声音更浑厚；数值接近 100，声音更清脆


                      ![timbre
                      adjustment](https://filecdn.minimax.chat/public/5f0e6cae-363a-452b-8d42-fbc4ef5a0510.png)
                    required: false
                  - name: sound_effects
                    type: string
                    description: |-
                      音效设置，单次仅能选择一种，可选值：
                      1. spacious_echo（空旷回音）
                      2. auditorium_echo（礼堂广播）
                      3. lofi_telephone（电话失真）
                      4. robotic（电音）
                    enumValues:
                      - spacious_echo
                      - auditorium_echo
                      - lofi_telephone
                      - robotic
                    required: false
              - name: subtitle_enable
                type: boolean
                description: >-
                  控制是否开启字幕服务，默认值为 `false`。仅对 `speech-2.8-hd`,
                  `speech-2.8-turbo`, `speech-2.6-hd`, `speech-2.6-turbo`,
                  `speech-02-hd`, `speech-02-turbo`, `speech-01-hd`,
                  `speech-01-turbo` 模型有效
                required: false
              - name: subtitle_type
                type: string
                description: >-
                  字幕粒度，默认值为 `sentence`。可选值：

                  - `sentence`：句级别时间戳

                  - `word`：词级别时间戳

                  - `word_streaming`：流式优化的词级别时间戳


                  字幕通过 `task_continued` 事件的 `data.subtitle` 随音频下发，不提供字幕文件：

                  - `sentence` / `word`：每个分段只在该分段最后一个音频片段中返回一次完整字幕，`sentence` 不含
                  `timestamped_words`

                  - `word_streaming`：每个音频片段都返回当前分段截至目前的累计字幕（`timestamped_words`
                  与 `time_end` 持续增长），客户端应以最新一条覆盖同一分段的旧结果；`text_begin`
                  变化表示进入下一个分段


                  `is_final` 为 `true` 的消息不含字幕，请在每条 `task_continued` 消息中检查
                  `data.subtitle`


                  双向模式下服务端按句合成，每句（一组 `sentence_start` … `sentence_end`）独立计时：字幕中的
                  `time_begin` / `time_end` 与 `text_begin` / `text_end` 均相对当前句，从
                  0 开始
                enumValues:
                  - sentence
                  - word
                  - word_streaming
                required: false
              - name: continuous_sound
                type: boolean
                description: |-
                  控制模型侧文本切分策略，仅对 `speech-2.8-hd`、`speech-2.8-turbo` 模型有效。
                  - `true`：模型侧不切分文本，连续推理生成音频（长文本韵律更自然）
                  - `false`：模型侧切分文本，并发推理生成音频（延迟更低）

                  默认值为 `false`
                required: false
              - name: session_id
                type: string
                description: >-
                  会话 id，由客户端生成，用于标识本次合成会话。可不传，不传时服务端使用 `connect_id`
                  兜底。该字段仅作透传回显，便于客户端串联自己的会话上下文
                required: false
        headers: []
        jsonPayloadSchema:
          type: object
          required:
            - event
            - model
            - voice_setting
          properties:
            event:
              type: string
              enum:
                - task_start
              default:
                - task_start
              description: 控制发送的指令，当前环节应填写： `task_start`
              x-parser-schema-id: <anonymous-schema-7>
            model:
              type: string
              description: 请求的模型版本
              enum:
                - speech-2.8-hd
                - speech-2.8-turbo
                - speech-2.6-hd
                - speech-2.6-turbo
                - speech-02-hd
                - speech-02-turbo
                - speech-01-hd
                - speech-01-turbo
              x-parser-schema-id: <anonymous-schema-8>
            voice_setting:
              type: object
              required:
                - voice_id
              properties:
                voice_id:
                  type: string
                  description: "合成音频的音色编号。若需要设置混合音色，请设置 timbre_weights 参数，本参数设置为空值。支持系统音色、复刻音色以及文生音色三种类型，以下是部分最新的系统音色（ID），可查看 [系统音色列表](/faq/system-voice-id) 或使用 [查询可用音色 API](/api-reference/voice-management-get) 查询系统支持的全部音色\n\n - **中文**:\n\t- moss_audio_ce44fc67-7ce3-11f0-8de5-96e35d26fb85\n\t- moss_audio_aaa1346a-7ce7-11f0-8e61-2e6e3c7ee85d\n\t- Chinese (Mandarin)_Lyrical_Voice\n\t- Chinese (Mandarin)_HK_Flight_Attendant\n- **英文**:\n\t- English_Graceful_Lady\n\t- English_Insightful_Speaker\n\t- English_radiant_girl\n\t- English_Persuasive_Man\n\t- moss_audio_6dc281eb-713c-11f0-a447-9613c873494c\n\t- moss_audio_570551b1-735c-11f0-b236-0adeeecad052\n\t- moss_audio_ad5baf92-735f-11f0-8263-fe5a2fe98ec8\n\t- English_Lucky_Robot\n- **日文**:\n\t- Japanese_Whisper_Belle\n\t- moss_audio_24875c4a-7be4-11f0-9359-4e72c55db738\n\t- moss_audio_7f4ee608-78ea-11f0-bb73-1e2a4cfcd245\n\t- moss_audio_c1a6a3ac-7be6-11f0-8e8e-36b92fbb4f95"
                  x-parser-schema-id: <anonymous-schema-9>
                speed:
                  type: number
                  format: float
                  description: 合成音频的语速，取值越大，语速越快。取值范围 `[0.5,2]`，默认值为1.0
                  minimum: 0.5
                  maximum: 2
                  default: 1
                  x-parser-schema-id: <anonymous-schema-10>
                vol:
                  type: number
                  format: float
                  description: 合成音频的音量，取值越大，音量越高。取值范围 `(0,10]`，默认值为 1.0
                  exclusiveMinimum: 0
                  maximum: 10
                  default: 1
                  x-parser-schema-id: <anonymous-schema-11>
                pitch:
                  type: integer
                  description: 合成音频的语调，取值范围 `[-12,12]`，默认值为 0，其中 0 为原音色输出
                  minimum: -12
                  maximum: 12
                  default: 0
                  x-parser-schema-id: <anonymous-schema-12>
                emotion:
                  type: string
                  description: "控制合成语音的情绪，参数范围 `[\"happy\", \"sad\", \"angry\", \"fearful\", \"disgusted\", \"surprised\", \"calm\", \"fluent\", \"whisper\"]`，分别对应 8 种情绪：高兴，悲伤，愤怒，害怕，厌恶，惊讶，中性，生动，低语 \r\n- 模型会根据输入文本自动匹配合适的情绪，一般无需手动指定  \r\n- 该参数仅对 `speech-2.8-hd`, `speech-2.8-turbo`, `speech-2.6-hd`, `speech-2.6-turbo`, `speech-02-hd`, `speech-02-turbo`, `speech-01-hd`, `speech-01-turbo` 模型生效 \r\n- 选项 `fluent`, `whisper` 仅对 `speech-2.6-turbo`, `speech-2.6-hd` 模型生效，`speech-2.8-hd`, `speech-2.8-turbo` 模型不支持 `whisper`"
                  enum:
                    - happy
                    - sad
                    - angry
                    - fearful
                    - disgusted
                    - surprised
                    - calm
                    - fluent
                    - whisper
                  x-parser-schema-id: <anonymous-schema-13>
                english_normalization:
                  type: boolean
                  description: >-
                    废弃参数，请使用 `task_start` 事件的一级参数 `text_normalization_mode`：本参数为
                    `true` 等价于 `text_normalization_mode=basic`；为 `false`
                    或不传等价于不传 `text_normalization_mode`。两者同时传入时以
                    `text_normalization_mode` 为准


                    该参数支持英语文本规范化，可提升数字阅读场景的性能，但会略微增加延迟，默认值为 `false`
                  default: false
                  deprecated: true
                  x-parser-schema-id: <anonymous-schema-14>
                text_normalization:
                  type: boolean
                  description: >-
                    废弃参数，请使用 `task_start` 事件的一级参数 `text_normalization_mode`：本参数为
                    `true` 等价于 `text_normalization_mode=basic`；为 `false`
                    或不传等价于不传 `text_normalization_mode`。两者同时传入时以
                    `text_normalization_mode` 为准


                    是否启用中文、英语文本规范化，开启后可提升数字阅读场景的性能，但会略微增加延迟，默认值为 `false`。与
                    `english_normalization` 同时传入时以本参数为准
                  default: false
                  deprecated: true
                  x-parser-schema-id: <anonymous-schema-15>
                latex_read:
                  type: boolean
                  description: >-
                    控制是否朗读 latex 公式，默认为 `false`

                    **需注意**:

                    - 仅支持中文，开启该参数后，`language_boost` 参数会被设置为 `Chinese`

                    - 请求中的公式需要在公式的首尾加上 `$$`

                    - 请求中公式若有 `"\"`，需转义成 `"\\"`.


                    示例：一元二次方程根的基本公式

                    ![The quadratic
                    formula](https://filecdn.minimax.chat/public/d6f62e9a-cd3f-4f55-a237-257eef531683.png)


                    应表示为 `$$x = \\frac{-b \\pm \\sqrt{b^2 - 4ac}}{2a}$$`
                  default: false
                  x-parser-schema-id: <anonymous-schema-16>
              x-parser-schema-id: VoiceSetting
            audio_setting:
              type: object
              properties:
                sample_rate:
                  type: integer
                  format: int64
                  description: >-
                    生成音频的采样率。可选范围 `[8000，16000，22050，24000，32000，44100]`，默认为
                    `32000`
                  x-parser-schema-id: <anonymous-schema-17>
                bitrate:
                  type: integer
                  format: int64
                  description: >-
                    生成音频的比特率。可选范围 `[32000，64000，128000，256000]`，默认值为
                    `128000`。该参数仅对 `mp3` 格式的音频生效
                  x-parser-schema-id: <anonymous-schema-18>
                format:
                  type: string
                  description: >-
                    生成音频的格式。`pcmu_raw` 与 `pcmu_wav` 为 G.711 μ-law 编码（采样率 8
                    kHz；`pcmu_raw` 为无文件头裸数据，`pcmu_wav` 封装在 WAV 容器中）。`opus` 为
                    Ogg/Opus 编码；流式模式下音频 chunk 需按到达顺序拼接后再解码
                  enum:
                    - mp3
                    - pcm
                    - flac
                    - wav
                    - pcmu_raw
                    - pcmu_wav
                    - opus
                  default: mp3
                  x-parser-schema-id: <anonymous-schema-19>
                channel:
                  type: integer
                  format: int64
                  description: 生成音频的声道数。可选范围：`[1,2]`，其中 `1` 为单声道，`2` 为双声道，默认值为 1
                  x-parser-schema-id: <anonymous-schema-20>
              x-parser-schema-id: AudioSetting
            pronunciation_dict:
              type: object
              properties:
                tone:
                  type: array
                  items:
                    type: string
                    x-parser-schema-id: <anonymous-schema-22>
                  description: |-
                    定义需要特殊标注的文字或符号对应的注音或发音替换规则。在中文文本中，声调用数字表示：
                    一声为 1，二声为 2，三声为 3，四声为 4，轻声为 5
                    示例如下：
                    `["燕少飞/(yan4)(shao3)(fei1)", "omg/oh my god"]`
                  x-parser-schema-id: <anonymous-schema-21>
              x-parser-schema-id: PronunciationDict
            timbre_weights:
              type: object
              properties:
                voice_id:
                  type: string
                  description: >-
                    合成音频的音色编号，须和weight参数同步填写。支持系统音色、复刻音色以及文生音色三种类型。系统支持的全部音色可查看
                    [系统音色列表](/faq/system-voice-id)，也可使用 [查询可用音色
                    API](/api-reference/voice-management-get) 查询系统支持的全部音色
                  x-parser-schema-id: <anonymous-schema-23>
                weight:
                  type: integer
                  format: int64
                  description: >-
                    合成音频各音色所占的权重，须与 voice_id 同步填写。可选值范围为[1, 100]，最多支持 4
                    种音色混合，单一音色取值占比越高，合成音色与该音色相似度越高.


                    ```json dark

                    "timbre_weights": [
                      {
                        "voice_id": "female-chengshu",
                        "weight": 30
                      },
                      {
                        "voice_id": "female-tianmei",
                        "weight": 70
                      }
                    ]

                    ```
                  minimum: 1
                  maximum: 100
                  x-parser-schema-id: <anonymous-schema-24>
              x-parser-schema-id: TimbreWeights
            language_boost:
              type: string
              description: >-
                是否增强对指定的小语种和方言的识别能力，设置后可以提升在指定小语种/方言场景下的语音表现。默认值为
                `null`，如果不明确小语种类型，可设置为 `auto`，模型将自主判断小语种类型

                可选值范围： 

                [`Chinese`, `Chinese,Yue`, `English`, `Arabic`, `Russian`,
                `Spanish`, `French`, `Portuguese`, `German`, `Turkish`, `Dutch`,
                `Ukrainian`, `Vietnamese`, `Indonesian`, `Japanese`, `Italian`,
                `Korean`, `Thai`, `Polish`, `Romanian`, `Greek`, `Czech`,
                `Finnish`, `Hindi`, `Bulgarian`, `Danish`, `Hebrew`, `Malay`,
                `Persian`, `Slovak`, `Swedish`, `Croatian`, `Filipino`,
                `Hungarian`, `Norwegian`, `Slovenian`, `Catalan`, `Nynorsk`,
                `Tamil`, `Afrikaans`, `auto`]


                注意：speech-01 和 speech-02 系列模型暂不支持 Persian、Filipino、Tamil 这三个语种。
              enum:
                - Chinese
                - Chinese,Yue
                - English
                - Arabic
                - Russian
                - Spanish
                - French
                - Portuguese
                - German
                - Turkish
                - Dutch
                - Ukrainian
                - Vietnamese
                - Indonesian
                - Japanese
                - Italian
                - Korean
                - Thai
                - Polish
                - Romanian
                - Greek
                - Czech
                - Finnish
                - Hindi
                - Bulgarian
                - Danish
                - Hebrew
                - Malay
                - Persian
                - Slovak
                - Swedish
                - Croatian
                - Filipino
                - Hungarian
                - Norwegian
                - Slovenian
                - Catalan
                - Nynorsk
                - Tamil
                - Afrikaans
                - auto
              x-parser-schema-id: <anonymous-schema-25>
            text_normalization_mode:
              type: string
              description: >-
                文本归一化模式。`basic` 使用快速的规则归一化；`quality` 采用 LLM +
                规则的混合方案，归一化质量更高，但会增加一定延迟。详见[文本归一化](/guides/speech-t2a-websocket#文本归一化)。


                注意：

                - `quality` 目前仅对非流式 HTTP 请求生效；WebSocket 为流式合成，传入 `quality` 时按
                `basic` 处理，不会报错

                - 传入本参数后，`voice_setting.text_normalization` 与
                `voice_setting.english_normalization` 不再生效；不传时沿用这两个参数的设置（默认关闭）
              enum:
                - basic
                - quality
              x-mint:
                post:
                  - updated
              x-parser-schema-id: <anonymous-schema-26>
            voice_modify:
              type: object
              description: 声音效果器设置
              properties:
                pitch:
                  type: integer
                  description: >-
                    音高调整（低沉/明亮），范围 [-100,100]，数值接近 -100，声音更低沉；接近 100，声音更明亮


                    ![pitch
                    adjustment](https://filecdn.minimax.chat/public/5d210c47-4236-4e81-893b-16cc1ef0302d.png)
                  minimum: -100
                  maximum: 100
                  x-parser-schema-id: <anonymous-schema-27>
                intensity:
                  type: integer
                  description: >-
                    强度调整（力量感/柔和），范围 [-100,100]，数值接近 -100，声音更刚劲；接近 100，声音更轻柔


                    ![intensity
                    adjustment](https://filecdn.minimax.chat/public/862d493e-71d5-4d1f-b7c3-9ac51890631b.png)
                  minimum: -100
                  maximum: 100
                  x-parser-schema-id: <anonymous-schema-28>
                timbre:
                  type: integer
                  description: >-
                    音色调整（磁性/清脆），范围 [-100,100]，数值接近 -100，声音更浑厚；数值接近 100，声音更清脆


                    ![timbre
                    adjustment](https://filecdn.minimax.chat/public/5f0e6cae-363a-452b-8d42-fbc4ef5a0510.png)
                  minimum: -100
                  maximum: 100
                  x-parser-schema-id: <anonymous-schema-29>
                sound_effects:
                  type: string
                  description: |-
                    音效设置，单次仅能选择一种，可选值：
                    1. spacious_echo（空旷回音）
                    2. auditorium_echo（礼堂广播）
                    3. lofi_telephone（电话失真）
                    4. robotic（电音）
                  enum:
                    - spacious_echo
                    - auditorium_echo
                    - lofi_telephone
                    - robotic
                  x-parser-schema-id: <anonymous-schema-30>
              x-parser-schema-id: VoiceModify
            subtitle_enable:
              type: boolean
              description: >-
                控制是否开启字幕服务，默认值为 `false`。仅对 `speech-2.8-hd`, `speech-2.8-turbo`,
                `speech-2.6-hd`, `speech-2.6-turbo`, `speech-02-hd`,
                `speech-02-turbo`, `speech-01-hd`, `speech-01-turbo` 模型有效
              default: false
              x-parser-schema-id: <anonymous-schema-31>
            subtitle_type:
              type: string
              description: >-
                字幕粒度，默认值为 `sentence`。可选值：

                - `sentence`：句级别时间戳

                - `word`：词级别时间戳

                - `word_streaming`：流式优化的词级别时间戳


                字幕通过 `task_continued` 事件的 `data.subtitle` 随音频下发，不提供字幕文件：

                - `sentence` / `word`：每个分段只在该分段最后一个音频片段中返回一次完整字幕，`sentence` 不含
                `timestamped_words`

                - `word_streaming`：每个音频片段都返回当前分段截至目前的累计字幕（`timestamped_words` 与
                `time_end` 持续增长），客户端应以最新一条覆盖同一分段的旧结果；`text_begin` 变化表示进入下一个分段


                `is_final` 为 `true` 的消息不含字幕，请在每条 `task_continued` 消息中检查
                `data.subtitle`


                双向模式下服务端按句合成，每句（一组 `sentence_start` … `sentence_end`）独立计时：字幕中的
                `time_begin` / `time_end` 与 `text_begin` / `text_end` 均相对当前句，从 0
                开始
              enum:
                - sentence
                - word
                - word_streaming
              default: sentence
              x-parser-schema-id: <anonymous-schema-32>
            continuous_sound:
              type: boolean
              description: |-
                控制模型侧文本切分策略，仅对 `speech-2.8-hd`、`speech-2.8-turbo` 模型有效。
                - `true`：模型侧不切分文本，连续推理生成音频（长文本韵律更自然）
                - `false`：模型侧切分文本，并发推理生成音频（延迟更低）

                默认值为 `false`
              default: false
              x-parser-schema-id: <anonymous-schema-33>
            session_id:
              type: string
              description: >-
                会话 id，由客户端生成，用于标识本次合成会话。可不传，不传时服务端使用 `connect_id`
                兜底。该字段仅作透传回显，便于客户端串联自己的会话上下文
              x-parser-schema-id: <anonymous-schema-34>
          x-parser-schema-id: SendTaskStartEvent
        title: 任务开始
        description: |-
          发送`任务开始`事件则正式开始合成任务，当服务端返回的 `task_started` 事件时，标志着任务已成功开始。
          只有在接收到该事件后，才能向服务器发送 `task_continue` 事件或 `task_finish` 事件。
        example: |-
          {
            "event": "task_start",
            "model": "speech-2.8-turbo",
            "language_boost": "Chinese",
            "voice_setting": {
              "voice_id": "male-qn-qingse",
              "speed": 1,
              "vol": 1,
              "pitch": 0
            },
            "pronunciation_dict": {
              "tone": [
                "处理/(chu3)(li3)",
                "危险/dangerous"
              ]
            },
            "audio_setting": {
              "sample_rate": 32000,
              "bitrate": 128000,
              "format": "mp3",
              "channel": 1
            },
            "session_id": "my-session-001"
          }
        bindings: []
        extensions:
          - id: x-parser-unique-object-id
            value: send_task_start
      - &ref_6
        id: send_task_continue
        contentType: application/json
        payload:
          - name: 任务继续
            description: >-
              当收到服务端返回的 `task_started` 事件后，任务正式开始，可通过发送 `task_continue`
              事件发送要合成的文本。


              与 `/ws/v1/t2a_v2`
              的关键区别：**本接口的文本不会一条一次合成**，而是进入服务端的攒句缓冲，按下列规则成句后才送去合成，因此可以安全地按逐字/逐
              token 粒度发送：

              - 遇到句末标点（`。！？…；!?.` 及换行）立即合成

              - 遇到次级标点（`，、：,;:`）且已攒够长度时合成

              - 累计长度达到上限时强制切分

              - 停止发送超过一定时间后，自动合成缓冲区中的残留文本


              纯空白文本会被静默丢弃，不会返回错误。

              当最后一次收到服务端返回结果后超过 120s 没有发送新事件时，WebSocket 连接自动断开。
            type: object
            properties:
              - name: event
                type: string
                description: 表示会话事件类型，当前环节应填写 `task_continue`
                enumValues:
                  - task_continue
                required: true
              - name: text
                type: string
                description: >-
                  需要合成语音的文本，长度限制小于 10,000 字符。


                  **可按任意粒度发送**（包括单个字符），服务端会自动攒句，无需客户端自行判断句子边界。


                  - 段落切换用换行符标记

                  - 停顿控制：支持自定义文本之间的语音时间间隔。使用方式：在文本中增加 `<#x#>` 标记，`x`
                  为停顿时长（单位：秒），范围 **[0.01,
                  99.99]**，最多保留两位小数。文本间隔时间需设置在两个可以语音发音的文本之间，不可连续使用多个停顿标记

                  - 语气词标签：仅当模型选择 `speech-2.8-hd` 或 `speech-2.8-turbo`
                  时，支持在文本中插入语气词标签。支持的语气词：`(laughs)`（笑声）、`(chuckle)`（轻笑）、`(coughs)`（咳嗽）、`(clear-throat)`（清嗓子）、`(groans)`（呻吟）、`(breath)`（正常换气）、`(pant)`（喘气）、`(inhale)`（吸气）、`(exhale)`（呼气）、`(gasps)`（倒吸气）、`(sniffs)`（吸鼻子）、`(sighs)`（叹气）、`(snorts)`（喷鼻息）、`(burps)`（打嗝）、`(lip-smacking)`（咂嘴）、`(humming)`（哼唱）、`(hissing)`（嘶嘶声）、`(emm)`（嗯）、`(sneezes)`（喷嚏）
                required: true
        headers: []
        jsonPayloadSchema:
          type: object
          required:
            - event
            - text
          properties:
            event:
              type: string
              description: 表示会话事件类型，当前环节应填写 `task_continue`
              enum:
                - task_continue
              default:
                - task_continue
              x-parser-schema-id: <anonymous-schema-41>
            text:
              type: string
              description: >-
                需要合成语音的文本，长度限制小于 10,000 字符。


                **可按任意粒度发送**（包括单个字符），服务端会自动攒句，无需客户端自行判断句子边界。


                - 段落切换用换行符标记

                - 停顿控制：支持自定义文本之间的语音时间间隔。使用方式：在文本中增加 `<#x#>` 标记，`x`
                为停顿时长（单位：秒），范围 **[0.01,
                99.99]**，最多保留两位小数。文本间隔时间需设置在两个可以语音发音的文本之间，不可连续使用多个停顿标记

                - 语气词标签：仅当模型选择 `speech-2.8-hd` 或 `speech-2.8-turbo`
                时，支持在文本中插入语气词标签。支持的语气词：`(laughs)`（笑声）、`(chuckle)`（轻笑）、`(coughs)`（咳嗽）、`(clear-throat)`（清嗓子）、`(groans)`（呻吟）、`(breath)`（正常换气）、`(pant)`（喘气）、`(inhale)`（吸气）、`(exhale)`（呼气）、`(gasps)`（倒吸气）、`(sniffs)`（吸鼻子）、`(sighs)`（叹气）、`(snorts)`（喷鼻息）、`(burps)`（打嗝）、`(lip-smacking)`（咂嘴）、`(humming)`（哼唱）、`(hissing)`（嘶嘶声）、`(emm)`（嗯）、`(sneezes)`（喷嚏）
              x-parser-schema-id: <anonymous-schema-42>
          x-parser-schema-id: SendTaskContinueEvent
        title: 任务继续
        description: >-
          当收到服务端返回的 `task_started` 事件后，任务正式开始，可通过发送 `task_continue` 事件发送要合成的文本。


          与 `/ws/v1/t2a_v2`
          的关键区别：**本接口的文本不会一条一次合成**，而是进入服务端的攒句缓冲，按下列规则成句后才送去合成，因此可以安全地按逐字/逐 token
          粒度发送：

          - 遇到句末标点（`。！？…；!?.` 及换行）立即合成

          - 遇到次级标点（`，、：,;:`）且已攒够长度时合成

          - 累计长度达到上限时强制切分

          - 停止发送超过一定时间后，自动合成缓冲区中的残留文本


          纯空白文本会被静默丢弃，不会返回错误。

          当最后一次收到服务端返回结果后超过 120s 没有发送新事件时，WebSocket 连接自动断开。
        example: |-
          {
            "event": "task_continue",
            "text": "真正的危险不是计算机开始像人一样思考(sighs)，而是人开始像计算机一样思考。计算机只是可以帮我们处理一些简单事务。"
          }
        bindings: []
        extensions:
          - id: x-parser-unique-object-id
            value: send_task_continue
      - &ref_7
        id: send_task_cancel
        contentType: application/json
        payload:
          - name: 打断合成
            description: >-
              发送 `task_cancel` 事件可立即打断当前合成：服务端会丢弃攒句缓冲区中尚未合成的文本、中断正在进行的合成，并返回
              `task_canceled` 事件。


              已经发送给客户端的音频不会撤回。


              打断后会话回到 `task_started` 状态，**可以继续发送 `task_continue`
              继续合成**，无需重建连接。适用于实时对话中用户插话打断的场景。
            type: object
            properties:
              - name: event
                type: string
                description: 表示会话事件类型，当前环节应填写 `task_cancel`
                enumValues:
                  - task_cancel
                required: true
        headers: []
        jsonPayloadSchema:
          type: object
          required:
            - event
          properties:
            event:
              type: string
              enum:
                - task_cancel
              default:
                - task_cancel
              description: 表示会话事件类型，当前环节应填写 `task_cancel`
              x-parser-schema-id: <anonymous-schema-91>
          x-parser-schema-id: SendTaskCancelEvent
        title: 打断合成
        description: >-
          发送 `task_cancel` 事件可立即打断当前合成：服务端会丢弃攒句缓冲区中尚未合成的文本、中断正在进行的合成，并返回
          `task_canceled` 事件。


          已经发送给客户端的音频不会撤回。


          打断后会话回到 `task_started` 状态，**可以继续发送 `task_continue`
          继续合成**，无需重建连接。适用于实时对话中用户插话打断的场景。
        example: |-
          {
            "event": "task_cancel"
          }
        bindings: []
        extensions:
          - id: x-parser-unique-object-id
            value: send_task_cancel
      - &ref_8
        id: send_task_flush
        contentType: application/json
        payload:
          - name: 催出残留（不结束会话）
            description: >-
              发送 `task_flush` 事件，让服务端立即把攒句缓冲区里剩余的文本送去合成，但**不结束会话、不关闭连接**。合成完毕后返回
              `task_flushed`。


              适用场景：一轮说完了，而最后一片文本很短又不带句末标点。这种残留不会被静默窗口立刻送出（那是为了避免在词中间切开），需要等一个更长的兜底窗口。发
              `task_flush` 可以立刻拿到这段音频。


              与 `task_finish` 的区别：`task_finish`
              会关闭连接，因此在一条连接上进行多轮对话时无法用它催出某一轮的尾句；`task_flush` 之后会话仍处于
              `task_started` 状态，可以继续发送 `task_continue`。


              缓冲区恰好为空时也会正常返回 `task_flushed`，不算错误。
            type: object
            properties:
              - name: event
                type: string
                description: 表示会话事件类型，当前环节应填写 `task_flush`
                enumValues:
                  - task_flush
                required: true
        headers: []
        jsonPayloadSchema:
          type: object
          required:
            - event
          properties:
            event:
              type: string
              enum:
                - task_flush
              default:
                - task_flush
              description: 表示会话事件类型，当前环节应填写 `task_flush`
              x-parser-schema-id: <anonymous-schema-75>
          x-parser-schema-id: SendTaskFlushEvent
        title: 催出残留（不结束会话）
        description: >-
          发送 `task_flush` 事件，让服务端立即把攒句缓冲区里剩余的文本送去合成，但**不结束会话、不关闭连接**。合成完毕后返回
          `task_flushed`。


          适用场景：一轮说完了，而最后一片文本很短又不带句末标点。这种残留不会被静默窗口立刻送出（那是为了避免在词中间切开），需要等一个更长的兜底窗口。发
          `task_flush` 可以立刻拿到这段音频。


          与 `task_finish` 的区别：`task_finish`
          会关闭连接，因此在一条连接上进行多轮对话时无法用它催出某一轮的尾句；`task_flush` 之后会话仍处于 `task_started`
          状态，可以继续发送 `task_continue`。


          缓冲区恰好为空时也会正常返回 `task_flushed`，不算错误。
        example: |-
          {
            "event": "task_flush"
          }
        bindings: []
        extensions:
          - id: x-parser-unique-object-id
            value: send_task_flush
      - &ref_9
        id: send_task_finish
        contentType: application/json
        payload:
          - name: 任务结束
            description: >-
              服务端收到 `task_finish` 事件后，会先把攒句缓冲区中剩余的文本送去合成，等全部音频返回后才回复
              `task_finished` 并关闭连接。


              因此**最后一句不完整的文本也不会丢失**，无需客户端在结束前补一个标点。
            type: object
            properties:
              - name: event
                type: string
                description: 表示会话事件类型，当前环节应填写 `task_finish`
                enumValues:
                  - task_finish
                required: true
        headers: []
        jsonPayloadSchema:
          type: object
          required:
            - event
          properties:
            event:
              type: string
              enum:
                - task_finish
              default:
                - task_finish
              description: 表示会话事件类型，当前环节应填写 `task_finish`
              x-parser-schema-id: <anonymous-schema-80>
          x-parser-schema-id: SendTaskFinishEvent
        title: 任务结束
        description: >-
          服务端收到 `task_finish` 事件后，会先把攒句缓冲区中剩余的文本送去合成，等全部音频返回后才回复 `task_finished`
          并关闭连接。


          因此**最后一句不完整的文本也不会丢失**，无需客户端在结束前补一个标点。
        example: |-
          {
            "event": "task_finish"
          }
        bindings: []
        extensions:
          - id: x-parser-unique-object-id
            value: send_task_finish
    bindings: []
    extensions: &ref_2
      - id: x-parser-unique-object-id
        value: t2a_v2_bidi_websocket
  - &ref_4
    id: receiveMessage
    title: Receive message
    type: send
    messages:
      - &ref_10
        id: receive_connected_success
        contentType: application/json
        payload:
          - name: 建连成功
            description: 成功建立连接后会返回 `connected_success` 事件
            type: object
            properties:
              - name: session_id
                type: string
                description: 表示整个会话的 id
                required: false
              - name: event
                type: string
                description: 表示会话事件类型，建连成功后会返回`connected_success`
                required: false
              - name: trace_id
                type: string
                description: 表示会话中单次请求的 id，用于在咨询/反馈时帮助定位问题
                required: false
              - name: base_resp
                type: object
                required: false
                properties:
                  - name: status_code
                    type: integer
                    description: |-
                      状态码，`0`代表建连成功.
                      更多状态码信息请参考 [错误码查询列表](/api-reference/errorcode)
                    required: false
                  - name: status_msg
                    type: string
                    description: 该请求对应的状态码和详情
                    required: false
              - name: connect_id
                type: string
                description: >-
                  表示当前 WebSocket 连接的 id。与 `session_id` 区分：一个连接对应一个
                  `connect_id`，`session_id` 标识连接内的合成会话
                required: false
        headers: []
        jsonPayloadSchema:
          type: object
          properties:
            session_id:
              type: string
              description: 表示整个会话的 id
              x-parser-schema-id: <anonymous-schema-1>
            event:
              type: string
              const: connected_success
              description: 表示会话事件类型，建连成功后会返回`connected_success`
              x-parser-schema-id: <anonymous-schema-2>
            trace_id:
              type: string
              description: 表示会话中单次请求的 id，用于在咨询/反馈时帮助定位问题
              x-parser-schema-id: <anonymous-schema-3>
            base_resp: &ref_0
              type: object
              properties:
                status_code:
                  type: integer
                  description: |-
                    状态码，`0`代表建连成功.
                    更多状态码信息请参考 [错误码查询列表](/api-reference/errorcode)
                  x-parser-schema-id: <anonymous-schema-4>
                status_msg:
                  type: string
                  description: 该请求对应的状态码和详情
                  x-parser-schema-id: <anonymous-schema-5>
              x-parser-schema-id: BaseResp
            connect_id:
              type: string
              description: >-
                表示当前 WebSocket 连接的 id。与 `session_id` 区分：一个连接对应一个
                `connect_id`，`session_id` 标识连接内的合成会话
              x-parser-schema-id: <anonymous-schema-6>
          x-parser-schema-id: ReceiveConnectedSuccessEvent
        title: 建连成功
        description: 成功建立连接后会返回 `connected_success` 事件
        example: |-
          {
            "session_id": "xxxx",
            "event": "connected_success",
            "trace_id": "0303a2882bf18235ae7a809ae0f3cca7",
            "base_resp": {
              "status_code": 0,
              "status_msg": "success"
            },
            "connect_id": "301871346491491"
          }
        bindings: []
        extensions:
          - id: x-parser-unique-object-id
            value: receive_connected_success
      - &ref_11
        id: receive_task_started
        contentType: application/json
        payload:
          - name: 任务开始
            description: 服务端返回 `task_started` 事件，标志着任务已成功开始
            type: object
            properties:
              - name: session_id
                type: string
                description: 表示整个会话的 id
                required: false
              - name: event
                type: string
                description: 表示会话事件类型，当前环节成功后会返回 `task_started`
                required: false
              - name: trace_id
                type: string
                description: 表示会话中单次请求的 id，用于在咨询/反馈时帮助定位问题
                required: false
              - name: base_resp
                type: object
                description: 该请求对应的状态码和详情
                required: false
                properties:
                  - name: status_code
                    type: integer
                    description: |-
                      状态码。
                      - 0: 表示发送成功
                      - 2202: 表示非法事件
                      更多内容可查看 [错误码查询列表](/api-reference/errorcode) 了解详情
                    required: false
                  - name: status_msg
                    type: string
                    description: 状态详情
                    required: false
              - name: connect_id
                type: string
                description: >-
                  表示当前 WebSocket 连接的 id。与 `session_id` 区分：一个连接对应一个
                  `connect_id`，`session_id` 标识连接内的合成会话
                required: false
        headers: []
        jsonPayloadSchema:
          type: object
          properties:
            session_id:
              type: string
              description: 表示整个会话的 id
              x-parser-schema-id: <anonymous-schema-35>
            event:
              type: string
              const: 表示会话事件类型，当前环节成功后会返回 `task_started`
              x-parser-schema-id: <anonymous-schema-36>
            trace_id:
              type: string
              description: 表示会话中单次请求的 id，用于在咨询/反馈时帮助定位问题
              x-parser-schema-id: <anonymous-schema-37>
            base_resp: &ref_1
              type: object
              description: 该请求对应的状态码和详情
              properties:
                status_code:
                  type: integer
                  description: |-
                    状态码。
                    - 0: 表示发送成功
                    - 2202: 表示非法事件
                    更多内容可查看 [错误码查询列表](/api-reference/errorcode) 了解详情
                  x-parser-schema-id: <anonymous-schema-38>
                status_msg:
                  type: string
                  description: 状态详情
                  x-parser-schema-id: <anonymous-schema-39>
              x-parser-schema-id: TaskStartFinishBaseResp
            connect_id:
              type: string
              description: >-
                表示当前 WebSocket 连接的 id。与 `session_id` 区分：一个连接对应一个
                `connect_id`，`session_id` 标识连接内的合成会话
              x-parser-schema-id: <anonymous-schema-40>
          x-parser-schema-id: ReceiveTaskStartedEvent
        title: 任务开始
        description: 服务端返回 `task_started` 事件，标志着任务已成功开始
        example: |-
          {
            "session_id": "xxxx",
            "event": "task_started",
            "trace_id": "0303a2882bf18235ae7a809ae0f3cca7",
            "base_resp": {
              "status_code": 0,
              "status_msg": "success"
            },
            "connect_id": "301871346491491"
          }
        bindings: []
        extensions:
          - id: x-parser-unique-object-id
            value: receive_task_started
      - &ref_12
        id: receive_sentence_start
        contentType: application/json
        payload:
          - name: 分句开始合成
            description: >-
              服务端攒够一个句子并开始合成时返回 `sentence_start` 事件。随后该句的音频通过 `task_continued`
              事件分块返回，直到 `sentence_end`。


              可用它统计服务端实际把文本攒成了多少句
            type: object
            properties:
              - name: session_id
                type: string
                description: 表示整个会话的 id
                required: false
              - name: connect_id
                type: string
                description: >-
                  表示当前 WebSocket 连接的 id。与 `session_id` 区分：一个连接对应一个
                  `connect_id`，`session_id` 标识连接内的合成会话
                required: false
              - name: event
                type: string
                description: 表示会话事件类型，分句开始合成时会返回 `sentence_start`
                required: false
              - name: trace_id
                type: string
                description: 表示会话中单次请求的 id，用于在咨询/反馈时帮助定位问题
                required: false
              - name: base_resp
                type: object
                required: false
                properties:
                  - name: status_code
                    type: integer
                    description: |-
                      状态码，`0`代表建连成功.
                      更多状态码信息请参考 [错误码查询列表](/api-reference/errorcode)
                    required: false
                  - name: status_msg
                    type: string
                    description: 该请求对应的状态码和详情
                    required: false
        headers: []
        jsonPayloadSchema:
          type: object
          properties:
            session_id:
              type: string
              description: 表示整个会话的 id
              x-parser-schema-id: <anonymous-schema-96>
            connect_id:
              type: string
              description: >-
                表示当前 WebSocket 连接的 id。与 `session_id` 区分：一个连接对应一个
                `connect_id`，`session_id` 标识连接内的合成会话
              x-parser-schema-id: <anonymous-schema-97>
            event:
              type: string
              const: sentence_start
              description: 表示会话事件类型，分句开始合成时会返回 `sentence_start`
              x-parser-schema-id: <anonymous-schema-98>
            trace_id:
              type: string
              description: 表示会话中单次请求的 id，用于在咨询/反馈时帮助定位问题
              x-parser-schema-id: <anonymous-schema-99>
            base_resp: *ref_0
          x-parser-schema-id: ReceiveSentenceStartEvent
        title: 分句开始合成
        description: >-
          服务端攒够一个句子并开始合成时返回 `sentence_start` 事件。随后该句的音频通过 `task_continued`
          事件分块返回，直到 `sentence_end`。


          可用它统计服务端实际把文本攒成了多少句
        example: |-
          {
            "session_id": "my-session-001",
            "connect_id": "301871346491491",
            "event": "sentence_start",
            "trace_id": "0303a2882bf18235ae7a809ae0f3cca7",
            "base_resp": {
              "status_code": 0,
              "status_msg": "success"
            }
          }
        bindings: []
        extensions:
          - id: x-parser-unique-object-id
            value: receive_sentence_start
      - &ref_13
        id: receive_task_continued
        contentType: application/json
        payload:
          - name: 任务继续
            description: 服务端返回 `task_continued` 事件，标志着任务已成功继续
            type: object
            properties:
              - name: data
                type: object
                description: '`data` 可能返回为 `null`，参考示例代码时，注意进行非空判断'
                required: false
                properties:
                  - name: audio
                    type: string
                    description: 合成后的音频片段，采用 `hex` 编码，按照输入定义的格式进行生成（mp3/pcm/flac）
                    required: false
                  - name: subtitle
                    type: object
                    description: >-
                      开启字幕时返回，携带当前分段的字幕，随对应的音频片段下发，返回时机见 `task_start` 的
                      `subtitle_type`。`is_final` 为 `true` 的消息不含该字段
                    required: false
                    properties:
                      - name: text
                        type: string
                        description: 分段文本
                        required: false
                      - name: text_begin
                        type: integer
                        description: 分段在本次合成文本中的起始字符位置（含）
                        required: false
                      - name: text_end
                        type: integer
                        description: 分段在本次合成文本中的结束字符位置（不含）
                        required: false
                      - name: time_begin
                        type: number
                        description: 分段起始时间，单位毫秒，相对本次合成音频的起点
                        required: false
                      - name: time_end
                        type: number
                        description: 分段结束时间，单位毫秒，相对本次合成音频的起点
                        required: false
                      - name: timestamped_words
                        type: array
                        description: >-
                          词级时间戳，仅 `subtitle_type` 为 `word` / `word_streaming`
                          时返回，`sentence` 时为 `null`
                        required: false
                        properties:
                          - name: word
                            type: string
                            description: 词文本
                            required: false
                          - name: word_begin
                            type: integer
                            description: 该词在本次合成文本中的起始字符位置（含）
                            required: false
                          - name: word_end
                            type: integer
                            description: 该词在本次合成文本中的结束字符位置（不含）
                            required: false
                          - name: time_begin
                            type: number
                            description: 该词起始时间，单位毫秒
                            required: false
                          - name: time_end
                            type: number
                            description: 该词结束时间，单位毫秒
                            required: false
              - name: trace_id
                type: string
                description: 表示会话中单次请求的 id，用于在咨询/反馈时帮助定位问题。
                required: false
              - name: session_id
                type: string
                description: 表示整个会话的 id。
                required: false
              - name: event
                type: string
                description: 表示会话类型，当前环节成功后会返回 task_continued`
                required: false
              - name: is_final
                type: boolean
                description: 该请求返回是否完结
                required: false
              - name: extra_info
                type: object
                description: 相关额外信息
                required: false
                properties:
                  - name: audio_length
                    type: integer
                    description: 音频时长，精确到毫秒
                    required: false
                  - name: audio_sample_rate
                    type: integer
                    description: 音频采样率
                    required: false
                  - name: audio_size
                    type: integer
                    description: 音频文件大小，单位为字节
                    required: false
                  - name: bitrate
                    type: integer
                    description: 音频比特率
                    required: false
                  - name: audio_format
                    type: string
                    description: 生成音频文件的格式。取值范围 mp3/pcm/flac
                    required: false
                  - name: audio_channel
                    type: integer
                    description: 生成音频声道数。1：单声道，2：双声道
                    required: false
                  - name: invisible_character_ratio
                    type: integer
                    description: 非法字符占比。非法字符不超过 10%（包含 10%），音频会正常生成并返回非法字符占比，超过进行报错
                    required: false
                  - name: usage_characters
                    type: integer
                    description: 计费字符数。本次语音生成的计费字符数
                    required: false
                  - name: usage_voice_count
                    type: integer
                    description: 本次请求计费的音色数量（音色首次使用时计费），仅在产生音色费用时返回
                    required: false
                  - name: word_count
                    type: integer
                    description: 合成文本的字符数（含标点和空格），仅供参考，不用于计费；计费字符数请以 `usage_characters` 为准
                    required: false
              - name: base_resp
                type: object
                description: 本次请求的状态码和详情
                required: false
                properties:
                  - name: status_code
                    type: integer
                    description: >-
                      状态码

                      - 0: 请求结果正常

                      - 1000: 未知错误

                      - 1001: 请求超时

                      - 1002: 触发限流

                      - 1004: 鉴权失败

                      - 1039: 触发 TPM 限流

                      - 1042: 非法字符超过 10%

                      - 2013: 输入参数信息不正常

                      - 2201: 连接空闲超时，被服务端关闭（见接口说明的「连接保活」一节）

                      - 2202: 非法事件

                      - 2204: 单条 `task_continue` 文本超过 10,000 字符，该条被跳过；连接与会话保持

                      - 2205: 排队待合成的文本过多（发送速度超过合成速度）。**这不是配额限流**：连接与会话均保持，稍后重发该条
                      `task_continue` 即可，不要重连或重新 `task_start`

                      - 2206: 事件顺序非法（如已开始任务后重复发送 `task_start`）


                      注意：本接口对纯空白文本会静默丢弃，不会返回 `2203`。

                      更多内容可查看 [错误码查询列表](/api-reference/errorcode) 了解详情
                    required: false
                  - name: status_msg
                    type: string
                    description: 状态详情
                    required: false
              - name: connect_id
                type: string
                description: >-
                  表示当前 WebSocket 连接的 id。与 `session_id` 区分：一个连接对应一个
                  `connect_id`，`session_id` 标识连接内的合成会话
                required: false
        headers: []
        jsonPayloadSchema:
          type: object
          properties:
            data:
              type: object
              description: '`data` 可能返回为 `null`，参考示例代码时，注意进行非空判断'
              properties:
                audio:
                  type: string
                  description: 合成后的音频片段，采用 `hex` 编码，按照输入定义的格式进行生成（mp3/pcm/flac）
                  x-parser-schema-id: <anonymous-schema-44>
                subtitle:
                  type: object
                  description: >-
                    开启字幕时返回，携带当前分段的字幕，随对应的音频片段下发，返回时机见 `task_start` 的
                    `subtitle_type`。`is_final` 为 `true` 的消息不含该字段
                  properties:
                    text:
                      type: string
                      description: 分段文本
                      x-parser-schema-id: <anonymous-schema-46>
                    text_begin:
                      type: integer
                      format: int64
                      description: 分段在本次合成文本中的起始字符位置（含）
                      x-parser-schema-id: <anonymous-schema-47>
                    text_end:
                      type: integer
                      format: int64
                      description: 分段在本次合成文本中的结束字符位置（不含）
                      x-parser-schema-id: <anonymous-schema-48>
                    time_begin:
                      type: number
                      description: 分段起始时间，单位毫秒，相对本次合成音频的起点
                      x-parser-schema-id: <anonymous-schema-49>
                    time_end:
                      type: number
                      description: 分段结束时间，单位毫秒，相对本次合成音频的起点
                      x-parser-schema-id: <anonymous-schema-50>
                    timestamped_words:
                      type: array
                      description: >-
                        词级时间戳，仅 `subtitle_type` 为 `word` / `word_streaming`
                        时返回，`sentence` 时为 `null`
                      items:
                        type: object
                        properties:
                          word:
                            type: string
                            description: 词文本
                            x-parser-schema-id: <anonymous-schema-53>
                          word_begin:
                            type: integer
                            format: int64
                            description: 该词在本次合成文本中的起始字符位置（含）
                            x-parser-schema-id: <anonymous-schema-54>
                          word_end:
                            type: integer
                            format: int64
                            description: 该词在本次合成文本中的结束字符位置（不含）
                            x-parser-schema-id: <anonymous-schema-55>
                          time_begin:
                            type: number
                            description: 该词起始时间，单位毫秒
                            x-parser-schema-id: <anonymous-schema-56>
                          time_end:
                            type: number
                            description: 该词结束时间，单位毫秒
                            x-parser-schema-id: <anonymous-schema-57>
                        x-parser-schema-id: <anonymous-schema-52>
                      x-parser-schema-id: <anonymous-schema-51>
                  x-parser-schema-id: <anonymous-schema-45>
              x-parser-schema-id: <anonymous-schema-43>
            trace_id:
              type: string
              description: 表示会话中单次请求的 id，用于在咨询/反馈时帮助定位问题。
              x-parser-schema-id: <anonymous-schema-58>
            session_id:
              type: string
              description: 表示整个会话的 id。
              x-parser-schema-id: <anonymous-schema-59>
            event:
              type: string
              description: 表示会话类型，当前环节成功后会返回 task_continued`
              x-parser-schema-id: <anonymous-schema-60>
            is_final:
              type: boolean
              description: 该请求返回是否完结
              x-parser-schema-id: <anonymous-schema-61>
            extra_info:
              type: object
              description: 相关额外信息
              properties:
                audio_length:
                  type: integer
                  format: int64
                  description: 音频时长，精确到毫秒
                  x-parser-schema-id: <anonymous-schema-62>
                audio_sample_rate:
                  type: integer
                  format: int64
                  description: 音频采样率
                  x-parser-schema-id: <anonymous-schema-63>
                audio_size:
                  type: integer
                  format: int64
                  description: 音频文件大小，单位为字节
                  x-parser-schema-id: <anonymous-schema-64>
                bitrate:
                  type: integer
                  format: int64
                  description: 音频比特率
                  x-parser-schema-id: <anonymous-schema-65>
                audio_format:
                  type: string
                  description: 生成音频文件的格式。取值范围 mp3/pcm/flac
                  x-parser-schema-id: <anonymous-schema-66>
                audio_channel:
                  type: integer
                  format: int64
                  description: 生成音频声道数。1：单声道，2：双声道
                  x-parser-schema-id: <anonymous-schema-67>
                invisible_character_ratio:
                  type: integer
                  format: float
                  description: 非法字符占比。非法字符不超过 10%（包含 10%），音频会正常生成并返回非法字符占比，超过进行报错
                  x-parser-schema-id: <anonymous-schema-68>
                usage_characters:
                  type: integer
                  format: int64
                  description: 计费字符数。本次语音生成的计费字符数
                  x-parser-schema-id: <anonymous-schema-69>
                usage_voice_count:
                  type: integer
                  format: int64
                  description: 本次请求计费的音色数量（音色首次使用时计费），仅在产生音色费用时返回
                  x-parser-schema-id: <anonymous-schema-70>
                word_count:
                  type: integer
                  format: int64
                  description: 合成文本的字符数（含标点和空格），仅供参考，不用于计费；计费字符数请以 `usage_characters` 为准
                  x-parser-schema-id: <anonymous-schema-71>
              x-parser-schema-id: ExtraInfo
            base_resp:
              type: object
              description: 本次请求的状态码和详情
              properties:
                status_code:
                  type: integer
                  description: >-
                    状态码

                    - 0: 请求结果正常

                    - 1000: 未知错误

                    - 1001: 请求超时

                    - 1002: 触发限流

                    - 1004: 鉴权失败

                    - 1039: 触发 TPM 限流

                    - 1042: 非法字符超过 10%

                    - 2013: 输入参数信息不正常

                    - 2201: 连接空闲超时，被服务端关闭（见接口说明的「连接保活」一节）

                    - 2202: 非法事件

                    - 2204: 单条 `task_continue` 文本超过 10,000 字符，该条被跳过；连接与会话保持

                    - 2205: 排队待合成的文本过多（发送速度超过合成速度）。**这不是配额限流**：连接与会话均保持，稍后重发该条
                    `task_continue` 即可，不要重连或重新 `task_start`

                    - 2206: 事件顺序非法（如已开始任务后重复发送 `task_start`）


                    注意：本接口对纯空白文本会静默丢弃，不会返回 `2203`。

                    更多内容可查看 [错误码查询列表](/api-reference/errorcode) 了解详情
                  x-parser-schema-id: <anonymous-schema-72>
                status_msg:
                  type: string
                  description: 状态详情
                  x-parser-schema-id: <anonymous-schema-73>
              x-parser-schema-id: TaskContinueBaseResp
            connect_id:
              type: string
              description: >-
                表示当前 WebSocket 连接的 id。与 `session_id` 区分：一个连接对应一个
                `connect_id`，`session_id` 标识连接内的合成会话
              x-parser-schema-id: <anonymous-schema-74>
          x-parser-schema-id: ReceiveTaskContinuedEvent
        title: 任务继续
        description: 服务端返回 `task_continued` 事件，标志着任务已成功继续
        example: |-
          {
            "data": {
              "audio": "xxx"
            },
            "extra_info": {
              "audio_channel": 1,
              "audio_format": "mp3",
              "audio_length": 9914,
              "audio_sample_rate": 32000,
              "audio_size": 157869,
              "bitrate": 128000,
              "invisible_character_ratio": 0,
              "usage_characters": 158,
              "word_count": 158
            },
            "is_final": true,
            "session_id": "301871346491491",
            "trace_id": "04ee3794e2c9e4a6d5f99e77742f06fd",
            "base_resp": {
              "status_code": 0,
              "status_msg": "success"
            },
            "connect_id": "301871346491491"
          }
        bindings: []
        extensions:
          - id: x-parser-unique-object-id
            value: receive_task_continued
      - &ref_14
        id: receive_sentence_end
        contentType: application/json
        payload:
          - name: 分句合成结束
            description: >-
              服务端返回 `sentence_end` 事件，表示当前句子的音频已全部返回。


              注意三层结束语义的区别：`is_final` 表示本次请求的音频结束，`sentence_end`
              表示当前句结束，`task_finished` 表示整个会话结束
            type: object
            properties:
              - name: session_id
                type: string
                description: 表示整个会话的 id
                required: false
              - name: connect_id
                type: string
                description: >-
                  表示当前 WebSocket 连接的 id。与 `session_id` 区分：一个连接对应一个
                  `connect_id`，`session_id` 标识连接内的合成会话
                required: false
              - name: event
                type: string
                description: 表示会话事件类型，分句合成结束时会返回 `sentence_end`
                required: false
              - name: trace_id
                type: string
                description: 表示会话中单次请求的 id，用于在咨询/反馈时帮助定位问题
                required: false
              - name: base_resp
                type: object
                required: false
                properties:
                  - name: status_code
                    type: integer
                    description: |-
                      状态码，`0`代表建连成功.
                      更多状态码信息请参考 [错误码查询列表](/api-reference/errorcode)
                    required: false
                  - name: status_msg
                    type: string
                    description: 该请求对应的状态码和详情
                    required: false
        headers: []
        jsonPayloadSchema:
          type: object
          properties:
            session_id:
              type: string
              description: 表示整个会话的 id
              x-parser-schema-id: <anonymous-schema-100>
            connect_id:
              type: string
              description: >-
                表示当前 WebSocket 连接的 id。与 `session_id` 区分：一个连接对应一个
                `connect_id`，`session_id` 标识连接内的合成会话
              x-parser-schema-id: <anonymous-schema-101>
            event:
              type: string
              const: sentence_end
              description: 表示会话事件类型，分句合成结束时会返回 `sentence_end`
              x-parser-schema-id: <anonymous-schema-102>
            trace_id:
              type: string
              description: 表示会话中单次请求的 id，用于在咨询/反馈时帮助定位问题
              x-parser-schema-id: <anonymous-schema-103>
            base_resp: *ref_0
          x-parser-schema-id: ReceiveSentenceEndEvent
        title: 分句合成结束
        description: >-
          服务端返回 `sentence_end` 事件，表示当前句子的音频已全部返回。


          注意三层结束语义的区别：`is_final` 表示本次请求的音频结束，`sentence_end`
          表示当前句结束，`task_finished` 表示整个会话结束
        example: |-
          {
            "session_id": "my-session-001",
            "connect_id": "301871346491491",
            "event": "sentence_end",
            "trace_id": "0303a2882bf18235ae7a809ae0f3cca7",
            "base_resp": {
              "status_code": 0,
              "status_msg": "success"
            }
          }
        bindings: []
        extensions:
          - id: x-parser-unique-object-id
            value: receive_sentence_end
      - &ref_15
        id: receive_task_canceled
        contentType: application/json
        payload:
          - name: 打断成功
            description: 服务端返回 `task_canceled` 事件，表示打断已生效。此后可继续发送 `task_continue`
            type: object
            properties:
              - name: session_id
                type: string
                description: 表示整个会话的 id
                required: false
              - name: connect_id
                type: string
                description: >-
                  表示当前 WebSocket 连接的 id。与 `session_id` 区分：一个连接对应一个
                  `connect_id`，`session_id` 标识连接内的合成会话
                required: false
              - name: event
                type: string
                description: 表示会话事件类型，打断成功后会返回 `task_canceled`
                required: false
              - name: trace_id
                type: string
                description: 表示会话中单次请求的 id，用于在咨询/反馈时帮助定位问题
                required: false
              - name: base_resp
                type: object
                required: false
                properties:
                  - name: status_code
                    type: integer
                    description: |-
                      状态码，`0`代表建连成功.
                      更多状态码信息请参考 [错误码查询列表](/api-reference/errorcode)
                    required: false
                  - name: status_msg
                    type: string
                    description: 该请求对应的状态码和详情
                    required: false
        headers: []
        jsonPayloadSchema:
          type: object
          properties:
            session_id:
              type: string
              description: 表示整个会话的 id
              x-parser-schema-id: <anonymous-schema-92>
            connect_id:
              type: string
              description: >-
                表示当前 WebSocket 连接的 id。与 `session_id` 区分：一个连接对应一个
                `connect_id`，`session_id` 标识连接内的合成会话
              x-parser-schema-id: <anonymous-schema-93>
            event:
              type: string
              const: task_canceled
              description: 表示会话事件类型，打断成功后会返回 `task_canceled`
              x-parser-schema-id: <anonymous-schema-94>
            trace_id:
              type: string
              description: 表示会话中单次请求的 id，用于在咨询/反馈时帮助定位问题
              x-parser-schema-id: <anonymous-schema-95>
            base_resp: *ref_0
          x-parser-schema-id: ReceiveTaskCanceledEvent
        title: 打断成功
        description: 服务端返回 `task_canceled` 事件，表示打断已生效。此后可继续发送 `task_continue`
        example: |-
          {
            "session_id": "my-session-001",
            "connect_id": "301871346491491",
            "event": "task_canceled",
            "trace_id": "0303a2882bf18235ae7a809ae0f3cca7",
            "base_resp": {
              "status_code": 0,
              "status_msg": "success"
            }
          }
        bindings: []
        extensions:
          - id: x-parser-unique-object-id
            value: receive_task_canceled
      - &ref_16
        id: receive_task_flushed
        contentType: application/json
        payload:
          - name: 残留已送出
            description: >-
              服务端返回 `task_flushed`，表示本次 `task_flush` 请求的音频已全部下发完毕。该事件排在本次 flush
              产生的音频帧之后，收到它即可认为这一轮的音频结束。此后可继续发送 `task_continue`。
            type: object
            properties:
              - name: session_id
                type: string
                description: 表示整个会话的 id
                required: false
              - name: connect_id
                type: string
                description: >-
                  表示当前 WebSocket 连接的 id。与 `session_id` 区分：一个连接对应一个
                  `connect_id`，`session_id` 标识连接内的合成会话
                required: false
              - name: event
                type: string
                description: 表示会话事件类型，残留送出完毕后会返回 `task_flushed`
                required: false
              - name: trace_id
                type: string
                description: 表示会话中单次请求的 id，用于在咨询/反馈时帮助定位问题
                required: false
              - name: base_resp
                type: object
                required: false
                properties:
                  - name: status_code
                    type: integer
                    description: |-
                      状态码，`0`代表建连成功.
                      更多状态码信息请参考 [错误码查询列表](/api-reference/errorcode)
                    required: false
                  - name: status_msg
                    type: string
                    description: 该请求对应的状态码和详情
                    required: false
        headers: []
        jsonPayloadSchema:
          type: object
          properties:
            session_id:
              type: string
              description: 表示整个会话的 id
              x-parser-schema-id: <anonymous-schema-76>
            connect_id:
              type: string
              description: >-
                表示当前 WebSocket 连接的 id。与 `session_id` 区分：一个连接对应一个
                `connect_id`，`session_id` 标识连接内的合成会话
              x-parser-schema-id: <anonymous-schema-77>
            event:
              type: string
              const: task_flushed
              description: 表示会话事件类型，残留送出完毕后会返回 `task_flushed`
              x-parser-schema-id: <anonymous-schema-78>
            trace_id:
              type: string
              description: 表示会话中单次请求的 id，用于在咨询/反馈时帮助定位问题
              x-parser-schema-id: <anonymous-schema-79>
            base_resp: *ref_0
          x-parser-schema-id: ReceiveTaskFlushedEvent
        title: 残留已送出
        description: >-
          服务端返回 `task_flushed`，表示本次 `task_flush` 请求的音频已全部下发完毕。该事件排在本次 flush
          产生的音频帧之后，收到它即可认为这一轮的音频结束。此后可继续发送 `task_continue`。
        example: |-
          {
            "session_id": "my-session-001",
            "connect_id": "301871346491491",
            "event": "task_flushed",
            "trace_id": "0303a2882bf18235ae7a809ae0f3cca7",
            "base_resp": {
              "status_code": 0,
              "status_msg": "success"
            }
          }
        bindings: []
        extensions:
          - id: x-parser-unique-object-id
            value: receive_task_flushed
      - &ref_17
        id: receive_task_finished
        contentType: application/json
        payload:
          - name: 任务结束
            description: 服务端返回 `task_finished` 事件，标志着任务已成功结束
            type: object
            properties:
              - name: trace_id
                type: string
                description: 表示会话中单次请求的 id，用于在咨询/反馈时帮助定位问题
                required: false
              - name: session_id
                type: string
                description: 表示整个会话的 id
                required: false
              - name: event
                type: string
                description: 表示会话类型，当前环节成功后会返回 `task_finished`
                required: false
              - name: base_resp
                type: object
                description: 该请求对应的状态码和详情
                required: false
                properties:
                  - name: status_code
                    type: integer
                    description: |-
                      状态码。
                      - 0: 表示发送成功
                      - 2202: 表示非法事件
                      更多内容可查看 [错误码查询列表](/api-reference/errorcode) 了解详情
                    required: false
                  - name: status_msg
                    type: string
                    description: 状态详情
                    required: false
              - name: connect_id
                type: string
                description: >-
                  表示当前 WebSocket 连接的 id。与 `session_id` 区分：一个连接对应一个
                  `connect_id`，`session_id` 标识连接内的合成会话
                required: false
        headers: []
        jsonPayloadSchema:
          type: object
          properties:
            trace_id:
              type: string
              description: 表示会话中单次请求的 id，用于在咨询/反馈时帮助定位问题
              x-parser-schema-id: <anonymous-schema-81>
            session_id:
              type: string
              description: 表示整个会话的 id
              x-parser-schema-id: <anonymous-schema-82>
            event:
              type: string
              description: 表示会话类型，当前环节成功后会返回 `task_finished`
              x-parser-schema-id: <anonymous-schema-83>
            base_resp: *ref_1
            connect_id:
              type: string
              description: >-
                表示当前 WebSocket 连接的 id。与 `session_id` 区分：一个连接对应一个
                `connect_id`，`session_id` 标识连接内的合成会话
              x-parser-schema-id: <anonymous-schema-84>
          x-parser-schema-id: ReceiveTaskFinishedEvent
        title: 任务结束
        description: 服务端返回 `task_finished` 事件，标志着任务已成功结束
        example: |-
          {
            "session_id": "xxxx",
            "event": "task_finished",
            "trace_id": "0303a2882bf18235ae7a809ae0f3cca7",
            "base_resp": {
              "status_code": 0,
              "status_msg": "success"
            },
            "connect_id": "301871346491491"
          }
        bindings: []
        extensions:
          - id: x-parser-unique-object-id
            value: receive_task_finished
      - &ref_18
        id: receive_task_failed
        contentType: application/json
        payload:
          - name: 任务失败
            description: 如果接收到 `task_failed` 事件，表示任务失败。此时需要关闭 WebSocket 连接并处理错误。
            type: object
            properties:
              - name: trace_id
                type: string
                description: 表示会话中单次请求的 id，用于在咨询/反馈时帮助定位问题
                required: false
              - name: session_id
                type: string
                description: 表示整个会话的 id
                required: false
              - name: event
                type: string
                description: 表示会话类型，任务失败会返回 `task_failed`
                required: false
              - name: base_resp
                type: object
                description: 本次请求的状态码和详情
                required: false
                properties:
                  - name: status_code
                    type: integer
                    description: |-
                      状态码
                      - `1000`: 未知错误
                      - `1001`: 超时
                      - `1002`: 触发限流
                      - `1004`: 鉴权失败
                      - `1039`: 触发 TPM 限流
                      - `1042`: 非法字符超过 10%
                      - `2013`: 输入参数信息不正常
                      - `2201`: 连接空闲超时，被服务端关闭（见接口说明的「连接保活」一节）
                      更多内容可查看 [错误码查询列表](/api-reference/errorcode) 了解详情
                    required: false
                  - name: status_msg
                    type: string
                    description: 状态详情
                    required: false
              - name: connect_id
                type: string
                description: >-
                  表示当前 WebSocket 连接的 id。与 `session_id` 区分：一个连接对应一个
                  `connect_id`，`session_id` 标识连接内的合成会话
                required: false
        headers: []
        jsonPayloadSchema:
          type: object
          properties:
            trace_id:
              type: string
              description: 表示会话中单次请求的 id，用于在咨询/反馈时帮助定位问题
              x-parser-schema-id: <anonymous-schema-85>
            session_id:
              type: string
              description: 表示整个会话的 id
              x-parser-schema-id: <anonymous-schema-86>
            event:
              type: string
              description: 表示会话类型，任务失败会返回 `task_failed`
              x-parser-schema-id: <anonymous-schema-87>
            base_resp:
              type: object
              description: 本次请求的状态码和详情
              properties:
                status_code:
                  type: integer
                  description: |-
                    状态码
                    - `1000`: 未知错误
                    - `1001`: 超时
                    - `1002`: 触发限流
                    - `1004`: 鉴权失败
                    - `1039`: 触发 TPM 限流
                    - `1042`: 非法字符超过 10%
                    - `2013`: 输入参数信息不正常
                    - `2201`: 连接空闲超时，被服务端关闭（见接口说明的「连接保活」一节）
                    更多内容可查看 [错误码查询列表](/api-reference/errorcode) 了解详情
                  x-parser-schema-id: <anonymous-schema-88>
                status_msg:
                  type: string
                  description: 状态详情
                  x-parser-schema-id: <anonymous-schema-89>
              x-parser-schema-id: TaskFailedBaseResp
            connect_id:
              type: string
              description: >-
                表示当前 WebSocket 连接的 id。与 `session_id` 区分：一个连接对应一个
                `connect_id`，`session_id` 标识连接内的合成会话
              x-parser-schema-id: <anonymous-schema-90>
          x-parser-schema-id: ReceiveTaskFailedEvent
        title: 任务失败
        description: 如果接收到 `task_failed` 事件，表示任务失败。此时需要关闭 WebSocket 连接并处理错误。
        example: |-
          {
            "session_id": "xxxx",
            "event": "task_failed",
            "trace_id": "0303a2882bf18235ae7a809ae0f3cca7",
            "base_resp": {
              "status_code": 1004,
              "status_msg": "XXXXXXX"
            },
            "connect_id": "301871346491491"
          }
        bindings: []
        extensions:
          - id: x-parser-unique-object-id
            value: receive_task_failed
    bindings: []
    extensions: *ref_2
sendOperations:
  - *ref_3
receiveOperations:
  - *ref_4
sendMessages:
  - *ref_5
  - *ref_6
  - *ref_7
  - *ref_8
  - *ref_9
receiveMessages:
  - *ref_10
  - *ref_11
  - *ref_12
  - *ref_13
  - *ref_14
  - *ref_15
  - *ref_16
  - *ref_17
  - *ref_18
extensions:
  - id: x-parser-unique-object-id
    value: t2a_v2_bidi_websocket
securitySchemes: []

````

> ## Documentation Index
> Fetch the complete documentation index at: https://platform.minimaxi.com/docs/llms.txt
> Use this file to discover all available pages before exploring further.

# 创建异步语音合成任务

> 使用本接口，创建异步语音合成任务。

### 返回文件信息

#### txt 文件

输出文件如下所示

* 音频文件：文件格式遵从请求体设置
* 字幕文件：精确到句的字幕信息
* 额外信息 JSON 文件：音频文件相关的附加信息

#### json 文件

* `title`，若该字段为空，则不输出该字段的文件
  * 音频文件：文件格式遵从请求体设置
  * 字幕文件：精确到句的字幕信息
  * 额外信息 JSON 文件：音频文件相关的附加信息

* `content`，若该字段为空，则不输出该字段的文件
  * 音频文件：文件格式遵从请求体设置
  * 字幕文件：精确到句的字幕信息
  * 额外信息 JSON 文件：音频文件相关的附加信息

* `extra`，若该字段为空，则不输出该字段的文件
  * 音频文件：文件格式遵从请求体设置
  * 字幕文件：精确到句的字幕信息
  * 额外信息 JSON 文件：音频文件相关的附加信息


## OpenAPI

````yaml api-reference/speech/t2a-async/api/openapi.json POST /v1/t2a_async_v2
openapi: 3.1.0
info:
  title: MiniMax T2A Async API
  description: >-
    MiniMax Text-to-Audio Async API with support for long text processing and
    task querying
  license:
    name: MIT
  version: 1.0.0
servers:
  - url: https://api.minimax.cn
security:
  - bearerAuth: []
paths:
  /v1/t2a_async_v2:
    post:
      tags:
        - Text to Audio
      summary: Text to Audio Async V2
      operationId: t2aAsyncV2
      parameters:
        - name: Content-Type
          in: header
          required: true
          description: 请求体的媒介类型，请设置为 `application/json`，确保请求数据的格式为 JSON
          schema:
            type: string
            enum:
              - application/json
            default: application/json
      requestBody:
        content:
          application/json:
            schema:
              $ref: '#/components/schemas/T2AAsyncV2Req'
            examples:
              文本输入:
                value:
                  model: speech-2.8-hd
                  text: 真正的危险不是计算机开始像人一样思考(sighs)，而是人开始像计算机一样思考。计算机只是可以帮我们处理一些简单事务。
                  language_boost: auto
                  voice_setting:
                    voice_id: audiobook_male_1
                    speed: 1
                    vol: 1
                    pitch: 1
                  pronunciation_dict:
                    tone:
                      - 危险/dangerous
                  audio_setting:
                    audio_sample_rate: 32000
                    bitrate: 128000
                    format: mp3
                    channel: 2
                  voice_modify:
                    pitch: 0
                    intensity: 0
                    timbre: 0
                    sound_effects: spacious_echo
              文件输入:
                value:
                  model: speech-2.8-hd
                  text_file_id: text_file_id
                  language_boost: auto
                  voice_setting:
                    voice_id: audiobook_male_1
                    speed: 1
                    vol: 10
                    pitch: 1
                  pronunciation_dict:
                    tone:
                      - 草地/(cao3)(di1)
                  audio_setting:
                    audio_sample_rate: 32000
                    bitrate: 128000
                    format: mp3
                    channel: 2
                  voice_modify:
                    pitch: 0
                    intensity: 0
                    timbre: 0
                    sound_effects: spacious_echo
        required: true
      responses:
        '200':
          description: ''
          content:
            application/json:
              schema:
                $ref: '#/components/schemas/T2AAsyncV2Resp'
              examples:
                文本输入:
                  value:
                    task_id: 95157322514444
                    task_token: eyJhbGciOiJSUz
                    file_id: 95157322514444
                    usage_characters: 101
                    base_resp:
                      status_code: 0
                      status_msg: success
                文件输入:
                  value:
                    task_id: 95157322514444
                    task_token: eyJhbGciOiJSUz
                    file_id: 95157322514444
                    usage_characters: 101
                    base_resp:
                      status_code: 0
                      status_msg: success
components:
  schemas:
    T2AAsyncV2Req:
      type: object
      required:
        - model
        - text
        - text_file_id
        - voice_setting
      properties:
        model:
          type: string
          description: >-
            请求的模型版本，可选范围：`speech-2.8-hd`, `speech-2.8-turbo`, `speech-2.6-hd`,
            `speech-2.6-turbo`, `speech-02-hd`, `speech-02-turbo`,
            `speech-01-hd`, `speech-01-turbo`.
          enum:
            - speech-2.8-hd
            - speech-2.8-turbo
            - speech-2.6-hd
            - speech-2.6-turbo
            - speech-02-hd
            - speech-02-turbo
            - speech-01-hd
            - speech-01-turbo
        text:
          type: string
          description: >-
            待合成音频的文本，限制最长 5 万字符。和 `text_file_id` 二选一必填

            - 语气词标签：仅当模型选择 `speech-2.8-hd` 或 `speech-2.8-turbo`
            时，支持在文本中插入语气词标签。支持的语气词：`(laughs)`（笑声）、`(chuckle)`（轻笑）、`(coughs)`（咳嗽）、`(clear-throat)`（清嗓子）、`(groans)`（呻吟）、`(breath)`（正常换气）、`(pant)`（喘气）、`(inhale)`（吸气）、`(exhale)`（呼气）、`(gasps)`（倒吸气）、`(sniffs)`（吸鼻子）、`(sighs)`（叹气）、`(snorts)`（喷鼻息）、`(burps)`（打嗝）、`(lip-smacking)`（咂嘴）、`(humming)`（哼唱）、`(hissing)`（嘶嘶声）、`(emm)`（嗯）、`(whistles)`（口哨）、`(sneezes)`（喷嚏）、`(crying)`（抽泣）、`(applause)`（鼓掌）
        text_file_id:
          type: integer
          format: int64
          description: "待合成音频的文本文件 待合成音频的文本文件 id，单个文件长度限制小于 100 万字符，支持的文件格式：txt、zip。和 `text` 二选一必填，传入后自动校验格式。\n- **txt 文件**：长度限制 <1,000,000 字符。支持使用 <#x#> 标记自定义停顿。x 为停顿时长（单位：秒），范围 [0.01,99.99]，最多保留两位小数。注意停顿需设置在两个可以语音发音的文本之间，不可连续使用多个停顿标记\n- **zip 文件**：\n\t- 压缩包内需包含同一格式的 txt 或 json 文件。\n\t- json 文件格式：支持 [`title`, `content`, `extra`] 三个字段，分别表示标题、正文、附加信息。若三个字段都存在，则产出 3 组结果，共 9 个文件，统一存放在一个文件夹中。若某字段不存在或内容为空，则该字段不会生成对应结果"
        voice_setting:
          $ref: '#/components/schemas/T2AAsyncV2VoiceSetting'
        audio_setting:
          $ref: '#/components/schemas/T2AAsyncV2AudioSetting'
        pronunciation_dict:
          $ref: '#/components/schemas/T2AAsyncV2PronunciationDict'
        language_boost:
          type: string
          description: |-
            是否增强对指定的小语种和方言的识别能力。默认值为 `null`，可设置为 `auto` 让模型自主判断。

            注意：speech-01 和 speech-02 系列模型暂不支持 Persian、Filipino、Tamil 这三个语种。
          enum:
            - Chinese
            - Chinese,Yue
            - English
            - Arabic
            - Russian
            - Spanish
            - French
            - Portuguese
            - German
            - Turkish
            - Dutch
            - Ukrainian
            - Vietnamese
            - Indonesian
            - Japanese
            - Italian
            - Korean
            - Thai
            - Polish
            - Romanian
            - Greek
            - Czech
            - Finnish
            - Hindi
            - Bulgarian
            - Danish
            - Hebrew
            - Malay
            - Persian
            - Slovak
            - Swedish
            - Croatian
            - Filipino
            - Hungarian
            - Norwegian
            - Slovenian
            - Catalan
            - Nynorsk
            - Tamil
            - Afrikaans
            - auto
          default: null
        voice_modify:
          $ref: '#/components/schemas/VoiceModify'
        aigc_watermark:
          type: boolean
          description: 控制在合成音频的末尾添加音频节奏标识，默认值为 False。该参数仅对非流式合成生效
          default: false
    T2AAsyncV2Resp:
      type: object
      properties:
        task_id:
          type: string
          description: 当前任务的 ID
        file_id:
          type: integer
          format: int64
          description: >-
            任务创建成功后返回的对应音频文件的 ID。

            - 当任务完成后，可通过 file_id 调用
            [文件检索接口](/api-reference/file-management-retrieve) 进行下载

            - 当请求出错时，不返回该字段

            注意：返回的下载 URL 自生成起 9 小时（32,400 秒）内有效，过期后文件将失效，生成的信息便会丢失，请注意下载信息的时间
        task_token:
          type: string
          description: 完成当前任务使用的密钥信息
        usage_characters:
          type: integer
          description: 计费字符数
        base_resp:
          $ref: '#/components/schemas/BaseResp'
    T2AAsyncV2VoiceSetting:
      type: object
      required:
        - voice_id
      properties:
        voice_id:
          type: string
          description: "合成音频的音色编号。若需要设置混合音色，请设置 timbre_weights 参数，本参数设置为空值。支持系统音色、复刻音色以及文生音色三种类型，以下是部分最新的系统音色（ID），可查看 [系统音色列表](/faq/system-voice-id) 或使用 [查询可用音色 API](/api-reference/voice-management-get) 查询系统支持的全部音色\n\n - **中文**:\n\t- moss_audio_ce44fc67-7ce3-11f0-8de5-96e35d26fb85\n\t- moss_audio_aaa1346a-7ce7-11f0-8e61-2e6e3c7ee85d\n\t- Chinese (Mandarin)_Lyrical_Voice\n\t- Chinese (Mandarin)_HK_Flight_Attendant\n- **英文**:\n\t- English_Graceful_Lady\n\t- English_Insightful_Speaker\n\t- English_radiant_girl\n\t- English_Persuasive_Man\n\t- moss_audio_6dc281eb-713c-11f0-a447-9613c873494c\n\t- moss_audio_570551b1-735c-11f0-b236-0adeeecad052\n\t- moss_audio_ad5baf92-735f-11f0-8263-fe5a2fe98ec8\n\t- English_Lucky_Robot\n- **日文**:\n\t- Japanese_Whisper_Belle\n\t- moss_audio_24875c4a-7be4-11f0-9359-4e72c55db738\n\t- moss_audio_7f4ee608-78ea-11f0-bb73-1e2a4cfcd245\n\t- moss_audio_c1a6a3ac-7be6-11f0-8e8e-36b92fbb4f95"
        speed:
          type: number
          format: float
          description: 合成音频的语速，取值越大，语速越快。取值范围 `[0.5,2]`，默认值为1.0
          minimum: 0.5
          maximum: 2
          default: 1
        vol:
          type: number
          format: float
          description: 合成音频的音量，取值越大，音量越高。取值范围 `(0,10]`，默认值为 1.0
          exclusiveMinimum: 0
          maximum: 10
          default: 1
        pitch:
          type: integer
          description: 合成音频的语调，取值范围 `[-12,12]`，默认值为 0，其中 0 为原音色输出
          minimum: -12
          maximum: 12
          default: 0
        emotion:
          type: string
          description: "控制合成语音的情绪，参数范围 `[\"happy\", \"sad\", \"angry\", \"fearful\", \"disgusted\", \"surprised\", \"calm\", \"fluent\", \"whisper\"]`，分别对应 8 种情绪：高兴，悲伤，愤怒，害怕，厌恶，惊讶，中性，生动，低语 \r\n- 模型会根据输入文本自动匹配合适的情绪，一般无需手动指定  \r\n- 该参数仅对 `speech-2.8-hd`, `speech-2.8-turbo`, `speech-2.6-hd`, `speech-2.6-turbo`, `speech-02-hd`, `speech-02-turbo`, `speech-01-hd`, `speech-01-turbo` 模型生效 \r\n- 选项 `fluent`, `whisper` 仅对 `speech-2.6-turbo`, `speech-2.6-hd` 模型生效，`speech-2.8-hd`, `speech-2.8-turbo` 模型不支持 `whisper`"
          enum:
            - happy
            - sad
            - angry
            - fearful
            - disgusted
            - surprised
            - calm
            - fluent
            - whisper
        english_normalization:
          type: boolean
          description: 支持英语文本规范化，开启后可提升数字阅读场景的性能，但会略微增加延迟，默认 false
          default: false
    T2AAsyncV2AudioSetting:
      type: object
      properties:
        audio_sample_rate:
          type: integer
          format: int64
          default: 32000
          description: >-
            生成音频的采样率。可选范围 `[8000，16000，22050，24000，32000，44100]`，默认为 `32000`。

            注意：当输出格式为 `opus` 时，仅支持 `[8000, 12000, 16000, 24000,
            48000]`，使用其他采样率会导致任务报错。
        bitrate:
          type: integer
          format: int64
          default: 128000
          description: >-
            生成音频的比特率。可选范围 `[32000，64000，128000，256000]`，默认值为 `128000`。该参数仅对
            `mp3` 格式的音频生效
        format:
          type: string
          description: >-
            生成音频的格式。可选范围 `[mp3, pcm, flac, wav, pcmu_raw, pcmu_wav, opus]`，默认值为
            `mp3`。`pcmu_raw` 与 `pcmu_wav` 为 G.711 μ-law 编码（采样率 8 kHz；`pcmu_raw`
            为无文件头裸数据，`pcmu_wav` 封装在 WAV 容器中）。`opus` 为 Ogg/Opus 编码，仅支持采样率 `[8000,
            12000, 16000, 24000, 48000]`，使用其他采样率会导致任务报错。
          enum:
            - mp3
            - pcm
            - flac
            - wav
            - pcmu_raw
            - pcmu_wav
            - opus
          default: mp3
        channel:
          type: integer
          format: int64
          default: 2
          description: 生成音频的声道数。可选范围：`[1,2]`，其中 `1` 为单声道，`2` 为双声道，默认值为 2
    T2AAsyncV2PronunciationDict:
      type: object
      properties:
        tone:
          type: array
          description: |-
            定义需要特殊标注的文字或符号对应的注音或发音替换规则。在中文文本中，声调用数字表示：
            一声为 1，二声为 2，三声为 3，四声为 4，轻声为 5
            示例如下：
            `["燕少飞/(yan4)(shao3)(fei1)", "omg/oh my god"]`
          items:
            type: string
    VoiceModify:
      type: object
      description: >-
        声音效果器设置。


        支持的音频格式：`mp3`、`wav`、`flac`。（其他格式如 `pcm`、`pcmu_raw`、`pcmu_wav`、`opus`
        不支持，传入会返回参数错误。）
      properties:
        pitch:
          type: integer
          description: >-
            音高调整（低沉/明亮），范围 [-100,100]，数值接近 -100，声音更低沉；接近 100，声音更明亮


            ![pitch
            adjustment](https://filecdn.minimax.chat/public/5d210c47-4236-4e81-893b-16cc1ef0302d.png)
          minimum: -100
          maximum: 100
        intensity:
          type: integer
          description: >-
            强度调整（力量感/柔和），范围 [-100,100]，数值接近 -100，声音更刚劲；接近 100，声音更轻柔


            ![intensity
            adjustment](https://filecdn.minimax.chat/public/862d493e-71d5-4d1f-b7c3-9ac51890631b.png)
          minimum: -100
          maximum: 100
        timbre:
          type: integer
          description: >-
            音色调整（磁性/清脆），范围 [-100,100]，数值接近 -100，声音更浑厚；数值接近 100，声音更清脆


            ![timbre
            adjustment](https://filecdn.minimax.chat/public/5f0e6cae-363a-452b-8d42-fbc4ef5a0510.png)
          minimum: -100
          maximum: 100
        sound_effects:
          type: string
          description: |-
            音效设置，单次仅能选择一种，可选值：
            1. spacious_echo（空旷回音）
            2. auditorium_echo（礼堂广播）
            3. lofi_telephone（电话失真）
            4. robotic（电音）
          enum:
            - spacious_echo
            - auditorium_echo
            - lofi_telephone
            - robotic
    BaseResp:
      type: object
      description: 本次请求的状态码及其详情
      required:
        - status_code
        - status_msg
      properties:
        status_code:
          type: integer
          format: int64
          description: |-
            状态码

            - `0`: 正常
            - `1002`: 限流
            - `1004`: 鉴权失败
            - `1039`: 触发 TPM 限流
            - `1042`: 非法字符超10%
            - `2013`: 参数错误

            更多内容可查看 [错误码查询列表](/api-reference/errorcode) 了解详情
        status_msg:
          type: string
          description: 状态详情
  securitySchemes:
    bearerAuth:
      type: http
      scheme: bearer
      bearerFormat: JWT
      description: |-
        `HTTP: Bearer Auth`
         - Security Scheme Type: http
         - HTTP Authorization Scheme: Bearer API_key，用于验证账户信息，可在 [账户管理>接口密钥](https://platform.minimax.cn/user-center/basic-information/interface-key) 中查看。

````
> ## Documentation Index
> Fetch the complete documentation index at: https://platform.minimaxi.com/docs/llms.txt
> Use this file to discover all available pages before exploring further.

# 查询语音生成任务状态

> 使用本接口，查询异步语音合成任务状态。

**注：该 API 限制每秒最多查询 10 次。**


## OpenAPI

````yaml api-reference/speech/t2a-async/api/openapi.json GET /v1/query/t2a_async_query_v2
openapi: 3.1.0
info:
  title: MiniMax T2A Async API
  description: >-
    MiniMax Text-to-Audio Async API with support for long text processing and
    task querying
  license:
    name: MIT
  version: 1.0.0
servers:
  - url: https://api.minimax.cn
security:
  - bearerAuth: []
paths:
  /v1/query/t2a_async_query_v2:
    get:
      tags:
        - Text to Audio
      summary: Query T2A Async V2 Task Status
      operationId: t2aAsyncV2Query
      parameters:
        - name: task_id
          in: query
          required: true
          description: 任务 ID，提交任务时返回的信息
          schema:
            type: integer
            format: int64
      responses:
        '200':
          description: ''
          content:
            application/json:
              schema:
                $ref: '#/components/schemas/T2AAsyncV2QueryResp'
components:
  schemas:
    T2AAsyncV2QueryResp:
      type: object
      properties:
        task_id:
          type: integer
          format: int64
          description: 任务 ID
        status:
          type: string
          description: |-
            该任务的当前状态。

            - **Processing**: 该任务正在处理中
            - **Success**: 该任务已完成
            - **Failed**: 任务失败
            - **Expired**: 任务已过期
          enum:
            - success
            - failed
            - expired
            - processing
        file_id:
          type: integer
          format: int64
          description: >-
            任务创建成功后返回的对应音频文件的 ID。

            - 当任务完成后，可通过 file_id 调用
            [文件检索接口](/api-reference/file-management-retrieve) 进行下载

            - 当请求出错时，不返回该字段

            注意：返回的下载 URL 自生成起 9 小时（32,400 秒）内有效，过期后文件将失效，生成的信息便会丢失，请注意下载信息的时间
        base_resp:
          $ref: '#/components/schemas/BaseResp'
      example:
        task_id: 95157322514444
        status: Processing
        file_id: 95157322514496
        base_resp:
          status_code: 0
          status_msg: success
    BaseResp:
      type: object
      description: 本次请求的状态码及其详情
      required:
        - status_code
        - status_msg
      properties:
        status_code:
          type: integer
          format: int64
          description: |-
            状态码

            - `0`: 正常
            - `1002`: 限流
            - `1004`: 鉴权失败
            - `1039`: 触发 TPM 限流
            - `1042`: 非法字符超10%
            - `2013`: 参数错误

            更多内容可查看 [错误码查询列表](/api-reference/errorcode) 了解详情
        status_msg:
          type: string
          description: 状态详情
  securitySchemes:
    bearerAuth:
      type: http
      scheme: bearer
      bearerFormat: JWT
      description: |-
        `HTTP: Bearer Auth`
         - Security Scheme Type: http
         - HTTP Authorization Scheme: Bearer API_key，用于验证账户信息，可在 [账户管理>接口密钥](https://platform.minimax.cn/user-center/basic-information/interface-key) 中查看。

````

> ## Documentation Index
> Fetch the complete documentation index at: https://platform.minimaxi.com/docs/llms.txt
> Use this file to discover all available pages before exploring further.

# 音色设计

> 使用本接口，输入文本内容，进行音色设计。



## OpenAPI

````yaml api-reference/speech/voice-design/api/openapi.json POST /v1/voice_design
openapi: 3.1.0
info:
  title: MiniMax Voice Design API
  description: MiniMax Voice Design API with support for voice generation from text prompts
  license:
    name: MIT
  version: 1.0.0
servers:
  - url: https://api.minimax.cn
security:
  - bearerAuth: []
paths:
  /v1/voice_design:
    post:
      tags:
        - Voice
      summary: Voice Design
      operationId: voiceDesign
      parameters:
        - name: Content-Type
          in: header
          required: true
          description: 请求体的媒介类型，请设置为 `application/json`，确保请求数据的格式为 JSON
          schema:
            type: string
            enum:
              - application/json
            default: application/json
      requestBody:
        content:
          application/json:
            schema:
              $ref: '#/components/schemas/T2VReq'
        required: true
      responses:
        '200':
          description: ''
          content:
            application/json:
              schema:
                $ref: '#/components/schemas/T2VResp'
components:
  schemas:
    T2VReq:
      type: object
      required:
        - prompt
        - preview_text
      properties:
        prompt:
          type: string
          description: 音色描述。
        preview_text:
          type: string
          description: |-
            试听音频文本。
            注：试听音频的合成将收取 2 元/万字符的费用
          maxLength: 500
        voice_id:
          type: string
          description: 自定义生成音色的 voice_id。当不传入此参数时，将自动生成并返回一个唯一的 `voice_id`
        aigc_watermark:
          type: boolean
          description: 是否在合成试听音频的末尾添加音频节奏标识，默认值为 False
      example:
        prompt: 讲述悬疑故事的播音员，声音低沉富有磁性，语速时快时慢，营造紧张神秘的氛围。
        preview_text: 夜深了，古屋里只有他一人。窗外传来若有若无的脚步声，他屏住呼吸，慢慢地，慢慢地，走向那扇吱呀作响的门……
    T2VResp:
      type: object
      properties:
        voice_id:
          type: string
          description: 生成的音色 ID，可用于语音合成
        trial_audio:
          type: string
          description: 使用生成的音色合成的试听音频，以 hex 编码形式返回
        base_resp:
          type: object
          description: 状态码和状态详情
          properties:
            status_code:
              type: integer
              format: int64
              description: |-
                状态码。

                - `0`: 请求结果正常
                - `1000`: 未知错误
                - `1001`: 超时
                - `1002`: 触发 RPM 限流
                - `1004`: 鉴权失败
                - `1008`: 余额不足
                - `1013`: 服务内部错误
                - `1027`: 输出内容错误
                - `1039`: 触发 TPM 限流
                - `2013`: 输入格式信息不正常

                更多内容可查看 [错误码查询列表](/api-reference/errorcode) 了解详情
            status_msg:
              type: string
              description: 状态详情
      example:
        trial_audio: hex 编码音频
        voice_id: ttv-voice-2025060717322425-xxxxxxxx
        base_resp:
          status_code: 0
          status_msg: success
  securitySchemes:
    bearerAuth:
      type: http
      scheme: bearer
      bearerFormat: JWT
      description: |-
        `HTTP: Bearer Auth`
         - Security Scheme Type: http
         - HTTP Authorization Scheme: Bearer API_key，用于验证账户信息，可在 [账户管理>接口密钥](https://platform.minimax.cn/user-center/basic-information/interface-key) 中查看。

````
> ## Documentation Index
> Fetch the complete documentation index at: https://platform.minimaxi.com/docs/llms.txt
> Use this file to discover all available pages before exploring further.

# 查询可用音色ID

> 使用本接口支持查询不同分类下的音色信息。

该 API 支持查询**当前账号**下可调用的**全部音色 ID**（voice\_id）。

包括系统音色、快速克隆音色、文生音色接口生成的音色、音乐生成接口的人声音色以及伴奏音色。

<Note>
  快速复刻得到的音色为未激活状态，需正式调用一次才可在本接口查询到
</Note>


## OpenAPI

````yaml api-reference/speech/voice-management/api/openapi.json POST /v1/get_voice
openapi: 3.1.0
info:
  title: MiniMax Voice Management API
  description: MiniMax Voice Management API with support for getting and deleting voices
  license:
    name: MIT
  version: 1.0.0
servers:
  - url: https://api.minimax.cn
security:
  - bearerAuth: []
paths:
  /v1/get_voice:
    post:
      tags:
        - Voice
      summary: Get Voice
      operationId: getVoice
      parameters:
        - name: Content-Type
          in: header
          required: true
          description: 请求体的媒介类型，请设置为 `application/json`，确保请求数据的格式为 JSON
          schema:
            type: string
            enum:
              - application/json
            default: application/json
      requestBody:
        description: ''
        content:
          application/json:
            schema:
              $ref: '#/components/schemas/GetVoiceReq'
        required: true
      responses:
        '200':
          description: ''
          content:
            application/json:
              schema:
                $ref: '#/components/schemas/GetVoiceResp'
components:
  schemas:
    GetVoiceReq:
      type: object
      required:
        - voice_type
      properties:
        voice_type:
          type: string
          description: |-
            希望查询音色类型，支持以下取值：

            - `system`: 系统音色
            - `voice_cloning`: 快速复刻的音色，仅在成功用于语音合成后才可查询
            - `voice_generation`: 文生音色接口生成的音色，仅在成功用于语音合成后才可查询
            - `all`: 以上全部
          enum:
            - system
            - voice_cloning
            - voice_generation
            - all
      example:
        voice_type: all
    GetVoiceResp:
      type: object
      properties:
        system_voice:
          type: array
          items:
            $ref: '#/components/schemas/SystemVoiceInfo'
          description: 包含系统预定义的音色。
        voice_cloning:
          type: array
          items:
            $ref: '#/components/schemas/VoiceCloningInfo'
          description: 包含音色快速复刻的音色数据
        voice_generation:
          type: array
          items:
            $ref: '#/components/schemas/VoiceGenerationInfo'
          description: 包含音色生成接口产生的音色数据
        base_resp:
          $ref: '#/components/schemas/BaseResp'
      example:
        system_voice:
          - voice_id: Chinese (Mandarin)_Reliable_Executive
            description:
              - 一位沉稳可靠的中年男性高管声音，标准普通话，传递出值得信赖的感觉。
            voice_name: 沉稳高管
            created_time: '1970-01-01'
          - voice_id: Chinese (Mandarin)_News_Anchor
            description:
              - 一位专业、播音腔的中年女性新闻主播，标准普通话。
            voice_name: 新闻女声
            created_time: '1970-01-01'
        voice_cloning:
          - voice_id: test12345
            description: []
            created_time: '2025-08-20'
          - voice_id: test12346
            description: []
            created_time: '2025-08-21'
        voice_generation:
          - voice_id: ttv-voice-2025082011321125-2uEN0X1S
            description: []
            created_time: '2025-08-20'
          - voice_id: ttv-voice-2025082014225025-ZCQt0U0k
            description: []
            created_time: '2025-08-20'
        base_resp:
          status_code: 0
          status_msg: success
    SystemVoiceInfo:
      type: object
      properties:
        voice_id:
          type: string
          description: 音色 ID
        voice_name:
          type: string
          description: 音色名称，非调用的音色 ID
        description:
          type: array
          items:
            type: string
          description: 音色描述
    VoiceCloningInfo:
      type: object
      properties:
        voice_id:
          type: string
          description: 音色 ID
        description:
          type: array
          items:
            type: string
          description: 生成音色时填写的音色描述
        created_time:
          type: string
          description: 创建时间，格式 yyyy-mm-dd
    VoiceGenerationInfo:
      type: object
      properties:
        voice_id:
          type: string
          description: 音色 ID
        description:
          type: array
          items:
            type: string
          description: 生成音色时填写的音色描述
        created_time:
          type: string
          description: 创建时间，格式 yyyy-mm-dd
    BaseResp:
      type: object
      description: 本次请求的状态码和详情
      properties:
        status_code:
          type: integer
          format: int64
          description: |-
            状态码。

            - `0`: 请求结果正常
            - `2013`: 输入参数信息不正常

            更多内容可查看 [错误码查询列表](/api-reference/errorcode) 了解详情
        status_msg:
          type: string
          description: 状态详情
  securitySchemes:
    bearerAuth:
      type: http
      scheme: bearer
      bearerFormat: JWT
      description: |-
        `HTTP: Bearer Auth`
         - Security Scheme Type: http
         - HTTP Authorization Scheme: Bearer API_key，用于验证账户信息，可在 [账户管理>接口密钥](https://platform.minimax.cn/user-center/basic-information/interface-key) 中查看。

````
> ## Documentation Index
> Fetch the complete documentation index at: https://platform.minimaxi.com/docs/llms.txt
> Use this file to discover all available pages before exploring further.

# 删除音色 

> 使用本接口，对于生成的部分音色进行删除。

该 API 用于删除指定 voice\_id 的音色，删除范围为通过 [Voice Cloning API](/docs/api-reference/voice-cloning-clone) 和 [Voice Generation API](/docs/api-reference/voice-design-design) 生成的音色的 voice\_id。

⚠️ 注意：删除后，该 voice\_id 将无法再次使用。


## OpenAPI

````yaml api-reference/speech/voice-management/api/openapi.json POST /v1/delete_voice
openapi: 3.1.0
info:
  title: MiniMax Voice Management API
  description: MiniMax Voice Management API with support for getting and deleting voices
  license:
    name: MIT
  version: 1.0.0
servers:
  - url: https://api.minimax.cn
security:
  - bearerAuth: []
paths:
  /v1/delete_voice:
    post:
      tags:
        - Voice
      summary: Delete Voice
      description: Delete a voice by ID and type
      operationId: deleteVoice
      parameters:
        - name: Content-Type
          in: header
          required: true
          description: 请求体的媒介类型，请设置为 `application/json`，确保请求数据的格式为 JSON
          schema:
            type: string
            enum:
              - application/json
            default: application/json
      requestBody:
        content:
          application/json:
            schema:
              $ref: '#/components/schemas/DeleteVoiceReq'
        required: true
      responses:
        '200':
          description: Successful response
          content:
            application/json:
              schema:
                $ref: '#/components/schemas/DeleteVoiceResp'
components:
  schemas:
    DeleteVoiceReq:
      type: object
      required:
        - voice_type
        - voice_id
      properties:
        voice_type:
          type: string
          description: >-
            取值范围：`voice_cloning`（克隆的音色）/`voice_generation`（基于文本提示生成的音色），注意仅支持删除这两种类别的音色
          enum:
            - voice_cloning
            - voice_generation
        voice_id:
          type: string
          description: 希望删除音色的 voice_id
      example:
        voice_type: voice_cloning
        voice_id: yanshang11123
    DeleteVoiceResp:
      type: object
      properties:
        voice_id:
          type: string
          description: 被删除声音的 voice_id
        created_time:
          type: string
          description: 该音色生成请求提交的时间，非首次调用生效激活时间，格式为 `yyyy-mm-dd`
        base_resp:
          $ref: '#/components/schemas/DeleteBaseResp'
      example:
        voice_id: yanshang11123
        created_time: '1728962464'
        base_resp:
          status_code: 0
          status_msg: success
    DeleteBaseResp:
      type: object
      description: 状态码及状态详情
      properties:
        status_code:
          type: integer
          format: int64
          description: |-
            状态码

            - `0`: 删除成功
            - `2013`: 输入参数信息不正常

            更多内容可查看 [错误码查询列表](/api-reference/errorcode) 了解详情
        status_msg:
          type: string
          description: 状态详情
  securitySchemes:
    bearerAuth:
      type: http
      scheme: bearer
      bearerFormat: JWT
      description: |-
        `HTTP: Bearer Auth`
         - Security Scheme Type: http
         - HTTP Authorization Scheme: Bearer API_key，用于验证账户信息，可在 [账户管理>接口密钥](https://platform.minimax.cn/user-center/basic-information/interface-key) 中查看。

````
