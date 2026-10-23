/**
 * 应用接续（无缝流转）桥接层 —— 完整实现（2026-10-24 第二次大修）。
 *
 * ══════════════════════════════════════════════════════════════════════════
 * 一、官方要求（全部来自 `devecocli docs` + SDK d.ts 取证）
 * ══════════════════════════════════════════════════════════════════════════
 * · `abilities[].continuable: true`
 * · **API12 起无需任何权限**（同 BundleName 也不需要 AGC 接续服务）
 * · 源端 `onContinue(wantParam)` + `AGREE/REJECT`；API12 起支持 **async** 版本
 * · 对端 `onCreate`/`onNewWant` → `LaunchReason.CONTINUATION`
 * · **接续拉起时框架调 `onWindowStageRestore()` 而非 `onWindowStageCreate()`**
 *   （SDK `UIAbility.d.ts:412-427` NOTE，冷/热启动都一样）
 * · `setMissionContinueState(ACTIVE/INACTIVE)` 控制接续入口是否显示
 * · `context.restoreWindowStage(localStorage)` 必须主线程调用
 * · wantParam 系统保留键：`version` / `targetDevice` / `sessionId`（不可占用）
 *
 * ══════════════════════════════════════════════════════════════════════════
 * 二、书文件怎么过河 —— **必须走分布式数据对象 + Asset**（本次修正的关键）
 * ══════════════════════════════════════════════════════════════════════════
 * ❌ 曾经的错误实现：把书拷进 `context.distributedFilesDir`，对端用同一路径读。
 *    真机日志实证（`docs/日志.md` 21:39:32 / 21:39:45）：
 *      源端 `stageBookFile: ok ... -> /data/storage/el2/distributedfiles/ljcontinue_步步生莲.txt`
 *      对端 `staged path=... exists=false`      ← 同一路径在对端根本不存在
 *    ⇒ `distributedFilesDir` **不是跨设备共享盘**，文件不会自己跑过去。
 *
 * ✅ 官方正确机制（documentId `data-sync-of-distributed-data-object` 原文）：
 *    「**资产同步机制**：在分布式数据对象中，可以使用资产类型 `Asset` 来描述本地
 *      实体资产文件，分布式数据对象跨设备同步时，**该文件会和数据一起同步到其他
 *      设备上**。」
 *    「分布式数据对象加入 session 时，如果它的数据与 session 中的数据不同，则它会
 *      更新 session 中的数据。如果希望加入时得到 session 中的数据，需要将对象的
 *      属性的值设置为 **undefined**（资产类型的属性则是将它的各个属性值设置为
 *      **空字符串**）。」
 *    「对端加入组网的分布式数据对象**不能为临时变量**（on 是异步回调，可能在
 *      onCreate 结束后才执行，临时变量被释放会空指针）。」
 *    「分布式数据对象需要**先激活（setSessionId）再持久化（save）**。」
 *    「跨端迁移场景下，每个分布式数据对象大小不超过 **150KB**」
 *      ⇒ 所以**元数据走 wantParam**（几百字节），对象里只放 Asset 一个根属性。
 *
 * 完整链路：
 *   源端：书 → distributedFilesDir → `commonType.Asset` → create DataObject
 *         → genSessionId → setSessionId → **await save()** → sessionId 塞 wantParam
 *   对端：create 空 DataObject（Asset 各字段空串）→ **先 on('status')** → setSessionId
 *         → 收到 `restored` → 读出 Asset → 拷进自己 filesDir → 交给导入管线
 *
 * ══════════════════════════════════════════════════════════════════════════
 * 三、同步什么（用户 2026-10-24 逐条拍板）
 * ══════════════════════════════════════════════════════════════════════════
 * ✅ **进度**：`spineIndex + domPos` 主坐标，外加 `nodeIndex + charOffset` 备用坐标
 *    （domPos 若被引擎忽略/格式异常，对端用自己重算的 `domPosFor(node,char)` 兜底）
 * ✅ **排版**：`fontName / fontPath / fontWeight / fontColor / themeColor /
 *    themeBgImg / nightMode / flipMode` + 本书背景记录（含模糊）
 *    —— 用户原话：「除了字号和行距，都需要接续」
 * ❌ **字号 `fontSize` / 行距 `lineHeight`** —— 屏幕比例不同，真正影响体验的只有这两个
 * ❌ **`scaledDensity / viewPortWidth / viewPortHeight`** —— 设备度量，绝不能跨设备带
 * ❌ 听书：对端**不理会**，用户要听自己点（用户原话）
 * ❌ 对端字号行距：**完全不碰**，没设置过就用它自己的默认（用户原话）
 *
 * ══════════════════════════════════════════════════════════════════════════
 * 四、进度定位为什么用字符锚点而不是页码/百分比
 * ══════════════════════════════════════════════════════════════════════════
 * 三套翻页模式（仿真/横滑由引擎分页、滚动走像素）+ 两端屏幕尺寸与字号不同
 * ⇒ 页码、像素、章节内百分比全部不可迁移（百分比还会因每页字数不同而指向不同句子）。
 * `ReaderComponentController.startPlay(spineIndex, domPos)` 的 `domPos` 是
 * **与排版解耦的 DOM 位置**（`ReaderPage3.domPosFor(node,char)` =
 * `${2*node+1}=0#${char};@;0`），对端按自己的排版重新分页后，把包含该位置的页
 * 推出来 ⇒ 精度到"块内字符"，跨设备/跨字号/跨翻页模式都成立。
 *
 * ══════════════════════════════════════════════════════════════════════════
 * 五、事故教训（勿重蹈）
 * ══════════════════════════════════════════════════════════════════════════
 * ⚠️ 绝不从外部改写别的模块的持久位：曾把 `ReaderSetting_${bookName}` 写成 JSON
 *    字符串（那块存的是 readerSetting **对象**）⇒ 读回来类型错 ⇒ **进书黑屏且
 *    退出重进也黑**。排版信息一律**内存下发**（走 `ReaderRouteParam`）。
 * ⚠️ 背景落库必须走 `ReaderCustomBg.saveBook()`（键 `ReaderBg_<书名>` + 登记覆盖表）。
 */
