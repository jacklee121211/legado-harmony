/**
 * 全局听书会话状态（2026-10-09 新增，用户需求：书架听书迷你 dock）。
 *
 * ── 这个类解决什么 ─────────────────────────────────────────────────────────
 * 需求原文：「返回到书架等于听书自动关闭，我们需要返回书架继续听书，并且在这个新图标处
 * 可以管理…点击播放的同时，圆形向左侧展开，变成 dock…上面居中对齐出现一个信息条，是书名」。
 *
 * 旧实现（`ReaderPage3.aboutToDisappear()`，注释原文「离开阅读页时结束朗读
 * （避免回调引用已销毁页面；**后台收听留待后续版本**）」）：
 *   `TtsEngine.stop('')` —— 无条件停播。
 *
 * ⇒ 本类把"听书会话"从**页面**里剥离出来，落成一份 **AppStorage 全局状态**，
 *   书架的迷你 dock 只读这份状态，不依赖阅读页存活。
 *
 * ── 为什么必须有 `headless()` ───────────────────────────────────────────────
 * `TtsEngine.cb` 是**静态单例**持有的回调；阅读页把它设成**闭包捕获了页面实例**的实现。
 * 阅读页销毁后若不换掉，引擎继续播时会打到已销毁页面上（旧注释正是为此才 stop）。
 * `headless()` 返回一份**不引用任何页面对象**的实现，只把状态镜像进 AppStorage。
 *
 * ── ⚠️ AppStorage 键的写法约束 ─────────────────────────────────────────────
 * `@StorageLink('listenPlaying')` 这类装饰器**要求编译期字面量**，不能写
 * `@StorageLink(ListenSession.KEY_PLAYING)`。所以下面的常量**只用于"写"**；
 * 任何组件里"读"的地方必须写同样的字面量，改键名时**两处一起改**。
 *
 * ── 一键回退 ───────────────────────────────────────────────────────────────
 * `KEEP_PLAYING_ON_LEAVE_READER = false` ⇒ `ReaderPage3.aboutToDisappear()` 回到
 * 「无条件 `TtsEngine.stop('')`」，即 2026-10-09 之前的行为。
 * 回退后要验证：离开阅读页 → 朗读立即停止、书架不出现听书 dock。
 */
// 类型 import + 值 import 合并写（ArkTS 允许）：`TtsEngine` 用于 `beginExclusive()` 里
// 显式停掉"另一本书"的旧会话。**无循环依赖** —— `TtsEngine.ets` 全文件不 import
// `ListenSession`（grep 零命中），会话状态的镜像是由阅读页 `registerTtsCallbacks()`
// 那侧把 `ListenSession.wrap()/headless()` 的结果**喂**进引擎回调的。
import { TtsCallbacks, TtsState, TtsEngine } from './TtsEngine';
import { PreferencesUtil } from '@pura/harmony-utils';
import { hilog } from '@kit.PerformanceAnalysisKit';

/** 诊断日志域/标签（2026-10-12）：与 `ListenLauncher` / `ListenDock` 同域，便于一起 filt */
const DOMAIN: number = 0x0000;

export class ListenSession {
  /**
   * **一键回退开关**：`true` = 离开阅读页继续播（本次新行为）；
   * `false` = 离开即停（改动前的旧行为）。
   */
  static readonly KEEP_PLAYING_ON_LEAVE_READER: boolean = true;

  /** AppStorage 键（只用于写；组件里的装饰器必须写同样的字面量，见类注释） */
  static readonly KEY_ACTIVE: string = 'listenActive';
  static readonly KEY_PLAYING: string = 'listenPlaying';
  static readonly KEY_TITLE: string = 'listenTitle';
  /** 原始书名（始终带拓展名；UI 层按 setExtName 开关决定显示哪个） */
  static readonly KEY_TITLE_RAW: string = 'listenTitleRaw';
  static readonly KEY_CHAPTER: string = 'listenChapter';
  static readonly KEY_EXPANDED: string = 'listenExpanded';
  /**
   * **正在听的那本书的 bookUrl**（2026-10-09 新增）。
   *
   * 为什么必须有：`TtsEngine` 与沉浸层是**全局单例**，跟"当前打开的是哪本书"无关。
   * 真机 bug（用户 2026-10-09）：在听《神墓》时点开《鬼墓》，
   *   阅读页把这个**全局**的听书状态当成自己的 ⇒ 整页渲染成《神墓》的沉浸听读，
   *   而在《鬼墓》里点"退出听书"时又拿《神墓》的位置去定位 ⇒ **黑屏**。
   * ⇒ 阅读页必须能判断"**在听的是不是手里这本**"：只有相等才进沉浸听读，
   *   否则一律普通阅读模式。判据就是本字段（`ReaderPage3.listeningThisBook()`）。
   */
  static readonly KEY_URL: string = 'listenBookUrl';
  /**
   * **正在听的那本书的 `Books.id`**（2026-10-09 三次修复）。
   *
   * 为什么再加一个 id：`bookUrl` 判据在真机上**对同一本书也不相等**
   * （日志证据：`tts state restored on enter` 一次都没打出来 ⇒ `listeningThisBook()` 恒 false，
   *  结果连"正在听的那本"都进不了沉浸听读）。
   * url 是字符串，会被路径归一化/前后空白搞出差异；**id 是数据库主键数字，不会**。
   * ⇒ 判据优先级：**id → url → 书名**，任一命中即算同一本。
   */
  static readonly KEY_ID: string = 'listenBookId';

