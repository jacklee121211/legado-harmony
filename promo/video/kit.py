# -*- coding: utf-8 -*-
"""promo/video/kit.py —— 视频渲染基础件：缓动 / 背景 / 手机外框 / 文字元素

设计原则（与 make_posters.py 一脉相承）：
  1. **截图像素不改**：只做裁切 + 圆角 + 描边，UI 里的小字不会被画糊；
  2. 半透明元素必须画在独立图层再 `alpha_composite`
     —— ImageDraw 直接画带 alpha 的颜色是**替换像素**、不参与混合（make_posters.py 文件头铁律）；
  3. 每帧的开销要可控：**静态件一次算好、逐帧只做合成**，
     唯一需要逐帧变的"内容缩放"用「预放大源图 + 逐帧整数裁切」，避免每帧 LANCZOS 重采样。
"""

import os

import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageFont

FONT_DIR = r'C:\Windows\Fonts'
# 用户自备字体优先放这里（思源黑体 SIL OFL 1.1，商用最干净）
USER_FONT_DIR = os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(
    os.path.abspath(__file__)))), 'docs', '宣发物料', '00_原始素材', '字体')

# 每个字重按顺序尝试，第一个存在的胜出
_FONT_CANDIDATES = {
    'bold': [
        ('Source Han Sans', 'SourceHanSansSC-Bold.otf'),
        ('Source Han Sans', 'SourceHanSansSC-Bold.otf.otf'),
        ('HarmonyOS Sans', 'HarmonyOS_Sans_SC_Bold.ttf'),
    ],
    'medium': [
        ('Source Han Sans', 'SourceHanSansSC-Medium.otf'),
        ('HarmonyOS Sans', 'HarmonyOS_Sans_SC_Medium.ttf'),
    ],
    'regular': [
        ('Source Han Sans', 'SourceHanSansSC-Regular.otf'),
        ('HarmonyOS Sans', 'HarmonyOS_Sans_SC_Regular.ttf'),
    ],
}

FONTS = {}          # weight -> 实际文件路径
FONT_NAMES = {}     # weight -> (族名, 文件名)，打印用


def _resolve_fonts(force=None):
    """字体解析：用户字体目录优先 → 系统字体目录。

    `force='sourcehan' | 'harmony'` 可强制族（族名过滤），默认自动（谁先找到用谁）。
    """
    FONTS.clear()
    FONT_NAMES.clear()
    for weight, cands in _FONT_CANDIDATES.items():
        pool = list(cands)
        if force == 'sourcehan':
            pool = [c for c in pool if 'Source' in c[0]]
        elif force == 'harmony':
            pool = [c for c in pool if 'HarmonyOS' in c[0]]
        for family, name in pool:
            for base in (USER_FONT_DIR, FONT_DIR):
                p = os.path.join(base, name)
                if os.path.exists(p):
                    FONTS[weight] = p
                    FONT_NAMES[weight] = (family, name)
                    break
            if weight in FONTS:
                break
        if weight not in FONTS:
            raise SystemExit(f'找不到字体：{weight}（查过 {USER_FONT_DIR} 与 {FONT_DIR}）')
    _font_cache.clear()


_font_cache = {}


def font(kind, size):
    key = (kind, int(size))
    if key not in _font_cache:
        _font_cache[key] = ImageFont.truetype(FONTS[kind], int(size))
    return _font_cache[key]


_resolve_fonts()


# ── 缓动 ────────────────────────────────────────────────────────────────────

def clamp01(t):
    return 0.0 if t < 0 else (1.0 if t > 1 else t)


def lerp(a, b, t):
    return a + (b - a) * t


def ease_out_cubic(t):
    t = clamp01(t)
    return 1 - (1 - t) ** 3


def ease_in_out_cubic(t):
    t = clamp01(t)
    return 4 * t ** 3 if t < 0.5 else 1 - ((-2 * t + 2) ** 3) / 2


def ease_out_expo(t):
    t = clamp01(t)
    return 1.0 if t >= 1 else 1 - 2 ** (-10 * t)


def ease_out_quint(t):
    t = clamp01(t)
    return 1 - (1 - t) ** 5


def span(t, a, b):
    """把全局时间 t 映射到 [a,b] 区间的 0→1 进度（区间外自动夹紧）。"""
    if b <= a:
        return 1.0 if t >= b else 0.0
    return clamp01((t - a) / (b - a))


# ── 背景件（一次算好，全片复用）────────────────────────────────────────────

def diagonal_gradient(size, c1, c2, angle=(1.0, 0.55)):
    """斜向渐变：numpy 双线性直算，任意尺寸都平滑、无接缝。"""
    W, H = size
    ax, ay = angle
    xx = np.linspace(0.0, 1.0, W, dtype=np.float32)[None, :]
    yy = np.linspace(0.0, 1.0, H, dtype=np.float32)[:, None]
    t = np.clip((ax * xx + ay * yy) / (ax + ay), 0.0, 1.0)
    arr = np.zeros((H, W, 3), np.uint8)
    for i in range(3):
        arr[:, :, i] = (c1[i] + (c2[i] - c1[i]) * t).astype(np.uint8)
    return Image.fromarray(arr, 'RGB')


