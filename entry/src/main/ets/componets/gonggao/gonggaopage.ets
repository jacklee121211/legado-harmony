/**
 * ══════════════════════════════════════════════════════════════════════════════
 * 「公告」弹窗 —— 界面层（**改内容不用动这里**，去改同目录 `GonggaoData.ets`）
 * ══════════════════════════════════════════════════════════════════════════════
 *
 * 用户要求（原话归纳）：
 *   ①「显示风格按照系统整体的弹窗风格统一」  ⇒ 走 `docs/标准-弹窗与按钮统一规范.md`
 *      §2.1 @CustomDialog + §2.2 options 配方（由调用方 `Index.ets` 给）+ §2.3 内容层让出背景；
 *   ②「支持长文上下滚动」                    ⇒ 每页 = `Scroll` 包 `Column`；
 *   ③「图片展示」                            ⇒ `Image` 撑满宽度、按原比例、圆角 12；
 *   ④「左右滑动切换内容」                    ⇒ `Swiper` + 自绘指示点（不启用 Swiper 自带指示器）。
 *
 * ── 为什么只有「我知道了」一个按钮，没有右上角 ✕ ─────────────────────────────
 * 公告是**只读**内容，一个明确的关闭动作就够；多一个 ✕ 等于两个关闭语义，
 * 而且 ✕ 必须按规范 §1 做成 SymbolGlyph + 震动 + Q 弹三件套，收益不值得。
 * 点遮罩 / 返回键同样能关闭（由调用方 options 的 `autoCancel: true` + `cancel` 决定）。
 *
 * ── ⚠️ 本弹窗**不自己 close()** ──────────────────────────────────────────────
 * 2026-10-12 真机事故结论（`RenameBookDialog.ets:27-32` 原文）：`this.controller?.close()`
 * 在 `@CustomDialog` 子组件内**无效**（只能由创建 controller 的那一层关）。
 * ⇒ 这里只回调 `onConfirm()`，由 `Index.ets` 负责 `close()`。
 *
 * ── 为什么不把条目用 @Prop 传进来 ────────────────────────────────────────────
 * 内容是**编译期常量**（`GonggaoData.ets`），没有运行期变化 ⇒ 直接 import 最省事，
 * 也避免"弹窗参数不支持动态更新"（SDK `custom_dialog_controller.d.ts:756` NOTE 原文
 * 「Custom dialog box parameters **do not support dynamic updates**」）带来的迷惑。
 * 唯一从调用方传的是 `theme`（主色，与全应用主题同源，同 `RatingPromptDialog` 的做法）。
 */
import { MaterialColumnModifier } from '../../common/utils/ImmersiveMaterialUtil';
import UiMotion, { runJellyClick } from '../../common/utils/UiMotion';
import { Haptics } from '../../common/utils/Haptics';
import FontConstants from '../../common/constants/FontConstants';
import { ThemeColor } from '../../common/constants/Theme';
import { ThemeItem } from '../../common/model/Theme';
import { NightMode } from '../../common/utils/NightMode';
import { GonggaoItem, GONGGAO_DIALOG_TITLE, GONGGAO_ITEMS, GONGGAO_OK_TEXT } from './GonggaoData';

/** 指示点：未选中（亮/暗两档） */
const DOT_IDLE_LIGHT: string = 'rgba(0, 0, 0, 0.15)';
const DOT_IDLE_DARK: string = 'rgba(255, 255, 255, 0.25)';
/** 未选中点尺寸 / 选中点（胶囊）宽度 */
const DOT_SIZE: number = 6;
const DOT_ACTIVE_W: number = 16;
/** 指示点切换动画时长（只改宽度，不动布局 ⇒ 走图形变换，不触发重排） */
const DOT_ANIM_MS: number = 180;

@CustomDialog
export default struct GonggaoPage {
  controller?: CustomDialogController

