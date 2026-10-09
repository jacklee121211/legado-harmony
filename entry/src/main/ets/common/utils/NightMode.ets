import { common, ConfigurationConstant } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { WindowAbility } from '../../entryability/WindowAbility';

/**
 * App 级「亮色 / 自动 / 暗色」三档体系 —— 全工程唯一的状态与配色开关。
 * （2026-09-23 亮暗色重构：原"夜间布尔开关"升级为三档，并与阅读器日/夜间彻底解耦。）
 *
 * ── 用户拍板的四条规则（2026-09-23）─────────────────────────────────────────
 * ① App 级三档：**亮色 / 自动 / 暗色**，入口在「我的-主题」页顶部；
 *    "自动"实时跟随系统（系统切换回调 → 即时重涂）。
 * ② 阅读器里叫**日间 / 夜间**，不跟三档走：新书默认日间，用户手动切换，
 *    按书持久化（`ReaderSetting_<书名>.nightMode`，原有机制不变）。
 *    —— 理由：App 选"自动"且现在是白天（书架亮色），用户进书点夜间想要暗一点，
 *       退回书架若跟着变暗就不合理。
 * ③ 看书期间，弹窗/材质/系统栏这些"书页以外"的配色**临时跟随阅读器日/夜间**，
 *    退出自动还原成 App 三档的裁决（弹窗才不会和书页违和）。
 * ④ 旧的 `appNightMode` 布尔持久值**作废**（它曾被阅读器日夜键误写污染），默认"自动"。
 *
 * ── 派生规则 desiredDark()───────────────────────────────────────────────────
 *   阅读器在栈顶  ⇒ 阅读器的日/夜间（readerNight）
 *   其余一切界面  ⇒ 三档：dark ⇒ 深；light ⇒ 浅；auto ⇒ 跟系统（sysColorMode）
 * （旧版"我的页签强制浅色 / 书架推了子页回浅色"的规则随全端适配完成而废止。）
 *
 * ── 键位 ────────────────────────────────────────────────────────────────────
 * · `MODE_KEY`('appThemeMode')：三档本体，**持久化**（新键，与旧 appNightMode 无关）。
 * · `KEY`('appNightMode')：**键名沿用、语义改为"派生的有效深色"（内存，不再持久化）**——
 *   全工程十几处 `@StorageLink(NightMode.KEY)` 订阅点（Index / group/* / head/*）无需改动，
 *   值翻转即驱动它们重绘。旧磁盘上的布尔残留被内存值覆盖，等于作废（规则④）。
 * · `SYS_KEY`('sysColorMode')：系统深浅色真相（EntryAbility.onConfigurationUpdate 维护）。
 *   ⚠️ `ctx.setColorMode()` 自己也会触发一次配置回调（回声），`onSystemColorModeChange`
 *   里用 `applied` 把回声滤掉，否则"自动"档会被自己的下发改写。
 * · `READER_KEY`/`READER_NIGHT_KEY`：阅读器在栈顶 + 它当前的日/夜间。
 *
 * ── 状态栏图标色 ────────────────────────────────────────────────────────────
 * 此前只有冷启动设过一次 `statusBarContentColor`，之后从不更新。现在 `sync()` 在
 * "有效深浅"变化时调 `WindowAbility.setStatusBarContentColor()` 联动。
 *
 * ── 一键回退 ────────────────────────────────────────────────────────────────
 * 把 `NightMode.ENABLED` 改成 `false` ⇒ 全工程永远不调 `setColorMode`，
 * 所有页面走日间分支（`isDarkSurface()` 恒 false）。
 */
export class NightMode {
  /**
   * **总开关（一键回退点）**。
   * `false` ⇒ 一次都不调 `setColorMode`，`isDarkSurface()` 恒为 false ⇒ 所有页面都走日间分支。
   */
  static readonly ENABLED: boolean = true;

