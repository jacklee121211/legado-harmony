import { Haptics } from '../../../../../common/utils/Haptics'
import UiMotion, { runJellyClick } from '../../../../../common/utils/UiMotion'
import { pickerAvatar } from '../../../../../common/utils/photoViewPicker'
import { showMessage } from '../../../../../componets/common/promptShow'
import { Books } from '../../../../../database/entities/Books'
import booksUtil from '../../../../../common/utils/booksUtils'
import booksDao from '../../../../../database/dao/BooksDao'
import { MaterialColumnModifier } from '../../../../../common/utils/ImmersiveMaterialUtil'
import { COVER_DEFAULT_FILES, defaultCoverIndex, coverPathToUri } from '../../../../../common/utils/CoverSource'
import bookCover from '../../../../../common/utils/BookCover'

/**
 * 单本封面样式弹窗（v3.21，用户需求"自定义封面真实功能"）。
 *
 * ── 三类选择（与分组封面弹窗同语义）──────────────────────────────────────
 * ① 默认样式：内置 9 张装饰封面（rawfile/cover_defaults/c1~c9.svg，从
 *    colorLibrary 的 icon_book_default_cover_one~nine 拷贝），网格预览供选——
 *    参考阅读器-设置背景预览范式；存储协议 `default://cover_defaults/cN.svg`。
 * ② 自定义图片：pickerAvatar 选图后**立刻拷进沙箱**再显示（见下）。
 * ③ **自带封面**（2026-10-13，方案 C）：导入时从书籍文件里提取的封面
 *    （`Books.builtinCoverUrl`，存沙箱**路径**）。它不是"自定义封面"——
 *    用户不可直接改它，只通过「重置」把 ② / ① 清掉后"露出来"。
 *
 * ── 为什么选图后要落地沙箱（2026-10-13 真机问题修复）──────────────────────
 * 用户原话：「点击自定义图片之后，该按钮右侧**没有马上出现预览图**，没有被
 * 及时更新，第二次进入才能看到」。根因是 `pickerAvatar()` 返回的是**相册媒体
 * URI** —— SDK 原文 NOTE「can be used only by calling photoAccessHelper.getAssets」，
 * 直接丢给 `Image` 首帧解码会失败（第二次进入时才能加载）。
 * 官方 FAQ `faqs-arkui-154` 也要求走沙箱 URI。
 * ⇒ 现在选完立刻 `bookCover.importPickedImage()`（拷贝到 `filesDir/covers/`）
 * 再显示/落库：预览即时生效，且不会因相册授权变化而失效。
 *
 * ── 存储契约（唯一真源见 `common/utils/CoverSource.ets` 头注释）──────────
 * 写入 `Books.customCoverUrl`；渲染优先级
 * `customCoverUrl > builtinCoverUrl > coverUrl > alt`。
 */

