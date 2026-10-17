# -*- coding: utf-8 -*-
"""promo/video/film.py —— 宣发片渲染（竖版 / 横版，同一份 storyboard）

用法：
    python promo/video/film.py                 # 竖版 1080x1920
    python promo/video/film.py --mode wide     # 横版 1920x1080

两套版式（**不是缩放**）：
    竖版：文案在顶部，机身居中偏下，裂卡横排在下部
    横版：文案在左上，机身在右侧，裂卡横排在下方

11 段 / 55.4s。段间一律硬切（录屏段带操作动作，淡入淡出会糊掉动作起点）。
"""

import argparse
import os
import subprocess
import sys

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import kit
import mateframe
import scenes as SCN

HERE = os.path.dirname(os.path.abspath(__file__))
PROJECT = os.path.dirname(os.path.dirname(HERE))
CLIP = os.path.join(PROJECT, 'docs', '宣发物料', '00_原始素材', '录屏')
EDITED = os.path.join(PROJECT, 'docs', '宣发物料', '02_成片', '剪辑')
MAT = os.path.join(PROJECT, 'docs', '宣发物料', '00_原始素材', '截图')
FALLBACK = os.path.join(PROJECT, 'promo', 'src')
OUT = os.path.join(PROJECT, 'docs', '宣发物料', '02_成片')

FPS = 30
ASPECT = 1320 / 2720
SYS = 0.0449
CUT_890 = 86
CROP_H_890 = int(round(890 / ASPECT))

# 由 configure() 填充
CANVAS = (1080, 1920)
SW = 600
SH = 1294
L = {}
MODE = 'tall'


def configure(mode):
    global CANVAS, SW, SH, L, MODE
    MODE = mode
    if mode == 'tall':
        CANVAS = (1080, 1920)
        SW = 600
        L = dict(mx=96, top=116, title=100, sub=42, chip_px=28,
                 phone_bottom=64, phone_right=None,
                 burst_card=325, burst_row_y=1150, burst_gap=26,
                 close_dy=340, rise_dy=300)
    else:
        # 横版：文案与机身**都往中间收**（用户：太往两端了，不便阅览）
        CANVAS = (1920, 1080)
        SW = 410
        L = dict(mx=230, top=90, title=130, sub=48, chip_px=28,
                 phone_bottom=None, phone_right=230,
                 burst_card=250, burst_row_y=760, burst_gap=26,
                 close_dy=240, rise_dy=240)
    SH = mateframe.info(SW)['screen'][1]


# ── 素材 ────────────────────────────────────────────────────────────────────

def resolve(name):
    for d in (MAT, FALLBACK):
        p = os.path.join(d, name)
        if os.path.exists(p):
            return p
    raise SystemExit(f'找不到素材 {name}')


def app_canvas(img):
    cut = int(round(img.size[1] * SYS))
    im = img.crop((0, cut, img.size[0], img.size[1]))
    w, h = im.size
    if w / h > ASPECT:
        nw = int(round(h * ASPECT))
        x = (w - nw) // 2
        return im.crop((x, 0, x + nw, h))
    nh = int(round(w / ASPECT))
    y = (h - nh) // 2
    return im.crop((0, y, w, y + nh))


def still_canvas(name):
    return app_canvas(Image.open(resolve(name)).convert('RGB'))


def video_stream(clip, t0, t1, speed=1.0):
    """speed < 1 = 慢放（工具栏展开这类"真实动画只有 0.1s"的镜头需要）。"""
    vf = (f'trim=start={t0}:end={t1},setpts=(PTS-STARTPTS)/{speed},'
          f'crop=890:{CROP_H_890}:0:{CUT_890},'
          f'scale={SW}:{SH}:flags=lanczos,fps={FPS}')
    cmd = ['ffmpeg', '-v', 'error', '-i', clip, '-vf', vf,
           '-f', 'rawvideo', '-pix_fmt', 'rgb24', '-']
    p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    n = SW * SH * 3
    try:
        while True:
            buf = p.stdout.read(n)
            if not buf or len(buf) < n:
                break
            yield Image.frombytes('RGB', (SW, SH), buf)
    finally:
        p.stdout.close()
        p.wait()


