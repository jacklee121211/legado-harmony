/**
 * 本地 TTS 客户端（Core Speech Kit textToSpeech）—— 双引擎架构的默认引擎（2026-09-25）。
 *
 * 官方证据：
 *  · SDK `@hms.ai.textToSpeech.d.ts`（@since 4.1.0(11)）：
 *    `createEngine({language, person, online})`、`speak(text, SpeakParams)`、
 *    `SpeakListener.onData(requestId, audio: ArrayBuffer, SynthesisResponse)`、`shutdown()`；
 *    `online`：SDK 原文「**0**: online mode, which is not supported currently;
 *    **1**: offline mode, which is supported」⇒ 恒 1（离线端侧合成）；
 *  · `CreateEngineParams.person`：13=聆小珊女声（内置推荐）、21=凌飞哲男声（需下载）、
 *    8=劳拉 en-US（需下载）——音色是**引擎级**参数 ⇒ 多音色 = 引擎池按 person 缓存
 *    （全设备实例上限 3 个 ⇒ 池上限 2，超出走 `shutdown()` 淘汰最旧）；
 *  · FAQ core-speech-8 + 开发指南：`extraParams<'playType', 0>` = 仅合成不播报、
 *    经 onData 返回音频流（默认 1 = 引擎自播）；PCM 格式 **16kHz/单声道/S16LE**
 *    （指南示例 renderer 即此配置）；
 *  · 停顿：指南「插入静音停顿」原文「格式：[pN]，N 为无符号整数，单位为 ms」⇒
 *    句末/句中停顿以**文本内嵌标记**实现（本地引擎无词级时间戳，PCM 级插入不可行）；
 *  · 端侧能力，无网可用；单次 ≤10000 字符。
 *
 * 集成约定：
 *  · playType=0：PCM 交回应用 ⇒ 喂自家 PcmPlayer，熄屏低功耗/垫片保活全链路复用；
 *  · speak() 无 Promise ⇒ requestId + onComplete/onError 包 Promise；**串行队列**
 *    （未承诺并发 speak，探活/预取并发时排队）；
 *  · 输出封装 16k/单声道/S16LE 的 WAV（44 字节标准头），复用现有缓存管线
 *    （TtsEngine.playChunk 按扩展名 .wav 直读 PCM，免 MP3 解码）。
 *
 * 【待真机验证】onData 出流节奏：若快于实时 ⇒ 预取/垫片行为与 Edge 一致；
 * 若实时出流 ⇒ 预取会滞后（表现为块间等待），届时再做流式边收边播。
 */
import { textToSpeech } from '@kit.CoreSpeechKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { LOCAL_VOICES } from './LocalVoices';
import { PreferencesUtil } from '@pura/harmony-utils';

const DOMAIN: number = 0x0001;
const TAG: string = 'LocalTts';

/** 引擎输出采样率（官方指南示例口径：16kHz 单声道 S16LE） */
export const LOCAL_TTS_SAMPLE_RATE: number = 16000;
/** 单次合成安全超时（speak 无内置超时，挂死会堵住串行队列） */
const SYNTH_TIMEOUT_MS: number = 45000;
/** 引擎池上限（全设备所有应用共 3 个实例 ⇒ 自用最多 2 个：女声/男声各一） */
const ENGINE_POOL_MAX: number = 2;

const enginePool = new Map<number, textToSpeech.TextToSpeechEngine>();
/** 串行队列尾（未承诺并发 speak ⇒ 全部请求排队依次执行） */
let queueTail: Promise<void> = Promise.resolve();
let requestSeq: number = 0;

function shutdownEngine(e: textToSpeech.TextToSpeechEngine): void {
  try {
    e.shutdown();
  } catch (err) {
    // 忽略
  }
}

async function ensureEngine(person: number): Promise<textToSpeech.TextToSpeechEngine> {
  const cached = enginePool.get(person);
  if (cached !== undefined) {
    return cached;
  }
  if (enginePool.size >= ENGINE_POOL_MAX) {
    // 淘汰最旧（Map 保持插入序）
    const oldest = enginePool.keys().next();
    if (!oldest.done && oldest.value !== undefined) {
      const oldEngine = enginePool.get(oldest.value);
      enginePool.delete(oldest.value);
      if (oldEngine !== undefined) {
        shutdownEngine(oldEngine);
      }
    }
  }
  let e: textToSpeech.TextToSpeechEngine;
  try {
    e = await textToSpeech.createEngine({
      language: 'zh-CN',
      person: person,
      online: 1 // SDK 原文：「0=online（当前不支持）；1=offline mode, which is supported」
    });
  } catch (err) {
    // 引擎创建失败（音色未下载/系统服务异常）向上抛，走调用方既有重试/垫片路径
    throw err instanceof Error ? err : new Error(String(err));
  }
  enginePool.set(person, e);
  hilog.info(DOMAIN, TAG, 'engine created person=%{public}d poolSize=%{public}d', person, enginePool.size);
  return e;
}