import { Want, common, AbilityConstant } from '@kit.AbilityKit';
import { fileIo as fs, fileUri } from '@kit.CoreFileKit';
import { distributedDataObject, commonType } from '@kit.ArkData';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { ReaderCustomBg, ReaderBgRecord } from './ReaderCustomBg';

/** 一次接续要带过去的东西（元数据走 wantParam） */
export interface ContinuePayload {
  /** 书名（本工程 bookName **含扩展名**） */
  bookName: string;
  /** 书文件路径（源端沙箱路径；对端用于二次校验） */
  bookUrl: string;
  /** 章节标题（提示用） */
  chapterTitle: string;
  /** 章节索引（= spineIndex） */
  spineIndex: number;
  /** 主坐标：字符级 DOM 锚点 */
  domPos: string;
  /** 备用坐标：块节点下标（0 基） */
  nodeIndex: number;
  /** 备用坐标：节点内字符偏移 */
  charOffset: number;
  /** 字体族名 */
  fontName: string;
  /** 字体文件路径 */
  fontPath: string;
  /** 字重（加粗） */
  fontWeight: number;
  /** 字色 */
  fontColor: string;
  /** 主题色 */
  themeColor: string;
  /** 背景图/材质 */
  themeBgImg: string;
  /** 日/夜：true = 夜间 */
  nightMode: boolean;
  /** 翻页模式（仿真/横滑/滚动） */
  flipMode: string;
  /** 本书自定义背景记录 JSON（含模糊参数；超长不带） */
  bgJson: string;
  /** 分布式数据对象 sessionId（书文件靠它过河） */
  sessionId: string;
  /** true = 源端当时在听书（仅日志/后续策略；对端不自动播） */
  listenMode: boolean;
}

/**
 * 分布式数据对象的形状。
 * ⚠️ 只有一个根属性 `bookAsset` —— 官方限制「跨端迁移场景下每个分布式数据对象
 *    不超过 150KB」，元数据一律走 wantParam，对象里只放资产引用。
 */
interface ContinueDataObject {
  bookAsset: commonType.Asset;
}

const TAG: string = 'ContinueBridge';
const DOMAIN: number = 0x0000;

