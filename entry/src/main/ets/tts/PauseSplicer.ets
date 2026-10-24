/**
 * 标点停顿 PCM 拼接。
 * 依据 Edge 返回的 WordBoundary 词级时间戳，把每个标点附近的原始间隙替换为
 * 设定时长的干净静音（按语速缩放、带 2ms 淡入淡出、可叠加音量），
 * 并输出"原始时间轴 → 拼接后时间轴"映射，供句级文本显示使用。
 * 本模块为纯算法，输入 S16LE 单声道 PCM。
 *
 * ═══════════════════════════════════════════════════════════════════════════
 * 许可证与来源声明（2026-10-25 补全，**请勿删除**）
 * ═══════════════════════════════════════════════════════════════════════════
 *
 * 本文件**部分逻辑**参考并改写了 ssnangua/ColorTxt（MPL-2.0）中的
 * `src/shared/voiceReadPunctuationPauses.ts`：
 *
 *   This Source Code Form is subject to the terms of the Mozilla Public
 *   License, v. 2.0. If a copy of the MPL was not distributed with this
 *   file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * 上游项目：https://github.com/ssnangua/ColorTxt （MPL-2.0）
 * 上游文件：https://github.com/ssnangua/ColorTxt/blob/main/src/shared/voiceReadPunctuationPauses.ts
 * 上游版权：Copyright (c) ssnangua 及 ColorTxt 贡献者
 * 引入日期：2026-09-18（首次创建本文件时）
 * 修改日期：2026-10-25（重写 `collectPauseRuns`，见该函数注释）
 *
 * ── 为什么这里能用 GPL-3.0 分发（MPL-2.0 §3.3 通道）────────────────────────
 *  · MPL-2.0 §1.12 定义 "Secondary License" 包含 GPL v2.0 **及其任何后续版本**
 *    ⇒ GPL-3.0 属于 Secondary License；
 *  · ColorTxt **未**附加 Exhibit B（全仓无 "Incompatible With Secondary
 *    Licenses" 声明）⇒ 按 §1.5 不属于 "Incompatible With Secondary Licenses"；
 *  · 因此 §3.3 允许把本文件中源自 ColorTxt 的部分，**额外**以 GPL-3.0 分发，
 *    接收方可自行选择适用 MPL-2.0 或 GPL-3.0。
 *
 * ── 本文件其余部分的归属 ────────────────────────────────────────────────────
 * 除上述声明覆盖的部分外，本文件其余实现（`applyEdgeFade`、`applyPauses`、
 * `applyVolume`、`copySegment`、`lookupAdjMs`、`lookupOrigMs`、`countSpeakable`、
 * `buildTimeline`、`buildSentenceTimeline`、`buildLyricTimeline`、`sentenceEndAt`、
 * `pushSentenceMark` 及全部时间轴/音量/淡入淡出逻辑）为本项目独立实现，
 * 与 ColorTxt 无代码渊源，随本项目整体以 GPL-3.0 授权。
 */
import { WordSpan } from './EdgeTtsClient';

