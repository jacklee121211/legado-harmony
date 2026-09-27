import { window } from '@kit.ArkUI';
import { deviceInfo } from '@kit.BasicServicesKit';
import { display } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG = 'WindowAbility';

export class WindowAbility {
  private static readonly INSTANCE: WindowAbility = new WindowAbility();
  private context: common.UIAbilityContext | null = null;
  private windowStage: window.WindowStage | null = null;
  private windowClass: window.Window | null = null;
  private windowType: window.WindowStatusType | null = null;

  private constructor() {
  }

  public static getInstance(): WindowAbility {
    return WindowAbility.INSTANCE;
  }

  initContext(context: common.UIAbilityContext) {
    this.context = context;
  }

  setWindowStage(windowStage: window.WindowStage): void {
    this.windowStage = windowStage;
  }

  getWindowStage(): window.WindowStage | null {
    return this.windowStage;
  }

  /**
   * 初始化避开区域参数
   * @param - mainWindow windows
   * @returns void
   */
  async initAvoidArea(mainWindow: window.Window): Promise<void> {
    hilog.info(0x0000, TAG, 'initAvoidArea start');
    // Initialize default values
    AppStorage.setOrCreate<number>('statusBarHeight', 36);
    AppStorage.setOrCreate<number>('navigationAiBarHeight', 28);
    const defaultDisplay = display.getDefaultDisplaySync();
    let scaledDensity = (defaultDisplay.scaledDensity > 0) ? defaultDisplay.scaledDensity : 1;
    const systemArea: window.AvoidArea = mainWindow.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
    const navArea: window.AvoidArea = mainWindow.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR);
    if (systemArea) {
      const statusBarHeight = systemArea.topRect.height / scaledDensity;
      hilog.info(0x0000, TAG, "initAvoidArea statusBarHeight: " + statusBarHeight);
      AppStorage.setOrCreate<number>('statusBarHeight', statusBarHeight);

      if (deviceInfo.deviceType === 'tablet') {
        AppStorage.setOrCreate<number>("Paf.TopHeight", 56);
      } else if (deviceInfo.deviceType === '2in1') {
        AppStorage.setOrCreate<number>("Paf.TopHeight", 0);
      } else {
        AppStorage.setOrCreate<number>("Paf.TopHeight", systemArea.topRect.height);
      }
    }
    if (navArea) {
      const navigationAiBarHeight = navArea.bottomRect.height / scaledDensity;
      hilog.info(0x0000, TAG, "initAvoidArea navigationAiBarHeight: " + navigationAiBarHeight);
      AppStorage.setOrCreate<number>('navigationAiBarHeight', navigationAiBarHeight);

      if (deviceInfo.deviceType === 'tablet') {
        AppStorage.setOrCreate<number>("NavigationBarHeight", navArea.bottomRect.height);
      } else if (deviceInfo.deviceType === '2in1') {
        AppStorage.setOrCreate<number>("NavigationBarHeight", 0);
      } else {
        AppStorage.setOrCreate<number>("NavigationBarHeight", navArea.bottomRect.height);
      }
    }
    hilog.info(0x0000, TAG, 'initAvoidArea end');
  }

  initWindowSize(): void {
    window.getLastWindow(this.context, (err, windowClass) => {
      if (err.code) {
        hilog.error(0x0000, TAG, 'setWindowWidth getLastWindow failed, error is: ' + JSON.stringify(err));
        return;
      }
      let windowProperty = windowClass.getWindowProperties();
      AppStorage.setOrCreate<number>('windowWidth', windowProperty.windowRect.width);
      AppStorage.setOrCreate<number>('windowHeight', windowProperty.windowRect.height);
      this.windowClass = windowClass;
      this.onWindowSizeChange();
      // this.onWindowStatusChange();
      this.onWindowRectChange();
    });
  }

  private onWindowStatusChange(): void {
    if (!this.windowClass) {
      return;
    }
    this.windowClass.on('windowStatusChange', (type: window.WindowStatusType) => {
      this.windowType = type;
      hilog.info(0x0000, TAG, 'onWindowStatusChange type: ', JSON.stringify(type));
      this.initAvoidArea(this.windowClass!);
      if (type === window.WindowStatusType.FLOATING) {
        AppStorage.setOrCreate<number>("NavigationBarHeight", 0);
      }
    })
  }

  private onWindowRectChange(): void {
    if (!this.windowClass) {
      return;
    }
    this.windowClass.on('windowRectChange', (option) => {
      if (this.windowType === window.WindowStatusType.SPLIT_SCREEN ||
        this.windowType === window.WindowStatusType.FULL_SCREEN) {
        // 重新获取导航栏高度
        this.setNavigationBar();
      }
    })
  }

  private setNavigationBar(): void {
    if (!this.windowClass) {
      return;
    }
    const nav: window.AvoidArea = this.windowClass.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR);
    hilog.info(0x0000, TAG, 'setNavigationBar avoidArea: ', JSON.stringify(nav));
    if (nav) {
      AppStorage.setOrCreate<number>("NavigationBarHeight", nav.bottomRect.height);
    }
  }

  async setWindowLayoutFullScreen(isFullScreen: boolean): Promise<void> {
    if (deviceInfo.deviceType === '2in1') {
      return;
    }
    window.getLastWindow(this.context).then(async (wnd: window.Window) => {
      await wnd.setWindowLayoutFullScreen(isFullScreen);
    });
  }

  onWindowSizeChange(callback?: () => void): void {
    if (!this.windowClass) {
      return;
    }
    try {
      this.windowClass.on('windowSizeChange', (size) => {
        hilog.info(0x0000, TAG,
          'onWindowSizeChange windowSizeChange size is: ' + JSON.stringify(size));
        AppStorage.setOrCreate<number>('windowWidth', size.width);
        AppStorage.setOrCreate<number>('windowHeight', size.height);
        callback && callback();
      });
    } catch (exception) {
      hilog.error(0x0000, TAG,
        'onWindowSizeChange failed, error is ' + JSON.stringify(exception));
    }
  }

  setOrientation(windowStage: window.WindowStage, orientation: window.Orientation): void {
    windowStage.getMainWindow().then((win) => {
      win.setPreferredOrientation(orientation).then((data) => {
        hilog.info(0x0000, TAG, 'setOrientation succeeded, error is: ' + JSON.stringify(data));
      }).catch((err: Error) => {
        hilog.error(0x0000, TAG, 'setOrientation setPreferredOrientation failed. error is: ' + JSON.stringify(err));
      });
    }).catch((err: Error) => {
      hilog.error(0x0000, TAG, 'setOrientation getMainWindow failed, error is ' + JSON.stringify(err));
    });
  }

  // ── 阅读页沉浸期：冻结/恢复**上下**避让值（2026-09-22）────────────────────────
  //
  // ── 现象 ──────────────────────────────────────────────────────────────────
  // 用户报告（先后两次）：
  //   ① 「进入和退出，主页明显有个上下跳的感觉很割裂」→ 已修（顶部）
  //   ② 「之前出现状态栏消失，进入退出有状态栏会跳，现在好了，
  //       但是**底下的书架和我的图标还是会跳**」→ 本次修（底部）
  //
  // ── 根因 ──────────────────────────────────────────────────────────────────
  // 阅读页要全屏，所以会隐藏系统栏（`ReaderPage3` 里 `toggleWindowSystemBar([])`）。
  // 系统栏一隐藏，`EntryAbility` 注册的 `avoidAreaChange` 监听就会把：
  //   · `TYPE_SYSTEM` 的 `topRect.height`（实测 **38.81vp**）写成 `topRectHeight = 0`
  //   · `TYPE_NAVIGATION_INDICATOR` 的 `bottomRect.height`（实测 **27.85vp**）
  //     写成 `bottomRectHeight = 0`
  // 退出恢复系统栏时又写回原值。
  //
  // 而主页**上下两处**都用它们做避让：
  //   · 顶部：`ComponetModifier.ColumnModifier:12`、`IndexShelf:165`、`Header:104`…
  //   · 底部：`Index.ets:280` 的 `.barFloatingStyle(tabsFloatingStyle(bottomRectHeight + 8))`
  //           （悬浮页签条离底距离）与 `:281` 的 `.padding({bottom: …})`
  // ⇒ 两个值一起跳，所以"状态栏那块"和"底部书架/我的图标"会分别跳。
  //   上次只冻结了顶部，底部就还在跳。
  //
  // ── 为什么"冻结"就能解决 ──────────────────────────────────────────────────
  // 阅读页是盖在主页之上的 `NavDestination`，**沉浸期内主页根本不可见** ——
  // 它怎么重排用户都看不见。所以只要让这两个值在这段时间**保持不变**，
  // 跳动的源头就消失了，而且不牺牲任何东西。
  //
  // ── 为什么"存旧值再还回去"，而不是"退出时重算" ─────────────────────────────
  // `EntryAbility.toVp()` 走的是 `px2vp`（该文件 `AVOID_AREA_USE_UICONTEXT = false`）。
  // 若在这里另写一套 px→vp 换算，**必然引入细微偏差**（而且换算方式会随那个开关变）。
  // 存下进入前的值原样还回去，**零误差、零耦合**。
  // 另外：只恢复系统栏、指望异步的 `avoidAreaChange` 来纠正，会有窗口期
  // ⇒ 用户会看到"先跳一下再归位"。
  private topRectFrozen: boolean = false;
  private savedTopRectHeight: number = 0;
  private savedBottomRectHeight: number = 0;

  /** 进入沉浸（阅读页打开）：冻结上下避让值，让隐藏系统栏不再引起主页重排 */
  freezeTopRect(): void {
    if (this.topRectFrozen) {
      return;
    }
    this.savedTopRectHeight = (AppStorage.get<number>('topRectHeight') ?? 0) as number;
    this.savedBottomRectHeight = (AppStorage.get<number>('bottomRectHeight') ?? 0) as number;
    this.topRectFrozen = true;
    hilog.info(0x0000, TAG, 'freezeTopRect: saved top=' + this.savedTopRectHeight
      + ' bottom=' + this.savedBottomRectHeight);
  }

  /** 退出沉浸（阅读页关闭）：把冻结前的上下避让值原样还回去 */
  restoreTopRect(): void {
    if (!this.topRectFrozen) {
      return;
    }
    this.topRectFrozen = false;
    AppStorage.setOrCreate<number>('topRectHeight', this.savedTopRectHeight);
    AppStorage.setOrCreate<number>('bottomRectHeight', this.savedBottomRectHeight);
    hilog.info(0x0000, TAG, 'restoreTopRect: top=' + this.savedTopRectHeight
      + ' bottom=' + this.savedBottomRectHeight);
  }

  /**
   * 供 `avoidAreaChange` 监听询问：当前是否处于沉浸期。
   * 为 `true` 时监听应**跳过**对 `topRectHeight` / `bottomRectHeight` 的更新
   * （否则会打破冻结）。
   */
  isTopRectFrozen(): boolean {
    return this.topRectFrozen;
  }

  /**
   * 将系统栏设置为可见。
   *
   * @param { Array<'status' | 'navigation'> } names - 系统栏的设置
   * @param context - 当前应用程序上下文
   */
  toggleWindowSystemBar(names: Array<'status' | 'navigation'>, windowContext: Context | undefined): void {
    window.getLastWindow(windowContext, (err, data) => {
      try {
        if (err.code) {
          return;
        }
        let windowClass = data;
        if (names.length === 0) {
          AppStorage.setOrCreate('Grid.tabPro.enableAvoidAreaListener', false);
        }
        windowClass.setWindowSystemBarEnable(names).then(() => {
          hilog.info(0x0000, TAG, 'toggleWindowSystemBar setWindowSystemBarEnable succeeded');
        }, (error: Error) => {
          if (error) {
            hilog.error(0x0000, TAG,
              'toggleWindowSystemBar setWindowSystemBarEnable failed, error is:' + JSON.stringify(error));
          }
        })
        if (names.length > 0) {
          AppStorage.setOrCreate('Grid.tabPro.enableAvoidAreaListener', true);
        }
        hilog.info(0x0000, TAG, 'toggleWindowSystemBar Succeeded in setting the system bar to be invisible.');
      } catch (exception) {
        hilog.error(0x0000, TAG,
          'toggleWindowSystemBar Failed to set the system bar to be invisible. Cause:' + JSON.stringify(exception));
      }
    });
  }

  /**
   * 状态栏图标颜色随夜间体系联动（2026-09-23 亮暗色重构新增）。
   *
   * 此前全工程只有 `EntryAbility.initWindowProcess` 在冷启动设过一次
   * `statusBarContentColor`，之后从不更新 —— 夜间切换后状态栏图标颜色与页面脱节。
   * 现在由 `NightMode.sync()` 在「有效深浅」变化时调用。
   *
   * @param dark true = 深色界面（图标用白）；false = 浅色界面（图标用黑）
   */
  setStatusBarContentColor(dark: boolean): void {
    if (!this.windowClass) {
      return;
    }
    this.windowClass.setWindowSystemBarProperties({
      statusBarContentColor: dark ? '#FFFFFF' : '#000000'
    }).then(() => {
      hilog.info(0x0000, TAG, 'setStatusBarContentColor(%{public}s) succeeded', String(dark));
    }, (error: Error) => {
      hilog.error(0x0000, TAG, 'setStatusBarContentColor failed: ' + JSON.stringify(error));
    });
  }
}