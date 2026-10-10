import { BoxRatio, ratioToHeightRatio } from './PlugboardTypes'
import { CropResult, ImageInfo, readImageInfo } from './ImageCropper'
import { Haptics } from '../../common/utils/Haptics'
import UiMotion, { runJellyClick } from '../../common/utils/UiMotion'

/**
 * 图片裁剪器（2026-10-11 第六版重写）
 *
 * 设计哲学（用户原话）：
 *   "我们的裁剪器就是区域的真实比例，这就完了，我们取图，
 *    不管图多大，什么比例，我们就取比例那一块"
 *
 * 实现：
 *   · Image 用 ImageFit.Contain 居中显示（不压缩、不裁切，完整可见）
 *   · 用户手势（Pan/Pinch）调整 userOffsetX/Y + userScale
 *   · 裁剪结果 = scale/offsetX/offsetY/rotation 4 个参数
 *   · 渲染时（PlugboardZone）按这 4 个参数把 Image 摆到目标区域
 *
 * 修复 #3 裁剪器"压缩了"：
 *   · 旧代码 baseScale = min(targetW/imgW, targetH/imgH)，导致 4:3 → 16:1 时
 *     缩到 1/12 + 高度拉 4 倍，比例严重失衡
 *   · 新代码：Image 原样显示，userScale 从 1.0 起步，用户自由缩放
 */
@Component
export struct ImageCropperComponent {
  filePath: string = ''
  ratio: BoxRatio = '1:1'
  onConfirm: (result: CropResult) => void = (): void => {}
  onCancel: () => void = (): void => {}
  viewportW: number = 280

  @State viewportH: number = 200
  @State img: ImageInfo = { width: 0, height: 0, isGif: false }
  @State loading: boolean = true

  // 用户调整（userScale 从 1.0 起步：原图原始大小）
  @State userScale: number = 1
  @State userOffsetX: number = 0
  @State userOffsetY: number = 0
  @State userRotation: number = 0

  // 手势临时量
  private panLastX: number = 0
  private panLastY: number = 0
  private pinchLastScale: number = 1

  @State rotateScale: number = 1
  @State confirmScale: number = 1
  @State cancelScale: number = 1

  aboutToAppear(): void {
    this.computeViewport()
    this.loadImage()
  }

  private computeViewport(): void {
    const r = ratioToHeightRatio(this.ratio)
    this.viewportH = Math.max(80, Math.round(this.viewportW * r))
  }

  private async loadImage(): Promise<void> {
    if (this.filePath.length === 0) {
      return
    }
    try {
      const info = await readImageInfo(this.filePath)
      this.img = info
      this.userScale = 1
      this.userOffsetX = 0
      this.userOffsetY = 0
      this.userRotation = 0
      this.loading = false
    } catch (_e) {
      this.loading = false
    }
  }

  private onPanStart(_e: GestureEvent): void {
    this.panLastX = 0
    this.panLastY = 0
  }

  private onPanUpdate(e: GestureEvent): void {
    const dx = e.offsetX - this.panLastX
    const dy = e.offsetY - this.panLastY
    this.panLastX = e.offsetX
    this.panLastY = e.offsetY
    this.userOffsetX = this.userOffsetX + dx
    this.userOffsetY = this.userOffsetY + dy
  }

  private onPanEnd(_e: GestureEvent): void {
    this.panLastX = 0
    this.panLastY = 0
  }

  private onPinchStart(_e: GestureEvent): void {
    this.pinchLastScale = 1
  }

  private onPinchUpdate(e: GestureEvent): void {
    if (this.pinchLastScale > 0) {
      const ratio = e.scale / this.pinchLastScale
      this.userScale = Math.max(0.3, Math.min(5, this.userScale * ratio))
    }
    this.pinchLastScale = e.scale
  }

  private onPinchEnd(_e: GestureEvent): void {
    this.pinchLastScale = 1
  }

  private rotate90(): void {
    Haptics.tap()
    runJellyClick((v: number) => { this.rotateScale = v })
    this.userRotation = (this.userRotation + 90) % 360
  }

