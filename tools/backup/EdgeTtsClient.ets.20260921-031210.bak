/**
 * Edge-TTS 协议客户端（与 PC 版 ColorTxt voiceReadEdgeTts.ts / 真机验证过的 arkreader2 逐字对齐）。
 * 端点/签名/请求头/两帧/二进制帧解析 —— 协议参数全部常量化（微软调整时只改这里）。
 * 返回：mp3 ArrayBuffer + 词表（WordBoundary，100ns→ms）。
 */
import { webSocket } from '@kit.NetworkKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { langOfVoice } from './EdgeVoices';

const DOMAIN = 0x0001;
const TAG = 'EdgeTts';

// ---- 协议常量（可随微软调整更新） ----
const EDGE_TOKEN = '6A5AA1D4EAFF4E9FB37E23D68491D6F4';
const EDGE_GEC_VERSION = '1-143.0.3650.75';
const EDGE_UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36 Edg/143.0.0.0';
const EDGE_ORIGIN = 'chrome-extension://jdiccldimpdaibmpdkjnbmckianbfold';
const EDGE_URL = 'wss://speech.platform.bing.com/consumer/speech/synthesize/readaloud/edge/v1';
const CONNECT_TIMEOUT_MS = 15000;
const TURN_TIMEOUT_MS = 30000;

export interface WordSpan {
  text: string;
  startMs: number;
  endMs: number;
}

export interface SynthResult {
  mp3: ArrayBuffer;
  words: WordSpan[];
}

/** 是否含 TTS 可朗读的实义字符（字母、数字、CJK 等），纯标点/符号直接跳过，避免 Edge 长时间重试 */
export function hasSpeakableText(s: string): boolean {
  const t = s.replace(/\s/g, '');
  if (t.length === 0) {
    return false;
  }
  return /[\u3400-\u9fff\u3040-\u30ffA-Za-z0-9]/.test(t);
}

function strToU8(s: string): Uint8Array {
  const enc = new util.TextEncoder();
  return enc.encodeInto(s);
}

function bytesHexUpper(bytes: Uint8Array): string {
  const HEX = '0123456789ABCDEF';
  let out = '';
  for (let i = 0; i < bytes.length; i++) {
    out += HEX.charAt((bytes[i] >> 4) & 0xF) + HEX.charAt(bytes[i] & 0xF);
  }
  return out;
}

function randomHex(len: number, upper: boolean): string {
  const HEX = '0123456789abcdef';
  let out = '';
  for (let i = 0; i < len; i++) {
    out += HEX.charAt(Math.floor(Math.random() * 16));
  }
  return upper ? out.toUpperCase() : out;
}

/** Sec-MS-GEC：SHA256(ticks100ns + TOKEN)，ticks = Windows纪元秒(5分钟槽)×1e7（整秒×1e7=追加7个0） */
async function computeSecMsGec(): Promise<string> {
  const unixSec = Math.floor(Date.now() / 1000);
  let ticks = unixSec + 11644473600;
  ticks = ticks - (ticks % 300);
  const payload = ticks.toString() + '0000000' + EDGE_TOKEN;
  try {
    const md = cryptoFramework.createMd('SHA256');
    await md.update({ data: strToU8(payload) });
    const blob = await md.digest();
    return bytesHexUpper(blob.data);
  } catch (e) {
    throw new Error(`Sec-MS-GEC 计算失败：${e instanceof Error ? e.message : String(e)}`);
  }
}

function escapeXml(s: string): string {
  return s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;').replace(/'/g, '&apos;');
}

/** 按参考实现拼帧：逐行 "Key: value\r\n"，末尾空行再跟 body */
function genMessage(headers: string[], content: string): string {
  let header = '';
  for (let i = 0; i < headers.length; i++) {
    header += headers[i] + '\r\n';
  }
  return `${header}\r\n${content}`;
}

/**
 * 从协议头块中取出 Path 值（小写）。
 * 必须按 "Key: value" 逐行解析：Edge 实际下发的是 `Path:audio`（冒号后无空格），
 * 用字面量 'path: audio' 去 indexOf 会永远匹配失败，导致音频帧/turn.end 全部被丢弃。
 */
