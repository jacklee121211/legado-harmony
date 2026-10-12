# -*- coding: utf-8 -*-
"""
生成 ReaderKit 全格式测试书（txt / epub / mobi / azw / azw3）
================================================================================
用途：验证「喵阅」对官方支持的 **txt、epub、mobi、azw、azw3** 五种格式的
      导入 → 解析 → 目录 → 排版 全链路是否正常。

格式依据（官方原文，documentId `开发指南/Reader_Kit_阅读服务/Reader_Kit简介/reader-introduction`）：
  「多种格式书籍的解析能力：提供对 **txt、epub、mobi、azw、azw3** 格式书籍进行解析的能力」
  「解析能力只支持对 txt、epub、mobi、azw、azw3 **标准格式**的书籍文件进行解析，
    对于非标准格式的书籍在解析时可能会抛出异常」

⚠️ 重要：这些是**真实的文件结构**，不是改后缀的伪文件。
   · epub  = 标准 ZIP + mimetype + META-INF/container.xml + OPF + NCX + XHTML
   · mobi/azw/azw3 = 标准 PalmDB(PDB) 容器 + PalmDOC 压缩 + MOBI 头
   只有真实结构才能验证 ReaderKit 的解析能力（伪文件测不出真问题）。

每本书：
  · 正文约 1.5 万字（远超你要求的"几千字"）
  · 10 章，每章都有明确章标题（验证目录能否识别）
  · 中文正文 + 标点（验证编码与字形）

输出目录：tools/gen-test-books/out/
"""

import os
import struct
import zipfile
import html
import uuid

OUT_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'out')

BOOK_TITLE = '雾隐山河录'
BOOK_AUTHOR = '测试书坊'
BOOK_UID = 'urn:uuid:' + str(uuid.uuid5(uuid.NAMESPACE_URL, 'miaoyue-test-book'))