/**
 * 停顿注入：句末/句中停顿 → 官方文本标记 `[pN]`（指南「插入静音停顿」原文）。
 * 本地引擎无词级时间戳 ⇒ 无法像 Edge 那样在 PCM 里插静音，改在合成前把标记写进文本。
 * 句末类：。！？…\n；句中类：，、；：,（后随闭引号一并归入停顿点）。
 */
function injectPauses(text: string, sentenceMs: number, commaMs: number): string {
  if (sentenceMs <= 0 && commaMs <= 0) {
    return text;
  }
  let out: string = '';
  const isCloseQuote = (c: string): boolean =>
    c === '\u201D' || c === '\u2019' || c === '\u300D' || c === '\u300F';
  for (let i = 0; i < text.length; i++) {
    const ch = text.charAt(i);
    out += ch;
    let sentenceEnd: boolean = sentenceMs > 0 &&
      (ch === '\u3002' || ch === '\uFF01' || ch === '\uFF1F' || ch === '\u2026' || ch === '\n');
    let commaEnd: boolean = commaMs > 0 &&
      (ch === '\uFF0C' || ch === '\u3001' || ch === '\uFF1B' || ch === '\uFF1A' || ch === ',');
    if (sentenceEnd || commaEnd) {
      let j = i + 1;
      while (j < text.length && isCloseQuote(text.charAt(j))) {
        out += text.charAt(j);
        j++;
      }
      out += '[p' + (sentenceEnd ? sentenceMs : commaMs) + ']';
      i = j - 1;
    }
  }
  return out;
}

/** 16k/单声道/S16LE PCM → WAV（44 字节标准头），复用现有缓存/播放管线 */
function pcmToWav(pcm: Int16Array): ArrayBuffer {
  const dataBytes: number = pcm.length * 2;
  const buf = new ArrayBuffer(44 + dataBytes);
  const v = new DataView(buf);
  const wstr = (off: number, s: string): void => {
    for (let i = 0; i < s.length; i++) {
      v.setUint8(off + i, s.charCodeAt(i));
    }
  };
  wstr(0, 'RIFF');
  v.setUint32(4, 36 + dataBytes, true);
  wstr(8, 'WAVE');
  wstr(12, 'fmt ');
  v.setUint32(16, 16, true); // fmt 块长
  v.setUint16(20, 1, true); // PCM
  v.setUint16(22, 1, true); // 单声道
  v.setUint32(24, LOCAL_TTS_SAMPLE_RATE, true);
  v.setUint32(28, LOCAL_TTS_SAMPLE_RATE * 2, true); // 字节率
  v.setUint16(32, 2, true); // 块对齐
  v.setUint16(34, 16, true); // 位深
  wstr(36, 'data');
  v.setUint32(40, dataBytes, true);
  const out = new Int16Array(buf, 44, pcm.length);
  out.set(pcm);
  return buf;
}

