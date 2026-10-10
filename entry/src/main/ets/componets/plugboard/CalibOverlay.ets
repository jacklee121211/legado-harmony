import { CalibMode } from '../../common/utils/CalibMode'

/**
 * 标定叠加层（2026-10-10 新增）
 *
 * 视觉规范（沿用阅读器标尺的配色）：
 *   · 水平/竖直线 = 红色 `rgba(255,0,0,0.45)`，每 5 条加深到 `rgba(255,0,0,0.9)`
 *   · 区域外框 = 红色虚线 1vp
 *   · 区域内部半透明红底 = `rgba(255,0,0,0.06)`
 *   · 角标 = 红色字体显示位置信息（如"1区·bookshelf·40vp"）
 *   · 绿色左右边界 = `rgba(0,200,0,0.9)`（阅读器同款）
 *
 * 在父 Stack 里占满：
 *   CalibOverlay({ label: '1区' })
 *     .width('100%')
 *     .height('100%')
 */
@Component
export struct CalibOverlay {
  /** 区域标签（左上角红字） */
  label: string = ''

  /** 监听全局标定开关 */
  @StorageLink(CalibMode.STORAGE_KEY) @Watch('onDev') devOn: boolean = false

  /** 自测尺寸 */
  @State selfW: number = 0
  @State selfH: number = 0

  onDev(): void {
    // @StorageLink 自动重绘
  }

  build() {
    if (!this.devOn) {
      Column().width(0).height(0)
    } else if (this.selfW <= 0 || this.selfH <= 0) {
      // 还没测到尺寸 → 返回一个透明占位节点，等 onAreaChange 回调
      Column().width('100%').height('100%')
        .onAreaChange((_oldV: Area, newV: Area) => {
          const w = newV.width as number
          const h = newV.height as number
          if (w > 0 && h > 0) {
            this.selfW = w
            this.selfH = h
          }
        })
    } else {
      Stack() {
        // 半透明红底
        Column()
          .width(this.selfW)
          .height(this.selfH)
          .backgroundColor('rgba(255, 0, 0, 0.06)')

        // 红色虚线外框
        Column()
          .width(this.selfW)
          .height(this.selfH)
          .border({ width: 1, color: '#FF0000', style: BorderStyle.Dashed })

        // 经线（竖直）
        ForEach(this.vLines(), (x: number, i: number) => {
          Column()
            .width(1)
            .height(this.selfH)
            .backgroundColor(i % 5 === 0 ? 'rgba(255,0,0,0.9)' : 'rgba(255,0,0,0.35)')
            .position({ x: x, y: 0 })
            .hitTestBehavior(HitTestMode.None)
        }, (_x: number, i: number) => `v${i}`)

        // 纬线（水平）
        ForEach(this.hLines(), (y: number, i: number) => {
          Column()
            .width(this.selfW)
            .height(1)
            .backgroundColor(i % 5 === 0 ? 'rgba(255,0,0,0.9)' : 'rgba(255,0,0,0.35)')
            .position({ x: 0, y: y })
            .hitTestBehavior(HitTestMode.None)
        }, (_y: number, i: number) => `h${i}`)

        // 绿色左右边界（阅读器同款）
        Column()
          .width(1).height(this.selfH)
          .backgroundColor('rgba(0,200,0,0.9)')
          .position({ x: 0, y: 0 })
          .hitTestBehavior(HitTestMode.None)
        Column()
          .width(1).height(this.selfH)
          .backgroundColor('rgba(0,200,0,0.9)')
          .position({ x: this.selfW - 1, y: 0 })
          .hitTestBehavior(HitTestMode.None)

        // 角标
        Text(`${this.label} · ${Math.round(this.selfW)}×${Math.round(this.selfH)}vp`)
          .fontSize(9)
          .fontColor('#FF0000')
          .backgroundColor('rgba(255,255,255,0.85)')
          .padding(2)
          .position({ x: 2, y: 2 })
          .hitTestBehavior(HitTestMode.None)
      }
      .width(this.selfW)
      .height(this.selfH)
      .hitTestBehavior(HitTestMode.None)
    }
  }

  private vLines(): number[] {
    const step = 16
    const lines: number[] = []
    for (let x = step; x < this.selfW; x += step) {
      lines.push(x)
    }
    return lines
  }

  private hLines(): number[] {
    const step = 16
    const lines: number[] = []
    for (let y = step; y < this.selfH; y += step) {
      lines.push(y)
    }
    return lines
  }
}

// CalibBox 已删 —— 不再需要包装器，直接用 CalibOverlay 就行