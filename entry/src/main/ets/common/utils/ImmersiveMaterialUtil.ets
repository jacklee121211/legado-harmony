import { uiMaterial } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { NightMode } from './NightMode';

/**
 * 夜间浮层（弹窗 / 菜单）面板兜底色 —— **不透明**。
 * 与工程里既有的夜间面板色（`ReaderCatalogDialog.PANEL_BG_NIGHT` /
 * `ReaderListenDialog` / `TtsControlPanel`）**逐字一致**，避免同一屏出现两种黑。
 */
const MATERIAL_NIGHT_PANEL: string = '#1F1F1F';

/**
 * 沉浸光感（Immersive Material）统一入口 —— 全工程唯一的"是否开、开多厚"决策点。
 *
 * ── 为什么要有这个类 ──────────────────────────────────────────────────────
 * 沉浸光感是 **API 26.0.0 新增**的 ArkUI 能力（官方原文，documentId
 * `开发指南/ArkUI_方舟UI框架/UI开发_ArkTS声明式开发范式/沉浸光感/沉浸光感简介/arkts-immersive-light-sense-overview`：
 * 「从API版本26.0.0开始，ArkUI新增沉浸光感。」）。本工程 `compatibleSdkVersion = 26.0.0`，
 * 正好踩在支持线上。
 *
 * 但官方同时明确警告**功耗**（documentId `…/沉浸光感功耗优化/arkts-immersive-light-sense-constraints`）：
 *   「沉浸光感效果由材质滤镜、折射、高光、阴影等多层效果叠加而成，渲染时需要消耗GPU资源，
 *     不合理使用会显著增加功耗。」
 *   「总体优化原则：沉浸光感效果作为一种"稀缺"视觉资源使用，需控制面积与层数」
 *   「避免材质嵌套使用…同一子树中只需在最外层设置一次」
 * ⇒ 所以**不允许**在各个页面里散落 `new uiMaterial.ImmersiveMaterial(...)`：
 *   一律走这里，方便统一调档、统一关、并保证不嵌套。
 *
 * ── 一键回退 ──────────────────────────────────────────────────────────────
 * 把下面 `ENABLED` 改成 `false` 即可让全工程回到改造前的样子
 * （所有调用点都会拿到 `undefined`，等同于不设置 `systemMaterial`）。
 * 回退后要验证：底部页签恢复成"贴底实心条"、各 sheet 恢复成纯色背景。
 *
 * ── 自适应策略 ────────────────────────────────────────────────────────────
 * 官方要求材质档位随设备算力自适应，并提供 `uiMaterial.getGlobalMaterialLevel()`：
 *   EXQUISITE=0 高算力 / GENTLE=1 中算力 / SMOOTH=2 低算力
 * 以及能力查询 `uiMaterial.isImmersiveMaterialSupported()`（原文：
 *   「If it is false, setting the ImmersiveMaterial object in the systemMaterial
 *     attribute will not take effect.」）⇒ 不支持时我们直接返回 undefined。
 *
 * 官方对样式的推荐（documentId `…/组件适配沉浸光感/arkts-immersive-light-sense-component-adaptation`）：
 *   · 导航类（含底部页签）：「通常使用较薄的材质样式（ULTRA_THIN或THIN）」
 *   · 弹窗类：「通常使用较厚的材质样式（THICK或ULTRA_THICK）」
 *   · 按钮与选择类：「通常使用较薄的材质样式（ULTRA_THIN或THIN）」
 * 而 `style` 这个参数**只对高/中算力设备的显示效果生效**（`ImmersiveOptions.style` 原文注释），
 * 低算力设备上材质只影响 backgroundColor/borderColor/borderWidth/shadow。
 *
 * ⚠️ 严格遵守「避免材质嵌套」：底部页签是材质背板，其内部不要再对子组件设材质。
 *
 * ── 真机自查手段（官方给的，很好用）────────────────────────────────────────
 * 官方 FAQ（documentId
 * `…/沉浸光感/沉浸光感常见问题/arkts-immersive-light-sense-faq`）「组件不在沉浸光感生效范围」一节原文：
 *   「日志中存在打印：`Material inactive: out of scope. Use component in navigation title bar or Tabbar.`」
 * ⇒ 真机上如果怀疑某处材质没生效，直接过滤这条日志即可定位是"生效范围不满足"还是代码写错：
 *   `hdc shell hilog | Select-String "Material inactive"`
 *
 * ── 另外两条官方结论（解释了本类为什么这么写）────────────────────────────
 * · `uiMaterial.MaterialLevel` **不可设置**：「材质等级由设备决定，即自适应材质等级，
 *   仅支持通过 `uiMaterial.getGlobalMaterialLevel` 获取，不支持设置」
 *   ⇒ 所以本类只**读**它来决定用哪档 `ImmersiveStyle`，从不写。
 * · 「在低算力设备上，仅支持一种材质样式，`ImmersiveStyle` 枚举不生效」
 *   ⇒ 低端机上我们传的 style 会被忽略，无副作用。
 */
