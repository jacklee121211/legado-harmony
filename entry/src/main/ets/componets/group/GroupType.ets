import BookGroupsDao from '../../database/dao/BookGroupsDao'
import { BookGroups } from '../../database/entities/BookGroups'
import BookType from '../head/BookType'
import { GroupManageDialog } from './GroupManageDialog'
import FolderInfoDialog from '../../pages/view/bookShelf/components/dialog/FolderInfoDialog'
import ImmersiveMaterialUtil from '../../common/utils/ImmersiveMaterialUtil'
import UiMotion, { runJellyClick } from '../../common/utils/UiMotion'
import { NightMode, ShelfColors } from '../../common/utils/NightMode'
// ── 全局震动反馈（2026-09-25 新增）────────────────────────────────────────────
import { Haptics } from '../../common/utils/Haptics'

/**
 * 分组管理弹窗「停在分组行下面」的位置修正量（vp，**唯一可调点**）。
 *
 * `offset.dy` 是按「弹窗可用区的顶边」算的（SDK `custom_dialog_controller.d.ts:105-115` 原文
 *   「Offset of the dialog box relative to the alignment position.」），
 * 而本行上报的 `shelfGroupRowBottom` 是**窗口坐标**（`units.d.ts:2110-2119`）。
 * 弹窗可用区按官方说明「excludes safe areas」（同文件 `:128`）⇒ 两者差一个顶部安全区，
 * 代码里已用 `AppStorage['topRectHeight']` 相减。
 *
 * ⚠️ 【待验证】这一处是**唯一无法在本机验证**的几何换算：真机上如果面板位置偏高/偏低，
 *   只改这个常量即可（正值往下、负值往上），不要改别的地方。
 */
const GROUP_PANEL_DY_FIX: number = 0

@Component
export default struct groupTypeComponent {
  @State globalPositionY: Length = 0
  /** 分组行尾部三横按钮的 Q弹缩放值（2026-09-25，`runJellyClick` 自驱 `.scale()`） */
  @State groupRowScale: number = 1

  /** 显示分组 chip 的**长按编辑**弹窗（2026-09-25 新增：与隐藏分组同款 FolderInfoDialog） */
  @State editChipGroup: BookGroups | null = null
  private chipEditDialog: CustomDialogController | null = null

  private openChipEditDialog(): void {
    if (this.editChipGroup === null) {
      return
    }
    this.chipEditDialog = new CustomDialogController({
      builder: FolderInfoDialog({
        itemData: this.editChipGroup,
        cancel: (): void => {
          this.chipEditDialog?.close()
          this.getGroupList()
        }
      }),
      autoCancel: true,
      width: '80%',
      alignment: DialogAlignment.Center,
      customStyle: false,
      cornerRadius: 20,
      systemMaterial: ImmersiveMaterialUtil.sheetMaterial(),
      openAnimation: UiMotion.motionParam(UiMotion.SPRING_FAST),
      closeAnimation: UiMotion.motionParam(UiMotion.SPRING_FAST),
    })
    this.chipEditDialog?.open()
  }
  /** App 级夜间开关：只为触发重绘（取色走 `ShelfColors`），理由见 `IndexShelf` 同名字段 */
  @StorageLink(NightMode.KEY) nightOn: boolean = false
  @Link @Watch('changeRefresh')currentIndex: number
  @Link groupCoverShow:boolean
  @Link GROUP:string
  @State groupList:BookGroups[] = []
  @Link bookTypeNumber:number
  @StorageLink('BOOK_IS_BOOK_GROUPS_REFRESHING') @Watch('changeRefresh')BOOK_IS_BOOK_GROUPS_REFRESHING: number = 0
  /**
   * 分组管理弹窗控制器。
   * ⚠️ **每次展开都新建**（`openGroupPanel()` 里 `new CustomDialogController`）：
   *   SDK `custom_dialog_controller.d.ts:756` NOTE 原文「Custom dialog box parameters
   *   **do not support dynamic updates**」⇒ 要传"当前大类 index / 当前分组列表 / 当前位置"
   *   就只能新建（同 `ReaderPage3.openCatalogDialog()`）。
   *   新建的代价是不能用 `$xxx`（`@Link` 语法在方法里会 `ReferenceError`），
   *   所以参数一律走普通 `@Prop` 的"打开瞬间快照" —— 这正好是本面板需要的语义。
   */
  private groupPanelDialog: CustomDialogController | null = null
  aboutToAppear(): void {
    this.getGroupList()
  }
  changeRefresh(){
    this.getGroupList()
  }
  getGroupList(){
    BookGroupsDao.search({
      type:this.currentIndex
    }).then((val)=>{
      this.groupList = val
    })
  }

