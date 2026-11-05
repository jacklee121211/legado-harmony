/**
 * 主题皮肤系统 · 元素注册表核心（2026-11-06，P1.2）。
 *
 * 规范：`docs/主题皮肤系统-设计规范与交接-2026-11-06.md`（§3 元素注册表 / §4 皮肤包格式 / §5 层序）。
 * 本文件只定义「有哪些元素 / 皮肤槽位长什么样」；
 * ⚠️ 区域几何**一律由消费侧调用既有函数**（`ReaderCalibMath` 的 inset/宽度函数与
 * `ReaderPage3` 的信息条私有函数）——本文件禁止出现 88/62/0.861/12/8/18/20 任何一个对齐常量
 * （AGENTS §5.8 单一通路：常量历史上反复微调，抄了必错位）。
 *
 * 消费方：`SkinStore`（解析/回落）、`ReaderPage3.SkinLayers()`（渲染）、`Index` / `ListenDock`（图标，P3）。
 */

/** 皮肤素材通道（规范 §4.2 三型 + symbol-ttf，P3 启用） */
export class SkinAssetType {
  /** 纯色/渐变：零素材，color（渐变再加 colorEnd） */
  static readonly CODE: string = 'code';
  /** 位图：PNG/JPG，九宫格或整体拉伸；不可染色（Index.ets PNG fillColor 实测不生效） */
  static readonly IMAGE: string = 'image';
  /** 矢量：可随主题染色（fillColor） */
  static readonly SVG: string = 'svg';
  /** 自定义 symbol 字体：整包注册（symbolRegister），P3 + 真机验证后启用 */
  static readonly SYMBOL_TTF: string = 'symbol-ttf';
}

/**
 * 元素 key（规范 §3.1 注册表 v1）。
 * ⚠️ 新增/改名元素：先改规范文档再改这里（口径变更先文档后代码）。
 */
export class SkinElementKey {
  /** 顶部留白带（矩形：0..scrollTopInsetVp，全宽） */
  static readonly BAND_TOP: string = 'reader.band.top';
  /** 底部留白带（矩形：屏高−scrollBottomInsetVp..屏高，全宽） */
  static readonly BAND_BOTTOM: string = 'reader.band.bottom';
  /** 阅读区框（正文矩形外扩 insetExtraVp 的边框/四角装饰层） */
  static readonly TEXT_FRAME: string = 'reader.text.frame';
  /** 阅读区芯（正文后填充；RK 档实际由 themeColor 承担，见规范 §5.2 方案 A） */
  static readonly TEXT_FILL: string = 'reader.text.fill';
  /** 信息条底板·上态（infoWinPos==0 时挂） */
  static readonly INFOBAR_BG_TOP: string = 'reader.infobar.bg.top';
  /** 信息条底板·下态（infoWinPos==1 时挂） */
  static readonly INFOBAR_BG_BOTTOM: string = 'reader.infobar.bg.bottom';
  // ── 以下图标类 key：P3 启用（symbol-ttf / svg 通道） ──────────────────────
  /** 主页页签图标：shelf / theme / settings / mine */
  static readonly DOCK_ICON_SHELF: string = 'dock.icon.shelf';
  static readonly DOCK_ICON_THEME: string = 'dock.icon.theme';
  static readonly DOCK_ICON_SETTINGS: string = 'dock.icon.settings';
  static readonly DOCK_ICON_MINE: string = 'dock.icon.mine';
  /** 听书 minibar 图标：上一章/播放/暂停/下一章/关闭 */
  static readonly MINIBAR_ICON_PREV: string = 'dock.minibar.icon.prev';
  static readonly MINIBAR_ICON_PLAY: string = 'dock.minibar.icon.play';
  static readonly MINIBAR_ICON_PAUSE: string = 'dock.minibar.icon.pause';
  static readonly MINIBAR_ICON_NEXT: string = 'dock.minibar.icon.next';
  static readonly MINIBAR_ICON_CLOSE: string = 'dock.minibar.icon.close';
  /** 信息窗内容图标（日/月/电量族/书签/防窥眼）：P3 按同前缀扩展 */
  static readonly INFOBAR_ICON_MOON: string = 'reader.infobar.icon.moon';
  static readonly INFOBAR_ICON_SUN: string = 'reader.infobar.icon.sun';
  static readonly INFOBAR_ICON_BOOKMARK: string = 'reader.infobar.icon.bookmark';
  static readonly INFOBAR_ICON_BOOKMARK_FILL: string = 'reader.infobar.icon.bookmark.fill';
  static readonly INFOBAR_ICON_EYE: string = 'reader.infobar.icon.eye';
  static readonly INFOBAR_ICON_EYE_SLASH: string = 'reader.infobar.icon.eye.slash';
}