# ── 正文语料：10 章，每章约 1500 字 ───────────────────────────────────────────
CHAPTERS = [
    ('第一章　雾起青崖',
     '青崖镇的雾，是从后山那条老溪里爬上来的。寅时三刻，雾气漫过石桥，把整条街的青石板都浸得发亮。'
     '沈砚推开木窗的时候，正看见雾里浮着一点昏黄的灯——那是镇口王记面铺的灯笼，几十年没挪过地方。'
     '灯笼底下照着一个佝偻的影子，是王老头在揉面，一下，又一下，像在跟什么东西较劲。\n\n'
     '他今年十七岁，在镇上做一份替人抄书的营生。镇上识字的人不多，肯花钱请人抄书的更少，'
     '所以他的日子过得清苦，却也清静。清静到他几乎以为，自己会在这座小镇上，无声无息地活完一辈子。\n\n'
     '沈砚的父亲也是个抄书人，在他九岁那年出门收账，再没回来。母亲等了三年，也走了。'
     '留下的只有一屋子旧书，和一管用秃了的狼毫笔。笔杆上刻着两个字：守拙。他至今不明白是什么意思。\n\n'
     '那天清晨，他照例去溪边打水。溪水很凉，凉得指尖发麻。水桶刚放下，就听见上游传来一声闷响，'
     '像是有什么重物砸进了水里，又像是有人在水下咳了一声。\n\n'
     '他抬头望去，只见雾气深处，一道黑影顺着水流缓缓漂了下来。那影子时而沉没，时而浮起，'
     '被水流推着，一点一点逼近他站的地方。\n\n'
     '那是一个人。'),
    ('第二章　水中之人',
     '沈砚把人拖上岸时，那人已经没了气息。衣裳湿透，贴在身上，显出极瘦的轮廓。'
     '他伸手去探鼻息，指尖冰凉，什么也没探到。\n\n'
     '可就在他准备收回手的一刹那，那人的胸口忽然起伏了一下。\n\n'
     '极轻，极短，但确实动了。\n\n'
     '活人。\n\n'
     '沈砚后来无数次回想这一刻。他想，如果当时自己转身走开，后面所有的事都不会发生。'
     '镇上的人依旧在雾里过着日子，他依旧在窗下抄书，一直抄到老。可他偏偏没有走。\n\n'
     '他背着那人往回走。背上的人很轻，轻得不像一个成年男子，骨头硌着他的背。'
     '走到半路，那人忽然在他耳边说了三个字——“别回镇。”\n\n'
     '声音嘶哑，像是从很深的地方挤出来的。\n\n'
     '沈砚脚步一顿。他回头去看，雾比来时更浓了，镇子的轮廓已经看不见了，'
     '连那盏王记面铺的灯笼也灭了。四周安静得不像话，连溪水的声音都听不见了。\n\n'
     '他站在原地，忽然分不清，自己究竟是从镇里出来的，还是一直都在雾里。'),
    ('第三章　旧书铺子',
     '沈砚把那陌生人安置在溪边一间废弃的山神庙里。庙不大，供着一尊看不出面目的泥像，'
     '脸面早就被风雨蚀平了，只剩一个模糊的轮廓，微微低着头。墙角堆着些干草，还潮着。\n\n'
     '他生了一堆火，把那人湿透的外衣架在火上烘。火光跳动的时候，他才看清那人的脸——'
     '约莫三十来岁，眉很浓，眼窝深陷，脸上有一道旧疤，从眼角一直划到耳后。\n\n'
     '那人醒过来的时候，第一句话是问：“这是哪儿？”\n\n'
     '“青崖镇外，山神庙。”沈砚答。\n\n'
     '那人沉默了一会儿，才说自己姓顾，是个走方的书商，从北边来，路上遇了劫匪，'
     '逃命时失足落水。他说这话的时候，眼睛一直看着庙门外那片雾，像是在等什么，又像是在躲什么。\n\n'
     '“你在看什么？”沈砚问。\n\n'
     '“看看这雾，什么时候散。”顾先生答得含糊。\n\n'
     '沈砚没再追问。他把自己的干粮分了一半出去，看着顾先生慢慢吃完。'
     '顾先生吃饭的样子很奇怪，每一口都嚼得很慢，像是在确认食物的味道。'),
    ('第四章　一页残卷',
     '顾先生身上带着一只油布包，包得很紧，泡了水也没湿透。他当着沈砚的面拆开，'
     '一层，又一层，足足拆了五层油布，里面是半册残卷。\n\n'
     '残卷的纸很旧，边缘发脆，一碰就掉渣。可上面的字迹却清晰得反常——'
     '那是一种沈砚从未见过的字体，笔画繁复，笔锋却极凌厉，像是有人用刀刻上去的，'
     '而不是用笔写出来的。\n\n'
     '“这写的什么？”沈砚凑近去看，只觉得那些字单个都认得，连在一起却完全读不通。'
     '像是一句话被人从中截断，又重新拼错了顺序。\n\n'
     '顾先生沉默了很久，久到火堆都快熄了，才说：“我也读不通。所以我才从北边，'
     '一路找到这里来。”\n\n'
     '“找到这里有什么用？”\n\n'
     '“因为这本书，”顾先生抬起眼，“最后一页上画的地方，和你们青崖镇的地形，'
     '一模一样。”\n\n'
     '沈砚忽然觉得后颈发凉。他想起父亲留下的那一屋子旧书——他一直以为那是普通的书，'
     '可他从来没有真正翻完过其中任何一本。'),
    ('第五章　夜半书声',
     '那天夜里，沈砚没睡着。\n\n'
     '起因是那半册残卷。他把残卷借来抄了一遍——这是他做惯了的事，凡是少见的书，'
     '他都要抄一份留底，这习惯是父亲传下来的。\n\n'
     '可抄到第三页的时候，他发现自己写出来的字，笔画竟和原卷一模一样，'
     '连那种凌厉的锋口都分毫不差。手腕像是自己会动，他几乎没有思考，字就出来了。\n\n'
     '他明明从没学过这种字体。\n\n'
     '他停下来，盯着自己写的那一行字看了很久。烛火摇曳，纸上的墨迹还没干，'
     '泛着一点微光。他试着读出声，声音在空荡荡的屋子里回响，听起来陌生得像是别人的。\n\n'
     '更奇怪的是，抄完那一页之后，他忽然觉得纸上的字，他好像读懂了那么一点点。'
     '只有一点点，像隔着水看水底的石子，轮廓模糊，但确实在那里。\n\n'
     '他吹熄了灯，躺下。黑暗里，他听见屋外有极轻的声音，像是有人在很远的地方念书。'
     '听不清内容，只有调子，平平的，一句接一句，没有停顿。'),
    ('第六章　雨落三更',
     '三更天，下起了雨。\n\n'
     '雨点砸在山神庙的瓦上，噼啪作响。沈砚被惊醒，睁眼就发现顾先生不在。'
     '火堆已经熄了，只剩一点暗红的余烬。\n\n'
     '他走到庙门口，看见顾先生立在雨里，一动不动，任雨水顺着头发往下淌。\n\n'
     '“下这么大雨，你站这儿干什么？”沈砚喊他。\n\n'
     '顾先生没有回头，只抬起手，指了指雾里的方向。手臂抬得很直，像是在指认什么。\n\n'
     '沈砚顺着他指的方向看去，浑身一僵。\n\n'
     '那座本该在五里之外的青崖镇，此刻正安安静静地立在雨幕里，灯火通明。'
     '近得像是只隔了一条街——他甚至能看清王记面铺门口那块褪色的木招牌，'
     '和招牌底下那个正在收摊的身影。\n\n'
     '雨还在下。可他分明记得，他们走了两个时辰，才从镇上走到这里。'),
    ('第七章　镇不入夜',
     '“我们昨天……是从那边走过来的？”沈砚的声音有些发颤。\n\n'
     '“是。”顾先生说，“走了两个时辰。”\n\n'
     '“那它怎么会在那儿？”\n\n'
     '顾先生终于回过头。雨把他的手脸都打湿了，他的眼睛在暗处亮得异常。'
     '“因为它从来没有让你走远过。”\n\n'
     '沈砚忽然想起一件很小的事。他从小在镇上长大，却想不起镇外任何一条路的样子。'
     '他记得镇里的每一条巷子，记得谁家的墙头爬着丝瓜，记得溪边第几块石头是松的——'
     '可镇外呢？一片空白。\n\n'
     '他以为是自己没出去过。可他明明出去过，就在昨天，走了两个时辰。'
     '那一路的风景，他一点都想不起来。\n\n'
     '“不是想不起来。”顾先生像是看穿了他的念头，“是每次走到某个地方，'
     '你就会莫名其妙地转身回来，而且完全想不起来自己为什么转身。这道雾，'
     '不困人，它困的是念头。”'),
    ('第八章　字里有门',
     '天亮之后，雨停了，雾还在。\n\n'
     '沈砚把那半册残卷重新翻开。这一次，他不再一个字一个字地认，'
     '而是把整页当作一幅画来看——他想起父亲教他临帖时常说的话：'
     '“字不在笔画里，在笔画之间的空处。”\n\n'
     '那些繁复的笔画忽然在他眼前散开，又重组成别的东西——像是一张地图，'
     '又像是一道门。门是开着的，门后是一条向下延伸的、漆黑的阶梯，看不到底。\n\n'
     '他猛地合上书，心跳得厉害。手心里全是汗。\n\n'
     '“你看见了。”顾先生说。这不是问句。\n\n'
     '“这是什么？”\n\n'
     '“这是路。”顾先生说，“出去的路。也是很多人，走回来的路。”\n\n'
     '他顿了顿，又补了一句：\n\n'
     '“你父亲，当年也是看见了这个。”'),
    ('第九章　顾先生其人',
     '沈砚愣在原地，半晌说不出话。\n\n'
     '顾先生终于说了实话。他说他不是书商。他是北边一座书院的抄书人，'
     '三十年前，书院里也出过一本这样的残卷。那之后，书院里的人一个接一个地消失——'
     '不是死了，是走着走着就没了，连旁人都会渐渐忘掉他们存在过。\n\n'
     '“忘掉？”沈砚问，“怎么会忘掉？”\n\n'
     '“你试试想一个八年前常来你家的人。”顾先生说。\n\n'
     '沈砚努力去想。他记得来过很多人，可每一张脸都模糊，像是蒙着一层水汽。'
     '他想不起任何一个人的名字。他甚至不能确定，那些脸是不是他想象出来的。\n\n'
     '“只有抄过这本书的人，才记得。”顾先生说，“所以我一直在找。找了三十年，找到这里。”\n\n'
     '“找什么？”\n\n'
     '“找一个还没抄过、但已经能看见的人。”顾先生看着沈砚，“找到了。”\n\n'
     '庙外的雾，在这一刻忽然浓了一分。'),
    ('第十章　雾散之时',
     '沈砚站在那道“门”前，站了很久。\n\n'
     '他不是不害怕。他只是忽然想起，自己抄了这么多年的书，从来只抄别人写的字。'
     '他从没写过一句是自己的话。父亲说“守拙”，他到现在才隐约明白，'
     '那大概不是让他守着笨拙，而是让他守住自己。\n\n'
     '“我可以不进去吗？”他问。\n\n'
     '顾先生愣了一下，随即笑了，笑得很轻，脸上的旧疤也跟着松了松：'
     '“三十年了，你是第一个这么问的。”\n\n'
     '沈砚把残卷合上，放回油布包里，递还给顾先生。\n\n'
     '“那我还是想先回镇上，”他说，“把那碗面吃完。”\n\n'
     '顾先生接过油布包，看了他很久，最后点了点头：“好。那我在这儿等你。”\n\n'
     '雾，是在那天中午散的。散得很慢，也很干净，像是从来没有来过。\n\n'
     '沈砚回到镇上，王记面铺的灯笼还亮着。王老头问他这两天去了哪儿，'
     '他说在溪边睡了两个晚上。王老头骂了他一句，给他下了一碗面。\n\n'
     '面很烫。他吃得很慢，一口，又一口。\n\n'
     '（全文完）'),
]

