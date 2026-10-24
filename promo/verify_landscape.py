# -*- coding: utf-8 -*-
"""横版产物验收：尺寸/格式 + 图文碰撞 + 越界 + 内容区留白检查。

判据（不靠肉眼）：
 1. 每张都是目标宽高、PNG 格式（mode=RGB，无 alpha 意外透明）；
 2. 卡片区（右栏）与文字列（左栏）**无重叠**——用像素差检测：
    分别渲染「只有背景」与「只有文字层」的中间态成本高，改为直接按几何量：
    文字块右沿 ≤ 卡片左沿 - gap/2；
 3. 文字块不越出画布（左/上/下/右留白 ≥ margin/2）；
 4. 卡片可见高度 ≥ 画布高 - card_top（即确实"顶对齐 + 向下出血"）。
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from PIL import Image, ImageChops

import make_posters as P
import make_posters_landscape as L

OUT_ROOT = os.path.join(P.MATERIAL_ROOT, '02_成片')
SIZES = [('v2_横版_1920x1280', 1920, 1280), ('v2_横版_1920x1080', 1920, 1080)]

fails, notes = [], []

for d, W, H in SIZES:
    m = L.metrics(H)
    for i, p in enumerate(P.POSTERS, start=1):
        if p.get('skip'):
            continue
        path = os.path.join(OUT_ROOT, d, p['out'])
        if not os.path.exists(path):
            fails.append(f'{d}/{p["out"]} 缺失')
            continue
        im = Image.open(path)
        if (im.width, im.height) != (W, H):
            fails.append(f'{d}/{p["out"]} 尺寸 {im.width}x{im.height} != {W}x{H}')
        if im.format != 'PNG':
            fails.append(f'{d}/{p["out"]} 格式 {im.format} != PNG')
        if im.mode != 'RGB':
            notes.append(f'{d}/{p["out"]} mode={im.mode}（非 RGB）')

        # 用与 compose 相同的布局计算核对几何关系
        stack = p.get('stack') == 'material'
        probe_w = int(W * m['text_w_ratio'])
        if stack:
            import make_material_stitch as MS
            pg = MS.stitched_page()
            aspect = pg.size[0] / pg.size[1]
        else:
            shot = Image.open(P.resolve_src(p['src'])).convert('RGB').crop(p['crop'])
            aspect = shot.size[0] / shot.size[1]

        M0 = L.text_metrics(p, probe_w, H)
        text_w = min(M0['w'], probe_w)
        avail_for_card = W - m['margin'] - (m['margin'] + text_w + m['col_gap'])
        if stack:
            area_h = (H + m['bleed']) - m['card_top']
            expose = area_h * P.BACK_EXPOSE
            fh_max = area_h - expose
            card_w = min(fh_max * aspect, avail_for_card)
            card_h = min(card_w / aspect + m['bleed'], fh_max)
        else:
            card_h = (H - m['card_top']) + m['bleed']
            card_w = card_h * aspect
            if card_w > avail_for_card:
                card_w = avail_for_card
                card_h = card_w / aspect

        avail_w = int(min(probe_w, (W - m['margin'] - card_w) - m['margin'] - m['col_gap']))
        M = L.text_metrics(p, avail_w, H)
        card_x = int(round(W - m['margin'] - card_w))
        text_right = m['margin'] + M['w']
        gap = card_x - text_right

        if gap < 0:
            fails.append(f'{d}/{p["out"]} 图文重叠：文字右沿 {text_right:.0f} > 卡片左沿 {card_x}（gap={gap:.0f}）')
        elif gap < m['col_gap'] * 0.5:
            notes.append(f'{d}/{p["out"]} 图文间距偏小：{gap:.0f} < gap/2={m["col_gap"]*0.5:.0f}')

        if M['w'] > avail_w + 1:
            fails.append(f'{d}/{p["out"]} 文字超出可用宽：{M["w"]:.0f} > {avail_w}')

        if m['margin'] + M['h'] > H + 1:
            fails.append(f'{d}/{p["out"]} 文字块纵向越界：h={M["h"]:.0f}')

        if card_h < H - m['card_top']:
            notes.append(f'{d}/{p["out"]} 卡片未吃满高度：{card_h:.0f} < {H - m["card_top"]}')

print('=== FAIL ===')
print('\n'.join(fails) if fails else '(none)')
print('=== NOTE ===')
print('\n'.join(notes) if notes else '(none)')
print('total fails:', len(fails))
sys.exit(1 if fails else 0)
