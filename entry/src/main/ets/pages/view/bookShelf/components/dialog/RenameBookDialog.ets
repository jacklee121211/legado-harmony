import { Books } from '../../../../../database/entities/Books'
import bookRename, { RenameBookResult, MAX_BOOK_NAME_LEN } from '../../../../../common/utils/BookRename'
import { MaterialColumnModifier } from '../../../../../common/utils/ImmersiveMaterialUtil'
import { showMessage } from '../../../../../componets/common/promptShow'
import { Haptics } from '../../../../../common/utils/Haptics'
import { ThemeStorageKey } from '../../../../../common/constants/Theme'
import { ThemeItem } from '../../../../../common/model/Theme'
import { ShelfColors } from '../../../../../common/utils/NightMode'

/**
 * 单本书「重命名」弹窗（2026-10-05 新增，用户需求：长按弹窗里作者行换成重命名入口）
 * ============================================================================
 * 规范符合性（`docs/标准-弹窗与按钮统一规范.md`）：
 *   · §2.1 `@CustomDialog` 包装（裸组件绝不进 builder）；
 *   · §2.2 options 配方由**调用方**给（`BookInfoDialogs.openRenameDialog`：customStyle:false
 *     + cornerRadius:20 + systemMaterial + SPRING_FAST 开关动画）；
 *   · §2.3 内容层**不设 backgroundColor**，用 `MaterialColumnModifier(Color.White, true)` 让出背景；
 *   · §2.4 纯内容自适应短弹窗 ⇒ options 不给固定高；
 *   · §4.1 子进父退/子退父进：本弹窗只负责"关自己 + 回调"，父弹窗恢复与否由父级决定；
 *   · §5.1/§5.2 数据变更**在 DB 提交之后**广播 `BOOK_IS_BOOK_REFRESHING`（级联改名内部已
 *     await 事务提交，见 `BookRename.rename`）。
 *
 * 改名本身**不在这里拼 SQL**：全链路（4 张表事务 + 4 类 Preferences 键迁移）都在
 * `common/utils/BookRename.ets`，那里有唯一清单与逐条证据。
 */
@CustomDialog
export default struct RenameBookDialog {
  controller?: CustomDialogController
  @Prop bookData: Books
  /** 取消（含遮罩/返回键）：本弹窗已关自己，父级据此决定是否恢复 */
  cancel: () => void = (): void => {
  }
  /** 改名成功：父级据此**整条链关闭**（对象已改名，旧弹窗快照作废）并通知列表刷新 */
  onRenamed: (newName: string) => void = (): void => {
  }

  /** 输入框当前值（打开时预填书名） */
  @State inputName: string = ''
  /** 行内错误提示（空名/重名/写库失败） */
  @State errMsg: string = ''
  /** 提交中：防连点（改名是异步事务） */
  @State busy: boolean = false
  /** 数据变更广播（规范 §5.1，书架列表监听到后重查） */
  @StorageLink('BOOK_IS_BOOK_REFRESHING') isBookRefreshing: number = 0
  @StorageProp(ThemeStorageKey.THEME) theme: ThemeItem = {} as ThemeItem

  /** 背板：调用方 options 已给 systemMaterial ⇒ 让出背景（§2.3），材质不可用时回落白实底 */
  private surface: MaterialColumnModifier = new MaterialColumnModifier(Color.White, true)

  aboutToAppear(): void {
    // @Prop 是创建瞬间快照；本弹窗由调用方**每次打开都新建 controller**（§4.4 地雷表），
    // 所以这里预填的一定是当前书名。
    this.inputName = this.bookData.bookName ?? ''
    this.errMsg = ''
    this.busy = false
  }

  build() {
    Column() {
      Text('重命名')
        .fontWeight(600)
        .fontSize(20)
        .fontColor($r('app.color.text_primary'))
        .margin({ top: 20, bottom: 12 })

      TextInput({ placeholder: '请输入新的书名', text: this.inputName })
        .maxLength(MAX_BOOK_NAME_LEN)
        .height(44)
        .enterKeyType(EnterKeyType.Done)
        .onChange((value: string): void => {
          this.inputName = value
          if (this.errMsg !== '') {
            this.errMsg = ''
          }
        })
        .onSubmit((): void => {
          this.doRename()
        })

      // 行内错误（不弹 toast：用户正在输入，就近提示最清楚）
      if (this.errMsg !== '') {
        Text(this.errMsg)
          .fontSize(12)
          // 系统分层色（不用硬编码色值，etsLint `colorConsistentWarning` 的建议做法）：
          // 深/浅色模式自动切换，且随主题分层。
          .fontColor($r('sys.color.warning'))
          .width('100%')
          .margin({ top: 8 })
      }

      Row({ space: 24 }) {
        Text('取消')
          .onClick((): void => {
            Haptics.tap()
            this.closeSelfAndCancel()
          })
          .borderRadius(15)
          .padding({ left: 30, right: 30, top: 10, bottom: 10 })
          .fontColor(this.theme.mainColor)
          .backgroundColor(this.theme.secondColor)
        Text(this.busy ? '保存中…' : '确定')
          .onClick((): void => {
            this.doRename()
          })
          .borderRadius(15)
          .padding({ left: 30, right: 30, top: 10, bottom: 10 })
          .fontColor(Color.White)
          .backgroundColor(this.busy ? ShelfColors.textSub() : this.theme.mainColor)
      }
      .padding({ top: 20, bottom: 20 })
    }
    .width('100%')
    .padding({ left: 20, right: 20 })
    .borderRadius(20)
    .attributeModifier(this.surface)
  }

  /** 关自己 → 回调父级（关自己归子弹窗，恢复父弹窗归父级；§4.1） */
  private closeSelfAndCancel(): void {
    this.controller?.close()
    this.cancel()
  }

  private async doRename(): Promise<void> {
    if (this.busy) {
      return
    }
    Haptics.tap()
    const oldName: string = this.bookData.bookName ?? ''
    const id: number = this.bookData.id ?? 0
    this.busy = true
    const res: RenameBookResult = await bookRename.rename(id, oldName, this.inputName, this.bookData.author ?? '')
    this.busy = false
    if (!res.ok) {
      this.errMsg = res.message
      return
    }
    // DB 事务已提交（BookRename 内部 await 过）⇒ 现在广播，列表重查才读到新名字（规范 §5.2）
    this.isBookRefreshing++
    showMessage('已重命名为「' + this.inputName.trim() + '」')
    this.controller?.close()
    this.onRenamed(this.inputName.trim())
  }
}
