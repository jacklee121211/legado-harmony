/**
 * @author 2008
 * @datetime 2024/7/26 10:58
 * @className: booksUtils
 */
import BookGroupsDao from '../../database/dao/BookGroupsDao'
import BooksDao from '../../database/dao/BooksDao'
import { BookGroups } from '../../database/entities/BookGroups'
import { Books } from '../../database/entities/Books'
import { GroupTree } from '../group/GroupTree'
import { HiddenGroups } from '../group/HiddenGroups'
import { GroupEvents } from '../group/GroupEvents'
import toolsUtils from './ToolsUtils'
// 2026-11-02 第 26 轮（B②）：隐藏集合计算委托 GroupStore（唯一实现）
import { GroupStore } from '../group/GroupStore'

/** 2026-11-01：空分组是否自动解散（用户要求保留空目录 ⇒ 默认 false，可一键恢复） */
export const EMPTY_AUTO_DISSOLVE: boolean = false

class bookGroupUtils{
  //校验唯一性,同时进行更新
  async onlyGroupUpdateName(newName: string, id: number) {
    return await BookGroupsDao.onlyGroupUpdateName(id,newName)
  }
  //置顶分组
  // ⚠️ 逐个 await（2026-09-29，审核问题②）：与 booksUtils.isTopBook 同因 ——
  // forEach 裸调不等待 ⇒ 调用方 resolve 后立即重查会查到旧 isTop。
  async isTopGroup(id: number|number[], isTop: boolean) {
    let Ids:number[] = []
    if (typeof id === 'number'){
      Ids.push(id)
    } else {
      Ids = id
    }
    for (const item of Ids) {
      await BookGroupsDao.isUpdateGroupTop(item, isTop)
    }
  }
  //添加分组
  // ⚠️ 2026-11-01：补 `await`（原实现裸调 ⇒ 新建后立刻重查列表可能查不到，
  //   多级文件夹里还必须保证「父组先落库、子组再插入」的顺序）
  async addGroup(books: BookGroups){
    await BookGroupsDao.insert(books)
  }
  //删除分组
  /**
   * 删除分组行 + 组内书籍落到「未分组」（`bookGroup = 3`）。
   *
   * ⚠️ 2026-10-22 改为**逐个 await**（原实现两行全是裸调）：
   *   `BookGroupsDao.deleteBook(Ids)` 与 `BooksDao.queryBookByGroup(Ids, 3)` 都是 async，
   *   裸调 ⇒ 本方法立刻 resolve，调用方紧接着广播刷新时**写库可能还没提交**
   *   ⇒ 界面重查读到旧数据（"删了分组还在 / 书还在旧分组里"）。
   *   这正是 `docs/标准-弹窗与按钮统一规范.md` 第 5 节第 2 条
   *   「广播必须发生在 DB 提交之后」点名的那类坑（同 `updatePartialGroup` 2026-10-01 的修法）。
   *
   * ⚠️ 顺序：**先搬书、再删分组行**（与 `BooksDao.queryBookByGroup` 的语义一致 ——
   *   它按 `bookGroup IN (…)` 找书，不依赖分组行是否存在，但先搬后删语义更清晰）。
   */
  async delGroupById(id:number|number[], emitEvent: boolean = true){
    let Ids = toolsUtils.numberArrays(id)
    if (Ids.length === 0) return
    // ── 2026-11-02 预检：只对真实存在的分组动手，避免"删了不存在的 id"出现假成功 ──
    const groups: BookGroups[] = await BookGroupsDao.search()
    const alive: number[] = []
    for (const gid of Ids) {
      let hit: boolean = false
      for (const g of groups) {
        if ((g.groupId ?? -1) === gid) {
          hit = true
          break
        }
      }
      if (hit) {
        alive.push(gid)
      } else {
        console.error(`[GRP-PRECHECK] delGroupById: 分组不存在 id=${gid}，已跳过`)
      }
    }
    if (alive.length === 0) return
    // ── 2026-11-02 回滚快照：失败时把这些书的 bookGroup 写回原值 ─────────────
    const allBooks: Books[] = await BooksDao.search()
    const snap: Books[] = []
    for (const b of allBooks) {
      if (b.bookGroup !== undefined && alive.indexOf(b.bookGroup) >= 0) {
        snap.push(b)
      }
    }
    try {
      //同时更新书籍分组为未分组
      await BooksDao.queryBookByGroup(alive, 3)
      //删除分组
      await BookGroupsDao.deleteBook(alive)
      // ── 2026-11-02 第 24 轮（D2/S8）两处修正 ─────────────────────────────────
      // ① 事件改到 `refreshHiddenGroupIds()` **之后**：旧写法在 try 内、刷新隐藏集合之前 emit，
      //    万一刷新抛异常就会"事件已发出、随后回滚"，订阅方看到结构变了但数据没变。
      // ② 新增 `emitEvent` 开关（默认 true = 行为不变）：批量场景由调用方传 **一次数组**
      //    或传 false 后统一发一次，满足 S8「一次操作只发一次事件」。
      await this.refreshHiddenGroupIds()
      if (emitEvent) {
        GroupEvents.emit([], [])
      }
    } catch (e) {
      console.error(`[GRP-ROLLBACK] delGroupById 失败 ids=${alive.join(',')}：${JSON.stringify(e)}`)
      let restored: number = 0
      for (const b of snap) {
        if (b.id === undefined) {
          continue
        }
        try {
          await BooksDao.updateBookGroup([b.id], b.bookGroup)
          restored++
        } catch (e2) {
          console.error(`[GRP-ROLLBACK] 书回滚失败 bookId=${b.id}: ${JSON.stringify(e2)}`)
        }
      }
      console.error(`[GRP-ROLLBACK] 已回滚 ${restored}/${snap.length} 本`)
      throw e as Error
    }
  }

