/**
 * **PDF 图片阅读页**（2026-10-19 第二轮决策）。
 *
 * 为什么自研而不是复用 `ReaderPage3`：见 `PdfPageCache.ets` 头注释与
 * `docs/PDF支持方案决策-2026-10-19.md §12` —— ReaderKit 会把页图画成 1/3.375（屏幕密度）大小，
 * 7 种写法都改不掉；用户已预先认可"那就做一个我们自己的图片阅读器，随便放大缩小"。
 *
 * 能力（这一版）：
 *  · 左右翻页：**点击屏幕左右三分之一** 或 **横滑**；
 *  · 缩放：**双指 pinch**（1x~5x）、**双击**在 1x / 2x 间切换；放大后**单指拖动**平移，边界自动回弹；
 *  · 进度：顶栏显示 `当前页 / 总页`，翻页即写库（`Books.durChapterIndex`），下次进书恢复到该页；
 *  · 首次打开：逐页渲染并显示进度（真机实测 ≈53ms/页）。
 *
 * 与其它格式的关系：PDF 走本页；DOCX 走 epub + ReaderKit（文字重排效果好）；DOC 走系统预览。
 */
import { router } from '@kit.ArkUI';
import { fileUri } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { Books } from '../../../database/entities/Books';
import BooksDao from '../../../database/dao/BooksDao';
import { PdfPageCache, PdfPageMeta, PdfRenderProgress } from '../../../common/format/PdfPageCache';
import { Haptics } from '../../../common/utils/Haptics';

const MIN_SCALE: number = 1.0;
const MAX_SCALE: number = 5.0;

@Entry
@Component
struct PdfReaderPage {
  @State book: Books = new Books();
  @State total: number = 0;
  @State pageIndex: number = 0;
  @State prepText: string = '';
  @State errorMsg: string = '';
  @State ready: boolean = false;
  @State imgSrc: string = '';
  /** 缩放/平移 */
  @State zoom: number = 1;
  @State offsetX: number = 0;
  @State offsetY: number = 0;
  private baseZoom: number = 1;
  private baseOffsetX: number = 0;
  private baseOffsetY: number = 0;
  private lastTapMs: number = 0;
  private saveTick: number = 0;
  /** 页图宽高比（= meta.width / meta.height），显式给 Image 定比例，避免位图被当成 vp 尺寸画小 */
  @State imgAspect: number = 0.773;
  @State areaW: number = 0;

  aboutToAppear(): void {
    try {
      const p = router.getParams();
      if (p !== undefined && p !== null) {
        this.book = p as Books;
      }
    } catch (e) {
      // 忽略：拿不到参数就按错误卡处理
    }
    this.load();
  }

  aboutToDisappear(): void {
    this.persistProgress();
  }

  private async load(): Promise<void> {
    const src: string = this.book.bookUrl ?? '';
    if (src.length === 0) {
      this.errorMsg = '这本书没有可读的文件';
      return;
    }
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    try {
      this.prepText = '正在准备 PDF…';
      const meta: PdfPageMeta | null = await PdfPageCache.ensure(ctx, this.book,
        (p: PdfRenderProgress) => {
          this.prepText = '正在准备 PDF… ' + p.done + '/' + p.total;
        });
      if (meta === null) {
        this.prepText = '';
        this.errorMsg = 'PDF 解析失败（可能已加密或文件损坏）';
        return;
      }
      this.total = meta.total;
      if (meta.width > 0 && meta.height > 0) {
        this.imgAspect = meta.width / meta.height;
      }
      // 恢复上次页码
      let idx: number = this.book.durChapterIndex ?? 0;
      if (idx < 0) {
        idx = 0;
      }
      if (idx >= this.total) {
        idx = this.total - 1;
      }
      this.pageIndex = idx;
      this.prepText = '';
      this.ready = true;
      this.applyImage();
    } catch (e) {
      this.prepText = '';
      this.errorMsg = 'PDF 打开失败：' + (e instanceof Error ? e.message : String(e));
    }
  }

  private ctx(): common.UIAbilityContext {
    return this.getUIContext().getHostContext() as common.UIAbilityContext;
  }

  private applyImage(): void {
    const p: string = PdfPageCache.pagePath(this.ctx(), this.book, this.pageIndex);
    this.imgSrc = fileUri.getUriFromPath(p);
    this.resetZoom();
  }

  private resetZoom(): void {
    this.zoom = 1;
    this.baseZoom = 1;
    this.offsetX = 0;
    this.offsetY = 0;
    this.baseOffsetX = 0;
    this.baseOffsetY = 0;
  }

  private goTo(next: number): void {
    if (!this.ready) {
      return;
    }
    if (next < 0 || next >= this.total) {
      return;
    }
    this.pageIndex = next;
    this.applyImage();
    Haptics.tap();
    this.persistProgress();
  }

  private persistProgress(): void {
    if (!this.ready || this.total <= 0) {
      return;
    }
    try {
      this.book.durChapterIndex = this.pageIndex;
      this.book.durChapterTime = Date.now();
      BooksDao.partialUpdate(this.book).catch((e: Error): void => {
        console.error('pdf progress save failed: ' + e.message);
      });
    } catch (e) {
      // 忽略
    }
  }

  private close(): void {
    try {
      router.back();
    } catch (e) {
      console.error('pdf reader back failed');
    }
  }

