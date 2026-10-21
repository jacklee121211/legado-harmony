import { ThemeStorageKey } from "../../common/constants/Theme"
import { Haptics } from '../../common/utils/Haptics';
import { ThemeItem } from "../../common/model/Theme"

/**
 * 「新建分组」的输入值与结果 —— AppStorage 公共通道（2026-10-22 新增）。
 *
 * ── 为什么必须走 AppStorage（这是**真机崩溃换来的结论**）──────────────────────
 * 真机日志（`docs/日志.md`，2026-10-21 16:06:23）：
 * ```
 * Reason:SyntaxError
 * Error message:undefined 'bookType'[-227] <@Component 'addBookTypeDialog'[251]>:
 *   constructor: source variable in parent/ancestor @Component must be defined.
 *     at addBookTypeDialog entry (addBookTypeDialog.ets:40:1)
 *     at builder entry (BookSelectGroupDialog.ets:365:16)
 * Kill Reason:Js Error
 * ```
 * 根因：本组件原来用 `@Link bookType: string`，而**新的连续创建路径**是在**方法里**
 * `new CustomDialogController({ builder: addBookTypeDialog({...}) })` 打开的
 * （`BookSelectGroupDialog.openManageAddTypeDialog()`）。
 * `@Link` 要求有**父组件实例**可绑定（同步链 `SynchedPropertyTwoWayPU`，
 * 见堆栈第 1 帧），方法里 new 出来的 builder 没有父组件上下文 ⇒
 * 「source variable in parent/ancestor @Component must be defined」⇒ **进程被杀**。
 *
 * ⇒ 输入值改走 `@StorageLink`（AppStorage 全局通道），它不需要父组件绑定，
 *   方法内 new controller 完全成立。`createSucceeded` 同理（见组件内注释）。
 *
 * ⚠️ 两条入口都走这条通道，不再有任何 `@Link`：
 *   · `BookSelectGroupDialog.addBookType`（「移动至分组」路径，字段初始化器 new）；
 *   · `BookSelectGroupDialog.manageAddTypeDialog`（分组管理「连续创建」路径，方法内 new）。
 */
export class AddGroupChannel {
  /** 输入框当前内容（`@StorageLink` 双向绑定） */
  static readonly KEY_TEXT: string = 'ADD_GROUP_TEXT';
  /** true = 上一次「确定」真的建组成功（决定输入框 placeholder 文案） */
  static readonly KEY_OK: string = 'ADD_GROUP_LAST_OK';
}

/**
 * 添加分类类型弹窗（新建分组）。
 *
 * ── 2026-10-22 新增「连续创建」模式（`keepOpen`）──────────────────────────────
 * 用户原话：「新建分组弹窗不用点完确定取消，而是可以**连续创建**，比如输入1，点击确定，
 *   1 已经被创建了，但是这个弹窗没动，只是输入框重制了，可以继续输入，并且内部的内容
 *   从请输入分组名称变成了创建成功，可继续输入创建。这个逻辑就避免有的用户想要一次性
 *   多创建，反复打开弹窗问题。但是每次创建后底部的父弹窗需要实时更新，不然用户回不清楚
 *   是否真正创建成功。」
 *
 * 行为契约（`keepOpen === true` 时）：
 *   ① 点「确定」⇒ 调 `confirm()` 真正建组，但**本弹窗不关**；
 *   ② 输入框**清空**、placeholder 换成「创建成功，可继续输入创建」（`doneHint`）；
 *   ③ 可以继续输入下一个名字、再点确定 ⇒ 反复创建；
 *   ④ 每次创建后由调用方刷新父弹窗（`BookSelectGroupDialog` 的 `onGroupCreated` 通道）；
 *   ⑤ 点「取消」（此时文案由调用方决定，语义 = 关闭）⇒ 才真正关闭。
 *
 * ⚠️ 为什么"不关自己"这件事在这里成立（而别处强调"子组件内 close() 不可靠"）：
 *   那条坑说的是**关闭**（子组件里 `controller.close()` 可能无效）；本模式根本不需要关，
 *   只需要"保持打开 + 重置内部状态"，都是**组件自己的状态**，不涉及 controller。
 *   真正要关的那一次（取消）仍然由**调用方**持有 controller 关闭 —— 见 `BookSelectGroupDialog`。
 *
 * 一键回退：调用方不传 `keepOpen`（默认 false）⇒ 完全保持改造前的行为（确定后关闭）。
 */
