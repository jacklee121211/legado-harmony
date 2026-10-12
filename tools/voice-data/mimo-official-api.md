语音合成（MiMo-TTS 系列）- OpenAI API 兼容
请求地址
https://api.xiaomimimo.com/v1/chat/completions

请求头
接口支持以下两种认证方式，请选择其中一种添加到请求头中：

API Key 鉴权
Bearer 鉴权
api-key: $MIMO_API_KEY
Content-Type: application/json

请求体
messages
array
必选
对话的消息列表。

User message · object

Assistant message · object
由终端用户发送的消息，包含提示或额外的上下文信息。
注意：使用 mimo-v2.5-tts-voicedesign 模型生成音频时，该消息为必填，用于指定音色设计描述文本。
messages.content
string
必选
用户消息的内容。
messages.role
string
必选
用户消息的角色。
可选值：user
model
string
必选
用于生成响应的模型 ID。
可选值：mimo-v2.5-tts，mimo-v2.5-tts-voicedesign，mimo-v2.5-tts-voiceclone
audio
object
音频输出参数。详情请参考语音合成。
注意：如果要生成音频，必须添加一条 role 为 assistant 的消息，该消息需指定用于音频合成的文本。此外，使用 mimo-v2.5-tts-voicedesign 模型时，role 为 user 的消息为必填，若将optimize_text_preview 设置为 true，则可省略 assistant 消息。
audio.format
string
默认值: wav
指定输出音频格式。默认值：wav，如果设置 stream: true 则为 pcm。
传入 pcm 或 pcm16，均表示指定使用 pcm16 格式。
可选值：wav，mp3，pcm，pcm16
audio.optimize_text_preview
boolean
默认值: false
是否开启目标音频播报文本智能优化能力。
设置为 true 时，会对传入的目标文本做智能润色；若未传入目标文本，则自动生成适配播报场景的目标文本，再将处理完成的最终文本送入模型进行合成。
注意：该参数为 true 时，可省略传入用于指定音频合成内容的 assistant 消息。
仅支持 mimo-v2.5-tts-voicedesign 模型。
audio.voice
string
预置音色的音色ID 或音频样本的 base64 编码。
mimo-v2.5-tts：该字段为可选，且仅支持使用预置音色，默认值为 mimo_default
mimo-v2.5-tts-voiceclone：该字段为必填，且仅支持传入音频样本的 base64 编码，仅支持传入 mp3 和 wav 格式的音频样本文件
mimo-v2.5-tts-voicedesign：不支持该字段
可选值：
mimo-v2.5-tts：mimo_default，冰糖，茉莉，苏打，白桦，Mia，Chloe，Milo，Dean
stream
boolean
默认值: false
如果设置为 true，模型的响应数据会在生成过程中通过SSE（server-sent events）的形式流式传输到客户端。
Chat 响应对象（非流式输出）
choices
array
包含生成的回复选项列表。
choices.finish_reason
string
模型停止生成 token 的原因：
stop：模型到达自然结束点或触发了用户指定的停止序列
length：因超出模型最大生成长度而终止
content_filter：内容因触发过滤策略而被拦截
choices.index
integer
选项列表中对应选项的索引。
choices.message
object
模型生成的对话补全消息。
choices.message.content
string
消息的内容。
choices.message.role
string
消息作者的角色。
choices.message.audio
object
如果请求输出音频，该对象将包含有关模型音频响应的数据。
choices.message.audio.id
string
此音频响应的唯一标识符。
choices.message.audio.data
string
模型生成的 Base64 编码音频，格式为请求中指定的格式。
choices.message.audio.expires_at
number | null
此音频响应过期的 Unix 时间戳（以秒为单位）。当前仅为 null。
choices.message.audio.transcript
string | null
模型生成的音频的文字记录。当前仅为 null。
choices.message.final_text_preview
string
经过智能优化润色后的音频播报最终文本。仅当请求参数 optimize_text_preview 设为 true 时，该字段才会返回。
created
integer
对话补全对象创建时的 Unix 时间戳（以秒为单位）。
id
string
响应的唯一标识符。
model
string
用于生成结果的模型。
object
string
对象类型，仅为 chat.completion。
usage
object | null
该对话补全请求的用量信息。
usage.completion_tokens
integer
模型输出内容花费的 token。
usage.prompt_tokens
integer
提示词使用的 token 数量。
usage.total_tokens
integer
请求中使用的 token 总数（提示词 + 补全结果）。
usage.completion_tokens_details
object
补全中使用的 token 数量明细。
usage.completion_tokens_details.reasoning_tokens
integer
模型为推理生成的 token 数量，固定为 0。
usage.prompt_tokens_details
object
提示中使用的 token 数量明细。
usage.prompt_tokens_details.cached_tokens
integer
命中缓存的 token 数量。
Chat 响应 chunk 对象（流式输出）
choices
array
包含生成的回复选项列表。
choices.delta
object
流式模型响应生成的对话补全增量。
choices.delta.content
string
数据块消息的内容。
choices.delta.role
string
消息作者的角色。
choices.delta.audio
object | null
如果请求输出音频，该对象将包含有关模型音频响应的数据。
choices.delta.audio.id
string
此音频响应的唯一标识符。
choices.delta.audio.data
string
模型生成的 Base64 编码音频，格式为请求中指定的格式。
choices.delta.audio.expires_at
number | null
此音频响应过期的 Unix 时间戳（以秒为单位）。当前仅为 null。
choices.delta.audio.transcript
string | null
模型生成的音频的文字记录。当前仅为 null。
choices.delta.final_text_preview
string
经过智能优化润色后的音频播报最终文本。仅当请求参数 optimize_text_preview 设为 true 时，该字段才会返回。
choices.finish_reason
string | null
模型停止生成 token 的原因：
stop：模型到达自然结束点或触发了用户指定的停止序列
length：因超出模型最大生成长度而终止
content_filter：内容因触发过滤策略而被拦截
choices.index
integer
选项列表中对应选项的索引。
created
integer
对话补全对象创建时的 Unix 时间戳（以秒为单位）。每个数据块均使用相同的时间戳。
id
string
对话补全对象的唯一标识符。每个数据块均使用相同的 ID。
model
string
用于生成结果的模型。
object
string
对象类型，仅为 chat.completion.chunk。
usage
object | null
该对话补全请求的用量信息。
usage.completion_tokens
integer
模型输出内容花费的 token。
usage.prompt_tokens
integer
提示词使用的 token 数量。
usage.total_tokens
integer
请求中使用的 token 总数（提示词 + 补全结果）。
usage.completion_tokens_details
object
补全中使用的 token 数量明细。
usage.completion_tokens_details.reasoning_tokens
integer
模型为推理生成的 token 数量，固定为 0。
usage.prompt_tokens_details
object
提示中使用的 token 数量明细。
usage.prompt_tokens_details.cached_tokens
integer
命中缓存的 token 数量。


