/**
 * 「首页三段按钮排序」设置控件（2026-10-21 新增）。
 *
 * ══ 用户需求原文 ═════════════════════════════════════════════════════════════
 * 「我想在设置页增加个新的开关，位置就放在阅读器信息窗下面，名字叫做**首页三段按钮排序**，
 *   功能是调整三个按钮的排序，点击切换三个按钮，**六种组合**，该如何实现简洁的开关效果呢？
 *   我有个想法，这个开关由三个按钮组成，分别是最近，全部，和分组。用户无论是点击哪个，
 *   都会出现**子气泡**，有两种排列，如何判定呢，我们有个聪明办法，用户点击最近，
 *   那么出现的子气泡就是**最近为首的两种组合**，点击其他的则是同样逻辑，
 *   你是否理解。并且用户**应用后，这个开关下面会显示当前的排列**。」
 *
 * ══ 实现思路（完全按用户方案）════════════════════════════════════════════════
 * ① 一行三个按钮：最近 / 全部 / 分组；
 * ② 点某个按钮 → 弹出 `bindPopup` 子气泡，内容 = **以它为首的两种排列**：
 *      点「最近」→ `最近·全部·分组` / `最近·分组·全部`
 *      点「全部」→ `全部·最近·分组` / `全部·分组·最近`
 *      点「分组」→ `分组·最近·全部` / `分组·全部·最近`
 *    （共 3 × 2 = **6 种**，正好覆盖三元素全排列）
 * ③ 点子气泡里的一项 → 立即应用（落盘 + 广播），气泡自动关闭；
 * ④ 行下方常驻显示**当前排列**（如「当前：最近 · 全部 · 分组」）。
 *
 * ══ 为什么用 `bindPopup` 而不是 `bindMenu` ═══════════════════════════════════
 * · `bindMenu` 的面板底色/材质由系统接管、**没有颜色开关**
 *   （`MenuOptions` 只有 `title`/`showInSubWindow` 等，见 `IndexShelf` 的取证注释）；
 * · `bindPopup` 有 `popupColor`/`radius`/`shadow`/`backgroundBlurStyle` 等完整外观字段
 *   ⇒ 能做成与工程其它浮层一致的玻璃质感。
 * 本控件的子气泡是**自定义内容**（两行排列预览），用 `bindPopup` 更可控。
 *
 * ══ 状态同步 ═════════════════════════════════════════════════════════════════
 * 落盘走 `ShelfPrefs.setChipOrder()`；同时写 AppStorage 的 `SHELF_CHIP_ORDER`
 * ⇒ 书架 `GroupType` 用 `@StorageLink` 订阅，改完**立即重排**，无需重启。
 */
import { Haptics } from '../../common/utils/Haptics'
import UiMotion, { runJellyClick } from '../../common/utils/UiMotion'
import { NightMode } from '../../common/utils/NightMode'
import ShelfPrefs from '../../common/utils/ShelfPrefs'

/** 三种按钮的**语义下标**（与 `GroupType.CHIP_NAMES` 严格一致） */
const SEM_RECENT: number = 0
const SEM_ALL: number = 1
const SEM_GROUP: number = 2

/** 语义下标 → 显示名 */
const CHIP_NAMES: string[] = ['最近', '全部', '分组']

@Component
export struct ChipOrderSetting {
  /** 当前排列（语义下标的序列，长度 3）。初值从 ShelfPrefs 读，见 `aboutToAppear` */
  @State private order: number[] = [SEM_RECENT, SEM_ALL, SEM_GROUP]
  /** 当前展开子气泡的那个按钮的语义下标（-1 = 无） */
  @State private openSem: number = -1
  /** 三个按钮各自的 Q弹缩放（规范 §1：每键独立状态） */
  @State private scales: number[] = [1, 1, 1]

  aboutToAppear(): void {
    this.order = ShelfPrefs.getChipOrder()
  }

  /** 语义下标 → 显示名 */
  private nameOf(sem: number): string {
    return CHIP_NAMES[sem]
  }

  /** 当前排列的可读文案（如「最近 · 全部 · 分组」） */
  private orderText(): string {
    const parts: string[] = []
    for (const sem of this.order) {
      parts.push(this.nameOf(sem))
    }
    return parts.join(' · ')
  }

  /**
   * 以 `head` 为首的两种排列。
   *
   * 用户原话：「用户点击最近，那么出现的子气泡就是最近为首的两种组合」。
   * 三元素全排列共 6 种，按"首位"分组恰好每组 2 种 ⇒ 正好对上。
   */
  private combosWithHead(head: number): number[][] {
    const rest: number[] = []
    for (let sem = 0; sem <= 2; sem++) {
      if (sem !== head) {
        rest.push(sem)
      }
    }
    return [
      [head, rest[0], rest[1]],
      [head, rest[1], rest[0]]
    ]
  }

  /** 某个排列是否 == 当前排列（用于气泡里打勾） */
  private isCurrent(candidate: number[]): boolean {
    if (candidate.length !== this.order.length) {
      return false
    }
    for (let i = 0; i < candidate.length; i++) {
      if (candidate[i] !== this.order[i]) {
        return false
      }
    }
    return true
  }