  private static mirrorState(s: TtsState): void {
    // ★ 只在值**真的变了**才写 AppStorage（2026-10-09 旋转加速 bug 修复）。
    //   引擎每次 `onState` 都会调到这里，而 `setOrCreate` 即使值相同也会通知观察者
    //   ⇒ `@Watch` 反复触发 ⇒ 迷你栏每次都在同一个节点上叠一条无限旋转动画 ⇒ 越转越快。
    const playing: boolean = s === 'playing';
    if ((AppStorage.get<boolean>(ListenSession.KEY_PLAYING) ?? false) !== playing) {
      AppStorage.setOrCreate(ListenSession.KEY_PLAYING, playing);
    }
    if (s === 'stopped') {
      ListenSession.end();
    }
  }

  /** 开播前登记会话（书名 + url + 书 id 一起落，UI 首帧就能显示）。
   * 2026-10-12：书名联动"显示文件拓展名"开关——同时保存原始书名（带拓展名）和
   * 显示用书名（按当前开关决定），UI 层 `ListenTitleBar` 在开关变化时从原始书名
   * 重新计算显示值，不再依赖重新调用 `begin()`。 */
  static begin(title: string, url: string, bookId: number): void {
    const showExt: boolean = PreferencesUtil.getSync('setExtName', false) as boolean;
    const displayTitle: string = showExt ? title : title.replace(/\.[a-zA-Z0-9]{1,5}$/, '');
    // ★ 诊断打点（2026-10-12）：书名条显示旧名时，先确认"起播时登记的书名"本身对不对。
    //   若这里打出的就是新名、界面却显示旧名 ⇒ 问题在 UI 侧（重建/缓存）；
    //   若这里打出的就是旧名 ⇒ 问题在上游（`ListenLauncher` 拿到的 `Books` 就是旧快照）。
    hilog.info(DOMAIN, 'listenSession',
      'begin: raw=%{public}s display=%{public}s id=%{public}d url=%{public}s showExt=%{public}s',
      title, displayTitle, bookId, url, String(showExt));
    AppStorage.setOrCreate(ListenSession.KEY_TITLE_RAW, title);
    AppStorage.setOrCreate(ListenSession.KEY_TITLE, displayTitle);
    AppStorage.setOrCreate(ListenSession.KEY_URL, url);
    AppStorage.setOrCreate(ListenSession.KEY_ID, bookId);
    AppStorage.setOrCreate(ListenSession.KEY_CHAPTER, '');
    AppStorage.setOrCreate(ListenSession.KEY_PLAYING, false);
    // ⚠️ 这里**绝对不能**写 `KEY_EXPANDED = false`（2026-10-09 真机反馈修复）。
    //   症状：进 app 直接点圆形，圆形"展开一下又立刻回缩"。
    //   根因链：点圆 → HDS 展开并回调 `onBarStyleChange(EXPAND)` → `listenExpanded=true`
    //     → 我们异步去查"最后一次阅读的书" → 查到后调 `begin()`
    //     → 这里把 `EXPANDED` 置回 false → `Index` 的 `@Watch('onListenExpandedChanged')`
    //       看到 false 且 HDS 当前是 EXPAND ⇒ 立刻 `applyMiniBarStyle(COLLAPSE)`
    //     ⇒ 刚展开的 dock 被自己收回去了。
    //   `EXPANDED` 的唯一真相源是 HDS 的 `onBarStyleChange`，本方法不许碰。
    AppStorage.setOrCreate(ListenSession.KEY_ACTIVE, true);
  }

