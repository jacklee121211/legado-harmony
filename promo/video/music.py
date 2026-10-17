# -*- coding: utf-8 -*-
"""promo/video/music.py —— 生成三段候选 BGM（纯代码合成，无任何版权素材）

为什么要自己合成：网上找曲子要你逐个核授权，而且没法保证长度/结构贴合我们的剪辑。
这里按**片子的 11 个切点**直接排结构，导出 55.4s 正好一首。

三个方向（都 96 BPM，55.4s）：
    A 温暖钢琴 + 轻弦乐垫底（推荐）—— 单音钢琴 + pad + 轻鼓
    B 极简氛围 —— 无鼓，长 pad + 稀疏钢琴
    C 轻快 corporate —— 拨弦 arp + 四四拍

结构（对齐剪辑点）：
    0.0–6.2    只有 pad + 稀疏钢琴，不进来鼓
    6.2–13.0   加轻 kick + 钢琴 8 分
    13.0–41.8  全编制（裂卡那一下 13.0s 正好落在小节头）
    41.8–48.2  抽掉鼓，只留 pad + 钢琴（配合防窥段变暗）
    48.2–55.4  收束长和弦 + 淡出

另外合成两个音效并混进去：片尾打字声、鼠标点击声。

用法：python promo/video/music.py
"""

import os
import subprocess
import sys

import numpy as np
from scipy.signal import fftconvolve

SR = 44100
BPM = 96.0
BEAT = 60.0 / BPM          # 0.625s
BAR = BEAT * 4             # 2.5s
DUR = 55.4

HERE = os.path.dirname(os.path.abspath(__file__))
PROJECT = os.path.dirname(os.path.dirname(HERE))
OUT = os.path.join(PROJECT, 'docs', '宣发物料', '02_成片', '试听')


def midi(m):
    return 440.0 * 2 ** ((m - 69) / 12.0)


def env(n, a, d, s, r, sr=SR):
    """ADSR 包络，长度 n。"""
    a = max(1, int(a * sr)); d = max(1, int(d * sr)); r = max(1, int(r * sr))
    s_len = max(0, n - a - d - r)
    out = np.concatenate([
        np.linspace(0, 1, a, endpoint=False),
        np.linspace(1, s, d, endpoint=False),
        np.full(s_len, s),
        np.linspace(s, 0, r, endpoint=False),
    ])
    if len(out) < n:
        out = np.concatenate([out, np.zeros(n - len(out))])
    return out[:n]


def piano(buf, t0, m, dur, amp=0.5, bright=1.0):
    """钢琴近似：几个谐波 + 指数衰减。"""
    f = midi(m)
    n = int(dur * SR)
    t = np.arange(n) / SR
    sig = np.zeros(n)
    for h, w in enumerate([1.0, 0.5 * bright, 0.28 * bright, 0.14 * bright, 0.07 * bright], start=1):
        if f * h > SR / 2.2:
            break
        sig += w * np.sin(2 * np.pi * f * h * t)
    sig *= np.exp(-t * 3.2) * env(n, 0.004, 0.25, 0.55, min(0.5, dur * 0.4))
    add(buf, t0, sig * amp)


def pad(buf, t0, notes, dur, amp=0.18):
    """弦乐垫底：三个失谐正弦 + 慢起慢落。"""
    n = int(dur * SR)
    t = np.arange(n) / SR
    sig = np.zeros(n)
    for m in notes:
        f = midi(m)
        for det in (-0.6, 0.0, 0.6):
            sig += np.sin(2 * np.pi * (f * 2 ** (det / 1200.0)) * t + np.random.rand() * 6.28)
    sig *= env(n, min(0.9, dur * 0.3), 0.2, 0.85, min(1.2, dur * 0.4))
    sig /= (len(notes) * 3)
    add(buf, t0, sig * amp)


def pluck(buf, t0, m, dur, amp=0.35):
    f = midi(m)
    n = int(dur * SR)
    t = np.arange(n) / SR
    sig = (np.sin(2 * np.pi * f * t) + 0.45 * np.sin(4 * np.pi * f * t)
           + 0.2 * np.sin(6 * np.pi * f * t))
    sig *= np.exp(-t * 9.0) * env(n, 0.002, 0.08, 0.3, min(0.25, dur * 0.5))
    add(buf, t0, sig * amp)


