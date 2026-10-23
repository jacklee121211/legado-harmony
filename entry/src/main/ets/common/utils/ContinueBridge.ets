/**
 * 应用接续（无缝流转）桥接层（2026-10-24 新增）。
 *
 * ── 官方能力边界（`devecocli docs` 取证）─────────────────────────────────────
 * documentId `最佳实践/跨端迁移/应用接续概述/bpta-continue-cast` 原文：
 * · 「在 module.json5 的 abilities 中，将 continuable 标签配置为 "true"，表示该
 *    UIAbility 可被迁移。默认值为 false」；
 * · 「**自 API12 起，无需申请 ohos.permission.DISTRIBUTED_DATASYNC 权限**」
 *   ⇒ 本功能**零权限**，只要 continuable + 同 BundleName（同 HAP ⇒ 不需要 AGC 接续服务）；
 * · 「在 onContinue 回调中使用 wantParam 传输的数据需要控制在 **100KB 以下**」；
 * · 「`restoreWindowStage` **必须在同步接口方法中执行**，如果在异步回调中执行，
 *    可能会导致应用迁移后页面加载失败」。
 *
 * documentId `最佳实践/跨端迁移/应用接续数据迁移/bpta-continue-data` 的选型矩阵：
 * |            | <100kb          | >100kb        |
 * | 需要文件迁移 | 文件资产迁移     | 文件资产迁移   |
 * | 不需文件迁移 | want.param 迁移 | 分布式对象迁移 |
 *
 * ── 我们走哪条（用户 2026-10-24 拍板）───────────────────────────────────────
 * 「有书情况下传数据，没书情况下书也需要带过去，其实是两种并行路线，一个轻量一个全量」
 * · **轻量（本期）**：只传进度 + 排版信息（`wantParam`，几百字节）；
 * · **全量（下一期）**：书文件进 `context.distributedFilesDir` → `Asset` → 塞进
 *   `distributedDataObject`，与进度一起走。对端「有书就只用数据、没书才读 Asset 落库」。
 *
 * ── 同步哪些东西（用户明确要求）─────────────────────────────────────────────
 * ✅ 带：**字体**、**背景**、**日/夜模式** —— 换设备后"信息一致"；
 * ❌ 不带：**字号**、**行距** —— 让每块屏幕按自己的尺寸排版，**布局不变**。
 *
 * ── 位置坐标为什么用 spineIndex + domPos ────────────────────────────────────
 * 页码/像素都不可迁移（手机平板屏幕不同、我们还有仿真/横滑/滚动三种翻页模式）。
 * `ReaderComponentController.startPlay(spineIndex, domPos)` 的 `domPos` 是字符级
 * DOM 锚点，与排版无关 ⇒ 跨设备、跨字号、跨翻页模式都能精确落点。
 * 这与工程既有做法完全一致（`ReaderPage3` 的 `localBookDurChapterPos` 就是
 * `PageDataInfo{resourceIndex, startDomPos}`，书签/进度全走这套）。
 */
