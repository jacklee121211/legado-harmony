import { ThemeStorageKey } from '../../common/constants/Theme'
import { Haptics } from '../../common/utils/Haptics';
import { ThemeItem } from '../../common/model/Theme'
import bookGroupUtil from '../../common/utils/bookGroupUtils'
import BookGroupsDao from '../../database/dao/BookGroupsDao'
import { BookGroups } from '../../database/entities/BookGroups'
import FolderInfoDialog from '../../pages/view/bookShelf/components/dialog/FolderInfoDialog'
import UiMotion, { runJellyClick } from '../../common/utils/UiMotion'
import ImmersiveMaterialUtil, { MaterialColumnModifier } from '../../common/utils/ImmersiveMaterialUtil'
import { NightMode } from '../../common/utils/NightMode'

/**
 * 五个系统基础单元（2026-10-01 用户定义，**位置锁定、顺序恒定**）：
 *   全部 → 本地 → 书单 → 分组 → 未分组
 * 2026-10-13 起本常量只用于**判定**（哪些 chip 点击无反馈 / 不画眼睛 / 不许隐藏），
 * 不改变渲染顺序 —— 顺序仍与父级 `GroupType.sortSystemChips` 一致（五要素在前）。
 */
const BASE_UNIT_NAMES: string[] = ['全部', '本地', '书单', '分组', '未分组']

/**
 * 书架 → 分组行尾部「三横」→ 本面板（`GroupManageDialog` 的内容层）。
 *
 * ══ 2026-10-13 用户改版（本次，只动弹窗，**书架那一行原封不动**）══════════════════
 * 用户原话：
 *  「点击更多按钮出现的弹窗中所有分组点击不再出现半屏弹窗，默认五要素点击之后不需要有
 *    任何反馈，所有自定义分组点击后，直接进入隐藏分组，隐藏分组点击后恢复正常分组。
 *    右上角管理按钮直接取消。」
 *  「所有自定义分组右上角的X改成symbol的eye，睁眼表示未隐藏，闭眼表示隐藏，也就是和防窥
 *    的图标一样。」
 *  「简单来说，这个管理页面，只负责一个功能，就是进行自定义分组的隐藏和释放，因为半屏
 *    弹窗我们实际上用不上。」
 *
 * ⇒ 结构（两栏）**保持原样**：显示分组 / 隐藏分组。删掉的东西与理由：
 *   ① **半屏弹窗**：点击 chip 不再"进入分组"（`bindSheet` + `BookManageDialog` 整块删除，
 *      连带 `clickGroup` / `isShowBookFolderInfoDialog` / `bookFolderInfoDialog()`）；
 *   ② **「管理 / 完成」开关**：用户「右上角管理按钮直接取消」。它同时是拖拽排序的开关，
 *      而拖拽落点 `changeIndex()` 一直是 TODO（只打日志、不写库）⇒ 一并删除，不留假功能；
 *   ③ **隐藏/恢复前的二次确认框**（`hideDialogExample`）：用户要「点击后**直接**进入隐藏
 *      分组」⇒ 点击即生效，中间不再夹"确定隐藏吗"。
 *
 * ── X → eye（符号已核实，不是猜的）────────────────────────────────────────
 * 用户要求「和防窥的图标一样」⇒ 沿用阅读页防窥那一对（`ReaderPage3.ets:1817`）：
 *   · `sys.symbol.eye`       = 睁眼 = **未隐藏**（在「显示分组」栏）
 *   · `sys.symbol.eye_slash` = 闭眼 = **已隐藏**（在「隐藏分组」栏）
 * 符号存在性证据（SDK 真源 `sysResource.js`，非打包快照）：
 *   `sdk/default/openharmony/ets/build-tools/ets-loader/sysResource.js`
 *     `eye: 125832271,`
 *     `eye_slash: 125832272,`
 *
 * ── 点击行为矩阵 ────────────────────────────────────────────────────────
 * | 位置              | 点击                     | 长按            |
 * | 显示分组·五要素   | **完全无反馈**（不挂 onClick） | 无            |
 * | 显示分组·自定义   | 隐藏（移入隐藏分组）      | 无              |
 * | 隐藏分组          | 恢复（移回显示分组）      | 编辑（FolderInfoDialog）|
 */
