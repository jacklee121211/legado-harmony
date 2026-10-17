# -*- coding: utf-8 -*-
"""promo/video/wifi_clip.py —— WiFi 传书 片花（竖版 1080x1920）

两镜：
    ① 手机：我的 → 传书 → 弹窗升起 → 授权码 243138 + IP
    ② 电脑：浏览器窗口「使用说明.txt 待传」→ 点开始上传 → **已入架**，下方手机书架

为什么砍中间：电脑端 3.3-8.4s 是挑文件的过程（资源管理器 + 文件对话框，期间还拖过
窗口大小），跟内容无关且不连续 —— 整段丢弃，用「文件已选好」直接接上。

用法：python promo/video/wifi_clip.py
"""

import os
import subprocess
import sys

from PIL import Image, ImageDraw, ImageFilter

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import kit
import mateframe

HERE = os.path.dirname(os.path.abspath(__file__))
PROJECT = os.path.dirname(os.path.dirname(HERE))
OUT = os.path.join(PROJECT, 'docs', '宣发物料', '02_成片')
MAT = os.path.join(PROJECT, 'docs', '宣发物料', '00_原始素材', '截图')

PC_SRC = r'D:\Huawei Share\Screenshot\20261017_180147.mp4'
PH_SRC = r'D:\Huawei Share\Huawei Share\SVID_20261017_180010_1.mp4'

PC_CARD = (647, 248, 1277, 595)
CUT_890 = 86
SYS_ASPECT = 1320 / 2720

CANVAS = (1080, 1920)
FPS = 30
SW = 600
SW2 = 300

C1, C2, ACCENT = (52, 20, 6), (168, 78, 18), (255, 198, 120)

PH_IN, PH_OUT = 1.90, 5.10
PC_IN, PC_OUT = 8.45, 13.45
PH_DUR = PH_OUT - PH_IN
PC_DUR = PC_OUT - PC_IN

PH_SIZE = (SW, mateframe.info(SW)['screen'][1])
PW, PHH = PH_SIZE
PH_VF = f"crop=890:{int(round(890 / SYS_ASPECT))}:0:{CUT_890},scale={PW}:{PHH}:flags=lanczos"

CARD_W = PC_CARD[2] - PC_CARD[0]
CARD_H = PC_CARD[3] - PC_CARD[1]
WIN_W = 980
PAD = 26
CONTENT_W = WIN_W - PAD * 2
CARD_S = CONTENT_W / CARD_W
CHROME_H = 62
PC_SIZE = (CONTENT_W, int(round(CARD_H * CARD_S)))
WIN_H = CHROME_H + PC_SIZE[1] + PAD + 14
PC_VF = f"crop={CARD_W}:{CARD_H}:{PC_CARD[0]}:{PC_CARD[1]},scale={PC_SIZE[0]}:{PC_SIZE[1]}:flags=lanczos"


def video_stream(path, t0, t1, vf, size):
    """按给定 vf 抽流。size 必须和 vf 的 scale 目标一致，否则帧会错切。"""
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


def background():
    return kit.make_background(CANVAS, C1, C2, ACCENT, blur_scale=CANVAS[0] / 1080.0).convert('RGBA')


def title_layer(canvas, t, sub='同一个 WiFi，电脑传书到手机'):
    chip = kit.chip_img('喵阅 · HarmonyOS 阅读器', 'medium', 28, (255, 255, 255, 235))
    layer = Image.new('RGBA', CANVAS, (0, 0, 0, 0))
    a = kit.clamp01(kit.span(t, 0.05, 0.50))
    if a > 0:
        layer.alpha_composite(kit.set_alpha(chip, a), (96, 120))

    y = 120 + chip.size[1] + 26
    x = 96
    f = kit.font('bold', 96)
    probe = ImageDraw.Draw(Image.new('RGBA', (8, 8)))
    for i, ch in enumerate('WiFi 传书'):
        aa = kit.clamp01(kit.span(t, 0.15 + 0.06 * i, 0.15 + 0.06 * i + 0.5))
        if aa > 0:
            img = kit.set_alpha(kit.text_img(ch, 'bold', 96, (255, 255, 255, 255)), aa)
            e = kit.ease_out_cubic(aa)
            layer.alpha_composite(img, (int(x), y + int(round(24 * (1 - e)))))
        x += probe.textlength(ch, font=f)

    bar_y = y + 118
    g = kit.ease_out_quint(kit.clamp01(kit.span(t, 0.55, 1.00)))
    if g > 0:
        bw = max(2, int(round(112 * g)))
        layer.alpha_composite(Image.new('RGBA', (bw, 10), ACCENT + (255,)), (96, bar_y))
    a2 = kit.clamp01(kit.span(t, 0.66, 1.10))
    if a2 > 0:
        sub_img = kit.text_img(sub, 'medium', 42, (255, 255, 255, 232))
        layer.alpha_composite(kit.set_alpha(sub_img, a2), (96, bar_y + 40))
    return Image.alpha_composite(canvas, layer)


