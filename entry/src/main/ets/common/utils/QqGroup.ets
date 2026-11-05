/**
 * 「加入喵阅官方 QQ 群」的**唯一实现**（2026-11-05 从 `MySetPage.ets` 抽成公共件）。
 *
 * ── 为什么要抽出来 ──────────────────────────────────────────────────────────
 * 用户要求公告弹窗里的「点击加群」**共用工程既有的加群效果**（不是另写一套）。
 * 按项目铁律"同一语义只允许一处实现"，把原来只存在于 `MySetPage` 私有方法里的
 * 三级链路整体搬到这里，`MySetPage`（设置页胶囊）与公告弹窗（`componets/gonggao`）
 * **调用同一个函数** ⇒ 以后换通道只改这一处，不会出现"设置页能加、公告加不了"。
 *
 * ════════════════════════════════════════════════════════════════════════════
 * 三级链路：**① 让 QQ 自己打开官方邀请链接 → ② 系统浏览器打开邀请链接 → ③ 提示群号**
 * ════════════════════════════════════════════════════════════════════════════
 *
 * ⚠️ 2026-10-24 换通道的实证依据（MatePad Pro MRO-W00 / HarmonyOS 6.1 / QQ 9.2.71）：
 *   旧方案 ① 是 `mqqapi://card/show_pslcard?...&card_type=group`，**冷启动必卡「加载中」**
 *   （实测 40s 不恢复；热启动正常）。QQ 日志证明卡点在 QQ 自己那侧：
 *     `JumpService: sourceJumpUrl:mqqapi://card/show_pslcard?...`   ← 已收到
 *     `ProfileCardOIDBHelper: sendOIDBRequest: success, retCode=0`   ← 群资料已拉回
 *   但页面始终不渲染、loading 层不撤 ⇒ 我们这侧无法修，只能换通道。
 *   对照实验（同一台设备、同一个群）：
 *     · `card/show_pslcard`           → 冷启动卡死（40s 仍卡）／热启动正常
 *     · 裸 https 邀请链接              → 冷启动进浏览器官方群资料页，底部「申请加群」
 *     · **`forward/url` + url_prefix** → 冷启动 **2/2 直接进 QQ 原生群资料页**，不卡 ✅
 *     · `im/chat?...&chat_type=group`  → 冷启动不卡，直接进群聊（仅对已入群者有意义）
 *
 * ⚠️ 为什么弃用 `card/show_pslcard`：它是 QQ 的**内部私有 scheme**，不在任何官方文档里
 *   ——QQ互联 HarmonyOS SDK（V1.0.4）公开接口只有 login / share / isQQInstalled /
 *   addCustomLogger，Android SDK 功能列表同样**没有加群 / 群资料能力**。
 *   即「第三方 App 拉起 QQ 加群」腾讯从未提供官方 API，私有 scheme 的 bug 自然无人修。
 *
 * ① 官方语义下的加群载体是**群分享链接 / 二维码**（QQ 群设置里生成），即下面 `QQ_GROUP_URL`：
 *   `busi_data` 解出来是 `{"groupCode":"526836555","token":"…","uin":"…"}`，由 QQ 自己签发。
 *   官方期望的用法是「当普通网页链接打开 → H5 里点『申请加群』→ 由 H5 拉起 QQ」。
 *   `forward/url` 就是让 QQ **自己**去打开这条官方链接（QQ 内置浏览器加载后自动跳原生群资料页），
 *   语义上仍走官方 H5 通道，只是把 H5 放在了 QQ 里 ⇒ 既守规范、又免掉浏览器那一跳。
 *
 * ② 兜底：`forward/url` 抛错（QQ 未安装 / 老版本不认该 scheme）时，退回 `openLink(邀请链接)`，
 *   由系统浏览器打开官方 H5 群资料页。
 *   （`bm dump -n com.tencent.mqq` 显示 QQ 声明的 https host 只有 `qm.qq.com` 与
 *    `qqso.qianbao.qq.com`，**不含 `qun.qq.com`** ⇒ 走 openLink 必然落到浏览器。）
 *
 * ③ 群号 `526836555`：前两级都失败时，调用方负责提示/常驻展示，用户可手动搜索加群。
 *
 * ── 为什么 ① 用 `startAbility` 隐式 Want（官方依据）──────────────────────────
 *   `开发指南/Ability_Kit_程序框架服务/应用间跳转/拉起指定应用/使用Deep_Linking实现应用间跳转/deep-linking-startup`
 *   原文：「startAbility() 接口是将应用链接放入 Want 中，通过调用隐式 Want 匹配的方法触发应用跳转。」
 *   示例：`let want: Want = { uri: 'link://www.example.com' }; context.startAbility(want)`
 *   ⇒ scheme 由系统在本地已安装应用的 skills.uris 里匹配，命中 `mqqapi` 即拉起 QQ。
 */
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
// `forward/url` 需要 base64 编码官方邀请链接（url_prefix）
import { util } from '@kit.ArkTS';

