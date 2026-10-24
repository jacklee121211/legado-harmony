// 等价性验证：alignWords / mergeRanges / scaledPauseMs 的旧实现 vs 新实现
// 用法：node verify_three.js

const MAX_SCALED_PAUSE_MS = 10000;

// ══════════ alignWords ══════════
function oldAlign(text, words) {
  const aligned = [];
  let cursor = 0;
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

function newAlign(text, words) {
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

// ══════════ mergeRanges ══════════
function oldMerge(items) {
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

function newMerge(items) {
  return items.reduce((merged, it) => {
    const n = merged.length;
    if (n === 0) return merged.concat([{ fromSample: it.fromSample, toSample: it.toSample, durationSamples: it.durationSamples }]);
    const prev = merged[n - 1];
    if (it.fromSample > prev.toSample) {
      return merged.concat([{ fromSample: it.fromSample, toSample: it.toSample, durationSamples: it.durationSamples }]);
    }
    const fused = {
      fromSample: prev.fromSample,
      toSample: Math.max(prev.toSample, it.toSample),
      durationSamples: Math.max(prev.durationSamples, it.durationSamples)
    };
    return merged.slice(0, n - 1).concat([fused]);
  }, []);
}

// ══════════ scaledPauseMs ══════════
function oldScaled(configuredMs, rate) {
  if (!Number.isFinite(configuredMs) || configuredMs <= 0) return 0;
  const r = Number.isFinite(rate) && rate > 0 ? rate : 1;
  return Math.min(MAX_SCALED_PAUSE_MS, configuredMs / r);
}

function newScaled(configuredMs, rate) {
  const saneMs = Number.isFinite(configuredMs) ? configuredMs : 0;
  if (saneMs <= 0) return 0;
  const saneRate = (Number.isFinite(rate) && rate > 0) ? rate : 1;
  const scaled = saneMs / saneRate;
  return scaled > MAX_SCALED_PAUSE_MS ? MAX_SCALED_PAUSE_MS : scaled;
}

// ══════════ 测试 ══════════
let fails = 0;
function eq(name, a, b, extra) {
  const sa = JSON.stringify(a), sb = JSON.stringify(b);
  if (sa !== sb) { fails++; console.log('  ✗ ' + name + (extra ? ' | ' + extra : '')); console.log('    旧: ' + sa); console.log('    新: ' + sb); }
}

console.log('=== alignWords ===');
const alignCases = [
  ['你好世界', [{ text: '你好', startMs: 0, endMs: 100 }, { text: '世界', startMs: 100, endMs: 200 }]],
  ['你好世界', []],
  ['', [{ text: '你好', startMs: 0, endMs: 100 }]],
  ['他说他说', [{ text: '他说', startMs: 0, endMs: 50 }, { text: '他说', startMs: 50, endMs: 100 }]],
  ['一百块', [{ text: '100', startMs: 0, endMs: 50 }, { text: '块', startMs: 50, endMs: 100 }]],
  ['甲乙丙', [{ text: '', startMs: 0, endMs: 10 }, { text: '甲', startMs: 10, endMs: 20 }, { text: '', startMs: 20, endMs: 30 }]],
  ['abcabc', [{ text: 'abc', startMs: 0, endMs: 10 }, { text: 'abc', startMs: 10, endMs: 20 }]],
  ['重复重复重复', [{ text: '重复', startMs: 0, endMs: 10 }, { text: '重复', startMs: 10, endMs: 20 }, { text: '重复', startMs: 20, endMs: 30 }]],
  ['前中后', [{ text: '不存在', startMs: 0, endMs: 10 }, { text: '中', startMs: 10, endMs: 20 }, { text: '后', startMs: 20, endMs: 30 }]],
];
for (const [t, w] of alignCases) eq('alignWords', oldAlign(t, w), newAlign(t, w), JSON.stringify(t));

// 模糊
const wordsPool = ['你', '好', '他', '说', '世', '界', 'abc', '100', '', '重复', '中'];
let alignFuzz = 0;
for (let t = 0; t < 20000; t++) {
  let txt = '';
  const tl = Math.floor(Math.random() * 12);
  for (let k = 0; k < tl; k++) txt += ['你','好','他','说','世','界','a','b','c','1','0','重','复','中'][Math.floor(Math.random()*14)];
  const wn = Math.floor(Math.random() * 6);
  const ws = [];
  let ms = 0;
  for (let k = 0; k < wn; k++) {
    const w = wordsPool[Math.floor(Math.random() * wordsPool.length)];
    const dur = Math.floor(Math.random() * 50);
    ws.push({ text: w, startMs: ms, endMs: ms + dur });
    ms += dur;
  }
  if (JSON.stringify(oldAlign(txt, ws)) !== JSON.stringify(newAlign(txt, ws))) { alignFuzz++; if (alignFuzz < 4) console.log('  ✗ fuzz align: ' + JSON.stringify(txt) + ' words=' + JSON.stringify(ws)); }
}
console.log('  定向: ' + alignCases.length + ' 条 | 模糊 20000 轮失败: ' + alignFuzz);
fails += alignFuzz;

console.log('=== mergeRanges ===');
const mergeCases = [
  [],
  [{ fromSample: 0, toSample: 10, durationSamples: 5 }],
  [{ fromSample: 0, toSample: 10, durationSamples: 5 }, { fromSample: 20, toSample: 30, durationSamples: 5 }],
  [{ fromSample: 0, toSample: 10, durationSamples: 5 }, { fromSample: 10, toSample: 20, durationSamples: 7 }],
  [{ fromSample: 0, toSample: 10, durationSamples: 5 }, { fromSample: 5, toSample: 25, durationSamples: 3 }],
  [{ fromSample: 0, toSample: 30, durationSamples: 9 }, { fromSample: 5, toSample: 10, durationSamples: 2 }, { fromSample: 12, toSample: 15, durationSamples: 4 }],
  [{ fromSample: 0, toSample: 5, durationSamples: 1 }, { fromSample: 5, toSample: 5, durationSamples: 1 }],
];
for (const c of mergeCases) eq('mergeRanges', oldMerge(c.map(x=>({...x}))), newMerge(c.map(x=>({...x}))), JSON.stringify(c));

let mergeFuzz = 0;
for (let t = 0; t < 20000; t++) {
  const n = Math.floor(Math.random() * 7);
  const items = [];
  for (let k = 0; k < n; k++) {
    const from = Math.floor(Math.random() * 50);
    const to = from + Math.floor(Math.random() * 20);
    items.push({ fromSample: from, toSample: to, durationSamples: Math.floor(Math.random() * 15) });
  }
  // 旧实现会原地改入参 ⇒ 各自用深拷贝
  const a = oldMerge(items.map(x => ({ ...x })));
  const b = newMerge(items.map(x => ({ ...x })));
  if (JSON.stringify(a) !== JSON.stringify(b)) { mergeFuzz++; if (mergeFuzz < 4) console.log('  ✗ fuzz merge: ' + JSON.stringify(items)); }
}
console.log('  定向: ' + mergeCases.length + ' 条 | 模糊 20000 轮失败: ' + mergeFuzz);
fails += mergeFuzz;

console.log('=== scaledPauseMs ===');
const scaledCases = [
  [500, 1], [500, 2], [500, 0.5], [500, 0], [500, -1], [0, 1], [-5, 1],
  [Infinity, 1], [NaN, 1], [500, Infinity], [500, NaN], [20000, 1], [20000, 0.1],
  [10000, 1], [10001, 1], [1e9, 0.01],
];
for (const [ms, r] of scaledCases) eq('scaledPauseMs', oldScaled(ms, r), newScaled(ms, r), `ms=${ms} rate=${r}`);
console.log('  定向: ' + scaledCases.length + ' 条');

console.log('');
console.log(fails === 0 ? '✅ 三个函数全部等价' : '❌ 共 ' + fails + ' 处差异');
