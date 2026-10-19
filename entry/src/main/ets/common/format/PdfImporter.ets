/**
 * PDF → 页图 epub 转换器（真机 POC 已验证，见 docs/PDF支持方案决策-2026-10-19.md §11）。
 *
 * 流程：
 * ```
 * pdfService.PdfDocument.loadDocument(src)
 *   逐页： getPage(i) → getAreaPixelMapWithOptions(matrix, W, H) → ImagePacker.packToData(JPEG85)
 *          → EpubBuilder.addImage('images/pNNNN.jpg')
 *   每 FMT_PDF_PAGES_PER_CHAPTER 页一章（章节标题 "第 a–b 页"）
 *   首页再存一份 images/cover.jpg 并登记为封面（<meta name="cover">）
 *   EpubBuilder.finish → 得到可被 ReaderKit 直接打开的 .epub
 * ```
 *
 * 实测数据（Mate 80 Pro Max / API 26）：
 *  · `loadDocument` 19ms；单页渲染 20ms（612×792 → 1224×1584）；JPEG85 编码 33ms；
 *  · 2x 页图 JPEG85 ≈ 109KB/页 ⇒ 300 页约 33MB、约 16 秒（本文件按 1400px 宽渲染，体积略增）。
 *
 * ⚠️ PDF Kit 官方约束（`@hms.officeservice.pdfservice.d.ts`）：`releaseDocument()` 后才能再 `loadDocument`；
 *    同一页面对象用完必须 `release()`；加密文档 `loadDocument` 返回 `PARSE_ERROR_PASSWORD(3)`。
 */
import { pdfService } from '@kit.PDFKit';
import { image } from '@kit.ImageKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { EpubBuilder, EpubChapter, EpubImageRef, EpubMeta } from './EpubBuilder';
import { ZipWriter } from './ZipWriter';
import { FMT_PDF_PAGES_PER_CHAPTER, FMT_PDF_RENDER_WIDTH_PX, FMT_PDF_JPEG_QUALITY } from './FormatFlags';

const DOMAIN: number = 0x0000;
const TAG: string = 'PdfImporter';

export interface ConvertProgress {
  done: number;
  total: number;
}

export interface ConvertResult {
  ok: boolean;
  message: string;
  pages: number;
  chapters: number;
}

function pad4(n: number): string {
  let s: string = String(n);
  while (s.length < 4) {
    s = '0' + s;
  }
  return s;
}

export class PdfImporter {
  /**
   * 规范化 `ImagePacker` 产出的 JPEG（真机实测 2026-10-19）。
   *
   * ── 为什么必须做 ────────────────────────────────────────────────────────────
   * 同一个 ReaderKit 环境下的**标定实验**（scripts/poc-pdf/make-calibration-epub.ps1）：
   *   · System.Drawing 生成的 JPEG，1080/1320/1600 三种宽度**都按页宽满屏显示**；
   *   · `ImagePacker` 生成的 JPEG（1320px 宽）却只画到 ≈1/3.375（= 屏幕密度）大小。
   * 两者的可观测差异只在 JPEG 容器头：
   *   ImagePacker 产出 `APP0 JFIF(units=0,1x1)` + **`APP2 ICC_PROFILE`**，而 System.Drawing 只有 JFIF(96dpi)。
   * ⇒ 这里做两件事：① JFIF 密度写成 96dpi(units=1)；② **丢掉 APP2(ICC)/APP14(Adobe)** 段，
   *   只保留 JFIF 与压缩数据（解压出来的像素完全不变，只是不再让引擎按 ICC 里的信息折算尺寸）。
   *
   * 若将来引擎行为变化、图片又变小了：把本方法改成 `return data;` 即可一键回到原样。
   */
  static normalizeJfifDpi96(data: ArrayBuffer): ArrayBuffer {
    try {
      const b: Uint8Array = new Uint8Array(data);
      if (b.length < 24 || b[0] !== 0xFF || b[1] !== 0xD8) {
        return data;
      }
      // ① JFIF 密度 → 96dpi
      if (b[2] === 0xFF && b[3] === 0xE0 && b[6] === 0x4A && b[7] === 0x46) {
        b[13] = 1;
        b[14] = 0;
        b[15] = 96;
        b[16] = 0;
        b[17] = 96;
      }
      // ② 去掉 APP2(ICC) / APP14(Adobe)：只保留 JFIF 与其余段
      const out: number[] = [0xFF, 0xD8];
      let i: number = 2;
      let removed: number = 0;
      while (i + 3 < b.length) {
        if (b[i] !== 0xFF) {
          break;
        }
        const m: number = b[i + 1];
        if (m === 0xDA) {
          // SOS：后面全是压缩数据，原样拷到结尾
          for (let k = i; k < b.length; k++) {
            out.push(b[k]);
          }
          i = b.length;
          break;
        }
        const segLen: number = (b[i + 2] << 8) | b[i + 3];
        const segEnd: number = i + 2 + segLen;
        if (segEnd > b.length) {
          break;
        }
        if (m === 0xE2 || m === 0xEE) {
          removed++;
        } else {
          for (let k = i; k < segEnd; k++) {
            out.push(b[k]);
          }
        }
        i = segEnd;
      }
      if (removed === 0) {
        return data;
      }
      hilog.info(DOMAIN, TAG, 'jpeg normalized: dpi96 + dropped %{public}d app-seg', removed);
      return new Uint8Array(out).buffer as ArrayBuffer;
    } catch (e) {
      return data;
    }
  }