/** 单次合成（已串行化）。失败抛 Error（调用方按既有重试/垫片路径处理）。 */
async function synthesizeOnceLocal(text: string, speed: number, person: number,
  sentenceMs: number, commaMs: number): Promise<ArrayBuffer> {
  const e: textToSpeech.TextToSpeechEngine = await ensureEngine(person);
  const spoken = injectPauses(text, sentenceMs, commaMs);
  return new Promise<ArrayBuffer>((resolve: (r: ArrayBuffer) => void,
    reject: (e: Error) => void) => {
    const requestId: string = 'local' + (++requestSeq);
    const parts: Uint8Array[] = [];
    let total: number = 0;
    let done: boolean = false;
    let timerId: number = -1;
    const detachListener = (): void => {
      try {
        e.setListener({
          onStart(_id: string, _r: textToSpeech.StartResponse): void {
          },
          onComplete(_id: string, _r: textToSpeech.CompleteResponse): void {
          },
          onStop(_id: string, _r: textToSpeech.StopResponse): void {
          },
          onData: undefined,
          onError(_id: string, _c: number, _m: string): void {
          }
        });
      } catch (err) {
        // 忽略摘监听异常
      }
    };
    const finish = (err: string): void => {
      if (done) {
        return;
      }
      done = true;
      if (timerId !== -1) {
        clearTimeout(timerId);
        timerId = -1;
      }
      detachListener();
      if (err.length > 0 || total === 0) {
        reject(new Error(err.length > 0 ? err : 'local tts: 无音频返回'));
        return;
      }
      const merged = new Uint8Array(total);
      let off = 0;
      for (let i = 0; i < parts.length; i++) {
        merged.set(parts[i], off);
        off += parts[i].length;
      }
      const pcm = new Int16Array(merged.buffer, 0, total >> 1);
      resolve(pcmToWav(pcm));
    };
    timerId = setTimeout((): void => {
      finish('local tts: 合成超时');
    }, SYNTH_TIMEOUT_MS);
    const listener: textToSpeech.SpeakListener = {
      onStart(_id: string, _r: textToSpeech.StartResponse): void {
      },
      onComplete(_id: string, _r: textToSpeech.CompleteResponse): void {
        finish('');
      },
      onStop(_id: string, _r: textToSpeech.StopResponse): void {
        finish('local tts: 已停止');
      },
      onData: (id: string, audio: ArrayBuffer, _r: textToSpeech.SynthesisResponse): void => {
        if (id !== requestId || done) {
          return;
        }
        if (audio.byteLength > 0) {
          parts.push(new Uint8Array(audio.slice(0)));
          total += audio.byteLength;
        }
      },
      onError(_id: string, code: number, msg: string): void {
        finish(`local tts err ${code}: ${msg}`);
      }
    };
    try {
      e.setListener(listener);
      const extra: Record<string, Object> = {
        'playType': 0, // 仅合成不播报，音频经 onData 返回（FAQ core-speech-8）
        'speed': speed
      };
      const params: textToSpeech.SpeakParams = {
        requestId: requestId,
        extraParams: extra
      };
      e.speak(spoken, params);
    } catch (err) {
      finish(err instanceof Error ? err.message : String(err));
    }
  });
}

/**
 * 合成一段文本 → WAV(ArrayBuffer)（16k/单声道/S16LE）。
 * 对外入口：串行排队（探活/预取并发时依次合成），失败抛 Error。
 * @param speed 语速（0.5~2.0，1.0=常速；对应 extraParams<'speed'>）
 * @param person 音色（引擎级参数，见 LocalVoices）
 * @param sentenceMs/commaMs 句末/句中停顿（文本标记 [pN] 注入，0=不注入）
 */
export function synthesizeLocalWav(text: string, speed: number, person: number,
  sentenceMs: number, commaMs: number): Promise<ArrayBuffer> {
  const task: Promise<ArrayBuffer> = queueTail.then((): Promise<ArrayBuffer> => {
    return synthesizeOnceLocal(text, speed, person, sentenceMs, commaMs);
  });
  queueTail = task.then((): void => {
  }, (): void => {
  });
  return task;
}

// ── 音色枚举与下载（SDK @since 5.1.1(19)）────────────────────────────────────
// 权威音色表是 **listVoices 动态枚举**（静态文档只点名 13/21/8 三种，设备实际
// 可用集合以枚举为准）。状态 VoiceInfo.status：'INSTALLED'=已下载可直接用 /
// 'GA'=可下载（未下载时 speak 失败，FAQ core-speech-7）/ 'EOM'=不可用。
// 下载：downloadVoice + DownloadResponse 事件（start/progress/complete/cancel/error）；
// 音色模型由**系统级**存储，应用卸载不影响 ⇒ "下载后永久使用"由系统保证。

/** 本地音色行（listVoices 动态结果 + 静态标签合并，供面板渲染） */
export interface LocalVoiceRow {
  person: number;
  language: string;
  style: string;
  gender: string;
  label: string;
  description: string;
  /** 'INSTALLED'（已下载）/ 'GA'（可下载）/ 'EOM'（不可用）/ ''（未知） */
  status: string;
}

function staticLabel(person: number): string {
  for (let i = 0; i < LOCAL_VOICES.length; i++) {
    if (LOCAL_VOICES[i].person === person) {
      return LOCAL_VOICES[i].label;
    }
  }
  return '';
}

// ── 已下载音色"记忆名单"（用户要求：已下载的进本地列表，重新枚举不被覆盖）────
// listVoices 是设备实时状态，可能抖动（某次枚举缺席/状态回跳）——但音色模型是
// 系统级存储，一旦下载成功就该永久显示为可用。故：下载成功即记入持久化名单，
// 每次枚举后合并（钉状态 + 缺席补挂）。
const DOWNLOADED_KEY: string = 'LocalTtsDownloadedPersons';

function loadDownloadedPersons(): Set<number> {
  const s = new Set<number>();
  try {
    const raw = PreferencesUtil.getSync(DOWNLOADED_KEY, '') as string;
    if (typeof raw === 'string' && raw.length > 0) {
      const arr = JSON.parse(raw) as number[];
      for (let i = 0; i < arr.length; i++) {
        s.add(arr[i]);
      }
    }
  } catch (e) {
    // 忽略：名单读不到就当空（音色仍由系统真实状态兜底）
  }
  return s;
}

