# -*- coding: utf-8 -*-
"""promo/video/splice_shelf.py —— 把「旧截图的书列」拼到「新截图」上

背景
----
2026-10-17 截图顶部标题从「书架」改成了「喵阅」（品牌露出），但新截图的书架只剩
1 本书（默认协议），物料会空一大片。两张截图的版式坐标**完全一致**（实测：
状态栏 57-99、标题 140-218、页签 350-394、筛选 538-574、第一本书 701-837），
所以可以把旧图的 5 本书列原样搬过来。

为什么能无缝
------------
实测书列区域的背景两图**逐像素相同**（`[254,236,224]`，|diff|=0，y 620..2200），
所以只要在**纯背景行**上切，接缝不可见。脚本会自己找这样的行并断言。

用法
----
    python promo/video/splice_shelf.py            # 输出到 00_原始素材/截图/
    python promo/video/splice_shelf.py --dry-run  # 只打印诊断，不写文件
"""

import argparse
import os
import sys

import numpy as np
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
PROJECT = os.path.dirname(os.path.dirname(HERE))
OLD = os.path.join(PROJECT, 'promo', 'src', '02_shelf_new.jpg')
SHOT_DIR = os.path.join(PROJECT, 'docs', '宣发物料', '00_原始素材', '截图')
NEW = os.path.join(SHOT_DIR, '02_书架_喵阅标题.jpg')
OUT = os.path.join(SHOT_DIR, '02_书架_喵阅_带书.png')

FEATHER = 28          # 接缝羽化高度（像素）
CONTENT_TH = 8        # 内容判定阈值（通道差）；背景实测 0，留 8 完全够
BG = np.array([254, 236, 224])

# 切缝（实测，见 _shelf_rows.py）：
#   旧图内容行 620..2457，其中 620..634 是筛选胶囊的下沿阴影，
#   5 本书分别在 699..978 / 1069..1348 / 1439..1718 / 1809..2087 / 2179..2457；
#   dock 从 ~2500 起。⇒ 上下切缝选 660 与 2470，两处都是纯背景。
SEAM_TOP = 660
SEAM_BOT = 2470


def assert_clean_seam(old, new, y, span=4):
    """断言 y 附近是纯背景、且两图一致 —— 否则拼出来会露横线。"""
    for yy in range(y, y + span):
        o, n = old[yy], new[yy]
        if np.abs(o - n).max() > 2:
            raise SystemExit(f'切缝 y={yy} 两图不一致（最大差 {np.abs(o - n).max()}）⇒ 会露线')
        if np.abs(o - BG).max() > 4:
            raise SystemExit(f'切缝 y={yy} 不是纯背景（离背景色 {np.abs(o - BG).max()}）⇒ 会切到内容')


def content_band(img, y_lo=640, y_hi=2480, x_lo=60, x_hi=1300, th=12):
    sub = img[y_lo:y_hi, x_lo:x_hi]
    dist = np.abs(sub - BG).max(axis=2)
    rows = np.where(dist.max(axis=1) > th)[0] + y_lo
    return int(rows.min()), int(rows.max())


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--dry-run', action='store_true')
    args = ap.parse_args()

    old = np.asarray(Image.open(OLD).convert('RGB')).astype(np.int32)
    new = np.asarray(Image.open(NEW).convert('RGB')).astype(np.int32)
    assert old.shape == new.shape, f'两图尺寸不同：{old.shape} vs {new.shape}'
    H, W, _ = old.shape

    diff = np.abs(old - new)
    rowmax = diff.max(axis=2)
    has_content = rowmax.max(axis=1) > CONTENT_TH

    top, bot = SEAM_TOP, SEAM_BOT
    assert_clean_seam(old, new, top)
    assert_clean_seam(old, new, bot)
    print(f'切缝上沿 top={top}（纯背景、两图一致）  切缝下沿 bot={bot}（同）')

    # 诊断：旧图书列的实际范围必须落在切缝之内
    o_lo, o_hi = content_band(old)
    n_lo, n_hi = content_band(new)
    print(f'旧图书列 {o_lo}..{o_hi}   新图书列 {n_lo}..{n_hi}')
    assert o_lo >= top and o_hi <= bot, f'旧书列 {o_lo}..{o_hi} 溢出切缝 {top}..{bot}'
    assert o_hi > n_hi, '旧图内容并不比新图多，没有拼接的必要'
    assert bot - top > 1500, f'切缝区间异常（{bot - top}px）'

    # ── 合成：new 为主体，把 old 的 [top,bot) 整行贴过来，上下做羽化 ────────
    out = new.copy()
    patch = old[top:bot].copy()

    n = min(FEATHER, (bot - top) // 4)
    if n > 0:
        ramp = np.linspace(0.0, 1.0, n)[:, None, None]
        patch[:n] = new[top:top + n] * (1 - ramp) + patch[:n] * ramp
        patch[-n:] = new[bot - n:bot] * ramp[::-1] + patch[-n:] * (1 - ramp[::-1])

    out[top:bot] = patch
    print(f'拼接完成：y {top}..{bot}（{bot - top} px），羽化 {n} px')

    if args.dry_run:
        print('[dry-run] 不写文件')
        return

    Image.fromarray(out.astype(np.uint8), 'RGB').save(OUT)
    print(f'[saved] {OUT}  {os.path.getsize(OUT) // 1024} KB')


if __name__ == '__main__':
    sys.exit(main())
