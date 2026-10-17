# -*- coding: utf-8 -*-
"""把所有素材的"标题区"（y 100..280）拼成一张联络表，用于肉眼排查残留的旧版标题。"""
import glob
import os

from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
PROJECT = os.path.dirname(os.path.dirname(HERE))
DIRS = [
    os.path.join(PROJECT, 'promo', 'src'),
    os.path.join(PROJECT, 'docs', '宣发物料', '00_原始素材', '截图'),
]
files = []
for d in DIRS:
    files += sorted(glob.glob(os.path.join(d, '*.jpg')) + glob.glob(os.path.join(d, '*.png')))

W, H = 420, 190
cols = 4
rows = (len(files) + cols - 1) // cols
sheet = Image.new('RGB', (W * cols, H * rows), (30, 30, 30))
for i, p in enumerate(files):
    im = Image.open(p).convert('RGB')
    band = im.crop((0, 100, min(W, im.size[0]), min(100 + H, im.size[1])))
    x, y = (i % cols) * W, (i // cols) * H
    sheet.paste(band, (x, y))
    print(f'{i:2d}  {os.path.basename(p)}')
out = os.path.join(HERE, '_titles.png')
sheet.save(out)
print('[saved]', out, sheet.size)
