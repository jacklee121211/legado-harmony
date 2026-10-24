# -*- coding: utf-8 -*-
"""promo/video/sample15.py —— 15 秒样片（验证 motion.py 的「灵动」观感）

目的：**先花 20 分钟确认方向，再决定要不要铺满 60 秒。**
v3 的教训是"做了 1 小时才发现方向不对"，所以这一版只做 3 个镜头。

三个镜头各验证一种运动能力：
  01  截图 + 3D 姿态呼吸 + 推镜 + 背景视差      ← 主体（v3 里 71.8% 静止的元凶）
  02  真录屏 + 同样的姿态运动                    ← 证明"真动"也能动
  03  截图 + 更强的入场（俯冲 + 回弹）           ← 验证"有劲"的转场

用法
----
    python promo/video/sample15.py                    # 出片
    python promo/video/sample15.py --still 2.0        # 只出 2.0s 那一帧
    python promo/video/sample15.py --sheet            # 出 6 帧拼图（看运动轨迹）
"""

import argparse
import os
import subprocess
import sys
import time

import numpy as np
from PIL import Image, ImageDraw

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

import kit
import motion
import scenes as SCN

PROJECT = os.path.dirname(os.path.dirname(HERE))
MAT = os.path.join(PROJECT, 'docs', '宣发物料', '00_原始素材', '截图')
CLIP = os.path.join(PROJECT, 'docs', '宣发物料', '00_原始素材', '录屏')
OUT = os.path.join(PROJECT, 'docs', '宣发物料', '02_成片', 'v4_样片')

FPS = 30
CANVAS = (1080, 1920)
SW = 600
SYS = 0.0449          # 系统信息栏占屏高比例（真机实测，与 film.py 同源）
ASPECT = 1320 / 2720  # 裁掉系统栏后的 App 画布比例

# 890 宽录屏 → 裁掉系统栏 → 目标比例
CUT_890 = 86
CROP_H_890 = int(round(890 / ASPECT))


# ── 素材 ────────────────────────────────────────────────────────────────────

def app_canvas(img):
    """裁掉系统信息栏，再居中裁到 App 画布比例。"""
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


FALLBACK = os.path.join(PROJECT, 'promo', 'src')


def resolve(name):
    """素材查找：先新物料目录，再回落 promo/src（与 render.py/film.py 同序）。"""
    for d in (MAT, FALLBACK):
        p = os.path.join(d, name)
        if os.path.exists(p):
            return p
    raise SystemExit(f'找不到素材 {name}\n  查过：{MAT}\n  查过：{FALLBACK}')


def still(name):
    return app_canvas(Image.open(resolve(name)).convert('RGB'))


def video_stream(clip, t0, t1, sw, sh, speed=1.0):
    """按目标尺寸解码录屏片段，逐帧 yield。"""
    vf = (f'trim=start={t0}:end={t1},setpts=(PTS-STARTPTS)/{speed},'
          f'crop=890:{CROP_H_890}:0:{CUT_890},'
          f'scale={sw}:{sh}:flags=lanczos,fps={FPS}')
    cmd = ['ffmpeg', '-v', 'error', '-i', clip, '-vf', vf,
           '-f', 'rawvideo', '-pix_fmt', 'rgb24', '-']
    p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    n = sw * sh * 3
    try:
        while True:
            buf = p.stdout.read(n)
            if not buf or len(buf) < n:
                break
            yield Image.frombytes('RGB', (sw, sh), buf)
    finally:
        p.stdout.close()
        p.wait()


# ── 文案层（跟着姿态一起"轻推"，不是死贴）──────────────────────────────────

