/**
 * 封面源解析（v3.21，自定义封面真功能）+ 书名展示（v3.22，拓展名开关）：
 * 单本自定义封面存于 `Books.customCoverUrl`，三种形态：
 *   ① `default://cover_defaults/cN.svg` —— 内置 9 张装饰封面（rawfile，渲染端转 $rawfile）
 *   ② `datashare://...` / `file://...`  —— 用户自选图片（Image 原生可显）
 *   ③ 空                                 —— 回退书源封面/默认 alt
 * 渲染优先级（调用方组装）：customCoverUrl > coverUrl > alt。
 *
 * ⚠️ 本文件 2026-10-12 起**同时承载书名展示的唯一真源**（`stripBookExt()` / `BookNameDisplay`）：
 * 那些函数与封面无关，只是因为本文件的导入面**已经覆盖全部书名渲染点**
 * （工程内 14 处 import 本文件，恰好就是所有会显示书名的组件），
 * 而剥拓展名的规则要能被每一个渲染点共用、只写一份 ⇒ 挂在这里。
 */
export const DEFAULT_COVER_PREFIX: string = 'default://cover_defaults/'

/**
 * 书名末尾拓展名的**唯一真源**正则（`^` 锚点 + 非贪婪前缀，见 `bookExtMatch()`）。
 * 只认「末尾一个点 + 1~5 位字母数字」⇒ `斗破苍穹.txt` 命中，`卷.2024.10` 不命中。
 */
export const BOOK_EXT_PATTERN: RegExp = /^(.*?)(\.[a-zA-Z0-9]{1,5})$/

/** 拆名结果（`bookExtMatch` 的返回类型；ArkTS 禁匿名对象字面量 ⇒ 必须显式 interface） */
export interface BookNameParts {
  name: string
  ext: string
}

/** 拆出书名与拓展名。无拓展名 ⇒ ext = ''，name 原样返回。 */
export function bookExtMatch(rawName: string): BookNameParts {
  const m: RegExpMatchArray | null = (rawName ?? '').match(BOOK_EXT_PATTERN)
  return m !== null ? { name: m[1], ext: m[2] } : { name: rawName ?? '', ext: '' }
}

/** 剥掉末尾拓展名（`showExtName` 为真时原样返回）。 */
export function stripBookExt(rawName: string, showExtName: boolean): string {
  if (showExtName) {
    return rawName ?? ''
  }
  const m: RegExpMatchArray | null = (rawName ?? '').match(BOOK_EXT_PATTERN)
  return m !== null ? m[1] : (rawName ?? '')
}


/**
 * 书架书名的**唯一显示出口**。所有显示「书名」的组件一律走这里 —— 不要再自己写正则、
 * 也不要直接 `Text(x.bookName)`，否则「显示文件拓展名」开关必然漏覆盖。
 */
@Observed
export class BookNameDisplay {
  /**
   * 是否显示文件拓展名（我的-设置，Preferences 键 `MySetConstants.SET_EXT_NAME` = 'setExtName'）。
   *
   * 为什么是 `@Observed` 类字段而不是组件里的 `@StorageLink`：
   * `@StorageLink` **只能建在 @Component / @Entry 上**，
   * 而工具类里既没有 `this` 也没有组件生命周期 ⇒ 只能由**调用方**把
   * `@StorageLink('setExtName') showFileExt` 显式传进来。传进来的若是普通 string/bool，
   * 类内部再订阅 AppStorage 也无从触发组件重绘 ⇒ 这里保留字段，重绘责任在组件侧的装饰器上。
   * 依据（`docs/ArkTS-Language-Guide/**` AppStorage 章）：`@StorageLink` 的宿主是自定义组件实例。
   */
  showExt: boolean = false

  /**
   * 显示用书名：关开关 ⇒ 剥掉末尾拓展名。
   * `raw` 传**原始书名**（带拓展名，`Books.bookName`），不要传已处理过的值。
   */
  display(raw: string): string {
    return stripBookExt(raw, this.showExt)
  }
}