@Component
export default struct groupTypePanel {
  /**
   * ⚠️ 2026-09-23：原来这里是 `@Link groupCoverShow: boolean`（面板直接把它置 false 来关自己）。
   * 现在本面板是 `@CustomDialog` 的**内容**（见 `GroupManageDialog.ets`），关窗必须走
   * `controller.close()`，所以改成**回调**，由调用方去关。
   */
  onClose: () => void = (): void => {}
  /**
   * 底色兜底 + 材质分支让位（工程既有实现，说明见 `ImmersiveMaterialUtil.ets:390-459`）。
   * · 材质可用 ⇒ 本方法**什么都不做**，背景由弹窗层（`systemMaterial`）画；
   * · 材质不可用 / 总开关关闭 ⇒ 落回 **白色实底**，绝不会"透明露底"。
   */
  private surface: MaterialColumnModifier = new MaterialColumnModifier(Color.White, true)
  /** 右上角 ✕ 的 Q弹缩放（规范第 1 节三件套：SymbolGlyph + Haptics + runJellyClick） */
  @State closeScale: number = 1
  /** 打开瞬间的快照（父级最近一次查询结果，已按"五要素在前"排过序）——只为让首帧成型 */
  @Prop showGroupList: BookGroups[] = []
  @Prop currentIndex: number = 0
  /**
   * 面板自持的全量分组（2026-10-13 新增）。
   * 为什么不能只用 `@Prop showGroupList`：@Prop 是**创建瞬间快照**，点一下隐藏之后它不会变
   * ⇒ 分组会"点了没反应、要关掉弹窗再开"（规范 4.4 表格同款坑）。
   */
  @State allGroups: BookGroups[] = []
  /** 长按编辑的分组（走 `FolderInfoDialog`） */
  @State dialogGroupData: BookGroups = new BookGroups()
  // 主题颜色
  @StorageProp(ThemeStorageKey.THEME) theme: ThemeItem = {} as ThemeItem
  /** App 级夜间开关：只为触发重绘（取色走下面的 `fgMain/fgSub/chipBg`），理由见 `IndexShelf` 同名字段 */
  @StorageLink(NightMode.KEY) nightOn: boolean = false
  /** 分组变更广播键（规范第 5 节：改完必须广播，书架分组行 `GroupType` 在听） */
  @StorageLink('BOOK_IS_BOOK_GROUPS_REFRESHING') BOOK_IS_BOOK_GROUPS_REFRESHING: number = 0

  /**
   * 主文字色 / 次级文字色 / 淡色块底 —— 夜间必须自己翻，否则是**黑字压深底**。
   *
   * 为什么不能靠 `$r('app.string.color_black_*')` 的 dark 限定词：本面板这两处用的是
   * **字面量** `rgba(0,0,0,…)`（不是资源），限定词目录管不到。
   * 本面板唯一的宿主是 `GroupManageDialog`（书架 → 分组管理）⇒ 恒属"书架深色档"，
   * 直接读全局夜间开关是安全的。
   */
  private fgMain(): string {
    return NightMode.isDarkSurface() ? 'rgba(248, 249, 250, 0.88)' : 'rgba(0, 0, 0, 0.88)';
  }

  private fgSub(): string {
    return NightMode.isDarkSurface() ? 'rgba(248, 249, 250, 0.45)' : 'rgba(0, 0, 0, 0.45)';
  }

  private chipBg(): string {
    return NightMode.isDarkSurface() ? 'rgba(255, 255, 255, 0.10)' : 'rgba(0, 0, 0, 0.04)';
  }

  aboutToAppear(): void {
    // ① 先用父级快照成型（避免"打开瞬间列表是空的，过一会儿才刷出来"——工程老问题）
    this.allGroups = this.showGroupList.slice()
    // ② 再以库为准重查（父级快照可能是几分钟前的）
    this.reload()
  }

  /**
   * 重查本大类的全部分组（含隐藏），写入 `allGroups`。
   * 排序用 `sortChips()`，与父级 `GroupType.sortSystemChips()` **同一条规则**
   * （五要素在前、其余按库里的相对顺序），保证本面板与书架那一行的 chip 顺序一致。
   */
  private reload(): void {
    BookGroupsDao.search({
      type: this.currentIndex
    }).then((val: BookGroups[]) => {
      this.allGroups = this.sortChips(val)
    })
  }

