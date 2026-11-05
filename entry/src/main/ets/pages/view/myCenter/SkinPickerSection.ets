/**
 * 主题页 ·「阅读皮肤」选择区（2026-11-06，主题皮肤系统 UI 层）。
 *
 * 设计口径（规范 docs/主题皮肤系统-设计规范与交接-2026-11-06.md §7）：
 * · 挂在主题页签 GlassSegment 之下、主题色板网格之上（固定区段，不进网格、不改动主题 Grid）；
 * · 卡片横排（横向 Scroll），与主题色板瓦片同构（色块 + 名称 + 「使用中」角标）；
 * · 点选即生效（非破坏性操作，不需确认弹窗）：写皮肤包 id（AppStorage `readerSkinPackId`，
 *   PersistentStorage 持久）+ 同步总开关 `SET_READER_SKIN_ON`（Preferences，与设置页暗门组同一键）；
 * · 「默认外观」= id 清空 + 总开关关（= 改动前外观，一键回退）；
 * · 阅读页进场读一次（ReaderPage3.resolveSkinSlots），本区改完退出主题页进书即生效。
 * 弹窗/按钮全部按 `docs/标准-弹窗与按钮统一规范.md`：SymbolGlyph + Haptics.tap()、
 * @CustomDialog + DialogHost 唯一出口 + 材质四件套（customStyle:false / cornerRadius /
 * sheetMaterial / SPRING_FAST）。
 */
import { Haptics } from '../../../common/utils/Haptics';
import MySetConstants from '../../../common/constants/MySetConstants';
import { SkinPack } from '../../../common/theme/SkinCore';
import { SkinStore } from '../../../common/theme/SkinStore';
import ImmersiveMaterialUtil from '../../../common/utils/ImmersiveMaterialUtil';
import UiMotion from '../../../common/utils/UiMotion';
import { PreferencesUtil } from '@pura/harmony-utils';
import { DialogHost } from '../../../common/dialog/DialogHost';

/** 「阅读皮肤说明」弹窗（@CustomDialog；材质四件套由打开方 DialogHost 统一套） */
@CustomDialog
struct SkinInfoDialog {
  controller?: CustomDialogController
  onClose: () => void = (): void => {}

  build() {
    Column({ space: 14 }) {
      Text('阅读皮肤是什么？')
        .fontSize(18)
        .fontWeight(FontWeight.Bold)

      Text('它只换阅读页的"外观层"：上下留白带、正文区边框、信息窗底板。'
        + '正文排版、字体、翻页方式完全不受影响。')
        .fontSize(14)
        .lineHeight(22)

      Text('· 选择任意皮肤包即自动打开总开关；\n'
        + '· 选「默认外观」= 恢复改动前样子（一键回退）；\n'
        + '· 总开关也在 我的-设置-听书引擎（进阶） 里，两边是同一个开关。')
        .fontSize(13)
        .lineHeight(21)
        .alignSelf(ItemAlign.Start)

      Button('知道了')
        .fontSize(14)
        .width('100%')
        .height(40)
        .onClick(() => {
          Haptics.tap();
          this.controller?.close();
          this.onClose();
        })
    }
    .padding(20)
    .width('100%')
    .alignItems(HorizontalAlign.Center)
  }
}

@Component
export struct SkinPickerSection {
  /** 当前皮肤包 id（PersistentStorage 持久键，SkinStore.init 已 persistProp ⇒ 这里天然响应式） */
  @StorageProp('readerSkinPackId') skinId: string = ''
  /** 预览色块宽高比 / 最小高度：与主题色板瓦片同构（MyThemeConfigComp.TILE_ASPECT 同值口径） */
  private static readonly TILE_ASPECT: number = 167 / 77
  private static readonly TILE_MIN_H: number = 77

  /** 全部可选包（内置 code 兜底包 + rawfile 图片包），列表由 SkinStore 单源提供 */
  private packs(): SkinPack[] {
    return SkinStore.listPacks();
  }

