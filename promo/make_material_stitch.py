# -*- coding: utf-8 -*-
"""
「同一页 · 三段材质」拼图生成器（2026-10-07）
==============================================
需求（用户原话）：
    「整个一个图片，比如说我们找到其中一张，这一张分三份，上三分之一、中三分之一、
      下三分之一；我们三张图片都是一样的内容、一样的布局，那么**图1 是上、图2 是中、
      图3 是下**，拼在一起是**一个完整的页面**。」
    「不要顶部状态栏，但是内容要显示全。」
    「文字按我的来，不用你瞎弄。」⇒ 文案 = 用户 6 条文案里的材质那条（原文照抄）。

做法：
  ① 三张截图同内容同版式 ⇒ 取**同一个正文区**（顶栏整条去掉），按 y 三等分；
  ② 三个切点**吸附到正文行间隙**（`probe_lines.py` 实测：行高 56px、行间隙 56~118px），
     避免把某一行汉字切成两半 —— 三段拼起来的仍然是一页**完整可读**的正文；
  ③ 第 1 段取图1、第 2 段取图2、第 3 段取图3，上下相接 = 一整页，
     页面上三分之一/中三分之一/下三分之一分别是三种材质 ⇒「同样位置、不同材质」。

实测边界（源图 1320×2848，脚本 `probe_chrome.py` / `probe_lines.py`）：
  · 阅读器顶栏（'< preface' 白色圆角条）y ≈ 155..320 ⇒ 正文从 **322** 起
  · 底部胶囊条（上一章/下一章）y ≈ 2255..2490        ⇒ 正文到 **2250** 止
  · 正文行带：1)338-394 2)511-567 3)684-740 4)799-855 5)972-1028 6)1087-1144
              7)1204-1259 8)1376-1432 9)1492-1551 10)1607-1663 …
  ⇒ 切点 1 取 **964**（落在行4与行5之间）、切点 2 取 **1600**（落在行9与行10之间）

用法：
    python promo/make_material_stitch.py                 # 1080x1920
    python promo/make_material_stitch.py --size 1080x1440
"""

import argparse
import os
import sys

from PIL import Image, ImageDraw, ImageFilter

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
# 复用第一套海报的基元（同一套视觉标准：渐变 / 压暗 / 光斑 / 噪点 / 字体 / 圆角遮罩）
import make_posters as P  # noqa: E402

ROOT = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(ROOT, 'src')
OUT = os.path.join(ROOT, 'out')

# ── 素材：图1 供上段、图2 供中段、图3 供下段（顺序 = 用户给的顺序）────────────
SHOTS = ['mat_a_leather.jpg', 'mat_b_floral.jpg', 'mat_c_feather.jpg']

# ── 素材：三段分别取自哪张（索引进 SHOTS）──────────────────────────────────
# 用户 2026-10-07 追加要求：「现在的上中下应该改成**中、上、下**顺序」
# ⇒ 最上段用原来的中段（图2 花卉）、中间段用原来的上段（图1 皮革）、最下段仍是图3（羽毛）。
BAND_SOURCE = [1, 0, 2]

# ── 正文区与三等分切点（都吸附在行间隙里，见文件头实测值）────────────────────
CONTENT_TOP = 322
CONTENT_BOTTOM = 2250
CUT1 = 964
CUT2 = 1600
# 三段：上 / 中 / 下（每段的 y 区间）
BANDS = [(CONTENT_TOP, CUT1), (CUT1, CUT2), (CUT2, CONTENT_BOTTOM)]

# ── 文案：**用户原文照抄**（2026-10-07 用户指定，未改一字）──────────────────────
TITLE = '界面优雅'
SUB = '简单纯粹，怎么极致怎么来！'

# 暖调深色背景：衬得住米色皮革与白色花卉/羽毛
C1 = (16, 12, 8)
C2 = (74, 59, 44)
ACCENT = (232, 199, 155)


def stitched_page():
    """把三张截图各取一段拼成**一整页**（同一内容、同一版式，三段三种材质）

    段序 = `BAND_SOURCE`（上 / 中 / 下 各自取哪张图），切点见 `BANDS`。
    """
    shot0 = Image.open(os.path.join(SRC, SHOTS[0]))
    w = shot0.size[0]
    page = Image.new('RGB', (w, CONTENT_BOTTOM - CONTENT_TOP))
    for i, src_idx in enumerate(BAND_SOURCE):
        top, bottom = BANDS[i]
        shot = Image.open(os.path.join(SRC, SHOTS[src_idx])).convert('RGB').crop((0, top, w, bottom))
        page.paste(shot, (0, top - CONTENT_TOP))
    return page


