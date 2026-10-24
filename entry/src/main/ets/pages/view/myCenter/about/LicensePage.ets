import { common } from '@kit.AbilityKit'
import { BusinessError } from '@kit.BasicServicesKit'
import { hilog } from '@kit.PerformanceAnalysisKit'
import { SetHead } from '../../../../componets/myset/SetHead'
import UiMotion from '../../../../common/utils/UiMotion'
import { Haptics } from '../../../../common/utils/Haptics'
import { ShelfColors } from '../../../../common/utils/NightMode'
import { ThemeStorageKey } from '../../../../common/constants/Theme'
import { ThemeItem } from '../../../../common/model/Theme'

// ── 开源许可（2026-10-06 按仓库元数据逐条复核；2026-10-25 更正 ColorTxt 条款 + 增加跳转）──
// 事实源：各依赖 `oh_modules` 内 oh-package.json5 的 **license 字段原文**，不是凭印象：
//   @ohos/axios 2.2.0        → "license": "MIT"
//   dayjs 1.11.7             → "license": "MIT"
//   @pura/harmony-utils 1.3.2→ "license":"Apache-2.0"   ⚠️ 旧版本页误写 MIT，已修
//   @ohos/hypium 1.0.17      → "license":"Apache-2.0"
//   @ohos/hamock 1.0.0       → Apache License, Version 2.0（LICENSE 文件原文）
//   @hmanimations/ezcustomtransition 1.3.0 → "license":"Apache-2.0"
//       （ohpm 官方 API：`/ohpmweb/registry/oh-package/openapi/v1/detail/@hmanimations%2Fezcustomtransition`）
// ⚠️ Apache-2.0 与 GPL-3.0 兼容，但要求保留其 NOTICE/许可证文本 ⇒ 见仓库根
//    `THIRD_PARTY_NOTICES.md`。后续新增三方库时，两处都要追加。
//
// ⚠️ 2026-10-25 更正（**请勿改回去**）：
//   旧文案写「ColorTxt → MPL-2.0（带 Exhibit B），无代码复制，仅思想借鉴」——**与事实不符**：
//   ① 实测 ColorTxt 全仓 665 个源文件**无一份**附加 Exhibit B ⇒ 不是 Incompatible With
//      Secondary Licenses（MPL-2.0 §1.5）；反而 GPL-3.0 属其 §1.12 定义的 Secondary
//      License，§3.3 允许双重授权；
//   ② `tts/PauseSplicer.ets` 确实含源自其 `src/shared/voiceReadPunctuationPauses.ts`
//      的代码（上游提交 47430f28，2026-09-08，早于本文件创建日 2026-09-18）。
//   ⇒ 现文案如实披露衍生关系，并给出上游仓库地址供接收方核对。
/** 项目地址（README/仓库远端核实）。**必须定义在 `LICENSES` 之前** —— `const` 不提升。 */
const PROJECT_URL: string = 'https://github.com/jacklee121211/legado-harmony'

interface LicenseEntry {
  name: string
  desc: string
  license: string
  /** 上游项目地址（有则整条可点击跳转；空串 = 不可点） */
  url: string
}

