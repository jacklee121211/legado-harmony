/**
 * 意图框架执行器 —— 小艺「带我去」跳转（端插件 foreground 模式）
 *
 * ══════════════════════════════════════════════════════════════════════════
 * 用途
 * ══════════════════════════════════════════════════════════════════════════
 * 用户在「小喵」对话里说「带我去导入页 / 打开设置」时，小喵调用端插件，
 * 系统按 `insight_intent.json` 的 `executeMode: foreground` 把本 Ability 拉到前台，
 * 回调本类的 `onExecuteInUIAbilityForegroundMode`，我们据此跳到对应页。
 *
 * ══════════════════════════════════════════════════════════════════════════
 * 设计：**不在这里做页面跳转**，只写 AppStorage 标记
 * ══════════════════════════════════════════════════════════════════════════
 * 与工程既有约定完全一致（见 `EntryAbility.captureQuickAction()` 与
 * `Index.consumeQuickAction()` 的注释）：
 *   · 本回调触发时 UIAbility 可能刚起、DB 未建表、Navigation 栈未 attach
 *     ⇒ 此刻 `AppRouter.push` 会因 `stack === null` 静默失败；
 *   · 正确做法是把「意图」写进 AppStorage，由 `Index` 页在就绪后消费。
 *
 * 复用**同一条 `quickAction` 通道**（`'listen'` / `'read'` 已在用），
 * 新增 `'tab:<index>'` 形式承载底部页签跳转，不引入第二套机制。
 *
 * ══════════════════════════════════════════════════════════════════════════
 * 版本与平台
 * ══════════════════════════════════════════════════════════════════════════
 * · 意图框架 `InsightIntentExecutor` 首批接口 API version 11
 * · `executeMode: foreground` 语义见 `@ohos.app.ability.insightIntent`：
 *     UI_ABILITY_FOREGROUND = 0 → 「将UIAbility在前台显示」
 * · 本工程 `compatibleSdkVersion: "6.0.0(20)"` 完全覆盖
 *
 * ══════════════════════════════════════════════════════════════════════════
 * 回退方式
 * ══════════════════════════════════════════════════════════════════════════
 * 删除 `entry/src/main/resources/base/profile/insight_intent.json` 即整体失效，
 * 本文件成为无调用点的死代码，不影响 App 正常运行。
 */

import { insightIntent, InsightIntentExecutor } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';

const LOG_TAG: string = 'MiaoYueIntent';

/** 底部页签索引 —— 与 `pages/Index.ets` 的 `new NavItem(i, ...)` 严格对应 */
const TAB_SHELF: number = 0;
const TAB_THEME: number = 1;
const TAB_SETTING: number = 2;
const TAB_MINE: number = 3;

export default class InsightIntentExecutorImpl extends InsightIntentExecutor {
  /**
   * 前台模式回调：UIAbility 已在前台显示时触发。
   *
   * ⚠️ 生命周期顺序（SDK 原文）：
   *   冷启动：onCreate → onWindowStageCreate → onExecuteInUIAbilityForegroundMode → onForeground
   *   热启动（原在后台）：onNewWant → onExecuteInUIAbilityForegroundMode → onForeground
   *   热启动（原在前台）：onExecuteInUIAbilityForegroundMode
   */
  onExecuteInUIAbilityForegroundMode(
    name: string,
    param: Record<string, Object>,
    pageLoader: window.WindowStage
  ): insightIntent.ExecuteResult {
    // param 目前未参与路由决策（各意图的跳转目标由 name 唯一确定），
    // 保留形参以符合 SDK 签名；打印一次便于真机排查系统实际传了什么。
    hilog.info(0x0000, LOG_TAG, 'foreground intent: %{public}s, hasParam: %{public}s',
      name, param !== undefined ? 'yes' : 'no');

    // 确保主页面已加载（热启动时 WindowStage 里已有内容，loadContent 会重建，
    // 所以只在冷启动且未加载时调用 —— 这里用 try 兜底，失败不影响跳转）
    try {
      pageLoader.loadContent('pages/Index').catch((e: Error) => {
        hilog.info(0x0000, LOG_TAG, 'loadContent skipped: %{public}s', e.message);
      });
    } catch (e) {
      hilog.info(0x0000, LOG_TAG, 'loadContent threw (already loaded)');
    }

    // 只写标记，由 Index 就绪后消费（见文件头说明）
    const ok: boolean = this.dispatchIntent(name);
    if (!ok) {
      return {
        code: 1,
        result: { status: 'failed', message: `unsupported intent: ${name}` }
      };
    }
    return {
      code: 0,
      result: { status: 'ok', intent: name }
    };
  }

  /**
   * 把意图翻译成 AppStorage 标记。
   * @returns 是否识别（false ⇒ 调用方返回失败码）
   */
  private dispatchIntent(name: string): boolean {
    switch (name) {
      case 'OpenImportPage':
        // 书架页签 + 待触发「书籍导入」
        AppStorage.setOrCreate<string>('quickAction', `tab:${TAB_SHELF}`);
        AppStorage.setOrCreate<string>('pendingShelfAction', 'import');
        return true;

      case 'OpenShelfPage':
        AppStorage.setOrCreate<string>('quickAction', `tab:${TAB_SHELF}`);
        return true;

      case 'OpenSettingsPage':
        AppStorage.setOrCreate<string>('quickAction', `tab:${TAB_SETTING}`);
        return true;

      case 'OpenMyPage':
        AppStorage.setOrCreate<string>('quickAction', `tab:${TAB_MINE}`);
        return true;

      case 'OpenListenPage':
        // 复用既有的「快速听书」通道：进阅读页并自动起播
        AppStorage.setOrCreate<string>('quickAction', 'listen');
        return true;

      case 'OpenThemePage':
        AppStorage.setOrCreate<string>('quickAction', `tab:${TAB_THEME}`);
        return true;

      default:
        hilog.warn(0x0000, LOG_TAG, 'unknown intent: %{public}s', name);
        return false;
    }
  }
}
