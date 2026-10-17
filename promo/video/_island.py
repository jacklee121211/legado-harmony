# -*- coding: utf-8 -*-
"""量真机灵动岛（黑胶囊）的精确几何，用于让机框里的假岛精确覆盖它。"""
import sys

import numpy as np
from PIL import Image

try:
    sys.stdout.reconfigure(encoding='utf-8')
except Exception:
    pass

p = sys.argv[1] if len(sys.argv) > 1 else r'promo\video\_f06.png'
im = Image.open(p).convert('RGB')
a = np.asarray(im).astype(np.int32)
H, W, _ = a.shape
print(f'frame {W}x{H}')

# 黑胶囊：亮度 < 40 且横向连成一片
lum = a.mean(axis=2)
dark = lum < 40

best = None
for y in range(0, 300):
    xs = np.where(dark[y])[0]
    if len(xs) < W * 0.15:
        continue
    # 找最长连续段
    runs = []
    s = xs[0]
    prev = xs[0]
    for x in xs[1:]:
        if x - prev > 3:
            runs.append((s, prev))
            s = x
        prev = x
    runs.append((s, prev))
    x0, x1 = max(runs, key=lambda r: r[1] - r[0])
    if x1 - x0 < W * 0.2:
        continue
    if best is None:
        best = [y, y, x0, x1]
    best[1] = y
    best[2] = min(best[2], x0)
    best[3] = max(best[3], x1)

y0, y1, x0, x1 = best
print(f'胶囊 y {y0}..{y1} (高 {y1 - y0 + 1})   x {x0}..{x1} (宽 {x1 - x0 + 1})')
print(f'占屏宽 {(x1 - x0 + 1) / W:.3f}   占屏高 {(y1 - y0 + 1) / H:.4f}')
print(f'顶部偏移 {y0 / H:.4f}   水平中心 {(x0 + x1) / 2 / W:.4f}')