  /**
   * 打开「分组管理」面板（`@CustomDialog`）。
   *
   * 位置：停在**分组行底边**下面。底边来自本行 `onAreaChange` 上报的
   * `shelfGroupRowBottom`（窗口坐标，见 build() 里的注释），这里减去顶部安全区。
   */
  private openGroupPanel(): void {
    this.groupCoverShow = true
    this.groupPanelDialog = new CustomDialogController({
      builder: GroupManageDialog({
        showGroupList: this.groupList,
        currentIndex: this.currentIndex,
        onClose: (): void => {
          this.closeGroupPanel()
        }
      }),
      autoCancel: true,
      // 2026-09-25 用户改版：不再顶到分组行下面（旧"整宽下拉面板"观感 —— 左右顶满屏幕、
      // 只有下两角圆），改成与全工程统一的**标准居中弹窗**：四圆角 20 + 90% 宽
      // （用户原话：「不是四圆角，左右太宽，顶屏幕了，宽度百分之90就行」）。
      alignment: DialogAlignment.Center,
      width: '90%',
      // 只有 `customStyle: false` 时弹窗层才有背景 ⇒ 材质才有处可附。
      // SDK `custom_dialog_controller.d.ts:130-134` 原文：`customStyle: true` 时
      // 「the rounded corner radius is 0, and **the background color is transparent**」
      // ⇒ 材质无处附着（本工程 2026-09-22 真机踩过：弹窗整个变透明）。
      customStyle: false,
      cornerRadius: 20,
      // 真沉浸光感材质（官方「开启沉浸光感」把 CustomDialog 列在弹窗类里）
      systemMaterial: ImmersiveMaterialUtil.sheetMaterial(),
      // ── 展开动画（用户点名「其次没有展开动画」）────────────────────────────
      // SDK `custom_dialog_controller.d.ts:205/226`：`openAnimation?` / `closeAnimation?: AnimateParam`
      // ⚠️ 官方 NOTE（同文件 `:37-38`）原文：「During animation playback, the page **does not
      //   respond to touch, swipe, or click interactions**」⇒ 弹窗动效要短 ⇒ 用 `SPRING_FAST`。
      openAnimation: UiMotion.motionParam(UiMotion.SPRING_FAST),
      closeAnimation: UiMotion.motionParam(UiMotion.SPRING_FAST),
      cancel: (): void => {
        // 点遮罩 / 返回手势关掉：同步标志位（本行不依赖它渲染，只作状态镜像）
        this.groupCoverShow = false
      },
    })
    this.groupPanelDialog.open()
  }

  /** 关面板（面板里的 ✕ 按钮走这里） */
  private closeGroupPanel(): void {
    this.groupCoverShow = false
    this.groupPanelDialog?.close()
  }

