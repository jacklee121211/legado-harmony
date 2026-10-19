/**
 * 最小 **stored-only（不压缩）ZIP 写入器** —— 用于在设备上生成 epub。
 *
 * ── 为什么不用 `@ohos.zlib.compressFiles` ────────────────────────────────────
 * ① 官方 `@ohos.zlib.d.ts:1010-1033` 对 `decompressFile` 明确要求 inFile 后缀必须是 `.zip`；
 *    `compressFiles(inFiles: Array<string>, outFile: string, options)` 的**输出目录结构语义未文档化**
 *    （传文件夹会多一层顶层目录 ⇒ epub 的 `mimetype` 就不在根上，规范要求它必须是第一个且不压缩的条目）。
 * ② epub 规范（OCF）要求 `mimetype` 是**第一个条目且不压缩**；我们自写 ZIP 就能 100% 控制顺序与压缩方式。
 * ③ 页图本身是 JPEG（已压缩），再 deflate 几乎没有收益；stored 唯一代价是 xhtml/css 几十 KB。
 *
 * ── 格式依据 ────────────────────────────────────────────────────────────────
 * ZIP 规范（PKWARE APPNOTE）：本地文件头 30B + 文件名 + 数据；中央目录项 46B + 文件名；EOCD 22B。
 * 全部字段小端序；存储方式 method=0（stored）；通用标志位 bit11=1 表示文件名是 UTF-8（书名/章节名含中文必须置位）。
 *
 * ── 写入方式 ────────────────────────────────────────────────────────────────
 * 顺序写文件（不拼大内存）：`fs.writeSync(fd, buf)` 的 `offset` 语义是"当前 filePointer + offset"，
 * 不传 offset 即**从当前文件指针续写**（SDK `@ohos.file.fs.d.ts:5738` WriteOptions 原文：
 * "By default, data is written from the filePointer"）⇒ 可以边算边写，峰值内存只有单条数据。
 */
import { fileIo as fs } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0x0000;
const TAG: string = 'ZipWriter';

/** 中央目录项元数据 */
interface ZipMeta {
  name: string;
  crc: number;
  size: number;
  offset: number;
}

export class ZipWriter {
  private file: fs.File | null = null;
  private offset: number = 0;
  private metas: ZipMeta[] = [];
  private closed: boolean = false;
  private static crcTable: number[] | null = null;

