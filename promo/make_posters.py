# -*- coding: utf-8 -*-
"""
喵阅 · 宣传图生成器（本地合成，不经 AI 重绘）
================================================
思路：**截图像素原样保留**（只做裁切 + 圆角 + 投影 + 描边 + 倾斜），文字与背景由本脚本绘制。
这样 UI 里的小字（菜单名、按钮名、材质编号）不会被生成式模型画糊 —— 这是 App
宣传图的通行做法，也是本脚本相对「把截图丢给豆包/即梦重画」的唯一优势。

依赖：Python 3 + Pillow（本机实测：Python 3.12.9 / Pillow 12.2.0）
字体：C:\\Windows\\Fonts\\HarmonyOS_Sans_SC_*.ttf
      （= App 内默认的「鸿蒙黑体」，字体同源 ⇒ 宣传图与真机视觉一致）

用法：
    python promo/make_posters.py                    # 全部海报 1080x1920（9:16）
    python promo/make_posters.py --size 1080x1440   # 3:4，适合应用市场/小红书
    python promo/make_posters.py --only 1 6         # 只出第 1、6 张

改文案 / 换配色 / 换裁切框：只改下面 POSTERS 表，不用碰渲染逻辑。
⚠️ 绘图铁律（本文件踩过的坑）：ImageDraw 画带 alpha 的颜色是**直接替换像素**、
   不参与混合 ⇒ 所有半透明元素必须画在独立图层上再 `alpha_composite`，
   否则 `convert('RGB')` 时 alpha 被丢弃，半透明白会变成纯白（白底白字 = 看不见）。
⚠️ 倾斜铁律：`Image.rotate` 是**逆时针**、且默认把画布**撑大**并填黑。
   必须 `expand=True` + `resample=BICUBIC`，且用带 alpha 的图贴回，
   否则会出现黑角，或截图里的细字被插值打碎。
"""

import argparse
import os

from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = os.path.dirname(os.path.abspath(__file__))
SRC_DIR = os.path.join(ROOT, 'src')

# ── 物料/产物目录（2026-10-17 统一到 docs/宣发物料/）────────────────────────
#   素材查找：先 00_原始素材/截图/（你新录的），再回落 promo/src/（旧归档）
#   产物输出：02_成片/<vN>/，与视频成片同处
MATERIAL_ROOT = os.path.join(os.path.dirname(ROOT), 'docs', '宣发物料')
SHOT_DIR = os.path.join(MATERIAL_ROOT, '00_原始素材', '截图')
OUT_DIR = os.path.join(MATERIAL_ROOT, '02_成片')


def resolve_src(name):
    """素材查找：新物料目录优先，回落旧归档。找不到直接报错并列出两处路径。"""
    for d in (SHOT_DIR, SRC_DIR):
        p = os.path.join(d, name)
        if os.path.exists(p):
            return p
    raise SystemExit(f'找不到素材 {name}\n  查过：{SHOT_DIR}\n  查过：{SRC_DIR}')

FONTS = {
    'bold': r'C:\Windows\Fonts\HarmonyOS_Sans_SC_Bold.ttf',
    'medium': r'C:\Windows\Fonts\HarmonyOS_Sans_SC_Medium.ttf',
    'regular': r'C:\Windows\Fonts\HarmonyOS_Sans_SC_Regular.ttf',
}

BRAND = '喵阅'
BRAND_SUB = 'HarmonyOS 阅读器'

# ── 全图统一角标（2026-10-12 用户要求）──────────────────────────────────────
# 用户原话：「所有的图片里面，都需要增加字样，极致的本地书籍阅读器，这个字样能让用户
#           直观了解到我们的作用和竞品的区别，最好是能增加，支持XX、XX、XXX格式」
#
# 支持格式的**事实来源**（不是猜的）：
#   entry/src/main/ets/pages/view/bookShelf/IndexShelf.ets:699-705
#     「支持的后缀与 ReaderKit 官方支持列表一致：`txt / epub / mobi / azw / azw3`
#      （官方文档 documentId：`开发指南/Reader_Kit_阅读服务/Reader_Kit简介/reader-introduction`）」
#     pickLocalBooks() 实参：['.txt', '.epub', '.mobi', '.azw', '.azw3']
TAGLINE = '极致的本地书籍阅读器'
FORMATS = '支持 TXT / EPUB / MOBI / AZW / AZW3 格式'