def clip_frame(clip, t):
    vf = (f'trim=start={t}:end={t + 0.2},setpts=PTS-STARTPTS,'
          f'crop=890:{CROP_H_890}:0:{CUT_890},scale={SW}:{SH}:flags=lanczos')
    cmd = ['ffmpeg', '-v', 'error', '-i', clip, '-vf', vf, '-frames:v', '1',
           '-f', 'image2pipe', '-vcodec', 'png', '-']
    r = subprocess.run(cmd, capture_output=True)
    if not r.stdout:
        raise SystemExit(f'抽帧失败：{os.path.basename(clip)} @ {t}s')
    from io import BytesIO
    return Image.open(BytesIO(r.stdout)).convert('RGB')


# ── 版面 ────────────────────────────────────────────────────────────────────

def background(scene):
    return kit.make_background(CANVAS, scene['c1'], scene['c2'], scene['accent'],
                               blur_scale=CANVAS[0] / 1080.0).convert('RGBA')


class Stage:
    def __init__(self, scene):
        self.scene = scene
        self.bg = background(scene)
        self.dev_size = mateframe.info(SW)['device']
        pw, ph = self.dev_size
        if L.get('phone_bottom') is not None:
            self.pos = ((CANVAS[0] - pw) // 2, CANVAS[1] - L['phone_bottom'] - ph)
        else:
            self.pos = (CANVAS[0] - L['phone_right'] - pw, (CANVAS[1] - ph) // 2)
        sh = Image.new('RGBA', CANVAS, (0, 0, 0, 0))
        ImageDraw.Draw(sh).rounded_rectangle(
            (self.pos[0] + 8, self.pos[1] + 24, self.pos[0] + pw - 8, self.pos[1] + ph + 24),
            int(pw * 0.12), fill=(0, 0, 0, 165))
        self.shadow = sh.filter(ImageFilter.GaussianBlur(int(CANVAS[0] * 0.03)))

    def base(self, alpha=1.0):
        """背景 + 投影；alpha 跟随机身淡入淡出（否则机身没了投影还在，留一团黑影）。"""
        c = self.bg.copy()
        if alpha >= 0.999:
            return Image.alpha_composite(c, self.shadow)
        if alpha <= 0.001:
            return c
        return Image.alpha_composite(c, kit.set_alpha(self.shadow, alpha))

    def compose(self, screen_img):
        """把屏幕内容贴进**真实 Mate 80 边框**（摄像头已填平）。"""
        return mateframe.compose(screen_img, SW)

    def put_phone(self, canvas, screen_img, dy=0, alpha=1.0):
        dev = self.compose(screen_img)
        if alpha < 1.0:
            dev = kit.set_alpha(dev, alpha)
        canvas.paste(dev, (self.pos[0], self.pos[1] + int(dy)), dev)
        return canvas


def text_layer(canvas, title, sub, accent, t, t0=0.10, static=False):
    """文案：竖版贴顶部、横版贴左上；整组约 1.15s 走完。"""
    W, H = CANVAS
    mx, title_px, sub_px, chip_px = L['mx'], L['title'], L['sub'], L['chip_px']

    chip = kit.chip_img(f'{SCN.BRAND} · {SCN.BRAND_SUB}', 'medium', chip_px, (255, 255, 255, 235))
    sub_img = kit.text_img(sub, 'medium', sub_px, (255, 255, 255, 232))
    f = kit.font('bold', title_px)
    probe = ImageDraw.Draw(Image.new('RGBA', (8, 8)))

    title_h = int(round(title_px * 1.18))
    bar_y_off = chip.size[1] + 26 + title_h + 34
    y0 = L['top']

    if static:
        t = 99.0
    layer = Image.new('RGBA', (W, H), (0, 0, 0, 0))

    a = kit.clamp01(kit.span(t, t0, t0 + 0.45))
    if a > 0:
        e = kit.ease_out_cubic(a)
        layer.alpha_composite(kit.set_alpha(chip, a), (mx, y0 + int(round(14 * (1 - e)))))

    y = y0 + chip.size[1] + 26
    x = mx
    for i, ch in enumerate(title):
        a = kit.clamp01(kit.span(t, t0 + 0.18 + 0.10 * i, t0 + 0.18 + 0.10 * i + 0.55))
        if a > 0:
            e = kit.ease_out_cubic(a)
            img = kit.set_alpha(kit.text_img(ch, 'bold', title_px, (255, 255, 255, 255)), a)
            layer.alpha_composite(img, (int(x), y + int(round(26 * (1 - e)))))
        x += probe.textlength(ch, font=f)

    bar_y = y0 + bar_y_off
    g = kit.ease_out_quint(kit.clamp01(kit.span(t, t0 + 0.55, t0 + 1.00)))
    if g > 0:
        bw = max(2, int(round(112 * g)))
        layer.alpha_composite(Image.new('RGBA', (bw, 10), tuple(accent) + (255,)), (mx, bar_y))

    a = kit.clamp01(kit.span(t, t0 + 0.66, t0 + 1.10))
    if a > 0:
        e = kit.ease_out_cubic(a)
        layer.alpha_composite(kit.set_alpha(sub_img, a),
                              (mx, bar_y + 40 + int(round(20 * (1 - e)))))
    return Image.alpha_composite(canvas.convert('RGBA'), layer)


def ease(a):
    return kit.ease_out_cubic(a)


# ── 各类段 ──────────────────────────────────────────────────────────────────

def seg_intro():
    """片头：静态 1 秒。"""
    W, H = CANVAS
    scene = SCN.SCENES[0]
    canvas = background(scene)
    # 竖版画幅窄、横版画幅宽 —— 字体要分别定，不能用同一个系数缩
    px = dict(brand=230, tag=62, fmt=32, chip=32, bar_w=132, bar_h=12) if MODE == 'tall' else \
        dict(brand=168, tag=50, fmt=28, chip=26, bar_w=110, bar_h=10)

    chip = kit.chip_img(f'{SCN.BRAND} · {SCN.BRAND_SUB}', 'medium', px['chip'], (255, 255, 255, 240))
    brand = kit.text_img(SCN.BRAND, 'bold', px['brand'], (255, 255, 255, 255))
    tag = kit.text_img('极致的本地书籍阅读器', 'medium', px['tag'], (255, 236, 214, 245))
    fmt = kit.text_img('支持 TXT / EPUB / MOBI / AZW / AZW3', 'regular', px['fmt'],
                       (255, 240, 226, 200))
    bar_w, bar_h = px['bar_w'], px['bar_h']

    total = (chip.size[1] + 34 + brand.size[1] + 22 + bar_h + 26
             + tag.size[1] + 30 + fmt.size[1])
    y = (H - total) // 2

    layer = Image.new('RGBA', CANVAS, (0, 0, 0, 0))
    layer.alpha_composite(chip, (W // 2 - chip.size[0] // 2, y))
    y += chip.size[1] + 34
    layer.alpha_composite(brand, (W // 2 - brand.size[0] // 2, y))
    y += brand.size[1] + 22
    layer.alpha_composite(Image.new('RGBA', (bar_w, bar_h), tuple(scene['accent']) + (255,)),
                          (W // 2 - bar_w // 2, y))
    y += bar_h + 26
    layer.alpha_composite(tag, (W // 2 - tag.size[0] // 2, y))
    y += tag.size[1] + 30
    layer.alpha_composite(fmt, (W // 2 - fmt.size[0] // 2, y))
    return Image.alpha_composite(canvas, layer).convert('RGB')


def seg_video(clip, t0, t1, scene, stage, title=None, sub=None,
              fade_in=0.0, close_out=0.0, rise_in=0.0):
    dur = t1 - t0
    n = int(round(dur * FPS))
    stream = video_stream(clip, t0, t1)

    def frame(i):
        t = i / FPS
        try:
            screen = next(stream)
        except StopIteration:
            screen = None

        dy, alpha = 0.0, 1.0
        if rise_in > 0 and t < rise_in:
            p = kit.clamp01(t / rise_in)
            dy = kit.lerp(L['rise_dy'], 0, ease(p))
            alpha = p
        if close_out > 0 and t > dur - close_out:
            p = kit.clamp01((t - (dur - close_out)) / close_out)
            dy = L['close_dy'] * (p ** 2)
            alpha = 1.0 - p

        canvas = stage.base(alpha)
        if screen is not None:
            canvas = stage.put_phone(canvas, screen, dy=dy, alpha=alpha)
        if title:
            canvas = text_layer(canvas, title, sub, scene['accent'], t)
        if fade_in > 0 and t < fade_in:
            canvas = Image.blend(background(scene), canvas, t / fade_in)
        return canvas.convert('RGB')

    return frame, n


def seg_still(name, scene, stage, title, sub, dur=5.6):
    img = still_canvas(name).resize((SW, SH), Image.LANCZOS)
    n = int(round(dur * FPS))

    def frame(i):
        t = i / FPS
        canvas = stage.base()
        canvas = stage.put_phone(canvas, img)
        canvas = text_layer(canvas, title, sub, scene['accent'], t)
        return canvas.convert('RGB')

    return frame, n


def seg_strip(scene, stage, pages, dur=6.8, live=None, text_static=False):
    strip = Image.new('RGBA', (SW * len(pages), SH), (245, 242, 238, 255))
    for k, im in enumerate(pages):
        strip.alpha_composite(im.convert('RGBA'), (k * SW, 0))

    n = int(round(dur * FPS))
    t_start, move = 0.70, 0.90
    holds = [1.70, 0.60, 0.60]
    starts, t_acc = [], t_start
    for k in range(len(pages) - 1):
        starts.append(t_acc)
        t_acc += move + holds[k]

    live_idx = live_gen = None
    live_on, live_cur = 0.0, None
    if live:
        live_idx, clip, v0, v1, live_on, live_speed = live
        live_gen = video_stream(clip, v0, v1, live_speed)

    def frame(i):
        nonlocal live_cur
        t = i / FPS
        pos = 0.0
        for s in starts:
            pos += kit.ease_in_out_cubic(kit.clamp01((t - s) / move))
        off = min(strip.size[0] - SW, int(round(pos * SW)))

        win = strip.crop((off, 0, off + SW, SH))
        if live_gen is not None and t >= live_on:
            try:
                live_cur = next(live_gen)
            except StopIteration:
                pass
        if live_cur is not None:
            win = win.copy()
            win.paste(live_cur.convert('RGBA'), (live_idx * SW - off, 0))

        alpha = kit.clamp01(t / 0.7)
        canvas = stage.base(alpha)
        canvas = stage.put_phone(canvas, win, dy=kit.lerp(L['rise_dy'], 0, ease(alpha)),
                                 alpha=alpha)
        canvas = text_layer(canvas, '鸿蒙赋能', '沉浸光感，全新UI超美观！', scene['accent'],
                            t, static=text_static)
        return canvas.convert('RGB')

    return frame, n


def seg_burst(scene, stage, dur=3.4):
    import demo_transitions as FX

    dev_big = stage.compose(FX.theme_canvas(FX.THEME_T[0]).resize((SW, SH), Image.LANCZOS))
    pw, ph = stage.dev_size
    px, py = stage.pos

    cw = L['burst_card']
    gap = L['burst_gap']
    sprites = [FX.rounded_card(FX.theme_canvas(t), cw) for t in FX.THEME_T]
    ch = sprites[0].size[1]
    total_w = cw * 3 + gap * 2
    x0 = (CANVAS[0] - total_w) // 2
    xs = [x0 + k * (cw + gap) + cw // 2 for k in range(3)]
    row_y = L['burst_row_y']
    origin = (px + pw / 2, py + ph * 0.45)
    n = int(round(dur * FPS))

    def frame(i):
        t = i / FPS
        canvas = stage.base()

        p_out = kit.ease_in_out_cubic(kit.clamp01(kit.span(t, 0.75, 1.55)))
        sc = kit.lerp(1.0, 0.86, p_out)
        a_dev = kit.lerp(1.0, 0.0, p_out)
        if a_dev > 0.01:
            dev = dev_big.resize((max(2, int(pw * sc)), max(2, int(ph * sc))), Image.LANCZOS)
            dev = kit.set_alpha(dev, a_dev)
            canvas.paste(dev, (int(px + pw / 2 - dev.size[0] / 2),
                               int(py + ph / 2 - dev.size[1] / 2)), dev)

        for k, sp in enumerate(sprites):
            s0 = 0.60 + 0.13 * k
            p = kit.ease_out_cubic(kit.clamp01(kit.span(t, s0, s0 + 1.15)))
            if p <= 0:
                continue
            layer = FX.warp_onto(
                CANVAS, sp,
                kit.lerp(origin[0], xs[k], p), kit.lerp(origin[1], row_y, p),
                angle=kit.lerp(-24 + 8 * k, 0.0, p),
                persp=kit.lerp(0.26, 0.0, p),
                scale=kit.lerp(0.30, 1.0, p),
                alpha=kit.clamp01(p * 2.4))
            canvas = Image.alpha_composite(canvas, layer)

        canvas = text_layer(canvas, '更多预设', '自由调盘，万千色彩随你定！', scene['accent'], t)
        return canvas.convert('RGB')

    return frame, n


def seg_endcard(dur=7.2):
    """片尾：搜索栏逐字打出 → 鼠标点放大镜 → Q 弹（动画在 endcard.render_frame 里）。"""
    import endcard
    n = int(round(dur * FPS))

    def frame(i):
        return endcard.render_frame(i / FPS, CANVAS).convert('RGB')

    return frame, n


# ── WiFi 传书（两镜：手机授权码 / 电脑上传）────────────────────────────────

WIFI_PC_SRC = r'D:\Huawei Share\Screenshot\20261017_180147.mp4'
WIFI_PH_SRC = r'D:\Huawei Share\Huawei Share\SVID_20261017_180010_1.mp4'
WIFI_PC_CARD = (647, 248, 1277, 595)
WIFI_PH_IN, WIFI_PH_OUT = 1.90, 5.10      # 手机：传书弹窗升起 → 授权码 + IP
WIFI_PC_IN, WIFI_PC_OUT = 8.45, 13.45     # 电脑：文件已选(待传) → 已入架
# 源里 3.3–8.4s 是挑文件的过程（资源管理器 + 文件对话框，还拖过窗口大小），整段不要


def _wifi_geom():
    """按版式给出：窗口宽/位置、手机屏幕宽/位置、箭头方向。"""
    if MODE == 'tall':
        win_w, win_y, win_x = 980, 440, None
        sw2, ph_xy = 300, None
    else:
        win_w, win_y, win_x = 860, 500, 380
        sw2, ph_xy = 240, (1400, 520)
    return win_w, win_x, win_y, sw2, ph_xy


def _wifi_win_size(win_w):
    cw = win_w - 52
    ch = int(round((WIFI_PC_CARD[3] - WIFI_PC_CARD[1]) * cw / (WIFI_PC_CARD[2] - WIFI_PC_CARD[0])))
    return cw, ch, 62 + ch + 26 + 14


def _browser_window(scr, win_w):
    cw, ch, wh = _wifi_win_size(win_w)
    win = Image.new('RGBA', (win_w, wh), (0, 0, 0, 0))
    d = ImageDraw.Draw(win)
    d.rounded_rectangle((0, 0, win_w - 1, wh - 1), 22, fill=(255, 255, 255, 255))
    d.rounded_rectangle((0, 0, win_w - 1, 62), 22, fill=(242, 243, 247, 255))
    d.rectangle((0, 40, win_w - 1, 62), fill=(242, 243, 247, 255))
    for k, col in enumerate([(255, 95, 86), (255, 189, 46), (39, 201, 63)]):
        cx = 26 + k * 22
        d.ellipse((cx - 6, 25, cx + 6, 37), fill=col + (255,))
    px0, px1 = 106, win_w - 26
    d.rounded_rectangle((px0, 14, px1, 48), 17, fill=(255, 255, 255, 255))
    lcx = px0 + 26
    d.rounded_rectangle((lcx - 6, 29, lcx + 6, 39), 2, outline=(120, 126, 136, 255), width=2)
    d.arc((lcx - 6, 21, lcx + 6, 33), 180, 360, fill=(120, 126, 136, 255), width=2)
    url = kit.text_img('192.168.3.111:11232', 'regular', 22, (86, 92, 102, 255))
    win.alpha_composite(url, (px0 + 44, 31 - url.size[1] // 2))
    win.paste(scr.convert('RGBA'), (26, 62 + 8))
    return win


def _raw_stream(path, t0, t1, vf, size):
    cmd = ['ffmpeg', '-v', 'error', '-i', path,
           '-vf', f'trim=start={t0}:end={t1},setpts=PTS-STARTPTS,{vf},fps={FPS}',
           '-f', 'rawvideo', '-pix_fmt', 'rgb24', '-']
    p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    w, h = size
    n = w * h * 3
    try:
        while True:
            buf = p.stdout.read(n)
            if not buf or len(buf) < n:
                break
            yield Image.frombytes('RGB', (w, h), buf)
    finally:
        p.stdout.close()
        p.wait()


def seg_wifi(scene, dur_ph=3.2, dur_pc=5.0):
    win_w, win_x, win_y, sw2, ph_xy = _wifi_geom()
    cw, ch, wh = _wifi_win_size(win_w)
    if win_x is None:
        win_x = (CANVAS[0] - win_w) // 2
    steps = WIN_W_SCALE = 1.0

    # 手机镜头
    ph_size = (SW, SH)
    ph_vf = (f'crop=890:{CROP_H_890}:0:{CUT_890},'
             f'scale={ph_size[0]}:{ph_size[1]}:flags=lanczos')
    dev_size = mateframe.info(SW)['device']
    if MODE == 'tall':
        dev_pos = ((CANVAS[0] - dev_size[0]) // 2, CANVAS[1] - 70 - dev_size[1])
    else:
        # 横版必须和其它段一致：机身靠右，否则会压到左边的大标题上
        dev_pos = (CANVAS[0] - L['phone_right'] - dev_size[0], (CANVAS[1] - dev_size[1]) // 2)
    sh1 = Image.new('RGBA', CANVAS, (0, 0, 0, 0))
    ImageDraw.Draw(sh1).rounded_rectangle(
        (dev_pos[0] + 8, dev_pos[1] + 24, dev_pos[0] + dev_size[0] - 8, dev_pos[1] + dev_size[1] + 24),
        int(dev_size[0] * 0.12), fill=(0, 0, 0, 165))
    sh1 = sh1.filter(ImageFilter.GaussianBlur(int(CANVAS[0] * 0.03)))

    # 电脑镜头
    pc_size = (cw, ch)
    pc_vf = (f'crop={WIFI_PC_CARD[2] - WIFI_PC_CARD[0]}:{WIFI_PC_CARD[3] - WIFI_PC_CARD[1]}:'
             f'{WIFI_PC_CARD[0]}:{WIFI_PC_CARD[1]},'
             f'scale={cw}:{ch}:flags=lanczos')
    sh2 = Image.new('RGBA', CANVAS, (0, 0, 0, 0))
    ImageDraw.Draw(sh2).rounded_rectangle(
        (win_x + 10, win_y + 26, win_x + win_w - 10, win_y + wh + 26), 24, fill=(0, 0, 0, 190))
    sh2 = sh2.filter(ImageFilter.GaussianBlur(34))

    # 小手机（书架）
    sw_small = mateframe.info(sw2)['screen']
    shelf = still_canvas('02_书架_喵阅_完整版.jpg').resize(sw_small, Image.LANCZOS)
    ph_dev = mateframe.compose(shelf, sw2)
    if ph_xy is None:
        ph_pos = ((CANVAS[0] - ph_dev.size[0]) // 2, win_y + wh + 96)
    else:
        ph_pos = ph_xy
    sh3 = Image.new('RGBA', CANVAS, (0, 0, 0, 0))
    ImageDraw.Draw(sh3).rounded_rectangle(
        (ph_pos[0] + 6, ph_pos[1] + 18,
         ph_pos[0] + ph_dev.size[0] - 6, ph_pos[1] + ph_dev.size[1] + 18),
        int(ph_dev.size[0] * 0.12), fill=(0, 0, 0, 150))
    sh3 = sh3.filter(ImageFilter.GaussianBlur(26))

    gen1 = _raw_stream(WIFI_PH_SRC, WIFI_PH_IN, WIFI_PH_OUT, ph_vf, ph_size)
    gen2 = _raw_stream(WIFI_PC_SRC, WIFI_PC_IN, WIFI_PC_OUT, pc_vf, pc_size)
    n1, n2 = int(round(dur_ph * FPS)), int(round(dur_pc * FPS))
    keep1, keep2 = {'f': None}, {'f': None}

    def frame(i):
        if i < n1:                                    # ① 手机
            t = i / FPS
            try:
                scr = next(gen1)
            except StopIteration:
                scr = keep1['f']
            if scr is not None:
                keep1['f'] = scr
            a = kit.clamp01(t / 0.5)
            base = Image.alpha_composite(background(scene), kit.set_alpha(sh1, a))
            if scr is not None:
                dev = mateframe.compose(scr, SW)
                if a < 1:
                    dev = kit.set_alpha(dev, a)
                base.paste(dev, (dev_pos[0], dev_pos[1] + int(kit.lerp(60, 0, ease(a)))), dev)
            return text_layer(base, 'WiFi 传书', '同一个 WiFi，电脑传书到手机',
                              scene['accent'], t).convert('RGB')

        t = (i - n1) / FPS                            # ② 电脑
        try:
            scr = next(gen2)
        except StopIteration:
            scr = keep2['f']
        if scr is not None:
            keep2['f'] = scr
        base = Image.alpha_composite(background(scene), sh2)
        if scr is not None:
            base.paste(_browser_window(scr, win_w), (win_x, win_y))
        base = Image.alpha_composite(base, sh3)
        base.paste(ph_dev, ph_pos, ph_dev)

        g = kit.clamp01(kit.span(t, 0.10, 0.45))
        if g > 0:
            al = Image.new('RGBA', CANVAS, (0, 0, 0, 0))
            ad = ImageDraw.Draw(al)
            if MODE == 'tall':
                cx = CANVAS[0] // 2
                ay = win_y + wh + 8
                ad.line((cx, ay + 6, cx, ay + 48), fill=tuple(scene['accent']) + (255,), width=6)
                ad.line((cx - 15, ay + 34, cx, ay + 52), fill=tuple(scene['accent']) + (255,), width=6)
                ad.line((cx + 15, ay + 34, cx, ay + 52), fill=tuple(scene['accent']) + (255,), width=6)
            else:
                ay = win_y + wh // 2
                ax = win_x + win_w + 14
                ad.line((ax, ay, ax + 96, ay), fill=tuple(scene['accent']) + (255,), width=6)
                ad.line((ax + 74, ay - 15, ax + 98, ay), fill=tuple(scene['accent']) + (255,), width=6)
                ad.line((ax + 74, ay + 15, ax + 98, ay), fill=tuple(scene['accent']) + (255,), width=6)
            base = Image.alpha_composite(base, kit.set_alpha(al, g))
        # 第二镜标题给终态，避免切镜时标题重新入场
        return text_layer(base, 'WiFi 传书', '同一个 WiFi，电脑传书到手机',
                          scene['accent'], t, static=True).convert('RGB')

    return frame, n1 + n2


# ── 组装 ────────────────────────────────────────────────────────────────────

def nf(dur):
    return int(round(dur * FPS))


def build_film():
    st_ui = Stage(SCN.SCENES[0])
    st_theme = Stage(SCN.SCENES[3])
    st_color = Stage(SCN.SCENES[3])
    st_mat = Stage(SCN.SCENES[1])
    st_font = Stage(SCN.SCENES[2])
    st_tts = Stage(SCN.SCENES[4])
    st_tts2 = Stage(SCN.SCENES[4])
    st_priv = Stage(SCN.SCENES[6])

    pages = [
        still_canvas('02_书架_喵阅_完整版.jpg').resize((SW, SH), Image.LANCZOS),
        clip_frame(os.path.join(CLIP, 'SVID_20261017_125036_1.mp4'), 3.0),   # 底部工具栏
        clip_frame(os.path.join(CLIP, 'SVID_20261017_125216_1.mp4'), 5.4),   # 阅读设置
        clip_frame(os.path.join(CLIP, 'SVID_20261017_125112_1.mp4'), 6.6),   # 朗读面板
    ]

    segs = []
    segs.append(('片头', lambda i: seg_intro(), nf(1.0)))

    f, n = seg_video(os.path.join(EDITED, '黄昏书店_净版_30fps.mp4'), 0.0, 5.2,
                     SCN.SCENES[0], st_ui, '鸿蒙赋能', '沉浸光感，全新UI超美观！',
                     fade_in=0.3, close_out=1.0)
    segs.append(('01 一镜到底', f, n))

    f, n = seg_strip(SCN.SCENES[0], st_ui, pages, dur=6.8, text_static=True,
                     live=(1, os.path.join(CLIP, 'SVID_20261017_125036_1.mp4'),
                           0.90, 1.90, 1.60, 0.4))
    segs.append(('02 框内横滑', f, n))

    f, n = seg_wifi(SCN.SCENES[0])
    segs.append(('03 WiFi传书', f, n))

    f, n = seg_burst(SCN.SCENES[3], st_theme, dur=3.4)
    segs.append(('03 一裂多卡', f, n))

    f, n = seg_video(os.path.join(CLIP, 'SVID_20261017_125326_1.mp4'), 9.0, 12.0,
                     SCN.SCENES[3], st_color, '自定义调色', '取色盘 + RGB，调到满意为止',
                     rise_in=0.6)
    segs.append(('04 调色盘', f, n))

    f, n = seg_video(os.path.join(CLIP, 'SVID_20261017_125216_1.mp4'), 6.4, 12.4,
                     SCN.SCENES[1], st_mat, '超多材质', '个人定制，自由畅想随心配！')
    segs.append(('05 材质', f, n))

    f, n = seg_still('04_font.jpg', SCN.SCENES[2], st_font,
                     '自定字体', '多渠导入，怎么舒适怎么来！', dur=5.6)
    segs.append(('06 字体', f, n))

    f, n = seg_video(os.path.join(CLIP, 'SVID_20261017_125112_1.mp4'), 4.0, 11.6,
                     SCN.SCENES[4], st_tts, '本地TTS', '语音读书，畅听书海爽翻天！')
    segs.append(('07 本地TTS', f, n))

    # 实测 125437：5.6~8.8s 页面固定，服务商依次
    #   MiniMax → 阿里通义(Qwen3-TTS) → 火山豆包(豆包语音2.0) → 小米 MiMo
    f, n = seg_video(os.path.join(CLIP, 'SVID_20261017_125437_1.mp4'), 5.6, 8.8,
                     SCN.SCENES[4], st_tts2, 'AI听书', '多家大模型，任你切换')
    segs.append(('08 AI听书', f, n))

    # 副标题与海报对齐（make_posters.py 的 10_隐私防窥）——两套物料不能两种说法；
    # 原来的副标题含「单机」二字，按要求已不再使用。
    f, n = seg_video(os.path.join(CLIP, 'SVID_20261017_125133_1.mp4'), 5.2, 11.6,
                     SCN.SCENES[6], st_priv, '隐私防窥', '绝密保护，安全阅读最在行！')
    segs.append(('09 防窥', f, n))

    f, n = seg_endcard(7.2)
    segs.append(('10 片尾', f, n))
    return segs


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--mode', default='tall', choices=['tall', 'wide'])
    args = ap.parse_args()
    configure(args.mode)

    segs = build_film()
    total = sum(n for _, _, n in segs)
    tag = '竖版' if MODE == 'tall' else '横版'
    print(f'{tag} {CANVAS[0]}x{CANVAS[1]}  总帧数 {total} = {total / FPS:.1f}s  共 {len(segs)} 段')

    os.makedirs(OUT, exist_ok=True)
    out = os.path.join(OUT, f'宣发片_v2_{tag}_{CANVAS[0]}x{CANVAS[1]}.mp4')
    cmd = ['ffmpeg', '-y', '-v', 'error',
           '-f', 'rawvideo', '-pix_fmt', 'rgb24', '-s', f'{CANVAS[0]}x{CANVAS[1]}',
           '-r', str(FPS), '-i', '-', '-vf', 'format=yuv420p',
           '-c:v', 'libx264', '-preset', 'slow', '-crf', '18',
           '-movflags', '+faststart', out]
    p = subprocess.Popen(cmd, stdin=subprocess.PIPE)
    done = 0
    for name, fn, n in segs:
        t0 = done / FPS
        for i in range(n):
            p.stdin.write(fn(i).tobytes())
            done += 1
        print(f'  [段] {name:<10} {n:>4} 帧  {t0:5.2f}s → {done / FPS:5.2f}s', flush=True)
    p.stdin.close()
    p.wait()
    if p.returncode != 0:
        raise SystemExit('ffmpeg 失败')
    print(f'[done] {out}  {os.path.getsize(out) // 1024} KB')


if __name__ == '__main__':
    main()
