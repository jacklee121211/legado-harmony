# -*- coding: utf-8 -*-
"""指定时间区间、指定步长抽帧拼条，用于精确定位动作。用法：_finestrip.py 起 止 步长"""
import os
import subprocess
import sys
from io import BytesIO

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from PIL import Image, ImageDraw
import kit

CLIP = r'docs\宣发物料\00_原始素材\录屏\SVID_20261017_133647_1.mp4'
W = 150
t0, t1, step = float(sys.argv[1]), float(sys.argv[2]), float(sys.argv[3])
cols = int(sys.argv[4]) if len(sys.argv) > 4 else 8


def grab(t):
    r = subprocess.run(['ffmpeg', '-v', 'error', '-ss', f'{t:.3f}', '-i', CLIP,
                        '-frames:v', '1', '-vf', f'scale={W}:-1',
                        '-f', 'image2pipe', '-vcodec', 'png', '-'], capture_output=True)
    return Image.open(BytesIO(r.stdout)).convert('RGB') if r.stdout else None


times = []
t = t0
while t <= t1 + 1e-6:
    times.append(round(t, 2))
    t += step

fh = grab(t0).size[1]
rows = (len(times) + cols - 1) // cols
sheet = Image.new('RGB', (W * cols, (fh + 22) * rows), (18, 18, 20))
d = ImageDraw.Draw(sheet)
for i, tt in enumerate(times):
    im = grab(tt)
    if not im:
        continue
    x, y = (i % cols) * W, (i // cols) * (fh + 22)
    sheet.paste(im, (x, y))
    d.text((x + 4, y + 2), f'{tt:.2f}', font=kit.font('regular', 13), fill=(255, 235, 80))

p = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                 f'_strip_{t0}_{t1}.png')
sheet.save(p)
print('[ok]', p, sheet.size, '帧数', len(times))
