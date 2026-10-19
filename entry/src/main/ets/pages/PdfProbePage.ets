/**
 * ⚠️ POC 取证页（2026-10-19）：验证 ReaderKit 能否把「PDF 页面渲染图」当书页排版。
 *
 * 取证目标（对应 docs/PDF支持方案决策-2026-10-19.md §7）：
 *   POC-1  页图版 epub 能不能正常排版/翻页/出目录
 *   POC-4  epub 内部图片是否走 `on('resourceRequest')`（日志里有无该行）
 *   附带   BookInfo（标题/封面）、catalog、spine、getAbsoluteResourcePath、getResourceContent、
 *          getSpineItemContent 的实际返回，以及夜间模式下页图的观感
 *
 * 用到的 API 均为官方声明：
 *   @hms.core.readerservice.bookParser.d.ts:418 getDefaultHandler(path)
 *   @hms.core.readerservice.bookParser.d.ts:102 getResourceContent(spineIndex, filePath)
 *   @hms.core.readerservice.readerComponent.d.ets:223/242/257/271/294/308/336
 */
import { bookParser, readerCore, ReadPageComponent } from '@kit.ReaderKit';
import { pdfService } from '@kit.PDFKit';
import { image } from '@kit.ImageKit';
import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { display } from '@kit.ArkUI';
import { uniformTypeDescriptor } from '@kit.ArkData';
import { FileHandler } from '../common/utils/FileHandler';
import { PdfImporter, ConvertProgress, ConvertResult } from '../common/format/PdfImporter';
import DbUtil from '../common/utils/DbUtil';
import booksDao from '../database/dao/BooksDao';
import { Books } from '../database/entities/Books';
import DataBase from '../database';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';

const DOMAIN: number = 0x0000;
const TAG: string = 'PdfProbe';
const EPUB_NAME: string = 'poc_pages.epub';
const PDF_NAME: string = 'poc_sample.pdf';
/**
 * A/B 对照开关（2026-10-19）：true ⇒ 探针**一开始就**打开"PDF 转出来的 epub"，
 * 用来判断"页图被缩成 1/3.375"到底是**引擎对图片的处理**，还是 `ReaderPage3` 的 readerSetting/图层造成。
 * 两种模式共用同一份 setting（viewPort=屏幕物理像素、scaledDensity=屏幕值），只有 epub 不同。
 */
const PROBE_OPEN_PDF: boolean = true;

@Entry
@Component
struct PdfProbePage {
  @State status: string = '启动中…';
  @State lines: string[] = [];
  @State ready: boolean = false;
  @State night: boolean = false;
  @State pageNo: string = '';
  @State pdfInfo: string = '';
  /** 转页进度（playPdfEpub 用） */
  @State prepNote: string = '';
  @State showPdf: boolean = false;
  @State pdfPm: image.PixelMap | undefined = undefined;
  @State pdfPm2: image.PixelMap | undefined = undefined;

  private controller: readerCore.ReaderComponentController = new readerCore.ReaderComponentController();
  private handler: bookParser.BookParserHandler | null = null;
  private pdfDoc: pdfService.PdfDocument | null = null;
  private disposed: boolean = false;
  private resourceHits: number = 0;

  private setting: readerCore.ReaderSetting = {
    fontName: '系统字体',
    fontPath: '',
    fontSize: 18,
    fontColor: '#000000',
    fontWeight: 400,
    lineHeight: 1.9,
    nightMode: false,
    themeColor: 'rgba(248, 249, 250, 1)',
    themeBgImg: '',
    flipMode: '0',
    scaledDensity: 1,
    viewPortWidth: 1260,
    viewPortHeight: 2720
  };

  /** 页面内显示最近若干条日志（配合截图取证，日志全文看 hilog） */
  private note(msg: string): void {
    hilog.info(DOMAIN, TAG, '%{public}s', msg);
    const arr: string[] = this.lines.slice();
    arr.push(msg);
    while (arr.length > 7) {
      arr.shift();
    }
    this.lines = arr;
  }

  aboutToAppear(): void {
    this.bootstrap();
  }