  /**
   * 只渲染第 0 页当封面（导入时用，实测 ~60ms）。
   * @returns 写成功的 jpg 路径；失败返回 ''
   */
  static async renderCover(srcPath: string, dstJpg: string, widthPx: number): Promise<string> {
    const doc: pdfService.PdfDocument = new pdfService.PdfDocument();
    try {
      const r: pdfService.ParseResult = doc.loadDocument(srcPath);
      if (r !== pdfService.ParseResult.PARSE_SUCCESS || doc.getPageCount() <= 0) {
        doc.releaseDocument();
        return '';
      }
      const page: pdfService.PdfPage = doc.getPage(0);
      const pw: number = page.getWidth();
      const ph: number = page.getHeight();
      const tw: number = Math.max(240, widthPx);
      const th: number = Math.max(1, Math.round(tw * ph / Math.max(1, pw)));
      const m: pdfService.PdfMatrix = new pdfService.PdfMatrix();
      m.x = 0;
      m.y = 0;
      // matrix 的 width/height 是**缩放比**（SDK d.ts 原文 + 真机实测，见 PdfPageCache 注释）
      const coverZoom: number = tw / Math.max(1, pw);
      m.width = pw * coverZoom;
      m.height = ph * coverZoom;
      m.rotate = 0;
      const pm: image.PixelMap = page.getAreaPixelMapWithOptions(m, tw, th);
      const packer: image.ImagePacker = image.createImagePacker();
      const opt: image.PackingOption = { format: 'image/jpeg', quality: FMT_PDF_JPEG_QUALITY };
      const ab: ArrayBuffer = await packer.packToData(pm, opt);
      await pm.release();
      page.release();
      doc.releaseDocument();
      const f = fs.openSync(dstJpg, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(f.fd, ab);
      } finally {
        fs.closeSync(f);
      }
      hilog.info(DOMAIN, TAG, 'renderCover ok bytes=%{public}d', ab.byteLength);
      return dstJpg;
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'renderCover failed: %{public}s', JSON.stringify(e));
      try {
        doc.releaseDocument();
      } catch (e2) {
        // 忽略
      }
      return '';
    }
  }

  /** 加密判断（不加载整本？`isEncrypted` 是 PdfDocument 实例方法，需要先 load） */
  static loadErrorText(r: pdfService.ParseResult): string {
    if (r === pdfService.ParseResult.PARSE_ERROR_PASSWORD) {
      return 'PDF 已加密，暂不支持';
    }
    if (r === pdfService.ParseResult.PARSE_ERROR_FORMAT) {
      return 'PDF 格式异常，无法解析';
    }
    if (r === pdfService.ParseResult.PARSE_ERROR_FILE) {
      return 'PDF 文件损坏或不可读';
    }
    return 'PDF 解析失败（code=' + String(r) + '）';
  }

  /**
   * 转换。
   * @param srcPath 沙箱里的 .pdf
   * @param outEpub 目标 .epub（父目录必须已存在）
   * @param title 书名（写进 opf / 封面）
   * @param author 作者（未知传 '暂无'）
   * @param onProgress 逐页进度（可选）
   */
  static async convert(srcPath: string, outEpub: string, title: string, author: string,
    onProgress: (p: ConvertProgress) => void): Promise<ConvertResult> {
    const doc: pdfService.PdfDocument = new pdfService.PdfDocument();
    let zip: ZipWriter | null = null;
    try {
      const r: pdfService.ParseResult = doc.loadDocument(srcPath);
      if (r !== pdfService.ParseResult.PARSE_SUCCESS) {
        const msg: string = PdfImporter.loadErrorText(r);
        hilog.error(DOMAIN, TAG, 'loadDocument failed: %{public}s', msg);
        return { ok: false, message: msg, pages: 0, chapters: 0 };
      }
      const total: number = doc.getPageCount();
      if (total <= 0) {
        doc.releaseDocument();
        return { ok: false, message: 'PDF 没有可显示的页面', pages: 0, chapters: 0 };
      }
      hilog.info(DOMAIN, TAG, 'convert start: pages=%{public}d title=%{public}s', total, title);

      zip = EpubBuilder.open(outEpub);
      const refs: EpubImageRef[] = [];
      const packer: image.ImagePacker = image.createImagePacker();
      const opt: image.PackingOption = { format: 'image/jpeg', quality: FMT_PDF_JPEG_QUALITY };
      let coverBytes: ArrayBuffer = new ArrayBuffer(0);

      for (let i = 0; i < total; i++) {
        const page: pdfService.PdfPage = doc.getPage(i);
        const pw: number = page.getWidth();
        const ph: number = page.getHeight();
        const tw: number = FMT_PDF_RENDER_WIDTH_PX;
        const th: number = Math.max(1, Math.round(tw * ph / Math.max(1, pw)));
        // ⚠️ matrix 的 width/height 是**相对原始页的缩放比**（SDK d.ts 原文 + 真机实测，
        // 见 PdfPageCache 同处注释）；后两个参数才是画布像素。
        // 旧写法 matrix 传原始点尺寸 ⇒ 整页只有 1:1 点大小，画在画布左上角（看起来"缩成 1/3"）。
        const zoom: number = tw / Math.max(1, pw);
        const m: pdfService.PdfMatrix = new pdfService.PdfMatrix();
        m.x = 0;
        m.y = 0;
        m.width = pw * zoom;
        m.height = ph * zoom;
        m.rotate = 0;
        const pm: image.PixelMap = page.getAreaPixelMapWithOptions(m, tw, th);
        const packed: ArrayBuffer = await packer.packToData(pm, opt);
        // 2026-10-19 真机实测：ImagePacker 输出的 JPEG 头是 `JFIF units=0, 1x1`，
        // 而 ReaderKit 的排版引擎会按图片密度折算 CSS 尺寸 ⇒ 页图被画成 1/3.375（实测 1400px → 415px）。
        // 这里把 JFIF 密度规范成 96dpi（units=1），让"1 图像像素 = 1 CSS 像素"。
        const bytes: ArrayBuffer = PdfImporter.normalizeJfifDpi96(packed);
        await pm.release();
        page.release();

        const href: string = 'images/p' + pad4(i + 1) + '.jpg';
        EpubBuilder.addImage(zip, href, bytes);
        refs.push({ href: href, mediaType: 'image/jpeg' });
        if (i === 0) {
          coverBytes = bytes;
        }
        if (onProgress !== undefined) {
          onProgress({ done: i + 1, total: total });
        }
      }

      // 封面：单独一份 images/cover.jpg（<meta name="cover"> 指向它）
      // ⚠️ 封面**不进 refs**（2026-10-19 修）：refs 是"正文页"，混进封面会让正文多出一页"封面"。
      const imageRefs: EpubImageRef[] = [];
      for (const r of refs) {
        imageRefs.push(r);
      }
      let coverHref: string = '';
      if (coverBytes.byteLength > 0) {
        coverHref = 'images/cover.jpg';
        EpubBuilder.addImage(zip, coverHref, coverBytes);
        imageRefs.push({ href: coverHref, mediaType: 'image/jpeg' });
      }

      // 章节：每 N 页一章（只用正文页 refs）
      const chapters: EpubChapter[] = [];
      const per: number = Math.max(1, FMT_PDF_PAGES_PER_CHAPTER);
      for (let start = 0; start < refs.length; start += per) {
        const end: number = Math.min(refs.length, start + per);
        const hrefs: string[] = [];
        for (let k = start; k < end; k++) {
          hrefs.push(refs[k].href);
        }
        const a: number = start + 1;
        const b: number = end;
        const t: string = a === b ? ('第 ' + a + ' 页') : ('第 ' + a + '–' + b + ' 页');
        chapters.push({ title: t, bodyHtml: EpubBuilder.imagePageHtml(hrefs) });
      }

      const meta: EpubMeta = { title: title, author: author, language: 'zh-CN' };
      EpubBuilder.finish(zip, meta, chapters, imageRefs, coverHref);
      zip = null;

      doc.releaseDocument();
      hilog.info(DOMAIN, TAG, 'convert ok: pages=%{public}d chapters=%{public}d', total, chapters.length);
      return { ok: true, message: '', pages: total, chapters: chapters.length };
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'convert failed: %{public}s', JSON.stringify(e));
      try {
        doc.releaseDocument();
      } catch (e2) {
        // 忽略
      }
      return { ok: false, message: 'PDF 转换失败：' + (e instanceof Error ? e.message : String(e)),
        pages: 0, chapters: 0 };
    }
  }
}
