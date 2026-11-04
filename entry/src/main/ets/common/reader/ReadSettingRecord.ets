// 阅读设置的**纯记录层**（2026-11-04 渲染侧 S2-a：设置域重构的第一块）。
//
// ── 这一层要解决什么 ────────────────────────────────────────────────────────
// 现在设置散在两处：`ReaderPage3` 的 `@State readerSetting: readerCore.ReaderSetting`（13 字段、259 个读写点）
// + 旁路 Preferences 的外观记录（`ReaderBg_<书名>` / `ReaderBgGlobal`，见 `ReaderCustomBg`）。
// 本文件只负责**其中 ReaderKit 的 13 字段**的「形状 + 编解码 + 校验」，不含任何 UI/状态装饰器。
//
// ── 为什么单独成文件（判据）──────────────────────────────────────────────────
// ① **无装饰器、无 import** ⇒ 能被 `scripts/tests/_ets-harness.mjs` 直接执行**真源码**做单测
//    （harness 明文限制：出现 `@Xxx` 装饰器即抛，见该文件 :44/:193-197）；`@ObservedV2` 的模型壳
//    因此必须与本文件分离；
// ② 它是「落盘前唯一必经之路」：`__ob_` 污染的防线就在这里（见下）；
// ③ 纯函数 ⇒ 可断言"13 字段逐字段相等 / 往返一致 / 脏数据被拒"。
//
// ── 字段来源取证（不是凭印象）───────────────────────────────────────────────
// SDK：`sdk/default/hms/ets/api/@hms.core.readerservice.readerComponent.d.ets:69-200`
//   `interface ReaderSetting { fontName?; fontSize?; fontWeight?; fontColor?; fontPath?; lineHeight?;
//    nightMode?; themeColor?; themeBgImg?; flipMode?; scaledDensity?; viewPortWidth?; viewPortHeight? }`
//   —— **13 个字段全部 optional，@since 5.0.4(16)**。
// 页面默认值：`ReaderPage3.ets:1804-1828`（与上面 13 个字段逐一对应）。
// `readerSetting` 的持久位：`PreferencesUtil.putSync('ReaderSetting_<书名>', this.readerSetting)`
//   （`:3284` / `:4150`），读取处有一道"类型体检"（`:4133-4144`，历史上被污染过一次）。
//
// ── 为什么不能把响应式模型直接落盘（`__ob_` 陷阱）────────────────────────────
// 官方 FAQ（documentId `FAQ/UI框架/组件使用/ObservedV2与_Trace装饰的对象key都带有_ob_导致反序列化异常/faqs-arkui-1587`）：
//   「@ObservedV2与@Trace装饰的对象key都带有__ob_导致反序列化出现异常…
//     状态管理V2装饰器会为装饰的变量生成getter和setter方法，同时为原有变量名添加__ob_的前缀」
// ⇒ 模型 = `@ObservedV2`（响应式真源）；**落盘与 `setPageConfig` 一律先过 `toReadSettingRecord()`**，
//   本文件只产出**普通对象**，`hasLeakedObservingKeys()` 就是这条防线的断言工具。
//
// 回退：删本文件 + 从 `scripts/tests/run-all.mjs` 去掉对应测试项（本阶段无人引用，回退零风险）。

// ⚠️ ArkTS 要求 import 必须在所有其它语句之前（`arkts-no-misplaced-imports`，实测编译报错），
//   故常量 `READ_SETTING_FIELDS` 放到了 import 之后。
import { SYSTEM_CJK_FONT_NAME } from './ReaderConst'

/** 13 个字段名（顺序与 SDK 接口声明一致，供"键集合"断言与序列化稳定性使用） */
export const READ_SETTING_FIELDS: string[] = [
  'fontName', 'fontSize', 'fontWeight', 'fontColor', 'fontPath', 'lineHeight', 'nightMode',
  'themeColor', 'themeBgImg', 'flipMode', 'scaledDensity', 'viewPortWidth', 'viewPortHeight'
]

/**
 * 设置的**纯数据形状**。
 *
 * 与 SDK 的 `readerCore.ReaderSetting` 字段同名同类型，区别只有一点：这里是**必填**（默认值由
 * `defaultReadSettingRecord()` 给）。理由：调用方少一层 `??` 判断，且"缺字段"这件事在
 * `fromReadSettingRecord()` 里一次性补齐 —— 与页面 `:4133-4144` 的"类型体检 + 丢弃重建"同语义。
 */
export interface ReadSettingRecord {
  fontName: string
  fontSize: number
  fontWeight: number
  fontColor: string
  fontPath: string
  lineHeight: number
  nightMode: boolean
  themeColor: string
  themeBgImg: string
  flipMode: string
  scaledDensity: number
  viewPortWidth: number
  viewPortHeight: number
}

/**
 * 默认字体文件（页面 `:1814` 的兜底路径，理由见那里 2026-10-12 的注释）。
 * ⚠️ 与 `fontName` 是**两件事**：族名走 `ReaderConst.SYSTEM_CJK_FONT_NAME`（值 = '鸿蒙黑体'，
 * 真机 `FONTPROBE` 实测），路径是引擎索要字体字节时的兜底。
 */
