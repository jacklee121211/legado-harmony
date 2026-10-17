# -*- coding: utf-8 -*-
"""promo/video/demo_transitions.py —— 两个"信息型转场"样片

A  框内多页横滑：机框不动，5 个页面在屏幕里像胶片一样横向滑过
B  一页裂成多张卡：机框缩小上移，3 张材质卡从框里"飞"出来排到下方（带透视）

两者都只用**真实截图**，不做任何 UI 重绘。
输出：docs/宣发物料/02_成片/样片/*.mp4

依赖：Pillow + numpy + opencv（透视用 cv2，实测 2.2ms/帧；PIL 的 QUAD 要 37.7ms）
"""

import math
import os
import subprocess
import sys

import cv2
import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from PIL import Image, ImageDraw, ImageFilter

import kit
import scenes as SCN

HERE = os.path.dirname(os.path.abspath(__file__))
PROJECT = os.path.dirname(os.path.dirname(HERE))
MAT = os.path.join(PROJECT, 'docs', '宣发物料', '00_原始素材', '截图')
FALLBACK = os.path.join(PROJECT, 'promo', 'src')
OUT = os.path.join(PROJECT, 'docs', '宣发物料', '02_成片', '样片')

CANVAS = (1080, 1920)
FPS = 30
SYS = 0.0449


# ── 素材 ────────────────────────────────────────────────────────────────────

def resolve(name):
    for d in (MAT, FALLBACK):
        p = os.path.join(d, name)
        if os.path.exists(p):
            return p
    raise SystemExit(f'找不到素材 {name}')


def app_canvas(name):
    """截图 → 裁掉系统栏 → 居中 cover 到统一画布比例 0.4853。"""
    im = Image.open(resolve(name)).convert('RGB')
    cut = int(round(im.size[1] * SYS))
    im = im.crop((0, cut, im.size[0], im.size[1]))
    ar = im.size[0] / im.size[1]
    target = 1320 / 2720
    w, h = im.size
    if ar > target:
        nw = int(round(h * target))
        x = (w - nw) // 2
        return im.crop((x, 0, x + nw, h))
    nh = int(round(w / target))
    y = (h - nh) // 2
    return im.crop((0, y, w, y + nh))


def rounded_card(im, w, radius_ratio=0.082, border=3, bottom_square=False):
    ar = im.size[0] / im.size[1]
    h = int(round(w / ar))
    body = im.resize((w, h), Image.LANCZOS)
    r = int(round(w * radius_ratio))
    mask = Image.new('L', (w, h), 0)
    d = ImageDraw.Draw(mask)
    d.rounded_rectangle((0, 0, w - 1, h - 1), r, fill=255)
    if bottom_square:
        d.rectangle((0, h - r - 1, w - 1, h - 1), fill=255)
    out = Image.new('RGBA', (w, h), (0, 0, 0, 0))
    out.paste(body, (0, 0), mask)
    edge = Image.new('RGBA', (w, h), (0, 0, 0, 0))
    ImageDraw.Draw(edge).rounded_rectangle((0, 0, w - 1, h - 1), r,
                                           outline=(255, 255, 255, 76), width=border)
    return Image.alpha_composite(out, edge)


def drop_shadow(canvas, box, radius, blur, alpha=150, dy=22, inset=6):
    W, H = canvas.size
    sh = Image.new('RGBA', (W, H), (0, 0, 0, 0))
    x0, y0, x1, y1 = box
    ImageDraw.Draw(sh).rounded_rectangle((x0 + inset, y0 + dy, x1 - inset, y1 + dy),
                                         radius, fill=(0, 0, 0, alpha))
    return Image.alpha_composite(canvas, sh.filter(ImageFilter.GaussianBlur(blur)))