export default class ImmersiveMaterialUtil {
  /**
   * **总开关（一键回退点）**。
   * `false` ⇒ 全工程所有 `xxx()` 都返回 `undefined`，行为与改造前完全一致。
   */
  static readonly ENABLED: boolean = true;

  private static supported: boolean = false;
  private static level: uiMaterial.MaterialLevel = uiMaterial.MaterialLevel.GENTLE;
  private static probed: boolean = false;

  /**
   * 探测设备能力与算力档位（幂等，只在首次真正调用时执行一次）。
   * 全部包在 try/catch 里：这些接口是 API 26 新增的，在更低版本设备上不存在，
   * 取不到就当"不支持"，绝不让它把界面搞崩。
   */
  private static probe(): void {
    if (ImmersiveMaterialUtil.probed) {
      return;
    }
    ImmersiveMaterialUtil.probed = true;
    if (!ImmersiveMaterialUtil.ENABLED) {
      ImmersiveMaterialUtil.supported = false;
      return;
    }
    try {
      ImmersiveMaterialUtil.supported = uiMaterial.isImmersiveMaterialSupported();
      ImmersiveMaterialUtil.level = uiMaterial.getGlobalMaterialLevel();
      const info = uiMaterial.getMaterialInfo();
      hilog.info(0x0000, 'immersive',
        'probe: supported=%{public}s level=%{public}d state=%{public}d',
        String(ImmersiveMaterialUtil.supported), ImmersiveMaterialUtil.level, info.state);
    } catch (e) {
      ImmersiveMaterialUtil.supported = false;
      hilog.warn(0x0000, 'immersive', 'probe failed, fallback to off: %{public}s',
        e instanceof Error ? e.message : String(e));
    }
  }

  /** 沉浸光感当前是否真的可用（总开关 + 设备能力都满足） */
  static isOn(): boolean {
    ImmersiveMaterialUtil.probe();
    return ImmersiveMaterialUtil.supported;
  }

  /** 设备算力档位（供需要按档位微调的地方读取） */
  static materialLevel(): uiMaterial.MaterialLevel {
    ImmersiveMaterialUtil.probe();
    return ImmersiveMaterialUtil.level;
  }

  /** 是否高算力设备（可用更厚的材质） */
  private static isHighEnd(): boolean {
    return ImmersiveMaterialUtil.materialLevel() === uiMaterial.MaterialLevel.EXQUISITE;
  }

  /**
   * 底部页签的**完整悬浮样式**（含材质背板）。
   *
   * 关闭时返回 `undefined` ⇒ 连"悬浮"这个布局形态也一并撤销，
   * 完全回到原生默认的贴底实心页签条 ⇒ 这才是真正的一键回退。
   *
   * 字段来自 SDK 原文（`…\openharmony\ets\component\tabs.d.ts:824`）：
   *   `barSideMargin?: Length;`   「The width of the left and right margins of the bar.
   *                                It cannot be set in percentage.」
   *   `barBottomMargin?: Length;` 「The distance between the bar and the bottom of tab.
   *                                It cannot be set in percentage.」
   *   `systemMaterial?: UIMaterial.ImmersiveMaterial;`
   *
   * @param barBottomMargin 页签条离底部的距离。**不能用百分比**，所以直接吃像素值。
   *        传 `bottomRectHeight + 8`：让悬浮条浮在系统导航条之上，并留 8vp 呼吸位。
   */
  static tabsFloatingStyle(barBottomMargin: number): FloatingTabBarStyle | undefined {
    if (!ImmersiveMaterialUtil.isOn()) {
      return undefined;
    }
    const style: FloatingTabBarStyle = {
      barSideMargin: 16,
      barBottomMargin: barBottomMargin,
      systemMaterial: ImmersiveMaterialUtil.tabBarMaterial(),
      // ★ 关掉悬浮页签的**底部遮罩**（2026-09-21 真机截图反馈修复）。
      //   `FloatingTabBarStyle` 有 `maskColor`（遮罩颜色）与 `maskHeight`（遮罩高度，不能百分比）
      //   两个字段，SDK 声明见 `…\ets\component\tabs.d.ts:855-874`。
      //   我们此前没设它们 ⇒ 走系统默认，而默认遮罩在真机上是**屏幕底部一大片灰色渐变**，
      //   用户反馈「太大了」「像底部的特效」。页签条自己已经有材质背板，
      //   再叠一层大面积渐变既费 GPU 又难看 ⇒ 显式关掉。
      maskColor: Color.Transparent,
      maskHeight: 0,
    };
    return style;
  }

