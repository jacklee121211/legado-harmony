/**
 * 列表 / 宫格「渐次入场」波次控制器（2026-09-24 新增）。
 *
 * ── 它解决什么问题 ────────────────────────────────────────────────────────
 * 需求有两面，且互相牵制：
 *   ① **视觉**：冷启动进入书架时，书本要「陆续出现」（渐次入场）。
 *      ⚠️ 2026-10-19 用户口径收紧：**只有冷启动**保留这个效果 ——
 *      从其他 dock 切回书架 / 切分组标签 / 切列表↔宫格 一律不再重播（见文件末「只在冷启动播一次」段）。
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
 * AppStorage 键 `shelfAnimSpeed`，值 0~6（档位）。
 *   0 = 关闭动画（波次不播）；3 = 默认档（BASE=90, STEP=48, DUR=380）。
 * `speedMultiplier()` 把档位映射到 0~1.5 倍率（档位 × 0.25）。
 * ⚠️ 2026-10-19：设置页的「书架动画速度」滑块**整项已删除**（用户要求"这个书架动画速度不要了"），
 *   `MySetPage` 不再读写本键 ⇒ 实际生效的是默认档 3（0.75x）。
 *   若 AppStorage 里残留老值（老版本写入过），`speedMultiplier()` 仍会照读 —— 这是**特意保留**的
 *   最小改动口径（本类与书架渲染侧一行未动，删设置项不会影响入场动画本身）。
 *
 * ── 只在冷启动播一次（2026-10-19 用户要求）────────────────────────────────
 * 用户原话：「只保留冷启动进入动画，进入后 dock 切换回书架，书架书籍无需动画。」
 * 实现：`begin()` 先过 `allowColdStartWave()` 闸门 —— 进程内**首个** begin() 开启一个
 * `COLD_WINDOW_MS` 的冷启动窗口，窗口内的 begin() 都算"冷启动那一波"（冷启动时
 * 书列表 / 文件夹 / 书单可能几乎同时各调一次）；窗口关掉之后，本进程内**任何** begin()
 * 一律不生效。
 * 被闸掉的 begin() **不改** `running` / `startTs` ⇒ `delayFor()` 自然返回 -1
 * ⇒ 子组件（`BookInfos` / `BookInfoGrids`）收到 -1 就把 `entered` 置 true
 * **直接以终态渲染，一帧动画都不产生**（依据：`BookInfos.ets:72-75` 的 `delayMs < 0` 分支）。
 * 一键回退：把 `COLD_START_ONLY` 改 `false` ⇒ 完全恢复旧行为
 * （切分类 / 切分组 / dock 切回书架都会重播）。
 */
export class EntranceWave {
  /** AppStorage 键：动画速度档位（0~6；3 = 默认 0.75x，0 = 关闭；映射见 `speedMultiplier()`） */
  static readonly SPEED_KEY: string = 'shelfAnimSpeed';

  /** 基准参数（标准速度下的值，会被 speedMultiplier 缩放） */
  static readonly STEP_MS_BASE: number = 48;
  static readonly BASE_MS_BASE: number = 90;
  static readonly CAP: number = 15;
  static readonly DUR_MS_BASE: number = 380;

  // ── 只在冷启动播一次（2026-10-19）──────────────────────────────────────────
  /**
   * 一键回退开关（本工程惯例）：
   *   `true`  = 只在**冷启动**播一波入场（当前口径，用户 2026-10-19 要求）；
   *   `false` = 恢复旧行为 —— 每次切分类 / 切分组 / dock 切回书架都会重播。
   */
  static readonly COLD_START_ONLY: boolean = true;