const LICENSES: LicenseEntry[] = [
  {
    name: '喵阅（本应用）',
    desc: '基于开源项目 Legado（开源阅读）HarmonyOS 移植版本重构打磨。上游致谢：gedoor/legado（安卓原版）、yongfengnice/legado-harmony（HarmonyOS 移植）。',
    license: 'GPL-3.0',
    url: PROJECT_URL,
  },
  {
    name: 'gedoor/legado（安卓原版上游）',
    desc: '本项目的最终上游。Legado 3.0 阅读，GPL-3.0。',
    license: 'GPL-3.0',
    url: 'https://github.com/gedoor/legado',
  },
  {
    name: 'yongfengnice/legado-harmony（鸿蒙移植上游）',
    desc: '本项目的直接上游基座（HarmonyOS 移植版），GPL-3.0。本仓库根提交即其原样快照。',
    license: 'GPL-3.0',
    url: 'https://github.com/yongfengnice/legado-harmony',
  },
  {
    name: 'ssnangua/ColorTxt（部分代码衍生）',
    desc: 'AI 阅读 / 多引擎 TTS 听书的架构思路借鉴了 ColorTxt 的设计（引擎分派、provider 注册表、说话人识别、配置方案等）。'
      + '此外，`tts/PauseSplicer.ets` 中标点停顿的段落收集与词级对齐逻辑，改写自其 `src/shared/voiceReadPunctuationPauses.ts`。'
      + '该部分按 MPL-2.0 授权，并依 MPL-2.0 §3.3 同时以 GPL-3.0 提供；其余听书实现为本项目自研。感谢 ColorTxt 作者。',
    license: 'MPL-2.0（与 GPL-3.0 双许可）',
    url: 'https://github.com/ssnangua/ColorTxt',
  },
  {
    name: '@hmanimations/ezcustomtransition',
    desc: '鸿蒙一镜到底转场库（v1.3.0）。本项目以受控 fork 方式引入 `common/ezlt/`：契约层（打断闸/手势返回/session 状态机）保留原样，仅改编排段。',
    license: 'Apache-2.0',
    url: 'https://ohpm.openharmony.cn/#/cn/detail/@hmanimations%2Fezcustomtransition',
  },
  {
    name: '@ohos/axios',
    desc: 'OpenHarmony 三方 HTTP 客户端库',
    license: 'MIT',
    url: 'https://gitcode.com/openharmony-sig/ohos_axios',
  },
  {
    name: 'dayjs',
    desc: '轻量日期时间处理库',
    license: 'MIT',
    url: 'https://github.com/iamkun/dayjs',
  },
  {
    name: '@pura/harmony-utils',
    desc: 'HarmonyOS 工具集（PreferencesUtil、ScanUtil 等）',
    license: 'Apache-2.0',
    url: 'https://gitee.com/tongyuyan/harmony-utils',
  },
  {
    name: '@ohos/hypium · @ohos/hamock',
    desc: '单元测试框架（仅开发/测试期使用，不进发行包）',
    license: 'Apache-2.0',
    url: 'https://gitee.com/openharmony/testfwk_arkxtest',
  },
  {
    // 系统 Kit 随 HarmonyOS 提供，无独立开源仓库地址 ⇒ url 留空，条目纯展示不可点
    name: 'HarmonyOS 系统服务',
    desc: 'ReaderKit（阅读服务）、Core Speech Kit（本地 TTS）、Core Vision、AVSession、Share Kit（分享/碰一碰）等系统 Kit',
    license: 'HarmonyOS 系统组件',
    url: '',
  },
]

/** 项目地址（README/仓库远端核实） */

/**
 * 版权与使用限制（2026-10-06 **按用户要求改写为完全开源**）。
 *
 * ⚠️ 改写原因（务必别再改回去）：旧版写的是
 *   · 「付费模块、服务端配置、品牌与运营资产为**专有部分**，不属于开源授权范围」
 *   · 「未经授权，不得…**用于商业用途**」
 * 这两条与 GPL-3.0 冲突：
 *   · GPL-3.0 前言原文 —— 许可「designed to make sure that you have the freedom …」
 *     并明确允许「charge for them if you wish」；§4 允许「convey verbatim copies … for a price」
 *     ⇒ **商业使用是 GPL 明文授予的权利**，加"不得商用"属于 §10 禁止的 further restrictions；
 *   · 付费模块源码（IapManager/VipManager/VipDialog）本就在本仓库内、与 GPL 代码同编一个 HAP
 *     ⇒ 对外称"专有"与事实不符。
 * 现在的口径：**代码整体（含付费模块）一律 GPL-3.0，任何人可自由使用、修改、再分发、商用**；
 * 只有「名称与图标」走商标主张 —— 那是商标法层面的事，不写成许可证附加条款。
 */
const RESTRICTIONS: string[] = [
  '本项目依 GPL-3.0 开源，**代码整体**（含会员/付费相关实现）均在授权范围内：任何人可自由使用、修改、再分发，也可用于商业用途，无需另行取得授权。',
  '本项目是基于上游开源项目持续修改而来，同样欢迎并鼓励继续 fork、魔改与再发布；再发布时保留 GPL-3.0 许可证与版权声明、并提供对应源码即可。',
  '「喵阅」名称与应用图标为项目标识，仅用于区分来源；他人再发布修改版时请使用自己的名称与图标，避免与官方发行版混淆。',
  '本项目按「现状」提供，不对可用性、稳定性与适用性作任何担保；因使用本软件产生的任何后果由使用者自行承担。',
]

