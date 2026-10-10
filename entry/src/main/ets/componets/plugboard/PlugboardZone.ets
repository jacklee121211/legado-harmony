import { PlugboardConfig, PlugType, PlugNode, PlugZone, ratioToHeightRatio } from './PlugboardTypes'
import { PlugboardPrefs } from './PlugboardPrefs'
import { CalibOverlay } from './CalibOverlay'
import { CalibMode } from '../../common/utils/CalibMode'

/**
 * 个性化插件屏 —— 区域容器组件（2026-10-11 第五版重写）
 *
 * 渲染铁律（2026-10-11 用户反馈）：
 *   · 区域"真实比例" = boxRatio（1:1 / 2:1 / 16:1）
 *   · 区域 width = 父布局给（书架 = 剩余空间，方块 = 屏宽/3 居中）
 *   · 区域 height = width × ratioToHeightRatio(boxRatio)
 *   · 图片渲染 = 区域 width × height（用 ImageFit.Fill 充满，绝不 Cover/Contain）
 *   · 用户在裁剪器里"框中的那一块" = 渲染时的可视区域
 *   · 不做"图片适配容器"的二次缩放——图片在裁剪器里已经按用户选择裁了
 *
 * 实时刷新：
 *   · @StorageLink('plugboardTick') 触发 reload → @State config 变 → build 重绘
 *   · reload 也调 parseKeyframes()
 */
@Component
export struct PlugboardZone {
  zone: PlugZone = PlugZone.SHELF_TOP
  zoneLabel: string = ''

  @State config: PlugboardConfig = {
    type: PlugType.IMAGE, source: '', fit: 'fit', opacity: 1,
    boxRatio: '1:1',
    crop: { croppedPath: '', offsetX: 0, offsetY: 0, scale: 1, rotation: 0 },
    positionOffset: { x: 0, y: 0 },
  }

  @StorageLink('plugboardTick') @Watch('onTick') plugboardTick: number = 0
  @StorageLink(CalibMode.STORAGE_KEY) @Watch('onDev') devOn: boolean = false

  /** keyframe 当前帧的展开节点 */
  @State kfCurrentNodes: PlugNode[] = []
  private parsedNodes: PlugNode[] | null = null
  private parseError: boolean = false
  private kfTimerRunning: boolean = false

  /** 实测宽度（vp）—— 用 onAreaChange 同步更新 */
  @State measuredW: number = 0

  onTick(): void {
    this.reload()
  }
  onDev(): void {
    // @StorageLink 自动重绘
  }

  aboutToAppear(): void {
    this.reload()
  }

  reload(): void {
    this.config = PlugboardPrefs.getWithZone(this.zone)
    this.parseError = false
    this.parsedNodes = null
    if (this.config.type === PlugType.JSON && this.config.source.length > 0) {
      try {
        const parsed = JSON.parse(this.config.source) as PlugNode[]
        this.parsedNodes = parsed
        this.kfCurrentNodes = this.flattenNodes(parsed)
        this.startKeyframeLoop(parsed)
      } catch (_e) {
        this.parseError = true
        this.parsedNodes = null
        this.kfCurrentNodes = []
      }
    } else {
      this.parsedNodes = null
      this.kfCurrentNodes = []
    }
  }

  private hasConfig(): boolean {
    return this.config.source.length > 0
  }

  /**
   * 根据实测宽度 + 比例算实际渲染高度
   * measuredW=0（首次）时，给一个合理的 fallback
   */
  private actualH(): number {
    if (this.zone === PlugZone.SHELF_TOP) {
      return 40
    }
    if (this.measuredW <= 0) {
      // 第一次 build 时的兜底
      return 200
    }
    const r = ratioToHeightRatio(this.config.boxRatio)
    return Math.max(60, Math.round(this.measuredW * r))
  }

