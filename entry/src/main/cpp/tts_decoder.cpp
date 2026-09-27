/**
 * MP3 → PCM 离线解码（NAPI 模块 ttsdec）。
 * 输入 Edge TTS 的 MP3 ArrayBuffer，输出 S16LE 交错 PCM + 实际采样率/声道。
 * 使用统一编解码 API OH_AudioCodec_*（API 11+，本工程兼容 API 16）。
 *
 * 关键点：OH 的 ffmpeg 插件把每个输入缓冲视为完整包，包首落在 MP3 帧中间时
 * 报 "Invalid data" 并整块丢弃。因此本模块解析 MP3 帧头，保证每个输入缓冲
 * 只承载完整帧（帧长 144/145B @ 24kHz 48kbps），缓冲间零错位。
 */
#include "napi/native_api.h"
#include "multimedia/player_framework/native_avcodec_audiocodec.h"
#include "multimedia/player_framework/native_avcodec_base.h"
#include "hilog/log.h"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstring>
#include <mutex>
#include <string>
#include <vector>

#undef LOG_DOMAIN
#undef LOG_TAG
#define LOG_DOMAIN 0x0001
#define LOG_TAG "ttsdec"

namespace {

// Edge 输出为 24kHz 单声道；作为配置初值，真实值以 onStreamChanged 上报为准
constexpr int32_t DEFAULT_SAMPLE_RATE = 24000;
constexpr int32_t DEFAULT_CHANNELS = 1;
constexpr int64_t DECODE_TIMEOUT_MS = 30000;

/**
 * 解析 pos 处的 MP3 帧头，返回帧总长（含头）；无效返回 0。
 * 兼容 MPEG1/MPEG2/MPEG2.5 Layer III（Edge 为 MPEG2 L3：576 样本/帧）。
 */
size_t Mp3FrameLengthAt(const uint8_t *d, size_t size, size_t pos)
{
    if (pos + 4 > size) {
        return 0;
    }
    if (d[pos] != 0xFF || (d[pos + 1] & 0xE0) != 0xE0) {
        return 0;
    }
    const uint8_t b1 = d[pos + 1];
    const uint8_t b2 = d[pos + 2];
    const uint8_t versionBits = (b1 >> 3) & 0x3; // 0=MPEG2.5 1=保留 2=MPEG2 3=MPEG1
    const uint8_t layerBits = (b1 >> 1) & 0x3;   // 1 = Layer III
    if (versionBits == 1 || layerBits != 1) {
        return 0;
    }
    const uint8_t brIdx = (b2 >> 4) & 0xF;
    const uint8_t srIdx = (b2 >> 2) & 0x3;
    const uint8_t pad = (b2 >> 1) & 0x1;
    if (brIdx == 0 || brIdx == 15 || srIdx == 3) {
        return 0;
    }
    // Layer III 位率表（kbps）
    static const int BR1[15] = {0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320};
    static const int BR2[15] = {0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160};
    // 采样率表：MPEG1 / MPEG2 / MPEG2.5
    static const int SR[3][4] = {
        {44100, 48000, 32000, 0},
        {22050, 24000, 16000, 0},
        {11025, 12000, 8000, 0}
    };
    const int tableIdx = versionBits == 3 ? 0 : (versionBits == 2 ? 1 : 2);
    const int sr = SR[tableIdx][srIdx];
    const int br = versionBits == 3 ? BR1[brIdx] : BR2[brIdx];
    if (sr <= 0 || br <= 0) {
        return 0;
    }
    const size_t coef = versionBits == 3 ? 144 : 72;
    size_t len = static_cast<size_t>(coef * br * 1000 / sr) + pad;
    if (len < 4) {
        return 0;
    }
    // 下一帧头校验，降低同步字误判（校验失败交由上层逐字节重同步）
    if (pos + len + 1 < size) {
        if (d[pos + len] != 0xFF || (d[pos + len + 1] & 0xE0) != 0xE0) {
            return 0;
        }
    }
    return len;
}

/** 跳过文件头的 ID3v2 标签（若有），返回数据起始偏移 */
size_t SkipId3v2(const uint8_t *d, size_t size)
{
    if (size < 10 || d[0] != 'I' || d[1] != 'D' || d[2] != '3') {
        return 0;
    }
    // synchsafe size（字节 6..9）
    size_t sz = (static_cast<size_t>(d[6]) << 21) | (static_cast<size_t>(d[7]) << 14)
        | (static_cast<size_t>(d[8]) << 7) | static_cast<size_t>(d[9]);
    bool footer = (d[5] & 0x10) != 0;
    size_t total = 10 + sz + (footer ? 10 : 0);
    return total < size ? total : 0;
}

struct DecodeJob {
    // 输入
    const uint8_t *input = nullptr;
    size_t inputSize = 0;
    size_t inputPos = 0; // 下一待喂字节（始终为完整帧边界）
    size_t fedBytes = 0;