import { Want, common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { PreferencesUtil } from '@pura/harmony-utils';

/** 一次接续要带过去的东西 */
export interface ContinuePayload {
  /** 书名（对端据此在 books 表里找书） */
  bookName: string;
  /** 书文件路径（书名可能重名，url 兜底比对） */
  bookUrl: string;
  /** 章节标题（仅用于对端提示/校验） */
  chapterTitle: string;
  /** 章节索引（= spineIndex） */
  spineIndex: number;
  /** 章节内字符级 DOM 锚点 */
  domPos: string;
  /** 字体族名（引擎侧 fontName） */
  fontName: string;
  /** 字体文件路径（沙箱/系统绝对路径） */
  fontPath: string;
  /** 日/夜：true = 夜间 */
  nightMode: boolean;
  /** 背景图/材质（ReaderSetting.themeBgImg 原样带） */
  themeBgImg: string;
  /** 本书自定义背景记录（JSON；超长则不带，避免撑破 100KB） */
  bgJson: string;
  /**
   * **全量路线**：源端已把书文件放进 `context.distributedFilesDir` 后的文件名
   * （不是绝对路径！对端要用**自己的** distributedFilesDir 拼，见
   * `ContinueBridge.targetBookPath()`）。空串 = 没暂存（书文件读不到/不需要）。
   */
  bookFileName: string;
}

const TAG: string = 'ContinueBridge';
const DOMAIN: number = 0x0000;

export class ContinueBridge {
  // ── AppStorage 键（统一 `CONTINUE_` 前缀，避免与其它模块撞车）──────────────
  /** 有待消费的接续数据（Index 订阅它来跳阅读页） */
  static readonly KEY_PENDING: string = 'CONTINUE_PENDING';
  /** 阅读页上报的"当前阅读态"（onContinue 时从这里取） */
  static readonly KEY_LIVE: string = 'CONTINUE_LIVE';

  /** wantParam 里我们自己用的键（**不能**和系统占用的 `version`/`targetDevice`/`sessionId` 撞） */
  private static readonly W_PREFIX: string = 'ljContinue';
  /** 背景 JSON 的体积上限（超过就不带，宁可少带也不能撑破 100KB） */
  private static readonly BG_JSON_MAX: number = 4000;

  /**
   * 阅读页调用：把"此刻读到哪儿"登记到 AppStorage。
   * 每次翻页/滚动都调，代价是一次 AppStorage 写入（微秒级），不做落盘。
   */
  static publish(p: ContinuePayload): void {
    if (p.bookName.length === 0) {
      return; // 空书名没有意义（也会污染后续比对）
    }
    AppStorage.setOrCreate(ContinueBridge.KEY_LIVE, JSON.stringify(p));
  }

  /** 离开阅读页 / 听书停止时清掉，避免"在书架上还能接续到一本已经退出的书" */
  static clear(): void {
    AppStorage.setOrCreate(ContinueBridge.KEY_LIVE, '');
  }

  /** 取当前阅读态（没有 / 不在阅读页 ⇒ null） */
  static live(): ContinuePayload | null {
    const raw: string = AppStorage.get<string>(ContinueBridge.KEY_LIVE) ?? '';
    return ContinueBridge.parse(raw);
  }

  /**
   * 源端：把阅读态灌进 `wantParam`。
   * @returns 是否同意接续（不在阅读页 ⇒ REJECT，交给 EntryAbility 直接用）
   */
  static fillWantParam(wantParam: Record<string, Object>): boolean {
    const p: ContinuePayload | null = ContinueBridge.live();
    if (p === null) {
      hilog.info(DOMAIN, TAG, 'fillWantParam: no live reading state, reject');
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
    hilog.info(DOMAIN, TAG,
      'fillWantParam: book=%{public}s spine=%{public}d domPos=%{public}s',
      p.bookName, p.spineIndex, p.domPos);
    return true;
  }

  /**
   * 对端：从 `want.parameters` 还原，并挂到 AppStorage 等 `Index` 消费。
   * @returns 是否成功识别为一次接续
   */
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
      bookFileName: ContinueBridge.str(params[pre + 'BookFile'])
    };
    AppStorage.setOrCreate(ContinueBridge.KEY_PENDING, JSON.stringify(p));
    hilog.info(DOMAIN, TAG,
      'restoreFromWant: book=%{public}s spine=%{public}d domPos=%{public}s',
      p.bookName, p.spineIndex, p.domPos);
    return true;
  }

  /** `Index` 消费一次（读走即清，避免重复跳转） */
  static consumePending(): ContinuePayload | null {
    const raw: string = AppStorage.get<string>(ContinueBridge.KEY_PENDING) ?? '';
    if (raw.length === 0) {
      return null;
    }
    AppStorage.setOrCreate(ContinueBridge.KEY_PENDING, '');
    return ContinueBridge.parse(raw);
  }

  /**
   * 对端：把带过来的**字体/背景/日夜间**写进本书的 ReaderSetting 持久位。
   *
   * 为什么不直接写内存：阅读页 `aboutToAppear` 会从
   * `ReaderSetting_${bookName}` 读初值，先落盘再进页面，等于"一进就是对的"，
   * 不需要额外的时序协调（字号/行距**刻意不动**，见文件头注释）。
   */
  static applyLayoutToBook(p: ContinuePayload, setting: Record<string, Object>): void {
    if (p.fontName.length > 0) {
      setting.fontName = p.fontName;
    }
    if (p.fontPath.length > 0) {
      setting.fontPath = p.fontPath;
    }
    setting.nightMode = p.nightMode;
    if (p.themeBgImg.length > 0) {
      setting.themeBgImg = p.themeBgImg;
    }
    hilog.info(DOMAIN, TAG,
      'applyLayoutToBook: font=%{public}s night=%{public}s', p.fontName, String(p.nightMode));
  }

  /** 背景记录落盘（超长/空则跳过） */
  static saveBgIfAny(p: ContinuePayload): void {
    if (p.bgJson.length === 0 || p.bgJson.length > ContinueBridge.BG_JSON_MAX) {
      return;
    }
    try {
      PreferencesUtil.putSync(`ReaderBgBook_${p.bookName}`, p.bgJson);
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'saveBgIfAny failed');
    }
  }

  // ══════════════════════════════════════════════════════════════════════════
  // 全量路线：书文件通过「分布式文件目录」过河（2026-10-24）
  //
  // ── 为什么不用官方示例的 distributedDataObject + Asset ──────────────────────
  // 官方《应用接续数据迁移》的「文件资产迁移」是：书 → `distributedFilesDir` →
  // 包成 `commonType.Asset` → 塞进 `distributedDataObject` → 对端在
  // `status === 'restored'` 回调里读。
  // 但那条链要维护 sessionId、组网、属性置空、回调时序，坑极多（官方自己也列了
  // 三条 ⚠️）。而我们**只需要文件到得了对端**，元数据走 wantParam 更简单可控：
  //   · 源端：书拷进 `context.distributedFilesDir`，把**文件名**塞进 wantParam；
  //   · 对端：用**自己的** `distributedFilesDir` 拼同名路径直接读。
  // `distributedFilesDir` 是同账号设备间的分布式目录（hmdfs 合并视图）⇒ 同一相对
  // 路径在对端可解析，省掉整条 DataObject 组网链，且 wantParam 依旧只有几百字节。
  // 若对端读不到（未开多设备协同/网络断）⇒ 回落"本机没有这本书"提示，不崩。
  // ══════════════════════════════════════════════════════════════════════════

  /** 暂存文件名前缀，便于清理与辨识 */
  private static readonly STAGE_PREFIX: string = 'ljcontinue_';

  /**
   * 源端：把书文件拷进分布式目录，返回**暂存文件名**（'' = 失败/无需）。
   *
   * ⚠️ 必须**同步**：`onContinue` 是同步回调，异步拷贝会在文件写完前就允许迁移。
   *    书是纯文本，几 MB 的同步拷贝在真机上约几十毫秒，可接受。
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
      const safe: string = ContinueBridge.STAGE_PREFIX
        + bookName.replace(/[\\/:*?"<>|]/g, '_') + ext;
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

  /**
   * 对端：把暂存文件名拼成**本机**分布式目录下的绝对路径。
   * 用本机 `distributedFilesDir` 而不是源端传过来的绝对路径 —— 两台设备的沙箱
   * 根不同，只有"同一相对位置"这个语义是对端可用的。
   */
  static targetBookPath(ctx: common.UIAbilityContext, fileName: string): string {
    if (fileName.length === 0) {
      return '';
    }
    return ctx.distributedFilesDir + '/' + fileName;
  }

  /** 对端读完/导入后清理暂存文件（失败无所谓，分布式目录会自己回收） */
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
        bookFileName: typeof p.bookFileName === 'string' ? p.bookFileName : ''
      };
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'parse payload failed');
      return null;
    }
  }
}
