import confirmDialogExample from '../../../../../componets/common/confirmDialog'
import { showMessage } from '../../../../../componets/common/promptShow'
import { BookGroups } from '../../../../../database/entities/BookGroups'
import BookFolderGridManage from './BookFolderGridManage'
import { Books } from '../../../../../database/entities/Books'
import { gKey } from '../../../../../common/manage/SelectionKeys'
import BookFolderInfoManage from './BookFolderInfoManage'
import { NightMode, ShelfColors } from '../../../../../common/utils/NightMode'
// 宫格列数（2026-10-25 多端适配补齐）：与书架分组宫格**同源同一份取值**
import ShelfPrefs from '../../../../../common/utils/ShelfPrefs'
// 手势划选（2026-10-25 新增）：与书籍管理同一套几何/会话逻辑
import ManageBrush, { BrushRect, bumpSelectionVersion } from './ManageBrush'
import { Haptics } from '../../../../../common/utils/Haptics'

@Component
export default struct BookFolderManages {
  @Prop bookGroups:BookGroups[] = []
  @Link checkGroup:Record<number, boolean>
  @Prop EXHIBIT:string
  @State delCache:boolean = false
  @Prop isManage:boolean = true
  /** 2026-11-01：内联模式（与书籍块同页）—— 高度自适应，不抢占剩余空间 */
  @Prop fitContent: boolean = false
  /** 当前所在分组 id（用于"本分组"角标；根目录传 0） */
  @Prop currentGroupId: number = 0
  /** 当前页可见书籍（点父分组时要一起勾选） */
  @Prop allBooks: Books[] = []
  /** App 级深浅色：订阅只为深浅切换时触发重绘 */
  @StorageLink(NightMode.KEY) nightOn: boolean = false
  // ── 宫格列数的两个输入源（2026-10-25 补齐）────────────────────────────────
  // 与 `bookListManage` / 书架 `BookFolder` **同一份取值**：
  //   `ShelfPrefs.effectiveColumns(用户滑块值, 当前断点)`。
  // 用户原话：「全部、分组、最近皆受益于此…但是批量管理页面没有收益」——
  //   分组这一路在管理页写死 `columns: 3`，本次补齐。
  // ⚠️ 分组卡片的视觉宽度与单本书封面同量级（书架 `BookFolder` 早就这么做了），
  //   两处列数一致才对得齐；不要给分组单独再开一个滑块。
  // ⚠️ 手机端恒为 3（sm 档 = 旧写死值）⇒ 零回归。
  @StorageProp('currentBreakpoint') currentBreakpoint: string = 'sm'
  @StorageProp(ShelfPrefs.KEY_GRID_COLUMNS_STORAGE) userGridColumns: number = 0
  onSelect:Function = () => {}

  // ── 手势划选（2026-10-25 新增）────────────────────────────────────────────
  // 与 `bookListManage` 完全同一套（长按 → 拖动、起手格定方向、每格只写一次）；
  // 详细理由与官方依据见 `ManageBrush.ets` 文件头。分组管理页同样是"天然批量环境"，
  // 用户既然要求"点哪都能选 + 滑动批量选"，两种视图必须一致。
  private brush: ManageBrush = new ManageBrush()

  private groupIdOf(item: BookGroups): number {
    return item.groupId !== undefined && item.groupId !== null ? item.groupId : -1
  }

  private recordRect(item: BookGroups, area: Area): void {
    const id: number = this.groupIdOf(item)
    if (id < 0) {
      return
    }
    const x: number = (area.position.x ?? 0) as number
    const y: number = (area.position.y ?? 0) as number
    const w: number = (area.width ?? 0) as number
    const h: number = (area.height ?? 0) as number
    this.brush.record(new BrushRect(id, x, y, x + w, y + h))
  }

  private fingerX(ev: GestureEvent): number {
    const list = ev.fingerList
    return list === undefined || list.length === 0 ? -1 : list[0].localX
  }

  private fingerY(ev: GestureEvent): number {
    const list = ev.fingerList
    return list === undefined || list.length === 0 ? -1 : list[0].localY
  }

  private brushBegin(ev: GestureEvent): void {
    if (!this.isManage) {
      return
    }
    const x: number = this.fingerX(ev)
    const y: number = this.fingerY(ev)
    if (x < 0 || y < 0) {
      return
    }
    const started: boolean = this.brush.begin(x, y,
      (id: number): boolean => this.checkGroup[gKey(id)] ?? false,
      (id: number, checked: boolean): void => {
        this.checkGroup[gKey(id)] = checked
      })
    if (started) {
      Haptics.tick()
      bumpSelectionVersion()
      this.onSelect()
    }
  }

