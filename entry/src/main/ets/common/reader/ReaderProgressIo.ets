// 阅读器**进度 / 书签 IO 的纯计算与读取投影**（2026-11-04 P3 批 A-3：从 `ReaderPage3.ets` 搬出）。
//
// 为什么独立成模块（判据三条，逐条满足才搬）：
//   ① 只依赖入参 + 模块常量（`ReaderConst` / `ReaderCalibMath`）—— 本文件不持有任何
//      实例/单例状态，`hasBookmarkInRange` 走 `BookmarkPorts.list()` **只读**；
//   ② 函数体内不出现 `this.`（原来的 `this.<成员>` 全部改成显式形参）；
//   ③ 不写 DB、不写 AppStorage、不改 `@State`、不发事件。
//
// ⚠️ 函数体除 `this.<成员>` → 形参名外**逐字未改**（连注释一起搬）：值、顺序、边界、
//   判定阈值全部原样。唯一的结构性变化是把"隐式 this 读取"改成显式形参。
//
// ⚠️ **本批不搬**（留 `ReaderPage3.ets`，A-3 的硬边界）：
//   · `persistReadProgress` / `checkFinished` / `flushReadProgressThenNotifyShelf`
//     —— 写 `books` 表（经 `ReaderPorts`）+ 广播书架刷新；
//   · `toggleBookmark` —— 写/删书签行（`BookmarkPorts.removeByTime` / `add`）+ toast +
//     改 `@State isBookmarked`；
//   · `syncBookmarkState` —— 读库 + 改 `@State isBookmarked`，且查库去重键
//     `bmProbeKey` 是页面字段；
//   · `tryBookmarkJump` / `jumpToBookmark` / `jumpToCatalogItem` / `seekToChapterRatio`
//     —— 导航 + toast + `TtsEngine.seekToChapter`；
//   · `commitProgressSeek` —— 改 `bookData.durChapterIndex/durChapterTitle` + toast + 触感；
//   · `syncSliderPctFromPosition` —— 写 `@State progressUnit`；
//   · `currentPageFirstLine` —— 命中判据 ①③ 的边缘：它读 `TtsEngine.currentNodeTexts()/
//     currentChapter()` 单例，且 `TtsEngine.previewNodeTexts()` **会写引擎内部缓存**
//     （`previewNodes`/`previewSpine`，见 `tts/TtsEngine.ets:1243-1256`）⇒ 不属于"纯"。
//     等 `ReaderSession` 把 TtsEngine 的归属收口后再搬。
//
// 回退：把本文件的函数原样搬回 `ReaderPage3.ets`（git revert 对应提交即可）。

import { readerCore } from '@kit.ReaderKit';
import { BookmarkPorts } from './BookmarkPorts';
import { BookmarkRow } from '../../database/dao/BookmarksDao';
import { PROGRESS_TIP_W, PROGRESS_UNIT_MAX } from './ReaderConst';
import { PageRange } from './ReaderCalibMath';

// ══════════════════════════════════════════════════════════════════════════════
// 一、位置换算（ReaderKit 坐标系：spine / 块节点 / 节点内字符）
// ══════════════════════════════════════════════════════════════════════════════

/**
 * "19=0#43;@;0" → [块节点下标(0 基), 节点内字符偏移]。
 * 官方 FAQ：domPos = 章节标识=子节点索引=子孙节点索引#文字索引;@;进度；
 * 本工程实际形态 "<子节点索引>=0#<字符下标>"，且 X 段序号满足 X = 2k−1
 * （见文件头注释：偶数 X 是不渲染的块间空节点）。
 * 因此 node = floor((X−1)/2)；遇到偶数 X 也归到它前面那个渲染块。
 */
