/**
 * 书籍封面文件：**自带封面提取** + **用户选图落地沙箱** + **文件清理**。
 *
 * ── 为什么需要这个文件（2026-10-13，方案 C）──────────────────────────────
 * ① **自带封面**：`txt` 没有封面，但 `epub / mobi / azw / azw3` 有。ReaderKit 的
 *    `bookParser` 已经把书封暴露出来，本文件负责"导入时取出来 → 落成沙箱文件 →
 *    把**路径**写进 `Books.builtinCoverUrl`"。
 * ② **用户选图落地**：`pickerAvatar()` 返回的是**相册媒体 URI**，
 *    `photoViewPicker.ets:29-32` 的头注释已点名隐患（SDK 原文「can be used only by
 *    calling photoAccessHelper.getAssets」，而调用方直接拿它当图片地址）。
 *    真机症状：选完图预览位**不刷新**（首帧解码失败），退出重进才显示。
 *    ⇒ 选完立刻拷进沙箱，用**沙箱 URI** 去显示/落库：
 *      · 官方 FAQ `faqs-arkui-154`：「Image组件不能直接传入应用沙箱路径，
 *        需要传入应用沙箱URI」；
 *      · 沙箱文件无权限时序问题、也不会因相册授权过期而失效。
 * ③ **清理**：删书时把该书的封面文件真删掉（只删本模块管理的 `covers/` 目录）。
 *
 * ── 目录约定 ───────────────────────────────────────────────────────────────
 * 封面统一放 `<书籍文件所在目录>/covers/`（即 `filesDir/covers/`），命名：
 *   · 自带封面：`<书籍文件名净化后>.<扩展名>`（同名书覆盖同名文件，天然幂等）
 *   · 自定义图：`custom_<时间戳>.<扩展名>`
 * 存**路径**给 `builtinCoverUrl`、存**URI** 给 `customCoverUrl`（历史契约不变）。
 */

import fs from '@ohos.file.fs'
import { common } from '@kit.AbilityKit'
import { fileUri } from '@kit.CoreFileKit'
import { bookParser } from '@kit.ReaderKit'
import { AppUtil } from '@pura/harmony-utils'

/**
 * 自带封面提取总开关。
 * `false` = **完全回到旧行为**（导入不写 `builtinCoverUrl`，渲染端因该列为空而
 * 自动等价于"三层" ⇒ 行为与本次改造前逐字一致）。回退只需改这一行。
 */
const EXTRACT_LOCAL_COVER: boolean = true

/** 支持从文件里提取封面的扩展名（`txt` 没有封面，不在列表里 ⇒ 天然跳过） */
const COVER_BOOK_EXT: string[] = ['.epub', '.mobi', '.azw', '.azw3']

/**
 * 单次提取的超时（ms）。ReaderKit 的 `getDefaultHandler` 会解析整本书，
 * 超大 epub 可能较慢；导入是**逐本 await** 的（`IndexShelf.pickLocalBooks:718-723`），
 * 不能让它无限期拖住导入进度 ⇒ 超时即当作"这本书没有自带封面"，静默继续。
 */
const EXTRACT_TIMEOUT_MS: number = 5000

/** 封面文件大小上限（异常/损坏的书可能给出巨大 buffer，直接放弃而不是写盘） */
const MAX_COVER_BYTES: number = 16 * 1024 * 1024

/** 目录名 */
const COVER_DIR_NAME: string = 'covers'

// ── 基础工具 ────────────────────────────────────────────────────────────────

function errMsg(e: Object): string {
  return e instanceof Error ? e.message : String(e)
}

/** 目录不存在则递归创建（`accessSync` 在不存在时**抛异常**，必须 try —— 见 FileHandler 同款注释） */
function ensureDir(dir: string): void {
  let exists: boolean = false
  try {
    exists = fs.accessSync(dir)
  } catch (e) {
    exists = false
  }
  if (!exists) {
    fs.mkdirSync(dir, true)
  }
}

/** 从书籍文件路径推出封面目录：`/…/files/书.epub` ⇒ `/…/files/covers` */
function coversDirOfBook(bookPath: string): string {
  const slash: number = bookPath.lastIndexOf('/')
  const dir: string = slash > 0 ? bookPath.substring(0, slash) : bookPath
  return dir + '/' + COVER_DIR_NAME
}

/** 选图落地用的封面目录（沙箱 `filesDir/covers`） */
function coversDirApp(): string {
  try {
    // 走 AppUtil 而不是模块级 getContext()：`EntryAbility.onCreate` 已 init ⇒ 确定性
    // （理由与 `FileHandler.doSeed:133-136` 完全相同）
    const ctx: common.Context = AppUtil.getContext() as common.Context
    return ctx.filesDir + '/' + COVER_DIR_NAME
  } catch (e) {
    console.error('BookCover.coversDirApp failed: ' + errMsg(e as Object))
    return ''
  }
}