  /**
   * 2026-11-01：**解散**分组（与「删除」语义区分开）
   *
   * 用户需求：「子目录被解散后，书应该还给父目录」，而不是落到「未分组」。
   * 因此本方法：
   *   ① 组内直属书的 `bookGroup` 改为**该组的 parentId**（父为根时用 3 = 未分组）；
   *   ② 直属**子分组**的 `parentId` 挂到同一父级（不是跟着删除），避免孙目录变孤儿；
   *   ③ 最后才删本分组行。
   *
   * ⚠️ 全部 `await`，保证调用方随后广播刷新时写库已提交
   *   （同 `delGroupById` 2026-10-22 的教训）。
   */
  async dissolveGroup(id: number, mode: string = 'keepChildren', emitEvent: boolean = true): Promise<void> {
    if (id <= 0) {
      return
    }
    const groups: BookGroups[] = await BookGroupsDao.search()
    let parentId: number = 0
    let exists: boolean = false
    for (const g of groups) {
      if ((g.groupId ?? -1) === id) {
        parentId = g.parentId ?? 0
        exists = true
        break
      }
    }
    // ── 2026-11-02 预检：分组不存在 ⇒ 直接返回（不半途改库、不误删） ──────────
    if (!exists) {
      console.error(`[GRP-PRECHECK] dissolveGroup: 分组不存在 id=${id}，已跳过`)
      return
    }
    const target: number = parentId > 0 ? parentId : 3
    // ── 2026-11-02 回滚快照：记录"哪些书来自哪个分组"，失败按快照逆序恢复 ──────
    const idsPreview: number[] = mode === 'collapse' ? GroupTree.build(groups).subtreeIds(id) : [id]
    const allBooks: Books[] = await BooksDao.search()
    const bookSnap: Books[] = []
    for (const b of allBooks) {
      if (b.bookGroup !== undefined && idsPreview.indexOf(b.bookGroup) >= 0) {
        bookSnap.push(b)
      }
    }
    try {      if (mode === 'collapse') {
        // 2026-11-01：**全部解散** —— 整棵子树的书全部上提到父级，子树目录行全删
        const tree: GroupTree = GroupTree.build(groups)
        const ids: number[] = tree.subtreeIds(id)
        await BooksDao.queryBookByGroup(ids, target)
        await BookGroupsDao.deleteBook(ids)
        await this.refreshHiddenGroupIds()
        // 2026-11-02 第 24 轮（D2）：解散原来**一次事件都不发** ⇒ 批量页的 S6 清空永远不触发、
        //   真机上"解散后取不到 [GRP-EVENT]"就是这条导致的。放在最后一个 await 之后 = 成功才发。
        if (emitEvent) {
          GroupEvents.emit([], [])
        }
        return
      }
      // ① 直属书归还父级
      await BooksDao.queryBookByGroup([id], target)
      // ② 子分组挂到同一父级（保持层级不断链）
      const moved: number[] = []
      for (const g of groups) {
        if ((g.parentId ?? 0) === id && g.groupId !== undefined && g.groupId !== id) {
          moved.push(g.groupId)
        }
      }
      for (const cid of moved) {
        for (const g of groups) {
          if ((g.groupId ?? -1) === cid) {
            g.parentId = parentId > 0 ? parentId : 0
            await BookGroupsDao.update(g)
            break
          }
        }
      }
      // ③ 删本分组行
      await BookGroupsDao.deleteBook([id])
      // 2026-11-02 第 24 轮（D2）：同上 —— 成功之后发**唯一一次**结构变更事件（最后一步，失败则不发）
      if (emitEvent) {
        GroupEvents.emit([], [])
      }
    } catch (e) {
      // ── 失败回滚：把动过的书按快照写回原分组 ────────────────────────────────
      console.error(`[GRP-ROLLBACK] dissolveGroup 失败 id=${id} mode=${mode}，开始回滚：${JSON.stringify(e)}`)
      let restored: number = 0
        for (const b of bookSnap) {
          if (b.id === undefined) {
            continue
          }
          try {
            await BooksDao.updateBookGroup([b.id], b.bookGroup)
            restored++
          } catch (e2) {
            console.error(`[GRP-ROLLBACK] 书回滚失败 bookId=${b.id}: ${JSON.stringify(e2)}`)
          }
        }
      console.error(`[GRP-ROLLBACK] 已回滚 ${restored}/${bookSnap.length} 本`)
      throw e as Error
    }
  }