  /**
   * 派生的「当前界面是否深色」（**内存**键）。
   * 键名沿用历史的 `'appNightMode'`：全工程十几处 `@StorageLink(NightMode.KEY)` 订阅点
   * 不需要改动；值语义已从"用户开关"变为"派生的有效深色"，且**不再持久化**。
   */
  static readonly KEY: string = 'appNightMode';
  /** 三档模式（**持久化**）：`MODE_LIGHT` / `MODE_AUTO` / `MODE_DARK` */
  static readonly MODE_KEY: string = 'appThemeMode';
  static readonly MODE_LIGHT: string = 'light';
  static readonly MODE_AUTO: string = 'auto';
  static readonly MODE_DARK: string = 'dark';
  /** 系统深浅色真相（`ConfigurationConstant.ColorMode`：0=暗 1=亮；回调维护） */
  static readonly SYS_KEY: string = 'sysColorMode';
  /** 阅读器是否在栈顶（决定 `desiredDark()` 走阅读器分支） */
  static readonly READER_KEY: string = 'readerActive';
  /** 阅读器当前的日/夜间（true=夜间；仅 readerActive 时有意义） */
  static readonly READER_NIGHT_KEY: string = 'readerNight';
  /** 当前底部页签下标（0 = 书架，1 = 我的）；由 `pages/Index.ets` 维护（保留键位，暂不参与裁决） */
  static readonly TAB_KEY: string = 'mainTabIndex';
  /** 书架 NavBar 可见性（`Navigation.onNavBarStateChange` 维护；保留键位，暂不参与裁决） */
  static readonly HOME_KEY: string = 'navHomeVisible';

  /** 上一次真正下发给 UIAbility 的配色（`-99` = 还没下发过） */
  private static applied: number = -99;
  /** 上一次下发的派生深色（null = 还没下发过）；变了才写 KEY/状态栏，避免订阅点空转 */
  private static lastDark: boolean | null = null;
  /**
   * sync 重入闸 + 补跑标记。`ctx.setColorMode()` 会**同步重入** `onConfigurationUpdate`
   * （真机故障栈实证，2026-09-23 JSCrash RangeError: Stack overflow）⇒ 重入期间再调 sync
   * 不能直接执行（会无限递归），但也不能白白丢掉 —— 置 `pendingSync`，外层收尾时补跑一次
   * （状态收敛，最多补跑一轮）。
   */
  private static syncing: boolean = false;
  private static pendingSync: boolean = false;

  /**
   * 冷启动初始化（在 `EntryAbility.onWindowStageCreate()` 的 `loadContent` **之前**调用）。
   * 这里**只建状态**，`setColorMode` 一律等页面加载后由各页面调 `sync()`。
   */
  static init(): void {
    // 三档模式要**跨启动保留**（用户选了暗色，第二天打开还该是暗色）。
    // 旧的 'appNightMode' 布尔持久值不再读取 = 作废（规则④），默认"自动"。
    PersistentStorage.persistProp<string>(NightMode.MODE_KEY, NightMode.MODE_AUTO);
    AppStorage.setOrCreate<number>(NightMode.SYS_KEY, ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT);
    AppStorage.setOrCreate<boolean>(NightMode.READER_KEY, false);
    AppStorage.setOrCreate<boolean>(NightMode.READER_NIGHT_KEY, false);
    AppStorage.setOrCreate<number>(NightMode.TAB_KEY, 0);
    AppStorage.setOrCreate<boolean>(NightMode.HOME_KEY, true);
    // 派生值初值（内存键，覆盖磁盘上的旧布尔残留）
    AppStorage.setOrCreate<boolean>(NightMode.KEY, false);
  }

  /** 当前三档模式（'light' | 'auto' | 'dark'） */
  static getMode(): string {
    const m = AppStorage.get<string>(NightMode.MODE_KEY);
    return (m === NightMode.MODE_LIGHT || m === NightMode.MODE_DARK) ? m : NightMode.MODE_AUTO;
  }

  /** 用户在三档开关上选择（「我的-主题」页调用）；ctx 用于立刻下发 */
  static setMode(mode: string, ctx: common.UIAbilityContext | undefined): void {
    AppStorage.setOrCreate<string>(NightMode.MODE_KEY, mode);
    NightMode.sync(ctx);
  }

  /** 系统深浅色回调入口（`EntryAbility.onConfigurationUpdate` 调用）。回声过滤见 SYS_KEY 注释。 */
  static onSystemColorModeChange(colorMode: ConfigurationConstant.ColorMode | undefined): void {
    if (colorMode === undefined || colorMode === NightMode.applied) {
      // 这是我们自己 `setColorMode` 触发的配置回声，不是系统切换 —— 不能当"系统真相"记录，
      // 否则"自动"档会被阅读器期间的临时配色污染。
      return;
    }
    AppStorage.setOrCreate<number>(NightMode.SYS_KEY, colorMode);
  }