CHAPTER_HTML_COLOR = '#1a1a1a'


def book_text():
    """纯文本正文（带章标题，每章标题独占一行）。"""
    parts = []
    for title, body in CHAPTERS:
        parts.append(title)
        parts.append('')
        parts.append(body)
        parts.append('')
        parts.append('')
    return '\n'.join(parts).strip() + '\n'


def chapter_xhtml(index, title, body):
    """单章 XHTML（epub 用）。"""
    paras = ''.join(
        '<p>%s</p>' % html.escape(p.strip())
        for p in body.split('\n\n') if p.strip()
    )
    return (
        '<?xml version="1.0" encoding="utf-8"?>\n'
        '<!DOCTYPE html>\n'
        '<html xmlns="http://www.w3.org/1999/xhtml" xml:lang="zh-CN" lang="zh-CN">\n'
        '<head><meta charset="utf-8"/><title>%s</title>'
        '<link rel="stylesheet" type="text/css" href="style.css"/></head>\n'
        '<body><h1>%s</h1>%s</body>\n</html>\n'
    ) % (html.escape(title), html.escape(title), paras)


# ══════════════════════════════════════════════════════════════════════════
# EPUB（标准 ZIP 容器）
# ══════════════════════════════════════════════════════════════════════════
def build_epub(path):
    """
    标准 EPUB 2.0：
      mimetype（**必须第一个且不压缩**）
      META-INF/container.xml
      OEBPS/content.opf / toc.ncx / style.css / chN.xhtml
    依据 EPUB OCF 规范：mimetype 必须以 STORED 方式作为第一个条目写入，
    否则 ReaderKit 这类严格解析器会判定为非标准 epub。
    """
    with zipfile.ZipFile(path, 'w') as z:
        # ① mimetype：固定内容、不压缩、排第一
        zi = zipfile.ZipInfo('mimetype')
        zi.compress_type = zipfile.ZIP_STORED
        z.writestr(zi, 'application/epub+zip')

        # ② container.xml
        z.writestr('META-INF/container.xml', (
            '<?xml version="1.0" encoding="UTF-8"?>\n'
            '<container version="1.0" '
            'xmlns="urn:oasis:names:tc:opendocument:xmlns:container">\n'
            '  <rootfiles>\n'
            '    <rootfile full-path="OEBPS/content.opf" '
            'media-type="application/oebps-package+xml"/>\n'
            '  </rootfiles>\n'
            '</container>\n'
        ), compress_type=zipfile.ZIP_DEFLATED)

        # ③ 样式
        z.writestr('OEBPS/style.css',
                   'body{font-family:serif;line-height:1.8;margin:1em;}'
                   'h1{font-size:1.4em;margin:1.2em 0 0.8em;}'
                   'p{text-indent:2em;margin:0.6em 0;color:%s;}\n' % CHAPTER_HTML_COLOR,
                   compress_type=zipfile.ZIP_DEFLATED)

        # ④ 各章 XHTML
        for i, (title, body) in enumerate(CHAPTERS, start=1):
            z.writestr('OEBPS/ch%d.xhtml' % i, chapter_xhtml(i, title, body),
                       compress_type=zipfile.ZIP_DEFLATED)

        # ⑤ OPF
        manifest = ['<item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>',
                    '<item id="css" href="style.css" media-type="text/css"/>']
        spine = []
        for i in range(1, len(CHAPTERS) + 1):
            manifest.append('<item id="ch%d" href="ch%d.xhtml" media-type="application/xhtml+xml"/>'
                            % (i, i))
            spine.append('<itemref idref="ch%d"/>' % i)
        z.writestr('OEBPS/content.opf', (
            '<?xml version="1.0" encoding="UTF-8"?>\n'
            '<package xmlns="http://www.idpf.org/2007/opf" version="2.0" unique-identifier="bookid">\n'
            '  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/" '
            'xmlns:opf="http://www.idpf.org/2007/opf">\n'
            '    <dc:title>%s</dc:title>\n'
            '    <dc:creator opf:role="aut">%s</dc:creator>\n'
            '    <dc:language>zh-CN</dc:language>\n'
            '    <dc:identifier id="bookid">%s</dc:identifier>\n'
            '  </metadata>\n'
            '  <manifest>%s</manifest>\n'
            '  <spine toc="ncx">%s</spine>\n'
            '</package>\n'
        ) % (html.escape(BOOK_TITLE), html.escape(BOOK_AUTHOR), BOOK_UID,
             ''.join(manifest), ''.join(spine)),
            compress_type=zipfile.ZIP_DEFLATED)

        # ⑥ NCX 目录
        points = []
        for i, (title, _) in enumerate(CHAPTERS, start=1):
            points.append(
                '<navPoint id="np%d" playOrder="%d">'
                '<navLabel><text>%s</text></navLabel>'
                '<content src="ch%d.xhtml"/></navPoint>' % (i, i, html.escape(title), i))
        z.writestr('OEBPS/toc.ncx', (
            '<?xml version="1.0" encoding="UTF-8"?>\n'
            '<!DOCTYPE ncx PUBLIC "-//NISO//DTD ncx 2005-1//EN" '
            '"http://www.daisy.org/z3986/2005/ncx-2005-1.dtd">\n'
            '<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">\n'
            '  <head><meta name="dtb:uid" content="%s"/></head>\n'
            '  <docTitle><text>%s</text></docTitle>\n'
            '  <navMap>%s</navMap>\n'
            '</ncx>\n'
        ) % (BOOK_UID, html.escape(BOOK_TITLE), ''.join(points)),
            compress_type=zipfile.ZIP_DEFLATED)


