import newAddShelf from '../../Manage/bookManage/newAddShelf'
import { MaterialColumnModifier } from '../../../../../common/utils/ImmersiveMaterialUtil'

/**
 * 「添加书籍」选书弹窗（2026-10-01，新建/编辑书单内使用）。
 *
 * 为什么必须有这层 @CustomDialog 包装（同 NewBookShelfDialog）：
 * ① `newAddShelf` 是普通 @Component，不能直接进 builder 字段初始化器（真机闪退，见
 *    AddToBookListDialog 类注释）；
 * ② 原承载方式 `bindContentCover` 是**页面级模态**——新建书单本身已是 CustomDialog，
 *    content cover 盖不过弹窗（用户实测过同款"点击没反应"）⇒ 改 CustomDialog 叠加。
 */
@CustomDialog
export default struct NewAddShelfDialog {
  controller?: CustomDialogController
  @Prop currentIndex: number = 0
  /** 已选书籍 id（回显勾选） */
  @Prop lastBookIds: number[] = []
  /** 选完回调（宿主刷新已选列表并提示） */
  addBookList: (selectBookIds: number[]) => void = (_selectBookIds: number[]) => {
  }
  /** 关闭回调 */
  close: () => void = () => {
  }
  /** 背板：调用方 options 已给 systemMaterial ⇒ 让出背景 */
  private surface: MaterialColumnModifier = new MaterialColumnModifier(Color.White, true)

  build() {
    Column() {
      // build 内组件参数的闭包只能是单表达式（ets lint noNonUISyntax），
      // 多语句逻辑收敛到私有方法
      newAddShelf({
        currentIndex: this.currentIndex,
        lastBookIds: this.lastBookIds,
        addBookList: (selectBookIds: number[]): void => this.onPicked(selectBookIds),
        close: (): void => this.onCloseTap()
      })
    }
    .width('100%')
    .height('100%')
    .borderRadius(20)
    .attributeModifier(this.surface)
  }

  private onPicked(selectBookIds: number[]): void {
    this.controller?.close()
    this.addBookList(selectBookIds)
  }

  private onCloseTap(): void {
    this.controller?.close()
    this.close()
  }
}
