import time
from PIL import Image, ImageDraw, ImageFilter

W, H = 1920, 1080
shot = Image.open(r'D:\Arkts\3.8.11\legado-harmonydsh\promo\src\02_shelf_new.jpg')
bg = Image.new('RGB', (W, H), (10, 20, 60)).convert('RGBA')

t0 = time.time()
N = 10
for i in range(N):
    c = bg.copy()
    crop = shot.resize((650, 1400), Image.LANCZOS)
    c.alpha_composite(crop.convert('RGBA'), (100, 50))
    d = ImageDraw.Draw(c)
    d.text((50, 50), 'test', fill=(255, 255, 255))
dt = time.time() - t0
print("frames:", N, " total:", round(dt, 3), "s  per frame:", round(dt / N * 1000, 1), "ms")

# blur cost (glow per frame would be the killer)
sh = Image.new('RGBA', (W, H), (0, 0, 0, 0))
ImageDraw.Draw(sh).ellipse((200, -100, 1600, 600), fill=(90, 200, 255, 120))
t1 = time.time()
for i in range(5):
    sh.filter(ImageFilter.GaussianBlur(150))
print("gblur150 per frame:", round((time.time() - t1) / 5 * 1000, 1), "ms")
