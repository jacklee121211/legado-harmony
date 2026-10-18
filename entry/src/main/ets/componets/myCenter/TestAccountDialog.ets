/**
 * 「测试账号登录 / 邀请码」弹窗（2026-09-28 新增，2026-10-12 增加邀请码入口）。
 *
 * ── 需求（用户）──────────────────────────────────────────────────────────
 * 三职能表单（账号 + 密码 + 确认），按输入分流：
 * ① 凭证 = 测试账号（huaweiceshi / huaweiceshi1234）→ 登录为测试账号
 *    （本地虚拟账号，昵称沿用「我的」页现有昵称体系）；
 * ② 凭证 = 彩蛋码（我爱李杰克 / 我爱小妖）→ **解锁不登录**：隐藏功能
 *    （Edge TTS / 标定模式 / 听书入口）恢复显示，语义与原「改名解锁」完全一致
 *    （ListenUnlock 标志位，卸载前一直有效）；成功后弹原版免责声明（页面侧）；
 * ③ 邀请码（账户行输入邀请码，密码留空）→ HMAC 验签 + 送 VIP
 *    （格式 LEGADO-XXXXXXXXXX，每个码限用一次，跨设备不可追查复用）；
 * ④ 其他 → 账号或密码不正确。
 *
 * 邀请码不在 UI 上单独提示 —— 知道的人自然会用。
 */
import { Haptics } from '../../common/utils/Haptics'
import { VipManager } from '../../common/utils/VipManager'
import { ListenUnlock } from '../../common/utils/ListenUnlock'
import { InviteCodeManager } from '../../common/utils/InviteCodeManager'

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

  /** 邀请码激活成功（页面侧 toast） */
  onInviteRedeemed: () => void = (): void => {}

  @State userInput: string = ''
  @State passInput: string = ''

  private mainColor(): string {
    return this.dark ? 'rgba(248, 249, 250, 1)' : 'rgba(19, 19, 19, 1.00)'
  }

  private subColor(): string {
    return this.dark ? 'rgba(248, 249, 250, 0.55)' : 'rgba(19, 19, 19, 0.55)'
  }

  /** 确认：先查彩蛋码 → 测试账号 → 邀请码（密码留空时），都不中报错 */
  private confirm(): void {
    Haptics.tap();
    const u = this.userInput.trim()
    const p = this.passInput
    if (u === VipManager.EGG_USER && p === VipManager.EGG_PASS) {
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
    // 邀请码：密码留空 + 账号不为空 → 同步白名单比对
    if (p === '' && u.length > 0) {
      const err = InviteCodeManager.redeem(u)
      if (err === '') {
        this.onInviteRedeemed()
        this.onClose()
      } else {
        this.getUIContext().getPromptAction().showToast({ message: err })
      }
      return
    }
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

      Text('账号密码登录 · 请妥善保管账号信息')
        .fontSize(10)
        .fontColor(this.subColor())
        .width('100%')
        .textAlign(TextAlign.Center)
    }
    .width('100%')
    .padding(20)
  }
}
