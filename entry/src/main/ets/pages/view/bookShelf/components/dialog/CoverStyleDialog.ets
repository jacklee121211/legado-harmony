import { Haptics } from '../../../../../common/utils/Haptics'
import UiMotion, { runJellyClick } from '../../../../../common/utils/UiMotion'
import { pickerAvatar } from '../../../../../common/utils/photoViewPicker'
import { showMessage } from '../../../../../componets/common/promptShow'
import { Books } from '../../../../../database/entities/Books'
import booksUtil from '../../../../../common/utils/booksUtils'
import { MaterialColumnModifier } from '../../../../../common/utils/ImmersiveMaterialUtil'
import { COVER_DEFAULT_FILES, defaultCoverIndex } from '../../../../../common/utils/CoverSource'

/**
 * 单本封面样式弹窗（v3.21，用户需求"自定义封面真实功能"）。
 *
 * ── 三类选择（与分组封面弹窗同语义）──────────────────────────────────────
 * ① 默认样式：内置 9 张装饰封面（rawfile/cover_defaults/c1~c9.svg，从
 *    colorLibrary 的 icon_book_default_cover_one~nine 拷贝），网格预览供选——
 *    参考阅读器-设置背景预览范式；存储协议 `default://cover_defaults/cN.svg`。
 * ② 自定义图片：pickerAvatar 选图（datashare:// URI 直接可被 Image 显示）。
 * 选中即保存到 `Books.customCoverUrl`（booksUtil.addBooks 同库），渲染端
 * （BookInfos/BookContent）优先级：customCoverUrl > coverUrl > 默认 alt。
 * `default://` 协议在渲染端转 `$rawfile(...)`（渲染端 helper：CoverSource.ets）。
 */

@CustomDialog
export default struct CoverStyleDialog {
  controller?: CustomDialogController
  @Prop bookData: Books
  onClose: () => void = (): void => {}
  private surface: MaterialColumnModifier = new MaterialColumnModifier(Color.White, true)
  /** 当前生效封面值（customCoverUrl 原值，可能是 default:// / datashare:// / file://） */
  @State currentCover: string = ''
  /** 选中高亮的网格 index（-1 = 未选默认，走自定义图） */
  @State pickedIndex: number = -1
  /** 自定义图 URI */
  @State customUri: string = ''
  @State saving: boolean = false
  /**
   * 书架刷新信号（2026-10-01 修"换封面必须重启才生效"）：保存成功后 ++，
   * `BookContent.isRefresh` 监听同一 key ⇒ 书架重查数据库。
   * ⚠️ 只广播还不够 —— LazyForEach 键值不含封面字段时照样复用旧组件，
   * 见 `BookContent.ets` 键值生成函数里的 `customCoverUrl`（两处必须同时存在）。
   */
  @StorageLink('BOOK_IS_BOOK_REFRESHING') isBookRefreshing: number = 0

  aboutToAppear(): void {
    const cur: string = this.bookData.customCoverUrl ?? ''
    this.currentCover = cur
    // 反解统一走 CoverSource.defaultCoverIndex（本文件原有一份重复实现已删）
    const idx: number = defaultCoverIndex(cur)
    this.pickedIndex = idx > 0 ? idx - 1 : -1
    if (idx <= 0 && cur !== '') {
      this.customUri = cur
    }
  }

  // （2026-10-01 已删除死方法 coverSource()：定义后从未被调用，且其 `$rawfile('cover_defaults/'
  //  ' + v.substring(...))` 拼接写法正是 IDE 资源检查误报「No such 'cover_defaults/' resource」
  //  的来源之一 —— 解析统一走 CoverSource（字面量表 + $rawfile 传变量，告警零噪音）。）
  /** 保存：写 customCoverUrl 落库（booksUtil.addBooks 走 BooksDao.updatePartial 同管线） */
  private save(): void {
    let value: string = ''
    if (this.pickedIndex >= 0) {
      // 存储协议值（运行时字符串拼接，非 $rawfile 参数 ⇒ 无资源检查问题）
      value = 'default://cover_defaults/c' + (this.pickedIndex + 1) + '.svg'
    } else if (this.customUri !== '') {
      value = this.customUri
    }
    if (value === (this.bookData.customCoverUrl ?? '')) {
      this.closeDialog()
      return
    }
    this.saving = true
    const b: Books = this.bookData
    b.customCoverUrl = value
    booksUtil.addBooks(b).then((): void => {
      this.saving = false
      // 广播书架刷新（依据见本字段注释；与删除/置顶同一条公共信号）
      this.isBookRefreshing++
      showMessage('封面已更新')
      this.closeDialog()
    }).catch((): void => {
      this.saving = false
      showMessage('保存失败')
    })
  }

