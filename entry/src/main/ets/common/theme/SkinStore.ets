/**
 * 主题皮肤系统 · 皮肤存储与回落解析（2026-11-06，P1.3）。
 *
 * 规范：`docs/主题皮肤系统-设计规范与交接-2026-11-06.md` §4（皮肤包格式）/ §5.3（优先级）。
 *
 * 职责：
 * · 注册内置皮肤包（P1 只有一份 code 通道占位包；P2 起增加 rawfile manifest 解析）；
 * · 当前皮肤 id 持久化（`PersistentStorage` 挂 `readerSkinPackId`，默认 '' = 全默认外观）；
 * · 逐元素缺省回落解析：`resolve()` 查不到返回 null ⇒ 渲染层跳过该元素（= 默认外观）。
 *
 * 初始化：`EntryAbility` 里与 `themeManager.init()` 同点调用 `SkinStore.init()`（同一先例）。
 * ⚠️ 本文件不出现任何对齐常量（88/62/0.861/12/8/18/20）；区域几何由渲染层调既有函数（§5.8）。
 */
import { SkinAssetType, SkinElementKey, SkinPack, SkinSlot,
  findDarkSlot, findSlot, SKIN_FORMAT_VERSION } from './SkinCore';

/** AppStorage/PersistentStorage 键：当前皮肤包 id（'' = 未启用皮肤） */
const SKIN_ID_KEY: string = 'readerSkinPackId';

export class SkinStore {
  private static packs: SkinPack[] = [];

  /** 应用启动时调用一次（EntryAbility，与 themeManager.init() 同点）：持久化 + 注册内置包 */
  static init(): void {
    PersistentStorage.persistProp<string>(SKIN_ID_KEY, '');
    SkinStore.registerBuiltin(SkinStore.builtinCodePack());
  }

  /** 注册内置皮肤包（幂等：同 id 只注册一次） */
  static registerBuiltin(pack: SkinPack): void {
    if (pack.formatVersion !== SKIN_FORMAT_VERSION) {
      return; // 协议不匹配整包拒绝（规范 §4.1）
    }
    for (let i = 0; i < SkinStore.packs.length; i++) {
      if (SkinStore.packs[i].id === pack.id) {
        return;
      }
    }
    SkinStore.packs.push(pack);
  }

  static listPacks(): SkinPack[] {
    return SkinStore.packs;
  }

  /** 当前皮肤包 id（'' = 未启用） */
  static activePackId(): string {
    const v: string | undefined = AppStorage.get<string>(SKIN_ID_KEY);
    if (v === undefined || v === null) {
      return '';
    }
    return v;
  }

  /** 切换皮肤包（id='' = 回到全默认外观）；未注册的 id 视为未启用 */
  static setActivePackId(id: string): void {
    if (id !== '') {
      let found = false;
      for (let i = 0; i < SkinStore.packs.length; i++) {
        if (SkinStore.packs[i].id === id) {
          found = true;
          break;
        }
      }
      if (!found) {
        return;
      }
    }
    AppStorage.setOrCreate<string>(SKIN_ID_KEY, id);
  }

  /** 当前生效皮肤包；未启用或 id 未注册 → null（所有元素走默认外观） */
  static activePack(): SkinPack | null {
    const id: string = SkinStore.activePackId();
    if (id === '') {
      return null;
    }
    for (let i = 0; i < SkinStore.packs.length; i++) {
      if (SkinStore.packs[i].id === id) {
        return SkinStore.packs[i];
      }
    }
    return null;
  }

  /**
   * 解析一个元素的皮肤槽位（回落链，规范 §4.1 / §5.3）：
   *   深色档：dark[key] → elements[key] → null；亮色档：elements[key] → null。
   * 返回 null = 该元素无皮肤 ⇒ 渲染层跳过（默认外观，一行不改现状）。
   */
  static resolve(pack: SkinPack, key: string, dark: boolean): SkinSlot | null {
    if (dark) {
      const d: SkinSlot | null = findDarkSlot(pack, key);
      if (d !== null) {
        return d;
      }
    }
    return findSlot(pack, key);
  }

  /**
   * 内置占位皮肤包（code 通道，P1 用；素材为"暖纸"极简配色，正式素材 P2 换）。
   * ⚠️ 不含 `reader.text.fill`：该元素必须画在正文层之下，P1 的插入槽位在正文之上
   *    （规范 §5.2 方案 A：RK 档的芯由 themeColor 承担；自绘档的芯 P2 单独开槽位）。
   * ⚠️ 颜色即素材：换素材不改代码（P2 走 manifest 后本包降级为兜底演示包）。
   */
  private static builtinCodePack(): SkinPack {
    const light: SkinSlot[] = [
      { key: SkinElementKey.BAND_TOP, type: SkinAssetType.CODE,
        color: '#FFF1DE', colorEnd: '#FFFBF3' },
      { key: SkinElementKey.BAND_BOTTOM, type: SkinAssetType.CODE,
        color: '#FFFBF3', colorEnd: '#FFF1DE' },
      { key: SkinElementKey.TEXT_FRAME, type: SkinAssetType.CODE,
        color: '#C8A272' },
      { key: SkinElementKey.INFOBAR_BG_TOP, type: SkinAssetType.CODE,
        color: '#80F6E9D2' },
      { key: SkinElementKey.INFOBAR_BG_BOTTOM, type: SkinAssetType.CODE,
        color: '#80F6E9D2' }
    ];
    const dark: SkinSlot[] = [
      { key: SkinElementKey.BAND_TOP, type: SkinAssetType.CODE,
        color: '#241C17', colorEnd: '#1C1613' },
      { key: SkinElementKey.BAND_BOTTOM, type: SkinAssetType.CODE,
        color: '#1C1613', colorEnd: '#241C17' },
      { key: SkinElementKey.TEXT_FRAME, type: SkinAssetType.CODE,
        color: '#7A5C42' },
      { key: SkinElementKey.INFOBAR_BG_TOP, type: SkinAssetType.CODE,
        color: '#802E241E' },
      { key: SkinElementKey.INFOBAR_BG_BOTTOM, type: SkinAssetType.CODE,
        color: '#802E241E' }
    ];
    const pack: SkinPack = {
      formatVersion: SKIN_FORMAT_VERSION,
      id: 'warm-paper-lite',
      name: '暖纸·极简（内置占位）',
      elements: light,
      dark: dark
    };
    return pack;
  }
}
