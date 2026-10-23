/**
 * 应用接续（无缝流转）桥接层 —— 完整实现（2026-10-24 大修）。
 *
 * ══════════════════════════════════════════════════════════════════════════
 * 一、官方要求（全部来自 `devecocli docs` + SDK d.ts 取证，非经验判断）
 * ══════════════════════════════════════════════════════════════════════════
 * · `module.json5` → `abilities[].continuable: true`
 *   （documentId `最佳实践/跨端迁移/应用接续概述/bpta-continue-cast`）
 * · **API12 起无需任何权限**：同文档原文「自 API12 起，无需申请
 *   ohos.permission.DISTRIBUTED_DATASYNC 权限」；同 BundleName 也不需要 AGC 接续服务。
 * · 源端 `onContinue(wantParam)` 存数据 + 返回 `AGREE / REJECT`
 * · 对端 `onCreate` / `onNewWant` → 判 `LaunchReason.CONTINUATION` 恢复
 * · **接续拉起时框架调 `onWindowStageRestore()` 而非 `onWindowStageCreate()`**
 *   （SDK `@ohos.app.ability.UIAbility.d.ts:412-427` 原文 NOTE，冷/热启动都一样）
 * · **`setMissionContinueState(ACTIVE / INACTIVE)`** 控制接续可用性
 *   （SDK `AbilityConstant.ContinueState`：ACTIVE=0 / INACTIVE=1）。
 *   这是官方推荐的「只有某页可接续」实现 —— 不可接续时系统**不显示入口**，
 *   比"显示入口→用户点→再 REJECT"的体验好得多。
 * · `wantParam` < 100KB；系统保留键 `version` / `targetDevice` / `sessionId` 不可占用
 * · `context.restoreWindowStage(localStorage)` 必须在**主线程**调用
 *   （SDK `UIAbilityContext.d.ts`：「It can be called only on the main thread」）
 *
 * ══════════════════════════════════════════════════════════════════════════
 * 二、数据迁移选型（官方矩阵，documentId `bpta-continue-data`）
 * ══════════════════════════════════════════════════════════════════════════
 * |            | <100kb          | >100kb        |
 * | 需要文件迁移 | 文件资产迁移     | 文件资产迁移   |
 * | 不需文件迁移 | want.param 迁移 | 分布式对象迁移 |
 *
 * 我们的书是**沙箱本地文件** ⇒ 属于"需要文件迁移"。但官方示例的
 * `Asset + distributedDataObject` 链要维护 sessionId、组网、属性置空、回调时序
 * （官方自己列了 3 条 ⚠️）。我们只需要**文件到得了对端**，元数据走 wantParam 更可控：
 *   · 源端：书 → `context.distributedFilesDir`，只把**文件名**塞 wantParam；
 *   · 对端：用自己的 `distributedFilesDir` 拼同名路径直接读
 *     （hmdfs 合并视图，同相对路径跨设备可解析）。
 * ⇒ wantParam 恒为几百字节，完全规避 100KB 限制与组网复杂度。
 *
 * ══════════════════════════════════════════════════════════════════════════
 * 三、同步什么（用户 2026-10-24 拍板）
 * ══════════════════════════════════════════════════════════════════════════
 * ✅ **阅读进度**（spineIndex + 字符级 domPos）—— 不传页码/像素（屏幕尺寸、
 *    三种翻页模式都不同，页码不可迁移；`startPlay(spine, domPos)` 的 domPos 是
 *    与排版无关的 DOM 锚点）
 * ✅ **听书进度**（同一套 spine + domPos，由 `TtsEngine.currentSegment()` 换算）
 * ✅ **字体 / 背景 / 日夜间** —— 换设备后信息一致
 * ❌ **字号 / 行距** —— 每块屏幕按自己尺寸排版，**布局不变**
 * ❌ 对端不自动播放听书（用户点播放才播，符合常理）
 *
 * ══════════════════════════════════════════════════════════════════════════
 * 四、事故教训（勿重蹈）
 * ══════════════════════════════════════════════════════════════════════════
 * ⚠️ **绝不从外部改写别的模块的持久位**。曾经在 `Index` 里把
 *    `ReaderSetting_${bookName}` 用 `JSON.stringify` 覆盖，而那块存的是
 *    readerSetting **对象** ⇒ 读回来变字符串 ⇒ 引擎配置非法 ⇒ **进书黑屏且退出
 *    重进也黑**。现在排版信息一律**内存下发**（走 `ReaderRouteParam`）。
 * ⚠️ 背景落库必须走 `ReaderCustomBg.saveBook()`（键是 `ReaderBg_<书名>`，
 *    不是自造的 `ReaderBgBook_`，且要登记覆盖表，否则「同步全局」清不掉）。
 */
