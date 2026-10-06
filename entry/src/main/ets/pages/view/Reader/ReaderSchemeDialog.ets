/**
 * 「更多方案」弹窗（2026-09-25 新增，用户设计；2026-10-06 升 V3）。
 *
 * ── 需求原文 ──────────────────────────────────────────────────────────────
 * 「保存的方案在底部显示很差，也拖不动，我们直接做一个**和更多材质一样的按钮和弹窗**，
 *   就放在更多材质旁边，就叫做**更多方案**。效果一样，如果选择的方案是其中，
 *   则**按钮外有红圈**。」
 * ⇒ 方案全部收进本弹窗：四列网格、点选即应用、可删除。当前正在使用的方案画橙圈，
 *   弹窗关闭后「更多方案」按钮持圈（页面侧 `bgFocus === 'scheme'` 判定）。
 *
 * ── V3（2026-10-06 用户诉求：「预设颜色、材质，自定义颜色、材质，预设字体颜色、
 *    自定义字体颜色，全能自由搭配，并且被保存成方案」）──────────────────────────
 * · 一条方案 = **背景家族**（纯色 / 内置材质 / 自定义材质 + 模糊档位）× **字色家族**
 *   （自动对比 / 指定字色），见 `SchemeV3`；
 * · 缩略图：纯色 = 色块；内置材质 = rawfile 图（`ReaderTexture.res`，走缓存）；
 *   自定义材质 = `file://` 沙箱图；左下角标"材质编号 / 自定 + 模糊档位"；
 * · 圈选键：`ReaderCustomBg.schemeKeyV3(s)`（V2 用背景 hex 认方案，材质方案认不出来）；
 * · **素材已失效**（材质文件被删）的方案仍显示（角标"失效"）—— 让用户能删掉它，
 *   点它则页面侧提示"材质不存在"且不动当前背景（见 `ReaderPage3.applyScheme`）。
 *
 * ── 交互 ──────────────────────────────────────────────────────────────────
 * · 点缩略图 = 应用该方案（回调页面 `applyScheme`）并自关；
 * · 右上角小 × = 删除该方案（本弹窗内即时刷新列表）。
 * 弹窗配方与「更多材质」同款：`systemMaterial` 沉浸光感 + 弹簧出入场。
 */
import { common } from '@kit.AbilityKit'
import { ReaderCustomBg, SchemeV3 } from '../../../common/utils/ReaderCustomBg'
import { ReaderTexture } from '../../../common/utils/ReaderTexture'
import { Haptics } from '../../../common/utils/Haptics'
import UiMotion from '../../../common/utils/UiMotion'

/**
 * 一条方案卡片的**渲染快照**（`aboutToAppear` 一次性算好）。
 * 构建期只读这些纯字符串字段 ⇒ 不在 build 里做文件枚举/颜色解析
 * （`ReaderTexture.byId` 会枚举 rawfile 目录，放 build 里会每帧跑）。
 */
interface SchemeCard {
  s: SchemeV3
  key: string
  /** 内置材质的 rawfile 名（'' = 本卡片不用图片） */
  resFile: string
  /** 自定义材质的 `file://` 地址（'' = 不用） */
  uri: string
  /** 纯色背景色（'' = 不用） */
  color: string
  /** 左下角标：'001' / '自定' / '失效' / '' */
  badge: string
  /** 模糊角标：'' = 未开 */
  blur: string
  /** "字"的显示色 */
  fontHex: string
  /** "字"是否要垫一层深色药丸（自动对比 + 材质背景时的可读性保险） */
  pill: boolean
}

@CustomDialog
export struct ReaderSchemeDialog {
  controller?: CustomDialogController

  /** 当前应用中的**方案键**（页面 `bgFocus==='scheme'` 时的 `schemeFocusKey`）；'' = 无 */
  @Prop focusKey: string = ''

  /** 点选回调：页面侧 `applyScheme(e)` 应用方案；本弹窗随后自关 */
  onPick: (e: SchemeV3) => void = (): void => {}

  /**
   * 关闭回调（2026-09-26 弹窗协调）：完成/选中后由**页面**关本弹窗并恢复父弹窗
   * （设置面板）—— 关闭权在页面（弹窗内 controller?.close() 曾失灵，见页面侧注释）。
   */
  onClose: () => void = (): void => {}

  /** 0 = 夜间，1 = 日间（与 `ReaderPage3.colorMode` 同义，随 AppStorage 同步） */
  @StorageLink('readerColorMode') colorMode: number = 1

  /** 卡片列表（弹窗内自持 @State：删除后本弹窗即时刷新，不必重建弹窗） */
  @State cards: SchemeCard[] = []