# ── 合规标注（新增两张 AI 听书海报专用）────────────────────────────────────
# 用户 2026-10-12 指定，原文照抄，不缩写、不改字。
DISCLAIMER = (
    '本软件不提供 API Key，请自行配置。'
    '本软件无服务器，不收集任何用户信息，请放心使用。'
)

# ── 海报配置 ────────────────────────────────────────────────────────────────
# crop   : 从 1320x2848 原图里取哪一块（左, 上, 右, 下）—— 只取"能证明这个卖点"的区域
# title  : 主标题（4 字，用户文案第一句，**原样**）
# sub    : 副标题（12 字，用户文案剩余部分，**原样**）
# c1/c2  : 背景渐变（深 → 亮，左上 → 右下）
# accent : 主标题下的强调条 + 光斑颜色
# note   : 可选，卡片下方小字免责说明（长文案走这里，不挤占标题区）
#
# 全部 8 张统一版式标准：主标题 **4 字** + 副标题 **12 字**（用户 2026-10-12 确认）。
POSTERS = [
    dict(
        src='01_wifi.jpg', out='1_wifi_传书.png',
        crop=(100, 560, 1220, 2345),
        title='WIFI传输', sub='电脑阅读，双端协同超便利！',
        c1=(6, 28, 88), c2=(0, 138, 224), accent=(96, 205, 255),
    ),
    dict(
        # 2026-10-17 终版截图：顶部标题「喵阅」+ 5 本书 + **dock 磨砂材质（能透出底下书卡）**。
        # 这张是原生完整截图，不再需要 splice_shelf.py 拼接（拼接版留作备选）。
        # 裁切上沿 110：状态栏文字到 y=99，标题「喵阅」在 y=141..218（实测 _measure.py），
        # 旧裁切 300 恰好把标题整条切掉 ⇒ 新版故意**保留品牌标题**。
        src='02_书架_喵阅_完整版.jpg', out='2_鸿蒙光感.png',
        crop=(0, 110, 1320, 2848),
        title='鸿蒙赋能', sub='沉浸光感，全新UI超美观！',
        c1=(112, 38, 4), c2=(255, 140, 44), accent=(255, 210, 140),
    ),
    dict(
        # 2026-10-12 改造：改为「选择窗 + 效果」双层倾斜叠加，见 material_stack()
        out='3_多材质.png',
        stack='material',
        title='超多材质', sub='个人定制，自由畅想随心配！',
        c1=(40, 16, 74), c2=(140, 82, 226), accent=(215, 175, 255),
    ),
    dict(
        src='04_font.jpg', out='4_自定字体.png',
        crop=(95, 420, 1225, 2462),
        title='自定字体', sub='多渠导入，怎么舒适怎么来！',
        c1=(4, 54, 50), c2=(22, 180, 160), accent=(140, 245, 225),
    ),
    dict(
        src='05_color.jpg', out='5_自由调盘.png',
        crop=(65, 840, 1255, 2726),
        title='更多预设', sub='自由调盘，万千色彩随你定！',
        c1=(86, 8, 46), c2=(238, 82, 144), accent=(255, 170, 200),
    ),
    dict(
        # ⚠️ 2026-10-12 用户要求：**移除独立出图** —— 并入 #7，主标题改为「AI听书 & 本地TTS」。
        #    依据：华为本地 TTS 与 AI 听书同属"听书"能力，且华为侧是**纯本地端侧合成**
        #    （证据 `tts/LocalTtsClient.ets:8-9` 引 SDK 原文：online 「0: not supported
        #      currently; 1: offline mode, which is supported」⇒ 恒 1），
        #    合并后"本地"与"AI"两条路都覆盖，单独一张「本地TTS」意义不大。
        src='06_tts.jpg', out='6_本地TTS.png',
        crop=(70, 1595, 1250, 2700),
        title='本地TTS', sub='语音读书，畅听书海爽翻天！',
        c1=(12, 24, 88), c2=(88, 96, 236), accent=(172, 182, 255),
        skip=True,
    ),
    dict(
        # 2026-10-12 新增：AI 听书（服务商/方案配置），涉及第三方服务器与 API
        # ⚠️ 裁切坑（两轮才调干净）：
        #   ① 初版 455..2140：上界切掉「第1章」标题（顶部一片空白），下界又正好切在
        #      「模型 qwen3-tts-flash」那一行中间 ⇒ 卡片底出现半截元素。
        #   ② 二版 420..2400：仍保留「第1章」整块（用户："第一张那一块不要"），
        #      底部还带着「音色 → …」说明段（用户："底部也不够干净"）。
        #   ⇒ 实测：y=380..456 是「第1章」、y=560..708 是提示条、胶囊底 ≈2310、
        #     「音色 →」说明首行从 y=2320 起、其文字底 2356。
        #     取 **520..2315**：顶部从提示条开始，底部落在胶囊之后、说明段之前的**空白行**，
        #     不切字（第三版取 2320 仍切进了说明首行 ⇒ 用户仍评"底部不够干净"）。
        src='07_ai_tts.jpg', out='7_AI听书.png',
        crop=(60, 520, 1260, 2315),
        # 2026-10-12 用户要求：主标题加「&本地TTS」，吸收原 #6 的定位
        title='AI听书 & 本地TTS', sub='全链支持，文字温度我知道！',
        c1=(10, 30, 30), c2=(20, 176, 166), accent=(122, 245, 224),
        note=DISCLAIMER,
    ),
    dict(
        # 2026-10-12 新增：AI 音色（旁白/对白/男生/女生 四槽位）
        src='08_ai_voice.jpg', out='8_超多音色.png',
        crop=(60, 1005, 1260, 2500),
        title='超多音色', sub='男女识别，沉浸听书体验佳！',
        c1=(38, 12, 62), c2=(150, 74, 220), accent=(214, 168, 255),
        note=DISCLAIMER,
    ),
    dict(
        # 2026-10-12 替换：高斯模糊左右对比（新截图，源图高 2360 而非 2848）
        src='09_blur_new.png', out='9_高斯模糊.png',
        crop=(0, 0, 1320, 2360),
        title='高斯模糊', sub='多级调节，任何背景都合适！',
        c1=(16, 12, 8), c2=(74, 59, 44), accent=(232, 199, 155),
    ),
    dict(
        # 2026-10-12 新增：隐私防窥（防窥保护开启弹窗）
        src='10_privacy.jpg', out='10_隐私防窥.png',
        crop=(40, 590, 1280, 2090),
        title='隐私防窥', sub='绝密保护，安全阅读最在行！',
        c1=(8, 16, 34), c2=(46, 104, 186), accent=(140, 200, 255),
    ),
]

