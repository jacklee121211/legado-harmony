# -*- coding: utf-8 -*-
"""promo/video/scenes.py —— 分镜表（视频唯一"内容源"）

一份分镜 → 两个版式（9:16 / 16:9）。改文案、换图、调时长**只动这个文件**。

字段
----
id      场景号（输出文件名前缀）
src     promo/src/ 下的真机截图（1320×2848 原生分辨率，**像素不改**）
crop    取原图哪一块 (左, 上, 右, 下)；None = 整屏
focus   Ken Burns 推进的焦点（画面比例坐标 0~1），决定"镜头往哪儿推"
title   主标题（4 字，与静态海报同一套文案，**原样**）
sub     副标题（海报第二行，**原样**）
c1/c2   背景渐变（深 → 亮）
accent  柔光 + 标题强调条颜色
dur     本场景时长（秒）；节奏：一个卖点 ≈ 3.2~4.0s

⚠️ 文案与静态海报（promo/make_posters.py 的 POSTERS 表）保持同一措辞，
   两套物料不能有两种说法。
"""

BRAND = '喵阅'
BRAND_SUB = 'HarmonyOS 阅读器'
TAGLINE = '极致的本地书籍阅读器'

SCENES = [
    dict(
        id='01_light', src='02_书架_喵阅_完整版.jpg', crop=None, focus=(0.50, 0.42),
        title='鸿蒙赋能', sub='沉浸光感，全新UI超美观！',
        c1=(112, 38, 4), c2=(255, 140, 44), accent=(255, 210, 140),
        dur=3.6,
    ),
    dict(
        # 兴趣区按「画布比例 0.4853」重新框定（2026-10-17 统一画布后返工）：
        # 弹窗面板实测边界 = (79,698,1241,2156)（见 make_posters.py MATERIAL_DIALOG_CROP），
        # 以面板中心 (660,1427) 为心，取高 1900 → 宽 922 ⇒ 0.4853，四周留上下文不切字。
        id='02_material', src='03_material.jpg', crop=(199, 477, 1121, 2377), focus=(0.50, 0.50),
        title='超多材质', sub='个人定制，自由畅想随心配！',
        c1=(40, 16, 74), c2=(140, 82, 226), accent=(215, 175, 255),
        dur=3.4,
    ),
    dict(
        id='03_font', src='04_font.jpg', crop=(95, 420, 1225, 2462), focus=(0.50, 0.55),
        title='自定字体', sub='多渠导入，怎么舒适怎么来！',
        c1=(4, 54, 50), c2=(22, 180, 160), accent=(140, 245, 225),
        dur=3.4,
    ),
    dict(
        # 同样按 0.4853 重框：保留取色盘全宽 1190，把高度撑到 2452（顶到画布上沿）。
        id='04_theme', src='05_color.jpg', crop=(65, 396, 1255, 2848), focus=(0.50, 0.45),
        title='更多预设', sub='自由调盘，万千色彩随你定！',
        c1=(86, 8, 46), c2=(238, 82, 144), accent=(255, 170, 200),
        dur=3.4,
    ),
    dict(
        id='05_ai_tts', src='07_ai_tts.jpg', crop=None, focus=(0.50, 0.60),
        title='AI听书', sub='多音色朗读，边看边听真省眼！',
        c1=(12, 24, 88), c2=(88, 96, 236), accent=(172, 182, 255),
        dur=3.8,
    ),
    dict(
        id='06_wifi', src='01_wifi.jpg', crop=(100, 560, 1220, 2345), focus=(0.50, 0.50),
        title='WIFI传输', sub='电脑阅读，双端协同超便利！',
        c1=(6, 28, 88), c2=(0, 138, 224), accent=(96, 205, 255),
        dur=3.4,
    ),
    dict(
        id='07_privacy', src='10_privacy.jpg', crop=None, focus=(0.50, 0.45),
        title='隐私防窥', sub='绝密保护，安全阅读最在行！',
        c1=(18, 18, 22), c2=(58, 58, 66), accent=(200, 200, 210),
        dur=3.2,
    ),
]

SCENE_BY_ID = {s['id']: s for s in SCENES}