  @Builder
  TopBar() {
    Row({ space: 12 }) {
      Text('‹')
        .fontSize(28)
        .width(44)
        .height(44)
        .textAlign(TextAlign.Center)
        .fontColor($r('app.color.text_primary'))
        .onClick(() => {
          this.close();
        })
      Column({ space: 2 }) {
        Text(this.book.bookName ?? 'PDF')
          .fontSize(15)
          .fontWeight(600)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .fontColor($r('app.color.text_primary'))
        Text(this.ready ? ('第 ' + (this.pageIndex + 1) + ' / ' + this.total + ' 页'
          + (this.zoom > 1.01 ? ('  ·  ' + this.zoom.toFixed(1) + 'x') : '')) : '准备中')
          .fontSize(11)
          .fontColor($r('app.color.text_secondary'))
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      Text('1x')
        .fontSize(12)
        .fontColor($r('app.color.text_secondary'))
        .onClick(() => {
          this.resetZoom();
        })
    }
    .width('100%')
    .height(52)
    .padding({ left: 8, right: 16 })
    .backgroundColor($r('app.color.card_bg'))
  }

  build() {
    Column() {
      this.TopBar()
      Stack({ alignContent: Alignment.Center }) {
        if (this.errorMsg.length > 0) {
          Column({ space: 12 }) {
            Text(this.errorMsg)
              .fontSize(14)
              .textAlign(TextAlign.Center)
              .fontColor($r('app.color.text_secondary'))
              .padding({ left: 32, right: 32 })
            Button('返回')
              .fontSize(14)
              .height(40)
              .width(140)
              .backgroundColor($r('app.color.sub_btn_bg'))
              .fontColor($r('app.color.sub_btn_fg'))
              .onClick(() => {
                this.close();
              })
          }
        } else if (!this.ready) {
          Column({ space: 14 }) {
            LoadingProgress().width(48).height(48).color($r('app.color.text_secondary'))
            Text(this.prepText).fontSize(13).fontColor($r('app.color.text_secondary'))
            Text('首次打开会为每一页生成页面图，之后秒开')
              .fontSize(11)
              .fontColor($r('app.color.text_tertiary'))
          }
        } else {
          // ⚠️ 2026-10-19 真机实测：`ImagePacker` 产出的位图没有"密度"信息，ArkUI 会把它按 **vp**
          // 解读（1320px 的页图被当成 1320vp），再 `Contain` 到 391vp 宽的内容区 ⇒ 只画到 1/3.375。
          // 解法：用 `width('100%') + aspectRatio(页图宽高比)` 显式定框，`Contain` 只负责在框内等比铺满。
          Image(this.imgSrc)
            .objectFit(ImageFit.Contain)
            .width('100%')
            .aspectRatio(this.imgAspect)
            .scale({ x: this.zoom, y: this.zoom })
            .translate({ x: this.offsetX, y: this.offsetY })
        }
      }
      .width('100%')
      .layoutWeight(1)
      .backgroundColor($r('app.color.page_bg'))
      .onAreaChange((_old: Area, now: Area) => {
        this.areaW = Number(now.width);
      })
      .gesture(
        GestureGroup(GestureMode.Parallel,
          // 双指缩放
          PinchGesture({ fingers: 2 })
            .onActionStart(() => {
              this.baseZoom = this.zoom;
            })
            .onActionUpdate((event: GestureEvent) => {
              const s: number = this.baseZoom * event.scale;
              this.zoom = s < MIN_SCALE ? MIN_SCALE : (s > MAX_SCALE ? MAX_SCALE : s);
            })
            .onActionEnd(() => {
              this.baseZoom = this.zoom;
              if (this.zoom <= MIN_SCALE + 0.02) {
                this.resetZoom();
              }
            }),
          // 放大后单指拖动
          PanGesture({ fingers: 1, distance: 12 })
            .onActionStart(() => {
              this.baseOffsetX = this.offsetX;
              this.baseOffsetY = this.offsetY;
            })
            .onActionUpdate((event: GestureEvent) => {
              if (this.zoom > MIN_SCALE + 0.01) {
                this.offsetX = this.baseOffsetX + event.offsetX;
                this.offsetY = this.baseOffsetY + event.offsetY;
              }
            })
            .onActionEnd(() => {
              if (this.zoom <= MIN_SCALE + 0.01) {
                this.offsetX = 0;
                this.offsetY = 0;
              }
            }),
          // 横滑翻页（未放大时）
          SwipeGesture({ direction: SwipeDirection.Horizontal, speed: 60 })
            .onAction((event: GestureEvent) => {
              if (this.zoom > MIN_SCALE + 0.01) {
                return;
              }
              if (event.angle > 90 && event.angle < 270) {
                this.goTo(this.pageIndex - 1);
              } else {
                this.goTo(this.pageIndex + 1);
              }
            }),
          // 单击左右翻页 / 双击缩放
          TapGesture({ count: 1 })
            .onAction((event: GestureEvent) => {
              const now: number = Date.now();
              if (now - this.lastTapMs < 260) {
                // 双击：1x <-> 2x
                if (this.zoom > 1.01) {
                  this.resetZoom();
                } else {
                  this.zoom = 2;
                  this.baseZoom = 2;
                }
                this.lastTapMs = 0;
                return;
              }
              this.lastTapMs = now;
              if (this.zoom > MIN_SCALE + 0.01) {
                return;
              }
              const x: number = event.fingerList.length > 0 ? event.fingerList[0].localX : 0;
              // localX 是相对本组件的 vp 坐标；用 `areaW`（onAreaChange 量到的内容区宽度）判 1/3、2/3 热区
              const w: number = this.areaW > 0 ? this.areaW : 400;
              if (x < w / 3) {
                this.goTo(this.pageIndex - 1);
              } else if (x > w * 2 / 3) {
                this.goTo(this.pageIndex + 1);
              }
            })
        )
      )
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_bg'))
  }
}