  aboutToAppear(): void {
    this.cards = this.buildCards()
  }

  /** 方案 → 卡片渲染快照（材质存在性、缩略图源、字色都在这里定死） */
  private buildCards(): SchemeCard[] {
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext
    const out: SchemeCard[] = []
    const list: SchemeV3[] = ReaderCustomBg.loadSchemesV3()
    for (const s of list) {
      let resFile: string = ''
      let uri: string = ''
      let color: string = ''
      let badge: string = ''
      let pill: boolean = false
      if (s.bgKind === ReaderCustomBg.BG_KIND_TEX) {
        const t = ReaderTexture.byId(ctx, s.texId)
        if (t === null) {
          // 材质文件已不在：仍列出（可删），点它由页面提示"材质不存在"
          badge = '失效'
        } else {
          resFile = t.file
          badge = this.label(s.texId)
        }
      } else if (s.bgKind === ReaderCustomBg.BG_KIND_CUSTOM) {
        const c = ReaderTexture.customById(ctx, s.customTexId)
        if (c === null) {
          badge = '失效'
        } else {
          uri = 'file://' + c.path
          badge = '自定'
        }
      } else {
        color = s.bgHex
      }
      // 字色：指定字色直接用它；自动对比时——纯色按背景亮度算，材质背景垫药丸用白字
      let fontHex: string = s.fontHex
      if (s.fontKind !== ReaderCustomBg.FONT_KIND_HEX) {
        if (color.length > 0) {
          const rgb = ReaderCustomBg.parseColor(color)
          fontHex = rgb === null ? '#000000' : ReaderCustomBg.contrastFont(rgb)
        } else {
          fontHex = '#FFFFFF'
          pill = true
        }
      }
      out.push({
        s: s,
        key: ReaderCustomBg.schemeKeyV3(s),
        resFile: resFile,
        uri: uri,
        color: color,
        badge: badge,
        blur: s.blurOn ? s.blurRadius.toFixed(0) : '',
        fontHex: fontHex,
        pill: pill
      })
    }
    return out
  }

  /** 三位编号文案（texture_001 ⇒ "001"，与用户定的命名规则一致） */
  private label(id: number): string {
    return id < 10 ? '00' + id : (id < 100 ? '0' + id : '' + id)
  }

  /** 该方案是否为当前应用中的（画橙圈） */
  private isFocused(card: SchemeCard): boolean {
    return this.focusKey.length > 0 && card.key === this.focusKey
  }

  private borderColorOf(card: SchemeCard): string {
    if (this.isFocused(card)) {
      return '#ff6600'
    }
    return this.colorMode == 0 ? 'rgba(248, 249, 250, 0.30)' : 'rgba(0, 0, 0, 0.20)'
  }

  /**
   * 底部角标占位 ⇒ 把居中的"字"往上让一点。
   * 两枚角标竖排（编号/自定 + 模糊）约 34vp 高，居中 24vp 高的"字"会压在第一枚上；
   * 一枚角标（约 16vp，贴底）不需要让。
   */
  private fontLift(card: SchemeCard): number {
    let n: number = 0
    if (card.badge.length > 0) {
      n++
    }
    if (card.blur.length > 0) {
      n++
    }
    return n >= 2 ? 18 : 0
  }

