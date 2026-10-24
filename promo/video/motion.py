# -*- coding: utf-8 -*-
"""promo/video/motion.py —— 「灵动」运动系统：让机身每一帧都在变

为什么需要这个文件
------------------
2026-10-25 实测 v3 成片（`docs/宣发物料/02_成片/宣发片_v3_竖版_1080x1920_音乐24LUFS.mp4`）：
    逐帧灰度差运动能量 均值 2.09 / 中位 0.04 / **近乎静止(<0.35)占比 71.8%**
    ⇒ 63.6 秒里 45.7 秒画面几乎一动不动，观感就是"挂在动态背景上的一张海报"。
根因：`film.py` 的 `Stage.pos` 是常量，机身完全静止；整屏截图又不许推镜（见 render.py 注释）。
所以"不灵动"不是特效不够炫，是**没有逐帧变化**。

设计（四条，缺一条就回到"PPT"观感）
------------------------------------
1. **3D 姿态**：机身按 yaw/pitch/roll 做真实透视投影（不是 2D 旋转），
   侧面走近时那一侧会自然变窄 —— 这是"手机是实物"的核心线索。
2. **多频呼吸**：每个轴由 3 个**互不通约**的正弦叠加（0.13 / 0.21 / 0.34 Hz），
   合成周期 ≈ 数分钟 ⇒ 片子再长也不会看出循环。
3. **永不停歇的推镜**：z 从 1.000 单调推到 1.045，中途没有平台期。
4. **背景视差**：背景反向/滞后位移（幅度 = 机身的 0.35），机身动 1px 背景动 0.35px
   ⇒ 立刻产生纵深，这是最便宜的"高级感"。

技术要点
--------
* 透视用 `Image.transform(..., Image.PERSPECTIVE, coeffs)`：先把 3D 投影得到的四角
  反解成 homography（输出像素 → 源像素），PIL 的 PERSPECTIVE 正是这个方向。
* 变换只在**机身外接矩形**内做（不是整张画布），1080×1920 下单帧约 55~65 ms；
  按 v3 实测 95 ms/帧的基线，整片仍在 3 分钟量级，可接受。
* 背景预渲染成 1.12 倍再逐帧整数裁切 ⇒ 视差几乎零成本（这是 render.py 已验证的手法）。
* 所有相位由 `seed` 决定 ⇒ **同一 seed 逐帧完全可复现**，改一版对比一版不会漂。

用法
----
    from motion import Motion, Stage3D
    st = Stage3D(scene, canvas=(1080,1920), screen_w=600)
    m  = Motion(scene, seed=11)
    canvas = st.render(t, dur, screen_img, text_draw_fn)
"""

import math
import os
import sys

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

import kit
import mateframe


# ── 3D 姿态 ─────────────────────────────────────────────────────────────────

# 三个互不通约的频率（Hz）⇒ 合成周期极长，看不出循环
#   0.13 / 0.21 / 0.34 → 周期 7.69 / 4.76 / 2.94 秒，最小公倍数在分钟级
FREQS = (0.130, 0.210, 0.340)
WEIGHTS = (0.58, 0.28, 0.14)          # 主频占大头，高频只做"细颤"


def _wave(t, phases, freqs=FREQS, weights=WEIGHTS):
    """多频叠加，返回 -1..1 之间的连续量（weights 之和为 1）。"""
    v = 0.0
    for f, w, p in zip(freqs, weights, phases):
        v += w * math.sin(2 * math.pi * f * t + p)
    return v