# ── 「超多材质」双层倾斜叠加素材（2026-10-12 用户指定构图）────────────────────
# 用户意图：**上面是效果、下面是选择窗**，两层倾斜叠放，体现「联动」。
#   · 后层（上） = 「更多材质」九宫格弹窗 —— 选择窗
#   · 前层（下） = 「同一页·三段材质」拼好的那一页 —— 效果预览
# 实测边界（`promo/_probe2.py`，源图 1320x2848）：
#   · 弹窗面板 x 79..1241、y 698..2150（其上 y<=697 是灰色遮罩 204,204,204）
#   · 三段材质页由 make_material_stitch.py 的 CONTENT_TOP/CUT1/CUT2/CONTENT_BOTTOM 拼出
MATERIAL_DIALOG_CROP = (79, 698, 1241, 2156)   # 九宫格弹窗面板（含圆角外沿）= 1162x1458
# ⚠️ 顶界必须是 **698**，不能是 690（2026-10-12 用户圈出"切得不干净"）：
#    实测 03_material.jpg 在 y=693..695 处 x=300 有近黑像素 (7,7,7) —— 那是**弹窗背后
#    页面上的正文**（"已接受修改后的协议"一行）透出来的一线；y=698 起才是面板纯白
#    (255,255,255)。取 690 会把这条脏边一起裁进卡片顶边（放大后可见一排黑点）。
MATERIAL_TILT = 0.0                            # 已废弃：倾斜叠加改成正交层叠（见 material_layers）
# 正交层叠参数（2026-10-12 用户指定）
W_FRONT = 0.88          # 前层（书页）宽 = 画布宽 × 该值（"百分之百宽度"= 占满可用宽度）
BACK_W_RATIO = 0.86     # 后层（弹窗）宽 = 前层宽 × 该值
                        # ⚠️ 2026-10-12 用户反馈原 0.70「太窄了，保持比例别为了宽压缩」
                        #    ⇒ 加宽到 0.86。注意：**宽度比例变了，高度按各自宽高比自动跟随**，
                        #    不做任何非等比拉伸（用户明确要求保持比例）。
