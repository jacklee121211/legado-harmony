import { SetHead } from '../../../../componets/myset/SetHead'
import UiMotion from '../../../../common/utils/UiMotion'
import { ShelfColors } from '../../../../common/utils/NightMode'

// ── 更新日志（2026-09-30 回填）──────────────────────────────────────────────
// 内容由用户提供（与 git 提交记录一致）：V2.0.0 全功能版本 15 条。
// 后续版本在此数组追加即可（新的版本对象放最前）。
interface VersionEntry {
  version: string
  date: string
  items: string[]
}

const LOGS: VersionEntry[] = [
  {
    version: 'V2.0.0 全功能版本', date: '',
    items: [
      'UI全面优化，引入鸿蒙7.0沉浸光感材质及特效，全新的动画机制',
      '完全精简的极致体验',
      '极致的功耗优化',
      '听书稳定性优化1',
      '新增自定义背景系统',
      '听书稳定性优化2',
      '新增材质背景以及混合模块',
      '优化自定义背景上线以及排布',
      '增加本地TTS方案',
      '阅读器-设置页个性化区块全面重做',
      '震动反馈全面重做，UI风格化完善',
      '上架前优化',
      '修复垫片构建阻塞主线程导致的冻结与断流',
      '增加付费模块',
      '书籍进入动画重做',
    ]
  },
]

@Component
export default struct VersionLogPage {
  @StorageLink('bottomRectHeight') bottomRectHeight: number = 0
  @StorageLink('topRectHeight') topRectHeight: number = 0

  build() {
    NavDestination() {
      Column() {
        Blank(this.topRectHeight)
        SetHead({ titleName: '更新日志' })
        Scroll() {
          Column({ space: 16 }) {
            ForEach(LOGS, (entry: VersionEntry) => {
              Column({ space: 10 }) {
                Row({ space: 8 }) {
                  Text(entry.version)
                    .fontSize(16).fontWeight(600)
                    .fontColor($r('app.color.text_primary'))
                  if (entry.date !== '') {
                    Text(entry.date).fontSize(12).opacity(0.45)
                  }
                }
                .width('100%')

                ForEach(entry.items, (item: string, idx: number) => {
                  Row({ space: 8 }) {
                    Text(`${idx + 1}.`)
                      .fontSize(14).opacity(0.45)
                    Text(item)
                      .fontSize(14)
                      .fontColor($r('app.color.text_primary'))
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
            })
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
