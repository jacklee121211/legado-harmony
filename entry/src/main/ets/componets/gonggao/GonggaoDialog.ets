/**
 * ══════════════════════════════════════════════════════════════════════════════
 * 「公告」弹窗的**唯一创建入口**（样式 / 关闭口径 / 动作分派都只在这里）
 * ══════════════════════════════════════════════════════════════════════════════
 *
 * 为什么要有这个文件（2026-11-05 新增「关于我们 → 更新公告」第二个入口时抽出来）：
 *   公告弹窗现在有**两个**打开入口：
 *     ① 自动：`pages/Index.ets` 冷启动/回本页时按版本号判定后弹（`maybeShowGonggao`）；
 *     ② 手动：`pages/view/myCenter/about/AboutPage.ets` 的「更新公告」行（用户主动查阅）。
 *   两个入口必须**长得一模一样、关闭口径一模一样**（否则"手点开的那份"和"自动弹的那份"
 *   迟早跑偏）。按项目铁律"同一语义只允许一处实现"，把 options 配方 + 关闭记账 + 动作分派
 *   全部收在这里，调用方只负责：**创建 → DialogHost.openIf → 自己存 controller 引用**。
 *
 * ── options 配方（逐条对齐 `docs/标准-弹窗与按钮统一规范.md` §2.2 / §2.4）
 *   · `customStyle: false` + `cornerRadius: 20` + `systemMaterial` + SPRING_FAST 开关动画；
 *   · 内容含 `Scroll` ⇒ **必须给固定高**（§2.4），这里给 `'78%'`。
 *     官方文档原文（documentId `harmonyos-references/…/弹窗/自定义弹窗_(CustomDialog)/自定义弹窗_(CustomDialog)`）：
 *     「height…弹窗高度默认最大值：0.9 *（窗口高度 - 安全区域）。**百分比参数方式：弹窗参考高度为
 *      （窗口高度 - 安全区域）**，在此基础上调小或调大。」⇒ 百分比自动跟随窗口/设备。
 *     宽度同文档：「百分比参数方式：弹窗参考宽度为所在窗口的宽度」⇒ 见 `dialogWidth()`。
 *
 * ── 关闭 / 记账口径（真机事故结论，见 `pages/Index.ets` 公告那节 + 施工记录 §101.12）
 *   · 「我知道了」/ 点遮罩 / 返回键 ⇒ `Gonggao.markShown()`（**用户看过**才算用掉这次机会）；
 *   · 程序化关闭（被别的弹窗顶掉 / 系统销毁）⇒ 不记账 ⇒ 下次还能补弹。
 *   ⚠️ 因此**手动入口也走同一口径**：用户在「关于我们」看过后，本版本的自动弹窗就不再弹
 *      （符合直觉：他已经读到了）。
 *
 * ── 关闭权归属
 *   `@CustomDialog` 的 `this.controller?.close()` 在子组件内**无效**（`RenameBookDialog.ets:27-32`
 *   真机结论）⇒ 本文件提供 `close(controller)`，由**创建者**（Index / AboutPage）执行。
 */
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { ThemeItem } from '../../common/model/Theme';
import ImmersiveMaterialUtil from '../../common/utils/ImmersiveMaterialUtil';
import UiMotion from '../../common/utils/UiMotion';
// 加群链路（与「我的 → 设置 → 加入Q群」同一个实现）
import { QqGroup, QQ_GROUP_CODE } from '../../common/utils/QqGroup';
import { showMessage } from '../../componets/common/promptShow';
import GonggaoPage from './gonggaopage';
import { Gonggao } from './Gonggao';
import { GONGGAO_ACTION_JOIN_GROUP, GONGGAO_ITEMS } from './GonggaoData';

const TAG: string = 'Gonggao';

export class GonggaoDialog {
  /** 当前是否有公告内容（没有就不该打开 —— 两个入口都先问这个） */
  static hasContent(): boolean {
    return GONGGAO_ITEMS.length > 0;
  }

