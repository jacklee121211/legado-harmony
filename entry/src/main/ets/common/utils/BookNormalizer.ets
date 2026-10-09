/**
 * 书籍「转译版」生成器（2026-10-09，用户拍板方案）。
 *
 * ── 它解决什么 ─────────────────────────────────────────────────────────────
 * 真机日志实证：有一类书 ReaderKit **解析不了**——
 *   `E  Engine parse epub or txt content failed!`
 *   `catalog list length: 1`（整本零目录）
 *   开书 10:24:05.459 → 首个 pageShow 10:24:10.047 ⇒ **4.59 秒黑屏**
 * 用户原话：「我用其他软件看这个书都没问题…我怀疑是因为全文都是一个行段」。
 *
 * ⇒ 方案：**我们自己先解一遍、规整一次，缓存成"转译版"**，之后每次打开都读转译版
 *   ⇒ ReaderKit 一次解析成功 ⇒ 既快、又有目录。
 *   （用户原话：「相当于我们做了一个转译版本」「第二次进入默认有缓存加载」）
 *
 * ── 三个关键设计决定（都有依据）────────────────────────────────────────────
 * ① **编码**：`util.TextDecoder` 官方支持 gbk / gb18030 / big5 / gb2312 / utf-16le 等
 *    （SDK `@ohos.util.d.ts:289-292` 原文：「The following formats are supported:
 *      utf-8, … gbk, gb18030, big5, euc-jp, …, utf-16be, utf-16le, gb2312, and iso-8859-1.」）
 *    ⇒ 我们自己解，不依赖 ReaderKit 的编码识别（那正是它失败的环节之一）。
 * ② **目录单层级**：用户确认「我们当前的目录是单层级」⇒ 只产出 `string[]` 章标题，
 *    不建树。切章正则**放宽**（第X章/回/节/卷/篇/部/集、Chapter/Part/Section、
 *    序章/前言/后记/尾声/番外/楔子/引子，以及纯数字行兜底）。
 * ③ **缓存新鲜度**：文件名里带上源文件的 `size + mtime` ⇒ 源文件一变（重导/替换）
 *    自动换缓存，**不需要额外元数据、也不会读到过期缓存**。
 *
 * ── 一键回退 ───────────────────────────────────────────────────────────────
 * `ENABLED = false` ⇒ `ensure()` 直接返回 null，全工程行为与改造前一致。
 * 回退后要验证：那本"零目录 + 首屏 4 秒"的书恢复原样（能开、但慢且没目录）。
 */
import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { Books } from '../../database/entities/Books';

const DOMAIN: number = 0x0000;
const TAG: string = 'normalize';

/** 规整结果：转译版文件路径 + 单层级目录 */
export interface NormalizeResult {
  path: string;
  toc: string[];
}

/** 合成章节的结果（正文 + 目录） */
interface SynthesizedBook {
  text: string;
  toc: string[];
}

export class BookNormalizer {
  /** **一键回退开关**：false ⇒ 本模块整体旁路 */
  static readonly ENABLED: boolean = true;

  /** 缓存目录（应用沙箱内，随卸载清除） */
  private static readonly SUB_DIR: string = 'normalized';

  /** 规整算法版本 —— 参与缓存文件名，改算法即自动作废旧缓存 */
  private static readonly FORMAT_VERSION: string = 'v2';

  /**
   * 判定"这本书需要转译"的阈值：我们自己的切章正则**切不出这么多章**时，
   * 就认为 ReaderKit 也切不出来（零目录）⇒ 需要转译。
   * 取 2：正常书没有低于 2 章还能读的；1 章往往就是"全文一个行段"那种。
   */
  private static readonly MIN_CHAPTERS: number = 2;