  /**
   * **底部页签**的材质背板。
   * 官方硬性约束（`…/组件适配沉浸光感` 原文）：
   *   「悬浮样式仅在 barOverlap 为 true、vertical 为 false、barPosition 为
   *     BarPosition.End 时生效，三个条件需同时满足，否则 systemMaterial 设置不生效。」
   * ⇒ 调用方必须同时满足那三个条件（见 `pages/Index.ets`）。
   */
  static tabBarMaterial(): uiMaterial.ImmersiveMaterial | undefined {
    if (!ImmersiveMaterialUtil.isOn()) {
      return undefined;
    }
    // 导航类用薄材质；高算力给 THIN（更明显的通透层次），中/低算力给 ULTRA_THIN（最省）
    return new uiMaterial.ImmersiveMaterial({
      style: ImmersiveMaterialUtil.isHighEnd()
        ? uiMaterial.ImmersiveStyle.THIN
        : uiMaterial.ImmersiveStyle.ULTRA_THIN,
      // ★ 关掉材质自带的阴影（2026-09-21 真机反馈修复）。
      // 官方 `ImmersiveOptions.applyShadow` 原文：
      //   「Whether to add a shadow effect for a material. If this parameter is set to **true**,
      //     the added shadow effect in the material **always takes effect**, which takes precedence
      //     over the general shadow attribute.」默认值 **true**。
      // 它给整条页签背板铺了一层很宽的柔和暗影，真机上看就是"屏幕底部一大块灰色渐变"，
      // 比我们想要的"轻盈悬浮"重得多 ⇒ 显式关掉，改由胶囊自己的圆角边界来表达层次。
      applyShadow: false,
    });
  }

  /**
   * **按钮**的材质（2026-09-21 用户拍板「愿意为主题色换成材质」后启用）。
   *
   * 官方「组件适配沉浸光感」原文（「按钮（Button）」一节）：
   *   · 「组件级开启：按钮支持通过 `systemMaterial` 属性为 Button 组件设置沉浸光感效果。」
   *   · 「配置沉浸光感但**未设置 `buttonStyle`、`backgroundColor` 等颜色相关属性**且未设置材质颜色时，
   *      默认生效 **Button 主题色**的材质样式。」
   *   · 「当沉浸光感启用了光感交互反馈效果（`lightEffect`）时，按钮默认的点击态和悬浮态视觉反馈
   *      **不再展示**，由材质的光感交互反馈效果替代。」
   *
   * ⇒ 两条要点：
   *   ① 我们自己用 `materialColor` **喂进主题色**，这样按钮不会变成系统默认蓝，而是我们的主题色材质；
   *   ② 开了材质就**必须撤掉** `backgroundColor`（否则「已主动设置背景色…不呈现沉浸光感效果」）。
   *      所以「开材质」与「保留原 backgroundColor」是互斥的 —— 这正是用户拍板要做的取舍。
   *
   * ⚠️ `materialColor` 有硬限制（官方 `ImmersiveOptions.materialColor` 原文）：
   *   「The pure color **must have a certain transparency value and cannot be completely opaque**.
   *     Otherwise, the material filter effect will be **completely blocked**.」
   *   ⇒ 必须传半透明色，所以下面用 `tint()` 给主题色加上 alpha。
   *
   * @param tintColor 主题色（`ThemeItem.mainColor`，形如 `#RRGGBB`）
   */
  static buttonMaterial(tintColor: string): uiMaterial.ImmersiveMaterial | undefined {
    if (!ImmersiveMaterialUtil.isOn()) {
      return undefined;
    }
    return new uiMaterial.ImmersiveMaterial({
      style: uiMaterial.ImmersiveStyle.ULTRA_THIN,
      materialColor: ImmersiveMaterialUtil.tint(tintColor, 0.55),
      interactive: true,
      lightEffect: {},
      applyShadow: false,
    });
  }

