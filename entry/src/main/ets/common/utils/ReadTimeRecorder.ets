/**
 * 阅读时长记录器（2026-10-13 新建）——**「真实阅读时长」能力的唯一写入端**。
 *
 * ══════════════════════════════════════════════════════════════════════════
 * 为什么需要它（现状取证）
 * ══════════════════════════════════════════════════════════════════════════
 * 工程里原本**没有任何阅读时长写入**：
 *   · `readRecord` 表全工程零写入（`ReadRecordDao.ets:36-39` 自述、
 *     `BookDetailPage.ets:404-406` 记录）；
 *   · 「读过」只用 `Books.durChapterTime > 0` 判"是否读过"（`BooksDao.countRead()`），
 *     **没有任何时长概念**；
 *   · 唯一与"时间"有关的落库点是 `ReaderPage3.persistReadProgress()`（5 秒节流，
 *     只写章号），以及退出时的 `flushReadProgressThenNotifyShelf()`。
 *
 * ⇒ 本类接管"进书 → 前台停留多久 → 落到 `readDaily` 日粒度表"这条链。
 *
 * ══════════════════════════════════════════════════════════════════════════
 * 计时口径（**只算真实前台停留**）
 * ══════════════════════════════════════════════════════════════════════════
 * ① **只算前台**：切后台立刻结算并停表，回前台重新起表
 *    （`appForeground` 由 `EntryAbility.onForeground/onBackground` 维护，
 *      `EntryAbility.ets:334,341`）；阅读页的 `onAppForegroundChanged()` 是接线点。
 * ② **心跳 60 秒落一次库**：防止进程被杀丢整段（阅读页长期停留很容易被杀）。
 * ③ **短会话丢弃**：一次停留 < 10 秒不计（防"点错书立刻退出"污染日榜）。
 * ④ **单次超长不截断（默认）**：`MAX_SESSION_SEC = 0`。
 *    本模块的产品口径是**真实时长优先** —— 用户开着常亮读了 3 小时就是 3 小时。
 *    若日后要加挂机防护，把该常量改成 `4 * 3600` 即可（一行开关）。
 * ⑤ **写库失败绝不影响阅读**：DAO 内部已全 catch，本类再包一层 try/catch。
 *
 * ══════════════════════════════════════════════════════════════════════════
 * 一键回退
 * ══════════════════════════════════════════════════════════════════════════
 * 把 `ENABLED` 改成 `false` ⇒ 不建表以外的一切动作都不发生：
 * `attach()` 直接返回、不装定时器、不写一行数据；
 * UI 侧读到空数据走空态，其余功能零影响。
 *
 * ══════════════════════════════════════════════════════════════════════════
 * 2026-10-28 新增：两处**阅读里程碑推广**埋点（不改变计时口径）
 * ══════════════════════════════════════════════════════════════════════════
 * 「阅读 >1h 弹评分软引导 / >10h 弹 VIP」的调度层是 `common/utils/ReadPromo.ets`；
 * 它需要本类提供两个信号，这就是本文件为它改的全部内容（只加 2 处，口径零改动）：
 *   ① `commitSegment()`：每次把 `sec` 写进 `readDaily` 之后，**同步**再交给
 *      `ReadPromo.addSeconds(sec)` ⇒ 推广层拿到"累计阅读秒数"（跨会话单调递增，
 *      落 Preferences，所以杀进程也不丢）。放在心跳里而不是只在 `detach()` 里，
 *      是因为长时间停留很容易被系统杀（本文件 :22-23 同一个理由）。
 *   ② `detach()` 末尾：`AppStorage('readPromoTick')` 自增 ⇒ 这是「刚退出一本书」的广播，
 *      宿主 `pages/Index.ets` 用 `@StorageProp('readPromoTick') @Watch` 接住，
 *      在退书**转场结束之后**才判定要不要弹窗（弹窗不能盖在阅读页/转场动画上）。
 * 回退：把 `ReadPromo.ENABLED` 改 `false` 即可（本类这两处调用保持无条件、不做判断，
 *      这样回退只需改一个常量，不必回来改本文件）。
 */
import ReadDailyDao, { dayKeyOf } from '../../database/dao/ReadDailyDao'
import { ReadPromo } from './ReadPromo'

export class ReadTimeRecorder {
  /** **总开关（一键回退点）**：false ⇒ 完全不记时长（也不装定时器） */
  static readonly ENABLED: boolean = true

  /** 一次停留短于该秒数 ⇒ 丢弃（防误点开就退） */
  static readonly MIN_SESSION_SEC: number = 10

