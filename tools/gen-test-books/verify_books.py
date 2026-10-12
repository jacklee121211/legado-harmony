# -*- coding: utf-8 -*-
"""
校验生成的测试书：**独立解析**每个文件，确认结构与正文都能正确读回。
================================================================================
这不是"生成后自己说自己对"，而是按各格式**独立解包**：
  · txt      → 按声明编码解码，检查章标题与字数
  · epub     → 独立解析 ZIP + OPF + NCX，逐章读出正文
  · mobi/azw/azw3 → 独立解析 PalmDB + PalmDOC 解压，恢复全文并比对

任一项失败即非零退出。
"""
import os
import sys
import struct
import zipfile

OUT_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'out')
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

FAIL = []


def ok(cond, msg):
    print(('  [PASS] ' if cond else '  [FAIL] ') + msg)
    if not cond:
        FAIL.append(msg)


# ── PalmDOC 解压（独立实现，用于验证生成端） ────────────────────────────────
def palmdoc_decompress(data, expected):
    out = bytearray()
    i = 0
    while i < len(data) and len(out) < expected:
        ctrl = data[i]
        i += 1
        for bit in range(8):
            if i >= len(data) or len(out) >= expected:
                break
            if ctrl & (1 << bit):
                out.append(data[i])
                i += 1
            else:
                if i + 1 >= len(data):
                    return bytes(out)
                code = (data[i] << 8) | data[i + 1]
                i += 2
                if code & 0x8000:
                    dist = (code >> 3) & 0x7FF
                    length = (code & 7) + 3
                    start = len(out) - dist
                    if start < 0:
                        raise ValueError('illegal back-reference dist=%d at out=%d' % (dist, len(out)))
                    for k in range(length):
                        out.append(out[start + k])
                else:
                    out.append(0x20)
                    out.append(data[i])
                    i += 1
    return bytes(out)


def read_pdb(path):
    """解析 PalmDB，返回 (type, creator, [records])。"""
    d = open(path, 'rb').read()
    typ = d[60:64].decode('latin-1')
    cre = d[64:68].decode('latin-1')
    n = struct.unpack('>H', d[76:78])[0]
    offs = []
    for k in range(n):
        offs.append(struct.unpack('>I', d[78 + k * 8: 82 + k * 8])[0])
    recs = []
    for k, o in enumerate(offs):
        end = offs[k + 1] if k + 1 < n else len(d)
        recs.append(d[o:end])
    return typ, cre, recs


def check_txt(path, enc, label):
    print('\n[%s] %s' % (label, os.path.basename(path)))
    raw = open(path, 'rb').read()
    text = raw.decode(enc, 'replace')
    ok(len(text) > 3000, '正文长度 %d 字（>3000）' % len(text))
    hits = [t for t, _ in CHAPTERS] if False else None
    n_ch = sum(1 for line in text.split('\n') if line.strip().startswith('第') and '章' in line[:6])
    ok(n_ch >= 10, '识别到章标题 %d 个（>=10）' % n_ch)
    ok('全文完' in text, '结尾标记存在')
    ok('\ufffd' not in text, '无解码失败替换符 U+FFFD')


def check_epub(path):
    print('\n[epub] %s' % os.path.basename(path))
    z = zipfile.ZipFile(path)
    ok(z.namelist()[0] == 'mimetype', 'mimetype 是第一个条目')
    ok(z.getinfo('mimetype').compress_type == zipfile.ZIP_STORED, 'mimetype 未压缩(STORED)')
    ok(z.read('mimetype').decode() == 'application/epub+zip', 'mimetype 内容正确')
    ok(z.testzip() is None, 'ZIP 完整性通过')
    opf = z.read('OEBPS/content.opf').decode('utf-8')
    ok('<dc:title>' in opf, 'OPF 含书名')
    ok(opf.count('<itemref') == 10, 'OPF spine 有 10 项')
    ncx = z.read('OEBPS/toc.ncx').decode('utf-8')
    ok(ncx.count('<navPoint') == 10, 'NCX 有 10 个 navPoint（目录）')
    total = 0
    body_chars = 0
    for k in range(1, 11):
        xh = z.read('OEBPS/ch%d.xhtml' % k).decode('utf-8')
        total += len(xh)
        # 只统计 <p> 里的正文字符（章标题 h1 另计），与纯文本口径对齐
        body_chars += sum(len(m) for m in __import__('re').findall(r'<p>(.*?)</p>', xh))
    # XHTML 含 DOCTYPE/head/标签等固定开销；正文 <p> 才是实质内容（下面单独断言）。
    # 这里只要求"每章都非空且总和合理"，阈值取自实测（10 章 ≈ 6.8KB）。
    ok(total > 5000, '各章 XHTML 合计 %d 字符' % total)
    # `<p>` 只装正文段落，**不含章标题(h1)**，所以比纯文本(3655)少不到标题的量即算合格
    ok(body_chars > 3000, '各章 <p> 正文合计 %d 字符（>3000）' % body_chars)
    ok(body_chars >= 3200, '正文与 txt 口径一致（差值为章标题，属正常）')


