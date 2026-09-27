export interface PcmDecodeResult {
  pcm: ArrayBuffer;
  sampleRate: number;
  channels: number;
}

export const decodeMp3ToPcm: (mp3: ArrayBuffer) => Promise<PcmDecodeResult>;
