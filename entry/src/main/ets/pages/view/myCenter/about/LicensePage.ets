import { SetHead } from '../../../../componets/myset/SetHead'
import UiMotion from '../../../../common/utils/UiMotion'
import { ShelfColors } from '../../../../common/utils/NightMode'

// ── 开源许可（2026-09-30 按项目实际情况重写）────────────────────────────────
// 事实源：根/entry oh-package.json5 依赖 + 基座 LICENSE（GPL-3.0，Legado 衍生）。
// 条目与实际使用一一对应；后续新增三方库时在此追加。
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
    license: 'MIT',
  },
  {
    name: 'HarmonyOS 系统服务',
    desc: 'ReaderKit（阅读服务）、Core Speech Kit（本地 TTS）、Core Vision、AVSession、Share Kit（分享/碰一碰）等系统 Kit',
    license: 'HarmonyOS 系统组件',
  },
]

/** 项目地址（README/仓库远端核实） */
const PROJECT_URL: string = 'https://github.com/jacklee121211/legado-harmony'

/** 版权与使用限制（2026-09-30 商业化保护声明，用户需求） */
const RESTRICTIONS: string[] = [
  '本应用基于 GPL-3.0 开源，欢迎用户自行修改、编译与学习交流；修改版同样须遵循 GPL-3.0 开源。',
  '「喵阅」商店版的增值内容（付费模块、服务端配置、品牌与运营资产）为专有部分，不属于开源授权范围。',
  '未经授权，不得将本应用或其修改版本以「喵阅」名义上架任何应用商店，或用于商业用途。',
  '「喵阅」名称与品牌受保护；发现冒名上架，可通过应用市场侵权投诉渠道举报下架。',
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