  /**
   * **听书会话的唯一性闸门**（2026-10-12 新增）。
   *
   * ── 它解决什么 ──────────────────────────────────────────────────────────────
   * 用户实测反馈：「我们似乎可以同时阅读多个书籍？？？这绝对不行，听书是具备
   * 唯一性的，不能同时读多个书籍」。
   *
   * ── 根因（读代码得出，非推测）────────────────────────────────────────────────
   * ① `TtsEngine` 是**全局静态单例**（`bookTitle` / `handler` / `player` 都是 static 字段），
   *    与"当前打开哪本书"无关；
   * ② 两处开播入口（`ReaderPage3.ttsStart():5348`、`ListenLauncher.startBook():79`）
   *    都**无条件**调 `ListenSession.begin(...)` ⇒ 直接覆盖会话身份（URL / ID / TITLE）；
   * ③ 而 `TtsEngine.start()` 里"重新开播前先停旧的"这一步**压制了 stopped 回调**
   *    （`:1370-1372` `suppressStopCb = true` / `stopInternal('')` / `false`）——
   *    那个压制本身是**必要的**（不压制会触发 `ListenSession.end()` 把刚写好的会话身份
   *    立刻清空，导致"正在听的那本也进不了沉浸听读"），但副作用是：
   *    **旧书 A 的会话身份被 B 静默替换，且没有任何一步显式地"结束 A"**。
   *    表现就是用户看到的：A 仍在播（`KEEP_PLAYING_ON_LEAVE_READER = true` 允许离开
   *    阅读页继续播），界面却已经是 B，而 B 的听书面板又能开一路 ⇒ 像"同时在读两本"。
   *
   * ── 本方法做什么 ────────────────────────────────────────────────────────────
   * 开播前**先判是否同一本**（id → url → 书名，判据与 `ReaderPage3.listeningThisBook()`
   * 严格同源，避免两处判据漂移）：
   *   · 同一本：什么都不做（续播 / 切章 / 重新锚定都属正常）；
   *   · 不同本：**先显式停掉旧会话**（`TtsEngine.stop` + `end()`），再登记新会话。
   *
   * ⚠️ `TtsEngine.stop()` 会走完整停播链（停播放器 / 停后台任务 / 清睡眠定时 /
   *    `deactivateSession()`），正是"干净结束上一本"所要的。它内部**不**设
   *    `suppressStopCb`，所以 `onState('stopped')` 会正常发出 ⇒ `mirrorState()` 走
   *    `end()` 分支 —— 这与我们随后自己调 `end()` 是**幂等**的（`end()` 只是把几个
   *    AppStorage 键置成"无会话"初值）。
   *
   * @param title 书名（**原始书名，带拓展名**；显示名由 `refreshTitle` 按开关算）
   * @param url   书的 `bookUrl`
   * @param bookId 书的 `Books.id`（判同一本的首选判据）
   */
  static beginExclusive(title: string, url: string, bookId: number): void {
    if (ListenSession.isActive() && !ListenSession.sameBook(url, bookId, title)) {
      // 旧会话属于**另一本书** ⇒ 显式收尾，绝不留给它一条隐式存活的路径
      TtsEngine.stop('');
      ListenSession.end();
    }
    ListenSession.begin(title, url, bookId);
  }

  /**
   * 判断给定标识是否就是**正在听的那一本**。判据顺序 id → url → 书名，
   * 与 `ReaderPage3.listeningThisBook()` 严格同源（那处是"本页是不是在听的那本"，
   * 本处是"即将开播的是不是正在听的那本"）。
   *
   * 空值一律**不**参与匹配（绝不让"空 == 空"误判成同一本 —— 这是 url 判据的老坑，
   * 见 `KEY_ID` 注释里"真机上同一本书 url 也不相等"的记录）。
   */
  static sameBook(url: string, bookId: number, title: string): boolean {
    if (!ListenSession.isActive()) {
      return false;
    }
    // ① id 首选（数据库主键数字，不受路径归一化/空白影响）
    if (bookId >= 0 && ListenSession.bookId() === bookId) {
      return true;
    }
    const curUrl: string = ListenSession.bookUrl();
    const u: string = (url ?? '').trim();
    // ② url 次选
    if (curUrl.length > 0 && u.length > 0 && curUrl.trim() === u) {
      return true;
    }
    // ③ 书名兜底（用**原始书名**比，显示名会被拓展名开关改写，不能当判据）
    const raw: string = AppStorage.get<string>(ListenSession.KEY_TITLE_RAW) ?? '';
    const t: string = (title ?? '').trim();
    return raw.length > 0 && t.length > 0 && raw === t;
  }

