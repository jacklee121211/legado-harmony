/**
 * PDF 页图缓存（供**自研图片阅读页**使用，2026-10-19 第二轮决策）。
 *
 * ── 为什么不再走 epub ──────────────────────────────────────────────────────
 * 真机实测（docs/PDF支持方案决策-2026-10-19.md §12）：把页图塞进 epub 交给 ReaderKit 排版时，
 * 引擎会把页图画成约 **1/3.375**（= 屏幕密度）大小 —— 它的内部排版单位是 vp
 * （日志 `target offset 391.11 = 1320/3.375`、`pageWidth 391vp`），文字按密度放大、图片不放大。
 * 试过 7 种写法（width:100% / 无宽高 / 显式 px / 内联 style / JFIF 96dpi / 去 ICC / PNG）全部无效。
 * ⇒ PDF 改为**我们自己渲染页面图 + 自己做阅读页**（用户已预先认可该"保守方案"），
 *   DOCX 仍走 epub（文字重排效果已被真机证明很好）。
 *
 * 产物（都在 filesDir 下，删目录即清）：
 * ```
 * fmt_cache/<bookId>_<size>_<mtime>_<VER>/pages/p0001.jpg … pNNNN.jpg
 * fmt_cache/<bookId>_<size>_<mtime>_<VER>/pages/meta.json   {"total":n,"width":w,"height":h}
 * ```
 * 渲染参数与 `PdfImporter` 一致（`getAreaPixelMapWithOptions` 按目标像素 + `ImagePacker` JPEG）。
 */
import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { display } from '@kit.ArkUI';
import { pdfService } from '@kit.PDFKit';
import { image } from '@kit.ImageKit';
import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { Books } from '../../database/entities/Books';
import { FMT_CACHE_DIR, FMT_CACHE_VER, FMT_PDF_JPEG_QUALITY } from './FormatFlags';

const DOMAIN: number = 0x0000;
const TAG: string = 'PdfPageCache';

export interface PdfPageMeta {
  total: number;
  width: number;
  height: number;
}

export interface PdfRenderProgress {
  done: number;
  total: number;
}

export class PdfPageCache {
  /** 页图目录（不存在就建） */
  static dirFor(ctx: common.UIAbilityContext, book: Books): string {
    const src: string = book.bookUrl ?? '';
    let size: number = 0;
    let mtime: number = 0;
    try {
      const st = fs.statSync(src);
      size = st.size;
      mtime = Math.floor(st.mtime);
    } catch (e) {
      size = 0;
      mtime = 0;
    }
    return ctx.filesDir + '/' + FMT_CACHE_DIR + '/' + (book.id ?? -1) + '_' + size + '_' + mtime
      + '_' + FMT_CACHE_VER + '/pages';
  }

  static pagePath(ctx: common.UIAbilityContext, book: Books, index: number): string {
    let s: string = String(index + 1);
    while (s.length < 4) {
      s = '0' + s;
    }
    return PdfPageCache.dirFor(ctx, book) + '/p' + s + '.jpg';
  }

  private static ensureDir(path: string): void {
    try {
      if (!fs.accessSync(path)) {
        fs.mkdirSync(path, true);
      }
    } catch (e) {
      try {
        fs.mkdirSync(path, true);
      } catch (e2) {
        hilog.error(DOMAIN, TAG, 'mkdir failed');
      }
    }
  }

