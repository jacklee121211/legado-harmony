/**
 * 「VIP 购买」弹窗（2026-09-28 新增）。
 *
 * ── 需求（用户）──────────────────────────────────────────────────────────
 * · 统一材质弹窗（与更多材质/字体管理同款配方），介绍 VIP 特有功能 + 9.9 永久；
 * · 免费用户点锁定功能（导入/下载字体、更多材质、更多方案、自定义颜色）
 *   直接弹本窗；未登录**不强制先登录**——开通跟系统华为账号走（IAP 收银台内置）。
 * · 文案要求：说清楚解锁了什么能力（见下方特权清单）。
 *
 * ── 阶段边界 ─────────────────────────────────────────────────────────────
 * 阶段1（本文件）：UI + 状态展示；「立即开通」暂为占位提示。
 * 阶段2：接 IAP（queryEnvironmentStatus → queryProducts → createPurchase →
 *   queryPurchases 恢复），商品 miaoyue_vip_permanent（非消耗型，9.9 永久）。
 */
import { common } from '@kit.AbilityKit';
import { Haptics } from '../../common/utils/Haptics'
import UiMotion from '../../common/utils/UiMotion'
import { IapManager } from '../../common/utils/IapManager'
import { VipManager } from '../../common/utils/VipManager'
import { READER_PANEL_NIGHT_BG, READER_PANEL_DAY_BG } from '../../common/utils/ImmersiveMaterialUtil'

/**
 * 内容层底色 —— **只给阅读器宿主**用（2026-11-02）。
 *
 * 为什么用 `AttributeModifier` 而不是三元 `backgroundColor(...)`：
 * 本组件是**共享**的（阅读器 / 我的页 / 书架 / 字体管理 都在用）。那些宿主的老行为是
 * 「内容层**不设**背景，敞开让弹窗层（`CustomDialogControllerOptions.systemMaterial` 沉浸光感）
 * 去画」。一旦这里无条件写上 `backgroundColor`，那些宿主就会被这层实底盖住材质
 * ⇒ 必须留一个"什么都不做"的分支。
 *
 * 阅读器宿主（`readerPanel = true`）要的恰恰相反：底色必须**显式**、
 * 且由**阅读器自己的**亮暗决定 —— 沉浸光感是系统按**整机**模式渲染的，
 * 「系统暗 + 阅读器亮」时会把弹窗带成暗色（用户看到黑底黑字）。
 * 色值取**顶栏同款**（`ImmersiveMaterialUtil.READER_PANEL_*`），不自创。
 */
class VipPanelBg implements AttributeModifier<ColumnAttribute> {
  private readonly readerPanel: boolean;
  private readonly dark: boolean;

  constructor(readerPanel: boolean, dark: boolean) {
    this.readerPanel = readerPanel;
    this.dark = dark;
  }

  applyNormalAttribute(instance: ColumnAttribute): void {
    if (!this.readerPanel) {
      // 非阅读器宿主：保持原行为（不设背景，让弹窗层的材质透出来）
      return;
    }
    instance.backgroundColor(this.dark ? READER_PANEL_NIGHT_BG : READER_PANEL_DAY_BG);
    // 弹窗层的圆角是 options 里的 20；内容层自己画底必须**同值 + 裁切**，
    // 否则直角会把弹窗的圆角顶掉（工程里目录/书签/听书面板都是这个写法）。
    // 证据：`clip(value: boolean): T;`（`component/common.d.ts:21161`）、
    //      `borderRadius(value: Length | BorderRadiuses): T;`（同文件 `:18250`）。
    instance.borderRadius(20);
    instance.clip(true);
  }
}

@CustomDialog
export struct VipDialog {
  controller?: CustomDialogController

  /** 深色底（页面注入：我的页 = nightOn；阅读页 = colorMode == 0） */
  @Prop dark: boolean = false

  /** 已开通（页面注入当前值；controller 每次新建 ⇒ 打开时即最新） */
  @Prop vipOwned: boolean = false

  /** 购买进行中（收银台已拉起/结算中，防重复点击） */
  @State buying: boolean = false

  /** 关闭回调：关闭权在页面（与更多方案同款协调方式） */
  onClose: () => void = (): void => {}

  /**
   * 阅读器宿主（2026-11-02 新增）：**true 时由本组件自己画"顶栏同款"显式底色**。
   * 默认 `false` ⇒ 保持书架 / 我的 / 字体管理那些宿主的老行为（底色仍由弹窗层的
   * `systemMaterial` 提供，一行都不变）。见 `VipPanelBg` 的注释。
   */
  @Prop readerPanel: boolean = false

