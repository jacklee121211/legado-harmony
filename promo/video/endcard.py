# -*- coding: utf-8 -*-
"""promo/video/endcard.py —— 片尾卡（动画版）

内容：品牌胶囊 / 喵阅 / 标语 / **应用市场搜索栏** / 支持格式 / 合规脚注
      **已移除社区群号**（2026-10-17 用户决定不要了）

搜索栏动画（片尾的重点）：
    ① 搜索栏淡入放大
    ② 「喵」「阅」**逐字打出**（带光标闪烁）
    ③ 小鼠标箭头从右下 **滑到放大镜上**
    ④ 点击 → 放大镜 **Q 弹**（压扁→回弹→过冲→归位）+ 一圈扩散水波
    ⑤ 提示文字与支持格式随后淡入

用法：
    python promo/video/endcard.py                      # 静帧（动画终态）
    python promo/video/endcard.py --size 1920x1080
"""

import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from PIL import Image, ImageDraw

import kit

OUT_DIR = os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(
    os.path.abspath(__file__)))), 'docs', '宣发物料', '02_成片')
ICON_APPGALLERY = os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(
    os.path.abspath(__file__)))), 'docs', '宣发物料', 'PNG+SVG', 'PNG', '应用市场@4x.png')

BRAND = '喵阅'
TAGLINE = '极致的本地书籍阅读器'
FORMATS = '支持 TXT / EPUB / MOBI / AZW / AZW3'
CAPTION = '在华为应用市场搜索「喵阅」'
DISCLAIMER = ('本软件不提供 API Key，请自行配置。'
              '本软件无服务器，不收集任何用户信息，请放心使用。')
SEARCH_TEXT = '喵阅'

C1 = (52, 20, 6)
C2 = (168, 78, 18)
ACCENT = (255, 198, 120)

# ——— 时间轴（相对片尾段起点，秒）———
T_CHIP = (0.05, 0.55)
T_TAG = (0.35, 0.80)
T_BAR = (0.75, 1.15)
T_TYPE0 = 1.15
TYPE_STEP = 0.38
T_CURSOR = 1.95
T_MOVE = (2.00, 2.72)
T_CLICK = 2.75
T_BOUNCE = 0.55
T_CAP = (3.10, 3.50)
T_FMT = (3.30, 3.70)

_ASSETS = {}