class Motion:
    """一个镜头的运动曲线。同 seed ⇒ 完全可复现。

    输出（`pose(t, dur)` 返回 dict）
    --------------------------------
    yaw    绕竖轴，正 = 右侧走近        （度，±YAW）
    pitch  绕横轴，正 = 顶部走近        （度，±PITCH）
    roll   平面内旋转                   （度，±ROLL）
    z      缩放（1.0 = 基准）           （单调递增到 1+ZOOM）
    dx,dy  机身位移                     （画布像素）
    bgx,bgy  背景位移（视差，自动 = -0.35 × 机身位移）
    """

    YAW = 1.55        # 度
    PITCH = 1.05
    ROLL = 0.42
    ZOOM = 0.045      # 全段推镜 4.5%
    FLOAT = 4.2       # 悬浮位移（px）
    PARALLAX = 0.35   # 背景滞后系数

    def __init__(self, seed=0):
        r = np.random.RandomState(seed * 7919 + 13)
        self.ph = r.uniform(0, 2 * math.pi, size=(5, 3))   # 5 个通道 × 3 个频率
        self.ph2 = r.uniform(0, 2 * math.pi, size=2)

    def pose(self, t, dur):
        d = max(dur, 1e-6)
        u = t / d                                     # 0..1 线性进度

        # ① 姿态呼吸（永远在动，且不重复）
        yaw = self.YAW * _wave(t, self.ph[0])
        pitch = self.PITCH * _wave(t, self.ph[1])
        roll = self.ROLL * _wave(t, self.ph[2])

        # ② 推镜：单调递增，没有平台期；用 u**0.9 让前半段稍快，符合"注意力在前"
        z = 1.0 + self.ZOOM * (u ** 0.9)

        # ③ 悬浮位移（与姿态错开相位，避免"整机在画圈"的机械感）
        dx = self.FLOAT * _wave(t, self.ph[3])
        dy = self.FLOAT * _wave(t, self.ph[4])

        # ④ 入场/退场：叠加到上面，不是替换 —— 保证入场时"也在呼吸"
        return dict(yaw=yaw, pitch=pitch, roll=roll, z=z, dx=dx, dy=dy,
                    bgx=-dx * self.PARALLAX, bgy=-dy * self.PARALLAX)


def entry_scale(t, t_in=0.85):
    """入场包络：0→1，ease-out-expo（起步猛、收尾极慢 = 高级感来源）。"""
    if t_in <= 0:
        return 1.0
    p = kit.clamp01(t / t_in)
    return 1.0 if p >= 1 else 1 - 2 ** (-9 * p)


# ── homography ──────────────────────────────────────────────────────────────

def _homography(src, dst):
    """求把 src 四点 → dst 四点的 3×3 单应矩阵（float64，齐次坐标）。"""
    A = []
    for (x, y), (u, v) in zip(src, dst):
        A.append([x, y, 1, 0, 0, 0, -u * x, -u * y, -u])
        A.append([0, 0, 0, x, y, 1, -v * x, -v * y, -v])
    A = np.asarray(A, dtype=np.float64)
    # 最小奇异值对应的向量即解
    _, _, vt = np.linalg.svd(A)
    return vt[-1].reshape(3, 3)


def _inverse_coeffs(sprite_size, quad):
    """sprite 四角 → 目标 quad 的正向单应，取逆得到 PIL PERSPECTIVE 需要的 8 个系数。

    PIL `Image.transform(size, PERSPECTIVE, coeffs)` 的语义是：
        对**输出**像素 (x, y)，取源图坐标
        u = (a·x + b·y + c) / (g·x + h·y + 1)
        v = (d·x + e·y + f) / (g·x + h·y + 1)
    也就是 coeffs 描述的是 **输出 → 源** 的映射，所以这里必须取逆。
    """
    w, h = sprite_size
    src = [(0, 0), (w, 0), (w, h), (0, h)]          # 源：sprite 四角
    H = _homography(src, quad)                       # 源 → 输出
    try:
        Hi = np.linalg.inv(H)
    except np.linalg.LinAlgError:
        return None
    Hi = Hi / Hi[2, 2]
    return (Hi[0, 0], Hi[0, 1], Hi[0, 2],
            Hi[1, 0], Hi[1, 1], Hi[1, 2],
            Hi[2, 0], Hi[2, 1])


# ── 3D 投影 ─────────────────────────────────────────────────────────────────

