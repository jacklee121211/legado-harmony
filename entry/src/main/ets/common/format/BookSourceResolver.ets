/**
 * 新格式（PDF / DOCX）的"可读路径"解析器 —— 阅读页与听书共用**同一个**入口。
 *
 * ── 设计要点 ────────────────────────────────────────────────────────────────
 * ① DB 里的 `bookUrl` **永远是原始文件**（.pdf/.docx）⇒ 书名/后缀/分享/导出/封面语义全部保持不变；
 * ② 转换产物（epub）放在 `filesDir/fmt_cache/`，文件名带**源文件 size + mtime 指纹**，
 *    源文件一换自动失效（与 `BookNormalizer.cachePathFor` 同一套思路，见其注释）；
 * ③ 阅读页与听书**必须**都走这里 —— 只有一边走会出现"ReaderKit 按 A 排版、TTS 按 B 取正文"的错位
 *    （`ReaderPage3.ets:3497-3499` 已写过同款教训）。
 *
 * ── 依赖的官方能力（均已真机验证）────────────────────────────────────────────
 *  · PDF：`pdfService` 渲染 + 自写 stored-only zip → epub（docs/PDF支持方案决策-2026-10-19.md §11）
 *  · DOCX：`@ohos.zlib.decompressFile`（要求 `.zip` 后缀）+ 自研 OOXML 解析
 *  · epub 结构：`EpubBuilder`（mimetype 首个且不压缩）
 */
import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { display } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { Books } from '../../database/entities/Books';
import { PdfImporter, ConvertProgress, ConvertResult } from './PdfImporter';
import { DocxImporter } from './DocxImporter';
import {
  FMT_MASTER_ENABLED, FMT_PDF_ENABLED, FMT_DOCX_ENABLED, FMT_CACHE_DIR, FMT_CACHE_VER,
  isPdfPath, isDocxPath, isPreviewOnlyExt, extOf
} from './FormatFlags';

const DOMAIN: number = 0x0000;
const TAG: string = 'FmtResolver';

export class BookSourceResolver {
  /** 同一本书并发的重复转换只跑一次 */
  private static inflight: Map<string, Promise<string | null>> = new Map<string, Promise<string | null>>();
  /** 最近一次失败原因（阅读页拿它给用户看） */
  static lastError: string = '';