import { Want, common, AbilityConstant } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { ReaderCustomBg, ReaderBgRecord } from './ReaderCustomBg';

/** 一次接续要带过去的东西 */
export interface ContinuePayload {
  /** 书名（对端据此在 books 表里找书；本工程 bookName **含扩展名**） */
  bookName: string;
  /** 书文件路径（用于暂存与二次校验） */
  bookUrl: string;
  /** 章节标题（提示/校验用） */
  chapterTitle: string;
  /** 章节索引（= spineIndex） */
  spineIndex: number;
  /** 章节内字符级 DOM 锚点（与排版无关，跨设备可精确落点） */
  domPos: string;
  /** 字体族名 */
  fontName: string;
  /** 字体文件路径（沙箱/系统绝对路径） */
  fontPath: string;
  /** 日/夜：true = 夜间 */
  nightMode: boolean;
  /** 背景图/材质（ReaderSetting.themeBgImg） */
  themeBgImg: string;
  /** 本书自定义背景记录（JSON；超长不带，防撑破 100KB） */
  bgJson: string;
  /** 源端暂存在分布式目录里的书文件名（'' = 未暂存） */
  bookFileName: string;
  /** true = 源端当时处于**听书**状态（仅用于日志与后续策略，对端一律不自动播） */
  listenMode: boolean;
}

const TAG: string = 'ContinueBridge';
const DOMAIN: number = 0x0000;

export class ContinueBridge {
  // ── AppStorage 键（统一 CONTINUE_ 前缀）──────────────────────────────────
  /** 待消费的接续数据（Index 订阅） */
  static readonly KEY_PENDING: string = 'CONTINUE_PENDING';
  /** 源端"当前阅读/听书态"（onContinue 从这里取） */
  static readonly KEY_LIVE: string = 'CONTINUE_LIVE';
  /**
   * 源端"当前是否处于可接续页面"（阅读页/听书态）。
   * 这是 `onContinue` 的**最后一道防线** —— 即使 `setMissionContinueState`
   * 因为某些设备差异没生效，也不会把书架上的一次误触当成接续发出去。
   */
  static readonly KEY_ACTIVE: string = 'CONTINUE_READER_ACTIVE';

  /** wantParam 自定义键前缀（避开系统保留键 version/targetDevice/sessionId） */
  private static readonly W_PREFIX: string = 'ljContinue';
  /** 背景 JSON 体积上限（超过就不带） */
  private static readonly BG_JSON_MAX: number = 4000;
  /** 暂存文件名前缀 */
  private static readonly STAGE_PREFIX: string = 'ljcontinue_';

  // ══════════════════════════════════════════════════════════════════════════
  // 接续可用性开关（官方 setMissionContinueState）
  // ══════════════════════════════════════════════════════════════════════════