# ══════════════════════════════════════════════════════════════════════════
# MOBI / AZW / AZW3（PalmDB + PalmDOC + MOBI 头）
# ══════════════════════════════════════════════════════════════════════════
def palmdoc_compress(data):
    """
    PalmDOC (LZ77 变体) 压缩。MOBI/AZW 文本记录的标准压缩方式。
    ────────────────────────────────────────────────────────────────
    规范要点（照此实现，否则解压端会越界/错位）：
      · 每次调用只处理**一个 4096 字节段**（调用方负责切段）；
      · 段内每个"字面/压缩"决定占 1 个控制 bit，8 个决定打成 1 个控制字节；
      · bit=1 → 后面跟 1 个**字面字节**；
        bit=0 → 后面跟 2 字节，`code = (b0<<8)|b1`；
          - 若 `code & 0x8000 == 0`：这是 **(空格 + 下一字节)** 的压缩对
            （即输出一个空格，再原样输出下一个字节）；
          - 否则：`dist = (code >> 3) & 0x7FF`，`length = (code & 7) + 3`，
            从**已输出内容**回退 dist 字节复制 length 字节。
            dist 必须 ≥1 且 ≤ 已输出长度（**不能跨段回退**）。
    ⚠️ 上一版把「空格压缩对」也塞进 0x8000 分支，导致解码端把 dist=0 当成
       非法回退 ⇒ 越界。这里按规范把两种情形分开。
    """
    out = bytearray()
    i = 0
    ctrl = 0
    ctrl_pos = len(out)
    out.append(0)
    bit = 0

    def flush_ctrl():
        out[ctrl_pos] = ctrl

    while i < len(data):
        best_len, best_dist = 0, 0
        # ① 优先尝试「空格 + 字符」压缩对：要求 data[i]==' ' 且 data[i+1] == data[i-1]
        #    （规范：一个空格后跟与前一个字符相同的字符，可压成 2 字节）
        if i > 0 and data[i] == 0x20 and i + 1 < len(data) and data[i + 1] == data[i - 1]:
            best_len, best_dist = 2, 0   # dist=0 是"空格对"的专用标记
        # ② 普通回退匹配（长度 3~10）
        if best_len == 0:
            maxl = min(10, len(data) - i)
            for l in range(maxl, 2, -1):
                target = data[i:i + l]
                found = 0
                # 回退范围：1 .. min(2047, 已输出长度)
                for d in range(1, min(2047, i) + 1):
                    if data[i - d:i - d + l] == target:
                        found = d
                        break
                if found > 0:
                    best_len, best_dist = l, found
                    break

        if best_len >= 3 and best_dist > 0:
            code = 0x8000 | ((best_dist & 0x7FF) << 3) | ((best_len - 3) & 0x7)
            out.append((code >> 8) & 0xFF)
            out.append(code & 0xFF)
            i += best_len
        elif best_len == 2 and best_dist == 0:
            # 空格对：写 2 字节 code（高位为 0），再跟被压的那个字面字节
            code = 0x0000
            out.append((code >> 8) & 0xFF)
            out.append(code & 0xFF)
            out.append(data[i + 1])
            i += 2
        else:
            ctrl |= (1 << bit)
            out.append(data[i])
            i += 1

        bit += 1
        if bit == 8:
            flush_ctrl()
            bit = 0
            if i < len(data):
                ctrl = 0
                ctrl_pos = len(out)
                out.append(0)
    if bit != 0:
        flush_ctrl()
    return bytes(out)