  /** 标记阅读器在/不在栈顶（进 `ReaderPage3.aboutToAppear`，出 `aboutToDisappear`） */
  static setReaderActive(active: boolean): void {
    AppStorage.setOrCreate<boolean>(NightMode.READER_KEY, active);
  }

  /** 阅读器当前的日/夜间（阅读器出现/切换时调用；替代旧的 `NightMode.set()`） */
  static setReaderNight(night: boolean): void {
    AppStorage.setOrCreate<boolean>(NightMode.READER_NIGHT_KEY, night);
  }

  /** 标记当前底部页签（保留写入点；当前裁决不使用） */
  static setMainTab(index: number): void {
    AppStorage.setOrCreate<number>(NightMode.TAB_KEY, index);
  }

  /** 标记书架 NavBar 可见性（保留写入点；当前裁决不使用） */
  static setHomeVisible(visible: boolean): void {
    AppStorage.setOrCreate<boolean>(NightMode.HOME_KEY, visible);
  }

  /**
   * 当前界面**是否应该**是深色。规则见类头注释。纯函数，无副作用。
   */
  static desiredDark(): boolean {
    if (!NightMode.ENABLED) {
      return false;
    }
    // 阅读器在栈顶 ⇒ 跟阅读器的日/夜间（与 App 三档解耦，规则②③）
    if (AppStorage.get<boolean>(NightMode.READER_KEY) === true) {
      return AppStorage.get<boolean>(NightMode.READER_NIGHT_KEY) === true;
    }
    const mode = NightMode.getMode();
    if (mode === NightMode.MODE_DARK) {
      return true;
    }
    if (mode === NightMode.MODE_LIGHT) {
      return false;
    }
    // auto：跟系统
    return AppStorage.get<number>(NightMode.SYS_KEY) === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
  }

  /** 给页面用的便捷判断：当前是否要给"深色档"上色（被 ShelfColors / 十几处组件消费） */
  static isDarkSurface(): boolean {
    return NightMode.ENABLED && AppStorage.get<boolean>(NightMode.KEY) === true;
  }

