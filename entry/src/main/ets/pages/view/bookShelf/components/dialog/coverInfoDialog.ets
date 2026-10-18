import { pickerAvatar } from '../../../../../common/utils/photoViewPicker'
import { Haptics } from '../../../../../common/utils/Haptics';
import { NightMode } from '../../../../../common/utils/NightMode'
import coverInfoImageShow from '../../../coverInfoImageShow'
import { BookGroups } from '../../../../../database/entities/BookGroups'
import { showMessage } from '../../../../../componets/common/promptShow'
import bookGroupUtil from '../../../../../common/utils/bookGroupUtils'
import booksDao from '../../../../../database/dao/BooksDao'
import BookGroupsDao from '../../../../../database/dao/BookGroupsDao'
import worksListsDao from '../../../../../database/dao/WorksListsDao'
import { Books } from '../../../../../database/entities/Books'
import { ThemeItem } from '../../../../../common/model/Theme'
import { ThemeStorageKey } from '../../../../../common/constants/Theme'
import ImmersiveMaterialUtil, { MaterialColumnModifier } from '../../../../../common/utils/ImmersiveMaterialUtil'
import UiMotion from '../../../../../common/utils/UiMotion'
import booksUtil from '../../../../../common/utils/booksUtils'
import TitleContentDialog from '../../../../../componets/common/TitleContentDialog'
import { COVER_DEFAULT_FILES, coverCorners } from '../../../../../common/utils/CoverSource'
import CommonConstants from '../../../../../common/constants/CommonConstants'
import bookCover from '../../../../../common/utils/BookCover'

@CustomDialog
/**
 * 封面弹窗（分组封面样式）
 *
 * 2026-10-01 改版（用户反馈）：
 * ① 修溢出：原来 3 个预览列挤一行，「默认样式」列还内嵌 9×26vp 缩略图行（≈282vp），
 *    必然横向溢出 ⇒ 预览收成两列（默认/自定义），9 张缩略图移到下方**全宽网格**
 *    （与单本 CoverStyleDialog 同款 5 列网格，选中即存 `default://` 协议）。
 * ② 删「全图样式」：与「自定义」共用同一选图器，渲染唯一差异是 BookOverlay
 *    `coverType !== 2` 的装饰叠层（BookOverlay.ets:37），重叠 ⇒ 删除；
 *    存量 coverType=2 的分组不受影响（渲染端判断保留）。
 * ③ 「仅用于当前分组」开关已删除（2026-10-01：coverOnly 字段全工程无渲染消费方，
 *    开关没有实际效果，用户确认移除）。
 * ④ 冲突弹窗（范围内单本手动封面 vs 批量封面，单本优先）确定时无条件检查；
 *    范围内**没有**手动封面时直接全部覆盖（封面真实写入每本书）。
 */
@Preview
export default struct coverInfoDialog{
  controller?: CustomDialogController

  /**
   * 弹窗背板（2026-09-21 接入沉浸光感）。底部面板、高度不大，
   * 不属官方点名的「接近全屏的超大面积」。用修饰器的原因见
   * `MaterialColumnModifier` 注释 —— 这行白底会把 Dialog 的**自动沉浸**挡掉。
   * 2026-10-01：第二参数补 `true` —— 调用方（FolderInfoDialog.coverDialog）options 里
   * 已给 `systemMaterial`，本层要**让出背景**把材质透出来；默认 false 会画白实底挡住
   * 材质（与工程其它弹窗同款写法，依据见 MaterialColumnModifier 构造注释）。
   */
  private surface: MaterialColumnModifier = new MaterialColumnModifier(Color.White, true)
  //推送提醒
  @Prop itemData:BookGroups
  @State coverImages:string = ''
  /** v3.21：默认样式网格选中项（0-based；-1=未选）；存量 default:// 反解 */
  @State pickDefault: number = -1
  /** 当前选中的样式单选（0=默认样式 1=自定义；驱动缩略图网格显隐） */
  @State selectedType: number = 0
  @StorageLink('BOOK_IS_BOOK_REFRESHING') isBookRefreshing: number = 0
  @StorageLink('BOOK_IS_BOOK_GROUPS_REFRESHING') BOOK_IS_BOOK_GROUPS_REFRESHING: number = 0
  cancel: () => void = () => {
  }
  aboutToAppear(): void {
    this.coverImages = this.itemData.coverUrl??''
    const cu: string = String(this.itemData.coverUrl ?? '')
    if (cu.startsWith('default://cover_defaults/c')) {
      const n = parseInt(cu.substring('default://cover_defaults/c'.length))
      this.pickDefault = n >= 1 && n <= 9 ? n - 1 : -1
    }
    // 2026-10-01：重进弹窗时按**当前封面值**还原选中态（coverUrl 是自定义图 ⇒ 自定义；
    // default:// 或空 ⇒ 默认样式）。原来只看 coverType，而确定路径已不写它 ⇒ 重进永远"默认样式"。
    if (cu !== '' && !cu.startsWith('default://')) {
      this.selectedType = 1
    } else {
      this.selectedType = 0
    }
  }
  // 主题颜色
  @StorageProp(ThemeStorageKey.THEME) theme: ThemeItem = {} as ThemeItem

