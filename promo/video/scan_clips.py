# -*- coding: utf-8 -*-
"""promo/video/scan_clips.py —— 录屏素材体检

对每段录屏做四件事（全部可复现，不依赖人眼）：
  1. ffprobe 元数据：时长 / 分辨率 / 帧率 / 有无音轨 / 码率
  2. 以 2fps 抽灰度小帧，算「运动量」= 相邻帧平均绝对差
     —— 运动量长期≈0 = 画面没动（废片）；个别帧尖峰 = 某一下翻页
  3. 首帧/末帧亮度 —— 全黑 = 录废了
  4. dHash 感知哈希：跨文件对比采样帧，找出重复/近乎重复的素材

用法：
    python promo/video/scan_clips.py            # 打印体检表 + 重复分组
    python promo/video/scan_clips.py --json out.json
"""

import argparse
import glob
import json
import os
import subprocess
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
PROJECT = os.path.dirname(os.path.dirname(HERE))
CLIP_DIR = os.path.join(PROJECT, 'docs', '宣发物料', '00_原始素材', '录屏')

GW, GH = 90, 195      # 灰度小帧尺寸（与原图同比例）


def sh(cmd):
    return subprocess.run(cmd, capture_output=True, text=True, encoding='utf-8', errors='replace')


def probe(path):
    r = sh(['ffprobe', '-v', 'error', '-show_entries',
            'stream=codec_type,codec_name,width,height,r_frame_rate,avg_frame_rate,nb_frames',
            '-show_entries', 'format=duration,size,bit_rate',
            '-of', 'json', path])
    if r.returncode != 0:
        return None
    d = json.loads(r.stdout or '{}')
    fmt = d.get('format', {})
    streams = d.get('streams', [])
    v = next((s for s in streams if s.get('codec_type') == 'video'), {})
    a = next((s for s in streams if s.get('codec_type') == 'audio'), None)
    return dict(
        duration=float(fmt.get('duration') or 0),
        size=int(fmt.get('size') or 0),
        bitrate=int(fmt.get('bit_rate') or 0),
        width=int(v.get('width') or 0),
        height=int(v.get('height') or 0),
        fps=v.get('r_frame_rate') or '',
        codec=v.get('codec_name') or '',
        has_audio=a is not None,
        audio_codec=(a or {}).get('codec_name', ''),
    )


def gray_frames(path):
    """2fps 抽灰度帧，返回 (N, GH, GW) uint8。"""
    r = subprocess.run(
        ['ffmpeg', '-v', 'error', '-i', path,
         '-vf', f'fps=2,scale={GW}:{GH},format=gray',
         '-f', 'rawvideo', '-pix_fmt', 'gray', '-'],
        capture_output=True)
    if r.returncode != 0 or not r.stdout:
        return None
    buf = np.frombuffer(r.stdout, dtype=np.uint8)
    n = buf.size // (GW * GH)
    if n == 0:
        return None
    return buf[:n * GW * GH].reshape(n, GH, GW)


def dhash(img):
    """8x8 差分哈希（64 bit int）。img 为灰度二维数组。"""
    from PIL import Image
    small = np.asarray(Image.fromarray(img).resize((9, 8), 1), dtype=np.int16)
    bits = (small[:, 1:] > small[:, :-1]).flatten()
    v = 0
    for b in bits:
        v = (v << 1) | int(b)
    return v


def hamming(a, b):
    return bin(a ^ b).count('1')


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--json', default=None)
    args = ap.parse_args()

    files = sorted(glob.glob(os.path.join(CLIP_DIR, '*.mp4')))
    if not files:
        raise SystemExit(f'{CLIP_DIR} 里没有 mp4')

    rows = []
    for p in files:
        name = os.path.basename(p)
        meta = probe(p)
        frames = gray_frames(p)
        if meta is None or frames is None:
            rows.append(dict(name=name, error='probe/decode failed'))
            print(f'[FAIL] {name} 无法解析')
            continue

        f = frames.astype(np.int16)
        motion = np.abs(np.diff(f, axis=0)).mean(axis=(1, 2)) if len(f) > 1 else np.array([0.0])
        bright = f.mean(axis=(1, 2))

        # 采样 8 帧做哈希（用于跨文件查重）
        idx = np.linspace(0, len(f) - 1, min(8, len(f))).round().astype(int)
        hashes = [dhash(f[i]) for i in idx]

        rows.append(dict(
            name=name, **meta,
            n_samples=len(f),
            motion_mean=float(motion.mean()),
            motion_max=float(motion.max()),
            motion_p95=float(np.percentile(motion, 95)),
            bright_first=float(bright[0]),
            bright_last=float(bright[-1]),
            bright_mean=float(bright.mean()),
            hashes=hashes,
        ))

    # ── 重复检测：哈希逐位平均距离 <= 6 认为是同一段（或几乎同一段）──────
    good = [r for r in rows if 'hashes' in r]
    parent = list(range(len(good)))

    def find(i):
        while parent[i] != i:
            parent[i] = parent[parent[i]]
            i = parent[i]
        return i

    for i in range(len(good)):
        for j in range(i + 1, len(good)):
            hs, ht = good[i]['hashes'], good[j]['hashes']
            n = min(len(hs), len(ht))
            d = np.mean([hamming(hs[k], ht[k]) for k in range(n)])
            if d <= 6:
                parent[find(i)] = find(j)

    groups = {}
    for i, r in enumerate(good):
        groups.setdefault(find(i), []).append(r['name'])

    # ── 打印体检表 ──────────────────────────────────────────────────────────
    print('\n{:<30} {:>6} {:>5} {:>9} {:>7} {:>8} {:>8} {:>6} {:>6}'.format(
        '文件', '时长s', 'fps', '分辨率', '音轨', '运动均值', '运动峰值', '首亮', '均亮'))
    print('-' * 104)
    for r in rows:
        if 'error' in r:
            print(f'{r["name"]:<30}  {r["error"]}')
            continue
        fps = r['fps']
        try:
            num, den = fps.split('/')
            fps_s = f'{int(num) / int(den):.0f}'
        except Exception:
            fps_s = fps
        print('{:<30} {:>6.1f} {:>5} {:>9} {:>7} {:>8.2f} {:>8.2f} {:>6.0f} {:>6.0f}'.format(
            r['name'][:30], r['duration'], fps_s, f'{r["width"]}x{r["height"]}',
            '有' if r['has_audio'] else '无',
            r['motion_mean'], r['motion_max'], r['bright_first'], r['bright_mean']))

    print('\n=== 重复/近似重复分组 ===')
    for k, names in groups.items():
        if len(names) > 1:
            print('  组:', ' | '.join(names))
    if all(len(v) == 1 for v in groups.values()):
        print('  （无重复）')

    if args.json:
        out = [{k: v for k, v in r.items() if k != 'hashes'} for r in rows]
        with open(args.json, 'w', encoding='utf-8') as fp:
            json.dump(out, fp, ensure_ascii=False, indent=2)
        print(f'\n[json] {args.json}')


if __name__ == '__main__':
    sys.exit(main())
