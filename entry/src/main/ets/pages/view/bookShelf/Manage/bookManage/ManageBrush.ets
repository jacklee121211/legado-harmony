/**
 * 批量管理页「手势划选」几何与状态机（2026-10-25 新增）。
 *
 * ══════════════════════════════════════════════════════════════════════════
 * 用户需求（原话）
 * ══════════════════════════════════════════════════════════════════════════
 *   「批量管理状态下，我们只能一个个点击书籍，并且只能点击书籍的选择圈，这个不对…
 *     整个书籍全能被点击选中或取消，不仅仅是选择圈。并且支持手势滑动批量选择…
 *     就像是系统相册一样…用户不仅能点击一个进行选择取消，用可以跟随手势滑动，
 *     批量的选择取消。」
 *
 * ══════════════════════════════════════════════════════════════════════════
 * 为什么需要这个类（官方没有现成的"拖选"API）
 * ══════════════════════════════════════════════════════════════════════════
 * 官方文档检索结论（`devecocli docs search`）：
 *   · `List`/`Grid` 的"选中"只有 `Checkbox` / `GridItem` 拖拽交换
 *     （`开发指南/…/Grid网格元素拖拽/arkts-grid-element-drag-exchange`）——
 *     那是**拖拽排序**，不是"划过多选"；
 *   · `Checkbox` 多选只有"点选/全选/反选"三个 FAQ
 *     （`FAQ/…/Checkbox多选_反选_全选场景实现方案/faqs-arkui-1202`）；
 *   ⇒ **没有**"手指划过连续选中"的一等公民 API，必须自己用「几何命中 + 手势」实现。
 *
 * ══════════════════════════════════════════════════════════════════════════
 * 官方依据（两条，都是 SDK/官方文档原文）
 * ══════════════════════════════════════════════════════════════════════════
 * ① **坐标语义**（SDK `component/gesture.d.ts:656-677` 原文）：
 *      「localX: X-coordinate relative to the upper left corner of the current
 *        component's original area, in vp.」
 *    ⇒ 绑在**容器**上的 `PanGesture`，其 `event.fingerList[0].localX/localY`
 *      就是"相对该容器左上角"的坐标，和格子矩形同一坐标系，可直接命中判定。
 * ② **格子矩形**（SDK `component/common.d.ts:23977-23980` 对 `onAreaChange` 的 `Area` 原文）：
 *      「Information after the area change, including the width, height,
 *        **coordinates relative to the parent element**, and position coordinates
 *        of the upper-left corner in the current window coordinate system.」
 *    ⇒ 把 `onAreaChange` 挂在**格子的父容器**（GridRow / Column）的直接子节点上，
 *      `newValue.position` 就是"相对父容器"的坐标 ⇒ 与 ① 的 `localX/localY` 同源。
 * ③ **为什么必须"长按后再拖"**（官方 FAQ `faqs-arkui-827`「如何处理PanGesture与其他
 *    手势冲突问题」原文）：
 *      「方案：使用手势组合模式，通过 LongPressGesture 和 PanGesture 实现拖拽的效果，
 *        **在长按手势识别后才能顺序识别滑动手势**。」
 *    ⇒ 这正是本文件配套的 `GestureGroup(GestureMode.Sequence, LongPress, Pan)` 写法：
 *      竖向单指快滑仍然归 `Scroll` 滚动，**只有"按住不动 → 再划"才进入划选**，
 *      两者不会互相抢（否则整页都划不动了）。
 *
 * ══════════════════════════════════════════════════════════════════════════
 * 行为口径（与系统相册一致）
 * ══════════════════════════════════════════════════════════════════════════
 *   · **起手那格决定方向**：起手格当前**未选中** ⇒ 本次划选全部**选中**；
 *     起手格当前**已选中** ⇒ 本次划选全部**取消**。（相册同款：从已选的往下划是取消）
 *   · 同一次划选里，每一格**只写一次**（`applied` 去重），手指来回划不会反复翻转。
 *   · 抬手 / 手势取消 ⇒ 会话结束，下一次重新判定方向。
 *
 * ⚠️ 本类是**纯逻辑**（不带 @Observed / 不驱动 UI）：
 *   视觉更新由调用方通过 AppStorage 版本号广播（见 `BookManagePage.bumpSelectionVersion()`），
 *   这样划选过程只走"重渲染"而不是"重建组件"（重建会让封面图闪）。
 */