  /**
   * 「自定义」预览列 —— 2026-10-18 **内联到本组件**，不再经 `coverInfoImageShow` 子组件。
   *
   * ── 为什么必须内联（真机日志证据，`docs/日志.md`）─────────────────────────
   * 选完图后日志里出现：
   *   `E AceStateMgmt: View coverInfoImageShow is already in process of destruction,
   *    will not execute observeComponentCreation2`
   * ⇒ 给子组件 `@Prop imageString` 赋进去的**新 URI 被丢弃**，
   *   预览位于是停在旧值/空值上，露出深色衬底 —— 用户看到的就是"灰色蒙版"。
   * 内联后预览直接读本组件的 `@State coverImages`，没有跨组件这一层，
   * 也就没有"子组件正在销毁"的窗口期。
   */
  @Builder customColumn() {
    Column() {
      Stack() {
        Flex({ alignItems: ItemAlign.End }) {
          // ⚠️⚠️ **必须用 `visibility` 而不是 `if`**（2026-10-18，与 CoverStyleDialog 同因）：
          //   选图回来后 `if` 分支翻转 ⇒ ArkUI 在组件销毁/重建窗口期创建 Image 被跳过
          //   （日志 `View coverInfoImageShow is already in process of destruction` 是同一回事），
          //   于是预览位停在空态、露出深色衬底 = 用户看到的"灰色蒙版"。
          //   常驻 + 切 visibility ⇒ 组件实例不重建，src 变化走正常的重新加载。
          Image(this.customPreviewSrc() === ''
            ? $rawfile(COVER_DEFAULT_FILES[0]) : this.customPreviewSrc())
            .draggable(false)
            .borderRadius(coverCorners(CommonConstants.NOVEL_IMG_WIDTH))
            .width(CommonConstants.NOVEL_IMG_WIDTH)
            .height(CommonConstants.NOVEL_IMG_HEIGHT)
            .visibility(this.customPreviewSrc() !== '' ? Visibility.Visible : Visibility.None)
          // 空态：浅色底 + 可见虚线框 + 图标（旧实现是深色衬底 + 黑字，用户说"像灰块套框"）
          Column({ space: 4 }) {
            SymbolGlyph($r('sys.symbol.picture'))
              .fontSize(20)
              .fontColor([$r('app.string.color_black_45')])
            Text('点击选择')
              .fontColor($r('app.string.color_black_45'))
              .fontWeight(400)
              .fontSize(12)
              .lineHeight(16)
          }
          .justifyContent(FlexAlign.Center)
          .width(CommonConstants.NOVEL_IMG_WIDTH)
          .height(CommonConstants.NOVEL_IMG_HEIGHT)
          .borderRadius(5)
          .backgroundColor('rgba(0, 0, 0, 0.03)')
          .border({ width: 1, color: 'rgba(0, 0, 0, 0.18)', style: BorderStyle.Dashed, radius: 5 })
          .visibility(this.customPreviewSrc() !== '' ? Visibility.None : Visibility.Visible)
        }
        .borderRadius(5)
        // 深色衬底只在**有图**时当画框；空态必须透明
        .backgroundColor(this.customPreviewSrc() !== '' ? $r('app.string.color_black_65') : Color.Transparent)
        .align(Alignment.Start)
        .width(CommonConstants.NOVEL_IMG_WIDTH)
        .height(CommonConstants.NOVEL_IMG_HEIGHT)
        .zIndex(2)
      }
      .align(Alignment.BottomStart)
      Row({ space: 12 }) {
        Text('自定义')
          .fontWeight(400)
          .fontSize(14)
          .fontColor($r('app.string.color_black_45'))
          .lineHeight(22)
        Radio({ value: JSON.stringify('1'), group: 'radioGroup' })
          .checked(this.selectedType === 1)
          .radioStyle({
            checkedBackgroundColor: this.theme.mainColor
          })
          .border({ width: 2, color: 'rgba(255, 255, 255, 0.10)' })
          .width(20).height(20)
          .onChange((val) => {
            // ⚠️ 这里**只切样式**，不拉起选图器：点单选框会冒泡到整列 `onClick`，
            //    两边都拉选图器会连开两次系统相册（改造前子组件的 onChange 也只切样式）。
            if (val) {
              this.pickDefault = -1
              this.selectedType = 1
            }
          })
      }
      .padding({ top: 8 })
    }
    .onClick((): void => {
      Haptics.tap()
      this.onSelectCustom()
    })
  }

