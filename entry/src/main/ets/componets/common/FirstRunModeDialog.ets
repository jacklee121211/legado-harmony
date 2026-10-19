/**
 * 首次安装「全量 / 离线」模式选择弹窗（2026-10-13 新增，用户需求）。
 *
 * ── 需求（用户原文）───────────────────────────────────────────────────────────
 * 「整个屏幕会是呈现灰色的遮罩，屏幕中间有一个四圆角矩形弹窗（材质在我们的 docs 中有
 *   详细规范）居中对齐，上下有两个按钮，上面为全量模式，下面为离线模式，点击后会被
 *   红色边框框选，点击不生效，点击选择后，再次点击确定才生效，弹窗底部写好，
 *   后续可在设置页进行更改模式。默认框选全量模式。」
 *
 * ── 实现口径（全部对齐 `docs/标准-弹窗与按钮统一规范.md`）─────────────────────
 *  · 四圆角 + 沉浸光感材质：材质走 **options 的 `systemMaterial`**（规范 2.2），
 *    内容层用 `MaterialColumnModifier(色, true)` **不设任何 backgroundColor**（规范 2.3）。
 *  · 灰色遮罩：`maskColor`（SDK 默认 `0x33000000`）。本弹窗是**强制选择**语义，
 *    故 `autoCancel: false`（点遮罩不关）—— 用户必须做出选择才能进入主界面。
 *  · 上下两个按钮 = 单选（点一下只是**选中**，红框框选），
 *    **不立即生效** —— 必须再点「确定」才落盘（用户原话"点击不生效…再次点击确定才生效"）。
 *  · 默认框选「全量模式」。
 *  · 底部说明：后续可在设置页更改。
 *
 * ── ⚠️ 为什么这里是 `@CustomDialog` 而不是普通 `@Component` ────────────────────
 * 规范 2.1 铁律：普通 `@Component` 直接写进 `builder:` 字段初始化器会**真机闪退**
 *   （`TypeError: class constructor cannot called without 'new'`，2026-10-01 真机日志）。
 *
 * ── ⚠️ 为什么选择结果通过回调交出去，而不是在弹窗里直接调 OfflineMode.set ─────────
 * 规范 4.4 铁律：弹窗组件**禁用 `@Consume`**（close→open 复用重建时会 `Fail to resolve
 *   @Consume`，真机 BusinessError 140112 闪退）。本弹窗全部数据走 `@Prop` + 回调。
 */
import { MaterialColumnModifier } from '../../common/utils/ImmersiveMaterialUtil'
import UiMotion, { runJellyClick } from '../../common/utils/UiMotion'
import { Haptics } from '../../common/utils/Haptics'
import FontConstants from '../../common/constants/FontConstants'
import { NightMode } from '../../common/utils/NightMode'

/**
 * 模式选项（首次引导只有两项，顺序即**上下**排列顺序：全量在上、精简在下）。
 *
 * 布局（2026-10-13 用户定稿）：每个选项**两行** ——
 *   第一行 = 「模式名 · 短标签」（如 `全量模式 · 全量功能`），加粗、带分隔点；
 *   第二行 = 详细说明。
 * ⚠️ `OPTION_LABEL_*` 只含**模式名**（不含短标签）—— 它同时被用作
 *    「确定」后回调语义、以及无障碍朗读的锚点，短标签属于展示层，不要并进常量。
 */
const OPTION_LABEL_FULL: string = '全量模式';
const OPTION_LABEL_OFFLINE: string = '精简模式';
/** 第一行短标签（与模式名用 ` · ` 连接，用户定稿） */
const OPTION_TAG_FULL: string = '全量功能';
const OPTION_TAG_OFFLINE: string = '简单极致';
/** 第二行详细说明（2026-10-13 用户定稿，勿改字） */
const OPTION_DESC_FULL: string = '部分个性化依赖网络链接的超精致阅读体验';
const OPTION_DESC_OFFLINE: string = '缺少部分个性化却保证极致阅读的极简主义';
/** 底部说明：先写"后续可在设置页更改"，再补一行"无广告"（用户要求分两行） */
// ⚠️ 2026-10-19：设置页原来的「其他」分组已改名为「功能」（用户要求），这里跟着改，
//    否则首启引导会指路到一个不存在的分组名。
const FOOTER_HINT_SETTINGS: string = '后续可在「我的 → 设置 → 功能」中更改模式';
const FOOTER_HINT_NO_AD: string = '双模式下均不存在广告以及其他扰人因素';
/** 第一行的模式名与短标签之间的分隔符（前后各一个空格，用户定稿写法） */
const LABEL_TAG_SEP: string = ' · ';

