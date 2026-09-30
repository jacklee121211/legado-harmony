import { Books } from '../../database/entities/Books';
import { router } from '@kit.ArkUI';
import { LongTakeFlightData } from '../utils/LongTakeBook';

/**
 * 路由门面（2026-09-21 起，为「全量迁 Navigation」铺路）。
 *
 * ── 为什么要这个东西 ──────────────────────────────────────────────────────
 * 本工程原本全部走 `router`（`@Entry` 页面）。要拿到官方两件事必须换成
 * `Navigation` + `NavDestination` + `NavPathStack`：
 *   ① **标题栏沉浸光感** —— 官方生效范围原文：「其他组件**仅在** Navigation/NavDestination
 *      标题栏，或横向 Tabs 中 barPosition 为 BarPosition.End 的底部 TabBar 中生效」；
 *   ② **一镜到底转场** —— 官方 skill `hmos-arkui-longtake-transition` 前提原文：
 *      「使用 Navigation 路由 —— 应用必须基于 Navigation + NavDestination 的路由体系，**而非 Router**」。
 *
 * 迁移是**分期**做的（28 个 `@Entry` 页面、约 40 处 `router.pushUrl`，一次全改风险太大），
 * 所以中间必然存在「一部分页面走 Navigation、一部分还走 router」的混合期。
 * 这个门面就是为了让**调用点只写一次**、后续换实现不用回头改页面：
 *   · 已迁的页面用 `AppRouter.push(name, param)` / `AppRouter.pop()`（走 NavPathStack）；
 *   · 没迁的页面继续用 `router.pushUrl` / `router.back()`（`router` 与 `Navigation` 可共存：
 *     `router` 推出来的是**整页**，会盖住 `Index` 连同它的 Navigation，返回后仍是原来那套栈）。
 *
 * ⚠️ **混合期的一条铁律**：页面**必须**用与自己入栈方式匹配的返回 API ——
 *   走 `pathStack` 进来的页面调 `router.back()` 会把**整个 Index 弹掉（直接回桌面）**，
 *   因为它弹的是 router 页栈。改一个页面时，务必同时改它的「入栈」和「返回」。
 */
export default class AppRouter {
  /** 由 `pages/Index.ets` 的 `Navigation` 在 onAppear 时挂上 */
  private static stack: NavPathStack | null = null;

  /** `Index.ets` 调用：把 Navigation 的栈交给门面 */
  static attach(stack: NavPathStack): void {
    AppRouter.stack = stack;
  }

  /** Navigation 是否已就绪（迁移期用于判断该走哪条路） */
  static isReady(): boolean {
    return AppRouter.stack !== null;
  }

  /**
   * 推入一个 NavDestination。
   * @param name 路由名（见 `RouteName`）
   * @param param 参数对象（目标页在 `navDestination` 构建器里取用）
   *
   * ⚠️ 2026-09-24 记录：这里**一度**加过一个 `animated` 形参（配合"书架→阅读器一镜到底"
   *   里"关闭系统默认转场"的要求）。那整套尝试**已全部撤除** ⇒ 形参也已撤除，恢复原样。
   */
  static push(name: string, param?: object): boolean {
    if (AppRouter.stack === null) {
      return false;
    }
    AppRouter.stack.pushPath({ name: name, param: param });
    return true;
  }

  /** 弹出当前 NavDestination（**只能**用于走 pathStack 进来的页面） */
  static pop(): void {
    if (AppRouter.stack !== null) {
      AppRouter.stack.pop();
    }
  }

