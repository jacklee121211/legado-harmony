import UIAbility from '@ohos.app.ability.UIAbility';
import hilog from '@ohos.hilog';
import window from '@ohos.window';
import { BusinessError } from '@kit.BasicServicesKit';
import { AbilityConstant, Configuration, Want, common } from '@kit.AbilityKit';
import display from '@ohos.display';
import { ezCustomTransition } from '../common/ezlt';
import DbUtil from '../common/utils/DbUtil';
import DataBase from '../database'
import { webview } from '@kit.ArkWeb';
import { themeManager, ThemeManager } from '../common/utils/ThemeManager';
import { AppUtil } from '@pura/harmony-utils';
import { WindowAbility } from './WindowAbility';
import { deviceInfo } from '@kit.BasicServicesKit';
import BrightnessUtil from '../../common/utils/BrightnessUtil';
import { NightMode } from '../common/utils/NightMode';
// 防窥两层（2026-10-08）：启动即按已存开关应用（全局生效，见 utils/AntiPeep.ets 文件头）
import { AntiPeep } from '../common/utils/AntiPeep';

/**
 * ── T13/D-16：避让区 / 屏幕尺寸换算改用 `UIContext` 开关 ─────────────────────
 * **默认 false = 旧行为**（全局 `px2vp`）。回退 = 把下面这一行改回 false（无其它副作用）。
 *
 * 为什么必须换 —— 官方依据（原文）：
 *  · 官方 FAQ `FAQ/UI框架/组件使用/为什么vp2px_px2vp返回的结果不正确/faqs-arkui-259`：
 *    「vp2px、px2vp 是 ArkUI 的全局接口，该接口**已被标记为废弃，不推荐使用**。
 *      **在应用启动阶段或非 UI 线程调用时，UI 实例不明确，使用默认屏幕的虚拟像素比进行转换，
 *      可能导致转换后结果与预期不一致的情况。** UIContext 的 vp2px、px2vp 为推荐的替代接口，
 *      **能保证调用时 UI 实例已经创建，并返回正确的结果**。」
 *  · SDK `…\ets\component\common.d.ts:6028-6045`（全局 `declare function px2vp`）：
 *    「By default, the virtual pixel ratio of the screen where the current UI instance is located is used
 *      for conversion. **If no UI instance is available, the virtual pixel ratio of the default screen
 *      is used instead.**」+ `@since 11` / `@deprecated since 18` /
 *      `@useinstead ohos.arkui.UIContext.UIContext#px2vp`
 *  · SDK `…\ets\api\@ohos.window.d.ts:5196-5208`：`Window.getUIContext(): UIContext`
 *    `@since 10` `@stagemodelonly`，`@throws { BusinessError } 1300002 - This window state is abnormal.`
 *  · 本项目这 7 处恰好都在 **`onWindowStageCreate` 的 `windowStage.getMainWindow` 回调里**
 *    —— 正是官方点名"**应用启动阶段…UI 实例不明确**"的场景；算出来的值又是
 *    `topRectHeight` / `bottomRectHeight` / `WindowHeight` / `WindowWidth` / `stateHeight`
 *    这 5 个**避让区与屏幕尺寸预算**，一旦用了默认屏密度，沉浸排版会整片偏移。
 *
 * 验证点（翻 true 之后必须做的真机验证）：
 *  1. 视觉：状态栏 / 导航条避让与旧行为**一致**（顶部/底部不留白、不压字）；
 *  2. 折叠屏 / 外接显示器（不同密度屏）上切换，避让值**跟随当前窗口**而不是固定屏；
 *  3. 旋转屏幕（触发 `avoidAreaChange`）后避让值正确刷新。
 */
const AVOID_AREA_USE_UICONTEXT: boolean = false;

export default class EntryAbility extends UIAbility {
  private curBp: string = ''

  /**
   * T13/D-16：px → vp。
   * 开关关闭时**直接走全局 `px2vp`**（旧行为）；开启时优先用该窗口的 `UIContext`，
   * 取不到（`1300002` 等）则**回退**全局 `px2vp` 并记一条 warn —— 保证任何情况下都不会把启动流程打断。
   */
  private toVp(windowClass: window.Window, px: number): number {
    if (!AVOID_AREA_USE_UICONTEXT) {
      return px2vp(px);
    }
    try {
      return windowClass.getUIContext().px2vp(px);
    } catch (e) {
      hilog.warn(0x0000, 'testTag', 'getUIContext().px2vp failed, fallback to global: %{public}s',
        e instanceof Error ? e.message : String(e));
      return px2vp(px);
    }
  }