BACK_EXPOSE = 0.30      # 后层露出区高度 = 可用高 × 该值（≈ 两行九宫格 + 标题）
MATERIAL_BLEED = 96     # 前层书页"底部贯穿"的出血量：下边直角、超出画布这么多


# ── 基础工具 ────────────────────────────────────────────────────────────────

def font(kind, size):
    return ImageFont.truetype(FONTS[kind], size)


def text_wh(draw, text, f):
    box = draw.textbbox((0, 0), text, font=f)
    return box[2] - box[0], box[3] - box[1]


def diagonal_gradient(size, c1, c2, angle=(1.0, 0.55)):
    """平滑斜向渐变：先算小图（64x64）再放大 ⇒ 无旋转接缝、无黑角。"""
    step = 64
    ax, ay = angle
    small = Image.new('L', (step, step))
    px = small.load()
    for y in range(step):
        for x in range(step):
            t = (ax * x / (step - 1) + ay * y / (step - 1)) / (ax + ay)
            px[x, y] = int(round(255 * min(1.0, max(0.0, t))))
    g = small.resize(size, Image.BICUBIC)
    return Image.merge('RGB', [
        g.point(lambda v, i=i: int(round(c1[i] + (c2[i] - c1[i]) * v / 255.0)))
        for i in range(3)
    ])


def top_shade(size, peak=170, fade=0.62):
    """顶部压暗，保证白字在亮渐变上也够清楚。"""
    h = size[1]
    strip = Image.new('L', (1, h))
    px = strip.load()
    for y in range(h):
        t = min(1.0, y / (h * fade))
        px[0, y] = int(round(peak * (1.0 - t) ** 1.6))
    layer = Image.new('RGBA', size, (0, 0, 0, 0))
    layer.putalpha(strip.resize(size, Image.BICUBIC))
    return layer


def noise_layer(size, strength=9):
    n = Image.effect_noise(size, 22).convert('L').point(lambda v: int(v * strength / 255))
    layer = Image.new('RGBA', size, (255, 255, 255, 0))
    layer.putalpha(n)
    return layer


def rounded_mask(size, radius, bottom_square=False):
    m = Image.new('L', size, 0)
    d = ImageDraw.Draw(m)
    d.rounded_rectangle((0, 0, size[0] - 1, size[1] - 1), radius, fill=255)
    if bottom_square:
        d.rectangle((0, size[1] - radius - 1, size[0] - 1, size[1] - 1), fill=255)
    return m


def rounded_box(draw, box, radius, fill=None, outline=None, width=1):
    draw.rounded_rectangle(box, radius, fill=fill, outline=outline, width=width)


def card_image(shot, w, h, radius, border=4, border_alpha=90, bottom_square=False):
    """把截图做成「圆角 + 白描边」的卡片 RGBA（尺寸 w×h）。

    返回带 alpha 的图，交由调用方 alpha_composite —— 描边画在独立图层上，
    避免半透明白被 ImageDraw 直接覆写（见文件头铁律）。

    `bottom_square=True`：**下边不收圆角**（直角）。用于 #3 的前层书页 ——
    用户要求"书页底部贯穿、不用收圆角"，让它像从画布下沿长出来一样。
    """
    body = shot.convert('RGB').resize((w, h), Image.LANCZOS)
    card = Image.new('RGBA', (w, h), (0, 0, 0, 0))
    card.paste(body, (0, 0), rounded_mask((w, h), radius, bottom_square))
    edge = Image.new('RGBA', (w, h), (0, 0, 0, 0))
    ImageDraw.Draw(edge).rounded_rectangle(
        (0, 0, w - 1, h - 1), radius, outline=(255, 255, 255, border_alpha), width=border)
    if bottom_square:
        # 抹掉下边缘的白描边与圆角，保持直角贯通
        ImageDraw.Draw(edge).rectangle((0, h - border - 1, w - 1, h - 1), fill=(0, 0, 0, 0))
    return Image.alpha_composite(card, edge)


