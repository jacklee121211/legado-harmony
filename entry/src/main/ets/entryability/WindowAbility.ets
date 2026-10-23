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

  /**
   * 窗口尺寸变化监听（2026-10-23 重做：去重 + 防抖 + 安全区重算 + 监听器单例）。
   *
   * ── 旧实现的两个问题（用户反馈「竖屏偶尔整页被挤压，横屏再竖屏才好」）──────
   *   ① **监听器重复注册**：`onWindowSizeChange()` 每调一次就 `on('windowSizeChange')`
   *      一次。阅读页每次进入都会注册（`ReaderPage3.registerListener()`），
   *      退出不注销 ⇒ 监听器越积越多，一次旋转触发 N 次回调。
   *   ② **安全区不重算**：旋转后状态栏/手势条高度会变，但 `initAvoidArea()`
   *      只在启动时调过一次 ⇒ `statusBarHeight` / `Paf.TopHeight` /
   *      `NavigationBarHeight` 仍是旋转前的值 ⇒ 页面按错的避让值排版 = 「被挤压」。
   *      转一圈横屏再回来能恢复，是因为那一圈里又走了一次重新测量。
   *
   * ── 现在的做法 ────────────────────────────────────────────────────────────
   *   · 监听器**只注册一次**（`sizeListenerBound` 闸门），回调集中存在 `sizeCallbacks`；
   *   · 同尺寸重复上报**直接丢弃**（旋转过程会连报多次相同尺寸）；
   *   · 用 **150ms 防抖**合并，只在尺寸稳定后重算一次（日志实证：一次旋转会连发
   *     6+ 次 config 推送，重排整本书 ⇒ 卡顿 + 闪）；
   *   · 稳定后先 `initAvoidArea()` 刷新安全区，再递增 `windowSizeTick`
   *     （供书架等非阅读页 `@StorageLink` 它触发重建），最后才回调业务。
   */
  onWindowSizeChange(callback?: () => void): void {
    if (callback) {
      this.sizeCallbacks.push(callback);
    }
    if (!this.windowClass || this.sizeListenerBound) {
      return;
    }
    this.sizeListenerBound = true;
    try {
      this.windowClass.on('windowSizeChange', (size) => {
        hilog.info(0x0000, TAG,
          'onWindowSizeChange windowSizeChange size is: ' + JSON.stringify(size));
        // 去重：同一尺寸重复上报（旋转过程常见）直接忽略
        if (size.width === this.lastSizeWidth && size.height === this.lastSizeHeight) {
          return;
        }
        this.lastSizeWidth = size.width;
        this.lastSizeHeight = size.height;
        AppStorage.setOrCreate<number>('windowWidth', size.width);
        AppStorage.setOrCreate<number>('windowHeight', size.height);
        // 防抖合并：一次旋转会连续触发多次，只在稳定后重算一次
        if (this.sizeChangeTimer !== -1) {
          clearTimeout(this.sizeChangeTimer);
        }
        this.sizeChangeTimer = setTimeout(() => {
          this.sizeChangeTimer = -1;
          // ★ 关键：安全区随方向变化 ⇒ 必须重算（旧实现漏了这一步）
          if (this.windowClass) {
            this.initAvoidArea(this.windowClass);
          }
          // 通知全 App「尺寸已稳定」（非阅读页可 @StorageLink 它触发重建）
          const tick = (AppStorage.get<number>('windowSizeTick') ?? 0) as number;
          AppStorage.setOrCreate<number>('windowSizeTick', tick + 1);
          for (const cb of this.sizeCallbacks) {
            try {
              cb();
            } catch (e) {
              hilog.error(0x0000, TAG,
                'onWindowSizeChange callback failed: ' + JSON.stringify(e));
            }
          }
        }, 150);
      });
    } catch (exception) {
      hilog.error(0x0000, TAG,
        'onWindowSizeChange failed, error is ' + JSON.stringify(exception));
    }
  }

  /**
   * 直接设置窗口方向（2026-10-23 新增：阅读页内锁定方向 / 手动横竖屏切换用）。
   *
   * 与上面 `setOrientation(windowStage, …)` 的区别：阅读页（NavDestination）里拿不到
   * `windowStage`，所以这里内部走 `getLastWindow()` 自己取。
   *
   * 用途：平板 / 2in1 进入阅读页时**锁住当前方向**（禁止自动旋转），
   * 再由顶栏的横竖屏按钮手动切换 —— 因为 ReaderKit 的原生 surface 在自动旋转后
   * **不会重新分配**（真机实证：旋转后内容仍按竖屏 1840px 宽渲染，塞进 2800px 窗口
   * ⇒ 左侧占 65.7%、右侧空白、行距异常）。锁定 + 手动切换才能让重建时机可控。
   */
  setOrientationDirect(orientation: window.Orientation): void {
    window.getLastWindow(this.context).then((win: window.Window) => {
      win.setPreferredOrientation(orientation).then(() => {
        hilog.info(0x0000, TAG, 'setOrientationDirect ok, orientation=' + orientation);
      }).catch((err: Error) => {
        hilog.error(0x0000, TAG, 'setOrientationDirect failed: ' + JSON.stringify(err));
      });
    }).catch((err: Error) => {
      hilog.error(0x0000, TAG, 'setOrientationDirect getLastWindow failed: ' + JSON.stringify(err));
    });
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
  /** 尺寸变化回调集合（2026-10-23：监听器单例化，避免每进一次阅读页就多注册一个） */
  private sizeCallbacks: Array<() => void> = [];
  /** 'windowSizeChange' 是否已注册（只允许注册一次） */
  private sizeListenerBound: boolean = false;
  /** 上一次生效的窗口尺寸（去重用，单位 px） */
  private lastSizeWidth: number = 0;
  private lastSizeHeight: number = 0;
  /** 尺寸变化防抖计时器 id（-1 = 空闲） */
  private sizeChangeTimer: number = -1;

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

  /**
   * 阅读页「显示系统状态栏」= **真穿透**（2026-10-19 新增，用户需求）。
   *
   * 做法：状态栏底色设为**全透明** `#00000000`，只改图标/文字颜色。
   * 为什么这样就能"背景融合"：窗口在 `EntryAbility.ets:278` 就设置了
   * `setWindowLayoutFullScreen(true)`（布局延伸到系统栏区域），阅读页根容器本身铺满
   * 整屏并自带阅读背景/材质 ⇒ 状态栏区域露出的就是**阅读页自己的背景**。
   *
   * 依据（SDK 原文，`@ohos.window.d.ts`）：
   *   · `:442-450` `statusBarColor?: string` ——「The value is a hexadecimal RGB **or ARGB**
   *     color code … The default value is **'#66000000'**」⇒ 支持带 alpha 的 ARGB，
   *     默认值本身就带 alpha，说明透明度会生效。
   *   · `:469` `statusBarContentColor?: string` ——「Color of the text on the status bar.
   *     After this property is set, the setting of **isStatusBarLightIcon** is invalid.」
   *     ⇒ 只传 content color 即可，不必再传 lightIcon。
   *
   * @param dark true = 深色阅读背景（状态栏图标用白）；false = 浅色（图标用黑）
   */
  setStatusBarTransparent(dark: boolean): void {
    if (!this.windowClass) {
      return;
    }
    try {
      this.windowClass.setWindowSystemBarProperties({
        statusBarColor: '#00000000',
        statusBarContentColor: dark ? '#FFFFFF' : '#000000'
      }).then(() => {
        hilog.info(0x0000, TAG, 'setStatusBarTransparent(%{public}s) succeeded', String(dark));
      }, (error: Error) => {
        hilog.error(0x0000, TAG, 'setStatusBarTransparent failed: ' + JSON.stringify(error));
      });
    } catch (exception) {
      hilog.error(0x0000, TAG, 'setStatusBarTransparent threw: ' + JSON.stringify(exception));
    }
  }

  /**
   * 退出阅读页时把状态栏底色**还原成全透明**（2026-10-20 用户拍板 A 方案）。
   *
   * ── 改版背景（2026-10-20 真机反馈）─────────────────────────────────────────
   * 用户原话：「进入阅读器后返回书架，整个软件顶部，系统状态栏都有个灰色遮罩」。
   * 日志与代码对得上（真机 `docs/日志.md` 16:42:28）：
   * ```
   * 16:42:27.309  setStatusBarTransparent(false) succeeded      ← 进阅读器设透明
   * 16:42:28.234  restoreStatusBarBackground succeeded          ← 退出还原
   * ```
   * 而旧实现在这里写的是 `statusBarColor: '#66000000'` ——
   * alpha `0x66` = **40% 不透明的纯黑**，铺满整个状态栏底色；书架是浅色底，
   * 所以看上去就是"顶部一条灰遮罩"。
   * ⇒ 这里改成 `'#00000000'`（全透明），让页面自己的背景透上来，顶部绝对干净。
   *
   * ⚠️ 为什么不是"啥都不设"：本 App 启动时 `EntryAbility` 就是
   * `setWindowLayoutFullScreen(true)`（窗口铺满、内容延伸到状态栏区域），
   * 状态栏必须有底色来源，不设就会退回系统默认的半透明黑（即刚修掉的灰遮罩）。
   */
  restoreStatusBarBackground(): void {
    if (!this.windowClass) {
      return;
    }
    try {
      this.windowClass.setWindowSystemBarProperties({
        statusBarColor: '#00000000'
      }).then(() => {
        hilog.info(0x0000, TAG, 'restoreStatusBarBackground(transparent) succeeded');
      }, (error: Error) => {
        hilog.error(0x0000, TAG, 'restoreStatusBarBackground failed: ' + JSON.stringify(error));
      });
    } catch (exception) {
      hilog.error(0x0000, TAG, 'restoreStatusBarBackground threw: ' + JSON.stringify(exception));
    }
  }
}