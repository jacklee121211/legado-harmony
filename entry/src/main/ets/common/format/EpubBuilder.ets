/**
 * EPUB 生成器（EPUB 3 + 兼容 EPUB 2 的 ncx）——PDF 页图版与 DOCX 重排版共用。
 *
 * 产物结构（顺序即写入顺序，`mimetype` 必须是第一个且不压缩，见 OCF 规范）：
 * ```
 * mimetype
 * META-INF/container.xml
 * OEBPS/style.css
 * OEBPS/images/*          ← 页图 / docx 内嵌图片 / 封面（调用方逐张写入）
 * OEBPS/ch1.xhtml …
 * OEBPS/nav.xhtml         ← EPUB3 目录
 * OEBPS/toc.ncx           ← EPUB2 兼容目录（ReaderKit 两个都认，见 POC 实测）
 * OEBPS/content.opf
 * ```
 *
 * ── 为什么是"分批写入"而不是一次性传图片数组 ─────────────────────────────────
 * 一本 300 页的 PDF，页图合计 ~33MB。若把全部 `ArrayBuffer` 攒在数组里再打包，
 * 峰值内存会翻倍（页图 + zip 缓冲）。这里用 `open → addImage(逐张) → finish` 的流式接口，
 * 任意时刻只持有一张页图的字节（ZipWriter 只顺序写文件，见其头注释）。
 *
 * 真机 POC 依据（docs/PDF支持方案决策-2026-10-19.md §11）：
 *  · 这种手造 epub 被 ReaderKit 正常解析：`catalog=3`、`spine=3`、逐页可翻；
 *  · `<meta name="cover">` 会被读进 `BookInfo.bookCoverImage`；
 *  · 一个 xhtml 里放多张 `width:100%` 图片 ⇒ 引擎逐张成页、不粘连、不切开（超长图整体缩放）。
 */
import { ZipWriter } from './ZipWriter';

/** 一章（一个 xhtml / 一个 spine item） */
export interface EpubChapter {
  /** 目录里显示的标题 */
  title: string;
  /** `<body>` 内部的 HTML（不含 body 标签） */
  bodyHtml: string;
}

/** 图片引用（finish 时只写清单，不写数据） */
export interface EpubImageRef {
  /** 相对 OEBPS 的路径，如 `images/p0001.jpg` */
  href: string;
  /** `image/jpeg` / `image/png` */
  mediaType: string;
}

export interface EpubMeta {
  title: string;
  author: string;
  language: string;
}

const CSS: string = 'html,body{margin:0;padding:0;background:#ffffff;}\n' +
  // ⚠️ 页图**不能**设 width（见 imagePageHtml 的实测注释）；docx 内嵌图片用 .docimg 单独控制
  'img{display:block;margin:0;padding:0;}\n' +
  'h1,h2,h3{line-height:1.4;margin:0.8em 0 0.4em;}\n' +
  'p{line-height:1.75;margin:0.35em 0;text-indent:2em;}\n' +
  'table{border-collapse:collapse;width:100%;margin:0.6em 0;}\n' +
  'td,th{border:1px solid #cccccc;padding:0.25em 0.4em;vertical-align:top;line-height:1.6;}\n' +
  'td p,th p{text-indent:0;margin:0;}\n' +
  '.docimg{max-width:100%;height:auto;margin:0.4em 0;}\n' +
  '.center{text-align:center;}\n';

export class EpubBuilder {
  /** UTF-8 编码（手写，避免 `util.TextEncoder.encodeInto` 的弃用告警） */
  private static utf8(s: string): ArrayBuffer {
    const out: number[] = [];
    for (let i = 0; i < s.length; i++) {
      let c: number = s.charCodeAt(i);
      if (c >= 0xD800 && c <= 0xDBFF && i + 1 < s.length) {
        const lo: number = s.charCodeAt(i + 1);
        if (lo >= 0xDC00 && lo <= 0xDFFF) {
          c = 0x10000 + ((c - 0xD800) << 10) + (lo - 0xDC00);
          i++;
        }
      }
      if (c < 0x80) {
        out.push(c);
      } else if (c < 0x800) {
        out.push(0xC0 | (c >> 6), 0x80 | (c & 0x3F));
      } else if (c < 0x10000) {
        out.push(0xE0 | (c >> 12), 0x80 | ((c >> 6) & 0x3F), 0x80 | (c & 0x3F));
      } else {
        out.push(0xF0 | (c >> 18), 0x80 | ((c >> 12) & 0x3F),
          0x80 | ((c >> 6) & 0x3F), 0x80 | (c & 0x3F));
      }
    }
    return new Uint8Array(out).buffer as ArrayBuffer;
  }

