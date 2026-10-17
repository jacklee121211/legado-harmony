# -*- coding: utf-8 -*-
"""promo/video/render.py —— 分镜表 → MP4（9:16 竖版 / 16:9 横版，同一份分镜）

用法
----
    # 单场景预览（先看静帧，最省时间）
    python promo/video/render.py --scene 01_light --ratio 9:16 --still 1.8

    # 渲染一个场景
    python promo/video/render.py --scene 01_light --ratio 9:16

    # 全片（后续阶段：拼接 + 转场 + 配乐）
    python promo/video/render.py --all --ratio 16:9

版式（关键设计）
----------------
**两套版式，不是把 9:16 缩放成 16:9。**
  9:16 → 文案在顶部 1/4，手机居中偏下，底部留安全边
  16:9 → 文案在左，手机在右；文案块垂直居中
同一份 `scenes.SCENES` 数据驱动两套版式，改一处两边同步，不会走样。
"""

import argparse
import os
import subprocess
import sys
import time

from PIL import Image, ImageDraw, ImageFilter

# 控制台中文路径可读（PowerShell 默认按代码页编码外部输出，会糊成方块）
try:
    sys.stdout.reconfigure(encoding='utf-8', errors='replace')
except Exception:
    pass

import kit
import scenes as SCN

ROOT = os.path.dirname(os.path.abspath(__file__))
PROMO = os.path.dirname(ROOT)
SRC = os.path.join(PROMO, 'src')

# ── 物料根目录（用户自录素材放这里，优先于 promo/src 旧归档）─────────────────
#     docs/宣发物料/00_原始素材/截图/xxx.png  →  找不到再回落到 promo/src/xxx.png
MATERIAL_ROOT = os.path.join(os.path.dirname(PROMO), 'docs', '宣发物料')
SHOT_DIR = os.path.join(MATERIAL_ROOT, '00_原始素材', '截图')
OUT = os.path.join(MATERIAL_ROOT, '02_成片')

FPS = 30

# 系统信息栏占屏高的比例（实测：1320×2848 裁 128 → 0.0449；890×1920 裁 86 → 0.0448）
# ⇒ 所有素材（静帧截图 / 录屏）**统一裁掉同样比例**，得到同一个 App 画布，比例 0.4853
SYSTEM_BAR_RATIO = 0.0449


def expand_box(box, aspect, size):
    """把兴趣区**向外扩**到目标宽高比（不裁掉兴趣区内的任何内容）。

    为什么不用 cover：实测（2026-10-17）03_font 的 crop 比例 0.553，cover 裁到 0.485
    会把左侧「字号/行距」标签切掉一半。往外扩只会多带一点上下文，不会切内容。
    """
    x0, y0, x1, y1 = box
    w, h = x1 - x0, y1 - y0
    W, H = size
    if w / h > aspect:
        nh = w / aspect
        cy = (y0 + y1) / 2.0
        y0, y1 = cy - nh / 2.0, cy + nh / 2.0
    else:
        nw = h * aspect
        cx = (x0 + x1) / 2.0
        x0, x1 = cx - nw / 2.0, cx + nw / 2.0
    # 夹回画布内（先平移，仍超界再压缩）
    if x0 < 0:
        x1 -= x0
        x0 = 0
    if x1 > W:
        x0 -= (x1 - W)
        x1 = W
    if y0 < 0:
        y1 -= y0
        y0 = 0
    if y1 > H:
        y0 -= (y1 - H)
        y1 = H
    x0, y0 = max(0, x0), max(0, y0)
    x1, y1 = min(W, x1), min(H, y1)
    return int(round(x0)), int(round(y0)), int(round(x1)), int(round(y1))


def resolve_src(name):
    """素材查找：先新物料目录，再旧的 promo/src 归档。找不到直接报错并列出两处路径。"""
    for d in (SHOT_DIR, SRC):
        p = os.path.join(d, name)
        if os.path.exists(p):
            return p
    raise SystemExit(f'找不到素材 {name}\n  查过：{SHOT_DIR}\n  查过：{SRC}')


# ── 版式 ────────────────────────────────────────────────────────────────────

