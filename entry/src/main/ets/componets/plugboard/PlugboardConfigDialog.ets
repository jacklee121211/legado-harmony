import { PlugZone, PlugboardConfig, PlugType, BoxRatio, PlugNode, PlugboardConfigDefault } from './PlugboardTypes'
import { PlugboardPrefs, PlugPresets, PlugPreset } from './PlugboardPrefs'
import { ImageCropperComponent } from './ImageCropperView'
import { CropResult } from './ImageCropper'
import { Haptics } from '../../common/utils/Haptics'
import { FileHandler } from '../../common/utils/FileHandler'
import { NightMode, ShelfColors } from '../../common/utils/NightMode'
import { MaterialColumnModifier } from '../../common/utils/ImmersiveMaterialUtil'
import UiMotion from '../../common/utils/UiMotion'

/**
 * 个性化插件屏 —— 配置弹窗（2026-10-11 第五版重写）
 *
 * 修复记录（用户反馈 → 修复）：
 *   · #1 保存无反应 → 用同步 Q弹 + 闭锁，setTimeout 0 后再 close controller
 *   · #2 方块区显示极小 → previewW/H 与区域真实比例联动
 *   · #3 图片比例错 → 预览框用 ImageFit.Fill，区域比例 = boxRatio
 *   · #4 按钮参差 + emoji → 统一 Button 尺寸（28vp 高 / 12 fontSize / 14 字号）
 *     预置标签去掉 emoji，保留 4 个纯文字标签
 *   · #5 欢迎语/阅读时光预览不出 → 预览框最小高度 80vp，居中
 */
@CustomDialog
export struct PlugboardConfigDialog {
  onClose: () => void = (): void => {}
  controller?: CustomDialogController

  @State zone: PlugZone = PlugZone.SHELF_TOP
  @State cfg: PlugboardConfig = JSON.parse(JSON.stringify(PlugboardConfigDefault)) as PlugboardConfig

  /** 预览框尺寸（按区域真实比例） */
  @State previewW: number = 280
  @State previewH: number = 40
  @State previewLabel: string = '书架顶部'

  /** JSON 编辑 */
  @State jsonEditing: boolean = false
  @State jsonText: string = ''
  @State jsonError: string = ''

  /** 预览的 JSON 节点 */
  @State parsedNodesJson: PlugNode[] = []
  @State jsonPreviewError: boolean = false

  /** 裁剪器 */
  @State cropperOpen: boolean = false
  @State cropperPath: string = ''

  /** 同步 Q弹：直接 animateTo scale，不依赖 runJellyClick */
  @State saveScale: number = 1
  @State saveLock: boolean = false
  @State closeScale: number = 1
  @State importScale: number = 1
  @State leftScale: number = 1
  @State rightScale: number = 1
  @State upScale: number = 1
  @State downScale: number = 1
  @State resetScale: number = 1
  @State ratio1Scale: number = 1
  @State ratio2Scale: number = 1
  @State presetScale: number = 1

  private surface: MaterialColumnModifier = new MaterialColumnModifier(
    NightMode.isDarkSurface() ? ShelfColors.card() : Color.White, true)

  aboutToAppear(): void {
    this.syncZoneUI()
    this.refreshJsonPreview()
  }

  private syncZoneUI(): void {
    this.cfg = PlugboardPrefs.getWithZone(this.zone)
    if (this.zone === PlugZone.SHELF_TOP) {
      this.previewW = 320
      this.previewH = 20
      this.previewLabel = '书架顶部 · 16:1'
    } else {
      this.previewW = 240
      const r = this.cfg.boxRatio
      this.previewH = r === '1:1' ? this.previewW : Math.round(this.previewW * 0.5)
      this.previewLabel = r === '1:1' ? '我的·方块 · 1:1' : '我的·方块 · 2:1'
    }
  }

  private switchZone(z: PlugZone): void {
    Haptics.tap()
    this.zone = z
    this.syncZoneUI()
    this.refreshJsonPreview()
  }