  /** 会话结束（引擎 stopped / 用户停播）→ dock 收回圆形 */
  static end(): void {
    AppStorage.setOrCreate(ListenSession.KEY_ACTIVE, false);
    AppStorage.setOrCreate(ListenSession.KEY_PLAYING, false);
    AppStorage.setOrCreate(ListenSession.KEY_EXPANDED, false);
    AppStorage.setOrCreate(ListenSession.KEY_URL, '');
    AppStorage.setOrCreate(ListenSession.KEY_ID, -1);
  }

  /**
   * **按当前（或指定的）拓展名开关重算显示书名**（2026-10-12 新增）。
   *
   * ── 为什么需要它 ──────────────────────────────────────────────────────────
   * `begin()` 只在**起播那一刻**算过一次显示名。听书进行中用户去设置页拨
   * 「显示文件拓展名」开关时，`listenTitle` 不会自己重算 ⇒ 迷你栏一直显示旧文件名
   * （用户原话：「不是实时刷新，比如说此时是开启，我们播放，然后去设置页关闭，
   *   继续看那个播放的信息窗，还是开启的文件名」）。
   *
   * ── 为什么不靠 `ListenTitleBar` 的 @Watch 就够 ─────────────────────────────
   * `ListenTitleBar` 已经挂了 `@Watch('refreshDisplayTitle')`（同时订 `listenTitleRaw`
   * 与 `setExtName`），开关一变它会自己重算。但**书架迷你栏不是常驻节点** ——
   * 它由 HDS `miniBarBuilder` 构建，切页签/父组件重渲染时会**销毁重建**
   * （`ListenDock` 类注释里那条「dock node rebuilt」打点证据）。
   * 重建后的首帧只读 AppStorage 里的 `listenTitle`，@Watch 不会补跑
   * ⇒ 必须由**写开关的那一侧**主动把 `listenTitle` 也刷新掉。
   *
   * @param showExt 开关的目标值。**必须显式传入**：`putSync` 与 `getSync` 之间
   *   存在时序窗口，本方法若自己回读 Preferences 可能读到旧值。
   */
  static refreshTitle(showExt: boolean): void {
    const raw: string = AppStorage.get<string>(ListenSession.KEY_TITLE_RAW) ?? '';
    if (raw === '') {
      return;
    }
    const display: string = showExt ? raw : raw.replace(/\.[a-zA-Z0-9]{1,5}$/, '');
    // 只在真的变了才写：`setOrCreate` 即使值相同也会通知观察者 ⇒ 无谓重绘
    // （与 `mirrorState()` / `setExpanded()` 同款差值写入，那两处的教训见各自注释）。
    if ((AppStorage.get<string>(ListenSession.KEY_TITLE) ?? '') !== display) {
      AppStorage.setOrCreate(ListenSession.KEY_TITLE, display);
    }
  }

  /**
   * **改写会话书名**（2026-10-12 新增）—— 书名在别处被改了（重命名）时同步迷你栏。
   *
   * 与 `refreshTitle()` 的分工：
   *   · `refreshTitle(showExt)`：书名**没变**，只是"显示拓展名"开关拨了 ⇒ 重算显示值；
   *   · `updateTitle(newTitle)`：书名**本身变了**（改名）⇒ 连**原始书名**（真相源）
   *     一起换掉，再按当前开关算显示值。
   * 两者都必须**同时**更新 `KEY_TITLE_RAW` 与 `KEY_TITLE`，否则下一次拨开关会
   * 从**旧**原始书名重算，把改名覆盖回去（这正是用户报的"minibar 显示还是之前的名字"）。
   *
   * 调用方是 `BookRename.syncListenSessionTitle()`（它已按 `Books.id` 判过
   * "正在听的就是这本书"）。
   */
  static updateTitle(newTitle: string): void {
    const title: string = (newTitle ?? '').trim();
    if (title === '') {
      return;
    }
    hilog.info(DOMAIN, 'listenSession', 'updateTitle: %{public}s (active=%{public}s)',
      title, String(AppStorage.get<boolean>(ListenSession.KEY_ACTIVE) ?? false));
    const showExt: boolean = PreferencesUtil.getSync('setExtName', false) as boolean;
    const display: string = showExt ? title : title.replace(/\.[a-zA-Z0-9]{1,5}$/, '');
    // ⚠️ 2026-10-12 二修：**RAW 与 TITLE 必须一起无条件写**。
    //   上一版给 TITLE 加了"值没变就不写"的差值判断（本意是避免无谓重绘），
    //   但改名场景下两者的"变没变"**不是同一件事**：新名如果只是拓展名被隐藏后
    //   与原显示值相同（例如 `111.txt` → `11.txt` 时关着开关，两者显示都是 `111`/`11`
    //   之外的边界情况），就会出现"RAW 写成新名、TITLE 却因判断被跳过"
    //   ⇒ AppStorage 里两份数据不一致 ⇒ 迷你栏重建后取到旧的那份。
    //   现在无条件写两份，杜绝不同步（`setOrCreate` 的额外通知代价可忽略：
    //   本方法只在"用户改名"时调用，不是高频路径）。
    AppStorage.setOrCreate(ListenSession.KEY_TITLE_RAW, title);
    AppStorage.setOrCreate(ListenSession.KEY_TITLE, display);
  }

