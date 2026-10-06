import { MaterialColumnModifier } from '../../../common/utils/ImmersiveMaterialUtil'
// ── 全局震动反馈（2026-09-25 新增）────────────────────────────────────────────
import { Haptics } from '../../../common/utils/Haptics'
import { hilog } from '@kit.PerformanceAnalysisKit'
import { common } from '@kit.AbilityKit'
import { ReaderCustomBg } from '../../../common/utils/ReaderCustomBg'
import { ReaderTexture } from '../../../common/utils/ReaderTexture'

/**
 * 「保存此颜色方案」确认弹窗（2026-09-26 按用户设计新建；2026-10-06 升 V3）。
 *
 * ── 用户需求原文 ──────────────────────────────────────────────────────────
 * 「在开启自定义后，翻页右侧再增加个按钮，**保存方案**，点击后出现弹窗，
 *   **是否保存此颜色方案，确定，取消**。」
 * 「无论是预设颜色、材质，自定义颜色、材质，预设字体颜色、自定义字体颜色，
 *   全能自由搭配，并且被保存成方案。」（2026-10-06）
 *
 * ── 配方与邻居完全一致（刻意照抄 `SleepTimerDialog`）────────────────────────
 * · 材质走 `CustomDialogControllerOptions.systemMaterial`
 *   （`custom_dialog_controller.d.ts`，@since 26.0.0）+ `customStyle:false`
 *   ⇒ 悬空四圆角 + 半透明沉浸光感；内容层**一个背景属性都不设**（设了会挡掉材质）。
 * · `@StorageLink('readerColorMode')` 而不是 `@Prop`：弹窗由页面**每次新建**时构造，
 *   但日夜配色是"随页面变化"的，直接吃父页面写进 AppStorage 的同一个 key
 *   ⇒ 零传参、天然同步（与 `ReaderListenDialog` / `SleepTimerDialog` 同款）。
 * · 次级按钮（取消）底色/字色必须随日夜翻，否则夜间是"深底黑字"看不见。
 *
 * ── V3：预览要能表达"材质背景" ─────────────────────────────────────────────
 * 弹窗只收**种类 + 取值**（`bgKind/bgHex/texId/customTexId`，全是基本类型 —— 不传
 * `Resource`，避免 @Prop 传资源对象的坑），缩略图在 `aboutToAppear` 里本地解析一次。
 * 本弹窗**不做任何持久化**：只负责"问一句"，保存动作由页面（`ReaderPage3`）执行。
 */
@CustomDialog
export struct ReaderSaveSchemeDialog {
  controller?: CustomDialogController

  // ── 待保存的**背景家族**（与 `SchemeV3` 同字段）──────────────────────────────
  /** 背景种类：0 = 纯色 / 1 = 内置材质 / 2 = 自定义材质（`ReaderCustomBg.BG_KIND_*`） */
  @Prop bgKind: number = 0
  /** 纯色背景色（bgKind = 0 时用），用于预览块与文案 */
  @Prop bgHex: string = '#FFFFFF'
  /** 内置材质编号（bgKind = 1 时用） */
  @Prop texId: number = 0
  /** 自定义材质 id（bgKind = 2 时用） */
  @Prop customTexId: string = ''
  /** 背景模糊开关（属背景家族，随方案一起存） */
  @Prop blurOn: boolean = false
  /** 背景模糊强度（px） */
  @Prop blurRadius: number = 0

  /**
   * 待保存的**字色**：`''` = 字色未手动选过（应用时按背景自动对比），
   * 预览块的"字"用自动对比色（材质背景则垫一层深色药丸保证可读）。
   */
  @Prop fontHex: string = ''

  /** 确定：交给调用方去落盘 */
  onConfirm: () => void = (): void => {}
  /** 取消 / 关闭 */
  onCancel: () => void = (): void => {}