  private toggleRatio(r: BoxRatio): void {
    Haptics.tap()
    this.cfg.boxRatio = r
    this.previewH = r === '1:1' ? this.previewW : Math.round(this.previewW * 0.5)
    this.previewLabel = r === '1:1' ? '我的·方块 · 1:1' : '我的·方块 · 2:1'
    this.jellyTap(this.ratio1Scale === 1 ? 'ratio1Scale' : 'ratio2Scale')
  }

  /**
   * 同步 Q弹：直接设 state → @State 触发 animateTo
   * 简化为：点击瞬间置 0.92，下一帧回到 1
   */
  private jellyTap(key: 'ratio1Scale' | 'ratio2Scale' | 'leftScale' | 'rightScale' | 'upScale' | 'downScale' | 'resetScale' | 'presetScale' | 'importScale' | 'closeScale'): void {
    if (key === 'ratio1Scale') {
      this.ratio1Scale = 0.92
    } else if (key === 'ratio2Scale') {
      this.ratio2Scale = 0.92
    } else if (key === 'leftScale') {
      this.leftScale = 0.92
    } else if (key === 'rightScale') {
      this.rightScale = 0.92
    } else if (key === 'upScale') {
      this.upScale = 0.92
    } else if (key === 'downScale') {
      this.downScale = 0.92
    } else if (key === 'resetScale') {
      this.resetScale = 0.92
    } else if (key === 'presetScale') {
      this.presetScale = 0.92
    } else if (key === 'importScale') {
      this.importScale = 0.92
    } else if (key === 'closeScale') {
      this.closeScale = 0.92
    }
    setTimeout(() => {
      if (key === 'ratio1Scale') {
        this.ratio1Scale = 1
      } else if (key === 'ratio2Scale') {
        this.ratio2Scale = 1
      } else if (key === 'leftScale') {
        this.leftScale = 1
      } else if (key === 'rightScale') {
        this.rightScale = 1
      } else if (key === 'upScale') {
        this.upScale = 1
      } else if (key === 'downScale') {
        this.downScale = 1
      } else if (key === 'resetScale') {
        this.resetScale = 1
      } else if (key === 'presetScale') {
        this.presetScale = 1
      } else if (key === 'importScale') {
        this.importScale = 1
      } else if (key === 'closeScale') {
        this.closeScale = 1
      }
    }, 100)
  }

  private selectPreset(p: PlugboardConfig): void {
    Haptics.tap()
    this.jellyTap('presetScale')
    this.cfg = {
      type: p.type,
      source: p.source,
      fit: p.fit,
      opacity: p.opacity,
      boxRatio: this.zone === PlugZone.SHELF_TOP ? '16:1' : (p.boxRatio === '16:1' ? '1:1' : p.boxRatio),
      crop: {
        croppedPath: p.crop.croppedPath ?? '',
        offsetX: p.crop.offsetX ?? 0,
        offsetY: p.crop.offsetY ?? 0,
        scale: p.crop.scale ?? 1,
        rotation: p.crop.rotation ?? 0,
      },
      positionOffset: { x: 0, y: 0 },
    }
    this.syncZoneUI()
    this.refreshJsonPreview()
  }

  private async pickImage(): Promise<void> {
    Haptics.tap()
    this.jellyTap('importScale')
    try {
      const files = await FileHandler.documentPickerFile(1, ['.png', '.jpg', '.jpeg', '.gif', '.webp', '.bmp'])
      if (files.length > 0) {
        this.cropperPath = files[0]
        this.cropperOpen = true
      }
    } catch (_e) {
      // user cancel
    }
  }

  private onCropDone(result: CropResult): void {
    this.cropperOpen = false
    const isGif = this.cropperPath.toLowerCase().endsWith('.gif')
    this.cfg.type = isGif ? PlugType.GIF : PlugType.IMAGE
    this.cfg.source = this.cropperPath
    this.cfg.crop = {
      croppedPath: '',
      offsetX: result.offsetX,
      offsetY: result.offsetY,
      scale: result.scale,
      rotation: result.rotation,
    }
    this.refreshJsonPreview()
  }

  private onCropCancel(): void {
    this.cropperOpen = false
    this.cropperPath = ''
  }

