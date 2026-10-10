import { image } from '@kit.ImageKit'
import { fileIo } from '@kit.CoreFileKit'
import { BoxRatio, ratioToHeightRatio } from './PlugboardTypes'

/**
 * 裁剪器工具（2026-10-10 新增）
 *
 * 设计哲学（"坐标戏法"）：
 *   · 不真裁剪原图（避免破坏动图 + 避免重写文件）
 *   · 裁剪器只是让用户看到"按目标比例应展示哪一块"
 *   · 最终保存的是 scale/offsetX/offsetY/rotation 四个参数
 *   · 渲染时（PlugboardZone）按这四个参数把原 Image 摆到位
 */

/**
 * 裁剪结果（统一的"坐标戏法"参数）
 */
export interface CropResult {
  scale: number
  offsetX: number
  offsetY: number
  rotation: number
  originalW: number
  originalH: number
}

/** 原图尺寸信息 */
export interface ImageInfo {
  width: number
  height: number
  /** 是否为动图（GIF 走坐标戏法、不真裁剪） */
  isGif: boolean
}

/**
 * 读原图尺寸（不解码全图）。
 * 用 image.createImageSource + getImageInfo 异步拿尺寸。
 */
export async function readImageInfo(filePath: string): Promise<ImageInfo> {
  let isGif = false
  // 头部 6 字节判 GIF
  try {
    const fid = fileIo.openSync(filePath, fileIo.OpenMode.READ_ONLY)
    try {
      const buf = new ArrayBuffer(4096)
      fileIo.readSync(fid.fd, buf)
      isGif = detectGif(buf)
    } finally {
      fileIo.closeSync(fid)
    }
  } catch (_e) {
    // 头部读失败就走 isGif=false
  }
  const src = image.createImageSource(filePath)
  const info = await src.getImageInfo()
  let w = 0
  let h = 0
  if (info !== null && info !== undefined) {
    // ImageInfo.size.width/height
    const size = info.size
    w = size.width
    h = size.height
  }
  src.release()
  return { width: w, height: h, isGif }
}

/** 检测前 6 字节是否为 GIF87a/89a */
function detectGif(buf: ArrayBuffer): boolean {
  if (buf.byteLength < 6) {
    return false
  }
  const view = new Uint8Array(buf, 0, 6)
  const sig = String.fromCharCode(view[0], view[1], view[2], view[3], view[4], view[5])
  return sig === 'GIF87a' || sig === 'GIF89a'
}

/**
 * 计算裁剪参数（用于"初始化"裁剪器）：
 *   · 把原图塞进一个 (targetW × targetH) 的视口，按"短边贴合"计算 scale
 */
export function computeInitialCrop(
  img: ImageInfo,
  targetW: number,
  targetH: number
): CropResult {
  if (img.width <= 0 || img.height <= 0 || targetW <= 0 || targetH <= 0) {
    return {
      scale: 1, offsetX: 0, offsetY: 0, rotation: 0,
      originalW: img.width, originalH: img.height,
    }
  }
  const sx = targetW / img.width
  const sy = targetH / img.height
  const scale = Math.min(sx, sy)
  return {
    scale: scale,
    offsetX: 0,
    offsetY: 0,
    rotation: 0,
    originalW: img.width,
    originalH: img.height,
  }
}

/** 视口尺寸（vp） */
export interface BoxSize {
  w: number
  h: number
}

/**
 * 按"目标比例"算出画布尺寸（vp）。
 */
export function computeTargetBoxSize(boxW: number, ratio: BoxRatio): BoxSize {
  const h = Math.max(60, Math.round(boxW * ratioToHeightRatio(ratio)))
  const r: BoxSize = { w: boxW, h: h }
  return r
}