  /**
   * 给颜色串加上透明度，用于 `materialColor`。
   * 支持 `#RGB` / `#RRGGBB` / `#AARRGGBB`；解析不了就原样返回（宁可不动，也不乱改颜色）。
   * @param hex 颜色串
   * @param alpha 0~1
   */
  static tint(hex: string, alpha: number): string {
    if (hex === undefined || hex === null || hex.length === 0 || hex.charAt(0) !== '#') {
      return hex;
    }
    const a = Math.max(0, Math.min(255, Math.round(alpha * 255)));
    const aa = a.toString(16).padStart(2, '0').toUpperCase();
    const body = hex.substring(1);
    if (body.length === 6) {
      return `#${aa}${body.toUpperCase()}`;
    }
    if (body.length === 3) {
      // #RGB → #RRGGBB
      const r = body.charAt(0);
      const g = body.charAt(1);
      const b = body.charAt(2);
      return `#${aa}${r}${r}${g}${g}${b}${b}`.toUpperCase();
    }
    if (body.length === 8) {
      // 已有 alpha，直接替换掉前两位
      return `#${aa}${body.substring(2).toUpperCase()}`;
    }
    return hex;
  }

  /**
   * 底部页签条高度。官方「沉浸光感典型场景」参考实现写的是 `barHeight(56)`，
   * 本工程 `pages/Index.ets` 也设了 56 —— 两处**必须一致**，否则内容避让会算错。
   */
  static readonly TAB_BAR_HEIGHT: number = 56;

  /** 悬浮页签条与屏幕底边之间额外留的边距（与 `tabsFloatingStyle()` 里的 +8 对应） */
  static readonly TAB_BAR_BOTTOM_MARGIN: number = 8;

  /**
   * 内容区为了**不被悬浮页签条压住**而需要预留的底部内边距（不含系统安全区）。
   *
   * 为什么必须有：`barOverlap(true)` 的语义是「TabBar 背后变模糊并**叠加在 TabContent 之上**」
   * （官方 FAQ `faqs-arkui-1101` 背景知识原文）⇒ 内容会**流到页签条下面**。
   * 真机截图反馈：「我的」页的「主题」卡片被顶到最底部且点不到。
   *
   * ⚠️ **必须加在"页面自己的滚动内容"上，不能加在 `TabContent` 的外层包裹 Column 上**：
   *   后者会造出一段既不属于页面、也没背景的空白区，露出窗口底色 ⇒ 真机表现为
   *   「底部多出一块白块」（用户截图反馈）。加在页面滚动内容里，页面渐变/背景仍铺满整屏，
   *   只是滚动到底时最后一项停在页签条上方。
   *
   * ⚠️ 这里**不含**系统底部安全区：MyCenter 走 `ColumnModifier`（会设 `bottomRectHeight`）、
   *   书架自行处理，重复叠加会把内容顶太高。
   *
   * 关闭沉浸光感时返回 0，避让回到改造前的状态。
   */
  static tabsContentBottomInset(): number {
    if (!ImmersiveMaterialUtil.isOn()) {
      return 0;
    }
    // 条高 + 条底边距 + 8 呼吸位
    return ImmersiveMaterialUtil.TAB_BAR_HEIGHT
      + ImmersiveMaterialUtil.TAB_BAR_BOTTOM_MARGIN
      + 8;
  }

  /**
   * 底部悬浮 dock 的**内容末尾让位**（自适应，2026-10-01）。
   *
   * barOverlap 悬浮 dock 会盖住 TabContent 的内容（官方语义）⇒ 各页滚动内容的
   * **最后一个条目**必须垫出 dock 的实际覆盖高度，否则滚到底时被压在 dock 下面。
   * 覆盖高度 = 条高 56 + 条底边距（bottomRectHeight 系统安全区**实测值** + 8）+ 12 呼吸位
   * ⇒ bottomRectHeight 由调用方从 `AppStorage('bottomRectHeight')` 注入，
   *   全面屏手势/三键导航/平板等不同屏幕比例下由系统实时下发，天然自适应。
   *
   * ⚠️ 与 `tabsContentBottomInset()` 的区别：那个不含安全区实测值（书架旧值 72，
   * 手势机上 dock 实际覆盖 ~92 ⇒ 最后一本书仍被压角 —— 2026-10-01 用户反馈的根因），
   * 新代码一律用本方法。
   */
  static dockContentEndOffset(bottomRectHeight: number): number {
    if (!ImmersiveMaterialUtil.isOn()) {
      return 12;
    }
    return ImmersiveMaterialUtil.TAB_BAR_HEIGHT + 8 + bottomRectHeight + 12;
  }

  /**
   * **弹窗类**（`bindSheet` 的 `SheetOptions`、`CustomDialog` 的 options 等）的材质。
   * 官方：弹窗类「通常使用较厚的材质样式（THICK或ULTRA_THICK）」。
   *
   * ⚠️ 官方同时要求：「沉浸光感开启后，如果**已主动设置背景色、背景模糊**等自定义样式属性，
   *    则**不呈现**沉浸光感效果。」⇒ 开了材质就**必须把 `backgroundColor`/`backgroundBlurStyle` 去掉**，
   *    否则设了也是白设。
   */
  static sheetMaterial(): uiMaterial.ImmersiveMaterial | undefined {
    if (!ImmersiveMaterialUtil.isOn()) {
      return undefined;
    }
    return new uiMaterial.ImmersiveMaterial({
      style: ImmersiveMaterialUtil.isHighEnd()
        ? uiMaterial.ImmersiveStyle.THICK
        : uiMaterial.ImmersiveStyle.REGULAR,
    });
  }

