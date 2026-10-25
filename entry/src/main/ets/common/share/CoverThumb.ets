/**
 * 分享缩略图：书籍封面 → 沙箱 JPEG（≤30KB，3:4 / 600×800）
 *
 * ── 用途（2026-10-25 真机实测后定稿）────────────────────────────────────────
 * 只服务**系统分享面板**（`systemShare.ShareController`，`previewMode` 缺省卡片模式）的
 * 预览图：该卡片读 `SharedRecord.thumbnail` / `thumbnailUri`。
 * ⚠️ **碰一碰 / 隔空传送的卡片不吃这两个字段**（文件记录）——URI 通道、内联 JPEG、
 *    内联 PNG 三条通道全部实测无效，卡片上那个大图标是系统按内容类型给的占位。
 *    所以本文件的目的**不是**让碰一碰卡片出封面（做不到），而是让分享面板好看。
 *
 * ── 为什么需要"落盘 + 规整"这一层 ─────────────────────────────────────────
 * `thumbnailUri` 只接受**应用文件 URI / 用户文件 URI**（SDK
 * `@hms.collaboration.systemShare.d.ts:152-159`，官方 API 表原文：「缺省时使用与分享
 * 内容类型匹配的图标作为缩略图。支持的 uri 类型：应用文件URI、用户文件URI」），
 * 而本项目封面的三种形态里只有两种能直接用：
 *   · `customCoverUrl` = `file://`（用户自选图，已拷进沙箱）→ 能
 *   · `builtinCoverUrl` = 沙箱绝对路径（epub/pdf/docx 提取的封面）→ 能（转 URI）
 *   · `customCoverUrl` = `default://cover_defaults/cN.svg`（预置彩色爪印封面）→ **不能**（rawfile）
 *   · 全空（txt 无自带封面）→ **没有图**
 * ⇒ 必须有"解码 → 规整 → 落盘"这一层，才能把 rawfile 预设封面和"无封面"兜底都变成文件。
 *
 * ── 输出规格：一律 3:4 / 600×800 / ≤30KB ──────────────────────────────────
 * 依据 `开发指南/Share_Kit_分享服务/碰一碰分享/手机与手机碰一碰分享/内容分享/
 * knock-share-between-phones-content` §设置合适的预览图原文：
 * 「应用创作的海报 | 3:4 | 最小分辨率：600*800 最大分辨率：3000*4000 | 512KB」。
 * 30KB 上限来自 FAQ `faqs-share-8`：「thumbnail 是否尺寸过大：**限制图片大小：32KB 以下**，
 * 过大的图片可能导致 want 数据超限无法拉起分享」。
 *
 * ── 取图优先级：与书架渲染完全一致（唯一真源 `CoverSource.resolveBookCover()`）──
 * `customCoverUrl`（用户改过的：预设 `default://` 或自选图片）
 *   > `builtinCoverUrl`（epub/pdf/docx 自带封面）> `app.media.icon_book_default_cover_one`
 *   （书架 `Image().alt()` 同一张，即 txt 的预置爪印封面）
 * `coverUrl` 是历史字段（本项目已只做本地书），仅当它是本地文件时才尝试。
 *
 * ── 解码 API 依据 ─────────────────────────────────────────────────────────
 * · `image.createImageSource(buf | fd | uri)` —— `@ohos.multimedia.image.d.ts:4258/4220/4182`，
 *   支持格式含 **svg(10+)**（`:4172-4175`，要求 svg 标签带 width/height，本工程
 *   `cover_defaults/c1.svg` 为 90×120 ✓）。
 * · `ImageSource.getImageInfoSync()` —— 同文件 `:11787`，@since 12。
 * · `DecodingOptions.desiredRegion` + `desiredSize` + `cropAndScaleStrategy`
 *   —— 同文件 `:3311/:3286/:3363`；原文「若同时传 desiredSize 与 desiredRegion，
 *   **必须**再传 cropAndScaleStrategy」，故固定 `CROP_FIRST`（`:2724`，@since 18）。
 * · `fs.openSync(path)` 原文「This API supports the use of a URI」—— `@ohos.file.fs.d.ts:2581-2634`。
 * · `ImagePacker.packToData` —— 工程先例 `PdfViewerPage.ets:576-596`。
 */
