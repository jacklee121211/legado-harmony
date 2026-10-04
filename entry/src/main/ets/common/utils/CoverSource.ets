/**
 * 封面源解析（v3.21，自定义封面真功能）：
 * 单本自定义封面存于 `Books.customCoverUrl`，三种形态：
 *   ① `default://cover_defaults/cN.svg` —— 内置 9 张装饰封面（rawfile，渲染端转 $rawfile）
 *   ② `datashare://...` / `file://...`  —— 用户自选图片（Image 原生可显）
 *   ③ 空                                 —— 回退书源封面/默认 alt
 * 渲染优先级（调用方组装）：customCoverUrl > coverUrl > alt。
 */
export const DEFAULT_COVER_PREFIX: string = 'default://cover_defaults/'

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
