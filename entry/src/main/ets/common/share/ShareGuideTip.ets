/**
 * 碰一碰 / 隔空传送 引导气泡（2026-10-25 新增；同日第 2 版）
 *
 * ── 素材来源（官方，非自绘）──────────────────────────────────────────────────
 * documentId：`开发指南/Share_Kit_分享服务/碰一碰分享/手机与手机碰一碰分享/内容分享/knock-share-between-phones-content`
 * 原文：「Share Kit提供统一的动图资源文件以方便应用接入。下载地址：碰一碰引导资源，
 * 请完整下载knock_share_guide目录所有文件，并放置于应用entry/src/main/resources/rawfile目录下。」
 * ⇒ 逐帧播放官方素材（210×140，3:2）：
 *   · `knock_share_guide_phone_01..128.webp`（手机/平板）
 *   · `knock_share_guide_pc_01..104.webp` + `knock_share_guide_pc_pull_01..150.webp`（2in1 两段接播）
 * ⚠️ 官方**只有碰一碰的动图**，没有隔空传送的；隔空传送只有文案。
 *
 * ── 本版行为（2026-10-25 用户口述，按此为准）────────────────────────────────
 * ① **每次进入都出现**（原来是"每个界面一次"）：气泡本身只持续几秒、不影响操作，
 *    用户明确要求「每次进入都可以出现」⇒ `active` 每次 false→true 都重新播一遍。
 * ② **文案可自定义**：`line1` / `line2` 由调用方给；留空时按当前设备能力自动生成
 *    （碰一碰可用 →「可碰一碰分享」；隔空传送可用 →「可隔空传送」）。
 *    两条都可用就显示两行。
 * ③ 不支持的设备/版本**完全不渲染**（静默降级，与 BookShareBridge 的闸门口径一致）。
 *
 * ── 放置方式 ────────────────────────────────────────────────────────────────
 * 本组件只画「一条居中的胶囊」，位置由宿主决定：
 *   · 管理页：`.margin({ top: 12 })` 直接挂在页面顶部
 *   · 长按弹窗（底部弹窗）：挂在**页面**的 `.overlay()` 上（弹窗外、屏幕顶部），
 *     不能放进弹窗内容 —— 见 `BookInfoDialogs` 里那段注释。
 */
import { ShareCapability, shareCapability, SHARE_GUIDE_ANIM_ENABLED } from './BookShareBridge'

/** 两位补零（帧名格式：`_01` … `_99`，三位数原样 `_100`） */
function pad2(n: number): string {
  return n < 10 ? `0${n}` : `${n}`
}

/** 手机/平板：官方 128 帧 */
function phoneFrames(): ImageFrameInfo[] {
  const arr: ImageFrameInfo[] = []
  for (let i = 1; i <= 128; i++) {
    arr.push({ src: $rawfile(`knock_share_guide/knock_share_guide_phone_${pad2(i)}.webp`) })
  }
  return arr
}

/** 2in1：官方 pc(104) + pc_pull(150) 两段接起来 */
function pcFrames(): ImageFrameInfo[] {
  const arr: ImageFrameInfo[] = []
  for (let i = 1; i <= 104; i++) {
    arr.push({ src: $rawfile(`knock_share_guide/knock_share_guide_pc_${pad2(i)}.webp`) })
  }
  for (let i = 1; i <= 150; i++) {
    arr.push({ src: $rawfile(`knock_share_guide/knock_share_guide_pc_pull_${pad2(i)}.webp`) })
  }
  return arr
}

@Component
export default struct ShareGuideTip {
  /** 宿主界面传入：此刻是否处于「有选定内容」的可分享态（false→true 时播一遍） */
  @Prop @Watch('onActiveChanged') active: boolean = false
  /** 文案第 1 行；留空 = 自动 */
  @Prop line1: string = ''
  /** 文案第 2 行；留空 = 自动（仅当隔空传送也可用时自动补一行） */
  @Prop line2: string = ''
  /**
   * 是否几秒后自动淡出（2026-10-25 用户要求，两处行为不同）：
   *   · 管理页（浮在页面顶部、会挡视线）⇒ `true`：播 2 轮后淡出
   *   · 长按弹窗（放在卡片内容之上、卡片本来就只开一会儿）⇒ `false`：**常驻不消失**
   */
  @Prop autoHide: boolean = true
  @State private visible: boolean = false
  @State private frames: ImageFrameInfo[] = []
  @State private text1: string = ''
  @State private text2: string = ''
  /** 一轮动画时长（ms）；2 轮后淡出 */
  private readonly roundDuration: number = 2600
  /**
   * 根节点显式高度（vp）= 动画高 44 + 上下 padding 4+4 = 52。
   *
   * ⚠️⚠️ 这个常量是**必须**的，不是样式偏好 —— 2026-10-25 真机回归：
   *   `.overlay()` 的 builder 根节点**不给显式高度时会被撑到整屏高**，
   *   内容贴顶 + **吃掉全部命中测试** ⇒ 表现「进入 app 后点什么都没用」。
   *   本次日志取证：`docs/日志.md:7/20/35/48/63/77/91/106/119` 全是
   *   `W Touch test result is empty.`（输入被处理、但命中测试全空）。
   *   同一坑在工程里已有记录：`pages/view/myCenter/readStatistics.ets:148-151`
   *   （「不给 height 时 overlay 会把根节点撑到整屏高…整页无法点击」）。
   * ⇒ 隐藏时高度必须为 **0**，否则即使 `visible=false` 也会留一块整屏节点挡点击。
   */
  private readonly capsuleHeight: number = 52
  private hideTimer: number = -1