/** 九宫格边宽（vp）。对应 `Image.resizable({ slice: EdgeWidths })`，SDK `image.d.ts` 明示单位 vp。 */
export interface SkinSlice {
  top: number;
  right: number;
  bottom: number;
  left: number;
}

/**
 * 单个元素的皮肤槽位（manifest `elements` 数组的一项）。
 * 逐元素缺省回落：解析器对没配到的 key 返回 null ⇒ 渲染层跳过 = 用默认外观。
 */
export interface SkinSlot {
  /** SkinElementKey 之一 */
  key: string;
  /** SkinAssetType 之一 */
  type: string;
  /** CODE 通道：纯色值（#RRGGBB/#AARRGGBB） */
  color?: string;
  /** CODE 通道渐变第二色；给了 = color→colorEnd 线性渐变，不给 = 纯色 */
  colorEnd?: string;
  /** IMAGE/SVG/SYMBOL_TTF 通道：rawfile 相对路径或 file:// 沙箱路径 */
  asset?: string;
  /** IMAGE 通道九宫格（vp）；缺省 = 整体拉伸（objectFill） */
  slice?: SkinSlice;
  /**
   * 仅 TEXT_FRAME：四周向外冗余（vp）。默认 16 —— 依据规范 §2.6 实测：
   * 12.2 横屏 RK 横滑正文比模型矩形每侧宽 15.1vp，16 = 偏差 + 余量，圆角不压墨迹。
   */
  insetExtraVp?: number;
  /** SYMBOL_TTF 通道：unicode 码位（如 '0x100016'，写进 string.json 后经 $r 引用） */
  glyph?: string;
  /**
   * 渲染期解析好的素材路径（2026-11-06 v2）：SkinStore.selToSlot 按选择来源计算——
   * 预制 = `skins/<包id>/<素材>`（配 $rawfile）；自定义 = file:// 沙箱路径（直接作 Image src）。
   * 渲染层**只认这个字段**，不再自行拼包路径。
   */
  resolvedPath?: string;
}

/**
 * 皮肤包 manifest（规范 §4.1，formatVersion 现为 1）。
 * elements 用数组（ArkTS 友好，量级 ≤ 20，查找用 for 循环）。
 */
export interface SkinPack {
  formatVersion: number;
  id: string;
  name: string;
  author?: string;
  /** 预览主色（主题页皮肤卡片的色块底色，2026-11-06 UI 增补；缺省 = 中性灰） */
  previewColor?: string;
  /** 是否在选择 UI 中可见（2026-11-06：内置兜底包标 false，不出现在预设列表） */
  visible?: boolean;
  /** 亮色档元素表 */
  elements: SkinSlot[];
  /** 深色档可选；解析顺序 dark[key] → elements[key] → 无皮肤（规范 §4.1 回落链） */
  dark?: SkinSlot[];
}

/** 当前 manifest 协议版本（解析时校验，不匹配即整包拒绝并回落默认） */
export const SKIN_FORMAT_VERSION: number = 1;

/** TEXT_FRAME 的默认四周冗余（vp）——数值依据见 SkinSlot.insetExtraVp 注释 */
export const SKIN_FRAME_INSET_EXTRA_VP_DEFAULT: number = 16;

/** 按 key 查槽位（亮色表）；查不到返回 null（= 该元素回落默认外观） */
export function findSlot(pack: SkinPack, key: string): SkinSlot | null {
  const arr: SkinSlot[] = pack.elements;
  if (arr !== null && arr !== undefined) {
    for (let i = 0; i < arr.length; i++) {
      if (arr[i].key === key) {
        return arr[i];
      }
    }
  }
  return null;
}

/** 按 key 查深色档槽位；无 dark 段或查不到返回 null */
export function findDarkSlot(pack: SkinPack, key: string): SkinSlot | null {
  const arr: SkinSlot[] | undefined = pack.dark;
  if (arr === null || arr === undefined) {
    return null;
  }
  for (let i = 0; i < arr.length; i++) {
    if (arr[i].key === key) {
      return arr[i];
    }
  }
  return null;
}