def kick(buf, t0, amp=0.55):
    n = int(0.22 * SR)
    t = np.arange(n) / SR
    f = 118 * np.exp(-t * 34) + 44
    sig = np.sin(2 * np.pi * np.cumsum(f) / SR) * np.exp(-t * 15)
    add(buf, t0, sig * amp)


def hat(buf, t0, amp=0.06):
    n = int(0.05 * SR)
    t = np.arange(n) / SR
    sig = np.random.randn(n) * np.exp(-t * 90)
    add(buf, t0, sig * amp)


def clap(buf, t0, amp=0.22):
    """拍手：三段错开的噪声爆发。"""
    n = int(0.16 * SR)
    t = np.arange(n) / SR
    sig = np.zeros(n)
    for d in (0.0, 0.011, 0.023):
        i = int(d * SR)
        seg = np.random.randn(n - i) * np.exp(-np.arange(n - i) / SR * 42)
        sig[i:] += seg * (1.0 - d * 12)
    add(buf, t0, sig * amp)


def click(buf, t0, amp=0.30):
    """鼠标点击：极短的高频噪声 + 一点低频 '嗒'。"""
    n = int(0.09 * SR)
    t = np.arange(n) / SR
    sig = np.random.randn(n) * np.exp(-t * 130) * 0.8
    sig += np.sin(2 * np.pi * 900 * t) * np.exp(-t * 55) * 0.5
    add(buf, t0, sig * amp)


def typekey(buf, t0, amp=0.16):
    """键盘敲击：短促的低频闷响 + 一丝高频。"""
    n = int(0.06 * SR)
    t = np.arange(n) / SR
    sig = np.sin(2 * np.pi * 180 * t) * np.exp(-t * 120) * 0.7
    sig += np.random.randn(n) * np.exp(-t * 300) * 0.35
    add(buf, t0, sig * amp)


_BUF = None


def add(buf, t0, sig):
    i = int(t0 * SR)
    if i >= len(buf):
        return
    j = min(len(buf), i + len(sig))
    buf[i:j] += sig[:j - i]


def reverb(x, wet=0.28, decay=1.1):
    n = int(decay * SR)
    t = np.arange(n) / SR
    ir = np.random.randn(n) * np.exp(-t * 3.4)
    ir[:200] *= np.linspace(0, 1, 200)
    ir /= np.abs(ir).sum() / 8
    return (1 - wet) * x + wet * fftconvolve(x, ir, mode='same')


PROG = [
    ([48, 55, 60, 64, 67], 36),      # Cmaj  (C3 G3 C4 E4 G4) / C2
    ([47, 55, 59, 62, 67], 43),      # G/B
    ([45, 52, 57, 60, 64], 45),      # Am7
    ([41, 48, 53, 57, 60], 41),      # Fmaj7
]