  /** 0 = 夜间，1 = 日间（与 `ReaderPage3.colorMode` 同义，见文件头） */
  @StorageLink('readerColorMode') colorMode: number = 1

  private surface: MaterialColumnModifier = new MaterialColumnModifier(Color.White, true)

  // ── 预览（aboutToAppear 一次性算好；build 里只读）────────────────────────────
  /** 内置材质缩略图（rawfile 名；'' = 不用） */
  private thumbFile: string = ''
  /** 自定义材质缩略图（`file://` 地址；'' = 不用） */
  private thumbUri: string = ''
  /** 背景文案：'背景 #RRGGBB' / '材质 007' / '自定义材质'（失效时加"（已失效）"） */
  private bgLabel: string = ''
  /** 预览"字"的颜色 */
  private previewFontHex: string = '#000000'
  /** 预览"字"是否垫深色药丸（自动对比 + 材质背景时用） */
  private fontPill: boolean = false

  private subBtnBg(): string {
    return this.colorMode == 0 ? 'rgba(255, 255, 255, 0.14)' : 'rgba(0, 0, 0, 0.06)';
  }

  private subBtnFg(): string {
    return this.colorMode == 0 ? 'rgba(255, 255, 255, 0.88)' : 'rgba(0, 0, 0, 0.88)';
  }

  /** 三位编号文案（texture_001 ⇒ '001'，与「更多材质」命名规则一致） */
  private label(id: number): string {
    return id < 10 ? '00' + id : (id < 100 ? '0' + id : '' + id)
  }

  /** 轻量自动对比：按 hex 的感知亮度选黑/白（与 `ReaderCustomBg` 同一思路的简化版） */
  private autoFont(hex: string): string {
    const h = hex.replace('#', '')
    if (h.length !== 6) {
      return '#000000'
    }
    const r = parseInt(h.substring(0, 2), 16)
    const g = parseInt(h.substring(2, 4), 16)
    const b = parseInt(h.substring(4, 6), 16)
    return (0.2126 * r + 0.7152 * g + 0.0722 * b) > 128 ? '#000000' : '#FFFFFF'
  }

  private fontLabel(): string {
    return this.fontHex.length > 0 ? this.fontHex : '自动'
  }

  aboutToAppear(): void {
    // 材质不可用时的兜底色（夜里给深底，否则白底 + 白字）
    this.surface = new MaterialColumnModifier(
      this.colorMode == 0 ? '#1F1F1F' : Color.White, true);
    // ── 背景预览源与文案（V3：材质/自定义材质都要能表达）────────────────────────
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext
    if (this.bgKind === ReaderCustomBg.BG_KIND_TEX) {
      const t = ReaderTexture.byId(ctx, this.texId)
      if (t === null) {
        this.bgLabel = '材质 ' + this.label(this.texId) + '（已失效）'
      } else {
        this.thumbFile = t.file
        this.bgLabel = '材质 ' + this.label(this.texId)
      }
    } else if (this.bgKind === ReaderCustomBg.BG_KIND_CUSTOM) {
      const c = ReaderTexture.customById(ctx, this.customTexId)
      if (c === null) {
        this.bgLabel = '自定义材质（已失效）'
      } else {
        this.thumbUri = 'file://' + c.path
        this.bgLabel = '自定义材质'
      }
    } else {
      this.bgLabel = '背景 ' + this.bgHex
    }
    if (this.blurOn) {
      this.bgLabel += ' · 模糊 ' + this.blurRadius.toFixed(0)
    }
    // ── 预览"字"的颜色 ────────────────────────────────────────────────────────
    if (this.fontHex.length > 0) {
      this.previewFontHex = this.fontHex
    } else if (this.bgKind === ReaderCustomBg.BG_KIND_COLOR) {
      this.previewFontHex = this.autoFont(this.bgHex)
    } else {
      // 材质背景 + 自动对比：图片明暗未知 ⇒ 白字 + 深色药丸（任何材质上都读得清）
      this.previewFontHex = '#FFFFFF'
      this.fontPill = true
    }
  }

