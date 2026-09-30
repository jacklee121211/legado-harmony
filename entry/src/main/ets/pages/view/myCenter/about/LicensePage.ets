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
    desc: '基于开源项目 Legado（开源阅读）HarmonyOS 移植版本重构打磨',
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
    desc: 'ReaderKit（阅读服务）、Core Speech Kit（本地 TTS）、Core Vision、AVSession 等系统 Kit',
    license: 'HarmonyOS 系统组件',
  },
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
