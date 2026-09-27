import { BookGroups } from '../../database/entities/BookGroups'
import { Haptics } from '../../common/utils/Haptics';
import groupTypePanel from './groupTypePanel'

/**
 * 书架「分组管理」弹窗（2026-09-23 新增，用户点名要求）。
 *
 * ── 用户原话 ──────────────────────────────────────────────────────────────
 *   「点击书架的上部分右侧，有个三条杠，点击展开分组管理，**首先这个模块没有沉浸光感材质，
 *     也就是 CustomDialog，其次没有展开动画**」
 *
 * ── 改造前是什么（代码定位）──────────────────────────────────────────────
 * · 三条杠 = `componets/group/GroupType.ets` 里的 `Image($r('app.media.more_search'))`，
 *   点击置 `groupCoverShow = true`。
 * · 展开出来的东西 = 本目录下的 `groupTypePanel`，但它当时是**页内自绘 Stack**：
 *   `GroupType.ets` 里 `if (this.groupCoverShow) { Stack(){ groupTypePanel(...) ; Rect().fill(...) } }`
 *   ⇒ ① 遮罩是**手画的 `Rect`**、材质完全没有（面板根节点还写死 `.backgroundColor(Color.White)`）；
 *     ② 展开是**纯 `if`**，没有任何 `.transition()` ⇒ 硬切，没有展开动画。
 *
 * ── 现在怎么改 ────────────────────────────────────────────────────────────
 * 变成 `@CustomDialog`，一次拿到三样东西（与「目录 / 听书 / 设置」三个弹窗同款）：
 *   ① **真沉浸光感材质** → 官方「开启沉浸光感」原文把 `CustomDialog` 列在弹窗类里
 *      （documentId `…/沉浸光感开发指导/开启沉浸光感/arkts-immersive-light-sense-enable`）；
 *      材质由调用方的 `CustomDialogControllerOptions.systemMaterial` 提供，
 *      内容层用 `MaterialColumnModifier` **让开背景**（否则会挡住材质，官方 FAQ 有原文）。
 *   ② **遮罩** → 不写 `maskColor` 就是默认 `0x33000000`
 *      （SDK `component/custom_dialog_controller.d.ts:158-169` 原文
 *       「Custom mask color. Default value: **0x33000000**」），
 *      改造前那个手画 `Rect` 是 `rgba(0,0,0,0.45)`，比默认重；要还原就在调用方写 `maskColor`。
 *   ③ **展开动画** → `openAnimation` / `closeAnimation`
 *      （SDK `:205/226`），调用方传弹簧令牌。
 *
 * ── ⚠️ 数据怎么传（这一层很关键）──────────────────────────────────────────
 * 调用方（`GroupType`）是**每次展开都新建控制器**的 —— 因为
 * `custom_dialog_controller.d.ts:756` NOTE 原文「Custom dialog box parameters
 * **do not support dynamic updates**」，要传"当前的大类 index / 当前分组列表"就只能新建。
 * 而 `$xxx`（`@Link` 语法）**只能在组件构造上下文里用**，写在方法里会
 * `ReferenceError: $xxx is not defined`（本工程 2026-09-22 真机崩溃记录）。
 * ⇒ 所以这里**全部用普通 `@Prop` 传值**：新建控制器 = 新建组件实例 = 构造时取到当前值，
 *   正是我们想要的"打开瞬间的快照"语义（同 `ReaderCatalogDialog` / `SleepTimerDialog`）。
 */
@CustomDialog
export struct GroupManageDialog {
  /** 由 `CustomDialogController` 注入（`@CustomDialog` 必需字段） */
  controller?: CustomDialogController

  /** 当前要显示的分组（调用方在打开瞬间读一次） */
  @Prop showGroupList: BookGroups[] = []
  /** 小说 / 漫画 / 有声书的大类下标 */
  @Prop currentIndex: number = 0
  /** 请求关闭（面板里的 ✕ 按钮）⇒ 由调用方去 `close()` */
  onClose: () => void = (): void => {
  }

  build() {
    Column() {
      groupTypePanel({
        showGroupList: this.showGroupList,
        currentIndex: this.currentIndex,
        onClose: this.onClose
      })
    }
    .width('100%')
    // 高度**由内容决定**（弹窗 options 里不写 height）：
    // SDK `custom_dialog_controller.d.ts:126` 原文「If the width and height of the dialog box are
    // not set, the dialog box … adapts its height to the custom content node.」
  }
}