@CustomDialog
export default struct CoverStyleDialog {
  controller?: CustomDialogController
  @Prop bookData: Books
  onClose: () => void = (): void => {}
  private surface: MaterialColumnModifier = new MaterialColumnModifier(Color.White, true)
  /** 当前生效封面值（customCoverUrl 原值，可能是 default:// / datashare:// / file://） */
  @State currentCover: string = ''
  /** 自带封面的可显示源（沙箱 URI；'' = 这本书没有自带封面，如 txt） */
  /**
   * 自带封面的可显示源。
   *
   * ⚠️ 2026-10-18：**不再缓存到 `@State`**，每次现算。
   * 真机问题：第一次（同一次弹窗会话内）点「重置」能看到自带封面预览，
   * 完全关闭再进入后点「重置」就没有预览了 —— 说明缓存值与实例生命周期绑死了。
   * 现算 `bookData.builtinCoverUrl → fileUri.getUriFromPath()` 是纯同步字符串运算，
   * 没有时序依赖，弹窗什么时候打开都拿得到。
   */
  private builtinSrc(): string {
    return coverPathToUri(this.bookData.builtinCoverUrl ?? '')
  }
  /**
   * 是否已请求「恢复自带封面」（**只是本地状态**，点「确定」才落库）。
   * 语义：清空 `customCoverUrl` ⇒ 渲染端自动露出 `builtinCoverUrl`（无则回落默认封面）。
   */
  @State resetRequested: boolean = false
  /** 选中高亮的网格 index（-1 = 未选默认，走自定义图/自带封面） */
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
    // ⚠️ 只有 `customCoverUrl` 才能喂 `customUri`：绝不能把自带封面写进来，
    //    否则点「确定」会把自带封面存成"用户自定义封面"，`重置` 就永久失效了。
    if (idx <= 0 && cur !== '') {
      this.customUri = cur
    }
    this.logState('open')
    // ── 自带封面缺失时**从数据库自愈**（2026-10-18）────────────────────────
    // 弹窗拿到的 `bookData` 是 `@Prop` 快照（`BookInfoDialogs` 那份是创建瞬间的拷贝），
    // 快照里若没有 `builtinCoverUrl`，"重置"就无从显示自带封面。
    // 这里补一次按 id 的回查 —— 只在字段为空时发生，一次查询，代价可忽略。
    if ((this.bookData.builtinCoverUrl ?? '') === '' && this.bookData.id !== undefined) {
      const id: number = this.bookData.id
      booksDao.getBookByIds([id]).then((rows: Books[]): void => {
        if (rows.length > 0) {
          const path: string = rows[0].builtinCoverUrl ?? ''
          if (path !== '') {
            this.bookData.builtinCoverUrl = path
            console.info('[CoverStyleDialog] builtinPath recovered from db id=' + id)
          }
        }
      }).catch((e: Error): void => {
        console.error('[CoverStyleDialog] recover builtinPath failed: ' + e.message)
      })
    }
  }

  /** 诊断打点（2026-10-18）：自带封面预览依赖 `builtinCoverUrl`，把三态一次打全 */
  private logState(tag: string): void {
    const path: string = this.bookData.builtinCoverUrl ?? ''
    const uri: string = this.builtinSrc()
    console.info('[CoverStyleDialog] ' + tag + ' id=' + (this.bookData.id ?? -1)
      + ' custom=' + ((this.bookData.customCoverUrl ?? '') === '' ? '<empty>' : (this.bookData.customCoverUrl ?? ''))
      + ' builtinPath=' + (path === '' ? '<empty>' : path)
      + ' builtinUri=' + (uri === '' ? '<empty>' : uri))
  }

  // （2026-10-01 已删除死方法 coverSource()：定义后从未被调用，且其 `$rawfile('cover_defaults/'
  //  ' + v.substring(...))` 拼接写法正是 IDE 资源检查误报「No such 'cover_defaults/' resource」
  //  的来源之一 —— 解析统一走 CoverSource（字面量表 + $rawfile 传变量，告警零噪音）。）

  /** 「自定义封面位」当前应显示的图：重置中 ⇒ 自带；否则 自定义图 > 当前值 > 自带 */
  private previewSrc(): string {
    if (this.resetRequested) {
      return this.builtinSrc()
    }
    if (this.customUri !== '') {
      return this.customUri
    }
    if (this.currentCover !== '') {
      return this.currentCover
    }
    return this.builtinSrc()
  }

  /** 是否有可显示的自定义位预览 */
  private hasPreview(): boolean {
    return this.previewSrc() !== ''
  }

  /** 是否显示「重置」：**被改动过**才显示（未改动时没有"要撤掉的封面"，按钮无意义） */
  private canReset(): boolean {
    return (this.bookData.customCoverUrl ?? '') !== '' || this.resetRequested
  }

  /**
   * 重置 = 请求"恢复自带封面"。
   * **不关弹窗**（用户 2026-10-13 明确要求）：只把本地选择清空、预览位切回自带封面，
   * 真正落库仍走「确定」⇒ 中途点「取消」不会误改数据。
   */
  private onResetTap(): void {
    Haptics.tap()
    this.resetRequested = true
    this.pickedIndex = -1
    this.customUri = ''
    // 诊断打点（2026-10-18）：重置那一刻预览到底解析成了什么
    this.logState('reset')
    console.info('[CoverStyleDialog] reset preview=' + (this.previewSrc() === '' ? '<empty>' : this.previewSrc()))
  }

  /** 保存：写 customCoverUrl 落库（booksUtil.addBooks 走 BooksDao 同管线） */
  private save(): void {
    let value: string = ''
    if (this.resetRequested) {
      // 恢复自带封面 = 清空自定义封面（自带封面是只读字段，不在这里写）
      value = ''
    } else if (this.pickedIndex >= 0) {
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
      showMessage(this.resetRequested ? '已恢复自带封面' : '封面已更新')
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
      // ── 标题行 + 「重置」symbol 按钮（2026-10-13）──────────────────────────
      // 规范 §1.2 手写三件套：SymbolGlyph + Haptics.tap() + clickEffect。
      // 符号名已核实：`sdk\default\openharmony\ets\build-tools\ets-loader\sysResource.js`
      //   `arrow_counterclockwise: 125832702`（同表的 `arrow_clockwise: 125831551` 亦可选）。
      Row() {
        Text('封面样式')
          .fontSize(16).fontWeight(600)
          .fontColor($r('app.string.color_black_88'))
        Blank()
        if (this.canReset()) {
          Row({ space: 4 }) {
            SymbolGlyph($r('sys.symbol.arrow_counterclockwise'))
              .fontSize(15)
              .fontColor([this.resetRequested ? Color.White : $r('app.string.color_black_65')])
            Text('重置')
              .fontSize(12)
              .fontColor(this.resetRequested ? Color.White : $r('app.string.color_black_65'))
          }
          .height(30)
          .padding({ left: 12, right: 12 })
          .borderRadius(15)
          .backgroundColor(this.resetRequested ? '#0A84FF' : 'rgba(0, 0, 0, 0.06)')
          .clickEffect(UiMotion.CLICK)
          .onClick((): void => {
            this.onResetTap()
          })
        }
      }
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
              // 选了默认样式就不再是"恢复自带封面"
              this.resetRequested = false
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
                // 2026-10-13 修「选完图预览位不刷新」：相册 URI 先落地沙箱再显示。
                // `importPickedImage` 失败会自动回退原始 URI（= 旧行为），不会更差。
                bookCover.importPickedImage(uris[0]).then((local: string): void => {
                  this.customUri = local
                  this.pickedIndex = -1
                  this.resetRequested = false
                })
              }
            })
          })
        // ── 自定义位预览（2026-10-13 起也承担"自带封面"的展示）──────────────
        // ⚠️⚠️ **必须用 `visibility` 而不是 `if`**（2026-10-18 真机复现，第 3 次才定死）
        //   `if` 分支在"点重置"这一刻翻转 ⇒ ArkUI 在**弹窗组件正在销毁/重建的窗口期**
        //   创建 Image，直接跳过创建（日志两条铁证）：
        //     `[CoverStyleDialog] reset preview=file://…蜘蛛_-_十宗罪.epub.jpg`   ← 值是对的
        //     `E AceStateMgmt: View CoverStyleDialog is already in process of destruction,
        //      will not execute observeComponentCreation2`                      ← 创建被跳过
        //   并且整段时间**没有任何 `AceImage load image`** ⇒ 预览位永远空白。
        //   工程内已有同款教训：`coverInfoDialog.ets` 的 9 宫格
        //   （2026-10-01「默认→自定义→默认后缩略图丢失」）就是改用 visibility 修好的。
        //   ⇒ 这里 Image / 角标**常驻**，只切 visibility：组件实例不重建，就不会被跳过。
        Stack() {
          // src 永远给有效值（空时用内置 c1 兜底），避免出现 `Image('')`
          Image(this.previewSrc() === '' ? $rawfile(COVER_DEFAULT_FILES[0]) : this.previewSrc())
            .width(38).height(52)
            .borderRadius(4)
            .objectFit(ImageFit.Cover)
          Text('自带')
            .fontSize(8)
            .fontColor(Color.White)
            .padding({ left: 3, right: 3, top: 1, bottom: 1 })
            .backgroundColor('#0A84FF')
            .borderRadius(3)
            .align(Alignment.BottomEnd)
            .margin({ right: 2, bottom: 2 })
            .visibility(this.resetRequested ? Visibility.Visible : Visibility.None)
        }
        .width(38).height(52)
        .borderRadius(4)
        .border({ width: this.resetRequested ? 2 : 0, color: '#0A84FF' })
        .visibility(this.pickedIndex < 0 && this.hasPreview() ? Visibility.Visible : Visibility.None)
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