  /** 读缓存元信息；没有/不完整 ⇒ null */
  static readMeta(ctx: common.UIAbilityContext, book: Books): PdfPageMeta | null {
    const dir: string = PdfPageCache.dirFor(ctx, book);
    const metaPath: string = dir + '/meta.json';
    try {
      if (!fs.accessSync(metaPath)) {
        return null;
      }
      const st = fs.statSync(metaPath);
      const buf: ArrayBuffer = new ArrayBuffer(st.size);
      const f = fs.openSync(metaPath, fs.OpenMode.READ_ONLY);
      try {
        fs.readSync(f.fd, buf);
      } finally {
        fs.closeSync(f);
      }
      const json: string = util.TextDecoder.create('utf-8', { ignoreBOM: true })
        .decodeToString(new Uint8Array(buf));
      const m: PdfPageMeta = JSON.parse(json) as PdfPageMeta;
      if (m.total <= 0) {
        return null;
      }
      // 抽查首页是否存在（防止渲染到一半被杀的残缓存）
      if (!fs.accessSync(PdfPageCache.pagePath(ctx, book, 0))) {
        return null;
      }
      if (!fs.accessSync(PdfPageCache.pagePath(ctx, book, m.total - 1))) {
        return null;
      }
      return m;
    } catch (e) {
      return null;
    }
  }