/**
 * 按文件头魔数判断图片格式。
 * 只用于**给落盘文件起一个可读的扩展名**；Image 解码看内容不看后缀，
 * 所以猜错也只是文件名不好看，不影响显示。
 */
function sniffImageExt(head: Uint8Array): string {
  const n: number = head.length
  if (n >= 3 && head[0] === 0xFF && head[1] === 0xD8 && head[2] === 0xFF) {
    return 'jpg'
  }
  if (n >= 8 && head[0] === 0x89 && head[1] === 0x50 && head[2] === 0x4E && head[3] === 0x47) {
    return 'png'
  }
  if (n >= 6 && head[0] === 0x47 && head[1] === 0x49 && head[2] === 0x46) {
    return 'gif'
  }
  if (n >= 12 && head[0] === 0x52 && head[1] === 0x49 && head[2] === 0x46 && head[3] === 0x46
    && head[8] === 0x57 && head[9] === 0x45 && head[10] === 0x42 && head[11] === 0x50) {
    return 'webp'
  }
  if (n >= 2 && head[0] === 0x42 && head[1] === 0x4D) {
    return 'bmp'
  }
  return 'jpg'
}

/** 文件名净化：去掉路径分隔符 / Windows 非法字符 / 换行 / 空格 */
function sanitizeStem(name: string): string {
  let s: string = name.replace(/[\/\\:*?"<>|\r\n\t ]/g, '_')
  s = s.replace(/^\.+/, '')
  if (s.length > 60) {
    s = s.substring(0, 60)
  }
  return s === '' ? 'cover_' + Date.now() : s
}

/** URI / 路径取扩展名（不含点）；未知返回 jpg */
function extOfPath(uri: string): string {
  const dot: number = uri.lastIndexOf('.')
  if (dot < 0 || dot < uri.lastIndexOf('/')) {
    return 'jpg'
  }
  const ext: string = uri.substring(dot + 1).toLowerCase()
  const known: string[] = ['jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp', 'heic', 'heif']
  return known.includes(ext) ? ext : 'jpg'
}

/** 把 ArrayBuffer 写成一个封面文件，返回**沙箱绝对路径** */
function saveBytes(dir: string, stem: string, buffer: ArrayBuffer): string {
  ensureDir(dir)
  const headLen: number = Math.min(16, buffer.byteLength)
  const head: Uint8Array = new Uint8Array(buffer, 0, headLen)
  const ext: string = sniffImageExt(head)
  const path: string = dir + '/' + stem + '.' + ext
  const file: fs.File = fs.openSync(path, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC)
  try {
    fs.writeSync(file.fd, buffer)
  } finally {
    try {
      fs.closeSync(file)
    } catch (e) {
      // 已关闭则忽略
    }
  }
  return path
}

function isCoverBook(bookPath: string): boolean {
  const lower: string = bookPath.toLowerCase()
  for (const ext of COVER_BOOK_EXT) {
    if (lower.endsWith(ext)) {
      return true
    }
  }
  return false
}

/**
 * `getDefaultHandler` 的超时包装：超时/失败统一返回 `null`。
 *
 * ⚠️ 落败的 promise 仍会继续跑完，这里**必须**挂 `.catch` 吞掉它的 reject，
 *    否则会变成 unhandled rejection（ArkTS 运行时会打红日志）。
 */
function handlerWithTimeout(p: Promise<bookParser.BookParserHandler>): Promise<bookParser.BookParserHandler | null> {
  return new Promise<bookParser.BookParserHandler | null>((resolve: (v: bookParser.BookParserHandler | null) => void) => {
    let settled: boolean = false
    const timer: number = setTimeout(() => {
      if (!settled) {
        settled = true
        resolve(null)
      }
    }, EXTRACT_TIMEOUT_MS)
    p.then((handler: bookParser.BookParserHandler) => {
      if (!settled) {
        settled = true
        clearTimeout(timer)
        resolve(handler)
      }
    }).catch((e: Object) => {
      if (!settled) {
        settled = true
        clearTimeout(timer)
        console.warn('BookCover: getDefaultHandler rejected: ' + errMsg(e))
        resolve(null)
      }
    })
  })
}

class BookCoverUtil {
  /**
   * 提取书籍**自带封面**并落盘。
   *
   * @param bookPath 沙箱内的书籍文件绝对路径（必须在**拷贝完成之后**调用）
   * @param bookName 书籍文件名（仅用于给封面文件命名）
   * @returns 封面文件**沙箱绝对路径**；无封面/失败/超时 一律返回 `''`
   *
   * ⚠️ 调用方必须把返回值当"可空"处理：本方法**永不抛异常**，
   *    失败只是没有自带封面（渲染回落默认封面），绝不能影响导入本身。
   */
  async extractBuiltinCover(bookPath: string, bookName: string): Promise<string> {
    if (!EXTRACT_LOCAL_COVER || bookPath === '') {
      return ''
    }
    if (!isCoverBook(bookPath)) {
      // txt 等：本来就没有封面，静默跳过（这是正常路径，不是错误）
      return ''
    }
    const started: number = Date.now()
    try {
      const handler: bookParser.BookParserHandler | null = await handlerWithTimeout(bookParser.getDefaultHandler(bookPath))
      if (handler === null) {
        console.warn('BookCover: no handler (timeout/fail), skip: ' + bookName)
        return ''
      }
      const info: bookParser.BookInfo = handler.getBookInfo()
      const rel: string = info.bookCoverImage ?? ''
      if (rel === '') {
        console.info('BookCover: no embedded cover: ' + bookName)
        return ''
      }
      // spineIndex 传 -1 = 取书封。官方 `reader-book-parser` 原文：
      // 「如果传负数，如-1，代表获取书封」
      const buffer: ArrayBuffer = handler.getResourceContent(-1, rel)
      if (buffer === undefined || buffer === null || buffer.byteLength === 0) {
        console.warn('BookCover: empty cover bytes: ' + bookName)
        return ''
      }
      if (buffer.byteLength > MAX_COVER_BYTES) {
        console.warn('BookCover: cover too large (' + buffer.byteLength + '), skip: ' + bookName)
        return ''
      }
      const path: string = saveBytes(coversDirOfBook(bookPath), sanitizeStem(bookName), buffer)
      console.info('BookCover: extracted ' + bookName + ' -> ' + path
        + ' (' + buffer.byteLength + ' bytes, ' + (Date.now() - started) + 'ms)')
      return path
    } catch (e) {
      // 解析失败（格式不支持/文件损坏/1017xxxx 错误码）⇒ 没有自带封面，不影响导入
      console.error('BookCover: extract failed for ' + bookName + ': ' + errMsg(e as Object))
      return ''
    }
  }

  /**
   * 用户选中的图片 → 落地沙箱，返回**沙箱 URI**（可直接给 `Image`，也可直接存库）。
   *
   * 失败时**回退返回原始 URI**（= 旧行为），保证最坏情况只是回到改造前的表现。
   */
  async importPickedImage(uri: string): Promise<string> {
    if (uri === '') {
      return ''
    }
    try {
      const dir: string = coversDirApp()
      if (dir === '') {
        return uri
      }
      ensureDir(dir)
      const dst: string = dir + '/custom_' + Date.now() + '.' + extOfPath(uri)
      // src 用 URI 直接 open：工程先例 `FileHandler.CopyFile:65`
      // （picker 返回的 `file://docs/…` 同样直接 openSync）
      const src: fs.File = fs.openSync(uri, fs.OpenMode.READ_ONLY)
      try {
        await fs.copyFile(src.fd, dst, 0)
      } finally {
        try {
          fs.closeSync(src)
        } catch (e) {
          // 已关闭则忽略
        }
      }
      const local: string = fileUri.getUriFromPath(dst)
      console.info('BookCover: picked image -> ' + local)
      return local
    } catch (e) {
      console.error('BookCover: importPickedImage failed, fallback to raw uri: ' + errMsg(e as Object))
      return uri
    }
  }

  /**
   * 删除封面文件。**只删本模块目录（`/covers/`）下的文件** ——
   * 用户自选的历史封面可能是 `datashare://` 等外部资源，绝不能误删。
   *
   * @param pathOrUri 沙箱路径（`builtinCoverUrl`）或沙箱 URI（`customCoverUrl`）
   */
  removeCoverFile(pathOrUri: string): void {
    if (pathOrUri === undefined || pathOrUri === null || pathOrUri === '') {
      return
    }
    let path: string = pathOrUri
    if (path.startsWith('file://')) {
      // 沙箱 URI 形态：file://<bundleName>/data/storage/... ⇒ 取 bundleName 之后的绝对路径
      const slash: number = path.indexOf('/', 'file://'.length)
      if (slash < 0) {
        return
      }
      path = path.substring(slash)
    }
    if (path.indexOf('/' + COVER_DIR_NAME + '/') < 0) {
      return
    }
    try {
      fs.unlinkSync(path)
      console.info('BookCover: removed ' + path)
    } catch (e) {
      // 文件不存在 / 已被删 ⇒ 忽略
    }
  }

  /** 给 UI 层用的目录（自定义封面落地目录），保证 `<filesDir>/covers` 存在 */
  ensureCustomDir(): string {
    const dir: string = coversDirApp()
    if (dir !== '') {
      try {
        ensureDir(dir)
      } catch (e) {
        console.error('BookCover.ensureCustomDir failed: ' + errMsg(e as Object))
      }
    }
    return dir
  }
}

const bookCover = new BookCoverUtil()
export default bookCover as BookCoverUtil