  private sortChips(list: BookGroups[]): BookGroups[] {
    const systems: BookGroups[] = []
    for (const name of BASE_UNIT_NAMES) {
      const hit = list.find((g: BookGroups) => g.isSystem && g.groupName === name)
      if (hit !== undefined) {
        systems.push(hit)
      }
    }
    const result: BookGroups[] = []
    for (const g of systems) {
      result.push(g)
    }
    for (const g of list) {
      if (!systems.includes(g)) {
        result.push(g)
      }
    }
    return result
  }

  /** 是不是五个系统基础单元（`isSystem` + 名字在白名单里）⇒ 点击无反馈 / 不画眼睛 / 不许隐藏 */
  private isBaseUnit(item: BookGroups): boolean {
    return item.isSystem && BASE_UNIT_NAMES.includes(item.groupName)
  }

  /** 「显示分组」栏 = 所有 `show = true` 的分组（五要素 + 自定义），顺序与原实现一致 */
  private visibleGroups(): BookGroups[] {
    return this.allGroups.filter((g: BookGroups) => g.show)
  }

  /** 「隐藏分组」栏 = 所有 `show = false` 的分组 */
  private hiddenGroups(): BookGroups[] {
    return this.allGroups.filter((g: BookGroups) => !g.show)
  }

  /**
   * 点击分组 = 隐藏 ⇄ 恢复（本面板唯一功能）。
   *
   * 顺序很关键（规范第 5 节第 2 条「广播必须发生在 DB 提交之后」）：
   *   ① 面板内**先**乐观更新 ⇒ 手指抬起就能看到它跳到另一栏（不等异步写库）；
   *   ② `await` 落库 ⇒ 然后才重查 + 广播。
   *   反例（本次一并修掉）：`bookGroupUtil.updateGroupShow` 原实现是 `forEach` 裸调 DAO
   *   （不 await），调用方立刻重查会读到**旧** `show` ⇒ "点了没反应，重开弹窗才对"。
   */
  private toggleShow(item: BookGroups): void {
    const id: number | undefined = item.groupId
    if (id === undefined) {
      return
    }
    Haptics.tap()
    const next: boolean = !item.show
    // ① 乐观更新：改对象 + **换数组引用**（只改对象属性不会触发本次 build）
    item.show = next
    this.allGroups = this.allGroups.slice()
    // ② 落库 → 重查 → 广播
    bookGroupUtil.updateGroupShow(id, next).then(() => {
      this.reload()
      this.BOOK_IS_BOOK_GROUPS_REFRESHING++
    })
  }

  /** 长按隐藏分组 → 编辑（改名 / 删除；隐藏中的分组**只有**这里能编辑） */
  private editGroup(item: BookGroups): void {
    Haptics.tap()
    this.dialogGroupData = item
    this.groupInfoDialog?.open()
  }

  groupInfoDialog: CustomDialogController | null = new CustomDialogController({
    builder: FolderInfoDialog({
      itemData: this.dialogGroupData,
      // 真开真关（2026-10-01 用户方案）：子关闭→重查→open，全新实例=全新快照
      reopen: (): void => { this.reopenGroupInfoDialog() },
      // ⚠️ 必须用箭头包一层：旧写法 `cancel: this.exitDialog` 把方法**脱绑**传出去，
      //   回调里 `this` 不再指向本组件（工程内同类坑见规范 4.4 表格）
      cancel: (): void => {
        this.exitDialog()
      }
    }),
    cancel: (): void => {
      this.exitDialog()
    },
    autoCancel: true,
    // 2026-09-25 用户反馈：长按编辑弹窗与全局统一 —— 居中 + 四圆角 + 标准宽
    // （原 Bottom/100%/customStyle:true 是贴底老款式）。customStyle:false 时弹窗层
    // 才有背景，systemMaterial 才有处附着（工程 2026-09-22 真机结论）。
    width: '80%',
    alignment: DialogAlignment.Center,
    customStyle: false,
    cornerRadius: 20,
    systemMaterial: ImmersiveMaterialUtil.sheetMaterial(),

  })

  //退出弹框
  exitDialog(): void {
    this.groupInfoDialog?.close()
    // 改名 / 删除 / 改隐藏态都会影响两栏归属 ⇒ 关子弹窗后重查
    this.dialogGroupData = new BookGroups()
    this.reload()
    this.BOOK_IS_BOOK_GROUPS_REFRESHING++
  }