  aboutToDisappear(): void {
    this.disposed = true;
    try {
      this.controller.off('pageShow');
      this.controller.off('resourceRequest');
      this.controller.releaseBook();
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'release err %{public}s', JSON.stringify(e));
    }
    try {
      if (this.pdfDoc !== null) {
        this.pdfDoc.releaseDocument();
        this.pdfDoc = null;
      }
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'pdf release err %{public}s', JSON.stringify(e));
    }
  }

  private async bootstrap(): Promise<void> {
    try {
      const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const disp: display.Display = display.getDefaultDisplaySync();
      this.setting.scaledDensity = disp.scaledDensity > 0 ? disp.scaledDensity : 1;
      this.setting.viewPortWidth = disp.width;
      this.setting.viewPortHeight = disp.height;
      this.note(`屏幕 ${disp.width}x${disp.height}(px) density=${disp.densityPixels} scaled=${disp.scaledDensity}`);

      // 取证：分享/导入要靠"后缀 → UTD"映射，这里把要用的后缀全打出来（决定分享面板能否出现喵阅）
      this.note('UTD .pdf=' + (uniformTypeDescriptor.getUniformDataTypeByFilenameExtension('.pdf') ?? 'null')
        + ' .docx=' + (uniformTypeDescriptor.getUniformDataTypeByFilenameExtension('.docx') ?? 'null')
        + ' .doc=' + (uniformTypeDescriptor.getUniformDataTypeByFilenameExtension('.doc') ?? 'null')
        + ' .epub=' + (uniformTypeDescriptor.getUniformDataTypeByFilenameExtension('.epub') ?? 'null'));

      const path: string = PROBE_OPEN_PDF ? await this.ensurePdfEpub(ctx) : await this.copyAsset(ctx);
      this.note('沙箱路径 ' + path);

      // ① 解析器
      this.handler = await bookParser.getDefaultHandler(path);
      const info: bookParser.BookInfo = this.handler.getBookInfo();
      this.note(`BookInfo title=${info.bookTitle} cover=${info.bookCoverImage ?? 'null'} type=${info.bookType ?? 'null'}`);
      const cats: bookParser.CatalogItem[] = this.handler.getCatalogList();
      this.note('catalog=' + cats.length + ' → ' + cats.slice(0, 4).map((c: bookParser.CatalogItem) => c.catalogName).join(' / '));
      const spines: bookParser.SpineItem[] = this.handler.getSpineList();
      this.note('spine=' + spines.length + ' → ' + spines.slice(0, 4).map((s: bookParser.SpineItem) => s.href).join(' / '));
      if (spines.length > 0) {
        this.note('spine[0] absPath=' + this.handler.getAbsoluteResourcePath(0));
        // 诊断用：拿图片字节。v1 样本返回过 234927B，v2 样本返回 undefined（原生侧行为不一致）
        // ⇒ 这里必须自我防御，不能因为它中断整条链路。
        try {
          const img: ArrayBuffer = this.handler.getResourceContent(0, 'images/p1.jpg');
          this.note('getResourceContent(0,images/p1.jpg)=' + (img ? img.byteLength : -1) + 'B');
        } catch (e) {
          this.note('getResourceContent 抛错（忽略）：' + JSON.stringify(e));
        }
        const body: string = await this.handler.getSpineItemContent(0);
        this.note('spineContent[0] len=' + body.length + ' 头=' + body.substring(0, 90).replace(/\n/g, ' '));
      }

      // ② 监听（POC-4：epub 内部图片是否会走这里）
      this.controller.on('resourceRequest', (filePath: string): ArrayBuffer => {
        this.resourceHits++;
        hilog.info(DOMAIN, TAG, 'resourceRequest#%{public}d: %{public}s', this.resourceHits, filePath);
        return new ArrayBuffer(0);
      });
      this.controller.on('pageShow', (data: readerCore.PageDataInfo): void => {
        hilog.info(DOMAIN, TAG, 'pageShow state=%{public}d res=%{public}d domPos=%{public}s',
          data.state, data.resourceIndex, data.startDomPos);
        if (data.state === readerCore.PageState.PAGE_ON_SHOW) {
          this.ready = true;
          this.status = `已排版 · 资源回调 ${this.resourceHits} 次`;
          this.pageNo = `resourceIndex=${data.resourceIndex}`;
        }
      });

      // ③ 按官方「构建阅读器」顺序：init → handler → registerBookParser → setPageConfig → startPlay
      await this.controller.init(ctx);
      if (this.disposed) {
        return;
      }
      this.controller.registerBookParser(this.handler);
      this.controller.setPageConfig(this.setting);
      await this.controller.startPlay(0, '');
      this.note('startPlay 已调用');
      this.status = '排版中…';
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(DOMAIN, TAG, 'bootstrap failed: code=%{public}d msg=%{public}s',
        err.code ?? -1, err.message ?? JSON.stringify(e));
      this.status = '失败：' + (err.message ?? JSON.stringify(e));
    }
  }

  /**
   * A/B 对照：用 `PdfImporter` 把 rawfile 的 PDF 转成 epub（走生产同一套代码），
   * 每轮覆盖生成，保证和产品链路一致。
   */
  private async ensurePdfEpub(ctx: common.UIAbilityContext): Promise<string> {
    const pdfPath: string = ctx.filesDir + '/probe_ab.pdf';
    const outEpub: string = ctx.filesDir + '/probe_ab.epub';
    const v: Uint8Array = ctx.resourceManager.getRawFileContentSync('pocpdf.pdf');
    const f = fs.openSync(pdfPath, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    try {
      fs.writeSync(f.fd, v.buffer as ArrayBuffer);
    } finally {
      fs.closeSync(f);
    }
    try {
      fs.unlinkSync(outEpub);
    } catch (e) {
      // 不存在则忽略
    }
    this.note('A/B：开始生成 PDF epub');
    const res: ConvertResult = await PdfImporter.convert(pdfPath, outEpub, 'probe-ab', 'poc',
      (p: ConvertProgress) => {
        this.note('A/B 转页 ' + p.done + '/' + p.total);
      });
    this.note('A/B 生成 ok=' + res.ok + ' pages=' + res.pages + ' ' + res.message);
    return outEpub;
  }

  /** 把 rawfile 里的 POC epub 拷进沙箱（ReaderKit 只吃沙箱路径）。每次覆盖，便于换样本迭代。 */  private async copyAsset(ctx: common.UIAbilityContext): Promise<string> {
    const dst: string = ctx.filesDir + '/' + EPUB_NAME;
    const v: Uint8Array = ctx.resourceManager.getRawFileContentSync(EPUB_NAME);
    const f = fs.openSync(dst, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    try {
      fs.writeSync(f.fd, v.buffer as ArrayBuffer);
    } finally {
      fs.closeSync(f);
    }
    const st = fs.statSync(dst);
    this.note(`${EPUB_NAME} → ${st.size} 字节`);
    return dst;
  }

  private flip(next: boolean): void {
    try {
      this.controller.flipPage(next);
      this.note('flipPage(' + next + ')');
    } catch (e) {
      this.note('flipPage err ' + JSON.stringify(e));
    }
  }

  /**
   * PDF 链路实测（POC-2）：rawfile 里的样本 PDF → 落沙箱 → pdfService 解析/渲染 → 编码 JPEG → 落盘。
   * 取证点：解析耗时、页数/页面尺寸、1x 与 2x 渲染的像素尺寸与耗时、JPEG 体积。
   */
  private async testPdf(): Promise<void> {
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    try {
      const pdfPath: string = ctx.filesDir + '/' + PDF_NAME;
      const v: Uint8Array = ctx.resourceManager.getRawFileContentSync(PDF_NAME);
      const f = fs.openSync(pdfPath, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(f.fd, v.buffer as ArrayBuffer);
      } finally {
        fs.closeSync(f);
      }
      this.note('PDF 落盘 ' + v.byteLength + 'B');

      if (this.pdfDoc !== null) {
        this.pdfDoc.releaseDocument();
        this.pdfDoc = null;
      }
      const t0: number = Date.now();
      const doc: pdfService.PdfDocument = new pdfService.PdfDocument();
      const r: pdfService.ParseResult = doc.loadDocument(pdfPath);
      const t1: number = Date.now();
      this.pdfDoc = doc;
      const cnt: number = doc.getPageCount();
      const p0: pdfService.PdfPage = doc.getPage(0);
      const pw: number = p0.getWidth();
      const ph: number = p0.getHeight();
      this.note(`load=${t1 - t0}ms result=${r} pages=${cnt} page0=${pw.toFixed(1)}x${ph.toFixed(1)}pt`);

      const t2: number = Date.now();
      const pm1: image.PixelMap = p0.getPagePixelMap();
      const i1: image.ImageInfo = pm1.getImageInfoSync();
      const t3: number = Date.now();

      const m: pdfService.PdfMatrix = new pdfService.PdfMatrix();
      m.x = 0;
      m.y = 0;
      m.width = pw;
      m.height = ph;
      m.rotate = 0;
      const t4: number = Date.now();
      const pm2: image.PixelMap = p0.getAreaPixelMapWithOptions(m, Math.round(pw * 2), Math.round(ph * 2));
      const i2: image.ImageInfo = pm2.getImageInfoSync();
      const t5: number = Date.now();
      this.note(`1x=${i1.size.width}x${i1.size.height}(${t3 - t2}ms) 2x=${i2.size.width}x${i2.size.height}(${t5 - t4}ms)`);

      const packer: image.ImagePacker = image.createImagePacker();
      const opt: image.PackingOption = { format: 'image/jpeg', quality: 85 };
      const t6: number = Date.now();
      const ab: ArrayBuffer = await packer.packToData(pm2, opt);
      const t7: number = Date.now();
      this.note(`packToData(jpeg85)=${ab.byteLength}B ${t7 - t6}ms`);
      const imgFile: string = ctx.filesDir + '/pdf_p0_2x.jpg';
      const g = fs.openSync(imgFile, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(g.fd, ab);
      } finally {
        fs.closeSync(g);
      }
      this.note('落盘 ' + fs.statSync(imgFile).size + 'B');

      this.pdfInfo = `pages=${cnt} 1x=${i1.size.width}x${i1.size.height} 2x=${i2.size.width}x${i2.size.height} jpeg=${ab.byteLength}B`;
      this.pdfPm = pm1;
      this.pdfPm2 = pm2;
      this.showPdf = true;
      this.note('PDF 测试完成');
    } catch (e) {
      const err = e as BusinessError;
      this.note('PDF 测试失败 code=' + (err.code ?? -1) + ' msg=' + (err.message ?? JSON.stringify(e)));
    }
  }

  /**
   * 用**生产链路**导入样本：rawfile → cacheDir → `FileHandler.CopyFile()`（与 picker/分享完全同一条）。
   * 目的：验证"导入即建库 + 封面生成"，之后去书架点开就是真实阅读路径。
   */
  private async importSamples(): Promise<void> {
    try {
      const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      // ⚠️ ProbeAbility 不经过 EntryAbility.onWindowStageCreate ⇒ 这里必须自己把库建好，
      //    否则 `FileHandler.CopyFile` 里的写库会失败（第一次试跑就是这么挂的：拷贝和封面都成功，
      //    但 `booksUtil.addBooks` 拿不到 rdbStore）。
      await DbUtil.initDB(ctx);
      await DataBase.initAllTable();
      this.note('DB 就绪');
      const names: string[] = ['pocpdf.pdf', 'pocdocx.docx', 'pocdoc.doc', 'pocimg.docx'];
      for (const n of names) {
        const cachePath: string = ctx.cacheDir + '/' + n;
        const bytes: Uint8Array = ctx.resourceManager.getRawFileContentSync(n);
        const f = fs.openSync(cachePath, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
        try {
          fs.writeSync(f.fd, bytes.buffer as ArrayBuffer);
        } finally {
          fs.closeSync(f);
        }
        const ok: boolean = await FileHandler.CopyFile(cachePath, 0);
        this.note('CopyFile(' + n + ')=' + ok);
      }
      this.note('样本导入完成，去书架看');
    } catch (e) {
      this.note('导入样本失败 ' + JSON.stringify(e));
    }
  }

  /**
   * 在**探针自己的** ReaderKit 管线里打开"PDF 转出来的 epub"。
   * 目的：把问题一分为二——若这里页图是满宽，说明 epub 没问题、差异在 ReaderPage3 的 readerSetting/图层；
   * 若这里也小，说明问题在 epub 内容本身。
   */
  private async playPdfEpub(): Promise<void> {
    try {
      const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const pdfPath: string = ctx.filesDir + '/pocpdf.pdf';
      const outEpub: string = ctx.filesDir + '/probe_pdf.epub';
      if (!fs.accessSync(pdfPath)) {
        const v: Uint8Array = ctx.resourceManager.getRawFileContentSync('pocpdf.pdf');
        const f = fs.openSync(pdfPath, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
        try {
          fs.writeSync(f.fd, v.buffer as ArrayBuffer);
        } finally {
          fs.closeSync(f);
        }
      }
      this.note('开始转 PDF…');
      const res: ConvertResult = await PdfImporter.convert(pdfPath, outEpub, 'probe-pdf', 'poc',
        (p: ConvertProgress) => {
          this.prepNote = '转页 ' + p.done + '/' + p.total;
        });
      this.note('转换 ok=' + res.ok + ' pages=' + res.pages + ' msg=' + res.message);
      if (!res.ok) {
        return;
      }
      // 重新注册解析器并起播（先释放旧的）
      try {
        this.controller.off('pageShow');
        this.controller.off('resourceRequest');
        this.controller.releaseBook();
      } catch (e) {
        // 忽略
      }
      await this.controller.init(ctx);
      this.handler = await bookParser.getDefaultHandler(outEpub);
      this.controller.registerBookParser(this.handler);
      this.controller.setPageConfig(this.setting);
      await this.controller.startPlay(0, '');
      this.note('已起播 probe_pdf.epub');
    } catch (e) {
      this.note('测 PDF 阅读失败 ' + JSON.stringify(e));
    }
  }

  /**
   * 清理 POC 测试书（书名以 `poc`/`probe` 开头）：删库行 + 刷新书架。
   * 只为把真机书架恢复干净，不碰正式数据。
   */
  private async cleanupTestBooks(): Promise<void> {
    try {
      const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      await DbUtil.initDB(ctx);
      await DataBase.initAllTable();
      const list: Books[] = await booksDao.search(undefined);
      const ids: number[] = [];
      for (const b of list) {
        const name: string = (b.bookName ?? '').toLowerCase();
        if (name.startsWith('poc') || name.startsWith('probe')) {
          ids.push(b.id ?? -1);
        }
      }
      if (ids.length === 0) {
        this.note('没有测试书可清理');
        return;
      }
      await booksDao.deleteBook(ids);
      const tick: number = (AppStorage.get<number>('BOOK_IS_BOOK_REFRESHING') ?? 0) + 1;
      AppStorage.setOrCreate('BOOK_IS_BOOK_REFRESHING', tick);
      this.note('已删除 ' + ids.length + ' 本测试书');
    } catch (e) {
      this.note('清理失败 ' + JSON.stringify(e));
    }
  }

  private toggleNight(): void {
    this.night = !this.night;
    this.setting.nightMode = this.night;
    this.setting.themeColor = this.night ? 'rgba(18, 18, 18, 1)' : 'rgba(248, 249, 250, 1)';
    this.setting.fontColor = this.night ? '#cccccc' : '#000000';
    this.controller.setPageConfig(this.setting);
    this.note('nightMode=' + this.night);
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      ReadPageComponent({
        controller: this.controller,
        readerCallback: (err: BusinessError, data: readerCore.ReaderComponentController) => {
          this.controller = data;
        }
      }).width('100%').height('100%')

      Column({ space: 6 }) {
        Text('PDF 页图 POC' + (this.ready ? ' · 已排版' : ' · 排版中'))
          .fontSize(14).fontWeight(600).fontColor('#ffffff')
        Text(this.status).fontSize(12).fontColor('#ffffff').maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
        if (this.pageNo.length > 0) {
          Text(this.pageNo).fontSize(12).fontColor('#ffee88')
        }
        ForEach(this.lines, (s: string) => {
          Text(s).fontSize(10).fontColor('#cfe8ff').maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        }, (s: string, i: number) => `l-${i}-${s}`)
        Flex({ wrap: FlexWrap.Wrap }) {
          Button('上一页').fontSize(12).height(30).onClick(() => this.flip(false))
          Button('下一页').fontSize(12).height(30).onClick(() => this.flip(true))
          Button(this.night ? '日间' : '夜间').fontSize(12).height(30).onClick(() => this.toggleNight())
          Button('测 PDF 渲染').fontSize(11).height(30).onClick(() => {
            this.testPdf();
          })
          Button('导入样本').fontSize(12).height(30).onClick(() => {
            this.importSamples();
          })
          Button('测 PDF 阅读').fontSize(11).height(30).onClick(() => {
            this.playPdfEpub();
          })
          Button('清理测试书').fontSize(11).height(30).onClick(() => {
            this.cleanupTestBooks();
          })
        }
      }
      .width('100%')
      .padding(10)
      .backgroundColor('rgba(0,0,0,0.62)')
      .alignItems(HorizontalAlign.Start)

      // PDF 渲染结果对比层：左 1x（pdfService 默认分辨率），右 2x（matrix 放大重渲染）
      if (this.showPdf && this.pdfPm !== undefined && this.pdfPm2 !== undefined) {
        Column({ space: 6 }) {
          Row({ space: 8 }) {
            Text(this.pdfInfo).fontSize(11).fontColor('#ffffff').layoutWeight(1).maxLines(2)
            Button('关闭').fontSize(12).height(28).onClick(() => {
              this.showPdf = false;
            })
          }.width('100%')

          Flex({ wrap: FlexWrap.Wrap }) {
            Column({ space: 2 }) {
              Text('1x').fontSize(10).fontColor('#9fe')
              Image(this.pdfPm as image.PixelMap).objectFit(ImageFit.Contain).width('100%').layoutWeight(1)
            }.layoutWeight(1).height('100%')
            Column({ space: 2 }) {
              Text('2x').fontSize(10).fontColor('#9fe')
              Image(this.pdfPm2 as image.PixelMap).objectFit(ImageFit.Contain).width('100%').layoutWeight(1)
            }.layoutWeight(1).height('100%')
          }.width('100%').layoutWeight(1)
        }
        .width('100%')
        .height('100%')
        .padding(8)
        .backgroundColor('rgba(10,10,10,0.97)')
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#FFFFFF')
  }
}
