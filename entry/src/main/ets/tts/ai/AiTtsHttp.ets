/**
 * AI 语音合成 —— HTTP / 编解码工具（自研）。
 *
 * 依赖的鸿蒙 API（全部取自本机 SDK 声明原文）：
 *  · `http.createHttp()` → `request(url, options?): Promise<HttpResponse>`
 *    `@ohos.net.http.d.ts:1500`
 *  · `HttpRequestOptions.expectDataType?`（`:135`）/ `HttpDataType.ARRAY_BUFFER = 2`（`:2436`）
 *  · `connectTimeout?`（`:191`）/ `readTimeout?`（`:182`）
 *  · `util.Base64Helper.decodeSync(src, options?): Uint8Array`（`@ohos.util.d.ts:1806`）
 *    `util.Type.BASIC | MIME | BASIC_URL_SAFE | MIME_URL_SAFE`（`:1679-1723`）
 * ⚠️ 本环境无法出网，故**服务端字段名不做假设**：请求体按标准形拼装，
 *    附加 JSON 由用户补，错误原文一律回显到 UI（见方案 §13.3 / §13.4）。
 */
import { http } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { AiCancelToken } from './AiTtsTypes';

const AI_TAG: string = 'AiTtsHttp';
const DOMAIN: number = 0x0001;
const AI_CONNECT_TIMEOUT_MS: number = 15000;
const AI_READ_TIMEOUT_MS: number = 60000;

/**
 * BusinessError 码 → 人话（**只列我们真会遇到的**）。
 * 错误码原文取自本机 SDK：`@ohos.net.http.d.ts:2300006/2300007/2300028/2300997/2300998…`
 * （其中 `2300028 - Operation timeout.` 见 `:1345/1411/1475/1538/1586/1638/1688`）。
 *
 * 为什么加这个（2026-10-09 真机教训）：用户接 DeepSeek 报"网络错误"，
 * 日志里只有 `errCode:2300028 + connect:0.000 + RespCode:0`，
 * 而应用侧**一个字都没打**，无法自查到底是"连不上"还是"接口不存在"。
 */
export function httpErrHint(code: number): string {
  if (code === 2300005) {
    return '代理域名解析失败';
  }
  if (code === 2300006) {
    return '域名解析失败：接口地址可能写错';
  }
  if (code === 2300007) {
    return '无法连接到服务器：网络不可达或端口被拦';
  }
  if (code === 2300028) {
    return '连接超时：TCP 都没握上手（主机不可达／被网络拦截／地址填错）';
  }
  if (code === 2300997) {
    // ⚠️ 官方 FAQ 原文（documentId `FAQ/网络/网络_Network/Stage模型如何配置支持http明文传输/faqs-network-16`）：
    //    「无需配置，支持HTTP明文传输数据。」⇒ Stage 模型下 **http:// 是可用的**，
    //    本工程就是 Stage 模型（`module.json5` 的 EntryAbility）。所以这条提示改成中性描述，
    //    免得误导用户以为必须上 https（局域网自建 TTS 全是 http）。
    return '系统拦截了明文 HTTP（少见）：Stage 模型按官方 FAQ 无需配置即可用 http，'
      + '若确实被拦请改用 https 或检查网络管控策略';
  }
  if (code === 2300998) {
    return '系统禁止访问该域名（网络管控）';
  }
  if (code === 2300009) {
    return '服务端拒绝访问';
  }
  if (code === 2300052) {
    return '服务端无响应内容';
  }
  if (code === 2300001) {
    return '协议不支持（只支持 http/https）';
  }
  return '';
}

/** 只保留 scheme+host+path（去掉查询串，避免万一 Key 被写在 query 里时进日志） */
export function safeUrlForLog(url: string): string {
  const q: number = url.indexOf('?');
  return q >= 0 ? url.substring(0, q) : url;
}

export interface AiHttpResult {
  code: number;
  isBinary: boolean;
  text: string;
  bin: ArrayBuffer;
}

/** 取消时统一抛这个文案（TtsEngine 的重试/垫片路径按消息区分处理） */
export const AI_CANCELLED_MSG: string = 'AI 合成已取消';

function emptyBuf(): ArrayBuffer {
  return new ArrayBuffer(0);
}

/** 行式请求头：一行 `Key: Value`；空行与 `#` 开头的行忽略 */
export function parseHeaderLines(raw: string, into: Record<string, string>): void {
  const lines: string[] = raw.split('\n');
  for (let i = 0; i < lines.length; i++) {
    const line: string = lines[i].trim();
    if (line.length === 0 || line.startsWith('#')) {
      continue;
    }
    const idx: number = line.indexOf(':');
    if (idx <= 0) {
      continue;
    }
    const k: string = line.substring(0, idx).trim();
    const v: string = line.substring(idx + 1).trim();
    if (k.length > 0) {
      into[k] = v;
    }
  }
}

