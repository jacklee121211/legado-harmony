import { ThemeStorageKey } from '../../../../../common/constants/Theme'
import { Haptics } from '../../../../../common/utils/Haptics';
import { ThemeItem } from '../../../../../common/model/Theme'
import { BookGroups } from '../../../../../database/entities/BookGroups'
import { NightMode, ShelfColors } from '../../../../../common/utils/NightMode'
import UiMotion from '../../../../../common/utils/UiMotion'
import { resolveCoverSource, coverCorners } from '../../../../../common/utils/CoverSource'
import { MANAGE_SEL_VERSION_KEY } from './ManageBrush'

/**
 * 文件夹宫格_管理页
 */
@Component
export default struct BookFolderGridManage {
  @Prop group:BookGroups
  @Link checkGroup:Record<number, boolean>
  @Prop isManage:boolean
  onSelect:Function = () => {}
  // 主题颜色
  @StorageProp(ThemeStorageKey.THEME) theme: ThemeItem = {} as ThemeItem
  /** App 级深浅色：订阅只为深浅切换时触发重绘 */
  @StorageLink(NightMode.KEY) nightOn: boolean = false

  // ── 勾选视觉与"整卡可点"（2026-10-25 重做）────────────────────────────────
  // 与书籍宫格 `BookInfoGridManage` 同一套（理由见那边注释）：
  //   Checkbox 只当显示件（触摸穿透），整卡点击走 toggle()，外部批量改动靠
  //   `MANAGE_SEL_VERSION_KEY` 广播回读。
  @State checked: boolean = false
  /** 2026-11-01：层级（1 = 顶层分组）。用于外框色边，最多 10 层。 */
  @Prop depth: number = 1
  /** 2026-11-01：是否就是当前所在分组（批量管理里给"本分组"角标） */
  @Prop isCurrent: boolean = false
  /** 左上角来源标签：本分组 / 来自本分组 / 来自XX（空串 = 不显示） */
  @Prop originLabel: string = ''
  /** 全部分组（级联选择需要算子孙/祖先） */
  @Prop allGroups: BookGroups[] = []

  private levelColor(): string {
    // 2026-11-01：L1 也要有外框色（用户："祖分组也有外框颜色，不然太特别"）
    if (this.depth <= 1) {
      return NightMode.isDarkSurface() ? '#6FA8CC' : '#5B9BD5'
    }
    // 10 层级配色（L1 无色）；夜间用更亮的同族色
    const day: string[] = ['rgba(0,0,0,0)', '#7FB3D5', '#82C39B', '#E0B050', '#D98880',
      '#B39DDB', '#4DB6AC', '#F06292', '#9575CD', '#A1887F']
    const night: string[] = ['rgba(0,0,0,0)', '#9CC7E8', '#9FD9B4', '#F0C46A', '#E9A29B',
      '#C9B8EC', '#6FD0C6', '#F58BAE', '#B39DDB', '#C0A79C']
    const i: number = Math.min(this.depth, 10)
    return NightMode.isDarkSurface() ? night[i] : day[i]
  }
  @StorageProp(MANAGE_SEL_VERSION_KEY) @Watch('resyncChecked') selVersion: number = 0

  aboutToAppear(): void {
    this.resyncChecked()
  }

  private resyncChecked(): void {
    const id: number | undefined = this.group.groupId
    this.checked = id !== undefined && id !== null ? (this.checkGroup[id] ?? false) : false
  }

  private toggle(): void {
    if (!this.isManage) {
      return
    }
    Haptics.tap()
    this.checked = !this.checked
    const id: number | undefined = this.group.groupId
    if (id === undefined || id === null) {
      this.onSelect()
      return
    }
    // 2026-11-01 级联：点父 ⇒ 父 + 全部子孙同选/同取消
    const val: boolean = this.checked
    const ids: number[] = this.subtreeIds(id)
    for (const x of ids) {
      this.checkGroup[x] = val
    }
    // 子全选 ⇒ 父选中；否则父取消（祖先链逐级重算）
    this.recalcAncestors(id)
    this.onSelect()
  }