  /**
   * 把 `desiredDark()` 的结果统一下发（幂等）：
   * ① 派生值变了 → 写 `KEY`（驱动所有 `@StorageLink` 订阅点重绘）+ 联动状态栏图标色；
   * ② Ability 配色变了 → `ctx.setColorMode()`（幂等短路）。
   *
   * ⚠️⚠️ 重入防线（2026-09-23 崩溃修复，JSCrash RangeError: Stack overflow）─────────
   * 真机故障栈（faultlog）实证：`ctx.setColorMode()` 会**同步重入**
   * `EntryAbility.onConfigurationUpdate`（在 setColorMode 尚未返回、下面那句
   * `applied = want` 还没执行时就回调进来）⇒ 旧实现的回声过滤失效，
   * sync 在回调里再次判"需要切换"再次 setColorMode ⇒ 无限递归 → 栈溢出，进程被杀。
   * 两层修复：
   *   ① **乐观记录**：先 `applied = want` 再调 `setColorMode` ⇒ 重入的回调看到
   *      "这就是我刚设置的值"，回声被正确过滤，循环断掉；
   *   ② **重入闸**：`syncing` 期间任何再入的 `sync` 直接返回（覆盖 KEY 写入触发
   *      `@Watch('onNightModeChanged')` 再调 sync 这类同源重入）。
   *
   * @param ctx 调用方的 `UIAbilityContext`（`this.getUIContext().getHostContext()`）；
   *            取不到时**保持现状**（宁可不改，也不乱改配色）。
   */
  static sync(ctx: common.UIAbilityContext | undefined): void {
    if (!NightMode.ENABLED) {
      return;
    }
    if (NightMode.syncing) {
      // 重入闸：setColorMode 的同步回调 / KEY 的 @Watch 链路再入时不能直接执行
      // （无限递归 = JSCrash），置补跑标记后由外层收尾时再跑一遍。
      NightMode.pendingSync = true;
      return;
    }
    NightMode.syncing = true;
    try {
      do {
        NightMode.pendingSync = false;
        const dark: boolean = NightMode.desiredDark();
        // ① 派生值变化 → 通知订阅点 + 状态栏联动
        if (NightMode.lastDark === null || NightMode.lastDark !== dark) {
          AppStorage.setOrCreate<boolean>(NightMode.KEY, dark);
          NightMode.lastDark = dark;
          WindowAbility.getInstance().setStatusBarContentColor(dark);
        }
        // ② Ability 配色（幂等）。
        // ── 钉死 vs 解除钉死（2026-09-23"自动跟随不及时"修复）──────────────────
        // `ctx.setColorMode()` 一旦调用，Ability 配色就被**应用钉死**（真机日志实证：
        // `ohos.system.colorMode.isSetByApp`）——钉死期间**系统切换深浅色不再向本
        // Ability 下发 colorMode 配置** ⇒ "自动"档永远等不到系统变化，只能退出重进。
        // ⇒ 两类策略：
        //   · 需要覆盖（阅读器在栈顶：跟书的日/夜间；或用户显式选了亮色/暗色）→ 钉死；
        //   · "自动"且非阅读器 → **解除钉死**（setColorMode(NOT_SET)），把配色还给系统：
        //     系统切换以原生配置回调即时到达（onSystemColorModeChange 记录 → ① 重绘）。
        const readerBranch: boolean = AppStorage.get<boolean>(NightMode.READER_KEY) === true;
        const mode: string = NightMode.getMode();
        let want: ConfigurationConstant.ColorMode;
        if (readerBranch || mode === NightMode.MODE_DARK || mode === NightMode.MODE_LIGHT) {
          want = dark
            ? ConfigurationConstant.ColorMode.COLOR_MODE_DARK
            : ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT;
        } else {
          want = ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET;
        }
        if (want === NightMode.applied) {
          continue;
        }
        if (ctx === undefined || ctx === null) {
          continue;
        }
        try {
          // ⚠️ 乐观记录：必须先写 applied 再调 setColorMode —— 这个调用会同步重入
          // onConfigurationUpdate（JSCrash 实证），后写的话回声过滤拿到的是旧值。
          NightMode.applied = want;
          ctx.setColorMode(want);
          hilog.info(0x0000, 'testTag', 'nightMode: ability colorMode -> %{public}d', want);
        } catch (e) {
          hilog.error(0x0000, 'testTag', 'nightMode: setColorMode(%{public}d) failed: %{public}s',
            want, e instanceof Error ? e.message : String(e));
        }
      } while (NightMode.pendingSync);
    } finally {
      NightMode.syncing = false;
    }
  }
}

/**
 * 书架（及阅读页）**深色档配色表** —— 日间档与改造前的字面量**逐字一致**。
 *
 * 为什么集中在这里：书架由 10+ 个组件拼成（`IndexShelf` / `BookBodyContent` / `BookContent` /
 * `BookInfos` / `BookInfoGrids` / `BookHistoryContent` / `BookFolder` / `WorksBookList*` /
 * `pages/Index.ets` 的底部页签…），散落写三元必然走色。
 *
 * ⚠️ **只覆盖"自己写死的颜色"**：默认字色（没写 `fontColor` 的 `Text`）由系统 token 跟着
 * 应用配色自动翻转，不需要也不应该在这里重复指定。
 */
export class ShelfColors {
  /** 书架页面底色 —— 夜间用中性深灰（不再用 `themeManager` 的浅色主题色） */
  static pageBg(): string {
    return NightMode.isDarkSurface() ? '#1B1B1D' : '#FFFFFF';
  }

  /** 书架页顶部的主题渐变终点（日间 = 主题 secondColor，由调用方传入） */
  static gradientEnd(dayColor: string): string {
    return NightMode.isDarkSurface() ? '#121214' : dayColor;
  }

  /** 顶部主题渐变起点（日间 = 主题 mainColor） */
  static gradientStart(dayColor: string): string {
    return NightMode.isDarkSurface() ? '#232326' : dayColor;
  }

  /** 卡片 / 胶囊 / 面板底（半透明，压在页面渐变上） */
  static surface(): string {
    return NightMode.isDarkSurface() ? 'rgba(38, 38, 41, 0.92)' : 'rgba(255, 255, 255, 0.92)';
  }

  /** 实心卡片底 */
  static card(): string {
    return NightMode.isDarkSurface() ? '#26262A' : '#FFFFFF';
  }

