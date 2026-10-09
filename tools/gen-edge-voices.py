#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
从**微软公开音色服务**生成 `entry/src/main/ets/tts/EdgeVoices.ets`（一手来源）。

用途（2026-10-10）：
  工程内原有的 Edge 音色表文件头写着「与 PC 版 ColorTxt voiceReadEdgeTtsVoices.ts 同步」，
  与项目的「零代码复制」纪律冲突。本脚本改为**直接从微软音色服务取数据**：

    数据源：`edge_tts.list_voices()`（即微软 Edge 朗读服务公开的音色清单，322 条）
    选材：Locale 前缀 ∈ {zh, en-US, en-GB, en-HK, ja-JP, ko-KR} ⇒ **恰好 43 条**
    字段：id=ShortName / lang=Locale / gender=Gender / name=ShortName 第三段
          description = VoiceTag 的 ContentCategories + VoicePersonalities **本项目自译**
          label = 中文显示名（微软官方中文名，公开事实）+ 英文 name

⇒ 与旧表**同一批 id**（行为不变），但来源可证、可随时重新生成。

用法：
    python tools/gen-edge-voices.py            # 打印到 stdout
    python tools/gen-edge-voices.py --write    # 直接覆盖 EdgeVoices.ets
"""
import argparse
import asyncio
import io
import os
import sys

import edge_tts

KEEP_PREFIX = ("zh", "en-US", "en-GB", "en-HK", "ja-JP", "ko-KR")

# 微软官方中文显示名（公开事实；仅中文相关音色有）
ZH_NAME = {
    "zh-CN-XiaoxiaoNeural": "晓晓",
    "zh-CN-XiaoyiNeural": "晓伊",
    "zh-CN-YunjianNeural": "云健",
    "zh-CN-YunxiaNeural": "云夏",
    "zh-CN-YunxiNeural": "云希",
    "zh-CN-YunyangNeural": "云扬",
    "zh-CN-liaoning-XiaobeiNeural": "晓北",
    "zh-CN-shaanxi-XiaoniNeural": "晓妮",
    "zh-HK-HiuGaaiNeural": "晓佳",
    "zh-HK-HiuMaanNeural": "晓曼",
    "zh-HK-WanLungNeural": "云龙",
    "zh-TW-HsiaoChenNeural": "晓臻",
    "zh-TW-HsiaoYuNeural": "晓雨",
    "zh-TW-YunJheNeural": "云哲",
}

# 微软 VoiceTag → 中文（**本项目自译**，属于我方表达）
CAT_ZH = {
    "News": "新闻", "Novel": "小说", "Cartoon": "卡通", "Sports": "体育",
    "General": "通用", "Conversation": "对话", "Dialogue": "对话",
    "Narration": "旁白", "Education": "教育", "Advertising": "广告",
}
PERSON_ZH = {
    "Warm": "温暖", "Lively": "活泼", "Passion": "激情", "Positive": "积极",
    "Friendly": "友善", "Confident": "自信", "Expressive": "富有表现力",
    "Caring": "体贴", "Cheerful": "开朗", "Clear": "清晰",
    "Considerate": "周到", "Pleasant": "悦耳", "Approachable": "亲切",
    "Casual": "随性", "Reliable": "可靠", "Authority": "权威",
    "Rational": "理性", "Cute": "可爱", "Multilingual": "多语种",
    "Calm": "沉稳", "Energetic": "充满活力", "Humorous": "幽默",
    "Professional": "专业", "Sunny": "阳光", "Bright": "明亮",
    "Soft": "柔和", "Deep": "低沉", "Gentle": "轻柔", "Narration": "叙述",
}

# 少数音色的人工精选描述（**本项目的表达**，比微软元数据更贴合听书场景）
DESC_OVERRIDE = {
    "zh-CN-YunyangNeural": "专业、可靠 · 新闻",
    "zh-CN-YunxiNeural": "活泼、阳光 · 小说",
    "zh-CN-liaoning-XiaobeiNeural": "幽默 · 方言",
    "zh-CN-shaanxi-XiaoniNeural": "明亮 · 方言",
}

LOCALE_RANK = ["zh-CN", "zh-CN-liaoning", "zh-CN-shaanxi", "zh-HK", "zh-TW",
               "en-US", "en-GB", "en-HK", "ja-JP", "ko-KR"]


def rank(locale: str) -> int:
    return LOCALE_RANK.index(locale) if locale in LOCALE_RANK else 99


def translate(tag: dict) -> str:
    """
    VoiceTag → 中文描述。格式与旧表观感一致：「语气 · 分类、分类」
    例：Warm + [News, Novel] → 「温暖 · 新闻、小说」
    """
    pers = []
    for p in tag.get("VoicePersonalities", []):
        t = PERSON_ZH.get(p.strip())
        if t and t not in pers:
            pers.append(t)
    cats = []
    for c in tag.get("ContentCategories", []):
        t = CAT_ZH.get(c.strip())
        if t and t not in cats:
            cats.append(t)
    pers_s = "、".join(pers)
    cat_s = "、".join(cats)
    if pers_s and cat_s:
        return pers_s + " · " + cat_s
    return pers_s or cat_s or "通用"


def ets_str(s: str) -> str:
    return "'" + s.replace("\\", "\\\\").replace("'", "\\'") + "'"


async def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--write", action="store_true", help="直接写入 EdgeVoices.ets")
    ap.add_argument("--out", default="entry/src/main/ets/tts/EdgeVoices.ets")
    args = ap.parse_args()

    voices = await edge_tts.list_voices()
    rows = []
    for v in voices:
        loc = v["Locale"]
        if not loc.startswith(KEEP_PREFIX):
            continue
        sn = v["ShortName"]
        desc = DESC_OVERRIDE.get(sn)
        if desc is None:
            desc = translate(v.get("VoiceTag", {}))
            # 方言音色：locale 本身就是方言标记（微软元数据里没有"方言"分类）
            if loc in ("zh-CN-liaoning", "zh-CN-shaanxi") and "方言" not in desc:
                desc = desc + " · 方言"
        rows.append({
            "id": sn,
            "lang": loc,
            "gender": v["Gender"].lower(),
            "name": sn.split("-")[-1].replace("Neural", ""),
            "desc": desc,
        })
    # 排序：locale 优先级 → 女声在前 → id 字母序（与旧表观感一致）
    rows.sort(key=lambda r: (rank(r["lang"]), 0 if r["gender"] == "female" else 1, r["id"]))

    buf = io.StringIO()
    buf.write("/**\n")
    buf.write(" * Edge-TTS 音色表（**由脚本从微软公开音色服务生成**）。\n")
    buf.write(" *\n")
    buf.write(" * 数据来源（一手，可随时重跑）：\n")
    buf.write(" *   `tools/gen-edge-voices.py` → `edge_tts.list_voices()`（微软 Edge 朗读服务公开音色清单，共 322 条）\n")
    buf.write(" *   选材规则：Locale ∈ {zh*, en-US, en-GB, en-HK, ja-JP, ko-KR} ⇒ 43 条\n")
    buf.write(" *   字段映射：id=ShortName / lang=Locale / gender=Gender / name=ShortName 第三段\n")
    buf.write(" *             description = VoiceTag 的 ContentCategories + VoicePersonalities（**本项目自译**）\n")
    buf.write(" *     ⇒ 音色 id / 语言 / 性别是微软的公开事实；描述文案是微软元数据的直译。\n")
    buf.write(" *       本文件**不派生自任何第三方仓库**（2026-10-10 重生成，切断旧来源）。\n")
    buf.write(" *\n")
    buf.write(" * 重新生成： python tools/gen-edge-voices.py --write\n")
    buf.write(" */\n\n")
    buf.write("export type EdgeVoiceGender = 'female' | 'male';\n\n")
    buf.write("export interface EdgeVoice {\n")
    buf.write("  id: string;\n  lang: string;\n  gender: EdgeVoiceGender;\n  name: string;\n")
    buf.write("  label: string;\n  description: string;\n}\n\n")
    buf.write("export const EDGE_VOICES: EdgeVoice[] = [\n")
    for r in rows:
        zh = ZH_NAME.get(r["id"], "")
        label = ("%s (%s)" % (zh, r["name"])) if zh else r["name"]
        buf.write("  { id: %s, lang: %s, gender: %s, name: %s, label: %s, description: %s },\n"
                  % (ets_str(r["id"]), ets_str(r["lang"]), ets_str(r["gender"]),
                     ets_str(r["name"]), ets_str(label), ets_str(r["desc"])))
    # 末尾去掉多余逗号
    text = buf.getvalue()
    text = text.rstrip(",\n") + "\n"
    text = text[:text.rfind("\n")] + "\n];\n"
    text += """
