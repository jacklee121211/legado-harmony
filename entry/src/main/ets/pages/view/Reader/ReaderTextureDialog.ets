/**
 * 「更多材质」弹窗（2026-09-25 新增，用户设计）。
 *
 * ── 需求原文 ──────────────────────────────────────────────────────────────
 * 「将会引入大批量材质…只要在 rawfile 目录下名字叫做 texture_xxx.jpg 的文件，都编译，
 *   只是**前八个**进入设置主页，**其他的在更多里面**。」
 * ⇒ 列表来自 `ReaderTexture.items()` 的**运行时动态枚举**（`getRawFileListSync('')`，
 *   失败回落顺序探测）：往 rawfile 里丢 `texture_009.jpg`、`texture_010.jpg`…
 *   即自动出现在这里，零代码改动。主页只展示前 8 个，本弹窗展示**全部**。
 *
 * ── 交互 ──────────────────────────────────────────────────────────────────
 * 点任一材质 = 选中并立即应用（回调页面 `pickTexture`，与主页材质格同一入口），
 * 然后本弹窗自关。当前正在用的材质画橙圈。
 *
 * 弹窗配方与目录/定时弹窗同款：`systemMaterial` 沉浸光感 + 弹簧出入场
 * （controller 由页面每次新建，参数不支持动态更新）。
 */
import { common } from '@kit.AbilityKit'
import { photoAccessHelper } from '@kit.MediaLibraryKit'
import { ReaderTexture, TextureItem, CustomTex } from '../../../common/utils/ReaderTexture'
import { Haptics } from '../../../common/utils/Haptics'
import UiMotion from '../../../common/utils/UiMotion'

@CustomDialog
export struct ReaderTextureDialog {
  controller?: CustomDialogController

  /** 当前正在使用的材质编号（0 = 无），画选中圈用 */
  @Prop currentId: number = 0

  /** 选中回调：页面侧 `pickTexture(id)` 应用材质；本弹窗随后自关 */
  onPick: (id: number) => void = (): void => {}

  /**
   * 关闭回调（2026-09-26 弹窗协调）：完成/选中后由**页面**关本弹窗并恢复父弹窗
   * （设置面板）—— 弹窗内 controller?.close() 曾失灵（见页面侧注释），关闭权在页面。
   */
  onClose: () => void = (): void => {}

  // ── 自定义背景（2026-09-27）：+ 导入（单次 ≤15）→ 排在内置材质之前，X 删除 ──
  /** 当前应用中的自定义背景 id（'' = 无），画选中圈 + 删除保护 */
  @Prop currentCustomId: string = ''

  /** 点选自定义背景回调：页面侧 `pickCustom(id)` 应用；本弹窗随后自关 */
  onPickCustom: (id: string) => void = (): void => {}

  /** 库变化回调（导入/删除后页面刷新色板与状态） */
  onChanged: () => void = (): void => {}

  @State customs: CustomTex[] = []

  /** 0 = 夜间，1 = 日间（与 `ReaderPage3.colorMode` 同义，随 AppStorage 同步） */
  @StorageLink('readerColorMode') colorMode: number = 1

  /** 全部材质（aboutToAppear 时一次性枚举；弹窗每次打开都新建 ⇒ 无需响应增量） */
  private items: TextureItem[] = []

  aboutToAppear(): void {
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext
    this.items = ReaderTexture.items(ctx)
    this.customs = ReaderTexture.customItems(ctx)
  }

  private refreshLists(): void {
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext
    this.customs = ReaderTexture.customItems(ctx)
    this.onChanged()
  }

  /** 图库选图（单次 ≤15 张）→ 逐张拷入沙箱并登记 → 刷新 + 通知页面 */
  private importCustom(): void {
    const picker = new photoAccessHelper.PhotoViewPicker()
    const opts: photoAccessHelper.PhotoSelectOptions = new photoAccessHelper.PhotoSelectOptions()
    opts.MIMEType = photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE
    opts.maxSelectNumber = ReaderTexture.MAX_CUSTOM_ONCE
    picker.select(opts).then((result: photoAccessHelper.PhotoSelectResult) => {
      const uris: string[] = result.photoUris
      if (uris.length === 0) {
        return
      }
      const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext
      let ok: number = 0
      let fail: number = 0
      const next = (i: number): void => {
        if (i >= uris.length) {
          this.refreshLists()
          if (fail === 0) {
            this.toast(`已添加 ${ok} 张自定义背景`)
          } else {
            this.toast(`添加 ${ok} 张，失败 ${fail} 张（仅支持 jpg/png）`)
          }
          return
        }
        ReaderTexture.addCustomTex(ctx, uris[i]).then((item: CustomTex | null) => {
          if (item === null) {
            fail++
          } else {
            ok++
          }
          next(i + 1)
        })
      }
      next(0)
    }).catch((): void => {
      // 用户取消选择，不提示
    })
  }

  private toast(m: string): void {
    this.getUIContext().getPromptAction().showToast({ message: m, duration: 1500 })
  }