import { image } from '@kit.ImageKit'
import { fileIo as fs, fileUri } from '@kit.CoreFileKit'
import { common } from '@kit.AbilityKit'
import { hilog } from '@kit.PerformanceAnalysisKit'
import { BusinessError } from '@kit.BasicServicesKit'
import { Books } from '../../database/entities/Books'
import { COVER_DEFAULT_FILES, defaultCoverIndex, isDefaultCover } from '../utils/CoverSource'

const DOMAIN: number = 0x0000
const TAG: string = 'ShareThumb'

/** 输出宽（3:4 的 3） */
export const SHARE_THUMB_W: number = 600
/** 输出高（3:4 的 4） */
export const SHARE_THUMB_H: number = 800
/** 内联字节上限（官方 32KB，留 2KB 余量） */
export const SHARE_THUMB_INLINE_LIMIT: number = 30 * 1024
/** 缩略图子目录（挂在 filesDir 下，见 `thumbDir()`） */
const CACHE_SUBDIR: string = 'share_thumb'

/** 与书架 `Image().alt()` 同一张默认封面（`BookInfos.ets:231`） */
function defaultCoverMedia(): Resource {
  return $r('app.media.icon_book_default_cover_one')
}

/** djb2 变体：把封面三处来源压成 8 位 hex（只做缓存键，不需要密码学强度） */
function hashOf(s: string): string {
  let h: number = 5381
  for (let i = 0; i < s.length; i++) {
    h = ((h * 33) ^ s.charCodeAt(i)) >>> 0
  }
  return h.toString(16)
}

/**
 * 缓存键 = `bookId_封面指纹`。
 * **必须**带指纹：只按 id 缓存的话，用户换了封面仍会命中旧图。
 */
function coverKey(book: Books): string {
  const id: number = book.id ?? -1
  const raw: string = `${book.customCoverUrl ?? ''}|${book.builtinCoverUrl ?? ''}|${book.coverUrl ?? ''}`
  return `${id}_${hashOf(raw)}`
}

/** 放 filesDir 而非 cacheDir：对齐官方示例 `context.filesDir + '/exampleKnock1.jpg'`，
 *  cacheDir 属"系统可随时清理"目录，被清后预览图会突然消失。 */
function thumbDir(ctx: common.UIAbilityContext): string {
  return `${ctx.filesDir}/${CACHE_SUBDIR}`
}

function ensureDir(dir: string): boolean {
  try {
    if (!fs.accessSync(dir)) {
      fs.mkdirSync(dir, true)
    }
    return true
  } catch (e) {
    const err = e as BusinessError
    hilog.warn(DOMAIN, TAG, 'mkdir failed: %{public}s', err.message ?? '')
    return false
  }
}

/**
 * 沙箱路径 → 文件 URI。
 *
 * ⚠️ **必须**用 `fileUri.getUriFromPath`，不能手拼 `'file://' + path`（2026-10-25 踩过）：
 * 官方 `开发指南/Core_File_Kit_文件基础服务/应用文件/应用文件分享/share-app-file`
 * §文件URI规范原文：「格式为 file://\<bundleName\>/\<path\> … 系统无法保证应用自行
 * 拼接的URI地址的可用性；推荐使用系统提供的接口获取URI，如 getUriFromPath」。
 */
function toFileUri(path: string): string {
  try {
    return fileUri.getUriFromPath(path)
  } catch (e) {
    const err = e as BusinessError
    hilog.warn(DOMAIN, TAG, 'getUriFromPath failed: %{public}s', err.message ?? '')
    return ''
  }
}

/** 已缓存且非空 ⇒ 返回 file URI，否则 '' */
function cachedThumb(path: string): string {
  try {
    if (fs.accessSync(path) && fs.statSync(path).size > 0) {
      return toFileUri(path)
    }
  } catch (e) {
    // 访问失败按未缓存处理
  }
  return ''
}