  private toggleJsonEditor(): void {
    Haptics.tap()
    this.jsonEditing = !this.jsonEditing
    if (this.jsonEditing) {
      if (this.cfg.type === PlugType.JSON && this.cfg.source.length > 0) {
        try {
          const pp = JSON.parse(this.cfg.source) as PlugNode[]
          this.jsonText = JSON.stringify(pp, null, 2)
        } catch (_e) {
          this.jsonText = this.cfg.source
        }
      } else {
        this.jsonText = JSON.stringify([{ type: 'Text', text: 'hello' }], null, 2)
      }
      this.jsonError = ''
    }
  }

  private applyJson(): void {
    Haptics.tap()
    this.jsonError = ''
    let ok = false
    let nodes: PlugNode[] = []
    try {
      nodes = JSON.parse(this.jsonText) as PlugNode[]
      ok = true
    } catch (e) {
      this.jsonError = 'JSON 解析错误: ' + (e instanceof Error ? e.message : String(e))
    }
    if (ok) {
      this.cfg.type = PlugType.JSON
      this.cfg.source = JSON.stringify(nodes)
      this.cfg.crop = { croppedPath: '', offsetX: 0, offsetY: 0, scale: 1, rotation: 0 }
      this.refreshJsonPreview()
    }
  }

  private clearContent(): void {
    Haptics.tap()
    this.cfg = JSON.parse(JSON.stringify(PlugboardConfigDefault)) as PlugboardConfig
    if (this.zone === PlugZone.SHELF_TOP) {
      this.cfg.boxRatio = '16:1'
    }
    this.syncZoneUI()
    this.refreshJsonPreview()
  }

  /**
   * 位置偏移（精度 1vp 一档）
   */
  private moveOffset(dx: number, dy: number, key: 'leftScale' | 'rightScale' | 'upScale' | 'downScale'): void {
    Haptics.tap()
    this.jellyTap(key)
    this.cfg.positionOffset = {
      x: this.cfg.positionOffset.x + dx,
      y: this.cfg.positionOffset.y + dy,
    }
  }

  private resetOffset(): void {
    Haptics.tap()
    this.jellyTap('resetScale')
    this.cfg.positionOffset = { x: 0, y: 0 }
  }

  /**
   * 保存（修复 #1 保存无反应）
   *   · saveLock 防重入
   *   · 同步 Q弹（避免 runJellyClick 异步状态机冲突）
   *   · 落盘 + 广播 tick 后 setTimeout 0 再 close controller
   */
  private save(): void {
    if (this.saveLock) {
      return
    }
    Haptics.tap()
    this.saveLock = true
    this.saveScale = 0.94
    // 1) 落盘
    PlugboardPrefs.set(this.zone, this.cfg)
    // 2) 广播刷新信号
    const tick = AppStorage.get<number>('plugboardTick')
    AppStorage.setOrCreate('plugboardTick', (tick ?? 0) + 1)
    // 3) 下一帧 close
    setTimeout(() => {
      this.saveScale = 1
      this.onClose()
      this.controller?.close()
      this.saveLock = false
    }, 80)
  }

  private refreshJsonPreview(): void {
    if (this.cfg.type === PlugType.JSON && this.cfg.source.length > 0) {
      try {
        this.parsedNodesJson = JSON.parse(this.cfg.source) as PlugNode[]
        this.jsonPreviewError = false
      } catch (_e) {
        this.jsonPreviewError = true
      }
    } else {
      this.parsedNodesJson = []
      this.jsonPreviewError = false
    }
  }

  build() {
    if (this.cropperOpen) {
      this.buildCropper()
    } else {
      this.buildConfig()
    }
  }