def warp_onto(canvas_size, sprite, cx, cy, angle=0.0, persp=0.0, scale=1.0, alpha=1.0):
    """把 RGBA 精灵做「缩放 + 旋转 + 透视」后贴到指定中心，返回整画布 RGBA 层。

    persp > 0 ⇒ 右边缘张开、左边缘收窄（像从侧面看过去）。
    """
    W, H = sprite.size
    tw, th = max(2, int(W * scale)), max(2, int(H * scale))
    arr = np.ascontiguousarray(np.asarray(sprite.convert('RGBA')))
    src = cv2.resize(arr, (tw, th), interpolation=cv2.INTER_AREA if scale < 1 else cv2.INTER_LINEAR)

    p = np.float32([[-tw / 2, -th / 2], [tw / 2, -th / 2], [tw / 2, th / 2], [-tw / 2, th / 2]])
    q = p.copy()
    if persp:
        k = th * persp / 2.0
        q[0, 1] -= k          # 左上收
        q[3, 1] += k          # 左下收
        q[1, 1] += k * 0.35   # 右上略张
        q[2, 1] -= k * 0.35   # 右下略张
    if angle:
        a = math.radians(angle)
        R = np.array([[math.cos(a), -math.sin(a)], [math.sin(a), math.cos(a)]], np.float32)
        q = q @ R.T
    q = q + np.float32([cx, cy])

    src_abs = p + np.float32([tw / 2, th / 2])
    M = cv2.getPerspectiveTransform(src_abs, q)
    out = cv2.warpPerspective(src, M, canvas_size, flags=cv2.INTER_LINEAR,
                              borderMode=cv2.BORDER_CONSTANT, borderValue=(0, 0, 0, 0))
    layer = Image.fromarray(out, 'RGBA')
    if alpha < 1.0:
        layer = kit.set_alpha(layer, alpha)
    return layer


# ── 文本块（复用 video 的竖版排版）──────────────────────────────────────────

def text_block(canvas, title, sub, accent, t, t0=0.10):
    """标题逐字上浮 + 强调条生长 + 副标题淡入。返回新的画布。"""
    W, H = canvas.size
    mx, top = 96, 116
    chip = kit.chip_img(f'{SCN.BRAND} · {SCN.BRAND_SUB}', 'medium', 28, (255, 255, 255, 235))
    title_px, sub_px = 100, 42

    layer = Image.new('RGBA', (W, H), (0, 0, 0, 0))
    a = kit.clamp01(kit.span(t, t0, t0 + 0.30))
    if a > 0:
        e = kit.ease_out_cubic(a)
        layer.alpha_composite(kit.set_alpha(chip, a), (mx, top + int(round(14 * (1 - e)))))

    y = top + chip.size[1] + 26
    f = kit.font('bold', title_px)
    probe = ImageDraw.Draw(Image.new('RGBA', (8, 8)))
    x = mx
    for i, ch in enumerate(title):
        a = kit.clamp01(kit.span(t, t0 + 0.14 + 0.055 * i, t0 + 0.14 + 0.055 * i + 0.42))
        if a > 0:
            e = kit.ease_out_cubic(a)
            img = kit.set_alpha(kit.text_img(ch, 'bold', title_px, (255, 255, 255, 255)), a)
            layer.alpha_composite(img, (int(x), y + int(round(26 * (1 - e)))))
        x += probe.textlength(ch, font=f)

    bar_y = y + int(round(title_px * 1.18)) + 34
    g = kit.ease_out_quint(kit.clamp01(kit.span(t, t0 + 0.42, t0 + 0.86)))
    if g > 0:
        bw = max(2, int(round(112 * g)))
        layer.alpha_composite(Image.new('RGBA', (bw, 10), tuple(accent) + (255,)), (mx, bar_y))

    a = kit.clamp01(kit.span(t, t0 + 0.48, t0 + 0.84))
    if a > 0:
        e = kit.ease_out_cubic(a)
        sub_img = kit.set_alpha(kit.text_img(sub, 'medium', sub_px, (255, 255, 255, 232)), a)
        layer.alpha_composite(sub_img, (mx, bar_y + 10 + 30 + int(round(20 * (1 - e)))))

    return Image.alpha_composite(canvas.convert('RGBA'), layer)


def background(c1, c2, accent):
    return kit.make_background(CANVAS, c1, c2, accent, blur_scale=1.0).convert('RGBA')


# ── A：框内多页横滑 ─────────────────────────────────────────────────────────

A_PAGES = ['02_书架_喵阅_完整版.jpg', '05_color.jpg', '03_material.jpg',
           '04_font.jpg', '07_ai_tts.jpg']