/** 同一个 bookId 只保留最新那张（封面一换，旧键就成垃圾） */
function dropStale(dir: string, id: number, keepPath: string): void {
  const prefix: string = `${id}_`
  try {
    const names: string[] = fs.listFileSync(dir)
    for (const name of names) {
      if (!name.startsWith(prefix)) {
        continue
      }
      const full: string = `${dir}/${name}`
      if (full === keepPath) {
        continue
      }
      try {
        fs.unlinkSync(full)
      } catch (e) {
        // 单文件删不掉不影响结果
      }
    }
  } catch (e) {
    // listFileSync 失败（目录刚建/无权限）忽略
  }
}

/**
 * 按「居中裁剪 + 缩放到 600×800」解码，等价 `ImageFit.Cover`。
 * 必须先按目标比例算原图上的居中裁剪框，再用 `CROP_FIRST` 解码
 * （否则不同图片格式"先缩后裁"取到的区域会不一致）。
 */
async function decodeCropped(src: image.ImageSource): Promise<image.PixelMap | null> {
  try {
    const info: image.ImageInfo = src.getImageInfoSync()
    const w: number = info.size.width
    const h: number = info.size.height
    if (w <= 0 || h <= 0) {
      return null
    }
    const targetRatio: number = SHARE_THUMB_W / SHARE_THUMB_H
    const srcRatio: number = w / h
    let cropW: number = w
    let cropH: number = h
    if (srcRatio > targetRatio) {
      cropW = Math.floor(h * targetRatio)
    } else if (srcRatio < targetRatio) {
      cropH = Math.floor(w / targetRatio)
    }
    const opts: image.DecodingOptions = {
      desiredRegion: {
        size: { width: cropW, height: cropH },
        x: Math.floor((w - cropW) / 2),
        y: Math.floor((h - cropH) / 2)
      },
      desiredSize: { width: SHARE_THUMB_W, height: SHARE_THUMB_H },
      desiredPixelFormat: image.PixelMapFormat.RGBA_8888,
      cropAndScaleStrategy: image.CropAndScaleStrategy.CROP_FIRST
    }
    return await src.createPixelMap(opts)
  } catch (e) {
    const err = e as BusinessError
    hilog.warn(DOMAIN, TAG, 'decode failed: %{public}s', err.message ?? '')
    return null
  }
}

/** 本地文件（沙箱路径 / file:// / datashare://）→ 规整后的 PixelMap */
async function decodeLocal(path: string): Promise<image.PixelMap | null> {
  let file: fs.File | null = null
  let src: image.ImageSource | null = null
  try {
    file = fs.openSync(path, fs.OpenMode.READ_ONLY)
    src = image.createImageSource(file.fd)
    return src === null ? null : await decodeCropped(src)
  } catch (e) {
    const err = e as BusinessError
    hilog.warn(DOMAIN, TAG, 'open local failed: %{public}s', err.message ?? '')
    return null
  } finally {
    if (src !== null) {
      try {
        src.release()
      } catch (e) {
        // 释放失败不影响结果
      }
    }
    if (file !== null) {
      try {
        fs.closeSync(file)
      } catch (e) {
        // 同上
      }
    }
  }
}

/** rawfile 里的预置封面（SVG）→ 规整后的 PixelMap */
async function decodeRawfile(ctx: common.UIAbilityContext, relPath: string): Promise<image.PixelMap | null> {
  let src: image.ImageSource | null = null
  try {
    const bytes: Uint8Array = await ctx.resourceManager.getRawFileContent(relPath)
    if (bytes.byteLength === 0) {
      return null
    }
    // Uint8Array 未必从 0 偏移开始 ⇒ 取它自己那一段（工程先例 SessionCover.ets:84）
    const buf: ArrayBuffer = bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength)
    src = image.createImageSource(buf)
    return src === null ? null : await decodeCropped(src)
  } catch (e) {
    const err = e as BusinessError
    hilog.warn(DOMAIN, TAG, 'rawfile %{public}s failed: %{public}s', relPath, err.message ?? '')
    return null
  } finally {
    if (src !== null) {
      try {
        src.release()
      } catch (e) {
        // 释放失败不影响结果
      }
    }
  }
}