curl --location --request POST 'https://api.xiaomimimo.com/v1/chat/completions' \
--header "api-key: $MIMO_API_KEY" \
--header 'Content-Type: application/json' \
--data-raw '{
    "model": "mimo-v2.5-tts",
    "messages": [
        {
            "role": "user",
            "content": "Bright, bouncy, slightly sing-song tone — like you are bursting with good news you can barely hold in. Fast pace, rising pitch at the end."
        },
        {
            "role": "assistant",
            "content": "Hey boss — guess what, guess what? I just got the results back and I actually passed! Not just passed, I got a distinction! I know, I know — you told me I was cutting it close, but hey, here we are. Drinks are on me tonight, okay?"
        }
    ],
    "audio": {
        "format": "wav",
        "voice": "mimo_default"
    }
}'

curl --location --request POST 'https://api.xiaomimimo.com/v1/chat/completions' \
--header "api-key: $MIMO_API_KEY" \
--header 'Content-Type: application/json' \
--data-raw '{
    "model": "mimo-v2.5-tts-voicedesign",
    "messages": [
        {
            "role": "user",
            "content": "Give me a young male tone."
        },
        {
            "role": "assistant",
            "content": "Yes, I had a sandwich."
        }
    ],
    "audio": {
        "format": "wav"
    }
}'

