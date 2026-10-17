# -*- coding: utf-8 -*-
"""promo/video/analyze_audio.py —— 测一首曲子的 BPM / 拍点 / 结构 / 响度

不依赖 librosa（本机没装），全部用 numpy + scipy 实现：
  · STFT → 谱通量 → 起音包络
  · 起音包络自相关 → 主 BPM（含半拍/倍拍候选）
  · 与脉冲串互相关 → 拍点相位
  · 每秒 RMS + 谱质心 → 段落结构（哪里进鼓、哪里抽空）
"""

import os
import subprocess
import sys

import numpy as np

SR = 22050
HOP = 512
NFFT = 2048


def load(path):
    r = subprocess.run(['ffmpeg', '-v', 'error', '-i', path,
                        '-f', 'f32le', '-ac', '1', '-ar', str(SR), '-'],
                       capture_output=True)
    if not r.stdout:
        raise SystemExit('解码失败')
    return np.frombuffer(r.stdout, dtype=np.float32)


def stft_mag(x):
    n = 1 + (len(x) - NFFT) // HOP
    win = np.hanning(NFFT).astype(np.float32)
    frames = np.lib.stride_tricks.sliding_window_view(x, NFFT)[::HOP]
    frames = frames[:n] * win
    return np.abs(np.fft.rfft(frames, axis=1))


def onset_env(S):
    # 谱通量（只算上升沿）
    d = np.diff(S, axis=0)
    d[d < 0] = 0
    env = d.sum(axis=1)
    env = env - env.mean()
    return np.maximum(env, 0)


def estimate_tempo(env, fps):
    e = env - env.mean()
    ac = np.correlate(e, e, mode='full')[len(e) - 1:]
    ac /= (ac[0] + 1e-9)
    lo = int(fps * 60 / 200)      # 200 BPM 上限
    hi = int(fps * 60 / 55)       # 55 BPM 下限
    seg = ac[lo:hi]
    cands = []
    for i in range(2, len(seg) - 2):
        if seg[i] > seg[i - 1] and seg[i] > seg[i + 1]:
            bpm = 60.0 * fps / (i + lo)
            cands.append((seg[i], bpm))
    cands.sort(reverse=True)
    return cands[:6], ac


def beat_phase(env, bpm, fps):
    period = 60.0 / bpm * fps
    best, bestp = -1e9, 0.0
    for p in np.arange(0, period, 0.5):
        idx = np.arange(p, len(env), period).astype(int)
        idx = idx[idx < len(env)]
        v = env[idx].mean()
        if v > best:
            best, bestp = v, p
    return bestp, period


def main():
    try:
        sys.stdout.reconfigure(encoding='utf-8')
    except Exception:
        pass
    p = sys.argv[1]
    x = load(p)
    dur = len(x) / SR
    print(f'文件 {os.path.basename(p)}')
    print(f'时长 {dur:.2f}s  采样率 {SR}')

    S = stft_mag(x)
    fps = SR / HOP
    env = onset_env(S)

    cands, ac = estimate_tempo(env, fps)
    print('\nBPM 候选（自相关峰值）：')
    for v, bpm in cands:
        print(f'   {bpm:6.2f} BPM   相关 {v:.3f}')

    bpm = cands[0][1] if cands else 100.0
    phase, period = beat_phase(env, bpm, fps)
    print(f'\n采用 {bpm:.2f} BPM   拍长 {60/bpm:.3f}s   首拍 {phase/fps:.3f}s')

    # 每秒 RMS + 谱质心
    n_sec = int(dur)
    print('\n每秒能量（RMS dB）与亮度（谱质心 Hz）：')
    line = []
    for s in range(n_sec):
        a, b = int(s * SR), int((s + 1) * SR)
        seg = x[a:b]
        rms = 20 * np.log10(max(1e-9, np.sqrt((seg ** 2).mean())))
        i0 = int(s * fps)
        i1 = min(len(S), int((s + 1) * fps))
        if i1 > i0:
            spec = S[i0:i1].mean(axis=0)
            freqs = np.fft.rfftfreq(NFFT, 1 / SR)
            cen = (spec * freqs).sum() / (spec.sum() + 1e-9)
        else:
            cen = 0
        line.append(f'{s:>3}s {rms:6.1f} /{cen:5.0f}')
    for i in range(0, len(line), 4):
        print('   ' + '   '.join(line[i:i + 4]))


if __name__ == '__main__':
    main()
