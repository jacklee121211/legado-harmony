# -*- coding: utf-8 -*-
"""
喵阅 · 宣传图生成器（本地合成，不经 AI 重绘）
================================================
思路：**截图像素原样保留**（只做裁切 + 圆角 + 投影 + 描边），文字与背景由本脚本绘制。
这样 UI 里的小字（菜单名、按钮名、材质编号）不会被生成式模型画糊 —— 这是 App
宣传图的通行做法，也是本脚本相对「把截图丢给豆包/即梦重画」的唯一优势。

依赖：Python 3 + Pillow（本机实测：Python 3.12.9 / Pillow 12.2.0）
字体：C:\\Windows\\Fonts\\HarmonyOS_Sans_SC_*.ttf
      （= App 内默认的「鸿蒙黑体」，字体同源 ⇒ 宣传图与真机视觉一致）

用法：
    python promo/make_posters.py                    # 6 张 1080x1920（9:16）
    python promo/make_posters.py --size 1080x1440   # 3:4，适合应用市场/小红书
    python promo/make_posters.py --only 1 6         # 只出第 1、6 张

改文案 / 换配色 / 换裁切框：只改下面 POSTERS 表，不用碰渲染逻辑。
⚠️ 绘图铁律（本文件踩过的坑）：ImageDraw 画带 alpha 的颜色是**直接替换像素**、
   不参与混合 ⇒ 所有半透明元素必须画在独立图层上再 `alpha_composite`，
   否则 `convert('RGB')` 时 alpha 被丢弃，半透明白会变成纯白（白底白字 = 看不见）。
"""

import argparse
import os

from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = os.path.dirname(os.path.abspath(__file__))
SRC_DIR = os.path.join(ROOT, 'src')
OUT_DIR = os.path.join(ROOT, 'out')

FONTS = {
    'bold': r'C:\Windows\Fonts\HarmonyOS_Sans_SC_Bold.ttf',
    'medium': r'C:\Windows\Fonts\HarmonyOS_Sans_SC_Medium.ttf',
    'regular': r'C:\Windows\Fonts\HarmonyOS_Sans_SC_Regular.ttf',
}

BRAND = '喵阅'
BRAND_SUB = 'HarmonyOS 阅读器'

# ── 6 张图的配置 ────────────────────────────────────────────────────────────
# crop   : 从 1320x2848 原图里取哪一块（左, 上, 右, 下）—— 只取"能证明这个卖点"的区域
# title  : 主标题（用户文案的第一句，**原样**）
# sub    : 副标题（用户文案的剩余部分，**原样**）
# c1/c2  : 背景渐变（深 → 亮，左上 → 右下）
# accent : 主标题下的强调条 + 光斑颜色
POSTERS = [
    dict(
        src='01_wifi.jpg', out='1_wifi_传书.png',
        crop=(100, 560, 1220, 2345),
        title='WIFI传输', sub='电脑阅读，双端协同超便利！',
        c1=(6, 28, 88), c2=(0, 138, 224), accent=(96, 205, 255),
    ),
    dict(
        src='02_shelf.jpg', out='2_鸿蒙光感.png',
        crop=(0, 300, 1320, 2848),
        title='鸿蒙赋能', sub='沉浸光感，全新UI超美观！',
        c1=(112, 38, 4), c2=(255, 140, 44), accent=(255, 210, 140),
    ),
    dict(
        src='03_material.jpg', out='3_多材质.png',
        crop=(95, 712, 1225, 2172),
        title='超多材质', sub='个人定制，自由畅想随心配！',
        c1=(40, 16, 74), c2=(140, 82, 226), accent=(215, 175, 255),
    ),
    dict(
        src='04_font.jpg', out='4_自定字体.png',
        crop=(95, 420, 1225, 2462),
        title='自定字体', sub='多渠导入，怎么舒适怎么来！',
        c1=(4, 54, 50), c2=(22, 180, 160), accent=(140, 245, 225),
    ),
    dict(
        src='05_color.jpg', out='5_自由调盘.png',
        crop=(65, 840, 1255, 2726),
        title='更多预设', sub='自由调盘，万千色彩随你定！',
        c1=(86, 8, 46), c2=(238, 82, 144), accent=(255, 170, 200),
    ),
    dict(
        src='06_tts.jpg', out='6_本地TTS.png',
        crop=(70, 1595, 1250, 2700),
        title='本地TTS', sub='语音读书，畅听书海爽翻天！',
        c1=(12, 24, 88), c2=(88, 96, 236), accent=(172, 182, 255),
    ),
]