export class ContinueBridge {
  // ── AppStorage 键（统一 CONTINUE_ 前缀）──────────────────────────────────
  /** 待消费的接续数据（Index 订阅） */
  static readonly KEY_PENDING: string = 'CONTINUE_PENDING';
  /** 源端"当前阅读/听书态"（onContinue 从这里取） */
  static readonly KEY_LIVE: string = 'CONTINUE_LIVE';
  /** 源端"当前是否处于可接续页面"（onContinue 的最后一道防线） */
  static readonly KEY_ACTIVE: string = 'CONTINUE_READER_ACTIVE';
  /** 对端：Asset 已就绪后的**本机**文件路径（Index 轮询它） */
  static readonly KEY_ASSET_PATH: string = 'CONTINUE_ASSET_PATH';

  /** wantParam 自定义键前缀（避开系统保留键 version/targetDevice/sessionId） */
  private static readonly W_PREFIX: string = 'ljContinue';
  /** 背景 JSON 体积上限 */
  private static readonly BG_JSON_MAX: number = 4000;
  /** 暂存文件名前缀 */
  private static readonly STAGE_PREFIX: string = 'ljcontinue_';

  /**
   * 源端持有的分布式数据对象。
   * ⚠️ 必须是类成员（官方：不能是临时变量，异步回调可能在作用域结束后才触发）。
   */
  private static srcObject: distributedDataObject.DataObject | null = null;
  /** 对端持有的分布式数据对象（同上，必须常驻） */
  private static dstObject: distributedDataObject.DataObject | null = null;

  // ══════════════════════════════════════════════════════════════════════════
  // 接续可用性开关（官方 setMissionContinueState）
  // ══════════════════════════════════════════════════════════════════════════

  /**
   * 声明"本应用此刻是否允许被接续"。
   * 进入阅读页/听书 → ACTIVE；离开 → INACTIVE。系统层面直接不显示入口。
   * ⚠️ 部分设备（如不支持分布式业务的 Wearable）该接口不生效 ⇒ onContinue 里仍有
   *    `isActive()` 兜底。
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
        // 接续过程中 scb 可能已断（真机日志 `AMC1558 scb call ... err`），属预期，不阻断
        hilog.warn(DOMAIN, TAG, 'setMissionContinueState failed: %{public}s',
          e instanceof Error ? e.message : String(e));
      });
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'setMissionContinueState throw: %{public}s',
        e instanceof Error ? e.message : String(e));
    }
  }

  static isActive(): boolean {
    return AppStorage.get<boolean>(ContinueBridge.KEY_ACTIVE) === true;
  }

  // ══════════════════════════════════════════════════════════════════════════
  // 源端：登记当前阅读态
  // ══════════════════════════════════════════════════════════════════════════

  static publish(p: ContinuePayload): void {
    if (p.bookName.length === 0) {
      return;
    }
    AppStorage.setOrCreate(ContinueBridge.KEY_LIVE, JSON.stringify(p));
  }

  /**
   * 离开阅读页：只关"可接续"开关，**不删阅读态**。
   * 旧实现在这里 clear() 会让「读到某处 → 退回书架 → 立刻接续」直接 REJECT；
   * 留一份几百字节的 AppStorage 快照毫无代价，真正的门禁是 mission state。
   */
  static leaveReader(ctx: common.UIAbilityContext | null): void {
    ContinueBridge.setMissionActive(ctx, false);
  }

  static live(): ContinuePayload | null {
    const raw: string = AppStorage.get<string>(ContinueBridge.KEY_LIVE) ?? '';
    return ContinueBridge.parse(raw);
  }

  /** 源端：把阅读态灌进 `wantParam`（不含 sessionId，那个由 createSession 补） */
  static fillWantParam(wantParam: Record<string, Object>): ContinuePayload | null {
    const p: ContinuePayload | null = ContinueBridge.live();
    if (p === null || !ContinueBridge.isActive()) {
      hilog.info(DOMAIN, TAG, 'fillWantParam: reject (live=%{public}s active=%{public}s)',
        String(p !== null), String(ContinueBridge.isActive()));
      return null;
    }
    const pre: string = ContinueBridge.W_PREFIX;
    wantParam[pre + 'BookName'] = p.bookName;
    wantParam[pre + 'BookUrl'] = p.bookUrl;
    wantParam[pre + 'ChapterTitle'] = p.chapterTitle;
    wantParam[pre + 'Spine'] = p.spineIndex;
    wantParam[pre + 'DomPos'] = p.domPos;
    wantParam[pre + 'Node'] = p.nodeIndex;
    wantParam[pre + 'Char'] = p.charOffset;
    wantParam[pre + 'FontName'] = p.fontName;
    wantParam[pre + 'FontPath'] = p.fontPath;
    wantParam[pre + 'FontWeight'] = p.fontWeight;
    wantParam[pre + 'FontColor'] = p.fontColor;
    wantParam[pre + 'ThemeColor'] = p.themeColor;
    wantParam[pre + 'ThemeBgImg'] = p.themeBgImg;
    wantParam[pre + 'NightMode'] = p.nightMode;
    wantParam[pre + 'FlipMode'] = p.flipMode;
    wantParam[pre + 'BgJson'] = p.bgJson;
    wantParam[pre + 'Listen'] = p.listenMode;
    hilog.info(DOMAIN, TAG,
      'fillWantParam: book=%{public}s spine=%{public}d node=%{public}d char=%{public}d domPos=%{public}s listen=%{public}s',
      p.bookName, p.spineIndex, p.nodeIndex, p.charOffset, p.domPos, String(p.listenMode));
    return p;
  }