@Component
export default struct LicensePage {
  @StorageLink('bottomRectHeight') bottomRectHeight: number = 0
  @StorageLink('topRectHeight') topRectHeight: number = 0
  /** 全局主题（2026-10-12：本页底色改为跟随主题渐变） */
  @StorageProp(ThemeStorageKey.THEME) theme: ThemeItem = {} as ThemeItem

  /**
   * 用**系统浏览器**打开上游项目地址（2026-10-25 新增，用户需求：许可条目可点击跳转）。
   *
   * ── 为什么用 `openLink` 而不是 App 内 Web ────────────────────────────────
   *  与工程内既有先例一致：`ContactPage.ets`（QQ 群外链）、
   *  `MySetPage.openQqGroupInBrowser`、`TtsControlPanel.openAiVoiceListUrl`
   *  全部走 `UIAbilityContext.openLink`。App 内嵌 Web 要额外处理加载态/返回/权限，
   *  成本与收益不匹配（同 TtsControlPanel 的结论）。
   *
   * ── SDK 依据 ─────────────────────────────────────────────────────────────
   *  `UIAbilityContext.openLink(link, options?, callback?): Promise<void>` `@since 12`
   *  （证据：`sdk\default\openharmony\ets\api\application\UIAbilityContext.d.ts:300`）；
   *  `OpenLinkOptions.appLinkingOnly` 默认 **false** ⇒ 无 App Linking 匹配时回落
   *  Deep Linking（证据：`@ohos.app.ability.OpenLinkOptions.d.ts` 注释
   *  "The default value is **false**"）⇒ https 链接会交给浏览器。
   *
   * ── 失败处理 ─────────────────────────────────────────────────────────────
   *  只 toast 提示、不抛 —— 它只是个可选入口。同时该 URL 文本本身带
   *  `.copyOption(CopyOptions.LocalDevice)`，用户可长按复制手动访问。
   */
  private openUrl(url: string): void {
    if (url.length === 0) {
      return
    }
    try {
      const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext
      ctx.openLink(url).catch((err: BusinessError) => {
        hilog.warn(0x0000, 'LicensePage', `openLink failed, code=${err.code}, url=${url}`)
        this.toast('打开失败，可长按链接复制')
      })
    } catch (err) {
      hilog.warn(0x0000, 'LicensePage', `openLink threw: ${JSON.stringify(err)}`)
      this.toast('打开失败，可长按链接复制')
    }
  }

