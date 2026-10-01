export class NavItem {
  /**
   * 标题
   */
  title:string

  /**
   * Index
   */
  index:number

  /**
   * symbol 图标（2026-10-01：四页签全部 symbol 化 —— 原媒体图标对（PNG）的
   * fillColor 不生效、无暗色适配；symbol 的 fontColor 深浅档天然自适应）
   */
  symbol:Resource

  constructor(index = 0 ,title = '', symbol?:Resource) {
    this.title = title
    this.index = index
    this.symbol = symbol as Resource
  }
}

export class MainScrollBar {
  //是否滚动
  isStop:boolean
  //滚动位置
  yOffsetTop:number = 0
  //Scroll
  isScroll:Scroller

  constructor(isStop:boolean,isScroll:Scroller,yOffsetTop:number = 0) {
    this.isStop = isStop
    this.yOffsetTop = yOffsetTop
    this.isScroll = isScroll
  }

}