  static isActive(): boolean {
    return AppStorage.get<boolean>(ListenSession.KEY_ACTIVE) ?? false;
  }

  static isPlaying(): boolean {
    return AppStorage.get<boolean>(ListenSession.KEY_PLAYING) ?? false;
  }

  static bookTitle(): string {
    return AppStorage.get<string>(ListenSession.KEY_TITLE) ?? '';
  }

  /**
   * 正在听的那本书的 bookUrl（空串 = 没有会话）。
   * 阅读页据此判断"在听的是不是手里这本"，见 `KEY_URL` 的注释。
   */
  static bookUrl(): string {
    return AppStorage.get<string>(ListenSession.KEY_URL) ?? '';
  }

  /** 正在听的那本书的 `Books.id`（-1 = 没有会话 / 未知）。判据首选，见 `KEY_ID` 注释 */
  static bookId(): number {
    return AppStorage.get<number>(ListenSession.KEY_ID) ?? -1;
  }

  static chapterTitle(): string {
    return AppStorage.get<string>(ListenSession.KEY_CHAPTER) ?? '';
  }

  /** 圆形 ⇄ 展开 dock（X 只收 UI，不停播 —— 用户 2026-10-09 拍板） */
  /**
   * 圆形 ⇄ 展开 dock（X 只收 UI，不停播）。
   *
   * ★ 2026-10-09「切页签时圆形会闪」的修复：**值没变就不写 AppStorage**。
   *   原因：`Index.onAnimationStart`（每次切页签必走）无条件调本方法传 `false`；
   *   而 `AppStorage.setOrCreate` **即使值相同也会通知观察者** ⇒
   *   `ListenDock` 的 `@StorageLink('listenExpanded')` 被无谓唤醒 ⇒ 迷你栏内容
   *   重绘一帧（材质背板要重新合成）⇒ 肉眼看到"闪一下"。
   *   与 `mirrorState()` 里的处理同源（那里也做了差值写入）。
   */
  static setExpanded(v: boolean): void {
    if ((AppStorage.get<boolean>(ListenSession.KEY_EXPANDED) ?? false) === v) {
      return;
    }
    AppStorage.setOrCreate(ListenSession.KEY_EXPANDED, v);
  }

  static isExpanded(): boolean {
    return AppStorage.get<boolean>(ListenSession.KEY_EXPANDED) ?? false;
  }

  /**
   * 包一层：既转发给**页面**回调，又把状态镜像进 AppStorage。
   * 阅读页 `registerTtsCallbacks()` 里用它包住原来的实现（改动最小）。
   */
  static wrap(inner: TtsCallbacks): TtsCallbacks {
    const out: TtsCallbacks = {
      onState: (s: TtsState): void => {
        inner.onState(s);
        ListenSession.mirrorState(s);
      },
      onChapter: (spineIndex: number, title: string): void => {
        inner.onChapter(spineIndex, title);
        AppStorage.setOrCreate(ListenSession.KEY_CHAPTER, title);
      },
      onSegment: (segIndex: number, total: number, text: string): void => {
        inner.onSegment(segIndex, total, text);
      },
      onProgress: (charInSentence: number, sentenceLen: number): void => {
        inner.onProgress(charInSentence, sentenceLen);
      },
      onToast: (msg: string): void => {
        inner.onToast(msg);
      }
    };
    return out;
  }

  /**
   * 阅读页销毁后接管回调：**只镜像状态，绝不触碰任何页面对象**。
   * 每个 ArkTS 形参都必须显式标注类型（工程规范）。
   */
  static headless(): TtsCallbacks {
    const out: TtsCallbacks = {
      onState: (s: TtsState): void => {
        ListenSession.mirrorState(s);
      },
      onChapter: (_spineIndex: number, title: string): void => {
        AppStorage.setOrCreate(ListenSession.KEY_CHAPTER, title);
      },
      onSegment: (_segIndex: number, _total: number, _text: string): void => {
      },
      onProgress: (_charInSentence: number, _sentenceLen: number): void => {
      },
      onToast: (_msg: string): void => {
      }
    };
    return out;
  }
}