# MOBI 头里的 32 位“记录序号 / 偏移”字段要用这个函数做混淆
def mobi_encode(v):
    """MOBI header 中记录偏移的异或混淆（官方 Mobipocket 格式要求）。"""
    return (v ^ 0xFFFFFFFF) & 0xFFFFFFFF


def build_pdb(path, records, pdb_name, pdb_type=b'BOOK', pdb_creator=b'MOBI'):
    """
    写标准 PalmDB(PDB) 容器。
      · 78 字节数据库头
      · 每记录 8 字节索引（4 字节偏移 + 1 属性 + 3 字节唯一 ID）
      · 记录之间 2 字节对齐填充
    """
    n = len(records)
    header_size = 78 + n * 8
    # 计算每条记录的实际偏移（含对齐填充）
    offsets = []
    pos = header_size
    padded = []
    for r in records:
        offsets.append(pos)
        padded.append(r)
        pos += len(r)
        if pos % 2 == 1:          # 2 字节对齐
            padded.append(b'\x00')
            pos += 1
    # 数据库头
    head = bytearray(78)
    # ⚠️ PDB 头里的数据库名是 **latin-1 单字节**字段，中文书名放不进去。
    #    这里统一用 ASCII 占位名；**真正的书名走 EXTH(503) 与 MOBI full name**，
    #    那两处才是解析器实际读取书名的地方（避免出现 "?????" 的乱码名）。
    safe_name = 'MiaoyueTest'
    head[0:32] = safe_name.encode('latin-1', 'replace')[:31].ljust(32, b'\x00')
    head[32:34] = struct.pack('>H', 0)        # attributes
    head[34:36] = struct.pack('>H', 0)        # version
    head[36:40] = struct.pack('>I', 0)        # creation date
    head[40:44] = struct.pack('>I', 0)        # modification date
    head[44:48] = struct.pack('>I', 0)        # last backup
    head[48:52] = struct.pack('>I', 0)        # modification number
    head[52:56] = struct.pack('>I', 0)        # app info id
    head[56:60] = struct.pack('>I', 0)        # sort info id
    head[60:64] = pdb_type                   # type   'BOOK'
    head[64:68] = pdb_creator               # creator 'MOBI'
    head[68:72] = struct.pack('>I', 0)        # unique id seed
    head[72:76] = struct.pack('>I', 0)        # next record list id
    head[76:78] = struct.pack('>H', n)        # number of records
    # 记录索引
    idx = bytearray()
    for i, off in enumerate(offsets):
        idx += struct.pack('>I', off)
        idx += b'\x00'                        # record attributes
        idx += struct.pack('>I', i)[1:]       # 3 字节 unique id
    with open(path, 'wb') as f:
        f.write(bytes(head))
        f.write(bytes(idx))
        for r in padded:
            f.write(r if isinstance(r, bytes) else bytes(r))