/**
 * base64 → ArrayBuffer。
 * 先剔除空白（许多服务端返回带换行的 base64），再用 SDK 的 Base64Helper 解码。
 */
export function decodeBase64(b64: string): ArrayBuffer {
  const clean: string = b64.replace(/[\r\n\t ]/g, '');
  if (clean.length === 0) {
    return emptyBuf();
  }
  const helper = new util.Base64Helper();
  let u8: Uint8Array;
  try {
    u8 = helper.decodeSync(clean, util.Type.BASIC);
  } catch (e) {
    // URL-safe 变体（`-`/`_`）兜底
    u8 = helper.decodeSync(clean, util.Type.BASIC_URL_SAFE);
  }
  const out = new ArrayBuffer(u8.byteLength);
  new Uint8Array(out).set(u8);
  return out;
}

/** 是否像十六进制串（MiniMax 一类可能返回 hex 而非 base64） */
export function looksLikeHex(s: string): boolean {
  const t: string = s.trim();
  if (t.length === 0 || t.length % 2 !== 0) {
    return false;
  }
  return /^[0-9a-fA-F]+$/.test(t);
}

export function decodeHex(hex: string): ArrayBuffer {
  const t: string = hex.trim();
  const n: number = t.length >> 1;
  const out = new ArrayBuffer(n);
  const view = new Uint8Array(out);
  for (let i = 0; i < n; i++) {
    view[i] = parseInt(t.substring(i * 2, i * 2 + 2), 16);
  }
  return out;
}

/** 二进制或文本智能解码：像 hex 就按 hex，否则按 base64 */
export function decodeAudioField(raw: string): ArrayBuffer {
  const t: string = raw.trim();
  if (looksLikeHex(t)) {
    return decodeHex(t);
  }
  return decodeBase64(t);
}

/** 字节是否像 MP3（ID3 头 或 MPEG 帧同步） */
export function looksLikeMp3(buf: ArrayBuffer): boolean {
  const n: number = buf.byteLength;
  if (n >= 3) {
    const v3 = new Uint8Array(buf, 0, 3);
    if (v3[0] === 0x49 && v3[1] === 0x44 && v3[2] === 0x33) {
      return true;
    }
  }
  if (n >= 2) {
    const v2 = new Uint8Array(buf, 0, 2);
    if (v2[0] === 0xFF && (v2[1] & 0xE0) === 0xE0) {
      return true;
    }
  }
  return false;
}

/**
 * **智能解码音频字段**（2026-10-10 审查发现的风险修复）。
 * MiniMax 的 `data.audio` 可能是 hex 也可能是 base64，而"像 hex"的判据
 * （全为 0-9a-f 且长度为偶数）对**短 base64 串**可能误判 ⇒ 解出来是垃圾音频。
 * 这里改成"**解出来像 MP3 的那个方案优先**"，两种都试、以内容为准。
 */
export function decodeAudioSmart(raw: string): ArrayBuffer {
  const t: string = raw.trim();
  if (!looksLikeHex(t)) {
    return decodeBase64(t);
  }
  const asHex: ArrayBuffer = decodeHex(t);
  if (looksLikeMp3(asHex)) {
    return asHex;
  }
  let asB64: ArrayBuffer;
  try {
    asB64 = decodeBase64(t);
  } catch (e) {
    return asHex;
  }
  if (looksLikeMp3(asB64)) {
    return asB64;
  }
  return asHex; // 都不像 MP3 ⇒ 维持原行为（hex 优先）
}

/** ArrayBuffer → utf-8 文本（错误体回显用） */
export function bufToText(buf: ArrayBuffer): string {
  if (buf.byteLength === 0) {
    return '';
  }
  try {
    return util.TextDecoder.create('utf-8').decodeToString(new Uint8Array(buf));
  } catch (e) {
    return '';
  }
}

/**
 * POST 请求。`binary=true` 时要求二进制（音频），否则要文本。
 * 失败一律抛 Error（消息里带 BusinessError.code / HTTP 状态码 / 服务端原文片段）。
 */
