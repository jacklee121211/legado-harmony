import BookInfoManage from './BookInfoManage'
import BookInfoGridManage from './BookInfoGridManage'
import { Books } from '../../../../../database/entities/Books'
import { NightMode, ShelfColors } from '../../../../../common/utils/NightMode'
// 宫格列数（2026-10-25 多端适配补齐）：与书架书籍宫格**同源同一份取值**
import ShelfPrefs from '../../../../../common/utils/ShelfPrefs'
// 手势划选（2026-10-25 新增）：几何命中 + 会话状态机，见该文件头注释
import ManageBrush, { BrushRect, bumpSelectionVersion } from './ManageBrush'
import { Haptics } from '../../../../../common/utils/Haptics'

@Component
export default struct bookListManage{
  @Prop EXHIBIT:string
  @Prop bookList:Books[]
  @Prop isManage:boolean = true
  @Link checkGroup:Record<number, boolean>
  @State delCache:boolean = false
  /** App 级深浅色：订阅只为深浅切换时触发重绘 */
  @StorageLink(NightMode.KEY) nightOn: boolean = false
  // ── 宫格列数的两个输入源（2026-10-25 补齐）────────────────────────────────
  // 用户原话：「批量管理页面没有收益（于设置页那个「一行显示书籍数」滑块），
  //   我们需要优化一下」。
  //
  // ── 旧实现（已删）──────────────────────────────────────────────────────────
  //   `GridRow({ columns: 3 })` —— 写死 3 列，与 `BookContent`/`BookFolder` 改造前
  //   那两处写死的 3 列是同一个历史遗留。书架那边 2026-10-23 已改成
  //   `ShelfPrefs.effectiveColumns(用户值, 断点)`，**唯独管理页这三处没跟上**
  //   ⇒ 平板/2in1 上「书架 5 列、进批量管理变回 3 列」。
  //
  // ── 现在：与书架**同一个函数**（AGENTS.md §7 的硬要求：列数相关 UI 必须同源）
  //   自动档 sm=3 / md=4 / lg=5 / xl=6；手动档 = 设置页滑块值。
  //   ⚠️ 手机端恒为 3（sm 档 = 旧写死值）⇒ 零回归。
  //   ⚠️ 两个 `@StorageProp` 订阅 AppStorage ⇒ 设置页拖滑块 / 旋转 / 2in1 拖窗口，
  //      本页**立刻重排**，不必退出重进。
  @StorageProp('currentBreakpoint') currentBreakpoint: string = 'sm'
  @StorageProp(ShelfPrefs.KEY_GRID_COLUMNS_STORAGE) userGridColumns: number = 0
  onSelect:Function = () => {}

  // ══════════════════════════════════════════════════════════════════════════
  // 手势划选（2026-10-25 新增）
  // ══════════════════════════════════════════════════════════════════════════
  // 用户原话：「…并且支持手势滑动批量选择…就像是系统相册一样…用户不仅能点击一个
  //   进行选择取消，用可以跟随手势滑动，批量的选择取消。」
  //
  // ── 分工 ──────────────────────────────────────────────────────────────────
  //   · **单击整卡**：由格子组件自己处理（`BookInfoGridManage` / `BookInfoManage`
  //     各自 `.onClick` + 本地 `@State checked`）⇒ 点哪都算，不再只有选择圈能点；
  //   · **划选**：由本容器处理 —— 容器才知道"格子都在哪"（`onAreaChange` 记矩形），
  //     也才知道手势落点（`PanGesture` 的 `localX/localY` 相对本容器）。
  //     两者坐标系一致（官方 SDK 原文见 `ManageBrush.ets` 文件头 ①②）。
  //
  // ── 为什么是"长按后再划"而不是"直接划" ────────────────────────────────────
  //   本页外层是 `Scroll`：直接划会被滚动吃掉（整页就划不动了）。官方 FAQ
  //   `faqs-arkui-827` 给的标准解法就是「LongPressGesture + PanGesture 组合，
  //   **长按识别后才顺序识别滑动**」⇒ 竖向快滑仍是滚动，按住再划才是划选。
  //
  // ⚠️ 回退：删掉下面两处 `.gesture(...)` 即恢复"只能一个个点"的旧行为。
  private brush: ManageBrush = new ManageBrush()