function headerPath(head: string): string {
  const lines = head.split('\r\n');
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    const idx = line.indexOf(':');
    if (idx <= 0) {
      continue;
    }
    if (line.substring(0, idx).trim().toLowerCase() === 'path') {
      return line.substring(idx + 1).trim().toLowerCase();
    }
  }
  return '';
}

/** Edge 不接受的控制字符（与 PC 版一致，避免合成失败） */
function cleanForEdge(s: string): string {
  let out = '';
  for (let i = 0; i < s.length; i++) {
    const code = s.charCodeAt(i);
    if (code <= 8 || (code >= 11 && code <= 12) || (code >= 14 && code <= 31)) {
      out += ' ';
    } else {
      out += s.charAt(i);
    }
  }
  return out;
}

function buildSsml(text: string, voice: string, lang: string, rate: number,
  pitch: number): string {
  const ratePct = Math.round((rate - 1) * 100);
  const rateStr = (ratePct >= 0 ? '+' : '') + ratePct + '%';
  const pitchHz = Math.round((pitch - 1) * 50);
  const pitchStr = (pitchHz >= 0 ? '+' : '') + pitchHz + 'Hz';
  return `<speak version="1.0" xmlns="http://www.w3.org/2001/10/synthesis" xml:lang="${lang}">` +
    `<voice name="${voice}"><prosody rate="${rateStr}" pitch="${pitchStr}">` +
    `${escapeXml(cleanForEdge(text))}</prosody></voice></speak>`;
}

function buildHeaders(): Record<string, string> {
  const h: Record<string, string> = {
    'User-Agent': EDGE_UA,
    'Accept-Encoding': 'gzip, deflate, br, zstd',
    'Accept-Language': 'en-US,en;q=0.9',
    'Pragma': 'no-cache',
    'Cache-Control': 'no-cache',
    'Origin': EDGE_ORIGIN,
    'Cookie': `muid=${randomHex(32, true)};`
  };
  return h;
}

/**
 * 合成一段文本。返回 mp3 与词表。
 * 失败时抛 Error（调用方做重试/跳句）。
 */
/**
 * P1 功耗自检：本进程内累计建立的 WebSocket 连接数。
 * 现状是**每块音频新建一条连接**（`synthesizeOnce` 里 `webSocket.createWebSocket()`，
 * 结束 `ws.close()`），因此该计数 ≈ 音频块数。射频侧每约 7 秒被唤醒一次做 TCP+TLS 握手，
 * 是网络侧的主要能量开销来源。仅用于观察，不参与任何逻辑。
 */
let wsConnSeq: number = 0;

