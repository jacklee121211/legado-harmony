/**
 * 书架偏好持久化（2026-10-19 新增）。
 *
 * ── 为什么要单独一个类 ────────────────────────────────────────────────────
 * 需求（用户 2026-10-19）：
 *   · 「默认进入是宫格显示，而不再是列表，并且切换做好持久化，而不是每次都重置为列表」
 *   · 「全部这一行也需要记录用户的点击持久化…避免每次进入重置」
 *   · 排序面板「做好持久化」
 * ⇒ 三样都是**跨进程存活**的界面偏好，必须落 Preferences，不能只放 `@State`。
 *
 * ── 为什么用 `PreferencesUtil` 而不是自己 new preferences ──────────────────
 * 工程既有入口 `@pura/harmony-utils` 的 `PreferencesUtil.getSync/putSync` 已经被
 * `FileHandler.ets:162,206` 用在同一套"书籍数据"命名空间里（`CommonConstants.PREFERENCES_BOOK_DATA_KEY`），
 * 复用它 = 与既有偏好同库同 flush 语义，不再引入第二种持久化姿势。
 * 取证：`oh_modules/.ohpm/@pura+harmony-utils@1.3.2/.../utils/PreferencesUtil.ets:79-84`
 *   `static putSync(key, value, preferenceName = defaultPreferenceName)` —— 内部已 `flush()`
 *   （原文注释：「此处一定要flush，要不然不能永久序列化到本地」）；
 *   `:105-109` `static getSync(key, defValue, preferenceName)`。
 *
 * ── 一键回退 ──────────────────────────────────────────────────────────────
 * 每个 getter 都有默认值兜底；把 `ENABLED` 改成 `false` ⇒ 全部返回默认值
 * （宫格、分组「最近」、排序「最近阅读↓」），等同于"不读持久化"。
 */
import { PreferencesUtil } from '@pura/harmony-utils';
import CommonConstants from '../constants/CommonConstants';

/** 书架展示形态（列表 / 宫格） */
export enum ExhibitMode {
  LIST = 0,
  GRID = 1
}

/**
 * 书架排序档位（2026-10-19 新增，需求第 6 条）。
 *
 * ⚠️ 每个档位是**双向**的：`SortKey` 只表达"按什么排"，方向单独用 `SortDir` 表达。
 * 用户原话：「排序都是双向的，点击之后↑/↓可以切换」。
 */
export enum SortKey {
  /** 首字母（用官方 `intl.Collator('zh-Hans', { collation: 'pinyin' })` 比较） */
  PINYIN = 0,
  /** 导入时间（`books.createTime`） */
  IMPORT_TIME = 1,
  /** 最近阅读（`books.durChapterTime`，0 用 createTime 兜底，与既有 SQL 口径一致） */
  RECENT_READ = 2,
  /** 格式（`books.bookUrl` 的扩展名） */
  FORMAT = 3,
  /** 文件大小（`books.fileSize`） */
  FILE_SIZE = 4
}

/** 排序方向 */
export enum SortDir {
  ASC = 0,
  DESC = 1
}

export default class ShelfPrefs {
  /**
   * 总开关（一键回退点）：false ⇒ 所有读取都拿默认值，不写不读持久化。
   */
  static readonly ENABLED: boolean = true;

  // ── Preferences key（前缀统一，避免与既有书源/书名等偏好撞名）──────────────
  private static readonly K_EXHIBIT: string = 'shelf_exhibit_grid';
  private static readonly K_SORT_KEY: string = 'shelf_sort_key';
  private static readonly K_SORT_DIR: string = 'shelf_sort_dir';
  /**
   * 「最近」分组的 groupId 持久化。
   * 需求第 3 条：「用户后续点击之后，都是有持久化的，避免每次进入重置」。
   */
  private static readonly K_CURRENT_CHIP: string = 'shelf_current_chip_id';
  /** 顶栏「三段开关 + 三图标」是否融合成一条（2026-10-21，见 isHeaderMerged 的注释） */
  private static readonly K_HEADER_MERGED: string = 'shelf_header_merged';
  /** 顶栏三段按钮排列（2026-10-21，见 getChipOrder 的注释） */
  private static readonly K_CHIP_ORDER: string = 'shelf_chip_order';
  /** 宫格一行显示几本（2026-10-23；0 = 自动跟随断点，见 autoColumns 注释） */
  private static readonly K_GRID_COLUMNS: string = 'shelf_grid_columns';

  /** 偏好文件与既有书籍数据同一个（见文件头说明） */
  private static readonly PREF_NAME: string = CommonConstants.PREFERENCES_BOOK_DATA_KEY;

  // ── 展示形态 ────────────────────────────────────────────────────────────