  private static root(ctx: common.UIAbilityContext): string {
    return ctx.filesDir + '/' + FMT_CACHE_DIR;
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
        hilog.error(DOMAIN, TAG, 'mkdir failed %{public}s', path);
      }
    }
  }

  /** 缓存键：`<id>_<size>_<mtime秒>`；源文件被替换 ⇒ 自动落到新目录 */
  private static keyOf(book: Books): string {
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
    return (book.id ?? -1) + '_' + size + '_' + mtime + '_' + FMT_CACHE_VER;
  }

  /** 该书的可读 epub 路径（**不管是否已生成**），非转换类格式返回 null */
  static epubPathFor(ctx: common.UIAbilityContext, book: Books): string | null {
    const src: string = book.bookUrl ?? '';
    if (!FMT_MASTER_ENABLED || src.length === 0) {
      return null;
    }
    const needPdf: boolean = isPdfPath(src) && FMT_PDF_ENABLED;
    const needDocx: boolean = isDocxPath(src) && FMT_DOCX_ENABLED;
    if (!needPdf && !needDocx) {
      return null;
    }
    return BookSourceResolver.root(ctx) + '/' + BookSourceResolver.keyOf(book) + '/book.epub';
  }

  /** 已生成好的 epub（同步查，给听书等不能等待的场景用）；没有 ⇒ null */
  static cachedReadablePath(ctx: common.UIAbilityContext, book: Books): string | null {
    const p: string | null = BookSourceResolver.epubPathFor(ctx, book);
    if (p === null) {
      return null;
    }
    try {
      return fs.accessSync(p) ? p : null;
    } catch (e) {
      return null;
    }
  }

  /** `.doc` 这类"只能预览"的格式 */
  static isPreviewOnly(book: Books): boolean {
    return isPreviewOnlyExt(book.bookUrl ?? '');
  }

  /**
   * 取"可读路径"：转换类格式 → 生成/命中缓存后返回 epub；其它格式 → `null`（调用方走原逻辑）。
   * 失败返回 null，并把原因写进 `lastError`。
   */
  static async ensureReadable(ctx: common.UIAbilityContext, book: Books,
    onProgress: (p: ConvertProgress) => void): Promise<string | null> {
    const out: string | null = BookSourceResolver.epubPathFor(ctx, book);
    if (out === null) {
      return null;
    }
    const cached: string | null = BookSourceResolver.cachedReadablePath(ctx, book);
    if (cached !== null) {
      hilog.info(DOMAIN, TAG, 'cache hit %{public}s', cached);
      return cached;
    }
    const key: string = BookSourceResolver.keyOf(book);
    const running: Promise<string | null> | undefined = BookSourceResolver.inflight.get(key);
    if (running !== undefined) {
      return running;
    }
    const task: Promise<string | null> = BookSourceResolver.doConvert(ctx, book, out, key, onProgress);
    BookSourceResolver.inflight.set(key, task);
    try {
      return await task;
    } finally {
      BookSourceResolver.inflight.delete(key);
    }
  }

  private static async doConvert(ctx: common.UIAbilityContext, book: Books, out: string, key: string,
    onProgress: (p: ConvertProgress) => void): Promise<string | null> {
    const src: string = book.bookUrl ?? '';
    const dir: string = out.substring(0, out.lastIndexOf('/'));
    BookSourceResolver.ensureDir(BookSourceResolver.root(ctx));
    BookSourceResolver.ensureDir(dir);
    const title: string = (book.bookName ?? 'book').replace(/\.[^.]+$/, '');
    const author: string = book.author ?? '暂无';
    try {
      let res: ConvertResult;
      if (isPdfPath(src)) {
        hilog.info(DOMAIN, TAG, 'convert PDF → %{public}s', out);
        res = await PdfImporter.convert(src, out, title, author, onProgress);
      } else {
        // zlib.decompressFile 硬性要求 .zip 后缀（@ohos.zlib.d.ts:1010-1033）
        const zipPath: string = dir + '/src.zip';
        const f = fs.openSync(src, fs.OpenMode.READ_ONLY);
        try {
          fs.copyFileSync(f.fd, zipPath);
        } finally {
          fs.closeSync(f);
        }
        hilog.info(DOMAIN, TAG, 'convert DOCX → %{public}s', out);
        res = await DocxImporter.convert(zipPath, dir, out, title, author, onProgress);
        try {
          fs.unlinkSync(zipPath);
        } catch (e) {
          // 忽略
        }
      }
      if (!res.ok) {
        BookSourceResolver.lastError = res.message;
        hilog.error(DOMAIN, TAG, 'convert failed: %{public}s', res.message);
        return null;
      }
      BookSourceResolver.lastError = '';
      return out;
    } catch (e) {
      BookSourceResolver.lastError = e instanceof Error ? e.message : String(e);
      hilog.error(DOMAIN, TAG, 'convert threw: %{public}s', BookSourceResolver.lastError);
      return null;
    }
  }

  /**
   * 导入时给新格式生成"自带封面"（PDF=第 0 页；DOCX=docProps 缩略图或首张图）。
   * 返回封面沙箱路径；失败一律 `''`（绝不阻塞导入）。
   */
  static async ensureBuiltinCover(ctx: common.UIAbilityContext, srcPath: string, bookName: string): Promise<string> {
    try {
      if (!FMT_MASTER_ENABLED || srcPath.length === 0) {
        return '';
      }
      const e: string = extOf(srcPath);
      if (e !== '.pdf' && e !== '.docx') {
        return '';
      }
      const coverDir: string = BookSourceResolver.root(ctx) + '/covers';
      BookSourceResolver.ensureDir(BookSourceResolver.root(ctx));
      BookSourceResolver.ensureDir(coverDir);
      let st = 0;
      let mt = 0;
      try {
        const s = fs.statSync(srcPath);
        st = s.size;
        mt = Math.floor(s.mtime);
      } catch (err) {
        return '';
      }
      const safeName: string = bookName.replace(/[\\/:*?"<>|]/g, '_');
      const base: string = coverDir + '/' + safeName + '_' + st + '_' + mt;
      for (const ext of ['.jpg', '.png']) {
        try {
          if (fs.accessSync(base + ext)) {
            return base + ext;
          }
        } catch (err) {
          // 不存在 → 继续
        }
      }
      if (e === '.pdf') {
        return await PdfImporter.renderCover(srcPath, base + '.jpg',
          display.getDefaultDisplaySync().width);
      }
      // docx：解压找 thumbnail / 首张图
      const work: string = BookSourceResolver.root(ctx) + '/cov_' + st + '_' + mt;
      BookSourceResolver.ensureDir(work);
      const zipPath: string = work + '/c.zip';
      const f = fs.openSync(srcPath, fs.OpenMode.READ_ONLY);
      try {
        fs.copyFileSync(f.fd, zipPath);
      } finally {
        fs.closeSync(f);
      }
      const cover: string = await DocxImporter.extractCover(zipPath, work + '/unzip', base);
      try {
        fs.unlinkSync(zipPath);
      } catch (err) {
        // 忽略
      }
      return cover;
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'cover failed: %{public}s', JSON.stringify(e));
      return '';
    }
  }
}