  build() {
    // ── 2026-09-23 结构简化（用户：「点击展开分组管理…首先这个模块没有沉浸光感材质，
    //    也就是 CustomDialog，其次没有展开动画」）────────────────────────────────
    // 原来这里是 `if (this.groupCoverShow) { Stack{ 面板 + 手画 Rect 遮罩 } } else { 本行 }`：
    //   · 遮罩是手画的 `Rect().fill('rgba(0, 0, 0, 0.45)')`，材质一点没有（面板根节点写死白底）；
    //   · 展开是纯 `if`，**没有任何 `.transition()`** ⇒ 硬切。
    // ⇒ 现在展开的面板搬进 `@CustomDialog`（`GroupManageDialog`），三样一块到位：
    //   真材质（弹窗 options 的 `systemMaterial`）+ 默认遮罩（`0x33000000`）+ 弹簧展开动画。
    //   本行**始终渲染**（不再被面板顶掉），`groupCoverShow` 退化为"面板是否打开"的镜像标志。
    Flex(
      {
        alignItems: ItemAlign.Center,
        justifyContent: FlexAlign.SpaceBetween
      }
    ) {
      Scroll() {
        Row({ space: 10 }) {
          ForEach(this.groupList,(item:BookGroups)=>{
            if (item.show) {
              BookType({ title: item.groupName,
                index:item.groupId,
                bookTypeNumber:this.bookTypeNumber
              }).onClick(() => {
                Haptics.tap();
                if (item.groupName === '分组') {
                  this.GROUP = '文件夹'
                } else {
                  this.GROUP = '标签'
                }
                if (item.groupId){
                  this.bookTypeNumber = item.groupId
                }
                })
                // 2026-09-25 用户反馈：显示分组也要能长按编辑（原来只有管理面板里的能长按）
                .gesture(LongPressGesture({ repeat: false, duration: 500 })
                  .onAction(() => {
                    Haptics.tap();
                    this.editChipGroup = item
                    this.openChipEditDialog()
                  }))
              }
            }, (item: BookGroups): string => item.groupId !== undefined ? 'g' + item.groupId : item.groupName)
          }
        }
        .scrollBar(BarState.Off)
        .scrollable(ScrollDirection.Horizontal)
        Row(){
          // ── 分组行尾部按钮（2026-09-25 换 SymbolGlyph；点击 Q弹缩放见 runJellyClick）──
          // 原 `app.media.more_search`（三横 SVG）→ `sys.symbol.line_3_horizontal`
          // （SDK 符号表 `…\Sdk\23\previewer\common\resources\entry\resources.txt` 查得，
          // 语义就是"三横线"，与原图标形状一致）。
          SymbolGlyph($r('sys.symbol.line_3_horizontal'))
            .fontSize(24)
            .fontColor([ShelfColors.icon()])
            .scale({ x: this.groupRowScale, y: this.groupRowScale })
            .onClick(()=>{
              Haptics.tap();
              runJellyClick((v: number) => {
                this.groupRowScale = v
              })
              // 2026-09-23：不再是"置标志位让本组件换渲染"，而是**开一个 @CustomDialog**
              this.openGroupPanel()
            })
            .clickEffect(UiMotion.CLICK)
        }.width(
          '10%'
        )
      }.margin({ left: 15, right: 15, bottom: 10})
        // ── 2026-09-23「书架顶部向沉浸光感看齐」（用户选 A：调到最像）──────────────
        // 「分组 / 全部 / 未分组 / 本地」这一栏：自绘内容拿不到真材质（官方生效范围见
        // `IndexShelf` 顶部同款注释）⇒ 通用属性模拟，取值与阅读页胶囊一致。
        .backgroundColor(ShelfColors.surface())
        .backgroundBlurStyle(BlurStyle.COMPONENT_ULTRA_THICK)
        .borderRadius(20)
        .padding({ left: 12, right: 12, top: 6, bottom: 6 })
        // ★ 2026-09-23 用户反馈：「这一行下面没空间，和下面的书籍叠加了」。
        //   本栏与书籍列表是同一个 Stack 里的两层（本栏 zIndex 999 浮在上面）
        //   ⇒ 把**实测高度**上报，由 `BookBodyContent` 给列表让位（不写死数字）。
        .onAreaChange((_o: Area, n: Area) => {
          AppStorage.setOrCreate('shelfGroupRowH', Number(n.height))
          // ★ 2026-09-23 新增：把本行的**窗口坐标底边**也上报 —— 分组管理弹窗要停在它下面。
          //   `Area.globalPosition` 依据（SDK `component/units.d.ts:2110-2119`）原文：
          //     「Position of the top-left corner of the target element in the **current window
          //       coordinate system**.」（单位 vp）
          //   弹窗侧用它算 `offset.dy`（见 `openGroupPanel()`）。
          AppStorage.setOrCreate('shelfGroupRowBottom', Number(n.globalPosition.y) + Number(n.height))
        })
  }
}