/** 下载成功（含"已下载"错误码）后调用：把 person 记入持久化名单 */
export function rememberDownloadedVoice(person: number): void {
  const s = loadDownloadedPersons();
  s.add(person);
  const arr: number[] = [];
  s.forEach((n: number): void => {
    arr.push(n);
  });
  try {
    PreferencesUtil.putSync(DOWNLOADED_KEY, JSON.stringify(arr));
  } catch (e) {
    // 忽略
  }
}

/**
 * 枚举结果与"记忆名单"合并：
 *  · 名单内的音色若本次枚举存在 ⇒ 状态钉为 INSTALLED（防枚举抖动回跳 GA）；
 *  · 名单内的音色若本次枚举缺席 ⇒ 以静态表兜底信息追加保留（用户不丢音色）。
 */
export function mergeDownloadedRows(fresh: LocalVoiceRow[]): LocalVoiceRow[] {
  const remembered = loadDownloadedPersons();
  if (remembered.size === 0) {
    return fresh;
  }
  const out: LocalVoiceRow[] = [];
  const seen = new Set<number>();
  for (let i = 0; i < fresh.length; i++) {
    const r = fresh[i];
    if (remembered.has(r.person) && r.status !== 'EOM') {
      out.push({
        person: r.person, language: r.language, style: r.style, gender: r.gender,
        label: r.label, description: r.description, status: 'INSTALLED'
      });
    } else {
      out.push(r);
    }
    seen.add(r.person);
  }
  remembered.forEach((p: number): void => {
    if (!seen.has(p)) {
      out.push({
        person: p, language: 'zh-CN', style: '', gender: '',
        label: staticLabel(p).length > 0 ? staticLabel(p) : `音色 ${p}`,
        description: '已下载音色（本次枚举未返回，保留显示）', status: 'INSTALLED'
      });
    }
  });
  return out;
}

/** 枚举离线可用音色（online=1；失败抛 Error，由调用方回退静态表） */
export async function listLocalVoices(): Promise<LocalVoiceRow[]> {
  const query: textToSpeech.VoiceQuery = {
    requestId: 'lv' + (++requestSeq),
    online: 1
  };
  const voices: textToSpeech.VoiceInfo[] = await textToSpeech.listVoices(query);
  const rows: LocalVoiceRow[] = [];
  for (let i = 0; i < voices.length; i++) {
    const v = voices[i];
    const known: string = staticLabel(v.person);
    rows.push({
      person: v.person,
      language: v.language,
      style: v.style,
      gender: v.gender,
      label: known.length > 0 ? known : v.description,
      description: v.description,
      status: v.status === undefined ? '' : v.status
    });
  }
  hilog.info(DOMAIN, TAG, 'listVoices %{public}d voices', rows.length);
  return rows;
}

/**
 * 下载指定音色（点击触发）。进度经 onProgress 回调（服务端字符串口径）；
 * 完成（complete 事件）resolve；出错/取消 reject。错误码 1002300010=已下载 ⇒ 视为成功。
 * 音色模型由系统存储 ⇒ 下载一次永久可用（重装应用也不丢）。
 */
export function downloadLocalVoice(row: LocalVoiceRow,
  onProgress: (p: string) => void): Promise<void> {
  return new Promise<void>((resolve: () => void, reject: (e: Error) => void) => {
    let done: boolean = false;
    const settle = (err: Error | null): void => {
      if (done) {
        return;
      }
      done = true;
      if (err === null) {
        rememberDownloadedVoice(row.person); // 成功（含已下载）⇒ 记入永久名单
        resolve();
      } else {
        reject(err);
      }
    };
    try {
      textToSpeech.downloadVoice({
        requestId: 'dl' + (++requestSeq),
        language: row.language,
        person: row.person,
        style: row.style
      }, (err: BusinessError, resp: textToSpeech.DownloadResponse) => {
        if (err) {
          // 1002300010 = 音色已下载 ⇒ 直接成功
          if (err.code === 1002300010) {
            settle(null);
          } else {
            settle(new Error(`下载失败 ${err.code}: ${err.message}`));
          }
          return;
        }
        resp.on('progress', (p: string) => {
          if (!done) {
            onProgress(p);
          }
        });
        resp.on('complete', (_v: textToSpeech.VoiceInfo) => {
          settle(null);
        });
        resp.on('error', (e: BusinessError) => {
          settle(new Error(`下载失败 ${e.code}: ${e.message}`));
        });
        resp.on('cancel', (_s: string) => {
          settle(new Error('下载已取消'));
        });
      });
    } catch (err) {
      settle(err instanceof Error ? err : new Error(String(err)));
    }
  });
}