  /** 真开真关（2026-10-01 用户方案）：重查该分组 → 更新 dialogGroupData → open。 */
  private async reopenGroupInfoDialog(): Promise<void> {
    const id = this.dialogGroupData.groupId
    if (id !== undefined) {
      const groups: BookGroups[] = await BookGroupsDao.search({ type: this.currentIndex })
      const fresh = groups.find((g: BookGroups) => g.groupId === id)
      if (fresh !== undefined) {
        this.dialogGroupData = fresh
      }
    }
    this.groupInfoDialog?.open()
  }

  build() {
    Column({
      space: 15
    }) {
      Flex({
        justifyContent: FlexAlign.SpaceBetween,
        alignItems: ItemAlign.End
      }) {
        Row({ space: 12 }) {
          Text('显示分组').fontSize(16).fontWeight(500).lineHeight(24).fontColor(this.fgMain())
          // 2026-10-13：原「点击进入」—— 点击语义已改为"隐藏"，提示同步改。
          // 五要素点击仍然无任何反馈（既不隐藏也不跳转），见两个 ForEach 的 onClick 守卫。
          Text('点击隐藏').fontSize(12).fontWeight(400).lineHeight(20).fontColor(this.fgSub())
        }.alignItems(VerticalAlign.Bottom)

        Row({ space: 12 }) {
          // ── 2026-10-13：「管理 / 完成」文字开关已删（用户：「右上角管理按钮直接取消」）──
          // v3.20：关闭 X 换 SymbolGlyph + 主题色——原 `app.media.close` 位图为固定深色，
          // 深色模式下不可观测（用户反馈）。`xmark` 经 SDK 符号表核实存在。
          SymbolGlyph($r('sys.symbol.xmark'))
            .fontSize(20)
            .fontColor([this.theme.mainColor])
            .scale({ x: this.closeScale, y: this.closeScale })
            .clickEffect(UiMotion.CLICK)
            .onClick(() => {
              Haptics.tap();
              runJellyClick((v: number) => {
                this.closeScale = v
              })
              this.onClose()
            })
        }
      }

      Flex({
        direction: FlexDirection.Row, wrap: FlexWrap.Wrap,
        justifyContent: FlexAlign.Start
      }) {
        ForEach(this.visibleGroups(), (item: BookGroups, index: number) => {
          Row() {
            if (index === 0) {
              this.GroupTypeColor(item.groupName)
            } else {
              this.GroupType(item.groupName)
            }
            if (!this.isBaseUnit(item)) {
              // 2026-10-13：X（`app.media.clear`）→ `sys.symbol.eye`（睁眼＝未隐藏）。
              // 位置沿用原来的 `offset({ x: -20, y: -20 })`（**不改布局/比例**，只换图标），
              // 并且自己带 onClick —— 与 chip 本体同一个动作（同一个 hit 只派发一次，
              // 不会"点一次翻两次"）。
              SymbolGlyph($r('sys.symbol.eye'))
                .fontSize(12)
                .fontColor([this.theme.mainColor])
                .offset({ x: -20, y: -20 })
                .onClick(() => {
                  this.toggleShow(item)
                })
            }
          }
          .width('25%')
          .onClick(() => {
            // 用户：「默认五要素点击之后不需要有任何反馈」⇒ 五要素**连 onClick 效果都没有**
            // （不是"点了弹提示"，是完全不动）。
            if (!this.isBaseUnit(item)) {
              this.toggleShow(item)
            }
          })
        }, (item: BookGroups): string => item.groupId !== undefined
          // 键值并入显示字段（规范 5.3）：改名 / 隐藏态变化都必须换键，否则 ForEach 复用旧组件。
          ? 'g' + item.groupId + item.groupName + (item.show ? 'S' : 'H')
          : item.groupName)
      }

      Flex({
        justifyContent: FlexAlign.SpaceBetween,
        alignItems: ItemAlign.End
      }) {
        Row({ space: 12 }) {
          Text('隐藏分组').fontSize(16).fontWeight(500).lineHeight(24).fontColor(this.fgMain())
          Text('点击恢复，长按编辑').fontSize(12).fontWeight(400).lineHeight(20).fontColor(this.fgSub())
        }.alignItems(VerticalAlign.Bottom)
      }

      if (this.hiddenGroups().length > 0) {
        Flex({
          direction: FlexDirection.Row, wrap: FlexWrap.Wrap, alignContent: FlexAlign.Center
        }) {
          ForEach(this.hiddenGroups(), (item: BookGroups) => {
            Row() {
              this.GroupType(item.groupName)
              // 2026-10-13：`app.media.add_new_fill` → `sys.symbol.eye_slash`（闭眼＝已隐藏），
              // 位置沿用原 `offset({ x: -20, y: -20 })`。
              SymbolGlyph($r('sys.symbol.eye_slash'))
                .fontSize(12)
                .fontColor([this.theme.mainColor])
                .offset({ x: -20, y: -20 })
                .onClick(() => {
                  this.toggleShow(item)
                })
            }
            .onClick(() => {
              // 用户：「隐藏分组点击后恢复正常分组」⇒ 点击即恢复（不再有确认框、不再开半屏）
              this.toggleShow(item)
            })
            .gesture(
              LongPressGesture({ repeat: false, duration: 500 })
                .onAction(() => {
                  this.editGroup(item)
                }))
            .width('25%')
          }, (item: BookGroups): string => item.groupId !== undefined
            ? 'h' + item.groupId + item.groupName + (item.show ? 'S' : 'H')
            : 'h' + item.groupName)
        }
      } else {
        Flex({
          justifyContent: FlexAlign.Center
        }) {
          Text('暂无隐藏分组').fontSize(12).fontWeight(400).fontColor(this.fgSub())
        }
        .borderRadius(4)
        .width('100%')
        .backgroundColor(this.chipBg())
        .padding({ top: 6, bottom: 6 })

      }
    }
    .borderRadius({ bottomLeft: 20, bottomRight: 20 })
    .padding({
      left: 15,
      right: 15,
      top: 12,
      bottom: 20
    })
    .width('100%')
    // ⚠️ 2026-09-23：原来这里是 `.backgroundColor(Color.White)` —— **写死纯白**，
    //   这就是用户说的「这个模块没有沉浸光感材质」的直接原因：
    //   ① 它原本只是 Stack 里的一个自绘 Column，**不在沉浸光感的生效范围内**；
    //   ② 而且写死的背景色会把材质层整个盖住（官方 FAQ「背景色或背景模糊遮挡材质效果」原文：
    //      「沉浸光感的视觉层级位于组件的 backgroundColor、backgroundBlurStyle 等属性**之下**。
    //        如果同时设置了不透明的背景色或背景模糊样式，这些属性会覆盖在材质层之上」）。
    //   ⇒ 现在材质由弹窗层 options 提供（`GroupManageDialog` 的 `systemMaterial`），
    //     本层交给 `MaterialColumnModifier`：材质可用时不设任何背景，不可用时回落白色实底。
    .attributeModifier(this.surface)
  }