  /**
   * **自适应返回** —— 给「共享返回按钮」用。
   *
   * ── 为什么需要它 ──────────────────────────────────────────────────────────
   * 工程里有 4 个被多处复用的返回按钮：`componets/common/Header.ets`、
   * `componets/myCenter/MyCenterTitle.ets`、`componets/myset/SetHead.ets`、
   * `componets/search/SearchHead.ets`。它们原本一律调 `router.back()`。
   *
   * 但混合期里 `router` 栈与 `Navigation` 的 `pathStack` 是**两个独立的栈**，
   * 一个按钮该弹哪个，取决于「**此刻谁在最上面**」：
   *   · 顶部是 `NavDestination` ⇒ 必须 `pop()` pathStack；
   *   · 顶部是 router 页（例如从已迁移的页面 `router.pushUrl` 打开了一个还没迁的
   *     `@Entry` 页）⇒ 必须 `router.back()`。
   *
   * 判据：把 `pathStack` 的栈顶名和 router 栈顶名比一比，相等就说明
   * **router 页压在 NavDestination 之上**（否则已迁移的 NavDestination 根本不会
   * 出现在 router 栈里）。
   *
   * ⚠️ 前提：路由名与 router 页名不能撞车 —— 若某个 NavDestination 的 `name`
   *    恰好等于某个同时存在于 router 栈里的页面 `name`，这里会误判。
   *    当前 `RouteName` 的取值都不与 `main_pages.json` 中的路径同名（见该类注释），
   *    后续新增路由名时请保持这一约定。
   *
   * ⚠️ 下面两处 `router.back()` / `router.getState()` 会触发**既有**的废弃告警
   *    （SDK `@ohos.router.d.ts:487` / `:589` 原文均为 `@deprecated since 18`，
   *    `@useinstead @ohos.arkui.UIContext:Router#back` 等）。这里**刻意保留**：
   *    它们是「顶部其实是 router 页」时的回退分支，而全工程另外 30 处 `router.back()`
   *    用的是同一套 API ⇒ 单点改成 UIContext 版只会造成风格分裂、收益为零。
   *    真要把 router 系 API 整体换掉，应当**一期统一重构**，不夹在本期里做。
   */
  static back(): void {
    if (AppRouter.stack === null) {
      router.back();
      return;
    }
    const top: string | null = AppRouter.topName();
    if (top === null) {
      router.back();
      return;
    }
    // `router.getState()` 返回 router 栈顶页面的状态（`RouterState.name` 即页面名）。
    // 取不到（栈空 / 异常）时按"顶部是 NavDestination"处理。
    let routerTop: string = '';
    try {
      const state = router.getState();
      routerTop = state ? state.name : '';
    } catch (e) {
      routerTop = '';
    }
    if (routerTop === top) {
      router.back();
    } else {
      AppRouter.stack.pop();
    }
  }

  /** 清空 Navigation 栈（回主页用） */
  static clear(): void {
    if (AppRouter.stack !== null) {
      AppRouter.stack.clear();
    }
  }

  /**
   * 当前栈顶的路由名；栈空或门面未就绪时返回 `null`。
   *
   * 用途：`pages/Index.ets` 的 `consumeQuickAction()` 原来靠
   * `router.getState().name === 'pages/view/Reader/ReaderPage3'` 判断"已经在阅读页里"，
   * 从而避免叠出第二个阅读页。迁到 Navigation 后阅读页是 NavDestination，
   * router 状态里看不到它 ⇒ 必须改问本方法。
   */
  static topName(): string | null {
    if (AppRouter.stack === null) {
      return null;
    }
    const names: string[] = AppRouter.stack.getAllPathName();
    return names.length > 0 ? names[names.length - 1] : null;
  }
}

/**
 * 「阅读页」路由参数。
 *
 * ⚠️ 为什么必须显式声明这个接口：ArkTS 的 `arkts-no-untyped-obj-literals` 规则禁止把
 * **无类型对象字面量**传给 `object` 参数（`AppRouter.push` 的 `param`）——
 * 迁第 2 期时已在 `SearchBookItem` 上撞到过一次编译错误。所以每个路由的参数都要有名字。
 */