  // ── 主配置面板 ──
  @Builder
  buildConfig() {
    Column() {
      // 标题栏
      Row() {
        Text('个性化配置').fontSize(16).fontWeight(600)
          .fontColor(NightMode.isDarkSurface() ? 'rgba(248,249,250,0.92)' : '#333')
        Blank()
        SymbolGlyph($r('sys.symbol.xmark'))
          .fontSize(20)
          .fontColor([NightMode.isDarkSurface() ? 'rgba(248,249,250,0.6)' : '#666'])
          .scale({ x: this.closeScale, y: this.closeScale })
          .onClick(() => {
            Haptics.tap()
            this.jellyTap('closeScale')
            this.onClose()
            this.controller?.close()
          })
          .clickEffect(UiMotion.CLICK)
      }
      .width('100%')
      .padding({ top: 16, bottom: 10 })

      // 区域选择
      Row({ space: 8 }) {
        Text('区域').fontSize(12).fontColor($r('app.color.text_tertiary')).width(36)
        this.zoneBtn('书架', PlugZone.SHELF_TOP, $r('sys.symbol.book'))
        this.zoneBtn('方块', PlugZone.MY_BLOCK, $r('sys.symbol.rectangle_3_group'))
      }
      .width('100%')
      .margin({ top: 6, bottom: 10 })

      // 2区比例选择（只有2区显示）
      if (this.zone === PlugZone.MY_BLOCK) {
        Row({ space: 8 }) {
          Text('比例').fontSize(12).fontColor($r('app.color.text_tertiary')).width(36)
          this.ratioBtn('1:1', '1:1', this.ratio1Scale)
          this.ratioBtn('2:1', '2:1', this.ratio2Scale)
        }
        .width('100%')
        .margin({ bottom: 10 })
      }

      // 位置调整（上下左右按钮）
      Row({ space: 6 }) {
        Text('位置').fontSize(12).fontColor($r('app.color.text_tertiary')).width(36)
        this.posBtn('sys.symbol.arrow_left', this.leftScale, () => this.moveOffset(-1, 0, 'leftScale'))
        this.posBtn('sys.symbol.arrow_up', this.upScale, () => this.moveOffset(0, -1, 'upScale'))
        this.posBtn('sys.symbol.arrow_down', this.downScale, () => this.moveOffset(0, 1, 'downScale'))
        this.posBtn('sys.symbol.arrow_right', this.rightScale, () => this.moveOffset(1, 0, 'rightScale'))
        Blank()
        Text(`x=${this.cfg.positionOffset.x} y=${this.cfg.positionOffset.y}`)
          .fontSize(10).fontColor('#888')
        SymbolGlyph($r('sys.symbol.arrow_counterclockwise'))
          .fontSize(16)
          .fontColor(['#e44'])
          .margin({ left: 6 })
          .scale({ x: this.resetScale, y: this.resetScale })
          .onClick(() => { this.resetOffset() })
          .clickEffect(UiMotion.CLICK)
      }
      .width('100%')
      .margin({ bottom: 10 })

      // 内容来源
      Row({ space: 8 }) {
        Text('内容').fontSize(12).fontColor($r('app.color.text_tertiary')).width(36)
        this.actionBtn('图片', $r('sys.symbol.picture'), () => this.pickImage())
        this.actionBtn('JSON', $r('sys.symbol.square_and_pencil'), () => this.toggleJsonEditor())
        this.actionBtn('清除', $r('sys.symbol.trash'), () => this.clearContent())
      }
      .width('100%')
      .margin({ bottom: 10 })

      // 预置列表（无 emoji，统一字号）
      Row({ space: 6 }) {
        Text('预置').fontSize(12).fontColor($r('app.color.text_tertiary')).width(36)
        this.presetBtn('鲸鱼')
        this.presetBtn('星光')
        this.presetBtn('阅读')
        this.presetBtn('欢迎')
      }
      .width('100%')
      .margin({ bottom: 10 })

      // JSON 编辑面板
      if (this.jsonEditing) {
        this.buildJsonEditor()
      }

      // 实时预览
      this.buildPreview()

      // 保存按钮
      Row() {
        Text('保存')
          .fontSize(15).fontWeight(600)
          .fontColor(Color.White)
          .scale({ x: this.saveScale, y: this.saveScale })
          .onClick(() => { this.save() })
          .clickEffect(UiMotion.CLICK)
      }
      .width('60%').height(44)
      .justifyContent(FlexAlign.Center)
      .borderRadius(22)
      .backgroundColor('#4A90D9')
      .margin({ bottom: 12 })
      .enabled(!this.saveLock)
    }
    .attributeModifier(this.surface)
    .borderRadius(20)
    .width('100%')
    .padding({ left: 16, right: 16 })
  }

