# -*- coding: utf-8 -*-
"""promo/video/sample15b.py —— 15 秒样片 v2：机身静止 + 文字动效 + AI 配音

对应用户 2026-10-25 的明确要求：
    「手机不需要动，文字动就行了」+ 「人家都有 ai 的语音解说」

与 v1（`sample15.py`）的区别
---------------------------
| | v1 灵动版 | v2 本版 |
|---|---|---|
| 机身 | 3D 姿态持续运动 | **完全静止**（用户要求） |
| 文字 | 简单淡入 | **逐字入场 + 呼吸 + 擦除 + 强调条** |
| 声音 | 无 | **AI 配音（晓晓）** |
| 镜头时长 | 硬编码 5s | **由口播时长反推**（audio-first） |

为什么镜头时长要由口播反推
--------------------------
先切画面再配音，几乎必然对不上：要么话没说完就切镜，要么留一段干等。
`vo.load_timings()` 用 ffprobe 实测的口播时长 + 头尾留白算出每个镜头长度。

用法
----
    python promo/video/vo.py --build        # 先生成口播（改文案后必须重跑）
    python promo/video/sample15b.py --still 2.0
    python promo/video/sample15b.py
"""

import argparse
import json
import os
import subprocess
import sys
import time

import numpy as np
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

import kit
import motion
import scenes as SCN
import textmotion
import vo

PROJECT = os.path.dirname(os.path.dirname(HERE))
MAT = os.path.join(PROJECT, 'docs', '宣发物料', '00_原始素材', '截图')
FALLBACK = os.path.join(PROJECT, 'promo', 'src')
CLIP = os.path.join(PROJECT, 'docs', '宣发物料', '00_原始素材', '录屏')
OUT = os.path.join(PROJECT, 'docs', '宣发物料', '02_成片', 'v4_样片')

FPS = 30
CANVAS = (1080, 1920)
SW = 600
SYS = 0.0449
ASPECT = 1320 / 2720
CUT_890 = 86
CROP_H_890 = int(round(890 / ASPECT))

# 镜头定义：id 必须与 vo.py 的 SCRIPT id 一致（口播时长靠它对齐）
SHOTS = [
    dict(id='s1_shelf', kind='still',
         src='02_书架_喵阅_新首页_20261021.jpg',
         title='全新界面', sub='沉浸光感，一本书就是一个世界',
         scene=0, seed=11),
    dict(id='s2_material', kind='video',
         clip='SVID_20261017_125216_1.mp4', t0=6.4, t1=12.0,
         title='超多材质', sub='四十多种，随心搭配',
         scene=1, seed=23),
    dict(id='s3_tts', kind='still',
         src='07_ai_tts.jpg',
         title='AI听书', sub='多音色朗读，眼睛也能歇一歇',
         scene=4, seed=37),
]


# ── 素材 ────────────────────────────────────────────────────────────────────

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


def resolve(name):
    for d in (MAT, FALLBACK):
        p = os.path.join(d, name)
        if os.path.exists(p):
            return p
    raise SystemExit(f'找不到素材 {name}\n  查过：{MAT}\n  查过：{FALLBACK}')


def still(name):
    return app_canvas(Image.open(resolve(name)).convert('RGB'))


