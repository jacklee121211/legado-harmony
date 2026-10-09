#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
喵阅「AI 听书」—— 本机 TTS 服务（零成本 / 零密钥）

用途：在没有 OpenAI/火山/阿里 等付费 Key 的情况下，验证 App 的「AI 听书」全链路。
原理：在 PC 上起一个 **OpenAI 兼容** 的 `POST /v1/audio/speech` 服务，手机通过局域网访问。

两种后端（自动选择，可用 --backend 指定）：
  · edge  —— 微软 Edge TTS（免费、无 Key、音色多、输出 mp3）。
             需要先装： pip install edge-tts
  · sapi  —— Windows 自带语音合成（完全离线、无需联网、无需安装、输出 wav）。
             用 PowerShell + System.Speech。

为什么这两个后端正好够用：App 侧已支持 mp3 / wav / pcm 三种容器，
并且**按音频字节内容嗅探真实格式**（服务端忽略 response_format 也不会出错）。

用法：
    python local_tts_server.py                 # 自动选后端，端口 8880
    python local_tts_server.py --port 9000
    python local_tts_server.py --backend sapi  # 强制离线
启动后它会打印手机端要填的「接口地址」。

App 端怎么填（阅读器 → 听书 → AI 语音 → 接入设置）：
    接口地址   http://<本机内网IP>:8880/v1
    API Key    local          ← 本服务不校验，随便填（不能留空）
    模型       tts-1          ← 本服务忽略
    输出格式   mp3
    音色       zh-CN-XiaoxiaoNeural（edge）/ 空 或 Huihui（sapi）
               —— App 的「音色」区允许**手填任意 id**，直接填即可

注意：
  1. 手机与 PC 必须在同一 Wi-Fi；
  2. Windows 防火墙首次会弹窗 → 必须允许「专用网络」；
  3. 明文 HTTP 在 HarmonyOS Stage 模型下**无需配置即可用**
     （官方 FAQ documentId: FAQ/网络/网络_Network/Stage模型如何配置支持http明文传输/faqs-network-16
      原文：「无需配置，支持HTTP明文传输数据。」）