export const DEFAULT_FONT_PATH: string = '/system/fonts/HarmonyOS_Sans_SC.ttf'

/**
 * 生成默认记录。
 *
 * ⚠️ 有 3 个字段**不能**在这里写死：`scaledDensity` / `viewPortWidth` / `viewPortHeight`
 * 都来自运行时（`display.getDefaultDisplaySync().scaledDensity` 与窗口尺寸，
 * 页面 `:1823-1827`）。故做成入参、由调用方在**同一时刻**取好传进来——本文件保持纯函数。
 *
 * @param scaledDensity 屏幕 scaledDensity（>0 才有效，页面同款兜底为 1）
 * @param viewPortWidth 视口宽（px，与 `ReaderSetting.viewPortWidth` 同单位）
 * @param viewPortHeight 视口高（px）
 */
export function defaultReadSettingRecord(scaledDensity: number, viewPortWidth: number,
  viewPortHeight: number): ReadSettingRecord {
  const rec: ReadSettingRecord = {
    fontName: SYSTEM_CJK_FONT_NAME,
    fontSize: 18,
    fontWeight: 400,
    fontColor: '#000000',
    fontPath: DEFAULT_FONT_PATH,
    lineHeight: 1.9,
    nightMode: false,
    themeColor: 'rgba(248, 249, 250, 1)',
    themeBgImg: '',
    flipMode: '0',
    scaledDensity: scaledDensity > 0 ? scaledDensity : 1,
    viewPortWidth: viewPortWidth,
    viewPortHeight: viewPortHeight
  }
  return rec
}

function isNum(v: Object | null | undefined): boolean {
  return typeof v === 'number' && !Number.isNaN(v as number)
}

/**
 * 把任意来源（页面 `readerSetting`、持久位读回的对象、响应式模型）**投影**成记录。
 *
 * 关键约定：
 * · **只取 13 个已知字段** ⇒ `@ObservedV2` 生成的 `__ob_xxx` 外壳键、以及历史脏字段一律被丢弃；
 * · 缺失/类型不对 ⇒ 用 `fallback` 的对应值（不给 `fallback` 就报错，避免静默造默认值）；
 * · 不做范围夹取：字号/行距的合法区间属**业务规则**，本函数不擅自引入（见文件尾 TODO）。
 *
 * @param src 任意对象（可空 → 全用 fallback）
 * @param fallback 缺字段时的取值来源
 */
export function fromReadSettingRecord(src: Object | null | undefined,
  fallback: ReadSettingRecord): ReadSettingRecord {
  const o = (src ?? {}) as Record<string, Object>
  const out: ReadSettingRecord = {
    fontName: typeof o.fontName === 'string' ? o.fontName as string : fallback.fontName,
    fontSize: isNum(o.fontSize) ? o.fontSize as number : fallback.fontSize,
    fontWeight: isNum(o.fontWeight) ? o.fontWeight as number : fallback.fontWeight,
    fontColor: typeof o.fontColor === 'string' ? o.fontColor as string : fallback.fontColor,
    fontPath: typeof o.fontPath === 'string' ? o.fontPath as string : fallback.fontPath,
    lineHeight: isNum(o.lineHeight) ? o.lineHeight as number : fallback.lineHeight,
    nightMode: typeof o.nightMode === 'boolean' ? o.nightMode as boolean : fallback.nightMode,
    themeColor: typeof o.themeColor === 'string' ? o.themeColor as string : fallback.themeColor,
    themeBgImg: typeof o.themeBgImg === 'string' ? o.themeBgImg as string : fallback.themeBgImg,
    flipMode: typeof o.flipMode === 'string' ? o.flipMode as string : fallback.flipMode,
    scaledDensity: isNum(o.scaledDensity) && (o.scaledDensity as number) > 0
      ? o.scaledDensity as number : fallback.scaledDensity,
    viewPortWidth: isNum(o.viewPortWidth) ? o.viewPortWidth as number : fallback.viewPortWidth,
    viewPortHeight: isNum(o.viewPortHeight) ? o.viewPortHeight as number : fallback.viewPortHeight
  }
  return out
}

/**
 * 落盘 / 交给引擎之前的**唯一出口**：产出一个 13 键的普通对象。
 * （`readerCore.ReaderSetting` 全是 optional 字段，本返回值可直接赋给它。）
 */
export function toReadSettingRecord(src: Object | null | undefined,
  fallback: ReadSettingRecord): ReadSettingRecord {
  return fromReadSettingRecord(src, fallback)
}

/**
 * 类型体检：是否是一份**可用**的设置记录。
 *
 * 复刻并加深页面 `:4133-4144` 的判据（那里只查 `fontSize`/`lineHeight` 是 number）：
 * 这里按字段类型全查一遍，但不要求"非默认值"——用户完全可能就用默认字号。
 */
