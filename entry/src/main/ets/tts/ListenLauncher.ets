/**
 * 书架听书启动器（2026-10-09 第二版）。
 *
 * ── 它解决什么 ─────────────────────────────────────────────────────────────
 * 用户要求（原话）：「点击圆形播放不应该进入阅读页，只是此时如果进入阅读页
 *   直接就是沉浸听读模式而已，而且进度都是同步的，这才是天然同步」。
 * ⇒ 点圆形 = **留在书架原地起播**，不 push 任何页面。
 *   「进阅读页自动进入沉浸听读」由 `ReaderPage3.registerTtsCallbacks()` 末尾的
 *   状态回拉负责（真机日志已证：`tts state restored on enter: state=playing spine=174`）。
 *
 * ── ⚠️ 这个文件为什么能成立（真机日志换来的前提）──────────────────────────
 * `getSpineItemContent` 报 **1017010002（bookParser 的 Invalid request）**
 * 只有两种成因：索引越界，或 **handler 已失效**。
 * 真机日志（10-09 01:50:39~01:50:55）里索引 175…764 连续失败 666 次，
 * 而 ReaderKit 自己停在 174 ⇒ 是后者，元凶是 `ReaderPage3.aboutToDisappear()` 的
 * `releaseBook()`。**同期已修**：听书进行中不再 releaseBook。
 * ⇒ 没有那个修复，本启动器起的播会在返回书架后立刻断流。
 *
 * ── 位置锚点（"进度天然同步"）────────────────────────────────────────────
 * 起点取书上的阅读进度：
 *   · spine = `localBookDurChapterPos.resourceIndex`（ReaderKit 正文号，
 *             沉浸听读跟随翻章时落库的就是它），取不到才用目录号换算；
 *   · (node, char) = 解析 `localBookDurChapterPos.startDomPos`，
 *     与 `ReaderPage3.domPosFor()` 互逆：
 *       `domPosFor(node,char) = "${2*node+1}=0#${char};@;0"`
 *       ⇒ 反解 `node = floor((x-1)/2)`、`char = y`。
 *   暂停后继续走 `TtsEngine.resume()`（原地续播），不会再从章首重来。
 */
import { common } from '@kit.AbilityKit';
import { bookParser } from '@kit.ReaderKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import BooksDao from '../database/dao/BooksDao';
import { Books } from '../database/entities/Books';
import { TtsEngine } from './TtsEngine';
import { TtsPrefs, loadTtsPrefs } from './TtsPrefs';
import { ListenSession } from './ListenSession';

const DOMAIN: number = 0x0000;
const TAG: string = 'listen';

export class ListenLauncher {
  /**
   * 书架圆形按钮点「播放」时调用。
   * 无阅读历史 ⇒ 静默（用户约定"新用户点了没反应"），只把 dock 收回圆形。
   */
  static startLastRead(context: common.UIAbilityContext): void {
    BooksDao.getLastReadBook().then((book: Books | null) => {
      if (book === null) {
        hilog.info(DOMAIN, TAG, 'no last read book, ignore tap');
        // 置回折叠态：`Index` 对 `listenExpanded` 挂了 @Watch，会据此把 HDS 也钉回圆形
        ListenSession.setExpanded(false);
        return;
      }
      ListenLauncher.startBook(context, book);
    }).catch((e: Error) => {
      hilog.error(DOMAIN, TAG, 'getLastReadBook err %{public}s', e.message);
      ListenSession.setExpanded(false);
    });
  }

  /** 用一本书直接起播（书架侧无页面 ⇒ 回调一律 headless） */
  static startBook(context: common.UIAbilityContext, book: Books): void {
    const path: string = book.bookUrl ?? '';
    if (path.length === 0) {
      hilog.error(DOMAIN, TAG, 'book has empty bookUrl, ignore');
      ListenSession.setExpanded(false);
      return;
    }
    // `Books` 实体里书名只有 `bookName`（`name` 属同文件另一个类，别混用）
    const title: string = book.bookName;
    const prefs: TtsPrefs = loadTtsPrefs();
    TtsEngine.init(context);
    // 记录路径：解析器被阅读页 releaseBook 作废后，TtsEngine.tryHealHandler() 靠它重开
    TtsEngine.setOwnPath(path);
    // 书架侧没有任何阅读页实例 ⇒ 必须用 headless 回调（只镜像 AppStorage）
    TtsEngine.setCallbacks(ListenSession.headless());
    // 位置提供者也要清掉：可能残留着上一个已销毁阅读页的闭包
    TtsEngine.clearReaderPositionProvider();
    ListenSession.begin(title, path, book.id ?? -1);
    bookParser.getDefaultHandler(path).then((h: bookParser.BookParserHandler) => {
      const pos = book.localBookDurChapterPos;
      let spine: number = 0;
      let anchor: number[] = [-1, 0];
      if (pos !== null && pos !== undefined) {
        spine = pos.resourceIndex;
        anchor = ListenLauncher.anchorFrom(pos.startDomPos);
      } else {
        spine = ListenLauncher.spineForCatalog(h, book.durChapterIndex ?? 0);
      }
      hilog.info(DOMAIN, TAG, 'start from spine=%{public}d node=%{public}d char=%{public}d',
        spine, anchor[0], anchor[1]);
      TtsEngine.start(context, h, spine, prefs, title, anchor[0], anchor[1])
        .catch((e: Object) => {
          hilog.error(DOMAIN, TAG, 'tts start failed: %{public}s', JSON.stringify(e));
          ListenSession.end();
        });
    }).catch((e: Error) => {
      hilog.error(DOMAIN, TAG, 'getDefaultHandler err %{public}s', e.message);
      ListenSession.end();
    });
  }

  /**
   * `domPos` → `[块节点下标, 节点内字符偏移]`；解析不出来返回 `[-1, 0]`（= 从该章章首）。
   * 与 `ReaderPage3.domPosFor()` 互逆，格式 `"${2*node+1}=0#${char};@;0"`。
   */
  private static anchorFrom(domPos: string): number[] {
    const m: RegExpMatchArray | null = domPos.match(/^(\d+)=0#(\d+)/);
    if (m === null) {
      return [-1, 0];
    }
    const x: number = Number(m[1]);
    const y: number = Number(m[2]);
    const node: number = Math.max(0, Math.floor((Math.max(1, x) - 1) / 2));
    return [node, Number.isFinite(y) ? Math.max(0, y) : 0];
  }

  /**
   * 目录号 → 正文号（老书没有 `localBookDurChapterPos` 时的兜底）。
   * 与阅读页 `ReaderPage3.getResourceItemByCatalog()` **同源**：目录项 `resourceFile`
   * 与 spine 的 `href` 相等即命中；找不到就退回第 0 章（绝不返回非法下标）。
   */
  private static spineForCatalog(h: bookParser.BookParserHandler, catalogIndex: number): number {
    try {
      const catalogs: bookParser.CatalogItem[] = h.getCatalogList();
      const spines: bookParser.SpineItem[] = h.getSpineList();
      if (spines.length === 0) {
        return 0;
      }
      if (catalogIndex >= 0 && catalogIndex < catalogs.length) {
        const file: string = catalogs[catalogIndex].resourceFile || '';
        for (let i = 0; i < spines.length; i++) {
          if (spines[i].href === file) {
            return spines[i].index;
          }
        }
      }
      return 0;
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'spineForCatalog err %{public}s',
        e instanceof Error ? e.message : String(e));
      return 0;
    }
  }
}