  /**
   * **即时反馈**（Toast / 菜单）的材质。
   * 官方默认档位是 THICK；这里同样按算力收敛一档，省电。
   */
  static feedbackMaterial(): uiMaterial.ImmersiveMaterial | undefined {
    if (!ImmersiveMaterialUtil.isOn()) {
      return undefined;
    }
    return new uiMaterial.ImmersiveMaterial({
      style: ImmersiveMaterialUtil.isHighEnd()
        ? uiMaterial.ImmersiveStyle.THICK
        : uiMaterial.ImmersiveStyle.REGULAR,
    });
  }

  /**
   * **按钮 / 开关 / 滑条**等"选择类"控件的材质。
   * 官方：选择类「通常使用较薄的材质样式（ULTRA_THIN或THIN），…通过 ImmersiveOptions 中的
   * 交互形变（interactive）和点光源（lightEffect）为按压、触摸等操作提供灵动的视觉反馈，
   * **替代组件默认的按压态和悬浮态效果**」。
   * `lightEffect` 传 `{}` 表示启用（其 `color` 默认 `Color.White`）。
   */
  static controlMaterial(): uiMaterial.ImmersiveMaterial | undefined {
    if (!ImmersiveMaterialUtil.isOn()) {
      return undefined;
    }
    return new uiMaterial.ImmersiveMaterial({
      style: uiMaterial.ImmersiveStyle.ULTRA_THIN,
      interactive: true,
      lightEffect: {},
    });
  }

  /**
   * **Slider 专用**的沉浸光感材质 —— **照抄官方示例10**（不再自己加参数）。
   *
   * 官方出处：`API参考/ArkUI_方舟UI框架/ArkTS组件/按钮与选择/Slider/ts-basic-components-slider`
   * 的「示例10（设置滑动条的沉浸光感效果）」，原文代码：
   * ```
   *   Slider({ style: SliderStyle.InSet })
   *     .systemMaterial(new uiMaterial.ImmersiveMaterial({
   *       style: uiMaterial.ImmersiveStyle.ULTRA_THIN,
   *     }))
   * ```
   * 官方说明原文：「该示例通过通用属性 `systemMaterial` 设置滑动条的系统材质，实现沉浸光感效果。
   *   设置系统材质后，**Slider 滑动过程中会产生粒子动画效果**。」
   * ⇒ 官方只传 `style` 一个字段（我们自己加过 `interactive: true` / `lightEffect: {}`，
   *   那不是官方写法；而"粒子动画"是材质自带，不需要 lightEffect）。
   *
   * ⚠️ 为什么我们这边看着"裤子反穿"（用户原话）—— 看官方示例的**最后一行的背景**：
   *   官方是把滑条压在 `backgroundImage($r("app.media.img"))`（一张图）上演示的：
   *   材质那层"底"的作用就是**透出底下的图**，看起来像一条悬浮磨砂轨道。
   *   我们放在**纯色面板**里，底下没有内容可透，那层底就变成一块"多余的矩形"。
   *   官方 `systemMaterial` 声明（`component/common.d.ts:22642`）写明它会接管
   *   「background color / border color / border width / shadow」，**没有"只留粒子、不要底"的开关**。
   * ⇒ 对策不在材质参数上，而在**滑条自己的几何**：把滑条框做成圆角胶囊
   *   （`.borderRadius` + 左右内边距，见各调用点），让材质那层底**就是轨道本身**。
   */
  static sliderMaterial(): uiMaterial.ImmersiveMaterial | undefined {
    if (!ImmersiveMaterialUtil.isOn()) {
      return undefined;
    }
    // 与官方示例10 逐字一致：只传 style
    return new uiMaterial.ImmersiveMaterial({
      style: uiMaterial.ImmersiveStyle.ULTRA_THIN,
    });
  }

  /**
   * 显式**关闭**某个组件的沉浸光感。
   * 官方原文：「要关闭一个默认开启沉浸光感的组件，应使用 `uiMaterial.Material.empty`」
   * 并特别提醒 `Material.empty` 与 `undefined` **含义不同**：
   *   `undefined` = 恢复组件默认的沉浸光感接口效果；`empty` = 关闭。
   * 主要用途：系统在 default 模式下会给 Dialog / Toast / AlphabetIndexer 等默认开启，
   * 我们如果不想要，就用这个关掉。
   */
  static off(): uiMaterial.Material {
    return uiMaterial.Material.empty;
  }
}

