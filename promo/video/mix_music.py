# -*- coding: utf-8 -*-
"""promo/video/mix_music.py —— 把 BGM 混成「浅浅的底垫」

用户反馈：原版（-14.5 LUFS）太响。这里改成**远低于主体**的垫底档，并一次出多档供挑选。

做法：
  1. 选窗 + 起点微调（让 11 个切点尽量落拍）
  2. 音量自动化（裂卡提一点、防窥抽空、结尾淡出）
  3. 音乐**单独**做 loudnorm 到指定 LUFS（-20 / -24 / -28）
  4. 再把音效（片尾打字 + 点击）**独立加进去**，峰值固定 —— 音乐再轻，音效也听得见

用法：
    python promo/video/mix_music.py --lufs 20 24 28
    python promo/video/mix_music.py --lufs 24 --both    # 定稿后竖版横版一起出
"""

import argparse
import os
import subprocess
import sys
import wave

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

PROJECT = os.path.dirname(os.path.dirname(HERE))
OUT = os.path.join(PROJECT, 'docs', '宣发物料', '02_成片')
MUSIC = os.path.join(OUT, '试听', 'atlasaudio-soft-inspiration-617607.mp3')

SR = 44100
DUR = 63.6
# 与 film.py 完全一致的 12 段切点（含新增的「WiFi 传书」13.0–21.2）
CUTS = [0.0, 1.0, 6.2, 13.0, 21.2, 24.6, 27.6, 33.6, 39.2, 46.8, 50.0, 56.4, 63.6]
BPM = 76.0
BEAT = 60.0 / BPM
PHASE = 0.046

# 片尾段从 56.4s 开始；音效按 endcard 内部时间轴 (1.18 / 1.56 / 2.75) 推算
EC = 56.4
SFX = [(EC + 1.18, 'type', 0.30), (EC + 1.56, 'type', 0.30), (EC + 2.75, 'click', 0.55)]
SFX_PEAK = 0.22          # 音效峰值（约 -13 dBFS），比任何一档音乐都清楚


def load_stereo(path):
    r = subprocess.run(['ffmpeg', '-v', 'error', '-i', path,
                        '-f', 'f32le', '-ac', '2', '-ar', str(SR), '-'], capture_output=True)
    if not r.stdout:
        raise SystemExit('解码失败')
    return np.frombuffer(r.stdout, dtype=np.float32).reshape(-1, 2)


def best_offset(lo, hi):
    cuts = np.array(CUTS[:-1])
    best = (1e18, lo)
    for t0 in np.arange(lo, hi, 0.004):
        beats = PHASE + BEAT * np.arange(int((t0 + DUR) / BEAT) + 2) - t0
        beats = beats[(beats >= 0) & (beats <= DUR)]
        if len(beats) < 10:
            continue
        d = np.abs(cuts[:, None] - beats[None, :]).min(axis=1)
        cost = float((d ** 2).sum())
        if cost < best[0]:
            best = (cost, float(t0))
    return best[1], best[0]


def gain_curve(n):
    """总线动态。切点变了要跟着改：裂卡 21.2s、防窥 50.0–56.4、片尾 56.4s 起。"""
    xs = [0.0, 0.7, 6.2, 20.4, 21.2, 23.2, 50.0, 50.8, 56.4, 58.2, DUR - 1.0, DUR]
    ys = [0.00, 1.00, 1.00, 1.00, 1.10, 1.04, 1.00, 0.58, 0.66, 0.86, 0.86, 0.00]
    t = np.arange(n) / SR
    return np.interp(t, xs, ys)


def write_wav(path, stereo):
    data = (np.clip(stereo, -1, 1) * 32767).astype(np.int16).reshape(-1)
    with wave.open(path, 'wb') as w:
        w.setnchannels(2)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(data.tobytes())


def read_wav(path):
    with wave.open(path, 'rb') as w:
        n = w.getnframes()
        raw = w.readframes(n)
    a = np.frombuffer(raw, dtype=np.int16).astype(np.float32) / 32768.0
    return a.reshape(-1, 2)


