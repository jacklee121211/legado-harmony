/**
 * 播控中心 / 锁屏 / 实况窗（灵动岛）的媒体封面：`AVMetadata.mediaImage` = **应用图标**
 *
 * ── 需求（用户口径 2026-10-08）───────────────────────────────────────────────
 * 「我需要不是书的封面，我需要就是 app 图标，正好正方形，天生完美」
 * ⇒ 封面固定用应用图标：天然 1:1，不需要任何裁切/留边，直接满足官方对封面的比例要求。
 *
 * ── 为什么之前是个"正方形 + 右下角小头像"（根因）────────────────────────────
 * 应用此前**从未设置过 `mediaImage`**（全工程 grep 零命中）⇒ 系统回退默认占位图：
 * 大方块 + 角落一个小小的应用图标（那枚小图是系统自己填的 `AVMetadata.bundleIcon`，
 * 官方注明「no need to be set by application」）。
 *
 * ── 官方依据（原文）──────────────────────────────────────────────────────────
 *  · `开发指南/AVSession_Kit_音视频播控服务/应用接入播控自检/应用接入播控检查项详细说明/
 *    基础播控/basic-playback-control` §媒体封面：
 *      「应用提供媒体内容的封面图片（AVMetadata.mediaImage）……**mediaImage设置PixelMap
 *        性能更优**。」
 *      「音乐类媒体内容应提供比例为**1:1的方形封面图片**，建议分辨率为**800px*800px**
 *        （如果应用提供的图片分辨率更大，将被压缩到800px*800px显示），最小分辨率是
 *        **300px*300px**。」
 *      「如果应用提供的媒体封面比例或分辨率不满足要求，将会被自动缩放、裁切到合适大小。
 *        这可能导致封面图片内的信息损失或模糊，体验下降。」
 *    ⇒ 应用图标是正方形、按 800×800 输出、无透明底 ⇒ **三条全都天然满足**。
 *  · 实况窗与播控中心**同源**（应用不需要接 Live View Kit，系统自动接）——
 *    documentId `FAQ/实况视图服务_Live_View_Kit/哪些系统服务会自动接入实况窗/faqs-liveview-5`
 *      原文：「自动接入实况窗的系统服务包括以下：* AVSession Kit（音视频播控服务）* Call
 *      Service Kit（通话服务）」
 *    ⇒ **设一次 `mediaImage`，播控中心 / 锁屏 / 实况窗三处一起有封面。**
 *  · SDK `@ohos.multimedia.avsession.d.ts:3065`：`mediaImage?: image.PixelMap | string;`
 *    （string 形态官方 API 表注明「**仅支持网络路径**」⇒ 本地图标必须走 PixelMap）
 *
 * ── 为什么不用 `getDrawableDescriptor(appInfo.iconId)` 那条"系统合成图标"的路 ─────
 *  · `bundleManager.getBundleInfoForSelfSync`（`@ohos.bundle.bundleManager.d.ts:1041`）+
 *    `ApplicationInfo.iconId`（`bundleManager/ApplicationInfo.d.ts:120`）+
 *    `resourceManager.getDrawableDescriptor(resId, density?, type?)`
 *    （`@ohos.resourceManager.d.ts:2099`，文档：「Obtains the DrawableDescriptor object
 *      **for icon display**…type 0: Icon resource of the application」）+
 *    `DrawableDescriptor.getPixelMap()`（`@ohos.arkui.drawableDescriptor.d.ts:86`）
 *    这条链**看起来很对**，但我们的图标是**分层图标**（`app.json5: "icon": "$media:layered_image"`
 *    ⇒ `LayeredDrawableDescriptor`，见该文件 `:175`）。分层描述符另有
 *    `getForeground()/getBackground()/getMask()`，而 `getPixelMap()` 在分层场景下
 *    **是返回合成图还是只返回前景层，SDK 声明里没有写** ⇒ 若只返回前景，就是一个
 *    **透明底黑猫**，在深色卡片上几乎看不见（灾难性）。故不采用。
 *
 * ── 本实现：自己把两层合成（前景 over 背景），结果可控且与桌面图标一致 ──────────
 *  ① 背景层 `$r('app.media.icon_background')`（纯色，256²）→ 解码成 **800×800 可写画布**
 *  ② 前景层 `$r('app.media.icon')`（透明底黑猫，1024²）→ 解码成 800×800 RGBA
 *  ③ `readPixelsToBuffer` 取两层像素 → 按 `ImageInfo.alphaType` 做 source-over 合成
 *     （PREMUL / UNPREMUL 两种都按声明原文分别处理，见 `blendOver`）
 *  ④ `writeBufferToPixels` 写回画布 ⇒ 一张不透明、1:1、800×800 的应用图标
 *
 * 容错：任何一步失败都返回 `null`（**不设 mediaImage**，保持系统默认占位图），
 * 绝不影响朗读主链路；合成前置校验（尺寸/stride）不满足时退回**纯背景色**，
 * 宁可给一张品牌色方块，也不给一张错位的花屏。
 *
 * 相关声明原文：
 *  · `resourceManager.getMediaContent(resId: number): Promise<Uint8Array>`
 *    —— `@ohos.resourceManager.d.ts:1887`（`Resource` 形态的旧重载已 `@deprecated` ⇒ 用 `.id`）
 *  · `Resource.id: number` —— `global/resource.d.ts:58`
 *  · `image.createImageSource(buf: ArrayBuffer)` —— `@ohos.multimedia.image.d.ts:4258`
 *  · `ImageSource.createPixelMap(options?: DecodingOptions)`，`DecodingOptions` 的
 *    `editable` / `desiredSize` / `desiredPixelFormat` —— 同文件 `DecodingOptions` 定义
 *  · `PixelMap.readPixelsToBuffer(dst): Promise<void>`（`:4570`）、
 *    `writeBufferToPixels(src): Promise<void>`（`:4873`）、`getImageInfoSync()`（`:4952`）
 *  · `ImageInfo.alphaType`、`enum AlphaType { UNKNOWN=0, OPAQUE=1, PREMUL=2, UNPREMUL=3 }`
 */
