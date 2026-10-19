/**
 * DOCX → 重排 epub（纯自研，无第三方库）。
 *
 * ── 为什么是"解压 + 读 XML"而不是别的 ────────────────────────────────────────
 * docx 就是 ZIP + OOXML（本机实测：`word/document.xml` 39099 字节 / 59 个 `<w:p>` / 92 个 `<w:t>`），
 * 系统**没有任何 Word 解析 API**（官方 FAQ 对 Word 只给 `fs.writeSync` 写字符串），
 * 所以只能自己解。解压用系统 `@ohos.zlib.decompressFile`（`@ohos.zlib.d.ts:1033`，
 * ⚠️ 要求 inFile 后缀必须是 `.zip` ⇒ 调用方先把它复制成 `xxx.docx.zip`）。
 *
 * ── 产物 ────────────────────────────────────────────────────────────────────
 * 与 PDF 共用 `EpubBuilder`：段落/标题/表格/图片 → xhtml → epub。
 * 走 ReaderKit 现有排版 ⇒ 换字体、字号、主题、听书、目录全部可用（这是 DOCX 相对 PDF 的优势：
 * 文档是流式的，重排比"转图片"更自然）。
 *
 * ── 解析策略：正则扫描（不开 XML 解析器） ─────────────────────────────────────
 * 理由：docx 的 XML 是 Office 机器生成的，结构高度规范；而 `@ohos.xml` 的 `XmlPullParser`
 * 在标签名前缀/命名空间（`w:`、`a:`、`r:`）上的行为需要额外验证，且拿不到"相邻 run 的样式合并"
 * 这类便利。这里用一个"按顶层块切分 + 段内正则"的扫描器，规则集中、可预期、易调试。
 * 已知取舍：嵌套表格压平、修订记录里的删除文本忽略、字段代码只取显示文本。
 */
import { fileIo as fs } from '@kit.CoreFileKit';
import { zlib } from '@kit.BasicServicesKit';
import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { EpubBuilder, EpubChapter, EpubImageRef, EpubMeta } from './EpubBuilder';
import { ZipWriter } from './ZipWriter';
import { ConvertProgress, ConvertResult } from './PdfImporter';

const DOMAIN: number = 0x0000;
const TAG: string = 'DocxImporter';

/** styles.xml 里一条段落样式 */
interface ParaStyle {
  name: string;
  outlineLvl: number;
}

/** 解析出的一块内容 */
interface Block {
  /** 0=正文段落 1..6=标题级别 9=表格 */
  kind: number;
  html: string;
  /** 标题纯文本（切章用） */
  text: string;
}

/** 正文里发现的一张图片 */
interface DocImage {
  href: string;
  filePath: string;
  mediaType: string;
}

function decodeUtf8(bytes: ArrayBuffer): string {
  const dec = util.TextDecoder.create('utf-8', { ignoreBOM: true });
  return dec.decodeToString(new Uint8Array(bytes));
}

function readText(path: string): string {
  const st = fs.statSync(path);
  if (st.size <= 0) {
    return '';
  }
  const buf: ArrayBuffer = new ArrayBuffer(st.size);
  const f = fs.openSync(path, fs.OpenMode.READ_ONLY);
  try {
    fs.readSync(f.fd, buf);
  } finally {
    fs.closeSync(f);
  }
  return decodeUtf8(buf);
}

function readBytes(path: string): ArrayBuffer {
  const st = fs.statSync(path);
  const buf: ArrayBuffer = new ArrayBuffer(st.size);
  const f = fs.openSync(path, fs.OpenMode.READ_ONLY);
  try {
    fs.readSync(f.fd, buf);
  } finally {
    fs.closeSync(f);
  }
  return buf;
}

function exists(path: string): boolean {
  try {
    return fs.accessSync(path);
  } catch (e) {
    return false;
  }
}

function mkdirs(path: string): void {
  if (!exists(path)) {
    fs.mkdirSync(path, true);
  }
}

