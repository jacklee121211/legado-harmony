/**
 * 主题页 ·「阅读器」页签 · 阅读皮肤面板（2026-11-06 v2 按元素模型）。
 *
 * 用户拍板的设计（对话原话归纳）：
 * · 主题页页签切「设置主题 / 阅读器」（像书架「全部/最近/分组」，同款 GlassSegment）；
 * · 阅读器皮肤 = **按元素**定义：正文区域 / 信息窗区域 / 顶部留白 / 底部留白，
 *   每个元素独立选「预制元素」（来自皮肤包库）或「自定义导入」（本机图片）或「无」；
 * · 元素只是穿在自己区域上的层，**整体背景永远跟随阅读器真实背景**（不冲突，真机已证）；
 * · 「预设方案」= 一键四元素整套换装（方便测试），与按元素选择并存，元素选择覆盖方案。
 * 弹窗/按钮全部按 `docs/标准-弹窗与按钮统一规范.md`（@CustomDialog + DialogHost + 材质四件套
 * + Haptics.tap）。持久化：SkinStore 按元素选择表（`readerSkinElemSel`，PersistentStorage）；
 * 总开关与设置页暗门组同一键（`SET_READER_SKIN_ON`）。阅读页进场读一次（不热切）。
 */
import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { Haptics } from '../../../common/utils/Haptics';
import MySetConstants from '../../../common/constants/MySetConstants';
import { SkinAssetType, SkinElementKey, SkinPack, SkinSlot } from '../../../common/theme/SkinCore';
import { SkinElemSel, SkinStore } from '../../../common/theme/SkinStore';
import ImmersiveMaterialUtil from '../../../common/utils/ImmersiveMaterialUtil';
import UiMotion from '../../../common/utils/UiMotion';
import { PreferencesUtil } from '@pura/harmony-utils';
import { pickerAvatar } from '../../../common/utils/photoViewPicker';
import { DialogHost } from '../../../common/dialog/DialogHost';
import { NightMode } from '../../../common/utils/NightMode';

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

      Text('它只换阅读页的"外观层"：正文区边框、信息窗底板、上下留白带。'
        + '每个元素可以单独选预制款式或导入本机图片，也可以选「无」＝那块透出阅读页真实背景。')
        .fontSize(14)
        .lineHeight(22)

      Text('· 整页背景永远跟随阅读器现有的背景设置，元素不会与它冲突；\n'
        + '· 改完进阅读页生效（阅读中途不热切）；\n'
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

/** 元素组定义（面板按组渲染；keys[0] 是该组的"选择存储键"，信息窗一组写两个键） */
interface SkinGroupDef {
  title: string;
  keys: string[];
}

@Component
export struct ReaderSkinPanel {
  /** 总开关（与设置页暗门组同一 Preferences 键） */
  @State skinOn: boolean = false
  /**
   * 留白带「等比平铺」开关（2026-11-06 A/B，与设置页暗门组同一 Preferences 键）。
   * 关（默认）= 素材整图拉进带区（现状）；开 = 按原比例横向平铺（不变形、一屏单元更少）。
   * 放在这里是为了**试用时不用去解锁暗门组**；两处读写同一个键，改一边即同步。
   */
  @State skinTile: boolean = false
  /** 按元素选择表（原始 JSON；@StorageProp 驱动重渲染，选中态读 SkinStore.elemSel） */
  @StorageProp('readerSkinElemSel') selsRaw: string = '[]'
  /** 手势条高度：滚动内容底部让位悬浮 dock（2026-11-06 用户反馈「底部留白卡到 dock 点不到」） */
  @StorageLink('bottomRectHeight') bottomRectHeight: number = 0

  aboutToAppear(): void {
    this.skinOn = PreferencesUtil.getSync(MySetConstants.SET_READER_SKIN_ON, false) as boolean;
    this.skinTile = PreferencesUtil.getSync(MySetConstants.SET_READER_SKIN_TILE, false) as boolean;
  }

  /** 元素组定义（信息窗一组映射 top+bottom 两个存储键） */
  private groups(): SkinGroupDef[] {
    return [
      { title: '正文区域', keys: [SkinElementKey.TEXT_FRAME] },
      { title: '信息窗区域', keys: [SkinElementKey.INFOBAR_BG_TOP, SkinElementKey.INFOBAR_BG_BOTTOM] },
      { title: '顶部留白', keys: [SkinElementKey.BAND_TOP] },
      { title: '底部留白', keys: [SkinElementKey.BAND_BOTTOM] }
    ];
  }

  /** 组内当前选择（按 keys[0] 读；信息窗 top/bottom 永远镜像，读一个即可） */
  private groupSel(keys: string[]): SkinElemSel | null {
    return SkinStore.elemSel(keys[0]);
  }

  /** 预制元素 chip 的选中判定：来源包一致即选中 */
  private chipSelected(keys: string[], packId: string): boolean {
    const sel: SkinElemSel | null = this.groupSel(keys);
    return sel !== null && sel.sourcePack === packId;
  }

  /** 自定义导入 chip 的选中判定 */
  private isCustomSel(keys: string[]): boolean {
    const sel: SkinElemSel | null = this.groupSel(keys);
    return sel !== null && sel.customPath !== undefined && sel.customPath !== '';
  }

  /** 该组当前来源文案（无 / 包名 / 自定义） */
  private selLabel(keys: string[]): string {
    const sel: SkinElemSel | null = this.groupSel(keys);
    if (sel === null) {
      return '无（透出真实背景）';
    }
    if (sel.customPath !== undefined && sel.customPath !== '') {
      return '自定义图片';
    }
    const packs: SkinPack[] = SkinStore.listPacks();
    for (let i = 0; i < packs.length; i++) {
      if (packs[i].id === sel.sourcePack) {
        return packs[i].name;
      }
    }
    return '已设置';
  }

  /**
   * 任意选择动作前确保总开关打开（用户拍板的开关语义：关=完全恢复原版，开=出现皮肤；
   * 选择了元素却没开开关 = 无效操作，自动代开）。
   */
  private ensureOn(): void {
    if (!this.skinOn) {
      this.skinOn = true;
      PreferencesUtil.putSync(MySetConstants.SET_READER_SKIN_ON, true);
    }
  }

  /** 对一组键写同一个选择（预制） */
  private applyPresetToGroup(def: SkinGroupDef, pack: SkinPack): void {
    this.ensureOn();
    const slot: SkinSlot | null = SkinStore.resolve(pack, def.keys[0], NightMode.isDarkSurface());
    for (let i = 0; i < def.keys.length; i++) {
      if (slot === null) {
        SkinStore.setElemSel(def.keys[i], null);
        continue;
      }
      const sel: SkinElemSel = {
        key: def.keys[i], type: slot.type,
        asset: slot.asset, sourcePack: pack.id,
        color: slot.color, colorEnd: slot.colorEnd, slice: slot.slice
      };
      SkinStore.setElemSel(def.keys[i], sel);
    }
    this.getUIContext().getPromptAction().showToast(
      { message: '「' + pack.name + '」已应用到' + def.title + '，进阅读页生效' });
  }

  /** 对一组键写「无」（只清本组键，不殃及其它元素） */
  private clearGroup(def: SkinGroupDef): void {
    this.ensureOn();
    for (let i = 0; i < def.keys.length; i++) {
      SkinStore.setElemSel(def.keys[i], null);
    }
    this.getUIContext().getPromptAction().showToast({ message: '已恢复透出真实背景' });
  }

  /**
   * 自定义导入：系统相册选图 → 复制进沙箱 → 写选择表（亮暗共用同一张，整体拉伸）。
   * 复制方式与 `BookCover.ets:276` 同款（open uri → copyFile(fd, dst, 0)）。
   */
  private async importCustom(keys: string[]): Promise<void> {
    const uris: string[] = await pickerAvatar();
    if (uris.length === 0) {
      return;
    }
    this.ensureOn();
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    const dir: string = ctx.filesDir + '/skins/custom';
    try {
      fs.accessSync(dir);
    } catch (e) {
      fs.mkdirSync(dir, true);
    }
    const dest: string = dir + '/' + keys[0] + '_' + Date.now() + '.img';
    const src = fs.openSync(uris[0], fs.OpenMode.READ_ONLY);
    try {
      await fs.copyFile(src.fd, dest, 0);
    } finally {
      fs.closeSync(src.fd);
    }
    for (let i = 0; i < keys.length; i++) {
      const sel: SkinElemSel = {
        key: keys[i], type: SkinAssetType.IMAGE, customPath: 'file://' + dest
      };
      SkinStore.setElemSel(keys[i], sel);
    }
    this.getUIContext().getPromptAction().showToast({ message: '自定义素材已应用，进阅读页生效' });
  }

  /** 一键整套方案：全部四组来自同一个包；'' = 清空四组（默认外观） */
  private applyWholePack(packId: string): void {
    Haptics.tap();
    this.ensureOn();
    SkinStore.applyPresetPack(packId);
    const tip: string = packId === '' ? '已恢复默认外观' : '整套方案已应用，进阅读页生效';
    this.getUIContext().getPromptAction().showToast({ message: tip });
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

  private textColor(): string {
    return NightMode.isDarkSurface() ? 'rgba(248, 249, 250, 0.72)' : 'rgba(0, 0, 0, 0.62)';
  }

  private subTextColor(): string {
    return NightMode.isDarkSurface() ? 'rgba(248, 249, 250, 0.45)' : 'rgba(0, 0, 0, 0.45)';
  }

  /** 预设方案卡（与主题色板瓦片同构） */
  @Builder
  packCard(id: string, name: string, previewColor: string, active: boolean) {
    Column({ space: 8 }) {
      Column() {
        if (active) {
          Text('使用中')
            .fontSize(9)
            .fontColor('#fff')
            .backgroundColor('#ef4444')
            .textAlign(TextAlign.Center)
            .lineHeight(14)
            .width(39)
            .height(14)
            .borderRadius({ topRight: 8, bottomLeft: 8 })
            .position({ right: 0, top: 0 })
        }
      }
      .width('100%')
      .aspectRatio(167 / 77)
      .constraintSize({ minHeight: 77 })
      .borderRadius(8)
      .backgroundColor(previewColor)
      .border({
        width: active ? 2 : 1,
        color: active ? 'rgba(0,0,0,0.45)' : 'rgba(0,0,0,0.15)'
      })
      Text(name)
        .fontSize(14)
        .height(22)
        .lineHeight(22)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
    }
    .width(140)
    .onClick(() => {
      this.applyWholePack(id)
    })
  }

  /** 元素选择 chip（无 / 预制包名 / 自定义导入） */
  @Builder
  selChip(label: string, selected: boolean, onTap: () => void) {
    Text(label)
      .fontSize(13)
      .fontColor(selected ? '#ffffff' : this.textColor())
      .backgroundColor(selected ? 'rgba(0,0,0,0.55)' : 'rgba(0,0,0,0.08)')
      .padding({ left: 14, right: 14, top: 7, bottom: 7 })
      .borderRadius(16)
      .border({
        width: selected ? 1.5 : 1,
        color: selected ? 'rgba(0,0,0,0.55)' : 'rgba(0,0,0,0.15)'
      })
      .onClick(() => {
        Haptics.tap();
        onTap()
      })
  }

  /** 单个元素组：标题 + 当前来源 + chip 行 */
  @Builder
  groupSection(def: SkinGroupDef) {
    Column({ space: 8 }) {
      Row() {
        Text(def.title)
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.textColor())
        Blank()
        Text(this.selLabel(def.keys))
          .fontSize(11)
          .fontColor(this.subTextColor())
      }
      .width('100%')

      Scroll() {
        Row({ space: 8 }) {
          this.selChip('无', this.groupSel(def.keys) === null, (): void => {
            this.clearGroup(def)
          })
          ForEach(SkinStore.visiblePacks(), (pack: SkinPack) => {
            if (SkinStore.resolve(pack, def.keys[0], NightMode.isDarkSurface()) !== null) {
              this.selChip(pack.name, this.chipSelected(def.keys, pack.id), (): void => {
                this.applyPresetToGroup(def, pack)
              })
            }
          }, (pack: SkinPack) => pack.id + '_' + this.selsRaw)
          this.selChip('自定义导入…', this.isCustomSel(def.keys), (): void => {
            this.importCustom(def.keys)
          })
        }
      }
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)
      .width('100%')
      .align(Alignment.Start)
    }
    .width('100%')
    .padding(12)
    .borderRadius(12)
    .backgroundColor(NightMode.isDarkSurface() ? 'rgba(255,255,255,0.05)' : 'rgba(255,255,255,0.55)')
  }

  build() {
    Scroll() {
      Column({ space: 16 }) {
        // ── 总开关行（与设置页暗门组同一键；关 = 全部元素零渲染 = 改动前外观）────────
        Row() {
          Column({ space: 3 }) {
            Text('启用阅读皮肤')
              .fontSize(15)
              .fontColor(this.textColor())
            Text('关闭 = 完全恢复原版外观（所有皮肤元素不渲染）；任意选择会自动打开')
              .fontSize(11)
              .fontColor(this.subTextColor())
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)

          Toggle({ type: ToggleType.Switch, isOn: this.skinOn })
            .selectedColor('rgba(0,0,0,0.55)')
            .onChange((on: boolean) => {
              Haptics.tap();
              this.skinOn = on;
              PreferencesUtil.putSync(MySetConstants.SET_READER_SKIN_ON, on);
            })
        }
        .width('100%')
        .padding(12)
        .borderRadius(12)
        .backgroundColor(NightMode.isDarkSurface() ? 'rgba(255,255,255,0.05)' : 'rgba(255,255,255,0.55)')

        // ── 留白带等比平铺（2026-11-06 A/B，与设置页暗门组同一个键）──────────────
        Row() {
          Column({ space: 3 }) {
            Text('留白带等比平铺')
              .fontSize(15)
              .fontColor(this.textColor())
            Text('开 = 纹样按原比例横向平铺（不被压扁，但一屏看到的纹样更少）；关 = 整图拉伸（默认，与之前一致）')
              .fontSize(11)
              .fontColor(this.subTextColor())
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)

          Toggle({ type: ToggleType.Switch, isOn: this.skinTile })
            .selectedColor('rgba(0,0,0,0.55)')
            .onChange((on: boolean) => {
              Haptics.tap();
              this.skinTile = on;
              PreferencesUtil.putSync(MySetConstants.SET_READER_SKIN_TILE, on);
            })
        }
        .width('100%')
        .padding(12)
        .borderRadius(12)
        .backgroundColor(NightMode.isDarkSurface() ? 'rgba(255,255,255,0.05)' : 'rgba(255,255,255,0.55)')

        // ── 预设方案（一键整套）──────────────────────────────────────────────────
        Row() {
          Text('预设方案')
            .fontSize(15)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.textColor())
          Blank()
          SymbolGlyph($r('sys.symbol.info_circle'))
            .fontSize(20)
            .fontColor([this.subTextColor()])
            .onClick(() => {
              this.openInfo()
            })
        }
        .width('100%')

        Scroll() {
          Row({ space: 12 }) {
            this.packCard('', '默认外观', NightMode.isDarkSurface() ? '#2A2D31' : '#ECEFF1',
              SkinStore.elemSels().length === 0)
            ForEach(SkinStore.visiblePacks(), (pack: SkinPack) => {
              this.packCard(pack.id, pack.name, pack.previewColor ?? '#ECEFF1',
                this.chipSelected([SkinElementKey.BAND_TOP], pack.id))
            }, (pack: SkinPack) => pack.id + '_' + this.selsRaw)
          }
          .alignItems(VerticalAlign.Top)
        }
        .scrollable(ScrollDirection.Horizontal)
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
        .width('100%')
        .align(Alignment.Start)

        // ── 四元素独立选择 ──────────────────────────────────────────────────────
        Text('按元素选择（可混搭，也可导入本机图片）')
          .fontSize(13)
          .fontColor(this.subTextColor())
          .width('100%')

        ForEach(this.groups(), (def: SkinGroupDef) => {
          this.groupSection(def)
        }, (def: SkinGroupDef) => def.title + '_' + this.selsRaw)
      }
      .width('100%')
      .padding({
        left: 20,
        right: 20,
        top: 4,
        // 底部 dock 让位（2026-11-06 用户反馈：底部留白那组卡到 dock 点不到）。
        // 与主题页内容区同款（MyThemeConfig 内容区同口径）；Scroll 无 contentEndOffset
        // （工程 readStatisticsDataList 注释：SDK scroll.d.ts 无该声明，List 才有）⇒ 用内容 padding。
        bottom: ImmersiveMaterialUtil.dockContentEndOffset(this.bottomRectHeight)
      })
    }
    .width('100%')
    .height('100%')
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
  }
}