  // ══════════════════════════════════════════════════════════════════════════
  // 源端：书文件 → Asset → 分布式数据对象 → sessionId
  // ══════════════════════════════════════════════════════════════════════════

  /**
   * 把书文件拷进 `distributedFilesDir` 并构造 `commonType.Asset`。
   * @returns Asset；失败 undefined（调用方仍可只传元数据，对端会提示缺书）
   */
  static buildAsset(ctx: common.UIAbilityContext, bookUrl: string, bookName: string): commonType.Asset | undefined {
    if (bookUrl.length === 0) {
      return undefined;
    }
    try {
      if (!fs.accessSync(bookUrl)) {
        hilog.warn(DOMAIN, TAG, 'buildAsset: source not found %{public}s', bookUrl);
        return undefined;
      }
      const dir: string = ctx.distributedFilesDir;
      if (!fs.accessSync(dir)) {
        fs.mkdirSync(dir, true);
      }
      // ⚠️⚠️ 2026-10-23 关键修正（真机日志定案）：**不能给暂存文件加前缀**。
      //
      // 事故（`docs/日志.md` 23:45:19）：
      //   `onAssetRestored: name=ljcontinue_神墓.txt ... size=5950220`   ← 文件到了
      //   `importContinueBook: CopyFile ok=true`                          ← 导入成功
      //   `importContinueBook: relookup hits=0`                           ← 但查不到
      // 根因：`FileHandler.CopyFile()`（FileHandler.ets:69）用
      //   `dstPath = filesDir + '/' + file.name` 当目标名 ⇒ 加了 `ljcontinue_` 前缀后，
      //   书在 B 端被存成 `ljcontinue_神墓.txt`、入库名也是它 ⇒ 与源端 `神墓.txt`
      //   对不上 ⇒ `isExistBooks(url,name)` 命中 0 ⇒ 兜底 `getLastReadBook()` 拿了
      //   别的书 ⇒ 弹「没有这本书」。
      // 修法：暂存文件**直接用书名本身**（本工程 bookName 已含扩展名），
      //   这样 CopyFile 落地后文件名/书名/路径与源端完全一致。
      const safe: string = bookName.replace(/[\\/:*?"<>|]/g, '_');
      const dst: string = dir + '/' + safe;
      fs.copyFileSync(bookUrl, dst);
      const st = fs.statSync(dst);
      const asset: commonType.Asset = {
        name: safe,
        uri: fileUri.getUriFromPath(dst),
        path: dst,
        createTime: String(st.ctime),
        modifyTime: String(st.mtime),
        size: String(st.size)
      };
      hilog.info(DOMAIN, TAG, 'buildAsset: ok %{public}s (size=%{public}s)', dst, asset.size);
      return asset;
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'buildAsset failed: %{public}s',
        e instanceof Error ? e.message : String(e));
      return undefined;
    }
  }

  /**
   * 源端：创建分布式数据对象并**持久化到对端设备**，返回 sessionId（'' = 失败）。
   *
   * ── 官方要求（documentId `最佳实践/跨端迁移/应用接续数据迁移/bpta-continue-data`）──
   * 「① 在 onContinue() 中使用 create() 创建分布式数据对象，把要迁移的数据填充进去；
   *   ② genSessionId() 生成组网 id，setSessionId() 激活；
   *   ③ 使用 **save()** 接口将已激活的分布式数据对象**持久化，确保源端退出后
   *      对端依然可以获取到数据**；
   *   ④ 将 sessionId 通过 want 传给对端。」
   * 「必须先 setSessionId 再 save。」
   * 「源端迁移后要退出的应用，应 **await** save() 执行完毕（API12 起 onContinue 有 async 版本）。」
   *
   * ── ⚠️⚠️ save() 的参数是对端 deviceId，不是 'local'（真机日志定案）──────────
   * 官方示例原文（同文档「基础数据迁移 · 源端保存迁移数据」）：
   *   `await this.distributedObject.save(wantParam.targetDevice as string)`
   * SDK `@ohos.data.distributedDataObject.d.ts`：
   *   `save(deviceId: string)` —
   *   「ID of the device where the data is **saved**. The default value is `local`」
   *
   * 真机事故（`docs/日志.md` 23:39:22）：传 `'local'` 时——
   *   A端 `createSession: ok sessionId=3670086053`（本地建成功）
   *   B端 `joinSession: setSessionId ok 3670086053`（也加入成功）
   *   B端 **再无任何 `dstObject status=` 事件**，9 秒后 `importContinueBook: asset timeout`
   * 原因：数据只持久化在 A 本机；A 接续后退出 ⇒ 组网里没有数据 ⇒ B 永远等不到 restored。
   * ⇒ 必须传 `targetDevice`（系统在 onContinue 的 wantParam 里预置的对端 networkId），
   *   数据才会落到 B，A 退出后 B 仍可恢复 —— 这才是官方那句"确保源端退出后对端依然
   *   可以获取到数据"的真实含义。
   *
   * @param targetDevice 对端 networkId（来自 `wantParam.targetDevice`）
   */
  static async createSession(ctx: common.UIAbilityContext,
    asset: commonType.Asset | undefined, targetDevice: string): Promise<string> {
    if (asset === undefined) {
      return '';
    }
    if (targetDevice.length === 0) {
      // 拿不到对端 deviceId 就**不能**用 'local' 硬顶（那等于没传，A 退出即丢）
      hilog.error(DOMAIN, TAG, 'createSession: targetDevice empty, cannot persist to peer');
      return '';
    }
    try {
      const source: ContinueDataObject = { bookAsset: asset };
      const sessionId: string = distributedDataObject.genSessionId();
      const obj = distributedDataObject.create(ctx, source);
      ContinueBridge.srcObject = obj;
      obj.setSessionId(sessionId);
      // 官方：save(对端 deviceId) —— 持久化到对端，确保 A 退出后 B 仍能恢复
      await obj.save(targetDevice);
      hilog.info(DOMAIN, TAG, 'createSession: ok sessionId=%{public}s target=%{public}s',
        sessionId, targetDevice);
      return sessionId;
    } catch (e) {
      // ⚠️ 不要用 String(e)：BusinessError 不是 Error 实例，String() 只会得到
      //   `[object Object]`（真机日志就是这么把 401 参数错误吞掉的）。
      const be = e as BusinessError;
      const code: string = (be !== undefined && be !== null && be.code !== undefined)
        ? String(be.code) : '?';
      const msg: string = (be !== undefined && be !== null && be.message !== undefined)
        ? String(be.message) : String(e);
      hilog.error(DOMAIN, TAG, 'createSession failed: code=%{public}s msg=%{public}s', code, msg);
      return '';
    }
  }

  /** 源端：接续结束后释放对象（A 端退出前调用，失败无所谓） */
  static releaseSource(): void {
    if (ContinueBridge.srcObject === null) {
      return;
    }
    try {
      ContinueBridge.srcObject.setSessionId('');
    } catch (e) {
      // 忽略
    }
    ContinueBridge.srcObject = null;
  }

  // ══════════════════════════════════════════════════════════════════════════
  // 对端：加入 session 并等 Asset 落地
  // ══════════════════════════════════════════════════════════════════════════

  /**
   * 对端：从 `want.parameters` 还原元数据（不含 Asset，Asset 走 DataObject）。
   */
  static restoreFromWant(want: Want): ContinuePayload | null {
    const params: Record<string, Object> | undefined = want.parameters;
    if (params === undefined || params === null) {
      return null;
    }
    const pre: string = ContinueBridge.W_PREFIX;
    const bookName: string = ContinueBridge.str(params[pre + 'BookName']);
    if (bookName.length === 0) {
      hilog.info(DOMAIN, TAG, 'restoreFromWant: not a continuation want');
      return null;
    }
    const p: ContinuePayload = {
      bookName: bookName,
      bookUrl: ContinueBridge.str(params[pre + 'BookUrl']),
      chapterTitle: ContinueBridge.str(params[pre + 'ChapterTitle']),
      spineIndex: ContinueBridge.num(params[pre + 'Spine']),
      domPos: ContinueBridge.str(params[pre + 'DomPos']),
      nodeIndex: ContinueBridge.num(params[pre + 'Node']),
      charOffset: ContinueBridge.num(params[pre + 'Char']),
      fontName: ContinueBridge.str(params[pre + 'FontName']),
      fontPath: ContinueBridge.str(params[pre + 'FontPath']),
      fontWeight: ContinueBridge.num(params[pre + 'FontWeight']),
      fontColor: ContinueBridge.str(params[pre + 'FontColor']),
      themeColor: ContinueBridge.str(params[pre + 'ThemeColor']),
      themeBgImg: ContinueBridge.str(params[pre + 'ThemeBgImg']),
      nightMode: ContinueBridge.bool(params[pre + 'NightMode']),
      flipMode: ContinueBridge.str(params[pre + 'FlipMode']),
      bgJson: ContinueBridge.str(params[pre + 'BgJson']),
      sessionId: ContinueBridge.str(params[pre + 'Session']),
      listenMode: ContinueBridge.bool(params[pre + 'Listen'])
    };
    // Asset 路径先清空，等 DataObject restored 再填（避免读到上一轮的残留）
    AppStorage.setOrCreate(ContinueBridge.KEY_ASSET_PATH, '');
    AppStorage.setOrCreate(ContinueBridge.KEY_PENDING, JSON.stringify(p));
    hilog.info(DOMAIN, TAG,
      'restoreFromWant: book=%{public}s spine=%{public}d node=%{public}d char=%{public}d session=%{public}s listen=%{public}s',
      p.bookName, p.spineIndex, p.nodeIndex, p.charOffset, p.sessionId, String(p.listenMode));
    return p;
  }

  /**
   * 对端：加入源端建的 session，等 Asset 同步过来。
   *
   * 官方三条 ⚠️ 全部照做：
   *  ① 创建的空对象**所有属性设空**（资产类型 = 各字段空字符串），否则会**倒灌**
   *     覆盖源端数据；
   *  ② `on('status')` 必须在 `setSessionId()` **之前**注册，否则会错过 `restored`；
   *  ③ 对象不能是临时变量（存类成员 `dstObject`）。
   */
  static joinSession(ctx: common.UIAbilityContext, sessionId: string): void {
    if (sessionId.length === 0) {
      hilog.warn(DOMAIN, TAG, 'joinSession: empty sessionId, skip');
      return;
    }
    try {
      const emptyAsset: commonType.Asset = {
        name: '', uri: '', path: '', createTime: '', modifyTime: '', size: ''
      };
      const empty: ContinueDataObject = { bookAsset: emptyAsset };
      const obj = distributedDataObject.create(ctx, empty);
      ContinueBridge.dstObject = obj;
      // ② 先注册监听
      obj.on('status', (_sessionId: string, _networkId: string,
        status: 'online' | 'offline' | 'restored') => {
        hilog.info(DOMAIN, TAG, 'dstObject status=%{public}s', status);
        if (status !== 'restored') {
          return;
        }
        ContinueBridge.onAssetRestored(ctx);
      });
      // ① + 激活
      obj.setSessionId(sessionId);
      hilog.info(DOMAIN, TAG, 'joinSession: setSessionId ok %{public}s', sessionId);
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'joinSession failed: %{public}s',
        e instanceof Error ? e.message : String(e));
    }
  }