def video_stream(clip, t0, t1, sw, sh):
    vf = (f'trim=start={t0}:end={t1},setpts=PTS-STARTPTS,'
          f'crop=890:{CROP_H_890}:0:{CUT_890},'
          f'scale={sw}:{sh}:flags=lanczos,fps={FPS}')
    p = subprocess.Popen(['ffmpeg', '-v', 'error', '-i', clip, '-vf', vf,
                          '-f', 'rawvideo', '-pix_fmt', 'rgb24', '-'],
                         stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
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


# ── 镜头构建 ────────────────────────────────────────────────────────────────

def build(shot, dur):
    """返回 (frame_fn, n_frames)。**机身完全静止**，只有文字在动。"""
    scene = SCN.SCENES[shot['scene']]
    st = motion.Stage3D(scene, CANVAS, SW)

    # 静止姿态：所有 3D 量归零 ⇒ 机身固定在基准位，不呼吸、不位移、不推镜
    STATIC = dict(yaw=0.0, pitch=0.0, roll=0.0, z=1.0, dx=0.0, dy=0.0,
                  bgx=0.0, bgy=0.0)

    tb = textmotion.TextBlock(shot['title'], shot['sub'], scene['accent'],
                              CANVAS, seed=shot['seed'])

    if shot['kind'] == 'video':
        frames = list(video_stream(os.path.join(CLIP, shot['clip']),
                                   shot['t0'], shot['t1'], st.sw, st.sh))
        getter = lambda i: frames[min(i, len(frames) - 1)]
    else:
        img = still(shot['src']).resize((st.sw, st.sh), Image.LANCZOS)
        getter = lambda i: img

    # 背景只算一次（机身静止 ⇒ 背景也不需要逐帧裁切）
    bg = st.background(STATIC)
    bg = Image.alpha_composite(bg, st.shadow)

    def frame(i):
        t = i / FPS
        canvas = bg.copy()
        canvas = st.render(canvas, getter(i), STATIC)
        canvas = tb.render(t, canvas)
        out = canvas.convert('RGB')

        fade = 1.0
        fade *= kit.clamp01(kit.span(t, 0.0, 0.18))
        fade *= 1.0 - kit.clamp01(kit.span(t, dur - 0.26, dur))
        if fade < 0.999:
            out = Image.blend(Image.new('RGB', CANVAS, (0, 0, 0)), out, fade)
        return out

    return frame, int(round(dur * FPS))


# ── 输出 ────────────────────────────────────────────────────────────────────

def encode(frames, out_path):
    W, H = CANVAS
    os.makedirs(os.path.dirname(out_path), exist_ok=True)
    p = subprocess.Popen(
        ['ffmpeg', '-y', '-v', 'error',
         '-f', 'rawvideo', '-pix_fmt', 'rgb24', '-s', f'{W}x{H}', '-r', str(FPS), '-i', '-',
         '-vf', 'format=yuv420p', '-c:v', 'libx264', '-preset', 'slow', '-crf', '17',
         '-movflags', '+faststart', out_path],
        stdin=subprocess.PIPE)
    n = 0
    try:
        for im in frames:
            p.stdin.write(im.tobytes())
            n += 1
            if n % 45 == 0:
                print(f'  frame {n}', flush=True)
    finally:
        p.stdin.close()
        p.wait()
    if p.returncode != 0:
        raise SystemExit(f'ffmpeg 失败 code={p.returncode}')
    return n


def mux_audio(video, out, timings):
    """把各镜头口播按时间轴拼成一条音轨，再合到视频上。

    ⚠️ 用 `adelay` 把每条口播推到它在片中的起点 —— 不能用 concat，
       因为镜头时长 = 口播 + 头尾留白，留白处必须是静音。
    ⚠️ 输入索引：`-i video` 是 **0**，所以第 k 条口播是 **k+1**（不是 k）。
       实测踩过：写成 `[{k}:a]` 会报 `Stream specifier ':a' ... matches no streams`。
    """
    inputs = []
    filters = []
    for k, (sid, tm) in enumerate(timings):
        p = os.path.join(PROJECT, tm['path'])
        inputs += ['-i', p]
        idx = k + 1                       # 0 是视频
        delay_ms = int(round(tm['start'] * 1000))
        filters.append(f'[{idx}:a]adelay={delay_ms}|{delay_ms},volume=1.0[a{k}]')
    mix = ''.join(f'[a{k}]' for k in range(len(timings)))
    # apad 放在 filtergraph 里（用 -af 会与 filter_complex 冲突）
    filters.append(f'{mix}amix=inputs={len(timings)}:duration=longest:normalize=0,'
                   f'apad=whole_dur=999[aout]')

    # ⚠️ `-shortest` 会把视频切到"最后一条口播结束"的位置（实测 15.41s 成片被切成 14.41s，
    #    最后一个镜头的尾部留白被吃掉）。所以：音轨先 apad 补齐，再按画面时长 `-t` 截断。
    total = timings[-1][1]['start'] + timings[-1][1]['dur']
    cmd = ['ffmpeg', '-y', '-v', 'error', '-i', video, *inputs,
           '-filter_complex', ';'.join(filters),
           '-map', '0:v:0', '-map', '[aout]',
           '-c:v', 'copy', '-c:a', 'aac', '-b:a', '192k',
           '-ar', '48000',
           '-t', f'{total:.3f}', out]
    r = subprocess.run(cmd, capture_output=True, text=True, encoding='utf-8', errors='replace')
    if r.returncode != 0:
        raise SystemExit('混音失败：\n' + (r.stderr or '')[-1200:])
    return out


def main():
    try:
        sys.stdout.reconfigure(encoding='utf-8', errors='replace')
    except Exception:
        pass
    ap = argparse.ArgumentParser()
    ap.add_argument('--still', type=float, default=None)
    ap.add_argument('--sheet', action='store_true')
    args = ap.parse_args()

    os.makedirs(OUT, exist_ok=True)

    # 口播时长 → 镜头时长（audio-first）
    timings = vo.load_timings(lead=0.55, tail=0.45, min_dur=3.2)
    t_cursor = 0.0
    for s in SHOTS:
        tm = timings[s['id']]
        tm['start'] = t_cursor
        t_cursor += tm['dur']
    total = t_cursor

    print('镜头时长（由口播反推）:')
    for s in SHOTS:
        tm = timings[s['id']]
        print(f"  {s['id']:<12} 口播 {tm['vo']:.2f}s + 留白 → 画面 {tm['dur']:.2f}s"
              f"  (起点 {tm['start']:.2f}s)")
    print(f'  合计 {total:.2f}s\n')

    if args.still is not None:
        acc = 0.0
        for s in SHOTS:
            dur = timings[s['id']]['dur']
            if acc <= args.still < acc + dur:
                frame, n = build(s, dur)
                idx = min(int(round((args.still - acc) * FPS)), n - 1)
                t0 = time.time()
                im = frame(idx)
                p = os.path.join(OUT, f'v2_still_{s["id"]}_{args.still:.1f}s.png')
                im.save(p)
                print(f'[still] {p}  {im.size[0]}x{im.size[1]}  {time.time() - t0:.2f}s')
                return
            acc += dur
        print(f'--still {args.still} 超出总时长 {total:.2f}s')
        return

    if args.sheet:
        for s in SHOTS:
            dur = timings[s['id']]['dur']
            frame, n = build(s, dur)
            idxs = [int(round(k * (n - 1) / 5)) for k in range(6)]
            ims = [frame(i).resize((270, 480), Image.LANCZOS) for i in idxs]
            sheet = Image.new('RGB', (270 * 6, 480), (20, 20, 20))
            for k, im in enumerate(ims):
                sheet.paste(im, (270 * k, 0))
            p = os.path.join(OUT, f'v2_sheet_{s["id"]}.png')
            sheet.save(p)
            print(f'[sheet] {p}  帧号={idxs}')
        return

    # 全片
    all_frames = []
    for s in SHOTS:
        dur = timings[s['id']]['dur']
        frame, n = build(s, dur)
        all_frames.extend(frame(i) for i in range(n))
        print(f'[built] {s["id"]}  {n} frames / {dur:.2f}s')

    silent = os.path.join(OUT, '_silent.mp4')
    t0 = time.time()
    got = encode(iter(all_frames), silent)
    print(f'[video] {got} frames  {time.time() - t0:.1f}s')

    final = os.path.join(OUT, '样片_文字动效_配音版_1080x1920.mp4')
    mux_audio(silent, final, [(s['id'], timings[s['id']]) for s in SHOTS])
    os.remove(silent)
    print(f'[done] {final}')
    print(f'       体积 {os.path.getsize(final) // 1024} KB  时长 {total:.2f}s')


if __name__ == '__main__':
    sys.exit(main())