/** media 资源（默认封面 SVG）→ 规整后的 PixelMap */
async function decodeMedia(ctx: common.UIAbilityContext, res: Resource): Promise<image.PixelMap | null> {
  let src: image.ImageSource | null = null
  try {
    const bytes: Uint8Array = await ctx.resourceManager.getMediaContent(res.id)
    if (bytes.byteLength === 0) {
      return null
    }
    const buf: ArrayBuffer = bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength)
    src = image.createImageSource(buf)
    return src === null ? null : await decodeCropped(src)
  } catch (e) {
    const err = e as BusinessError
    hilog.warn(DOMAIN, TAG, 'media %{public}d failed: %{public}s', res.id, err.message ?? '')
    return null
  } finally {
    if (src !== null) {
      try {
        src.release()
      } catch (e) {
        // 释放失败不影响结果
      }
    }
  }
}

/** 能否直接当本地图像读（网络图 / rawfile 协议都不行） */
function isLocalBitmap(v: string): boolean {
  if (v === '' || v.startsWith('http://') || v.startsWith('https://') || v.startsWith('default://')) {
    return false
  }
  return true
}

/** 取图结果（ArkTS 禁匿名对象字面量当类型 ⇒ 显式 class） */
class CoverPick {
  pm: image.PixelMap | null = null
  /** 命中来源，仅用于日志：custom-default / custom-file / builtin / cover-local / app-default */
  kind: string = ''

  constructor(pm: image.PixelMap | null, kind: string) {
    this.pm = pm
    this.kind = kind
  }
}

/** 按书架同序取封面像素（优先级见文件头） */
async function loadCoverPixels(ctx: common.UIAbilityContext, book: Books): Promise<CoverPick> {
  const custom: string = book.customCoverUrl ?? ''
  if (isDefaultCover(custom)) {
    // 用户选的预置封面（rawfile SVG）
    const idx: number = defaultCoverIndex(custom)
    if (idx > 0) {
      const pm: image.PixelMap | null = await decodeRawfile(ctx, COVER_DEFAULT_FILES[idx - 1])
      if (pm !== null) {
        return new CoverPick(pm, `custom-default(c${idx})`)
      }
    }
  } else if (isLocalBitmap(custom)) {
    const pm: image.PixelMap | null = await decodeLocal(custom)
    if (pm !== null) {
      return new CoverPick(pm, 'custom-file')
    }
  }
  const builtin: string = book.builtinCoverUrl ?? ''
  if (isLocalBitmap(builtin)) {
    const pm: image.PixelMap | null = await decodeLocal(builtin)
    if (pm !== null) {
      return new CoverPick(pm, 'builtin')
    }
  }
  const cover: string = book.coverUrl ?? ''
  if (isLocalBitmap(cover)) {
    const pm: image.PixelMap | null = await decodeLocal(cover)
    if (pm !== null) {
      return new CoverPick(pm, 'cover-local')
    }
  }
  // 兜底：书架默认封面（同 `Image().alt()`），保证预览图不是系统图标
  return new CoverPick(await decodeMedia(ctx, defaultCoverMedia()), 'app-default')
}

/** 从高画质往下降，直到字节数 ≤ `SHARE_THUMB_INLINE_LIMIT` */
async function packAdaptive(pm: image.PixelMap): Promise<ArrayBuffer | null> {
  const qualities: number[] = [85, 70, 55, 40, 30]
  const packer: image.ImagePacker = image.createImagePacker()
  try {
    let last: ArrayBuffer | null = null
    for (const q of qualities) {
      const opt: image.PackingOption = { format: 'image/jpeg', quality: q }
      const buf: ArrayBuffer = await packer.packToData(pm, opt)
      last = buf
      if (buf.byteLength <= SHARE_THUMB_INLINE_LIMIT) {
        return buf
      }
    }
    hilog.warn(DOMAIN, TAG, 'thumb still %{public}d bytes after compression', last === null ? 0 : last.byteLength)
    return last
  } catch (e) {
    const err = e as BusinessError
    hilog.warn(DOMAIN, TAG, 'pack failed: %{public}s', err.message ?? '')
    return null
  } finally {
    packer.release().catch((): void => {
    })
  }
}

function writeBytes(path: string, buf: ArrayBuffer): boolean {
  try {
    const f: fs.File = fs.openSync(path, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC)
    try {
      fs.writeSync(f.fd, buf)
    } finally {
      fs.closeSync(f)
    }
    return true
  } catch (e) {
    const err = e as BusinessError
    hilog.warn(DOMAIN, TAG, 'write failed: %{public}s', err.message ?? '')
    return false
  }
}