def app_canvas(img):
    cut = int(round(img.size[1] * 0.0449))
    im = img.crop((0, cut, img.size[0], img.size[1]))
    w, h = im.size
    if w / h > SYS_ASPECT:
        nw = int(round(h * SYS_ASPECT))
        x = (w - nw) // 2
        return im.crop((x, 0, x + nw, h))
    nh = int(round(w / SYS_ASPECT))
    y = (h - nh) // 2
    return im.crop((0, y, w, y + nh))


def shelf_scr():
    im = Image.open(os.path.join(MAT, '02_书架_喵阅_完整版.jpg')).convert('RGB')
    return app_canvas(im).resize(mateframe.info(SW2)['screen'], Image.LANCZOS)


def soft_shadow(box, radius, blur, alpha):
    sh = Image.new('RGBA', CANVAS, (0, 0, 0, 0))
    ImageDraw.Draw(sh).rounded_rectangle(box, radius, fill=(0, 0, 0, alpha))
    return sh.filter(ImageFilter.GaussianBlur(blur))


def seg_phone():
    n = int(round(PH_DUR * FPS))
    gen = video_stream(PH_SRC, PH_IN, PH_OUT, PH_VF, PH_SIZE)
    dev_size = mateframe.info(SW)['device']
    pos = ((CANVAS[0] - dev_size[0]) // 2, CANVAS[1] - 70 - dev_size[1])
    shadow = soft_shadow((pos[0] + 8, pos[1] + 24, pos[0] + dev_size[0] - 8, pos[1] + dev_size[1] + 24),
                         int(dev_size[0] * 0.12), int(CANVAS[0] * 0.03), 165)

    last = {'f': None}

    def frame(i):
        t = i / FPS
        try:
            scr = next(gen)
        except StopIteration:
            scr = last['f']          # 流比段短时**保持最后一帧**，否则会出现黑屏空帧
        if scr is not None:
            last['f'] = scr
        a = kit.clamp01(t / 0.5)
        base = Image.alpha_composite(background(), kit.set_alpha(shadow, a))
        if scr is not None:
            dev = mateframe.compose(scr, SW)
            if a < 1:
                dev = kit.set_alpha(dev, a)
            base.paste(dev, (pos[0], pos[1] + int(kit.lerp(60, 0, kit.ease_out_cubic(a)))), dev)
        return title_layer(base, t).convert('RGB')

    return frame, n


def browser_window(scr):
    win = Image.new('RGBA', (WIN_W, WIN_H), (0, 0, 0, 0))
    d = ImageDraw.Draw(win)
    d.rounded_rectangle((0, 0, WIN_W - 1, WIN_H - 1), 22, fill=(255, 255, 255, 255))
    d.rounded_rectangle((0, 0, WIN_W - 1, CHROME_H), 22, fill=(242, 243, 247, 255))
    d.rectangle((0, CHROME_H - 22, WIN_W - 1, CHROME_H), fill=(242, 243, 247, 255))
    for k, col in enumerate([(255, 95, 86), (255, 189, 46), (39, 201, 63)]):
        cx = 26 + k * 22
        d.ellipse((cx - 6, CHROME_H // 2 - 6, cx + 6, CHROME_H // 2 + 6), fill=col + (255,))

    px0, px1 = 106, WIN_W - 26
    d.rounded_rectangle((px0, 14, px1, CHROME_H - 14), 17, fill=(255, 255, 255, 255))
    lcx, lcy = px0 + 26, CHROME_H // 2
    d.rounded_rectangle((lcx - 6, lcy - 2, lcx + 6, lcy + 8), 2,
                        outline=(120, 126, 136, 255), width=2)
    d.arc((lcx - 6, lcy - 10, lcx + 6, lcy + 2), 180, 360, fill=(120, 126, 136, 255), width=2)
    url = kit.text_img('192.168.3.111:11232', 'regular', 22, (86, 92, 102, 255))
    win.alpha_composite(url, (px0 + 44, (CHROME_H - url.size[1]) // 2))

    win.paste(scr.convert('RGBA'), (PAD, CHROME_H + 8))
    return win


def seg_pc():
    """电脑镜：上方浏览器窗口（待传 -> 已入架），下方手机书架。

    不做淡入，直接硬切 —— 第一版做了 0.5s 淡入，结果切过来第一帧是空画面，闪一下。
    """
    n = int(round(PC_DUR * FPS))
    gen = video_stream(PC_SRC, PC_IN, PC_OUT, PC_VF, PC_SIZE)
    win_x = (CANVAS[0] - WIN_W) // 2
    win_y = 440

    shadow = soft_shadow((win_x + 10, win_y + 26, win_x + WIN_W - 10, win_y + WIN_H + 26),
                         24, 34, 190)

    ph_dev = mateframe.compose(shelf_scr(), SW2)
    ph_pos = ((CANVAS[0] - ph_dev.size[0]) // 2, win_y + WIN_H + 96)
    ph_sh = soft_shadow((ph_pos[0] + 6, ph_pos[1] + 18,
                         ph_pos[0] + ph_dev.size[0] - 6, ph_pos[1] + ph_dev.size[1] + 18),
                        int(ph_dev.size[0] * 0.12), 26, 150)

    arrow = Image.new('RGBA', (CANVAS[0], 80), (0, 0, 0, 0))
    ad = ImageDraw.Draw(arrow)
    cx = CANVAS[0] // 2
    ay = win_y + WIN_H + 8
    ad.line((cx, 6, cx, 48), fill=ACCENT + (255,), width=6)
    ad.line((cx - 15, 34, cx, 52), fill=ACCENT + (255,), width=6)
    ad.line((cx + 15, 34, cx, 52), fill=ACCENT + (255,), width=6)

    last = {'f': None}

    def frame(i):
        t = i / FPS
        try:
            scr = next(gen)
        except StopIteration:
            scr = last['f']
        if scr is not None:
            last['f'] = scr
        base = Image.alpha_composite(background(), shadow)
        if scr is not None:
            base.paste(browser_window(scr), (win_x, win_y))
        base = Image.alpha_composite(base, ph_sh)
        base.paste(ph_dev, ph_pos, ph_dev)
        g = kit.clamp01(kit.span(t, 0.10, 0.45))
        if g > 0:
            al = Image.new('RGBA', CANVAS, (0, 0, 0, 0))
            al.alpha_composite(kit.set_alpha(arrow, g), (0, ay))
            base = Image.alpha_composite(base, al)
        # 第二镜标题直接给终态：否则切镜时标题会再入场一次，很跳
        return title_layer(base, 99.0).convert('RGB')

    return frame, n


def _paste_arrow(base, arrow, y, g):
    return Image.alpha_composite(base, kit.set_alpha(arrow, g)) if False else base


def main():
    try:
        sys.stdout.reconfigure(encoding='utf-8')
    except Exception:
        pass
    print(f'手机镜 {PH_DUR:.2f}s | PC 镜 {PC_DUR:.2f}s | 合计 {PH_DUR + PC_DUR:.2f}s')
    segs = [('手机', seg_phone()), ('电脑', seg_pc())]
    total = sum(n for _, (_, n) in segs)
    out = os.path.join(OUT, '片花_WiFi传书_1080x1920.mp4')
    cmd = ['ffmpeg', '-y', '-v', 'error',
           '-f', 'rawvideo', '-pix_fmt', 'rgb24', '-s', f'{CANVAS[0]}x{CANVAS[1]}',
           '-r', str(FPS), '-i', '-', '-vf', 'format=yuv420p',
           '-c:v', 'libx264', '-preset', 'slow', '-crf', '18',
           '-movflags', '+faststart', out]
    p = subprocess.Popen(cmd, stdin=subprocess.PIPE)
    done = 0
    for name, (fn, n) in segs:
        for i in range(n):
            p.stdin.write(fn(i).tobytes())
            done += 1
        print(f'  [段] {name}  {n} 帧  -> {done / FPS:.2f}s', flush=True)
    p.stdin.close()
    p.wait()
    if p.returncode != 0:
        raise SystemExit('ffmpeg failed')
    print(f'[done] {out}  {os.path.getsize(out) // 1024} KB  {total / FPS:.2f}s')


if __name__ == '__main__':
    main()