export async function aiHttpPost(url: string, headers: Record<string, string>, body: string,
  binary: boolean, cancel: AiCancelToken): Promise<AiHttpResult> {
  if (cancel.cancelled) {
    throw new Error(AI_CANCELLED_MSG);
  }
  const httpRequest = http.createHttp();
  try {
    const options: http.HttpRequestOptions = {
      method: http.RequestMethod.POST,
      header: headers,
      extraData: body,
      expectDataType: binary ? http.HttpDataType.ARRAY_BUFFER : http.HttpDataType.STRING,
      connectTimeout: AI_CONNECT_TIMEOUT_MS,
      readTimeout: AI_READ_TIMEOUT_MS
    };
    const resp: http.HttpResponse = await httpRequest.request(url, options);
    const result: AiHttpResult = {
      code: resp.responseCode,
      isBinary: false,
      text: '',
      bin: emptyBuf()
    };
    const r: string | Object | ArrayBuffer = resp.result;
    if (r instanceof ArrayBuffer) {
      result.bin = r as ArrayBuffer;
      result.isBinary = true;
      result.text = bufToText(r as ArrayBuffer);
    } else if (typeof r === 'string') {
      result.text = r as string;
    } else if (r !== null && r !== undefined) {
      result.text = JSON.stringify(r);
    }
    if (cancel.cancelled) {
      throw new Error(AI_CANCELLED_MSG);
    }
    return result;
  } catch (e) {
    if (e instanceof Error) {
      throw e;
    }
    const be = e as BusinessError;
    const code: number = be !== undefined && be.code !== undefined ? be.code : -1;
    const msg: string = be !== undefined && be.message !== undefined ? be.message : String(e);
    const hint: string = httpErrHint(code);
    // 取证用（真机排查必需）：URL（去 query）+ 错误码 + 原始消息
    hilog.error(DOMAIN, AI_TAG, 'post fail url=%{public}s code=%{public}d msg=%{public}s',
      safeUrlForLog(url), code, msg);
    throw new Error(`网络请求失败(${code}${hint.length > 0 ? ' ' + hint : ''})：${msg}`);
  } finally {
    // 与工程既有 TtsSpeaker 同款收尾（TtsSpeaker.ets:145-147）
    httpRequest.destroy();
  }
}

/** 把服务端错误体压成一行短文本给 UI（最长 300 字，换行折成空格） */
export function shortErrorBody(result: AiHttpResult): string {
  const raw: string = result.isBinary ? result.text : result.text;
  const one: string = raw.replace(/[\r\n]+/g, ' ').trim();
  if (one.length === 0) {
    return '';
  }
  return one.length > 300 ? one.substring(0, 300) + '…' : one;
}

/** 多个字节块合并（SSE / NDJSON 流式分片累积用） */
export function concatBytes(parts: Uint8Array[], total: number): ArrayBuffer {
  const out = new ArrayBuffer(total);
  const dst = new Uint8Array(out);
  let off: number = 0;
  for (let i = 0; i < parts.length; i++) {
    dst.set(parts[i], off);
    off += parts[i].byteLength;
  }
  return out;
}

/** URL 拼接：base 末尾斜杠与 path 首斜杠去重 */
export function joinUrl(base: string, path: string): string {
  let b: string = base.trim();
  while (b.endsWith('/')) {
    b = b.substring(0, b.length - 1);
  }
  let p: string = path.trim();
  if (!p.startsWith('/')) {
    p = '/' + p;
  }
  return b + p;
}

/**
 * 从音频字节**嗅探真实容器格式**（2026-10-10 新增）。
 *
 * 为什么必须有：`response_format` 是**请求**参数，服务端**经常忽略它**
 * （中转站、自建服务、本地 mock 都常见）。若我们只信请求参数，就会把 mp3 当 wav 解析
 * ⇒ `parseWavPcm` 失败 ⇒ 回落"当裸 PCM"⇒ 满耳噪音。
 * ⇒ 拿到字节后按**内容**判定，并以内容为准（同时打日志留痕）。
 *
 * 判据：
 *  · `RIFF`(0-3) + `WAVE`(8-11) ⇒ wav
 *  · `ID3`(0-2) 或 MPEG 帧同步 `0xFF Ex/Fx` ⇒ mp3
 *  · 其它 ⇒ 按请求参数兜底（裸 pcm 无魔数，只能靠调用方约定）
 */
export function sniffAudioFormat(buf: ArrayBuffer, fallback: string): string {
  const n: number = buf.byteLength;
  if (n >= 12) {
    const v = new Uint8Array(buf, 0, 12);
    if (v[0] === 0x52 && v[1] === 0x49 && v[2] === 0x46 && v[3] === 0x46
      && v[8] === 0x57 && v[9] === 0x41 && v[10] === 0x56 && v[11] === 0x45) {
      return 'wav';
    }
  }
  if (n >= 3) {
    const v3 = new Uint8Array(buf, 0, 3);
    if (v3[0] === 0x49 && v3[1] === 0x44 && v3[2] === 0x33) {
      return 'mp3';
    }
  }
  if (n >= 2) {
    const v2 = new Uint8Array(buf, 0, 2);
    if (v2[0] === 0xFF && (v2[1] & 0xE0) === 0xE0) {
      return 'mp3';
    }
  }
  return fallback;
}
