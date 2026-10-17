# -*- coding: utf-8 -*-
"""promo/video/action_timeline.py —— 每 0.4s 一格的"运动时间轴"，用来定剪辑入出点。

输出示例：
    125112  (12.0s)
      0.0 |#####                       |  1.2   0.4s
      ...
      ★ 峰值 3.2s

## 是运动越大越好吗？不是。
## 这里只用来**定位"动作发生在第几秒"**，方便我给出精确的 in/out 建议；
## 电影感靠的是选段，不是数值。
"""

import glob
import os
import subprocess
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
PROJECT = os.path.dirname(os.path.dirname(HERE))
CLIP_DIR = os.path.join(PROJECT, 'docs', '宣发物料', '00_原始素材', '录屏')

GW, GH = 60, 130
STEP = 0.4


def load(path):
    r = subprocess.run(
        ['ffmpeg', '-v', 'error', '-i', path,
         '-vf', f'fps=10,scale={GW}:{GH},format=gray',
         '-f', 'rawvideo', '-pix_fmt', 'gray', '-'],
        capture_output=True)
    buf = np.frombuffer(r.stdout, dtype=np.uint8)
    n = buf.size // (GW * GH)
    return buf[:n * GW * GH].reshape(n, GH, GW).astype(np.int16) if n else None


def main():
    names = sys.argv[1:]
    files = [os.path.join(CLIP_DIR, n) for n in names] if names else \
        sorted(glob.glob(os.path.join(CLIP_DIR, '*.mp4')))

    for p in files:
        f = load(p)
        if f is None:
            print(f'{os.path.basename(p)}  解码失败')
            continue
        motion = np.abs(np.diff(f, axis=0)).mean(axis=(1, 2))   # 10fps
        per = max(1, int(round(STEP * 10)))
        bars, vals = [], []
        for i in range(0, len(motion), per):
            v = float(motion[i:i + per].mean())
            vals.append(v)
            bars.append(int(min(28, v * 1.4)))
        dur = len(f) / 10.0
        print(f'\n{os.path.basename(p)}  ({dur:.1f}s)   每格 {STEP}s')
        for k, (b, v) in enumerate(zip(bars, vals)):
            t = k * STEP
            star = ' ★' if v == max(vals) and v > 3 else ''
            print(f'  {t:5.1f} |{"#" * b:<28}| {v:6.2f}{star}')
        peak = int(np.argmax(vals)) * STEP
        print(f'  → 动作峰值约 {peak:.1f}s')


if __name__ == '__main__':
    main()