  /** 选中「自定义」并拉起选图器（点预览列或单选框都会到这里） */
  private onSelectCustom(): void {
    this.pickDefault = -1
    this.selectedType = 1
    this.setCoverImages().catch((e: Error): void => {
      console.error('setCoverImages failed: ' + e.message)
    })
  }

  build() {
    Column(){
      Flex({
        justifyContent:FlexAlign.SpaceBetween,
        alignItems:ItemAlign.Center
      }){
        Column(){
          Text(this.itemData.groupName).fontColor(NightMode.isDarkSurface() ? 'rgba(248, 249, 250, 0.88)' : 'rgba(0, 0, 0, 0.88)').fontSize(16).fontWeight(500).lineHeight(24)
          Text(`共${0}本`).fontColor(NightMode.isDarkSurface() ? 'rgba(248, 249, 250, 0.45)' : 'rgba(0, 0, 0, 0.45)').fontWeight(400).lineHeight(20).fontSize(12)
        }
        // ── 批量「重置」（2026-10-13，用户要求）──────────────────────────────
        // 语义（用户口径）：范围内**每本书各自**恢复到自己"导入时的那张封面"——
        //   · 有自带封面的书 ⇒ 恢复为自带封面（清空 customCoverUrl 即可，自带封面是只读字段）
        //   · 没有自带封面的书（txt 等）⇒ 恢复为默认封面（同样只是清空 customCoverUrl）
        // 所以这是**一次清空、两种效果**，不需要按书分支写逻辑。
        // 符号名已核实：`sysResource.js` 中 `arrow_counterclockwise: 125832702`。
        Row({ space: 4 }) {
          SymbolGlyph($r('sys.symbol.arrow_counterclockwise'))
            .fontSize(15)
            .fontColor([NightMode.isDarkSurface() ? 'rgba(248, 249, 250, 0.88)' : 'rgba(0, 0, 0, 0.65)'])
          Text('重置')
            .fontSize(12)
            .fontColor(NightMode.isDarkSurface() ? 'rgba(248, 249, 250, 0.88)' : 'rgba(0, 0, 0, 0.65)')
        }
        .height(30)
        .padding({ left: 12, right: 12 })
        .borderRadius(15)
        .backgroundColor(NightMode.isDarkSurface() ? 'rgba(255, 255, 255, 0.12)' : 'rgba(0, 0, 0, 0.06)')
        .clickEffect(UiMotion.CLICK)
        .onClick((): void => {
          Haptics.tap()
          this.openResetConfirm()
        })
      }.padding(20)
      // （2026-10-01 已删除「仅用于当前分组」开关：coverOnly 字段全工程无渲染消费方，
      //  开关没有实际效果，用户确认删除。）
      Divider().strokeWidth(0.5)
      Flex({
        direction: FlexDirection.Row,
        justifyContent:FlexAlign.SpaceBetween
      }){
        coverInfoImageShow({
          coverCount:1,
          // 2026-10-01 修"左右两侧预览都是自定义图片"：默认样式预览只接受 default://
          // 协议或空（空时子组件落内置默认封面 c1），绝不能回退显示自定义图。
          image: String(this.itemData.coverUrl ?? '').startsWith('default://') ? (this.itemData.coverUrl ?? '') : '',
          selectImage:this.selectedType,
          pickDefault:this.pickDefault,
          onSelectImageNumber:(number:number)=>{
            this.selectedType = number
          },
          onPickDefault:(n:number)=>{
            // v3.21：网格选中 ⇒ 封面值 = 内置封面协议串；渲染端 BookOverlay 已支持
            this.itemData.coverUrl = 'default://cover_defaults/c' + (n + 1) + '.svg'
            this.pickDefault = n
          }
        })
        .onClick(()=>{
          Haptics.tap();
          // 2026-10-01 修"选自定义后返回默认样式，底部 9 宫格没了"：原来只有小 radio
          // 能切回默认样式，点预览列无响应 ⇒ selectedType 停在 1、网格一直隐藏。
          // 整列可点，点即切回默认样式（网格随之恢复）。
          this.selectedType = 0
        })
        this.customColumn()
        // 2026-10-18：整列可点 = 选「自定义」并拉起选图器（行为与改造前一致）
      }.padding({ left:20, right:20, top:16 })

      // ── 9 张默认封面网格（2026-10-01 从预览列移出为全宽，修横向溢出）────────────
      // ⚠️ 用 visibility 而不是 if（2026-10-01 修"默认→自定义→默认后缩略图丢失"）：
      // if 移除再重建 Grid 时，9 个 Image($rawfile) 重新创建会渲染失败（真机流程截图
      // 19:11：radio 已选回默认样式、区域高度还在但缩略图全白）；visibility 保住组件
      // 实例，图片不重解码，None 时也不占布局空间。
      Grid() {
        ForEach([1, 2, 3, 4, 5, 6, 7, 8, 9], (n: number) => {
          GridItem() {
            Column() {
              // $rawfile 传字面量表变量（见 CoverSource.COVER_DEFAULT_FILES 注释），防资源检查误报
              Image($rawfile(COVER_DEFAULT_FILES[n - 1]))
                .width(52).height(72)
                .borderRadius(6)
                .border({
                  width: this.pickDefault === n - 1 ? 2 : 0.5,
                  color: this.pickDefault === n - 1 ? this.theme.mainColor : 'rgba(0,0,0,0.12)'
                })
            }
            .onClick(() => {
              Haptics.tap();
              this.pickDefault = n - 1
              this.selectedType = 0
              // v3.21：网格选中 ⇒ 封面值 = 内置封面协议串；渲染端 BookOverlay 已支持
              this.itemData.coverUrl = 'default://cover_defaults/c' + n + '.svg'
            })
          }
        }, (n: number) => 'd' + n)
      }
      .columnsTemplate('1fr 1fr 1fr 1fr 1fr')
      .columnsGap(10)
      .rowsGap(10)
      .height(164)
      .width('100%')
      .padding({ left:20, right:20, top:12 })
      .visibility(this.selectedType === 0 ? Visibility.Visible : Visibility.None)

      Divider().strokeWidth(0.5).margin({top:16}).padding({bottom:16})
      Column(){
        Flex({
          justifyContent:FlexAlign.SpaceBetween
        }) {
          Column(){
            Text('取消').fontSize(16).fontWeight(400).fontColor(this.theme.mainColor)
              .lineHeight(24)
              .padding({left:32,right:32,bottom:8,top:8})
          }
          .onClick(()=>{
            Haptics.tap();
            // 先关自己再回调（父级 cancel 回调只负责"子退父进"，不负责关本弹窗）
            this.controller?.close()
            this.cancel()
          })
          .width('49%')
          .borderRadius(20)
          .alignItems(HorizontalAlign.Center)
          .backgroundColor(this.theme.secondColor)
          Column(){
            Text('确定')
              .fontSize(16)
              .fontWeight(400)
              .fontColor(Color.White)
              .lineHeight(24)
              .padding({left:32,right:32,bottom:8,top:8})
              .onClick(async ()=>{
                // v3.21 冲突提醒（用户设计）：批量封面与范围内"单本自定义封面"冲突时，
                // 用户手动选：保留手动（仅存设置）/ 全部覆盖（写入每本书）。
                // 2026-10-01 三入口统一管线（用户拍板）：
                //   「分组」聚合条目 = 所有自建分组的书（**不含未分组**）；
                //   「书单」聚合条目 = 所有书单内的书；
                //   「全部」聚合条目 = 全库书籍；
                //   普通分组 = 本组书籍。
                const coverUrlStr: string = String(this.itemData.coverUrl ?? '')
                const usesPic = (this.selectedType !== 0) ||
                  coverUrlStr.startsWith('default://')
                if (usesPic) {
                  const targetBooks = await this.resolveTargetBooks()
                  const customized = targetBooks.filter((b: Books) =>
                    (b.customCoverUrl ?? '') !== '')
                  if (customized.length > 0) {
                    this.conflictCount = customized.length
                    this.conflictDialog?.open()
                    return
                  }
                  // 2026-10-01 修"普通分组改封面没效果"：范围内没有手动封面时**直接全部
                  // 覆盖**（封面真实写入组内每本书）——原来到这里只落了分组设置、书籍没动，
                  // 用户实测"分组的封面变了，内容没变"。
                  await this.applyGroupCover(true)
                  return
                }
                await this.applyGroupCover(false)
              })
          }
          .width('49%')
          .borderRadius(20)
          .alignItems(HorizontalAlign.Center)
          .backgroundColor(this.theme.mainColor)
        }
      }
      .alignItems(HorizontalAlign.Center)
      .padding({right:20,left:20,bottom:16})
    }
    .borderRadius(20)
    .attributeModifier(this.surface)
    .width('100%')
  }

