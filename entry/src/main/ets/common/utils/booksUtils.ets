import BooksDao from '../../database/dao/BooksDao'
import { Books, bookShelfImport, BOOK_SEARCH_TYPE } from '../../database/entities/Books'
import bookGroupUtils from './bookGroupUtils'
import toolsUtils from './ToolsUtils'
import bookRename from './BookRename'

class booksUtils{
  // ⚠️ 必须**逐个 await**（2026-09-29，审核问题②）：
  // 旧实现 `Ids.forEach(item => BooksDao.isUpdateBookTop(item, isTop))` 裸调不等待 ⇒
  // 本方法 resolve 时写库**尚未完成**，调用方（BookManagePage.manageTop）随即重查列表，
  // 查到的还是旧 isTop ⇒ 表现为"置顶成功后数据未实时更新"。
  async isTopBook(id: number|number[], isTop: boolean): Promise<boolean>{
    let Ids:number[] = toolsUtils.numberArrays(id)
    try {
      for (const item of Ids) {
        await BooksDao.isUpdateBookTop(item, isTop)
      }
      return true
    } catch (e){
      return false
    }
  }
  async addBooks(books: Books){
    books.isJoin = true
    books.bookGroup = books.bookGroup??3 //默认未分组
    // ⚠️ 必须 await：旧实现"裸调 insert 不等待"，调用方 `await addBooks()` 拿不到
    // "已入库"的时点 ⇒ 批量导入后立即刷 UI 查不到新数据（2026-09-24 导入竞态修复）。
    await BooksDao.insert(books)
  }
  //校验当前书籍是否存在书架中
  async isExistBooks(bookUrl?:string,bookName?:string): Promise<boolean>{
    let books: Books[] = await BooksDao.isExistBooks(bookUrl, bookName)
    return books.length > 0
  }
  //更新部分书籍信息
  async partialUpdate(books: Books){
    BooksDao.partialUpdate(books)
  }
  //批量添加
  async batchAdd(books: bookShelfImport[], bookType:number){
    books.forEach((item:bookShelfImport)=>{
      let book:Books = {
        bookName: item.name,
        bookUrl: item.bookUrl,
        author: item.author,
        intro: item.intro,
        bookGroup: 3,
        latestChapterTime: 0,
        totalChapterNum: 0,
        durChapterIndex: 0,
        durChapterPos: 0,
        durChapterTime: 0,
        canUpdate: false,
        sort: 0,
        originOrder: 0,
        syncTime: 0,
        bookType: bookType,
        isTop: false,
        isJoin: true,
        isLocalBook: false
      }
      BooksDao.insert(book)
    })
  }
  /**
   * @author 2008
   * @param id 需要移动的书籍Id
   * @param group 移动到的分组Id
   * updateBooks 书籍批量移动
   */
  async updateBooks(id:number|number[], group:number){
    let BookGroupId: Record<number, number> = {}
    //循环更新
    let bookId:number[] = toolsUtils.numberArrays(id)
    //根据书籍获取旧的分组Id
    BookGroupId = await BooksDao.getBookIdsByGroupId(bookId)

    if (Object.values(BookGroupId).map(o=>o).length === 0){
      await bookGroupUtils.updateAddBookIds(group, bookId)
    } else {
      bookGroupUtils.updateMoveBookIdsByGroupId(BookGroupId)
      //同时将新的书籍Id添加到分组中
      bookGroupUtils.updateAddBookIds(group, bookId)
    }
    //再去更新新的书籍的分组
    bookId.forEach((item:number)=>{
      BooksDao.updateBookGroup(item,group)
    })
  }

  async delBooksById(id:number|number[]){
    let BookGroupId: Record<number, number> = {}
    let bookId:number[] = toolsUtils.numberArrays(id)
    // ── 删前取书名（2026-10-05 修 H7，用户口径：「删除算是重置，不再继承」）──────────
    // 以书名为键的存储（阅读进度 / 阅读器设置 / 自定义背景 / 字体覆盖 / 网页同步锚 /
    // 书签 / 浏览历史）都挂在 `BookRename` 的清单里。必须在**删行之前**拿名字，
    // 否则同名重导会继承旧进度与旧设置。
    let names: string[] = []
    try {
      const rows: Books[] = await BooksDao.getBookByIds(bookId)
      names = rows.map((b: Books): string => b.bookName ?? '')
        .filter((n: string): boolean => n !== '')
    } catch (e) {
      console.log('delBooksById: read names failed, ', JSON.stringify(e))
    }
    //根据书籍获取分组Id
    BookGroupId = await BooksDao.getBookIdsByGroupId(bookId)
    if (Object.values(BookGroupId).map(o=>o).length > 0) {
      bookGroupUtils.updateMoveBookIdsByGroupId(BookGroupId)
    }

    BooksDao.deleteBook(bookId)
    // 删行之后清理派生数据（失败只记日志，不影响删除本身 —— 本方法无返回值语义）
    for (const n of names) {
      await bookRename.purge(n)
    }
  }

  async getBookByIds(ids:number|number[]){
    let bookId: number[] = toolsUtils.numberArrays(ids)
    return await BooksDao.getBookByIds(bookId)
  }

  //校验类型数据查询数组内容
  getOrder(type:string){
    return BOOK_SEARCH_TYPE.indexOf(type) ?? 0;
  }
}
let booksUtil = new booksUtils();
export default booksUtil as booksUtils;