function readBytes(path: string): Uint8Array | null {
  try {
    const size: number = fs.statSync(path).size
    if (size <= 0 || size > SHARE_THUMB_INLINE_LIMIT) {
      return null
    }
    const buf: ArrayBuffer = new ArrayBuffer(size)
    const f: fs.File = fs.openSync(path, fs.OpenMode.READ_ONLY)
    try {
      fs.readSync(f.fd, buf)
    } finally {
      fs.closeSync(f)
    }
    return new Uint8Array(buf)
  } catch (e) {
    return null
  }
}

/**
 * 回读校验：把刚写好的 JPEG 再解一次，打「尺寸 + 中心像素 RGBA」。
 * 预览图不显示时，"我们到底生成了什么图"是第一个要排除的变量（只解 1×1 拿平均色，代价可忽略）。
 */
async function verifyThumb(path: string): Promise<string> {
  let src: image.ImageSource | null = null
  try {
    src = image.createImageSource(path)
    if (src === null) {
      return 'open-failed'
    }
    const info: image.ImageInfo = src.getImageInfoSync()
    const one: image.PixelMap = await src.createPixelMap({
      desiredSize: { width: 1, height: 1 },
      desiredPixelFormat: image.PixelMapFormat.RGBA_8888
    })
    const buf: ArrayBuffer = new ArrayBuffer(4)
    await one.readPixelsToBuffer(buf)
    const px: Uint8Array = new Uint8Array(buf)
    one.release().catch((): void => {
    })
    return `${info.size.width}x${info.size.height} rgba(${px[0]},${px[1]},${px[2]},${px[3]})`
  } catch (e) {
    const err = e as BusinessError
    return `verify-failed:${err.message ?? ''}`
  } finally {
    if (src !== null) {
      try {
        src.release()
      } catch (e) {
        // 忽略
      }
    }
  }
}

/** 一次生成的产物：文件 URI（`thumbnailUri`）+ 内联字节（`thumbnail`） */
export class ShareThumb {
  uri: string = ''
  bytes: Uint8Array | null = null

  constructor(uri: string, bytes: Uint8Array | null) {
    this.uri = uri
    this.bytes = bytes
  }
}

/**
 * 书籍封面 → 分享面板预览图（URI + 内联字节，同一张 JPEG）。
 *
 * 两种形态都给：官方 FAQ `faqs-share-8`「如果同时设置 thumbnail 和 thumbnailUri，
 * **会优先使用 thumbnail**」，内联字节随 want 走、不依赖任何沙箱读取授权。
 *
 * 失败返回空对象（调用方不设字段 ⇒ 面板用系统图标，绝不影响分享本身）。
 */
export async function coverThumb(ctx: common.UIAbilityContext, book: Books): Promise<ShareThumb> {
  const dir: string = thumbDir(ctx)
  const path: string = `${dir}/${coverKey(book)}.jpg`
  const hit: string = cachedThumb(path)
  if (hit !== '') {
    return new ShareThumb(hit, readBytes(path))
  }
  if (!ensureDir(dir)) {
    return new ShareThumb('', null)
  }
  const pick: CoverPick = await loadCoverPixels(ctx, book)
  const pm: image.PixelMap | null = pick.pm
  if (pm === null) {
    hilog.warn(DOMAIN, TAG, 'no cover pixels, book=%{public}d src=%{public}s', book.id ?? -1, pick.kind)
    return new ShareThumb('', null)
  }
  try {
    const buf: ArrayBuffer | null = await packAdaptive(pm)
    if (buf === null || !writeBytes(path, buf)) {
      return new ShareThumb('', null)
    }
    dropStale(dir, book.id ?? -1, path)
    const uri: string = toFileUri(path)
    hilog.info(DOMAIN, TAG, 'thumb ready book=%{public}d src=%{public}s bytes=%{public}d check=%{public}s uri=%{public}s',
      book.id ?? -1, pick.kind, buf.byteLength, await verifyThumb(path), uri)
    return new ShareThumb(uri, new Uint8Array(buf))
  } finally {
    pm.release().catch((): void => {
    })
  }
}