def drop_shadow(canvas, box, radius, blur, alpha=170, dy=26, inset=8):
    """在 canvas 上叠一层卡片投影（独立图层 + 高斯模糊）。"""
    W, H = canvas.size
    sh = Image.new('RGBA', (W, H), (0, 0, 0, 0))
    x0, y0, x1, y1 = box
    ImageDraw.Draw(sh).rounded_rectangle(
        (x0 + inset, y0 + dy, x1 - inset, y1 + dy), radius, fill=(0, 0, 0, alpha))
    return Image.alpha_composite(canvas, sh.filter(ImageFilter.GaussianBlur(blur)))


# ── 正交层叠（「超多材质」专用，2026-10-12 用户改定）──────────────────────────
#
# 用户原话：「我感觉应该是一个在前一个在后，上下叠加，而不是这种歪七扭八的…
#           更多材质弹窗在后，百分之七十宽度，然后书页在前，百分之百宽度叠加在后面
#           的弹窗，弹窗漏出来到第二行就够了，然后书页正常尺寸一直到底。」
#
# ⇒ 取消全部倾斜（MATERIAL_TILT 作废），改成正交层叠：
#     · 后层 = 「更多材质」弹窗，宽 = 画布宽 × 70%
#     · 前层 = 三段材质书页，宽 = 100%（画布满宽），对齐到底
#     · 后层只需露出**两行**九宫格，其余被前层盖住

def material_layers(size, scale, area_h, bleed):
    """返回 (后层弹窗卡片, 前层书页卡片)。

    `area_h` = 副标题下方 → 画布底 可用高；`bleed` = 前层出血量（下边直角、超出画布）。

    · 前层（书页）= **满宽**（画布宽 × W_FRONT）、**下边直角**、**出血贯穿到底**
    · 后层（弹窗）= 前层宽 × BACK_W_RATIO（用户指定 70%），只露出顶部约两行九宫格

    ⚠️ 实测坑（2026-10-12 三轮返工，每轮的错都不一样）：
       ① rotate 倾斜叠加 ⇒ 用户判定「歪七扭八」；
       ② 正交但前层占满 98.8% 可用高 ⇒ 后层只剩 17px（2%），等于没叠；
       ③ 想靠"缩窄前层"来腾空间 ⇒ 前层掉到 61% 宽，违反"书页 100% 宽"。
       ⇒ 正解：前层**保持满宽**，改为**裁切书页高度**（只取上部一段）+ 底部直角出血。
         因为拼接后的整页宽高比只有 0.685，满宽必然是 1484px 高，装不下"后层露出"，
         所以必须裁高度，而不是缩宽度 —— 宽度是构图要求，高度才是可裁项。
    """
    def s(v):
        return int(round(v * scale))

    # 后层：九宫格弹窗（完整面板）
    dlg = Image.open(resolve_src('03_material.jpg')).convert('RGB')
    x0, y0, x1, y1 = MATERIAL_DIALOG_CROP
    dlg = dlg.crop((x0, y0, x1, y1))          # 完整体：1162 x 1466

    # 前层：三段材质拼好的一整页
    import make_material_stitch as MS   # 复用同一套切点，保证与既有产物一致
    page = MS.stitched_page()

    pg_ar = page.size[0] / page.size[1]       # 前层宽高比
    dlg_ar = dlg.size[0] / dlg.size[1]        # 后层宽高比

    # 前层宽度：满宽（构图要求，不可动）
    front_w = W_FRONT * size[0]

    # 前层高度：先按"满宽 × 原比例 + 出血"算，再用 可用高 - 露出区 封顶
    expose = area_h * BACK_EXPOSE
    front_h = min(front_w / pg_ar + bleed, area_h - expose)

    # 满宽固定 ⇒ 若要更矮，就裁书页内容（从顶部开始取，底部直角出血贯穿）
    need_src_h = int(round((front_h - bleed) * page.size[0] / front_w))
    need_src_h = max(s(300), min(need_src_h, page.size[1]))
    page = page.crop((0, 0, page.size[0], need_src_h))

    # 后层：宽度 = 前层 × BACK_W_RATIO
    back_w = front_w * BACK_W_RATIO
    back_h = back_w / dlg_ar

    # ⚠️ mask 半径必须 ≈ 面板**自带**的圆角，不能凭手感给（2026-10-12 用户圈出）
    #    实测 03_material.jpg 左上角弧线：dy=0→dx=73、dy=10→32、dy=20→19、dy=40→6、
    #    dy=60→1 ⇒ 面板原生圆角 ≈74px（源）。本裁切宽 1162 缩到 back_w 后按比例折算：
    #      r_card = 74 × (back_w / 1162)
    #    旧值固定 34px 比原生小 18px，mask 切得比面板更"方" ⇒ 四角各漏出一块背景。
    DIALOG_NATIVE_RADIUS_SRC = 74.0
    back_radius = max(6, int(round(DIALOG_NATIVE_RADIUS_SRC * back_w / (x1 - x0))))

    back = card_image(dlg, int(round(back_w)), int(round(back_h)), back_radius,
                      border=max(2, s(3)))
    front = card_image(page, int(round(front_w)), int(round(front_h)), s(34),
                       border=max(2, s(3)), bottom_square=True)
    return back, front, expose, need_src_h


