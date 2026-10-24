import confirmDialogExample from '../../../../../componets/common/confirmDialog'
import { showMessage } from '../../../../../componets/common/promptShow'
import { BookGroups } from '../../../../../database/entities/BookGroups'
import BookFolderGridManage from './BookFolderGridManage'
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
      (id: number): boolean => this.checkGroup[id] ?? false,
      (id: number, checked: boolean): void => {
        this.checkGroup[id] = checked
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
      this.checkGroup[id] = checked
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
         GridRow({
           // 2026-10-25：由写死 3 列改为与书架分组宫格同源的列数（见上方字段注释）
           columns: ShelfPrefs.effectiveColumns(this.userGridColumns, this.currentBreakpoint)
         }){
           ForEach(this.bookGroups, (item: BookGroups) => {
             if (item.show && !item.isSystem) {
               GridCol(){
                 BookFolderGridManage({
                   group:item,
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
             }
           }, (item: BookGroups): string => groupCardKey(item))
         }
         // ⚠️ 手势必须挂在**格子的直接父容器**（GridRow）上：
         //   矩形由 `GridCol.onAreaChange` 给出，其 `position` 是相对 GridRow 的
         //   （SDK 原文见 `ManageBrush.ets` ②）；`localX/localY` 也相对被绑定的组件
         //   ⇒ 只有两者是**同一个容器**时命中判定才对得上。
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
     }
     .layoutWeight(1)
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
