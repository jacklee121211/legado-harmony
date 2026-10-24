# -*- coding: utf-8 -*-
"""promo/video/textmotion.py —— 文字动效系统（机身固定不动，运动全在文字上）

用户 2026-10-25 明确要求：
    **「手机不需要动，文字动就行了」**
所以 `motion.py` 的 3D 机身姿态在这一版里**全部关掉**（`Stage3D` 用静止姿态），
所有"活"的东西都在文字层。

这一版的四条运动（缺一条就退回 PPT 观感）
------------------------------------------
1. **逐字入场**：每个字独立上浮 + 淡入，字与字错开 0.06s，
   用 ease-out-cubic（起步快、收尾慢）。这是"有生命感"最直接的来源。
2. **呼吸位移**：整块文字在入场完成后仍然极缓地上下浮动（±3px，多频叠加不循环）。
   ⚠️ 关键：**不能停**。v3 的问题就是文字演完 1.1 秒后画面彻底静止。
3. **强调条生长**：标题下方那条 accent 色横条从 0 长到目标宽度，
   用 ease-out-quint（尾部极慢，显得"稳"）。
4. **副标擦除入场**：副标题按**字符裁剪**从左往右擦出（不是淡入），
   与逐字入场区分开，形成节奏层次。

为什么不用"整块滑入"
--------------------
整块滑入是 PPT 默认动画，观众一眼就认出来是模板。
逐字 + 擦除 + 呼吸三件套的组合才是"人做的"观感。

用法
----
    from textmotion import TextBlock
    tb = TextBlock(title='全新界面', sub='沉浸光感，一本书就是一个世界',
                   accent=(255, 210, 140), canvas=(1080, 1920))
    layer = tb.render(t)          # t = 镜头内时间（秒）
"""

import math
import os
import sys

from PIL import Image, ImageDraw

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

import kit


# ── 呼吸：多频叠加，永不循环 ────────────────────────────────────────────────
# 与 motion.py 同源思路：三个互不通约的频率，合成周期在分钟级
_BREATH_F = (0.115, 0.190, 0.310)
_BREATH_W = (0.60, 0.27, 0.13)


def _breath(t, phases):
    v = 0.0
    for f, w, p in zip(_BREATH_F, _BREATH_W, phases):
        v += w * math.sin(2 * math.pi * f * t + p)
    return v