  aboutToAppear(): void {
    if (this.active) {
      this.play()
    }
  }

  aboutToDisappear(): void {
    if (this.hideTimer >= 0) {
      clearTimeout(this.hideTimer)
      this.hideTimer = -1
    }
  }

  onActiveChanged(): void {
    if (this.active) {
      // 每次进入都重新播（用户要求），不做"只出现一次"的闸门
      this.play()
    } else {
      this.stop()
    }
  }

  private stop(): void {
    if (this.hideTimer >= 0) {
      clearTimeout(this.hideTimer)
      this.hideTimer = -1
    }
    this.visible = false
  }

  private play(): void {
    if (!SHARE_GUIDE_ANIM_ENABLED) {
      return
    }
    const cap: ShareCapability = shareCapability()
    if (!cap.any()) {
      // 静默降级：不支持的设备/版本不出现任何引导
      return
    }
    // 动图只有碰一碰的素材；只有隔空传送可用时也用这套（画面是"两部手机靠近"，
    // 语义上仍成立）。
    this.frames = cap.knock ? phoneFrames() : pcFrames()
    // ── 文案：**固定两行**（2026-10-25 用户要求）──────────────────────────────
    // 原话：「我建议文案写两行，碰一碰和隔空传送都写，便于用户知晓。」
    // ⇒ 不再按设备能力裁剪文案（不支持时整个气泡本来就不渲染，不会误导）。
    this.text1 = this.line1 !== '' ? this.line1 : '可碰一碰分享'
    this.text2 = this.line2 !== '' ? this.line2 : '可隔空传送'
    this.visible = true
    if (this.hideTimer >= 0) {
      clearTimeout(this.hideTimer)
      this.hideTimer = -1
    }
    if (!this.autoHide) {
      // 常驻模式（弹窗内）：不设定时器，卡片关掉时组件随之销毁
      return
    }
    this.hideTimer = setTimeout((): void => {
      this.visible = false
      this.hideTimer = -1
    }, this.roundDuration * 2 + 400)
  }

  build() {
    Stack() {
      if (this.visible && this.frames.length > 0) {
        Row({ space: 8 }) {
          // 官方帧尺寸 210×140（3:2）⇒ 按 66×44 显示
          ImageAnimator()
            .images(this.frames)
            .duration(this.roundDuration)
            // 常驻模式（弹窗内）无限循环；自动消失模式播 2 轮即停
            // （官方 `ImageAnimator.iterations`：设为 -1 表示无限次播放）
            .iterations(this.autoHide ? 2 : -1)
            .width(66)
            .height(44)
          Column({ space: 1 }) {
            Text(this.text1)
              .fontSize(12)
              .fontWeight(500)
              .fontColor('#E6FFFFFF')
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            if (this.text2 !== '') {
              Text(this.text2)
                .fontSize(11)
                .fontWeight(400)
                .fontColor('#B3FFFFFF')
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
            }
          }
          .alignItems(HorizontalAlign.Start)
        }
        .padding({ left: 10, right: 14, top: 4, bottom: 4 })
        .backgroundColor('#B3000000')
        .borderRadius(24)
        // 子节点同样要退出命中测试（AGENTS.md §7：`HitTestMode.None` 只让自身退出，
        // 子节点照样吃触摸 ⇒ Stack 与子 Row 都要设）
        .hitTestBehavior(HitTestMode.None)
        .transition(TransitionEffect.OPACITY.animation({ duration: 220 }))
      }
    }
    .width('100%')
    // ⚠️ 显式高度（隐藏时 0）：见 capsuleHeight 注释 —— 不给就会被 overlay 撑到整屏高、
    //    吃掉整页命中测试（2026-10-25 真机回归，日志取证 `docs/日志.md:7` 等）。
    .height(this.visible ? this.capsuleHeight : 0)
    // Stack 默认 Alignment.Center（本组件只做「顶部居中的一条」，具体位置由宿主决定）
    .alignContent(Alignment.Center)
    .hitTestBehavior(HitTestMode.None)
  }
}
