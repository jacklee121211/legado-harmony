/**
 * C++ 原生模块 libttsdec.so 的类型声明（实现在 src/main/cpp/tts_decoder.cpp）。
 */
declare module 'libttsdec.so' {
  interface PcmDecodeResult {
    pcm: ArrayBuffer;
    sampleRate: number;
    channels: number;
  }

  interface TtsDecModule {
    decodeMp3ToPcm(mp3: ArrayBuffer): Promise<PcmDecodeResult>;
  }

  const ttsdec: TtsDecModule;
  export default ttsdec;
}