  private brushUpdate(ev: GestureEvent): void {
    if (!this.brush.isActive()) {
      return
    }
    const x: number = this.fingerX(ev)
    const y: number = this.fingerY(ev)
    if (x < 0 || y < 0) {
      return
    }
    const changed: number = this.brush.update(x, y, (id: number, checked: boolean): void => {
      this.checkGroup[gKey(id)] = checked
    })
    if (changed > 0) {
      Haptics.tick()
      bumpSelectionVersion()
      this.onSelect()
    }
  }

  private brushEnd(): void {
    this.brush.end()
  }

  bookInfoDel: CustomDialogController | null = new CustomDialogController({
    builder: confirmDialogExample({
      cancel: ()=> { this.onCancel() },
      confirm: ()=> { this.onAccept() },
      delCache:this.delCache
    }),
    cancel: this.exitApp,
    autoCancel: true,
    alignment: DialogAlignment.Center,
    gridCount: 4,
    customStyle: false,
    cornerRadius: 25,
  })

  onCancel() {
    // this.isClear = false
  }

  onAccept() {
    this.deleteFolder()
  }

  exitApp() {
    // this.isClear = false
  }

  deleteFolder() {
    showMessage('删除成功')
  }

  /** 左上角来源标签：本分组 / 来自本分组 / 来自XX（用户：用来源标签代替纯色环） */
  private originLabelOf(item: BookGroups): string {
    const id: number = item.groupId ?? -1
    if (id <= 0) {
      return ''
    }
    if (id === this.currentGroupId) {
      return '本分组'
    }
    const pid: number = item.parentId ?? 0
    if (pid <= 0) {
      // 根目录批量管理：每个自定义分组都标出来源（父 = 根目录）
      return '来自根目录'
    }
    if (pid === this.currentGroupId) {
      return '来自本分组'
    }
    for (const g of this.bookGroups) {
      if ((g.groupId ?? -1) === pid) {
        return '来自' + (g.groupName ?? '')
      }
    }
    return ''
  }

  /** 层级：沿 parentId 往上数（1 = 顶层分组） */
  private depthOf(item: BookGroups): number {
    let d: number = 1
    let pid: number = item.parentId ?? 0
    let guard: number = 0
    while (pid !== 0 && guard < 12) {
      d++
      guard++
      let next: number = 0
      for (const g of this.bookGroups) {
        if ((g.groupId ?? -1) === pid) {
          next = g.parentId ?? 0
          break
        }
      }
      pid = next
    }
    return Math.min(d, 10)
  }

  /**
   * 2026-11-01：按顶层分组分块（用户：不同分组之间要隔开）。
   * bookGroups 已由 getGroupList() 按 DFS 排好，这里只按"遇到 parentId=0 就开新块"切分。
   */
  private blocks(): BookGroups[][] {
    const out: BookGroups[][] = []
    let cur: BookGroups[] = []
    for (const g of this.bookGroups) {
      // 2026-11-02：**管理页必须显示被隐藏的分组**，否则"隐藏后无法恢复"（用户原话：
      //   隐藏还能隐藏，恢复不能恢复了）。移动模式下才过滤隐藏项。
      if (g.isSystem) {
        continue
      }
      if (!g.show && !this.isManage) {
        continue
      }
      const isRoot: boolean = (g.parentId ?? 0) === 0
      if (isRoot && cur.length > 0) {
        out.push(cur)
        cur = []
      }
      cur.push(g)
    }
    if (cur.length > 0) {
      out.push(cur)
    }
    return out
  }