export async function synthesizeOnce(text: string, voice: string, rate: number,
  pitch: number): Promise<SynthResult> {
  if (!hasSpeakableText(text)) {
    const empty: SynthResult = { mp3: new ArrayBuffer(0), words: [] };
    return empty;
  }
  let gec = '';
  try {
    gec = await computeSecMsGec();
  } catch (e) {
    throw e instanceof Error ? e : new Error(String(e));
  }
  const connId = randomHex(32, false);
  const url = `${EDGE_URL}?ConnectionId=${connId}&TrustedClientToken=${EDGE_TOKEN}` +
    `&Sec-MS-GEC=${gec}&Sec-MS-GEC-Version=${EDGE_GEC_VERSION}`;

  wsConnSeq++;
  hilog.info(DOMAIN, TAG, 'power: ws connect #%{public}d (new socket per chunk)', wsConnSeq);
  const ws = webSocket.createWebSocket();
  let mp3Parts: Uint8Array[] = [];
  let mp3Len = 0;
  const words: WordSpan[] = [];
  let turnEnded = false;
  let errMsg = '';
  let lastResponse = '';

  return new Promise<SynthResult>((resolve: (r: SynthResult) => void,
    reject: (e: Error) => void) => {
    const finish = (): void => {
      if (turnEnded) {
        return;
      }
      turnEnded = true;
      try {
        ws.off('message');
        ws.off('open');
        ws.off('close');
        ws.off('error');
      } catch (e) {
        // 忽略
      }
      try {
        // close() 返回 Promise：try/catch 抓不到它的 reject，必须直接挂 catch（审查发现）
        ws.close().catch((): void => {
          // 忽略关闭异常
        });
      } catch (e) {
        // 忽略
      }
      if (mp3Len > 0) {
        const mp3 = new ArrayBuffer(mp3Len);
        const view = new Uint8Array(mp3);
        let off = 0;
        for (let i = 0; i < mp3Parts.length; i++) {
          view.set(mp3Parts[i], off);
          off += mp3Parts[i].length;
        }
        const result: SynthResult = { mp3: mp3, words: words };
        hilog.info(DOMAIN, TAG, 'synth ok mp3=%{public}dB words=%{public}d',
          mp3Len, words.length);
        resolve(result);
      } else {
        const reason = errMsg.length > 0
          ? errMsg
          : (lastResponse.length > 0 ? `服务返回：${lastResponse.substring(0, 200)}` : '无音频返回');
        hilog.error(DOMAIN, TAG, 'synth fail %{public}s', reason);
        reject(new Error(reason));
      }
    };
    const timeoutId = setTimeout(() => {
      errMsg = '合成超时';
      finish();
    }, TURN_TIMEOUT_MS);

    // 与 PC 版逐字对齐的帧构造：头顺序 Content-Type / Path / X-RequestId / X-Timestamp，
    // X-RequestId 直接用 ConnectionId，X-Timestamp 用 Date.toString() 不加 Z 后缀。
    const date = new Date().toString();
    // ArkTS 禁止无类型嵌套对象字面量，故直接按 PC 版的 JSON 结构拼串
    const configBody = '{"context":{"synthesis":{"audio":' +
      '{"metadataoptions":{"sentenceBoundaryEnabled":false,"wordBoundaryEnabled":true},' +
      '"outputFormat":"audio-24khz-48kbitrate-mono-mp3"}}}}';
    const configMsg = genMessage([
      'Content-Type: application/json; charset=utf-8',
      'Path: speech.config',
      `X-Timestamp: ${date}`
    ], configBody);
    const ssmlMsg = genMessage([
      'Content-Type: application/ssml+xml',
      'Path: ssml',
      `X-RequestId: ${connId}`,
      `X-Timestamp: ${date}`
    ], buildSsml(text, voice, langOfVoice(voice), rate, pitch));

    // 只在 open 时发送（与 PC 版一致）。真机实测：open 前发送的帧会被内核静默丢弃。
    let framesSent = false;
    const sendOnce = (): void => {
      if (turnEnded || framesSent) {
        return;
      }
      framesSent = true;
      ws.send(configMsg, (e1: Error | undefined) => {
        if (e1) {
          errMsg = `发送配置失败：${e1.message}`;
          clearTimeout(timeoutId);
          finish();
          return;
        }
        ws.send(ssmlMsg, (e2: Error | undefined) => {
          if (e2) {
            errMsg = `发送 ssml 失败：${e2.message}`;
            clearTimeout(timeoutId);
            finish();
          }
        });
      });
    };

    ws.on('open', () => {
      sendOnce();
    });

    ws.on('message', (_err: Error | undefined, value: string | ArrayBuffer) => {
      if (turnEnded) {
        return;
      }
      if (typeof value === 'string') {
        // 文本帧：按 Path 分发
        const sep = value.indexOf('\r\n\r\n');
        if (sep < 0) {
          return;
        }
        const path = headerPath(value.substring(0, sep));
        const body = value.substring(sep + 4);
        if (path === 'turn.end') {
          clearTimeout(timeoutId);
          finish();
        } else if (path === 'response') {
          const t = body.trim();
          if (t.length > 0) {
            lastResponse = t;
          }
        } else if (path === 'audio.metadata') {
          try {
            const meta = JSON.parse(body) as Metadata;
            const items = meta.Metadata;
            for (let i = 0; i < items.length; i++) {
              if (items[i].Type === 'WordBoundary') {
                const d = items[i].Data;
                const startMs = d.Offset / 10000;
                const w: WordSpan = {
                  text: d.text.Text,
                  startMs: startMs,
                  endMs: startMs + d.Duration / 10000
                };
                words.push(w);
              }
            }
          } catch (e) {
            // 词表解析失败可容忍
          }
        }
      } else if (value instanceof ArrayBuffer) {
        // 二进制帧：2字节大端头长 + 头 + mp3
        if (value.byteLength < 2) {
          return;
        }
        const view = new DataView(value);
        const headLen = view.getUint16(0);
        if (value.byteLength < 2 + headLen) {
          return;
        }
        const headBytes = new Uint8Array(value, 2, headLen);
        if (headerPath(bytesToAscii(headBytes)) !== 'audio') {
          return;
        }
        const body = new Uint8Array(value, 2 + headLen, value.byteLength - 2 - headLen);
        if (body.length > 0) {
          mp3Parts.push(body);
          mp3Len += body.length;
        }
      }
    });

    ws.on('close', (_err: Error | undefined, value: Object) => {
      // 服务端主动断开（如 1002 协议错误）会带 reason，必须记下来定位根因
      let info = '';
      try {
        const v = value as webSocket.CloseResult;
        if (v !== undefined && v !== null) {
          info = `code=${v.code} reason=${v.reason}`;
        }
      } catch (e) {
        // 忽略
      }
      hilog.info(DOMAIN, TAG, 'ws closed %{public}s', info);
      if (!turnEnded) {
        if (info.length > 0) {
          errMsg = `连接被关闭(${info})`;
        }
        clearTimeout(timeoutId);
        finish();
      }
    });
    ws.on('error', (err: Error | undefined) => {
      // 【T6-1 取证·纯增量，不改 errMsg 语义】
      // 官方 FAQ `faqs-network-132` 的原机日志里，error 回调对象形如 {"code":200,"data":"0"}；
      // 而错误码表 `errorcode-net-websocket` 中 `200` 一条覆盖 4 种原因
      // （连接建立失败 / 链路异常断开 / header 处理异常 / 系统内部异常）。
      // 这里把 code 一并落日志，便于与 hilog 里 NETSTACK 的
      // `lws callback reason is N` / `Lws client connection error ...` 对齐定位。
      const be = err as BusinessError;
      const code = be !== undefined && be.code !== undefined ? be.code : -1;
      hilog.error(DOMAIN, TAG, 'ws error code=%{public}d msg=%{public}s', code,
        err !== undefined && err.message !== undefined ? err.message : '');
      errMsg = err !== undefined && err.message !== undefined ? err.message : '连接错误';
      if (!turnEnded) {
        clearTimeout(timeoutId);
        finish();
      }
    });

    const connectTimeout = setTimeout(() => {
      errMsg = '连接超时';
      if (!turnEnded) {
        finish();
      }
    }, CONNECT_TIMEOUT_MS);

    const options: webSocket.WebSocketRequestOptions = { header: buildHeaders() };
    ws.connect(url, options, (err: Error | undefined) => {
      clearTimeout(connectTimeout);
      if (turnEnded) {
        return;
      }
      if (err) {
        errMsg = err.message !== undefined ? err.message : '握手失败';
        clearTimeout(timeoutId);
        finish();
        return;
      }
      // 连接请求已创建（不代表链路可用）；真正的发送在 on('open') 里
    });
  });
}

function bytesToAscii(bytes: Uint8Array): string {
  let out = '';
  for (let i = 0; i < bytes.length; i++) {
    out += String.fromCharCode(bytes[i]);
  }
  return out;
}

interface Metadata {
  Metadata: MetadataItem[];
}

interface MetadataItem {
  Type: string;
  Data: MetadataData;
}

interface MetadataData {
  Offset: number;
  Duration: number;
  text: MetadataText;
}

interface MetadataText {
  Text: string;
  Length: number;
}