  /**
   * 2026-11-02 第 24 轮（D2 + S8）：**批量解散，只发一次事件**。
   *
   * 为什么不能由调用方 for 循环 `dissolveGroup(gid, mode)`：那样 N 个分组会发 N 次事件，
   * 违反 S8「一次操作只发一次 `GroupChanged`」（真机已实测同类问题：批量删 2 个分组 = 2 条事件）。
   * 这里逐个原子解散（每个都有自己的预检/回滚），最后统一 emit 一次。
   *
   * ⚠️ 失败语义：任一分组解散抛异常 ⇒ **不 emit**（异常原样抛给调用方去提示"解散失败"），
   *   `refreshHiddenGroupIds()` 由各个 `dissolveGroup` 内部按需刷新。
   */
  async dissolveGroups(ids: number[], mode: string = 'keepChildren', emitEvent: boolean = true): Promise<void> {
    if (ids.length === 0) {
      return
    }
    for (const id of ids) {
      await this.dissolveGroup(id, mode, false)
    }
    if (emitEvent) {
      GroupEvents.emit([], [])
    }
  }

  /**
   * 2026-11-02：**需要排除的分组 id 集合** —— 所有 `show=false` 分组及其整棵子树。
   * 用于 `BooksDao.setHiddenGroupIds()`，实现"隐藏组的书与计数全部排除"。
   */
  async hiddenSubtreeIds(): Promise<number[]> {
    // 2026-11-02 第 26 轮（B②）：**完全委托 `GroupStore.hiddenIds()`**。
    //   这里的实现原本与它逐字重复（父隐藏 ⇒ 整棵子树隐藏 + `!g.show` 的 number 判定），
    //   两处改一处忘另一处就会分叉 —— 未通过清单 #20 那类"隐藏后书还在「全部」列表"
    //   正是这种分叉的后果。`refresh()` 保证读到库里最新状态（本方法调用点都在写操作之后）。
    await GroupStore.refresh()
    return GroupStore.hiddenIds()
  }

