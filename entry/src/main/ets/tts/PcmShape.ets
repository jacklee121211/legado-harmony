/**
 * PCM 规格归一化 + WAV 解析（**AI 语音专用**，自研）。
 *
 * ── 为什么要它（方案 §1.2 三条硬约束）──────────────────────────────────────
 *  · `PcmPlayer.ensureRenderer()` 固定单声道（`PcmPlayer.ets:317-328`）⇒ 喂立体声会 2 倍速+变调；
 *  · `TtsEngine.playChunk` 原来**丢弃** `decoded.channels`（`TtsEngine.ets:2301-2305`），
 *    `applyPauses` 也只接受单声道（`PauseSplicer.ets:6`）；
 *  · `libttsdec.so` 只认 MP3（`tts_decoder.cpp:230`），WAV/裸 PCM 得自己处理。
 *
 * ── 算法来源：**本工程已验证过的垫片代码**（不是从参考项目抄的）──────────────
 *  · 立体声折叠：`TtsEngine.ets:2602-2613`（真机跑过 206s 垫片）
 *  · 线性重采样：`TtsEngine.ets:2614-2634`
 *  · 主线程切片让出：`TtsEngine.ets:431,441`（真机物证见 `:388-420`：不让出会把主线程堵死 11.88s）
 *
 * ⚠️ 只服务 AI 路径：本地(16k mono)/Edge(24k mono) 的既有行为**绝不受影响**——
 *    `playChunk` 只在 sidecar 带 `fmt` 字段（= AI 产物）时才调用本模块。
 */
export const AI_TARGET_SAMPLE_RATE: number = 24000;

/** 每处理多少个样本让出一次主线程（与 TtsEngine 的 PAD_BUILD_YIELD_SAMPLES 同量级） */
const YIELD_SAMPLES: number = 65536;

async function yieldNow(): Promise<void> {
  await new Promise<void>((resolve: () => void): void => {
    setTimeout((): void => {
      resolve();
    }, 0);
  });
}

/** WAV 解析结果 */
export interface WavPcm {
  pcm: ArrayBuffer;
  sampleRate: number;
  channels: number;
}

function readAscii(buf: ArrayBuffer, off: number, len: number): string {
  const v = new Uint8Array(buf, off, len);
  let s: string = '';
  for (let i = 0; i < v.length; i++) {
    s += String.fromCharCode(v[i]);
  }
  return s;
}

/**
 * 解析标准 RIFF/WAVE（16bit PCM）。失败返回 null（调用方回落旧行为）。
 * 能正确解析本工程 `LocalTtsClient.pcmToWav` 产出的 44 字节标准头
 * （`LocalTtsClient.ets:124-149`：RIFF/WAVE/fmt 16/PCM/1ch/16000/16bit/data）。
 */
export function parseWavPcm(buf: ArrayBuffer): WavPcm | null {
  if (buf.byteLength < 44) {
    return null;
  }
  try {
    if (readAscii(buf, 0, 4) !== 'RIFF' || readAscii(buf, 8, 4) !== 'WAVE') {
      return null;
    }
    const view = new DataView(buf);
    let off: number = 12;
    let channels: number = 0;
    let sampleRate: number = 0;
    let bits: number = 0;
    let audioFormat: number = 0;
    let dataOff: number = -1;
    let dataLen: number = 0;
    while (off + 8 <= buf.byteLength) {
      const id: string = readAscii(buf, off, 4);
      const size: number = view.getUint32(off + 4, true);
      const body: number = off + 8;
      if (id === 'fmt ' && body + 16 <= buf.byteLength) {
        audioFormat = view.getUint16(body, true);
        channels = view.getUint16(body + 2, true);
        sampleRate = view.getUint32(body + 4, true);
        bits = view.getUint16(body + 14, true);
      } else if (id === 'data') {
        dataOff = body;
        dataLen = size;
        if (dataOff + dataLen > buf.byteLength) {
          dataLen = buf.byteLength - dataOff;
        }
        break;
      }
      off = body + size + (size % 2);
    }
    if (dataOff < 0 || dataLen <= 1 || channels <= 0 || sampleRate <= 0) {
      return null;
    }
    // 只支持 16bit PCM（WAVE_FORMAT_PCM=1 与 WAVE_FORMAT_EXTENSIBLE=65534 都按 16bit 处理）
    if (bits !== 16 || (audioFormat !== 1 && audioFormat !== 65534)) {
      return null;
    }
    const src = new Uint8Array(buf, dataOff, dataLen);
    const usable: number = dataLen - (dataLen % 2);
    const out = new ArrayBuffer(usable);
    new Uint8Array(out).set(src.subarray(0, usable));
    const res: WavPcm = { pcm: out, sampleRate: sampleRate, channels: channels };
    return res;
  } catch (e) {
    return null;
  }
}

/** 立体声（交错）→ 单声道。算法同 `TtsEngine.ets:2602-2613` */
export async function foldToMono(src: Int16Array, channels: number): Promise<Int16Array> {
  const ch: number = channels < 1 ? 1 : Math.floor(channels);
  const monoLen: number = Math.floor(src.length / ch);
  const mono = new Int16Array(monoLen);
  for (let off = 0; off < monoLen; off += YIELD_SAMPLES) {
    const end: number = Math.min(off + YIELD_SAMPLES, monoLen);
    for (let i = off; i < end; i++) {
      let sum: number = 0;
      for (let c = 0; c < ch; c++) {
        sum += src[i * ch + c];
      }
      mono[i] = Math.round(sum / ch);
    }
    await yieldNow();
  }
  return mono;
}

/** 线性重采样。算法同 `TtsEngine.ets:2614-2634` */
export async function resampleLinear(src: Int16Array, fromRate: number,
  toRate: number): Promise<Int16Array> {
  if (fromRate <= 0 || toRate <= 0 || fromRate === toRate) {
    return src;
  }
  const outN: number = Math.round(src.length * toRate / fromRate);
  if (outN <= 0) {
    return new Int16Array(0);
  }
  const rs = new Int16Array(outN);
  const step: number = fromRate / toRate;
  const lastIdx: number = src.length - 1;
  for (let off = 0; off < outN; off += YIELD_SAMPLES) {
    const end: number = Math.min(off + YIELD_SAMPLES, outN);
    for (let i = off; i < end; i++) {
      const pos: number = i * step;
      const i0: number = Math.floor(pos);
      const frac: number = pos - i0;
      const a: number = i0 <= lastIdx ? src[i0] : src[lastIdx];
      const b: number = i0 + 1 <= lastIdx ? src[i0 + 1] : a;
      rs[i] = Math.round(a + (b - a) * frac);
    }
    await yieldNow();
  }
  return rs;
}

/**
 * 归一化：任意 (采样率, 声道数) → 单声道 + targetRate。
 * 已经是 mono@target 时**原样返回**（零拷贝、零开销，AI 音色若本来合规就无感）。
 */
export async function shapePcmToTarget(pcm: Int16Array, sampleRate: number,
  channels: number, targetRate: number): Promise<Int16Array> {
  let out: Int16Array = pcm;
  let ch: number = channels < 1 ? 1 : Math.floor(channels);
  if (ch > 1) {
    out = await foldToMono(out, ch);
    ch = 1;
  }
  const rate: number = sampleRate > 0 ? Math.floor(sampleRate) : targetRate;
  if (rate !== targetRate && out.length > 0) {
    out = await resampleLinear(out, rate, targetRate);
  }
  return out;
}