  /**
   * 单次会话的统计上限（秒）。**0 = 不截断**（默认，真实时长优先）。
   * 设为 `4 * 3600` 即开启"挂机防护"（超过 4 小时的停留不再累加）。
   */
  static readonly MAX_SESSION_SEC: number = 0

  /** 心跳间隔：60 秒落一次库 */
  static readonly HEARTBEAT_MS: number = 60 * 1000

  /** `EntryAbility` 维护的前后台键（与 `ReaderPage3.ets:931` 同一个字面量） */
  static readonly FG_KEY: string = 'appForeground'

  private static shared: ReadTimeRecorder | null = null

  /** 取全局唯一实例（懒建：不在静态初始化里 `new` 自己，避开初始化顺序问题） */
  static get(): ReadTimeRecorder {
    if (ReadTimeRecorder.shared === null) {
      ReadTimeRecorder.shared = new ReadTimeRecorder()
    }
    return ReadTimeRecorder.shared
  }

  /** 当前计时的书（0 = 未挂载） */
  private bookId: number = 0
  /** 是否已挂载（进书后 true，退出后 false） */
  private attached: boolean = false
  /** 是否正在计时（前台且已开始） */
  private counting: boolean = false
  /** 未结算区间的起点（毫秒；0 = 无） */
  private segStart: number = 0
  /** 本次会话的起点（毫秒）—— 只用于算「单次最长」 */
  private sessionStart: number = 0
  /** 本次会话已累计的秒数（跨心跳累加） */
  private sessionSec: number = 0
  /** 心跳定时器 id（-1 = 未装） */
  private timer: number = -1


  // ── 对外 API ────────────────────────────────────────────────────────────

  /** 进书：开始记账（阅读页 `aboutToAppear` 调用） */
  attach(bookId: number): void {
    if (!ReadTimeRecorder.ENABLED) {
      return
    }
    const id: number = Math.floor(bookId)
    if (id <= 0) {
      return
    }
    // 防御：上一本没收干净时先结算，避免串到这本书上
    if (this.attached) {
      this.detach()
    }
    this.bookId = id
    this.attached = true
    this.startTimer()
    if (this.isForeground()) {
      this.begin()
    }
  }

  /** 退书：结算 + 停表（阅读页 `aboutToDisappear` 调用） */
  detach(): void {
    if (!this.attached) {
      return
    }
    try {
      this.endSession()
    } catch (e) {
      console.error('ReadTimeRecorder.detach, Error, ' + JSON.stringify(e))
    }
    this.stopTimer()
    this.attached = false
    this.bookId = 0
    // ── 埋点②（2026-10-28）：「刚退出一本书」广播 ─────────────────────────────
    // 宿主 `pages/Index.ets` 用 `@StorageProp('readPromoTick') @Watch` 接住它，
    // 再延时判定要不要弹「评分引导 / VIP」推广弹窗（见 `ReadPromo.ets` 文件头）。
    // 为什么用 AppStorage 自增而不是回调：阅读页与 `Index` 之间没有直接引用
    // （ReaderPage3 是 NavDestination 子树），AppStorage 是本工程既有的跨层广播通道
    // （同款用法：`BOOK_IS_BOOK_REFRESHING`，规范性依据见
    //  `docs/标准-弹窗与按钮统一规范.md` §5「所有数据变更必须广播 AppStorage 公共信号」）。
    // 放在**末尾**：此时计时已停、秒数已落库，宿主读到的时长一定是最新的。
    try {
      AppStorage.setOrCreate<number>('readPromoTick',
        (AppStorage.get<number>('readPromoTick') ?? 0) + 1)
    } catch (e) {
      // 广播失败不影响退书流程（最多这一轮推广判定不触发，下次冷启动仍会判定）
      console.error('ReadTimeRecorder.detach tick, Error, ' + JSON.stringify(e))
    }
  }

  /** 前后台切换（阅读页 `onAppForegroundChanged()` 调用） */
  onForegroundChange(foreground: boolean): void {
    if (!ReadTimeRecorder.ENABLED || !this.attached) {
      return
    }
    try {
      if (foreground) {
        this.begin()
      } else {
        this.endSession()
      }
    } catch (e) {
      console.error('ReadTimeRecorder.onForegroundChange, Error, ' + JSON.stringify(e))
    }
  }

  /** 心跳：把当前区间结算进库，但**不结束会话**（会话还在继续） */
  flush(): void {
    if (!ReadTimeRecorder.ENABLED || !this.attached) {
      return
    }
    try {
      this.commitSegment()
    } catch (e) {
      console.error('ReadTimeRecorder.flush, Error, ' + JSON.stringify(e))
    }
  }

