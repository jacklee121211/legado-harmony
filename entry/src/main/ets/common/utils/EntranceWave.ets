/**
 * 列表 / 宫格「渐次入场」波次控制器（2026-09-24 新增）。
 *
 * ── 它解决什么问题 ────────────────────────────────────────────────────────
 * 需求有两面，且互相牵制：
 *   ① **视觉**：冷启动 / 切分组标签 / 切列表↔宫格 / 从其他 dock 回到书架 时，
 *      书本要「陆续出现」（渐次入场）。
 *   ② **性能**：书架可能有上百本。用户没看完的、波次已经结束之后才滚进屏幕的书，
 *      **不应该**再走一遍入场动画（否则每滑一下都"闪一下"，还白烧 GPU）。
 *
 * 把「这一波什么时候开始、持续多久」集中到一个对象里，每个列表项自己去问
 * `delayFor(index)`，于是：
 *   · 波次进行中 → 返回「还应等多少毫秒」⇒ 该项按错峰延迟入场；
 *   · 波次已结束 → 返回 **-1** ⇒ 该项**根本不播动画**，直接以终态渲染。
 *
 * ── 官方依据 ──────────────────────────────────────────────────────────────
 * · 官方 FAQ `faqs-arkui-1136`（《LazyForEach渲染的List列表上滑触发刷新动画》）原文：
 *   「LazyForEach 从提供的数据源中按需迭代数据…当组件滑出可视区域外时，框架会进行组件销毁回收…
 *     因此当 List 往下滑动，滚动出可视区域的列表项就会被销毁回收，当再往上回到顶部时，
 *     实际上会重新创建列表项，就会出现上滑过程中触发刷新动画。」
 *   官方给出的方案就是一个**开关变量** `@State showItemAnimation: boolean`，
 *   在 `transition(...)` 里写 `this.showItemAnimation ? <动画> : null`。
 *   本类把那个"开关"升级成"带时间窗的开关"，从而支持需求里的**错峰**与**自动结束**。
 * · 官方指南 `arkts-enter-exit-transition`（《出现/消失转场》）原文：
 *   「对多个组件添加转场效果时，可以在 animation 动画参数中配置不同的 delay 值，
 *     实现组件渐次出现消失的效果」。
 *   并给出官方示例参数：`const ITEM_COUNTS = 9; const INTERVAL = 30; const DURATION = 300;`
 *   ⇒ 本类的 `STEP_MS = 30` 直接对齐官方示例的 `INTERVAL`。
 *
 * ── 为什么是"一屏封顶"（CAP）────────────────────────────────────────────
 * 如果按绝对下标线性叠加延迟，第 100 本的延迟 = 60 + 100×30 = 3060ms，
 * 而它**此刻根本不在屏幕上**（LazyForEach 还没创建它），等到用户滚到它时波次早结束了。
 * 所以延迟按"一屏槽位"封顶：`min(index, CAP)`。一屏约 15 项（列表 6~7 项 + 预加载，
 * 宫格 3 列 5 行），超过这个数就与第 CAP 项同时入场。
 *
 * ── 速度倍率（2026-10-12）─────────────────────────────────────────────────
 * 用户可从设置页调节动画速度：AppStorage 键 `shelfAnimSpeed`，值 -2~+2。
 *   0 = 标准速度（BASE=90, STEP=48, DUR=380）；
 *   +2 = 2x 快（所有时长 ÷ 2）；-2 = 0.5x 慢（所有时长 × 2）。
 * `speedMultiplier()` 把 -2~+2 映射到 0.5~2.0，线性插值。
 */
export class EntranceWave {
  /** AppStorage 键：动画速度档位（-2~+2，0=标准） */
  static readonly SPEED_KEY: string = 'shelfAnimSpeed';