# ── 基础工具 ────────────────────────────────────────────────────────────────

def font(kind, size):
    return ImageFont.truetype(FONTS[kind], size)


def text_wh(draw, text, f):
    box = draw.textbbox((0, 0), text, font=f)
    return box[2] - box[0], box[3] - box[1]


def diagonal_gradient(size, c1, c2, angle=(1.0, 0.55)):
    """平滑斜向渐变：先算小图（64x64）再放大 ⇒ 无旋转接缝、无黑角。"""
    step = 64
    ax, ay = angle
    small = Image.new('L', (step, step))
    px = small.load()
    for y in range(step):
        for x in range(step):
            t = (ax * x / (step - 1) + ay * y / (step - 1)) / (ax + ay)
            px[x, y] = int(round(255 * min(1.0, max(0.0, t))))
    g = small.resize(size, Image.BICUBIC)
    return Image.merge('RGB', [
        g.point(lambda v, i=i: int(round(c1[i] + (c2[i] - c1[i]) * v / 255.0)))
        for i in range(3)
    ])


def top_shade(size, peak=170, fade=0.62):
    """顶部压暗，保证白字在亮渐变上也够清楚。"""
    h = size[1]
    strip = Image.new('L', (1, h))
    px = strip.load()
    for y in range(h):
        t = min(1.0, y / (h * fade))
        px[0, y] = int(round(peak * (1.0 - t) ** 1.6))
    layer = Image.new('RGBA', size, (0, 0, 0, 0))
    layer.putalpha(strip.resize(size, Image.BICUBIC))
    return layer


def noise_layer(size, strength=9):
    n = Image.effect_noise(size, 22).convert('L').point(lambda v: int(v * strength / 255))
    layer = Image.new('RGBA', size, (255, 255, 255, 0))
    layer.putalpha(n)
    return layer


def rounded_mask(size, radius):
    m = Image.new('L', size, 0)
    ImageDraw.Draw(m).rounded_rectangle((0, 0, size[0] - 1, size[1] - 1), radius, fill=255)
    return m


def rounded_box(draw, box, radius, fill=None, outline=None, width=1):
    draw.rounded_rectangle(box, radius, fill=fill, outline=outline, width=width)


# ── 主流程 ──────────────────────────────────────────────────────────────────