  private confirm(): void {
    Haptics.tap()
    runJellyClick((v: number) => { this.confirmScale = v })
    const r: CropResult = {
      scale: this.userScale,
      offsetX: this.userOffsetX,
      offsetY: this.userOffsetY,
      rotation: this.userRotation,
      originalW: this.img.width,
      originalH: this.img.height,
    }
    this.onConfirm(r)
  }

  private cancel(): void {
    Haptics.tap()
    runJellyClick((v: number) => { this.cancelScale = v })
    this.onCancel()
  }

  build() {
    Column() {
      // 标题
      Row() {
        Text('裁剪 · ' + this.ratio)
          .fontSize(13).fontWeight(600)
          .fontColor('#333')
        Blank()
        Text(this.img.isGif ? '动图·保留动画' : '静态图')
          .fontSize(10)
          .fontColor('#888')
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 8, bottom: 8 })

      // 裁剪画布
      // Image 永远 .width(viewportW).height(viewportH)
      // "缩放/旋转/平移"通过修饰符应用（不引起 Image 自身尺寸变化，避免黑屏）
      Stack({ alignContent: Alignment.Center }) {
        if (this.loading) {
          Text('加载中…').fontSize(11).fontColor('#888')
        }
        Image(this.filePath)
          .objectFit(ImageFit.Contain)
          .width(this.viewportW)
          .height(this.viewportH)
          .scale({ x: this.userScale, y: this.userScale })
          .rotate({ angle: this.userRotation })
          .offset({ x: this.userOffsetX, y: this.userOffsetY })
          .hitTestBehavior(HitTestMode.None)
        // 暗色蒙板
        Column()
          .width('100%').height('100%')
          .backgroundColor('rgba(0,0,0,0.55)')
          .hitTestBehavior(HitTestMode.None)
        // 中间挖空（高亮目标比例区）
        Column()
          .width(this.viewportW)
          .height(this.viewportH)
          .backgroundColor('rgba(0,0,0,0)')
          .border({ width: 2, color: '#FFFFFF', style: BorderStyle.Solid })
          .hitTestBehavior(HitTestMode.None)
      }
      .width(this.viewportW)
      .height(this.viewportH)
      .backgroundColor('#222')
      .clip(true)
      .gesture(
        GestureGroup(GestureMode.Parallel,
          PanGesture({ fingers: 1, distance: 2 })
            .onActionStart((e: GestureEvent) => this.onPanStart(e))
            .onActionUpdate((e: GestureEvent) => this.onPanUpdate(e))
            .onActionEnd((e: GestureEvent) => this.onPanEnd(e)),
          PinchGesture({ fingers: 2, distance: 5 })
            .onActionStart((e: GestureEvent) => this.onPinchStart(e))
            .onActionUpdate((e: GestureEvent) => this.onPinchUpdate(e))
            .onActionEnd((e: GestureEvent) => this.onPinchEnd(e))
        )
      )

      // 工具栏
      Row({ space: 16 }) {
        SymbolGlyph($r('sys.symbol.arrow_2_circlepath'))
          .fontSize(22)
          .fontColor(['#333'])
          .scale({ x: this.rotateScale, y: this.rotateScale })
          .onClick(() => this.rotate90())
          .clickEffect(UiMotion.CLICK)

        Blank()

        Text('取消')
          .fontSize(13)
          .fontColor('#888')
          .padding({ left: 12, right: 12, top: 6, bottom: 6 })
          .borderRadius(14)
          .backgroundColor('rgba(0,0,0,0.06)')
          .scale({ x: this.cancelScale, y: this.cancelScale })
          .onClick(() => this.cancel())
          .clickEffect(UiMotion.CLICK)

        Text('完成')
          .fontSize(13)
          .fontWeight(600)
          .fontColor(Color.White)
          .padding({ left: 12, right: 12, top: 6, bottom: 6 })
          .borderRadius(14)
          .backgroundColor('#4A90D9')
          .scale({ x: this.confirmScale, y: this.confirmScale })
          .onClick(() => this.confirm())
          .clickEffect(UiMotion.CLICK)
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 8, bottom: 8 })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Center)
  }
}