/**
 * 本弹窗的**强调红**（选中红框 + 底部无广告承诺文字共用同一值）。
 *
 * 为什么抽成常量而不是各写各的：这两处是同一个弹窗里仅有的两个红色元素，
 * 一旦各写一份，以后调色必然漏改一处 ⇒ 出现"两种红"。
 *
 * 取值口径：**不**用主题红 `ThemeColor.RED.mainColor = '#ef4444'`
 * —— 那是"主题色"（用户可在主题页换掉整套配色），而本弹窗是首启引导、
 * 此时用户还没进过主题页，用固定强调红更可控（用户原话"红色着重表示"）。
 * 夜间档用更亮的一档，保证 12 号小字在深底上可读。
 */
const ACCENT_RED: string = '#E84026';
/** 夜间档的强调红（提亮，保证深底可读） */
const ACCENT_RED_DARK: string = '#FF6B6B';

@CustomDialog
export default struct FirstRunModeDialog {
  controller?: CustomDialogController

  /**
   * 用户点「确定」后的回调：把**选中的模式**（true = 离线）交给创建者落盘。
   * 为什么由创建者落盘：`OfflineMode.set()` 同时写 Preferences + AppStorage 广播，
   * 是全工程唯一入口（见 `MySetPage.ets:737`），弹窗不该越过它自己写存储。
   */
  confirm: (offline: boolean) => void = () => {}

  /**
   * 初始选中值（创建者传入，通常恒为 false = 全量模式 —— 用户要求"默认框选全量模式"）。
   * ⚠️ `@Prop` 是创建瞬间快照。本弹窗不需要动态更新（SDK NOTE：
   *    `custom_dialog_controller.d.ts:756` 原文「Custom dialog box parameters
   *    **do not support dynamic updates**」）⇒ 每次打开都 new 一个新 controller。
   */
  @Prop initialOffline: boolean = false

  /** 当前选中值（点选项只改它；点确定才交出去） */
  @State selectedOffline: boolean = false
  /** 两个选项各自的 Q 弹缩放（规范 1.2 三件套：独立状态，不用数组下标驱动） */
  @State fullScale: number = 1
  @State offlineScale: number = 1
  /** 确定键的 Q 弹缩放 */
  @State okScale: number = 1

  /**
   * 内容层背板修饰器。
   * 第二参数 `true` 的语义（`ImmersiveMaterialUtil.ets:439-443,476`）：
   * **调用方 options 里确实给了 `systemMaterial`** ⇒ 内容层不画背景，由弹窗层负责；
   * 夜间档它自己会盖一层不透明深底（`:501-504`），不会出现"浅底白字"。
   */
  private surface: MaterialColumnModifier =
    new MaterialColumnModifier(NightMode.isDarkSurface() ? '#2C2C2E' : Color.White, true)

  aboutToAppear(): void {
    // 默认框选全量模式（用户明确要求）；若创建者指定了初始值则以其为准。
    this.selectedOffline = this.initialOffline
  }

