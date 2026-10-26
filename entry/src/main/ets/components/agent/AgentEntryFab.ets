/**
 * 小喵入口悬浮按钮 —— **临时验证用**（2026-10-26）
 *
 * ══════════════════════════════════════════════════════════════════════════
 * 目的
 * ══════════════════════════════════════════════════════════════════════════
 * 验证三件事：
 *   ① FunctionComponent 能否在本工程拉起小艺智能体弹窗
 *   ② 「关联应用」配置是否正确（错了会报 1022400011 / 「智能体未授权给该应用」）
 *   ③ 端插件 foreground 的「带我去」跳转是否生效
 *
 * ══════════════════════════════════════════════════════════════════════════
 * 为什么是「悬浮按钮」而不是复用 miniBar
 * ══════════════════════════════════════════════════════════════════════════
 * 实测依据（本工程源码原文）：`components/tts/ListenDock.ets:219`
 *   「⚠️ 这里**不挂 onClick**：会让 HDS「点迷你栏自动展开」收不到事件。」
 * HDS MiniBar 的圆形区已被官方语义占用（点击 = 展开/收起迷你栏），
 * 挂 onClick 会吃掉该手势 ⇒ 不能复用。
 *
 * ══════════════════════════════════════════════════════════════════════════
 * 设备与版本（SDK 原文取证）
 * ══════════════════════════════════════════════════════════════════════════
 * · `@kit.AgentFrameworkKit.d.ts:8` → `@since 6.0.0(20)`；
 *   本工程 `build-profile.json5` `compatibleSdkVersion: "6.0.0(20)"` ⇒ 匹配。
 * · `device-define/api-version/AgentFrameworkKit.json` 中
 *   `FunctionComponent` 的 `deviceTypes` 只有 **phone / tablet**（无 2in1）
 *   ⇒ 用 `canIUse('SystemCapability.AI.Agent.AgentKit')` 门控，
 *     不支持时整个 `FunctionComponent` 分支不进入（满足 lint 28057 的 canIUse 要求）。
 *
 * ══════════════════════════════════════════════════════════════════════════
 * 一键回退
 * ══════════════════════════════════════════════════════════════════════════
 * 把 `pages/Index.ets` 里 `.overlay(this.agentEntryOverlay())` 那一行删掉即可，
 * 本文件成为无引用死代码，不影响任何既有功能。
 */

import { BusinessError } from '@kit.BasicServicesKit';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import {
  ButtonType,
  FunctionComponent,
  FunctionController
} from '@kit.AgentFrameworkKit';

const LOG_TAG: string = 'MiaoYueAgent';

/**
 * 小喵 agentId —— 取自小艺开放平台「小喵 → 配置 → AgentCard → AgentID」
 * ⚠️ 换 Agent 时**只需改这一处**。
 */
const AGENT_ID: string = 'agentf823d5db352c4e0fab89e44a64d4fd2a';

/** 悬浮按钮尺寸（vp） */
const FAB_SIZE: number = 44;

@Component
export struct AgentEntryFab {
  /** syscap 门控：只有 phone/tablet 且系统 ≥ 6.0.0(20) 才为 true */
  private supported: boolean = canIUse('SystemCapability.AI.Agent.AgentKit');
  /** 弹窗是否打开（用于按钮态反馈） */
  @State private dialogOpen: boolean = false;
  private controller: FunctionController = new FunctionController();

  aboutToAppear(): void {
    if (!this.supported) {
      hilog.info(0x0000, LOG_TAG, 'AgentKit syscap NOT supported, FAB hidden');
      return;
    }
    this.registerDialogEvents();
    this.probeAgent();
  }

  aboutToDisappear(): void {
    if (!this.supported) {
      return;
    }
    // SDK 要求成对解注册
    this.controller.off('agentDialogOpened');
    this.controller.off('agentDialogClosed');
  }

  /** 注册弹窗开关回调（全部包在 canIUse 分支内，满足 lint 28057） */
  private registerDialogEvents(): void {
    if (!canIUse('SystemCapability.AI.Agent.AgentKit')) {
      return;
    }
    this.controller.on('agentDialogOpened', (): void => {
      this.dialogOpen = true;
      hilog.info(0x0000, LOG_TAG, 'agent dialog opened');
    });
    this.controller.on('agentDialogClosed', (): void => {
      this.dialogOpen = false;
      hilog.info(0x0000, LOG_TAG, 'agent dialog closed');
    });
  }

