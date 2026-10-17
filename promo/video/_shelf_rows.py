# -*- coding: utf-8 -*-
"""量旧图纸张书列在整屏里的确切行范围（排除 dock），用于定拼接缝。"""
import numpy as np
from PIL import Image

OLD = r'promo/src/02_shelf_new.jpg'
NEW = r'docs/宣发物料/00_原始素材/截图/02_书架_喵阅标题.jpg'
BG = np.array([254, 236, 224])

old = np.asarray(Image.open(OLD).convert('RGB')).astype(np.int32)
new = np.asarray(Image.open(NEW).convert('RGB')).astype(np.int32)

def content_rows(img, y_lo, y_hi, x_lo=60, x_hi=1300, th=12):
    sub = img[y_lo:y_hi, x_lo:x_hi]
    dist = np.abs(sub - BG).max(axis=2)          # 与背景的最大通道偏离
    return np.where(dist.max(axis=1) > th)[0] + y_lo

for tag, img in (('old', old), ('new', new)):
    r = content_rows(img, 620, 2480)
    print(f'{tag}: 书列内容行 {r.min()} .. {r.max()}  (共 {len(r)} 行)')

# 旧图每本书的"行带"（间隔 > 40 行算新的一本）
r = content_rows(old, 620, 2480)
bands = []
s = r[0]
prev = r[0]
for y in r[1:]:
    if y - prev > 40:
        bands.append((s, prev))
        s = y
    prev = y
bands.append((s, prev))
print('旧图书列行带：')
for i, (a, b) in enumerate(bands, 1):
    print(f'  第{i}本 y {a}..{b}  (h={b-a+1})')

# 候选下边界：最后一本之后、dock 之前
last = bands[-1][1]
print(f'\n最后一本结束于 {last}；dock 大约从 2500 起')
for y in range(last, 2500, 20):
    d = np.abs(old[y, 20:60] - new[y, 20:60]).max()
    print(f'  y={y:4d} 左边缘背景差={d}')