  /**
   * 章节标题正则（**单层级、尽量宽**，用户要求「最好支持范围广一点」）。
   * 逐行匹配，命中即为一个章标题。
   */
  private static readonly CHAPTER_RES: RegExp[] = [
    // 第X章 / 第X回 / 第X节 / 第X卷 / 第X篇 / 第X部 / 第X集（X 可中文数字或阿拉伯数字）
    /^第\s*[0-9零一二三四五六七八九十百千万两]{1,8}\s*[章回节卷篇部集]\s*.*$/,
    // Chapter 1 / CHAPTER 1 / Part 1 / Section 1 / Volume 1
    /^(chapter|part|section|volume|book)\s*[0-9ivxlcdm]{1,6}\b.*$/i,
    // 序章 / 序言 / 前言 / 后记 / 尾声 / 番外 / 楔子 / 引子 / 终章
    /^(序章|序言|序|前言|后记|尾声|终章|番外|楔子|引子)\s*.*$/,
    // 卷一 / 卷二 …
    /^卷\s*[0-9零一二三四五六七八九十百千万两]{1,4}\s*.*$/
  ];

  /** 纯数字行（如"123"）—— 只在其它规则都切不出时才启用，见 `splitChapters` */
  private static readonly NUMERIC_LINE: RegExp = /^\s*[0-9]{1,4}\s*$/;

  // ────────────────────────────────────────────────────────────────────────
  // 读：按编码解出文本
  // ────────────────────────────────────────────────────────────────────────

