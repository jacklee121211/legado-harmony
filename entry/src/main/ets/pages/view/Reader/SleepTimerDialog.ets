import { MaterialColumnModifier } from '../../../common/utils/ImmersiveMaterialUtil'
// ── 全局震动反馈（2026-09-25 新增）────────────────────────────────────────────
import { Haptics } from '../../../common/utils/Haptics'

/**
 * 睡眠定时弹窗（2026-09-22 按用户设计新建）。
 *
 * ── 用户需求原文 ──────────────────────────────────────────────────────────
 * 「单独做个 symbol 式中图标，放在**书签左面**，点击之后是**双滚轮选择**
 *  （鸿蒙有这种 api），左面是按照**章节，1-99** 进行选择，右面是按照时间，
 *   可以调节**时和分**，然后真的可以实现功能，**到点暂停**。
 *   大概就是点击这个图标，出现一个**光感弹窗**，顶部有两个滑块，分别是章节和时间，
 *   章节对应的是一个数字选择器，点击时间出现时间选择器，底部是**取消、重置和确定**」
 *
 * ── 关键取证 ──────────────────────────────────────────────────────────────
 * · `TextPicker`（`text_picker.d.ts`）：`range: string[]`（:120）、
 *   `selected?: number`（:167）、`onChange`（:737）⇒ 做 1-99 章节滚轮。
 * · `TimePicker`（`time_picker.d.ts`）：`TimePickerOptions{selected?: Date, format?}`
 *   （:124/:139/:152），`TimePickerFormat.HOUR_MINUTE`（:79，`@since 11`）
 *   ⇒ 做"时:分"滚轮。
 * · **材质**：走 `CustomDialogControllerOptions.systemMaterial`
 *   （`custom_dialog_controller.d.ts:681`，@since 26.0.0）+ `customStyle:false`，
 *   与长按书籍弹窗/加入书单弹窗同款 ⇒ 悬空四圆角 + 半透明沉浸光感。
 *   （⚠️ 这是**小弹窗**，不受 sheet 的 `detents` 限制，所以能上真材质；
 *     听书那个大面板做不到，见其注释。）
 *
 * ── 到点暂停 ──────────────────────────────────────────────────────────────
 * 底层能力**早已存在且未被改动**：`TtsEngine.setSleepTimer(chapters, minutes)`、
 * `getSleepChaptersReq()`、`getSleepMinutesReq()`、`getSleepStopMs()`。
 * 本弹窗只负责采集用户选择并把它们交给调用方（`ReaderPage3`）去写引擎。
 */
@CustomDialog
export struct SleepTimerDialog {
  controller?: CustomDialogController

  /** 当前已设：章节数（0 = 不按章节） */
  @Prop initChapters: number = 0
  /** 当前已设：分钟数（0 = 不按时长） */
  @Prop initMinutes: number = 0
  /** 剩余量文案（由调用方从 `TtsEngine.getSleepStopMs()` 派生；空 = 未设定时） */
  @Prop statusText: string = ''

  /**
   * 日/夜模式（**0 = 夜间**，1 = 日间）—— 与父页面 `ReaderPage3.colorMode` 同义。
   *
   * ⚠️ 这里**故意用 `@StorageLink` 而不是 `@Prop`**：
   *   `ReaderPage3` 是"每次打开新建 controller"以外的写法（睡眠定时弹窗的 controller
   *   建在 `openSleepTimerDialog()` 里，每次新建）⇒ 用 `@Prop` 也能取到当前值；
   *   但这个弹窗**自己不持有** colorMode 入参（构造点只传 initChapters/initMinutes/statusText），
   *   加 `@Prop` 要动调用点的 4 个字段传参，而 `@StorageLink` 直接吃父页面已经写进
   *   AppStorage 的同一个 key（`ReaderPage3` 的 `@StorageLink('readerColorMode')`），
   *   零传参、天然同步。`ReaderListenDialog` 已是同款写法。
   *   ⚠️ 亮暗色重构（2026-09-23）：键从 'colorMode'（已还给系统深浅色）改为专用键
   *   'readerColorMode' —— 跟随阅读器的日/夜间，而不是系统。
   */
  @StorageLink('readerColorMode') colorMode: number = 1

  /** 确定：把选择结果交回调用方去写 `TtsEngine` */
  onConfirm: (chapters: number, minutes: number) => void = (_c: number, _m: number): void => {}
  /** 取消 / 关闭 */
  onCancel: () => void = (): void => {}
  /** 重置（清空定时） */
  onReset: () => void = (): void => {}

  /** 章节滚轮：1~99（下标 0 对应"关"，即不按章节） */
  private chapterOptions: string[] = [];
  /** 选中的章节数；0 = 关 */
  @State selChapters: number = 0
  /** 选中的时长（分钟）；0 = 关 */
  @State selMinutes: number = 0
  /** 当前展示哪个选择器：0 = 章节，1 = 时间（按用户"顶部两个滑块"的设计做成可切换） */
  @State activePane: number = 0