# ── 主流程 ──────────────────────────────────────────────────────────────────

def compose(p, size):
    W, H = size
    scale = W / 1080.0

    def s(v):
        return int(round(v * scale))

    # 背景 + 顶部压暗 + 光斑 + 细噪点（全部走独立图层，见文件头铁律）
    canvas = diagonal_gradient(size, p['c1'], p['c2']).convert('RGBA')
    canvas = Image.alpha_composite(canvas, top_shade(size))

    blobs = Image.new('RGBA', size, (0, 0, 0, 0))
    bd = ImageDraw.Draw(blobs)
    bd.ellipse((W * 0.52, -H * 0.06, W * 1.40, H * 0.42), fill=p['accent'] + (120,))
    bd.ellipse((-W * 0.34, H * 0.34, W * 0.48, H * 0.86), fill=p['accent'] + (66,))
    canvas = Image.alpha_composite(canvas, blobs.filter(ImageFilter.GaussianBlur(s(150))))
    canvas = Image.alpha_composite(canvas, noise_layer(size))

    # ── 文字层（标题 / 副标题 / 品牌胶囊，全在半透明图层上画）────────────
    text_layer = Image.new('RGBA', size, (0, 0, 0, 0))
    d = ImageDraw.Draw(text_layer)

    chip_f = font('medium', s(30))
    chip_txt = f'{BRAND} · {BRAND_SUB}'
    tw, th = text_wh(d, chip_txt, chip_f)
    cx, cy, ch = s(72), s(86), s(64)
    rounded_box(d, (cx, cy, cx + tw + s(56), cy + ch), s(32), fill=(255, 255, 255, 42))
    d.rounded_rectangle((cx, cy, cx + tw + s(56), cy + ch), s(32),
                        outline=(255, 255, 255, 90), width=max(1, s(2)))
    d.text((cx + s(28), cy + (ch - th) / 2 - s(5)), chip_txt, font=chip_f,
           fill=(255, 255, 255, 242))

    # 标题：按可用宽度**自动缩号**（长标题如「AI听书 & 本地TTS」用 104 会顶出画布右缘）
    title_max_w = W - s(72) * 2
    title_size = s(104)
    while title_size > s(40):
        title_f = font('bold', title_size)
        tw, th = text_wh(d, p['title'], title_f)
        if tw <= title_max_w:
            break
        title_size -= s(2)
    ty = cy + ch + s(56)
    # 标题描影：同一位置先画一层深色再画白字，保证亮背景上也立得住
    d.text((s(72) + s(3), ty - s(11)), p['title'], font=title_f, fill=(0, 0, 0, 90))
    d.text((s(72), ty - s(14)), p['title'], font=title_f, fill=(255, 255, 255, 255))

    bar_y = ty + th + s(16)
    rounded_box(d, (s(76), bar_y, s(76) + s(112), bar_y + s(11)), s(6),
                fill=p['accent'] + (255,))

    sub_f = font('medium', s(45))
    sw, sh = text_wh(d, p['sub'], sub_f)
    sy = bar_y + s(42)
    d.text((s(75), sy + s(2)), p['sub'], font=sub_f, fill=(0, 0, 0, 80))
    d.text((s(72), sy), p['sub'], font=sub_f, fill=(255, 255, 255, 238))

    # ── 统一角标：极致的本地书籍阅读器 + 支持格式（2026-10-12 用户要求全图必加）──
    # 放在副标题**下方**、截图卡片**上方** —— 位置依据：
    #   · 标题区（胶囊/主标题/副标题）已排满，塞进去会挤爆版式；
    #   · 紧贴副标题下方属"卖点陈述区"，读者读完副标题自然往下扫，视觉上连贯；
    #   · 在卡片之上留一行 30px 小字，不干扰截图，也不与底部免责小字打架。
    tag_f = font('medium', s(30))
    tag_y = sy + sh + s(30)
    # 角标左对齐到与标题同一左边距，形成竖向对齐节奏
    d.text((s(73), tag_y + s(2)), TAGLINE, font=tag_f, fill=(0, 0, 0, 100))
    d.text((s(72), tag_y), TAGLINE, font=tag_f, fill=(255, 255, 255, 232))

    fmt_f = font('regular', s(26))
    fmt_y = tag_y + s(42)
    d.text((s(73), fmt_y + s(2)), FORMATS, font=fmt_f, fill=(0, 0, 0, 90))
    d.text((s(72), fmt_y), FORMATS, font=fmt_f, fill=(255, 255, 255, 200))

    canvas = Image.alpha_composite(canvas, text_layer)
    sub_bottom = fmt_y + text_wh(d, FORMATS, fmt_f)[1]

    # ── 正交层叠（「超多材质」）────────────────────────────────────────────
    if p.get('stack') == 'material':
        back_top = sub_bottom + s(60)
        area_h = (H - s(20)) - back_top
        back, front, expose, src_h = material_layers(size, scale, area_h, s(MATERIAL_BLEED))

        # 前层"正常尺寸、直角、贯穿到底"：底边直接落到画布外（出血）
        front_cx = W * 0.50
        front_bottom = H + s(MATERIAL_BLEED) - s(20)
        front_cy = front_bottom - front.size[1] / 2

        # 后层：顶端对齐露出区顶部，水平居中（比前层窄，两侧自然露出背景）
        back_cx = W * 0.50
        back_cy = back_top + back.size[1] / 2

        front_top = front_cy - front.size[1] / 2
        shown = front_top - back_top
        assert shown > s(80), f'「超多材质」后层露出太少：shown={shown:.0f}'
        assert back.size[0] < front.size[0], '「超多材质」后层未比前层窄，露不出边缘'
        assert front.size[0] >= W * 0.80, '「超多材质」前层未达满宽'

        # 后层投影（先画，被前层压住下半部 ⇒ 自然形成层次）
        canvas = drop_shadow(canvas, (back_cx - back.size[0] / 2, back_cy - back.size[1] / 2,
                                      back_cx + back.size[0] / 2, back_cy + back.size[1] / 2),
                             s(34), s(34), alpha=150, dy=s(14), inset=s(6))
        canvas.alpha_composite(back, (int(round(back_cx - back.size[0] / 2)),
                                      int(round(back_cy - back.size[1] / 2))))
        # 前层投影：只在下半部起层次作用（被画布裁掉也无妨，故不加底部 inset）
        canvas = drop_shadow(canvas, (front_cx - front.size[0] / 2, front_cy - front.size[1] / 2,
                                      front_cx + front.size[0] / 2, front_cy + front.size[1] / 2),
                             s(34), s(38), alpha=175, dy=s(16), inset=s(10))
        canvas.alpha_composite(front, (int(round(front_cx - front.size[0] / 2)),
                                       int(round(front_cy - front.size[1] / 2))))
        return canvas.convert('RGB')

    # ── 单卡：原图直出（只裁切/缩放/圆角/投影/描边）────────────────────────
    shot = Image.open(resolve_src(p['src'])).convert('RGB').crop(p['crop'])
    aspect = shot.size[0] / shot.size[1]

    # 卡片下方若还有免责小字，先给它留出高度。
    # ⚠️ 实测坑（2026-10-12）：带 note 的卡片**必须禁掉 bleed**。原本 bleed 是给纯竖卡
    #    "出血到画布外"用的（#1~#5 卡片底=1980 > 1920 是**刻意**的），但一旦卡片下方
    #    还要画小字，出血就会把小字顶出画布（实测 #7 小字 y=1880..1960 > 1920，被裁掉）。
    note = p.get('note')
    note_h = s(130) if note else 0

    bleed = 0 if (aspect > 0.9 or note) else s(96)   # 竖卡出血到画布外；横卡/带小字的卡不出血
    card_top = sub_bottom + s(74)
    avail = (H + bleed) - card_top - s(36) - note_h
    card_h = int(avail)
    card_w = int(card_h * aspect)
    max_w = W - s(92)
    if card_w > max_w:
        card_w = max_w
        card_h = int(card_w / aspect)
    card_x = (W - card_w) // 2
    card_y = card_top if card_h >= avail else card_top + (avail - card_h) // 2
    radius = s(44)

    canvas = drop_shadow(canvas, (card_x, card_y, card_x + card_w, card_y + card_h),
                         radius, s(40), alpha=170, dy=26, inset=s(8))

    shot = shot.resize((card_w, card_h), Image.LANCZOS)
    canvas.paste(shot, (card_x, card_y), rounded_mask((card_w, card_h), radius))

    edge = Image.new('RGBA', size, (0, 0, 0, 0))
    ImageDraw.Draw(edge).rounded_rectangle(
        (card_x, card_y, card_x + card_w, card_y + card_h), radius,
        outline=(255, 255, 255, 80), width=max(2, s(4)))
    canvas = Image.alpha_composite(canvas, edge)

    # ── 免责小字：卡片正下方、卡片宽度内，居中 ────────────────────────────
    if note:
        canvas = draw_note(canvas, size, scale, note, card_x, card_w, card_y + card_h)

    return canvas.convert('RGB')