@CustomDialog
export default struct addBookTypeDialog {

  /**
   * 输入框内容 —— **`@StorageLink`，不是 `@Link`**。
   *
   * ⚠️ 2026-10-22 真机崩溃修复（必读，别再改回 `@Link`）：
   *   原来是 `@Link bookType: string`，而「连续创建」这条路径是在**方法里**
   *   `new CustomDialogController({ builder: addBookTypeDialog({...}) })` 打开的
   *   ⇒ `@Link` 找不到父组件实例可绑定 ⇒ 真机直接杀进程：
   *   ```
   *   Error message:undefined 'bookType'[-227] <@Component 'addBookTypeDialog'[251]>:
   *     constructor: source variable in parent/ancestor @Component must be defined.
   *   Kill Reason:Js Error
   *   ```
   *   `@StorageLink` 绑的是 AppStorage（全局），不依赖父组件 ⇒ 两条入口都安全。
   *   完整证据见文件头 `AddGroupChannel` 的注释。
   */
  @StorageLink(AddGroupChannel.KEY_TEXT) bookType: string = ''

  controller?: CustomDialogController
  // 若尝试在CustomDialog中传入多个其他的Controller，以实现在CustomDialog中打开另一个或另一些CustomDialog，那么此处需要将指向自己的controller放在所有controller的后面
  cancel: () => void = () => {
  }
  confirm: () => void = () => {
  }

  /** 连续创建模式（见类注释）；false = 改造前行为（确定后由自己 close） */
  keepOpen: boolean = false
  /** 连续创建模式下**创建成功后**输入框的 placeholder 文案 */
  @Prop doneHint: string = '创建成功，可继续输入创建'
  /**
   * 上一次「确定」是否**真的创建成功**（决定 placeholder 显示哪个文案）。
   *
   * ── 为什么走 AppStorage 而不是 `@Prop` / `@Link` ──────────────────────────
   * 调用方是在**方法里** `new CustomDialogController({ builder: addBookTypeDialog({...}) })`：
   *   · `@Prop` 是**创建瞬间快照**（SDK `custom_dialog_controller.d.ts:756` NOTE
   *     「Custom dialog box parameters **do not support dynamic updates**」）
   *     ⇒ 父级后来改 `manageCreateOk`，本组件收不到，placeholder 永远不变；
   *   · `@Link` 需要调用方在 builder 里写 `$xxx`，而 `$` 语法**只能用在组件构造上下文**，
   *     写在方法里会 `ReferenceError: $xxx is not defined`（工程 2026-09-22 真机踩过）。
   * ⇒ 用工程既有的**公共广播通道**：`@StorageLink` 直连 AppStorage，
   *   父级写、本组件读，天然响应式（与 `SHELF_SORT_TICK` / `BOOK_IS_BOOK_GROUPS_REFRESHING`
   *   同一套做法）。
   *
   * ⚠️ 为什么必须由调用方写、而不是本组件"点了确定就算成功"：
   *   空名 / 重名都会**不建组**（调用方只 toast 提示）。若本组件乐观地切到
   *   「创建成功，可继续输入创建」，用户会以为建好了、实际没建 ——
   *   正是用户最在意的"不清楚是否真正创建成功"。
   */
  @StorageLink(AddGroupChannel.KEY_OK) createSucceeded: boolean = false
  /** 输入框控制器（用于创建后把焦点留在输入框，方便直接输入下一个） */
  private inputCtrl: TextInputController = new TextInputController()

  @State BookTypeValueLength:number = 0
  // 主题颜色
  @StorageProp(ThemeStorageKey.THEME) theme: ThemeItem = {} as ThemeItem