  /**
   * 创建公告弹窗控制器（**不打开**，打开由调用方 `DialogHost.openIf()` 决定）。
   *
   * @param ctx         UIAbilityContext（「点击加群」要用）
   * @param theme       当前主题（主色，按钮/指示点同源）
   * @param onAppeared  `onDidAppear` 回调（Index 的显示看门狗要用）
   * @param onDisappeared `onDidDisappear` 回调（调用方清 controller 引用 / 决定是否补弹）
   * @param markOnClose 用户关闭时是否记账（默认 `true`）。两个入口当前都传 `true`：
   *                    手动看过本版本后不再自动弹（"一次版本号变化 = 一次展示机会"）；
   *                    若将来希望"手动查阅**不**消耗自动弹出机会"，自动入口传 `true`、
   *                    手动入口传 `false` 即可，不必改本文件。
   * @returns controller；`null` = 没有内容，调用方应改为提示"本版本暂无公告"
   */
  static create(ctx: common.UIAbilityContext, theme: ThemeItem,
    onAppeared: () => void, onDisappeared: () => void,
    markOnClose: boolean = true): CustomDialogController | null {
    if (!GonggaoDialog.hasContent()) {
      return null;
    }
    // 自引用：`onConfirm` 里要关自己 ⇒ 先声明再赋值（ArkTS 允许闭包引用外层的 let）
    let controller: CustomDialogController | null = null;
    try {
      controller = new CustomDialogController({
        builder: GonggaoPage({
          theme: theme,
          // 「我知道了」：先记账，再关（关自己归创建者，见文件头）
          onConfirm: (): void => {
            if (markOnClose) {
              Gonggao.markShown();
            }
            GonggaoDialog.close(controller);
          },
          // 公告里的可点按钮（如「点击加群」）：动作分派收在本文件，两个入口行为一致
          onAction: (action: string): void => {
            GonggaoDialog.dispatchAction(ctx, action);
          }
        }),
        autoCancel: true,
        alignment: DialogAlignment.Center,
        width: GonggaoDialog.dialogWidth(),
        height: '78%',
        cornerRadius: 20,
        // ★ 材质生效的必要条件（规范 2.2）
        customStyle: false,
        systemMaterial: ImmersiveMaterialUtil.sheetMaterial(),
        openAnimation: UiMotion.motionParam(UiMotion.SPRING_FAST),
        closeAnimation: UiMotion.motionParam(UiMotion.SPRING_FAST),
        onDidAppear: onAppeared,
        onDidDisappear: onDisappeared,
        cancel: (): void => {
          // 点遮罩 / 返回键 = 用户看到了并关掉 ⇒ 记账（弹窗已被系统关掉，这里只记账）
          if (markOnClose) {
            Gonggao.markShown();
          }
        }
      });
      return controller;
    } catch (e) {
      hilog.warn(0x0000, TAG, `create failed: ${JSON.stringify(e)}`);
      return null;
    }
  }

  /**
   * 关闭公告弹窗（**必须由创建 controller 的那一层调用**，见文件头）。
   * 注意：这里**不记账** —— 记账绑在"用户动作"上（onConfirm / cancel），见文件头口径。
   */
  static close(controller: CustomDialogController | null): void {
    if (controller === null) {
      return;
    }
    try {
      controller.close();
    } catch (e) {
      hilog.warn(0x0000, TAG, `close failed: ${JSON.stringify(e)}`);
    }
  }

  /**
   * 公告内可点按钮的动作分派（目前只有「加入 QQ 群」）。
   * 新增动作：`GonggaoData.ets` 加常量 + 这里加一个分支，**界面文件不用动**。
   */
  private static dispatchAction(ctx: common.UIAbilityContext, action: string): void {
    if (action === GONGGAO_ACTION_JOIN_GROUP) {
      QqGroup.join(ctx, (): void => {
        hilog.warn(0x0000, TAG, 'join QQ group failed at all three levels');
        GonggaoDialog.toast(`打开失败，请手动搜索 QQ群：${QQ_GROUP_CODE}`);
      });
      return;
    }
    hilog.info(0x0000, TAG, `unhandled announcement action: ${action}`);
  }

  /** 安全 toast（`showToast` 会抛异常 ⇒ 吞掉，提示失败不影响主流程） */
  private static toast(message: string): void {
    try {
      showMessage(message);
    } catch (e) {
      hilog.warn(0x0000, TAG, `toast failed: ${JSON.stringify(e)}`);
    }
  }

  /**
   * 弹窗宽度：手机（xs/sm/md）按窗口宽 88%，平板 / 2in1（lg/xl）固定 460vp。
   * 为什么大屏不用百分比：`width` 的百分比口径是"所在窗口宽"，平板/2in1 上用 88%
   * 会变成"一条横跨整屏的公告"⇒ 固定宽更接近系统弹窗观感。
   * `currentBreakpoint` 由 `EntryAbility.updateBreakpoint()` 写入，与书架列数同源。
   * ⚠️ 返回类型必须是 `Dimension`（不是 `string | number`）：SDK `component/units.d.ts:347`
   * 原文 `declare type Dimension = PX | VP | FP | LPX | Percentage | Resource;`，
   * 其中 `:289 declare type Percentage = \`${number}%\`;`、`PX/VP` 也是模板字面量类型
   * ⇒ 裸 `string`/裸 `number` 联合**不可赋值**（MCP check 实测报 2322）。
   */
  private static dialogWidth(): Dimension {
    const bp: string = AppStorage.get<string>('currentBreakpoint') ?? '';
    return (bp === 'lg' || bp === 'xl') ? '460vp' : '88%';
  }
}

export default GonggaoDialog;