  /** 取书 id（无 id 的脏数据用 -1 占位，不参与划选） */
  private bookIdOf(item: Books): number {
    return item.id !== undefined && item.id !== null ? item.id : -1
  }

  /**
   * 记录一个格子的矩形（`onAreaChange` 回调）。
   * `area.position` 是**相对父容器**的坐标（SDK 原文见 `ManageBrush.ets` ②），
   * 而手势的 `localX/localY` 也是相对同一个容器 ⇒ 可直接命中判定。
   */
  private recordRect(item: Books, area: Area): void {
    const id: number = this.bookIdOf(item)
    if (id < 0) {
      return
    }
    const x: number = (area.position.x ?? 0) as number
    const y: number = (area.position.y ?? 0) as number
    const w: number = (area.width ?? 0) as number
    const h: number = (area.height ?? 0) as number
    this.brush.record(new BrushRect(id, x, y, x + w, y + h))
  }

  /** 手势落点（相对本容器）。取不到手指（键盘/手柄触发）时返回 -1 表示本次忽略 */
  private fingerX(ev: GestureEvent): number {
    const list = ev.fingerList
    return list === undefined || list.length === 0 ? -1 : list[0].localX
  }

  private fingerY(ev: GestureEvent): number {
    const list = ev.fingerList
    return list === undefined || list.length === 0 ? -1 : list[0].localY
  }

  /** 落盘：只写数据，视觉由版本号广播统一刷新（见 `ManageBrush.ets` 末尾说明） */
  private writeChecked(id: number, checked: boolean): void {
    this.checkGroup[id] = checked
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
        this.writeChecked(id, checked)
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
      this.writeChecked(id, checked)
    })
    if (changed > 0) {
      // 跨格才刷新：手指在同一格里移动时不广播，避免无谓重渲染
      Haptics.tick()
      bumpSelectionVersion()
      this.onSelect()
    }
  }

  private brushEnd(): void {
    this.brush.end()
  }

  build() {
    if (this.bookList === null || this.bookList.length === 0) {
      Column() {
        Image($r('app.media.no_record')).width(200).height(200)
        Text('暂无浏览记录').fontSize(12).fontColor(ShelfColors.textSub()).fontWeight(500).padding(5)
      }
      .margin({ top: 120 })

    } else {
      Column(
        {space:10}
      ){
        if (this.EXHIBIT === '宫格') {
         GridRow({
           // 2026-10-25：由写死 3 列改为与书架书籍宫格同源的列数（见上方字段注释）
           columns: ShelfPrefs.effectiveColumns(this.userGridColumns, this.currentBreakpoint)
         }){
           ForEach(this.bookList, (item: Books,index:number) => {
             GridCol(){
               BookInfoGridManage({
                 bookData:item,
                 isManage:this.isManage,
                 checkGroup:this.checkGroup,
                 onSelect: ()=>{
                   this.onSelect()
                 }
               })
             }
             // 划选命中所需的矩形（相对本 GridRow，见 recordRect 注释）
             .onAreaChange((oldValue: Area, newValue: Area): void => {
               this.recordRect(item, newValue)
             })
           }, (item: Books): string => item.id !== undefined ? 'b' + item.id : (item.bookUrl ?? item.bookName))
         }
         // 长按 → 划选（官方 FAQ faqs-arkui-827 的标准组合；见上方字段注释）
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
        } else {
          Column({
            space: 10
          }) {
            ForEach(this.bookList, (item: Books,index:number) => {
              BookInfoManage({
                bookData:item,
                isManage:this.isManage,
                checkGroup:this.checkGroup,
                onSelect: ()=>{
                  this.onSelect()
                }
              })
              .onAreaChange((oldValue: Area, newValue: Area): void => {
                this.recordRect(item, newValue)
              })
            }, (item: Books): string => item.id !== undefined ? 'b' + item.id : (item.bookUrl ?? item.bookName))
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
      }

    }
  }
}
