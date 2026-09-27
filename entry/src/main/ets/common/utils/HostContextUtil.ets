/**
 * ── T13/D-17：`getContext()` 的确定性替代 ────────────────────────────────────
 * 把「取当前页面/能力的 Context」从**全局 `getContext()`** 改为
 * **`UIContext.getHostContext()`**，并保留旧路径作为回退。
 *
 * ## 官方依据（原文）
 *
 * 1) SDK `…\ets\component\common.d.ts:1346-1366`（全局 `declare function getContext(component?: Object): Context;`）：
 *    「Obtains the Context object associated with a component on the page.
 *      @param component - indicate the component on the page.
 *      **If no component is passed in or the passed-in parameter type is invalid, the default context is returned.**
 *      The default context is the context obtained by tracing the call chain of the API.
 *      **If this API is used in an asynchronous callback or not initially called on the current page,
 *      the context of the instance may fail to be traced. In this case, `undefined` is returned.**」
 *    且 `@since 11` / **`@deprecated since 18`** /
 *    **`@useinstead ohos.arkui.UIContext.UIContext#getHostContext`**
 *
 * 2) SDK `…\ets\api\@ohos.arkui.UIContext.d.ts:5212-5227`：
 *    `getHostContext(): Context | undefined;` `@since 12`
 *    「Obtains the context of this ability. … **If the ability context does not exist, `undefined` is returned.**」
 *    —— 它是**确定性**取值（不依赖调用链回溯），这是它取代 `getContext()` 的核心理由。
 *
 * 3) 本项目已有先例（**活的**推荐用法）：
 *    `pages/Index.ets:36` `this.getUIContext().getHostContext()`。
 *
 * ## 风险与开关
 * 两个接口在"页面内同步调用"这一常见场景下取值相同；差异在于**异步回调 / 非页面首帧**时
 * `getContext()` 可能回溯不到而返回 `undefined`（官方原文），此时旧代码往往直接 `.xxx` ⇒ 抛异常。
 * 由于无法本地验证"每个站点在真机上都等价"，本迁移**默认关闭**：
 * **默认 `false` = 旧行为**（完全走 `getContext(...)`）；回退 = 把下面这一行改回 `false`。
 *
 * ## 验证点（翻 true 之后必须做的真机验证）
 *  1. 文件导入（选书源 / 本地导入）→ 能正常拉起选择器；
 *  2. 「分享书单为图片」→ 能写入相册（该路径的 `getContext()` 位于 `imagePacker.packing().then(...)`
 *     **异步回调**内，正是官方点名的失败场景）；
 *  3. 订阅批量编辑的两个 `eventHub.emit`（`SubscriptionBatchEdit`）仍能生效；
 *  4. 应用内购买（`productViewManager.loadProduct`）仍能被拉起；
 *  5. 无新增 `undefined` 相关异常。
 */

import { common } from '@kit.AbilityKit';
import { UIContext } from '@kit.ArkUI';

/** T13/D-17：`getContext()` → `UIContext.getHostContext()` 开关。`false` = 旧行为。 */
const USE_UICONTEXT_HOST: boolean = false;

/**
 * 取当前页面的 Context（确定性优先，失败回退旧实现）。
 *
 * 返回类型刻意声明为**非可选**的 `common.Context`：让调用方可以直接
 * `hostContext(…).eventHub.xxx()` 而**不需要**写 `(hostContext(…) as common.Context).xxx()` ——
 * 后者在 ArkTS 里编译期会报 `10505001 This expression is not callable`（实测，见审计 §24-2），
 * 而前者正常。
 *
 * @param ui 组件内通过 `this.getUIContext()` 取得；拿不到时传 `undefined`
 * @param component 旧 `getContext(component)` 的入参，一般传 `this`；不传则等价于旧 `getContext()`
 */
export function hostContext(ui: UIContext | undefined, component?: Object): common.Context {
  if (USE_UICONTEXT_HOST && ui !== undefined) {
    const ctx: common.Context | undefined = ui.getHostContext();
    if (ctx !== undefined) {
      return ctx;
    }
  }
  // ---------- 旧路径（默认；也是新路径取不到时的回退）----------
  return (component === undefined ? getContext() : getContext(component)) as common.Context;
}