  /** v3.21：与范围内单本自定义封面冲突的书数（冲突弹窗文案用） */
  @State conflictCount: number = 0

  /**
   * 解析本次封面修改的**目标书籍范围**（2026-10-01 三入口统一管线，用户拍板）：
   * · 「分组」聚合条目（全部左侧、isSystem）→ 所有自建分组的书籍（**不含未分组**，
   *   用户定义："这个的逻辑就是统一管理所有已分组的分组内书籍"）；
   * · 「书单」聚合条目（isSystem）→ 所有书单内的书；
   * · 「全部」聚合条目（isSystem）→ 全库书籍；
   * · 普通分组 → 本组书籍（原行为）。
   */
  private async resolveTargetBooks(): Promise<Books[]> {
    const name: string = this.itemData.groupName ?? ''
    if (this.itemData.isSystem && name === '分组') {
      const groups: BookGroups[] = await BookGroupsDao.search()
      const gids: number[] = groups
        .filter((g: BookGroups) => !g.isSystem && g.groupId !== undefined)
        .map((g: BookGroups) => g.groupId as number)
      if (gids.length === 0) {
        return []
      }
      const ids = await booksDao.queryBooksByGroupId(gids)
      return ids.length > 0 ? await booksDao.getBookByIds(ids) : []
    }
    if (this.itemData.isSystem && name === '书单') {
      const lists = await worksListsDao.search()
      const ids: number[] = []
      for (const w of lists) {
        for (const wb of (w.worksBookList ?? [])) {
          if (wb.bookId !== undefined) {
            ids.push(wb.bookId)
          }
        }
      }
      return ids.length > 0 ? await booksDao.getBookByIds(ids) : []
    }
    if (this.itemData.isSystem && name === '全部') {
      return await booksDao.search()
    }
    const ids = await booksDao.queryBooksByGroupId([this.itemData.groupId ?? -1])
    return ids.length > 0 ? await booksDao.getBookByIds(ids) : []
  }