  /**
   * **主文字色**：页面主标题 / 选中态页签。
   *
   * 2026-10-11 新增（修书架顶部「书架」标签对比度）。原本顶部标签取 `theme.mainColor`
   * 作字色，而它压着的正是**同一条主题渐变彩带**、渐变起点就是 `mainColor`
   * （`IndexShelf.ets:271-275` + SDK `enums.d.ts:2513-2523`：`GradientDirection.Bottom`
   * = 从上到下 ⇒ stop 0 在屏幕顶边）⇒ 字与底同色系。
   * 真机截图像素采样（`screenshots/v1.jpeg`，橙主题）：字 `#FF6600` / 底 `#FF9650`
   * ⇒ WCAG 对比度 **1.36:1**（黄主题最差 1.02:1；大字粗体门槛也要 3:1）。
   * 同一个 `mainColor` 压在浅底 `#FFFFFF` 上也只有 2.2–3.8:1 ⇒ 主标题一律走本方法：
   * 日间近黑（压在彩带上 8.6:1）、夜间近白（14.9:1）。
   * ⚠️ 取值与 `IndexSearchType.chipFg()`、`BookMark` 的 `isBackground=false` 分支
   *    逐字一致（那两处可后续并入本方法，本次未动以免扩大改动面）。
   */
  static textMain(): string {
    return NightMode.isDarkSurface() ? 'rgba(248, 249, 250, 1)' : 'rgba(0, 0, 0, 1.00)';
  }

  /** 次级文字（书籍简介 / 最新章节 / 空列表提示） */
  static textSub(): string {
    return NightMode.isDarkSurface() ? 'rgba(248, 249, 250, 0.62)' : 'rgba(96, 96, 96, 0.6)';
  }

  /**
   * 图标（SVG 的 `fillColor`）。
   * 日间档 **与图标自身的 `fill="black" fill-opacity="0.88"` 逐字一致** ——
   * 书架顶部的 `search.svg` / `more.svg` / `more_search.svg` 三个文件里写的就是这个值
   * （见 `resources/base/media/*.svg`），所以白天给它上这个色**看不出任何变化**。
   * ⚠️ 不给 `fillColor` 的话，夜间会原样画成黑色 ⇒ 在深色书架/胶囊上**完全看不见**
   * （真机第一轮就踩了：切夜间后顶部放大镜和「⋯」直接消失）。
   */
  static icon(): string {
    return NightMode.isDarkSurface() ? 'rgba(248, 249, 250, 0.88)' : 'rgba(19, 19, 19, 0.88)';
  }

  /** 胶囊 / 标签 / 输入框底（淡色块） */
  static chip(): string {
    return NightMode.isDarkSurface() ? 'rgba(255, 255, 255, 0.10)' : 'rgba(0, 0, 0, 0.04)';
  }

  /** 分隔线 */
  static line(): string {
    return NightMode.isDarkSurface() ? 'rgba(248, 249, 250, 0.22)' : '#989797';
  }

  /** 封面占位块 / 骨架屏（`rgba(255,255,255,0.6)` 那种"透出底色的白块"） */
  static skeleton(): string {
    return NightMode.isDarkSurface() ? 'rgba(255, 255, 255, 0.14)' : 'rgba(255, 255, 255, 0.6)';
  }

  /** `Checkbox` 未勾选时的框线色（批量管理里的选择框） */
  static checkboxIdle(): string {
    return NightMode.isDarkSurface() ? 'rgba(248, 249, 250, 0.35)' : 'rgba(0, 0, 0, 0.35)';
  }

  /** 导入按钮那种"白色圆角方块" */
  static solidChip(): string {
    return NightMode.isDarkSurface() ? '#2C2C30' : '#FFFFFF';
  }

  /** 弹窗/面板里的"取消·重置"类次级按钮底 */
  static subButtonBg(): string {
    return NightMode.isDarkSurface() ? 'rgba(255, 255, 255, 0.14)' : 'rgba(0, 0, 0, 0.06)';
  }

  /** 弹窗/面板"取消·重置"类次级按钮字色 */
  static subButtonFg(): string {
    return NightMode.isDarkSurface() ? 'rgba(255, 255, 255, 0.88)' : 'rgba(0, 0, 0, 0.88)';
  }
}