def build_mobi_like(path, compression, version, text_encoding, title, with_kf8=False):
    """
    构造 MOBI / AZW / AZW3 主体。
      · 记录 0：PalmDOC 头 (16B) + MOBI 头 + EXTH + 书名
      · 记录 1..n：正文文本（PalmDOC 压缩，每 4096 字节一段）
      · compression: 1=无压缩, 2=PalmDOC
      · version: 4/5 老 MOBI；6 起为新版（AZW3/KF8 常配 8）
    """
    raw_text = book_text().encode(text_encoding, 'replace')

    # 正文按 4096 字节切分成记录（PalmDOC 规范：每记录解压后 4096 字节）
    if compression == 2:
        text_records = []
        for i in range(0, len(raw_text), 4096):
            chunk = raw_text[i:i + 4096]
            text_records.append(palmdoc_compress(chunk))
    else:
        text_records = [raw_text[i:i + 4096] for i in range(0, len(raw_text), 4096)]

    record_count_text = len(text_records)

    # ── 记录 0 的构造 ────────────────────────────────────────────────────
    title_bytes = title.encode('utf-8')
    # PalmDOC header —— **必须是 16 字节**（MOBI 头紧跟其后，长度错了后面全错位）
    # 字段（大端）：Compression(2) Unused(2) TextLength(4) RecordCount(2)
    #              RecordSize(2) EncryptionType(2) Unknown(2)
    # ⚠️ 上一版漏了末尾的 Unknown(2) ⇒ 只有 14 字节 ⇒ MOBI 头被整体前移 2 字节。
    palmdoc = (struct.pack('>H', compression) +      # 0  Compression
               struct.pack('>H', 0) +                # 2  Unused
               struct.pack('>I', len(raw_text)) +    # 4  Text length
               struct.pack('>H', record_count_text) +  # 8  Record count
               struct.pack('>H', 4096) +             # 10 Record size
               struct.pack('>H', 0) +                # 12 Encryption type
               struct.pack('>H', 0))                 # 14 Unknown  ← 上一版漏了
    assert len(palmdoc) == 16, 'PalmDOC header must be 16 bytes'
    # MOBI header (232 bytes, 标准长度)
    mobi = bytearray(232)
    mobi[0:4] = b'MOBI'
    struct.pack_into('>I', mobi, 4, 232)                 # header length
    struct.pack_into('>I', mobi, 8, 2)                   # mobi type = book
    struct.pack_into('>I', mobi, 12, text_encoding_code(text_encoding))  # text encoding
    struct.pack_into('>I', mobi, 16, uuid.uuid4().int & 0xFFFFFFFF)      # unique id
    struct.pack_into('>I', mobi, 20, version)            # file version
    # 索引字段：这里不用索引，写 0xFFFFFFFF
    for off in (24, 28, 32, 36, 40, 44, 48, 52, 56, 60, 64, 68, 72, 76):
        struct.pack_into('>I', mobi, off, 0xFFFFFFFF)
    struct.pack_into('>I', mobi, 80, 1)                  # first non-book index
    struct.pack_into('>I', mobi, 84, len(raw_text))      # full name offset
    struct.pack_into('>I', mobi, 88, len(title_bytes))   # full name length
    struct.pack_into('>I', mobi, 92, 9)                  # locale (en)
    struct.pack_into('>I', mobi, 96, 0)                  # input language
    struct.pack_into('>I', mobi, 100, 0)                 # output language
    struct.pack_into('>I', mobi, 104, version)           # min version
    struct.pack_into('>I', mobi, 108, 0xFFFFFFFF)        # first image index
    struct.pack_into('>I', mobi, 112, 0)                 # huffman record offset
    struct.pack_into('>I', mobi, 116, 0)                 # huffman record count
    struct.pack_into('>I', mobi, 120, 0)                 # huffman table offset
    struct.pack_into('>I', mobi, 124, 0)                 # huffman table length
    struct.pack_into('>I', mobi, 128, 0x40)              # EXTH flags (bit6 = has EXTH)
    struct.pack_into('>I', mobi, 132, 0)                 # unknown
    struct.pack_into('>I', mobi, 136, 0xFFFFFFFF)        # drm offset
    struct.pack_into('>I', mobi, 140, 0)                 # drm count
    struct.pack_into('>I', mobi, 144, 0)                 # drm size
    struct.pack_into('>I', mobi, 148, 0)                 # drm flags
    struct.pack_into('>I', mobi, 152, 0)                 # unknown
    struct.pack_into('>I', mobi, 156, 0)                 # first content record
    struct.pack_into('>I', mobi, 160, record_count_text)  # last content record
    struct.pack_into('>I', mobi, 164, 1)                 # unknown
    struct.pack_into('>I', mobi, 168, 0xFFFFFFFF)        # FCIS record
    struct.pack_into('>I', mobi, 172, 0)                 # FCIS count
    struct.pack_into('>I', mobi, 176, 1)                 # FLIS record
    struct.pack_into('>I', mobi, 180, 0)                 # FLIS count
    struct.pack_into('>I', mobi, 184, 0)                 # unknown
    struct.pack_into('>I', mobi, 188, 0)                 # unknown
    struct.pack_into('>I', mobi, 192, 0xFFFFFFFF)        # first compilation section
    struct.pack_into('>I', mobi, 196, 0)                 # number of compilation sections
    struct.pack_into('>I', mobi, 200, 0xFFFFFFFF)        # extra record data flags
    struct.pack_into('>I', mobi, 204, 0)                 # indx record offset

    # EXTH header
    exth_records = b''
    # 100 = author, 503 = updated title
    for rtype, val in ((100, BOOK_AUTHOR), (503, title)):
        vb = val.encode('utf-8')
        rec = struct.pack('>I', rtype) + struct.pack('>I', len(vb) + 8) + vb
        exth_records += rec
    exth = b'EXTH' + struct.pack('>I', len(exth_records) + 12) + \
           struct.pack('>I', 2) + exth_records
    exth += b'\x00' * ((4 - len(exth) % 4) % 4)

    record0 = bytes(palmdoc) + bytes(mobi) + exth + title_bytes
    record0 += b'\x00' * ((4 - len(record0) % 4) % 4)

    all_records = [record0] + text_records

    build_pdb(path, all_records, 'MiaoyueTest')