  build() {
    Column({ space: 12 }) {
      // 顶栏：标题 + 完成
      Row() {
        Text('更多方案')
          .fontSize(16)
          .fontWeight(600)
          .fontColor(this.colorMode == 0 ? 'rgba(248, 249, 250, 1)' : 'rgba(19, 19, 19, 1.00)')
        Blank()
        Text('完成')
          .fontSize(15)
          .fontColor('#007DFF')
          .onClick(() => {
            Haptics.tap();
            this.onClose()
          })
      }
      .width('100%')

      if (this.cards.length === 0) {
        Text('还没有保存过方案：调好背景（颜色或材质）与字色后，按「保存方案」即可存到这里')
          .fontSize(12)
          .fontColor(this.colorMode == 0 ? 'rgba(248, 249, 250, 0.5)' : 'rgba(19, 19, 19, 0.5)')
          .width('100%')
          .textAlign(TextAlign.Center)
          .padding({ top: 30, bottom: 30 })
      } else {
        // 方案网格：四列、纵向滚动（上限 100，装得下）
        Grid() {
          ForEach(this.cards, (card: SchemeCard) => {
            GridItem() {
              Stack({ alignContent: Alignment.TopEnd }) {
                // ── 背景层：自定义材质图 / 内置材质图 / 纯色 ────────────────────
                if (card.uri.length > 0) {
                  Column()
                    .width('100%')
                    .height(64)
                    .borderRadius(12)
                    .backgroundImage(card.uri)
                    .backgroundImagePosition(Alignment.Center)
                    .backgroundImageSize(ImageSize.Cover)
                    .borderWidth(this.isFocused(card) ? 2 : 1)
                    .borderColor(this.borderColorOf(card))
                } else if (card.resFile.length > 0) {
                  Column()
                    .width('100%')
                    .height(64)
                    .borderRadius(12)
                    // ⚠️ Resource 走 ReaderTexture.res() 缓存（每次 new 会让 Image 反复解码）
                    .backgroundImage(ReaderTexture.res(card.resFile))
                    .backgroundImagePosition(Alignment.Center)
                    .backgroundImageSize(ImageSize.Cover)
                    .borderWidth(this.isFocused(card) ? 2 : 1)
                    .borderColor(this.borderColorOf(card))
                } else {
                  Column()
                    .width('100%')
                    .height(64)
                    .borderRadius(12)
                    .backgroundColor(card.badge === '失效' ? '#9AA0A6' : card.color)
                    .borderWidth(this.isFocused(card) ? 2 : 1)
                    .borderColor(this.borderColorOf(card))
                }
                // ── 居中"字"：颜色 = 该方案的字色（自动对比已折算成具体色）────────
                Column() {
                  Text('字')
                    .fontSize(18)
                    .fontWeight(600)
                    .fontColor(card.fontHex)
                    .backgroundColor(card.pill ? 'rgba(0, 0, 0, 0.45)' : Color.Transparent)
                    .borderRadius(10)
                    .padding(card.pill ? { left: 7, right: 7, top: 1, bottom: 1 } : 0)
                }
                .width('100%')
                .height(64)
                .justifyContent(FlexAlign.Center)
                // 两枚角标竖排时把"字"往上让，避免压在第一枚角标上
                .padding({ bottom: this.fontLift(card) })
                .hitTestBehavior(HitTestMode.None)
                // ── 左下角标：材质编号 / 自定 / 失效 + 模糊档位（**竖排**，见下）────────
                // ⚠️ 2026-10-06 改竖排（用户实测："自定义背景 + 模糊30 存成方案后，预览底部
                //   `自定  模糊30` 字太多溢出了"）：4 列网格每格实宽约 66vp，两个角标横排
                //   ≈ 30 + 4 + 50 = 84vp ⇒ 必然溢出。竖排后最宽的那个（"模糊30"≈50vp）单独
                //   一行，任何档位/编号组合都装得下。
                Column({ space: 2 }) {
                  if (card.badge.length > 0) {
                    Text(card.badge)
                      .fontSize(10)
                      .fontColor('#FFFFFF')
                      .padding({ left: 5, right: 5, top: 1, bottom: 1 })
                      .borderRadius(6)
                      .backgroundColor('rgba(0, 0, 0, 0.55)')
                  }
                  if (card.blur.length > 0) {
                    Text('模糊' + card.blur)
                      .fontSize(10)
                      .fontColor('#FFFFFF')
                      .padding({ left: 5, right: 5, top: 1, bottom: 1 })
                      .borderRadius(6)
                      .backgroundColor('rgba(0, 0, 0, 0.55)')
                  }
                }
                .width('100%')
                .height(64)
                .padding({ left: 4, bottom: 4 })
                .justifyContent(FlexAlign.End)
                .alignItems(HorizontalAlign.Start)
                .hitTestBehavior(HitTestMode.None)
                // ── 删除（右上角小 ×）───────────────────────────────────────────
                Text('×')
                  .fontSize(11)
                  .fontWeight(600)
                  .fontColor('#FFFFFF')
                  .width(16)
                  .height(16)
                  .textAlign(TextAlign.Center)
                  .borderRadius(8)
                  .backgroundColor('rgba(0, 0, 0, 0.55)')
                  .margin({ right: 3, top: 3 })
                  .onClick(() => {
                    Haptics.tap();
                    ReaderCustomBg.deleteSchemeV3(card.s)
                    this.cards = this.buildCards()
                  })
              }
              .width('100%')
              .onClick(() => {
                Haptics.tap();
                this.onPick(card.s)
                this.onClose()
              })
              .clickEffect(UiMotion.CLICK)
            }
          }, (card: SchemeCard): string => 'sv3-' + card.key)
        }
        .columnsTemplate('1fr 1fr 1fr 1fr')
        .columnsGap(10)
        .rowsGap(10)
        .height(320)
        .width('100%')
        .scrollBar(BarState.Off)
      }
    }
    .width('100%')
    .padding(20)
  }
}