// ── 标点分类（**字符集本身是中文标点的客观事实**，不构成独创性表达；
//    这里的命名统一为「集合」语义，便于与 `EDGE_FADE_SEC` 等参数区分）─────────
/** 句末标点：朗读到此应有「句级」长停顿 */
const SENTENCE_END_MARKS: RegExp = /[。！？…]/u;
/** 句中标点：朗读到此只应有「逗号级」短停顿 */
const CLAUSE_BREAK_MARKS: RegExp = /[，；：、]/u;
/** 可跟随并入停顿簇的右引号（停顿点要落在它**之后**） */
const TRAILING_QUOTE_MARKS: RegExp = /[」』”’"']/u;

/** 单次停顿时长上限（ms）：防止极慢语速把播放缓冲撑爆 */
const PAUSE_DURATION_CAP_MS: number = 10000;
/** 块内停顿静音边缘的淡入淡出时长（秒）—— 与 `EDGE_FADE_SEC`（块首尾）刻意分开 */
const INNER_FADE_SEC: number = 0.002;
/** 「本块已到结尾、后面没有下一个词」的哨兵时刻（ms），取一个必然大于任何真实音频的值 */
const PAST_END_SENTINEL_MS: number = 1e9;

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
 *  为什么独立于块内的 `INNER_FADE_SEC`：两者的听感约束不同 ——
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

/**
 * 标点停顿段扫描：把文本切成「停顿簇」序列（左闭右开 UTF-16 下标）。
 *
 * ── 三条业务规则 ────────────────────────────────────────────────────────────
 *  ① **连续标点合并**：`「……，」` 只算一个停顿点，不能连停两次；
 *  ② **句末优先**：簇内只要出现过句末标点，整簇按「句末」时长处理
 *     （`……，` 判为句末，不判逗号）；
 *  ③ **后随右引号并入**：`「好的。」` 的停顿点要落在右引号**之后**，
 *     否则引号会被当成下一句的字头、朗读时"抢拍"。
 *
 * ── 实现取向（2026-10-25 重写）──────────────────────────────────────────────
 * 旧实现是**逐字符状态机**：外层 `while` 找簇首，内层 `while` 用 `sawSentence`
 * 布尔标志一路吞掉后续标点与引号，靠手工维护 `i` / `j` 两个游标。
 *
 * 现在改为**单条全局正则一次性切出全部簇**，上面三条规则全部由正则的字符类
 * 直接表达，不再有游标与状态标志：
 *   · 簇首必须是停顿标点（句末类或逗号类）  → `[。！？…，；：、]`
 *   · 簇体可继续是停顿标点，也可以是右引号  → `[。！？…，；：、」』”’"']*`
 *   · 规则② = 对切出来的簇文本再测一次句末字符类
 *
 * 顺带删掉旧的 `codePointAt` 辅助函数：本函数关心的字符**全部落在 BMP**
 * （中文全角标点与 ASCII 引号都是单码元），而正则的 `u` 标志本身就能正确
 * 跨越代理对（emoji / 生僻字），不需要手工按码点步进 `i += ch.length`。
 *
 * ── 为什么正则在函数内新建而不是提到模块级 ──────────────────────────────────
 * 带 `g` 标志的 RegExp **对象**持有 `lastIndex` 状态。模块级复用会被
 * 「播放链路」与「时间线生成」两条调用路径互相污染（同一 chunk 上
 * `computePausePoints` 与 `buildSentenceTimeline` 会先后调用本函数）。
 * 正则**字面量**每次求值都产生新对象，因此写在函数体内天然重入安全。
 *
 * ── 等价性 ──────────────────────────────────────────────────────────────────
 * 与旧状态机逐字符等价：簇首判定一致、簇体吞并顺序一致、`isSentence` 语义
 * 一致（旧实现只要见过句末标点就置 true，等价于"簇内含有句末标点"）。
 *
 * @param text 一个合成块的原文（可为空串）
 * @returns 按出现顺序排列的停顿簇；空串输入返回空数组
 */
export function collectPauseRuns(text: string): PauseRun[] {
  const runs: PauseRun[] = [];
  if (text.length === 0) {
    return runs;
  }
  // 簇首 = 停顿标点；簇体 = 停顿标点或右引号（贪婪吞并，实现规则①与③）
  const clusterRe: RegExp = /[。！？…，；：、][。！？…，；：、」』”’"']*/gu;
  // 规则②：簇内出现任一句末标点即整簇判句末
  const sentenceRe: RegExp = /[。！？…]/u;
  let hit: RegExpExecArray | null = clusterRe.exec(text);
  while (hit !== null) {
    const cluster: string = hit[0];
    const start: number = hit.index;
    runs.push({
      start: start,
      end: start + cluster.length,
      isSentence: sentenceRe.test(cluster)
    });
    hit = clusterRe.exec(text);
  }
  return runs;
}

/**
 * 词级时间戳 → 原文区间对齐（把 TTS 返回的每个词定位回 `text` 的字符下标）。
 *
 * ── 为什么要"对齐"而不是直接用词的下标 ─────────────────────────────────────
 *  TTS 返回的 `words[]` 只给 `text` 与相对时间，**不给字符位置**。而停顿点必须
 *  按字符下标算，所以只能拿词文本回原文里搜。搜的时候必须**从上一个词的结束处
 *  往后找**（`cursor` 单调前进），否则重复词会被错配到前面去
 *  （「他说他说」第二个「他说」必须配到后一处）。
 *
 * ── 实现取向（2026-10-25 重写）──────────────────────────────────────────────
 *  旧实现用 `for` + `continue` 跳过空词与搜不到的词，游标 `cursor` 手工推进。
 *  现在改为 `Array.prototype.reduce` 一次折叠：累加器里同时带 `aligned` 结果
 *  与 `cursor` 游标，空词 / 搜不到的词直接**返回原累加器**（不推进游标），
 *  语义与旧实现完全一致，但没有可变的外部状态。
 *
 *  `indexOf` 返回 -1 时**不推进 cursor** —— 这一点是刻意的：某个词在原文里
 *  搜不到（TTS 做了数字/单位归一化，如把「100」念成「一百」），若推进游标就会
 *  把后续所有词错配到更后面的位置。保持游标不动，后续词仍按原顺序对齐。
 */
function alignWords(text: string, words: WordSpan[]): AlignedWord[] {
  interface Acc {
    aligned: AlignedWord[];
    cursor: number;
  }
  const seed: Acc = { aligned: [], cursor: 0 };
  const fin: Acc = words.reduce((acc: Acc, w: WordSpan): Acc => {
    // 空词（TTS 偶尔插入的纯停顿标记）不占字符位，也不动游标
    if (w.text.length === 0) {
      return acc;
    }
    const at: number = text.indexOf(w.text, acc.cursor);
    // 搜不到 ⇒ 该词被 TTS 归一化过，跳过它但**不推进游标**（见上方注释）
    if (at < 0) {
      return acc;
    }
    const next: AlignedWord = {
      startMs: w.startMs,
      endMs: w.endMs,
      charStart: at,
      charEnd: at + w.text.length
    };
    return { aligned: acc.aligned.concat([next]), cursor: at + w.text.length };
  }, seed);
  return fin.aligned;
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
      toMs = PAST_END_SENTINEL_MS;
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

/**
 * 一个待替换的停顿区间（**采样点**单位，不是毫秒）。
 *
 * `silenceLenSamples` 是**要插入的静音长度**，与被替换区间本身的长度
 * (`gapEndSample - gapStartSample`) 无关 —— 后者是原文里本来就有的自然间隙。
 */
interface PauseSampleRange {
  gapStartSample: number;
  gapEndSample: number;
  silenceLenSamples: number;
}

/**
 * 合并重叠的停顿区间（音频里不允许两段静音互相覆盖）。
 *
 * 判据：下一段的 `gapStartSample` ≤ 上一段的 `gapEndSample` 即为重叠（左闭右开区间
 * 首尾相接也算重叠，因为中间没有语音可留）。
 *
 * 合并规则 —— 两个字段各自取 `max`：
 *   · `gapEndSample`：取更远的终点，保证覆盖到所有重叠段；
 *   · `silenceLenSamples`：取**更长**的静音。为什么不是相加：两段重叠的停顿在
 *     听感上仍是"一个停顿"，相加会让「……，」这类连续标点停两次，实测很怪。
 *
 * 实现用 `reduce` 折叠，避免旧实现里"取末元素再原地改写"的可变状态
 * （原地改写要求 `merged` 非空判断与下标计算同时正确，容易出错）。
 */
function mergeRanges(items: PauseSampleRange[]): PauseSampleRange[] {
  return items.reduce((merged: PauseSampleRange[], it: PauseSampleRange): PauseSampleRange[] => {
    const n: number = merged.length;
    if (n === 0) {
      return merged.concat([{ gapStartSample: it.gapStartSample, gapEndSample: it.gapEndSample,
        silenceLenSamples: it.silenceLenSamples }]);
    }
    const prev: PauseSampleRange = merged[n - 1];
    if (it.gapStartSample > prev.gapEndSample) {
      // 不重叠 ⇒ 另起一段（拷贝一份，不复用入参对象）
      return merged.concat([{ gapStartSample: it.gapStartSample, gapEndSample: it.gapEndSample,
        silenceLenSamples: it.silenceLenSamples }]);
    }
    // 重叠 ⇒ 只替换末元素（不可原地改，reduce 要求返回新数组）
    const fused: PauseSampleRange = {
      gapStartSample: prev.gapStartSample,
      gapEndSample: Math.max(prev.gapEndSample, it.gapEndSample),
      silenceLenSamples: Math.max(prev.silenceLenSamples, it.silenceLenSamples)
    };
    return merged.slice(0, n - 1).concat([fused]);
  }, []);
}

/**
 * 把「1x 语速下的停顿时长」换算成当前语速下的实际时长。
 *
 * 语义：语速 2x 时停顿应减半，整段（语音+停顿）同比缩放，听感才一致。
 * 三道防线：
 *   · `configuredMs` 非有限或 ≤0 ⇒ 返回 0（调用方据此跳过该停顿点）；
 *   · `rate` 非有限或 ≤0 ⇒ 按 1x 处理（不因脏参数静音整段）；
 *   · 结果封顶 `PAUSE_DURATION_CAP_MS`（10s）—— 防止极端慢速把缓冲撑爆。
 */
function scaledPauseMs(configuredMs: number, rate: number): number {
  const saneMs: number = Number.isFinite(configuredMs) ? configuredMs : 0;
  if (saneMs <= 0) {
    return 0;
  }
  const saneRate: number = (Number.isFinite(rate) && rate > 0) ? rate : 1;
  const scaled: number = saneMs / saneRate;
  return scaled > PAUSE_DURATION_CAP_MS ? PAUSE_DURATION_CAP_MS : scaled;
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
    const gapStartSample = Math.max(0, Math.min(srcLen, Math.round(p.fromMs / 1000 * sampleRate)));
    const gapEndSample = Math.max(gapStartSample, Math.min(srcLen, Math.round(p.toMs / 1000 * sampleRate)));
    const silenceLenSamples = Math.round(durationMs / 1000 * sampleRate);
    if (silenceLenSamples > 0) {
      items.push({ gapStartSample: gapStartSample, gapEndSample: gapEndSample, silenceLenSamples: silenceLenSamples });
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
  items.sort((a: PauseSampleRange, b: PauseSampleRange): number => a.gapStartSample - b.gapStartSample);
  const merged = mergeRanges(items);
  let newLen = srcLen;
  for (let i = 0; i < merged.length; i++) {
    newLen += merged[i].silenceLenSamples - (merged[i].gapEndSample - merged[i].gapStartSample);
  }
  if (newLen <= 0) {
    applyEdgeFade(pcm, sampleRate);
    const r1: SpliceResult = { pcm: pcm, sampleRate: sampleRate, timeMap: timeMap };
    return r1;
  }
  const fade = Math.max(1, Math.round(INNER_FADE_SEC * sampleRate));
  const out = new Int16Array(newLen);
  let srcPos = 0;
  let dstPos = 0;
  let shiftSamples = 0;
  for (let i = 0; i < merged.length; i++) {
    const from = merged[i].gapStartSample;
    const to = merged[i].gapEndSample;
    const speechLen = from - srcPos;
    copySegment(out, dstPos, pcm, srcPos, speechLen, dstPos > 0, true, fade, vol);
    dstPos += speechLen;
    // 记录时间轴映射：经过该停顿后，原始 to 之后的时刻整体平移 shift
    dstPos += merged[i].silenceLenSamples;
    shiftSamples += merged[i].silenceLenSamples - (to - from);
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
    if (!SENTENCE_END_MARKS.test(c) && !CLAUSE_BREAK_MARKS.test(c)
      && !TRAILING_QUOTE_MARKS.test(c) && !/\s/.test(c)) {
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
      || (splitOnClause && CLAUSE_BREAK_MARKS.test(text.charAt(i))));
    if (boundary) {
      // 越过句末标点与后随右引号
      let j = i + 1;
      while (j < text.length && TRAILING_QUOTE_MARKS.test(text.charAt(j))) {
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
    if (!SENTENCE_END_MARKS.test(c) && !CLAUSE_BREAK_MARKS.test(c)
      && !TRAILING_QUOTE_MARKS.test(c) && !/\s/.test(c)) {
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
