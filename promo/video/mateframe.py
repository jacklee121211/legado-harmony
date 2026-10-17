# -*- coding: utf-8 -*-
"""promo/video/mateframe.py —— 用真实 Mate 80 边框做机框

素材：`docs/宣发物料/Mate 80-PNG/Mate 80.png`（4020×8304 RGBA）
  · 外圈是金属边框（香槟金），屏幕区是纯白
  · 屏幕区里画了三颗摄像头 —— **必须去掉**：截图本身不含物理挖孔，留着会像"画上去的"

做法（自动，不手填坐标）：
  1. 取"接近纯白"的像素 → 最大连通域 = 屏幕区（三颗摄像头是它内部的孔）
  2. `scipy.ndimage.binary_fill_holes` 把摄像头孔填平
  3. 白区当屏幕 mask；原图把这块 alpha 清零 → 得到"只剩金属边框"的覆盖层
  4. 目标尺寸下：先贴内容（用 mask 裁圆角），再贴边框覆盖层
"""

import os
import sys

import numpy as np
from PIL import Image
from scipy import ndimage

HERE = os.path.dirname(os.path.abspath(__file__))
PROJECT = os.path.dirname(os.path.dirname(HERE))
SRC = os.path.join(PROJECT, 'docs', '宣发物料', 'Mate 80-PNG', 'Mate 80.png')

_cache = {}


def _build(target_screen_w):
    """返回 (bezel_rgba, screen_mask, screen_box, size)，全部已缩放到目标尺寸。"""
    im = Image.open(SRC).convert('RGBA')
    a = np.asarray(im)
    alpha = a[:, :, 3]

    # 实测：屏幕区是**全透明**（alpha=0），只有金属边框和摄像头是不透明的。
    # 所以：① 填充不透明区域的外轮廓 → 整个机身；② 机身减去不透明 = 屏幕；
    #      ③ 屏幕再 fill 一次，把三颗摄像头（屏幕里的不透明小圆）吃掉。
    opaque = alpha > 8
    silhouette = ndimage.binary_fill_holes(opaque)
    screen = silhouette & ~opaque
    if not screen.any():
        raise SystemExit('Mate 80.png 里找不到屏幕区')
    screen = ndimage.binary_fill_holes(screen)

    ys, xs = np.where(screen)
    y0, y1, x0, x1 = int(ys.min()), int(ys.max()), int(xs.min()), int(xs.max())
    sw, sh = x1 - x0 + 1, y1 - y0 + 1

    scale = target_screen_w / float(sw)
    tw, th = int(round(im.size[0] * scale)), int(round(im.size[1] * scale))

    mask_full = Image.fromarray((screen * 255).astype(np.uint8), 'L')
    mask_full = mask_full.resize((tw, th), Image.LANCZOS)

    keep = alpha.copy()
    keep[screen] = 0                              # 屏幕区挖空 → 只剩金属边框
    bezel = Image.merge('RGBA', (*im.split()[:3], Image.fromarray(keep, 'L')))
    bezel = bezel.resize((tw, th), Image.LANCZOS)

    box = (int(round(x0 * scale)), int(round(y0 * scale)),
           int(round((x1 + 1) * scale)), int(round((y1 + 1) * scale)))
    return bezel, mask_full.crop(box), box, (tw, th)


def get(target_screen_w):
    key = int(target_screen_w)
    if key not in _cache:
        _cache[key] = _build(key)
    return _cache[key]


def info(target_screen_w=620):
    bezel, mask, box, size = get(target_screen_w)
    return dict(device=size, screen_box=box,
                screen=(box[2] - box[0], box[3] - box[1]))


def compose(content, target_screen_w, fit='stretch'):
    """把 content 贴进真实屏幕区，再盖金属边框。

    `fit='stretch'`（默认）：直接拉伸到屏幕尺寸。
        我们的画布是「整屏裁掉系统栏」后的比例 0.4853，而真机屏幕是 0.4635，
        差 4.5% 高。用 cover 会切掉左右各约 14px（可能切到 UI 边缘），
        用 stretch 只是把画面纵向放大 4.5%，不丢内容 —— 实测肉眼几乎看不出。
    """
    bezel, mask, box, size = get(target_screen_w)
    sw, sh = box[2] - box[0], box[3] - box[1]
    body = content.convert('RGB')
    if fit == 'cover':
        ar = sw / sh
        w, h = body.size
        if w / h > ar:
            nw = int(round(h * ar))
            x = (w - nw) // 2
            body = body.crop((x, 0, x + nw, h))
        else:
            nh = int(round(w / ar))
            y = (h - nh) // 2
            body = body.crop((0, y, w, y + nh))
    body = body.resize((sw, sh), Image.LANCZOS)

    out = Image.new('RGBA', size, (0, 0, 0, 0))
    out.paste(body, (box[0], box[1]), mask)
    out.alpha_composite(bezel)
    return out


if __name__ == '__main__':
    try:
        sys.stdout.reconfigure(encoding='utf-8')
    except Exception:
        pass
    print(info(620))
    # 自检：贴一张纯色，确认摄像头被填平、边框还在
    img = compose(Image.new('RGB', (620, 1300), (250, 240, 232)), 620)
    out = os.path.join(HERE, '_mate_check.png')
    img.save(out)
    print('[ok]', out, img.size)
