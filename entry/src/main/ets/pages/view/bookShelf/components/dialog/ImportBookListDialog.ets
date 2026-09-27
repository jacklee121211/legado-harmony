/**
 * 「导入书单」弹窗（2026-09-25 用户改版：从贴底 bindSheet 升级为标准居中弹窗）。
 *
 * ── 需求原文 ──────────────────────────────────────────────────────────────
 * 「管理-加入书单这个弹窗还是**老式贴底弹窗**呢，改一下，**统一一下**。
 *   里面的图标好像**还不是 symbol** 也没有我们现在用的**动画系统**。」
 * ⇒ ①居中弹窗框架（四圆角 20 + 90% 宽内缩 + 沉浸光感材质 + 弹簧出入场，
 *   与保存方案 / 睡眠定时同款）；②图标换 SymbolGlyph（符号名查自 SDK 符号表：
 *   `general_paste` 粘贴 / `folder` 本地，均核过存在）；③所有可点件带
 *   `Haptics.tap()` + `UiMotion.CLICK` 按压动效。
 *
 * ── 关闭约定（2026-09-25 全工程统一）──────────────────────────────────────
 * 关闭权在**页面侧**（真机日志定位过弹窗内 `controller?.close()` 偶发失灵，
 * 页面持有的 controller 从未失手）：本弹窗所有关闭路径都调 `onClose()` 回调，
 * `controller?.close()` 仅作双保险。
 */
import { ShelfColors } from '../../../../../common/utils/NightMode'
import { Haptics } from '../../../../../common/utils/Haptics'
import UiMotion from '../../../../../common/utils/UiMotion'

@CustomDialog
export struct ImportBookListDialog {
  controller?: CustomDialogController

  /** 粘贴导入（页面侧执行既有 `pasteBookImport` 流程） */
  onPaste: () => void = (): void => {}
  /** 本地导入（页面侧执行书单 JSON 文件选择 + 导入流程） */
  onLocal: () => void = (): void => {}
  /** 关闭（页面侧 close，见文件头说明） */
  onClose: () => void = (): void => {}

  /** 一个入口格：symbol 圆底 + 标签（视觉延续原 ImportClickBox 的圆底语言） */
  @Builder
  EntryBox(symbolName: Resource, label: string, onTap: () => void) {
    Column({ space: 8 }) {
      Column() {
        SymbolGlyph(symbolName)
          .fontSize(24)
          .fontColor([ShelfColors.icon()])
      }
      .width(48)
      .height(48)
      .borderRadius(24)
      .borderColor(ShelfColors.line())
      .backgroundColor(ShelfColors.chip())
      .borderWidth(1)
      .justifyContent(FlexAlign.Center)

      Text(label)
        .fontSize(12)
        .fontColor(ShelfColors.icon())
    }
    .padding({ top: 16, bottom: 12, left: 21, right: 21 })
    .clickEffect(UiMotion.CLICK)
    .onClick(() => {
      Haptics.tap();
      onTap()
      this.onClose()
      this.controller?.close()
    })
  }

  build() {
    Column({ space: 14 }) {
      Text('导入书单')
        .fontSize(16)
        .fontWeight(600)
        .fontColor(ShelfColors.icon())
        .width('100%')
        .textAlign(TextAlign.Center)

      Row({ space: 16 }) {
        // ⚠️ 符号名核名依据（2026-09-25 修正）：必须查 **ets-loader 的 sysResource.js 的
        //   symbol 段**（`sdk/default/openharmony/ets/build-tools/ets-loader/sysResource.js:3372-7415`，
        //   编译期 restool 用的就是它）。此前用预览器 resources.txt 核名会把 string 段的
        //   同名文案资源混进来 —— `general_paste` 就是字符串"粘贴"而非符号 ⇒ 编译报
        //   「Unknown resource name」。`text_clipboard`（剪贴板+文字）/ `folder` 均已在
        //   symbol 段核过。
        this.EntryBox($r('sys.symbol.text_clipboard'), '粘贴导入', (): void => {
          this.onPaste()
        })
        this.EntryBox($r('sys.symbol.folder'), '本地导入', (): void => {
          this.onLocal()
        })
      }
      .width('100%')
      .justifyContent(FlexAlign.Center)

      Button('取消')
        .fontSize(13)
        .fontColor(ShelfColors.icon())
        .backgroundColor(ShelfColors.chip())
        .borderRadius(18)
        .height(34)
        .padding({ left: 14, right: 14 })
        .clickEffect(UiMotion.CLICK)
        .onClick(() => {
          Haptics.tap();
          this.onClose()
          this.controller?.close()
        })
    }
    .width('100%')
    .padding(20)
  }
}