  /** 探活：agentId 是否有效 + 功能是否支持 */
  private probeAgent(): void {
    if (!canIUse('SystemCapability.AI.Agent.AgentKit')) {
      return;
    }
    try {
      const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      this.controller.isAgentSupport(ctx, AGENT_ID).then((ok: boolean): void => {
        hilog.info(0x0000, LOG_TAG, 'isAgentSupport=%{public}s', ok ? 'true' : 'false');
      }).catch((e: BusinessError): void => {
        hilog.error(0x0000, LOG_TAG,
          'isAgentSupport failed code=%{public}d msg=%{public}s', e.code, e.message);
      });
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(0x0000, LOG_TAG, 'probeAgent threw code=%{public}d', err.code);
    }
  }

  /** 真实渲染 FunctionComponent 的分支（已被 canIUse 门控） */
  @Builder
  agentComponent() {
    FunctionComponent({
      agentId: AGENT_ID,
      controller: this.controller,
      onError: (err: BusinessError): void => {
        // 1022400010 参数错误 / 1022400011 隐私协议 / 1022400012 未登录 /
        // 1022400013 网络 / 1022400014 内部错误
        hilog.error(0x0000, LOG_TAG,
          'FunctionComponent error code=%{public}d msg=%{public}s', err.code, err.message);
      },
      options: {
        // title 为空 ⇒ 渲染为圆形图标入口（SDK BaseOptions 语义）
        title: '',
        controlSize: ControlSize.SMALL,
        buttonType: ButtonType.CIRCLE,
        isShowShadow: false
      }
    })
      .width(FAB_SIZE)
      .height(FAB_SIZE)
  }

  build() {
    if (canIUse('SystemCapability.AI.Agent.AgentKit')) {
      Stack() {
        this.agentComponent()
      }
      .width(FAB_SIZE)
      .height(FAB_SIZE)
      .borderRadius(FAB_SIZE / 2)
      // ── 触摸穿透修复（2026-10-26）────────────────────────────────────────────
      // 真机日志证据：`ITK Id:... TTHNI:fId: 0` 后面紧跟
      //   `W  Touch test result is empty.`（共 38 次）⇒ 命中链**一个节点都没命中**，
      // 而同期点 TabBar 的命中链正常（`{ T: TabBar, D: 11 };{ T: Stack, D: 13 }`）
      // ⇒ 有一层把大面积区域的命中吞掉了，而 `.overlay()` 内容天然在最上层 z 序。
      //
      // 两道保险：
      //  ① `clip(true)`：强制按 44×44 裁剪。`FunctionComponent` 是系统组件，
      //     内部可能带超出声明尺寸的绘制/命中区域（弹窗挂载容器等），
      //     不裁剪时它的实际命中范围不受 `.width/.height` 约束。
      //  ② `HitTestMode.Transparent`：SDK `component/enums.d.ts` 原文
      //     「Both the node itself and its child nodes respond to the hit test and
      //      **do not block the hit test of sibling nodes and ancestor nodes**.」
      //     ⇒ 自身和子节点照常响应（按钮仍可点），但不阻塞兄弟/祖先 —— 正是要的语义。
      //
      // ⚠️ 注意：`Transparent` 与 `None` 不同。`None` 是「自身不响应」，
      //    会把按钮自己也弄失效；这里必须用 `Transparent`。
      .clip(true)
      .hitTestBehavior(HitTestMode.Transparent)
      // 弹窗打开时轻微放大，给用户"正在进行"的即时反馈
      .scale({ x: this.dialogOpen ? 0.92 : 1, y: this.dialogOpen ? 0.92 : 1 })
      .animation({ duration: 120, curve: Curve.EaseOut })
      .onClick((): void => {
        // FunctionComponent 自身处理点击拉起弹窗；这里只做日志便于真机排查
        hilog.info(0x0000, LOG_TAG, 'FAB tapped, dialogOpen=%{public}s',
          this.dialogOpen ? 'true' : 'false');
      })
    } else {
      // 不支持 AgentKit 的设备（如 2in1）不占位
      Column().width(0).height(0)
    }
  }
}