  build() {
    Column() {
      Text(`新建分组` ).fontWeight(600).fontSize(20).margin({ top: 20, bottom: 10 })
      this.inputBookType()
      Row({space:24}) {
        Text('取消')
          .onClick(() => {
            Haptics.tap();
            // 连续创建模式下"取消"的语义就是"结束创建并关闭" ⇒ 交给调用方关
            // （子组件内 close() 不可靠，见类注释与 `RenameBookDialog` 的同类记录）
            if (this.keepOpen) {
              this.cancel()
              return
            }
            if (this.controller != undefined) {
              this.controller.close()
              this.cancel()
            }
          })
          .borderRadius(15)
          .padding({left:30,right:30,top:10,bottom:10})
          .fontColor(this.theme.mainColor)
          .backgroundColor(this.theme.secondColor)
        Text('确认')
          .onClick(() => {
            Haptics.tap();
            if (this.keepOpen) {
              // ── 顺序契约（改动前务必读）──────────────────────────────────────
              // ① **先** `this.confirm()`：调用方的 `createGroupKeepOpen()` 会在
              //    **同步段**第一行就读走 `this.bookType`（`const newName = this.bookType.trim()`）
              //    ⇒ 名字在这一刻已经被捕获，后面的清空不会影响它。
              // ② **再**清空输入框。若把这两步对调，调用方读到的是空串 ⇒ 每次都提示
              //    「分组名称不能为空」（这是本模式最容易写反的地方）。
              this.confirm()
              this.bookType = ''
              this.BookTypeValueLength = 0
              this.translateX = 0
              // ③ 焦点留在输入框 ⇒ 键盘不收起，可直接继续输入。
              //    ⚠️ 不要调 `stopEditing()`：那会收起键盘，用户还得再点一次输入框。
              this.inputCtrl.caretPosition(0)
              return
            }
            if (this.controller != undefined) {
              this.controller.close()
              this.confirm()
            }
          })
          .borderRadius(15)
          .padding({left:30,right:30,top:10,bottom:10})
          .fontColor(Color.White)
          .backgroundColor(this.theme.mainColor)
      }.padding({top:20,bottom:20})
    }.width('80%')
  }
  @State translateX: number = 0;
  @Builder inputBookType(){
    Row(){
      TextInput({
        placeholder: this.createSucceeded ? this.doneHint : '请输入分组名称',
        text: this.bookType,
        controller: this.inputCtrl
      }).height(40)
        .onChange((value: string) => {
          this.bookType = value
          this.BookTypeValueLength = value.length
          if (10 - this.BookTypeValueLength === 0) {
            // T13/D-17（Round 37）：全局 `animateTo` 是 @deprecated since 18，
            // SDK `component/common.d.ts` `@useinstead ohos.arkui.UIContext.UIContext#animateTo`；
            // 同一 UI 实例、同一参数 ⇒ 行为等价（无开关）。
            this.getUIContext().animateTo({
              duration: 200,
              // curve: curves.springCurve(100, 0, 50, 10),
              iterations: 4,
            },
              () => {
                // 抖动动偏移量
                this.translateX = 10;
              })
            this.translateX = 0;
          }
        })
        .translate({ x: this.translateX})
        .border({width:10 - this.BookTypeValueLength===0?0.5:0, color: Color.Red })
        .maxLength(10)
      if (10 - this.BookTypeValueLength !== 0){
      Row(){
          Text(JSON.stringify(10 - this.BookTypeValueLength)).fontSize(10).fontWeight(600).fontColor(10 - this.BookTypeValueLength ===0?Color.Red:'')
          Text('/').fontSize(10).fontWeight(600).fontColor(10 - this.BookTypeValueLength ===0?Color.Red:'')
          Text('10').fontSize(10).fontWeight(600).fontColor(10 - this.BookTypeValueLength ===0?Color.Red:'')
      }.offset({x:-40})
      } else {
        Text('清空').fontSize(12).fontWeight(500).fontColor(Color.Red).onClick(()=>{
          Haptics.tap(); this.bookType = ''
        }).offset({x:-40})
      }

    }
    .alignItems(VerticalAlign.Center)
  }
}