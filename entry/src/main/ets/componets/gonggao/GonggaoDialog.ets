/**
 * ══════════════════════════════════════════════════════════════════════════════
 * 「公告」弹窗的**共享件**：尺寸常量 / 关闭口径 / 加群动作 / 有无内容
 * ══════════════════════════════════════════════════════════════════════════════
 *
 * ⚠️⚠️ 2026-11-05 真机事故（**必读，别再犯**）：本文件曾经把
 * `new CustomDialogController({ builder: GonggaoPage({…}), … })` 整段放进这里的
 * `static create()`，想让两个入口共用同一份 options。结果真机上：
 *   · 代码不报错、`open()` 不抛、**没有任何异常日志**；
 *   · 但弹窗**从不出现**（`onDidAppear` 永不触发），日志只有一圈看门狗重试：
 *     ```
 *     Gonggao: open (source=coldStart, attempt=0)
 *     Gonggao: not appeared within 2000ms (attempt=0), retry later
 *     Gonggao: open (source=retry, attempt=1)     ← 循环，屏幕始终没有弹窗
 *     ```
 *   · 全日志 `appeared` / `markShown` / `ModalPage` / `CustomDialog` 命中 0 次。
 * 根因：**`builder: XxxDialog({…})` 这种"结构体实例化"必须写在 @Component 的上下文里**
 *   （struct 的方法 / `@Builder` 方法）；放进**普通 TS 类的静态方法**后，ets 编译产物把它
 *   变成一次普通函数调用，CustomDialogController 拿到的是个"空 builder" ⇒ 建不出节点。
 *   同源结论本工程早有记录（`docs/标准-弹窗与按钮统一规范.md` §4.4：
 *   「跨组件 contentBuilder 回调里直接实例化组件 ⇒ 结构体被编译成普通函数调用 ⇒ 真机必崩」）。
 * ⇒ 因此：**本文件只提供"与 builder 无关"的共享件**，`new CustomDialogController({ builder: GonggaoPage({…}) })`
 *   一律写在各宿主的 struct 里（`pages/Index.ets`、`pages/view/myCenter/about/AboutPage.ets`）。
 *
 * ── 两个入口（自动弹 / 关于我们手动查）必须保持一致的三件事，都在这里：
 *   ① 尺寸：`DIALOG_HEIGHT` / `DIALOG_CORNER` / `dialogWidth()`；
 *   ② 关闭记账：`onUserClosed()`（「我知道了」）/ `markShown()`（点遮罩、返回键）；
 *   ③ 可点按钮动作：`dispatchAction()`（目前只有「加入 QQ 群」，与设置页同一个 `QqGroup`）。
 *
 * ── options 其余字段（材质 / 动画 / customStyle）两个宿主各写一遍，但逐条对齐
 *   `docs/标准-弹窗与按钮统一规范.md` §2.2：
 *   `customStyle: false` + `cornerRadius: 20` + `systemMaterial: ImmersiveMaterialUtil.sheetMaterial()`
 *   + `openAnimation/closeAnimation: UiMotion.motionParam(UiMotion.SPRING_FAST)`。
 */
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
// 加群链路（与「我的 → 设置 → 加入Q群」同一个实现）
import { QqGroup, QQ_GROUP_CODE } from '../../common/utils/QqGroup';
import { showMessage } from '../../componets/common/promptShow';
import { Gonggao } from './Gonggao';
import { GONGGAO_ACTION_JOIN_GROUP, GONGGAO_ITEMS } from './GonggaoData';

const TAG: string = 'Gonggao';

export class GonggaoDialog {
  /**
   * 弹窗高度（百分比）。
   * 官方文档原文（documentId `harmonyos-references/…/弹窗/自定义弹窗_(CustomDialog)/自定义弹窗_(CustomDialog)`）：
   * 「height…弹窗高度默认最大值：0.9 *（窗口高度 - 安全区域）。**百分比参数方式：弹窗参考高度为
   *  （窗口高度 - 安全区域）**，在此基础上调小或调大。」
   * 规范 §2.4 要求"内容含 Scroll 的弹窗必须给固定高" ⇒ 这里给 78%（自动跟随窗口/设备）。
   */
  static readonly DIALOG_HEIGHT: Dimension = '78%';

  /** 弹窗圆角（规范 §2.2：与 options.cornerRadius 同值，内容层也要补一份） */
  static readonly DIALOG_CORNER: number = 20;

  /** 当前是否有公告内容（没有就不该打开 —— 两个入口都先问这个） */
  static hasContent(): boolean {
    return GONGGAO_ITEMS.length > 0;
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
  static dialogWidth(): Dimension {
    const bp: string = AppStorage.get<string>('currentBreakpoint') ?? '';
    return (bp === 'lg' || bp === 'xl') ? '460vp' : '88%';
  }

  /**
   * 用户**关掉**了公告（「我知道了」/ 点遮罩 / 返回键）⇒ 记为本版本已展示。
   *
   * 真机事故结论（施工记录 §101.12）：**不能**在 `open()` 之后立刻记账 ——
   * 首装时系统隐私协议窗会盖在应用之上，公告开在它下面用户根本看不到，
   * 若此时就记账，这个版本号的公告就**永久丢失**了。⇒ 记账绑在"用户动作"上。
   */
  static markShown(): void {
    Gonggao.markShown();
  }

  /** 关闭 controller（**必须由创建它的 struct 调用**；`@CustomDialog` 子组件内 close 无效） */
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
  static dispatchAction(ctx: common.UIAbilityContext, action: string): void {
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
  static toast(message: string): void {
    try {
      showMessage(message);
    } catch (e) {
      hilog.warn(0x0000, TAG, `toast failed: ${JSON.stringify(e)}`);
    }
  }
}

export default GonggaoDialog;