export interface ReaderRouteParam {
  /** 书籍数据（必填） */
  bookData: Books;
  /** 从详情页目录点进来时的目录项 id */
  clickBookCatalogId?: number;
  /** 桌面快捷方式「快速听书」带过来的标记：进入后自动开始朗读 */
  quickListen?: boolean;
  /** 「我的 → 书签」回跳：书签的目录号 */
  bmChapterIndex?: number;
  /** 「我的 → 书签」回跳：书签的页首块节点号 */
  bmNode?: number;
  /**
   * 一镜到底飞行数据（2026-09-23）。
   * 仅书架点击封面时由 `LongTakeFlightData.capture()` 生成并携带；
   * 详情页 / 快捷方式 / 书签回跳**不传** ⇒ `Index.ets` 的转场 delegate 据此分流：
   * 有 = 演一镜到底，无 = 保持 `T_READER`（EXPLODE）内置转场、行为与从前完全一致。
   */
  longTake?: LongTakeFlightData;
}

/**
 * 「读过/读完/书签」二级菜单（`pages/view/myCenter/readStatistics`）路由参数。
 *
 * 原实现是 `(router.getParams() as dataItem).value`（该文件 :35）。
 * 迁 Navigation 后**没有 `router.getParams()` 可用** —— NavDestination 的参数是
 * `pushPath({name, param})` 里的 `param`，由 `Index.appRoutes()` 转交给组件。
 *
 * ⚠️ ArkTS 的 `arkts-no-untyped-obj-literals` 禁止无类型字面量传给 `object` 参数，
 *    所以每个路由参数都要有显式声明的接口（同 `ReaderRouteParam`）。
 */
export interface ReadStatisticsRouteParam {
  /** 0=读过 / 1=读完 / 2=书签 */
  type: number;
}

/**
 * 「书架管理」页（`pages/view/bookShelf/Manage/BookManagePage`）路由参数。
 *
 * 对应原 `BookManagePage.ets:24-33` 的 `class routerParams`（字段名保持一致）。
 */
export interface BookManageRouteParam {
  currentIndex: number;
  EXHIBIT: string;
  bookTypeNumber: number;
}

/**
 * 路由名常量表。
 *
 * 命名刻意与旧 `router` 路径**分开**：迁移期两者并存，用同一个字符串表反而容易混。
 * 每迁一个页面就在这里加一条，并在 `Index.ets` 的 `appRoutes()` 里加对应分支。
 *
 * ⚠️ **约定（`back()` 的正确性依赖它）**：这些取值不得与任何会同时存在于
 *    router 栈里的页面名相同，否则 `back()` 的自适应判定会误判。
 */
export class RouteName {
  /** 占位名，永不匹配（`Index.appRoutes()` 里用来避免空 @Builder） */
  static readonly NONE: string = '__none__';
  /** 书籍详情页（`pages/view/BookDetailPage`） */
  static readonly BOOK_DETAIL: string = 'BookDetailPage';
  /** 阅读页（`pages/view/Reader/ReaderPage3`） */
  static readonly READER: string = 'ReaderPage3';
  /** 读过 / 读完 / 书签 二级菜单（`pages/view/myCenter/readStatistics`） */
  static readonly READ_STATISTICS: string = 'ReadStatistics';
  /** 主题配置（`pages/view/myCenter/MyThemeConfig`） */
  static readonly THEME_CONFIG: string = 'MyThemeConfig';
  /** 我的设置（`pages/view/myCenter/MySetPage`） */
  static readonly MY_SET: string = 'MySetPage';
  /** 自定义主题（`pages/view/myCenter/CreateCustomTheme`） */
  static readonly CUSTOM_THEME: string = 'CreateCustomTheme';
  /** 书架管理（`pages/view/bookShelf/Manage/BookManagePage`） */
  static readonly BOOK_MANAGE: string = 'BookManagePage';
  /** 关于我们（`pages/view/myCenter/about/AboutPage`，2026-09-30 回填） */
  static readonly ABOUT: string = 'AboutPage';
  /** 更新日志（`pages/view/myCenter/about/VersionLogPage`） */
  static readonly VERSION_LOG: string = 'VersionLogPage';
  /** 用户隐私与协议（应用内 Web 组件打开远程协议页） */
  static readonly PRIVACY: string = 'PrivacyPage';
  /** 开源许可（`pages/view/myCenter/about/LicensePage`） */
  static readonly LICENSE: string = 'LicensePage';
}