curl --location --request POST 'https://api.xiaomimimo.com/v1/chat/completions' \
--header "api-key: $MIMO_API_KEY" \
--header 'Content-Type: application/json' \
--data-raw '{
    "model": "mimo-v2.5-tts-voiceclone",
    "messages": [
        {
            "role": "user",
            "content": ""
        },
        {
            "role": "assistant",
            "content": "Yes, I had a sandwich."
        }
    ],
    "audio": {
        "format": "wav",
        "voice": "data:{MIME_TYPE};base64,$BASE64_AUDIO"
    }
}'

import os
from openai import OpenAI

client = OpenAI(
    api_key=os.environ.get("MIMO_API_KEY"),
    base_url="https://api.xiaomimimo.com/v1"
)

completion = client.chat.completions.create(
    model="mimo-v2.5-tts",
    messages=[
        {
            "role": "user",
            "content": "Bright, bouncy, slightly sing-song tone — like you're bursting with good news you can barely hold in. Fast pace, rising pitch at the end."
        },
        {
            "role": "assistant",
            "content": "Hey boss — guess what, guess what? I just got the results back and I actually passed! Not just passed, I got a distinction! I know, I know — you told me I was cutting it close, but hey, here we are. Drinks are on me tonight, okay?"
        }
    ],
    audio={
        "format": "wav",
        "voice": "mimo_default"
    }
)

print(completion.model_dump_json())

import os
from openai import OpenAI
import base64

client = OpenAI(
    api_key=os.environ.get("MIMO_API_KEY"),
    base_url="https://api.xiaomimimo.com/v1"
)

completion = client.chat.completions.create(
    model="mimo-v2.5-tts-voicedesign",
    messages=[
        {
            "role": "user",
            "content": "Give me a young male tone."
        },
        {
            "role": "assistant",
            "content": "Yes, I had a sandwich."
        }
    ],
    audio={
        "format": "wav"
    }
)

print(completion.model_dump_json())

import os
import base64
import urllib.request
from openai import OpenAI

client = OpenAI(
    api_key=os.environ.get("MIMO_API_KEY"),
    base_url="https://api.xiaomimimo.com/v1",
)

# Example audio URL
audio_url = "https://example-files.cnbj1.mi-fds.com/example-files/audio/audio_example.wav"
audio_file = "audio_example.wav"

# Download the audio file from URL (skip if already exists)
if not os.path.exists(audio_file):
    urllib.request.urlretrieve(audio_url, audio_file)

# To use a local file directly, replace the above with:
# audio_file = "your_local_audio.wav"
with open(audio_file, "rb") as f:
    audio_bytes = f.read()
audio_base64 = base64.b64encode(audio_bytes).decode("utf-8")

completion = client.chat.completions.create(
    model="mimo-v2.5-tts-voiceclone",
    messages=[
        {
            "role": "user",
            "content": ""
        },
        {
            "role": "assistant", 
            "content": "Yes, I had a sandwich."
        }
    ],
    audio={
        "format": "wav",
        "voice": f"data:audio/wav;base64,{audio_base64}"
    }
)

message = completion.choices[0].message
audio_bytes = base64.b64decode(message.audio.data)
with open("audio_file.wav", "wb") as f:
    f.write(audio_bytes)

    {
    "id": "6ebed286b58546f6b87fa7fa9d0e806b",
    "choices": [
        {
            "finish_reason": "stop",
            "index": 0,
            "message": {
                "content": "",
                "role": "assistant",
                "audio": {
                    "id": "979a91904f9a4143928d9e1f54837b4f",
                    "data": "base64Data",
                    "expires_at": null,
                    "transcript": null
                },
                "tool_calls": null
            }
        }
    ],
    "created": 1776954802,
    "model": "mimo-v2.5-tts",
    "object": "chat.completion",
    "usage": {
        "completion_tokens": 97,
        "prompt_tokens": 213,
        "total_tokens": 310,
        "completion_tokens_details": {
            "reasoning_tokens": 0
        },
        "prompt_tokens_details": {
            "cached_tokens": 109
        }
    }
}
{
    "id": "00a6059fabb2426cae38376b5fb8cdab",
    "choices": [
        {
            "finish_reason": "stop",
            "index": 0,
            "message": {
                "content": "",
                "role": "assistant",
                "audio": {
                    "id": "4834cbe5887545898e2fd634235ca4cc",
                    "data": "base64Data",
                    "expires_at": null,
                    "transcript": null
                },
                "tool_calls": null
            }
        }
    ],
    "created": 1776849848,
    "model": "mimo-v2.5-tts-voicedesign",
    "object": "chat.completion",
    "usage": {
        "completion_tokens": 12,
        "prompt_tokens": 30,
        "total_tokens": 42,
        "completion_tokens_details": {
            "reasoning_tokens": 0
        },
        "prompt_tokens_details": {
            "cached_tokens": 3
        }
    }
}

