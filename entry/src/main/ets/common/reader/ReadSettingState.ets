// 阅读设置的**响应式模型壳**（2026-11-04 渲染侧 S2-b-2：设置域重构第二步）。
//
// ── 这个文件解决什么 ────────────────────────────────────────────────────────
// S2-a 已把"默认值 / 编解码 / 校验"收进 `ReadSettingRecord.ets`（纯函数，可单测）。
// 但**真源**仍是页面的 `@State readerSetting`。要让设置域真正可拆、可测，需要一份
// 独立于页面的响应式承载：本类用 `@ObservedV2` + `@Trace`，将来由它持 13 个字段并驱动 UI。
//
// ── 为什么是 `@ObservedV2`（官方原文取证）────────────────────────────────────
// · documentId `…/状态管理V1和V2混用场景/…/arkts-v1-v2-mixusage` 限制条件 1：
//   「V1装饰器不能和@ObservedV2一起使用。因为@ObservedV2/@Trace有自己独立的观察能力，
//     **不仅可以在@ComponentV2中使用，也可以独立在@Component中使用**…」
//   ⇒ V1 的 `@Component`（本页）可以直接用这个类，**只要不套 V1 装饰器**。
// · 同文档限制条件 2：「V2->V1，V1不支持用装饰器接收@ObservedV2装饰的class，否则编译报错。」
//   ⇒ 页面里必须写成**普通成员**：`private settingState: ReadSettingState = new ReadSettingState(...)`，
//   **不能**写 `@State`/`@Prop`/`@Link`。
// · documentId `…/arkts-new-observedv2-and-trace`：
//   「@ObservedV2仅能装饰class」「@Trace是class中属性的装饰器」「被@Trace装饰的属性property变化时，
//     仅会通知property关联的组件进行刷新」「需通过 new 操作符实例化后，才具备被观测变化的能力」
//   「@Trace不支持观察Function类型的数据」⇒ 本类**不放回调/方法字段**，方法只是普通成员函数。
//
// ── 当前状态（2026-11-04 S2-c(10) 后，**13/13 字段已是真源**）─────────────────────
// · **已迁字段** = `readerCore.ReaderSetting` 全部 13 个：
//   fontName / fontSize / fontWeight / fontColor / fontPath / lineHeight / nightMode /
//   themeColor / themeBgImg / flipMode / scaledDensity / viewPortWidth / viewPortHeight。
//   运行期写入口先改本类、再同步回页面 `readerSetting` 的快照（供未改的读点使用）；
//   装载期与设备度量类来源（持久位/接续/全局记录/窗口/系统密度）方向相反：来源 → 本类 → 快照。
// · **未迁字段**：无。进度计（`RATCHET_UNMIGRATED_WRITES`）= 0。
// · **迁移脚手架已拆**（S2-c(10)）：`syncFromExcept()` 与 `ReaderPage3.MIGRATED_SETTING_FIELDS`
//   已删除 —— 边界出口不再从页面快照回灌，杜绝"陈旧快照盖掉模型"这一类隐患。
// · 仍保留：页面 `@State readerSetting`（纯快照）。删它需要先解决两件事，见施工记录 §90.4：
//   ① 25+ 处把它当**参数**传给 `geom()` / `scrollFontFamily()` 等纯函数（改传本类实例有 `__ob_` 外溢风险）；
//   ② V1 `@Component` 读 V2 `@Trace` 驱动 UI 刷新这一能力尚未真机验证。
//
// ── `__ob_` 陷阱（官方原文）──────────────────────────────────────────────────
// documentId `FAQ/UI框架/组件使用/ObservedV2与_Trace装饰的对象key都带有_ob_导致反序列化异常/faqs-arkui-1587`：
//   「@ObservedV2与@Trace装饰的对象key都带有__ob_…状态管理V2装饰器会为装饰的变量生成getter和setter方法，
//     同时为原有变量名添加__ob_的前缀」
// ⇒ **绝不能**把本类实例直接交给 `PreferencesUtil.putSync` 或 `JSON.stringify` 落盘；
//   一律先 `snapshot()`（逐字段显式拷贝成普通对象，天然不含 `__ob_`）。
//
// 回退：删本文件 + 把 `ReaderPage3.settingForBoundary()` 还原为 S2-b-1 的实现（`git revert` 本提交）。

import { defaultReadSettingRecord, fromReadSettingRecord, ReadSettingRecord } from './ReadSettingRecord'

@ObservedV2
export class ReadSettingState {
  @Trace fontName: string = ''
  @Trace fontSize: number = 18
  @Trace fontWeight: number = 400
  @Trace fontColor: string = '#000000'
  @Trace fontPath: string = ''
  @Trace lineHeight: number = 1.9
  @Trace nightMode: boolean = false
  @Trace themeColor: string = ''
  @Trace themeBgImg: string = ''
  @Trace flipMode: string = '0'
  @Trace scaledDensity: number = 1
  @Trace viewPortWidth: number = 0
  @Trace viewPortHeight: number = 0

  /**
   * @param init 初始值（通常是 `defaultReadSettingRecord(...)` 或页面当前 `readerSetting`）；
   *   缺字段按内置默认补齐（复用记录层的 `fromReadSettingRecord`，不另立规则）
   */
  constructor(init: Object | null | undefined) {
    this.assignFrom(init)
  }

  /** 把任意来源镜像进本类（缺字段/类型错 ⇒ 回退到内置默认，与记录层同一套判据） */
  assignFrom(src: Object | null | undefined): void {
    const base: ReadSettingRecord = defaultReadSettingRecord(
      this.scaledDensity > 0 ? this.scaledDensity : 1, this.viewPortWidth, this.viewPortHeight)
    const rec: ReadSettingRecord = fromReadSettingRecord(src, base)
    this.fontName = rec.fontName
    this.fontSize = rec.fontSize
    this.fontWeight = rec.fontWeight
    this.fontColor = rec.fontColor
    this.fontPath = rec.fontPath
    this.lineHeight = rec.lineHeight
    this.nightMode = rec.nightMode
    this.themeColor = rec.themeColor
    this.themeBgImg = rec.themeBgImg
    this.flipMode = rec.flipMode
    this.scaledDensity = rec.scaledDensity
    this.viewPortWidth = rec.viewPortWidth
    this.viewPortHeight = rec.viewPortHeight
  }

  /**
   * 取**普通对象快照**（13 字段显式拷贝）。
   *
   * ⚠️ 这是本类交给外部的**唯一**出口：`@Trace` 生成的 getter/setter 与 `__ob_` 内部键
   * 不会出现在这里（逐字段读 + 逐字段写新建对象）；可直接给 `setPageConfig` 或 Preferences。
   */
  snapshot(): ReadSettingRecord {
    const out: ReadSettingRecord = {
      fontName: this.fontName,
      fontSize: this.fontSize,
      fontWeight: this.fontWeight,
      fontColor: this.fontColor,
      fontPath: this.fontPath,
      lineHeight: this.lineHeight,
      nightMode: this.nightMode,
      themeColor: this.themeColor,
      themeBgImg: this.themeBgImg,
      flipMode: this.flipMode,
      scaledDensity: this.scaledDensity,
      viewPortWidth: this.viewPortWidth,
      viewPortHeight: this.viewPortHeight
    }
    return out
  }
}

export default ReadSettingState