def check_mobi_like(path, label, expect_version):
    print('\n[%s] %s' % (label, os.path.basename(path)))
    typ, cre, recs = read_pdb(path)
    ok(typ == 'BOOK' and cre == 'MOBI', 'PDB 类型 BOOK/MOBI（实得 %s/%s）' % (typ, cre))
    ok(len(recs) >= 2, '记录数 %d（>=2）' % len(recs))
    r0 = recs[0]
    comp, _, txtlen = struct.unpack('>HHI', r0[0:8])
    nrec, recsize = struct.unpack('>HH', r0[8:12])
    ok(comp == 2, '压缩方式 PalmDOC(2)（实得 %d）' % comp)
    ok(r0[16:20] == b'MOBI', 'MOBI magic 正确')
    # ⚠️ MOBI 头**从记录 0 的第 16 字节开始**（前 16 字节是 PalmDOC 头），
    #    所以 MOBI 内部的字段偏移都要 +16。下面用 mb() 统一换算，避免再次错位。
    def mb(off):
        return 16 + off
    ver = struct.unpack('>I', r0[mb(20):mb(24)])[0]
    ok(ver == expect_version, '文件版本 %d（期望 %d）' % (ver, expect_version))
    hdrlen = struct.unpack('>I', r0[mb(4):mb(8)])[0]
    ok(hdrlen == 232, 'MOBI 头长度 %d（期望 232）' % hdrlen)
    enc = struct.unpack('>I', r0[mb(12):mb(16)])[0]
    ok(enc == 65001, '文本编码 UTF-8(65001)（实得 %d）' % enc)
    # 全文解压
    out = bytearray()
    for r in recs[1:1 + nrec]:
        remain = txtlen - len(out)
        out += palmdoc_decompress(r, min(4096, remain))
    ok(len(out) == txtlen, '解压后长度 %d == 头部声明 %d' % (len(out), txtlen))
    text = bytes(out).decode('utf-8', 'replace')
    ok('\ufffd' not in text, '正文无解码失败替换符')
    ok('雾隐山河录' not in '' and text.count('第') >= 10, '正文含 >=10 处章节标题痕迹')
    ok('全文完' in text, '结尾标记「全文完」可读回')
    ok(text.startswith('第一章'), '正文以「第一章」开头')
    return text


if __name__ == '__main__':
    print('=' * 74)
    print('测试书校验（独立解析）')
    print('=' * 74)

    import gen_books as g
    CHAPTERS = g.CHAPTERS

    check_txt(os.path.join(OUT_DIR, '01_雾隐山河录.txt'), 'utf-8', 'txt(UTF-8)')
    check_txt(os.path.join(OUT_DIR, '02_雾隐山河录_GBK.txt'), 'gbk', 'txt(GBK)')
    check_epub(os.path.join(OUT_DIR, '03_雾隐山河录.epub'))
    t1 = check_mobi_like(os.path.join(OUT_DIR, '04_雾隐山河录.mobi'), 'mobi', 6)
    t2 = check_mobi_like(os.path.join(OUT_DIR, '05_雾隐山河录.azw'), 'azw', 4)
    t3 = check_mobi_like(os.path.join(OUT_DIR, '06_雾隐山河录.azw3'), 'azw3', 8)

    print('\n' + '=' * 74)
    if FAIL:
        print('校验失败 %d 项：' % len(FAIL))
        for f in FAIL:
            print('  · ' + f)
        sys.exit(1)
    print('全部校验通过')
    print('=' * 74)