  /**
   * 应用封面（v3.21；2026-10-01 扩三入口）：
   * overwrite=false =「保留手动」——只保存本次设置（渲染端按 单本 > 批量 优先级取用）；
   * overwrite=true  =「全部覆盖」——把封面值写入目标范围内每本书的 customCoverUrl。
   * 刷新：BOOK_IS_BOOK_GROUPS_REFRESHING ⇒ 分组卡片重查（BookFolder @Watch）；
   * BOOK_IS_BOOK_REFRESHING ⇒ 书架书列表重查（覆盖改写了书行）。
   */
  private async applyGroupCover(overwrite: boolean): Promise<void> {
    if (overwrite) {
      const groupBooks: Books[] = await this.resolveTargetBooks()
      for (const b of groupBooks) {
        if ((b.customCoverUrl ?? '') === this.itemData.coverUrl) {
          continue
        }
        b.customCoverUrl = this.itemData.coverUrl
        await booksUtil.addBooks(b)
      }
      // 覆盖改写了书行 ⇒ 书架列表也要重查（LazyForEach 键值含 customCoverUrl）
      this.isBookRefreshing++
    }
    // await：工具层已补 await（bookGroupUtils.updatePartialGroup）⇒ 提交完成后才广播，
    // 避免"确定后刷新读到旧值"（与 BooksDao.insert 同款时序修复）
    await bookGroupUtil.updatePartialGroup(this.itemData)
    setTimeout(()=>{
      this.BOOK_IS_BOOK_GROUPS_REFRESHING++
      // 先关自己再回调父级（cancel ⇒ 子退父进，长按分组弹窗恢复）
      this.controller?.close()
      this.cancel()
      showMessage('修改成功!')
    },100)
  }