  constructor(outPath: string) {
    this.file = fs.openSync(outPath, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    this.offset = 0;
  }

  /** CRC32 查表（IEEE 802.3 多项式 0xEDB88320） */
  private static table(): number[] {
    if (ZipWriter.crcTable !== null) {
      return ZipWriter.crcTable;
    }
    const t: number[] = [];
    for (let n = 0; n < 256; n++) {
      let c: number = n;
      for (let k = 0; k < 8; k++) {
        c = (c & 1) === 1 ? (0xEDB88320 ^ (c >>> 1)) : (c >>> 1);
      }
      t.push(c >>> 0);
    }
    ZipWriter.crcTable = t;
    return t;
  }

  private static crc32(bytes: Uint8Array): number {
    const t: number[] = ZipWriter.table();
    let crc: number = 0xFFFFFFFF;
    for (let i = 0; i < bytes.length; i++) {
      crc = (t[(crc ^ bytes[i]) & 0xFF] ^ (crc >>> 8)) >>> 0;
    }
    return (crc ^ 0xFFFFFFFF) >>> 0;
  }

  /**
   * UTF-8 编码（手写，不依赖 `util.TextEncoder`）。
   * 为什么不用 `new util.TextEncoder().encodeInto()`：SDK `@ohos.util.d.ts:482-496` 已把它标 `@deprecated`，
   * 而替代 API `encodeIntoUint8Array(input, dest)` 需要预分配缓冲区、拿不到长度就得再遍历一遍。
   * 这里只处理文件名/XML 文本，手写 6 行更直接、无弃用告警。
   */
  private static utf8(s: string): Uint8Array {
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
        out.push(0xF0 | (c >> 18), 0x80 | ((c >> 12) & 0x3F), 0x80 | ((c >> 6) & 0x3F), 0x80 | (c & 0x3F));
      }
    }
    return new Uint8Array(out);
  }

  private write(buf: ArrayBuffer): void {
    if (this.file === null) {
      throw new Error('ZipWriter not open');
    }
    fs.writeSync(this.file.fd, buf);
    this.offset += buf.byteLength;
  }

  /** 追加一个"不压缩"条目。name 用 `/` 分隔（如 `OEBPS/p1.xhtml`） */
  add(name: string, data: ArrayBuffer): void {
    if (this.closed) {
      throw new Error('ZipWriter already closed');
    }
    const nameBytes: Uint8Array = ZipWriter.utf8(name);
    const bytes: Uint8Array = new Uint8Array(data);
    const crc: number = ZipWriter.crc32(bytes);
    const size: number = data.byteLength;
    const entryOffset: number = this.offset;

    // ── 本地文件头（30 + nameLen）──
    const lh: ArrayBuffer = new ArrayBuffer(30 + nameBytes.length);
    const lv: DataView = new DataView(lh);
    lv.setUint32(0, 0x04034b50, true);   // 签名
    lv.setUint16(4, 20, true);           // version needed
    lv.setUint16(6, 0x0800, true);       // 通用标志：bit11 = UTF-8 文件名
    lv.setUint16(8, 0, true);            // 压缩方式 0 = stored
    lv.setUint16(10, 0, true);           // 修改时间（固定 00:00:00）
    lv.setUint16(12, 0x0021, true);      // 修改日期（1980-01-01）
    lv.setUint32(14, crc, true);
    lv.setUint32(18, size, true);        // 压缩后大小（stored ⇒ 相等）
    lv.setUint32(22, size, true);        // 原始大小
    lv.setUint16(26, nameBytes.length, true);
    lv.setUint16(28, 0, true);           // extra 长度
    new Uint8Array(lh).set(nameBytes, 30);
    this.write(lh);
    this.write(data);

    this.metas.push({ name: name, crc: crc, size: size, offset: entryOffset });
  }

  /** 写中央目录 + EOCD 并关闭文件 */
  close(): void {
    if (this.closed) {
      return;
    }
    this.closed = true;
    const cdStart: number = this.offset;
    for (const m of this.metas) {
      const nameBytes: Uint8Array = ZipWriter.utf8(m.name);
      const ch: ArrayBuffer = new ArrayBuffer(46 + nameBytes.length);
      const cv: DataView = new DataView(ch);
      cv.setUint32(0, 0x02014b50, true);  // 签名
      cv.setUint16(4, 20, true);          // version made by
      cv.setUint16(6, 20, true);          // version needed
      cv.setUint16(8, 0x0800, true);      // flags
      cv.setUint16(10, 0, true);          // method
      cv.setUint16(12, 0, true);          // time
      cv.setUint16(14, 0x0021, true);     // date
      cv.setUint32(16, m.crc, true);
      cv.setUint32(20, m.size, true);
      cv.setUint32(24, m.size, true);
      cv.setUint16(28, nameBytes.length, true);
      cv.setUint16(30, 0, true);          // extra
      cv.setUint16(32, 0, true);          // comment
      cv.setUint16(34, 0, true);          // disk number
      cv.setUint16(36, 0, true);          // internal attrs
      cv.setUint32(38, 0, true);          // external attrs
      cv.setUint32(42, m.offset, true);   // 本地头偏移
      new Uint8Array(ch).set(nameBytes, 46);
      this.write(ch);
    }
    const cdSize: number = this.offset - cdStart;
    const eocd: ArrayBuffer = new ArrayBuffer(22);
    const ev: DataView = new DataView(eocd);
    ev.setUint32(0, 0x06054b50, true);
    ev.setUint16(4, 0, true);
    ev.setUint16(6, 0, true);
    ev.setUint16(8, this.metas.length, true);
    ev.setUint16(10, this.metas.length, true);
    ev.setUint32(12, cdSize, true);
    ev.setUint32(16, cdStart, true);
    ev.setUint16(20, 0, true);
    this.write(eocd);

    try {
      if (this.file !== null) {
        fs.closeSync(this.file);
        this.file = null;
      }
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'close err %{public}s', JSON.stringify(e));
    }
    hilog.info(DOMAIN, TAG, 'zip done: entries=%{public}d bytes=%{public}d', this.metas.length, this.offset);
  }
}