  /**
   * **空分组自动解散**（2026-10-12 新增，用户需求原文：
   * 「自定义分组空了之后没有自动解散并更新刷新」「自定义分组没有书籍会自动解散」）。
   *
   * 用法：在**任何可能让分组变空的写操作之后**调用 ——
   * `BookSelectGroupDialog.clickBookAccept()`（单本/批量移出）已接；
   * 管理页删书、其它移动路径将来也应接这里，别各写一份。
   *
   * ── 为什么必须有它（而不是散在各处的 `if (count === 0) delGroupById()`）────
   * ① 判据统一：用 `BooksDao.queryBooksByGroupId`（精准 `bookGroup IN (…)`），
   *    **不叠加** `bookType` 过滤 —— 分组里的书 bookType 可能与当前页签不同，
   *    用 `searchPage({bookGroup, type})` 会误判成"空"（上一版就是这么漏的）；
   * ② 系统分组**永不**解散（`isSystem`，即「全部/分组/书单」那些聚合条目）；
   * ③ 「未分组」不是一个真分组（`bookGroup = 3` 是 `books` 表里的特殊值，
   *    `book_groups` 里没有对应行），传 3 会被跳过；
   * ④ 返回是否**真的解散了**，让调用方据此决定要不要广播刷新
   *    （刷新是调用方的职责：不同页面对键的依赖不同）。
   *
   * @param groupIds 候选分组 id（通常就一个：刚被移空的那个）
   * @returns true = 至少解散了一个分组（调用方应广播分组刷新）
   */
  async dissolveIfEmpty(groupIds: number | number[]): Promise<boolean> {
    // 2026-11-01（用户拍板）：**空目录一律保留**，不再自动解散。
    //   改 `EMPTY_AUTO_DISSOLVE = true` 即恢复旧行为（一键回退）。
    if (!EMPTY_AUTO_DISSOLVE) {
      return false
    }
    const ids: number[] = toolsUtils.numberArrays(groupIds)
      .filter((g: number): boolean => g > 0 && g !== 3)  // ③ 跳过「未分组」
    if (ids.length === 0) {
      return false
    }
    let dissolved: boolean = false
    for (const gid of ids) {
      try {
        // ② 系统分组永不解散
        const groups: BookGroups[] = await BookGroupsDao.search()
        const hit: BookGroups | undefined = groups.find((g: BookGroups): boolean => g.groupId === gid)
        if (hit === undefined || hit.isSystem) {
          continue
        }
        // ① 精准判空
        const bookIds: number[] = await BooksDao.queryBooksByGroupId([gid])
        if (bookIds.length > 0) {
          continue
        }
        // 空 ⇒ 解散（delGroupById 内部同时把组内书置 3，此处组已为空，属幂等）
        await this.delGroupById(gid)
        dissolved = true
      } catch (err) {
        console.error(`bookGroupUtils.dissolveIfEmpty failed at ${gid}: ` + JSON.stringify(err))
      }
    }
    return dissolved
  }

  /**
   * **预取分组列表**（2026-10-12 新增，配合 `BookSelectGroupDialog.presetGroups`）。
   *
   * 为什么需要：`BookSelectGroupDialog` 的列表原本在 `aboutToAppear()` 里**异步**查库，
   * 弹窗打开的瞬间 `groupList` 还是空的 ⇒ 用户看到"分组要过一会儿才出现"
   * （用户原话：「此时未分组还没被刷新出来，过一会儿才刷新出来」）。
   * 调用方在 `controller.open()` **之前** await 本方法，把结果传进弹窗即可首帧成型。
   *
   * ⚠️ **不要**在这里调 `fillRealBookIds`：那是给"要显示共 N 本"的卡片用的，
   *    按分组逐条查库（N 次）。本弹窗只显示分组名，不需要计数
   *    （方法自己的注释也写明「别放进高频路径」）。
   *
   * @param type 分组类型（= 书架页签 `currentIndex`）
   */
  async prefetchGroups(type: number): Promise<BookGroups[]> {
    try {
      return await BookGroupsDao.search({ type: type })
    } catch (err) {
      console.error('bookGroupUtils.prefetchGroups failed: ' + JSON.stringify(err))
      return []
    }
  }

  //管理页面批量移动分组
  /**
   * @author 2008
   * @param oldGroup
   * @param newGroup
   * 分组批量移动
   */
  async moveBookByGroupId(oldGroup: number | number[], newGroup: number) {
    try {
      let Ids: number[] = toolsUtils.numberArrays(oldGroup)
      //如果Ids里面有存在newGroup则把Ids移除
      if (Ids.includes(newGroup)) {
        Ids = Ids.filter(item => item !== newGroup);
      }
      // 根据旧的分组Id获取书籍Id
      const booksInGroup = await BooksDao.queryBooksByGroupId(Ids);

      // 更新书籍分组
      await BooksDao.updateBookGroup(booksInGroup, newGroup);

      //将旧分组书籍id移除
      BookGroupsDao.updateMoveGroupBookIds(Ids)

      //更新移动的分组下的bookId将GroupBookIds中的值添加到新的分组中
      BookGroupsDao.updateAddBookIds(newGroup, booksInGroup.map(val => val.toString()))

    } catch (e) {
      console.log('moveBookByGroupId, Error, ', JSON.stringify(e));
    }
  }