/** 换一份只带开关的轻量实例，避免各组件重复 `new`（开关仍是逐实例字段，无共享状态） */
export function bookNameDisplay(showExt: boolean): BookNameDisplay {
  const d: BookNameDisplay = new BookNameDisplay()
  d.showExt = showExt
  return d
}

/**
 * 内置 9 张封面的 rawfile **完整路径字面量表**。
 *
 * ⚠️ 为什么是表而不是 `'cover_defaults/' + n` 拼接（2026-10-01）：
 * IDE 的资源检查只对 `$rawfile('静态字面量')` 做 rawfile 目录比对，**不会求值字符串拼接**
 * ⇒ `$rawfile('cover_defaults/c' + n + '.svg')` 一律误报
 * 「No such 'cover_defaults/' resource in current module」（文件实际都在
 * rawfile/cover_defaults/，编译与真机渲染均正常 —— 纯告警噪音）。
 * 把 9 个完整路径列成常量、`$rawfile` 传变量（运行时按路径加载，合法 ——
 * 工程先例 ReaderTexture.ets:116 `$rawfile(file)`），检查器无字面量可查 ⇒ 警告消失。
 */
export const COVER_DEFAULT_FILES: string[] = [
  'cover_defaults/c1.svg', 'cover_defaults/c2.svg', 'cover_defaults/c3.svg',
  'cover_defaults/c4.svg', 'cover_defaults/c5.svg', 'cover_defaults/c6.svg',
  'cover_defaults/c7.svg', 'cover_defaults/c8.svg', 'cover_defaults/c9.svg'
]

/** 该值是否为内置默认封面协议 */
export function isDefaultCover(v: string): boolean {
  return v.startsWith(DEFAULT_COVER_PREFIX)
}

/**
 * 封面圆角几何（2026-10-04）：自定义/网络封面与内置默认封面**同曲率**。
 *
 * 参数来自 `cover_defaults/c1.svg` 主轮廓 path 实测（c2~c9 为同一模板，path 逐字节一致）：
 * 画布 90×120，四角是**书脊式不对称圆角** —— 左上/左下 4、右上/右下 8
 * （书脊在左侧 ⇒ 靠书脊一边收得急，这正是内置封面"像一本书"的来源）。
 * 自定义封面按显示宽度等比换算（k = 宽/90），四个圆角与内置封面对齐后，
 * 视觉上与 SVG 自带的轮廓严丝合缝；阴影（shadow）也跟随该轮廓。
 *
 * 用法：`Image(...).borderRadius(coverCorners(60))`（参数=该 Image 的显示宽度）。
 */
export function coverCorners(displayWidth: number): BorderRadiuses {
  const k: number = displayWidth / 90
  return {
    topLeft: 4 * k,
    topRight: 8 * k,
    bottomRight: 8 * k,
    bottomLeft: 4 * k
  }
}

/** 内置默认封面 → 序号（1~9；非法/越界返回 -1） */
export function defaultCoverIndex(custom: string): number {
  const digits: string = custom.substring(DEFAULT_COVER_PREFIX.length).replace(/[^1-9]/g, '')
  const n: number = parseInt(digits)
  return n >= 1 && n <= 9 ? n : -1
}

/**
 * 统一解析：返回 Image 可显示源。
 * 返回 null = 无自定义封面（调用方回退 coverUrl/alt）。
 * default:// 但序号非法（理论不可达，存量脏数据兜底）⇒ 返回 ''（Image 走 alt）。
 */
export function resolveCoverSource(custom: string): ResourceStr | null {
  if (custom === undefined || custom === null || custom === '') {
    return null
  }
  if (isDefaultCover(custom)) {
    const idx: number = defaultCoverIndex(custom)
    return idx > 0 ? $rawfile(COVER_DEFAULT_FILES[idx - 1]) : ''
  }
  return custom
}