{
    "id": "499340240f6f4286a5b46606b145ae43",
    "choices": [
        {
            "finish_reason": "stop",
            "index": 0,
            "message": {
                "content": "",
                "role": "assistant",
                "audio": {
                    "id": "0ccba3874db64c7ea6bd6fd203390548",
                    "data": "base64Data",
                    "expires_at": null,
                    "transcript": null
                },
                "tool_calls": null
            }
        }
    ],
    "created": 1784254087,
    "model": "mimo-v2.5-tts-voiceclone",
    "object": "chat.completion",
    "usage": {
        "completion_tokens": 17,
        "prompt_tokens": 61,
        "total_tokens": 78,
        "completion_tokens_details": {
            "reasoning_tokens": 0
        },
        "prompt_tokens_details": {
            "cached_tokens": 9
        }
    }
}

{
    "id": "6ebed286b58546f6b87fa7fa9d0e806b",
    "choices": [
        {
            "finish_reason": "stop",
            "index": 0,
            "message": {
                "content": "",
                "role": "assistant",
                "audio": {
                    "id": "979a91904f9a4143928d9e1f54837b4f",
                    "data": "base64Data",
                    "expires_at": null,
                    "transcript": null
                },
                "tool_calls": null
            }
        }
    ],
    "created": 1776954802,
    "model": "mimo-v2.5-tts",
    "object": "chat.completion",
    "usage": {
        "completion_tokens": 97,
        "prompt_tokens": 213,
        "total_tokens": 310,
        "completion_tokens_details": {
            "reasoning_tokens": 0
        },
        "prompt_tokens_details": {
            "cached_tokens": 109
        }
    }
}
{
    "id": "00a6059fabb2426cae38376b5fb8cdab",
    "choices": [
        {
            "finish_reason": "stop",
            "index": 0,
            "message": {
                "content": "",
                "role": "assistant",
                "audio": {
                    "id": "4834cbe5887545898e2fd634235ca4cc",
                    "data": "base64Data",
                    "expires_at": null,
                    "transcript": null
                },
                "tool_calls": null
            }
        }
    ],
    "created": 1776849848,
    "model": "mimo-v2.5-tts-voicedesign",
    "object": "chat.completion",
    "usage": {
        "completion_tokens": 12,
        "prompt_tokens": 30,
        "total_tokens": 42,
        "completion_tokens_details": {
            "reasoning_tokens": 0
        },
        "prompt_tokens_details": {
            "cached_tokens": 3
        }
    }
}
{
    "id": "499340240f6f4286a5b46606b145ae43",
    "choices": [
        {
            "finish_reason": "stop",
            "index": 0,
            "message": {
                "content": "",
                "role": "assistant",
                "audio": {
                    "id": "0ccba3874db64c7ea6bd6fd203390548",
                    "data": "base64Data",
                    "expires_at": null,
                    "transcript": null
                },
                "tool_calls": null
            }
        }
    ],
    "created": 1784254087,
    "model": "mimo-v2.5-tts-voiceclone",
    "object": "chat.completion",
    "usage": {
        "completion_tokens": 17,
        "prompt_tokens": 61,
        "total_tokens": 78,
        "completion_tokens_details": {
            "reasoning_tokens": 0
        },
        "prompt_tokens_details": {
            "cached_tokens": 9
        }
    }
}
