import newBookShelf from '../../Manage/bookManage/newBookShelf'
import { WorksLists } from '../../../../../database/entities/WorksLists'
import { MaterialColumnModifier } from '../../../../../common/utils/ImmersiveMaterialUtil'

/**
 * 新建/编辑书单弹窗（2026-10-01，修"长按书籍→加入书单→点击新建没用"）。
 *
 * ── 为什么必须从 bindContentCover 改成 CustomDialog ──────────────────────────
 * 原 `catalogAddShelf` 用 `bindContentCover` 承载 newBookShelf。bindContentCover 是
 * **页面级**模态 —— 当加入书单本身已经以 CustomDialog 打开（长按书籍/长按分组入口，
 * 2026-10-01 统一后）时，content cover 盖不过弹窗 ⇒ 用户实测"点击新建没用，是没功能"
 * （2.md 17:0x）。管理页入口正常（"管理中的加入书单有用"），因为那里 catalogAddShelf
 * 在页面上。CustomDialog 可以叠加在弹窗之上，页面/弹窗两种宿主都成立。
 *
 * newBookShelf 是普通 @Component ⇒ 不能直接进 builder 字段初始化器（裸组件进 builder
 * 真机闪退，见 AddToBookListDialog 类注释），必须本层 @CustomDialog 包装。
 */
@CustomDialog
export default struct NewBookShelfDialog {
  controller?: CustomDialogController
  /** 大类（书架 currentIndex） */
  @Prop currentIndex: number = 0
  /** 0=新建书单 2=把选中内容加入已有书单（newBookShelf 语义） */
  @Prop workBookListStatus: number = 0
  /** 编辑目标书单（新建时传空对象） */
  @Prop lastWorkBookList: WorksLists = new WorksLists()
  /** 要加入书单的书籍 id 列表 */
  @Prop bookIds: number[] = []
  /** 编辑器"完成/返回"回调（宿主刷新列表） */
  changeShowNumber: () => void = () => {
  }
  /** 编辑器"提交"回调（宿主关闭加入书单流程） */
  submit: () => void = () => {
  }
  /** 遮罩关闭（autoCancel=false 时仅返回键触发） */
  onClose: () => void = () => {
  }
  /** 背板：调用方 options 已给 systemMaterial ⇒ 让出背景 */
  private surface: MaterialColumnModifier = new MaterialColumnModifier(Color.White, true)

  build() {
    Column() {
      // build 内组件参数的闭包只能是单表达式（ets lint noNonUISyntax），
      // 多语句逻辑收敛到私有方法
      newBookShelf({
        currentIndex: this.currentIndex,
        // 本组件宿主是 @CustomDialog：newBookShelf 关掉系统安全区 padding（弹窗自带留白，
        // 不关会底部多一条空白——真机截图 19:07"底部 ui 不对"）
        embeddedInDialog: true,
        changeShowNumber: (): void => this.onEditorDone(),
        submit: (): void => this.onEditorSubmit(),
        workBookListStatus: this.workBookListStatus,
        lastWorkBookList: this.lastWorkBookList,
        bookIds: this.bookIds
      })
    }
    .width('100%')
    .height('100%')
    .borderRadius(20)
    .attributeModifier(this.surface)
  }

  private onEditorDone(): void {
    this.controller?.close()
    this.changeShowNumber()
  }

  private onEditorSubmit(): void {
    this.controller?.close()
    this.submit()
  }
}
