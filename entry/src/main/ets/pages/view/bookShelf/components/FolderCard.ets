/**
 * 统一文件夹卡片（2026-11-01，父子统一框架）。
 *
 * 背景：主栏分组、进入分组后的子文件夹、父卡片里的子分组格子，原先是三套画法，
 * 导致"层级一变画法就变"（尺寸/三层叠/宫格都不一致）。这里收敛成一个组件，
 * 层级只体现在 `role` 上：
 *
 * · role = 'card'：自己是一张卡 ⇒ 画 2×2 宫格（格子由 `cells` 提供，空格为淡底色块）；
 * · role = 'cell'：自己只是父卡里的一个格子 ⇒ 三层叠，首层是自己的封面。
 *
 * 规则（用户拍板）：
 * · 卡片 = 2×2 预览；格子（子分组）= 三层叠 + 首层封面；
 * · 子分组优先、书在后；超过 4 格忽略；
 * · 卡片尺寸与书籍卡一致：撑满列宽 + 书封比例 0.72。
 */
import { NightMode } from '../../../../common/utils/NightMode'

/** 卡片里的一个格子 */
export interface FolderCell {
  /** true = 子分组（三层叠）；false = 书（真实封面） */
  isFolder: boolean
  /** 封面；null = 淡底空格 */
  cover: ResourceStr | null
}

@Component
export default struct FolderCard {
  /** 'card' = 一张卡片；'cell' = 父卡里的格子 */
  @Prop role: string = 'card'
  @Prop title: string = ''
  /** 是否画标题（主栏卡片由外层画「书名 + 共N本」，这里传 false 避免重复） */
  @Prop showTitle: boolean = true
  /** role='cell' 时自己的封面 */
  @Prop cover: ResourceStr | null = null
  /** role='card' 时的格子（最多 4 个） */
  @Prop cells: FolderCell[] = []
  onTap: () => void = () => {
  }
  onLongPress: () => void = () => {
  }

  private emptyColor(): string {
    return NightMode.isDarkSurface() ? 'rgba(255,255,255,0.06)' : 'rgba(0,0,0,0.04)'
  }

  private frameColor(): string {
    return NightMode.isDarkSurface() ? 'rgba(255,255,255,0.12)' : 'rgba(0,0,0,0.08)'
  }

  /** 有无可用封面：null/undefined/空串都算没有（`resolveBookCover` 无封面时返回 ''） */
  private hasCover(c: ResourceStr | null): boolean {
    if (c === null || c === undefined) {
      return false
    }
    if (typeof c === 'string') {
      return c.length > 0
    }
    return true
  }

  @Builder
  cellContent(cell: FolderCell) {
    Stack() {
      if (cell.isFolder) {
        // 子分组：三层叠（首层 = 它自己的封面）
        Stack({ alignContent: Alignment.Center }) {
          Row().width('80%').height('80%').borderRadius(3)
            .backgroundColor(NightMode.isDarkSurface() ? 'rgba(255,255,255,0.16)' : 'rgba(0,0,0,0.10)')
            .translate({ x: 7, y: 5 })
          Row().width('90%').height('90%').borderRadius(3)
            .backgroundColor(NightMode.isDarkSurface() ? 'rgba(255,255,255,0.24)' : 'rgba(0,0,0,0.15)')
            .translate({ x: 3, y: 2 })
          if (this.hasCover(cell.cover)) {
            Image(cell.cover).width('100%').height('100%').borderRadius(3).draggable(false)
          } else {
            Row().width('100%').height('100%').borderRadius(3).backgroundColor(this.emptyColor())
          }
        }
        .width('100%').height('100%')
      } else if (this.hasCover(cell.cover)) {
        Image(cell.cover).width('100%').height('100%').borderRadius(4).draggable(false)
      } else {
        Row().width('100%').height('100%').borderRadius(4).backgroundColor(this.emptyColor())
      }
    }
    .layoutWeight(1)
    .height('100%')
  }

  build() {
    // 单一根容器（ArkTS 要求）：角色差异只用内部 if/else 表达
    Column() {
    if (this.role === 'cell') {
      // 父卡里的格子：三层叠 + 自己的封面
      Stack({ alignContent: Alignment.Center }) {
        Row().width('80%').height('80%').borderRadius(3)
          .backgroundColor(NightMode.isDarkSurface() ? 'rgba(255,255,255,0.16)' : 'rgba(0,0,0,0.10)')
          .translate({ x: 7, y: 5 })
        Row().width('90%').height('90%').borderRadius(3)
          .backgroundColor(NightMode.isDarkSurface() ? 'rgba(255,255,255,0.24)' : 'rgba(0,0,0,0.15)')
          .translate({ x: 3, y: 2 })
        if (this.hasCover(this.cover)) {
          Image(this.cover).width('100%').height('100%').borderRadius(3).draggable(false)
        } else {
          Row().width('100%').height('100%').borderRadius(3).backgroundColor(this.emptyColor())
        }
      }
      .width('100%')
      .height('100%')
    } else {
      Column({ space: 8 }) {
        Stack({ alignContent: Alignment.Center }) {
          Row().width('100%').height('100%').borderRadius(10)
            .backgroundColor(NightMode.isDarkSurface() ? 'rgba(255,255,255,0.05)' : 'rgba(0,0,0,0.03)')
            .border({ width: 1, color: this.frameColor() })
          Column({ space: 3 }) {
            Row({ space: 3 }) {
              this.cellContent(this.cells.length > 0 ? this.cells[0] : { isFolder: false, cover: null })
              this.cellContent(this.cells.length > 1 ? this.cells[1] : { isFolder: false, cover: null })
            }
            .layoutWeight(1).width('100%')
            Row({ space: 3 }) {
              this.cellContent(this.cells.length > 2 ? this.cells[2] : { isFolder: false, cover: null })
              this.cellContent(this.cells.length > 3 ? this.cells[3] : { isFolder: false, cover: null })
            }
            .layoutWeight(1).width('100%')
          }
          .width('100%').height('100%').padding(5)
        }
        .width('100%').aspectRatio(0.72).clip(true)

        if (this.showTitle) {
          Text(this.title)
            .fontSize(15).fontWeight(700).maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
        }
      }
      .padding({ left: 6, right: 6, top: 4, bottom: 8 })
    }
    }
    // 点击/长按统一由外部注入（与层级无关）
    .onClick(() => {
      this.onTap()
    })
    .gesture(
      LongPressGesture({ repeat: false, duration: 500 })
        .onAction(() => {
          this.onLongPress()
        }))
  }
}