  build() {
    if (!this.hasConfig() && !this.devOn) {
      Column().width(0).height(0)
    } else {
      Stack({ alignContent: Alignment.TopStart }) {
        // 真实内容
        if (this.hasConfig()) {
          if (this.config.type === PlugType.JSON) {
            if (this.parseError) {
              Text('JSON 错误').fontSize(10).fontColor('#e44')
            } else if (this.kfCurrentNodes.length > 0) {
              this.renderJsonNodes()
            } else {
              Text('加载中…').fontSize(10).fontColor('#888')
            }
          } else if (this.config.type === PlugType.GIF) {
            this.renderGif()
          } else {
            this.renderImage()
          }
        } else {
          // 标定模式无内容：占位
          Column()
            .width('100%')
            .height(this.actualH())
        }
        // 标定叠加层
        if (this.devOn) {
          CalibOverlay({ label: this.zoneLabel })
            .width('100%')
            .height('100%')
        }
      }
      .width('100%')
      .height(this.actualH())
      .offset({ x: this.config.positionOffset.x, y: this.config.positionOffset.y })
      .onAreaChange((_oldV: Area, newV: Area) => {
        const w = newV.width as number
        if (w > 0 && Math.abs(w - this.measuredW) > 0.5) {
          this.measuredW = w
        }
      })
    }
  }

  // ── 渲染：image / gif / json ─────────────────────────────────────

  @Builder
  renderImage() {
    Image(this.resolveMediaSource())
      .objectFit(ImageFit.Fill)
      .width(this.boxRenderW())
      .height(this.actualH())
      .offset({ x: this.cropOffsetX(), y: this.cropOffsetY() })
      .rotate({ angle: this.cropRotation() })
      .opacity(this.config.opacity)
  }

  @Builder
  renderGif() {
    Image(this.config.source)
      .objectFit(ImageFit.Fill)
      .width(this.boxRenderW())
      .height(this.actualH())
      .offset({ x: this.cropOffsetX(), y: this.cropOffsetY() })
      .rotate({ angle: this.cropRotation() })
      .opacity(this.config.opacity)
  }

  private boxRenderW(): number {
    return this.measuredW > 0 ? this.measuredW : 0
  }

  @Builder
  renderJsonNodes() {
    Column() {
      ForEach(this.kfCurrentNodes, (node: PlugNode) => {
        this.renderNode(node)
      }, (_n: PlugNode, idx: number) => idx.toString())
    }
    .width('100%')
    .height(this.actualH())
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .opacity(this.config.opacity)
    .clip(true)
  }

  @Builder
  renderNode(node: PlugNode) {
    if (node.type === 'Text') {
      Text(node.text ?? '')
        .fontSize(node.fontSize ?? 12)
        .fontWeight(node.fontWeight ?? 400)
        .fontColor(node.color ?? '#333')
    } else if (node.type === 'Image') {
      Image(node.src ?? '')
        .width(node.width ?? 24)
        .height(node.height ?? 24)
        .objectFit(ImageFit.Contain)
    } else if (node.type === 'Row') {
      Row({ space: node.gap ?? 0 }) {
        if (node.children !== undefined && node.children !== null) {
          ForEach(node.children, (child: PlugNode) => {
            this.renderNode(child)
          }, (_c: PlugNode, i: number) => i.toString())
        }
      }
      .justifyContent(this.toFlexAlign(node.justifyContent))
      .alignItems(this.toVerticalAlign(node.alignItems))
    } else if (node.type === 'Column') {
      Column({ space: node.gap ?? 0 }) {
        if (node.children !== undefined && node.children !== null) {
          ForEach(node.children, (child: PlugNode) => {
            this.renderNode(child)
          }, (_c: PlugNode, i: number) => i.toString())
        }
      }
      .justifyContent(this.toFlexAlign(node.justifyContent))
      .alignItems(this.toHorizontalAlign(node.alignItems))
    }
  }

  // ── 工具 ────────────────────────────────────────────────────────