/**
 * AppStorage 键：批量管理「勾选状态版本号」。
 *
 * ── 为什么需要它 ──────────────────────────────────────────────────────────
 * 格子的勾选视觉由各自组件内的 `@State checked` 驱动（这样单击只重渲染**自己**）。
 * 但下面三种变化**不是某个格子自己点出来的**，必须让**所有**格子重新对齐数据：
 *   ① 全选 / 取消全选（`dataMoveCheckList`）；
 *   ② 划选（本文件 `applyHits` 批量写 `checkGroup`）；
 *   ③ 操作后刷新列表但保留勾选（`reloadListKeepSelection`）。
 * ⇒ 统一把本键 +1，各格子 `@StorageProp` + `@Watch` 回读 `checkGroup[id]` 即可。
 *
 * ⚠️ 为什么不用 `@Prop` 一层层往下传：格子组件在 `bookListManage` /
 *   `BookFolderManages` 里被 ForEach 生成，逐层透传要改 3 个文件 4 个组件；
 *   AppStorage 是本工程既有的跨组件广播通道（如 `BOOK_IS_BOOK_REFRESHING`），同款即可。
 */
export const MANAGE_SEL_VERSION_KEY: string = 'MANAGE_SEL_VERSION'

/** 广播一次"勾选状态变了"（非本格自己触发的变化都走这里） */
export function bumpSelectionVersion(): void {
  const cur: number = AppStorage.get<number>(MANAGE_SEL_VERSION_KEY) ?? 0
  AppStorage.setOrCreate<number>(MANAGE_SEL_VERSION_KEY, cur + 1)
}

/** 一个格子的矩形（相对划选容器左上角，单位 vp） */
export class BrushRect {
  id: number;
  x1: number;
  y1: number;
  x2: number;
  y2: number;

  constructor(id: number, x1: number, y1: number, x2: number, y2: number) {
    this.id = id;
    this.x1 = x1;
    this.y1 = y1;
    this.x2 = x2;
    this.y2 = y2;
  }
}

export default class ManageBrush {
  /** 当前可见格子的矩形表（由调用方在 onAreaChange 里维护） */
  private rects: BrushRect[] = [];
  /** 本次划选已写过的 id（去重，避免来回划反复翻转） */
  private applied: number[] = [];
  /** 本次划选的目标状态（true = 选中，false = 取消） */
  private target: boolean = true;
  /** 会话是否进行中 */
  private active: boolean = false;

  /** 清空矩形表（列表数据整体重建时调用） */
  clearRects(): void {
    this.rects = [];
  }

  /** 记录/更新一个格子的矩形（同 id 覆盖） */
  record(rect: BrushRect): void {
    for (let i = 0; i < this.rects.length; i++) {
      if (this.rects[i].id === rect.id) {
        this.rects[i] = rect;
        return;
      }
    }
    this.rects.push(rect);
  }

  /** 会话是否进行中（调用方据此决定要不要锁滚动 / 显示提示） */
  isActive(): boolean {
    return this.active;
  }

  /** 命中测试：返回落点下的所有格子 id（矩形可重叠，比如网格空隙处可能 0 个） */
  private hitTest(x: number, y: number): number[] {
    const hits: number[] = [];
    for (let i = 0; i < this.rects.length; i++) {
      const r: BrushRect = this.rects[i];
      if (x >= r.x1 && x <= r.x2 && y >= r.y1 && y <= r.y2) {
        hits.push(r.id);
      }
    }
    return hits;
  }

  /** 把目标状态写进"还没写过的"命中格；返回本次新写入的格子数 */
  private applyHits(hits: number[], apply: (id: number, checked: boolean) => void): number {
    let changed = 0;
    for (let i = 0; i < hits.length; i++) {
      const id: number = hits[i];
      if (this.applied.indexOf(id) >= 0) {
        continue;
      }
      this.applied.push(id);
      apply(id, this.target);
      changed++;
    }
    return changed;
  }

  /**
   * 起手（长按识别成功那一刻）。
   * @param x/y 相对容器的坐标（`event.fingerList[0].localX/localY`）
   * @param isChecked 读取某格当前是否已选中（用来决定本次是"选"还是"取消"）
   * @param apply 落盘回调（写 checkGroup）
   * @returns 是否成功起手（落点不在任何格子上 ⇒ false，本次不划选）
   */
  begin(x: number, y: number, isChecked: (id: number) => boolean,
    apply: (id: number, checked: boolean) => void): boolean {
    const hits: number[] = this.hitTest(x, y);
    if (hits.length === 0) {
      this.active = false;
      return false;
    }
    // 起手格决定方向：未选 ⇒ 本次全选；已选 ⇒ 本次全取消
    this.target = !isChecked(hits[0]);
    this.applied = [];
    this.active = true;
    this.applyHits(hits, apply);
    return true;
  }

  /** 划动中：返回本次新写入的格子数（0 = 手指还在同一格里，调用方可跳过广播） */
  update(x: number, y: number, apply: (id: number, checked: boolean) => void): number {
    if (!this.active) {
      return 0;
    }
    return this.applyHits(this.hitTest(x, y), apply);
  }

  /** 抬手 / 取消 */
  end(): void {
    this.active = false;
    this.applied = [];
  }
}
