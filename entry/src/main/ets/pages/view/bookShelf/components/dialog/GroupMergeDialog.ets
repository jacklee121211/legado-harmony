import { ThemeStorageKey } from '../../../../../common/constants/Theme'
import { ThemeItem } from '../../../../../common/model/Theme'
import { Haptics } from '../../../../../common/utils/Haptics'

/** 冲突判定结果（2026-11-01）：一条 = 一本会被移动的书与目标分组里的某本重复 */
export interface MergeConflictInfo {
  bookId: number
  bookName: string
  detail: string
  oldId: number
  oldName: string
  oldDetail: string
}

/**
 * 合并冲突弹窗（2026-11-01）。
 *
 * 触发场景：解散子分组 / 移动分组时，组内书要并入目标分组，而目标里已有"同一本书"。
 * 判定口径（用户拍板）：**书名+作者 相同** 或 **文件大小+入库时间 相同**，任一命中。
 * 每条可单独选「覆盖 / 重命名 / 跳过」，也可一键批量；`choices` 下标与 `conflicts` 对齐：
 *   0 = 覆盖（删旧书：记录+文件+书签+进度，保留新书）
 *   1 = 重命名（新书书名加 ` (2)` 后并入）
 *   2 = 跳过（新书不并入，落「未分组」）
 */
@CustomDialog
export default struct GroupMergeDialog {
  controller?: CustomDialogController
  conflicts: MergeConflictInfo[] = []
  @State choices: number[] = []
  onConfirm: (choices: number[]) => void = () => {
  }
  onClose: () => void = () => {
  }
  @StorageProp(ThemeStorageKey.THEME) theme: ThemeItem = {} as ThemeItem

  aboutToAppear(): void {
    const arr: number[] = []
    for (let i = 0; i < this.conflicts.length; i++) {
      arr.push(0)
    }
    this.choices = arr
  }

  private pick(idx: number, v: number): void {
    Haptics.tap()
    this.choices[idx] = v
    this.choices = this.choices.slice()
  }

  private pickAll(v: number): void {
    Haptics.tap()
    const arr: number[] = []
    for (let i = 0; i < this.conflicts.length; i++) {
      arr.push(v)
    }
    this.choices = arr
  }

  build() {
    Column({ space: 10 }) {
      Text('发现重复书籍').fontSize(16).fontWeight(700)
      Text(`共 ${this.conflicts.length} 本与目标位置的书重复，请选择处理方式`)
        .fontSize(12)
        .fontColor('rgba(128,128,128,0.95)')

      Scroll() {
        Column({ space: 8 }) {
          ForEach(this.conflicts, (c: MergeConflictInfo, idx: number) => {
            Column({ space: 3 }) {
              Text(c.bookName).fontSize(14).fontWeight(600).maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
              Text(`新：${c.detail}`).fontSize(11).fontColor('rgba(128,128,128,0.95)')
              Text(`旧：${c.oldName} · ${c.oldDetail}`).fontSize(11).maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .fontColor('rgba(128,128,128,0.95)')
              Row({ space: 6 }) {
                Text(this.choiceText(0)).fontSize(12)
                  .fontColor(this.choices[idx] === 0 ? Color.White : this.theme.mainColor)
                  .backgroundColor(this.choices[idx] === 0 ? this.theme.mainColor : this.theme.secondColor)
                  .padding({ left: 10, right: 10, top: 4, bottom: 4 }).borderRadius(10)
                  .onClick(() => { this.pick(idx, 0) })
                Text(this.choiceText(1)).fontSize(12)
                  .fontColor(this.choices[idx] === 1 ? Color.White : this.theme.mainColor)
                  .backgroundColor(this.choices[idx] === 1 ? this.theme.mainColor : this.theme.secondColor)
                  .padding({ left: 10, right: 10, top: 4, bottom: 4 }).borderRadius(10)
                  .onClick(() => { this.pick(idx, 1) })
                Text(this.choiceText(2)).fontSize(12)
                  .fontColor(this.choices[idx] === 2 ? Color.White : this.theme.mainColor)
                  .backgroundColor(this.choices[idx] === 2 ? this.theme.mainColor : this.theme.secondColor)
                  .padding({ left: 10, right: 10, top: 4, bottom: 4 }).borderRadius(10)
                  .onClick(() => { this.pick(idx, 2) })
              }
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
            .padding(8)
            .borderRadius(10)
            .backgroundColor('rgba(0,0,0,0.03)')
          }, (c: MergeConflictInfo) => 'm' + c.bookId)
        }
        .width('100%')
      }
      .width('100%')
      .height(220)
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })

      Row({ space: 8 }) {
        Text('全部覆盖').fontSize(12).fontColor(this.theme.mainColor)
          .padding({ left: 10, right: 10, top: 5, bottom: 5 }).borderRadius(10)
          .backgroundColor(this.theme.secondColor)
          .onClick(() => { this.pickAll(0) })
        Text('全部重命名').fontSize(12).fontColor(this.theme.mainColor)
          .padding({ left: 10, right: 10, top: 5, bottom: 5 }).borderRadius(10)
          .backgroundColor(this.theme.secondColor)
          .onClick(() => { this.pickAll(1) })
        Text('全部跳过').fontSize(12).fontColor(this.theme.mainColor)
          .padding({ left: 10, right: 10, top: 5, bottom: 5 }).borderRadius(10)
          .backgroundColor(this.theme.secondColor)
          .onClick(() => { this.pickAll(2) })
      }

      Row({ space: 24 }) {
        Text('取消').fontSize(15).fontColor(this.theme.mainColor)
          .onClick(() => { Haptics.tap(); this.onClose() })
        Text('确定').fontSize(15).fontColor(Color.White)
          .backgroundColor(this.theme.mainColor)
          .padding({ left: 24, right: 24, top: 8, bottom: 8 })
          .borderRadius(15)
          .onClick(() => { Haptics.tap(); this.onConfirm(this.choices) })
      }
      .margin({ top: 6 })
    }
    .width('100%')
    .padding(16)
  }

  private choiceText(v: number): string {
    if (v === 0) {
      return '覆盖'
    }
    if (v === 1) {
      return '重命名'
    }
    return '跳过'
  }
}