  private closeDialog(): void {
    this.controller?.close()
    this.onClose()
  }

  build() {
    Column({ space: 12 }) {
      Text('封面样式')
        .fontSize(16).fontWeight(600)
        .fontColor($r('app.string.color_black_88'))
        .width('100%')

      // ── 9 张默认封面网格（参考阅读器背景预览范式）────────────────────────
      // ⚠️ $rawfile 传 COVER_DEFAULT_FILES 变量（完整路径字面量表，见 CoverSource 注释），
      //    不做字符串拼接 —— 拼接会触发 IDE 资源检查误报。
      Grid() {
        ForEach([1, 2, 3, 4, 5, 6, 7, 8, 9], (n: number) => {
          GridItem() {
            Column() {
              Image($rawfile(COVER_DEFAULT_FILES[n - 1]))
                .width(56).height(76)
                .borderRadius(6)
                .border({
                  width: this.pickedIndex === n - 1 ? 2 : 0.5,
                  color: this.pickedIndex === n - 1 ? '#0A84FF' : 'rgba(0,0,0,0.12)'
                })
            }
            .onClick(() => {
              Haptics.tap();
              this.pickedIndex = n - 1
              this.customUri = ''
            })
          }
        }, (n: number) => 'c' + n)
      }
      .columnsTemplate('1fr 1fr 1fr 1fr 1fr')
      .columnsGap(10)
      .rowsGap(10)
      .height(200)
      .width('100%')

      // ── 自定义图片 ──
      Row({ space: 10 }) {
        // 2026-10-01（用户）：文字精简为「自定义图片」防溢出（原"选自定义图片/已选图片 ✓"
        // 太长）；按钮升级质感：渐变材质底 + 白色外圈线条 + 同色系光圈阴影。
        // 渐变色标随选中态切换（蓝=未选 / 绿=已选），checkmark_circle 已在 SDK 符号表核实。
        Button() {
          Row({ space: 4 }) {
            Text('自定义图片')
            if (this.customUri !== '') {
              SymbolGlyph($r('sys.symbol.checkmark_circle'))
                .fontSize(15)
                .fontColor([Color.White])
            }
          }
        }
        .height(38)
        .linearGradient({
          angle: 135,
          colors: this.customUri !== ''
            ? [['#1E9E63', 0.0], ['#24B277', 0.55], ['#3ED598', 1.0]]
            : [['#0A6ED1', 0.0], ['#0A84FF', 0.55], ['#4DA8FF', 1.0]]
        })
        .borderRadius(19)
        .border({ width: 1, color: 'rgba(255, 255, 255, 0.45)' })
        .shadow({
          radius: 12,
          color: this.customUri !== '' ? 'rgba(36, 178, 119, 0.40)' : 'rgba(10, 132, 255, 0.40)',
          offsetX: 0,
          offsetY: 3
        })
        .fontColor(Color.White)
        .fontSize(13)
        .onClick(() => {
            Haptics.tap();
            pickerAvatar().then((uris: string[]): void => {
              if (uris.length > 0 && uris[0] !== '') {
                this.customUri = uris[0]
                this.pickedIndex = -1
              }
            })
          })
        if (this.customUri !== '' || (this.pickedIndex < 0 && this.currentCover !== '')) {
          Image(this.customUri !== '' ? this.customUri : this.currentCover)
            .width(38).height(52)
            .borderRadius(4)
            .objectFit(ImageFit.Cover)
        }
        Blank()
      }
      .width('100%')

      // ── 操作行 ──
      Row({ space: 10 }) {
        Button('取消')
          .layoutWeight(1)
          .height(42)
          .backgroundColor($r('app.string.color_black_65'))
          .fontColor(Color.White)
          .fontSize(15)
          .onClick(() => {
            Haptics.tap();
            this.closeDialog()
          })
        Button(this.saving ? '保存中…' : '确定')
          .layoutWeight(1)
          .height(42)
          .backgroundColor('#0A84FF')
          .fontColor(Color.White)
          .fontSize(15)
          .enabled(!this.saving)
          .onClick(() => {
            Haptics.tap();
            runJellyClick((_v: number) => {})
            this.save()
          })
      }
      .width('100%')
      .margin({ bottom: 6 })
    }
    .padding(20)
    .borderRadius(20)
    .attributeModifier(this.surface)
    .width('100%')
  }
}