  /**
   * 材质背板（调用方已通过 options 提供材质 ⇒ 传 true 让出背景）。
   * 兜底色按日夜模式给：材质不可用（`ImmersiveMaterialUtil.ENABLED = false` /
   * 设备不支持）时才会落到它，夜里必须是深底，否则白色兜底 + 白色文字。
   */
  private surface: MaterialColumnModifier = new MaterialColumnModifier(Color.White, true)

  /**
   * 次级按钮（取消 / 重置）的底色 —— 夜间要反过来用"淡白"。
   *
   * 原先写死 `'rgba(0, 0, 0, 0.06)'` 底 + `'rgba(0, 0, 0, 0.88)'` 字。
   * 本弹窗的背景由**沉浸光感材质**提供（`systemMaterial`，见文件头），
   * 而材质底色跟随**应用配色**（夜间 = 深底）⇒ 写死的黑字黑底会直接看不见。
   * 证据与整体方案见 `ReaderPage3.syncAbilityColorMode()` 的注释。
   */
  private subBtnBg(): string {
    return this.colorMode == 0 ? 'rgba(255, 255, 255, 0.14)' : 'rgba(0, 0, 0, 0.06)';
  }

  /** 次级按钮（取消 / 重置）的文字色 —— 与 `subBtnBg()` 同理，夜间转白 */
  private subBtnFg(): string {
    return this.colorMode == 0 ? 'rgba(255, 255, 255, 0.88)' : 'rgba(0, 0, 0, 0.88)';
  }

  /** 未选中页签的灰 —— 夜间提亮一档，避免深底上过暗 */
  private idleGray(): string {
    return this.colorMode == 0 ? 'rgba(160, 160, 160, 1.00)' : 'rgba(136, 136, 136, 1.00)';
  }

  aboutToAppear(): void {
    // 构造 1~99 的滚轮数据（"关" 放在首位，便于取消定时）
    const arr: string[] = ['关'];
    for (let i = 1; i <= 99; i++) {
      arr.push(String(i));
    }
    this.chapterOptions = arr;
    this.selChapters = this.initChapters;
    this.selMinutes = this.initMinutes;
    // 材质不可用时的兜底色（夜里给深底，否则白底 + 白字）
    this.surface = new MaterialColumnModifier(
      this.colorMode == 0 ? '#1F1F1F' : Color.White, true);
  }

  /** 选中项在 `chapterOptions` 中的下标（0 = 关） */
  private chapterIndex(): number {
    return this.selChapters <= 0 ? 0 : this.selChapters;
  }

  /** 把分钟数转成 TimePicker 需要的 Date */
  private minutesToDate(): Date {
    const d = new Date();
    const m = this.selMinutes > 0 ? this.selMinutes : 0;
    d.setHours(Math.floor(m / 60), m % 60, 0, 0);
    return d;
  }

  /** 把目标时刻（时:分）换算成"距离现在还有多少分钟" —— **闹钟式语义** */
  private computeRemainingMinutes(hour: number, minute: number): number {
    const now = new Date();
    const target = new Date();
    target.setHours(hour, minute, 0, 0);
    // 防击穿：目标时刻已过（或刚好现在）⇒ 视为**明天**的同一时刻
    let diff = target.getTime() - now.getTime();
    if (diff <= 0) {
      diff += 24 * 60 * 60 * 1000;
    }
    // 兜底：任何异常都返回 0（调用方会把 0 当成"关"），绝不产生负数
    const mins = Math.round(diff / 60000);
    return mins > 0 ? mins : 0;
  }

  /** 从 Date 取"时"与"分"（越界时钳制到合法范围，防击穿） */
  private safeHour(value: TimePickerResult): number {
    const h = value.hour ?? 0;
    return h >= 0 && h <= 23 ? h : 0;
  }

  private safeMinute(value: TimePickerResult): number {
    const m = value.minute ?? 0;
    return m >= 0 && m <= 59 ? m : 0;
  }

  /** 右上角提示：时间模式显示"剩余 N 分钟"（闹钟式），章节模式显示章数 */
  private headerHint(): string {
    if (this.activePane === 1) {
      return this.selMinutes > 0 ? `剩余 ${this.selMinutes} 分钟` : '未设定时';
    }
    return this.selChapters > 0 ? `再读 ${this.selChapters} 章` : '未设定时';
  }

