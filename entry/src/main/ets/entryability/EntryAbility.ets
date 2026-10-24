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
// 离线模式（2026-10-13）：手动切换的「全量/离线」模式，隐藏依赖网络的入口（见 utils/OfflineMode.ets）
import { OfflineMode } from '../common/utils/OfflineMode';
// 音量键翻页默认值一次性迁移（2026-10-19）：新装默认开、老用户保持关（见该文件头）
import { KeyVolDefaultMigration, HapticsDefaultMigration } from '../common/utils/KeyVolDefaultMigration';
// 标定模式全局信号（2026-10-10）：冷启动回填到 AppStorage
import { CalibMode } from '../common/utils/CalibMode';
// VIP 启动自愈（2026-10-14）：付费用户卸载重装/换机后，把 IAP 已购记录查回来
import { IapManager } from '../common/utils/IapManager';
// 外部文件接收（2026-10-19 双响炮）：分享（sendData）与"用其他应用打开"（viewData）
import { systemShare } from '@kit.ShareKit';
import { IncomingFiles } from '../common/format/IncomingFiles';
import { FMT_MASTER_ENABLED, FMT_SHARE_INTAKE_ENABLED } from '../common/format/FormatFlags';
// 应用接续（无缝流转，2026-10-24）：源端 onContinue 存进度、对端 onCreate/onNewWant 恢复
import { ContinueBridge } from '../common/utils/ContinueBridge';
// 书架宫格列数（2026-10-23 多端适配）：启动时把用户手动设定回填到 AppStorage
import ShelfPrefs from '../common/utils/ShelfPrefs';
// PuraX 外屏「极简阅读」形态判定（2026-10-24）：全工程唯一的形态判断入口
import { OuterScreen } from '../common/utils/OuterScreen';

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
  /**
   * `onWindowStageCreate` 是否已跑过（2026-10-24，应用接续用）。
   * 接续拉起时框架调 `onWindowStageRestore` 而非 `onWindowStageCreate`，
   * 用它区分"冷启动需补跑初始化"与"热启动只需交回 windowStage"。
   */
  private windowStageInited: boolean = false;

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
  //
  // ── 2026-10-23 两处修正（2in1 适配必需）──────────────────────────────────
  //  ① **补 `xl` 档（≥1440vp）**。原实现最大只到 `lg`（≥840vp 全部算 lg），
  //     而 `ShelfPrefs.autoColumns()` 里 `xl → 6 列`、
  //     `BookContent.isUltraWide()` 判 `'xl'` 才启用 1600vp 限宽
  //     ⇒ 断点永远产不出 `xl`，那两条分支**永远不会命中**（2in1 全屏 2000vp+
  //     会被当成 `lg` 给 5 列，且内容区不限宽）。这是必须补的。
  //     阈值依据：技能 `hmos-multidevice-screen-window-size` 的
  //     `references/responsive_layout.md` 里 GridRow `breakpoints` 示例
  //     `{ value: ['320vp', '600vp', '840vp', '1440vp'] }`（xl 起点 1440vp）。
  //  ② **改用该窗口自己的 `UIContext.px2vp()`**，不再用
  //     `display.getDefaultDisplaySync().densityPixels`。
  //     原因：2in1 可以拖到不同 DPI 的显示器上 / 系统显示缩放不同，
  //     "默认屏密度"未必等于"当前窗口密度"⇒ 算出的 vp 会偏，断点判错档。
  //     官方 FAQ `FAQ/UI框架/组件使用/为什么vp2px_px2vp返回的结果不正确/faqs-arkui-259`
  //     原文：「UIContext 的 vp2px、px2vp 为推荐的替代接口，能保证调用时 UI 实例
  //     已经创建，并返回正确的结果」。
  //     取不到 UIContext 时回退全局 `px2vp()`（与 `toVp()` 同一套兜底策略），
  //     保证任何情况下都不打断启动流程。
  private updateBreakpoint(windowClass: window.Window, windowWidthPx: number): void {
    let windowWidthVp: number = 0;
    try {
      windowWidthVp = windowClass.getUIContext().px2vp(windowWidthPx);
    } catch (e) {
      hilog.warn(0x0000, 'testTag', 'breakpoint px2vp(UIContext) failed, fallback: %{public}s',
        e instanceof Error ? e.message : String(e));
      windowWidthVp = px2vp(windowWidthPx);
    }
    let newBp: string = '';
    if (windowWidthVp < 320) {
      newBp = 'xs'
    } else if (windowWidthVp < 600) {
      newBp = 'sm'
    } else if (windowWidthVp < 840) {
      newBp = 'md'
    } else if (windowWidthVp < 1440) {
      newBp = 'lg'
    } else {
      // xl：PC / 2in1 全屏、外接大屏（≥1440vp）。见方法头 ① 的说明。
      newBp = 'xl'
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

  /**
   * 外部文件入口（**分享 / 用其他应用打开** 双响炮，2026-10-19）。
   *
   * 官方依据（documentId `FAQ/PDF文档解析服务_PDF_Kit/如何打开三方应用分享的PDF文件/faqs-pdf-6`）：
   * 声明 `ohos.want.action.viewData` + `ohos.want.action.sendData` 后，
   * 两种入口都通过 `systemShare.getSharedData(want)` 取记录（`SharedRecord.uri`）。
   * 该 FAQ 的示例代码正是 `handleSharedData(want)` → `getSharedData` → `fileIo.copyFileSync` 进沙箱。
   *
   * 与 `captureQuickAction` 同一条约定：**只把意图写进 AppStorage，不在这里导入**
   * （`onCreate` 阶段 DB 还没建表，见 `onWindowStageCreate` 里的 `DbUtil.initDB`）。
   * 由 `BookContent.aboutToAppear` / `@StorageLink(INCOMING_TICK)` 消费。
   *
   * 解析失败必须静默 —— 绝大多数启动都没有分享内容，`getSharedData` 会 reject。
   */
  private captureIncomingFiles(want: Want): void {
    if (!FMT_MASTER_ENABLED || !FMT_SHARE_INTAKE_ENABLED) {
      return;
    }
    const collect: (data: systemShare.SharedData) => void = (data: systemShare.SharedData): void => {
      try {
        const uris: string[] = [];
        const records: systemShare.SharedRecord[] = data.getRecords();
        for (const r of records) {
          const u: string = r.uri ?? '';
          if (u.length > 0) {
            uris.push(u);
          }
        }
        if (uris.length > 0) {
          hilog.info(0x0000, 'testTag', 'incoming files=%{public}d', uris.length);
          IncomingFiles.push(uris);
        }
      } catch (e) {
        hilog.warn(0x0000, 'testTag', 'incoming parse err');
      }
    };
    try {
      systemShare.getSharedData(want).then(collect).catch((e: BusinessError): void => {
        // viewData（用其他应用打开）不是分享意图，getSharedData 会失败 ⇒ 回落到 want.uri
        const u: string = want.uri ?? '';
        if (u.length > 0) {
          hilog.info(0x0000, 'testTag', 'incoming by viewData uri');
          IncomingFiles.push([u]);
        }
      });
    } catch (e) {
      // 忽略：普通启动没有 uri
    }
    // 兜底：部分入口直接把 uri 放在 want.uri 上（与上面 catch 互补，去重由 IncomingFiles 负责）
    try {
      const direct: string = want.uri ?? '';
      if (direct.length > 0) {
        IncomingFiles.push([direct]);
      }
    } catch (e) {
      // 忽略
    }
  }

  /**
   * 外屏形态的**调试强制位**（2026-10-24 新增）。
   *
   * ── 为什么需要它 ──────────────────────────────────────────────────────────
   * 外屏形态只出现在真 PuraX 折叠态；而模拟器的折叠/展开只能在窗口里手点，
   * `devecocli ui` 没有折叠命令 ⇒ 无法脚本化验证精简版 UI。
   * 有了这个位，就能在**现有手机**上强制进入外屏态做验收与 A/B。
   *
   * ── 用法（零 UI 侵入，不留任何界面痕迹）──────────────────────────────────
   *   hdc shell aa start -a EntryAbility -b com.jk.reader --ps outerMinimalDebug true
   * 取消：`--ps outerMinimalDebug false`，或杀进程重开（AppStorage 是内存态）。
   *
   * 与 `captureQuickAction` 同一条约定：**解析失败必须静默忽略**，绝不影响正常启动。
   */
  private captureOuterDebugFlag(want: Want): void {
    try {
      const p = want.parameters;
      if (p === undefined) {
        return;
      }
      const v = p['outerMinimalDebug'];
      if (typeof v === 'string') {
        OuterScreen.setDebugForce(v === 'true');
      } else if (typeof v === 'boolean') {
        OuterScreen.setDebugForce(v);
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
    // PuraX 外屏形态调试强制位（2026-10-24）：必须在首帧渲染前解析
    this.captureOuterDebugFlag(want);
    // 分享 / 用其他应用打开（2026-10-19）：只登记，由书架消费导入
    this.captureIncomingFiles(want);
    // 应用接续（2026-10-24）：对端**冷启动**恢复
    this.appContinuity(want, launchParam);
    // 应用接续：**启动默认不可接续**（2026-10-24）。
    // 只有阅读页/听书页会在 aboutToAppear 里把它打开（`ContinueBridge.setMissionActive`）。
    // 这样在书架/设置等页面上，系统层面**不显示接续入口** —— 官方推荐做法，
    // 比"显示入口→用户点→再 REJECT"的体验好得多。
    ContinueBridge.setMissionActive(this.context, false);
    // 标定模式全局信号（2026-10-10）：从 Preferences 回填到 AppStorage，
    // 让书架/我的/PlugboardZone 在冷启动时也能感知到用户开过标定模式。
    CalibMode.bootstrap()

    // ── VIP 启动自愈（2026-10-14）────────────────────────────────────────────
    // 缺口：`IapManager.refreshVip` 原先**只在「我的」页**（MyCenter.ets:69）调用 ⇒
    //   付费用户卸载重装/换机后，缓存位 `VipUnlocked` 随沙箱一起没了，而 IAP 查询
    //   要等用户**手动翻到「我的」页**才发生；在那之前书城所有 VIP 门控
    //   （自定义主题/导入下载字体/更多材质/更多方案/防窥两层）都按免费用户处理，
    //   付费用户点一下就被弹「去买 VIP」⇒ 误以为权益丢失。
    // 修法：启动最早时机补一次查询，与「我的」页那处并存。
    // · 安全性：`refreshVip` **只升不降**（IapManager.ets:41-43）——查到已购才置 true，
    //   查不到（未登录/网络异常/沙盒查不到已发货订单）绝不清本地位，重复调用幂等无副作用。
    // · 不阻塞启动：不 await（IAP 是网络调用，await 会拖慢首帧）。
    // · 失败自吞：refreshVip 内部整个 try/catch，不抛给启动流程。
    // 回退方式：删掉下面这一行即可，行为退回 2026-10-14 之前（仅「我的」页恢复）。
    IapManager.refreshVip(this.context)
  }

  /**
   * 应用**已在后台**时点桌面快捷方式，走的是这里而**不是** `onCreate`。
   * 不实现它的话，第二次点快捷方式不会有任何反应（首次点才有效）。
   */
  onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam) {
    hilog.info(0x0000, 'testTag', '%{public}s', 'Ability onNewWant');
    this.captureQuickAction(want);
    // 外屏形态调试强制位（2026-10-24）：应用已在后台时重新拉起也能切换
    this.captureOuterDebugFlag(want);
    // 应用已在后台时，从「文件管理 → 用其他应用打开」或分享面板进来走这里
    this.captureIncomingFiles(want);
    // 应用接续（2026-10-24）：对端**热启动**恢复（singleton 启动模式下走这里）
    this.appContinuity(want, launchParam);
  }

  // ══════════════════════════════════════════════════════════════════════════
  // 应用接续 / 无缝流转（2026-10-24 新增）
  //
  // ── 官方约束（documentId `最佳实践/跨端迁移/应用接续概述/bpta-continue-cast`）──
  // · 源端：`onContinue()` 里把数据写进 `wantParam`，返回 `AGREE` 才允许迁移；
  //   `REJECT` = 拒绝（我们的用法：**不在阅读页/听书页就不允许接续**，用户拍板）；
  // · 对端：`onCreate()`（冷启动）/ `onNewWant()`（singleton 热启动）里按
  //   `launchParam.launchReason === LaunchReason.CONTINUATION` 判断并恢复；
  // · `wantParam` 数据 **< 100KB**；`restoreWindowStage` **必须在同步方法里调用**
  //   （放异步回调会导致迁移后页面加载失败）。
  //
  // ── 我们的分工 ────────────────────────────────────────────────────────────
  // · 本类只负责"存取 wantParam + 打标记"；
  // · 真正的跳转由 `Index` 消费 `ContinueBridge.KEY_PENDING` 完成 ——
  //   因为 `onCreate` 阶段 UI 还没起来、DB 也还没建表（见本文件 `:141` 注释），
  //   在这里 push 路由必然失败。
  // ══════════════════════════════════════════════════════════════════════════

  /**
   * 源端：系统触发接续时调用。
   * 只在"正在阅读/听书"时同意，其它页面一律 REJECT（用户 2026-10-24 拍板）。
   */
  async onContinue(wantParam: Record<string, Object>): Promise<AbilityConstant.OnContinueResult> {
    const p = ContinueBridge.fillWantParam(wantParam);
    if (p === null) {
      hilog.info(0x0000, 'testTag', 'onContinue: not in reader, REJECT');
      return AbilityConstant.OnContinueResult.REJECT;
    }
    // ── 全量路线（2026-10-24 修正）：书文件必须走 Asset + 分布式数据对象 ──────
    // 真机日志实证：直接写 `distributedFilesDir` 让对端读同一路径 = **读不到**。
    // 官方机制是 Asset 随对象同步。
    // ⚠️ 关键：save() 必须传 **对端 deviceId**（系统预置的 wantParam.targetDevice），
    //   传 'local' 只持久化到本机 ⇒ A 退出后 B 拿不到（真机日志 23:39:22 实证：
    //   B 端 `joinSession ok` 但永远没有 `dstObject status=restored`，9 秒超时）。
    const asset = ContinueBridge.buildAsset(this.context, p.bookUrl, p.bookName);
    const targetDevice: string = (wantParam.targetDevice !== undefined
      && wantParam.targetDevice !== null) ? String(wantParam.targetDevice) : '';
    hilog.info(0x0000, 'testTag', 'onContinue: targetDevice=%{public}s', targetDevice);
    const sessionId: string = await ContinueBridge.createSession(
      this.context, asset, targetDevice);
    if (sessionId.length > 0) {
      wantParam.ljContinueSession = sessionId;
      hilog.info(0x0000, 'testTag', 'onContinue: session ready %{public}s', sessionId);
    } else {
      hilog.warn(0x0000, 'testTag', 'onContinue: no session (asset unavailable), metadata only');
    }
    // 官方体验建议（新闻阅读/电子书）：进度同步 + 源端**退出**（用户拍板：听书也退出）。
    // 返回 AGREE 后系统按默认策略退出源端，无需应用自己 kill。
    hilog.info(0x0000, 'testTag', 'onContinue: AGREE');
    return AbilityConstant.OnContinueResult.AGREE;
  }

  /**
   * 对端：把 `want.parameters` 里的接续数据落成 AppStorage 标记。
   *
   * ⚠️ 本方法**必须是同步的**（官方原文：`restoreWindowStage` 必须在同步接口方法中执行，
   *   放异步回调会导致迁移后页面加载失败）。
   */
  private appContinuity(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    if (launchParam === undefined || launchParam === null) {
      return;
    }
    if (launchParam.launchReason !== AbilityConstant.LaunchReason.CONTINUATION) {
      return;
    }
    hilog.info(0x0000, 'testTag', 'appContinuity: CONTINUATION launch');
    // ══════════════════════════════════════════════════════════════════════
    // ⚠️⚠️ 顺序铁律（2026-10-23 真机日志定案，勿改）⚠️⚠️
    //
    // 必须**先** restoreWindowStage，**再**写 CONTINUE_PENDING。
    //
    // 真机事故证据（`docs/日志.md` 22:48:38，同一毫秒内）：
    //   `restoreWindowStage ok`
    //   `SetUIContentInner: {"stackInfo":[{"url":"pages/Index"}],"nodeInfo":{}}`
    //   `window destroy`
    //   `AceContainer Destroy begin`          ← 整个 UI 容器被销毁重建
    //   ……之后 `open: name=步步生莲.txt id=2` 才 push 阅读页
    //   ⇒ 阅读页随旧容器一起被销毁 ⇒ 用户「停在书架，没有任何操作」。
    //
    // 根因：`restoreWindowStage()` 会销毁并重建 AceContainer。而
    //   `@StorageLink + @Watch` 是**同步**回调 —— 一旦先写 AppStorage，
    //   Index 立刻 push 阅读页，紧接着容器被销毁，push 白做。
    // 修法：先把容器重建掉，再写标记 ⇒ Index（新的那个）通过 @Watch 或
    //   onPageShow 消费，`waitReadyThenFind()` 会等路由就绪后才 push。
    // ══════════════════════════════════════════════════════════════════════
    // ① 官方范式：给框架一份 LocalStorage 用于恢复窗口数据
    // SDK `UIAbilityContext.d.ts`：「Restores the WindowStage data in the UIAbility.
    //   It can be called only on the main thread.」
    // 不调它会报 `E [JUA1128] null content storage`（真机日志实证）。
    try {
      this.context.restoreWindowStage(new LocalStorage());
      hilog.info(0x0000, 'testTag', 'appContinuity: restoreWindowStage ok (before pending)');
    } catch (e) {
      hilog.error(0x0000, 'testTag', 'appContinuity: restoreWindowStage failed %{public}s',
        e instanceof Error ? e.message : String(e));
    }
    // ② 再解析 wantParam（内部会写 CONTINUE_PENDING，触发 Index 消费）
    const p = ContinueBridge.restoreFromWant(want);
    if (p === null) {
      hilog.warn(0x0000, 'testTag', 'appContinuity: payload missing');
      return;
    }
    // ③ 对端：加入源端建的 session，等 Asset 同步落地
    // 官方三条 ⚠️ 全在 `ContinueBridge.joinSession()` 里照做了
    // （属性全空防倒灌 / 先 on('status') 再 setSessionId / 对象常驻）。
    ContinueBridge.joinSession(this.context, p.sessionId);
  }

  onDestroy() {
    hilog.info(0x0000, 'testTag', '%{public}s', 'Ability onDestroy');
  }

  /**
   * 应用接续（2026-10-24）：**接续拉起时框架调用的是本回调，而不是 onWindowStageCreate()**。
   *
   * ── 官方原文（SDK `@ohos.app.ability.UIAbility.d.ts:412-427`）──────────────
   * > Called when the page stack is restored for the target UIAbility during
   * > cross-device migration.
   * > **NOTE**: When an application is launched as a result of a migration, the
   * > **onWindowStageRestore()** lifecycle callback function, **rather than
   * > onWindowStageCreate()**, is triggered following onCreate() or onNewWant().
   * > This sequence occurs for **both cold start and hot start**.
   *
   * ── 不实现它的后果（真机日志 `docs/日志.md` 15:48:44 实证）──────────────
   * `E [JUA1128] null content storage` —— 框架拿不到 LocalStorage/页面栈 ⇒
   * 冷启动时窗口**空白**（loadContent 一次都没跑），热启动时页面栈恢复失败。
   * 这就是"接续到了但没跳阅读页"的第一层原因。
   *
   * ── 为什么分冷/热两条分支 ────────────────────────────────────────────────
   * `onWindowStageCreate` 里的初始化很重（建表、迁移、亮度、防窥、一镜到底…），
   * 热启动时**已经跑过一遍**，重复执行会重复注册回调。所以用 `windowStageInited` 闸门：
   * · 冷启动 ⇒ 完整补跑 `onWindowStageCreate`（框架不会替我们跑）；
   * · 热启动 ⇒ 只把 windowStage 重新交给 WindowAbility，页面与 DB 本就绪。
   */
  onWindowStageRestore(windowStage: window.WindowStage): void {
    hilog.info(0x0000, 'testTag', 'Ability onWindowStageRestore, inited=%{public}s',
      String(this.windowStageInited));
    if (!this.windowStageInited) {
      // 冷启动被接续拉起：补全套初始化（loadContent 等）
      this.onWindowStageCreate(windowStage);
      return;
    }
    // 热启动：窗口还在，只需确保 WindowAbility 持有最新的 windowStage
    WindowAbility.getInstance().setWindowStage(windowStage);
  }

  onWindowStageCreate(windowStage: window.WindowStage) {
    this.windowStageInited = true;
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
    // ★ 2026-10-20 闪退修复（必读）：**先把"就绪等待者"登记上**，再让 UI 继续加载。
    //   书架 `BookContent.aboutToAppear` 会 `await DataBase.whenReady()`（见那边注释），
    //   这里提前调一次 `whenReady()` 只是**创建并持有 Promise**，不改任何时序，
    //   作用是保证"信号发出前监听方一定已登记"这条契约成立（避免永远等下去）。
    //   真机事故证据见 `docs/日志.md`：迁移未完成时书架已开始查询 ⇒ GetColumnIndex(-1) ⇒ 闪退。
    DataBase.whenReady()
    // ── 离线模式（2026-10-13）：把落盘意图灌进 AppStorage，供各页 @StorageLink 订阅 ──
    //    必须在首屏渲染前调用，否则首帧会按默认「全量模式」渲染再闪一下。
    OfflineMode.init();
    // ── 「音量键翻页」默认值一次性迁移（2026-10-19）─────────────────────────────
    //    该开关默认由「关」改成「开」，但只对新装用户生效；老用户（升级安装）保持原来的「关」。
    //    幂等：迁移过的机器靠 Preferences 标记跳过 ⇒ 以后版本更新不会覆盖用户配置。
    //    同样必须早于首屏渲染（设置页首帧要按迁移后的值渲染）。
    KeyVolDefaultMigration.runOnce();
    // ── 「震动强度 / 震感模式」默认值一次性迁移（2026-10-22）─────────────────────
    //    新默认值 = 强度 500 / 震感**第 2 档**（2026-10-25 由第 3 档再改，用户口径
    //    「首次安装应该是强度 500，震感 2 档」）；**只对新装生效**，
    //    老用户（升级安装）若从未拖过滑块，显式写回改造前的 250 / 250（不改变手感）。
    //    幂等：独立标记键 `hapticsDefaultMigratedV1` ⇒ 以后版本更新不再执行。
    //    同样必须早于首屏渲染（设置页首帧要按迁移后的值渲染）。
    HapticsDefaultMigration.runOnce();
    // ── V2（2026-10-25）：把"仍停在旧默认 250/250 上"的存量配置升到新默认 ──────────
    //    由 `HapticsDefaultMigration.UPGRADE_LEGACY_DEFAULTS` 控制，**当前开启**
    //    （用户 2026-10-25 拍板选"全员生效"口径）：只升级"值仍精确等于旧默认 250/250"
    //    的键，用户真正拖过的值一律不动；跑一次即落 `hapticsDefaultMigratedV2` 永不再跑。
    //    详见该类 V2 段注释（含一键回退：把该常量改回 false）。
    HapticsDefaultMigration.runOnceV2();
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

      // ══ 断点体系「修活」（2026-10-23）══════════════════════════════════════
      // ── 改之前的事实（取证）────────────────────────────────────────────────
      //   `updateBreakpoint()` 早就写好了，但**全工程 0 处调用**；
      //   它写入的 AppStorage 键 `currentBreakpoint` 也**0 处消费**
      //   ⇒ 整套断点体系是死代码，任何页面都无法按屏幕宽度做响应式布局
      //     （书架宫格因此只能写死 3 列，见 `BookContent.ets` 的 `lanes`）。
      //
      // ── 现在做的两件事 ─────────────────────────────────────────────────────
      //   ① 启动时立刻算一次（此时窗口已完成布局，`windowRect` 是真实值）；
      //   ② 注册 `windowSizeChange` 持续维护 —— 旋转 / 折叠展开 / 2in1 拖窗口 /
      //      分屏都会触发，这正是响应式布局需要的输入。
      //   为什么自己注册而不是复用 `WindowAbility.onWindowSizeChange()`：
      //   那个是**业务回调 + 150ms 防抖**（合并一次旋转的多次上报），
      //   而断点需要**第一时间**跟随（防抖窗口内布局会先按旧断点渲染一帧）；
      //   且 `EntryAbility` 是 `updateBreakpoint` 的持有者，放这里无需跨模块暴露。
      //   监听器数量：`on('windowSizeChange')` 允许多个监听，二者互不影响。
      //
      // ── 单位 ───────────────────────────────────────────────────────────────
      //   `windowSizeChange` 回调给的是**物理像素**，`updateBreakpoint()` 内部
      //   已经按 `densityPixels` 换算成 vp 再判档（阈值 320/600/840 vp）。
      //   取值链依据：官方 `API参考/ArkUI_方舟UI框架/.../windowSizeChange`
      //   「回调参数为 `window.Size`（物理像素）」。
      try {
        this.updateBreakpoint(windowClass, windowClass.getWindowProperties().windowRect.width);
        windowClass.on('windowSizeChange', (size: window.Size) => {
          this.updateBreakpoint(windowClass, size.width);
        });
        hilog.info(0x0000, 'testTag', 'breakpoint live: init=%{public}s',
          AppStorage.get<string>('currentBreakpoint') ?? '');
      } catch (e) {
        hilog.error(0x0000, 'testTag', 'breakpoint live failed: %{public}s',
          e instanceof Error ? e.message : String(e));
      }

      // ══ PuraX 外屏形态判定（2026-10-24）══════════════════════════════════════
      // 判定收口在 `common/utils/OuterScreen.ets`（文件头有完整取证），这里只负责
      // 「启动算一次 + 跟随窗口变化重算」两件事，结果写进 `AppStorage('outerMinimal')`。
      //
      // 为什么挂在**断点注册旁边**：两者输入完全同源（窗口宽度），生命周期也同源
      //   （`windowSizeChange` 覆盖折叠展开 / 旋转 / 2in1 拖窗口 / 分屏），
      //   放一起便于以后一起维护；且此时窗口已完成首次布局，`windowRect` 是真实值。
      // 为什么 `windowSizeChange` 是**主信号**：官方 FAQ `faqs-arkui-1589` 明确
      //   「云调试环境下，`display.on('foldStatusChange')` 无法监听折叠屏屏幕状态的改变」
      //   ⇒ 折叠状态事件在模拟器/云调试下拿不到，窗口尺寸变化才是可靠的。
      //   `foldStatusChange` 由 `OuterScreen` 内部注册作辅助（真机上能更早感知）。
      try {
        OuterScreen.init(windowClass);
        windowClass.on('windowSizeChange', () => {
          OuterScreen.refresh();
        });
        hilog.info(0x0000, 'testTag', 'outerScreen live: init=%{public}s',
          OuterScreen.isOn() ? 'true' : 'false');
      } catch (e) {
        // 判定失败绝不能影响启动 —— 静默降级为"不是外屏"
        hilog.error(0x0000, 'testTag', 'outerScreen live failed: %{public}s',
          e instanceof Error ? e.message : String(e));
      }

      // ── 书架宫格列数：启动即从 Preferences 回填到 AppStorage（2026-10-23）──────
      //   `BookContent` 用 `@StorageProp('shelfGridColumns')` 订阅该键，而 AppStorage
      //   是内存态、冷启动为空 ⇒ 不回填的话用户手动设过的列数重启后失效。
      //   `ShelfPrefs.getUserColumns()` 内部已做范围钳制（2..8，0=自动）。
      try {
        AppStorage.setOrCreate(ShelfPrefs.KEY_GRID_COLUMNS_STORAGE, ShelfPrefs.getUserColumns());
      } catch (e) {
        hilog.error(0x0000, 'testTag', 'shelfGridColumns restore failed: %{public}s',
          e instanceof Error ? e.message : String(e));
      }

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
    // ══════════════════════════════════════════════════════════════════════════
    // 屏幕方向策略（2026-10-23 用户拍板）
    // ══════════════════════════════════════════════════════════════════════════
    //   · **手机：锁竖屏**（用户原话「手机不支持横屏」）。
    //     旧实现手机**完全没设方向** ⇒ 走系统默认（多数手机可自由旋转）
    //     ⇒ 横屏下布局没做过适配 = 用户看到的"横竖屏切换很烂"。
    //   · **平板 / 2in1（笔记本模式）：自由旋转**（用户原话「自由旋转」）。
    //     旧实现只有 tablet 设了 `AUTO_ROTATION_RESTRICTED`（受限旋转，部分方向不可用），
    //     2in1 完全没处理。
    //   依据：`setPreferredOrientation(orientation: Orientation): Promise<void>`
    //        见 `…\ets\api\@ohos.window.d.ts`，`@since 9`；枚举 `window.Orientation`
    //        含 `PORTRAIT` / `AUTO_ROTATION` / `AUTO_ROTATION_RESTRICTED` 等。
    //   回退：改回 `if (deviceInfo.deviceType === 'tablet') { … AUTO_ROTATION_RESTRICTED }`
    //        即恢复改造前行为（手机会重新变成可旋转）。
    if (deviceInfo.deviceType === 'phone') {
      WindowAbility.getInstance().setOrientation(windowStage, window.Orientation.PORTRAIT);
    } else {
      // tablet / 2in1 / 其它宽屏设备：自由旋转
      WindowAbility.getInstance().setOrientation(windowStage, window.Orientation.AUTO_ROTATION);
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