  /**
   * 是否宫格。
   * 需求第 2 条：「默认进入是宫格显示，而不再是列表」⇒ 默认 `true`。
   */
  static isGrid(): boolean {
    if (!ShelfPrefs.ENABLED) {
      return true;
    }
    try {
      const v = PreferencesUtil.getSync(ShelfPrefs.K_EXHIBIT, true, ShelfPrefs.PREF_NAME);
      return v === true;
    } catch (e) {
      return true;
    }
  }

  static setGrid(grid: boolean): void {
    if (!ShelfPrefs.ENABLED) {
      return;
    }
    try {
      PreferencesUtil.putSync(ShelfPrefs.K_EXHIBIT, grid, ShelfPrefs.PREF_NAME);
    } catch (e) {
      // 持久化失败不影响当前会话的界面（状态仍在内存里）
    }
  }

  // ── 宫格「一行显示几本」（2026-10-23 多端适配新增）──────────────────────
  //
  // ── 为什么要这一套 ────────────────────────────────────────────────────────
  //   旧实现把列数**写死**在 `BookContent.ets`：`.lanes(this.EXHIBIT === '宫格' ? 3 : 1)`
  //   ⇒ 手机/平板/2in1、横屏/竖屏全是 3 列。平板横屏（实测 1244vp 宽）下
  //   每格约 400vp，封面比手机还大 ⇒ 一屏只能看 3×3，用户反馈「显示太少」。
  //
  // ── 取值规则（官方规格 + 本项目基线）──────────────────────────────────────
  //   ① **自动档**（用户没手动调过，`userCols <= 0`）：跟随横向断点
  //      `sm=3 / md=4 / lg=5 / xl=6`。
  //      · 规格来源：技能 `hmos-multidevice-screen-window-size` 的
  //        `references/responsive_layout.md` →「RESP-01 重复布局」网格列数 sm/md/lg。
  //      · 但同一文档紧接着有一条**硬性规则**「列数递增原则」原文：
  //        「若原始设计（直板机/SM断点）为 N 列，则 md = N+1，lg = N+2」
  //        本项目原始基线就是 **3 列**（手机现状，不能改），
  //        所以这里取 3/4/5（而不是把手机缩成 2 列的通用值 2/3/4）。
  //        ⇒ **手机端永远是 3 列，零回归**（`sm` 档与旧写死值完全相同）。
  //      · `xl`（PC/2in1 全屏）按同一递增规律 +1 = 6。
  //   ② **手动档**（用户在设置页拖过滑块，`userCols > 0`）：直接用用户值，
  //      不再跟随断点 —— 这是用户明确要的「自己定义的机会」。
  //   ③ 断点取不到（冷启动极早期，键还没写入）⇒ 回落 `sm` 的 3 列，
  //      与旧行为完全一致，不会出现"一进书架列数乱跳"。
  //
  // ── 为什么用 `ShelfPrefs` 而不是新开一个类 ────────────────────────────────
  //   它已经是书架界面偏好的唯一落盘点（同库同 flush 语义），
  //   宫格列数属于同一类偏好，放在一起才不会出现"两套持久化姿势"。
  /** 用户手动设定的列数下限（低于 2 列在平板上没有意义） */
  static readonly COLUMNS_MIN: number = 2;
  /** 用户手动设定的列数上限（再多封面就小到看不清书名） */
  static readonly COLUMNS_MAX: number = 8;

  /**
   * 自动档：按横向断点给出列数。
   * @param bp `currentBreakpoint` 的值（`xs`/`sm`/`md`/`lg`/`xl`）
   * @returns 3 / 4 / 5 / 6（未知或缺失一律 3，与旧写死值一致）
   */
  static autoColumns(bp: string): number {
    if (bp === 'md') {
      return 4;
    }
    if (bp === 'lg') {
      return 5;
    }
    if (bp === 'xl') {
      return 6;
    }
    // sm / xs / 空串 / 未知 ⇒ 3（手机基线，绝不回归）
    return 3;
  }

  /** 读取用户手动设定的列数；`<= 0` 表示"自动"（默认 0） */
  static getUserColumns(): number {
    if (!ShelfPrefs.ENABLED) {
      return 0;
    }
    try {
      const v = PreferencesUtil.getSync(ShelfPrefs.K_GRID_COLUMNS, 0, ShelfPrefs.PREF_NAME);
      const n: number = typeof v === 'number' ? Math.round(v) : 0;
      return n <= 0 ? 0 : (n < ShelfPrefs.COLUMNS_MIN ? ShelfPrefs.COLUMNS_MIN
        : (n > ShelfPrefs.COLUMNS_MAX ? ShelfPrefs.COLUMNS_MAX : n));
    } catch (e) {
      return 0;
    }
  }

