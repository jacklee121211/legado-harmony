# -*- coding: utf-8 -*-
"""
喵阅 · 横版宣传图（1920x1280 = 3:2 / 1920x1080 = 16:9）
========================================================
与竖版 `make_posters.py`（1080x1920 = `docs/宣发物料/02_成片/v2/`）**同源**：

  · 文案 / 配色 / 裁切框 / 圆角 / 描边 / 投影 / 噪点 / 字体 **全部复用**
    `make_posters.py` 的 `POSTERS` 表与基元函数 —— 改文案只改一处，竖横自动同步；
  · 本文件**只做一件事**：把竖屏版式重排为横屏版式。

竖 → 横的版式换算（设计原则不变，只换排布轴向）
------------------------------------------------
| 元素 | 竖版 1080×1920 | 横版 1920×1280 / 1920×1080 |
|---|---|---|
| 文字块 | 顶部通栏，自上而下 | **左栏**，左对齐到统一边距，整块垂直居中 |
| 截图卡 | 文字下方通栏、向下出血 | **右栏**，右对齐到同一边距，顶对齐 + 向下出血 |
| 免责小字 | 卡片正下方居中 | **左栏**底部、随文字块（横屏卡片已出血，卡下无处落脚） |
| 压暗层 | 顶部压暗 `top_shade` | **左侧压暗** `left_shade`（白字改从左往右读） |
| 光斑 | 右上 + 左下 | 右上 + 左下（半径按画布**高**取，横屏不拉成椭圆） |

三条硬约束（决定了本文件为什么长这样）：
 ① **卡片尺寸由高度决定**：手机截图宽高比 ≈0.48，横屏画布矮而宽 ⇒ 卡片只能吃满高度，
    宽度按原比例跟随（绝不非等比拉伸）。沿用竖版"向下出血出画布"的手法把卡片做大，
    版面重心靠右；左栏留白由渐变压暗 + 光斑 + 放大后的字级填充。
 ② **字级随画布高 H 等比缩放**：`u(v) = v × H/1080`，故 1280 与 1080 两个横版比例
    版式完全一致（用户要求"保证观赏效果与比例"）。
 ③ **超长标题折行而不缩号**：竖版靠自动缩号放进通栏；横屏左栏窄，缩号会让
    「AI听书 & 本地TTS」比其它 9 张“小一号”破坏统一性 ⇒ 改为**最多折 2 行**，
    字号与其它卡保持一致（仅当单个词本身就超宽才缩号）。

用法：
    python promo/make_posters_landscape.py --size 1920x1280 --outdir v3_横版_1920x1280
    python promo/make_posters_landscape.py --size 1920x1080 --outdir v3_横版_1920x1080
    python promo/make_posters_landscape.py --size 1920x1080 --only 2 3   # 单张调试

⚠️ 沿用 `make_posters.py` 文件头两条铁律（本文件同样适用）：
   ① ImageDraw 画带 alpha 的颜色是**直接替换像素**、不混合 ⇒ 半透明元素一律
      "独立图层 + alpha_composite"；
   ② 卡片一律走 `P.card_image` / `P.rounded_mask`，不要手搓 `rotate`。
"""

import argparse
import os
import sys

from PIL import Image, ImageDraw, ImageFilter

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import make_posters as P          # noqa: E402  同一套设计基元 + 唯一内容源 POSTERS


# ── 版式度量（单位 = 竖版 1080 高基准，按 u() 随 H 等比缩放）──────────────────
def metrics(H):
    def u(v):
        return int(round(v * H / 1080.0))

    return dict(
        margin=u(96),          # 左右统一外边距（文字块左沿 / 卡片右沿）
        card_top=u(64),        # 卡片上沿 = 上边距
        bleed=u(112),          # 卡片向下出血量（超出画布底）
        col_gap=u(86),         # 左栏 → 卡片 最小水平间距
        chip=u(34), chip_box_h=u(72), chip_pad=u(30),
        title=u(150),          # 主标题基准字号（左栏内可折 2 行）
        bar_h=u(11), bar_w=u(118),
        sub=u(62),
        tag=u(34),
        fmt=u(30),
        note=u(27), note_line=u(44),
        g_chip_title=u(52),    # 胶囊 → 主标题
        g_title_bar=u(22),     # 主标题 → 强调条
        g_bar_sub=u(40),       # 强调条 → 副标题
        g_sub_tag=u(30),       # 副标题 → 角标
        g_tag_fmt=u(13),       # 角标 → 格式行
        g_fmt_note=u(30),      # 格式行 → 免责小字
        radius=u(44),
        card_border=u(4),
        text_w_ratio=0.42,     # 左栏最大宽 = 画布宽 × 该值（上限，实际按可用空间收）
    )