  /** 含自身的子树 id 集合 */
  private subtreeIds(rootId: number): number[] {
    const out: number[] = [rootId]
    let guard: number = 0
    let i: number = 0
    while (i < out.length && guard < 500) {
      const cur: number = out[i]
      for (const g of this.allGroups) {
        if ((g.parentId ?? 0) === cur && g.groupId !== undefined && out.indexOf(g.groupId) < 0) {
          out.push(g.groupId)
        }
      }
      i++
      guard++
    }
    return out
  }

  /** 自底向上重算祖先：本节点所有子公司全选 ⇒ 祖先选中，否则取消 */
  private recalcAncestors(startId: number): void {
    let pid: number = 0
    for (const g of this.allGroups) {
      if ((g.groupId ?? -1) === startId) {
        pid = g.parentId ?? 0
        break
      }
    }
    let guard: number = 0
    while (pid !== 0 && guard < 12) {
      const kids: number[] = []
      for (const g of this.allGroups) {
        if ((g.parentId ?? 0) === pid && g.groupId !== undefined) {
          kids.push(g.groupId)
        }
      }
      let allOn: boolean = kids.length > 0
      for (const k of kids) {
        if (!(this.checkGroup[k] ?? false)) {
          allOn = false
          break
        }
      }
      this.checkGroup[pid] = allOn
      let next: number = 0
      for (const g of this.allGroups) {
        if ((g.groupId ?? -1) === pid) {
          next = g.parentId ?? 0
          break
        }
      }
      pid = next
      guard++
    }
  }