  /** 写入用户手动设定的列数；传 `0` = 恢复自动（跟随断点） */
  static setUserColumns(n: number): void {
    if (!ShelfPrefs.ENABLED) {
      return;
    }
    try {
      const v: number = n <= 0 ? 0 : Math.round(n);
      PreferencesUtil.putSync(ShelfPrefs.K_GRID_COLUMNS, v, ShelfPrefs.PREF_NAME);
      // 同步到 AppStorage：书架 `BookContent` 用 `@StorageProp` 订阅它 ⇒ 改完立即重排，
      // 不必等下次进书架（否则用户拖完滑块回书架还是旧列数）。
      AppStorage.setOrCreate(ShelfPrefs.KEY_GRID_COLUMNS_STORAGE, v);
    } catch (e) {
    }
  }

  /**
   * **最终列数**（书架唯一取值入口）。
   * @param userCols `@StorageProp` 里的用户值（0 = 自动）
   * @param bp 当前横向断点
   */
  static effectiveColumns(userCols: number, bp: string): number {
    if (userCols > 0) {
      return userCols;
    }
    return ShelfPrefs.autoColumns(bp);
  }

  /** AppStorage 键：宫格列数（设置页写、书架读；与持久化键分离，见 setUserColumns） */
  static readonly KEY_GRID_COLUMNS_STORAGE: string = 'shelfGridColumns';

  // ── 当前选中的分组 chip ──────────────────────────────────────────────────

  /**
   * 当前选中的分组 groupId。
   *
   * 需求第 3 条：「首次安装默认都是在最近」⇒ 默认返回 `undefined`，
   * 由调用方解释成「最近」那个虚拟 chip（它不是数据库里的分组，见 GroupType 注释）。
   */
  static getCurrentChipId(): number | undefined {
    if (!ShelfPrefs.ENABLED) {
      return undefined;
    }
    try {
      const v = PreferencesUtil.getSync(ShelfPrefs.K_CURRENT_CHIP, -1, ShelfPrefs.PREF_NAME);
      const n: number = typeof v === 'number' ? v : -1;
      return n < 0 ? undefined : n;
    } catch (e) {
      return undefined;
    }
  }

  static setCurrentChipId(id: number | undefined): void {
    if (!ShelfPrefs.ENABLED) {
      return;
    }
    try {
      PreferencesUtil.putSync(ShelfPrefs.K_CURRENT_CHIP,
        id === undefined ? -1 : id, ShelfPrefs.PREF_NAME);
    } catch (e) {
    }
  }

  /** 当前是否停在「最近」这个虚拟 chip 上（默认是） */
  static isRecentChip(): boolean {
    return ShelfPrefs.getCurrentChipId() === undefined;
  }

  // ── 排序 ────────────────────────────────────────────────────────────────

  /**
   * 当前排序档位。**默认「导入时间」**（2026-10-22 用户口径，上架前定稿）。
   *
   * ⚠️ 历史口径变更：
   *   · 2026-10-19：默认 `RECENT_READ`（理由：「最近只有一种排序就是最近↓」）；
   *   · 2026-10-22：改为 `IMPORT_TIME`（用户原话：「书籍排序默认是导入时间」）。
   *   只改默认值，不改任何查询口径 —— `BooksDao.buildOrderByClause(1, desc)` 早就存在，
   *   且 `search()` 未传 sortKey 时的旧回落分支用的就是「导入时间降序」
   *   （`BooksDao.ets:229` `this.buildOrderByClause(1, true)`）⇒ 行为一致、零迁移。
   *   ⚠️ 默认值只在**本地从未写过该键**时生效（`getSync(key, def)` 语义）⇒ 用户调过的不受影响。
   */
  static getSortKey(): SortKey {
    if (!ShelfPrefs.ENABLED) {
      return SortKey.IMPORT_TIME;
    }
    try {
      const v = PreferencesUtil.getSync(ShelfPrefs.K_SORT_KEY,
        SortKey.IMPORT_TIME as number, ShelfPrefs.PREF_NAME);
      const n: number = typeof v === 'number' ? v : SortKey.IMPORT_TIME;
      return (n >= 0 && n <= SortKey.FILE_SIZE) ? n as SortKey : SortKey.IMPORT_TIME;
    } catch (e) {
      return SortKey.IMPORT_TIME;
    }
  }

  static setSortKey(key: SortKey): void {
    if (!ShelfPrefs.ENABLED) {
      return;
    }
    try {
      PreferencesUtil.putSync(ShelfPrefs.K_SORT_KEY, key as number, ShelfPrefs.PREF_NAME);
    } catch (e) {
    }
  }