  build() {
    Column() {
      // ── 标题 + 右上角「剩余分钟」（闹钟式语义）────────────────────────
      // 用户要求：「**右上角显示 300 分钟**」（即目标时刻与现在的差值）。
      Row() {
        Text('睡眠定时').fontSize(16).fontWeight(600)
        Blank()
        Text(this.headerHint())
          .fontSize(12)
          .fontColor(this.selMinutes > 0 || this.selChapters > 0
            ? 'rgba(0, 125, 255, 1.00)' : this.idleGray())
      }
      .width('100%')
      .padding({ bottom: 12 })

      // ── 顶部两选一：章节 / 时间（2026-09-22 用户要求**不能并行**）────────
      // 用户原话：「睡眠定时章节和时间**不能并行，只能二选一**；
      //   选择时间的 api 有点诡异，明明是目标时间的，被你搞成了奇怪的定时，
      //   你可以直接像**闹钟**一样，设定目标时间，比如现在凌晨四点，设定上午9点，
      //   就是五个小时，**右上角显示 300 分钟**，不就完了，
      //   做好**防击穿逻辑**，避免出现负时间」。
      // ⇒ `activePane` 即"当前生效的模式"（0=章节 / 1=时间），**同时只有一个生效**；
      //   确认时把另一个置 0，保证二选一。
      Row({ space: 12 }) {
        Text(this.activePane === 0 ? `章节 ${this.selChapters > 0 ? this.selChapters : '关'}` : '章节')
          .fontSize(14)
          .fontWeight(this.activePane === 0 ? 600 : 400)
          .fontColor(this.activePane === 0 ? 'rgba(0, 125, 255, 1.00)' : this.idleGray())
          .layoutWeight(1)
          .textAlign(TextAlign.Center)
          .padding({ top: 8, bottom: 8 })
          .onClick(() => {
            Haptics.tap();
            this.activePane = 0
            this.selMinutes = 0
          })
        Text('时间')
          .fontSize(14)
          .fontWeight(this.activePane === 1 ? 600 : 400)
          .fontColor(this.activePane === 1 ? 'rgba(0, 125, 255, 1.00)' : this.idleGray())
          .layoutWeight(1)
          .textAlign(TextAlign.Center)
          .padding({ top: 8, bottom: 8 })
          .onClick(() => {
            Haptics.tap();
            this.activePane = 1
            this.selChapters = 0
          })
      }
      .width('100%')
      .padding({ bottom: 8 })

      // ── 选择器区（只显示当前模式对应的那个）──────────────────────────
      if (this.activePane === 0) {
        // 章节：1~99 数字滚轮
        TextPicker({ range: this.chapterOptions, selected: this.chapterIndex() })
          .width('100%')
          .height(180)
          .onChange((_value: string | string[], index: number | number[]) => {
            const idx = typeof index === 'number' ? index : index[0];
            this.selChapters = idx <= 0 ? 0 : idx;
            Haptics.tick();
          })
      } else {
        // 时间：**闹钟式** —— 选目标时刻（时:分），剩余分钟由差值算出并显示在右上角
        TimePicker({
          selected: this.minutesToDate(),
          format: TimePickerFormat.HOUR_MINUTE
        })
          .width('100%')
          .height(180)
          // ★ 强制 24 小时制（2026-09-22 用户反馈修复）。
          //   用户原话：「你这个带上**下午**，我需要的那种**只有时和分**」。
          //   SDK 原文（`time_picker.d.ts:254` 的 `useMilitaryTime`）：
          //     「Sets whether the time is displayed in 24-hour format.
          //       **If this attribute is not specified, the system time format is used**
          //       by default. - true: 24-hour format」
          //   ⇒ 之前没设 ⇒ 跟随系统；用户手机是 12 小时制 ⇒ 出现"上午/下午"。
          //   显式设为 true 即只显示"时:分"。
          .useMilitaryTime(true)
          .onChange((value: TimePickerResult) => {
            this.selMinutes = this.computeRemainingMinutes(
              this.safeHour(value), this.safeMinute(value));
            Haptics.tick();
          })
      }

      // ── 底部：取消 / 重置 / 确定 ─────────────────────────────────────
      Row({ space: 12 }) {
        Button('取消')
          .layoutWeight(1)
          .backgroundColor(this.subBtnBg())
          .fontColor(this.subBtnFg())
          .onClick(() => {
            Haptics.tap();
            this.onCancel()
            this.controller?.close()
          })
        Button('重置')
          .layoutWeight(1)
          .backgroundColor(this.subBtnBg())
          .fontColor(this.subBtnFg())
          .onClick(() => {
            Haptics.tap();
            this.selChapters = 0
            this.selMinutes = 0
            this.onReset()
            this.controller?.close()
          })
        Button('确定')
          .layoutWeight(1)
          .backgroundColor('rgba(0, 125, 255, 1.00)')
          .fontColor(Color.White)
          .onClick(() => {
            // **二选一**（用户明确要求章节与时间不能并行）：
            // 按当前 `activePane` 只提交一个，另一个强制置 0。
            // 另外 `selMinutes` 已在 `computeRemainingMinutes` 里做过防负值，
            // 这里再兜一次（>0 才算，否则当"关"）。
            Haptics.tap();
            if (this.activePane === 0) {
              this.onConfirm(this.selChapters > 0 ? this.selChapters : 0, 0)
            } else {
              this.onConfirm(0, this.selMinutes > 0 ? this.selMinutes : 0)
            }
            this.controller?.close()
          })
      }
      .width('100%')
      .padding({ top: 12 })
    }
    .width('100%')
    .padding(20)
    .borderRadius(20)
    .attributeModifier(this.surface)
  }
}