export function isValidReadSettingRecord(o: Object | null | undefined): boolean {
  if (o === null || o === undefined || typeof o !== 'object') {
    return false
  }
  const r = o as Record<string, Object>
  if (typeof r.fontSize !== 'number' || typeof r.lineHeight !== 'number') {
    return false
  }
  if (typeof r.fontName !== 'string' || typeof r.fontPath !== 'string') {
    return false
  }
  if (typeof r.fontWeight !== 'number' || typeof r.fontColor !== 'string') {
    return false
  }
  if (typeof r.nightMode !== 'boolean') {
    return false
  }
  if (typeof r.themeColor !== 'string' || typeof r.themeBgImg !== 'string') {
    return false
  }
  if (typeof r.flipMode !== 'string') {
    return false
  }
  return isNum(r.scaledDensity) && isNum(r.viewPortWidth) && isNum(r.viewPortHeight)
}

/**
 * 两个记录是否逐字段相等（用于"投影是否真的没变"的断言，避免整对象 JSON 比较的顺序陷阱）。
 *
 * ⚠️ 逐字段显式比较而不是 `JSON.stringify`：① 字段顺序不参与判定；② ArkTS 里把
 * interface 转 `Record<string, Object>` 会被编译器判为可疑转换（实测 `2846`），显式比较最稳。
 */
export function readSettingRecordEquals(a: ReadSettingRecord, b: ReadSettingRecord): boolean {
  return a.fontName === b.fontName
    && a.fontSize === b.fontSize
    && a.fontWeight === b.fontWeight
    && a.fontColor === b.fontColor
    && a.fontPath === b.fontPath
    && a.lineHeight === b.lineHeight
    && a.nightMode === b.nightMode
    && a.themeColor === b.themeColor
    && a.themeBgImg === b.themeBgImg
    && a.flipMode === b.flipMode
    && a.scaledDensity === b.scaledDensity
    && a.viewPortWidth === b.viewPortWidth
    && a.viewPortHeight === b.viewPortHeight
}

/**
 * **边界投影**（S2-b-1）：只保留 13 个已知字段，**值原样透传**（不做类型纠正）。
 *
 * 与 `toReadSettingRecord()` 的分工：
 * · `toReadSettingRecord()` = "我要一份能用的记录" ⇒ 缺字段/类型错就用 fallback 补齐；
 * · `pickReadSettingFields()` = "我要把手上这份交给引擎/落盘，只求把垃圾键剔掉" ⇒ **不改值**。
 *
 * 为什么边界上不做纠正：那会改变既有渲染行为（脏书原来什么样就下发什么样）。剔除多余键
 * 已经足够挡住 `@ObservedV2` 的 `__ob_` 外壳与历史脏字段，属"零行为变化"的收口。
 *
 * @returns 13 字段齐全且类型合法时返回新对象；否则 `null`（调用方应原样透传，保持既有行为）
 */
export function pickReadSettingFields(src: Object | null | undefined): ReadSettingRecord | null {
  if (!isValidReadSettingRecord(src)) {
    return null
  }
  const o = src as Record<string, Object>
  const out: ReadSettingRecord = {
    fontName: o.fontName as string,
    fontSize: o.fontSize as number,
    fontWeight: o.fontWeight as number,
    fontColor: o.fontColor as string,
    fontPath: o.fontPath as string,
    lineHeight: o.lineHeight as number,
    nightMode: o.nightMode as boolean,
    themeColor: o.themeColor as string,
    themeBgImg: o.themeBgImg as string,
    flipMode: o.flipMode as string,
    scaledDensity: o.scaledDensity as number,
    viewPortWidth: o.viewPortWidth as number,
    viewPortHeight: o.viewPortHeight as number
  }
  return out
}

/**
 * `__ob_` 防线的断言工具：对象是否混入了状态管理 V2 生成的内部键。
 *
 * 用在两处：① 单测（守 `toReadSettingRecord` 的输出形态）；
 * ② 将来的落盘守卫（写 Preferences 前 assert 一次，防止有人把响应式模型直接塞给 `putSync`）。
 */
export function hasLeakedObservingKeys(o: Object | null | undefined): boolean {
  if (o === null || o === undefined) {
    return false
  }
  const json: string = JSON.stringify(o)
  if (json === undefined) {
    return false
  }
  return json.indexOf('__ob_') >= 0
}

// TODO（**未定，属待决策项**，本轮不擅自引入）：
//   字号 / 行距 / 缩放的**合法区间夹取**该收在哪一层？
//   现状：区间只写在 UI 滑条（`ReaderFontDialog` 的 min/max）与 `migrateReaderSetting()` 里，
//   本记录层**不做**夹取 —— 一旦在这里加，就会出现"UI 一套、模型一套"两份规则。
//   工程先例：`ShelfPrefs.setUserColumns` 曾因"写侧不夹取"出过缺陷（docs §71）。
//   ⇒ 迁移完成、UI 只剩模型一个入口时再决定（届时夹取放本记录层才没有歧义）。
