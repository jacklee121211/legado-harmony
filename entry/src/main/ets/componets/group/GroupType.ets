import BookGroupsDao from '../../database/dao/BookGroupsDao'
import { BookGroups } from '../../database/entities/BookGroups'
import BookType from '../head/BookType'
import { GroupManageDialog } from './GroupManageDialog'
import FolderInfoDialog from '../../pages/view/bookShelf/components/dialog/FolderInfoDialog'
import coverInfoDialog from '../../pages/view/bookShelf/components/dialog/coverInfoDialog'
import ImmersiveMaterialUtil from '../../common/utils/ImmersiveMaterialUtil'
import UiMotion, { runJellyClick } from '../../common/utils/UiMotion'
import { showMessage } from '../common/promptShow'
import { NightMode } from '../../common/utils/NightMode'
// ── 全局震动反馈（2026-09-25 新增）────────────────────────────────────────────
import { Haptics } from '../../common/utils/Haptics'
// ★ 2026-10-11：分组行三横图标跟随主题色（与 IndexShelf.trailingIconColor 同款语义）
import { ThemeItem } from '../../common/model/Theme'
import { ThemeStorageKey } from '../../common/constants/Theme'

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
        // 真开真关（2026-10-01 用户方案）：子弹窗关闭后由**创建者**重建父弹窗——
        // 全新实例=全新 @Prop 快照，天然刷新；不再复用旧实例（其快照不具备刷新能力）。
        reopen: (): void => { this.reopenChipEditDialog() },
        cancel: (): void => {
          this.chipEditDialog = null
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

  /** 真开真关：重查该分组 → 更新 editChipGroup → **新建 controller** 全新实例打开 */
  private async reopenChipEditDialog(): Promise<void> {
    const id = this.editChipGroup?.groupId
    if (id !== undefined) {
      const groups: BookGroups[] = await BookGroupsDao.search({ type: this.currentIndex })
      const fresh = groups.find((g: BookGroups) => g.groupId === id)
      if (fresh !== undefined) {
        this.editChipGroup = fresh
      }
    }
    this.openChipEditDialog()
  }

  /**
   * 「书单」（系统单元）长按 → **直达封面样式弹窗**（2026-10-01 用户定义）。
   * 封面会真实应用到所有书单内的书（见 coverInfoDialog.resolveTargetBooks 的书单聚合分支）。
   */
  private worksCoverDialog: CustomDialogController | null = null
  private openWorksCoverDialog(item: BookGroups): void {
    this.worksCoverDialog = new CustomDialogController({
      builder: coverInfoDialog({
        itemData: item,
        cancel: (): void => {
          this.worksCoverDialog = null
        }
      }),
      autoCancel: true,
      width: '92%',
      alignment: DialogAlignment.Center,
      cornerRadius: 20,
      customStyle: false,
      systemMaterial: ImmersiveMaterialUtil.sheetMaterial(),
      openAnimation: UiMotion.motionParam(UiMotion.SPRING_FAST),
      closeAnimation: UiMotion.motionParam(UiMotion.SPRING_FAST),
      cancel: (): void => {
        this.worksCoverDialog = null
      }
    })
    this.worksCoverDialog?.open()
  }
  /** App 级夜间开关：只为触发重绘（取色走 `ShelfColors`），理由见 `IndexShelf` 同名字段 */
  @StorageLink(NightMode.KEY) nightOn: boolean = false
  // ★ 2026-10-11：主题颜色（与 IndexShelf.ets:164 同款），给"三横"图标跟随主题色用。
  @StorageProp(ThemeStorageKey.THEME) theme: ThemeItem = {} as ThemeItem
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
      this.groupList = this.sortSystemChips(val)
    })
  }

  /**
   * 五个系统基础单元（2026-10-01 用户定义，**位置锁定**，顺序恒为）：
   *   全部 → 本地 → 书单 → 分组 → 未分组
   * 用户自建分组/书单按原相对顺序排在后面。
   * ⚠️ 实现必须是"按 isSystem+名字识别后**重建整个数组**"：上一版在 filter 出的子集里
   * `rest.indexOf(all)`（all 已被滤掉 ⇒ -1 ⇒ splice 位置错乱 + 全部丢失）——真机 18:2x
   * 复现"全部没了、书单改名后才出现全部"（改名后名字不再等于'书单'、works 找不到 ⇒ 走了
   * 原序分支）。这版对缺名系统行做兜底（找到几个排几个），customs 永远不会吞掉系统行。
   */
  private sortSystemChips(list: BookGroups[]): BookGroups[] {
    const order: string[] = ['全部', '本地', '书单', '分组', '未分组']
    const systems: BookGroups[] = []
    for (const name of order) {
      const hit = list.find((g: BookGroups) => g.isSystem && g.groupName === name)
      if (hit !== undefined) {
        systems.push(hit)
      }
    }
    const customs = list.filter((g: BookGroups) => !systems.includes(g))
    const result: BookGroups[] = []
    for (const g of systems) {
      result.push(g)
    }
    for (const g of customs) {
      result.push(g)
    }
    return result
  }

  /** 五个系统基础单元识别（锁定改名/删除/长按编辑，见各入口守卫） */
  private isLockedUnit(item: BookGroups): boolean {
    return item.isSystem && ['全部', '本地', '书单', '分组', '未分组'].includes(item.groupName ?? '')
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

  /**
   * 分组行尾部"三横"图标颜色（2026-10-11：与搜索/更多同款主题色跟随）。
   * 与 IndexShelf.trailingIconColor() 语义一致：亮色档=主题主色、暗色档=浅色对比色。
   */
  private groupIconColor(): string {
    return NightMode.isDarkSurface() ? 'rgba(248, 249, 250, 0.88)' : this.theme.mainColor
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
                // ⚠️ 2026-10-01 五个系统单元锁定（用户定义）：全部/本地/分组/未分组
                // **不再提供长按弹窗**；书单长按**直达封面样式弹窗**；只有自建分组/书单
                // 仍走 FolderInfoDialog（且其中改名对系统单元再拦一层）。
                .gesture(LongPressGesture({ repeat: false, duration: 500 })
                  .onAction(() => {
                    Haptics.tap();
                    if (this.isLockedUnit(item)) {
                      if (item.groupName === '书单') {
                        this.openWorksCoverDialog(item)
                      } else {
                        showMessage('「' + (item.groupName ?? '') + '」是系统单元，不支持编辑')
                      }
                      return
                    }
                    this.editChipGroup = item
                    this.openChipEditDialog()
                  }))
              }
            }, (item: BookGroups): string => item.groupId !== undefined
              // 2026-10-01 键值并入显示字段：ForEach 键值相同的项**复用旧组件、不重绑数据**
              // ⇒ 只用 'g'+groupId 时重命名后 chip 永远显示旧名（真机日志 2.md 17:05
              // "重命名后没有立刻刷新"）。show 影响显隐 if 分支，一并并入。
              // 同款修法见 BookContent.ets 键值注释。
              ? 'g' + item.groupId + item.groupName + (item.show ? 'S' : 'H')
              : item.groupName)
          }
        }
        .scrollBar(BarState.Off)
        .scrollable(ScrollDirection.Horizontal)
        Row(){
          // ── 分组行尾部按钮（2026-09-25 换 SymbolGlyph；点击 Q弹缩放见 runJellyClick）──
          // 2026-10-01：justifyContent End ⇒ 三横贴右边距（margin 15），与上一行
          // 「最近阅读」行尾「更多」按钮中心（右边距 15+12=27vp）垂直对齐。
          // ★ 2026-10-11：字号 24→20，颜色跟随主题色（与搜索/更多同款）。
          SymbolGlyph($r('sys.symbol.line_3_horizontal'))
            .fontSize(20)
            .fontColor([this.groupIconColor()])
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
        }.width('10%')
        .justifyContent(FlexAlign.End)
        // 2026-10-01（用户，夜间模式反馈）：三横原来贴住胶囊右边缘（上一轮为对齐改成
        // End+右padding 0），"没有间距"⇒ 往回来 8vp。列右内边距 8 ⇒ 图标右缘在
        // 右边距 15+8=23vp 处，与上一行「更多」仍基本对齐（中心 35 vs 27，视觉可接受）。
        // ★ 2026-10-11：right padding 8→10，与"更多"图标右 padding 10 对齐
        //   ⇒ 三横右缘 = 屏右 - 15(margin) - 10(padding) = 屏右 - 25vp
        //   = "更多"图标右缘（屏右 - 15 - 10）= **两图标同列右对齐**。
        .padding({ right: 10 })
      }.margin({ left: 15, right: 15, bottom: 10})
        // ★ 2026-10-11：三胶囊配方完全统一（与左/右胶囊同款 0.55 透明兑底 + REGULAR）。
        //   user 截图反馈下胶囊"几乎看不见"——盖在 Tabs 内容（浅色书封网格）+ 渐变底端
        //   （接近白色）上时，单纯 REGULAR 模糊采样到浅色 → 朦胧出浅灰白，与页面背景
        //   几乎融为一体。修法：加 0.55 透明兑底层让朦胧有"色感"统一，能被肉眼识别。
        //   alpha=0.55 是 user 拍板的"折中"——足够识别但不压制 REGULAR 毛玻璃主效果。
        //   ⚠️ 没用 `ShelfColors.surface()`（0.92）——之前 user 反馈"白卡片"。
        //   容器高 = 15号字(18) + 8×2 = **34vp**（与左/右胶囊**完全等高**）。
        //   ⚠️ 右 padding 仍为 0：三横列靠右贴边缘（End 对齐），不受 padding 影响。
        .backgroundColor(NightMode.isDarkSurface() ? 'rgba(38, 38, 41, 0.15)' : 'rgba(255, 255, 255, 0.15)')
        .backgroundBlurStyle(BlurStyle.COMPONENT_REGULAR, { colorMode: ThemeColorMode.SYSTEM })
        .borderRadius(20)
        .padding({ left: 12, right: 0, top: 8, bottom: 8 })
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