  /** 当前排序方向。默认↓（与「最近阅读」默认排序一致） */
  static getSortDir(): SortDir {
    if (!ShelfPrefs.ENABLED) {
      return SortDir.DESC;
    }
    try {
      const v = PreferencesUtil.getSync(ShelfPrefs.K_SORT_DIR,
        SortDir.DESC as number, ShelfPrefs.PREF_NAME);
      const n: number = typeof v === 'number' ? v : SortDir.DESC;
      return n === SortDir.ASC ? SortDir.ASC : SortDir.DESC;
    } catch (e) {
      return SortDir.DESC;
    }
  }

  static setSortDir(dir: SortDir): void {
    if (!ShelfPrefs.ENABLED) {
      return;
    }
    try {
      PreferencesUtil.putSync(ShelfPrefs.K_SORT_DIR, dir as number, ShelfPrefs.PREF_NAME);
    } catch (e) {
    }
  }

  /** 一次性写入排序（档位 + 方向），减少两次 flush */
  static setSort(key: SortKey, dir: SortDir): void {
    ShelfPrefs.setSortKey(key);
    ShelfPrefs.setSortDir(dir);
  }

  // ── 顶栏融合模式（2026-10-21 新增）──────────────────────────────────────────

  /**
   * 顶栏「三段开关 + 三图标胶囊」是否**拼成一整条**（融合），还是分开两段。
   *
   * 用户原话：「现在三开关和三按钮拼在一起了，我建议两种方案，第一种缩短三开关的长短，
   *   在保持两边一样的距离屏幕的距离情况下，三开关向左侧缩短一些，保持与三按钮分离的效果。
   *   另一种直接拼在一起，胶囊拼在一起。两种都做，然后在设置页定时显示开关下面，
   *   增加一个三段开关+三按钮胶囊融合开关，进行切换显示效果。」
   *
   * · `false`（默认）= **分离式**：开关缩短、与右侧图标胶囊之间留出空隙，左右距屏幕相等；
   * · `true` = **融合式**：两者贴合，视觉上是一条连续的玻璃胶囊。
   */
  static isHeaderMerged(): boolean {
    if (!ShelfPrefs.ENABLED) {
      return false;
    }
    try {
      const v = PreferencesUtil.getSync(ShelfPrefs.K_HEADER_MERGED, false, ShelfPrefs.PREF_NAME);
      return v === true;
    } catch (e) {
      return false;
    }
  }

  static setHeaderMerged(merged: boolean): void {
    if (!ShelfPrefs.ENABLED) {
      return;
    }
    try {
      PreferencesUtil.putSync(ShelfPrefs.K_HEADER_MERGED, merged, ShelfPrefs.PREF_NAME);
    } catch (e) {
    }
  }

  // ── 顶栏三段按钮排序（2026-10-21 新增）──────────────────────────────────────

  /**
   * 顶栏三段按钮的排列顺序。
   *
   * 用户原话：「首页三段按钮排序…调整三个按钮的排序，点击切换三个按钮，六种组合…
   *   用户点击最近，那么出现的子气泡就是**最近为首的两种组合**，点击其他的则是同样逻辑。
   *   并且用户应用后，这个开关下面会显示当前的排列。」
   *
   * 存储形式：三个 chip 的**下标序列**（对应 `GroupType.chipLabels()` 的原始顺序
   * `['最近','全部','分组']`），以字符串 `"0,1,2"` 落盘。
   * 默认 `"0,1,2"` = 最近·全部·分组（改造前的固定顺序）。
   *
   * ⚠️ 为什么存下标而不是名字：名字将来若改文案（如"最近"→"最近阅读"），
   *   下标仍然稳定；且解析时可以直接用于数组重排。
   */
  static getChipOrder(): number[] {
    const DEFAULT_ORDER: number[] = [0, 1, 2];
    if (!ShelfPrefs.ENABLED) {
      return DEFAULT_ORDER;
    }
    try {
      const v = PreferencesUtil.getSync(ShelfPrefs.K_CHIP_ORDER, '0,1,2', ShelfPrefs.PREF_NAME);
      const raw: string = typeof v === 'string' ? v : '0,1,2';
      const parts: string[] = raw.split(',');
      const out: number[] = [];
      for (const p of parts) {
        const n: number = Number(p);
        // 只接受 0/1/2 且不重复，否则视为脏数据 → 回退默认
        if (!isNaN(n) && n >= 0 && n <= 2 && out.indexOf(n) < 0) {
          out.push(n);
        }
      }
      return out.length === 3 ? out : DEFAULT_ORDER;
    } catch (e) {
      return DEFAULT_ORDER;
    }
  }

  static setChipOrder(order: number[]): void {
    if (!ShelfPrefs.ENABLED) {
      return;
    }
    if (order.length !== 3) {
      return;
    }
    try {
      PreferencesUtil.putSync(ShelfPrefs.K_CHIP_ORDER, order.join(','), ShelfPrefs.PREF_NAME);
    } catch (e) {
    }
  }
}