def left_shade(size, peak=178, fade=0.66):
    """左侧压暗：横屏白字在左栏，亮渐变（如 #2 的橙色）上必须压暗才立得住。

    与 `P.top_shade` 同构，只把「上→下」换成「左→右」。
    """
    W, H = size
    strip = Image.new('L', (W, 1))
    px = strip.load()
    for x in range(W):
        t = min(1.0, x / (W * fade))
        px[x, 0] = int(round(peak * (1.0 - t) ** 1.6))
    layer = Image.new('RGBA', size, (0, 0, 0, 0))
    layer.putalpha(strip.resize(size, Image.BICUBIC))
    return layer


def background(size, c1, c2, accent):
    """渐变 + 左侧压暗 + 光斑 + 噪点（与竖版同一套视觉基因）。"""
    W, H = size
    canvas = P.diagonal_gradient(size, c1, c2).convert('RGBA')
    canvas = Image.alpha_composite(canvas, left_shade(size))

    blobs = Image.new('RGBA', size, (0, 0, 0, 0))
    bd = ImageDraw.Draw(blobs)
    # 右上主光斑 + 左下副光斑；半径按**画布高**取，横屏才不会被拉成宽带
    bd.ellipse((W * 0.62, -H * 0.34, W * 1.20, H * 0.78), fill=accent + (112,))
    bd.ellipse((-W * 0.14, H * 0.30, W * 0.26, H * 1.20), fill=accent + (62,))
    canvas = Image.alpha_composite(canvas, blobs.filter(ImageFilter.GaussianBlur(int(H * 0.15))))
    return Image.alpha_composite(canvas, P.noise_layer(size))