/**
 * 「材质优先」的弹窗内容背景修饰器 —— **它只管背景，不设材质**。
 *
 * ── 为什么非要写个 AttributeModifier，而不是三元表达式 ────────────────────
 * 官方原文（`…/组件适配沉浸光感`「弹出框（Dialog）」一节）：
 *   「沉浸光感开启后，如果**已主动设置背景色**、背景模糊等自定义样式属性，
 *     则**不呈现**沉浸光感效果」
 * 也就是说 `.backgroundColor(开启 ? Color.Transparent : Color.White)` 这种写法
 * 若把透明色也算"已设置"，就会把材质挡住。用 `AttributeModifier` 才能做到
 * 「开启时**一个背景属性都不设** / 关闭时落回纯色」，并且天然可一键回退
 * （`ImmersiveMaterialUtil.ENABLED = false` 时自动回到原来的白色）。
 *
 * ── ⚠️ 为什么这里**不**调用 `systemMaterial`（2026-09-21 修正）─────────────
 * 原本这里还给内容 Column 设了 `.systemMaterial(...)`。但审计时发现两条官方原文互证，
 * 说明**弹窗的材质必须走 options，而不是内容节点上的通用属性**：
 *   ① `…/组件适配沉浸光感/…`「弹出框（Dialog）」原文：
 *      「组件级开启：弹出框支持通过**弹出框 options 参数中的 `systemMaterial` 字段**
 *       设置沉浸光感效果，如 `CustomDialogControllerOptions`、`AlertDialogParam`、
 *       `ActionSheetOptions`、`SheetOptions` 等。」
 *   ② 官方 FAQ `…/沉浸光感常见问题/…` 给出的越界日志原文只提了两个地方：
 *      「`Material inactive: out of scope. **Use component in navigation title bar or Tabbar**.`」
 *      —— **没有弹窗**。
 *   而本修饰器用在**弹窗内容节点**上 ⇒ 通用属性很可能被判越界、静默失效；
 *   那样内容背景又被设成透明，**弹窗就会变成透明的、字看不清**。
 *   ⇒ 所以材质改由**调用方的 `CustomDialogControllerOptions.systemMaterial`** 提供
 *     （见各调用点），这里只负责背景的切换。
 */
export class MaterialColumnModifier implements AttributeModifier<ColumnAttribute> {
  private fallback: ResourceColor;
  /**
   * 这个弹窗**是否已经通过官方 options 渠道**拿到了材质 ⇒ 内容层是否要**让开**背景。
   *
   * ── ⚠️ 真机教训 + 正确用法（2026-09-22 二次定案）─────────────────────────
   * 我第一次按官方文档试「`systemMaterial` + 内容层透明」时，真机结果是**弹窗整个变透明**
   * （能看到背后的书架、字压在一起）。当时归因为"材质在 `customStyle: true` 下画不出来"，
   * 并**错误地**立了条"本工程必须保持 `false`"的规矩。
   *
   * 查 SDK 原文后确认，真正的根因是**两个错误叠在一起**：
   *   ① `customStyle: true` 时弹窗层**根本没有背景**。SDK
   *      `custom_dialog_controller.d.ts:130-134` 原文：
   *      「When this parameter is set to **true**: 1. The rounded corner radius is 0,
   *        and **the background color is transparent**.」
   *      ⇒ 材质无处附着。
   *   ② 内容层还设了 `Color.Transparent`。官方对 `MaterialState.DEFAULT` 原文
   *      （documentId `API参考/…/ohos_arkui_uiMaterial_系统材质_/arkts-apis-uimaterial`）：
   *      「弹出框Dialog…**在组件本身未设置背景颜色、模糊参数和阴影参数时**默认开启沉浸式系统材质」
   *      ⇒ 透明色也算"设置了背景颜色"，会把材质挡掉。
   *
   * ⇒ 正确姿势必须**两条一起满足**（缺一就会透明或发白）：
   *   · 调用方把 `customStyle` 设成 **`false`**，并给 `systemMaterial`（见 `BookInfos.ets` 调用点）；
   *   · 这里传 **`true`** ⇒ 材质分支**一个背景属性都不设**，由弹窗层负责画背景。
   *
   * 兜底依旧安全：`ENABLED = false` 或设备不支持时 `isOn()` 为假，
   * 自动落回 `fallback` 实底纯色，**绝不会出现"透明露底"**。
   */
  private hasOptionsMaterial: boolean;