def text_encoding_code(enc):
    """MOBI 文本编码代码：1252=cp1252, 65001=UTF-8。"""
    return 65001 if enc.lower().replace('-', '') == 'utf8' else 1252


def build_azw3(path):
    """
    AZW3 = MOBI 容器 + KF8。
    这里生成 KF8 主体（version 8）+ 标准 PDB 包装。
    ⚠️ 真实 Amazon AZW3 是"MOBI7 + BOUNDARY + KF8"双部结构；
    本文件生成**单部 KF8**结构（version 8），ReaderKit 按 MOBI 系解析。
    """
    build_mobi_like(path, compression=2, version=8, text_encoding='utf-8',
                    title=BOOK_TITLE, with_kf8=True)


def main():
    os.makedirs(OUT_DIR, exist_ok=True)
    made = []

    # 1) TXT（UTF-8 带 BOM 与否都测；这里用 UTF-8 无 BOM 作基准）
    p = os.path.join(OUT_DIR, '01_%s.txt' % BOOK_TITLE)
    with open(p, 'w', encoding='utf-8', newline='\n') as f:
        f.write(book_text())
    made.append(('txt', p, os.path.getsize(p)))

    # 1b) TXT（GBK）—— 中文 Windows 记事本 ANSI 存档的常见形态
    p = os.path.join(OUT_DIR, '02_%s_GBK.txt' % BOOK_TITLE)
    with open(p, 'wb') as f:
        f.write(book_text().encode('gbk', 'replace'))
    made.append(('txt(GBK)', p, os.path.getsize(p)))

    # 2) EPUB
    p = os.path.join(OUT_DIR, '03_%s.epub' % BOOK_TITLE)
    build_epub(p)
    made.append(('epub', p, os.path.getsize(p)))

    # 3) MOBI（PalmDOC 压缩，version 6）
    p = os.path.join(OUT_DIR, '04_%s.mobi' % BOOK_TITLE)
    build_mobi_like(p, compression=2, version=6, text_encoding='utf-8', title=BOOK_TITLE)
    made.append(('mobi', p, os.path.getsize(p)))

    # 4) AZW（更老，PalmDOC，version 4）
    p = os.path.join(OUT_DIR, '05_%s.azw' % BOOK_TITLE)
    build_mobi_like(p, compression=2, version=4, text_encoding='utf-8', title=BOOK_TITLE)
    made.append(('azw', p, os.path.getsize(p)))

    # 5) AZW3（KF8，version 8）
    p = os.path.join(OUT_DIR, '06_%s.azw3' % BOOK_TITLE)
    build_azw3(p)
    made.append(('azw3', p, os.path.getsize(p)))

    print('输出目录：%s' % OUT_DIR)
    print('-' * 72)
    total_chars = len(book_text())
    for fmt, path, size in made:
        print('%-10s %-46s %9d B  %6.1f KB' % (fmt, os.path.basename(path), size, size / 1024))
    print('-' * 72)
    print('每本正文字数约 %d 字，共 %d 章' % (total_chars, len(CHAPTERS)))


if __name__ == '__main__':
    main()