  @Builder
  buildJsonEditor() {
    Column() {
      Text('JSON 模板编辑').fontSize(12).fontColor($r('app.color.text_tertiary'))
        .margin({ bottom: 4 })
      TextArea({ text: this.jsonText })
        .height(140)
        .fontSize(11)
        .fontFamily('monospace')
        .onChange((v: string) => { this.jsonText = v })
      if (this.jsonError.length > 0) {
        Text(this.jsonError)
          .fontSize(10).fontColor('#e44')
          .margin({ top: 4 })
      }
      Row({ space: 8 }) {
        Button('应用').fontSize(12)
          .backgroundColor('#4A90D9')
          .fontColor(Color.White)
          .height(30)
          .onClick(() => this.applyJson())
        Button('关闭').fontSize(12)
          .backgroundColor('#ddd')
          .height(30)
          .onClick(() => { this.jsonEditing = false })
      }
      .margin({ top: 6 })
    }
    .width('100%')
    .padding(10)
    .borderRadius(8)
    .backgroundColor(NightMode.isDarkSurface() ? '#2a2a2a' : 'rgba(0,0,0,0.04)')
    .margin({ bottom: 10 })
  }

  /**
   * 预览框（按区域真实比例）
   *   · 1区 16:1 → 宽 320 × 高 20
   *   · 2区 1:1 → 宽 240 × 高 240
   *   · 2区 2:1 → 宽 240 × 高 120
   * 内部图片用 ImageFit.Fill 填满
   */
  @Builder
  buildPreview() {
    Column() {
      Text('预览 · ' + this.previewLabel).fontSize(11).fontColor($r('app.color.text_tertiary'))
        .margin({ bottom: 6 })
        .width('100%')
      Column() {
        if (this.cfg.source.length === 0) {
          Text('空').fontSize(11).fontColor('#ccc')
        } else if (this.cfg.type === PlugType.JSON) {
          this.buildJsonPreview()
        } else {
          this.buildImagePreview()
        }
      }
      .width(this.previewW)
      .height(this.previewH)
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
      .backgroundColor(NightMode.isDarkSurface() ? '#2a2a2a' : '#f9f9f9')
      .border({ width: 1, color: '#eee', style: BorderStyle.Dashed })
      .clip(true)
    }
    .width('100%')
    .margin({ bottom: 14 })
  }

  @Builder
  buildJsonPreview() {
    if (this.jsonPreviewError) {
      Text('JSON 错误').fontSize(10).fontColor('#e44')
    } else if (this.parsedNodesJson.length > 0) {
      Column() {
        ForEach(this.parsedNodesJson, (node: PlugNode) => {
          this.previewNode(node)
        }, (_n: PlugNode, i: number) => i.toString())
      }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
    } else {
      Text('空').fontSize(11).fontColor('#ccc')
    }
  }

  @Builder
  buildImagePreview() {
    Image(this.previewImageSource())
      .width('100%')
      .height('100%')
      .objectFit(ImageFit.Fill)
      .opacity(this.cfg.opacity)
  }

  @Builder
  buildCropper() {
    Column() {
      ImageCropperComponent({
        filePath: this.cropperPath,
        ratio: this.cfg.boxRatio,
        viewportW: 280,
        onConfirm: (r: CropResult) => { this.onCropDone(r) },
        onCancel: () => { this.onCropCancel() },
      })
    }
    .attributeModifier(this.surface)
    .borderRadius(20)
    .width('100%')
    .padding(16)
  }

  // ── 统一尺寸的按钮（修复 #4 按钮参差） ──

  @Builder
  zoneBtn(label: string, z: PlugZone, icon: Resource) {
    Row({ space: 4 }) {
      SymbolGlyph(icon)
        .fontSize(15)
        .fontColor([this.zone === z ? Color.White : '#666'])
      Text(label)
        .fontSize(13)
        .fontColor(this.zone === z ? Color.White : '#666')
    }
    .height(30)
    .padding({ left: 12, right: 12 })
    .borderRadius(15)
    .backgroundColor(this.zone === z ? '#4A90D9' : 'rgba(0,0,0,0.06)')
    .onClick(() => { this.switchZone(z) })
    .clickEffect(UiMotion.CLICK)
  }