  /** showToast 可能抛异常 ⇒ 按本页/AboutPage 既有写法包 try/catch */
  private toast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message })
    } catch (err) {
      // 提示失败不影响主流程
    }
  }

  build() {
    NavDestination() {
      Column() {
        Blank(this.topRectHeight)
        SetHead({ titleName: '开源许可' })
        Scroll() {
          Column({ space: 12 }) {
            ForEach(LICENSES, (entry: LicenseEntry) => {
              Column({ space: 6 }) {
                Column({ space: 4 }) {
                  Row({ space: 4 }) {
                    Text(entry.name)
                      .fontSize(15).fontWeight(600)
                      .fontColor($r('app.color.text_primary'))
                      .layoutWeight(1)
                    // 有上游地址才显示「前往」指示，避免给不可点的条目假承诺
                    if (entry.url.length > 0) {
                      SymbolGlyph($r('sys.symbol.chevron_forward'))
                        .fontSize(14)
                        .fontColor([$r('app.color.text_primary')])
                        .opacity(0.35)
                    }
                  }
                  .width('100%')
                  Text(entry.license)
                    .fontSize(12)
                    .fontColor('#0A84FF')
                    .width('100%')
                }
                .width('100%')

                Text(entry.desc)
                  .fontSize(13)
                  .opacity(0.6)
                  .width('100%')
                // 地址行：可点跳转 + 可长按复制（双保险，跳转失败仍能手动取用）
                if (entry.url.length > 0) {
                  Text(entry.url)
                    .fontSize(11)
                    .fontColor('#0A84FF')
                    .opacity(0.75)
                    .width('100%')
                    .copyOption(CopyOptions.LocalDevice)
                }
              }
              .width('100%')
              .padding(16)
              .backgroundColor($r('app.color.card_bg'))
              .borderRadius(10)
              .shadow({ radius: 12, color: 'rgba(0, 0, 0, 0.06)', offsetX: 0, offsetY: 4 })
              .alignItems(HorizontalAlign.Start)
              .clickEffect(entry.url.length > 0 ? UiMotion.CLICK : undefined)
              .onClick(() => {
                // 无地址的条目（如 HarmonyOS 系统服务）保持纯展示，不给点击反馈
                if (entry.url.length === 0) {
                  return
                }
                Haptics.tap()
                this.openUrl(entry.url)
              })
            })

            // ── 项目地址（2026-09-30 用户需求：许可页写上项目地址）────────────
            // 2026-10-25：整卡可点跳转（原先只有文本，用户反馈"点了没反应"）
            Column({ space: 8 }) {
              Row({ space: 4 }) {
                Text('项目地址')
                  .fontSize(15).fontWeight(600)
                  .fontColor($r('app.color.text_primary'))
                  .layoutWeight(1)
                SymbolGlyph($r('sys.symbol.chevron_forward'))
                  .fontSize(14)
                  .fontColor([$r('app.color.text_primary')])
                  .opacity(0.35)
              }
              .width('100%')
              Text(PROJECT_URL)
                .fontSize(13)
                .fontColor('#0A84FF')
                .width('100%')
                .copyOption(CopyOptions.LocalDevice)
              Text('欢迎 Star / Issue / PR；提交代码请遵循 GPL-3.0 同源开源。')
                .fontSize(12)
                .opacity(0.45)
                .width('100%')
            }
            .width('100%')
            .padding(16)
            .backgroundColor($r('app.color.card_bg'))
            .borderRadius(10)
            .shadow({ radius: 12, color: 'rgba(0, 0, 0, 0.06)', offsetX: 0, offsetY: 4 })
            .alignItems(HorizontalAlign.Start)
            .clickEffect(UiMotion.CLICK)
            .onClick(() => {
              Haptics.tap()
              this.openUrl(PROJECT_URL)
            })

            // ── 版权与使用限制（2026-09-30 商业化保护声明，用户需求）──────────
            Column({ space: 8 }) {
              Text('版权与使用限制')
                .fontSize(15).fontWeight(600)
                .fontColor($r('app.color.text_primary'))
                .width('100%')
              ForEach(RESTRICTIONS, (item: string, idx: number) => {
                Row({ space: 6 }) {
                  Text(`${idx + 1}.`)
                    .fontSize(13)
                    .opacity(0.45)
                  Text(item)
                    .fontSize(13)
                    .opacity(0.75)
                    .layoutWeight(1)
                }
                .width('100%')
                .alignItems(VerticalAlign.Top)
              })
            }
            .width('100%')
            .padding(16)
            .backgroundColor($r('app.color.card_bg'))
            .borderRadius(10)
            .shadow({ radius: 12, color: 'rgba(0, 0, 0, 0.06)', offsetX: 0, offsetY: 4 })
            .alignItems(HorizontalAlign.Start)

            Text('以上许可描述仅用于致谢与合规披露，具体以各项目官方仓库的许可证原文为准。')
              .fontSize(12)
              .opacity(0.45)
              .width('100%')
              .padding({ top: 8 })
          }
          .width('100%')
          .padding({ left: 20, right: 20, bottom: this.bottomRectHeight + 20 })
        }
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
      }
      .width('100%')
      .height('100%')
      // 2026-10-12 适配全局主题渐变（与书架/我的同款配色对与 stop）
      .linearGradient({
        direction: GradientDirection.Bottom,
        colors: ShelfColors.pageGradient(this.theme.mainColor, this.theme.secondColor)
      })
    }
    .hideTitleBar(true)
    .systemTransition(UiMotion.pageTransition(UiMotion.T_SETTING))
  }
}