"""
import argparse
import json
import os
import re
import socket
import subprocess
import sys
import tempfile
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

VERSION = "1.0.0"

# 默认音色：App 内置的建议音色（alloy/onyx/nova…）在 Edge TTS 里不存在，
# 所以认不出来的 voice 一律回落到默认音色并打日志，避免用户第一次就失败。
EDGE_DEFAULT_VOICE = "zh-CN-XiaoxiaoNeural"
SAPI_DEFAULT_VOICE = ""  # 空 = 用系统默认音色


def _harden_stdout() -> None:
    """
    控制台编码加固（2026-10-10 实测教训）。
    中文 Windows 控制台默认 GBK：`print("✅")` 会抛 UnicodeEncodeError，
    而异常发生在启动自检里 ⇒ **整个服务起不来**。两层防护：
      ① 尽量把 stdout/stderr 切到 UTF-8；
      ② 万一不行，log() 内部再兜一层（见下）。
    """
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(encoding="utf-8", errors="replace")
        except Exception:
            pass


def log(msg: str) -> None:
    line = "[%s] %s" % (time.strftime("%H:%M:%S"), msg)
    try:
        print(line, flush=True)
    except Exception:
        # 兜底：把不可编码字符换成 '?' 再写，绝不因为日志把服务搞崩
        try:
            sys.stdout.write(line.encode("ascii", "replace").decode("ascii") + "\n")
            sys.stdout.flush()
        except Exception:
            pass


def _ipconfig_pairs():
    """解析 Windows `ipconfig`，返回 [(适配器名, IPv4)]（用于区分真实网卡与虚拟网卡）"""
    pairs = []
    try:
        raw = subprocess.run(["ipconfig"], capture_output=True).stdout
    except Exception:
        return pairs
    text = None
    for enc in ("gbk", "utf-8"):
        try:
            text = raw.decode(enc)
            break
        except Exception:
            continue
    if not text:
        return pairs
    name = ""
    for line in text.splitlines():
        s = line.rstrip()
        if not s.strip():
            name = ""
            continue
        if not s.startswith(" ") and s.endswith(":"):
            name = s[:-1].strip()
            continue
        m = re.search(r"IPv4.*?:\s*([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)", s)
        if m and name:
            pairs.append((name, m.group(1)))
    return pairs


# 虚拟网卡关键字（出现即重罚）——2026-10-10 实测教训：脚本把 Clash 的 TUN 地址
# (198.18.0.1) 排在最前面，用户抄了它 ⇒ 手机永远连不上。
VIRTUAL_HINTS = (
    "vethernet", "wsl", "hyper-v", "vmware", "virtualbox", "tailscale", "zerotier",
    "tun", "tap", "clash", "loopback", "bluetooth", "npcap", "openvpn", "wireguard",
    "docker", "radmin", "virtual",
)
LAN_HINTS = ("wlan", "wi-fi", "wifi", "无线", "ethernet", "以太网", "本地连接")


def _score_ip(name: str, ip: str) -> int:
    n = name.lower()
    s = 0
    for h in VIRTUAL_HINTS:
        if h in n:
            s -= 100
            break
    for h in LAN_HINTS:
        if h in n:
            s += 100
            break
    if ip.startswith("192.168."):
        s += 50
    elif ip.startswith("10."):
        s += 40
    elif ip.startswith("172."):
        s += 10
    if ip.startswith("198.18.") or ip.startswith("198.19."):
        s -= 200  # 代理 TUN 常用段
    if ip.startswith("169.254."):
        s -= 200  # link-local
    return s


def lan_ips():
    """
    按"像真实局域网"排序的候选地址：[(score, ip, name)]，第一个带★（最可能是手机该填的）。

    ⚠️ 2026-10-10 实测教训：只靠"出口网卡地址"会把代理 TUN（198.18.x）排在最前，
    用户抄了它 ⇒ 手机永远连不上。现在**两条来源合并后统一打分**，
    并显式重罚代理/link-local/虚拟网卡段，保证 192.168.x 优先。
    """
    cands = []  # (ip, name)
    for name, ip in _ipconfig_pairs():
        cands.append((ip, name))
    names_ok = len(cands) > 0
    if not names_ok:
        # ipconfig 不可用（受限环境/非 Windows）：用 socket 枚举本机所有 IPv4
        try:
            for info in socket.getaddrinfo(socket.gethostname(), None, socket.AF_INET):
                cands.append((info[4][0], "本机地址"))
        except Exception:
            pass
        try:
            sk = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            sk.connect(("8.8.8.8", 80))
            cands.append((sk.getsockname()[0], "出口网卡"))
            sk.close()
        except Exception:
            pass

    scored = []
    for ip, name in cands:
        if ip.startswith("127."):
            continue
        scored.append((_score_ip(name, ip), ip, name))
    scored.sort(key=lambda t: (-t[0], t[1]))
    seen, out = set(), []
    for sc, ip, name in scored:
        if ip in seen:
            continue
        seen.add(ip)
        out.append((sc, ip, name))
    return out


def has_edge_tts() -> bool:
    try:
        import edge_tts  # noqa: F401
        return True
    except Exception:
        return False


# ── 后端 1：edge-tts（免费、无 Key、mp3）──────────────────────────────────────
def synth_edge(text: str, voice: str, speed: float, proxy: str = "") -> bytes:
    import asyncio
    import edge_tts

    rate = int(round((speed - 1.0) * 100))
    rate_s = ("+" if rate >= 0 else "") + str(rate) + "%"
    kw = {}
    if proxy:
        kw["proxy"] = proxy

    async def run() -> bytes:
        comm = edge_tts.Communicate(text, voice, rate=rate_s, **kw)
        buf = bytearray()
        async for chunk in comm.stream():
            if chunk.get("type") == "audio":
                buf.extend(chunk["data"])
        return bytes(buf)

    return asyncio.run(run())


# ── 后端 2：Windows SAPI（离线、wav）────────────────────────────────────────
SAPI_SCRIPT = r"""
param([string]$TextFile, [string]$OutFile, [string]$Voice, [int]$Rate)
Add-Type -AssemblyName System.Speech
$synth = New-Object System.Speech.Synthesis.SpeechSynthesizer
if ($Voice -ne "") { try { $synth.SelectVoice($Voice) } catch { } }
$rate = $Rate
if ($rate -gt 10) { $rate = 10 }
if ($rate -lt -10) { $rate = -10 }
$synth.Rate = $rate
$text = Get-Content -LiteralPath $TextFile -Raw -Encoding UTF8
$synth.SetOutputToWaveFile($OutFile)
$synth.Speak($text)
$synth.Dispose()
"""


def synth_sapi(text: str, voice: str, speed: float) -> bytes:
    rate = int(round((speed - 1.0) * 10))
    tmpdir = tempfile.mkdtemp(prefix="miaoyue-tts-")
    txt = os.path.join(tmpdir, "in.txt")
    wav = os.path.join(tmpdir, "out.wav")
    ps1 = os.path.join(tmpdir, "run.ps1")
    with open(txt, "w", encoding="utf-8") as f:
        f.write(text)
    with open(ps1, "w", encoding="utf-8") as f:
        f.write(SAPI_SCRIPT)
    cmd = [
        "powershell", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
        "-File", ps1, "-TextFile", txt, "-OutFile", wav, "-Voice", voice, "-Rate", str(rate),
    ]
    subprocess.run(cmd, check=True, capture_output=True)
    with open(wav, "rb") as f:
        return f.read()


def pick_voice(backend: str, voice: str) -> str:
    v = (voice or "").strip()
    known_prefix = (
        "zh-CN-", "zh-HK-", "zh-TW-", "en-US-", "en-GB-", "ja-JP-", "ko-KR-",
        "Microsoft", "Huihui", "Yaoyao", "Kangkang", "Xiaoxiao", "Yunxi",
    )
    if v and any(v.startswith(p) or p in v for p in known_prefix):
        return v
    default = EDGE_DEFAULT_VOICE if backend == "edge" else SAPI_DEFAULT_VOICE
    if v:
        log("voice '%s' 不是本机可用音色 → 回落默认 '%s'（可在 App 音色区手填上表里的 id）"
            % (v, default or "系统默认"))
    return default


def wav_to_44k_stereo(wav_bytes: bytes) -> bytes:
    """
    **仅调试用**：把单声道 16bit WAV 转成 44.1kHz 双声道 WAV。

    目的（2026-10-10）：App 侧 `PcmShape.shapePcmToTarget` 有两条分支一直没被真机压到
    ——「立体声折叠」与「重采样」，因为 edge-tts 与 SAPI 都是单声道。
    打开 `--force-44k-stereo` 后，手机上任意一次试听/朗读都会走这两条分支。

    实现：纯标准库（struct 手工解析 + 最近邻 2 倍上采样 + 复制到左右声道）。
    ⚠️ 音质不是重点，这是**验证用**信号；别拿它当正常音质配置。
    """
    import struct

    if len(wav_bytes) < 44 or wav_bytes[0:4] != b"RIFF" or wav_bytes[8:12] != b"WAVE":
        raise ValueError("不是 WAV")
    pos = 12
    fmt_chunk = None
    data = None
    while pos + 8 <= len(wav_bytes):
        cid = wav_bytes[pos:pos + 4]
        csize = struct.unpack_from("<I", wav_bytes, pos + 4)[0]
        body = wav_bytes[pos + 8: pos + 8 + csize]
        if cid == b"fmt ":
            fmt_chunk = body
        elif cid == b"data":
            data = body
        pos += 8 + csize + (csize & 1)  # 块按偶数字节对齐
    if fmt_chunk is None or data is None or len(fmt_chunk) < 16:
        raise ValueError("WAV 缺少 fmt/data 块")
    audio_format, channels, rate, _br, _ba, bits = struct.unpack_from("<HHIIHH", fmt_chunk, 0)
    if audio_format != 1 or bits != 16:
        raise ValueError("只支持 16bit PCM（fmt=%d bits=%d）" % (audio_format, bits))

    n = len(data) // 2
    samples = struct.unpack_from("<%dh" % n, data, 0)
    # 单声道：每样本复制两次（2 倍上采样）；多声道：取第一声道
    if channels > 1:
        mono = samples[0::channels]
    else:
        mono = samples
    out_rate = 44100
    # 最近邻按比例展开（输入 22050 → 输出 44100 即每样本 2 份）
    step = rate / float(out_rate)
    out_n = int(len(mono) / step)
    frames = bytearray()
    for i in range(out_n):
        s = mono[min(int(i * step), len(mono) - 1)]
        frames += struct.pack("<hh", s, s)  # 左右相同
    header = b"RIFF" + struct.pack("<I", 36 + len(frames)) + b"WAVE"
    header += b"fmt " + struct.pack("<IHHIIHH", 16, 1, 2, out_rate,
                                    out_rate * 4, 4, 16)
    header += b"data" + struct.pack("<I", len(frames))
    return header + bytes(frames)


class Handler(BaseHTTPRequestHandler):
    server_version = "MiaoyueLocalTTS/" + VERSION
    backend = "edge"
    proxy = ""
    force_44k_stereo = False
    lock = None

    def _json(self, code: int, obj) -> None:
        body = json.dumps(obj, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None:  # noqa: N802
        if self.path.startswith("/v1/models"):
            self._json(200, {"object": "list", "data": [{"id": "local-tts", "object": "model"}]})
            return
        self._json(404, {"error": {"message": "not found: " + self.path}})

    def do_POST(self) -> None:  # noqa: N802
        if not self.path.startswith("/v1/audio/speech"):
            self._json(404, {"error": {"message": "只有 /v1/audio/speech；收到 " + self.path}})
            return
        try:
            n = int(self.headers.get("Content-Length") or "0")
            req = json.loads(self.rfile.read(n).decode("utf-8") or "{}")
        except Exception as e:
            self._json(400, {"error": {"message": "请求体不是合法 JSON: %s" % e}})
            return

        text = (req.get("input") or req.get("text") or "").strip()
        if not text:
            self._json(400, {"error": {"message": "缺少 input 字段"}})
            return
        try:
            speed = float(req.get("speed") or 1.0)
        except Exception:
            speed = 1.0
        fmt = (req.get("response_format") or "mp3").strip().lower()
        voice = pick_voice(self.backend, req.get("voice") or "")

        t0 = time.time()
        try:
            with Handler.lock:  # 串行化：两个后端都不适合并发
                if self.backend == "edge":
                    audio = synth_edge(text, voice, speed, self.proxy)
                    actual = "mp3"
                else:
                    audio = synth_sapi(text, voice, speed)
                    actual = "wav"
        except Exception as e:
            log("合成失败: %s" % e)
            self._json(500, {"error": {"message": "本机合成失败: %s" % e}})
            return

        if not audio:
            self._json(500, {"error": {"message": "本机后端没产出音频"}})
            return

        # 调试开关：强制 44.1kHz 立体声（压 App 侧的折叠+重采样分支）
        if self.force_44k_stereo:
            if actual == "wav":
                try:
                    audio = wav_to_44k_stereo(audio)
                    log("调试：已转 44.1kHz 立体声（%d 字节）" % len(audio))
                except Exception as e:
                    log("调试转换失败，按原样返回：%s" % e)
            else:
                log("调试：--force-44k-stereo 只支持 wav 后端（edge 是 mp3，无法在纯标准库下解码）")

        log("合成 %d 字 → %s %.1fKB 用时 %.2fs (voice=%s speed=%.2f 请求格式=%s)"
            % (len(text), actual, len(audio) / 1024.0, time.time() - t0, voice or "默认", speed, fmt))
        self.send_response(200)
        self.send_header("Content-Type", "audio/mpeg" if actual == "mp3" else "audio/wav")
        self.send_header("Content-Length", str(len(audio)))
        self.end_headers()
        self.wfile.write(audio)

    def log_message(self, fmt, *args):  # 静音默认访问日志（我们自己打更有用的）
        return


def main() -> int:
    _harden_stdout()
    ap = argparse.ArgumentParser(description="喵阅 AI 听书 · 本机 TTS 服务")
    ap.add_argument("--port", type=int, default=8880)
    ap.add_argument("--host", default="0.0.0.0")
    ap.add_argument("--backend", choices=["auto", "edge", "sapi"], default="auto")
    ap.add_argument("--proxy", default="",
                    help="edge 后端走代理，例如 http://127.0.0.1:7890（留空则读 HTTPS_PROXY 环境变量）")
    ap.add_argument("--force-44k-stereo", action="store_true",
                    help="[调试] 把输出强制转成 44.1kHz 立体声 WAV（仅 wav 后端有效），"
                         "用于压 App 侧「立体声折叠 + 重采样」分支")
    args = ap.parse_args()

    import threading
    Handler.lock = threading.Lock()

    if args.backend == "auto":
        backend = "edge" if has_edge_tts() else "sapi"
    else:
        backend = args.backend
    if backend == "edge" and not has_edge_tts():
        log("选了 edge 但没装 edge-tts ⇒ 改走 sapi（离线）。装法： pip install edge-tts")
        backend = "sapi"
    Handler.backend = backend

    # 代理：命令行优先，否则读环境变量（2026-10-10 加：真机日志证明 PC→微软 会连不上）
    proxy = args.proxy.strip() or (
        os.environ.get("HTTPS_PROXY") or os.environ.get("https_proxy")
        or os.environ.get("ALL_PROXY") or os.environ.get("all_proxy") or "")
    Handler.proxy = proxy
    Handler.force_44k_stereo = bool(args.force_44k_stereo)
    if proxy:
        log("edge 后端将经代理出网：%s" % proxy)

    log("喵阅本机 TTS 服务 v%s 启动，后端 = %s" % (VERSION, backend))

    # ── 启动自检（2026-10-10 加）──────────────────────────────────────────────
    # 真机教训：App 侧只看到 `服务端返回 500 … Cannot connect to host
    # speech.platform.bing.com:443`，用户以为是自己的网络问题。
    # 现在启动时**先试合成一个字**，把结论直接打在控制台，并给出可行替代方案。
    # ⚠️ 日志里只用 ASCII 标记（[OK]/[FAIL]）——中文 Windows 控制台是 GBK，emoji 会崩。
    if backend == "edge":
        log("自检：正在试连微软语音服务（合成「好」）…")
        try:
            probe = synth_edge("好", EDGE_DEFAULT_VOICE, 1.0, proxy)
            if probe:
                log("[OK] 自检通过：微软语音服务可达（拿到 %d 字节音频）" % len(probe))
            else:
                log("[WARN] 自检异常：没拿到音频，但也没抛错")
        except Exception as e:
            log("[FAIL] 自检失败：连不上微软语音服务：%s" % e)
            log("  => 本后端的音频出不来（App 侧会看到 500 + Cannot connect to host）。三种解法：")
            log("     1) 给本服务配代理： --proxy http://127.0.0.1:7890（换成你代理的端口）")
            log("     2) 让代理软件把 Python 进程也接管（TUN 模式通常可以，需确认已开）")
            log("     3) 直接换离线后端： --backend sapi   <= 零依赖、不联网、立刻能用")
            log("  继续启动（你仍可改用 sapi 重启）")

    if backend == "edge":
        log("edge 后端可用音色示例：zh-CN-XiaoxiaoNeural / zh-CN-YunxiNeural / zh-CN-YunjianNeural")
        log("  查全部： python -m edge_tts --list-voices")
    else:
        log("sapi 后端（离线）。可用音色查法（PowerShell）：")
        log("  Add-Type -AssemblyName System.Speech; "
            "(New-Object System.Speech.Synthesis.SpeechSynthesizer).GetInstalledVoices()"
            " | %{ $_.VoiceInfo.Name }")
    log("手机端「接口地址」请填（同一 Wi-Fi）：")
    cands = lan_ips()
    if not cands:
        log("    http://<本机内网IP>:%d/v1   ← 没自动识别出来，请用 ipconfig 自己找" % args.port)
    for idx, (sc, ip, name) in enumerate(cands):
        mark = "★推荐 →" if idx == 0 else "        "
        log("    %s http://%s:%d/v1      [%s]" % (mark, ip, args.port, name))
    if len(cands) > 1:
        log("    带★的那条是真实局域网网卡；其余多为虚拟网卡（代理 TUN / WSL / VMware），填了连不上。")
    log("API Key 随便填（例如 local），模型填 tts-1，输出格式 mp3。Ctrl+C 结束。")

    srv = ThreadingHTTPServer((args.host, args.port), Handler)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        log("bye")
    finally:
        srv.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
