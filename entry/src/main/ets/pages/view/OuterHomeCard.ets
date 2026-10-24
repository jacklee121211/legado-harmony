/**
 * 外屏极简「继续阅读」卡片（2026-10-24 新增，PuraX 外屏适配）。
 *
 * ── 它是什么 ──────────────────────────────────────────────────────────────
 * PuraX 折叠态（1:1 小方屏，326×326vp）上**替代整个四页签书架**的单页。
 * 用户口径原话：「外屏只有一个功能…就是在外屏点击后，快速阅读」；
 * 「不需要有全量的功能，比如书架，而是可以快速进入阅读器」。
 *
 * ── 三个职责 ──────────────────────────────────────────────────────────────
 *   ① 外屏冷启动时，若自动进书失败（没有阅读记录）⇒ 它就是兜底页，不留静默失败；
 *   ② 阅读器的**返回落点** —— 顶栏按用户要求整条取消后，系统返回键落到这里；
 *   ③ 用户主动从阅读器退回后，这里给一个明确的「继续阅读」入口，而不是把人困住。
 *
 * ── 为什么不做成"缩小版书架" ───────────────────────────────────────────────
 * 326×326vp 上放宫格封面（3 列）每本只有 ~90vp 宽，书名基本不可读；
 * 而且用户明确说外屏不要全量功能。所以这里只给**一本书**（最后阅读的那本）。
 *
 * ── 隔离性 ────────────────────────────────────────────────────────────────
 * 本组件**只在** `outerMinimal === true` 时被 `Index.ets` 挂载；
 * 内屏 / 手机 / 平板 / 2in1 永远不会渲染它 ⇒ 对现有功能零影响。
 */
import { Books } from '../../database/entities/Books';
import BooksDao from '../../database/dao/BooksDao';
import { resolveBookCover, coverCorners } from '../../common/utils/CoverSource';
import { NightMode, ShelfColors } from '../../common/utils/NightMode';
import { Haptics } from '../../common/utils/Haptics';
import { showMessage } from '../../componets/common/promptShow';

/** 卡片内封面宽度（vp）。326vp 屏宽减去两侧 24vp 内边距 + 卡片内边距后留出的视觉主体 */
const COVER_W: number = 104;

@Component
export struct OuterHomeCard {
  /** 最后阅读的那本书；`null` = 还没读过任何书（或查询中） */
  @State private book: Books | null = null;
  /** 是否已查完（区分"查询中"与"确实没有记录"） */
  @State private loaded: boolean = false;
  /** 由父组件注入：点「继续阅读」/ 点封面时打开阅读器 */
  onOpen: () => void = (): void => {
  };

  aboutToAppear(): void {
    this.loadLastRead();
  }

  /** 每次回到本页（例如从阅读器返回）都重查一次 —— 书名/进度可能已变 */
  private loadLastRead(): void {
    BooksDao.getLastReadBook().then((b: Books | null): void => {
      this.book = b;
      this.loaded = true;
    }).catch((): void => {
      this.book = null;
      this.loaded = true;
    });
  }

  private open(): void {
    Haptics.tap();
    if (this.book === null) {
      showMessage('还没有阅读记录，展开手机去书架挑一本吧');
      return;
    }
    this.onOpen();
  }

  /** 书名（去掉扩展名的展示口径与书架一致） */
  private title(): string {
    const b: Books | null = this.book;
    if (b === null) {
      return '';
    }
    const n: string = b.bookName ?? '';
    return n.length > 0 ? n : '未命名';
  }

  /** 副标题：章节名 + 进度（拿不到就退回一句引导语） */
  private subtitle(): string {
    const b: Books | null = this.book;
    if (b === null) {
      return '';
    }
    const total: number = b.totalChapterNum ?? 0;
    const idx: number = (b.durChapterIndex ?? 0) + 1;
    if (total > 0) {
      return `第 ${idx} / ${total} 章`;
    }
    return '接着上次的位置继续';
  }

  build() {
    Column() {
      if (!this.loaded) {
        // ── 查询中：极简占位，避免闪一下空态 ──────────────────────────────
        Column({ space: 12 }) {
          LoadingProgress()
            .width(28)
            .height(28)
            .color(ShelfColors.textSub())
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
      } else if (this.book === null) {
        // ── 没有任何阅读记录：给引导，不留死路 ────────────────────────────
        Column({ space: 10 }) {
          // 符号名已核真源（`sdk/default/openharmony/ets/build-tools/ets-loader/sysResource.js`）：
          // `bookshelf: 125832876`。⚠️ 不要写 `books_vertical` —— 那个名字**不存在**，
          // 全表只有 `books_vertical_fill: 125832873`（`arkts_check` 会报 resource-name-check）。
          SymbolGlyph($r('sys.symbol.bookshelf'))
            .fontSize(34)
            .fontColor([ShelfColors.textSub()])
          Text('还没有阅读记录')
            .fontSize(15)
            .fontWeight(600)
            .fontColor(ShelfColors.textMain())
          Text('展开手机，去书架挑一本书')
            .fontSize(12)
            .fontColor(ShelfColors.textSub())
            .textAlign(TextAlign.Center)
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .padding({ left: 20, right: 20 })
      } else {
        // ── 有书：封面 + 书名 + 继续阅读 ──────────────────────────────────
        Column({ space: 14 }) {
          Image(resolveBookCover(this.book!))
            .width(COVER_W)
            .height(COVER_W * 4 / 3)
            .borderRadius(coverCorners(COVER_W))
            .objectFit(ImageFit.Cover)
            .draggable(false)
            .shadow({ radius: 12, color: 'rgba(0, 0, 0, 0.16)', offsetX: 0, offsetY: 4 })

          Column({ space: 4 }) {
            Text(this.title())
              .fontSize(15)
              .fontWeight(600)
              .fontColor(ShelfColors.textMain())
              .maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .textAlign(TextAlign.Center)
            Text(this.subtitle())
              .fontSize(11)
              .fontColor(ShelfColors.textSub())
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
          .width('100%')
          .padding({ left: 16, right: 16 })

          Button('继续阅读')
            .fontSize(15)
            .fontWeight(600)
            .height(42)
            .width('78%')
            .backgroundColor($r('app.color.sub_btn_bg'))
            .fontColor($r('app.color.sub_btn_fg'))
            .borderRadius(21)
            .onClick((): void => {
              this.open();
            })
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        // ⚠️ 2026-10-24 刻意**不**在这层挂 `.onClick`。
        //   原本想让"整块可点"更好按，但里面那个 `Button` 已有 `onClick`，
        //   父容器再挂一个会在一次点击里触发两次 `open()` ⇒ 连推两个阅读页。
        //   命中区已经够大（封面 104vp + 书名 + 78% 宽的按钮），不需要额外扩。
      }

      // ── 底部一行提示：说明"这里不是完整功能"，避免用户以为 App 坏了 ──────
      Text('展开手机使用完整功能')
        .fontSize(10)
        .fontColor(ShelfColors.textSub())
        .opacity(0.8)
        .margin({ bottom: 14 })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(ShelfColors.pageBg())
    .justifyContent(FlexAlign.Center)
  }
}

export default OuterHomeCard;