  constructor(fallback: ResourceColor, hasOptionsMaterial: boolean = false) {
    this.fallback = fallback;
    this.hasOptionsMaterial = hasOptionsMaterial;
  }

  applyNormalAttribute(instance: ColumnAttribute): void {
    // ★★ 夜间档：**必须由内容层自己盖一层不透明深底** ★★（2026-09-23 追加）
    //
    // ── 为什么（真机截图 + 官方原文）────────────────────────────────────────
    // 用户真机截图：阅读器/书架切夜间后，仍然有三个浮层是**浅底白字**：
    //   · 书架右上 ⋯ 菜单（`IndexShelf.MenuBuilder` 的 `bindMenu`）
    //   · 分组管理面板（`GroupManageDialog` → `groupTypePanel`）
    //   · 长按书籍弹窗（`BookInfoDialogs`）
    // 同一时刻**页面内**的节点已经是深色 ⇒ 差别只在"底色是不是浮层自带的材质"。
    //
    // 根因在官方对 `MaterialState.DEFAULT` 的原文（documentId
    // `API参考/…/ohos_arkui_uiMaterial_系统材质_/arkts-apis-uimaterial`）：
    //   「弹出框Dialog…**在组件本身未设置背景颜色、模糊参数和阴影参数时**默认开启沉浸式系统材质」
    // ⇒ `@CustomDialog` / `bindMenu` 这类浮层**默认就带沉浸材质**。而沉浸材质的
    //   `ImmersiveOptions`（SDK `…\ets\api\@ohos.arkui.uiMaterial.d.ts:306-429`）
    //   六个字段（style / materialColor / colorInvert / applyShadow / interactive /
    //   lightEffect）里**没有 colorMode** ⇒ 它不认应用配色，夜间还是那层浅色磨砂。
    //
    // 为什么不在 options 里换成 `Material.empty` 关掉材质：`CustomDialogControllerOptions`
    //   的参数**不支持动态更新**（SDK `custom_dialog_controller.d.ts:756` NOTE 原文
    //   「Custom dialog box parameters **do not support dynamic updates**」），
    //   而这些控制器大量是**成员初始化器**建的（`ReaderPage3.listenDialog` 等），
    //   建完之后日夜键再改就来不及了 ⇒ 只能在**内容层**把它压住。
    //   本修饰器的 `applyNormalAttribute` 每次渲染都会重跑，天然能跟着日夜键走。
    //
    // 代价（说清楚）：夜间弹窗是**不透明实底**，没有白天的"毛玻璃透出背景"效果。
    if (NightMode.isDarkSurface()) {
      instance.backgroundColor(MATERIAL_NIGHT_PANEL);
      return;
    }
    if (ImmersiveMaterialUtil.isOn() && this.hasOptionsMaterial) {
      // ⚠️ 这里**故意什么都不做**（2026-09-22 修正）。
      //
      // 之前的写法是 `instance.backgroundColor(Color.Transparent)`，看起来"无害"，
      // 实际会把材质挡掉。证据是官方对 `MaterialState` 的原文（documentId
      // `API参考/…/ohos_arkui_uiMaterial_系统材质_/arkts-apis-uimaterial`）：
      //   | DEFAULT | 0 | 默认模式。弹出框Dialog…**在组件本身未设置背景颜色、模糊参数和
      //     阴影参数时**默认开启沉浸式系统材质 |
      // 「彩色透明」同样属于"设置了背景颜色"，所以只要调了 `backgroundColor`，
      // 无论传什么值都可能让材质不呈现（官方在「组件适配沉浸光感」里也写了
      // 「已主动设置背景色、背景模糊等自定义样式属性，则不呈现沉浸光感效果」）。
      //
      // 既然调用方已经通过 options 的 `systemMaterial` 提供了材质，
      // 弹窗自己那一层就负责画背景 ⇒ 内容层**本来也不需要**背景色。
      // 什么都不设 = 最干净的做法，且零风险。
      return;
    }
    // 安全档 / 回退档：保持原来的实底纯色（绝对不会出现"透明露底"）
    instance.backgroundColor(this.fallback);
  }
}

/**
 * 「主题色材质」按钮修饰器（2026-09-21 用户拍板后启用）。
 *
 * 开启时：**不设** `backgroundColor`，改为 `systemMaterial(materialColor = 半透明主题色)`，
 *        于是按钮呈现「主题色的沉浸光感材质」，并且按压反馈由材质的 `lightEffect` 提供。
 * 关闭时：回落到原来的 `backgroundColor` + `fontColor`（一键回退，视觉与改造前一致）。
 *
 * ⚠️ 这是一个**有取舍**的改动：开了材质就不能再设 `backgroundColor`（官方：「已主动设置背景色…
 *    则不呈现沉浸光感效果」）。用户已确认接受该取舍。
 * ⚠️ 官方另有提醒：「You are advised **not to use this API together with** the aforementioned APIs
 *    [backgroundColor, borderColor, borderWidth, shadow]」⇒ 所以这里在开启分支里只设材质与字色。
 */
