# -*- coding: utf-8 -*-
"""promo/video/vo.py —— AI 语音解说（edge-tts），并让**口播时长反推画面时长**

为什么先做声音再定画面
----------------------
行业里叫 "audio-first"：先定口播，画面去贴声音。
反过来做（先切好画面再配音）几乎必然对不上 —— 要么话没说完就切镜，要么留一段干等。

本模块负责三件事：
  1. 生成口播 mp3（edge-tts，零成本、无 Key）
  2. 量出**真实时长**（不信 edge-tts 的元数据，用 ffprobe 实测）
  3. 把时长写进 `vo_manifest.json`，渲染器据此决定每个镜头的长度

⚠️ 2026-10-25 实测坑：edge-tts **7.2.8 合成会 403**
    （`WSServerHandshakeError: 403, wss://speech.platform.bing.com/...`），
    但 `--list-voices` 是另一个端点，**能通** ⇒ 表现为"音色列得出来、一合成 403"。
    升级到 **7.3.1** 后恢复。所以本模块启动时会**自检一次合成**，
    失败直接报错并提示升级，不要让它静默产出 0 字节文件。

用法
----
    python promo/video/vo.py --list                 # 列可用中文音色
    python promo/video/vo.py --build                # 按 SCRIPT 生成全部口播
    python promo/video/vo.py --build --voice zh-CN-XiaoxiaoNeural
"""

import argparse
import json
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
PROJECT = os.path.dirname(os.path.dirname(HERE))
OUT = os.path.join(PROJECT, 'docs', '宣发物料', '00_原始素材', '音频', '口播')
MANIFEST = os.path.join(OUT, 'vo_manifest.json')

# 默认音色：晓晓（女声·温暖）—— 用户 2026-10-25 选定
DEFAULT_VOICE = 'zh-CN-XiaoxiaoNeural'
DEFAULT_RATE = '+6%'      # 比默认稍快，宣发片不宜拖

# ── 口播稿（唯一内容源）────────────────────────────────────────────────────
# 每条一个镜头。写完直接 --build，时长自动量出来。
# 写作原则（实测有效）：
#   ① 一句一个信息点，不堆形容词 —— 观众在刷，听不懂就走
#   ② 数字/具体名词 > 抽象吹捧（"四十多种材质" > "超多材质"）
#   ③ 句尾不留长停顿，句间靠画面切点衔接
SCRIPT = [
    dict(id='s1_shelf',
         text='沉浸光感的全新界面。一本书，就是一个世界。'),
    dict(id='s2_material',
         text='四十多种阅读材质，随心搭配。'),
    dict(id='s3_tts',
         text='还能 AI 听书，多音色朗读，眼睛也能歇一歇。'),
]


def _run(cmd):
    return subprocess.run(cmd, capture_output=True, text=True, encoding='utf-8', errors='replace')


def probe_duration(path):
    """ffprobe 实测时长（秒）。文件不存在/空文件返回 None。"""
    if not os.path.exists(path) or os.path.getsize(path) < 1024:
        return None
    r = _run(['ffprobe', '-v', 'error', '-show_entries', 'format=duration',
              '-of', 'csv=p=0', path])
    try:
        return float(r.stdout.strip())
    except (ValueError, AttributeError):
        return None


def synth(text, path, voice=DEFAULT_VOICE, rate=DEFAULT_RATE, pitch='+0Hz'):
    """合成一条口播，返回实测时长；失败抛异常（**不静默产出空文件**）。"""
    os.makedirs(os.path.dirname(path), exist_ok=True)
    if os.path.exists(path):
        os.remove(path)
    r = _run([sys.executable, '-m', 'edge_tts',
              '--voice', voice, f'--rate={rate}', f'--pitch={pitch}',
              '--text', text, '--write-media', path])
    dur = probe_duration(path)
    if dur is None:
        tail = (r.stderr or r.stdout or '').strip().splitlines()
        hint = ''
        if any('403' in ln for ln in tail):
            hint = ('\n  ⇒ 合成端点 403（edge-tts 已知问题）。'
                    '\n    修复：pip install --upgrade edge-tts   （实测 7.2.8 失败 / 7.3.1 正常）')
        raise SystemExit(f'口播合成失败：{os.path.basename(path)}\n  '
                         + '\n  '.join(tail[-3:]) + hint)
    return dur


def build(voice=DEFAULT_VOICE, rate=DEFAULT_RATE):
    os.makedirs(OUT, exist_ok=True)
    manifest = {'voice': voice, 'rate': rate, 'clips': {}}
    total = 0.0
    for item in SCRIPT:
        p = os.path.join(OUT, f'{item["id"]}.mp3')
        dur = synth(item['text'], p, voice, rate)
        manifest['clips'][item['id']] = {
            'path': os.path.relpath(p, PROJECT).replace('\\', '/'),
            'duration': round(dur, 3),
            'text': item['text'],
        }
        total += dur
        print(f'  [ok] {item["id"]:<12} {dur:5.2f}s  {item["text"]}')

    manifest['total'] = round(total, 3)
    with open(MANIFEST, 'w', encoding='utf-8') as f:
        json.dump(manifest, f, ensure_ascii=False, indent=2)
    print(f'\n口播总长 {total:.2f}s  →  {os.path.relpath(MANIFEST, PROJECT)}')
    print('（画面时长将由这些数字反推，见 load_timings()）')
    return manifest


def load_timings(lead=0.55, tail=0.45, min_dur=3.0):
    """读 manifest，给每个镜头算「画面时长」= 口播时长 + 头尾留白。

    `lead` 是开口前的静场（让人先看清画面再听到声音），
    `tail` 是说完后的余韵（不要说完立刻切，会很仓促）。
    """
    if not os.path.exists(MANIFEST):
        raise SystemExit(f'没有口播清单：{MANIFEST}\n  先跑：python promo/video/vo.py --build')
    with open(MANIFEST, encoding='utf-8') as f:
        m = json.load(f)
    out = {}
    for k, v in m['clips'].items():
        out[k] = dict(vo=v['duration'], path=v['path'], text=v['text'],
                      dur=max(min_dur, v['duration'] + lead + tail))
    return out


def main():
    try:
        sys.stdout.reconfigure(encoding='utf-8', errors='replace')
    except Exception:
        pass
    ap = argparse.ArgumentParser()
    ap.add_argument('--list', action='store_true')
    ap.add_argument('--build', action='store_true')
    ap.add_argument('--voice', default=DEFAULT_VOICE)
    ap.add_argument('--rate', default=DEFAULT_RATE)
    args = ap.parse_args()

    if args.list:
        r = _run([sys.executable, '-m', 'edge_tts', '--list-voices'])
        for ln in (r.stdout or '').splitlines():
            if 'zh-CN' in ln:
                print(ln.rstrip())
        return

    if args.build:
        build(args.voice, args.rate)
        return

    # 默认：只做自检（验证 403 问题是否还在），不写文件
    print(f'[自检] 用 {DEFAULT_VOICE} 试合成一个字…')
    tmp = os.path.join(OUT, '_selfcheck.mp3')
    try:
        d = synth('喵', tmp)
        print(f'[自检] OK  合成成功（{d:.2f}s）')
    finally:
        if os.path.exists(tmp):
            os.remove(tmp)


if __name__ == '__main__':
    sys.exit(main())