  // ── 以下两个 chip 绘制与 2026-10-13 之前**完全一致**（只换了右上角图标）──────

  @Builder
  GroupTypeColor(title: string) {
    Column() {
      Row() {
        Text(title)
          .fontWeight(500)
          .fontSize(12)
          .textOverflow({
            overflow: TextOverflow.Ellipsis
          })
          .ellipsisMode(EllipsisMode.END)
          .maxLines(1)
          .fontColor(this.theme.mainColor)
          .textAlign(TextAlign.Center)
      }
      .margin({ right: 16, bottom: 16 })
      .justifyContent(FlexAlign.Center)
      .alignItems(VerticalAlign.Center)
      .width(68)
      .backgroundColor(this.theme.secondColor)
      .padding({
        left: 16,
        right: 16,
        top: 6,
        bottom: 6
      })
    }
  }

  @Builder
  GroupType(title: string) {
    Column() {
      Row() {
        Text(title)
          .fontWeight(500)
          .fontSize(12)
          .textOverflow({
            overflow: TextOverflow.Ellipsis
          })
          .ellipsisMode(EllipsisMode.END)
          .maxLines(1)
          .fontColor(this.fgMain())
          .textAlign(TextAlign.Center)
      }
      .margin({ right: 16, bottom: 16 })
      .justifyContent(FlexAlign.Center)
      .alignItems(VerticalAlign.Center)
      .width(68)
      .backgroundColor(this.chipBg())
      .padding({
        left: 16,
        right: 16,
        top: 6,
        bottom: 6
      })
    }
  }
}