    // 输出
    std::vector<int16_t> pcm;
    int32_t sampleRate = DEFAULT_SAMPLE_RATE;
    int32_t channels = DEFAULT_CHANNELS;

    // 状态
    std::mutex mtx;
    std::condition_variable cv;
    std::atomic<bool> eosOut{false};
    std::atomic<bool> failed{false};
    std::string error;

    OH_AVCodec *codec = nullptr;
};

void OnNeedInput(OH_AVCodec *codec, uint32_t index, OH_AVBuffer *buffer, void *userData)
{
    auto *job = static_cast<DecodeJob *>(userData);
    std::lock_guard<std::mutex> lock(job->mtx);
    if (job->input == nullptr) {
        return;
    }
    OH_AVCodecBufferAttr attr{};
    const int32_t cap = OH_AVBuffer_GetCapacity(buffer);
    uint8_t *dst = cap > 0 ? OH_AVBuffer_GetAddr(buffer) : nullptr;

    if (job->inputPos >= job->inputSize || dst == nullptr) {
        // 输入喂完：提交 EOS 空缓冲
        attr.size = 0;
        attr.flags = AVCODEC_BUFFER_FLAGS_EOS;
        OH_AVBuffer_SetBufferAttr(buffer, &attr);
        OH_AudioCodec_PushInputBuffer(codec, index);
        return;
    }

    // 只填完整 MP3 帧（这是本模块的核心：缓冲边界必须落在帧边界上）
    size_t consumed = job->inputPos;
    size_t filled = 0;
    while (consumed < job->inputSize) {
        size_t flen = Mp3FrameLengthAt(job->input, job->inputSize, consumed);
        if (flen == 0) {
            // 同步字误判/垃圾：跳过一个字节重同步（垃圾不喂给解码器）
            consumed++;
            continue;
        }
        if (flen > job->inputSize - consumed) {
            break; // 尾部残帧：交给 EOS 收尾（损失 < 1 帧 ≈ 24ms）
        }
        if (filled + flen > static_cast<size_t>(cap)) {
            break; // 本缓冲已满
        }
        std::memcpy(dst + filled, job->input + consumed, flen);
        filled += flen;
        consumed += flen;
    }

    if (filled == 0) {
        // 剩余无完整帧 → EOS
        attr.size = 0;
        attr.flags = AVCODEC_BUFFER_FLAGS_EOS;
        OH_AVBuffer_SetBufferAttr(buffer, &attr);
        OH_AudioCodec_PushInputBuffer(codec, index);
        job->inputPos = consumed;
        return;
    }
    job->inputPos = consumed;
    job->fedBytes += filled;
    attr.size = static_cast<int32_t>(filled);
    attr.flags = AVCODEC_BUFFER_FLAGS_NONE;
    OH_AVBuffer_SetBufferAttr(buffer, &attr);
    OH_AudioCodec_PushInputBuffer(codec, index);
}

void OnNewOutput(OH_AVCodec *codec, uint32_t index, OH_AVBuffer *buffer, void *userData)
{
    auto *job = static_cast<DecodeJob *>(userData);
    OH_AVCodecBufferAttr attr{};
    if (OH_AVBuffer_GetBufferAttr(buffer, &attr) == AV_ERR_OK && attr.size > 0) {
        uint8_t *src = OH_AVBuffer_GetAddr(buffer);
        if (src != nullptr) {
            const int16_t *samples = reinterpret_cast<const int16_t *>(src);
            size_t count = static_cast<size_t>(attr.size) / sizeof(int16_t);
            job->pcm.insert(job->pcm.end(), samples, samples + count);
        }
    }
    bool eos = (attr.flags & AVCODEC_BUFFER_FLAGS_EOS) != 0;
    OH_AudioCodec_FreeOutputBuffer(codec, index);
    if (eos) {
        job->eosOut.store(true);
        job->cv.notify_all();
    }
}

void OnStreamChanged(OH_AVCodec *codec, OH_AVFormat *format, void *userData)
{
    auto *job = static_cast<DecodeJob *>(userData);
    if (format != nullptr) {
        int32_t rate = 0;
        int32_t ch = 0;
        if (OH_AVFormat_GetIntValue(format, OH_MD_KEY_AUD_SAMPLE_RATE, &rate) && rate > 0) {
            job->sampleRate = rate;
        }
        if (OH_AVFormat_GetIntValue(format, OH_MD_KEY_AUD_CHANNEL_COUNT, &ch) && ch > 0) {
            job->channels = ch;
        }
    }
}

void OnError(OH_AVCodec *codec, int32_t errorCode, void *userData)
{
    (void)codec;
    auto *job = static_cast<DecodeJob *>(userData);
    job->error = "codec error " + std::to_string(errorCode);
    job->failed.store(true);
    job->cv.notify_all();
}

bool RunDecode(DecodeJob *job)
{
    job->codec = OH_AudioCodec_CreateByMime(OH_AVCODEC_MIMETYPE_AUDIO_MPEG, false);
    if (job->codec == nullptr) {
        job->error = "create decoder failed";
        return false;
    }
    OH_AVCodecCallback cb{};
    cb.onError = OnError;
    cb.onStreamChanged = OnStreamChanged;
    cb.onNeedInputBuffer = OnNeedInput;
    cb.onNewOutputBuffer = OnNewOutput;
    if (OH_AudioCodec_RegisterCallback(job->codec, cb, job) != AV_ERR_OK) {
        job->error = "register callback failed";
        return false;
    }
    OH_AVFormat *fmt = OH_AVFormat_Create();
    if (fmt == nullptr) {
        job->error = "create format failed";
        return false;
    }
    OH_AVFormat_SetIntValue(fmt, OH_MD_KEY_AUD_SAMPLE_RATE, job->sampleRate);
    OH_AVFormat_SetIntValue(fmt, OH_MD_KEY_AUD_CHANNEL_COUNT, job->channels);
    OH_AVFormat_SetIntValue(fmt, OH_MD_KEY_AUDIO_SAMPLE_FORMAT, SAMPLE_S16LE);
    OH_AVErrCode err = OH_AudioCodec_Configure(job->codec, fmt);
    OH_AVFormat_Destroy(fmt);
    if (err != AV_ERR_OK) {
        job->error = "configure failed " + std::to_string(err);
        return false;
    }
    if (OH_AudioCodec_Prepare(job->codec) != AV_ERR_OK) {
        job->error = "prepare failed";
        return false;
    }
    if (OH_AudioCodec_Start(job->codec) != AV_ERR_OK) {
        job->error = "start failed";
        return false;
    }
    {
        std::unique_lock<std::mutex> lock(job->mtx);
        bool finished = job->cv.wait_for(lock, std::chrono::milliseconds(DECODE_TIMEOUT_MS),
            [job] { return job->eosOut.load() || job->failed.load(); });
        if (!finished) {
            job->error = "decode timeout";
            return false;
        }
    }
    if (job->failed.load()) {
        return false;
    }
    if (!job->eosOut.load()) {
        job->error = "no eos output";
        return false;
    }
    return true;
}

void CleanupCodec(DecodeJob *job)
{
    if (job->codec != nullptr) {
        OH_AudioCodec_Stop(job->codec);
        OH_AudioCodec_Destroy(job->codec);
        job->codec = nullptr;
    }
}

struct AsyncCtx {
    napi_async_work work = nullptr;
    napi_deferred deferred = nullptr;
    napi_ref inputRef = nullptr; // 保活输入 ArrayBuffer
    DecodeJob job;
    bool ok = false;
};

void ExecuteDecode(napi_env env, void *data)
{
    (void)env;
    auto *ctx = static_cast<AsyncCtx *>(data);
    DecodeJob &job = ctx->job;
    job.inputPos = SkipId3v2(job.input, job.inputSize); // 跳过 ID3v2（若有）
    ctx->ok = RunDecode(&job);
    CleanupCodec(&job);
    OH_LOG_INFO(LOG_APP, "decode %{public}s: file=%{public}zu fed=%{public}zu pcm=%{public}zuB rate=%{public}d",
        ctx->ok ? "ok" : "fail", job.inputSize, job.fedBytes,
        job.pcm.size() * sizeof(int16_t), job.sampleRate);
}

void CompleteDecode(napi_env env, napi_status status, void *data)
{
    auto *ctx = static_cast<AsyncCtx *>(data);
    if (status != napi_ok || !ctx->ok) {
        napi_value err;
        napi_value msg;
        const char *msgStr = ctx->job.error.empty() ? "decode failed" : ctx->job.error.c_str();
        napi_create_string_utf8(env, msgStr, NAPI_AUTO_LENGTH, &msg);
        napi_create_error(env, nullptr, msg, &err);
        napi_reject_deferred(env, ctx->deferred, err);
    } else {
        napi_value result;
        napi_value pcmBuf;
        napi_value rateVal;
        napi_value chVal;
        void *outData = nullptr;
        size_t byteLen = ctx->job.pcm.size() * sizeof(int16_t);
        if (byteLen > 0 && napi_create_arraybuffer(env, byteLen, &outData, &pcmBuf) == napi_ok) {
            std::memcpy(outData, ctx->job.pcm.data(), byteLen);
        } else {
            napi_create_arraybuffer(env, 0, &outData, &pcmBuf);
        }
        napi_create_object(env, &result);
        napi_set_named_property(env, result, "pcm", pcmBuf);
        napi_create_int32(env, ctx->job.sampleRate, &rateVal);
        napi_set_named_property(env, result, "sampleRate", rateVal);
        napi_create_int32(env, ctx->job.channels, &chVal);
        napi_set_named_property(env, result, "channels", chVal);
        napi_resolve_deferred(env, ctx->deferred, result);
    }
    if (ctx->inputRef != nullptr) {
        napi_delete_reference(env, ctx->inputRef);
    }
    napi_delete_async_work(env, ctx->work);
    delete ctx;
}

napi_value DecodeMp3ToPcm(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value argv[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    if (argc < 1) {
        napi_throw_error(env, nullptr, "mp3 buffer required");
        return nullptr;
    }
    bool isArrayBuffer = false;
    napi_is_arraybuffer(env, argv[0], &isArrayBuffer);
    if (!isArrayBuffer) {
        napi_throw_error(env, nullptr, "argument must be ArrayBuffer");
        return nullptr;
    }

    auto *ctx = new AsyncCtx();
    void *data = nullptr;
    size_t byteLen = 0;
    napi_get_arraybuffer_info(env, argv[0], &data, &byteLen);
    ctx->job.input = static_cast<const uint8_t *>(data);
    ctx->job.inputSize = byteLen;
    ctx->job.inputPos = 0;
    napi_create_reference(env, argv[0], 1, &ctx->inputRef);

    napi_value promise;
    napi_value resourceName;
    napi_create_string_utf8(env, "DecodeMp3", NAPI_AUTO_LENGTH, &resourceName);
    napi_create_promise(env, &ctx->deferred, &promise);
    napi_create_async_work(env, nullptr, resourceName, ExecuteDecode, CompleteDecode, ctx, &ctx->work);
    napi_queue_async_work(env, ctx->work);
    return promise;
}

napi_value Init(napi_env env, napi_value exports)
{
    napi_property_descriptor desc[] = {
        {"decodeMp3ToPcm", nullptr, DecodeMp3ToPcm, nullptr, nullptr, nullptr, napi_default, nullptr},
    };
    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
    return exports;
}

} // namespace

static napi_module g_ttsdecModule = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = nullptr,
    .nm_register_func = Init,
    .nm_modname = "ttsdec",
    .nm_priv = nullptr,
    .reserved = {0},
};

extern "C" __attribute__((constructor)) void RegisterTtsDecModule(void)
{
    napi_module_register(&g_ttsdecModule);
}
