// 端到端等价性验证：旧版 PauseSplicer 与新版整条管线逐字节比对
// 把两个 .ets 的关键纯算法函数抽出来（去类型标注），跑同一批输入比 PCM 输出。
// 用法：node verify_pipeline.js

const fs = require('fs');

// ══════════════════════════════════════════════════════════════
// 旧版（HEAD，改动前）—— 逐字照抄算法，仅去 ArkTS 类型标注
// ══════════════════════════════════════════════════════════════
const OLD = (() => {
  const SENTENCE_PUNCT_RE = /[。！？…]/u;
  const COMMA_PUNCT_RE = /[，；：、]/u;
  const CLOSING_QUOTE_RE = /[」』”’"']/u;
  const MAX_SCALED_PAUSE_MS = 10000;
  const FADE_SEC = 0.002;
  const END_OF_AUDIO_MS = 1e9;
  const EDGE_FADE_ENABLED = true;
  const EDGE_FADE_SEC = 0.008;

  function codePointAt(text, index) {
    const cp = text.codePointAt(index);
    return cp === undefined ? '' : String.fromCodePoint(cp);
  }
  function collectPauseRuns(text) {
    const runs = [];
    let i = 0;
    while (i < text.length) {
      const ch = codePointAt(text, i);
      if (!ch) break;
      if (!SENTENCE_PUNCT_RE.test(ch) && !COMMA_PUNCT_RE.test(ch)) { i += ch.length; continue; }
      let j = i, sawSentence = false;
      while (j < text.length) {
        const c = codePointAt(text, j);
        if (!c) break;
        if (SENTENCE_PUNCT_RE.test(c)) { sawSentence = true; j += c.length; }
        else if (COMMA_PUNCT_RE.test(c)) { j += c.length; }
        else if (CLOSING_QUOTE_RE.test(c)) { j += c.length; }
        else { break; }
      }
      runs.push({ start: i, end: j, isSentence: sawSentence });
      i = j;
    }
    return runs;
  }
  function alignWords(text, words) {
    const aligned = []; let cursor = 0;
    for (let i = 0; i < words.length; i++) {
      const w = words[i];
      if (!w.text) continue;
      const idx = text.indexOf(w.text, cursor);
      if (idx < 0) continue;
      aligned.push({ startMs: w.startMs, endMs: w.endMs, charStart: idx, charEnd: idx + w.text.length });
      cursor = idx + w.text.length;
    }
    return aligned;
  }
  function interpolateMs(w, textIndex) {
    const len = w.charEnd - w.charStart;
    if (len <= 0) return w.startMs;
    const t = Math.min(1, Math.max(0, (textIndex - w.charStart) / len));
    return w.startMs + t * (w.endMs - w.startMs);
  }
  function computePausePoints(text, words) {
    const runs = collectPauseRuns(text);
    if (runs.length === 0 || words.length === 0) return [];
    const aligned = alignWords(text, words);
    if (aligned.length === 0) return [];
    const out = [];
    for (let r = 0; r < runs.length; r++) {
      const run = runs[r];
      let prev = null, next = null;
      for (let i = 0; i < aligned.length; i++) {
        const w = aligned[i];
        if (w.charStart < run.start) prev = w;
        if (next === null && w.charStart >= run.end) { next = w; break; }
      }
      let fromMs;
      if (prev !== null && prev.charEnd > run.start) fromMs = interpolateMs(prev, run.start);
      else if (prev !== null) fromMs = prev.endMs;
      else if (next !== null) fromMs = next.startMs;
      else fromMs = 0;
      let toMs, overlappingAfter = null;
      for (let i = 0; i < aligned.length; i++) {
        const w = aligned[i];
        if (w.charStart < run.end && w.charEnd > run.end) { overlappingAfter = w; break; }
      }
      if (overlappingAfter !== null) toMs = interpolateMs(overlappingAfter, run.end);
      else if (next !== null) toMs = next.startMs;
      else toMs = END_OF_AUDIO_MS;
      if (!Number.isFinite(fromMs) || !Number.isFinite(toMs)) continue;
      out.push({ fromMs, toMs: Math.max(fromMs, toMs), kind: run.isSentence ? 'sentence' : 'comma' });
    }
    return out;
  }
  function mergeRanges(items) {
    const merged = [];
    for (let i = 0; i < items.length; i++) {
      const it = items[i];
      const last = merged.length > 0 ? merged[merged.length - 1] : null;
      if (last !== null && it.fromSample <= last.toSample) {
        last.toSample = Math.max(last.toSample, it.toSample);
        last.durationSamples = Math.max(last.durationSamples, it.durationSamples);
      } else {
        merged.push({ fromSample: it.fromSample, toSample: it.toSample, durationSamples: it.durationSamples });
      }
    }
    return merged;
  }
  function scaledPauseMs(configuredMs, rate) {
    if (!Number.isFinite(configuredMs) || configuredMs <= 0) return 0;
    const r = Number.isFinite(rate) && rate > 0 ? rate : 1;
    return Math.min(MAX_SCALED_PAUSE_MS, configuredMs / r);
  }
  function applyEdgeFade(pcm, sampleRate) {
    if (!EDGE_FADE_ENABLED) return;
    const len = pcm.length;
    if (len <= 1) return;
    const n = Math.max(1, Math.round(EDGE_FADE_SEC * sampleRate));
    if (len < n * 2) {
      for (let k = 0; k < len; k++) {
        const pos = len === 1 ? 1 : k / (len - 1);
        pcm[k] = Math.round(pcm[k] * pos);
      }
      return;
    }
    for (let k = 0; k < n; k++) {
      const t = k / n;
      const g = 0.5 - 0.5 * Math.cos(Math.PI * t);
      pcm[k] = Math.round(pcm[k] * g);
    }
    for (let k = 0; k < n; k++) {
      const i = len - 1 - k;
      const t = k / n;
      const g = 0.5 - 0.5 * Math.cos(Math.PI * t);
      pcm[i] = Math.round(pcm[i] * g);
    }
  }
  function applyVolume(pcm, vol) {
    for (let i = 0; i < pcm.length; i++) pcm[i] = Math.round(pcm[i] * vol);
  }
  function copySegment(dst, dstPos, src, srcPos, len, fadeIn, fadeOut, fade, vol) {
    if (len <= 0) return;
    const n = Math.min(fade, len);
    for (let k = 0; k < len; k++) {
      let g = vol;
      if (fadeIn && k < n) g *= k / n;
      if (fadeOut && k >= len - n) g *= (len - 1 - k) / n;
      dst[dstPos + k] = Math.round(src[srcPos + k] * g);
    }
  }
  function applyPauses(pcm, sampleRate, points, sentenceMs, commaMs, rate, volume) {
    const srcLen = pcm.length;
    const vol = Math.max(0, Math.min(1, volume));
    const timeMap = [{ origMs: 0, adjMs: 0 }];
    if (srcLen <= 0 || sampleRate <= 0) return { pcm, sampleRate, timeMap };
    const items = [];
    for (let i = 0; i < points.length; i++) {
      const p = points[i];
      const durationMs = scaledPauseMs(p.kind === 'sentence' ? sentenceMs : commaMs, rate);
      const fromSample = Math.max(0, Math.min(srcLen, Math.round(p.fromMs / 1000 * sampleRate)));
      const toSample = Math.max(fromSample, Math.min(srcLen, Math.round(p.toMs / 1000 * sampleRate)));
      const durationSamples = Math.round(durationMs / 1000 * sampleRate);
      if (durationSamples > 0) items.push({ fromSample, toSample, durationSamples });
    }
    if (items.length === 0) {
      if (vol < 1) applyVolume(pcm, vol);
      applyEdgeFade(pcm, sampleRate);
      return { pcm, sampleRate, timeMap };
    }
    items.sort((a, b) => a.fromSample - b.fromSample);
    const merged = mergeRanges(items);
    let newLen = srcLen;
    for (let i = 0; i < merged.length; i++) newLen += merged[i].durationSamples - (merged[i].toSample - merged[i].fromSample);
    if (newLen <= 0) { applyEdgeFade(pcm, sampleRate); return { pcm, sampleRate, timeMap }; }
    const fade = Math.max(1, Math.round(FADE_SEC * sampleRate));
    const out = new Int16Array(newLen);
    let srcPos = 0, dstPos = 0, shiftSamples = 0;
    for (let i = 0; i < merged.length; i++) {
      const from = merged[i].fromSample, to = merged[i].toSample;
      const speechLen = from - srcPos;
      copySegment(out, dstPos, pcm, srcPos, speechLen, dstPos > 0, true, fade, vol);
      dstPos += speechLen;
      dstPos += merged[i].durationSamples;
      shiftSamples += merged[i].durationSamples - (to - from);
      timeMap.push({ origMs: to * 1000 / sampleRate, adjMs: (to + shiftSamples) * 1000 / sampleRate });
      srcPos = to;
    }
    const tailLen = srcLen - srcPos;
    copySegment(out, dstPos, pcm, srcPos, tailLen, dstPos > 0, false, fade, vol);
    applyEdgeFade(out, sampleRate);
    return { pcm: out, sampleRate, timeMap };
  }
  function lookupAdjMs(timeMap, origMs) {
    let base = timeMap[0];
    for (let i = 1; i < timeMap.length; i++) {
      const e = timeMap[i];
      if (e.origMs <= origMs) base = e; else break;
    }
    return base.adjMs + (origMs - base.origMs);
  }
  function lookupOrigMs(timeMap, adjMs) {
    let base = timeMap[0];
    for (let i = 1; i < timeMap.length; i++) {
      const e = timeMap[i];
      if (e.adjMs <= adjMs) base = e; else break;
    }
    return base.origMs + (adjMs - base.adjMs);
  }
  function countSpeakable(text, from, to) {
    let n = 0;
    const end = Math.min(to, text.length);
    for (let i = from; i < end; i++) {
      const c = text.charAt(i);
      if (!SENTENCE_PUNCT_RE.test(c) && !COMMA_PUNCT_RE.test(c) && !CLOSING_QUOTE_RE.test(c) && !/\s/.test(c)) n++;
    }
    return n;
  }
  function sentenceEndAt(text, i) {
    const c = text.charAt(i);
    return c === '。' || c === '！' || c === '？' || c === '…' || c === '!' || c === '?' || c === '\n';
  }
  function pushSentenceMark(marks, text, start, end, aligned, timeMap, est = false, totalSpeakable = 0, totalMs = 0) {
    const segText = text.substring(start, end);
    let hasSpeakable = false;
    for (let i = 0; i < segText.length; i++) {
      const c = segText.charAt(i);
      if (!SENTENCE_PUNCT_RE.test(c) && !COMMA_PUNCT_RE.test(c) && !CLOSING_QUOTE_RE.test(c) && !/\s/.test(c)) { hasSpeakable = true; break; }
    }
    if (!hasSpeakable) return;
    let origMs = -1;
    for (let i = 0; i < aligned.length; i++) {
      const w = aligned[i];
      if (w.charEnd > start) { origMs = interpolateMs(w, start); break; }
    }
    if (origMs < 0) {
      if (est && totalSpeakable > 0) origMs = totalMs * Math.min(1, countSpeakable(text, 0, start) / totalSpeakable);
      else origMs = aligned.length > 0 ? aligned[aligned.length - 1].endMs : 0;
    }
    marks.push({ text: segText.trim(), startAdjMs: lookupAdjMs(timeMap, origMs), charStart: start });
  }
  function buildTimeline(text, words, timeMap, splitOnClause, totalMs = 0) {
    const marks = [];
    const aligned = alignWords(text, words);
    if (text.length === 0) return marks;
    const est = aligned.length === 0 && totalMs > 0;
    const totalSpeakable = est ? countSpeakable(text, 0, text.length) : 0;
    let start = 0;
    for (let i = 0; i <= text.length; i++) {
      const isEnd = i >= text.length;
      const boundary = !isEnd && (sentenceEndAt(text, i) || (splitOnClause && COMMA_PUNCT_RE.test(text.charAt(i))));
      if (boundary) {
        let j = i + 1;
        while (j < text.length && CLOSING_QUOTE_RE.test(text.charAt(j))) j++;
        pushSentenceMark(marks, text, start, j, aligned, timeMap, est, totalSpeakable, totalMs);
        start = j; i = j - 1;
      }
    }
    if (start < text.length) pushSentenceMark(marks, text, start, text.length, aligned, timeMap, est, totalSpeakable, totalMs);
    return marks;
  }
  return { collectPauseRuns, alignWords, computePausePoints, mergeRanges, scaledPauseMs,
           applyEdgeFade, applyPauses, lookupAdjMs, lookupOrigMs, countSpeakable,
           buildTimeline,
           buildSentenceTimeline: (t, w, tm, ms = 0) => buildTimeline(t, w, tm, false, ms),
           buildLyricTimeline: (t, w, tm, ms = 0) => buildTimeline(t, w, tm, true, ms) };
})();

// ══════════════════════════════════════════════════════════════
// 新版（当前文件）—— 手工同步，保持与 PauseSplicer.ets 一致
// ══════════════════════════════════════════════════════════════
const NEW = (() => {
  const SENTENCE_END_MARKS = /[。！？…]/u;
  const CLAUSE_BREAK_MARKS = /[，；：、]/u;
  const TRAILING_QUOTE_MARKS = /[」』”’"']/u;
  const PAUSE_DURATION_CAP_MS = 10000;
  const INNER_FADE_SEC = 0.002;
  const PAST_END_SENTINEL_MS = 1e9;
  const EDGE_FADE_ENABLED = true;
  const EDGE_FADE_SEC = 0.008;

  function collectPauseRuns(text) {
    const runs = [];
    if (text.length === 0) return runs;
    const clusterRe = /[。！？…，；：、][。！？…，；：、」』”’"']*/gu;
    const sentenceRe = /[。！？…]/u;
    let hit = clusterRe.exec(text);
    while (hit !== null) {
      const cluster = hit[0];
      const start = hit.index;
      runs.push({ start, end: start + cluster.length, isSentence: sentenceRe.test(cluster) });
      hit = clusterRe.exec(text);
    }
    return runs;
  }
  function alignWords(text, words) {
    const seed = { aligned: [], cursor: 0 };
    const fin = words.reduce((acc, w) => {
      if (w.text.length === 0) return acc;
      const at = text.indexOf(w.text, acc.cursor);
      if (at < 0) return acc;
      const next = { startMs: w.startMs, endMs: w.endMs, charStart: at, charEnd: at + w.text.length };
      return { aligned: acc.aligned.concat([next]), cursor: at + w.text.length };
    }, seed);
    return fin.aligned;
  }
  function interpolateMs(w, textIndex) {
    const len = w.charEnd - w.charStart;
    if (len <= 0) return w.startMs;
    const t = Math.min(1, Math.max(0, (textIndex - w.charStart) / len));
    return w.startMs + t * (w.endMs - w.startMs);
  }
  function computePausePoints(text, words) {
    const runs = collectPauseRuns(text);
    if (runs.length === 0 || words.length === 0) return [];
    const aligned = alignWords(text, words);
    if (aligned.length === 0) return [];
    const out = [];
    for (let r = 0; r < runs.length; r++) {
      const run = runs[r];
      let prev = null, next = null;
      for (let i = 0; i < aligned.length; i++) {
        const w = aligned[i];
        if (w.charStart < run.start) prev = w;
        if (next === null && w.charStart >= run.end) { next = w; break; }
      }
      let fromMs;
      if (prev !== null && prev.charEnd > run.start) fromMs = interpolateMs(prev, run.start);
      else if (prev !== null) fromMs = prev.endMs;
      else if (next !== null) fromMs = next.startMs;
      else fromMs = 0;
      let toMs, overlappingAfter = null;
      for (let i = 0; i < aligned.length; i++) {
        const w = aligned[i];
        if (w.charStart < run.end && w.charEnd > run.end) { overlappingAfter = w; break; }
      }
      if (overlappingAfter !== null) toMs = interpolateMs(overlappingAfter, run.end);
      else if (next !== null) toMs = next.startMs;
      else toMs = PAST_END_SENTINEL_MS;
      if (!Number.isFinite(fromMs) || !Number.isFinite(toMs)) continue;
      out.push({ fromMs, toMs: Math.max(fromMs, toMs), kind: run.isSentence ? 'sentence' : 'comma' });
    }
    return out;
  }
  function mergeRanges(items) {
    return items.reduce((merged, it) => {
      const n = merged.length;
      if (n === 0) return merged.concat([{ gapStartSample: it.gapStartSample, gapEndSample: it.gapEndSample, silenceLenSamples: it.silenceLenSamples }]);
      const prev = merged[n - 1];
      if (it.gapStartSample > prev.gapEndSample) return merged.concat([{ gapStartSample: it.gapStartSample, gapEndSample: it.gapEndSample, silenceLenSamples: it.silenceLenSamples }]);
      const fused = { gapStartSample: prev.gapStartSample, gapEndSample: Math.max(prev.gapEndSample, it.gapEndSample), silenceLenSamples: Math.max(prev.silenceLenSamples, it.silenceLenSamples) };
      return merged.slice(0, n - 1).concat([fused]);
    }, []);
  }
  function scaledPauseMs(configuredMs, rate) {
    const saneMs = Number.isFinite(configuredMs) ? configuredMs : 0;
    if (saneMs <= 0) return 0;
    const saneRate = (Number.isFinite(rate) && rate > 0) ? rate : 1;
    const scaled = saneMs / saneRate;
    return scaled > PAUSE_DURATION_CAP_MS ? PAUSE_DURATION_CAP_MS : scaled;
  }
  function applyEdgeFade(pcm, sampleRate) {
    if (!EDGE_FADE_ENABLED) return;
    const len = pcm.length;
    if (len <= 1) return;
    const n = Math.max(1, Math.round(EDGE_FADE_SEC * sampleRate));
    if (len < n * 2) {
      for (let k = 0; k < len; k++) {
        const pos = len === 1 ? 1 : k / (len - 1);
        pcm[k] = Math.round(pcm[k] * pos);
      }
      return;
    }
    for (let k = 0; k < n; k++) {
      const t = k / n;
      const g = 0.5 - 0.5 * Math.cos(Math.PI * t);
      pcm[k] = Math.round(pcm[k] * g);
    }
    for (let k = 0; k < n; k++) {
      const i = len - 1 - k;
      const t = k / n;
      const g = 0.5 - 0.5 * Math.cos(Math.PI * t);
      pcm[i] = Math.round(pcm[i] * g);
    }
  }
  function applyVolume(pcm, vol) {
    for (let i = 0; i < pcm.length; i++) pcm[i] = Math.round(pcm[i] * vol);
  }
  function copySegment(dst, dstPos, src, srcPos, len, fadeIn, fadeOut, fade, vol) {
    if (len <= 0) return;
    const n = Math.min(fade, len);
    for (let k = 0; k < len; k++) {
      let g = vol;
      if (fadeIn && k < n) g *= k / n;
      if (fadeOut && k >= len - n) g *= (len - 1 - k) / n;
      dst[dstPos + k] = Math.round(src[srcPos + k] * g);
    }
  }
  function applyPauses(pcm, sampleRate, points, sentenceMs, commaMs, rate, volume) {
    const srcLen = pcm.length;
    const vol = Math.max(0, Math.min(1, volume));
    const timeMap = [{ origMs: 0, adjMs: 0 }];
    if (srcLen <= 0 || sampleRate <= 0) return { pcm, sampleRate, timeMap };
    const items = [];
    for (let i = 0; i < points.length; i++) {
      const p = points[i];
      const durationMs = scaledPauseMs(p.kind === 'sentence' ? sentenceMs : commaMs, rate);
      const gapStartSample = Math.max(0, Math.min(srcLen, Math.round(p.fromMs / 1000 * sampleRate)));
      const gapEndSample = Math.max(gapStartSample, Math.min(srcLen, Math.round(p.toMs / 1000 * sampleRate)));
      const silenceLenSamples = Math.round(durationMs / 1000 * sampleRate);
      if (silenceLenSamples > 0) items.push({ gapStartSample, gapEndSample, silenceLenSamples });
    }
    if (items.length === 0) {
      if (vol < 1) applyVolume(pcm, vol);
      applyEdgeFade(pcm, sampleRate);
      return { pcm, sampleRate, timeMap };
    }
    items.sort((a, b) => a.gapStartSample - b.gapStartSample);
    const merged = mergeRanges(items);
    let newLen = srcLen;
    for (let i = 0; i < merged.length; i++) newLen += merged[i].silenceLenSamples - (merged[i].gapEndSample - merged[i].gapStartSample);
    if (newLen <= 0) { applyEdgeFade(pcm, sampleRate); return { pcm, sampleRate, timeMap }; }
    const fade = Math.max(1, Math.round(INNER_FADE_SEC * sampleRate));
    const out = new Int16Array(newLen);
    let srcPos = 0, dstPos = 0, shiftSamples = 0;
    for (let i = 0; i < merged.length; i++) {
      const from = merged[i].gapStartSample, to = merged[i].gapEndSample;
      const speechLen = from - srcPos;
      copySegment(out, dstPos, pcm, srcPos, speechLen, dstPos > 0, true, fade, vol);
      dstPos += speechLen;
      dstPos += merged[i].silenceLenSamples;
      shiftSamples += merged[i].silenceLenSamples - (to - from);
      timeMap.push({ origMs: to * 1000 / sampleRate, adjMs: (to + shiftSamples) * 1000 / sampleRate });
      srcPos = to;
    }
    const tailLen = srcLen - srcPos;
    copySegment(out, dstPos, pcm, srcPos, tailLen, dstPos > 0, false, fade, vol);
    applyEdgeFade(out, sampleRate);
    return { pcm: out, sampleRate, timeMap };
  }
  function lookupAdjMs(timeMap, origMs) {
    let base = timeMap[0];
    for (let i = 1; i < timeMap.length; i++) {
      const e = timeMap[i];
      if (e.origMs <= origMs) base = e; else break;
    }
    return base.adjMs + (origMs - base.origMs);
  }
  function lookupOrigMs(timeMap, adjMs) {
    let base = timeMap[0];
    for (let i = 1; i < timeMap.length; i++) {
      const e = timeMap[i];
      if (e.adjMs <= adjMs) base = e; else break;
    }
    return base.origMs + (adjMs - base.adjMs);
  }
  function countSpeakable(text, from, to) {
    let n = 0;
    const end = Math.min(to, text.length);
    for (let i = from; i < end; i++) {
      const c = text.charAt(i);
      if (!SENTENCE_END_MARKS.test(c) && !CLAUSE_BREAK_MARKS.test(c) && !TRAILING_QUOTE_MARKS.test(c) && !/\s/.test(c)) n++;
    }
    return n;
  }
  function sentenceEndAt(text, i) {
    const c = text.charAt(i);
    return c === '。' || c === '！' || c === '？' || c === '…' || c === '!' || c === '?' || c === '\n';
  }
  function pushSentenceMark(marks, text, start, end, aligned, timeMap, est = false, totalSpeakable = 0, totalMs = 0) {
    const segText = text.substring(start, end);
    let hasSpeakable = false;
    for (let i = 0; i < segText.length; i++) {
      const c = segText.charAt(i);
      if (!SENTENCE_END_MARKS.test(c) && !CLAUSE_BREAK_MARKS.test(c) && !TRAILING_QUOTE_MARKS.test(c) && !/\s/.test(c)) { hasSpeakable = true; break; }
    }
    if (!hasSpeakable) return;
    let origMs = -1;
    for (let i = 0; i < aligned.length; i++) {
      const w = aligned[i];
      if (w.charEnd > start) { origMs = interpolateMs(w, start); break; }
    }
    if (origMs < 0) {
      if (est && totalSpeakable > 0) origMs = totalMs * Math.min(1, countSpeakable(text, 0, start) / totalSpeakable);
      else origMs = aligned.length > 0 ? aligned[aligned.length - 1].endMs : 0;
    }
    marks.push({ text: segText.trim(), startAdjMs: lookupAdjMs(timeMap, origMs), charStart: start });
  }
  function buildTimeline(text, words, timeMap, splitOnClause, totalMs = 0) {
    const marks = [];
    const aligned = alignWords(text, words);
    if (text.length === 0) return marks;
    const est = aligned.length === 0 && totalMs > 0;
    const totalSpeakable = est ? countSpeakable(text, 0, text.length) : 0;
    let start = 0;
    for (let i = 0; i <= text.length; i++) {
      const isEnd = i >= text.length;
      const boundary = !isEnd && (sentenceEndAt(text, i) || (splitOnClause && CLAUSE_BREAK_MARKS.test(text.charAt(i))));
      if (boundary) {
        let j = i + 1;
        while (j < text.length && TRAILING_QUOTE_MARKS.test(text.charAt(j))) j++;
        pushSentenceMark(marks, text, start, j, aligned, timeMap, est, totalSpeakable, totalMs);
        start = j; i = j - 1;
      }
    }
    if (start < text.length) pushSentenceMark(marks, text, start, text.length, aligned, timeMap, est, totalSpeakable, totalMs);
    return marks;
  }
  return { collectPauseRuns, alignWords, computePausePoints, mergeRanges, scaledPauseMs,
           applyEdgeFade, applyPauses, lookupAdjMs, lookupOrigMs, countSpeakable,
           buildTimeline,
           buildSentenceTimeline: (t, w, tm, ms = 0) => buildTimeline(t, w, tm, false, ms),
           buildLyricTimeline: (t, w, tm, ms = 0) => buildTimeline(t, w, tm, true, ms) };
})();

// ══════════════════════════════════════════════════════════════
// 比对
// ══════════════════════════════════════════════════════════════
let fails = 0, checks = 0;
function cmp(label, a, b, ctx) {
  checks++;
  const sa = JSON.stringify(a), sb = JSON.stringify(b);
  if (sa !== sb) {
    fails++;
    if (fails <= 5) {
      console.log('  ✗ ' + label + (ctx ? ' | ' + ctx : ''));
      console.log('    旧: ' + (sa.length > 300 ? sa.slice(0, 300) + '…' : sa));
      console.log('    新: ' + (sb.length > 300 ? sb.slice(0, 300) + '…' : sb));
    }
  }
}

// 造一个确定性的伪随机 PCM（含静音段、满幅段、突变沿）
function makePcm(n, seed) {
  const a = new Int16Array(n);
  let s = seed >>> 0;
  for (let i = 0; i < n; i++) {
    s = (s * 1664525 + 1013904223) >>> 0;
    // 每 2000 样本一个"语音段"，其余为 0（模拟真实 TTS 的自然间隙）
    const inSpeech = (Math.floor(i / 2000) % 2) === 0;
    a[i] = inSpeech ? ((s % 20000) - 10000) : 0;
  }
  return a;
}

const texts = [
  '你好，世界。',
  '「真的吗？」她问：「那就走吧。」',
  '等等……，然后呢？',
  '一句话没有任何标点',
  '',
  '。',
  '甲。乙，丙；丁：戊、己！庚？辛…',
  '长句测试，' + '内容'.repeat(30) + '。结束。',
  '😀表情。生僻字𠀀后面，测试代理对。',
  '他说：「好的。」然后走了。',
];

console.log('=== 1) collectPauseRuns ===');
for (const t of texts) cmp('collect', OLD.collectPauseRuns(t), NEW.collectPauseRuns(t), JSON.stringify(t).slice(0, 40));

console.log('=== 2) computePausePoints（含真实 words）===');
for (const t of texts) {
  // 造词级时间戳：按 2 字符切词
  const words = [];
  let ms = 0;
  for (let i = 0; i < t.length; i += 2) {
    const txt = t.substring(i, Math.min(i + 2, t.length));
    if (!txt) break;
    words.push({ text: txt, startMs: ms, endMs: ms + 180 });
    ms += 200;
  }
  cmp('points', OLD.computePausePoints(t, words), NEW.computePausePoints(t, words), JSON.stringify(t).slice(0, 40));
  // 空 words
  cmp('points-empty', OLD.computePausePoints(t, []), NEW.computePausePoints(t, []), JSON.stringify(t).slice(0, 30));
}

console.log('=== 3) applyPauses 整条拼接（PCM 逐字节）===');
const configs = [
  { sentenceMs: 600, commaMs: 250, rate: 1.0, volume: 1.0 },
  { sentenceMs: 600, commaMs: 250, rate: 2.0, volume: 1.0 },
  { sentenceMs: 600, commaMs: 250, rate: 0.5, volume: 0.7 },
  { sentenceMs: 0, commaMs: 0, rate: 1.0, volume: 1.0 },
  { sentenceMs: 600, commaMs: 250, rate: 1.0, volume: 0.0 },
  { sentenceMs: 30000, commaMs: 30000, rate: 0.1, volume: 1.0 },  // 触发上限
];
for (const t of texts) {
  const words = [];
  let ms = 0;
  for (let i = 0; i < t.length; i += 2) {
    const txt = t.substring(i, Math.min(i + 2, t.length));
    if (!txt) break;
    words.push({ text: txt, startMs: ms, endMs: ms + 180 });
    ms += 200;
  }
  const points = OLD.computePausePoints(t, words);
  for (const cfg of configs) {
    const src1 = makePcm(24000, 42);
    const src2 = makePcm(24000, 42);
    const r1 = OLD.applyPauses(src1, 24000, points.map(p => ({ ...p })), cfg.sentenceMs, cfg.commaMs, cfg.rate, cfg.volume);
    const r2 = NEW.applyPauses(src2, 24000, points.map(p => ({ ...p })), cfg.sentenceMs, cfg.commaMs, cfg.rate, cfg.volume);
    cmp('applyPauses.pcm', Array.from(r1.pcm), Array.from(r2.pcm), `text=${JSON.stringify(t).slice(0,20)} cfg=${JSON.stringify(cfg)}`);
    cmp('applyPauses.timeMap', r1.timeMap, r2.timeMap, `text=${JSON.stringify(t).slice(0,20)} cfg=${JSON.stringify(cfg)}`);
    cmp('applyPauses.len', r1.pcm.length, r2.pcm.length, `cfg=${JSON.stringify(cfg)}`);
  }
}

console.log('=== 4) 边界：空 PCM / 零采样率 ===');
cmp('empty-pcm', OLD.applyPauses(new Int16Array(0), 24000, [], 600, 250, 1, 1).pcm.length,
                 NEW.applyPauses(new Int16Array(0), 24000, [], 600, 250, 1, 1).pcm.length);
cmp('zero-rate', OLD.applyPauses(makePcm(100, 1), 0, [], 600, 250, 1, 1).timeMap,
                 NEW.applyPauses(makePcm(100, 1), 0, [], 600, 250, 1, 1).timeMap);

console.log('=== 5) 时间线（句级 / 歌词级）===');
for (const t of texts) {
  for (const totalMs of [0, 5000, 12000]) {
    const words = [];
    let ms = 0;
    for (let i = 0; i < t.length; i += 2) {
      const txt = t.substring(i, Math.min(i + 2, t.length));
      if (!txt) break;
      words.push({ text: txt, startMs: ms, endMs: ms + 180 });
      ms += 200;
    }
    const timeMap = [{ origMs: 0, adjMs: 0 }, { origMs: 1000, adjMs: 1300 }];
    cmp('sentenceTimeline', OLD.buildSentenceTimeline(t, words, timeMap, totalMs),
        NEW.buildSentenceTimeline(t, words, timeMap, totalMs), `t=${JSON.stringify(t).slice(0,20)} ms=${totalMs}`);
    cmp('lyricTimeline', OLD.buildLyricTimeline(t, words, timeMap, totalMs),
        NEW.buildLyricTimeline(t, words, timeMap, totalMs), `t=${JSON.stringify(t).slice(0,20)} ms=${totalMs}`);
    // 无 words + 有总时长（字符占比估算路径）
    cmp('sentenceTimeline-est', OLD.buildSentenceTimeline(t, [], timeMap, totalMs),
        NEW.buildSentenceTimeline(t, [], timeMap, totalMs), `t=${JSON.stringify(t).slice(0,20)} ms=${totalMs}`);
    cmp('lyricTimeline-est', OLD.buildLyricTimeline(t, [], timeMap, totalMs),
        NEW.buildLyricTimeline(t, [], timeMap, totalMs), `t=${JSON.stringify(t).slice(0,20)} ms=${totalMs}`);
  }
}

console.log('=== 6) lookup 往返一致性 ===');
{
  const tm = [{ origMs: 0, adjMs: 0 }, { origMs: 1000, adjMs: 1300 }, { origMs: 2000, adjMs: 2400 }];
  for (const x of [0, 500, 1000, 1500, 2000, 3000, -100]) {
    cmp('lookupAdj', OLD.lookupAdjMs(tm, x), NEW.lookupAdjMs(tm, x), 'x=' + x);
    cmp('lookupOrig', OLD.lookupOrigMs(tm, x), NEW.lookupOrigMs(tm, x), 'x=' + x);
  }
}

console.log('=== 7) 大规模随机模糊（PCM 逐字节）===');
let fuzz = 0;
const alpha = ['你','好','。','！','？','…','，','；','：','、','」','』','”','’','"',"'",' ','a','1'];
for (let t = 0; t < 400; t++) {
  const len = 1 + Math.floor(Math.random() * 40);
  let s = '';
  for (let k = 0; k < len; k++) s += alpha[Math.floor(Math.random() * alpha.length)];
  const words = [];
  let ms = 0;
  for (let i = 0; i < s.length; i += 1 + Math.floor(Math.random() * 3)) {
    const txt = s.substring(i, Math.min(i + 2, s.length));
    if (!txt) break;
    words.push({ text: txt, startMs: ms, endMs: ms + 100 + Math.floor(Math.random() * 150) });
    ms += 120 + Math.floor(Math.random() * 180);
  }
  const p1 = OLD.computePausePoints(s, words);
  const p2 = NEW.computePausePoints(s, words);
  if (JSON.stringify(p1) !== JSON.stringify(p2)) { fuzz++; if (fuzz <= 3) console.log('  ✗ fuzz points: ' + JSON.stringify(s)); }
  const n = 4000 + Math.floor(Math.random() * 8000);
  const a = OLD.applyPauses(makePcm(n, t), 24000, p1.map(x=>({...x})), 600, 250, 1, 0.9);
  const b = NEW.applyPauses(makePcm(n, t), 24000, p2.map(x=>({...x})), 600, 250, 1, 0.9);
  if (a.pcm.length !== b.pcm.length) { fuzz++; if (fuzz <= 3) console.log('  ✗ fuzz pcm len: ' + JSON.stringify(s)); }
  else {
    let diff = 0;
    for (let i = 0; i < a.pcm.length; i++) if (a.pcm[i] !== b.pcm[i]) { diff++; break; }
    if (diff) { fuzz++; if (fuzz <= 3) console.log('  ✗ fuzz pcm bytes: ' + JSON.stringify(s)); }
  }
  if (JSON.stringify(a.timeMap) !== JSON.stringify(b.timeMap)) { fuzz++; if (fuzz <= 3) console.log('  ✗ fuzz timeMap: ' + JSON.stringify(s)); }
}
console.log('  400 轮模糊失败: ' + fuzz);
fails += fuzz;

console.log('');
console.log('────────────────────────────────────');
console.log('总检查点: ' + checks + ' | 失败: ' + fails);
console.log(fails === 0 ? '✅ 新旧实现端到端完全等价（PCM 逐字节一致）' : '❌ 存在 ' + fails + ' 处差异');
