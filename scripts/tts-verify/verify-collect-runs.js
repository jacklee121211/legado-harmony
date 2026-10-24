// 等价性验证：旧逐字符状态机 vs 新正则实现
// 用法：node verify_collect.js

const SENTENCE_PUNCT_RE = /[。！？…]/u;
const COMMA_PUNCT_RE = /[，；：、]/u;
const CLOSING_QUOTE_RE = /[」』”’"']/u;

function codePointAt(text, index) {
  const cp = text.codePointAt(index);
  return cp === undefined ? '' : String.fromCodePoint(cp);
}

// ── 旧实现（原样照抄，用于对照）──
function oldCollect(text) {
  const runs = [];
  let i = 0;
  while (i < text.length) {
    const ch = codePointAt(text, i);
    if (!ch) break;
    if (!SENTENCE_PUNCT_RE.test(ch) && !COMMA_PUNCT_RE.test(ch)) {
      i += ch.length;
      continue;
    }
    let j = i;
    let sawSentence = false;
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

// ── 新实现（与 PauseSplicer.ets 中一致）──
function newCollect(text) {
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

// ── 用例集 ──
const cases = [
  '',
  '你好',
  '你好。',
  '你好，世界。',
  '甲。乙，丙；丁：戊、己！',
  '「好的。」他说。',
  '「真的吗？」她问：「那就走吧。」',
  '……',
  '……，',
  '等等……，然后呢？',
  'A。"B"',
  "他说：'走吧。'",
  '句末省略号……后面还有。',
  '多引号」』”’"\'堆叠。',
  'no punctuation at all here',
  '标点在前，。！？…；：、混合',
  '换行\n也算吗？\n',
  '😀表情后面。',
  '𠀀生僻字后面，测试代理对。',
  '。',
  '，',
  '」。',
  '「引号开头」。',
  '结尾是引号」',
  'a。b。c。d。e。',
  '逗号,和英文句点.不参与',
  '！？…，；：、」』”’"\'',
  '　　全角空格　　。',
  '……' + '。'.repeat(50),
];

let pass = 0, fail = 0;
const failures = [];

for (const c of cases) {
  const a = JSON.stringify(oldCollect(c));
  const b = JSON.stringify(newCollect(c));
  if (a === b) { pass++; }
  else { fail++; failures.push({ input: c, old: a, neu: b }); }
}

// ── 随机模糊测试 ──
const alphabet = ['你', '好', '。', '！', '？', '…', '，', '；', '：', '、',
                  '」', '』', '”', '’', '"', "'", ' ', '\n', 'a', '1', '😀'];
let fuzzFail = 0;
const fuzzFailures = [];
for (let t = 0; t < 20000; t++) {
  const len = Math.floor(Math.random() * 24);
  let s = '';
  for (let k = 0; k < len; k++) s += alphabet[Math.floor(Math.random() * alphabet.length)];
  const a = JSON.stringify(oldCollect(s));
  const b = JSON.stringify(newCollect(s));
  if (a !== b) { fuzzFail++; if (fuzzFailures.length < 5) fuzzFailures.push({ input: s, old: a, neu: b }); }
}

console.log('=== 定向用例 ===');
console.log('  通过: ' + pass + ' / 失败: ' + fail);
if (failures.length) failures.forEach(f => {
  console.log('  ✗ 输入: ' + JSON.stringify(f.input));
  console.log('    旧: ' + f.old);
  console.log('    新: ' + f.neu);
});
console.log('=== 随机模糊测试 20000 轮 ===');
console.log('  失败: ' + fuzzFail);
if (fuzzFailures.length) fuzzFailures.forEach(f => {
  console.log('  ✗ 输入: ' + JSON.stringify(f.input));
  console.log('    旧: ' + f.old);
  console.log('    新: ' + f.neu);
});
console.log('');
console.log(fail === 0 && fuzzFail === 0 ? '✅ 全部等价' : '❌ 存在差异');

// 抽样展示语义
console.log('');
console.log('=== 语义抽样 ===');
for (const s of ['「真的吗？」她问：「那就走吧。」', '等等……，然后呢？', '「好的。」他说。']) {
  console.log('  输入: ' + JSON.stringify(s));
  console.log('  结果: ' + JSON.stringify(newCollect(s)));
}