  @Builder
  cardContent() {
    Column() {
      Stack() {
        // 2026-11-01：三层叠（两层偏移底板 + 封面），与书架文件夹卡一致，
        // 避免分组卡与同封面的书籍卡混淆（用户验收反馈）。
        Row()
          .width(88).height(120)
          .borderRadius(coverCorners(88))
          .backgroundColor(NightMode.isDarkSurface() ? 'rgba(255,255,255,0.14)' : 'rgba(0,0,0,0.10)')
          .translate({ x: 8, y: 6 })
        Row()
          .width(88).height(120)
          .borderRadius(coverCorners(88))
          .backgroundColor(NightMode.isDarkSurface() ? 'rgba(255,255,255,0.22)' : 'rgba(0,0,0,0.16)')
          .translate({ x: 4, y: 3 })
        Stack(){
          if (this.isManage){
            Checkbox()
              .zIndex(9)
              // 只作显示件：勾选态由本组件 `@State checked` 决定
              .select(this.checked)
              .selectedColor(this.theme.mainColor)
              // 触摸穿透给整张卡片 ⇒ 点圈与点封面同一条 toggle 路径
              .hitTestBehavior(HitTestMode.None)
          }
          Stack(){
            if (this.group.isTop){
              Text('置顶').fontColor(Color.White).fontWeight(300).fontSize(8).padding(3).borderRadius(5)
                .backgroundColor('rgba(0, 0, 0, 0.45)').zIndex(1)
            }
            // 2026-11-01：左上角来源标签（本分组 / 来自本分组 / 来自XX）
            if (this.originLabel.length > 0) {
              Text(this.originLabel)
                .fontColor(Color.White).fontWeight(300).fontSize(8)
                .padding({ left: 4, right: 4, top: 3, bottom: 3 })
                .borderRadius(5)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .constraintSize({ maxWidth: 64 })
                // 2026-11-01：所有来源标签都用深色底 + 白字——分组封面多为浅色图，
                //   深色模式下用白色半透明底几乎看不见（用户："只有本分组优化了"）。
                //   本分组用珊瑚红强调，其余用 0.60 黑色底（亮/暗都压得住浅色封面）。
                .backgroundColor(this.originLabel === '本分组'
                  ? (NightMode.isDarkSurface() ? 'rgba(229,115,115,0.92)' : 'rgba(0, 0, 0, 0.55)')
                  : (NightMode.isDarkSurface() ? 'rgba(0, 0, 0, 0.62)' : 'rgba(0, 0, 0, 0.45)'))
                .position({ x: 4, y: 4 })
                .zIndex(3)
            }
            // 2026-10-06：分组封面与书架文件夹视图**同一解析契约**（`CoverSource.ets` 头注释；
            // 规范 `docs/标准-弹窗与按钮统一规范.md:200`「任何显示端不得手写 substring，
            // 统一走 resolveCoverSource()」）。此前直接 `Image(this.group.coverUrl)` ⇒
            // 用户挑的内置封面存成 `default://cover_defaults/cN.svg`，Image 认不出这个协议
            // ⇒ 落到 alt 默认图（"书架的封面改变，管理中还是默认的封面"的分组版）；
            // 未设封面（undefined）时与书架一致显示内置 c1。
            Image(resolveCoverSource(this.group.coverUrl ?? '') ?? $rawfile('cover_defaults/c1.svg'))
              .draggable(false)
              .alt($r('app.media.icon_book_default_cover_one'))
              .borderRadius(coverCorners(88))
              .width(88)
              .height(120)
          }.alignContent(Alignment.BottomStart)
        }
        .alignContent(Alignment.BottomEnd)
        .zIndex(2)


        // 2026-10-05：同款"书页叠层 + 底条"装饰统一受 UiMotion.SHELF_COVER_STACK 控制
        if (UiMotion.SHELF_COVER_STACK) {
          Row() {
            Image($r('app.media.occlusion1')).draggable(false)
          }
          .zIndex(1).width(95).height(110)
          Row() {
            Image($r('app.media.occlusion2')).draggable(false)
          }
          .zIndex(0).width(100).height(100)
        }
      }
      .alignContent(Alignment.BottomStart)
      // 2026-10-05：色条**保留**（独立开关，见 UiMotion.SHELF_COVER_BASE_BAR 注释）；
      // 宽度与封面同宽（88）⇒ 修掉原来 100 宽导致的左右各 6vp 溢出。
      if (UiMotion.SHELF_COVER_BASE_BAR) {
        Row().width(88).height(20).backgroundColor(ShelfColors.skeleton()).borderRadius(10)
      }
      Text(this.group.groupName)
          .fontSize(15)
          .fontWeight(700)
          .textOverflow({
            overflow:TextOverflow.Ellipsis
          })
          .ellipsisMode(EllipsisMode.END)
          .maxLines(2)
      Text(`共${this.group.bookIds?.length||0}本`).fontSize(12).fontColor(ShelfColors.textSub())
          .textOverflow({
            overflow:TextOverflow.Ellipsis
          })
          .ellipsisMode(EllipsisMode.END)
          .fontWeight(500)
          .maxLines(1)
    }
    .padding({ left:8,right:8,bottom:5,top:5 })
  }

  /** 第 level 层的外环颜色（1..10；夜间更亮） */
  private ringColor(level: number): string {
    const day: string[] = ['#5B9BD5', '#82C39B', '#E0B050', '#D98880', '#B39DDB',
      '#4DB6AC', '#F06292', '#9575CD', '#A1887F', '#78909C']
    const night: string[] = ['#6FA8CC', '#9FD9B4', '#F0C46A', '#E9A29B', '#C9B8EC',
      '#6FD0C6', '#F58BAE', '#B39DDB', '#C0A79C', '#90A4AE']
    const i: number = Math.max(1, Math.min(level, 10)) - 1
    return NightMode.isDarkSurface() ? night[i] : day[i]
  }

  build() {
    // 2026-11-01：按用户要求**取消颜色环方案**，卡片恢复为简洁版（保留三层叠）
    Column() {
      this.cardContent()
    }
    // 2026-10-25：整张卡片可点（含封面 / 分组名 / 空白处）
    .onClick((): void => {
      this.toggle()
    })
  }
}