def draw_note(canvas, size, scale, text, card_x, card_w, card_bottom):
    """卡片正下方的合规小字：卡片宽度内自动折行、居中、半透明白。

    长文案不能塞进标题区（会撑爆版式）—— 用户 2026-10-12 确认放这里。
    """
    W, H = size

    def s(v):
        return int(round(v * scale))

    f = font('regular', s(25))
    probe = ImageDraw.Draw(Image.new('RGBA', (8, 8)))
    max_w = card_w - s(10)

    # 按字符贪心折行（中文无空格，只能逐字测宽）
    lines = []
    cur = ''
    for ch_ in text:
        if text_wh(probe, cur + ch_, f)[0] <= max_w:
            cur += ch_
        else:
            lines.append(cur)
            cur = ch_
    if cur:
        lines.append(cur)

    line_h = s(40)
    y = card_bottom + s(30)
    layer = Image.new('RGBA', (W, H), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    for ln in lines:
        lw, lh = text_wh(d, ln, f)
        x = card_x + (card_w - lw) // 2
        d.text((x + s(1), y + s(2)), ln, font=f, fill=(0, 0, 0, 120))   # 描影
        d.text((x, y), ln, font=f, fill=(255, 255, 255, 210))
        y += line_h
    return Image.alpha_composite(canvas, layer)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--size', default='1080x1920')
    ap.add_argument('--only', nargs='*', type=int, default=None,
                    help='只生成第 N 张（1 起），例如 --only 1 6')
    ap.add_argument('--format', default='both', choices=['both', 'png', 'jpg'],
                    help='默认 both：PNG（无损，1MB+）+ JPG（q92，便于微信/小红书上传）')
    ap.add_argument('--outdir', default=None,
                    help='输出根目录下的子目录名（默认 out/<W>x<H>/）。'
                         '用于把新一版生成到新文件夹、保留旧产物。')
    args = ap.parse_args()
    W, H = (int(v) for v in args.size.lower().split('x'))

    os.makedirs(OUT_DIR, exist_ok=True)
    leaf = args.outdir if args.outdir else f'{W}x{H}'
    out_dir = os.path.join(OUT_DIR, leaf)         # 按尺寸/版本分目录，避免互相覆盖
    os.makedirs(out_dir, exist_ok=True)
    for i, p in enumerate(POSTERS, start=1):
        if args.only and i not in args.only:
            continue
        if p.get('skip'):
            print(f'[{i}] {p["out"]}  —— 已停用（并入其他图），跳过')
            continue
        img = compose(p, (W, H))
        sizes = []
        if args.format in ('both', 'png'):
            path = os.path.join(out_dir, p['out'])
            img.save(path)
            sizes.append(f'PNG {os.path.getsize(path) // 1024}KB')
        if args.format in ('both', 'jpg'):
            path = os.path.join(out_dir, os.path.splitext(p['out'])[0] + '.jpg')
            img.save(path, quality=92, subsampling=1, optimize=True)
            sizes.append(f'JPG {os.path.getsize(path) // 1024}KB')
        print(f'[{i}] {p["out"]}  {W}x{H}  ' + '  '.join(sizes))


if __name__ == '__main__':
    main()