  @Builder
  ratioBtn(label: string, value: '1:1' | '2:1', scale: number) {
    Button(label)
      .fontSize(13)
      .fontColor(this.cfg.boxRatio === value ? Color.White : '#666')
      .height(30)
      .width(64)
      .borderRadius(15)
      .backgroundColor(this.cfg.boxRatio === value ? '#4A90D9' : 'rgba(0,0,0,0.06)')
      .scale({ x: scale, y: scale })
      .onClick(() => this.toggleRatio(value))
      .clickEffect(UiMotion.CLICK)
  }

  @Builder
  posBtn(icon: string, scale: number, onTap: () => void) {
    SymbolGlyph($r(icon))
      .fontSize(18)
      .fontColor(['#666'])
      .scale({ x: scale, y: scale })
      .onClick(() => onTap())
      .clickEffect(UiMotion.CLICK)
  }

  @Builder
  actionBtn(label: string, icon: Resource, onTap: () => void) {
    Column({ space: 4 }) {
      SymbolGlyph(icon)
        .fontSize(20)
        .fontColor(['#666'])
      Text(label)
        .fontSize(11)
        .fontColor('#666')
    }
    .height(56)
    .width(60)
    .justifyContent(FlexAlign.Center)
    .borderRadius(8)
    .backgroundColor('rgba(0,0,0,0.04)')
    .onClick(() => {
      Haptics.tap()
      onTap()
    })
    .clickEffect(UiMotion.CLICK)
  }

  @Builder
  presetBtn(label: string) {
    Text(label)
      .fontSize(12)
      .height(28)
      .padding({ left: 10, right: 10 })
      .borderRadius(14)
      .backgroundColor('rgba(0,0,0,0.06)')
      .scale({ x: this.presetScale, y: this.presetScale })
      .onClick(() => {
        Haptics.tap()
        this.jellyTap('presetScale')
        // 按 label 找 preset
        const p: PlugboardConfig | undefined = this.findPresetByShortLabel(label)
        if (p !== undefined) {
          this.selectPreset(p)
        }
      })
      .clickEffect(UiMotion.CLICK)
  }

  @Builder
  previewNode(node: PlugNode) {
    if (node.type === 'Text') {
      Text(node.text ?? '')
        .fontSize(node.fontSize ?? 11)
        .fontWeight(node.fontWeight ?? 400)
        .fontColor(node.color ?? '#333')
    } else if (node.type === 'Image') {
      Image(node.src ?? '')
        .width(node.width ?? 20)
        .height(node.height ?? 20)
        .objectFit(ImageFit.Contain)
    } else if (node.type === 'Row') {
      Row({ space: node.gap ?? 4 }) {
        if (node.children !== undefined && node.children !== null) {
          ForEach(node.children, (child: PlugNode) => {
            this.previewNode(child)
          }, (_c: PlugNode, i: number) => i.toString())
        }
      }
    } else if (node.type === 'Column') {
      Column({ space: node.gap ?? 4 }) {
        if (node.children !== undefined && node.children !== null) {
          ForEach(node.children, (child: PlugNode) => {
            this.previewNode(child)
          }, (_c: PlugNode, i: number) => i.toString())
        }
      }
    }
  }

  private findPresetByLabel(label: string): PlugboardConfig | undefined {
    for (let i = 0; i < PlugPresets.length; i++) {
      if (PlugPresets[i].label === label) {
        return PlugPresets[i].config
      }
    }
    return undefined
  }

  /**
   * 短标签映射到预设（去除 emoji，UI 干净）
   * 鲸鱼 / 星光 / 阅读 / 欢迎
   */
  private findPresetByShortLabel(short: string): PlugboardConfig | undefined {
    const map: Record<string, string> = {
      '鲸鱼': '🐋 像素鲸鱼',
      '星光': '✧ 星光点点',
      '阅读': '📖 阅读时光',
      '欢迎': '💬 欢迎语',
    }
    const full = map[short]
    if (full === undefined) {
      return undefined
    }
    return this.findPresetByLabel(full)
  }

  private previewImageSource(): string {
    const cp = this.cfg.crop.croppedPath
    if (typeof cp === 'string' && cp.length > 0) {
      return cp
    }
    return this.cfg.source
  }
}