def text_layer(W, H, title, sub, accent, t, t0=0.15, drift=(0, 0)):
    """标题逐字上浮 + 强调条长出 + 副标淡入。

    `drift` = 文案整体跟随机身的**反方向**微位移（幅度约为机身的 0.3），
    这样文字与机身有相对位移 ⇒ 层次感；完全同速会像"贴在同一张纸上"。
    """
    mx, title_px, sub_px, chip_px = 96, 100, 42, 28
    chip = kit.chip_img(f'{SCN.BRAND} · {SCN.BRAND_SUB}', 'medium', chip_px, (255, 255, 255, 235))
    sub_img = kit.text_img(sub, 'medium', sub_px, (255, 255, 255, 232))
    f = kit.font('bold', title_px)
    probe = ImageDraw.Draw(Image.new('RGBA', (8, 8)))

    layer = Image.new('RGBA', (W, H), (0, 0, 0, 0))
    dx, dy = int(round(drift[0])), int(round(drift[1]))

    a = kit.clamp01(kit.span(t, t0, t0 + 0.45))
    if a > 0:
        e = kit.ease_out_cubic(a)
        layer.alpha_composite(kit.set_alpha(chip, a), (mx + dx, 116 + dy + int(round(14 * (1 - e)))))

    y = 116 + chip.size[1] + 26
    x = mx
    for i, ch in enumerate(title):
        s0 = t0 + 0.18 + 0.10 * i
        a = kit.clamp01(kit.span(t, s0, s0 + 0.55))
        if a > 0:
            e = kit.ease_out_cubic(a)
            img = kit.set_alpha(kit.text_img(ch, 'bold', title_px, (255, 255, 255, 255)), a)
            layer.alpha_composite(img, (int(x) + dx, y + dy + int(round(26 * (1 - e)))))
        x += probe.textlength(ch, font=f)

    bar_y = 116 + chip.size[1] + 26 + int(round(title_px * 1.18)) + 34
    g = kit.ease_out_quint(kit.clamp01(kit.span(t, t0 + 0.55, t0 + 1.00)))
    if g > 0:
        bw = max(2, int(round(112 * g)))
        layer.alpha_composite(Image.new('RGBA', (bw, 10), tuple(accent) + (255,)),
                              (mx + dx, bar_y + dy))

    a = kit.clamp01(kit.span(t, t0 + 0.66, t0 + 1.10))
    if a > 0:
        e = kit.ease_out_cubic(a)
        layer.alpha_composite(kit.set_alpha(sub_img, a),
                              (mx + dx, bar_y + 40 + dy + int(round(20 * (1 - e)))))
    return layer


# ── 分镜 ────────────────────────────────────────────────────────────────────

SHOTS = [
    dict(id='s1_shelf', dur=5.0, kind='still',
         src='02_书架_喵阅_新首页_20261021.jpg', seed=11,
         title='全新界面', sub='沉浸光感，一本书就是一个世界',
         scene=0, intro='dive'),
    dict(id='s2_material', dur=5.0, kind='video',
         clip='SVID_20261017_125216_1.mp4', t0=6.4, t1=11.4, seed=23,
         title='超多材质', sub='个人定制，自由畅想随心配！',
         scene=1, intro='rise'),
    dict(id='s3_tts', dur=5.0, kind='still',
         src='07_ai_tts.jpg', seed=37,
         title='AI听书', sub='多音色朗读，边看边听真省眼！',
         scene=4, intro='dive'),
]


def build(shot, still_t=None):
    scene = SCN.SCENES[shot['scene']]
    st = motion.Stage3D(scene, CANVAS, SW)
    m = motion.Motion(seed=shot['seed'])
    dur = shot['dur']

    if shot['kind'] == 'video':
        gen = video_stream(os.path.join(CLIP, shot['clip']), shot['t0'], shot['t1'],
                           st.sw, st.sh)
        frames = list(gen)
        getter = lambda i: frames[min(i, len(frames) - 1)]
    else:
        img = still(shot['src']).resize((st.sw, st.sh), Image.LANCZOS)
        getter = lambda i: img

    def frame(i):
        t = i / FPS
        pose = m.pose(t, dur)

        # 入场：dive = 从远处俯冲（z 小 + 上移），rise = 从下方升起
        e = motion.entry_scale(t, 0.85)
        if shot['intro'] == 'dive':
            pose['z'] *= kit.lerp(0.90, 1.0, e)
            pose['dy'] += kit.lerp(-70, 0, e)
            pose['pitch'] += kit.lerp(6.0, 0.0, e)
        else:
            pose['dy'] += kit.lerp(190, 0, e)
            pose['z'] *= kit.lerp(0.96, 1.0, e)

        canvas = st.background(pose)
        sh = st.contact_shadow(pose, strength=e)
        if sh is not None:
            canvas = Image.alpha_composite(canvas, sh)
        canvas = st.render(canvas, getter(i), pose)

        # 文案跟随：反方向 0.3，产生相对位移
        drift = (-pose['dx'] * 0.30, -pose['dy'] * 0.30)
        canvas = Image.alpha_composite(
            canvas, text_layer(CANVAS[0], CANVAS[1], shot['title'], shot['sub'],
                               scene['accent'], t, drift=drift))

        out = canvas.convert('RGB')

        # 首尾微黑场（整片拼接时用转场，这里只做段内收尾）
        fade = 1.0
        fade *= kit.clamp01(kit.span(t, 0.0, 0.20))
        fade *= 1.0 - kit.clamp01(kit.span(t, dur - 0.28, dur))
        if fade < 0.999:
            out = Image.blend(Image.new('RGB', CANVAS, (0, 0, 0)), out, fade)
        return out

    n = int(round(dur * FPS))
    return frame, n


