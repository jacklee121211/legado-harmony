/**
 * 封面源解析（v3.21，自定义封面真功能）：
 * 单本自定义封面存于 `Books.customCoverUrl`，三种形态：
 *   ① `default://cover_defaults/cN.svg` —— 内置 9 张装饰封面（rawfile，渲染端转 $rawfile）
 *   ② `datashare://...` / `file://...`  —— 用户自选图片（Image 原生可显）
 *   ③ 空                                 —— 回退书源封面/默认 alt
 * 渲染优先级（调用方组装）：customCoverUrl > coverUrl > alt。
 * 注意：$rawfile 只能在组件上下文使用 ⇒ 返回 rawfile 相对路径由调用方包 $rawfile。
 */
export const DEFAULT_COVER_PREFIX: string = 'default://cover_defaults/'

/** 该值是否为内置默认封面协议 */
export function isDefaultCover(v: string): boolean {
  return v.startsWith(DEFAULT_COVER_PREFIX)
}

/** 内置默认封面 → rawfile 相对路径（cN.svg） */
export function defaultCoverRaw(v: string): string {
  return v.substring(DEFAULT_COVER_PREFIX.length)
}

/**
 * 统一解析：返回 Image 可显示源。
 * 返回 null = 无自定义封面（调用方回退 coverUrl/alt）。
 */
export function resolveCoverSource(custom: string): ResourceStr | null {
  if (custom === undefined || custom === null || custom === '') {
    return null
  }
  if (isDefaultCover(custom)) {
    return $rawfile('cover_defaults/' + defaultCoverRaw(custom))
  }
  return custom
}