  /**
   * 按声明的编码读文本；解出来"像乱码"就按常见中文编码再试一轮。
   *
   * 为什么不用 `fs.readTextSync`：它只有 utf-8 一种（读 gbk 会整篇乱码），
   *   而 gbk 正是这类书最常见的编码。
   */
  private static readText(path: string, charset: string): string | null {
    let bytes: ArrayBuffer | null = null;
    let fd: fs.File | null = null;
    try {
      const stat = fs.statSync(path);
      const size: number = stat.size;
      if (size <= 0) {
        return null;
      }
      const buf = new ArrayBuffer(size);
      fd = fs.openSync(path, fs.OpenMode.READ_ONLY);
      const readLen: number = fs.readSync(fd.fd, buf);
      bytes = readLen === size ? buf : buf.slice(0, readLen);
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'read bytes err %{public}s',
        e instanceof Error ? e.message : String(e));
      return null;
    } finally {
      if (fd !== null) {
        try {
          fs.closeSync(fd);
        } catch (e) {
          // 关不上就算了，不影响主流程
        }
      }
    }
    if (bytes === null) {
      return null;
    }
    // 候选编码：先用书里记的，再用最常见的几种
    const order: string[] = [];
    const hint: string = charset !== undefined && charset !== null ? charset.trim().toLowerCase() : '';
    if (hint.length > 0) {
      order.push(hint);
    }
    for (const c of ['utf-8', 'gb18030', 'gbk', 'big5', 'utf-16le', 'utf-16be']) {
      if (order.indexOf(c) < 0) {
        order.push(c);
      }
    }
    let best: string = '';
    let bestScore: number = -1;
    for (const enc of order) {
      const s: string = BookNormalizer.decode(bytes, enc);
      if (s.length === 0) {
        continue;
      }
      const score: number = BookNormalizer.score(s);
      if (score > bestScore) {
        bestScore = score;
        best = s;
      }
      // 乱码率极低 ⇒ 直接采纳，不再试后面的
      if (score >= 0.98) {
        break;
      }
    }
    return best.length > 0 ? best : null;
  }

  private static decode(bytes: ArrayBuffer, encoding: string): string {
    try {
      const dec = util.TextDecoder.create(encoding, { ignoreBOM: true });
      return dec.decodeToString(new Uint8Array(bytes));
    } catch (e) {
      // 该编码不被支持时会抛，交给调用方换下一个
      return '';
    }
  }

  /**
   * "像不像正常文本"打分（0~1）。
   * 判据：可打印字符与常见中文占比；`\uFFFD`（解码失败替换符）与不可见控制符算扣分。
   */
  private static score(s: string): number {
    const n: number = s.length;
    if (n === 0) {
      return 0;
    }
    let good: number = 0;
    const step: number = n > 4000 ? Math.floor(n / 4000) : 1;
    let sampled: number = 0;
    for (let i = 0; i < n; i += step) {
      const c: number = s.charCodeAt(i);
      sampled++;
      if (c === 0xFFFD) {
        continue;
      }
      // 中文 / 英文数字 / 常见标点 / 换行制表
      const isCjk: boolean = c >= 0x4E00 && c <= 0x9FFF;
      const isAscii: boolean = c >= 0x20 && c <= 0x7E;
      const isPunct: boolean = c === 0x0A || c === 0x0D || c === 0x09;
      const isCjkPunct: boolean = c >= 0x3000 && c <= 0x303F;
      const isFullWidth: boolean = c >= 0xFF00 && c <= 0xFFEF;
      if (isCjk || isAscii || isPunct || isCjkPunct || isFullWidth) {
        good++;
      }
    }
    return sampled > 0 ? good / sampled : 0;
  }

  // ────────────────────────────────────────────────────────────────────────
  // 切：目录（单层级）
  // ────────────────────────────────────────────────────────────────────────

  /**
   * 按行切章，返回章标题（单层级）。
   *
   * 兜底顺序：主正则 → 纯数字行。两者都切不出足够章数 ⇒ 返回空数组
   *   （调用方据此判定"这本书没救"，走固定长度切法，见 `normalize`）。
   */
  static splitChapters(text: string): string[] {
    const lines: string[] = text.split('\n');
    const toc: string[] = [];
    for (const raw of lines) {
      const line: string = raw.trim();
      // 标题行不会很长；超过 40 字基本是正文里恰好以"第X章"开头的一句
      if (line.length === 0 || line.length > 40) {
        continue;
      }
      if (BookNormalizer.isChapterTitle(line)) {
        toc.push(line);
      }
    }
    if (toc.length >= BookNormalizer.MIN_CHAPTERS) {
      return toc;
    }
    // 兜底：纯数字行（有些盗版 txt 就这么分章）
    const byNum: string[] = [];
    for (const raw of lines) {
      const line: string = raw.trim();
      if (BookNormalizer.NUMERIC_LINE.test(line)) {
        byNum.push(line);
      }
    }
    return byNum.length >= BookNormalizer.MIN_CHAPTERS ? byNum : [];
  }

  private static isChapterTitle(line: string): boolean {
    for (const re of BookNormalizer.CHAPTER_RES) {
      if (re.test(line)) {
        return true;
      }
    }
    return false;
  }

  /**
   * **兜底合成章节**（2026-10-09，用户要求「需要我们兜底生成」）。
   *
   * 什么时候用：正文里**一个可识别的章名都没有**（我们和 ReaderKit 的正则都切不出）——
   *   典型就是用户描述的"全文都是一个行段"的盗版 txt。
   *   ReaderKit 对这类书会 `Engine parse ... failed` ⇒ 零目录 + 首屏 4.6 秒。
   *
   * 做法：按**目标篇幅**切块（尽量切在句号/换行处，不切断句子），
   *   每块前面插一行 `第N章`（ReaderKit 的目录正则认这个格式）。
   *
   * ⚠️ 这是**不得已的兜底**：造出来的章号没有语义，只保证"能导航、能解析"。
   *    所以只在原文确实零章名时才走（见调用点）。
   */
  private static synthesizeChapters(body: string): SynthesizedBook {
    /** 每章目标字数：约 3000 字。太小会造出上千章（目录列表卡），太大则导航粒度太粗 */
    const TARGET: number = 3000;
    const text: string[] = [];
    const toc: string[] = [];
    let idx: number = 0;
    let n: number = 0;
    const total: number = body.length;
    while (idx < total) {
      n++;
      const title: string = '第' + n + '章';
      toc.push(title);
      text.push('\n\n' + title + '\n\n');
      let end: number = Math.min(total, idx + TARGET);
      if (end < total) {
        // 在 [idx+TARGET*0.6, idx+TARGET] 区间里找一个自然的断点，避免切断句子
        const lo: number = Math.min(end, idx + Math.floor(TARGET * 0.6));
        let cut: number = -1;
        for (let i = end; i >= lo; i--) {
          const c: string = body.charAt(i);
          if (c === '\n' || c === '。' || c === '！' || c === '？' || c === '”' || c === '"') {
            cut = i + 1;
            break;
          }
        }
        if (cut > idx) {
          end = cut;
        }
      }
      text.push(body.substring(idx, end));
      idx = end;
    }
    return { text: text.join(''), toc: toc };
  }

  // ────────────────────────────────────────────────────────────────────────
  // 缓存
  // ────────────────────────────────────────────────────────────────────────

  private static dir(context: common.UIAbilityContext): string {
    return context.filesDir + '/' + BookNormalizer.SUB_DIR;
  }

  /**
   * 转译版文件名带上**源文件的 size + mtime**：
   *   源文件一被替换/重导，size 或 mtime 必变 ⇒ 自动落到新名字、绝不读到过期缓存。
   *   （用户要求：「为这种类型的书做好缓存机制」「第二次进入默认有缓存加载」。）
   */
  private static cachePathFor(context: common.UIAbilityContext, book: Books): string | null {
    const src: string = book.bookUrl ?? '';
    if (src.length === 0) {
      return null;
    }
    try {
      const st = fs.statSync(src);
      const id: number = book.id ?? -1;
      // ⚠️ 文件名里带 `FORMAT_VERSION`：**规整算法一改，旧缓存必须自动失效**。
      //   本次就踩过 —— 第一版没插入章节，命中旧缓存后新算法永远不生效（用户看到"没效果"）。
      return `${BookNormalizer.dir(context)}/${id}_${st.size}_${Math.floor(st.mtime)}_${BookNormalizer.FORMAT_VERSION}.txt`;
    } catch (e) {
      return null;
    }
  }

  /** 缓存是否已经存在且可用（存在即命中，因为文件名已绑定源文件指纹） */
  static hitCache(context: common.UIAbilityContext, book: Books): string | null {
    const p: string | null = BookNormalizer.cachePathFor(context, book);
    if (p === null) {
      return null;
    }
    try {
      return fs.accessSync(p) ? p : null;
    } catch (e) {
      return null;
    }
  }

  // ────────────────────────────────────────────────────────────────────────
  // 主入口
  // ────────────────────────────────────────────────────────────────────────

  /**
   * 确保这本书有"转译版"。
   *
   * @returns 转译版路径 + 目录；**不需要转译 / 转译失败时返回 null**
   *   （调用方拿到 null 就按原逻辑打开原文件，行为与改造前一致 ⇒ 天然可回退）
   */
  static async ensure(context: common.UIAbilityContext, book: Books): Promise<NormalizeResult | null> {
    if (!BookNormalizer.ENABLED) {
      return null;
    }
    const src: string = book.bookUrl ?? '';
    if (src.length === 0) {
      return null;
    }
    // ① 命中缓存 ⇒ 直接用（这是"第二次进入要快"的快路径）
    const cached: string | null = BookNormalizer.hitCache(context, book);
    if (cached !== null) {
      const toc: string[] = BookNormalizer.readTocSidecar(cached);
      hilog.info(DOMAIN, TAG, 'cache hit: %{public}s toc=%{public}d', cached, toc.length);
      return { path: cached, toc: toc };
    }
    // ② 读原文（按编码解）
    const text: string | null = BookNormalizer.readText(src, book.charset ?? '');
    if (text === null) {
      hilog.warn(DOMAIN, TAG, 'readText failed, skip normalize');
      return null;
    }
    // ③ 我们自己能切出目录吗？
    const toc: string[] = BookNormalizer.splitChapters(text);
    if (toc.length >= BookNormalizer.MIN_CHAPTERS) {
      // 我们能切出来 ⇒ 说明 ReaderKit 大概率也能 ⇒ **不折腾**，走原文件
      hilog.info(DOMAIN, TAG, 'chapters=%{public}d, no need to normalize', toc.length);
      return null;
    }
    // ④ 切不出来 ⇒ 这本书就是"零目录"那种，转译
    hilog.warn(DOMAIN, TAG, 'no chapter found (len=%{public}d), normalizing', text.length);
    return BookNormalizer.writeNormalized(context, book, text);
  }

  /**
   * 写出转译版：正文按段落规整（`\r\n`→`\n`、压缩连续空行），
   * 并保证**每个章标题独占一行**，让 ReaderKit 的目录识别也能命中。
   *
   * ⚠️ 只**新增**文件，**绝不改动原书文件、也不改 `Books.bookUrl`** ——
   *    调用方拿到返回的 path 自行决定用不用 ⇒ 一键回退零风险。
   */
  private static writeNormalized(context: common.UIAbilityContext,
    book: Books, text: string): NormalizeResult | null {
    const out: string | null = BookNormalizer.cachePathFor(context, book);
    if (out === null) {
      return null;
    }
    try {
      fs.mkdirSync(BookNormalizer.dir(context), true);
    } catch (e) {
      // 已存在
    }
    // 规整正文：统一换行 + 压缩 3 个以上连续空行为 1 个空行
    let body: string = text.replace(/\r\n/g, '\n').replace(/\r/g, '\n');
    body = body.replace(/\n{3,}/g, '\n\n');
    let toc: string[] = BookNormalizer.splitChapters(body);
    if (toc.length < BookNormalizer.MIN_CHAPTERS) {
      // ★★ 2026-10-09 真机日志换来的关键一步（第一版漏了它，所以用户看到"没效果"）★★
      //   日志实证：转译后 ReaderKit **依旧**
      //     `catalog list length: 1` + `Engine parse epub or txt content failed!`，
      //     首屏仍 4.58 秒 ⇒ 转译等于白转。
      //   原因：本方法原来只统一换行、**没有插入任何章节标记**；而这本书本来就没有
      //     可识别的章名（用户原话："全文都是一个行段"）
      //     ⇒ 我们的正则和 ReaderKit 的正则**都找不到东西**。
      //   ⇒ 真正的兜底是**自己造章节**：按篇幅切块，每块前插一行 `第N章`
      //     （ReaderKit 的目录正则认这个格式）⇒ 它能解析成功 ⇒ 出目录 + 不再走慢路径。
      const made: SynthesizedBook = BookNormalizer.synthesizeChapters(body);
      body = made.text;
      toc = made.toc;
      hilog.info(DOMAIN, TAG, 'synthesized %{public}d chapters (source had none)', toc.length);
    }
    let fd: fs.File | null = null;
    try {
      fd = fs.openSync(out, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      fs.writeSync(fd.fd, body);
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'write normalized err %{public}s',
        e instanceof Error ? e.message : String(e));
      return null;
    } finally {
      if (fd !== null) {
        try {
          fs.closeSync(fd);
        } catch (e) {
          // 忽略
        }
      }
    }
    BookNormalizer.writeTocSidecar(out, toc);
    hilog.info(DOMAIN, TAG, 'normalized written: %{public}s toc=%{public}d bytes=%{public}d',
      out, toc.length, body.length);
    return { path: out, toc: toc };
  }

  // ── 目录旁挂文件：`<name>.txt` → `<name>.toc.json`（单层级字符串数组） ──

  private static tocPathOf(normalizedPath: string): string {
    return normalizedPath + '.toc.json';
  }

  private static writeTocSidecar(normalizedPath: string, toc: string[]): void {
    // ⚠️ `fileIo` **没有** `writeTextSync`（LSP 实测报 2551，提示改用 `writeSync`）
    //   ⇒ 用 open + writeSync(fd, string) 自己写。
    let fd: fs.File | null = null;
    try {
      fd = fs.openSync(BookNormalizer.tocPathOf(normalizedPath),
        fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      fs.writeSync(fd.fd, JSON.stringify(toc));
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'write toc sidecar failed: %{public}s',
        e instanceof Error ? e.message : String(e));
    } finally {
      if (fd !== null) {
        try {
          fs.closeSync(fd);
        } catch (e) {
          // 忽略
        }
      }
    }
  }

  /** 读回目录；文件缺失/损坏一律返回空数组（调用方走"无目录"的正常路径，不报错） */
  static readTocSidecar(normalizedPath: string): string[] {
    try {
      const raw: string = fs.readTextSync(BookNormalizer.tocPathOf(normalizedPath));
      const arr = JSON.parse(raw) as string[];
      return arr !== null && arr !== undefined ? arr : [];
    } catch (e) {
      return [];
    }
  }
}