export function parseDomPos(domPos: string): number[] {
  const eq = domPos.indexOf('=');
  const hash = domPos.indexOf('#');
  const semi = hash >= 0 ? domPos.indexOf(';', hash) : -1;
  const x = eq > 0 ? parseInt(domPos.substring(0, eq)) : NaN;
  const y = hash >= 0 && semi > hash ? parseInt(domPos.substring(hash + 1, semi)) : 0;
  if (!Number.isFinite(x)) {
    return [0, 0];
  }
  const node = Math.max(0, Math.floor((Math.max(1, x) - 1) / 2));
  return [node, Number.isFinite(y) ? Math.max(0, y) : 0];
}

/** [块节点下标(0 基), 节点内字符偏移] → domPos（与 pageShow 回报同构） */
export function domPosFor(node: number, char: number): string {
  return `${2 * Math.max(0, node) + 1}=0#${char};@;0`;
}

// ══════════════════════════════════════════════════════════════════════════════
// 二、当前位置投影（"此刻读到哪儿"的唯一投影；纯函数版）
// ══════════════════════════════════════════════════════════════════════════════

/**
 * 「当前位置」的唯一表示（ReaderKit 坐标，2026-10-24 新增）。
 * 由 `currentPosition()` 统一产出 —— 见该方法的注释。
 */
export interface ReaderPosition {
  /** 章节索引（= spineIndex = resourceIndex） */
  spine: number;
  /** 章内块节点下标（0 基） */
  node: number;
  /** 节点内字符偏移 */
  char: number;
}

/**
 * 本页的"当前位置"曾经有**三套表示、三套更新时机**，任何新功能接进来都要先
 * 猜"该读哪一个"——接续功能就因此踩坑（真机日志 01:18:00：滚动模式上报成了章首）。
 *
 * | 状态 | 更新时机 | 能否代表"用户此刻在哪" |
 * |---|---|---|
 * | `scrollSpine` / `scrollNode` | 滚动模式**每次**滚动事件（`onScrollPos` 开头） | ✅ 滚动模式**实时**位置 |
 * | `bookData.localBookDurChapterPos` | 分页模式每次 `pageShow`；滚动模式只在**节流**落盘时 | ⚠️ 滚动模式是**滞后**值 |
 * | `pageRange` | 两种模式都更新，但是**页范围**不是单点 | ⚠️ 只适合"目标是否在页内"判断 |
 *
 * ── 谁应该调它 ────────────────────────────────────────────────────────────
 * 任何"需要知道用户此刻读到哪儿"的功能，**一律调本方法**，不要直接读上面三个字段：
 * · 应用接续（`publishContinueState`）✅ 已迁移
 * · 书签新增 / 双端同步锚点 / 阅读统计 / TTS 回跳
 *   （这些目前各自读 `pageRange` 或 `localBookDurChapterPos`，**属历史实现**，
 *     行为已验证，暂不强改；但**新增功能必须走本方法**。）
 *
 * ── 分模式取值 ────────────────────────────────────────────────────────────
 * · **自绘层（滚动 / 无动画）**：读 `scrollSpine` / `scrollNode`（实时，未被节流）
 * · **分页模式**：读 `localBookDurChapterPos`（`pageShow` 每翻一页就更新，够实时）
 * · 两者都拿不到 ⇒ 兜底 `pageRange` 的页首；再不行 ⇒ `(0,0,0)`
 *
 * ⚠️ 不要在这里做节流/缓存：调用方语义就是"要此刻的准确位置"。
 *
 * @param selfDrawn 是否处于**任一自绘阅读层**（原 `this.selfDrawnModeOn()`）
 * @param scrollSpine 自绘层实时章节号（原 `this.scrollSpine`）
 * @param scrollNode 自绘层实时块节点号（原 `this.scrollNode`）
 * @param durPos 分页模式落盘的进度（原 `this.bookData.localBookDurChapterPos`）
 * @param range 当前页范围（原 `this.pageRange`）
 */