import { image } from '@kit.ImageKit';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN = 0x0001;
const TAG = 'SessionCover';
/** 官方建议的封面分辨率（正方形，1:1） */
const ICON_SIZE: number = 800;

/** 解码一张 media 资源为 ImageSource（Resource 形态重载已废弃 ⇒ 用 resId） */
async function mediaSource(ctx: common.UIAbilityContext, resId: number): Promise<image.ImageSource | null> {
  try {
    const bytes: Uint8Array = await ctx.resourceManager.getMediaContent(resId);
    if (bytes.byteLength === 0) {
      return null;
    }
    // Uint8Array 未必从 0 偏移开始 ⇒ 取它自己的那段（工程先例：TtsEngine 里 pcm.buffer.slice）
    const buf: ArrayBuffer = bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength);
    return image.createImageSource(buf);
  } catch (e) {
    hilog.warn(DOMAIN, TAG, 'icon: read resource %{public}d failed %{public}s', resId,
      e instanceof Error ? e.message : String(e));
    return null;
  }
}

/** source-over：把前景合成到已铺满背景的画布上（原地修改 dst） */
function blendOver(dst: Uint8Array, src: Uint8Array, alphaType: image.AlphaType): void {
  // 声明原文：PREMUL = "Premultiplied alpha"；UNPREMUL = "RGB non-premultiplied alpha"
  const premul: boolean = alphaType === image.AlphaType.PREMUL;
  for (let i = 0; i + 3 < dst.length && i + 3 < src.length; i += 4) {
    const a: number = src[i + 3];
    if (a === 0) {
      continue;
    }
    if (a === 255) {
      dst[i] = src[i];
      dst[i + 1] = src[i + 1];
      dst[i + 2] = src[i + 2];
      continue;
    }
    const f: number = a / 255;
    const inv: number = 1 - f;
    if (premul) {
      // 源已乘过 alpha：直接叠加，不再乘
      dst[i] = clamp255(src[i] + dst[i] * inv);
      dst[i + 1] = clamp255(src[i + 1] + dst[i + 1] * inv);
      dst[i + 2] = clamp255(src[i + 2] + dst[i + 2] * inv);
    } else {
      dst[i] = clamp255(src[i] * f + dst[i] * inv);
      dst[i + 1] = clamp255(src[i + 1] * f + dst[i + 1] * inv);
      dst[i + 2] = clamp255(src[i + 2] * f + dst[i + 2] * inv);
    }
  }
}