  /**
   * 冲突提醒弹窗（2026-10-01 从 confirmDialogExample 换 TitleContentDialog）：
   * ① confirmDialogExample 的 @Link delCache 传表达式真机 SyntaxError 闪退
   *    （2.md 17:50:36 崩溃报告，Kill Reason: Js Error）；
   * ② 旧弹窗文案固定"确定删除吗？"，语义完全不对；
   * ③ 语义：确认=全部覆盖；取消=保留手动封面并落库本次设置
   *    （旧实现取消只是关框，设置没存，用户得再走一遍确定⇒死循环）。
   */
  conflictDialog: CustomDialogController | null = new CustomDialogController({
    builder: TitleContentDialog({
      confirm: ()=> {
        this.conflictDialog?.close()
        this.applyGroupCover(true)
      },
      title:`要将封面覆盖到${this.conflictCount}本有手动封面的书`,
      content:'点「确认」= 全部覆盖（手动封面被替换）；点「取消」= 保留手动封面，仅保存本次设置',
      cancel: ()=> {
        this.conflictDialog?.close()
        this.applyGroupCover(false)
      }
    }),
    autoCancel: false,
    alignment: DialogAlignment.Center,
    gridCount: 4,
    customStyle: false,
    cornerRadius: 25,
    systemMaterial: ImmersiveMaterialUtil.sheetMaterial(),
    openAnimation: UiMotion.motionParam(UiMotion.SPRING_FAST),
    closeAnimation: UiMotion.motionParam(UiMotion.SPRING_FAST),
  })

  async setCoverImages(){
    // T13/D-18（Round 38）：`pickerAvatar()` 的返回契约从「整个 PhotoSelectResult」收敛为「URI 列表」，
    // 这样新旧两条实现才能共用同一签名（两者的 Result 类型不同、不可互相赋值）。
    // 行为与旧代码 `imageUrl?.photoUris[0] || ''` 完全等价：未选择 → `''`（即清空封面）。
    const uris: string[] = await pickerAvatar();
    if (uris.length === 0 || uris[0] === '') {
      this.coverImages = '';
      this.itemData.coverUrl = '';
      return
    }
    // ── 2026-10-13：相册 URI **先落地沙箱**再显示/落库 ──────────────────────
    // 修「点击并选择图片后预览图没有及时刷新」（真机）：`pickerAvatar()` 返回的是
    // 相册媒体 URI（SDK NOTE：can be used only by calling photoAccessHelper.getAssets），
    // 直接给 Image 首帧解码会失败。详见 `common/utils/BookCover.ets` 头注释。
    const local: string = await bookCover.importPickedImage(uris[0])
    this.coverImages = local;
    this.itemData.coverUrl = local
    // 诊断打点（2026-10-18）：选图后预览源到底是什么
    console.info('[coverInfo] pick done raw=' + uris[0]
      + ' local=' + local
      + ' preview=' + (this.customPreviewSrc() === '' ? '<EMPTY>' : this.customPreviewSrc()))
  }