  /**
   * `restored` 回调：把同步过来的 Asset 落成**本机可读路径**并广播给 Index。
   *
   * Asset 的 `path` / `uri` 在同步后指向系统为本应用落地的实体文件；
   * 这里按 path → uri 的顺序尝试，谁存在用谁（不同版本行为有差异，做双保险）。
   */
  private static onAssetRestored(ctx: common.UIAbilityContext): void {
    const obj = ContinueBridge.dstObject;
    if (obj === null) {
      return;
    }
    try {
      const asset = obj['bookAsset'] as commonType.Asset;
      if (asset === undefined || asset === null) {
        hilog.warn(DOMAIN, TAG, 'onAssetRestored: no bookAsset');
        return;
      }
      hilog.info(DOMAIN, TAG,
        'onAssetRestored: name=%{public}s path=%{public}s uri=%{public}s size=%{public}s',
        asset.name, asset.path, asset.uri, asset.size);
      let local: string = '';
      if (asset.path !== undefined && asset.path.length > 0 && fs.accessSync(asset.path)) {
        local = asset.path;
      } else if (asset.uri !== undefined && asset.uri.length > 0) {
        const p: string = asset.uri.startsWith('file://')
          ? asset.uri.substring('file://'.length) : asset.uri;
        if (fs.accessSync(p)) {
          local = p;
        }
      }
      if (local.length === 0) {
        hilog.warn(DOMAIN, TAG, 'onAssetRestored: asset file not readable');
        return;
      }
      AppStorage.setOrCreate(ContinueBridge.KEY_ASSET_PATH, local);
      hilog.info(DOMAIN, TAG, 'onAssetRestored: ready %{public}s', local);
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'onAssetRestored failed: %{public}s',
        e instanceof Error ? e.message : String(e));
    }
  }

  /** 对端：导入完成后退出 session 并释放（避免对象泄漏，单应用上限 16 个） */
  static releaseTarget(): void {
    if (ContinueBridge.dstObject === null) {
      return;
    }
    try {
      ContinueBridge.dstObject.setSessionId('');
    } catch (e) {
      // 忽略
    }
    ContinueBridge.dstObject = null;
    AppStorage.setOrCreate(ContinueBridge.KEY_ASSET_PATH, '');
  }

  /**
   * 读取待消费的接续数据 —— **不**清除标记。
   *
   * ⚠️ 2026-10-23 改为「读不清」（原来是读走即清）：
   *   `restoreWindowStage()` 会销毁重建 AceContainer（真机日志
   *   `window destroy` / `AceContainer Destroy begin`）。如果旧 Index 已经
   *   `consume` 掉标记、push 了阅读页，紧接着容器被销毁 ⇒ 新 Index 里标记已被清空
   *   ⇒ **页面丢了，停在书架**。
   *   ⇒ 现在标记保留，直到**跳转成功**才由 `clearPending()` 清掉；
   *     新旧 Index 谁先到都能再试一次（Index 侧有 `continueHandled` 防重复 push）。
   */
  static peekPending(): ContinuePayload | null {
    const raw: string = AppStorage.get<string>(ContinueBridge.KEY_PENDING) ?? '';
    return ContinueBridge.parse(raw);
  }

  /** 跳转成功 / 明确放弃后才清标记 */
  static clearPending(): void {
    AppStorage.setOrCreate(ContinueBridge.KEY_PENDING, '');
  }

  /** 兼容旧调用：等价于 peek（不清除） */
  static consumePending(): ContinuePayload | null {
    return ContinueBridge.peekPending();
  }

  /**
   * 对端：把带过来的**背景记录**落库。
   * ⚠️ 必须走 `ReaderCustomBg.saveBook()`（键 `ReaderBg_<书名>` + 登记覆盖表）。
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
        nodeIndex: typeof p.nodeIndex === 'number' ? p.nodeIndex : 0,
        charOffset: typeof p.charOffset === 'number' ? p.charOffset : 0,
        fontName: typeof p.fontName === 'string' ? p.fontName : '',
        fontPath: typeof p.fontPath === 'string' ? p.fontPath : '',
        fontWeight: typeof p.fontWeight === 'number' ? p.fontWeight : 0,
        fontColor: typeof p.fontColor === 'string' ? p.fontColor : '',
        themeColor: typeof p.themeColor === 'string' ? p.themeColor : '',
        themeBgImg: typeof p.themeBgImg === 'string' ? p.themeBgImg : '',
        nightMode: p.nightMode === true,
        flipMode: typeof p.flipMode === 'string' ? p.flipMode : '',
        bgJson: typeof p.bgJson === 'string' ? p.bgJson : '',
        sessionId: typeof p.sessionId === 'string' ? p.sessionId : '',
        listenMode: p.listenMode === true
      };
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'parse payload failed');
      return null;
    }
  }
}
