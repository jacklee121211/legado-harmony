import { deviceInfo } from '@kit.BasicServicesKit';
import { HdsTabsAttribute, HdsTabsFloatingStyle } from '@kit.UIDesignKit';

/** API<23 用的空实现：不设置任何属性（必须声明在 `HdsCompat` 之前，见那边注释） */
class NoopHdsTabsModifier implements AttributeModifier<HdsTabsAttribute> {
  applyNormalAttribute(instance: HdsTabsAttribute): void {
    // 故意留空：低版本设备不得触碰 HDS 6.1.0(23) 才有的属性
  }
}

/**
 * ── HDS 能力版本闸门（向下兼容 HarmonyOS 6 / API 20）────────────────────────
 *
 * 背景（用户 2026-10-23 拍板）：`compatibleSdkVersion` 从 26.0.0 降到 **20.0.0**
 * （鸿蒙6），否则鸿蒙6 用户在应用市场搜不到本应用。但工程里用到的 HDS（UI Design Kit）
 * 悬浮页签能力**不是 20 就有的**，必须运行时分级。
 *
 * ── 证据（SDK 原文，`…\hms\ets\api\@hms.hds.hdsBaseComponent.d.ets`）────────
 *   · `:5046  export declare const HdsTabs: HdsTabsInterface;`        `@since 6.0.0(20)` ✅
 *   · `:5805  export declare class HdsTabsController …`               `@since 6.0.0(20)` ✅
 *   · `:5124  export declare enum HdsBarStyle {`                      `@since 6.1.0(23)` ❌
 *   · `:5150  export declare enum HdsTabsBarChangeMode {`             `@since 6.1.0(23)` ❌
 *   · `:5380  export declare interface HdsTabsFloatingStyle {`        `@since 6.1.0(23)` ❌
 *   · `:5680  barFloatingStyle(barFloatingStyle?: Optional<…>)`       `@since 6.1.0(23)` ❌
 *   · `applyMiniBarStyle()`（HdsTabsController 成员）                  `@since 6.1.0(23)` ❌
 *
 * ── 为什么必须用"版本闸门"而不是 try/catch ──────────────────────────────────
 *   ArkTS 声明式语法里的 `.barFloatingStyle(x)` 会被编译成**裸方法调用**，
 *   实测本工程构建产物 `entry\build\…\pages\Index.ts` 原文：
 *     `HdsTabs.barFloatingStyle(this.hdsFloatingStyle());`
 *   ⇒ 设备上 HDS 版本低时该方法是 `undefined` ⇒ **调用即抛 TypeError**，
 *     且位置在首页冷启动路径（`build()` 里）⇒ 鸿蒙6 用户会直接白屏/闪退。
 *   同理 `HdsBarStyle.COLLAPSE` 这种**枚举取值**也一样：枚举对象本身不存在。
 *
 * ── 使用铁律（务必遵守）────────────────────────────────────────────────────
 *   ① 上面那几个 23 独有符号**只允许出现在 `supportsFloatingBar()` 为真的分支里**；
 *   ② **禁止**写在字段初始化器 / 模块顶层 / 无条件执行的代码里 —— 闸门拦不住；
 *   ③ 23 以下设备的预期表现：底部页签退回**贴底实心条**（无悬浮、无材质、无听书迷你栏），
 *      这是用户已明确接受的"老机型体验弱于新机型"。
 */
export default class HdsCompat {
  /** 悬浮页签 / 迷你栏相关符号的最低 API 版本（6.1.0 = API 23） */
  static readonly MIN_API_FLOATING_BAR: number = 23;

  /**
   * 当前设备 API 版本。
   * 证据：`…\openharmony\ets\api\@ohos.deviceInfo.d.ts` `const sdkApiVersion: number;`
   * `@since 6`（本工程 `AppGalleryUtil.ets:120` 已在用同一字段）。
   */
  static apiLevel(): number {
    return deviceInfo.sdkApiVersion;
  }

  /**
   * HDS 悬浮页签 / 迷你栏能力是否可用（API 23+，即 HarmonyOS 6.1 起）。
   * 为 `false` 时：不得调用 `barFloatingStyle()` / `applyMiniBarStyle()`，
   * 不得引用 `HdsBarStyle` / `HdsTabsFloatingStyle` / `HdsTabsBarChangeMode`。
   */
  static supportsFloatingBar(): boolean {
    return HdsCompat.apiLevel() >= HdsCompat.MIN_API_FLOATING_BAR;
  }

  /**
   * **空操作**的 HdsTabs 属性修改器（API 20~22 用）。
   * 什么都不做 —— 保证低版本设备**一次都不碰** HDS 的 23 独有属性。
   * ⚠️ 实现类 `NoopHdsTabsModifier` 必须声明在**本类之前**（本文件顶部），
   *   否则 ArkTS 报 `Class 'NoopHdsTabsModifier' used before its declaration`
   *   （静态字段初始化器在类定义时就求值，实测构建报错原文如此）。
   */
  static readonly NOOP_MODIFIER: AttributeModifier<HdsTabsAttribute> = new NoopHdsTabsModifier();
}

/**
 * 把 `barFloatingStyle(...)` 包进 `AttributeModifier` 里。
 *
 * ── 为什么非要绕这一层（关键，别改回去）──────────────────────────────────
 *   声明式语法里的 `.barFloatingStyle(x)` 会被编译成**裸方法调用**，
 *   本工程构建产物 `entry\build\…\pages\Index.ts` 原文：
 *     `HdsTabs.barFloatingStyle(this.hdsFloatingStyle());`
 *   设备上 HDS 版本低（API 20/21/22）时该方法不存在 ⇒ **调用即 TypeError**。
 *   而 `AttributeModifier.applyNormalAttribute()` 是**回调**，只有我们把
 *   这个 modifier 挂上去时才会执行 ⇒ 低版本改挂 `HdsCompat.NOOP_MODIFIER` 即可。
 *
 * ── 官方支持依据 ──────────────────────────────────────────────────────────
 *   HDS 自己就是这么扩展属性的（SDK `@hms.hds.hdsBaseComponent.d.ets:5751`）：
 *     `export declare class HdsTabsModifier extends HdsTabsAttribute
 *        implements AttributeModifier<HdsTabsAttribute> { … }`
 *   ⇒ `attributeModifier()` 这条通道对 HdsTabs 是官方认可的。
 */
export class HdsFloatingStyleModifier implements AttributeModifier<HdsTabsAttribute> {
  private readonly style: HdsTabsFloatingStyle;

  constructor(style: HdsTabsFloatingStyle) {
    this.style = style;
  }

  applyNormalAttribute(instance: HdsTabsAttribute): void {
    instance.barFloatingStyle(this.style);
  }
}
