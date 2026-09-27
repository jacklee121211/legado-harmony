/**
 * @author 2008
 * @datetime 2024/7/22 21:21
 * @className: Books
 * 书籍
 */
import { readerCore } from '@kit.ReaderKit';

@Observed
export class Books {
  //书籍ID
  id?: number;
  //书籍存储路径
  bookUrl?: string
  //目录页Url
  toUrl?: string
  // 书源URL
  origin?: string
  //书源名称 or 本地书籍文件名
  originName?: string
  // 书籍名称(书源获取) 或则自定义书籍名称
  bookName: string = ""
  // // 作者名称(书源获取)
  author: string = ""
  //分类信息(书源获取)
  cover?: string
  //分类信息
  customTag?: string
  //封面Url(书源获取)
  coverUrl?: string
  //自定义封面Url
  customCoverUrl?: string
  //简介内容(书源获取)
  intro?: string
  //简介内容(用户修改)
  customIntro?: string
  //自定义字符集名称(仅适用于本地书籍)
  charset?: string
  //在导入的情况下或则未分组默认为2 未分组
  bookGroup: number = 3;
  // 最新章节标题
  latestChapterTitle?: string
  // 最新章节标题更新时间
  latestChapterTime: number = 0;
  //最近一次更新书籍信息的时间
  lastCheckTime?: number
  //最近一次发现新章节的数量
  lastCheckCount?: number
  //书籍目录总数
  totalChapterNum: number = 0;
  //当前章节名称
  durChapterTitle?: string
  //当前章节索引
  durChapterIndex: number = 0
  //当前阅读的进度(首行字符的索引位置)
  durChapterPos: number = 0
  //本地书籍阅读的进度
  localBookDurChapterPos?:readerCore.PageDataInfo|null = null
  //最近一次阅读书籍的时间(打开正文的时间)
  durChapterTime: number = 0
  /**
   * 「曾经读完」的时间戳（0 = 从未读完）。
   *
   * 为什么不能只看 `durChapterIndex`：进度**会回退**（读完后回第一章重看），
   * 而需求是「达到过 100% 就算读完，同一本第二次 100% 不重复计」。
   * 故单独记一个**只写一次**的标记：读到末章时若本字段为 0 才写入 Date.now()。
   *
   * 迁移：本列是后加的，老库不会自动有 ⇒ 由 `AppDatabase/index.ets` 的
   * `ALTER TABLE books ADD COLUMN finishedTime INTEGER NOT NULL DEFAULT 0` 补齐
   * （try/catch 容忍"列已存在"）。
   *
   * 声明成**可选**（`?`）是必须的：工程内有多处 `Books` 字面量（`booksUtils.ets:35`、
   * `FileHandler.ets:52` 等）没有该字段，若声明为必填会直接编译失败。
   * 读取处一律用 `?? 0` 兜底。同文件 `createTime?: number = 0` 即此写法先例。
   */
  finishedTime?: number = 0
  //字数
  wordCount?: string
  //刷新书架时更新书籍信息
  canUpdate: boolean = true
  //排序
  sort: number = 0
  //书源排序
  originOrder: number = 0
  //同步时间
  syncTime: number = 0
  //小说0/漫画1/有声2
  bookType: number = 0
  //是否置顶
  isTop: boolean = false
  //创建时间
  createTime?: number = 0
  //更新时间
  updateTime?: number = 0
  //是否加入书架
  isJoin: boolean = false
  //是否本地导入
  isLocalBook: boolean = false
}

export class bookShelfImport {
  name: string = ""
  author: string = ""
  intro: string = ""
  bookUrl: string = ""

  constructor(bookShelf: bookShelfImport) {
    this.name = bookShelf.name
    this.author = bookShelf.author
    this.intro = bookShelf.intro
    this.bookUrl = bookShelf.bookUrl
  }
}

export const BOOK_SEARCH_TYPE: string[] = ['最近阅读', '更新排序', '手动排序']