def encode(frames, out_path):
    W, H = CANVAS
    os.makedirs(os.path.dirname(out_path), exist_ok=True)
    cmd = ['ffmpeg', '-y', '-v', 'error',
           '-f', 'rawvideo', '-pix_fmt', 'rgb24', '-s', f'{W}x{H}', '-r', str(FPS), '-i', '-',
           '-vf', 'format=yuv420p', '-c:v', 'libx264', '-preset', 'slow', '-crf', '17',
           '-movflags', '+faststart', out_path]
    p = subprocess.Popen(cmd, stdin=subprocess.PIPE)
    n = 0
    try:
        for im in frames:
            p.stdin.write(im.tobytes())
            n += 1
            if n % 30 == 0:
                print(f'  frame {n}', flush=True)
    finally:
        p.stdin.close()
        p.wait()
    if p.returncode != 0:
        raise SystemExit(f'ffmpeg 失败 code={p.returncode}')
    return n


def main():
    try:
        sys.stdout.reconfigure(encoding='utf-8', errors='replace')
    except Exception:
        pass
    ap = argparse.ArgumentParser()
    ap.add_argument('--still', type=float, default=None)
    ap.add_argument('--sheet', action='store_true')
    ap.add_argument('--shot', default=None, help='只跑某一镜，如 s1_shelf')
    args = ap.parse_args()

    shots = [s for s in SHOTS if args.shot is None or s['id'] == args.shot]
    os.makedirs(OUT, exist_ok=True)

    if args.still is not None:
        for s in shots:
            frame, n = build(s)
            idx = min(int(round(args.still * FPS)), n - 1)
            t0 = time.time()
            im = frame(idx)
            p = os.path.join(OUT, f'still_{s["id"]}_{args.still:.1f}s.png')
            im.save(p)
            print(f'[still] {p}  {im.size[0]}x{im.size[1]}  {time.time() - t0:.2f}s')
        return

    if args.sheet:
        # 每镜抽 6 帧拼一张，直接看运动轨迹
        for s in shots:
            frame, n = build(s)
            idxs = [int(round(k * (n - 1) / 5)) for k in range(6)]
            ims = [frame(i).resize((270, 480), Image.LANCZOS) for i in idxs]
            sheet = Image.new('RGB', (270 * 6, 480), (20, 20, 20))
            for k, im in enumerate(ims):
                sheet.paste(im, (270 * k, 0))
            p = os.path.join(OUT, f'sheet_{s["id"]}.png')
            sheet.save(p)
            print(f'[sheet] {p}  帧号={idxs}')
        return

    # 全片：三镜拼接
    all_frames = []
    for s in shots:
        frame, n = build(s)
        all_frames.extend(frame(i) for i in range(n))
        print(f'[built] {s["id"]}  {n} frames')

    out = os.path.join(OUT, '样片_灵动版_15s_1080x1920.mp4')
    t0 = time.time()
    got = encode(iter(all_frames), out)
    print(f'[done] {got} frames  {time.time() - t0:.1f}s  {out}')
    print(f'       体积 {os.path.getsize(out) // 1024} KB')


if __name__ == '__main__':
    sys.exit(main())