class TextBlock:
    """一块「标题 + 强调条 + 副标」的动效文字。

    所有静态件（每个字的图、副标图、胶囊）在 __init__ 里一次算好，
    逐帧只做 alpha / 位移 / 裁剪 —— 这是保持 30fps 的关键。
    """

    # ── 版式常量（竖版 1080×1920）──
    MX = 96               # 左边距
    TOP = 116             # 胶囊顶部
    TITLE_PX = 100
    SUB_PX = 42
    CHIP_PX = 28
    GAP_CHIP_TITLE = 26
    GAP_TITLE_BAR = 34
    GAP_BAR_SUB = 30
    BAR_W = 112
    BAR_H = 10

    # ── 动效常量（想调观感改这里）──
    STAGGER = 0.062       # 字与字错开（秒）
    CHAR_IN = 0.52        # 单字入场时长
    CHAR_RISE = 28        # 单字上浮距离（px）
    BREATH_AMP = 5.5      # 整块呼吸幅度（px）
    CHAR_FLOAT = 3.4      # **单字独立浮动幅度**（px）—— 制造"波浪"，这是最有效的灵动信号
    CHAR_PHASE_STEP = 0.72  # 相邻字的相位差（弧度）⇒ 波浪从左往右传
    WIPE_DUR = 0.62       # 副标擦除时长
    BAR_DUR = 0.46        # 强调条生长时长
    BAR_PULSE = 0.14      # 强调条呼吸（宽度比例，±14%）
    SWEEP_DUR = 2.6       # 高光扫过一次的周期（秒）
    SWEEP_ALPHA = 46      # 高光强度（0~255）
    # 文字层的外接区域（只对这一块做亚像素变换，成本远低于整张画布）
    LAYER_BOX = (40, 90, 1040, 640)

    def __init__(self, title, sub, accent, canvas=(1080, 1920),
                 brand='喵阅', brand_sub='HarmonyOS 阅读器', seed=0):
        self.title = title
        self.sub = sub
        self.accent = tuple(accent)
        self.W, self.H = canvas
        self.seed = seed

        # 呼吸相位（由 seed 决定 ⇒ 可复现）
        import random
        rnd = random.Random(seed * 131 + 7)
        self.ph = [rnd.uniform(0, 2 * math.pi) for _ in range(3)]
        self.ph_sub = [rnd.uniform(0, 2 * math.pi) for _ in range(3)]

        # ── 胶囊 ──
        self.chip = kit.chip_img(f'{brand} · {brand_sub}', 'medium', self.CHIP_PX,
                                 (255, 255, 255, 235))

        # ── 标题逐字图 ──
        f = kit.font('bold', self.TITLE_PX)
        probe = ImageDraw.Draw(Image.new('RGBA', (8, 8)))
        self.chars = [kit.text_img(ch, 'bold', self.TITLE_PX, (255, 255, 255, 255))
                      for ch in title]
        self.char_x = []
        x = float(self.MX)
        for ch in title:
            self.char_x.append(x)
            x += probe.textlength(ch, font=f)

        self.title_y = self.TOP + self.chip.size[1] + self.GAP_CHIP_TITLE
        self.bar_y = self.title_y + int(round(self.TITLE_PX * 1.18)) + self.GAP_TITLE_BAR
        self.sub_y = self.bar_y + self.BAR_H + self.GAP_BAR_SUB

        # ── 副标（整条画好，逐帧按字符宽度裁剪 = 擦除）──
        self.sub_img = kit.text_img(sub, 'medium', self.SUB_PX, (255, 255, 255, 232))

        # 文字入场总时长（用于外部决定镜头最短长度）
        self.in_dur = max(
            0.15 + 0.18 + self.STAGGER * max(0, len(title) - 1) + self.CHAR_IN,
            0.15 + 0.55 + self.BAR_DUR + 0.18 + self.WIPE_DUR,
        )

    # ── 单帧 ────────────────────────────────────────────────────────────────
    def render(self, t, base=None):
        """返回叠好文字的一层 RGBA（画布大小）。`base` 给了就直接合成上去。

        ⚠️ 两个实测坑（2026-10-25，都是"看起来在动其实没动"）
        ------------------------------------------------------
        ① **亚像素被取整抹平**：呼吸 5.5px / 0.115Hz ⇒ 每帧只走 0.13px。
           直接 `int(round(y))` 会把它抹成 0，自检实测 **97 帧里 49 帧零变化**。
           ⇒ 先在整数坐标画，再对图层做**浮点 AFFINE 平移**（BILINEAR 天然支持亚像素）。
        ② **只有整块呼吸 = 看不出来**：实测入场后文字区运动能量只有 0.10~0.24，
           13s 处掉到 0.036 —— 肉眼等同静止。
           ⇒ 必须加**单字独立浮动**（相邻字相位差 0.72rad，形成从左往右的波浪）
             + **高光扫过**（2.6s 一轮）。这两项才是"灵动"真正被看见的部分。
        """
        W, H = self.W, self.H
        bx0, by0, bx1, by1 = self.LAYER_BOX
        lw, lh = bx1 - bx0, by1 - by0

        # 整块呼吸（浮点）
        by = self.BREATH_AMP * _breath(t, self.ph)
        by_sub = self.BREATH_AMP * 0.72 * _breath(t, self.ph_sub)

        small = Image.new('RGBA', (lw, lh), (0, 0, 0, 0))

        # ① 胶囊
        t0 = 0.15
        a = kit.clamp01(kit.span(t, t0, t0 + 0.45))
        if a > 0:
            e = kit.ease_out_cubic(a)
            small.alpha_composite(kit.set_alpha(self.chip, a),
                                  (self.MX - bx0,
                                   self.TOP - by0 + int(round(14 * (1 - e)))))

        # ② 标题：逐字入场 + **逐字独立浮动**
        for i, ch in enumerate(self.chars):
            s0 = t0 + 0.18 + self.STAGGER * i
            a = kit.clamp01(kit.span(t, s0, s0 + self.CHAR_IN))
            if a <= 0:
                continue
            e = kit.ease_out_cubic(a)

            # 单字浮动：入场完成后逐渐"接管"（入场时以 RISE 为主，之后以 float 为主）
            fl = self.CHAR_FLOAT * math.sin(
                2 * math.pi * 0.145 * t + self.ph[0] + i * self.CHAR_PHASE_STEP)
            fl += self.CHAR_FLOAT * 0.45 * math.sin(
                2 * math.pi * 0.238 * t + self.ph[1] + i * self.CHAR_PHASE_STEP * 1.7)
            rise = self.CHAR_RISE * (1 - e)
            dy_char = rise + fl * e          # 入场期间 fl 被 e 淡入，避免一开始就抖

            img = kit.set_alpha(ch, a)
            cx = int(round(self.char_x[i])) - bx0
            cy = self.title_y - by0
            if abs(dy_char) > 0.01:
                img = self._shift(img, 0.0, dy_char)
            small.alpha_composite(img, (cx, cy))

        # ③ 强调条：长出 + 极缓呼吸
        s0 = t0 + 0.55
        g = kit.ease_out_quint(kit.span(t, s0, s0 + self.BAR_DUR))
        if g > 0:
            pulse = 1.0 + self.BAR_PULSE * math.sin(2 * math.pi * 0.175 * t + self.ph[2])
            bw = max(2, int(round(self.BAR_W * g * pulse)))
            small.alpha_composite(
                Image.new('RGBA', (bw, self.BAR_H), self.accent + (255,)),
                (self.MX - bx0, self.bar_y - by0))

        # ④ 副标：擦出
        s0 = t0 + 0.55 + self.BAR_DUR + 0.18
        p = kit.ease_out_cubic(kit.clamp01(kit.span(t, s0, s0 + self.WIPE_DUR)))
        if p > 0:
            sw, sh = self.sub_img.size
            cut = max(1, int(round(sw * p)))
            small.alpha_composite(self.sub_img.crop((0, 0, cut, sh)),
                                  (self.MX - bx0, self.sub_y - by0))

        # ⑤ 高光扫过（一轮 2.6s，斜向白光从左掠到右）—— 这是"贵感"的来源
        small = self._sweep(small, t, lw, lh)

        # ⑥ 整块呼吸（亚像素）
        moved = self._shift(small, 0.0, by)
        d_sub = by_sub - by
        if abs(d_sub) > 0.01:
            y0 = max(0, self.sub_y - by0 - 6)
            y1 = min(lh, y0 + self.sub_img.size[1] + 12)
            if y1 > y0:
                band = moved.crop((0, y0, lw, y1))
                moved.paste((0, 0, 0, 0), (0, y0, lw, y1))
                moved.alpha_composite(self._shift(band, 0.0, d_sub), (0, y0))

        out_layer = Image.new('RGBA', (W, H), (0, 0, 0, 0))
        out_layer.paste(moved, (bx0, by0), moved)

        if base is None:
            return out_layer
        return Image.alpha_composite(base.convert('RGBA'), out_layer)

    def _sweep(self, layer, t, lw, lh):
        """斜向高光扫过：只在文字已有像素的地方加亮（用 alpha 做遮罩，不会糊到背景）。"""
        cyc = self.SWEEP_DUR
        p = (t % cyc) / cyc
        # 只在周期的前 55% 扫，剩下 45% 留白 —— 连续扫会像跑马灯
        if p > 0.55:
            return layer
        u = p / 0.55
        band_w = int(lw * 0.26)
        x = int(round(kit.lerp(-band_w, lw, u)))

        grad = Image.new('L', (band_w, lh), 0)
        gd = ImageDraw.Draw(grad)
        for k in range(band_w):
            # 三角窗，中心最亮
            v = int(self.SWEEP_ALPHA * (1 - abs(k - band_w / 2) / (band_w / 2)))
            gd.line([(k, 0), (k, lh)], fill=max(0, v))
        # 倾斜：整体错切，形成斜光
        grad = grad.transform((band_w, lh), Image.AFFINE,
                              (1.0, 0.42, 0.0, 0.0, 1.0, 0.0), Image.BILINEAR)

        # 只在文字 alpha 区域生效
        src_a = layer.getchannel('A')
        mask = Image.new('L', (lw, lh), 0)
        mask.paste(grad, (x, 0))
        mask = Image.composite(mask, Image.new('L', (lw, lh), 0), src_a)

        white = Image.new('RGBA', (lw, lh), (255, 255, 255, 0))
        white.putalpha(mask)
        return Image.alpha_composite(layer, white)

    @staticmethod
    def _shift(img, dx, dy):
        """浮点平移（亚像素）。PIL 的 AFFINE 支持浮点系数 + BILINEAR 采样。"""
        if abs(dx) < 1e-3 and abs(dy) < 1e-3:
            return img
        return img.transform(img.size, Image.AFFINE,
                             (1.0, 0.0, -dx, 0.0, 1.0, -dy), Image.BILINEAR)

    def progress(self, t):
        """返回 0~1 的入场完成度（调试/外部对齐用）。"""
        return kit.clamp01(t / max(self.in_dur, 1e-6))