  build() {
    Column() {
      Text('是否保存此方案（背景 + 字色）')
        .fontSize(16)
        .fontWeight(600)

      // 预览：这一块就是即将存进方案区的样子（底 = 背景色/材质图，"字" = 字色）
      Row({ space: 10 }) {
        Stack() {
          if (this.thumbUri.length > 0) {
            Column()
              .width(40)
              .height(26)
              .borderRadius(13)
              .backgroundImage(this.thumbUri)
              .backgroundImagePosition(Alignment.Center)
              .backgroundImageSize(ImageSize.Cover)
          } else if (this.thumbFile.length > 0) {
            Column()
              .width(40)
              .height(26)
              .borderRadius(13)
              // ⚠️ Resource 走 `ReaderTexture.res()` 缓存（反复 new 会让 Image 反复解码）
              .backgroundImage(ReaderTexture.res(this.thumbFile))
              .backgroundImagePosition(Alignment.Center)
              .backgroundImageSize(ImageSize.Cover)
          } else {
            Column()
              .width(40)
              .height(26)
              .borderRadius(13)
              .backgroundColor(this.bgHex)
          }
          Text('字')
            .fontSize(15)
            .fontWeight(600)
            .fontColor(this.previewFontHex)
            .backgroundColor(this.fontPill ? 'rgba(0, 0, 0, 0.45)' : Color.Transparent)
            .borderRadius(8)
            .padding(this.fontPill ? { left: 5, right: 5 } : 0)
        }
        .width(40)
        .height(26)
        .borderRadius(13)
        .borderWidth(1)
        .borderColor(this.colorMode == 0 ? 'rgba(255, 255, 255, 0.35)' : 'rgba(0, 0, 0, 0.25)')
        // ⚠️ 2026-10-06：文案最长形如「背景 自定义材质 · 模糊 30 · 字色 #FFABAB」，
        //   不加约束会顶出弹窗（同一轮用户反馈的"预览溢出"）⇒ 限宽换行，最多两行。
        Text(`${this.bgLabel} · 字色 ${this.fontLabel()}`)
          .fontSize(13)
          .fontColor(this.colorMode == 0 ? 'rgba(248, 249, 250, 0.75)' : 'rgba(19, 19, 19, 0.7)')
          .layoutWeight(1)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .padding({ top: 14, bottom: 4 })

      Row({ space: 12 }) {
        // ⚠️ 2026-09-25 真机日志定位（2.md）：点取消时点击识别成功（CLK RACC T: Button）、
        //   onClick 也执行了（Haptics 探测日志都在），但 `this.controller?.close()` 没有关掉弹窗；
        //   而**页面侧**持有的 controller 调 close() 一直可靠（设置面板 Blank 关闭从未失手）。
        //   ⇒ 关闭权收回页面：onCancel/onConfirm 回调里由页面 close()，这里的双保险保留。
        Button('取消')
          .layoutWeight(1)
          .backgroundColor(this.subBtnBg())
          .fontColor(this.subBtnFg())
          .onClick(() => {
            hilog.info(0x0000, 'testTag', 'saveSchemeDlg: cancel clicked')
            Haptics.tap();
            this.onCancel()
            this.controller?.close()
          })
        Button('确定')
          .layoutWeight(1)
          .backgroundColor('rgba(0, 125, 255, 1.00)')
          .fontColor(Color.White)
          .onClick(() => {
            hilog.info(0x0000, 'testTag', 'saveSchemeDlg: confirm clicked')
            Haptics.tap();
            this.onConfirm()
            this.controller?.close()
          })
      }
      .width('100%')
      .padding({ top: 14 })
    }
    .width('100%')
    .padding(20)
    .borderRadius(20)
    .attributeModifier(this.surface)
  }
}