def _cursor(s):
    W = s(40)
    img = Image.new('RGBA', (W, W), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    unit = W / 18.0
    pts = [(0, 0), (0, 16), (4.6, 11.4), (7.2, 17.4), (9.8, 16.4), (7.2, 10.4), (12.2, 10.4)]
    poly = [(unit * x, unit * y) for x, y in pts]
    d.polygon(poly, fill=(255, 255, 255, 255), outline=(26, 26, 30, 255), width=max(2, s(3)))
    return img


def _magnifier(s, r):
    pad = int(r * 1.9)
    W = pad * 2
    img = Image.new('RGBA', (W, W), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    col = (150, 150, 158, 255)
    d.ellipse((pad - r, pad - r, pad + r, pad + r), outline=col, width=max(3, s(4)))
    d.line((pad + r * 0.72, pad + r * 0.72, pad + r * 1.52, pad + r * 1.52),
           fill=col, width=max(3, s(5)))
    return img


def _bounce(p):
    """Q 弹曲线：压扁 → 回弹过冲 → 小回摆 → 归位。"""
    keys = [(0.00, 1.00), (0.12, 0.78), (0.30, 1.22), (0.48, 0.90),
            (0.66, 1.08), (0.84, 0.96), (1.00, 1.00)]
    p = kit.clamp01(p)
    for i in range(len(keys) - 1):
        a, va = keys[i]
        b, vb = keys[i + 1]
        if a <= p <= b:
            u = (p - a) / (b - a)
            u = u * u * (3 - 2 * u)
            return va + (vb - va) * u
    return 1.0


def wrap_cn(text, font, max_w, probe):
    NO_HEAD = '，。、！？：；）」』】》%…'
    lines, cur = [], ''
    for ch in text:
        if probe.textlength(cur + ch, font=font) <= max_w or (cur and ch in NO_HEAD):
            cur += ch
        else:
            lines.append(cur)
            cur = ch
    if cur:
        lines.append(cur)
    return lines


def _assets(s, key):
    if key in _ASSETS:
        return _ASSETS[key]

    icon_px = s(80)
    icon = Image.open(ICON_APPGALLERY).convert('RGBA').resize((icon_px, icon_px), Image.LANCZOS)

    bar_w, bar_h = s(700), s(122)
    panel = Image.new('RGBA', (bar_w, bar_h), (0, 0, 0, 0))
    pd = ImageDraw.Draw(panel)
    pd.rounded_rectangle((0, 0, bar_w - 1, bar_h - 1), bar_h // 2, fill=(255, 255, 255, 250))
    pd.rounded_rectangle((0, 0, bar_w - 1, bar_h - 1), bar_h // 2,
                         outline=(255, 255, 255, 110), width=max(2, s(2)))
    panel.alpha_composite(icon, (s(21), (bar_h - icon_px) // 2))

    A = dict(
        chip=kit.chip_img(f'{BRAND} · HarmonyOS 阅读器', 'medium', s(28), (255, 255, 255, 240)),
        brand=kit.text_img(BRAND, 'bold', s(148), (255, 255, 255, 255)),
        tag=kit.text_img(TAGLINE, 'medium', s(52), (255, 236, 214, 245)),
        fmt=kit.text_img(FORMATS, 'regular', s(30), (255, 240, 226, 210)),
        cap=kit.text_img(CAPTION, 'regular', s(27), (255, 240, 226, 195)),
        panel=panel, bar_w=bar_w, bar_h=bar_h, icon_w=icon_px,
        text_x=s(21) + icon_px + s(22),
        mag_r=s(19), mag_cx=bar_w - s(60), mag_cy=bar_h // 2,
        cursor=_cursor(s),
        probe=ImageDraw.Draw(Image.new('RGBA', (8, 8))),
    )
    _ASSETS[key] = A
    return A


def render_frame(t, size):
    W, H = size
    wide = W > H
    scale = (H / 1080.0) if wide else (W / 1080.0)

    def s(v):
        return int(round(v * scale))

    A = _assets(s, (size, wide))
    canvas = kit.make_background(size, C1, C2, ACCENT, blur_scale=scale).convert('RGBA')

    # ── 搜索栏：逐字打字 + 放大镜 Q 弹 + 点击水波 ───────────────────────────
    typed = ''.join(ch for i, ch in enumerate(SEARCH_TEXT) if t >= T_TYPE0 + i * TYPE_STEP)
    caret_on = (len(typed) < len(SEARCH_TEXT) and t >= T_TYPE0
                and int((t - T_TYPE0) * 4) % 2 == 0)
    mag_scale = _bounce((t - T_CLICK) / T_BOUNCE) if t >= T_CLICK else 1.0

    bar = A['panel'].copy()
    bd = ImageDraw.Draw(bar)
    f = kit.font('medium', s(54))
    tx, ty = A['text_x'], (A['bar_h'] - s(54)) // 2 - s(4)
    bd.text((tx, ty), typed, font=f, fill=(24, 24, 26, 255))
    if caret_on:
        cw = max(2, s(3))
        cx_t = tx + A['probe'].textlength(typed, font=f) + s(3)
        bd.rectangle((cx_t, ty + s(6), cx_t + cw, ty + s(52)), fill=(24, 24, 26, 230))

    mag = _magnifier(s, A['mag_r'])
    if abs(mag_scale - 1.0) > 1e-3:
        mw = max(4, int(mag.size[0] * mag_scale))
        mag = mag.resize((mw, mw), Image.LANCZOS)
    bar.alpha_composite(mag, (A['mag_cx'] - mag.size[0] // 2, A['mag_cy'] - mag.size[1] // 2))

    if T_CLICK <= t <= T_CLICK + 0.45:
        p = (t - T_CLICK) / 0.45
        rr = int(A['mag_r'] * (1.2 + 1.7 * p))
        ring = Image.new('RGBA', bar.size, (0, 0, 0, 0))
        ImageDraw.Draw(ring).ellipse(
            (A['mag_cx'] - rr, A['mag_cy'] - rr, A['mag_cx'] + rr, A['mag_cy'] + rr),
            outline=(255, 255, 255, int(150 * (1 - p))), width=max(2, s(3)))
        bar = Image.alpha_composite(bar, ring)

    # ── 先把各元素透明度算出来 ──────────────────────────────────────────────
    a_chip = kit.clamp01(kit.span(t, *T_CHIP))
    a_tag = kit.clamp01(kit.span(t, *T_TAG))
    a_bar = kit.clamp01(kit.span(t, *T_BAR))
    a_cap = kit.clamp01(kit.span(t, *T_CAP))
    a_fmt = kit.clamp01(kit.span(t, *T_FMT))

    layer = Image.new('RGBA', size, (0, 0, 0, 0))

    # ── 布局：先把搜索栏坐标定出来（鼠标要用）──────────────────────────────
    if not wide:
        cx = W // 2
        rows = [('chip', A['chip'].size[1], s(24), a_chip),
                ('brand', A['brand'].size[1], s(16), 1.0),
                ('tag', A['tag'].size[1], s(46), a_tag),
                ('__BAR__', A['bar_h'], s(12), a_bar),
                ('cap', A['cap'].size[1], s(30), a_cap),
                ('fmt', A['fmt'].size[1], 0, a_fmt)]
        total = sum(h + g for _, h, g, _ in rows)
        top_min, bottom_reserved = s(160), s(300)
        y = top_min + max(0, ((H - bottom_reserved) - top_min - total) // 2)
        bar_pos = None
        for key, h, g, a in rows:
            y += g
            if key == '__BAR__':
                bar_pos = (cx - A['bar_w'] // 2, y)
            elif a > 0:
                layer.alpha_composite(kit.set_alpha(A[key], a),
                                      (cx - A[key].size[0] // 2, y))
            y += h
    else:
        lx = s(230)
        left = [('chip', 0, a_chip), ('brand', s(26), 1.0),
                ('tag', s(18), a_tag), ('fmt', s(30), a_fmt)]
        lh = sum(A[k].size[1] + g for k, g, _ in left)
        y = (H - lh) // 2
        for k, g, a in left:
            y += g
            if a > 0:
                layer.alpha_composite(kit.set_alpha(A[k], a), (lx, y))
            y += A[k].size[1]

        rcx = int(W * 0.715)
        y0 = (H - A['bar_h'] - s(12) - A['cap'].size[1]) // 2
        bar_pos = (rcx - A['bar_w'] // 2, y0)
        if a_cap > 0:
            layer.alpha_composite(kit.set_alpha(A['cap'], a_cap),
                                  (rcx - A['cap'].size[0] // 2, y0 + A['bar_h'] + s(12)))

    if a_bar > 0 and bar_pos is not None:
        bx, by = bar_pos
        sc = kit.lerp(0.94, 1.0, kit.ease_out_cubic(a_bar))
        im = kit.set_alpha(bar, a_bar)
        if sc != 1.0:
            im = im.resize((int(bar.size[0] * sc), int(bar.size[1] * sc)), Image.LANCZOS)
        layer.alpha_composite(im, (bx + (A['bar_w'] - im.size[0]) // 2,
                                   by + (A['bar_h'] - im.size[1]) // 2))

    # ── 鼠标箭头 ────────────────────────────────────────────────────────────
    if t >= T_CURSOR and bar_pos is not None:
        bx, by = bar_pos
        sx = bx + A['bar_w'] * 0.40
        sy = by + A['bar_h'] + s(84)
        ex = bx + A['mag_cx'] - s(3)
        ey = by + A['mag_cy'] - s(3)
        p = kit.ease_in_out_cubic(kit.clamp01((t - T_MOVE[0]) / (T_MOVE[1] - T_MOVE[0])))
        a_cur = kit.clamp01(kit.span(t, T_CURSOR, T_CURSOR + 0.25))

        press = 1.0
        if T_CLICK <= t <= T_CLICK + 0.18:
            u = (t - T_CLICK) / 0.09
            press = 1.0 - 0.15 * (1 - abs(u - 1))
        img = A['cursor']
        if abs(press - 1.0) > 1e-3:
            img = img.resize((max(4, int(img.size[0] * press)),
                              max(4, int(img.size[1] * press))), Image.LANCZOS)
        layer.alpha_composite(kit.set_alpha(img, a_cur),
                              (int(kit.lerp(sx, ex, p)), int(kit.lerp(sy, ey, p))))

    canvas = Image.alpha_composite(canvas, layer)

    # ── 合规脚注 ────────────────────────────────────────────────────────────
    f2 = kit.font('regular', s(23))
    lines = wrap_cn(DISCLAIMER, f2, W - s(150), A['probe'])
    fy = H - s(60) - len(lines) * s(34)
    foot = Image.new('RGBA', size, (0, 0, 0, 0))
    for i, ln in enumerate(lines):
        img = kit.text_img(ln, 'regular', s(23), (255, 246, 236, 165))
        foot.alpha_composite(img, (W // 2 - img.size[0] // 2, fy + i * s(34)))
    return Image.alpha_composite(canvas, foot).convert('RGB')


def build(size):
    """静帧 = 动画终态。"""
    return render_frame(99.0, size)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--size', default='1080x1920')
    ap.add_argument('--name', default=None)
    args = ap.parse_args()
    W, H = (int(v) for v in args.size.lower().split('x'))
    img = build((W, H))
    name = args.name or f'片尾卡_{W}x{H}.png'
    os.makedirs(OUT_DIR, exist_ok=True)
    p = os.path.join(OUT_DIR, name)
    img.save(p)
    print(f'[ok] {p}  {img.size[0]}x{img.size[1]}  {os.path.getsize(p) // 1024} KB')


if __name__ == '__main__':
    main()