# ── 自检 ────────────────────────────────────────────────────────────────────

if __name__ == '__main__':
    try:
        sys.stdout.reconfigure(encoding='utf-8', errors='replace')
    except Exception:
        pass

    tb = TextBlock('全新界面', '沉浸光感，一本书就是一个世界', (255, 210, 140), seed=11)
    print(f'入场总时长 = {tb.in_dur:.2f}s')

    # 逐帧检查：文字区域（y 100..600）的运动量
    import numpy as np
    prev = None
    rows = []
    for i in range(int(tb.in_dur * 30) + 40):
        t = i / 30.0
        im = tb.render(t).crop((0, 100, 1080, 620)).convert('L')
        a = np.asarray(im, dtype=np.float32)
        if prev is not None:
            rows.append(float(np.abs(a - prev).mean()))
        prev = a
    rows = np.array(rows)
    print(f'文字区运动能量: 均值={rows.mean():.2f}  '
          f'最小={rows.min():.4f}  零变化帧={int((rows < 1e-4).sum())}/{len(rows)}')
    print(f'入场后（{tb.in_dur:.1f}s 之后）仍在动: '
          f'均值={rows[int(tb.in_dur*30):].mean():.2f}  '
          f'最小={rows[int(tb.in_dur*30):].min():.4f}')
