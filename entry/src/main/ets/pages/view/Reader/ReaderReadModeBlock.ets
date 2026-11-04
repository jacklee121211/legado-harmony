/**
 * 设置面板「阅读方式」一行四档（2026-11-05 渲染侧 R-2-c 抽出）
 *
 * 用户原话（2026-10-26）：「底部有个点击切换阅读方式的按钮…把这个按钮拆解，挪到下一行展开，
 *   然后分别是横滑、仿真、上下、无动画。无动画是占位的，注释上，方便后续接入，
 *   然后其他的是真实」。
 *
 * ⚠️ **这里只有视图**：选谁由 `onPick` 回调交给页面，页面再走 `switchReadMode()`
 *    （进度交接、落盘、关面板、收回底栏图标、toast 全部留在页面）。
 *    为什么这么切：`switchReadMode` 有 19 处调用、牵涉三档落盘与自绘层重挂，
 *    把它搬进来只会把"唯一写入口"打散。
 *
 * ⚠️ **档位列表与文案不在本文件**：`modes` / `labels` 由页面传进来，
 *    源头仍是页面的 `readModeOptions()` 与 `readModeOptionLabel()`
 *    （后者同时被页面 toast 复用）⇒ 单一实现，不在两处各写一份。
 *
 * ⚠️ 与旧 @Builder 的行为等价：先 `Haptics.tap()`，**再**判"点的是当前档就直接返回"
 *    （所以点当前档会有震动、不触发切换），顺序不能反。
 */
import { Haptics } from '../../../common/utils/Haptics'
import UiMotion from '../../../common/utils/UiMotion'

@Component
export struct ReaderReadModeBlock {
  /** 当前档位（仿真0 / 横滑1 / 上下2 / 无动画3，见页面 READ_MODE_* 常量） */
  @Prop readMode: number = 1
  /** 0 = 夜间（浅字），其它 = 日间（深字）—— 与面板其它行同源 */
  @Prop colorMode: number = 1
  /** 要显示的档位（顺序由页面 `readModeOptions()` 决定，非 TXT 只给两档） */
  @Prop modes: number[] = []
  /** 与 `modes` 一一对应的按钮文案（页面 `readModeOptionLabel()` 生成） */
  @Prop labels: string[] = []
  /** 选中某一档（页面负责 switchReadMode + 关面板 + toast） */
  onPick: (mode: number) => void = (_m: number): void => {}

  build() {
    Row({ space: 6 }) {
      Text('阅读方式')
        .fontSize(12)
        .width(52)
        .maxLines(1)
        .fontColor(this.colorMode == 0 ? 'rgba(248, 249, 250, 0.6)' : 'rgba(19, 19, 19, 0.6)')
      ForEach(this.modes, (m: number, idx: number) => {
        Button(this.labels[idx])
          .fontSize(13)
          .fontColor(this.readMode === m
            ? Color.White
            : (this.colorMode == 0 ? 'rgba(248, 249, 250, 1)' : 'rgba(19, 19, 19, 1.00)'))
          .backgroundColor(this.readMode === m
            ? '#007DFF'
            : (this.colorMode == 0 ? 'rgba(248, 249, 250, 0.16)' : 'rgba(19, 19, 19, 0.06)'))
          .borderRadius(18)
          .height(34)
          .padding({ left: 6, right: 6 })
          .layoutWeight(1)
          .clickEffect(UiMotion.CLICK)
          .onClick(() => {
            // 顺序照抄原 @Builder：先震动，再判同档返回（点当前档只震动不切换）
            Haptics.tap()
            if (m === this.readMode) {
              return
            }
            this.onPick(m)
          })
      }, (m: number): string => 'rm-' + m)
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
  }
}