def layout(ratio):
    if ratio == '9:16':
        return dict(
            canvas=(1080, 1920), mx=96,
            block_top=116,
            title_px=100, sub_px=42, chip_px=28,
            gap_chip_title=26, gap_title_bar=34, gap_bar_sub=30,
            bar_w=112, bar_h=10,
            phone_screen_w=620,
            phone_anchor='bottom', phone_bottom=64,
            blurb=None,
        )
    if ratio == '16:9':
        return dict(
            canvas=(1920, 1080), mx=150,
            block_top=352,
            title_px=112, sub_px=46, chip_px=30,
            gap_chip_title=28, gap_title_bar=38, gap_bar_sub=34,
            bar_w=124, bar_h=11,
            phone_screen_h=900,
            phone_anchor='right', phone_right=168,
            blurb=None,
        )
    raise SystemExit('ratio 只支持 9:16 / 16:9')


class SceneRenderer:
    def __init__(self, scene, ratio):
        self.s = scene
        self.ratio = ratio
        self.L = layout(ratio)
        W, H = self.L['canvas']
        self.W, self.H = W, H

        # 背景（一次算好）
        self.bg = kit.make_background((W, H), scene['c1'], scene['c2'],
                                      scene['accent'], blur_scale=W / 1080.0)

        # 源图（像素不改，只裁切）：先统一裁掉系统信息栏，再取场景兴趣区
        raw = Image.open(resolve_src(scene['src'])).convert('RGB')
        cut = int(round(raw.size[1] * SYSTEM_BAR_RATIO))
        self.full = raw.crop((0, cut, raw.size[0], raw.size[1]))
        self.canvas_aspect = self.full.size[0] / self.full.size[1]

        if scene.get('crop'):
            x0, y0, x1, y1 = scene['crop']
            y0 = max(0, y0 - cut)
            y1 = min(self.full.size[1], y1 - cut)
            box = expand_box((x0, y0, x1, y1), self.canvas_aspect, self.full.size)
            self.crop = self.full.crop(box)
        else:
            self.crop = self.full

        # 手机样机：形状**恒为画布比例**，保证每个场景的机框轮廓一致；不画灵动岛
        if ratio == '9:16':
            sw = self.L['phone_screen_w']
            sh = int(round(sw / self.canvas_aspect))
        else:
            sh = self.L['phone_screen_h']
            sw = int(round(sh * self.canvas_aspect))
        self.phone = kit.Phone(sw, sh, island=False)
        self.sw, self.sh = self.phone.screen_box[2] - self.phone.screen_box[0], \
            self.phone.screen_box[3] - self.phone.screen_box[1]

        # 手机落位
        pw, ph = self.phone.size
        if ratio == '9:16':
            self.px = (W - pw) // 2
            self.py = H - self.L['phone_bottom'] - ph
        else:
            self.px = W - self.L['phone_right'] - pw
            self.py = (H - ph) // 2

        # 文案件（一次算好，逐帧只调 alpha / 位移）
        self._build_text()

    # ── 文案 ────────────────────────────────────────────────────────────────
    def _build_text(self):
        L, s, W = self.L, self.s, self.W
        d = ImageDraw.Draw(Image.new('RGBA', (8, 8)))
        y = L['block_top']

        self.chip = kit.chip_img(f'{SCN.BRAND} · {SCN.BRAND_SUB}', 'medium', L['chip_px'],
                                 (255, 255, 255, 235))
        self.chip_pos = (L['mx'], y)
        y += self.chip.size[1] + L['gap_chip_title']

        self.title_y = y
        f = kit.font('bold', L['title_px'])
        self.title_chars = [kit.text_img(ch, 'bold', L['title_px'], (255, 255, 255, 255))
                            for ch in s['title']]
        adv = d.textlength('国', font=f)
        widths = [d.textlength(ch, font=f) for ch in s['title']]
        total = sum(widths)
        x = L['mx']
        self.char_dx = []
        for w in widths:
            self.char_dx.append(x)
            x += w
        # 用真实字宽排布 ⇒ 不同字数也能居中/左对齐一致
        self.char_adv = widths
        y += int(round(L['title_px'] * 1.18))

        self.bar_y = y + L['gap_title_bar']
        y = self.bar_y + L['bar_h'] + L['gap_bar_sub']

        self.sub = kit.text_img(s['sub'], 'medium', L['sub_px'], (255, 255, 255, 232))
        self.sub_pos = (L['mx'], y)
        self.block_end = y + self.sub.size[1]

    # ── 单帧 ────────────────────────────────────────────────────────────────
    def frame(self, t, dur):
        W, H = self.W, self.H
        canvas = self.bg.copy()

        # ① 手机：入场（上浮 + 淡入）+ 极缓呼吸位移
        p_in = kit.ease_out_expo(kit.span(t, 0.10, 0.95))
        a_phone = kit.clamp01(kit.span(t, 0.06, 0.42))
        rise = int(round(kit.lerp(58, 0, p_in)))
        float_y = int(round(5 * __import__('math').sin(2 * 3.14159 * (t / max(dur, 1e-6)))))

        # ② 屏幕内容 Ken Burns
        #    ⚠️ 实测坑（2026-10-17）：整屏镜头只要推一点点，就会把**顶部状态栏**或
        #    **底部 dock 文字**推出屏幕，而机框是静止的 ⇒ 观感是"UI 被切坏了"。
        #    整屏素材上 UI 一直画到屏幕最上/最下沿，没有可让位的空白 ⇒ 整屏一律不推（z=1.0），
        #    画面"活"起来靠机身上浮 + 文字入场 + 场景转场。
        #    裁切镜头（crop 明确指定了兴趣区）才可以推，因为框外本来就不是我们要展示的内容。
        z_end = self.s.get('zoom', 1.0 if self.s.get('crop') is None else 1.10)
        z = kit.lerp(1.00, z_end, kit.clamp01(t / max(dur, 1e-6)) ** 0.85)
        fx, fy = self.s['focus']
        drift = kit.lerp(-0.012, 0.012, kit.clamp01(t / max(dur, 1e-6)))
        content = self._kenburns(z, fx + drift, fy)

        dev = self.phone.compose(content)
        if a_phone < 1.0:
            dev = kit.set_alpha(dev, a_phone)
        canvas.paste(dev, (self.px, self.py + rise + float_y), dev)

        # ③ 文案层
        txt = Image.new('RGBA', (W, H), (0, 0, 0, 0))

        a = kit.clamp01(kit.span(t, 0.16, 0.46))
        if a > 0:
            e = kit.ease_out_cubic(a)
            img = kit.set_alpha(self.chip, a)
            txt.alpha_composite(img, (self.chip_pos[0], self.chip_pos[1] + int(round(14 * (1 - e)))))

        for i, ch in enumerate(self.title_chars):
            s0 = 0.30 + 0.058 * i
            a = kit.clamp01(kit.span(t, s0, s0 + 0.44))
            if a <= 0:
                continue
            e = kit.ease_out_cubic(a)
            img = kit.set_alpha(ch, a)
            txt.alpha_composite(img, (int(round(self.char_dx[i])),
                                      self.title_y + int(round(26 * (1 - e)))))

        # 强调条：从左往右长出
        g = kit.ease_out_quint(kit.span(t, 0.60, 1.05))
        if g > 0:
            bw = max(2, int(round(self.L['bar_w'] * g)))
            bar = Image.new('RGBA', (bw, self.L['bar_h']), tuple(self.s['accent']) + (255,))
            txt.alpha_composite(bar, (self.L['mx'], self.bar_y))

        a = kit.clamp01(kit.span(t, 0.66, 1.02))
        if a > 0:
            e = kit.ease_out_cubic(a)
            img = kit.set_alpha(self.sub, a)
            txt.alpha_composite(img, (self.sub_pos[0], self.sub_pos[1] + int(round(20 * (1 - e)))))

        canvas = Image.alpha_composite(canvas.convert('RGBA'), txt).convert('RGB')

        # ④ 首尾黑场（拼接成片时用转场，逐场景可关：scene 里设 fade_in/fade_out=False）
        fade = 1.0
        if self.s.get('fade_in', True):
            fade *= kit.clamp01(kit.span(t, 0.0, 0.22))
        if self.s.get('fade_out', True):
            fade *= 1.0 - kit.clamp01(kit.span(t, dur - 0.30, dur))
        if fade < 0.999:
            canvas = Image.blend(Image.new('RGB', (W, H), (0, 0, 0)), canvas, fade)
        return canvas

    def _kenburns(self, z, fx, fy):
        w0, h0 = self.crop.size
        zw, zh = w0 / z, h0 / z
        cx, cy = fx * w0, fy * h0
        x = min(max(cx - zw / 2, 0), w0 - zw)
        y = min(max(cy - zh / 2, 0), h0 - zh)
        box = (int(round(x)), int(round(y)), int(round(x + zw)), int(round(y + zh)))
        return self.crop.crop(box).resize((self.sw, self.sh), Image.LANCZOS)