  /** 自定义列预览只接受"真实图片"值（`default://…` 交给默认样式列显示） */
  private customPreviewSrc(): string {
    const v: string = this.coverImages
    if (v === '' || v.startsWith('default://')) {
      return ''
    }
    return v
  }

  // ── 批量「重置」：确认弹窗（2026-10-13）────────────────────────────────
  /**
   * 重置确认弹窗。
   *
   * 规范要点（用户 2026-10-13：「弹窗支持**子进父出**，以及适配全局弹窗的风格和逻辑」）：
   *  · 子进父出：`openResetConfirm()` 先关本弹窗再开它；
   *  · 取消 ⇒ 关它 + 把本弹窗开回来（入规则）；
   *  · 确认 ⇒ 执行重置，然后按本文件既有的收尾方式（关自己 + `cancel()`
   *    通知父级 + toast），与「确定」按钮的 `applyGroupCover` 完全同一条链。
   *  · 风格：`customStyle:false` + `systemMaterial` + SPRING_FAST（全局弹窗配方）。
   */
  private resetConfirmDialog: CustomDialogController | null = new CustomDialogController({
    builder: TitleContentDialog({
      title: '将范围内书籍的封面恢复为自带封面',
      content: '有自带封面的书恢复为自带封面；没有自带封面的书恢复为默认封面。手动设置的封面将被清除。',
      confirm: (): void => {
        this.resetGroupCover().catch((e: Error): void => {
          console.error('resetGroupCover failed: ' + e.message)
        })
      },
      cancel: (): void => {
        // 入规则：取消重置 ⇒ 把封面弹窗开回来
        this.controller?.open()
      }
    }),
    autoCancel: true,
    alignment: DialogAlignment.Center,
    gridCount: 4,
    customStyle: false,
    cornerRadius: 25,
    systemMaterial: ImmersiveMaterialUtil.sheetMaterial(),
    openAnimation: UiMotion.motionParam(UiMotion.SPRING_FAST),
    closeAnimation: UiMotion.motionParam(UiMotion.SPRING_FAST),
    cancel: (): void => {
      // 遮罩/返回键：与取消按钮同一条收尾路径
      this.controller?.open()
    }
  })

  private openResetConfirm(): void {
    // 子进父出：先关自己（关闭权在**持有 controller 的宿主**这一侧 —— 本弹窗的
    // controller 正是父级创建后传进来的那个，所以这里 close 有效）
    this.controller?.close()
    this.resetConfirmDialog?.open()
  }

  /**
   * 执行批量重置：范围内每本书清空 `customCoverUrl`。
   *
   * 为什么"一次清空"就能做到"分别恢复"（用户口径）：
   * 渲染优先级 `customCoverUrl > builtinCoverUrl > coverUrl > alt` ——
   * 清空自定义层后，有自带封面的书自动露出自带封面，没有的自动落到默认封面。
   */
  private async resetGroupCover(): Promise<void> {
    const targetBooks: Books[] = await this.resolveTargetBooks()
    let count: number = 0
    for (const b of targetBooks) {
      if ((b.customCoverUrl ?? '') !== '') {
        b.customCoverUrl = ''
        await booksUtil.addBooks(b)
        count++
      }
    }
    // 分组自身的封面（分组卡片上那张）也恢复默认；聚合条目（分组/书单/全部）没有实体分组，跳过
    if (!this.itemData.isSystem) {
      this.itemData.coverUrl = ''
      await bookGroupUtil.updatePartialGroup(this.itemData)
    }
    // 弹窗自身的选择态一并清掉
    this.pickDefault = -1
    this.selectedType = 0
    this.coverImages = ''
    // 书行被改写 ⇒ 书架列表重查（LazyForEach 键值含 customCoverUrl）
    this.isBookRefreshing++
    setTimeout((): void => {
      this.BOOK_IS_BOOK_GROUPS_REFRESHING++
      this.controller?.close()
      this.cancel()
      showMessage(count > 0 ? `已恢复 ${count} 本书的封面` : '封面已恢复')
    }, 100)
  }
}