  /**
   * 单个模式选项（上下排列的大按钮）。
   *
   * 布局（用户定稿）：**两行** ——
   *   ① `全量模式 · 全量功能`（模式名 + 短标签，同一行、加粗）
   *   ② 详细说明（12 号，会折行）
   *
   * 选中态：**红色边框**框选（用户原话"点击后会被红色边框框选"）。
   * ⚠️ 未选中态也保留**同样宽度的透明边框** —— 否则选中时会因为边框占位
   *    导致文字整体位移 1-2px（视觉上"抖一下"）。
   */
  @Builder
  modeOption(offline: boolean, label: string, tag: string, desc: string, scale: number) {
    Column() {
      // ── 第一行：模式名 · 短标签 ────────────────────────────────────────────
      // 为什么拼成一个 Text 而不是 Row 里放两个 Text：
      //   两段文字要作为一个整体**居中**，用 Row 还得自己算宽度；
      //   拼接后交给 Text 的 textAlign 更稳，也天然支持"窄屏时整行折行"。
      Text(label + LABEL_TAG_SEP + tag)
        .fontSize(FontConstants.ITEM)
        .fontWeight(FontConstants.W_TITLE)
        .fontColor(NightMode.isDarkSurface() ? '#F8F9FA' : '#000000')
        .width('100%')
        .textAlign(TextAlign.Center)
      // ── 第二行：详细说明 ──────────────────────────────────────────────────
      Text(desc)
        .fontSize(FontConstants.CAPTION)
        .fontWeight(FontConstants.W_BODY)
        .fontColor(NightMode.isDarkSurface() ? 'rgba(248, 249, 250, 0.65)' : 'rgba(0, 0, 0, 0.45)')
        .margin({ top: 4 })
        // ⚠️ 文案较长会折行 ⇒ 必须给 Text 满宽，`textAlign(Center)` 才对**每一行**生效；
        //    否则 Text 按内容自适应宽度，居中的只是块本身、折行仍左对齐。
        .width('100%')
        .textAlign(TextAlign.Center)
        // 行高放宽：两行说明在 12 号字下贴太紧会糊成一团
        .lineHeight(18)
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 14, bottom: 14 })
    .borderRadius(14)
    .borderWidth(2)
    // 选中 = 红框；未选中 = 同宽透明框（占位，避免选中时文字位移）
    .borderColor(this.selectedOffline === offline ? ACCENT_RED : Color.Transparent)
    .backgroundColor(NightMode.isDarkSurface() ? 'rgba(255, 255, 255, 0.06)' : 'rgba(0, 0, 0, 0.03)')
    .scale({ x: scale, y: scale })
    .onClick(() => {
      Haptics.tap()
      runJellyClick((v: number) => {
        if (offline) {
          this.offlineScale = v
        } else {
          this.fullScale = v
        }
      })
      // ⚠️ 只改选中值，**不**落盘、**不**关弹窗 —— 用户原话"点击不生效，
      //    点击选择后，再次点击确定才生效"。
      this.selectedOffline = offline
    })
    .clickEffect(UiMotion.CLICK)
  }

  build() {
    Column() {
      // ── 标题 ──────────────────────────────────────────────────────────────
      Text('选择使用模式')
        .fontSize(FontConstants.TITLE)
        .fontWeight(FontConstants.W_TITLE)
        .fontColor(NightMode.isDarkSurface() ? '#F8F9FA' : '#000000')
        .margin({ bottom: 6 })

      // ── 选项（上下两个：全量在上，离线在下）──────────────────────────────
      Column({ space: 12 }) {
        this.modeOption(false, OPTION_LABEL_FULL, OPTION_TAG_FULL, OPTION_DESC_FULL, this.fullScale)
        this.modeOption(true, OPTION_LABEL_OFFLINE, OPTION_TAG_OFFLINE, OPTION_DESC_OFFLINE, this.offlineScale)
      }
      .width('100%')
      .margin({ top: 16 })

      // ── 确定（唯一生效入口）──────────────────────────────────────────────
      Text('确定')
        .fontSize(FontConstants.ITEM)
        .fontWeight(FontConstants.W_TITLE)
        .fontColor(Color.White)
        .textAlign(TextAlign.Center)
        .width('100%')
        .padding({ top: 12, bottom: 12 })
        .borderRadius(14)
        // 与选中红框 / 底部承诺文字**同一支红**（ACCENT_RED）⇒ 整弹窗红色只有一个来源
        .backgroundColor(ACCENT_RED)
        .margin({ top: 24 })
        .scale({ x: this.okScale, y: this.okScale })
        .onClick(() => {
          Haptics.tap()
          runJellyClick((v: number) => { this.okScale = v })
          // 生效：先关自己，再把选择交出去（职责划分同规范 4.1）
          this.controller?.close()
          this.confirm(this.selectedOffline)
        })
        .clickEffect(UiMotion.CLICK)

      // ── 底部说明（用户要求："弹窗底部写好，后续可在设置页进行更改模式"）──────
      // ⚠️ 2026-10-13 拆两行：第一行=设置页入口指引；第二行=无广告承诺。
      //    两行同为说明级（FontConstants.CAPTION），用 margin 而非字号区分，
      //    避免破坏字号阶梯（规范 6.1 硬规则）。
      Text(FOOTER_HINT_SETTINGS)
        .fontSize(FontConstants.CAPTION)
        .fontWeight(FontConstants.W_BODY)
        .fontColor(NightMode.isDarkSurface() ? 'rgba(248, 249, 250, 0.6)' : 'rgba(0, 0, 0, 0.4)')
        .textAlign(TextAlign.Center)
        .margin({ top: 14 })
      Text(FOOTER_HINT_NO_AD)
        .fontSize(FontConstants.CAPTION)
        // 2026-10-13 用户要求：本行**红色着重表示**（是承诺，不是细则）。
        // 强调用**字重**而非字号 —— 与上一行同为 CAPTION(12)，不破坏字号阶梯
        // （规范 6.1 硬规则：同一容器内不允许出现两个"条目"级字号）。
        .fontWeight(FontConstants.W_TITLE)
        // 与选中红框**共用** ACCENT_RED ⇒ 同一弹窗不会出现两种红
        .fontColor(NightMode.isDarkSurface() ? ACCENT_RED_DARK : ACCENT_RED)
        .textAlign(TextAlign.Center)
        .width('100%')
        .margin({ top: 6 })
    }
    .width('100%')
    // ⚠️ 规范 2.3：内容层绝不设 .backgroundColor()，让 options 的材质透出来。
    //    这里的实底由 surface 修饰器按"材质是否可用 / 是否夜间"决定。
    .borderRadius(20)
    .attributeModifier(this.surface)
    .padding({ left: 20, right: 20, top: 24, bottom: 20 })
  }
}
