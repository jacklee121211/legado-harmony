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
 * 句级文本时间线（拼接后时间轴）：供播放进度 → 当前句显示。
 */
export function buildSentenceTimeline(text: string, words: WordSpan[],
  timeMap: TimeMapEntry[]): SentenceMark[] {
  return buildTimeline(text, words, timeMap, false);
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
  timeMap: TimeMapEntry[]): SentenceMark[] {
  return buildTimeline(text, words, timeMap, true);
}

/**
 * 时间线生成器（句级 / 小句级共用同一套词级对齐与时间映射，故时间精度同源）。
 * @param splitOnClause true = 逗号类标点也断行（歌词用），false = 只在句末断行（播放用）
 */
function buildTimeline(text: string, words: WordSpan[], timeMap: TimeMapEntry[],
  splitOnClause: boolean): SentenceMark[] {
  const marks: SentenceMark[] = [];
  const aligned = alignWords(text, words);
  if (text.length === 0) {
    return marks;
  }
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
      pushSentenceMark(marks, text, start, j, aligned, timeMap);
      start = j;
      i = j - 1;
    }
  }
  if (start < text.length) {
    pushSentenceMark(marks, text, start, text.length, aligned, timeMap);
  }
  return marks;
}

function sentenceEndAt(text: string, i: number): boolean {
  const c = text.charAt(i);
  return c === '。' || c === '！' || c === '？' || c === '…' || c === '!' || c === '?' || c === '\n';
}

function pushSentenceMark(marks: SentenceMark[], text: string, start: number, end: number,
  aligned: AlignedWord[], timeMap: TimeMapEntry[]): void {
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
    origMs = aligned.length > 0 ? aligned[aligned.length - 1].endMs : 0;
  }
  const mark: SentenceMark = {
    text: segText.trim(),
    startAdjMs: lookupAdjMs(timeMap, origMs),
    charStart: start
  };
  marks.push(mark);
}