export function currentPosition(selfDrawn: boolean, scrollSpine: number, scrollNode: number,
  durPos: readerCore.PageDataInfo | null | undefined, range: PageRange | null): ReaderPosition {
  if (selfDrawn) {
    return { spine: scrollSpine, node: scrollNode, char: 0 };
  }
  const pd: readerCore.PageDataInfo | null | undefined = durPos;
  if (pd !== null && pd !== undefined) {
    const parsed: number[] = parseDomPos(pd.startDomPos ?? '');
    return { spine: pd.resourceIndex ?? 0, node: parsed[0], char: parsed[1] };
  }
  const r: PageRange | null = range;
  if (r !== null) {
    return { spine: r.spine, node: r.startNode, char: r.startChar };
  }
  return { spine: 0, node: 0, char: 0 };
}

// ══════════════════════════════════════════════════════════════════════════════
// 三、进度单位与百分比换算（滑条内部单位 1 单位 = 0.1%）
// ══════════════════════════════════════════════════════════════════════════════

/** 夹到 `[0, PROGRESS_UNIT_MAX]` 的整数单位 */
export function clampProgressUnit(u: number): number {
  if (!Number.isFinite(u) || u < 0) {
    return 0;
  }
  return u > PROGRESS_UNIT_MAX ? PROGRESS_UNIT_MAX : u;
}

/**
 * 气泡横向位置（跟随 thumb 中心，夹在轨道内）
 *
 * @param trackW 滑条轨道实测宽度（vp，原 `this.progressTrackW`）
 * @param unit 当前进度单位（原 `this.progressUnit`）
 */
export function progressTipX(trackW: number, unit: number): number {
  const track: number = trackW;
  if (track <= 0) {
    return 0;
  }
  // thumb 直径 30 ⇒ 两端各留 15vp 才是 thumb 中心的实际行程
  const usable: number = Math.max(1, track - 30);
  const center: number = 15 + usable * (unit / PROGRESS_UNIT_MAX);
  const maxX: number = Math.max(0, track - PROGRESS_TIP_W);
  const x: number = center - PROGRESS_TIP_W / 2;
  return Math.max(0, Math.min(maxX, x));
}

// ══════════════════════════════════════════════════════════════════════════════
// 四、书签判定（只读投影）
// ══════════════════════════════════════════════════════════════════════════════

/**
 * 当前页范围内是否已有书签（**区间包含**，不要求页首节点精确相等）。
 *
 * 为什么不能用 `isBookmarked(name, idx, startNode)` 精确匹配：
 *   书签存的是"保存那一页的页首节点"，而 `startPlay` 落页只保证目标节点在页内，
 *   经常落在页尾（真机日志：书签 node=62，落页 [59..62]）⇒ 页首 59 ≠ 62
 *   ⇒ 图标不亮、用户再点一次 ⇒ 同章多叠书签。跨档（ReaderKit 页首 vs 自绘页首）同理。
 *   换成「书签节点 ∈ 当前页 [startNode, endNode]」后，落页到尾/换档/换排版都能点亮。
 *
 * ⚠️ 本章节内"书签存的是**块节点号**而不是字符偏移"的口径说明（原注释）留在
 *   `ReaderPage3.ets` 的 `bmJump*` 附近，本函数只负责判定。
 *
 * @param bookName 书名（原 `this.bookData.bookName`）
 * @param idx 目录号（由页的 spine 反推，调用方保证坐标系与存书签时一致）
 * @param startNode 当前页起始块节点号（含）
 * @param endNode 当前页结束块节点号（含）
 */
export async function hasBookmarkInRange(bookName: string, idx: number, startNode: number,
  endNode: number): Promise<boolean> {
  const name: string = bookName
  if (name === undefined || name === null || name.length === 0) {
    return false
  }
  // ⚠️ 2026-10-31 回退 listByChapter：真机出现"书签图标上来就掉"，
  //    疑似 RdbPredicates 的 equalTo 链在该表上不可靠；先回到已验证的 list()+JS 过滤，
  //    书签量级很小（几十~几百），不是卡顿主因。
  const rows: BookmarkRow[] = await BookmarkPorts.list()
  const hits: BookmarkRow[] = rows.filter((b: BookmarkRow): boolean =>
    b.bookName === name && b.chapterIndex === idx
    && b.chapterPos >= startNode && b.chapterPos <= endNode)
  return hits.length > 0
}