def compose(p, size):
    W, H = size
    scale = W / 1080.0

    def s(v):
        return int(round(v * scale))

    # 背景 + 顶部压暗 + 光斑 + 细噪点（全部走独立图层，见文件头铁律）
    canvas = diagonal_gradient(size, p['c1'], p['c2']).convert('RGBA')
    canvas = Image.alpha_composite(canvas, top_shade(size))

    blobs = Image.new('RGBA', size, (0, 0, 0, 0))
    bd = ImageDraw.Draw(blobs)
    bd.ellipse((W * 0.52, -H * 0.06, W * 1.40, H * 0.42), fill=p['accent'] + (120,))
    bd.ellipse((-W * 0.34, H * 0.34, W * 0.48, H * 0.86), fill=p['accent'] + (66,))
    canvas = Image.alpha_composite(canvas, blobs.filter(ImageFilter.GaussianBlur(s(150))))
    canvas = Image.alpha_composite(canvas, noise_layer(size))

    # ── 文字层（标题 / 副标题 / 品牌胶囊，全在半透明图层上画）────────────
    text_layer = Image.new('RGBA', size, (0, 0, 0, 0))
    d = ImageDraw.Draw(text_layer)

    chip_f = font('medium', s(30))
    chip_txt = f'{BRAND} · {BRAND_SUB}'
    tw, th = text_wh(d, chip_txt, chip_f)
    cx, cy, ch = s(72), s(86), s(64)
    rounded_box(d, (cx, cy, cx + tw + s(56), cy + ch), s(32), fill=(255, 255, 255, 42))
    d.rounded_rectangle((cx, cy, cx + tw + s(56), cy + ch), s(32),
                        outline=(255, 255, 255, 90), width=max(1, s(2)))
    d.text((cx + s(28), cy + (ch - th) / 2 - s(5)), chip_txt, font=chip_f,
           fill=(255, 255, 255, 242))

    title_f = font('bold', s(104))
    tw, th = text_wh(d, p['title'], title_f)
    ty = cy + ch + s(56)
    # 标题描影：同一位置先画一层深色再画白字，保证亮背景上也立得住
    d.text((s(72) + s(3), ty - s(11)), p['title'], font=title_f, fill=(0, 0, 0, 90))
    d.text((s(72), ty - s(14)), p['title'], font=title_f, fill=(255, 255, 255, 255))

    bar_y = ty + th + s(16)
    rounded_box(d, (s(76), bar_y, s(76) + s(112), bar_y + s(11)), s(6),
                fill=p['accent'] + (255,))

    sub_f = font('medium', s(45))
    sw, sh = text_wh(d, p['sub'], sub_f)
    sy = bar_y + s(42)
    d.text((s(75), sy + s(2)), p['sub'], font=sub_f, fill=(0, 0, 0, 80))
    d.text((s(72), sy), p['sub'], font=sub_f, fill=(255, 255, 255, 238))

    canvas = Image.alpha_composite(canvas, text_layer)
    sub_bottom = sy + sh

    # ── 截图卡片：原图直出（只裁切/缩放/圆角/投影/描边）──────────────────
    shot = Image.open(os.path.join(SRC_DIR, p['src'])).convert('RGB').crop(p['crop'])
    aspect = shot.size[0] / shot.size[1]

    bleed = 0 if aspect > 0.9 else s(96)     # 竖卡出血到画布外，横卡不出血
    card_top = sub_bottom + s(74)
    avail = (H + bleed) - card_top - s(36)
    card_h = int(avail)
    card_w = int(card_h * aspect)
    max_w = W - s(92)
    if card_w > max_w:
        card_w = max_w
        card_h = int(card_w / aspect)
    card_x = (W - card_w) // 2
    card_y = card_top if card_h >= avail else card_top + (avail - card_h) // 2
    radius = s(44)

    shadow = Image.new('RGBA', size, (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle(
        (card_x + s(8), card_y + s(30), card_x + card_w - s(8), card_y + card_h + s(26)),
        radius, fill=(0, 0, 0, 170))
    canvas = Image.alpha_composite(canvas, shadow.filter(ImageFilter.GaussianBlur(s(40))))

    shot = shot.resize((card_w, card_h), Image.LANCZOS)
    canvas.paste(shot, (card_x, card_y), rounded_mask((card_w, card_h), radius))

    edge = Image.new('RGBA', size, (0, 0, 0, 0))
    ImageDraw.Draw(edge).rounded_rectangle(
        (card_x, card_y, card_x + card_w, card_y + card_h), radius,
        outline=(255, 255, 255, 80), width=max(2, s(4)))
    canvas = Image.alpha_composite(canvas, edge)

    return canvas.convert('RGB')


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--size', default='1080x1920')
    ap.add_argument('--only', nargs='*', type=int, default=None,
                    help='只生成第 N 张（1 起），例如 --only 1 6')
    ap.add_argument('--format', default='both', choices=['both', 'png', 'jpg'],
                    help='默认 both：PNG（无损，1MB+）+ JPG（q92，便于微信/小红书上传）')
    args = ap.parse_args()
    W, H = (int(v) for v in args.size.lower().split('x'))

    os.makedirs(OUT_DIR, exist_ok=True)
    out_dir = os.path.join(OUT_DIR, f'{W}x{H}')   # 按尺寸分目录，避免不同尺寸互相覆盖
    os.makedirs(out_dir, exist_ok=True)
    for i, p in enumerate(POSTERS, start=1):
        if args.only and i not in args.only:
            continue
        img = compose(p, (W, H))
        sizes = []
        if args.format in ('both', 'png'):
            path = os.path.join(out_dir, p['out'])
            img.save(path)
            sizes.append(f'PNG {os.path.getsize(path) // 1024}KB')
        if args.format in ('both', 'jpg'):
            path = os.path.join(out_dir, os.path.splitext(p['out'])[0] + '.jpg')
            img.save(path, quality=92, subsampling=1, optimize=True)
            sizes.append(f'JPG {os.path.getsize(path) // 1024}KB')
        print(f'[{i}] {p["out"]}  {W}x{H}  ' + '  '.join(sizes))


if __name__ == '__main__':
    main()