 build() {
   if (this.bookGroups === null || this.bookGroups.length === 0) {
     Column() {
       Image($r('app.media.no_record')).width(200).height(200)
       Text('暂无浏览记录').fontSize(12).fontColor(ShelfColors.textSub()).fontWeight(500).padding(5)
     }
     .margin({ top: 120 })
   } else {
     Column(){
       if (this.EXHIBIT === '列表') {
         ForEach(this.bookGroups, (item: BookGroups) => {
           if (item.show && !item.isSystem) {
             BookFolderInfoManage({
               group:item,
               checkGroup:this.checkGroup,
               isManage:this.isManage,
               onSelect:()=>{
                 this.onSelect()
               }
             })
             .onAreaChange((oldValue: Area, newValue: Area): void => {
               this.recordRect(item, newValue)
             })
           }
         }, (item: BookGroups): string => groupCardKey(item))
       } else {
         ForEach(this.blocks(), (block: BookGroups[], bi: number) => {
           // 2026-11-01：每个顶层分组一个圆角底板区块（块内 DFS，块间 16 间距）
           Column() {
             GridRow({
               columns: ShelfPrefs.effectiveColumns(this.userGridColumns, this.currentBreakpoint),
               // 2026-11-01：块内纵横间距（原来纵向默认 0 ⇒ 卡片上下贴在一起）
               gutter: { x: 8, y: 12 }
             }){
               ForEach(block, (item: BookGroups) => {
                 GridCol(){
                   BookFolderGridManage({
                     group:item,
                     depth: this.depthOf(item),
                     allGroups: this.bookGroups,
                     allBooks: this.allBooks,
                     isCurrent: (item.groupId ?? -1) === this.currentGroupId,
                     originLabel: this.originLabelOf(item),
                     checkGroup:this.checkGroup,
                     isManage:this.isManage,
                     onSelect:()=>{
                       this.onSelect()
                     }
                   })
                 }
                 .onAreaChange((oldValue: Area, newValue: Area): void => {
                   this.recordRect(item, newValue)
                 })
               }, (item: BookGroups): string => groupCardKey(item))
             }
             .gesture(
               GestureGroup(GestureMode.Sequence,
                 LongPressGesture({ repeat: false, duration: 300 })
                   .onAction((event: GestureEvent): void => {
                     this.brushBegin(event)
                   }),
                 PanGesture({ fingers: 1, distance: 1 })
                   .onActionUpdate((event: GestureEvent): void => {
                     this.brushUpdate(event)
                   })
                   .onActionEnd((): void => {
                     this.brushEnd()
                   })
                   .onActionCancel((): void => {
                     this.brushEnd()
                   })
               )
             )
           }
           .width('100%')
           .padding({ left: 6, right: 6, top: 8, bottom: 8 })
           .borderRadius(16)
           .backgroundColor(ShelfColors.card())
           .border({ width: 1, color: 'rgba(128,128,128,0.18)' })
           .margin({ bottom: 16 })
         }, (block: BookGroups[], bi: number) => 'blk' + bi + '_' + block.length + '_' + (block.length > 0 ? (block[0].groupId ?? 0) : 0))
       }
     }
     // 2026-11-01：内联模式（分组块 + 书籍块同页）时不吃剩余高度，避免把书籍顶到很下面
     .layoutWeight(this.fitContent ? 0 : 1)
     // 列表模式下格子的父容器就是本 Column（ForEach 不产生布局节点）⇒ 手势挂这里
     .gesture(
       GestureGroup(GestureMode.Sequence,
         LongPressGesture({ repeat: false, duration: 300 })
           .onAction((event: GestureEvent): void => {
             if (this.EXHIBIT === '列表') {
               this.brushBegin(event)
             }
           }),
         PanGesture({ fingers: 1, distance: 1 })
           .onActionUpdate((event: GestureEvent): void => {
             if (this.EXHIBIT === '列表') {
               this.brushUpdate(event)
             }
           })
           .onActionEnd((): void => {
             this.brushEnd()
           })
           .onActionCancel((): void => {
             this.brushEnd()
           })
       )
     )
   }
 }
}

/**
 * 分组卡片键值（2026-10-06）：**必须并入所有影响显示的字段**。
 *
 * 官方《ForEach：循环渲染》非首次渲染原文：「它会检查新生成的键值是否在上次渲染中已经存在。
 * 如果键值不存在，则会创建一个新的组件；**如果键值存在，则不会创建新的组件，而是直接渲染
 * 该键值所对应的组件**。」⇒ 只写 `'g'+groupId` 时，换封面 / 改名 / 置顶 / "共N本"变化
 * 都不会重建卡片（本项目规范 `docs/标准-弹窗与按钮统一规范.md:201,212` 同款要求）。
 */
function groupCardKey(item: BookGroups): string {
  return (item.groupId !== undefined ? 'g' + item.groupId : item.groupName)
    + '|' + (item.groupName ?? '')
    + '|' + (item.isTop ? 'T' : 'F')
    + '|' + (item.show ? '1' : '0')
    + '|' + (item.coverUrl ?? '')
    + '|' + item.coverType
    + '|' + (item.bookIds?.length ?? 0)
}
