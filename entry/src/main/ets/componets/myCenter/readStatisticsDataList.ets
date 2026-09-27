import CommonConstants from '../../common/constants/CommonConstants'
import { Haptics } from '../../common/utils/Haptics';
import { PublicConstants } from '../../common/constants/PublicConstants'
import { readBookList } from '../dataList/readBookList'
import { NightMode, ShelfColors } from '../../common/utils/NightMode'


@Component
export struct readStatisticsDataList{
  @Prop dateValue:number[]
  /** 表头口径文案：「读过」/「读完」（由 `readStatistics.ets` 按 type 传入） */
  @Prop headLabel:string = '读过'
  @Link bookList:readBookList[]
  @State translateX:number=0
  @State bookIndex:number=0
  @State screenStartX: number = 0
  @State screenStartY: number = 0
  @State lastScreenX: number = 0
  @State lastScreenY: number = 0
  @Consume delStatus:boolean
  /** App 级深浅色：订阅只为深浅切换时触发重绘（取色走 `ShelfColors`） */
  @StorageLink(NightMode.KEY) nightOn: boolean = false
  @Builder text(value:string,back:ResourceColor=ShelfColors.textSub()){
    Text(value)
      .fontSize(12)
      .fontWeight(400)
      .lineHeight(20)
      .fontColor(back)
  }
  scroller: Scroller = new Scroller()
  // 时间 本数
  /**
   * ⚠️ **这个 @Builder 绝对不能带参数**（2026-09-21 真机 bug 根因）。
   *
   * ArkUI 的 `@Builder` **按值传参**时不会随状态变量刷新。官方文档原文
   * （documentId：`开发指南/ArkUI_方舟UI框架/UI开发_ArkTS声明式开发范式/学习UI范式基本语法/`
   *   `组件扩展/Builder装饰器_自定义构建函数/arkts-builder`）：
   *
   *   > #### 按值传递参数
   *   > 调用@Builder装饰的函数默认按值传递。当传递的参数为状态变量时，
   *   > 状态变量的改变不会引起@Builder函数内的UI刷新。
   *   > ...
   *   > // 按值传递参数，状态变量的改变不会引起overBuilderByValue内的UI刷新
   *
   * 原实现是 `readHeader(dateValue:number[])` + `this.readHeader(this.dateValue)`：
   * `dateValue` 这个 `@Prop` 被**按值**传进去 ⇒ 表头永远停在**首次渲染**时的值。
   * 而首次渲染发生在 `readStatistics.aboutToAppear()` 里的 `loadData()` 完成**之前**，
   * 所以真机上表头一直显示初始值 —— 也就是底座样例遗留的硬编码 `[2023, 36]`：
   * 「2023年读过36本」（读过、读完两个二级页都会中招）。
   *
   * 改成无参、直接读 `this.dateValue` / `this.headLabel`，状态一变就刷新。
   */
  @Builder readHeader(){

    Row(){
      Text(`${this.dateValue[0]}年${this.headLabel}${this.dateValue[1]}本`)
        .fontSize(16)
        .lineHeight(24)
        .fontWeight(500)
    }.padding({top:12,bottom:12})
    .width("100%")
    .justifyContent(FlexAlign.Start)
  }
  //作者及书名
  @Builder bookAuthor(book:readBookList){
    Column({space:12}){
      Text(book.bookName).fontSize(16).lineHeight(24)
      Column(){
        this.text(book.author)
        // ⚠️ 「累计阅读X小时Y分钟」已移除（2026-09-21）。
        //   原实现传进来的是 `[当前章号, 总章数]`（见 readStatistics.ets 的构造），
        //   被这里当小时/分钟渲染 ⇒ 数字全是假的（例如「累计阅读0小时765分钟」）。
        //   真实的阅读时长本应来自 `readRecord` 表的 `readTime` 列
        //   （`AppDatabase/index.ets:1750` 建表），但**全工程没有任何代码写它**，
        //   属于"有表无写入"的半成品 ⇒ 按用户决定**先隐藏**，不再显示假数字。
      }.alignItems(HorizontalAlign.Start)
    }.alignItems(HorizontalAlign.Start)
    .width("50%")
    .height(80)
    .justifyContent(FlexAlign.SpaceBetween)
    .margin({left:12})
  }
  //时间及进度
  @Builder bookTime(status:boolean,dateTime:Date,schedule:number,index:number){
    Column({space:30}){
      if(this.delStatus){
        Checkbox({ name: 'checkbox1'+index, group: 'checkboxGroup' })
          .select(status)
          .selectedColor(0xed6f21)
          .shape(CheckBoxShape.CIRCLE)
          .onChange((value: boolean) => {
            Haptics.tap();
            this.bookList[index].status=value
          })
          .transition(
            TransitionEffect.asymmetric(
              TransitionEffect.OPACITY.animation({ duration: 500 }).combine(
                TransitionEffect.translate({ x: 100 }).animation({ duration: 500 }))
              ,
              TransitionEffect.OPACITY.animation({ delay: 500, duration: 1000 }).combine(
                TransitionEffect.translate({ x: 100 }).animation({ duration: 500 }))
            )
          )
      }else{
        Text(this.dateTimeToString(dateTime))
          .fontSize(12)
          .fontWeight(400)
          .lineHeight(20)
          .fontColor(ShelfColors.textSub())
          .transition(
            TransitionEffect.asymmetric(
              TransitionEffect.OPACITY.animation({ duration: 500 }).combine(
                TransitionEffect.translate({ x: 0 }).animation({ duration: 0 }))
              ,
              TransitionEffect.OPACITY.animation({ delay: 500, duration: 1000 }).combine(
                TransitionEffect.translate({ x: 100 }).animation({ duration: 500 }))
            )
          )
      }
      Row(){
        this.text("读到")
        Text(schedule.toString()).fontSize(24).lineHeight(24).fontWeight(600)
        this.text("%")
      }
    }.alignItems(HorizontalAlign.End)
    .justifyContent(FlexAlign.SpaceBetween)
    .width("25%")
    .padding(0)
    .height(80)
  }
  build() {
     Column(){
       this.readHeader()
       Scroll(){
         Column(){
           ForEach(this.bookList,(book:readBookList,index:number)=>{
             Row(){
               Row(){
                 Row(){
                   //封面
                   Image(book.coverImage)
                     .alt($r('app.media.icon_book_default_cover_one'))
                     // 视觉升级（2026-09-21）：与书架封面统一圆角 + 柔和投影。纯增量属性。
                     .borderRadius(4)
                     .shadow({ radius: 8, color: 'rgba(0, 0, 0, 0.18)', offsetX: 0, offsetY: 3 })
                     .size({width:60,height:80})
                   //书名作者及阅读时长
                   this.bookAuthor(book)
                   //时间和进度
                   this.bookTime(book.status,book.dateTime,book.schedule,index)
                 }.padding(16).width("100%")
                 Row(){
                   Text("删除").fontColor(PublicConstants.THEME_COLOR_WHITE)
                 }.width(70).height(110).backgroundColor(Color.Red)
                 .justifyContent(FlexAlign.Center)
               }.justifyContent(FlexAlign.End)
               .translate({x:this.bookIndex==index?this.translateX:0})
               .animation({
                 duration: 500,
                 curve: Curve.FastOutSlowIn
               })
               .onTouch((e) => {
                 this.ouTouch(e)
               })
               .gesture(
                 SwipeGesture({ direction: SwipeDirection.All })
                   .onAction(() => {
                     if(!this.delStatus){
                       console.log(index+"")
                       this.bookIndex=index
                       let direction =this.directionIf()
                       if(direction==="Left"){
                         this.translateX=-70
                       }else{
                         this.translateX=0
                       }
                     }
                   })
               )
             }.width(CommonConstants.FULL_WIDTH)
             .backgroundColor(ShelfColors.card())
             .borderRadius(12)
             .margin({bottom:16})
             .clip(true)
           })
         }
       }.scrollable(ScrollDirection.Vertical)
       .scrollBar(BarState.Off) // 滚动条常驻显示
       .friction(0.6)
       .edgeEffect(EdgeEffect.None)
       .size({width:320,height:"80%"})
       .padding({bottom:50})
       .align(Alignment.TopStart)
     }
  }

  ouTouch(e:TouchEvent){
    if (e.type === TouchType.Down && e.touches.length > 0) { // 触摸开始，记录初始位置
      this.screenStartX = e.touches[0].screenX;
      this.screenStartY = e.touches[0].screenY;
    } else if (e.type === TouchType.Up && e.changedTouches.length > 0) { // 当手指抬起时，更新最后的位置
      this.lastScreenX = e.changedTouches[0].screenX;
      this.lastScreenY = e.changedTouches[0].screenY;
    }
  }


  directionIf():string{
    const swipeX = this.lastScreenX - this.screenStartX;
    const swipeY = this.lastScreenY - this.screenStartY;
    // 判断滑动方向
    let directionText = '';
    if (Math.abs(swipeX) > Math.abs(swipeY)) {
      if (swipeX > 0) {
        directionText = 'Right'; // 向右滑动
      } else {
        directionText = 'Left'; // 向左滑动
      }
    }
    return directionText
  }
  dateTimeToString(date:Date){
    let year=date.getFullYear()
    let month=date.getMonth()+1
    let day=date.getDate()
    return `${year}/${month}/${day}`
  }


}