  /** 应用一个皮肤包（点选即生效）：写 id + 同步总开关 + 轻提示 */
  private applyPack(id: string): void {
    Haptics.tap();
    SkinStore.setActivePackId(id);
    // 总开关与设置页暗门组是同一个 Preferences 键：选包=开，默认外观=关
    PreferencesUtil.putSync(MySetConstants.SET_READER_SKIN_ON, id !== '');
    const tip: string = id === '' ? '已恢复默认外观'
      : '已应用「' + this.packName(id) + '」，进阅读页生效';
    this.getUIContext().getPromptAction().showToast({ message: tip });
  }

  private packName(id: string): string {
    if (id === '') {
      return '默认外观';
    }
    const packs: SkinPack[] = SkinStore.listPacks();
    for (let i = 0; i < packs.length; i++) {
      if (packs[i].id === id) {
        return packs[i].name;
      }
    }
    return id;
  }

  private openInfo(): void {
    Haptics.tap();
    DialogHost.open(new CustomDialogController({
      builder: SkinInfoDialog({
        onClose: (): void => {
          DialogHost.closeCurrent()
        }
      }),
      autoCancel: true,
      alignment: DialogAlignment.Center,
      width: '88%',
      cornerRadius: 20,
      customStyle: false,
      systemMaterial: ImmersiveMaterialUtil.sheetMaterial(),
      openAnimation: UiMotion.motionParam(UiMotion.SPRING_FAST),
      closeAnimation: UiMotion.motionParam(UiMotion.SPRING_FAST),
      cancel: (): void => {
        DialogHost.closeCurrent()
      }
    }))
  }

  /** 单张皮肤卡（与主题色板瓦片同构：色块 + 名称 + 使用中角标） */
  @Builder
  packCard(id: string, name: string, previewColor: string) {
    Column({ space: 8 }) {
      Column() {
        if (this.skinId === id) {
          Text('使用中')
            .fontSize(9)
            .fontColor('#fff')
            .backgroundColor('#ef4444')
            .textAlign(TextAlign.Center)
            .lineHeight(14)
            .width(39)
            .height(14)
            .borderRadius({
              topRight: 8,
              bottomLeft: 8
            })
            .position({ right: 0, top: 0 })
        }
      }
      .width('100%')
      .aspectRatio(SkinPickerSection.TILE_ASPECT)
      .constraintSize({ minHeight: SkinPickerSection.TILE_MIN_H })
      .borderRadius(8)
      .backgroundColor(previewColor)
      .border({
        width: this.skinId === id ? 2 : 1,
        color: this.skinId === id ? 'rgba(0,0,0,0.45)' : 'rgba(0,0,0,0.15)'
      })

      Text(name)
        .fontSize(14)
        .height(22)
        .lineHeight(22)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
    }
    .width(132)
    .onClick(() => {
      this.applyPack(id)
    })
  }

  build() {
    Column({ space: 10 }) {
      // ── 标题行：阅读皮肤 + 说明入口 ──────────────────────────────────────────
      Row() {
        Text('阅读皮肤')
          .fontSize(16)
          .fontWeight(FontWeight.Bold)
        Blank()
        SymbolGlyph($r('sys.symbol.info_circle'))
          .fontSize(20)
          .fontColor(['rgba(0,0,0,0.45)'])
          .onClick(() => {
            this.openInfo()
          })
      }
      .width('100%')

      Text('作用于阅读页的留白带、正文区边框与信息窗底板；进阅读页生效')
        .fontSize(11)
        .fontColor('rgba(0,0,0,0.45)')
        .width('100%')

      // ── 卡片横排：默认外观 + 全部注册包 ─────────────────────────────────────
      Scroll() {
        Row({ space: 12 }) {
          this.packCard('', '默认外观', '#ECEFF1')
          ForEach(this.packs(), (pack: SkinPack) => {
            this.packCard(pack.id, pack.name, pack.previewColor ?? '#ECEFF1')
          }, (pack: SkinPack) => pack.id + '_' + this.skinId)
        }
        .alignItems(VerticalAlign.Top)
      }
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)
      .width('100%')
      .align(Alignment.Start)
    }
    .width('90%')
    .padding(12)
    .borderRadius(12)
    // 2026-09-25 主题格子同款口径：不铺底色，跟随页面渐变背景
    .alignItems(HorizontalAlign.Start)
  }
}