function clamp255(v: number): number {
  const n: number = Math.round(v);
  return n < 0 ? 0 : (n > 255 ? 255 : n);
}

/**
 * 生成"应用图标"封面：1:1、不透明、≤800×800。
 * @returns PixelMap；失败返回 `null`（调用方保持系统默认占位图）
 */
export async function loadAppIconCover(ctx: common.UIAbilityContext): Promise<image.PixelMap | null> {
  let base: image.PixelMap | null = null;
  let fg: image.PixelMap | null = null;
  try {
    // ① 背景层 → 目标尺寸的**可写**画布（editable 才能 writeBufferToPixels）
    const bgSrc: image.ImageSource | null = await mediaSource(ctx, $r('app.media.icon_background').id);
    if (bgSrc === null) {
      hilog.warn(DOMAIN, TAG, 'icon: background resource empty');
      return null;
    }
    try {
      base = await bgSrc.createPixelMap({
        editable: true,
        desiredSize: { width: ICON_SIZE, height: ICON_SIZE },
        desiredPixelFormat: image.PixelMapFormat.RGBA_8888
      });
    } finally {
      bgSrc.release();
    }

    // ② 前景层（透明底图标）→ 同尺寸 RGBA
    const fgSrc: image.ImageSource | null = await mediaSource(ctx, $r('app.media.icon').id);
    if (fgSrc === null) {
      hilog.warn(DOMAIN, TAG, 'icon: foreground resource empty');
      return base;
    }
    try {
      fg = await fgSrc.createPixelMap({
        desiredSize: { width: ICON_SIZE, height: ICON_SIZE },
        desiredPixelFormat: image.PixelMapFormat.RGBA_8888
      });
    } finally {
      fgSrc.release();
    }

    // ③ 合成前置校验：尺寸 / stride / 像素格式必须严格符合预期，否则宁可只给背景色。
    //   · stride 必须是 800×4 ⇒ 否则按 4 字节步进会串行（花屏）
    //   · pixelFormat 必须是 RGBA_8888 ⇒ 否则字节序可能不是 R,G,B,A（颜色错乱）
    const bgInfo: image.ImageInfo = base.getImageInfoSync();
    const fgInfo: image.ImageInfo = fg.getImageInfoSync();
    const need: number = ICON_SIZE * 4;
    if (bgInfo.size.width !== ICON_SIZE || bgInfo.size.height !== ICON_SIZE
      || fgInfo.size.width !== ICON_SIZE || fgInfo.size.height !== ICON_SIZE
      || bgInfo.stride !== need || fgInfo.stride !== need
      || bgInfo.pixelFormat !== image.PixelMapFormat.RGBA_8888
      || fgInfo.pixelFormat !== image.PixelMapFormat.RGBA_8888) {
      hilog.warn(DOMAIN, TAG,
        'icon: layout mismatch bg=%{public}dx%{public}d/%{public}d/%{public}d fg=%{public}dx%{public}d/%{public}d/%{public}d',
        bgInfo.size.width, bgInfo.size.height, bgInfo.stride, bgInfo.pixelFormat,
        fgInfo.size.width, fgInfo.size.height, fgInfo.stride, fgInfo.pixelFormat);
      return base;
    }

    const bytes: number = ICON_SIZE * ICON_SIZE * 4;
    const dstBuf = new ArrayBuffer(bytes);
    const srcBuf = new ArrayBuffer(bytes);
    await base.readPixelsToBuffer(dstBuf);
    await fg.readPixelsToBuffer(srcBuf);
    blendOver(new Uint8Array(dstBuf), new Uint8Array(srcBuf), fgInfo.alphaType);
    await base.writeBufferToPixels(dstBuf);
    hilog.info(DOMAIN, TAG,
      'icon: composed %{public}dx%{public}d alpha=%{public}d fmt=%{public}d',
      ICON_SIZE, ICON_SIZE, fgInfo.alphaType, fgInfo.pixelFormat);
    return base;
  } catch (e) {
    hilog.warn(DOMAIN, TAG, 'icon: compose failed %{public}s',
      e instanceof Error ? e.message : String(e));
    // 背景层已经解好 ⇒ 至少给一张品牌色方块，比系统占位图强
    return base;
  } finally {
    try {
      if (fg !== null) {
        fg.release();
      }
    } catch (e) {
      // 释放失败不影响结果
    }
  }
}