  /** 内容层底色修饰器（`readerPanel` 为 false 时**什么都不做**） */
  private panelBg: AttributeModifier<ColumnAttribute> = new VipPanelBg(false, false)

  aboutToAppear(): void {
    this.panelBg = new VipPanelBg(this.readerPanel, this.dark)
  }

  /** VIP 特权清单（用户要求"说清楚解锁了什么能力"；2026-10-01 新增自定义主题
   *  ；2026-10-07 新增防窥保护） */
  private perks: string[] = [
    '导入字体文件 —— 用自己的字体阅读',
    '下载字体文件 —— 在线字体库一键获取',
    '更多材质 —— 解锁全部背景材质',
    '更多方案 —— 解锁完整背景方案库',
    '自定义颜色 —— 阅读字色/背景随心配',
    '自定义主题 —— 书架主题取色器+RGB 自由配',
    '防窥保护 —— 防截屏录屏 + 后台模糊 + 非机主注视遮屏（两层独立开关）',
  ]

  /** 主文字色（随深浅切换，与阅读弹窗同一套三元） */
  private mainColor(): string {
    return this.dark ? 'rgba(248, 249, 250, 1)' : 'rgba(19, 19, 19, 1.00)'
  }

  private subColor(): string {
    return this.dark ? 'rgba(248, 249, 250, 0.55)' : 'rgba(19, 19, 19, 0.55)'
  }

  /** 立即开通：走 IAP（阶段2 已接）。'' = 用户取消收银台，不提示 */
  private buy(): void {
    if (this.buying) {
      return
    }
    Haptics.tap();
    this.buying = true
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext
    IapManager.buy(ctx).then((msg: string) => {
      this.buying = false
      if (msg.length > 0) {
        this.getUIContext().getPromptAction().showToast({
          message: msg
        })
      }
      if (VipManager.isVip()) {
        this.vipOwned = true
        this.onClose()
      }
    }).catch(() => {
      this.buying = false
    })
  }

  build() {
    Column({ space: 14 }) {
      // 顶栏：标题 + 关闭
      Row() {
        Text('喵阅 · 永久会员')
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

      // 特权清单
      Column({ space: 8 }) {
        ForEach(this.perks, (p: string) => {
          Row({ space: 8 }) {
            // 2026-10-01（用户）：文本 √ 换 symbol（sys.symbol.checkmark，
            // SDK 符号表 resources.txt:3759 核实），与全工程图标规范一致
            SymbolGlyph($r('sys.symbol.checkmark'))
              .fontSize(15)
              .fontColor(['#ff6600'])
            Text(p)
              .fontSize(13)
              .fontColor(this.mainColor())
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)
        }, (p: string): string => p)
      }
      .width('100%')
      .padding(14)
      .borderRadius(12)
      .backgroundColor(this.dark ? 'rgba(248, 249, 250, 0.08)' : 'rgba(19, 19, 19, 0.05)')

      // 价格
      Row() {
        Text('¥9.9')
          .fontSize(28)
          .fontWeight(700)
          .fontColor('#ff6600')
        Text('  一次买断 · 永久有效')
          .fontSize(12)
          .fontColor(this.subColor())
      }
      .width('100%')
      .justifyContent(FlexAlign.Center)

      // 开通按钮
      Button(this.vipOwned ? '已开通' : (this.buying ? '正在拉起收银台…' : '立即开通'))
        .fontSize(15)
        .fontWeight(600)
        .fontColor(Color.White)
        .backgroundColor(this.vipOwned ? 'rgba(120, 120, 120, 0.6)' : '#ff6600')
        .borderRadius(22)
        .height(42)
        .width('100%')
        .enabled(!this.buying && !this.vipOwned)
        .clickEffect(UiMotion.CLICK)
        .onClick(() => {
          this.buy()
        })

      // 小字说明
      Text('绑定华为账号，更换设备后登录同一账号自动恢复\n支付由华为应用内支付服务提供')
        .fontSize(10)
        .fontColor(this.subColor())
        .textAlign(TextAlign.Center)
        .width('100%')
    }
    .width('100%')
    .padding(20)
    // 底色：阅读器宿主才画（顶栏同款显式色）；其它宿主保持"让弹窗层画"（见 `VipPanelBg`）
    .attributeModifier(this.panelBg)
  }
}
