# -*- coding: utf-8 -*-
"""量新截图的顶部几何：找深色文字的行区间（用于决定海报裁切上沿）。"""
import sys
import numpy as np
from PIL import Image

p = sys.argv[1]
im = Image.open(p).convert('RGB')
a = np.asarray(im).astype(np.int32)   # ⚠️ 必须 int32：255*299=76245 会撑爆 int16
lum = (a[:, :, 0] * 299 + a[:, :, 1] * 587 + a[:, :, 2] * 114) // 1000

H, W = lum.shape
print('image', W, 'x', H)

# 只看顶部 1400 行；深色文字 = 亮度 < 110
rows = []
for y in range(0, min(1400, H)):
    dark = int((lum[y] < 110).sum())
    rows.append(dark)

# 找连续"有深色像素"的带（按行阈值 20 个像素）
bands = []
inb = False
start = 0
for y, c in enumerate(rows):
    if c >= 20 and not inb:
        inb, start = True, y
    elif c < 20 and inb:
        inb = False
        if y - start >= 6:
            bands.append((start, y - 1))
if inb:
    bands.append((start, len(rows) - 1))

print('深色文字带（y_start, y_end, 高度）:')
for s, e in bands:
    # 该带的横向范围
    sub = lum[s:e + 1]
    cols = np.where((sub < 110).sum(axis=0) > 0)[0]
    print(f'  y {s:5d} .. {e:5d}   h={e - s + 1:4d}   x {cols.min():4d}..{cols.max():4d}')
