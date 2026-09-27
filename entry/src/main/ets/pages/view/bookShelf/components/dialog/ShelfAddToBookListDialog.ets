import { Books } from '../../../../../database/entities/Books'
import { Haptics } from '../../../../../common/utils/Haptics';
import catalogAddShelf from '../../Manage/components/catalogAddShelf'
import { MaterialColumnModifier } from '../../../../../common/utils/ImmersiveMaterialUtil'

/**
 * 「加入书单」弹窗（2026-09-22 从 `bindSheet` 改成 `@CustomDialog`）。
 *
 * ── 为什么必须改成 CustomDialog ────────────────────────────────────────────
 * 用户要求这个弹窗要有**半透明沉浸光感材质**（与「书籍长按弹窗」「移动分组弹窗」同款），
 * 而 **`SheetOptions` 里没有任何材质字段** —— 已逐个核对 `common.d.ts` 的
 * `interface SheetOptions` 全部 36 个字段，**没有 `systemMaterial`**
 * ⇒ sheet 载不了材质，只能实色/半透明模拟。
 *
 * 官方给弹窗材质的渠道是 `CustomDialogControllerOptions.systemMaterial`
 * （`custom_dialog_controller.d.ts:681`，@since 26.0.0），且实测前提是
 * `customStyle: false`（`true` 时 dialog 层背景透明、材质无处附着 —— 这是本工程
 * 之前"弹窗全透明"事故的根因，见 `MaterialColumnModifier.hasOptionsMaterial` 注释）。
 *
 * 调用方（`BookInfoDialogs.catalogAddShelfDialog`）已配好：
 * `alignment: Bottom` + `width: '92%'` + `offset{dx:0,dy:-16}` + `cornerRadius: 20`
 * + `customStyle: false` + `systemMaterial` ⇒ 悬空四圆角 + 沉浸光感，与长按弹窗同款。
 *
 * 本组件只负责**让出背景**（`MaterialColumnModifier(…, true)`），把 dialog 层材质透出来。
 */
@CustomDialog
export default struct ShelfAddToBookListDialog {
  controller?: CustomDialogController
  @Prop bookData: Books
  /** 关闭回调（由 `BookInfoDialogs` 传入） */
  cancel: () => void = () => {
  }
  /** 背板：调用方已通过 options 提供材质 ⇒ 传 `true` 让出背景 */
  private surface: MaterialColumnModifier = new MaterialColumnModifier(Color.White, true)

  build() {
    Column() {
      catalogAddShelf({
        onClickShelf: (val: boolean) => {
          // 复用原 sheet 的语义：内容自报是否还需要显示；这里一律按"关闭"处理
          this.cancel()
          this.controller?.close()
        },
        currentIndex: this.bookData.bookType,
        ids: this.bookData.id ? [this.bookData.id] : []
      })
    }
    .width('100%')
    // 兜底圆角：材质生效时由 dialog 层裁；材质不可用时内容层回落白实底，
    // 四角也必须是圆的才不会露直角。
    .borderRadius(20)
    .attributeModifier(this.surface)
  }
}
