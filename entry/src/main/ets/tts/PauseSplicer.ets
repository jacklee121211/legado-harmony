/**
 * 标点停顿 PCM 拼接（对齐 PC 版 ColorTxt voiceReadPunctuationPauses.ts）。
 * 依据 Edge 返回的 WordBoundary 词级时间戳，把每个标点附近的原始间隙替换为
 * 设定时长的干净静音（按语速缩放、带 2ms 淡入淡出、可叠加音量），
 * 并输出"原始时间轴 → 拼接后时间轴"映射，供句级文本显示使用。
 * 本模块为纯算法，输入 S16LE 单声道 PCM。
 */
import { WordSpan } from './EdgeTtsClient';

const SENTENCE_PUNCT_RE = /[。！？…]/u;
const COMMA_PUNCT_RE = /[，；：、]/u;
const CLOSING_QUOTE_RE = /[」』”’"']/u;
const MAX_SCALED_PAUSE_MS = 10000;
const FADE_SEC = 0.002;
const END_OF_AUDIO_MS = 1e9;

/**
 * ── 块边界淡入淡出（2026-10-11 新增，治「块间咔哒声」）──────────────────────
 *
 * **默认 true = 启用新行为**；设为 false 即完全回退到旧行为（无其它副作用）。
 *
 * 为什么需要（真机日志驱动）：
 *   AI 引擎**每块独立合成**，块与块之间要等下一次网络返回；而系统给我们的
 *   播放缓冲**只有 20~40ms**（证据：`PcmPlayer.ets:156-158` 真机 162/162 次
 *   `[GetBufferSize]Buffer size is 960` ⇒ 960B÷2÷24000Hz ≈ 20ms），
 *   所以块播放完、下一块还没到时会**缓冲欠载（underrun）**。
 *   欠载时硬件停在**最后一个采样值**上，下一块头部又是**非零起跳**
 *   ⇒ 波形突变 ⇒ **咔哒爆音**（用户 2026-10-12 实测描述："使用中咔哒声"）。
 *
 * 为什么改在这里：
 *   `applyPauses` 的输出**就是最终送去播放的 PCM**（`TtsEngine.ets:3034`）。
 *   旧实现在 `points.length === 0` 时**直接 return**（不淡入淡出），
 *   而"无停顿点"恰恰是短块的常态 ⇒ **块边界完全没有处理**。
 *   块内切分（有停顿点时）本来就有 2ms 淡入淡出，此处补齐**块首尾**。
 *
 * ── 斜坡时长取值（2026-10-12 一轮调参）────────────────────────────────────
 *  v1 = 2ms：真机反馈「还有咔的一声，但好像好多了」⇒ 未彻底消除，加大。
 *  v2 = **5ms（当前）**：真机 `docs/日志.md` 实测 `WriteUnderrunEvent` **0 次**
 *      （修复前同场景为 3 次），但用户仍能听到残余咔声 ⇒ 继续加斜坡。
 *  为什么独立于块内的 `FADE_SEC`：两者的听感约束不同 ——
 *      块内斜坡作用在**停顿静音的边缘**（静音本身无能量，2ms 足够且更自然）；
 *      块边界斜坡作用在**有声段的首尾**（需更缓的包络才能压住爆音）。
 *      若共用一个常量，调块边界会误伤块内停顿的自然度。
 */
const EDGE_FADE_ENABLED: boolean = true;

/**
 * 块边界斜坡时长（秒）。
 *
 * ⚠️ 调参注意（用真机日志的块大小核算过，`docs/日志.md` 的 `ai pcm: samples=`）：
 *   最短块 1361ms ⇒ 首尾各 5ms 共占 **0.73%**，仍听不出吃字；
 *   若继续加到 10ms 则占 1.47%，短块上开始有"字头发闷"的风险。
 */
const EDGE_FADE_SEC: number = 0.008;

/**
 * 对整段 PCM 的首尾施加淡入淡出（块边界去咔哒）。
 *
 * - **只改极短的头部与尾部**（各 {@link EDGE_FADE_SEC}），中段逐样本不变；
 * - 原地修改，不产生新数组（大块 PCM 下避免多一次拷贝）；
 * - 斜坡用**升余弦**而非线性：线性斜坡的**一阶导数在两端突变**，听感上仍可能
 *   留下轻微「嗒」；升余弦包络两端导数为 0，更干净（v2 从线性改为余弦）。
 *
 * @param pcm S16LE 单声道样本
 * @param sampleRate 采样率（用于把 EDGE_FADE_SEC 换算成样本数）
 */
export function applyEdgeFade(pcm: Int16Array, sampleRate: number): void {
  if (!EDGE_FADE_ENABLED) {
    return;
  }
  const len: number = pcm.length;
  if (len <= 1) {
    return;
  }
  const n: number = Math.max(1, Math.round(EDGE_FADE_SEC * sampleRate));
  if (len < n * 2) {
    // 极短块（比两段斜坡还短）：整块做成一个三角包络，避免中间出现突跳
    for (let k = 0; k < len; k++) {
      const pos: number = len === 1 ? 1 : k / (len - 1);
      pcm[k] = Math.round(pcm[k] * pos);
    }
    return;
  }
  // 淡入：升余弦 g = 0.5 - 0.5*cos(pi*t)，t 从 0 到 1（两端导数均为 0）
  for (let k = 0; k < n; k++) {
    const t: number = k / n;
    const g: number = 0.5 - 0.5 * Math.cos(Math.PI * t);
    pcm[k] = Math.round(pcm[k] * g);
  }
  // 淡出：与淡入对称
  for (let k = 0; k < n; k++) {
    const i: number = len - 1 - k;
    const t: number = k / n;
    const g: number = 0.5 - 0.5 * Math.cos(Math.PI * t);
    pcm[i] = Math.round(pcm[i] * g);
  }
}


export interface PauseRun {
  start: number;
  end: number;
  isSentence: boolean;
}

export interface PausePoint {
  fromMs: number;
  toMs: number;
  kind: string; // 'sentence' | 'comma'
}

export interface TimeMapEntry {
  origMs: number;
  adjMs: number;
}

export interface SpliceResult {
  pcm: Int16Array;
  sampleRate: number;
  timeMap: TimeMapEntry[];
}

export interface SentenceMark {
  text: string;
  startAdjMs: number;
  /** 本句在所属合成块文本内的字符起点（换算"当前朗读位置"用） */
  charStart: number;
}

interface AlignedWord {
  startMs: number;
  endMs: number;
  charStart: number;
  charEnd: number;
}

function codePointAt(text: string, index: number): string {
  const cp = text.codePointAt(index);
  return cp === undefined ? '' : String.fromCodePoint(cp);
}

/** 收集标点停顿段（连续标点合并；句末优先；后随右引号并入） */
export function collectPauseRuns(text: string): PauseRun[] {
  const runs: PauseRun[] = [];
  let i = 0;
  while (i < text.length) {
    const ch = codePointAt(text, i);
    if (!ch) {
      break;
    }
    if (!SENTENCE_PUNCT_RE.test(ch) && !COMMA_PUNCT_RE.test(ch)) {
      i += ch.length;
      continue;
    }
    let j = i;
    let sawSentence = false;
    while (j < text.length) {
      const c = codePointAt(text, j);
      if (!c) {
        break;
      }
      if (SENTENCE_PUNCT_RE.test(c)) {
        sawSentence = true;
        j += c.length;
      } else if (COMMA_PUNCT_RE.test(c)) {
        j += c.length;
      } else if (CLOSING_QUOTE_RE.test(c)) {
        j += c.length;
      } else {
        break;
      }
    }
    runs.push({ start: i, end: j, isSentence: sawSentence });
    i = j;
  }
  return runs;
}

function alignWords(text: string, words: WordSpan[]): AlignedWord[] {
  const aligned: AlignedWord[] = [];
  let cursor = 0;
  for (let i = 0; i < words.length; i++) {
    const w = words[i];
    if (!w.text) {
      continue;
    }
    const idx = text.indexOf(w.text, cursor);
    if (idx < 0) {
      continue;
    }
    aligned.push({
      startMs: w.startMs,
      endMs: w.endMs,
      charStart: idx,
      charEnd: idx + w.text.length
    });
    cursor = idx + w.text.length;
  }
  return aligned;
}

function interpolateMs(w: AlignedWord, textIndex: number): number {
  const len = w.charEnd - w.charStart;
  if (len <= 0) {
    return w.startMs;
  }
  const t = Math.min(1, Math.max(0, (textIndex - w.charStart) / len));
  return w.startMs + t * (w.endMs - w.startMs);
}

/**
 * 把标点停顿段映射为音频内待替换区间（与停顿时长无关）。
 * 区间 = 标点前语音结束 → 标点后语音开始；词跨标点时按文本比例插值。
 */
export function computePausePoints(text: string, words: WordSpan[]): PausePoint[] {
  const runs = collectPauseRuns(text);
  if (runs.length === 0 || words.length === 0) {
    return [];
  }
  const aligned = alignWords(text, words);
  if (aligned.length === 0) {
    return [];
  }
  const out: PausePoint[] = [];
  for (let r = 0; r < runs.length; r++) {
    const run = runs[r];
    let prev: AlignedWord | null = null;
    let next: AlignedWord | null = null;
    for (let i = 0; i < aligned.length; i++) {
      const w = aligned[i];
      if (w.charStart < run.start) {
        prev = w;
      }
      if (next === null && w.charStart >= run.end) {
        next = w;
        break;
      }
    }
    let fromMs: number;
    if (prev !== null && prev.charEnd > run.start) {
      fromMs = interpolateMs(prev, run.start);
    } else if (prev !== null) {
      fromMs = prev.endMs;
    } else if (next !== null) {
      fromMs = next.startMs;
    } else {
      fromMs = 0;
    }
    let toMs: number;
    let overlappingAfter: AlignedWord | null = null;
    for (let i = 0; i < aligned.length; i++) {
      const w = aligned[i];
      if (w.charStart < run.end && w.charEnd > run.end) {
        overlappingAfter = w;
        break;
      }
    }
    if (overlappingAfter !== null) {
      toMs = interpolateMs(overlappingAfter, run.end);
    } else if (next !== null) {
      toMs = next.startMs;
    } else {
      toMs = END_OF_AUDIO_MS;
    }
    if (!Number.isFinite(fromMs) || !Number.isFinite(toMs)) {
      continue;
    }
    const point: PausePoint = {
      fromMs: fromMs,
      toMs: Math.max(fromMs, toMs),
      kind: run.isSentence ? 'sentence' : 'comma'
    };
    out.push(point);
  }
  return out;
}

interface PauseSampleRange {
  fromSample: number;
  toSample: number;
  durationSamples: number;
}

function mergeRanges(items: PauseSampleRange[]): PauseSampleRange[] {
  const merged: PauseSampleRange[] = [];
  for (let i = 0; i < items.length; i++) {
    const it = items[i];
    const last = merged.length > 0 ? merged[merged.length - 1] : null;
    if (last !== null && it.fromSample <= last.toSample) {
      last.toSample = Math.max(last.toSample, it.toSample);
      last.durationSamples = Math.max(last.durationSamples, it.durationSamples);
    } else {
      const copy: PauseSampleRange = {
        fromSample: it.fromSample,
        toSample: it.toSample,
        durationSamples: it.durationSamples
      };
      merged.push(copy);
    }
  }
  return merged;
}

function scaledPauseMs(configuredMs: number, rate: number): number {
  if (!Number.isFinite(configuredMs) || configuredMs <= 0) {
    return 0;
  }
  const r = Number.isFinite(rate) && rate > 0 ? rate : 1;
  return Math.min(MAX_SCALED_PAUSE_MS, configuredMs / r);
}

/**
 * 拼接停顿：把各 [from,to) 间隙替换为设定时长的静音（按语速缩放），
 * 全程施加音量系数，静音边缘 2ms 淡入淡出；返回新 PCM 与时间轴映射。
 */
export function applyPauses(pcm: Int16Array, sampleRate: number, points: PausePoint[],
  sentenceMs: number, commaMs: number, rate: number, volume: number): SpliceResult {
  const srcLen = pcm.length;
  const vol = Math.max(0, Math.min(1, volume));
  const timeMap: TimeMapEntry[] = [];
  const base: TimeMapEntry = { origMs: 0, adjMs: 0 };
  timeMap.push(base);
  if (srcLen <= 0 || sampleRate <= 0) {
    const r: SpliceResult = { pcm: pcm, sampleRate: sampleRate, timeMap: timeMap };
    return r;
  }
  const items: PauseSampleRange[] = [];
  for (let i = 0; i < points.length; i++) {
    const p = points[i];
    const durationMs = scaledPauseMs(p.kind === 'sentence' ? sentenceMs : commaMs, rate);
    const fromSample = Math.max(0, Math.min(srcLen, Math.round(p.fromMs / 1000 * sampleRate)));
    const toSample = Math.max(fromSample, Math.min(srcLen, Math.round(p.toMs / 1000 * sampleRate)));
    const durationSamples = Math.round(durationMs / 1000 * sampleRate);
    if (durationSamples > 0) {
      items.push({ fromSample: fromSample, toSample: toSample, durationSamples: durationSamples });
    }
  }
  if (items.length === 0) {
    if (vol < 1) {
      applyVolume(pcm, vol);
    }
    // ⚠️ 2026-10-11：「无停顿点」是短块常态，旧代码在此**直接返回、不做任何边缘处理**
    //   ⇒ 块首尾是非零起跳/截断 ⇒ 块间欠载时产生咔哒爆音。这里补上。
    applyEdgeFade(pcm, sampleRate);
    const r0: SpliceResult = { pcm: pcm, sampleRate: sampleRate, timeMap: timeMap };
    return r0;
  }
  items.sort((a: PauseSampleRange, b: PauseSampleRange): number => a.fromSample - b.fromSample);
  const merged = mergeRanges(items);
  let newLen = srcLen;
  for (let i = 0; i < merged.length; i++) {
    newLen += merged[i].durationSamples - (merged[i].toSample - merged[i].fromSample);
  }
  if (newLen <= 0) {
    applyEdgeFade(pcm, sampleRate);
    const r1: SpliceResult = { pcm: pcm, sampleRate: sampleRate, timeMap: timeMap };
    return r1;
  }
  const fade = Math.max(1, Math.round(FADE_SEC * sampleRate));
  const out = new Int16Array(newLen);
  let srcPos = 0;
  let dstPos = 0;
  let shiftSamples = 0;
  for (let i = 0; i < merged.length; i++) {
    const from = merged[i].fromSample;
    const to = merged[i].toSample;
    const speechLen = from - srcPos;
    copySegment(out, dstPos, pcm, srcPos, speechLen, dstPos > 0, true, fade, vol);
    dstPos += speechLen;
    // 记录时间轴映射：经过该停顿后，原始 to 之后的时刻整体平移 shift
    dstPos += merged[i].durationSamples;
    shiftSamples += merged[i].durationSamples - (to - from);
    const entry: TimeMapEntry = {
      origMs: to * 1000 / sampleRate,
      adjMs: (to + shiftSamples) * 1000 / sampleRate
    };
    timeMap.push(entry);
    srcPos = to;
  }
  const tailLen = srcLen - srcPos;
  copySegment(out, dstPos, pcm, srcPos, tailLen, dstPos > 0, false, fade, vol);
  // ⚠️ 2026-10-11：`copySegment` 的 fadeIn 依赖 `dstPos > 0`，**首段不淡入**；
  //   末尾段 fadeOut=false。这两处正是**块的首尾边界** ⇒ 在此统一补齐淡入淡出。
  applyEdgeFade(out, sampleRate);
  const result: SpliceResult = { pcm: out, sampleRate: sampleRate, timeMap: timeMap };
  return result;
}

function applyVolume(pcm: Int16Array, vol: number): void {
  for (let i = 0; i < pcm.length; i++) {
    pcm[i] = Math.round(pcm[i] * vol);
  }
}

function copySegment(dst: Int16Array, dstPos: number, src: Int16Array, srcPos: number,
  len: number, fadeIn: boolean, fadeOut: boolean, fade: number, vol: number): void {
  if (len <= 0) {
    return;
  }
  const n = Math.min(fade, len);
  for (let k = 0; k < len; k++) {
    let g = vol;
    if (fadeIn && k < n) {
      g *= k / n;
    }
    if (fadeOut && k >= len - n) {
      g *= (len - 1 - k) / n;
    }
    dst[dstPos + k] = Math.round(src[srcPos + k] * g);
  }
}

/** 查询拼接后时间轴：原始 origMs 对应的调整时刻 */
export function lookupAdjMs(timeMap: TimeMapEntry[], origMs: number): number {
  let base = timeMap[0];
  for (let i = 1; i < timeMap.length; i++) {
    const e = timeMap[i];
    if (e.origMs <= origMs) {
      base = e;
    } else {
      break;
    }
  }
  return base.adjMs + (origMs - base.origMs);
}

/** 反查：拼接后时刻 adjMs 对应的原始时刻（句内字符进度用） */
export function lookupOrigMs(timeMap: TimeMapEntry[], adjMs: number): number {
  let base = timeMap[0];
  for (let i = 1; i < timeMap.length; i++) {
    const e = timeMap[i];
    if (e.adjMs <= adjMs) {
      base = e;
    } else {
      break;
    }
  }
  return base.origMs + (adjMs - base.adjMs);
}

/**
 * ── 无词级时间戳时的句起点估算（2026-10-19 新增，治「高亮永远钉在末句」）─────
 *
 * ── 问题（用户真机反馈，原文）─────────────────────────────────────────────
 *   「开启沉浸听读之后，每次阅读高亮都是标记某一段的**最后一两句**，并且我发现
 *     系统的播放组件，锁屏的播放组件都是这样，在显示歌词的时候也是这种感觉，
 *     明明某一段刚开始，实际显示的却是最后的一两句。」
 *
 * ── 根因（读代码得出，非推测）──────────────────────────────────────────────
 *   `TtsEngine.playChunk` 的播放回调是这样挑当前句的（`TtsEngine.ets:3442-3457`）：
 *       for (let m = timeline.length - 1; m >= 0; m--) {
 *         if (ms >= timeline[m].startAdjMs) { …选中这一句…; break; }
 *       }
 *   **从末尾往前**找第一个"已开始"的小句 ⇒ 只要所有小句的 `startAdjMs` 都等于 0，
 *   它必然命中该块的**最后一句**。
 *
 *   而它们确实全是 0：
 *     · 本地引擎 `TtsEngine.ets:2894` `chunk.words = [];`
 *     · AI 引擎  `TtsEngine.ets:2918` `chunk.words = [];`
 *     · 只有 Edge 是 `chunk.words = r.words;`（`TtsEngine.ets:2928`，有词级时间戳）
 *   ⇒ `words` 空 ⇒ `alignWords()` 返回空数组 ⇒ 下面 `pushSentenceMark` 里找 `origMs`
 *     的循环一次都不进 ⇒ `origMs` 停在 -1 ⇒ 落到 `aligned.length > 0 ? … : 0`
 *     ⇒ **0** ⇒ `startAdjMs = lookupAdjMs(timeMap, 0) = 0`。
 *
 *   ⇒ 华为本地 TTS 与 AI 语音**必然**全句零时刻；Edge 不受影响。
 *     锁屏/下拉播控中心的歌词同源（三处吃同一份 timeline/LRC，见
 *     `TtsEngine.ets:3400-3434` 与 `lrcTagMs`），所以一起坏、一起好。
 *
 * ── 修法 ───────────────────────────────────────────────────────────────────
 *   `words` 为空且**已知本块音频总时长**时，按"该句之前已消耗的可朗读字符占比"
 *   线性估算该句起点：`estOrigMs = totalMs × (句前可朗读字符数 / 全块可朗读字符数)`。
 *   朗读是匀速的，这个线性模型对 TTS 产物足够准（不需要精确到词）。
 *
 * ── 一键回退 ───────────────────────────────────────────────────────────────
 *   两个入口的 `totalMs` 默认 `0` ⇒ 直接走旧公式（全 0）⇒ 与改动前逐字一致。
 *   回退后要验证：高亮/歌词重新回到"总在末句"的旧行为。
 */
function countSpeakable(text: string, from: number, to: number): number {
  let n = 0;
  const end = Math.min(to, text.length);
  for (let i = from; i < end; i++) {
    const c = text.charAt(i);
    if (!SENTENCE_PUNCT_RE.test(c) && !COMMA_PUNCT_RE.test(c)
      && !CLOSING_QUOTE_RE.test(c) && !/\s/.test(c)) {
      n++;
    }
  }
  return n;
}

/**
 * 句级文本时间线（拼接后时间轴）：供播放进度 → 当前句显示。
 * @param totalMs 本块**拼接后**的音频总时长（ms）。`>0` 且无词级时间戳时启用
 *   字符占比估算；`0`（默认）= 旧行为（全 0 时刻，即"总在末句"）。
 */
export function buildSentenceTimeline(text: string, words: WordSpan[],
  timeMap: TimeMapEntry[], totalMs: number = 0): SentenceMark[] {
  return buildTimeline(text, words, timeMap, false, totalMs);
}

/**
 * 歌词行时间线（拼接后时间轴）：**按小句切** —— 句末标点与逗号类标点都断行。
 *
 * 唯一用途：生成推给系统歌词组件的 LRC 行（`TtsEngine.chapterLrcLines`）。
 *
 * 为什么必须切短（真机反馈 2026-10-08，用户原话"很难看到歌词的前面几个字"）：
 *  横向组件（播控中心**副标题区域**，官方口径"播控中心会自动按照进度，在副标题位置
 *  刷新显示"）一次只摆**一行**文字；行太长就必须横向滚动才看得全，而滚动是跟着朗读
 *  进度走的 ⇒ 句首几个字在用户反应过来之前就已经滚出可视区。
 *  切成一两个词的小句后，绝大多数行能**整行显示、根本不滚**，句首自然看得见。
 *  竖向列表页同时受益：高亮推进更细（≈ 每 2~3 秒一次），更接近歌词的观感。
 *
 * ⚠️ 只给歌词用。**不要**拿它当播放进度用：朗读浮条 / `onSegment` 仍是句级语义。
 */
export function buildLyricTimeline(text: string, words: WordSpan[],
  timeMap: TimeMapEntry[], totalMs: number = 0): SentenceMark[] {
  return buildTimeline(text, words, timeMap, true, totalMs);
}

/**
 * 时间线生成器（句级 / 小句级共用同一套词级对齐与时间映射，故时间精度同源）。
 * @param splitOnClause true = 逗号类标点也断行（歌词用），false = 只在句末断行（播放用）
 * @param totalMs 本块拼接后总时长（ms）；`>0` 且无词级时间戳时按字符占比估算句起点。
 *   见 `buildSentenceTimeline` 上方那段根因说明。
 */
function buildTimeline(text: string, words: WordSpan[], timeMap: TimeMapEntry[],
  splitOnClause: boolean, totalMs: number = 0): SentenceMark[] {
  const marks: SentenceMark[] = [];
  const aligned = alignWords(text, words);
  if (text.length === 0) {
    return marks;
  }
  // 无词级时间戳 + 已知总时长 ⇒ 启用字符占比估算（否则沿用全 0 的旧行为）
  const est: boolean = aligned.length === 0 && totalMs > 0;
  const totalSpeakable: number = est ? countSpeakable(text, 0, text.length) : 0;
  let start = 0;
  for (let i = 0; i <= text.length; i++) {
    const isEnd = i >= text.length;
    const boundary = !isEnd && (sentenceEndAt(text, i)
      || (splitOnClause && COMMA_PUNCT_RE.test(text.charAt(i))));
    if (boundary) {
      // 越过句末标点与后随右引号
      let j = i + 1;
      while (j < text.length && CLOSING_QUOTE_RE.test(text.charAt(j))) {
        j++;
      }
      pushSentenceMark(marks, text, start, j, aligned, timeMap,
        est, totalSpeakable, totalMs);
      start = j;
      i = j - 1;
    }
  }
  if (start < text.length) {
    pushSentenceMark(marks, text, start, text.length, aligned, timeMap,
      est, totalSpeakable, totalMs);
  }
  return marks;
}

function sentenceEndAt(text: string, i: number): boolean {
  const c = text.charAt(i);
  return c === '。' || c === '！' || c === '？' || c === '…' || c === '!' || c === '?' || c === '\n';
}

function pushSentenceMark(marks: SentenceMark[], text: string, start: number, end: number,
  aligned: AlignedWord[], timeMap: TimeMapEntry[],
  est: boolean = false, totalSpeakable: number = 0, totalMs: number = 0): void {
  const segText = text.substring(start, end);
  let hasSpeakable = false;
  for (let i = 0; i < segText.length; i++) {
    const c = segText.charAt(i);
    if (!SENTENCE_PUNCT_RE.test(c) && !COMMA_PUNCT_RE.test(c)
      && !CLOSING_QUOTE_RE.test(c) && !/\s/.test(c)) {
      hasSpeakable = true;
      break;
    }
  }
  if (!hasSpeakable) {
    return;
  }
  let origMs = -1;
  for (let i = 0; i < aligned.length; i++) {
    const w = aligned[i];
    if (w.charEnd > start) {
      origMs = interpolateMs(w, start);
      break;
    }
  }
  if (origMs < 0) {
    if (est && totalSpeakable > 0) {
      // 无词级时间戳：按"本句之前已消耗的可朗读字符占比"估算起点。
      // 为什么用**可朗读字符**而不是 `start / text.length`：标点/空白不发声，
      // 用全长会把纯标点段和长空白算进时间，句起点整体后移（短块上误差可达 20%+）。
      const before: number = countSpeakable(text, 0, start);
      origMs = totalMs * Math.min(1, before / totalSpeakable);
    } else {
      origMs = aligned.length > 0 ? aligned[aligned.length - 1].endMs : 0;
    }
  }
  const mark: SentenceMark = {
    text: segText.trim(),
    startAdjMs: lookupAdjMs(timeMap, origMs),
    charStart: start
  };
  marks.push(mark);
}