  static esc(s: string): string {
    return s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;').replace(/'/g, '&apos;');
  }

  /**
   * 页图版章节 HTML：一章 N 张整页图片。
   *
   * ⚠️ 2026-10-19 真机实测（探针 A/B 对照，同一 ReaderKit 环境）：
   *   · 给 `img` 写 `width:100%` ⇒ 引擎把页图缩到**排版页宽**（日志 `totalWidth=783`、
   *     `target offset 391.11 = 1320/3.375`，即 391vp），实测 1200px 的页图只画到 ≈400px，
   *     而且图片不随密度放大 ⇒ 页面缩在中间一小块；
   *   · **不写任何宽高** ⇒ 引擎按图片**自身像素**1:1 上屏（POC 样本 1080px 图实测 ≈1082px）。
   * ⇒ 正确做法：页图**不许设 width:100%**，而是"按屏幕内容宽度渲染多少像素，就显示多少像素"，
   *    由 `FMT_PDF_RENDER_WIDTH_PX` 控制。
   */
  static imagePageHtml(hrefs: string[]): string {
    // 2026-10-19（用户反馈 ②+b）：**上下居中**。
    // ReaderKit 是 web/CSS 排版引擎（工程既有结论），所以用 flex 把整页图在页内垂直居中；
    // 这样任何纸张比例（A4/Letter/异形页）都自动居中，不用按像素算留白。
    // `height:100%` 必须写在章节内联 style 里（全局 CSS 里给 html,body 定高会影响文字书）。
    let html: string = '<style>html,body{height:100%;margin:0;padding:0;}' +
      '.pagebox{height:100%;display:flex;align-items:center;justify-content:center;}</style>';
    for (const h of hrefs) {
      html += '<div class="pagebox"><img src="' + EpubBuilder.esc(h) + '" width="1320" height="1708" alt="page"/></div>';
    }
    return html;
  }

  /** 第 1 步：建文件并写固定的三件事（mimetype / container / css） */
  static open(outPath: string): ZipWriter {
    const w: ZipWriter = new ZipWriter(outPath);
    w.add('mimetype', EpubBuilder.utf8('application/epub+zip'));
    w.add('META-INF/container.xml', EpubBuilder.utf8('<?xml version="1.0" encoding="UTF-8"?>\n' +
      '<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">\n' +
      '  <rootfiles><rootfile full-path="OEBPS/content.opf" ' +
      'media-type="application/oebps-package+xml"/></rootfiles>\n</container>\n'));
    w.add('OEBPS/style.css', EpubBuilder.utf8(CSS));
    return w;
  }

  /** 第 2 步：写一张图片（页图 / docx 内嵌图 / 封面） */
  static addImage(w: ZipWriter, href: string, data: ArrayBuffer): void {
    w.add('OEBPS/' + href, data);
  }

  /** 第 3 步：写章节 + 目录 + opf 并关闭 */
  static finish(w: ZipWriter, meta: EpubMeta, chapters: EpubChapter[],
    images: EpubImageRef[], coverHref: string): void {
    // 章节
    for (let i = 0; i < chapters.length; i++) {
      const doc: string = '<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE html>\n' +
        '<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">\n' +
        '<head><meta charset="utf-8"/><title>' + EpubBuilder.esc(chapters[i].title) + '</title>' +
        // 样式同时写在外部 css **和** 本章内联 <style>：真机实测外部 CSS 在图片宽度上不生效
        // （页图按"原始像素"渲染），内联后才吃到 width:100%。
        '<style type="text/css">html,body{margin:0;padding:0;}' +
        // 同 imagePageHtml 注释：页图不能设宽度，否则会被缩到排版页宽
        'img{display:block;margin:0;padding:0;}' +
        'p{line-height:1.75;margin:0.35em 0;}' +
        'table{border-collapse:collapse;width:100%;}' +
        'td,th{border:1px solid #cccccc;padding:0.25em 0.4em;vertical-align:top;}' +
        '</style>' +
        '<link rel="stylesheet" type="text/css" href="style.css"/></head>\n' +
        '<body>' + chapters[i].bodyHtml + '</body></html>\n';
      w.add('OEBPS/ch' + (i + 1) + '.xhtml', EpubBuilder.utf8(doc));
    }

    // 目录
    let navLis: string = '';
    let navPoints: string = '';
    for (let i = 0; i < chapters.length; i++) {
      const href: string = 'ch' + (i + 1) + '.xhtml';
      navLis += '      <li><a href="' + href + '">' + EpubBuilder.esc(chapters[i].title) + '</a></li>\n';
      navPoints += '    <navPoint id="np' + (i + 1) + '" playOrder="' + (i + 1) + '">' +
        '<navLabel><text>' + EpubBuilder.esc(chapters[i].title) + '</text></navLabel>' +
        '<content src="' + href + '"/></navPoint>\n';
    }
    w.add('OEBPS/nav.xhtml', EpubBuilder.utf8('<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE html>\n' +
      '<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">\n' +
      '<head><title>目录</title></head><body><nav epub:type="toc" id="toc"><h1>目录</h1><ol>\n' +
      navLis + '</ol></nav></body></html>\n'));
    w.add('OEBPS/toc.ncx', EpubBuilder.utf8('<?xml version="1.0" encoding="UTF-8"?>\n' +
      '<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">\n' +
      '  <head><meta name="dtb:uid" content="urn:uuid:epubbuilder-1"/></head>\n' +
      '  <docTitle><text>' + EpubBuilder.esc(meta.title) + '</text></docTitle>\n  <navMap>\n' +
      navPoints + '  </navMap>\n</ncx>\n'));

    // opf
    let manifest: string = '    <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" ' +
      'properties="nav"/>\n' +
      '    <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>\n' +
      '    <item id="css" href="style.css" media-type="text/css"/>\n';
    for (let i = 0; i < chapters.length; i++) {
      manifest += '    <item id="ch' + (i + 1) + '" href="ch' + (i + 1) +
        '.xhtml" media-type="application/xhtml+xml"/>\n';
    }
    let coverId: string = '';
    for (let i = 0; i < images.length; i++) {
      const id: string = 'img' + (i + 1);
      const isCover: boolean = coverHref.length > 0 && images[i].href === coverHref;
      if (isCover) {
        coverId = id;
      }
      manifest += '    <item id="' + id + '" href="' + images[i].href +
        '" media-type="' + images[i].mediaType + '"' + (isCover ? ' properties="cover-image"' : '') + '/>\n';
    }
    let spine: string = '';
    for (let i = 0; i < chapters.length; i++) {
      spine += '    <itemref idref="ch' + (i + 1) + '"/>\n';
    }
    const coverMeta: string = coverId.length > 0
      ? '    <meta name="cover" content="' + coverId + '"/>\n' : '';
    w.add('OEBPS/content.opf', EpubBuilder.utf8('<?xml version="1.0" encoding="UTF-8"?>\n' +
      '<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="bookid">\n' +
      '  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">\n' +
      '    <dc:identifier id="bookid">urn:uuid:epubbuilder-1</dc:identifier>\n' +
      '    <dc:title>' + EpubBuilder.esc(meta.title) + '</dc:title>\n' +
      '    <dc:creator>' + EpubBuilder.esc(meta.author) + '</dc:creator>\n' +
      '    <dc:language>' + EpubBuilder.esc(meta.language) + '</dc:language>\n' +
      '    <meta property="dcterms:modified">2026-01-01T00:00:00Z</meta>\n' +
      coverMeta + '  </metadata>\n  <manifest>\n' + manifest + '  </manifest>\n' +
      '  <spine toc="ncx">\n' + spine + '  </spine>\n</package>\n'));

    w.close();
  }
}