  /**
   * 按需渲染**单页**（供阅读器里的"双击放大"用，2026-10-19）。
   *
   * 为什么单独一条路：`ensure()` 会把全本渲染一遍（300 页≈16s），只为一页放大不值当。
   * 这里只渲染请求的那一页，落盘到 `…/zoom/zNNNN_<宽>.jpg`，二次放大直接命中缓存。
   * 失败返回空串（调用方给提示，不崩）。
   */
  static async renderOne(ctx: common.UIAbilityContext, book: Books, index: number,
    widthPx: number): Promise<string> {
    const baseDir: string = PdfPageCache.dirFor(ctx, book);
    const zoomDir: string = baseDir + '/zoom';
    PdfPageCache.ensureDir(zoomDir);
    let s: string = String(index + 1);
    while (s.length < 4) {
      s = '0' + s;
    }
    const out: string = zoomDir + '/z' + s + '_' + Math.round(widthPx) + '.jpg';
    try {
      if (fs.accessSync(out)) {
        return out;
      }
    } catch (e) {
      // 没缓存 ⇒ 继续渲染
    }
    const doc: pdfService.PdfDocument = new pdfService.PdfDocument();
    try {
      const r: pdfService.ParseResult = doc.loadDocument(book.bookUrl ?? '');
      if (r !== pdfService.ParseResult.PARSE_SUCCESS) {
        return '';
      }
      const total: number = doc.getPageCount();
      if (index < 0 || index >= total) {
        doc.releaseDocument();
        return '';
      }
      const page: pdfService.PdfPage = doc.getPage(index);
      const pw: number = page.getWidth();
      const ph: number = page.getHeight();
      const tw: number = Math.max(200, Math.round(widthPx));
      const th: number = Math.max(1, Math.round(tw * ph / Math.max(1, pw)));
      // 与 ensure() 同一约定：matrix 的宽高是**缩放比**（SDK d.ts 原文），后两参才是画布像素。
      const zoom: number = tw / Math.max(1, pw);
      const mx: pdfService.PdfMatrix = new pdfService.PdfMatrix();
      mx.x = 0;
      mx.y = 0;
      mx.width = pw * zoom;
      mx.height = ph * zoom;
      mx.rotate = 0;
      const pm: image.PixelMap = page.getAreaPixelMapWithOptions(mx, tw, th);
      const packer: image.ImagePacker = image.createImagePacker();
      const opt: image.PackingOption = { format: 'image/jpeg', quality: FMT_PDF_JPEG_QUALITY };
      const bytes: ArrayBuffer = await packer.packToData(pm, opt);
      await pm.release();
      page.release();
      doc.releaseDocument();
      const f = fs.openSync(out, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(f.fd, bytes);
      } finally {
        fs.closeSync(f);
      }
      hilog.info(DOMAIN, TAG, 'renderOne page=%{public}d w=%{public}d', index + 1, tw);
      return out;
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'renderOne failed: %{public}s', JSON.stringify(e));
      try {
        doc.releaseDocument();
      } catch (e2) {
        // 忽略
      }
      return '';
    }
  }

  /**
   * 确保页图已渲染；已缓存直接返回元信息。
   * 渲染宽度取「屏幕物理宽度」（真机 1320），即 1 图像像素 = 1 物理像素，清晰度最好。
   */
  static async ensure(ctx: common.UIAbilityContext, book: Books,
    onProgress: (p: PdfRenderProgress) => void): Promise<PdfPageMeta | null> {
    const cached: PdfPageMeta | null = PdfPageCache.readMeta(ctx, book);
    if (cached !== null) {
      hilog.info(DOMAIN, TAG, 'cache hit: %{public}d pages', cached.total);
      return cached;
    }
    const dir: string = PdfPageCache.dirFor(ctx, book);
    PdfPageCache.ensureDir(dir);
    const doc: pdfService.PdfDocument = new pdfService.PdfDocument();
    try {
      const r: pdfService.ParseResult = doc.loadDocument(book.bookUrl ?? '');
      if (r !== pdfService.ParseResult.PARSE_SUCCESS) {
        hilog.error(DOMAIN, TAG, 'loadDocument failed code=%{public}d', r);
        return null;
      }
      const total: number = doc.getPageCount();
      if (total <= 0) {
        return null;
      }
      const screenW: number = display.getDefaultDisplaySync().width;
      const targetW: number = screenW > 0 ? screenW : 1320;
      const packer: image.ImagePacker = image.createImagePacker();
      const opt: image.PackingOption = { format: 'image/jpeg', quality: FMT_PDF_JPEG_QUALITY };
      let firstH: number = Math.round(targetW * 792 / 612);
      for (let i = 0; i < total; i++) {
        const page: pdfService.PdfPage = doc.getPage(i);
        const pw: number = page.getWidth();
        const ph: number = page.getHeight();
        const tw: number = targetW;
        const th: number = Math.max(1, Math.round(tw * ph / Math.max(1, pw)));
        // ⚠️ 2026-10-19 真机实证（关键）：`PdfMatrix.width/height` 是**相对原始页的缩放比**，
        // `getAreaPixelMapWithOptions` 的后两个参数只是**画布像素尺寸**。
        // 旧写法把 matrix 传成原始点尺寸（=缩放 1），结果 612×792pt 的内容 1:1 画进 1320×1708 画布
        // ⇒ 内容只占左上角约 46%，看起来像"整页被缩成 1/3"（真机把图拉回来一看就发现了）。
        // 正确写法：matrix 传 `页尺寸 × 缩放比`，画布传目标像素。
        const zoom: number = tw / Math.max(1, pw);
        const mx: pdfService.PdfMatrix = new pdfService.PdfMatrix();
        mx.x = 0;
        mx.y = 0;
        mx.width = pw * zoom;
        mx.height = ph * zoom;
        mx.rotate = 0;
        const pm: image.PixelMap = page.getAreaPixelMapWithOptions(mx, tw, th);
        const bytes: ArrayBuffer = await packer.packToData(pm, opt);
        await pm.release();
        page.release();
        if (i === 0) {
          firstH = th;
        }
        const out: string = PdfPageCache.pagePath(ctx, book, i);
        const f = fs.openSync(out, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
        try {
          fs.writeSync(f.fd, bytes);
        } finally {
          fs.closeSync(f);
        }
        if (onProgress !== undefined) {
          onProgress({ done: i + 1, total: total });
        }
      }
      doc.releaseDocument();
      const meta: PdfPageMeta = { total: total, width: targetW, height: firstH };
      const metaPath: string = dir + '/meta.json';
      const f2 = fs.openSync(metaPath, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      try {
        const enc = new util.TextEncoder();
        const arr: Uint8Array = enc.encodeInto(JSON.stringify(meta));
        fs.writeSync(f2.fd, arr.buffer as ArrayBuffer);
      } finally {
        fs.closeSync(f2);
      }
      hilog.info(DOMAIN, TAG, 'rendered %{public}d pages at w=%{public}d', total, targetW);
      return meta;
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'render failed: %{public}s', JSON.stringify(e));
      try {
        doc.releaseDocument();
      } catch (e2) {
        // 忽略
      }
      return null;
    }
  }
}