  /**
   * 声明"本应用此刻是否允许被接续"。
   *
   * 官方做法：进入可接续页面（阅读页/听书）调 `ACTIVE`，离开调 `INACTIVE`。
   * 这样系统层面就**不显示**接续入口，而不是等用户点了再拒绝。
   *
   * ⚠️ 必须在**主线程**调用（ArkUI 页面生命周期天然满足）。
   * ⚠️ `setMissionContinueState` 在部分设备（如不支持分布式业务的 Wearable）不生效，
   *   所以 `onContinue` 里仍保留 `KEY_ACTIVE` 兜底判断。
   */
  static setMissionActive(ctx: common.UIAbilityContext | null, active: boolean): void {
    AppStorage.setOrCreate(ContinueBridge.KEY_ACTIVE, active);
    if (ctx === null) {
      return;
    }
    const state: AbilityConstant.ContinueState = active
      ? AbilityConstant.ContinueState.ACTIVE
      : AbilityConstant.ContinueState.INACTIVE;
    try {
      ctx.setMissionContinueState(state).then(() => {
        hilog.info(DOMAIN, TAG, 'setMissionContinueState: %{public}s', String(active));
      }).catch((e: Object) => {
        hilog.warn(DOMAIN, TAG, 'setMissionContinueState failed: %{public}s',
          e instanceof Error ? e.message : String(e));
      });
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'setMissionContinueState throw: %{public}s',
        e instanceof Error ? e.message : String(e));
    }
  }

  /** 当前是否处于可接续页面 */
  static isActive(): boolean {
    return AppStorage.get<boolean>(ContinueBridge.KEY_ACTIVE) === true;
  }

  // ══════════════════════════════════════════════════════════════════════════
  // 源端：登记当前阅读态
  // ══════════════════════════════════════════════════════════════════════════

  /**
   * 阅读页/听书每次进度变化时调用：把"此刻读到哪儿"登记进 AppStorage。
   * 一次 AppStorage 写入（微秒级），不落盘。
   */
  static publish(p: ContinuePayload): void {
    if (p.bookName.length === 0) {
      return; // 空书名没有意义（也会污染后续比对）
    }
    AppStorage.setOrCreate(ContinueBridge.KEY_LIVE, JSON.stringify(p));
  }

  /**
   * 离开阅读页时调用。
   *
   * ⚠️ 2026-10-24 修正：**不删阅读态**，只把"可接续"关掉。
   *   旧实现在 `aboutToDisappear` 里 `clear()`，导致「读到某处 → 退出到书架 →
   *   立刻接续」这条路直接 REJECT；而 AppStorage 里留一份几百字节的快照毫无代价，
   *   真正的门禁应该是 `setMissionContinueState(INACTIVE)`。
   */
  static leaveReader(ctx: common.UIAbilityContext | null): void {
    ContinueBridge.setMissionActive(ctx, false);
  }

  /** 取当前阅读态（没有 ⇒ null） */
  static live(): ContinuePayload | null {
    const raw: string = AppStorage.get<string>(ContinueBridge.KEY_LIVE) ?? '';
    return ContinueBridge.parse(raw);
  }

  /**
   * 源端：把阅读态灌进 `wantParam`。
   * @returns 是否同意接续（false ⇒ 调用方返回 REJECT）
   */
  static fillWantParam(wantParam: Record<string, Object>): boolean {
    const p: ContinuePayload | null = ContinueBridge.live();
    if (p === null || !ContinueBridge.isActive()) {
      hilog.info(DOMAIN, TAG, 'fillWantParam: reject (live=%{public}s active=%{public}s)',
        String(p !== null), String(ContinueBridge.isActive()));
      return false;
    }
    const pre: string = ContinueBridge.W_PREFIX;
    wantParam[pre + 'BookName'] = p.bookName;
    wantParam[pre + 'BookUrl'] = p.bookUrl;
    wantParam[pre + 'ChapterTitle'] = p.chapterTitle;
    wantParam[pre + 'Spine'] = p.spineIndex;
    wantParam[pre + 'DomPos'] = p.domPos;
    wantParam[pre + 'FontName'] = p.fontName;
    wantParam[pre + 'FontPath'] = p.fontPath;
    wantParam[pre + 'NightMode'] = p.nightMode;
    wantParam[pre + 'ThemeBgImg'] = p.themeBgImg;
    wantParam[pre + 'BgJson'] = p.bgJson;
    wantParam[pre + 'BookFile'] = p.bookFileName;
    wantParam[pre + 'Listen'] = p.listenMode;
    hilog.info(DOMAIN, TAG,
      'fillWantParam: book=%{public}s spine=%{public}d domPos=%{public}s listen=%{public}s',
      p.bookName, p.spineIndex, p.domPos, String(p.listenMode));
    return true;
  }

  // ══════════════════════════════════════════════════════════════════════════
  // 对端：恢复
  // ══════════════════════════════════════════════════════════════════════════

  /** 从 `want.parameters` 还原并挂到 AppStorage 等 Index 消费 */
  static restoreFromWant(want: Want): boolean {
    const params: Record<string, Object> | undefined = want.parameters;
    if (params === undefined || params === null) {
      return false;
    }
    const pre: string = ContinueBridge.W_PREFIX;
    const bookName: string = ContinueBridge.str(params[pre + 'BookName']);
    if (bookName.length === 0) {
      hilog.info(DOMAIN, TAG, 'restoreFromWant: not a continuation want');
      return false;
    }
    const p: ContinuePayload = {
      bookName: bookName,
      bookUrl: ContinueBridge.str(params[pre + 'BookUrl']),
      chapterTitle: ContinueBridge.str(params[pre + 'ChapterTitle']),
      spineIndex: ContinueBridge.num(params[pre + 'Spine']),
      domPos: ContinueBridge.str(params[pre + 'DomPos']),
      fontName: ContinueBridge.str(params[pre + 'FontName']),
      fontPath: ContinueBridge.str(params[pre + 'FontPath']),
      nightMode: ContinueBridge.bool(params[pre + 'NightMode']),
      themeBgImg: ContinueBridge.str(params[pre + 'ThemeBgImg']),
      bgJson: ContinueBridge.str(params[pre + 'BgJson']),
      bookFileName: ContinueBridge.str(params[pre + 'BookFile']),
      listenMode: ContinueBridge.bool(params[pre + 'Listen'])
    };
    AppStorage.setOrCreate(ContinueBridge.KEY_PENDING, JSON.stringify(p));
    hilog.info(DOMAIN, TAG,
      'restoreFromWant: book=%{public}s spine=%{public}d domPos=%{public}s file=%{public}s listen=%{public}s',
      p.bookName, p.spineIndex, p.domPos, p.bookFileName, String(p.listenMode));
    return true;
  }

  /** Index 消费一次（读走即清，避免重复跳转） */
  static consumePending(): ContinuePayload | null {
    const raw: string = AppStorage.get<string>(ContinueBridge.KEY_PENDING) ?? '';
    if (raw.length === 0) {
      return null;
    }
    AppStorage.setOrCreate(ContinueBridge.KEY_PENDING, '');
    return ContinueBridge.parse(raw);
  }

  // ══════════════════════════════════════════════════════════════════════════
  // 全量路线：书文件过河（分布式文件目录）
  // ══════════════════════════════════════════════════════════════════════════

  /**
   * 源端：把书文件拷进分布式目录，返回**暂存文件名**（'' = 失败/无需）。
   * ⚠️ 必须同步：`onContinue` 是同步回调，异步拷贝会在文件写完前就放行迁移。
   */
  static stageBookFile(ctx: common.UIAbilityContext, bookUrl: string, bookName: string): string {
    if (bookUrl.length === 0) {
      return '';
    }
    try {
      if (!fs.accessSync(bookUrl)) {
        hilog.warn(DOMAIN, TAG, 'stageBookFile: source not found %{public}s', bookUrl);
        return '';
      }
      const dir: string = ctx.distributedFilesDir;
      if (!fs.accessSync(dir)) {
        fs.mkdirSync(dir, true);
      }
      // 保留原扩展名（引擎靠扩展名判格式：.txt/.epub/.pdf…）
      let ext: string = '';
      const dot: number = bookUrl.lastIndexOf('.');
      if (dot > 0) {
        ext = bookUrl.substring(dot);
      }
      // ⚠️ bookName 在本工程里**含扩展名**（如 `步步生莲.txt`），
      //   直接拼 ext 会产出 `ljcontinue_步步生莲.txt.txt`（真机日志实证）。
      let base: string = bookName;
      const dotN: number = base.lastIndexOf('.');
      if (dotN > 0) {
        base = base.substring(0, dotN);
      }
      const safe: string = ContinueBridge.STAGE_PREFIX
        + base.replace(/[\\/:*?"<>|]/g, '_') + ext;
      const dst: string = dir + '/' + safe;
      fs.copyFileSync(bookUrl, dst);
      hilog.info(DOMAIN, TAG, 'stageBookFile: ok %{public}s -> %{public}s', bookUrl, dst);
      return safe;
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'stageBookFile failed: %{public}s',
        e instanceof Error ? e.message : String(e));
      return '';
    }
  }

  /** 对端：把暂存文件名拼成**本机**分布式目录下的绝对路径 */
  static targetBookPath(ctx: common.UIAbilityContext, fileName: string): string {
    if (fileName.length === 0) {
      return '';
    }
    return ctx.distributedFilesDir + '/' + fileName;
  }

  /** 对端读完/导入后清理暂存文件 */
  static clearStagedFile(ctx: common.UIAbilityContext, fileName: string): void {
    if (fileName.length === 0) {
      return;
    }
    try {
      const p: string = ContinueBridge.targetBookPath(ctx, fileName);
      if (fs.accessSync(p)) {
        fs.unlinkSync(p);
      }
    } catch (e) {
      // 清不掉不影响主流程
    }
  }

  /**
   * 对端：把带过来的**背景记录**落库。
   *
   * ⚠️ 必须走 `ReaderCustomBg.saveBook()`：
   *   · 键是 `ReaderBg_<书名>`（`ReaderCustomBg.KEY_PREFIX`），
   *     不是自造的 `ReaderBgBook_`（旧实现的 bug，写了也用不上）；
   *   · 它内部还会把书名登记进 `ReaderBgOverrides` 覆盖表 ——
   *     否则「同步全局」清场时清不掉这条。
   */
  static saveBgIfAny(p: ContinuePayload): void {
    if (p.bgJson.length === 0 || p.bgJson.length > ContinueBridge.BG_JSON_MAX) {
      return;
    }
    try {
      const rec = JSON.parse(p.bgJson) as ReaderBgRecord;
      if (rec === null || rec === undefined) {
        return;
      }
      ReaderCustomBg.saveBook(p.bookName, rec);
      hilog.info(DOMAIN, TAG, 'saveBgIfAny: ok for %{public}s', p.bookName);
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'saveBgIfAny failed: %{public}s',
        e instanceof Error ? e.message : String(e));
    }
  }

  // ── 小工具（wantParam 的值是 Object，必须逐类型收敛）────────────────────
  private static str(v: Object | undefined): string {
    if (v === undefined || v === null) {
      return '';
    }
    return typeof v === 'string' ? v as string : String(v);
  }

  private static num(v: Object | undefined): number {
    if (v === undefined || v === null) {
      return 0;
    }
    if (typeof v === 'number') {
      return v as number;
    }
    const n: number = Number(v as string);
    return Number.isFinite(n) ? n : 0;
  }

  private static bool(v: Object | undefined): boolean {
    if (v === undefined || v === null) {
      return false;
    }
    if (typeof v === 'boolean') {
      return v as boolean;
    }
    return String(v) === 'true';
  }

  private static parse(raw: string): ContinuePayload | null {
    if (raw.length === 0) {
      return null;
    }
    try {
      const p = JSON.parse(raw) as ContinuePayload;
      if (p === null || p === undefined || typeof p.bookName !== 'string'
        || p.bookName.length === 0) {
        return null;
      }
      return {
        bookName: p.bookName,
        bookUrl: typeof p.bookUrl === 'string' ? p.bookUrl : '',
        chapterTitle: typeof p.chapterTitle === 'string' ? p.chapterTitle : '',
        spineIndex: typeof p.spineIndex === 'number' ? p.spineIndex : 0,
        domPos: typeof p.domPos === 'string' ? p.domPos : '',
        fontName: typeof p.fontName === 'string' ? p.fontName : '',
        fontPath: typeof p.fontPath === 'string' ? p.fontPath : '',
        nightMode: p.nightMode === true,
        themeBgImg: typeof p.themeBgImg === 'string' ? p.themeBgImg : '',
        bgJson: typeof p.bgJson === 'string' ? p.bgJson : '',
        bookFileName: typeof p.bookFileName === 'string' ? p.bookFileName : '',
        listenMode: p.listenMode === true
      };
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'parse payload failed');
      return null;
    }
  }
}
