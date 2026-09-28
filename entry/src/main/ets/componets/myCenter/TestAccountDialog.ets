/**
 * 「测试账号登录」弹窗（2026-09-28 新增）。
 *
 * ── 需求（用户）──────────────────────────────────────────────────────────
 * 双职能表单（账号 + 密码 + 确认），按输入分流：
 * ① 凭证 = 测试账号（huaweiceshi / huaweiceshi1234）→ 登录为测试账号
 *    （本地虚拟账号，昵称沿用「我的」页现有昵称体系）；
 * ② 凭证 = 彩蛋码（我爱李杰克 / 我爱小妖）→ **解锁不登录**：隐藏功能
 *    （Edge TTS / 标定模式 / 听书入口）恢复显示，语义与原「改名解锁」完全一致
 *    （ListenUnlock 标志位，卸载前一直有效）；成功后弹原版免责声明（页面侧）；
 * ③ 其他 → 账号或密码不正确。
 *
 * 彩蛋不在 UI 上留任何提示（只为少部分人准备）。
 */
import { Haptics } from '../../common/utils/Haptics'
import { VipManager } from '../../common/utils/VipManager'
import { ListenUnlock } from '../../common/utils/ListenUnlock'

@CustomDialog
export struct TestAccountDialog {
  controller?: CustomDialogController

  /** 深色底（页面注入 nightOn） */
  @Prop dark: boolean = false

  onClose: () => void = (): void => {}

  /** 彩蛋解锁成功（页面侧弹原版「🎉 解锁成功」免责声明弹窗） */
  onUnlocked: () => void = (): void => {}

  /** 测试账号登录成功（页面侧 toast） */
  onLoginOk: () => void = (): void => {}

  @State userInput: string = ''
  @State passInput: string = ''

  private mainColor(): string {
    return this.dark ? 'rgba(248, 249, 250, 1)' : 'rgba(19, 19, 19, 1.00)'
  }

  private subColor(): string {
    return this.dark ? 'rgba(248, 249, 250, 0.55)' : 'rgba(19, 19, 19, 0.55)'
  }

  /** 确认：先查彩蛋码（解锁不登录），再查测试账号凭证，都不中报错 */
  private confirm(): void {
    Haptics.tap();
    const u = this.userInput.trim()
    const p = this.passInput
    if (u === VipManager.EGG_USER && p === VipManager.EGG_PASS) {
      // 与旧「改名解锁」同语义：已解锁时 tryUnlock 返回 false，不重复弹
      const newly = ListenUnlock.tryUnlock(VipManager.EGG_USER)
      if (newly) {
        this.onUnlocked()
      } else {
        this.getUIContext().getPromptAction().showToast({ message: '已解锁过，无需重复解锁' })
      }
      this.onClose()
      return
    }
    if (VipManager.loginTest(u, p)) {
      this.onLoginOk()
      this.onClose()
      return
    }
    this.getUIContext().getPromptAction().showToast({ message: '账号或密码不正确' })
  }

  build() {
    Column({ space: 14 }) {
      Row() {
        Text('测试账号登录')
          .fontSize(16)
          .fontWeight(600)
          .fontColor(this.mainColor())
        Blank()
        Text('关闭')
          .fontSize(15)
          .fontColor('#007DFF')
          .onClick(() => {
            Haptics.tap();
            this.onClose()
          })
      }
      .width('100%')

      TextInput({ placeholder: '账号' })
        .height(42)
        .fontSize(14)
        .maxLength(20)
        .onChange((v: string) => {
          this.userInput = v
        })

      TextInput({ placeholder: '密码' })
        .height(42)
        .fontSize(14)
        .maxLength(32)
        .type(InputType.Password)
        .onChange((v: string) => {
          this.passInput = v
        })

      Button('确认')
        .fontSize(15)
        .fontWeight(600)
        .fontColor(Color.White)
        .backgroundColor('#ff6600')
        .borderRadius(21)
        .height(42)
        .width('100%')
        .onClick(() => {
          this.confirm()
        })

      Text('仅限内部测试使用')
        .fontSize(10)
        .fontColor(this.subColor())
        .width('100%')
        .textAlign(TextAlign.Center)
    }
    .width('100%')
    .padding(20)
  }
}
