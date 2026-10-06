/**
 * protocol.types.ts —— 协议里的**数据结构**（纯类型，无运行时代码）
 * 单独一个文件是为了让 Node 的 `--experimental-strip-types` 能直接跑测试
 * （类型剥离要求"类型与运行时代码可分离"；`import type` 是显式声明的边界）。
 */

/** 两端统一的「位置描述」（字段含义见手机端 SyncConfig.ets 的同名接口） */
export interface SyncPos {
  /** 结构版本 */
  v: number
  /**
   * 全局单调序号（**中继站核心**，2026-10-05）。由手机进程统一分配
   * ⇒ 跨写者可比、对两端时钟免疫。排序一律用 seq，**不要用 ts**。
   */
  seq: number
  /** 章标题（两端都有；用于章节级匹配） */
  chTitle: string
  /** **本端**章序（禁止跨端使用：两端切分口径不同） */
  chIndex: number
  /** **本端**总章数 */
  chCount: number
  /** chIndex / chCount（跨端可换算的章级比例；未知为 -1） */
  ratio: number
  /** 页首摘录（去空白，约 40 字） */
  topEx: string
  /** 页末摘录（去空白，约 40 字） */
  botEx: string
  /** 章内位置比例 0~1（未知为 -1） */
  posRatio: number
  /** 毫秒时间戳（写者本机时钟；仅显示与"未来时间"保护用，**不用于排序**） */
  ts: number
  /** 'phone' | 'web:<webId>' */
  writer: string
}

/** 手机端下发的目录项（M3 单源目录）：字符区间是**书籍原始文本**里的偏移 */
export interface TocEntry {
  title: string
  charStart: number
  charEnd: number
}

/** 书签行（与手机端 bookmarks 表字段同名，网页只读展示 + 增删） */
export interface MarkRow {
  time: number
  chapterIndex: number
  chapterName: string
  bookText: string
  /** 网页书签的稳定身份 webKey（手机加的书签此列为空） */
  content: string
}

/** `/sync` GET 的响应（手机端位置槽 + 中继站的"最新写者"） */
export interface SyncGetResponse {
  ok: boolean
  src?: string
  title?: string
  chTitle?: string
  topEx?: string
  botEx?: string
  ts?: number
  seq?: number
  ratio?: number
  posRatio?: number
  chCount?: number
  /** 中继站：最新一次写入的写者（'phone' / 'web:<id>'）；空 = 未知 */
  latestWriter?: string
  latestSeq?: number
}