  /** 基准参数（标准速度下的值，会被 speedMultiplier 缩放） */
  static readonly STEP_MS_BASE: number = 48;
  static readonly BASE_MS_BASE: number = 90;
  static readonly CAP: number = 15;
  static readonly DUR_MS_BASE: number = 380;

  /**
   * 当前错峰步长（ms），已应用速度倍率。
   * 2026-09-24 调参：用户真机反馈「太快了，稍微调慢一点」⇒ 30 → 48。
   */
  get STEP_MS(): number {
    return Math.round(EntranceWave.STEP_MS_BASE / EntranceWave.speedMultiplier());
  }
  /** 当前首项延迟（ms），已应用速度倍率 */
  get BASE_MS(): number {
    return Math.round(EntranceWave.BASE_MS_BASE / EntranceWave.speedMultiplier());
  }
  /** 当前单项入场动画时长（ms），已应用速度倍率 */
  get DUR_MS(): number {
    return Math.round(EntranceWave.DUR_MS_BASE / EntranceWave.speedMultiplier());
  }

  /**
   * 从 AppStorage 读动画速度档位（-2~+2），映射为倍率（0.5~2.0）。
   * 线性插值：0 → 1.0, +2 → 2.0, -2 → 0.5。
   * @returns 倍率（0.5~2.0），默认 1.0
   */
  static speedMultiplier(): number {
    const level: number = AppStorage.get<number>(EntranceWave.SPEED_KEY) ?? 0;
    const clamped = Math.max(-2, Math.min(2, level));
    // -2 → 0.5, 0 → 1.0, +2 → 2.0  线性: 1.0 + clamped * 0.5
    return 1.0 + clamped * 0.5;
  }

  private startTs: number = 0;
  private running: boolean = false;

  /**
   * 一整波的总时长（ms）：首项延迟 + 错峰 + 单项动画。
   * 当前参数下 = BASE_MS + 15×STEP_MS + DUR_MS。
   * 想要更快/更慢，设置页滑块调整速度档位即可，本方法自动跟随。
   */
  private totalMs(): number {
    return this.BASE_MS + EntranceWave.CAP * this.STEP_MS + this.DUR_MS;
  }

  /**
   * 开启一波。
   *
   * 调用点（**都在"数据刚准备好、马上要重渲染"的那一刻**，不要提前调：
   * 波次起点与渲染起点之间的间隔会让延迟整体缩水）：
   *   · `BookContent.getBookList()` 拿到数据后 → 冷启动 / 切分类 / 切分组 / 下拉刷新；
   *   · `BookFolder.getGroupList()`、`WorksBookLists.getWorkLists()` 同理。
   */
  begin(): void {
    this.startTs = Date.now();
    this.running = true;
  }

  /** 当前是否处于有效波次时间窗内。 */
  isRunning(): boolean {
    return this.running && (Date.now() - this.startTs) < this.totalMs();
  }

  /**
   * 取某一项的入场延迟。
   *
   * @returns
   *   `>= 0`：还应等待的毫秒数（0 表示"立刻入场，但仍走动画"）；
   *   `-1`  ：**这一波已经结束** ⇒ 调用方应当**完全不播动画**，直接以终态渲染。
   */
  delayFor(index: number): number {
    if (!this.isRunning()) {
      return -1;
    }
    const elapsed: number = Date.now() - this.startTs;
    const target: number = this.BASE_MS
      + Math.min(index, EntranceWave.CAP) * this.STEP_MS;
    const remain: number = target - elapsed;
    return remain > 0 ? remain : 0;
  }
}

/**
 * 书架列表 / 宫格 / 文件夹 / 书单**共用**的同一波次。
 *
 * 为什么共用一个实例而不是每个页面各一个：这些视图在同一个 Tabs 里互相切换
 * （`BookContentRefresh` 按 `bookTypeNumber` 分流），切过去的一瞬间
 * 「全部 / 未分组 / 本地 / 书单 / 浏览历史」只应有一波。
 */
export const shelfEntrance: EntranceWave = new EntranceWave();