/** XML 实体解码（只处理常见五种 + 数字实体） */
function decodeEntities(s: string): string {
  if (s.indexOf('&') < 0) {
    return s;
  }
  let out: string = s.replace(/&lt;/g, '<').replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"').replace(/&apos;/g, '\'')
    .replace(/&#(\d+);/g, (_m: string, d: string): string => String.fromCharCode(Number(d)))
    .replace(/&#x([0-9a-fA-F]+);/g, (_m: string, h: string): string => String.fromCharCode(parseInt(h, 16)));
  out = out.replace(/&amp;/g, '&');
  return out;
}

function basename(path: string): string {
  const i: number = Math.max(path.lastIndexOf('/'), path.lastIndexOf('\\'));
  return i >= 0 ? path.substring(i + 1) : path;
}

/** 取第一个 `<w:pPr>` 块里的 pStyle / outlineLvl */
function paragraphStyle(chunk: string): string {
  const m: RegExpMatchArray | null = chunk.match(/<w:pStyle\s+w:val="([^"]+)"/);
  return m !== null && m.length > 1 ? m[1] : '';
}

function paragraphOutlineLvl(chunk: string): number {
  const m: RegExpMatchArray | null = chunk.match(/<w:outlineLvl\s+w:val="(\d+)"/);
  return m !== null && m.length > 1 ? Number(m[1]) : -1;
}

/** 段落内所有可见文本（用于标题文字） */
function plainText(chunk: string): string {
  let text: string = '';
  const re: RegExp = /<w:t(?:\s[^>]*)?>([\s\S]*?)<\/w:t>|<w:tab\/>|<w:br\/>/g;
  let m: RegExpExecArray | null = re.exec(chunk);
  while (m !== null) {
    const whole: string = m[0];
    if (whole === '<w:tab/>') {
      text += '\t';
    } else if (whole === '<w:br/>') {
      text += '\n';
    } else if (m[1] !== undefined) {
      text += decodeEntities(m[1]);
    }
    m = re.exec(chunk);
  }
  return text;
}

export class DocxImporter {
  /**
   * 转换。`zipSrcPath` 必须是 **.zip 后缀**的副本（`@ohos.zlib` 的硬性要求）。
   */
  static async convert(zipSrcPath: string, workDir: string, outEpub: string,
    title: string, author: string, onProgress: (p: ConvertProgress) => void): Promise<ConvertResult> {
    try {
      mkdirs(workDir);
      // ① 解压（目标目录必须已存在；同名文件会被覆盖）
      const unpackDir: string = workDir + '/unzip';
      mkdirs(unpackDir);
      await zlib.decompressFile(zipSrcPath, unpackDir);
      const docXmlPath: string = unpackDir + '/word/document.xml';
      if (!exists(docXmlPath)) {
        hilog.error(DOMAIN, TAG, 'word/document.xml missing (not a real docx?)');
        return { ok: false, message: '不是有效的 DOCX（缺少 word/document.xml）', pages: 0, chapters: 0 };
      }
      const docXml: string = readText(docXmlPath);
      hilog.info(DOMAIN, TAG, 'document.xml %{public}d chars', docXml.length);

      // ② 样式表（styleId → 名称/大纲级别）
      const styles: Map<string, ParaStyle> = new Map<string, ParaStyle>();
      const stylesPath: string = unpackDir + '/word/styles.xml';
      if (exists(stylesPath)) {
        DocxImporter.parseStyles(readText(stylesPath), styles);
      }
      // ③ 关系表（rId → 媒体文件）
      const rels: Map<string, string> = new Map<string, string>();
      const relsPath: string = unpackDir + '/word/_rels/document.xml.rels';
      if (exists(relsPath)) {
        DocxImporter.parseRels(readText(relsPath), rels);
      }

      // ④ 解析正文块 + 收集图片
      const images: DocImage[] = [];
      const blocks: Block[] = DocxImporter.parseBody(docXml, styles, rels, unpackDir, images);
      hilog.info(DOMAIN, TAG, 'blocks=%{public}d images=%{public}d', blocks.length, images.length);
      if (blocks.length === 0) {
        return { ok: false, message: 'DOCX 正文为空', pages: 0, chapters: 0 };
      }

      // ⑤ 切章（标题切；无标题则按字数切）
      const chapters: EpubChapter[] = DocxImporter.splitChapters(blocks);

      // ⑥ 写 epub
      const zip: ZipWriter = EpubBuilder.open(outEpub);
      const refs: EpubImageRef[] = [];
      for (const img of images) {
        try {
          const bytes: ArrayBuffer = readBytes(img.filePath);
          EpubBuilder.addImage(zip, img.href, bytes);
          refs.push({ href: img.href, mediaType: img.mediaType });
        } catch (e) {
          hilog.warn(DOMAIN, TAG, 'image skip %{public}s', img.filePath);
        }
      }
      // 封面：docProps/thumbnail.jpeg
      let coverHref: string = '';
      const thumb: string = unpackDir + '/docProps/thumbnail.jpeg';
      if (exists(thumb)) {
        try {
          EpubBuilder.addImage(zip, 'images/cover.jpg', readBytes(thumb));
          coverHref = 'images/cover.jpg';
          refs.push({ href: coverHref, mediaType: 'image/jpeg' });
        } catch (e) {
          coverHref = '';
        }
      }
      const meta: EpubMeta = { title: title, author: author, language: 'zh-CN' };
      EpubBuilder.finish(zip, meta, chapters, refs, coverHref);
      if (onProgress !== undefined) {
        onProgress({ done: 1, total: 1 });
      }
      hilog.info(DOMAIN, TAG, 'convert ok: chapters=%{public}d refs=%{public}d',
        chapters.length, refs.length);
      return { ok: true, message: '', pages: blocks.length, chapters: chapters.length };
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'convert failed: %{public}s', JSON.stringify(e));
      return { ok: false, message: 'DOCX 转换失败：' + (e instanceof Error ? e.message : String(e)),
        pages: 0, chapters: 0 };
    }
  }

  /**
   * 只取封面（导入时用）：优先 `docProps/thumbnail.jpeg`，其次 `word/media` 里第一张图。
   * @param baseNoExt 目标文件去掉扩展名的前缀（按源图类型自动补 `.jpg`/`.png`）
   * @returns 写出的封面路径；找不到返回 ''
   */
  static async extractCover(zipPath: string, unpackDir: string, baseNoExt: string): Promise<string> {
    try {
      mkdirs(unpackDir);
      await zlib.decompressFile(zipPath, unpackDir);
      const cands: string[] = [
        unpackDir + '/docProps/thumbnail.jpeg',
        unpackDir + '/docProps/thumbnail.jpg',
        unpackDir + '/docProps/thumbnail.png'
      ];
      for (const c of cands) {
        if (exists(c)) {
          const dst: string = baseNoExt + (c.toLowerCase().endsWith('.png') ? '.png' : '.jpg');
          DocxImporter.copyFile(c, dst);
          return dst;
        }
      }
      const media: string = unpackDir + '/word/media';
      if (exists(media)) {
        const files: string[] = fs.listFileSync(media);
        for (const name of files) {
          const lower: string = name.toLowerCase();
          if (lower.endsWith('.png') || lower.endsWith('.jpg') || lower.endsWith('.jpeg')) {
            const dst: string = baseNoExt + (lower.endsWith('.png') ? '.png' : '.jpg');
            DocxImporter.copyFile(media + '/' + name, dst);
            return dst;
          }
        }
      }
      return '';
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'extractCover failed: %{public}s', JSON.stringify(e));
      return '';
    }
  }

  private static copyFile(src: string, dst: string): void {
    const bytes: ArrayBuffer = readBytes(src);
    const f = fs.openSync(dst, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    try {
      fs.writeSync(f.fd, bytes);
    } finally {
      fs.closeSync(f);
    }
  }

  /** `<w:style w:type="paragraph" w:styleId="X">` → name / outlineLvl */
  private static parseStyles(xml: string, out: Map<string, ParaStyle>): void {
    const re: RegExp = /<w:style\s[^>]*w:styleId="([^"]+)"[^>]*>([\s\S]*?)<\/w:style>/g;
    let m: RegExpExecArray | null = re.exec(xml);
    while (m !== null) {
      const id: string = m[1];
      const body: string = m[2];
      const nm: RegExpMatchArray | null = body.match(/<w:name\s+w:val="([^"]*)"/);
      const ol: RegExpMatchArray | null = body.match(/<w:outlineLvl\s+w:val="(\d+)"/);
      out.set(id, {
        name: nm !== null && nm.length > 1 ? nm[1] : '',
        outlineLvl: ol !== null && ol.length > 1 ? Number(ol[1]) : -1
      });
      m = re.exec(xml);
    }
  }

  /** `<Relationship Id="rId1" Type="...image" Target="media/image1.png"/>` */
  private static parseRels(xml: string, out: Map<string, string>): void {
    const re: RegExp = /<Relationship\s[^>]*Id="([^"]+)"[^>]*Target="([^"]+)"[^>]*\/>/g;
    let m: RegExpExecArray | null = re.exec(xml);
    while (m !== null) {
      const id: string = m[1];
      const target: string = m[2];
      // 只关心图片关系
      const lower: string = target.toLowerCase();
      if (lower.endsWith('.png') || lower.endsWith('.jpg') || lower.endsWith('.jpeg')
        || lower.endsWith('.gif') || lower.endsWith('.bmp') || lower.endsWith('.webp')) {
        out.set(id, target);
      }
      m = re.exec(xml);
    }
  }

  /** 把 body 切成顶层块，逐块转 HTML；同时收集图片 */
  private static parseBody(docXml: string, styles: Map<string, ParaStyle>,
    rels: Map<string, string>, unpackDir: string, images: DocImage[]): Block[] {
    const blocks: Block[] = [];
    const bodyStart: number = docXml.indexOf('<w:body>');
    if (bodyStart < 0) {
      return blocks;
    }
    let i: number = bodyStart + '<w:body>'.length;
    const bodyEnd: number = docXml.lastIndexOf('</w:body>');
    const end: number = bodyEnd > i ? bodyEnd : docXml.length;
    let guard: number = 0;

    while (i < end && guard < 200000) {
      guard++;
      const pIdx: number = docXml.indexOf('<w:p ', i);
      const pIdx2: number = docXml.indexOf('<w:p>', i);
      const tIdx: number = docXml.indexOf('<w:tbl>', i);
      if (pIdx < 0 && pIdx2 < 0 && tIdx < 0) {
        break;
      }
      let nextP: number = -1;
      if (pIdx >= 0 && pIdx2 >= 0) {
        nextP = Math.min(pIdx, pIdx2);
      } else {
        nextP = Math.max(pIdx, pIdx2);
      }
      if (tIdx >= 0 && (nextP < 0 || tIdx < nextP)) {
        // ── 表格 ──
        const close: number = DocxImporter.matchClose(docXml, tIdx, '<w:tbl>', '</w:tbl>');
        const tblEnd: number = close > 0 ? close : end;
        const chunk: string = docXml.substring(tIdx, tblEnd);
        blocks.push({
          kind: 9,
          html: DocxImporter.tableHtml(chunk, styles, rels, unpackDir, images),
          text: ''
        });
        i = tblEnd;
        continue;
      }
      if (nextP < 0) {
        break;
      }
      const pClose: number = docXml.indexOf('</w:p>', nextP);
      if (pClose < 0) {
        break;
      }
      const chunk: string = docXml.substring(nextP, pClose + '</w:p>'.length);
      const blk: Block = DocxImporter.paragraphBlock(chunk, styles, rels, unpackDir, images);
      // 空段落（纯空行）跳过，但保留真正的空行？→ 跳过，避免 epub 里大量空 <p>
      if (blk.html.length > 0) {
        blocks.push(blk);
      }
      i = pClose + '</w:p>'.length;
    }
    return blocks;
  }

  /** 找配对闭合标签（支持同名嵌套） */
  private static matchClose(xml: string, start: number, open: string, close: string): number {
    let depth: number = 0;
    let i: number = start;
    while (i < xml.length) {
      const o: number = xml.indexOf(open, i);
      const c: number = xml.indexOf(close, i);
      if (c < 0) {
        return -1;
      }
      if (o >= 0 && o < c) {
        depth++;
        i = o + open.length;
      } else {
        depth--;
        i = c + close.length;
        if (depth <= 0) {
          return i;
        }
      }
    }
    return -1;
  }

  /** 表格 → <table>（每格用段落转 HTML；嵌套表格压平） */
  private static tableHtml(chunk: string, styles: Map<string, ParaStyle>,
    rels: Map<string, string>, unpackDir: string, images: DocImage[]): string {
    let html: string = '<table>';
    const rowRe: RegExp = /<w:tr[\s>][\s\S]*?<\/w:tr>/g;
    let rm: RegExpExecArray | null = rowRe.exec(chunk);
    while (rm !== null) {
      html += '<tr>';
      const row: string = rm[0];
      const cellRe: RegExp = /<w:tc>[\s\S]*?<\/w:tc>/g;
      let cm: RegExpExecArray | null = cellRe.exec(row);
      while (cm !== null) {
        const cell: string = cm[0];
        html += '<td>';
        // 单元格里的每个段落
        const pRe: RegExp = /<w:p[\s>][\s\S]*?<\/w:p>/g;
        let pm: RegExpExecArray | null = pRe.exec(cell);
        if (pm === null) {
          const t: string = plainText(cell);
          if (t.trim().length > 0) {
            html += '<p>' + EpubBuilder.esc(t) + '</p>';
          }
        } else {
          while (pm !== null) {
            const blk: Block = DocxImporter.paragraphBlock(pm[0], styles, rels, unpackDir, images);
            if (blk.html.length > 0 && blk.kind !== 9) {
              // 表格里不出现标题标签，统一降级为 <p>
              html += blk.html.replace(/<h([1-6])>/g, '<p>').replace(/<\/h[1-6]>/g, '</p>');
            }
            pm = pRe.exec(cell);
          }
        }
        html += '</td>';
        cm = cellRe.exec(row);
      }
      html += '</tr>';
      rm = rowRe.exec(chunk);
    }
    html += '</table>';
    return html;
  }

  /** 单个段落 → 块（标题或正文），含行内加粗/斜体与图片 */
  private static paragraphBlock(chunk: string, styles: Map<string, ParaStyle>,
    rels: Map<string, string>, unpackDir: string, images: DocImage[]): Block {
    const styleId: string = paragraphStyle(chunk);
    let outline: number = paragraphOutlineLvl(chunk);
    if (outline < 0 && styleId.length > 0) {
      const st: ParaStyle | undefined = styles.get(styleId);
      if (st !== undefined) {
        if (st.outlineLvl >= 0) {
          outline = st.outlineLvl;
        } else {
          const nm: string = st.name.toLowerCase();
          if (nm.indexOf('heading') >= 0 || nm.indexOf('标题') >= 0) {
            const d: RegExpMatchArray | null = nm.match(/(\d+)/);
            outline = d !== null && d.length > 1 ? Number(d[1]) - 1 : 0;
          }
        }
      } else {
        // styleId 形如 Heading1 / 标题1（部分文档直接用系统样式 id）
        const d: RegExpMatchArray | null = styleId.match(/(\d+)/);
        const nm: string = styleId.toLowerCase();
        if (nm.indexOf('heading') >= 0 || styleId.indexOf('标题') >= 0) {
          outline = d !== null && d.length > 1 ? Number(d[1]) - 1 : 0;
        }
      }
    }

    // 行内内容：按 <w:r> 切 run
    let inline: string = '';
    const imgHtml: string = DocxImporter.collectImages(chunk, rels, unpackDir, images);
    const runRe: RegExp = /<w:r(?:\s[^>]*)?>([\s\S]*?)<\/w:r>/g;
    let rm: RegExpExecArray | null = runRe.exec(chunk);
    while (rm !== null) {
      const run: string = rm[1];
      const txt: string = plainText(run);
      if (txt.length > 0) {
        const rPrM: RegExpMatchArray | null = run.match(/<w:rPr>([\s\S]*?)<\/w:rPr>/);
        const rPr: string = rPrM !== null && rPrM.length > 1 ? rPrM[1] : '';
        const bold: boolean = /<w:b\/>|<w:b\s+w:val="(?:1|true|on)"/.test(rPr);
        const italic: boolean = /<w:i\/>|<w:i\s+w:val="(?:1|true|on)"/.test(rPr);
        let piece: string = EpubBuilder.esc(txt);
        if (bold) {
          piece = '<strong>' + piece + '</strong>';
        }
        if (italic) {
          piece = '<em>' + piece + '</em>';
        }
        inline += piece;
      }
      rm = runRe.exec(chunk);
    }

    const text: string = plainText(chunk);
    const htmlBody: string = imgHtml + (inline.length > 0 ? inline : '');
    if (htmlBody.length === 0) {
      return { kind: 0, html: '', text: '' };
    }
    if (outline >= 0) {
      const lv: number = Math.min(4, outline + 1);
      return {
        kind: lv,
        html: '<h' + lv + '>' + (inline.length > 0 ? inline : EpubBuilder.esc(text))
          + '</h' + lv + '>' + imgHtml,
        text: text.trim()
      };
    }
    return { kind: 0, html: '<p>' + htmlBody + '</p>', text: text.trim() };
  }

  /** 段落里的图片：`<a:blip r:embed="rIdN">` / 旧式 `<v:imagedata r:id="rIdN">` */
  private static collectImages(chunk: string, rels: Map<string, string>,
    unpackDir: string, images: DocImage[]): string {
    let html: string = '';
    const re: RegExp = /r:(?:embed|id)="([^"]+)"/g;
    let m: RegExpExecArray | null = re.exec(chunk);
    while (m !== null) {
      const rid: string = m[1];
      const target: string | undefined = rels.get(rid);
      if (target !== undefined) {
        const file: string = basename(target);
        const filePath: string = unpackDir + '/word/media/' + file;
        if (exists(filePath)) {
          const lower: string = file.toLowerCase();
          let mediaType: string = 'image/png';
          if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) {
            mediaType = 'image/jpeg';
          } else if (lower.endsWith('.gif')) {
            mediaType = 'image/gif';
          } else if (lower.endsWith('.bmp')) {
            mediaType = 'image/bmp';
          } else if (lower.endsWith('.webp')) {
            mediaType = 'image/webp';
          }
          const href: string = 'images/d_' + file;
          if (!DocxImporter.hasImage(images, href)) {
            images.push({ href: href, filePath: filePath, mediaType: mediaType });
          }
          html += '<p class="center"><img class="docimg" src="' + EpubBuilder.esc(href) + '"/></p>';
        }
      }
      m = re.exec(chunk);
    }
    return html;
  }

  private static hasImage(images: DocImage[], href: string): boolean {
    for (const it of images) {
      if (it.href === href) {
        return true;
      }
    }
    return false;
  }

  /** 切章：遇到标题（kind 1~2）开新章；没有标题则按累计 HTML 长度切 */
  private static splitChapters(blocks: Block[]): EpubChapter[] {
    const chapters: EpubChapter[] = [];
    let curTitle: string = '';
    let curHtml: string = '';
    let curLen: number = 0;
    let hasHeading: boolean = false;
    for (const b of blocks) {
      if (b.kind >= 1 && b.kind <= 2) {
        hasHeading = true;
      }
    }

    if (hasHeading) {
      for (const b of blocks) {
        const isHeading: boolean = b.kind >= 1 && b.kind <= 2;
        if (isHeading && curHtml.length > 0) {
          chapters.push({ title: curTitle.length > 0 ? curTitle : ('第 ' + (chapters.length + 1) + ' 节'),
            bodyHtml: curHtml });
          curHtml = '';
          curLen = 0;
        }
        if (isHeading && curTitle.length === 0) {
          curTitle = b.text.length > 0 ? b.text : ('第 ' + (chapters.length + 1) + ' 节');
        }
        curHtml += b.html;
      }
      if (curHtml.length > 0) {
        chapters.push({ title: curTitle.length > 0 ? curTitle : ('第 ' + (chapters.length + 1) + ' 节'),
          bodyHtml: curHtml });
      }
    } else {
      // 无标题：按累计长度 ~6000 字符切（够 2-3 屏，目录不会爆炸）
      const limit: number = 6000;
      let title: string = '第 1 节';
      for (const b of blocks) {
        curHtml += b.html;
        curLen += b.html.length;
        if (curLen >= limit) {
          chapters.push({ title: title, bodyHtml: curHtml });
          curHtml = '';
          curLen = 0;
          title = '第 ' + (chapters.length + 1) + ' 节';
        }
      }
      if (curHtml.length > 0) {
        chapters.push({ title: title, bodyHtml: curHtml });
      }
    }
    if (chapters.length === 0) {
      chapters.push({ title: '正文', bodyHtml: '<p></p>' });
    }
    return chapters;
  }
}
