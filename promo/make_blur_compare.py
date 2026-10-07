# -*- coding: utf-8 -*-
"""
「高斯模糊 · 左右对比」海报生成器（2026-10-07）
================================================
需求（用户原话）：「我刚给你发这两个图片，一个是有模糊一个是没有模糊的，也做成一个图，
左右对比，文字是——**高斯模糊，多级调节，任何背景都合适！**」

哪张是模糊的？**实测判定，不靠眼看**（`probe_blur2.py`）：本工程的模糊是"洗进背景图里"的
（见 `ReaderPage3` 的 bgBlurOn 注释），正文由引擎绘制、两张一样清晰 ⇒ 锐度差异只来自背景。
在**行间隙（纯背景）**上算边缘响应均值：
    · blur_a.jpg（截图 005707）背景锐度 =  7.71  ⇒ **已模糊**
    · blur_b.jpg（截图 005700）背景锐度 = 29.46  ⇒ **未模糊**
⇒ 左 = 未模糊（原图），右 = 已模糊（对比方向＝左到右、原图到效果）。

裁切：两张同版式 ⇒ 取同一个正文区（去掉系统状态栏 + 阅读器顶栏，正文一行不切）：
    · 状态栏 + 顶栏（'< preface' 白色圆角条）到 y ≈ 320 ⇒ 正文从 **322** 起
    · 底部胶囊条（上一章/下一章）y ≈ 2255 起        ⇒ 正文到 **2250** 止

用法：
    python promo/make_blur_compare.py                # 1080x1920
    python promo/make_blur_compare.py --size 1080x1440
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

SHOT_OFF = 'blur_b.jpg'      # 左：未模糊（锐度 29.46）
SHOT_ON = 'blur_a.jpg'       # 右：已模糊（锐度  7.71）

CROP_TOP = 322
CROP_BOTTOM = 2250

# ── 文案：用户原文照抄（未改一字）────────────────────────────────────────────
TITLE = '高斯模糊'
SUB = '多级调节，任何背景都合适！'

C1 = (16, 12, 8)
C2 = (74, 59, 44)
ACCENT = (232, 199, 155)


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

    shot0 = Image.open(os.path.join(SRC, SHOT_OFF))
    cw_src = shot0.size[0]
    ch_src = CROP_BOTTOM - CROP_TOP
    panel_w = s(483)
    panel_h = int(panel_w * ch_src / cw_src)
    gap = s(26)
    total = panel_w * 2 + gap
    x0 = (W - total) // 2
    radius = s(30)
    # 构图：标题块之下、画布下沿之上，垂直居中（上下留白对称）
    area_top = int(sub_bottom) + s(56)
    area_bottom = H - s(60)
    y = area_top + max(0, (area_bottom - area_top - panel_h) // 2)

    for i, name in enumerate((SHOT_OFF, SHOT_ON)):
        shot = Image.open(os.path.join(SRC, name)).convert('RGB').crop((0, CROP_TOP, cw_src, CROP_BOTTOM))
        x = x0 + i * (panel_w + gap)
        shadow = Image.new('RGBA', size, (0, 0, 0, 0))
        ImageDraw.Draw(shadow).rounded_rectangle(
            (x + s(6), y + s(24), x + panel_w - s(6), y + panel_h + s(20)), radius, fill=(0, 0, 0, 175))
        canvas = Image.alpha_composite(canvas, shadow.filter(ImageFilter.GaussianBlur(s(34))))
        canvas.paste(shot.resize((panel_w, panel_h), Image.LANCZOS), (x, y),
                     P.rounded_mask((panel_w, panel_h), radius))
        edge = Image.new('RGBA', size, (0, 0, 0, 0))
        ImageDraw.Draw(edge).rounded_rectangle((x, y, x + panel_w, y + panel_h), radius,
                                               outline=(255, 255, 255, 90), width=max(2, s(3)))
        canvas = Image.alpha_composite(canvas, edge)
    return canvas.convert('RGB')


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--size', default='1080x1920')
    args = ap.parse_args()
    W, H = (int(v) for v in args.size.lower().split('x'))

    out_dir = os.path.join(OUT, f'{W}x{H}')
    os.makedirs(out_dir, exist_ok=True)
    img = compose((W, H))
    base = os.path.join(out_dir, '高斯模糊-左右对比')
    img.save(base + '.png')
    img.save(base + '.jpg', quality=94, subsampling=1, optimize=True)
    print(f'高斯模糊-左右对比  {W}x{H}  PNG {os.path.getsize(base + ".png") // 1024}KB  '
          f'JPG {os.path.getsize(base + ".jpg") // 1024}KB')


if __name__ == '__main__':
    main()
