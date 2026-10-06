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
 *   MCP hover 原文（本工程实测，2026-10-06 复核）：
 *     「(property) TextPickerOptions.selected?: number | number[] | undefined
 *       Index of the selected item in the data list. The index is zero-based.
 *       Default value: 0 … 3. Since API version 10, this parameter supports
 *       two-way binding through $」
 *   ⇒ 时/分两只滚轮同样用 `TextPicker`（**不是** `TimePicker`）。
 *   ⚠️ `TimePicker`（时钟选择器）已于 2026-10-06 **整体弃用**：它是"选目标时刻"的
 *      墙上时钟 API，与"再听多久"的计时语义不匹配（用户原话见下）。
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
  /** 当前展示哪个选择器：0 = 章节，1 = 时间（按用户"顶部两个滑块"的设计做成可切换） */
  @State activePane: number = 0

  // ── 时间 = **计时器**（2026-10-06 用户改版，方案 B）────────────────────────
  // 用户原话："明显时间这个 api 是个时钟 api，我们需要的其实是个**计时 api**"。
  // 旧实现用 `TimePicker`（时钟选择器）选**目标时刻**（闹钟式），再拿"目标 − 现在"
  // 换算成分钟——对不想对钟点的用户完全反直觉 ⇒ 整个弃用。
  // 新语义：**纯倒数时长**——"时 + 分"两只滚轮，拨多少就是"再听多久"，
  // 右上角提示 = 时×60+分，**由滚轮实时推导**（单一数据源，绝无错位）。
  // 引擎侧 `TtsEngine.setSleepTimer(0, minutes)` 本就是时长语义，零改动。
  /** 时滚轮：0~23 */
  private hourOptions: string[] = [];
  /** 分滚轮：0~59 */
  private minuteOptions: string[] = [];
  /** 选中的"时"（0-23） */
  @State selHours: number = 0
  /** 选中的"分"（0-59） */
  @State selMinutesPart: number = 0

  /** 当前选中的总时长（分钟）= 时×60+分。**右上角提示与确定键的唯一数据源**。 */
  private totalMinutes(): number {
    return this.selHours * 60 + this.selMinutesPart;
  }

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
    // 计时滚轮数据：时 0~23、分 0~59
    const hs: string[] = [];
    const ms: string[] = [];
    for (let i = 0; i <= 23; i++) {
      hs.push(String(i));
    }
    for (let i = 0; i <= 59; i++) {
      ms.push(String(i));
    }
    this.hourOptions = hs;
    this.minuteOptions = ms;
    this.selChapters = this.initChapters;
    // 已设定时 ⇒ 把当初选的总分钟数**拆回"时/分"两轮**（例：300 ⇒ 时 5 分 0）；
    // 未设 ⇒ 0 时 0 分（提示"未设定时"）。
    // 钳制在滚轮量程内（0 时 0 分 ~ 23 时 59 分 = 1439 分钟）：`selected` 下标越界时
    // TextPicker 的行为未见官方声明（未取证），因此不让它有机会拿到越界值。
    const initMin = this.initMinutes > 0 ? Math.min(this.initMinutes, 23 * 60 + 59) : 0;
    this.selHours = Math.floor(initMin / 60);
    this.selMinutesPart = initMin % 60;
    // 材质不可用时的兜底色（夜里给深底，否则白底 + 白字）
    this.surface = new MaterialColumnModifier(
      this.colorMode == 0 ? '#1F1F1F' : Color.White, true);
  }

  /** 选中项在 `chapterOptions` 中的下标（0 = 关） */
  private chapterIndex(): number {
    return this.selChapters <= 0 ? 0 : this.selChapters;
  }

  /**
   * 右上角提示 —— **必须与时间滚轮实时对齐**（2026-10-06 用户要求：
   * 「方案B最好，但是**需要与右上角的时间对齐**」）。
   *
   * 时间模式：文案直接**镜像"时/分"两轮的读数**（拨 1 时 30 分 ⇒ "剩余 1 时 30 分"），
   *   并附总分钟数 —— 后者是用户 2026-09-22 的原话要求（「右上角显示 300 分钟」）。
   *   两个数字都由同一个 `totalMinutes()` 推导 ⇒ 结构上不可能出现"轮盘与提示不一致"。
   * 章节模式：显示章数。
   */
  private headerHint(): string {
    if (this.activePane === 1) {
      const total = this.totalMinutes();
      if (total <= 0) {
        return '未设定时';
      }
      const h = Math.floor(total / 60);
      const m = total % 60;
      if (h <= 0) {
        return `剩余 ${m} 分钟`;
      }
      if (m <= 0) {
        return `剩余 ${h} 时（${total} 分钟）`;
      }
      return `剩余 ${h} 时 ${m} 分（${total} 分钟）`;
    }
    return this.selChapters > 0 ? `再读 ${this.selChapters} 章` : '未设定时';
  }

  /** 右上角提示是否处于"蓝色高亮"（按**当前生效页签**取值，与 `headerHint()` 同源） */
  private headerActive(): boolean {
    return (this.activePane === 1 ? this.totalMinutes() : this.selChapters) > 0;
  }

  build() {
    Column() {
      // ── 标题 + 右上角「剩余时长」（**与时间滚轮同源**）──────────────────
      // 「右上角显示 300 分钟」是 2026-09-22 用户原话；2026-10-06 改版后额外镜像
      // 滚轮的"时/分"读数（例："剩余 1 时 30 分（90 分钟）"），二者同源 `totalMinutes()`。
      Row() {
        Text('睡眠定时').fontSize(16).fontWeight(600)
        Blank()
        Text(this.headerHint())
          .fontSize(12)
          .fontColor(this.headerActive()
            ? 'rgba(0, 125, 255, 1.00)' : this.idleGray())
      }
      .width('100%')
      .padding({ bottom: 12 })

      // ── 顶部两选一：章节 / 时间（2026-09-22 用户要求**不能并行**）────────
      // ⚠️ 历史注记（**下面这段是 2026-09-29 的旧语义，2026-10-06 已废弃**，保留仅为留痕）：
      //   用户当时原话「睡眠定时章节和时间**不能并行，只能二选一**；选择时间的 api 有点诡异，
      //   明明是目标时间的，被你搞成了奇怪的定时，你可以直接像**闹钟**一样，设定目标时间……
      //   **右上角显示 300 分钟**，不就完了，做好**防击穿逻辑**，避免出现负时间」。
      //   ⇒ 那套"目标时刻 − 现在"的闹钟换算（`computeRemainingMinutes`/`pickedTime`）
      //     已按 2026-10-06 用户新要求（「时间这个 api 是时钟 api，我们需要的是**计时 api**」）
      //     整体删除，时间页签现在是**纯倒数时长**（见下方 `totalMinutes()` 与两轮 TextPicker）。
      //   仍然成立的只有"二选一"本身：`activePane` 即"当前生效的模式"（0=章节 / 1=时间），
      //     确认时把另一个置 0（`确定` 按钮按 `activePane` 只提交一个）。
      // ⚠️ 2026-10-06（本次）：**切换页签不再清空另一侧的已选值**（旧写法：切到章节
      //   `selMinutes = 0`、切到时间 `selChapters = 0`）。原因：
      //     · "二选一"是由 `确定` 按 `activePane` 只提交一个来**保证**的，
      //       与另一侧的状态是否为 0 无关（引擎 `TtsEngine.ets:1039-1041`：只认传进去的实参）；
      //     · 旧写法会让"切过去看一眼再切回来"把刚拨好的值抹掉，
      //       与本次要求「右上角跟滚轮对齐」直接冲突（提示要等于滚轮读数，就不能被暗中清零）。
      //   副作用（预期内）：两个轮盘各自记住自己最后一次的读数；重开弹窗时由引擎回读覆盖。
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
            // 只切页签；时间滚轮的值保留（见上方 ⚠️ 说明）
            this.activePane = 0
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
            // 只切页签；章节滚轮的值保留（见上方 ⚠️ 说明）
            this.activePane = 1
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
        // 时间：**计时器**（2026-10-06 方案 B）——"时 + 分"两轮，拨多少 = 再听多久，
        // 右上角提示 = 时×60+分（totalMinutes 单一数据源，实时对齐，绝无钟点换算）。
        // 引擎侧 `TtsEngine.setSleepTimer(0, minutes)` 本就是累计时长语义，零改动。
        Row({ space: 10 }) {
          TextPicker({ range: this.hourOptions, selected: this.selHours })
            .width(84)
            .height(180)
            .onChange((_value: string | string[], index: number | number[]) => {
              const idx = typeof index === 'number' ? index : index[0];
              this.selHours = idx >= 0 && idx <= 23 ? idx : 0;
              Haptics.tick();
            })
          Text('时').fontSize(14).opacity(0.6)
          TextPicker({ range: this.minuteOptions, selected: this.selMinutesPart })
            .width(84)
            .height(180)
            .onChange((_value: string | string[], index: number | number[]) => {
              const idx = typeof index === 'number' ? index : index[0];
              this.selMinutesPart = idx >= 0 && idx <= 59 ? idx : 0;
              Haptics.tick();
            })
          Text('分').fontSize(14).opacity(0.6)
        }
        .width('100%')
        .justifyContent(FlexAlign.Center)
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
            // 时间滚轮清零 = "时 0 / 分 0" ⇒ `totalMinutes()` 归零 ⇒ 右上角回到"未设定时"
            this.selHours = 0
            this.selMinutesPart = 0
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
            // 时长 = `totalMinutes()`（= 时×60+分，与右上角提示**同一个来源**）；
            // 0 即"关"（引擎侧 `TtsEngine.ets:1041` 把 0 当作不设时长），绝不产生负值。
            Haptics.tap();
            if (this.activePane === 0) {
              this.onConfirm(this.selChapters > 0 ? this.selChapters : 0, 0)
            } else {
              const mins = this.totalMinutes();
              this.onConfirm(0, mins > 0 ? mins : 0)
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