  // 根据当前窗口尺寸更新断点
  private updateBreakpoint(windowWidth: number): void {
    // 将长度的单位由px换算为vp
    let windowWidthVp = windowWidth / display.getDefaultDisplaySync().densityPixels
    let newBp: string = ''
    if (windowWidthVp < 320) {
      newBp = 'xs'
    } else if (windowWidthVp < 600) {
      newBp = 'sm'
    } else if (windowWidthVp < 840) {
      newBp = 'md'
    } else {
      newBp = 'lg'
    }
    if (this.curBp !== newBp) {
      this.curBp = newBp
      // 使用状态变量记录当前断点值
      AppStorage.setOrCreate('currentBreakpoint', this.curBp)
    }
  }

  /**
   * 桌面静态快捷方式入口（快速听书 / 快速阅读）。
   *
   * 参数来源：`entry/src/main/resources/base/profile/shortcuts_config.json` 里
   * `wants[].parameters`。官方 documentId
   * `开发指南/开发基础知识/典型场景的开发指导/创建应用静态快捷方式/typical-scenario-configuration`。
   * 本工程约定 `"quickAction"`：`'listen'` = 快速听书（进书后自动开始朗读）；`'read'` = 快速阅读（只进书）。
   *
   * **这里只把意图写进 `AppStorage`，不在这里跳转** —— `onCreate` 阶段 UIAbility 刚起、
   * 页面栈尚未建立，直接 `router.pushUrl` 会失败。由书架首页消费该标记后再跳转。
   *
   * 解析失败必须静默忽略，绝不能影响正常启动。
   */
  private captureQuickAction(want: Want): void {
    try {
      const p = want.parameters;
      if (p === undefined) {
        return;
      }
      const action = p['quickAction'];
      if (typeof action === 'string' && action.length > 0) {
        AppStorage.setOrCreate('quickAction', action);
        hilog.info(0x0000, 'testTag', 'quickAction=%{public}s', action);
      }
    } catch (e) {
      // 忽略
    }
  }

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam) {
    webview.WebviewController.initializeWebEngine() //初始化web控件
    hilog.info(0x0000, 'testTag', '%{public}s', 'Ability onCreate');
    AppUtil.init(this.context);
    WindowAbility.getInstance().initContext(this.context)
    this.captureQuickAction(want);
  }

  /**
   * 应用**已在后台**时点桌面快捷方式，走的是这里而**不是** `onCreate`。
   * 不实现它的话，第二次点快捷方式不会有任何反应（首次点才有效）。
   */
  onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam) {
    hilog.info(0x0000, 'testTag', '%{public}s', 'Ability onNewWant');
    this.captureQuickAction(want);
  }

  onDestroy() {
    hilog.info(0x0000, 'testTag', '%{public}s', 'Ability onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage) {
    // 初始化db数据库/创建相关数据表
    // 2026-09-28 修首次安装竞态：原实现 initAllTable() 裸跑不等待——首屏（书架分组
    // 胶囊 GroupType.aboutToAppear → BookGroupsDao.search）在表建好**之前**查询，
    // 查到空列表 ⇒ 首次安装分组栏文字/按钮全空，杀后台重开才正常。
    // 修法：等建表完成后再广播一次分组刷新信号（GroupType 已 @Watch 该键），
    // 建表先于首屏完成时该信号也无害（挂载后首次查询本就能查到）。
    DbUtil.initDB(this.context).then(async () => {
      await DataBase.initAllTable()
      const t = (AppStorage.get<number>('BOOK_IS_BOOK_GROUPS_REFRESHING') ?? 0) + 1
      AppStorage.setOrCreate('BOOK_IS_BOOK_GROUPS_REFRESHING', t)
    })
    WindowAbility.getInstance().setWindowStage(windowStage);
    // 一镜到底官方库初始化（2026-10-02 迁移 @hmanimations/ezcustomtransition，
    // skill: hmos-arkui-longtake-transition Step 2 —— 缺它转场 API 全部不可用）
    ezCustomTransition.init(windowStage);
    this.initWindowProcess(windowStage);
    // 获取本地文件存储路径
    const pathDir = this.context.filesDir;
    AppStorage.setOrCreate('pathDir', pathDir);
    // Main window is created, set main page for this ability
    hilog.info(0x0000, 'testTag', '%{public}s', 'Ability onWindowStageCreate');
    // 全屏
    windowStage.getMainWindow((err, windowClass) => {
      if (err.code) {
        hilog.error(0x0000, 'testTag', 'Failed to load the content. Cause: %{public}s', JSON.stringify(err) ?? '');
        return
      }
      // 初始化屏幕亮度设置
      BrightnessUtil.initWindow(windowClass);

      // ── 防窥两层（2026-10-08）：启动最早时机把主窗口交给 AntiPeep ——
      //    第 1 层（防截屏/录屏）立即按用户意图应用；第 2 层（阅读防窥）静默对账系统防窥开关
      //    （**不**在启动拉起系统设置页，见 AntiPeep 文件头的引导时机说明）。
      AntiPeep.start(this.context as common.UIAbilityContext, windowClass);

      //全屏
      windowClass.setWindowLayoutFullScreen(true)
        .then(() => {
          console.info('Succeeded in setting the window layout to full-screen mode.');
        })
        .catch((err: BusinessError) => {
          console.error('Failed to set the window layout to full-screen mode. Cause:' + JSON.stringify(err));
        });
      //获取上下遮挡区域
      let type = window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR; //导航栏
      let avoidArea = windowClass.getWindowAvoidArea(type);
      let bottomRectHeight = avoidArea.bottomRect.height;
      AppStorage.setOrCreate('bottomRectHeight', this.toVp(windowClass, bottomRectHeight));

      // 2. 获取导航栏避让遮挡的区域
      type = window.AvoidAreaType.TYPE_SYSTEM; // 状态栏
      avoidArea = windowClass.getWindowAvoidArea(type);
      let topRectHeight = avoidArea.topRect.height;
      AppStorage.setOrCreate('topRectHeight', this.toVp(windowClass, topRectHeight));

      //手机屏幕高度和宽度
      let defaultDisplay = display.getDefaultDisplaySync()
      let WindowHeight = defaultDisplay.height
      let WindowWidth = defaultDisplay.width


      AppStorage.setOrCreate('WindowHeight', this.toVp(windowClass, WindowHeight));
      AppStorage.setOrCreate('WindowWidth', this.toVp(windowClass, WindowWidth));

      let avoidAreaSys = windowClass.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
      let navi = windowClass.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR);
      let total = avoidAreaSys.topRect.height + navi.bottomRect.height;
      AppStorage.setOrCreate('avoidHeight', total);
      AppStorage.setOrCreate('stateHeight', this.toVp(windowClass, avoidAreaSys.topRect.height));
      // 注册监听函数，动态获取避让区域数据
      windowClass.on('avoidAreaChange', (data) => {
        // ★ 阅读页沉浸期**跳过**上下避让值的更新（2026-09-22）。
        //   阅读页隐藏系统栏会让 `TYPE_SYSTEM` 的 topRect 与
        //   `TYPE_NAVIGATION_INDICATOR` 的 bottomRect 都归零；若照实写入：
        //     · 顶部跳 → 各页面内容上下移（`ComponetModifier.ColumnModifier:12` 等）
        //     · 底部跳 → 悬浮页签条离底距离变（`Index.ets:280` 的
        //       `.barFloatingStyle(tabsFloatingStyle(bottomRectHeight + 8))`）
        //       真机表现为「底下的书架和我的图标还是会跳」。
        //   沉浸期内主页不可见，冻结这两个值即可。详见 `WindowAbility.freezeTopRect()`。
        const frozen = WindowAbility.getInstance().isTopRectFrozen();
        if (data.type === window.AvoidAreaType.TYPE_SYSTEM) {
          if (frozen) {
            hilog.info(0x0000, 'testTag',
              'avoidAreaChange(TYPE_SYSTEM) skipped: topRectHeight frozen (reader immersive)');
          } else {
            let topRectHeight = data.area.topRect.height;
            AppStorage.setOrCreate('topRectHeight', this.toVp(windowClass, topRectHeight));
          }
        } else if (data.type == window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR) {
          if (frozen) {
            hilog.info(0x0000, 'testTag',
              'avoidAreaChange(TYPE_NAVIGATION_INDICATOR) skipped: bottomRectHeight frozen (reader immersive)');
          } else {
            let bottomRectHeight = data.area.bottomRect.height;
            AppStorage.setOrCreate('bottomRectHeight', this.toVp(windowClass, bottomRectHeight));
          }
        }
      });
    })

    // ── App 级夜间模式开关：**必须在 loadContent 之前**建好 ────────────────────
    // 为什么不能放进下面的 loadContent 回调：`pages/Index` 的 `@StorageLink(NightMode.KEY)`
    // 会在首帧就**创建**这个 AppStorage 键（默认 false），而
    // `PersistentStorage.persistProp(key, default)` 的语义是「AppStorage 已有该键 ⇒
    // 以 AppStorage 为准」⇒ 持久化的 `true` 会被那个默认 false 顶掉，夜间开关重启即失效。
    // 放在这里（页面一个都还没建）才能让持久化值先落地。
    NightMode.init()
    // 把系统当前的深浅色喂给 NightMode（"自动"档的初始真相）——
    // 若等 onConfigurationUpdate 才知道，冷启动在系统暗色下会先亮一帧再翻深。
    NightMode.onSystemColorModeChange(this.context.config.colorMode)

    // ── 启动页已删除（2026-09-23 用户要求：「直接去掉启动动画页，毫无意义」）──────────
    // 原来：`loadContent('/pages/welcomePage')` —— 欢迎页 onPageShow 里 `initAppData()`
    //   + `setTimeout(1500)` 后 `router.replaceUrl('pages/Index')`。
    // 现在：**直接加载首页**。原来的初始化搬到 `pages/Index.aboutToAppear()`：
    //   · `initAppData()`（页面上下文里 `getContext()` 可用，与在欢迎页调用等价，
    //     且早于首次 build ⇒ 书架不会先渲染成空）
    //   · `AppStorage.setOrCreate('startupStackCleared', true)`（不再有 `router.clear()`，
    //     这个"等清栈"标记不再有竞态；首页的快捷方式消费逻辑据此直接通过）
    windowStage.loadContent('/pages/Index'.slice(1), (err, data) => {
      if (err.code) {
        hilog.error(0x0000, 'testTag', 'Failed to load the content. Cause: %{public}s', JSON.stringify(err) ?? '');
        return;
      }
      // 主题初始化
      themeManager.init()
      hilog.info(0x0000, 'testTag', 'Succeeded in loading the content. Data: %{public}s', JSON.stringify(data) ?? '');
    });
  }

  onConfigurationUpdate(newConfig: Configuration): void {
    AppStorage.setOrCreate('colorMode', newConfig.colorMode);
    // 亮暗色重构（2026-09-23）：把系统深浅色真相记进 NightMode（自动档跟随它），
    // 并立即重下发 —— "自动"档下用户在系统里切深浅色，App 内所有页面即时跟翻。
    // ⚠️ onSystemColorModeChange 内部用 `applied` 过滤 setColorMode 自己触发的回声。
    NightMode.onSystemColorModeChange(newConfig.colorMode);
    NightMode.sync(this.context as common.UIAbilityContext);
  }

  initWindowProcess(windowStage: window.WindowStage): void {
    windowStage.getMainWindow((err, windowClass: window.Window) => {
      WindowAbility.getInstance().initAvoidArea(windowClass);
      let systemBarProperties: window.SystemBarProperties = {
        statusBarContentColor: this.context.config.colorMode ? '#000000' : '#FFFFFF'
      };
      windowClass.setWindowSystemBarProperties(systemBarProperties);
    });
    WindowAbility.getInstance().setWindowLayoutFullScreen(true);
    if (deviceInfo.deviceType === 'tablet') {
      WindowAbility.getInstance().setOrientation(windowStage, window.Orientation.AUTO_ROTATION_RESTRICTED);
    }
    WindowAbility.getInstance().initWindowSize();
  }

  onWindowStageDestroy() {
    // Main window is destroyed, release UI related resources
    hilog.info(0x0000, 'testTag', '%{public}s', 'Ability onWindowStageDestroy');
  }

  onForeground() {
    // Ability has brought to foreground
    // ★ 前台标志（2026-10-07）：给阅读页的「睡眠定时剩余量 / 信息窗」刷新器做**功耗门禁**。
    //   背景：这两个刷新器是 5s / 1s 的 `setInterval`，而阅读页（NavDestination）在后台仍然存活，
    //   旧实现只在「退出听书」时停 ⇒ 熄屏后台依旧每 5s/1s 唤醒主线程并改 `@State`（不可见重渲染），
    //   与官方低功耗口径「低功耗渲染器建议一次性填满缓冲区，**以减少唤醒次数**」
    //   （documentId `开发指南/Audio_Kit_音频服务/音频播放/低功耗音频播放/power-saving-for-playback`）相悖。
    AppStorage.setOrCreate('appForeground', true);
    hilog.info(0x0000, 'testTag', '%{public}s', 'Ability onForeground');
  }

  onBackground() {
    // Ability has back to background
    // ★ 熄屏/后台 ⇒ 阅读页停掉定时刷新器（详见 onForeground 注释）
    AppStorage.setOrCreate('appForeground', false);
    hilog.info(0x0000, 'testTag', '%{public}s', 'Ability onBackground');
  }
}