  /**
   * 应用主色（创建者传 `this.theme`）。
   * 用途：底部按钮底色 + 选中指示点 —— 同一个主色，避免"弹窗里两种强调色"。
   * 取不到时回落主题 1 的主色（`ThemeColor.ORANGE.mainColor`，`constants/Theme.ets:9`）。
   */
  @Prop theme: ThemeItem = {} as ThemeItem

  /** 用户点了「我知道了」：只做回调请求关闭（见文件头 ⚠️），真正的 close 在创建者 */
  onConfirm: () => void = (): void => {}

  /** 当前页下标（驱动底部指示点） */
  @State page: number = 0
  /** 确认键 Q 弹缩放（规范 §1.2 三件套：独立状态，不用数组下标驱动动画） */
  @State okScale: number = 1

  /**
   * 内容层背板修饰器。第二参数 `true` 的语义（`ImmersiveMaterialUtil.ets:720-725`）：
   * **调用方 options 里确实给了 `systemMaterial`** ⇒ 内容层不画背景，让弹窗层的材质透出来；
   * 夜间档它自己会盖一层不透明深底（`:753-756`），不会出现"浅底白字"；
   * 材质不可用（API<26 / 关掉沉浸光感）时回落这个 fallback 实底，绝不会透明露底。
   */
  private surface: MaterialColumnModifier =
    new MaterialColumnModifier(NightMode.isDarkSurface() ? '#2C2C2E' : Color.White, true)

  /** 是否夜间档（与全工程浮层同一判据，见 `FirstRunModeDialog.ets:107-108`） */
  private dark(): boolean {
    return NightMode.isDarkSurface();
  }

  /** 主色（主题为空时回落主题 1） */
  private accent(): string {
    const main: string = this.theme.mainColor;
    return (typeof main === 'string' && main.length > 0) ? main : ThemeColor.ORANGE.mainColor;
  }

