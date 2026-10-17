# -*- coding: utf-8 -*-
"""promo/video/sheet_clips.py —— 给录屏生成「每段一行、含时间戳」的联络表，用于人眼筛选。

用法：
    python promo/video/sheet_clips.py                 # 全部素材，每张 4 段
    python promo/video/sheet_clips.py --files a.mp4 b.mp4
"""

import argparse
import glob
import os
import subprocess

from PIL import Image, ImageDraw

import kit

HERE = os.path.dirname(os.path.abspath(__file__))
PROJECT = os.path.dirname(os.path.dirname(HERE))
CLIP_DIR = os.path.join(PROJECT, 'docs', '宣发物料', '00_原始素材', '录屏')
OUT_DIR = os.path.join(PROJECT, 'docs', '宣发物料', '02_成片', '_筛选')

FRAME_W = 210
K = 5          # 每段取 5 帧
LABEL_W = 250
PER_SHEET = 4  # 每张联络表放几段


def duration(path):
    r = subprocess.run(['ffprobe', '-v', 'error', '-show_entries', 'format=duration',
                        '-of', 'default=nw=1:nk=1', path], capture_output=True, text=True)
    return float(r.stdout.strip())


def grab(path, t):
    r = subprocess.run(['ffmpeg', '-v', 'error', '-ss', f'{t:.3f}', '-i', path,
                        '-frames:v', '1', '-vf', f'scale={FRAME_W}:-1',
                        '-f', 'image2pipe', '-vcodec', 'png', '-'],
                       capture_output=True)
    if r.returncode != 0 or not r.stdout:
        return None
    from io import BytesIO
    return Image.open(BytesIO(r.stdout)).convert('RGB')


def make_sheet(files, out_path):
    rows = []
    for p in files:
        d = duration(p)
        times = [d * (i + 0.5) / K for i in range(K)]
        imgs = [(t, grab(p, t)) for t in times]
        rows.append((os.path.basename(p), d, imgs))

    fh = None
    for _, _, imgs in rows:
        for _, im in imgs:
            if im:
                fh = im.size[1]
                break
        if fh:
            break
    row_h = (fh or int(FRAME_W * 1920 / 890)) + 26
    W = LABEL_W + FRAME_W * K
    H = row_h * len(rows)

    sheet = Image.new('RGB', (W, H), (24, 24, 26))
    d = ImageDraw.Draw(sheet)
    f_name = kit.font('bold', 17)
    f_meta = kit.font('regular', 15)
    f_ts = kit.font('regular', 13)

    for r, (name, dur, imgs) in enumerate(rows):
        y = r * row_h
        d.text((10, y + 8), name.replace('SVID_20261017_', ''), font=f_name, fill=(255, 255, 255))
        d.text((10, y + 30), f'{dur:.1f}s', font=f_meta, fill=(150, 200, 255))
        for k, (t, im) in enumerate(imgs):
            x = LABEL_W + k * FRAME_W
            if im:
                sheet.paste(im, (x, y + 26))
                d.text((x + 4, y + 30), f'{t:.1f}s', font=f_ts, fill=(255, 240, 120))
        d.line((0, y + row_h - 1, W, y + row_h - 1), fill=(70, 70, 76))

    os.makedirs(os.path.dirname(out_path), exist_ok=True)
    sheet.save(out_path)
    print('[sheet]', out_path, sheet.size)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--files', nargs='*', default=None)
    args = ap.parse_args()

    files = args.files or sorted(glob.glob(os.path.join(CLIP_DIR, '*.mp4')))
    for i in range(0, len(files), PER_SHEET):
        chunk = files[i:i + PER_SHEET]
        out = os.path.join(OUT_DIR, f'sheet_{i // PER_SHEET + 1:02d}.png')
        make_sheet(chunk, out)


if __name__ == '__main__':
    main()