def main():
    try:
        sys.stdout.reconfigure(encoding='utf-8')
    except Exception:
        pass
    ap = argparse.ArgumentParser()
    ap.add_argument('--lufs', nargs='+', type=float, default=[20.0, 24.0, 28.0])
    ap.add_argument('--both', action='store_true', help='竖版横版都出（默认只出竖版）')
    args = ap.parse_args()

    x = load_stereo(MUSIC)
    total = len(x) / SR
    lo, hi = max(0.0, total - DUR - 1.6), max(0.0, total - DUR - 0.05)
    t0, _ = best_offset(lo, hi)
    print(f'音乐 {total:.2f}s ｜ 选窗 {t0:.2f}s → {t0 + DUR:.2f}s')

    i0 = int(t0 * SR)
    seg = x[i0:i0 + int(DUR * SR)].copy()
    if len(seg) < int(DUR * SR):
        seg = np.pad(seg, ((0, int(DUR * SR) - len(seg)), (0, 0)))
    seg *= gain_curve(len(seg))[:, None]

    bed_raw = os.path.join(OUT, '试听', '_bed.wav')
    write_wav(bed_raw, seg)

    import music as M
    sfx = np.zeros(len(seg))
    for t, kind, amp in SFX:
        (M.typekey if kind == 'type' else M.click)(sfx, t, amp=amp)
    sfx *= (SFX_PEAK / max(1e-9, np.abs(sfx).max()))

    rots = [('竖版', '1080x1920')]
    if args.both:
        rots.append(('横版', '1920x1080'))

    for lufs in args.lufs:
        # loudnorm 的 I 只接受负数（合法区间 -70 ~ -5），所以这里传绝对值、算的时候取负
        target = -abs(float(lufs))
        norm = os.path.join(OUT, '试听', f'_bed_{int(abs(lufs))}.wav')
        subprocess.run(['ffmpeg', '-y', '-v', 'error', '-i', bed_raw,
                        '-af', f'loudnorm=I={target}:TP=-3:LRA=11',
                        '-ar', str(SR), '-ac', '2', norm], check=True)
        bed = read_wav(norm)
        if len(bed) < len(seg):
            bed = np.pad(bed, ((0, len(seg) - len(bed)), (0, 0)))
        bed = bed[:len(seg)]
        mix = bed.copy()
        mix[:, 0] += sfx
        mix[:, 1] += sfx

        pk = np.abs(mix).max()
        if pk > 0.95:
            mix *= 0.95 / pk

        final_wav = os.path.join(OUT, '试听', f'_final_{int(abs(lufs))}.wav')
        write_wav(final_wav, mix)
        enc = os.path.join(OUT, '试听', f'_final_{int(abs(lufs))}.m4a')
        subprocess.run(['ffmpeg', '-y', '-v', 'error', '-i', final_wav,
                        '-ar', '48000', '-c:a', 'aac', '-b:a', '192k', enc], check=True)

        for tag, res in rots:
            film = os.path.join(OUT, f'宣发片_v2_{tag}_{res}.mp4')
            out = os.path.join(OUT, f'宣发片_v3_{tag}_{res}_音乐{int(abs(lufs))}LUFS.mp4')
            subprocess.run(['ffmpeg', '-y', '-v', 'error', '-i', film, '-i', enc,
                            '-map', '0:v:0', '-map', '1:a:0', '-c:v', 'copy',
                            '-ar', '48000', '-c:a', 'aac', '-b:a', '192k',
                            '-shortest', out], check=True)
            print(f'  [ok] {os.path.basename(out)}  {os.path.getsize(out) // 1024} KB  音乐 {target:.0f} LUFS')
        for f in (norm, final_wav, enc):
            os.path.exists(f) and os.remove(f)

    os.path.exists(bed_raw) and os.remove(bed_raw)


if __name__ == '__main__':
    main()
