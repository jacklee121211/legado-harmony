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
   * 当前排序档位。默认「最近阅读」——
   * 需求第 3 条：「最近只有一种排序就是最近↓」，即默认状态与「最近」一致。
   */
  static getSortKey(): SortKey {
    if (!ShelfPrefs.ENABLED) {
      return SortKey.RECENT_READ;
    }
    try {
      const v = PreferencesUtil.getSync(ShelfPrefs.K_SORT_KEY,
        SortKey.RECENT_READ as number, ShelfPrefs.PREF_NAME);
      const n: number = typeof v === 'number' ? v : SortKey.RECENT_READ;
      return (n >= 0 && n <= SortKey.FILE_SIZE) ? n as SortKey : SortKey.RECENT_READ;
    } catch (e) {
      return SortKey.RECENT_READ;
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