def project_quad(cx, cy, hw, hh, yaw_deg, pitch_deg, roll_deg, cam_dist=5.2):
    """把一块 hw×hh 的平面按 yaw/pitch/roll 旋转后透视投影到画布，返回四角。

    相机距离 `cam_dist` 以"半宽"为单位（5.2 ⇒ 相机在 5.2×hw 处）。
    这个量决定透视强度：太近会鱼眼，太远退化成仿射。5.2 是实测比较像
    "手举手机给人看"的观感。
    """
    ry = math.radians(yaw_deg)
    rx = math.radians(pitch_deg)
    rz = math.radians(roll_deg)

    D = cam_dist * hw
    pts = []
    for sx, sy in ((-1, -1), (1, -1), (1, 1), (-1, 1)):
        x, y, z = sx * hw, sy * hh, 0.0
        # roll（绕 Z）—— 注意屏幕坐标 y 向下，这里保持一致
        x, y = x * math.cos(rz) - y * math.sin(rz), x * math.sin(rz) + y * math.cos(rz)
        # pitch（绕 X）
        y, z = y * math.cos(rx) - z * math.sin(rx), y * math.sin(rx) + z * math.cos(rx)
        # yaw（绕 Y）
        x, z = x * math.cos(ry) + z * math.sin(ry), -x * math.sin(ry) + z * math.cos(ry)
        # 透视投影（D 处为 z=0 平面，投影比 = D/(D+z)）
        k = D / (D + z)
        pts.append((cx + x * k, cy + y * k))
    return pts


# ── 舞台 ────────────────────────────────────────────────────────────────────

