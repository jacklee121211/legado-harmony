/**
 * 切句：CJK 计 2 单位、上限 800（对齐 PC 版 chunk 粒度，减少合成请求数）；
 * 句末标点贪心装箱 + 旁白/对白引号状态机分段。
 * 标点停顿由 PauseSplicer 在 PCM 内实现，不依赖块尾标点。
 * 引号风格可配置（与 PC 版 dialogueQuoteStyles 对应，0="" 1='' 2=「」 3=『』）。
 */
import { hasSpeakableText } from './EdgeTtsClient';

export const CHUNK_MAX_UNITS = 800;

export interface SpeakSegment {
  nodeIndex: number;
  charStart: number;      // 段内字符偏移
  text: string;
  isDialogue: boolean;
  endsSentence: boolean;  // 段尾是否句末标点（决定段间停顿的兜底）
}

export function textUnits(s: string): number {
  let units = 0;
  for (let i = 0; i < s.length; i++) {
    const c = s.charCodeAt(i);
    units += (c >= 0x2E80 && c <= 0x9FFF) || (c >= 0x3040 && c <= 0x30FF)
      || (c >= 0xFF00 && c <= 0xFF60) ? 2 : 1;
  }
  return units;
}

const QUOTE_PAIRS: string[][] = [
  ['\u201C', '\u201D'],   // “”
  ['\u2018', '\u2019'],   // ‘’
  ['\u300C', '\u300D'],   // 「」
  ['\u300E', '\u300F']    // 『』
];

function styleEnabled(styles: number[], idx: number): boolean {
  for (let i = 0; i < styles.length; i++) {
    if (styles[i] === idx) {
      return true;
    }
  }
  return false;
}

function matchOpen(text: string, pos: number, styles: number[]): number {
  for (let q = 0; q < QUOTE_PAIRS.length; q++) {
    if (!styleEnabled(styles, q)) {
      continue;
    }
    const open = QUOTE_PAIRS[q][0];
    if (text.startsWith(open, pos)) {
      return q;
    }
  }
  return -1;
}

/**
 * 段落 → 朗读分段：引号状态机把对白与旁白交替切开。
 * 未闭合引号：其余文本全部视为对白延续（跨段由调用方用 carry 状态处理）。
 */
export function splitParagraphIntoSegments(nodeIndex: number, text: string,
  carryIn: boolean, quoteStyles: number[]): SpeakSegment[] {
  const out: SpeakSegment[] = [];
  let inQuote = carryIn;
  let segStart = 0;
  let segIsDialogue = inQuote;
  let i = 0;
  while (i < text.length) {
    const openIdx = matchOpen(text, i, quoteStyles);
    if (!inQuote && openIdx >= 0) {
      // 旁白结束，对白开始（引号并入对白）
      if (i > segStart) {
        out.push(makeSeg(nodeIndex, text, segStart, i, segIsDialogue));
      }
      segStart = i;
      segIsDialogue = true;
      inQuote = true;
      i += QUOTE_PAIRS[openIdx][0].length;
      continue;
    }
    if (inQuote) {
      let closed = false;
      for (let k = 0; k < QUOTE_PAIRS.length; k++) {
        if (!styleEnabled(quoteStyles, k)) {
          continue;
        }
        if (text.startsWith(QUOTE_PAIRS[k][1], i)) {
          i += QUOTE_PAIRS[k][1].length;
          inQuote = false;
          out.push(makeSeg(nodeIndex, text, segStart, i, true));
          segStart = i;
          segIsDialogue = false;
          closed = true;
          break;
        }
      }
      if (closed) {
        continue;
      }
    }
    i++;
  }
  if (segStart < text.length) {
    out.push(makeSeg(nodeIndex, text, segStart, text.length, segIsDialogue));
  }
  return out;
}

function makeSeg(nodeIndex: number, text: string, start: number, end: number,
  dialogue: boolean): SpeakSegment {
  const segText = text.substring(start, end);
  const s: SpeakSegment = {
    nodeIndex: nodeIndex,
    charStart: start,
    text: segText,
    isDialogue: dialogue,
    endsSentence: endsWithSentence(segText)
  };
  return s;
}

function endsWithSentence(s: string): boolean {
  for (let i = s.length - 1; i >= 0; i--) {
    const c = s.charAt(i);
    if (c === ' ' || c === '\u201D' || c === '\u2019' || c === '\u300D' || c === '\u300F') {
      continue;
    }
    return c === '。' || c === '！' || c === '？' || c === '…' || c === '!' || c === '?' || c === '.';
  }
  return false;
}

function sentenceEndAt(text: string, i: number): boolean {
  const c = text.charAt(i);
  return c === '。' || c === '！' || c === '？' || c === '\n' || c === '…'
    || c === '.' || c === '!' || c === '?';
}

/** 分段 → 合成块（超长按句末标点装箱，硬上限 800 单位，对齐 PC 版） */
export function splitSegmentsIntoChunks(seg: SpeakSegment): SpeakSegment[] {
  const units = textUnits(seg.text);
  if (units <= CHUNK_MAX_UNITS) {
    return [seg];
  }
  const out: SpeakSegment[] = [];
  let hasSentenceEnd = false;
  for (let i = 0; i < seg.text.length; i++) {
    if (sentenceEndAt(seg.text, i)) {
      hasSentenceEnd = true;
      break;
    }
  }
  if (!hasSentenceEnd) {
    // 无句末标点：按硬上限对半切
    const step = Math.floor(CHUNK_MAX_UNITS / 2);
    for (let s = 0; s < seg.text.length; s += step) {
      out.push(makeSeg(seg.nodeIndex, seg.text, s, Math.min(seg.text.length, s + step), seg.isDialogue));
    }
    return out;
  }
  let chunkStart = 0;
  let acc = 0;
  for (let i = 0; i < seg.text.length; i++) {
    acc += textUnits(seg.text.charAt(i));
    if (sentenceEndAt(seg.text, i)) {
      if (acc >= CHUNK_MAX_UNITS && chunkStart < i) {
        out.push(makeSeg(seg.nodeIndex, seg.text, chunkStart, i + 1, seg.isDialogue));
        chunkStart = i + 1;
        acc = 0;
      }
    }
  }
  if (chunkStart < seg.text.length) {
    out.push(makeSeg(seg.nodeIndex, seg.text, chunkStart, seg.text.length, seg.isDialogue));
  }
  return out;
}

export { hasSpeakableText };