/**
 * **悬浮小 dock 的材质背板**（2026-10-09，目录弹窗右侧「顶部/定位/底部」那组按钮用）。
 *
 * ── 为什么要单独一个修饰器 ────────────────────────────────────────────────
 * 用户要求：「适配和书架一样的 dock」。书架 dock 的光感来自
 *   `HdsTabs.barFloatingStyle.systemMaterialEffect`；而这个三按钮组是**普通组件**，
 *   没有 HDS 容器可用 ⇒ 只能走**组件级** `systemMaterial`（官方两条路里的另一条：
 *   「普通ArkUI组件通过应用级开启或者组件级开启方式开启沉浸光感」）。
 *
 * ⚠️ 两条硬约束（都不能用三元表达式绕过）：
 *   ① 官方：「沉浸光感开启后，如果**已主动设置背景色**、背景模糊等自定义样式属性，
 *      则**不呈现**沉浸光感效果」⇒ 开材质时**一个 backgroundColor 都不能设**
 *      （连 `Color.Transparent` 也算"设置了背景色"）。这正是必须用 `AttributeModifier`
 *      的原因 —— 三元表达式一定会调到 `backgroundColor`。
 *   ② 官方：「要关闭一个默认开启沉浸光感的组件，应使用 `uiMaterial.Material.empty`」
 *      —— 本组件的场景是"默认没有材质、我们要开"，所以关的时候直接不设即可。
 *
 * 一键回退：`ImmersiveMaterialUtil.ENABLED = false`（或设备不支持）⇒ 自动落回
 *   `fallbackColor`（改造前那块 `rgba(0,125,255,1)` 蓝），视觉与改造前一致。
 */
export class MaterialDockModifier implements AttributeModifier<ColumnAttribute> {
  private fallbackColor: ResourceColor;

  constructor(fallbackColor: ResourceColor) {
    this.fallbackColor = fallbackColor;
  }

  applyNormalAttribute(instance: ColumnAttribute): void {
    // ⚠️⚠️ 2026-10-09 真机反馈修正（用户原话：「三个图标光秃秃在那里…你是不是搞错层了」）⚠️⚠️
    //   第一版这里写的是 `systemMaterial(controlMaterial())` —— **错了，而且是我自己文档里
    //   早就记过的坑**。官方 FAQ 对材质的**生效范围**只有两处（见本文件头注释第 50-56 行）：
    //     「`Material inactive: out of scope. Use component in navigation title bar or Tabbar.`」
    //   而本修饰器用在**弹窗里的一个普通 Column** 上 ⇒ **越界** ⇒ 材质**静默失效**；
    //   又因为"材质与 backgroundColor 互斥"把背景色删掉了 ⇒ **什么都不剩**（三个裸图标）。
    //   ⇒ 结论：**这个元素拿不到沉浸光感**。改回**一定渲染得出来**的毛玻璃：
    //     半透明底 + `backgroundBlurStyle`。观感接近书架 dock，且绝不静默失效。
    //   （真正的沉浸光感只留给"标题栏 / 底部页签"这两个在生效范围内的位置。）
    if (ImmersiveMaterialUtil.isOn()) {
      instance.backgroundBlurStyle(BlurStyle.COMPONENT_THICK, { colorMode: ThemeColorMode.SYSTEM });
      instance.backgroundColor(this.fallbackColor);
      return;
    }
    // 回退档 / 设备不支持：保持改造前的实底纯色
    instance.backgroundColor(this.fallbackColor);
  }
}
export class MaterialButtonModifier implements AttributeModifier<ButtonAttribute> {
  private bg: ResourceColor;
  private fg: ResourceColor;
  private tintColor: string;

  constructor(bg: ResourceColor, fg: ResourceColor, tintColor: string) {
    this.bg = bg;
    this.fg = fg;
    this.tintColor = tintColor;
  }

  applyNormalAttribute(instance: ButtonAttribute): void {
    const m = ImmersiveMaterialUtil.buttonMaterial(this.tintColor);
    if (m !== undefined) {
      instance.systemMaterial(m);
      instance.fontColor(Color.White);
    } else {
      instance.backgroundColor(this.bg);
      instance.fontColor(this.fg);
    }
  }
}