def render_A(out_path, dur=3.2):
    S = SCN.SCENES[3]
    bg = background(S['c1'], S['c2'], S['accent'])
    pages = [app_canvas(n) for n in A_PAGES]

    sw = 620
    sh = int(round(sw / (1320 / 2720)))
    phone = kit.Phone(sw, sh, island=False)
    inner = (phone.screen_box[2] - phone.screen_box[0],
             phone.screen_box[3] - phone.screen_box[1])
    pw, ph = phone.size
    px = (CANVAS[0] - pw) // 2
    py = CANVAS[1] - 64 - ph

    # 5 页横向拼成一条胶片，逐帧裁窗口 ⇒ 不会有负坐标合成的坑
    step = inner[0]
    strip = Image.new('RGBA', (step * len(pages), inner[1]), (245, 242, 238, 255))
    for k, p in enumerate(pages):
        strip.alpha_composite(p.resize(inner, Image.LANCZOS).convert('RGBA'), (k * step, 0))

    n = len(pages)
    t_start, hold, move = 0.62, 0.16, 0.30
    frames = int(round(dur * FPS))

    def frame(i):
        t = i / FPS
        canvas = bg.copy()

        pin = kit.ease_out_expo(kit.clamp01(kit.span(t, 0.0, 0.75)))
        a_in = kit.clamp01(kit.span(t, 0.0, 0.35))
        dy = int(round(kit.lerp(60, 0, pin)))

        pos = 0.0
        for k in range(n - 1):
            s = t_start + k * (hold + move)
            pos += kit.ease_in_out_cubic(kit.clamp01((t - s) / move))
        off = int(round(pos * step))

        screen = strip.crop((off, 0, off + step, inner[1]))
        dev = phone.compose(screen)
        if a_in < 1.0:
            dev = kit.set_alpha(dev, a_in)
        canvas = drop_shadow(canvas, (px, py + dy, px + pw, py + ph + dy), int(pw * 0.12), 34)
        canvas.paste(dev, (px, py + dy), dev)
        canvas = text_block(canvas, '鸿蒙赋能', '沉浸光感，全新UI超美观！', S['accent'], t)
        return canvas.convert('RGB')

    encode(frame, frames, out_path)


# ── B：一页裂成三张卡 ───────────────────────────────────────────────────────

B_CARDS = ['mat_a_leather.jpg', 'mat_b_floral.jpg', 'mat_c_feather.jpg']

# B 用的真实素材：从 124829 里抽三套不同主题色（同一页面不同配色 ⇒ 小尺寸也一眼能分辨）
THEME_CLIP = os.path.join(PROJECT, 'docs', '宣发物料', '00_原始素材', '录屏',
                          'SVID_20261017_124829_1.mp4')
THEME_T = [0.40, 6.50, 8.50]


def theme_canvas(t):
    """从录屏抽一帧 → 裁系统栏 → cover 到画布比例。"""
    import io
    r = subprocess.run(['ffmpeg', '-v', 'error', '-ss', f'{t:.2f}', '-i', THEME_CLIP,
                        '-frames:v', '1', '-f', 'image2pipe', '-vcodec', 'png', '-'],
                       capture_output=True)
    if not r.stdout:
        raise SystemExit(f'抽帧失败 t={t}')
    im = Image.open(io.BytesIO(r.stdout)).convert('RGB')
    cut = int(round(im.size[1] * SYS))
    im = im.crop((0, cut, im.size[0], im.size[1]))
    w, h = im.size
    target = 1320 / 2720
    if w / h > target:
        nw = int(round(h * target))
        x = (w - nw) // 2
        return im.crop((x, 0, x + nw, h))
    nh = int(round(w / target))
    y = (h - nh) // 2
    return im.crop((0, y, w, y + nh))


