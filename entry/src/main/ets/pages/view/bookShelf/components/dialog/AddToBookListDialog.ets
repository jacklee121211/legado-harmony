import catalogAddShelf from '../../Manage/components/catalogAddShelf'
import { MaterialColumnModifier } from '../../../../../common/utils/ImmersiveMaterialUtil'

/**
 * 「加入书单」弹窗 —— **全工程唯一入口包装**（v3.21 统一）。
 * 调用方：书籍长按（BookInfoDialogs）、分组长按（FolderInfoDialog）、
 * 管理页（BookManagePage）/ 文件夹管理（BookManageDialog）。
 *
 * ── 为什么必须有这一层 @CustomDialog 包装（2026-10-01 闪退修复）─────────────────
 * `catalogAddShelf` 是**普通 @Component**（无 `@CustomDialog` 装饰器）。把它直接写进
 * `CustomDialogController` 的 `builder:` 字段初始化器（原 `FolderInfoDialog.ets:52`），
 * 真机实测必崩：
 *   TypeError: class constructor cannot called without 'new'
 *     at FolderInfoDialog entry (FolderInfoDialog.ets:52:14)
 *     at builder entry (componets/group/GroupType.ets:41:16)
 * （2026-10-01 真机日志，长按分组打开弹窗即闪退，Kill Reason: Js Error。）
 * 工程里能安全放进 builder 的全是 `@CustomDialog` struct —— 本文件就是把 catalogAddShelf
 * 包一层 @CustomDialog 再给各方用。
 *
 * ── 为什么必须是 CustomDialog 而不是 bindSheet（材质取证）──────────────────────
 * 用户要求加入书单弹窗要有**半透明沉浸光感材质**，而 **`SheetOptions` 里没有任何材质字段**
 * （已逐个核对 `common.d.ts` 的 `interface SheetOptions` 全部字段，没有 `systemMaterial`）
 * ⇒ sheet 载不了材质。官方给弹窗材质的渠道是 `CustomDialogControllerOptions.systemMaterial`
 * （`custom_dialog_controller.d.ts:681`，@since 26.0.0），且前提是 `customStyle: false`
 * （`true` 时 dialog 层背景透明、材质无处附着 —— 本工程"弹窗全透明"事故的根因）。
 *
 * ── 高度/四圆角（2026-10-01）────────────────────────────────────────────────
 * 调用方 options 必须给 `height: 400` + `alignment: Center` + `cornerRadius: 20`：
 * catalogAddShelf 根节点是 `height('100%')`，弹窗层无确定高度时百分比按最大约束解 ⇒
 * 弹窗被撑满整屏、圆角顶到屏幕边缘（"加入书单不是四圆角卡片"的根因）。
 * 本层根 Column `height('100%')` 吃满调用方给的 400，内部 Scroll 才有界。
 */
@CustomDialog
export default struct AddToBookListDialog {
  controller?: CustomDialogController
  /** 目标所在大类（书籍的 bookType / 分组的 groupType；管理页传其 currentIndex） */
  @Prop currentIndex: number = 0
  /** 要加入书单的对象 id 列表（书籍 id / 分组 groupId / 管理页多选 id） */
  @Prop ids: number[] = []
  /** 0=书籍（ids 为 bookId），1=分组（ids 为 groupId，加入前先展开为组内书籍） */
  @Prop bookOrFolder: number = 0
  /** 关闭回调（由父级传入；父级在此做"子退父进"恢复与数据刷新） */
  cancel: () => void = () => {
  }
  /** 背板：调用方已通过 options 提供材质 ⇒ 传 `true` 让出背景（依据见类注释） */
  private surface: MaterialColumnModifier = new MaterialColumnModifier(Color.White, true)

  build() {
    Column() {
      catalogAddShelf({
        onClickShelf: (_val: boolean) => {
          this.cancel()
          this.controller?.close()
        },
        currentIndex: this.currentIndex,
        ids: this.ids,
        bookOrFolder: this.bookOrFolder
      })
    }
    .width('100%')
    .height('100%')
    // 兜底圆角：材质生效时由 dialog 层裁；回落白实底时四角也不能露直角。
    .borderRadius(20)
    .attributeModifier(this.surface)
  }
}