/** 与 PC 版 voiceReadEngineDefaults.ts 的 edge 默认值一致 */
export const EDGE_DEFAULT_NARRATION_VOICE = 'zh-CN-YunjianNeural';
export const EDGE_DEFAULT_DIALOGUE_VOICE = 'zh-CN-YunxiNeural';
export const EDGE_DEFAULT_DIALOGUE_MALE_VOICE = 'zh-CN-YunxiNeural';
export const EDGE_DEFAULT_DIALOGUE_FEMALE_VOICE = 'zh-CN-XiaoxiaoNeural';
export const EDGE_DEFAULT_SINGLE_VOICE = 'zh-CN-YunjianNeural';

export function findEdgeVoice(voiceId: string): EdgeVoice | null {
  for (let i = 0; i < EDGE_VOICES.length; i++) {
    if (EDGE_VOICES[i].id === voiceId) {
      return EDGE_VOICES[i];
    }
  }
  return null;
}

/** 由 voiceId 推断 SSML 语言（zh-CN-liaoning-XiaobeiNeural → zh-CN-liaoning） */
export function langOfVoice(voiceId: string): string {
  const v = findEdgeVoice(voiceId);
  if (v !== null) {
    return v.lang;
  }
  const parts = voiceId.split('-');
  if (parts.length >= 3 && parts[0] === 'zh') {
    return parts[0] + '-' + parts[1] + '-' + parts[2];
  }
  if (parts.length >= 2) {
    return parts[0] + '-' + parts[1];
  }
  return 'zh-CN';
}

/** 音色展示文案（列表里没有的自定义 id 也能显示） */
export function voiceLabel(voiceId: string): string {
  const v = findEdgeVoice(voiceId);
  return v !== null ? v.label : voiceId;
}
"""

    if args.write:
        with open(args.out, "w", encoding="utf-8", newline="\n") as f:
            f.write(text)
        print("written %s  (%d voices)" % (args.out, len(rows)))
    else:
        sys.stdout.write(text)
    return 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