  /**
   * 冷启动窗口时长（ms）：从进程内**第一次** `begin()` 起算。
   * 为什么要窗口而不是"首个 begin() 独占"：冷启动时书列表（`BookContent.getBookList`）、
   * 文件夹（`BookFolder.getGroupList`）、书单（`WorksBookLists.getWorkLists`）都可能在
   * 同一帧前后各开一次波，若只放行第一个，其余视图会突然"硬渲染"，冷启动观感不一致。
   * 取值 1500ms ≈ 默认档一整波的总时长（120 + 15×64 + 507 ≈ 1587ms），
   * 既覆盖同一次绘制的多次 begin，又不会把用户随后的切分类误判成冷启动。
   */
  private static readonly COLD_WINDOW_MS: number = 1500;

  /** 冷启动窗口截止时刻（0 = 本进程还没开过波） */
  private static coldWindowEnd: number = 0;

  /**
   * 本次 `begin()` 是否还属于"冷启动入场"（2026-10-19）。
   * @returns true = 放行（并可能开启冷启动窗口）；false = 本进程的冷启动波次已过，不重播。
   */
  static allowColdStartWave(): boolean {
    if (!EntranceWave.COLD_START_ONLY) {
      return true;
    }
    const now: number = Date.now();
    if (EntranceWave.coldWindowEnd === 0) {
      EntranceWave.coldWindowEnd = now + EntranceWave.COLD_WINDOW_MS;
      return true;
    }
    return now <= EntranceWave.coldWindowEnd;
  }

  /**
   * 当前错峰步长（ms），已应用速度倍率。
   * 2026-09-24 调参：用户真机反馈「太快了，稍微调慢一点」⇒ 30 → 48。
   */
  get STEP_MS(): number {
    const m = EntranceWave.speedMultiplier();
    return m <= 0 ? 999999 : Math.round(EntranceWave.STEP_MS_BASE / m);
  }
  /** 当前首项延迟（ms），已应用速度倍率 */
  get BASE_MS(): number {
    const m = EntranceWave.speedMultiplier();
    return m <= 0 ? 999999 : Math.round(EntranceWave.BASE_MS_BASE / m);
  }
  /** 当前单项入场动画时长（ms），已应用速度倍率 */
  get DUR_MS(): number {
    const m = EntranceWave.speedMultiplier();
    return m <= 0 ? 999999 : Math.round(EntranceWave.DUR_MS_BASE / m);
  }

  /**
   * 从 AppStorage 读动画速度档位（0~6），映射为倍率（0~1.5）。
   *   0: 关闭动画  |  1: 0.25x  |  2: 0.5x  |  3: 0.75x（默认）
   *   4: 1.0x      |  5: 1.25x  |  6: 1.5x
   * @returns 倍率（0~1.5），默认 0.75（档位 3）
   */
  static speedMultiplier(): number {
    const level: number = AppStorage.get<number>(EntranceWave.SPEED_KEY) ?? 3;
    const clamped = Math.max(0, Math.min(6, level));
    return clamped * 0.25;
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
   *   · `BookContent.onDockReturn()` → dock 切回书架；
   *   · `BookFolder.getGroupList()`、`WorksBookLists.getWorkLists()` 同理。
   *
   * ⚠️ 2026-10-19（用户要求「只保留冷启动进入动画」）：以上调用点**全部**先过
   *    `allowColdStartWave()` 闸门 —— 只有冷启动那一波真正开得起来，
   *    之后（dock 切回书架 / 切分类 / 切分组 / 进文件夹 / 切书单）一律不播。
   */
  begin(): void {
    if (!EntranceWave.allowColdStartWave()) {
      // 冷启动波次已过 ⇒ 不重播。
      // ⚠️ 这里**刻意不改** `running` / `startTs`：不改动才能让 `delayFor()` 按当前
      //    （已结束的）波次如实返回 -1，子组件随即直接以终态渲染；
      //    若在这里把 running 置 true 又不开 startTs，反而可能算出错误延迟。
      return;
    }
    this.startTs = Date.now();
    this.running = true;
  }

  /** 当前是否处于有效波次时间窗内。 */
  isRunning(): boolean {
    if (EntranceWave.speedMultiplier() <= 0) {
      return false;
    }
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
    if (EntranceWave.speedMultiplier() <= 0) {
      return -1;
    }
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