const TAG: string = 'QqGroup';

/** 群号兜底：前两级都失败时让用户手动搜索（两个调用点共用同一个号） */
export const QQ_GROUP_CODE: string = '526836555';

/** ② 官方群分享链接（用户给定，原样保留 percent-encoded 的 `%2B`/`%2F` 与 base64 的 busi_data） */
const QQ_GROUP_URL: string = 'https://qun.qq.com/universal-share/share?ac=1&authKey=d5vyZIDihejxMq67Ib9Ae05s1scbFNo4yvjkoNqcoGgnHOX0Lkf%2BabPN/bIEuAi1&busi_data=eyJncm91cENvZGUiOiI1MjY4MzY1NTUiLCJ0b2tlbiI6IlN0K0p0L3o1NWwwdEEvTEdKc0IvNXF5UGQrTDEvczUwbmxSNklXL0NGK0duWEJRVWhaeEFBVlMzTEN0anlHeUwiLCJ1aW4iOiIxNzMzODIyODc3In0=&data=uZnXBzbs3rpves1K30ISR1NR7hDg8V5OeQJ4wKxXtAklswbrdGD99qm8H5Sr-UW3FknXRZksOM8gssRqKN2leg&svctype=4&tempid=h5_group_info';

/**
 * ① 「让 QQ 自己打开官方邀请链接」的 Deep Link。
 *
 * `url_prefix` 是 **base64(UTF-8)** 的完整 URL —— 这是 QQ `forward/url` 的既有约定。
 * 证据：QQ 自己下发的插件数据里就有同款（2026-10-24 真机 hilog，`QQKMPPluginDataManager` 的 jumpUrl）：
 *   `mqqapi://forward/url?src_type=internal&plg_dev=0&plg_auth=1&version=1&style=home&url_prefix=aHR0cHM6…`
 *
 * 用**运行时编码**而不是写死 base64 串：`QQ_GROUP_URL` 一旦改动不会忘记同步
 * （写死过一次就必然踩：改了链接、忘了改 base64，表现为 QQ 打开一个 404 页）。
 */
function buildQqGroupScheme(): string {
  const prefix: string = new util.Base64Helper().encodeToStringSync(new util.TextEncoder().encodeInto(QQ_GROUP_URL));
  return `mqqapi://forward/url?src_type=internal&version=1&plg_auth=1&plg_dev=0&url_prefix=${prefix}`;
}

const QQ_GROUP_SCHEME: string = buildQqGroupScheme();

export class QqGroup {
  /**
   * 拉起加群（**不返回 Promise**，与原来 `MySetPage.openQqGroup()` 的调用形状一致，调用方不用 await）。
   *
   * @param ctx       调用方的 `UIAbilityContext`（页面里 `this.getUIContext().getHostContext()`）
   * @param onAllFailed ①② 都失败时回调（调用方负责提示"请手动搜索 QQ群：${QQ_GROUP_CODE}"）
   *
   * 全部失败只回调、不抛 —— 它只是个可选入口，绝不能影响宿主页面/弹窗。
   */
  static join(ctx: common.UIAbilityContext, onAllFailed: () => void): void {
    QqGroup.run(ctx, onAllFailed).catch((e: Error): void => {
      // run() 内部已兜住所有异常，这里只为杜绝 unhandled rejection
      hilog.warn(0x0000, TAG, `join unexpected: ${e.message}`);
      onAllFailed();
    });
  }

  /** ① → ② 顺序尝试；都失败才回调 `onAllFailed` */
  private static async run(ctx: common.UIAbilityContext, onAllFailed: () => void): Promise<void> {
    // ① 让 QQ 自己打开官方邀请链接
    try {
      await ctx.startAbility({ uri: QQ_GROUP_SCHEME });
      hilog.info(0x0000, TAG, 'qq forward/url ok');
      return;
    } catch (e) {
      const err = e as BusinessError;
      // 16000019 No matching ability（QQ 未安装）等 ⇒ 落到第 ② 级
      hilog.info(0x0000, TAG, `qq forward/url failed, code=${err.code}, try browser`);
    }
    // ② 浏览器兜底：打开 QQ 群邀请页；再失败则回调（群号兜底由调用方负责）
    try {
      await ctx.openLink(QQ_GROUP_URL);
      hilog.info(0x0000, TAG, 'qq openLink ok');
    } catch (e) {
      const err = e as BusinessError;
      hilog.warn(0x0000, TAG, `qq url failed, code=${err.code}`);
      onAllFailed();
    }
  }
}

export default QqGroup;
