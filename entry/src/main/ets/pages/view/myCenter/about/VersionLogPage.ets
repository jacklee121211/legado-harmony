import { SetHead } from '../../../../componets/myset/SetHead'
import UiMotion from '../../../../common/utils/UiMotion'
import { ShelfColors } from '../../../../common/utils/NightMode'
// ── 更新日志数据（2026-10-05 起**自动生成**）──────────────────────────────────
// ⚠️ 内容不再手写：由 `scripts/sync-version.ps1` 从 **git 提交备注**生成
//    （`.githooks/commit-msg` 钩子每次提交自动执行并 `git add` 进同一笔提交）。
//    规范：提交首行必须以版本号开头（如 `V2.0.2 封面圆角对齐`），
//    版本号与更新日志条目都从那里来；`AppScope/app.json5` 的
//    versionName/versionCode 也由同一次生成同步（见 `VersionLogData.ets` 头注释）。
//    同版本号的重复提交会合并条目，只保留最近 20 个版本。
import { VERSION_LOGS, VersionEntry } from './VersionLogData'

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
            ForEach(VERSION_LOGS, (entry: VersionEntry) => {
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