def base_canvas(size):
    canvas = P.diagonal_gradient(size, C1, C2).convert('RGBA')
    canvas = Image.alpha_composite(canvas, P.top_shade(size))
    W, H = size
    blobs = Image.new('RGBA', size, (0, 0, 0, 0))
    bd = ImageDraw.Draw(blobs)
    bd.ellipse((W * 0.46, -H * 0.04, W * 1.30, H * 0.34), fill=ACCENT + (86,))
    bd.ellipse((-W * 0.30, H * 0.42, W * 0.40, H * 0.92), fill=ACCENT + (52,))
    canvas = Image.alpha_composite(canvas, blobs.filter(ImageFilter.GaussianBlur(int(W * 0.14))))
    return Image.alpha_composite(canvas, P.noise_layer(size))


def header_block(canvas, size, scale):
    """品牌胶囊 + 主标题 + 强调条 + 副标题（与第一套海报同款排版；文案用用户原文）"""
    W, H = size

    def s(v):
        return int(round(v * scale))

    layer = Image.new('RGBA', size, (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)

    chip_f = P.font('medium', s(30))
    chip_txt = f'{P.BRAND} · {P.BRAND_SUB}'
    tw, th = P.text_wh(d, chip_txt, chip_f)
    cx, cy, ch = s(72), s(86), s(64)
    P.rounded_box(d, (cx, cy, cx + tw + s(56), cy + ch), s(32), fill=(255, 255, 255, 42))
    d.rounded_rectangle((cx, cy, cx + tw + s(56), cy + ch), s(32),
                        outline=(255, 255, 255, 90), width=max(1, s(2)))
    d.text((cx + s(28), cy + (ch - th) / 2 - s(5)), chip_txt, font=chip_f, fill=(255, 255, 255, 242))

    title_f = P.font('bold', s(104))
    tw, th = P.text_wh(d, TITLE, title_f)
    ty = cy + ch + s(56)
    d.text((s(72) + s(3), ty - s(11)), TITLE, font=title_f, fill=(0, 0, 0, 90))
    d.text((s(72), ty - s(14)), TITLE, font=title_f, fill=(255, 255, 255, 255))

    bar_y = ty + th + s(16)
    P.rounded_box(d, (s(76), bar_y, s(76) + s(112), bar_y + s(11)), s(6), fill=ACCENT + (255,))

    sub_f = P.font('medium', s(45))
    sy = bar_y + s(42)
    d.text((s(75), sy + s(2)), SUB, font=sub_f, fill=(0, 0, 0, 80))
    d.text((s(72), sy), SUB, font=sub_f, fill=(255, 255, 255, 238))

    return Image.alpha_composite(canvas, layer), sy + P.text_wh(d, SUB, sub_f)[1]


def compose(size):
    W, H = size
    scale = W / 1080.0

    def s(v):
        return int(round(v * scale))

    canvas = base_canvas(size)
    canvas, sub_bottom = header_block(canvas, size, scale)

    page = stitched_page()
    card_w = s(820)
    card_h = int(card_w * page.size[1] / page.size[0])
    card_x = (W - card_w) // 2
    radius = s(34)
    # 构图：标题块之下、画布下沿之上，垂直居中（上下留白对称）
    area_top = int(sub_bottom) + s(50)
    area_bottom = H - s(110)
    card_y = area_top + max(0, (area_bottom - area_top - card_h) // 2)

    shadow = Image.new('RGBA', size, (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle(
        (card_x + s(6), card_y + s(24), card_x + card_w - s(6), card_y + card_h + s(20)),
        radius, fill=(0, 0, 0, 175))
    canvas = Image.alpha_composite(canvas, shadow.filter(ImageFilter.GaussianBlur(s(34))))

    canvas.paste(page.resize((card_w, card_h), Image.LANCZOS), (card_x, card_y),
                 P.rounded_mask((card_w, card_h), radius))

    edge = Image.new('RGBA', size, (0, 0, 0, 0))
    ImageDraw.Draw(edge).rounded_rectangle((card_x, card_y, card_x + card_w, card_y + card_h),
                                           radius, outline=(255, 255, 255, 90),
                                           width=max(2, s(3)))
    return Image.alpha_composite(canvas, edge).convert('RGB')


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--size', default='1080x1920')
    args = ap.parse_args()
    W, H = (int(v) for v in args.size.lower().split('x'))

    out_dir = os.path.join(OUT, f'{W}x{H}')
    os.makedirs(out_dir, exist_ok=True)
    img = compose((W, H))
    base = os.path.join(out_dir, '同一页-三段材质')
    img.save(base + '.png')
    img.save(base + '.jpg', quality=94, subsampling=1, optimize=True)
    print(f'同一页-三段材质  {W}x{H}  PNG {os.path.getsize(base + ".png") // 1024}KB  '
          f'JPG {os.path.getsize(base + ".jpg") // 1024}KB')
    # 顺带把"拼好的那一页"单独存一份（真机对比用/二次加工用）
    page = stitched_page()
    page.save(os.path.join(out_dir, '同一页-三段材质_原图.jpg'), quality=95, subsampling=1)
    print(f'同一页-三段材质_原图  {page.size[0]}x{page.size[1]}')


if __name__ == '__main__':
    main()