# ── 输出 ────────────────────────────────────────────────────────────────────

def encode(frames_iter, canvas, out_path, fps):
    W, H = canvas
    os.makedirs(os.path.dirname(out_path) or '.', exist_ok=True)
    cmd = [
        'ffmpeg', '-y', '-v', 'error',
        '-f', 'rawvideo', '-pix_fmt', 'rgb24', '-s', f'{W}x{H}', '-r', str(fps), '-i', '-',
        '-vf', 'format=yuv420p',
        '-c:v', 'libx264', '-preset', 'slow', '-crf', '17',
        '-movflags', '+faststart', out_path,
    ]
    proc = subprocess.Popen(cmd, stdin=subprocess.PIPE)
    n = 0
    try:
        for im in frames_iter:
            proc.stdin.write(im.tobytes())
            n += 1
            if n % 45 == 0:
                print(f'  frame {n}', flush=True)
    finally:
        proc.stdin.close()
        proc.wait()
    if proc.returncode != 0:
        raise SystemExit(f'ffmpeg 失败，code={proc.returncode}')
    return n


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--scene', default='01_light')
    ap.add_argument('--all', action='store_true')
    ap.add_argument('--ratio', default='9:16', choices=['9:16', '16:9'])
    ap.add_argument('--fps', type=int, default=FPS)
    ap.add_argument('--dur', type=float, default=None, help='覆盖分镜时长（预览用）')
    ap.add_argument('--still', type=float, default=None, help='只出一张静帧（秒），不编码')
    ap.add_argument('--name', default=None, help='输出文件名（不含扩展名）')
    ap.add_argument('--font', default=None, choices=['sourcehan', 'harmony'],
                    help='强制字体族；默认优先用 00_原始素材/字体/ 下的思源黑体')
    args = ap.parse_args()

    if args.font:
        kit._resolve_fonts(args.font)
    print('[font] ' + ' / '.join(f'{k}={v[0]}({v[1]})' for k, v in kit.FONT_NAMES.items()))

    targets = SCN.SCENES if args.all else [SCN.SCENE_BY_ID[args.scene]]
    os.makedirs(OUT, exist_ok=True)

    for s in targets:
        dur = args.dur or s['dur']
        r = SceneRenderer(s, args.ratio)
        tag = args.ratio.replace(':', 'x')

        if args.still is not None:
            t0 = time.time()
            im = r.frame(args.still, dur)
            p = os.path.join(OUT, f'still_{s["id"]}_{tag}.png')
            im.save(p)
            print(f'[still] {p}  ({im.size[0]}x{im.size[1]})  {time.time() - t0:.2f}s')
            continue

        name = args.name or f'{s["id"]}_{tag}'
        out = os.path.join(OUT, f'{name}.mp4')
        n = int(round(dur * args.fps))
        t0 = time.time()
        print(f'[render] {s["id"]} {args.ratio}  {n} frames @ {args.fps}fps -> {out}')
        got = encode((r.frame(i / args.fps, dur) for i in range(n)), r.L['canvas'], out, args.fps)
        print(f'[done] {got} frames  {time.time() - t0:.1f}s  {out}')


if __name__ == '__main__':
    sys.exit(main())
