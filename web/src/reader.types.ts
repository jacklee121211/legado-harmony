/**
 * reader.types.ts —— 前端内部类型（与协议类型分开，避免循环依赖）
 */

/** 三种版式。'page1' 单页 / 'page2' 双页（跨页展开） */
export type Mode = 'scroll' | 'page1' | 'page2'

/** 定位结果（`Reader.jumpToRemote` 的返回，便于 toast 说明与单测） */
export type LocateBy = 'title' | 'ratio' | 'text' | 'posRatio' | 'none'

export interface LocateResult {
  by: LocateBy
  chapterIndex: number
  paraIndex: number
  offset: number
}
