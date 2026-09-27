/**
 * C++ 解码模块（libttsdec.so）的 ArkTS 封装。
 * 输入 Edge TTS 的 MP3，输出 S16LE PCM + 实际采样率/声道。
 */
import ttsdec from 'libttsdec.so';

export interface PcmDecodeResult {
  pcm: ArrayBuffer;
  sampleRate: number;
  channels: number;
}

export async function decodeMp3ToPcm(mp3: ArrayBuffer): Promise<PcmDecodeResult> {
  // ⚠️ 这个 await 不能删（2026-09-19 实测教训）：
  //   NAPI 侧用 napi_create_promise 真正返回 Promise
  //   （见 cpp/types/ttsdec/index.d.ts: `=> Promise<PcmDecodeResult>`、
  //     cpp/tts_decoder.cpp:380 `napi_create_promise`），
  //   而 ArkTS linter 解析不了 .so 模块的类型、会把这里误报成
  //   `await-thenable`（Error 级）。一旦轻信该告警删掉 await，
  //   返回值就变成 Promise 对象本身 → r.pcm 为 undefined →
  //   真机 `playChunk err: Cannot read property byteLength of undefined`，朗读全废。
  const r: ESObject = await ttsdec.decodeMp3ToPcm(mp3);
  const out: PcmDecodeResult = {
    pcm: r.pcm as ArrayBuffer,
    sampleRate: r.sampleRate as number,
    channels: r.channels as number
  };
  return out;
}
