# -*- coding: utf-8 -*-
"""校验样例书：编码 / 章节 / 各章字数 / 空段落。"""
import re
import sys

try:
    sys.stdout.reconfigure(encoding='utf-8')
except Exception:
    pass

P = r'docs\宣发物料\00_原始素材\书籍\黄昏书店.txt'
raw = open(P, 'rb').read()
t = raw.decode('utf-8')
lines = t.splitlines()

print('BOM:', raw[:3] == b'\xef\xbb\xbf', '| CRLF 数:', raw.count(b'\r\n'), '| 字节:', len(raw))
zh = len(re.findall(r'[\u4e00-\u9fff]', t))
print('汉字数:', zh, '| 总行数:', len(lines), '| 非空段落:', sum(1 for l in lines if l.strip()))

chs = [(i, l.strip()) for i, l in enumerate(lines)
       if re.match(r'^第[一二三四五六七八九十]+章', l.strip())]
print('\n章节数:', len(chs))
bounds = [c[0] for c in chs] + [len(lines)]
for k, (ln, name) in enumerate(chs):
    seg = '\n'.join(lines[ln:bounds[k + 1]])
    n = len(re.findall(r'[\u4e00-\u9fff]', seg))
    print(f'  行{ln + 1:>4}  {name:<14} {n:>4} 汉字')

dup = [i + 1 for i in range(len(lines) - 1) if not lines[i].strip() and not lines[i + 1].strip()]
print('\n连续空行位置:', dup if dup else '无')
print('末行:', repr(lines[-1]))
