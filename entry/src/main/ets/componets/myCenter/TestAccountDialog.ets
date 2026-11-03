/**
 * 「测试账号登录」弹窗（2026-09-28 新增；2026-11-03 移除邀请码职能）。
 *
 * ── 需求（用户）──────────────────────────────────────────────────────────
 * 三职能表单（账号 + 密码 + 确认），按输入分流：
 * ① 凭证 = 测试账号（huaweiceshi / huaweiceshi1234）→ 登录为测试账号
 *    （本地虚拟账号，昵称沿用「我的」页现有昵称体系）；
 * ② 凭证 = 彩蛋码（我爱李杰克 / 我爱李佳琦，密码 woaixiaoyao）→ **解锁不登录**：隐藏功能
 *    （Edge TTS / 标定模式 / 听书入口）恢复显示，语义与原「改名解锁」完全一致
 *    （ListenUnlock 标志位，卸载前一直有效）；成功后弹原版免责声明（页面侧）；
 * ③ 其他 → 账号或密码不正确。
 *
 * ⚠️ 2026-11-03（L5）：**邀请码职能已整体移除**（用户拍板"邀请码不要了"），
 *    只保留两个账号：`huaweiceshi`（VIP 测试）与彩蛋账号（后门）。
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

  /** 确认：先查彩蛋码 → 测试账号，都不中报错（邀请码职能已于 2026-11-03 移除） */
  private confirm(): void {
    Haptics.tap();
    const u = this.userInput.trim()
    const p = this.passInput
    if (VipManager.isEgg(u, p)) {
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
    // 邀请码职能已于 2026-11-03 移除（用户拍板），此处不再有第三条分支
    this.getUIContext().getPromptAction().showToast({ message: '账号或密码不正确' })
  }

  build() {
    Column({ space: 14 }) {
      Row() {
        Text('登录')
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

      Button('登录')
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

      Text('仅供内部测试功能使用，用户无需登录')
        .fontSize(10)
        .fontColor(this.subColor())
        .width('100%')
        .textAlign(TextAlign.Center)
    }
    .width('100%')
    .padding(20)
  }
}