  /**
   * 一页公告：小标题 / 灰色小字 / 正文 / 配图，整体在 `Scroll` 里上下滚动。
   * 字号一律取 `FontConstants` 的语义阶梯（规范 §6）：
   * 小标题 = ITEM(14) + 字重强调；正文 = ITEM(14)/行高 22；日期 = CAPTION(12)。
   */
  @Builder
  pageView(item: GonggaoItem) {
    Scroll() {
      Column() {
        if (item.title !== '') {
          Text(item.title)
            .fontSize(FontConstants.ITEM)
            .fontWeight(FontConstants.W_TITLE)
            .fontColor(this.dark() ? '#F8F9FA' : '#000000')
            .width('100%')
            .textAlign(TextAlign.Start)
        }

        if (item.date !== '') {
          Text(item.date)
            .fontSize(FontConstants.CAPTION)
            .fontWeight(FontConstants.W_BODY)
            .fontColor(this.dark() ? 'rgba(248, 249, 250, 0.6)' : 'rgba(0, 0, 0, 0.45)')
            .width('100%')
            .textAlign(TextAlign.Start)
            .margin({ top: 4 })
        }

        if (item.body !== '') {
          Text(item.body)
            .fontSize(FontConstants.ITEM)
            .fontWeight(FontConstants.W_BODY)
            // 0.85/0.9 而非纯黑纯白：长文整段纯黑在弹窗里偏硬，看一眼会累
            .fontColor(this.dark() ? 'rgba(248, 249, 250, 0.9)' : 'rgba(0, 0, 0, 0.85)')
            .lineHeight(22)
            .width('100%')
            .textAlign(TextAlign.Start)
            .margin({ top: 12 })
        }

        // 配图：宽度撑满内容区、高度按原图比例；多张纵向排列
        ForEach(item.images, (img: ResourceStr) => {
          Image(img)
            .width('100%')
            .borderRadius(12)
            .objectFit(ImageFit.Contain)
            .margin({ top: 12 })
        }, (_img: ResourceStr, idx: number) => `${idx}`)
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .padding({ bottom: 16 })
    }
    .width('100%')
    .height('100%')
    // 文字是主要阅读对象：滚到底给一点回弹，长文不至于"硬停"
    .edgeEffect(EdgeEffect.Spring)
  }

  /**
   * 底部指示点（只在多于 1 页时显示）。
   * 为什么自绘而不用 Swiper 自带指示器：这里有品牌主色 + "当前页拉长成胶囊"的样式需求，
   * 自绘一行 `Row` 足够，且不用引入 `DotIndicator`/`LengthMetrics` 一套 API。
   */
  @Builder
  dots() {
    Row({ space: 6 }) {
      ForEach(GONGGAO_ITEMS, (_dot: GonggaoItem, idx: number) => {
        Row()
          .width(this.page === idx ? DOT_ACTIVE_W : DOT_SIZE)
          .height(DOT_SIZE)
          .borderRadius(DOT_SIZE / 2)
          .backgroundColor(this.page === idx
            ? this.accent()
            : (this.dark() ? DOT_IDLE_DARK : DOT_IDLE_LIGHT))
          .animation({ duration: DOT_ANIM_MS, curve: Curve.EaseOut })
      }, (dotKey: GonggaoItem, idx: number) => `${idx}_${dotKey.title}`)
    }
    .width('100%')
    .height(DOT_SIZE)
    .justifyContent(FlexAlign.Center)
    .margin({ top: 12 })
  }

  build() {
    Column() {
      // ── 标题 ────────────────────────────────────────────────────────────────
      Text(GONGGAO_DIALOG_TITLE)
        .fontSize(FontConstants.TITLE)
        .fontWeight(FontConstants.W_TITLE)
        .fontColor(this.dark() ? '#F8F9FA' : '#000000')
        .width('100%')
        .textAlign(TextAlign.Center)

      // ── 内容：左右滑动切换（每页自己上下滚动）──────────────────────────────
      // 高度靠 `layoutWeight(1)` 吃掉"弹窗固定高 − 标题 − 指示点 − 按钮"的剩余空间；
      // 这也是规范 §2.4 要求 options 给固定高、包装层根节点 `.height('100%')` 的原因。
      Swiper() {
        ForEach(GONGGAO_ITEMS, (item: GonggaoItem) => {
          this.pageView(item)
        }, (pageKey: GonggaoItem, idx: number) => `${idx}_${pageKey.title}`)
      }
      .width('100%')
      .layoutWeight(1)
      // 只有一页时禁止循环滑动（否则单页也能"划出空白"）
      .loop(GONGGAO_ITEMS.length > 1)
      // 关掉自带指示器：底部那排点是自绘的（见 dots()）
      .indicator(false)
      .margin({ top: 12 })
      .onChange((index: number) => {
        this.page = index
      })

      // ── 指示点（单页时不显示）──────────────────────────────────────────────
      if (GONGGAO_ITEMS.length > 1) {
        this.dots()
      }

      // ── 确认（唯一关闭动作）────────────────────────────────────────────────
      Text(GONGGAO_OK_TEXT)
        .fontSize(FontConstants.TITLE)
        .fontWeight(FontConstants.W_TITLE)
        .fontColor(Color.White)
        .textAlign(TextAlign.Center)
        .width('100%')
        .height(46)
        .borderRadius(23)
        .backgroundColor(this.accent())
        .margin({ top: 16 })
        .scale({ x: this.okScale, y: this.okScale })
        .onClick(() => {
          Haptics.tap();
          runJellyClick((v: number) => {
            this.okScale = v;
          });
          // 只请求关闭，不自己 close（见文件头 ⚠️）
          this.onConfirm();
        })
        .clickEffect(UiMotion.CLICK)
    }
    .width('100%')
    .height('100%')
    // 规范 §2.3：内容层**不设** `.backgroundColor()`，让 options 的材质透出来；
    // 实底由 surface 修饰器按"材质是否可用 / 是否夜间"决定。圆角是兜底（材质不可用时也不露直角）。
    .borderRadius(20)
    .attributeModifier(this.surface)
    .padding({ left: 20, right: 20, top: 20, bottom: 20 })
  }
}