def chord_at(t):
    return PROG[int(t // BAR) % 4]


def master_env(n):
    """总线动态：保证段落之间有**听得出来**的强弱，不靠耳朵猜。

    0–6.2 渐入 → 6.2–13 抬到 1.0 → 主段满 → 41.8–48.2 抽到 0.6（配防窥变暗）
    → 48.2 片尾回到 0.82 → 最后 1.4s 收掉。
    """
    xs = [0.0, 1.2, 6.2, 7.2, 13.0, 41.8, 43.2, 48.2, 49.2, 54.0, 55.4]
    ys = [0.00, 0.55, 0.62, 0.98, 1.00, 1.00, 0.74, 0.76, 0.88, 0.88, 0.00]
    t = np.arange(n) / SR
    return np.interp(t, xs, ys)


def build(variant):
    n = int(DUR * SR) + int(2.0 * SR)
    buf = np.zeros(n)

    bar = 0
    while bar * BAR < DUR:
        t0 = bar * BAR
        notes, bass = chord_at(t0)
        intro = t0 < 6.2
        priv = 41.8 <= t0 < 48.2

        # ── pad：比一小节长，前后交叠，避免每小节"呼吸"出坑 ──────────────
        pad(buf, t0, notes, BAR * 1.5, amp=0.14)

        if not intro:
            piano(buf, t0, bass + 12, BAR * 0.9, amp=0.24, bright=0.3)

        # ── 钢琴动机：前奏稀疏 / 隐私段收掉 ────────────────────────────
        if intro:
            piano(buf, t0 + BEAT * 1.5, notes[2] + 12, 2.6, amp=0.20)
        elif priv:
            piano(buf, t0 + BEAT * 2, notes[4] + 12, 2.4, amp=0.22)
        else:
            seq = [notes[2] + 12, notes[4] + 12, notes[3] + 12, notes[4] + 12]
            for k in range(8):
                m = seq[k % 4]
                piano(buf, t0 + k * BEAT / 2, m, 1.1, amp=0.30 if k % 2 == 0 else 0.19)

        # ── 鼓：只有主段 ────────────────────────────────────────────────
        if 6.2 <= t0 < 41.8:
            for b in (0, 2):
                kick(buf, t0 + b * BEAT, amp=0.62)
            if variant == 'C':
                for b in (1, 3):
                    kick(buf, t0 + b * BEAT, amp=0.36)
                for b in (1, 3):
                    clap(buf, t0 + b * BEAT, amp=0.22)
            for k in range(8):
                hat(buf, t0 + k * BEAT / 2, amp=0.075 if k % 2 else 0.05)

        # ── corporate 的拨弦层 ──────────────────────────────────────────
        if variant == 'C' and t0 >= 6.2:
            for k in range(8):
                pluck(buf, t0 + k * BEAT / 2, notes[k % len(notes)] + 12, 0.35, amp=0.24)

        bar += 1

    # ── 片尾收束：48.2s 起一个长和弦 ───────────────────────────────────
    end_t = 48.2
    notes, _ = chord_at(end_t)
    pad(buf, end_t, notes, DUR - end_t + 0.5, amp=0.26)
    for m in notes:
        piano(buf, end_t, m + 12, 5.5, amp=0.28)

    # ── 音效：片尾打字 + 点击（对齐 endcard 时间轴）────────────────────
    ec = 48.2
    typekey(buf, ec + 1.18, amp=0.22)
    typekey(buf, ec + 1.56, amp=0.22)
    click(buf, ec + 2.75, amp=0.46)

    # ── 混响 + 总线动态 + 归一化 ───────────────────────────────────────
    buf = reverb(buf)
    buf = buf[:int(DUR * SR)]
    buf = buf * master_env(len(buf))

    buf /= max(1e-9, np.abs(buf).max())
    return buf * 0.92


def write(name, label, x):
    os.makedirs(OUT, exist_ok=True)
    wav = os.path.join(OUT, f'{name}.wav')
    data = (np.clip(x, -1, 1) * 32767).astype(np.int16)
    stereo = np.stack([data, data], axis=1).reshape(-1)
    import wave
    with wave.open(wav, 'wb') as w:
        w.setnchannels(2)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(stereo.tobytes())

    m4a = os.path.join(OUT, f'{name}.m4a')
    subprocess.run(['ffmpeg', '-y', '-v', 'error', '-i', wav,
                    '-af', 'loudnorm=I=-14:TP=-1.5:LRA=11',
                    '-c:a', 'aac', '-b:a', '192k', m4a], check=True)
    os.remove(wav)
    rms = 20 * np.log10(max(1e-9, np.sqrt((x ** 2).mean())))
    print(f'[ok] {os.path.basename(m4a)}  {DUR:.1f}s  峰值 {np.abs(x).max():.2f}  RMS {rms:.1f} dB  '
          f'{os.path.getsize(m4a)//1024} KB   ({label})')


def main():
    try:
        sys.stdout.reconfigure(encoding='utf-8')
    except Exception:
        pass
    np.random.seed(7)
    specs = [
        ('候选A_温暖钢琴_96bpm', '温暖钢琴 + 轻弦乐垫底', 'A'),
        ('候选B_极简氛围_96bpm', '极简氛围（无鼓）', 'B'),
        ('候选C_轻快corporate_96bpm', '轻快 corporate（拨弦+四四拍）', 'C'),
    ]
    for name, label, v in specs:
        write(name, label, build(v))


if __name__ == '__main__':
    main()