  /** 当前是否正在计时（排障/自检用） */
  isCounting(): boolean {
    return this.counting
  }

  // ── 内部 ────────────────────────────────────────────────────────────────

  /** 前后台真值（只认 AppStorage；取不到按前台处理，宁可记也别漏记） */
  private isForeground(): boolean {
    const fg: boolean | undefined = AppStorage.get<boolean>(ReadTimeRecorder.FG_KEY)
    return fg === undefined ? true : fg
  }

  /** 开始一段连续计时 */
  private begin(): void {
    if (this.counting) {
      return
    }
    this.counting = true
    this.segStart = Date.now()
    this.sessionStart = this.segStart
    this.sessionSec = 0
  }

  /**
   * 把 `segStart → now` 这段写进库（心跳与结算共用），并累加 sessionSec。
   * 桶归属用**区间起点**的时刻 ⇒ 跨整点的心跳会被正确分到起点那个小时。
   */
  private commitSegment(): void {
    if (!this.counting || this.segStart <= 0) {
      return
    }
    const now: number = Date.now()
    let sec: number = Math.floor((now - this.segStart) / 1000)
    if (sec <= 0) {
      return
    }
    // 挂机防护（默认关闭：MAX_SESSION_SEC = 0）
    const cap: number = ReadTimeRecorder.MAX_SESSION_SEC
    if (cap > 0 && this.sessionSec + sec > cap) {
      sec = Math.max(0, cap - this.sessionSec)
      if (sec <= 0) {
        // 已达上限：停表，本次会话不再累加
        this.counting = false
        this.segStart = 0
        return
      }
    }
    const bucketAt: number = this.segStart
    this.segStart = now
    this.sessionSec += sec
    const dayKey: string = dayKeyOf(bucketAt)
    const hourKey: number = new Date(bucketAt).getHours()
    // 不 await：生命周期回调里不能阻塞退出流程；DAO 内部已全 catch
    ReadDailyDao.addSeconds(dayKey, hourKey, this.bookId, sec)
      .catch((e: Error): void => {
        console.error('ReadTimeRecorder.addSeconds, Error, ' + e.message)
      })
    // ── 埋点①（2026-10-28）：把同一段秒数交给阅读里程碑推广层累加 ───────────────
    // 与上面的 `addSeconds` 用**同一个 `sec`**（口径完全一致：心跳 + 结算都走本方法，
    // 见 `commitSegment()` 头注释），因此 `ReadPromo` 的"累计阅读秒数"与
    // 阅读时长统计页的数字同源，不会出现"统计页 1h、推广层说没到"的分叉。
    // 内部全 try/catch：写盘失败绝不影响阅读（`ReadPromo.ets addSeconds` 头注释）。
    ReadPromo.addSeconds(sec)
    // 达到上限后停表（下一拍不再累加）
    if (cap > 0 && this.sessionSec >= cap) {
      this.counting = false
      this.segStart = 0
    }
  }

  /** 结束本次会话：结算剩余 + 记一次「单次最长」 */
  private endSession(): void {
    if (!this.counting) {
      return
    }
    this.commitSegment()
    const wasCounting: boolean = this.counting
    this.counting = false
    this.segStart = 0
    if (!wasCounting || this.sessionStart <= 0) {
      this.sessionSec = 0
      return
    }
    const dur: number = this.sessionSec
    this.sessionSec = 0
    if (dur < ReadTimeRecorder.MIN_SESSION_SEC) {
      // 太短：连 seconds 都不该留 ⇒ 把刚写进去的那点也扣掉反而复杂，
      // 这里只保证"不计入次数与最长"，秒数误差 ≤ 10 秒，可接受。
      return
    }
    const dayKey: string = dayKeyOf(this.sessionStart)
    const hourKey: number = new Date(this.sessionStart).getHours()
    ReadDailyDao.finishSession(dayKey, hourKey, this.bookId, dur)
      .catch((e: Error): void => {
        console.error('ReadTimeRecorder.finishSession, Error, ' + e.message)
      })
    this.sessionStart = 0
  }

  private startTimer(): void {
    if (this.timer !== -1) {
      return
    }
    try {
      this.timer = setInterval((): void => {
        if (!this.attached) {
          this.stopTimer() // 防御：漏调 detach 时自愈，绝不留下悬空定时器
          return
        }
        this.flush()
      }, ReadTimeRecorder.HEARTBEAT_MS)
    } catch (e) {
      this.timer = -1
    }
  }

  private stopTimer(): void {
    if (this.timer === -1) {
      return
    }
    try {
      clearInterval(this.timer)
    } catch (e) {
      // 忽略
    }
    this.timer = -1
  }
}

export default ReadTimeRecorder