  private askDeleteCustom(item: CustomTex): void {
    if (item.id === this.currentCustomId) {
      this.toast('正在使用中，请先换成其他背景')
      return
    }
    this.getUIContext().showAlertDialog({
      message: '删除这张自定义背景？图片与登记将一并移除。',
      autoCancel: true,
      alignment: DialogAlignment.Center,
      primaryButton: {
        value: '取消',
        action: (): void => {}
      },
      secondaryButton: {
        value: '删除',
        fontColor: '#E5310A',
        action: (): void => {
          Haptics.tap();
          const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext
          ReaderTexture.removeCustomTex(ctx, item.id)
          this.refreshLists()
          this.toast('已删除')
        }
      }
    })
  }

  /** 三位编号文案（texture_001 ⇒ "001"，与用户定的命名规则一致） */
  private label(id: number): string {
    return id < 10 ? '00' + id : (id < 100 ? '0' + id : '' + id)
  }

  build() {
    Column({ space: 12 }) {
      // 顶栏：标题 + 完成
      Row() {
        Text('更多材质')
          .fontSize(16)
          .fontWeight(600)
          .fontColor(this.colorMode == 0 ? 'rgba(248, 249, 250, 1)' : 'rgba(19, 19, 19, 1.00)')
        Blank()
        Text('完成')
          .fontSize(15)
          .fontColor('#007DFF')
          .onClick(() => {
            Haptics.tap();
            this.onClose()
          })
      }
      .width('100%')

      // 材质网格：四列、纵向滚动（大批量也装得下）
      Grid() {
        // ── 第 1 格：「+」添加自定义背景（2026-09-27 用户设计，样式与材质格一致）──
        GridItem() {
          Column() {
            SymbolGlyph($r('sys.symbol.plus'))
              .fontSize(26)
              .fontColor([this.colorMode == 0 ? 'rgba(248, 249, 250, 0.8)' : 'rgba(19, 19, 19, 0.55)'])
          }
          .width('100%')
          .height(84)
          .justifyContent(FlexAlign.Center)
          .borderRadius(12)
          .borderWidth(1)
          .borderColor(this.colorMode == 0 ? 'rgba(248, 249, 250, 0.30)' : 'rgba(0, 0, 0, 0.20)')
          .onClick(() => {
            Haptics.tap();
            this.importCustom()
          })
          .clickEffect(UiMotion.CLICK)
        }

        // ── 自定义背景：排在所有内置材质之前（用户设计："默认的之前"），右上角 X 删除 ──
        ForEach(this.customs, (item: CustomTex) => {
          GridItem() {
            Stack({ alignContent: Alignment.TopEnd }) {
              Column()
                .width('100%')
                .height(84)
                .borderRadius(12)
                .backgroundImage('file://' + item.path)
                .backgroundImagePosition(Alignment.Center)
                .backgroundImageSize(ImageSize.Cover)
                .borderWidth(this.currentCustomId === item.id ? 2 : 1)
                .borderColor(this.currentCustomId === item.id
                  ? '#ff6600'
                  : (this.colorMode == 0 ? 'rgba(248, 249, 250, 0.30)' : 'rgba(0, 0, 0, 0.20)'))
              Text('×')
                .fontSize(12)
                .fontWeight(600)
                .fontColor('#FFFFFF')
                .width(18)
                .height(18)
                .textAlign(TextAlign.Center)
                .borderRadius(9)
                .backgroundColor('rgba(0, 0, 0, 0.55)')
                .margin({ right: 4, top: 4 })
                .onClick(() => {
                  Haptics.tap();
                  this.askDeleteCustom(item)
                })
            }
            .width('100%')
            .onClick(() => {
              Haptics.tap();
              this.onPickCustom(item.id)
              this.onClose()
            })
            .clickEffect(UiMotion.CLICK)
          }
        }, (item: CustomTex): string => 'cu-' + item.id)

        ForEach(this.items, (item: TextureItem) => {
          GridItem() {
            Stack({ alignContent: Alignment.BottomEnd }) {
              Column()
                .width('100%')
                .height(84)
                .borderRadius(12)
                // ⚠️ Resource 走 ReaderTexture.res() 缓存（每次 new 会让 Image 反复解码）
                .backgroundImage(ReaderTexture.res(item.file))
                .backgroundImagePosition(Alignment.Center)
                .backgroundImageSize(ImageSize.Cover)
                .borderWidth(this.currentId === item.id ? 2 : 1)
                .borderColor(this.currentId === item.id
                  ? '#ff6600'
                  : (this.colorMode == 0 ? 'rgba(248, 249, 250, 0.30)' : 'rgba(0, 0, 0, 0.20)'))
              // 编号角标（三位，与命名规则一致）
              Text(this.label(item.id))
                .fontSize(10)
                .fontColor('#FFFFFF')
                .padding({ left: 5, right: 5, top: 1, bottom: 1 })
                .borderRadius(6)
                .backgroundColor('rgba(0, 0, 0, 0.55)')
                .margin({ right: 4, bottom: 4 })
            }
            .width('100%')
            .onClick(() => {
              Haptics.tap();
              this.onPick(item.id)
              this.onClose()
            })
            .clickEffect(UiMotion.CLICK)
          }
        }, (item: TextureItem): string => 'tex-' + item.id)
      }
      .columnsTemplate('1fr 1fr 1fr 1fr')
      .columnsGap(10)
      .rowsGap(10)
      .height(360)
      .width('100%')
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .padding(20)
  }
}
