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
import { TtsCallbacks, TtsState } from './TtsEngine';

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

  /** 开播前登记会话（书名 + url + 书 id 一起落，UI 首帧就能显示） */
  static begin(title: string, url: string, bookId: number): void {
    AppStorage.setOrCreate(ListenSession.KEY_TITLE, title);
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

  /** 会话结束（引擎 stopped / 用户停播）→ dock 收回圆形 */
  static end(): void {
    AppStorage.setOrCreate(ListenSession.KEY_ACTIVE, false);
    AppStorage.setOrCreate(ListenSession.KEY_PLAYING, false);
    AppStorage.setOrCreate(ListenSession.KEY_EXPANDED, false);
    AppStorage.setOrCreate(ListenSession.KEY_URL, '');
    AppStorage.setOrCreate(ListenSession.KEY_ID, -1);
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