# ── 标题折行（最多 2 行，不缩号）──────────────────────────────────────────────
def balanced_lines(text, f, max_w, n, penalize=None):
    """把 text 切成 n 行，使**最宽行尽量窄**（DP 求最优断点）。

    贪心折行会产生「……超便 / 利！」这种 2 字孤行（竖版单行放得下所以没暴露），
    横屏左栏窄时必须均衡分行，否则视觉上像被切断。
    `penalize(i)` 返回该断点的惩罚值：用来避开“把词语劈成两半”的位置。
    """
    def w(t):
        return P.text_wh(_PROBE[0], t, f)[0]

    L = len(text)
    INF = float('inf')
    # best[i][k] = 用 k 行装下 text[i:] 的最优代价
    best = [[INF] * (n + 1) for _ in range(L + 1)]
    cut = [[-1] * (n + 1) for _ in range(L + 1)]
    best[L][0] = 0

    for k in range(1, n + 1):
        for i in range(L - 1, -1, -1):
            for j in range(i + 1, L + 1):
                seg_w = w(text[i:j])
                if seg_w > max_w:
                    break
                if best[j][k - 1] == INF:
                    continue
                pen = 0 if j == L else (penalize(j) if penalize else 0)
                # 用 (最宽行, 总惩罚) 的字典序编码进一个数：主目标均衡，次目标断点自然
                mw = max(seg_w, best[j][k - 1] // 1_000_000)
                tp = pen + (best[j][k - 1] % 1_000_000)
                cand = mw * 1_000_000 + tp
                if cand < best[i][k]:
                    best[i][k] = cand
                    cut[i][k] = j

    if best[0][n] == INF:
        return None
    out, i = [], 0
    for k in range(n, 0, -1):
        j = cut[i][k]
        if j < 0:
            return None
        out.append(text[i:j])
        i = j
    return out


# 断行友好字符：在这些字符**之后**断行最自然（中文标点，以及空格/连字符）
_BREAK_AFTER = set('，。！？；：、）」』】…, .!?;:)]} 　-—/')


def _break_penalty(text):
    """构造断点惩罚函数：标点/空格之后 = 0（最自然）；行首是标点 = 中等惩罚；
    两个汉字之间硬切 = 较大惩罚（尽量避免把词劈开）。"""
    def pen(j):
        if j <= 0 or j >= len(text):
            return 0
        prev, nxt = text[j - 1], text[j]
        if prev in _BREAK_AFTER:
            return 0
        if nxt in _BREAK_AFTER:          # 标点被推到行首 = 排版大忌
            return 3
        return 1                          # 纯汉字之间
    return pen


_PROBE = [ImageDraw.Draw(Image.new('RGBA', (8, 8)))]


def wrap_lines(text, f, max_w, draw, max_lines=2, kind='bold'):
    """折行，优先级严格按「语义 → 均衡 → 缩号」：

    ① 单行放得下 → 原样（竖版所有文案本来都是单行，横屏能单行就绝不折）；
    ② **在标点处折**（，。！？；：、& 空格之后）—— 这是中文排版的正确断点，
       选"最均衡且两行都放得下"的那个标点（"电脑阅读，/ 双端协同超便利！"）；
    ③ 没有可用标点 → DP 均衡分行 + 断点惩罚（避免把词劈开、避免标点落行首）；
    ④ 仍超行数 → 缩号重排。

    ⚠️ 2026-10 实测教训：只做"最宽行尽量窄"的 DP 均衡，会把
    「电脑阅读，双/端协同超便利！」这种**词中间劈开**的结果判为最优 ——
    因为宽度差 1px 也压过任何断点惩罚 ⇒ 必须让标点断点**优先于**均衡。
    """
    _PROBE[0] = draw

    def w(t):
        return P.text_wh(draw, t, f)[0]

    if w(text) <= max_w:
        return [text], f

    # ② 标点优先断行（只在 max_lines = 2 时有意义）
    if max_lines == 2:
        best = None
        for j in range(1, len(text)):
            if text[j - 1] not in _BREAK_AFTER:
                continue
            a, b = text[:j].rstrip(), text[j:].lstrip()
            if not a or not b:
                continue
            wa, wb = w(a), w(b)
            if wa <= max_w and wb <= max_w:
                score = abs(wa - wb)          # 越均衡越好
                if best is None or score < best[0]:
                    best = (score, [a, b])
        if best:
            return best[1], f

    def greedy(font):
        lines, cur = [], ''
        for ch in text:
            if P.text_wh(draw, cur + ch, font)[0] <= max_w or not cur:
                cur += ch
            else:
                lines.append(cur)
                cur = ch
        if cur:
            lines.append(cur)
        return lines

    # ③ DP 均衡分行 + 断点惩罚
    need = len(greedy(f))
    if need <= max_lines:
        bl = balanced_lines(text, f, max_w, need, _break_penalty(text))
        if bl:
            return bl, f

    # ④ 缩号
    size = f.size
    while size > 24:
        size -= max(2, size // 24)
        f2 = P.font(kind, size)
        need = len(greedy(f2))
        if need <= max_lines:
            bl = balanced_lines(text, f2, max_w, need, _break_penalty(text))
            return (bl, f2) if bl else (greedy(f2), f2)
    return greedy(f)[:max_lines], f


def text_metrics(p, max_val_w, H):
    """量出左栏文字块的真实尺寸（不画），供 compose 布局。"""
    m = metrics(H)
    probe = ImageDraw.Draw(Image.new('RGBA', (8, 8)))

    chip_f = P.font('medium', m['chip'])
    chip_txt = f'{P.BRAND} · {P.BRAND_SUB}'
    chip_th = P.text_wh(probe, chip_txt, chip_f)[1]
    chip_w = P.text_wh(probe, chip_txt, chip_f)[0] + m['chip_pad'] * 2

    # 主标题：最多 2 行（超宽才缩号，见 wrap_lines）
    title_f = P.font('bold', m['title'])
    title_lines, title_f = wrap_lines(p['title'], title_f, max_val_w, probe, max_lines=2)
    title_lh = int(title_f.size * 1.22)
    title_h = title_lh * len(title_lines)
    title_w = max(P.text_wh(probe, ln, title_f)[0] for ln in title_lines)

    # 副标题：竖版是 12 字单行；横屏左栏可能放不下 ⇒ 最多 2 行（与主标题同规则）
    sub_f = P.font('medium', m['sub'])
    sub_lines, sub_f = wrap_lines(p['sub'], sub_f, max_val_w, probe,
                                  max_lines=2, kind='medium')
    sub_lh = int(sub_f.size * 1.34)
    sub_h = sub_lh * len(sub_lines)
    sub_w = max(P.text_wh(probe, ln, sub_f)[0] for ln in sub_lines)

    # 角标 / 格式行：固定文案，单行；若超宽则缩号（不折行，保持"注脚"观感）
    def fit_single(text, base_size, kind):
        size = base_size
        while size > 16:
            f = P.font(kind, size)
            if P.text_wh(probe, text, f)[0] <= max_val_w:
                return f, P.text_wh(probe, text, f)
            size -= 1
        f = P.font(kind, 16)
        return f, P.text_wh(probe, text, f)

    tag_f, tag_wh = fit_single(P.TAGLINE, m['tag'], 'medium')
    fmt_f, fmt_wh = fit_single(P.FORMATS, m['fmt'], 'regular')

    note = p.get('note')
    note_lines = []
    note_f = P.font('regular', m['note'])
    if note:
        cur = ''
        for ch in note:
            if P.text_wh(probe, cur + ch, note_f)[0] <= max_val_w or not cur:
                cur += ch
            else:
                note_lines.append(cur)
                cur = ch
        if cur:
            note_lines.append(cur)

    block_w = max(chip_w, title_w, sub_w, tag_wh[0], fmt_wh[0])
    if note_lines:
        block_w = max(block_w, max(P.text_wh(probe, ln, note_f)[0] for ln in note_lines))

    y_chip = 0
    y_title = y_chip + m['chip_box_h'] + m['g_chip_title']
    y_bar = y_title + title_h + m['g_title_bar']
    y_sub = y_bar + m['bar_h'] + m['g_bar_sub']
    y_tag = y_sub + sub_h + m['g_sub_tag']
    y_fmt = y_tag + tag_wh[1] + m['g_tag_fmt']
    y_note = y_fmt + fmt_wh[1] + m['g_fmt_note']
    note_h = len(note_lines) * m['note_line'] if note_lines else 0
    block_h = (y_note + note_h) if note_lines else (y_fmt + fmt_wh[1])

    return dict(w=block_w, h=block_h, y_chip=y_chip, y_title=y_title, y_bar=y_bar,
                y_sub=y_sub, y_tag=y_tag, y_fmt=y_fmt, y_note=y_note,
                chip_f=chip_f, chip_txt=chip_txt, chip_th=chip_th, chip_w=chip_w,
                title_f=title_f, title_lines=title_lines, title_lh=title_lh,
                sub_f=sub_f, sub_lines=sub_lines, sub_lh=sub_lh,
                tag_f=tag_f, tag_wh=tag_wh, fmt_f=fmt_f, fmt_wh=fmt_wh,
                note_f=note_f, note_lines=note_lines)


def draw_text_block(p, M, m):
    """把量好的左栏文字块画到独立图层（半透明描影一律独立图层，见铁律）。"""
    layer = Image.new('RGBA', (int(M['w']) + 8, int(M['h']) + int(M['title_f'].size * 0.2)), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    pad = 4
    dx = pad

    # 品牌胶囊
    P.rounded_box(d, (dx, M['y_chip'], dx + M['chip_w'], M['y_chip'] + m['chip_box_h']),
                  m['chip_box_h'] // 2, fill=(255, 255, 255, 42))
    d.rounded_rectangle((dx, M['y_chip'], dx + M['chip_w'], M['y_chip'] + m['chip_box_h']),
                        m['chip_box_h'] // 2, outline=(255, 255, 255, 90),
                        width=max(1, m['chip'] // 15))
    d.text((dx + m['chip_pad'],
            M['y_chip'] + (m['chip_box_h'] - M['chip_th']) / 2 - m['chip'] * 0.16),
           M['chip_txt'], font=M['chip_f'], fill=(255, 255, 255, 242))

    # 主标题（折行后逐行画；描影同竖版）
    ts = M['title_f'].size
    for i, ln in enumerate(M['title_lines']):
        ty = M['y_title'] + i * M['title_lh']
        d.text((dx + ts * 0.03, ty - ts * 0.10), ln, font=M['title_f'], fill=(0, 0, 0, 90))
        d.text((dx, ty - ts * 0.13), ln, font=M['title_f'], fill=(255, 255, 255, 255))

    # 强调条
    P.rounded_box(d, (dx + m['bar_h'], M['y_bar'], dx + m['bar_h'] + m['bar_w'],
                      M['y_bar'] + m['bar_h']), m['bar_h'] // 2, fill=p['accent'] + (255,))

    # 副标题（可能折 2 行）
    for i, ln in enumerate(M['sub_lines']):
        sy = M['y_sub'] + i * M['sub_lh']
        d.text((dx + M['sub_f'].size * 0.06, sy + M['sub_f'].size * 0.06), ln,
               font=M['sub_f'], fill=(0, 0, 0, 80))
        d.text((dx, sy), ln, font=M['sub_f'], fill=(255, 255, 255, 238))

    # 统一角标：极致的本地书籍阅读器 + 支持格式（用户 2026-10-12 要求全图必加）
    d.text((dx + m['tag'] * 0.06, M['y_tag'] + m['tag'] * 0.06), P.TAGLINE,
           font=M['tag_f'], fill=(0, 0, 0, 100))
    d.text((dx, M['y_tag']), P.TAGLINE, font=M['tag_f'], fill=(255, 255, 255, 232))

    d.text((dx + m['fmt'] * 0.08, M['y_fmt'] + m['fmt'] * 0.08), P.FORMATS,
           font=M['fmt_f'], fill=(0, 0, 0, 90))
    d.text((dx, M['y_fmt']), P.FORMATS, font=M['fmt_f'], fill=(255, 255, 255, 200))

    # 免责小字（左栏底部，左对齐；横屏卡片已出血，卡下无处落脚）
    yy = M['y_note']
    for ln in M['note_lines']:
        d.text((dx + m['note'] * 0.08, yy + m['note'] * 0.08), ln,
               font=M['note_f'], fill=(0, 0, 0, 120))
        d.text((dx, yy), ln, font=M['note_f'], fill=(255, 255, 255, 205))
        yy += m['note_line']

    return layer, pad


# ── 「超多材质」横屏双层叠加（同竖版语义：后层弹窗 + 前层书页）────────────────
def material_stack_landscape(size, card_x, card_top, card_w, m, scale):
    """前层满宽（= card_w）、下边直角出血；后层较窄，从上方露出约两行九宫格。"""
    def s(v):
        return int(round(v * scale))

    dlg = P.Image.open(P.resolve_src('03_material.jpg')).convert('RGB')
    cx0, cy0, cx1, cy1 = P.MATERIAL_DIALOG_CROP
    dlg = dlg.crop((cx0, cy0, cx1, cy1))

    import make_material_stitch as MS
    page = MS.stitched_page()

    pg_ar = page.size[0] / page.size[1]
    dlg_ar = dlg.size[0] / dlg.size[1]

    bleed = m['bleed']
    area_h = (size[1] + bleed) - card_top
    expose = area_h * P.BACK_EXPOSE

    front_w = float(card_w)
    front_h = min(front_w / pg_ar + bleed, area_h - expose)
    assert front_h >= bleed + s(60), f'「超多材质」前层太矮：front_h={front_h:.0f}'

    need_src_h = int(round((front_h - bleed) * page.size[0] / front_w))
    need_src_h = max(s(300), min(need_src_h, page.size[1]))
    page = page.crop((0, 0, page.size[0], need_src_h))

    back_w = front_w * P.BACK_W_RATIO
    back_h = back_w / dlg_ar

    # mask 半径必须 ≈ 面板自带圆角（竖版实测源图 74px），按缩放比折算
    DIALOG_NATIVE_RADIUS_SRC = 74.0
    back_radius = max(6, int(round(DIALOG_NATIVE_RADIUS_SRC * back_w / (cx1 - cx0))))

    back = P.card_image(dlg, int(round(back_w)), int(round(back_h)), back_radius,
                        border=max(2, s(3)))
    front = P.card_image(page, int(round(front_w)), int(round(front_h)), s(34),
                         border=max(2, s(3)), bottom_square=True)
    return back, front


# ── 单张合成 ────────────────────────────────────────────────────────────────
def compose(p, size):
    W, H = size
    m = metrics(H)
    scale = H / 1080.0

    def s(v):
        return int(round(v * scale))

    canvas = background(size, p['c1'], p['c2'], p['accent'])
    stack = p.get('stack') == 'material'

    # ① 先量文字块的"自然宽度需求"：用画布宽 × text_w_ratio 作为测量上限
    probe_w = int(W * m['text_w_ratio'])
    if stack:
        import make_material_stitch as MS
        pg = MS.stitched_page()
        aspect = pg.size[0] / pg.size[1]
    else:
        shot = P.Image.open(P.resolve_src(p['src'])).convert('RGB').crop(p['crop'])
        aspect = shot.size[0] / shot.size[1]

    M0 = text_metrics(p, probe_w, H)
    # 文字块实际占位宽度：取实测宽，但不超过测量上限
    text_w = min(M0['w'], probe_w)

    # ② 卡片宽度：高度优先（顶对齐 + 向下出血）算出"理想宽"，再与"左栏让位后的
    #    可用宽"取小。理想宽超出可用宽时按高度回撤（保持比例，绝不非等比压缩）。
    card_top = m['card_top']
    avail_for_card = W - m['margin'] - (m['margin'] + text_w + m['col_gap'])
    assert avail_for_card > W * 0.30, (
        f'左栏过宽导致卡片没空间：text_w={text_w:.0f} avail={avail_for_card:.0f}')

    if stack:
        area_h = (H + m['bleed']) - card_top
        expose = area_h * P.BACK_EXPOSE
        front_h_max = area_h - expose
        card_w = min(front_h_max * aspect, avail_for_card)
        card_h = min(card_w / aspect + m['bleed'], front_h_max)
    else:
        card_h = (H - card_top) + m['bleed']
        card_w = card_h * aspect
        if card_w > avail_for_card:
            card_w = avail_for_card
            card_h = card_w / aspect

    # ③ 用最终可用宽重测文字块（宽度变化可能改变折行/缩号结果 → 必须重测）
    avail_w = int(min(probe_w, (W - m['margin'] - card_w) - m['margin'] - m['col_gap']))
    M = text_metrics(p, avail_w, H)
    if M['w'] > avail_w + 1:
        # 仍有单行元素超宽（极少）：收卡片宽度再让一次
        card_w = max(W * 0.30, card_w - (M['w'] - avail_w))
        card_h = card_w / aspect if not stack else card_h
        avail_w = int(min(probe_w, (W - m['margin'] - card_w) - m['margin'] - m['col_gap']))
        M = text_metrics(p, avail_w, H)

    layer, pad = draw_text_block(p, M, m)
    card_x = int(round(W - m['margin'] - card_w))
    text_x = m['margin'] - pad
    text_y = int(round((H - M['h']) / 2))
    text_y = max(m['card_top'], text_y)

    # 卡片纵向定位：
    #  · 高瘦截图 → 吃满高度并向下出血（竖版同款手法），视觉重心下沉；
    #  · 宽扁截图（如 #8 裁切 0.80、#3 层叠）→ 宽度先撞到上限，高度填不满，
    #    此时**垂直居中**在右栏可用区内，让上下留白对称 ——
    #    否则卡片下方会留一截"带阴影的空白"，看着像没做完（2026-10 实图复查发现）。
    if stack:
        card_y = card_top
    else:
        usable_h = H - card_top - m['margin']
        card_y = card_top + max(0, int(round((usable_h - card_h) / 2)))
    canvas.alpha_composite(layer, (text_x, text_y))

    # ④ 卡片
    if stack:
        back, front = material_stack_landscape(size, card_x, card_top, card_w, m, scale)
        front_cx = card_x + front.size[0] / 2
        front_cy = (H + m['bleed']) - front.size[1] / 2
        back_cx = card_x + card_w / 2
        back_cy = card_top + back.size[1] / 2

        shown = (front_cy - front.size[1] / 2) - card_top
        assert shown > s(90), f'「超多材质」后层露出太少：shown={shown:.0f}'
        assert back.size[0] < front.size[0], '「超多材质」后层未比前层窄'
        assert shown < front_cy - front.size[1] / 2 - card_top + back.size[1], '露出区超出后层高度'

        canvas = P.drop_shadow(canvas,
                               (back_cx - back.size[0] / 2, back_cy - back.size[1] / 2,
                                back_cx + back.size[0] / 2, back_cy + back.size[1] / 2),
                               s(34), s(34), alpha=150, dy=s(14), inset=s(6))
        canvas.alpha_composite(back, (int(round(back_cx - back.size[0] / 2)),
                                      int(round(back_cy - back.size[1] / 2))))
        canvas = P.drop_shadow(canvas,
                               (front_cx - front.size[0] / 2, front_cy - front.size[1] / 2,
                                front_cx + front.size[0] / 2, front_cy + front.size[1] / 2),
                               s(34), s(38), alpha=175, dy=s(16), inset=s(10))
        canvas.alpha_composite(front, (int(round(front_cx - front.size[0] / 2)),
                                       int(round(front_cy - front.size[1] / 2))))
        return canvas.convert('RGB')

    canvas = P.drop_shadow(canvas, (card_x, card_y, card_x + card_w, card_y + card_h),
                           m['radius'], s(40), alpha=170, dy=s(26), inset=s(8))

    cw, ch = int(round(card_w)), int(round(card_h))
    shot = shot.resize((cw, ch), Image.LANCZOS)
    canvas.paste(shot, (card_x, card_y), P.rounded_mask((cw, ch), m['radius']))

    edge = Image.new('RGBA', size, (0, 0, 0, 0))
    ImageDraw.Draw(edge).rounded_rectangle(
        (card_x, card_y, card_x + cw, card_y + ch), m['radius'],
        outline=(255, 255, 255, 80), width=max(2, m['card_border']))
    canvas = Image.alpha_composite(canvas, edge)

    return canvas.convert('RGB')


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--size', default='1920x1280')
    ap.add_argument('--only', nargs='*', type=int, default=None)
    ap.add_argument('--outdir', default=None,
                    help='docs/宣发物料/02_成片/ 下的子目录名，默认 横版_<W>x<H>')
    args = ap.parse_args()
    W, H = (int(v) for v in args.size.lower().split('x'))

    out_dir = os.path.join(P.MATERIAL_ROOT, '02_成片', args.outdir or f'横版_{W}x{H}')
    os.makedirs(out_dir, exist_ok=True)

    for i, p in enumerate(P.POSTERS, start=1):
        if args.only and i not in args.only:
            continue
        if p.get('skip'):
            print(f'[{i}] {p["out"]}  —— 已停用（并入其他图），跳过')
            continue
        img = compose(p, (W, H))
        path = os.path.join(out_dir, p['out'])
        img.save(path)
        print(f'[{i}] {p["out"]}  {W}x{H}  PNG {os.path.getsize(path) // 1024}KB')


if __name__ == '__main__':
    main()