def glow_layer(size, blobs, blur):
    """柔光光斑：blobs = [(cx, cy, rx, ry, (r,g,b), alpha), ...]（均为画布比例坐标）。"""
    W, H = size
    layer = Image.new('RGBA', size, (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    for cx, cy, rx, ry, color, alpha in blobs:
        d.ellipse(((cx - rx) * W, (cy - ry) * H, (cx + rx) * W, (cy + ry) * H),
                  fill=tuple(color) + (alpha,))
    return layer.filter(ImageFilter.GaussianBlur(blur))


def noise_layer(size, strength=9):
    n = Image.effect_noise(size, 22).convert('L').point(lambda v: int(v * strength / 255))
    layer = Image.new('RGBA', size, (255, 255, 255, 0))
    layer.putalpha(n)
    return layer


def vignette_layer(size, strength=0.34, power=2.4):
    W, H = size
    yy, xx = np.mgrid[0:H, 0:W].astype(np.float32)
    r = np.sqrt(((xx - W / 2) / (W / 2)) ** 2 + ((yy - H / 2) / (H / 2)) ** 2) / np.sqrt(2.0)
    a = (np.clip(r, 0.0, 1.0) ** power * strength * 255).astype(np.uint8)
    layer = Image.new('RGBA', size, (0, 0, 0, 0))
    layer.putalpha(Image.fromarray(a))
    return layer


def make_background(size, c1, c2, accent, blur_scale):
    """渐变 + 两团柔光 + 细噪点 + 暗角，合成一张不透明的背景。"""
    W, H = size
    bg = diagonal_gradient(size, c1, c2).convert('RGBA')
    blobs = [
        (0.95, 0.18, 0.42, 0.24, accent, 120),
        (0.08, 0.60, 0.40, 0.26, accent, 62),
    ]
    bg = Image.alpha_composite(bg, glow_layer(size, blobs, int(150 * blur_scale)))
    bg = Image.alpha_composite(bg, noise_layer(size))
    bg = Image.alpha_composite(bg, vignette_layer(size))
    return bg.convert('RGB')


# ── 手机外框 ────────────────────────────────────────────────────────────────

class Phone:
    """按"屏幕宽高"生成一台手机样机（机身 + 屏幕裁切 mask + 灵动岛 + 玻璃高光）。

    坐标系：整张图左上角为原点，`.screen_box` 给出屏幕在其中的位置。
    屏幕区域在 `.body` 里是**透明**的，所以机身可以叠在任何内容上。
    """

    PAD_RATIO = 0.012      # 外扩留白（侧键用）
    BEZEL_RATIO = 0.030    # 边框宽 / 屏幕宽
    SCREEN_R_RATIO = 0.082  # 屏幕圆角 / 屏幕宽

    def __init__(self, screen_w, screen_h):
        sw, sh = int(round(screen_w)), int(round(screen_h))
        bezel = max(3, int(round(sw * self.BEZEL_RATIO)))
        pad = max(3, int(round(sw * self.PAD_RATIO)))
        r_screen = int(round(sw * self.SCREEN_R_RATIO))
        r_body = r_screen + bezel

        ox, oy = pad + bezel, pad + bezel
        self.screen_box = (ox, oy, ox + sw, oy + sh)
        self.size = (sw + 2 * (pad + bezel), sh + 2 * (pad + bezel))

        # 屏幕 mask（圆角矩形）
        mask = Image.new('L', (sw, sh), 0)
        ImageDraw.Draw(mask).rounded_rectangle((0, 0, sw - 1, sh - 1), r_screen, fill=255)
        self.screen_mask = mask

        # 机身：外圈圆角矩形挖掉屏幕，得到"边框圈"
        W, H = self.size
        body = Image.new('RGBA', (W, H), (0, 0, 0, 0))
        d = ImageDraw.Draw(body)
        d.rounded_rectangle((pad, pad, pad + sw + 2 * bezel - 1, pad + sh + 2 * bezel - 1),
                            r_body, fill=(18, 18, 21, 255))
        # 外沿高光（金属感）
        d.rounded_rectangle((pad, pad, pad + sw + 2 * bezel - 1, pad + sh + 2 * bezel - 1),
                            r_body, outline=(120, 122, 130, 190), width=max(1, bezel // 6))
        # 屏幕挖孔
        d.rounded_rectangle((ox, oy, ox + sw - 1, oy + sh - 1), r_screen, fill=(0, 0, 0, 0))
        # 内沿一圈高光（屏幕玻璃边缘）
        d.rounded_rectangle((ox - 1, oy - 1, ox + sw, oy + sh), r_screen + 1,
                            outline=(255, 255, 255, 46), width=1)

        # 侧键（右侧电源 + 左侧音量）
        btn_w = max(2, int(round(sw * 0.007)))
        btn_c = (58, 60, 66, 255)
        by = oy + int(sh * 0.22)
        d.rounded_rectangle((pad + sw + 2 * bezel - 1, by, pad + sw + 2 * bezel + btn_w, by + int(sh * 0.10)),
                            btn_w, fill=btn_c)
        vy = oy + int(sh * 0.20)
        for k in range(2):
            d.rounded_rectangle((pad - btn_w, vy + k * int(sh * 0.062), pad, vy + k * int(sh * 0.062) + int(sh * 0.048)),
                                btn_w, fill=btn_c)
        self.body = body

        # 灵动岛
        iw, ih = int(sw * 0.235), max(6, int(sh * 0.0295))
        ix = ox + (sw - iw) // 2
        iy = oy + int(sh * 0.0125)
        self.island = (ix, iy, iw, ih)

        # 玻璃高光（斜向白色低透明渐变，只铺在屏幕区）
        gloss = Image.new('RGBA', (sw, sh), (0, 0, 0, 0))
        gd = ImageDraw.Draw(gloss)
        gd.polygon([(0, 0), (int(sw * 0.55), 0), (0, int(sh * 0.42))], fill=(255, 255, 255, 16))
        gloss = gloss.filter(ImageFilter.GaussianBlur(max(2, sw // 60)))
        gloss.putalpha(Image.composite(gloss.getchannel('A'), Image.new('L', (sw, sh), 0), mask))
        self.gloss = gloss

    def compose(self, content):
        """content = 与屏幕等尺寸的图；返回整台手机（RGBA）。"""
        sw, sh = self.screen_box[2] - self.screen_box[0], self.screen_box[3] - self.screen_box[1]
        shot = content.convert('RGB')
        if shot.size != (sw, sh):
            shot = shot.resize((sw, sh), Image.LANCZOS)
        screen = Image.alpha_composite(shot.convert('RGBA'), self.gloss)
        out = self.body.copy()
        out.paste(screen, (self.screen_box[0], self.screen_box[1]), self.screen_mask)
        d = ImageDraw.Draw(out)
        ix, iy, iw, ih = self.island
        d.rounded_rectangle((ix, iy, ix + iw, iy + ih), ih // 2, fill=(0, 0, 0, 255))
        d.ellipse((ix + iw - ih - 2, iy + ih // 2 - ih // 5, ix + iw - 2, iy + ih // 2 + ih // 5),
                  fill=(26, 26, 30, 255))
        return out


# ── 文字件 ──────────────────────────────────────────────────────────────────

def set_alpha(img, a):
    """整层等比调 alpha（用于淡入淡出）。a=1 时原图返回，零拷贝。"""
    if a >= 0.999:
        return img
    a = clamp01(a)
    r, g, b, al = img.split()
    al = al.point(lambda v: int(v * a))
    return Image.merge('RGBA', (r, g, b, al))


def text_img(text, kind, size, color, stroke=0, stroke_fill=None):
    """把一行字画成紧贴字形的 RGBA（便于精确排版 + 逐帧位移）。"""
    f = font(kind, size)
    probe = ImageDraw.Draw(Image.new('RGBA', (8, 8)))
    box = probe.textbbox((0, 0), text, font=f, stroke_width=stroke)
    w, h = box[2] - box[0], box[3] - box[1]
    img = Image.new('RGBA', (max(1, w + 2), max(1, h + 2)), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    d.text((1 - box[0], 1 - box[1]), text, font=f, fill=color,
           stroke_width=stroke, stroke_fill=stroke_fill)
    return img


def chip_img(text, kind, size, fg, bg_alpha=42, border_alpha=90, pad_x=None, pad_y=None):
    """胶囊标签（品牌角标）。"""
    f = font(kind, size)
    probe = ImageDraw.Draw(Image.new('RGBA', (8, 8)))
    box = probe.textbbox((0, 0), text, font=f)
    tw, th = box[2] - box[0], box[3] - box[1]
    pad_x = int(size * 0.95) if pad_x is None else pad_x
    pad_y = int(size * 0.62) if pad_y is None else pad_y
    w, h = tw + 2 * pad_x, th + 2 * pad_y + int(size * 0.22)
    img = Image.new('RGBA', (w, h), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    d.rounded_rectangle((0, 0, w - 1, h - 1), h // 2, fill=(255, 255, 255, bg_alpha))
    d.rounded_rectangle((0, 0, w - 1, h - 1), h // 2, outline=(255, 255, 255, border_alpha), width=2)
    d.text((pad_x - box[0], pad_y - box[1] + int(size * 0.11)), text, font=f, fill=fg)
    return img
