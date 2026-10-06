import { SetHead } from '../../../../componets/myset/SetHead'
import UiMotion from '../../../../common/utils/UiMotion'
import { ShelfColors } from '../../../../common/utils/NightMode'

// ── 开源许可（2026-10-06 按仓库元数据逐条复核）────────────────────────────
// 事实源：各依赖 `oh_modules` 内 oh-package.json5 的 **license 字段原文**，不是凭印象：
//   @ohos/axios 2.2.0        → "license": "MIT"
//   dayjs 1.11.7             → "license": "MIT"
//   @pura/harmony-utils 1.3.2→ "license":"Apache-2.0"   ⚠️ 旧版本页误写 MIT，已修
//   @ohos/hypium 1.0.17      → "license":"Apache-2.0"
//   @ohos/hamock 1.0.0       → Apache License, Version 2.0（LICENSE 文件原文）
// ⚠️ Apache-2.0 与 GPL-3.0 兼容，但要求保留其 NOTICE/许可证文本 ⇒ 见仓库根
//    `THIRD_PARTY_NOTICES.md`。后续新增三方库时，两处都要追加。
interface LicenseEntry {
  name: string
  desc: string
  license: string
}

const LICENSES: LicenseEntry[] = [
  {
    name: '喵阅（本应用）',
    desc: '基于开源项目 Legado（开源阅读）HarmonyOS 移植版本重构打磨。上游致谢：gedoor/legado（安卓原版）、yongfengnice/legado-harmony（HarmonyOS 移植）',
    license: 'GPL-3.0',
  },
  {
    name: '@ohos/axios',
    desc: 'OpenHarmony 三方 HTTP 客户端库',
    license: 'MIT',
  },
  {
    name: 'dayjs',
    desc: '轻量日期时间处理库',
    license: 'MIT',
  },
  {
    name: '@pura/harmony-utils',
    desc: 'HarmonyOS 工具集（PreferencesUtil、ScanUtil 等）',
    license: 'Apache-2.0',
  },
  {
    name: '@ohos/hypium · @ohos/hamock',
    desc: '单元测试框架（仅开发/测试期使用，不进发行包）',
    license: 'Apache-2.0',
  },
  {
    name: 'HarmonyOS 系统服务',
    desc: 'ReaderKit（阅读服务）、Core Speech Kit（本地 TTS）、Core Vision、AVSession、Share Kit（分享/碰一碰）等系统 Kit',
    license: 'HarmonyOS 系统组件',
  },
]

/** 项目地址（README/仓库远端核实） */
const PROJECT_URL: string = 'https://github.com/jacklee121211/legado-harmony'

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

  build() {
    NavDestination() {
      Column() {
        Blank(this.topRectHeight)
        SetHead({ titleName: '开源许可' })
        Scroll() {
          Column({ space: 12 }) {
            ForEach(LICENSES, (entry: LicenseEntry) => {
              Column({ space: 6 }) {
                Row({ space: 8 }) {
                  Text(entry.name)
                    .fontSize(15).fontWeight(600)
                    .fontColor($r('app.color.text_primary'))
                  Blank(8)
                  Text(entry.license)
                    .fontSize(12)
                    .fontColor('#0A84FF')
                }
                .width('100%')

                Text(entry.desc)
                  .fontSize(13)
                  .opacity(0.6)
                  .width('100%')
              }
              .width('100%')
              .padding(16)
              .backgroundColor($r('app.color.card_bg'))
              .borderRadius(10)
              .shadow({ radius: 12, color: 'rgba(0, 0, 0, 0.06)', offsetX: 0, offsetY: 4 })
              .alignItems(HorizontalAlign.Start)
            })

            // ── 项目地址（2026-09-30 用户需求：许可页写上项目地址）────────────
            Column({ space: 8 }) {
              Text('项目地址')
                .fontSize(15).fontWeight(600)
                .fontColor($r('app.color.text_primary'))
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
      .backgroundColor(ShelfColors.pageBg())
    }
    .hideTitleBar(true)
    .systemTransition(UiMotion.pageTransition(UiMotion.T_SETTING))
  }
}