  /** 应用某个排列：落盘 + 广播 + 关气泡 */
  private applyOrder(next: number[]): void {
    Haptics.tap()
    this.order = next
    // ① 落盘（跨启动保留）
    ShelfPrefs.setChipOrder(next)
    // ② 广播（书架立即重排；`GroupType` 用 @StorageLink 订阅）
    AppStorage.setOrCreate<string>('SHELF_CHIP_ORDER', next.join(','))
    // ③ 关气泡
    this.openSem = -1
  }

  /** 气泡内容：以 `head` 为首的两种排列 */
  @Builder
  ComboList(head: number) {
    Column({ space: 2 }) {
      ForEach(this.combosWithHead(head), (combo: number[], idx: number) => {
        Row({ space: 8 }) {
          Text(`${idx + 1}`)
            .fontSize(11)
            .fontColor(this.isCurrent(combo)
              ? this.themeMain()
              : $r('app.color.text_tertiary'))
            .width(14)
          Text(this.comboText(combo))
            .fontSize(13)
            .fontWeight(this.isCurrent(combo) ? 600 : 400)
            .fontColor(this.isCurrent(combo)
              ? this.themeMain()
              : (NightMode.isDarkSurface() ? 'rgba(248,249,250,0.88)' : 'rgba(0,0,0,0.88)'))
            .layoutWeight(1)
          if (this.isCurrent(combo)) {
            SymbolGlyph($r('sys.symbol.checkmark'))
              .fontSize(13)
              .fontColor([this.themeMain()])
          }
        }
        .width('100%')
        .padding({ left: 8, right: 8, top: 8, bottom: 8 })
        .borderRadius(8)
        .clickEffect(UiMotion.CLICK)
        .onClick(() => {
          this.applyOrder(combo)
        })
      }, (combo: number[], idx: number): string => 'combo_' + head + '_' + idx + '_' + combo.join(''))
    }
    .width(200)
    .padding(6)
  }

  /** 排列的可读文案 */
  private comboText(combo: number[]): string {
    const parts: string[] = []
    for (const sem of combo) {
      parts.push(this.nameOf(sem))
    }
    return parts.join(' · ')
  }

  /** 主题主色（选中/打勾用） */
  private themeMain(): string {
    return (AppStorage.get<ResourceStr>('theme') as string) ?? '#FF95A8'
  }

  @Builder
  ChipButton(sem: number, index: number) {
    Text(this.nameOf(sem))
      .fontSize(13)
      .fontWeight(500)
      .fontColor(NightMode.isDarkSurface() ? 'rgba(248,249,250,0.88)' : 'rgba(0,0,0,0.88)')
      .textAlign(TextAlign.Center)
      .layoutWeight(1)
      .height(32)
      .borderRadius(16)
      .backgroundColor(NightMode.isDarkSurface()
        ? 'rgba(255,255,255,0.10)'
        : 'rgba(0,0,0,0.05)')
      .scale({
        x: this.scales.length > index ? this.scales[index] : 1,
        y: this.scales.length > index ? this.scales[index] : 1
      })
      .clickEffect(UiMotion.CLICK)
      .onClick(() => {
        Haptics.tap()
        runJellyClick((v: number) => {
          const next: number[] = this.scales.slice()
          if (index < next.length) {
            next[index] = v
            this.scales = next
          }
        })
        // 点同一个按钮再点一次 = 收起气泡（符合直觉）
        this.openSem = (this.openSem === sem) ? -1 : sem
      })
      .bindPopup(this.openSem === sem, {
        builder: this.ComboList(sem),
        placement: Placement.Bottom,
        popupColor: NightMode.isDarkSurface() ? '#2C2C30' : '#FFFFFF',
        radius: 12,
        // 与工程其它浮层同一档模糊（`glassOptions` 的配方语言）
        backgroundBlurStyle: BlurStyle.COMPONENT_THICK,
        onStateChange: (e) => {
          if (!e.isVisible && this.openSem === sem) {
            this.openSem = -1
          }
        }
      })
  }

  build() {
    Column({ space: 8 }) {
      Row({ space: 6 }) {
        ForEach([SEM_RECENT, SEM_ALL, SEM_GROUP], (sem: number, index: number) => {
          this.ChipButton(sem, index)
        }, (sem: number): string => 'chipbtn_' + sem)
      }
      .width('100%')

      // ── 当前排列（用户：「应用后，这个开关下面会显示当前的排列」）──────────
      Row({ space: 4 }) {
        Text('当前：')
          .fontSize(12)
          .fontColor($r('app.color.text_tertiary'))
        Text(this.orderText())
          .fontSize(12)
          .fontWeight(500)
          .fontColor(NightMode.isDarkSurface()
            ? 'rgba(248,249,250,0.62)'
            : 'rgba(0,0,0,0.62)')
      }
      .width('100%')
    }
    .width('100%')
  }
}