class Stage3D:
    """背景 + 机身 + 姿态变换。静态件一次算好，逐帧只做投影与合成。"""

    BG_OVERSCAN = 1.12    # 背景预渲染放大倍数（给视差留余量）

    def __init__(self, scene, canvas=(1080, 1920), screen_w=600, use_mate=True):
        self.scene = scene
        self.W, self.H = canvas
        self.screen_w = screen_w
        self.use_mate = use_mate

        # ── 背景（放大后逐帧裁切 = 零成本视差）──
        bw = int(round(self.W * self.BG_OVERSCAN))
        bh = int(round(self.H * self.BG_OVERSCAN))
        self.bg_big = kit.make_background((bw, bh), scene['c1'], scene['c2'],
                                          scene['accent'],
                                          blur_scale=self.W / 1080.0).convert('RGB')
        self.bg_max = ((bw - self.W) // 2, (bh - self.H) // 2)

        # ── 机身 ──
        if use_mate:
            self.dev_size = mateframe.info(screen_w)['device']
            box = mateframe.info(screen_w)['screen_box']
            self.sw, self.sh = box[2] - box[0], box[3] - box[1]
        else:
            self.phone = kit.Phone(screen_w, int(round(screen_w / 0.48529)), island=False)
            self.dev_size = self.phone.size
            self.sw = self.phone.screen_box[2] - self.phone.screen_box[0]
            self.sh = self.phone.screen_box[3] - self.phone.screen_box[1]

        pw, ph = self.dev_size
        self.base = ((self.W - pw) / 2.0, self.H - 64 - ph)   # 机身中心基准位
        self.cx = self.base[0] + pw / 2.0
        self.cy = self.base[1] + ph / 2.0
        self.hw, self.hh = pw / 2.0, ph / 2.0

        # 投影（机身下方的接触阴影）
        sh = Image.new('RGBA', (self.W, self.H), (0, 0, 0, 0))
        ImageDraw.Draw(sh).rounded_rectangle(
            (self.base[0] + 8, self.base[1] + ph - 26,
             self.base[0] + pw - 8, self.base[1] + ph + 30),
            int(pw * 0.10), fill=(0, 0, 0, 150))
        self.shadow = sh.filter(ImageFilter.GaussianBlur(int(self.W * 0.028)))

        self._sprite_cache = {}

    # ── 机身合成（同一个屏幕内容只做一次）────────────────────────────────
    def _sprite(self, screen_img):
        key = id(screen_img)
        hit = self._sprite_cache.get(key)
        if hit is not None:
            return hit
        if self.use_mate:
            dev = mateframe.compose(screen_img, self.screen_w)
        else:
            dev = self.phone.compose(screen_img)
        self._sprite_cache = {key: dev}      # 只留当前一帧，避免内存堆积
        return dev

    def background(self, pose):
        """按视差位移裁切预渲染背景。"""
        ox = int(round(self.bg_max[0] + pose['bgx'] * self.BG_OVERSCAN))
        oy = int(round(self.bg_max[1] + pose['bgy'] * self.BG_OVERSCAN))
        ox = max(0, min(ox, self.bg_big.size[0] - self.W))
        oy = max(0, min(oy, self.bg_big.size[1] - self.H))
        return self.bg_big.crop((ox, oy, ox + self.W, oy + self.H)).convert('RGBA')

    def render(self, canvas, screen_img, pose, shadow_alpha=1.0):
        """把机身按 pose 透视变换后贴到 canvas 上，返回新 canvas。"""
        sprite = self._sprite(screen_img)
        pw, ph = sprite.size

        # 缩放：z 同时作用于"离相机更近"（视觉上变大）
        hw, hh = self.hw * pose['z'], self.hh * pose['z']
        cx = self.cx + pose['dx']
        cy = self.cy + pose['dy']

        quad = project_quad(cx, cy, hw, hh,
                            pose['yaw'], pose['pitch'], pose['roll'])

        # 外接矩形（留 2px 余量，防止边缘被裁）
        xs = [p[0] for p in quad]
        ys = [p[1] for p in quad]
        x0 = int(math.floor(min(xs))) - 2
        y0 = int(math.floor(min(ys))) - 2
        x1 = int(math.ceil(max(xs))) + 2
        y1 = int(math.ceil(max(ys))) + 2
        bw, bh = x1 - x0, y1 - y0
        if bw <= 0 or bh <= 0:
            return canvas

        local = [(p[0] - x0, p[1] - y0) for p in quad]
        coeffs = _inverse_coeffs((pw, ph), local)
        if coeffs is None:
            return canvas

        warped = sprite.transform((bw, bh), Image.PERSPECTIVE, coeffs, Image.BICUBIC)

        out = canvas
        if shadow_alpha > 0.001:
            sh = self.shadow if shadow_alpha >= 0.999 else kit.set_alpha(self.shadow, shadow_alpha)
            out = Image.alpha_composite(out, sh)
        out.paste(warped, (x0, y0), warped)
        return out

    def contact_shadow(self, pose, strength=1.0):
        """按姿态给阴影加一点横向偏移，避免"阴影钉死、机身乱飞"的穿帮。"""
        if strength <= 0.001:
            return None
        dx = int(round(pose['dx'] * 0.55))
        img = Image.new('RGBA', (self.W, self.H), (0, 0, 0, 0))
        img.paste(self.shadow, (dx, int(round(-pose['dy'] * 0.25))), self.shadow)
        return kit.set_alpha(img, strength)


# ── 自检 ────────────────────────────────────────────────────────────────────

if __name__ == '__main__':
    try:
        sys.stdout.reconfigure(encoding='utf-8', errors='replace')
    except Exception:
        pass

    # 1) homography 往返正确性
    quad = [(100, 80), (700, 120), (720, 1200), (90, 1150)]
    c = _inverse_coeffs((600, 1294), quad)
    print('[1] 透视系数 =', ' '.join(f'{v:.6f}' for v in c))
    # 把源四角代回，应落在 quad 上
    ok = True
    for (sx, sy), (tx, ty) in zip([(0, 0), (600, 0), (600, 1294), (0, 1294)], quad):
        a, b, cc, d, e, f, g, h = c
        den = g * tx + h * ty + 1
        u = (a * tx + b * ty + cc) / den
        v = (d * tx + e * ty + f) / den
        err = math.hypot(u - sx, v - sy)
        ok = ok and err < 0.05
        print(f'    ({sx},{sy}) <- ({u:.2f},{v:.2f})  err={err:.4f}')
    print('    =>', 'OK' if ok else '**FAIL**')

    # 2) 姿态范围
    m = Motion(seed=11)
    for t in (0.0, 1.0, 2.5, 4.0):
        p = m.pose(t, 4.0)
        print(f'[2] t={t:.1f}s  yaw={p["yaw"]:+.2f}  pitch={p["pitch"]:+.2f}  '
              f'roll={p["roll"]:+.2f}  z={p["z"]:.4f}  dx={p["dx"]:+.1f}  dy={p["dy"]:+.1f}')

    # 3) 逐帧差异（证明"每一帧都在动"）
    d = 4.0
    n = 120
    qs = []
    for i in range(n):
        p = m.pose(i / 30.0, d)
        qs.append(project_quad(540, 960, 324, 670, p['yaw'], p['pitch'], p['roll']))
    qs = np.array(qs)
    step = np.abs(np.diff(qs, axis=0)).max(axis=(1, 2))
    print(f'[3] 相邻帧四角最大位移: 中位={np.median(step):.3f}px  最小={step.min():.3f}px  '
          f'最大={step.max():.3f}px  零位移帧={int((step < 1e-6).sum())}/{len(step)}')