  private toFlexAlign(v?: string): FlexAlign {
    if (v === 'center') {
      return FlexAlign.Center
    }
    if (v === 'end') {
      return FlexAlign.End
    }
    if (v === 'spaceBetween') {
      return FlexAlign.SpaceBetween
    }
    return FlexAlign.Start
  }

  private toVerticalAlign(v?: string): VerticalAlign {
    if (v === 'center') {
      return VerticalAlign.Center
    }
    if (v === 'end') {
      return VerticalAlign.Bottom
    }
    return VerticalAlign.Top
  }

  private toHorizontalAlign(v?: string): HorizontalAlign {
    if (v === 'center') {
      return HorizontalAlign.Center
    }
    if (v === 'end') {
      return HorizontalAlign.End
    }
    return HorizontalAlign.Start
  }

  private cropOffsetX(): number {
    const ox = this.config.crop.offsetX
    return (ox === undefined || ox === null) ? 0 : ox as number
  }

  private cropOffsetY(): number {
    const oy = this.config.crop.offsetY
    return (oy === undefined || oy === null) ? 0 : oy as number
  }

  private cropRotation(): number {
    const r = this.config.crop.rotation
    return (r === undefined || r === null) ? 0 : r as number
  }

  private resolveMediaSource(): string {
    const cp = this.config.crop.croppedPath
    if (typeof cp === 'string' && cp.length > 0) {
      return cp
    }
    return this.config.source
  }

  // ── 关键帧动画循环 ──────────────────────────────────────────────

  private startKeyframeLoop(rootNodes: PlugNode[]): void {
    if (this.kfTimerRunning) {
      return
    }
    this.kfTimerRunning = true
    this.scheduleAll(rootNodes)
  }

  private scheduleAll(nodes: PlugNode[]): void {
    for (let i = 0; i < nodes.length; i++) {
      this.scheduleOne(nodes[i])
    }
  }

  private scheduleOne(node: PlugNode): void {
    const kfs = node.keyframes
    if (kfs === undefined || kfs === null || kfs.length === 0) {
      if (node.children !== undefined && node.children !== null) {
        this.scheduleAll(node.children)
      }
      return
    }
    const ms = node.msPerFrame ?? 200
    let idx = 0
    const tick = (): void => {
      idx = (idx + 1) % kfs.length
      try {
        const next = JSON.parse(kfs[idx]) as PlugNode | PlugNode[]
        if (Array.isArray(next)) {
          node.children = next
        } else {
          node.children = [next]
        }
        if (this.parsedNodes !== null) {
          this.kfCurrentNodes = this.flattenNodes(this.parsedNodes)
        }
      } catch (_e) {
        // skip
      }
      setTimeout(tick, ms)
    }
    setTimeout(tick, ms)
  }

  private flattenNodes(nodes: PlugNode[]): PlugNode[] {
    const out: PlugNode[] = []
    for (let i = 0; i < nodes.length; i++) {
      out.push(this.flattenOne(nodes[i]))
    }
    return out
  }

  private flattenOne(n: PlugNode): PlugNode {
    const out: PlugNode = { type: n.type }
    if (n.text !== undefined) {
      out.text = n.text
    }
    if (n.src !== undefined) {
      out.src = n.src
    }
    if (n.color !== undefined) {
      out.color = n.color
    }
    if (n.fontSize !== undefined) {
      out.fontSize = n.fontSize
    }
    if (n.fontWeight !== undefined) {
      out.fontWeight = n.fontWeight
    }
    if (n.width !== undefined) {
      out.width = n.width
    }
    if (n.height !== undefined) {
      out.height = n.height
    }
    if (n.gap !== undefined) {
      out.gap = n.gap
    }
    if (n.justifyContent !== undefined) {
      out.justifyContent = n.justifyContent
    }
    if (n.alignItems !== undefined) {
      out.alignItems = n.alignItems
    }
    if (n.children !== undefined && n.children !== null) {
      out.children = this.flattenNodes(n.children)
    }
    return out
  }
}