/**
 * @author 2008
 * @datetime 2024/7/26 10:58
 * @className: booksUtils
 */
import BookGroupsDao from '../../database/dao/BookGroupsDao'
import BooksDao from '../../database/dao/BooksDao'
import { BookGroups } from '../../database/entities/BookGroups'
import toolsUtils from './ToolsUtils'

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
  async addGroup(books: BookGroups){
    BookGroupsDao.insert(books)
  }
  //删除分组
  async delGroupById(id:number|number[]){
    let Ids = toolsUtils.numberArrays(id)
    if (Ids.length === 0) return
    //删除分组
    BookGroupsDao.deleteBook(Ids)
    //同时更新书籍分组为未分组
    BooksDao.queryBookByGroup(Ids, 3)
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

  //批量更新分组是否显示
  async updateGroupShow(groupId:number|number[], isShow?:boolean){
    let Ids:number[] = toolsUtils.numberArrays(groupId)
    Ids.forEach((item:number)=>{
      BookGroupsDao.updateGroupShow(item,isShow)
    })
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