  /**
   * 批量更新分组是否显示。
   *
   * ⚠️ 2026-10-13 必须逐个 `await`（原实现 `Ids.forEach` 裸调 DAO）：
   * 书架「分组管理」面板改成"点一下自定义分组就隐藏/恢复"之后，点击回调紧跟着
   * 重查分组列表 + 广播刷新 —— 裸调的话 DAO 里的 UPDATE 可能还没提交，重查读到**旧** `show`
   * ⇒ 表现为"点了没反应，关掉弹窗再开才对"（同类坑：`updatePartialGroup` 2026-10-01 已修，
   * 依据 `docs/标准-弹窗与按钮统一规范.md` 第 5 节第 2 条「广播必须发生在 DB 提交之后」）。
   */
  async updateGroupShow(groupId:number|number[], isShow?:boolean){
    const ids:number[] = toolsUtils.numberArrays(groupId)
    for (const id of ids) {
      await BookGroupsDao.updateGroupShow(id,isShow)
    }
    // 2026-11-02：可见性变了 ⇒ 立刻刷新全局隐藏集合（所有书籍查询共用）
    await this.refreshHiddenGroupIds()
  }

  /**
   * 2026-11-02：**刷新全局隐藏分组集合**（`HiddenGroups.ids`）。
   * 分组结构/可见性变化后必须调用，否则搜索页等调用方会漏过滤。
   */
  async refreshHiddenGroupIds(): Promise<number[]> {
    const ids: number[] = await this.hiddenSubtreeIds()
    HiddenGroups.set(ids)
    return ids
  }

  //更新分组的bookIds
  async updateAddBookIds(newGroupId:number,bookId:number|number[]){
    //循环更新
    let book:number[] = toolsUtils.numberArrays(bookId)

    if(newGroupId && bookId){
      BookGroupsDao.updateAddBookIds(newGroupId, book.map(val => val.toString()))
    }
  }

  //移除分组下的bookId
  updateMoveBookIdsByGroupId(data:Record<number, number>){
    BookGroupsDao.updateMoveBookIdsByGroupId(data)
  }

  //分组批量移动书籍
  updateMoveGroupBookIds(data:Record<number, number>){
    BookGroupsDao.updateMoveBookIdsByGroupId(data)
  }
  //根据分组获取分组下的书籍Id
  async queryBookByGroupId(groupId:number|number[]){
    let Ids:number[] = toolsUtils.numberArrays(groupId)
    return await BookGroupsDao.queryBookByGroup(Ids)
  }

  //更新分组部分数据
  async updatePartialGroup(data:BookGroups){
    // 2026-10-01 必须 await：DAO 内是 async 更新，裸调不等待 ⇒ 调用方（分组封面弹窗
    // applyGroupCover）紧跟着广播刷新信号时，UPDATE 可能尚未提交，重查读到旧值。
    await BookGroupsDao.updatePartialGroup(data)
  }

  /**
   * 用 `books.bookGroup` **现算**每个分组下的书籍 id（覆盖 `book_groups.bookIds` 这个陈旧冗余列）。
   *
   * ── 为什么要现算（真机 DB + 源码双取证，2026-10-06）──────────────────────────
   * · `book_groups.bookIds` 只在「移动分组」时追加（`BookGroupsDao.updateAddBookIds`），
   *   导入 / 删除 / 建组都不同步。真机 novel.db 实测：`groupId=6`（自建分组"1"）名下
   *   8 本书（`books.bookGroup=6`），而该列是**空串**；
   * · `DbUtil.parseResultSet` 把空串读成 `undefined`（`DbUtil.ets:333`）⇒
   *   `bookIds?.length || 0` 恒为 0 ⇒ 真机分组卡片显示"共0本"（未分组曾在 BookFolder
   *   里单独现算，所以只有它是对的 —— 现在统一到这里，卡片与"点进去"的列表同源）。
   * · 计数 WHERE 与分组内列表查询同源（`BooksDao.buildWhereClause`）⇒ 数字 == 列表条数。
   *
   * ⚠️ 只重写**内存对象**的 `bookIds`，不落库：`BookGroupsDao.getPartialColumn()` 不含
   *    `bookIds`（换封面走 updatePartialGroup）⇒ 不会被写回数据库。
   * ⚠️ 调用方必须是"要显示共N本"的地方；本方法按分组逐条查库（N 次），别放进高频路径。
   */
  async fillRealBookIds(groups: BookGroups[], type?: number): Promise<void> {
    for (const group of groups) {
      // 只算会被渲染的卡片：隐藏分组不显示；除「未分组」外的系统单元（分组/全部/本地/书单）
      // 不是"装书的地方"（口径见 BookFolder.build / BookFolderManages.build 的过滤条件）。
      if (group.groupId === undefined || !group.show) {
        continue
      }
      if (group.isSystem && group.groupName !== '未分组') {
        continue
      }
      group.bookIds = await BooksDao.queryBookIds({ type: type, bookGroup: group.groupId })
    }
  }
}
let bookGroupUtil = new bookGroupUtils();
export default bookGroupUtil as bookGroupUtils;