def render_B(out_path, dur=3.4):
    S = SCN.SCENES[3]
    bg = background(S['c1'], S['c2'], S['accent'])

    sw_big = 620
    sh_big = int(round(sw_big / (1320 / 2720)))
    phone = kit.Phone(sw_big, sh_big, island=False)
    inner = (phone.screen_box[2] - phone.screen_box[0], phone.screen_box[3] - phone.screen_box[1])
    dev_big = phone.compose(theme_canvas(THEME_T[0]).resize(inner, Image.LANCZOS))
    pw, ph = phone.size
    px = (CANVAS[0] - pw) // 2
    py = CANVAS[1] - 64 - ph

    card_w = 325
    sprites = [rounded_card(theme_canvas(t), card_w) for t in THEME_T]
    cw, ch = sprites[0].size
    gap = 26
    row_y = 1150
    xs = [gap + k * (cw + gap) + cw // 2 for k in range(3)]
    origin = (CANVAS[0] / 2, py + ph * 0.45)      # 从机身屏幕中部裂出

    frames = int(round(dur * FPS))

    def frame(i):
        t = i / FPS
        canvas = bg.copy()

        # 机身：上浮淡入 → 卡片飞出时退场（缩小 + 淡出）
        pin = kit.ease_out_expo(kit.clamp01(kit.span(t, 0.0, 0.7)))
        dy = int(round(kit.lerp(60, 0, pin)))
        p_out = kit.ease_in_out_cubic(kit.clamp01(kit.span(t, 0.80, 1.55)))
        sc = kit.lerp(1.0, 0.86, p_out)
        a_dev = kit.lerp(kit.clamp01(kit.span(t, 0.0, 0.3)), 0.0, p_out)

        if a_dev > 0.01:
            dev = dev_big.resize((max(2, int(pw * sc)), max(2, int(ph * sc))), Image.LANCZOS)
            dev = kit.set_alpha(dev, a_dev)
            bx = int(px + pw / 2 - dev.size[0] / 2)
            by = int(py + dy + ph / 2 - dev.size[1] / 2)
            canvas = drop_shadow(canvas, (bx, by, bx + dev.size[0], by + dev.size[1]),
                                 int(dev.size[0] * 0.12), 30, alpha=int(150 * a_dev))
            canvas.paste(dev, (bx, by), dev)

        # 三张卡：从机身屏幕中部飞出，带旋转 + 透视，依次落地
        for k, sp in enumerate(sprites):
            s0 = 0.62 + 0.11 * k
            p = kit.ease_out_cubic(kit.clamp01(kit.span(t, s0, s0 + 0.95)))
            if p <= 0:
                continue
            cx = kit.lerp(origin[0], xs[k], p)
            cy = kit.lerp(origin[1], row_y, p)
            sc2 = kit.lerp(0.30, 1.0, p)
            ang = kit.lerp(-24 + 8 * k, 0.0, p)
            persp = kit.lerp(0.26, 0.0, p)
            a = kit.clamp01(p * 2.4)
            layer = warp_onto(CANVAS, sp, cx, cy, angle=ang, persp=persp, scale=sc2, alpha=a)
            canvas = Image.alpha_composite(canvas, layer)

        canvas = text_block(canvas, '更多预设', '自由调盘，万千色彩随你定！', S['accent'], t)
        return canvas.convert('RGB')

    encode(frame, frames, out_path)


# ── 编码 ────────────────────────────────────────────────────────────────────

def encode(frame_fn, n_frames, out_path):
    W, H = CANVAS
    os.makedirs(os.path.dirname(out_path), exist_ok=True)
    cmd = ['ffmpeg', '-y', '-v', 'error', '-f', 'rawvideo', '-pix_fmt', 'rgb24',
           '-s', f'{W}x{H}', '-r', str(FPS), '-i', '-',
           '-vf', 'format=yuv420p', '-c:v', 'libx264', '-preset', 'slow', '-crf', '17',
           '-movflags', '+faststart', out_path]
    proc = subprocess.Popen(cmd, stdin=subprocess.PIPE)
    for i in range(n_frames):
        proc.stdin.write(frame_fn(i).tobytes())
    proc.stdin.close()
    proc.wait()
    if proc.returncode != 0:
        raise SystemExit('ffmpeg 失败')
    print(f'[ok] {os.path.basename(out_path)}  {n_frames} 帧  {os.path.getsize(out_path)//1024} KB')


def main():
    os.makedirs(OUT, exist_ok=True)
    render_A(os.path.join(OUT, '样片A_框内多页横滑.mp4'))
    render_B(os.path.join(OUT, '样片B_一页裂出多卡.mp4'))


if __name__ == '__main__':
    main()
