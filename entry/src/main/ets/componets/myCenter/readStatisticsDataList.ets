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
  /**
   * 系统底部手势区高度（vp）——
   * 本组件所在的页面容器已用 `ColumnModifier.withoutBottomInset()` **不再让位**，
   * 所以"最后一项不被手势条压住"的职责搬到这里：内容末尾内边距 = bottomRectHeight + 呼吸位。
   * 依据：`docs/底部手势区贯通-排查记录.md:47,94`（盒子不留边，让位走内容末尾）。
   */
  @StorageLink('bottomRectHeight') bottomRectHeight: number = 0
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
        // 2026-10-13：原先**没写 fontColor**（走系统默认字色 token）。默认 token 跟的是
        // Ability 配色（`ctx.setColorMode`），而本页底色/列表文字跟的是 `ShelfColors`
        // （AppStorage 驱动）—— 两套机制在时序不同步时会"暗底 + 深字"。
        // 统一到 `ShelfColors.textMain()`，与页面标题同源。
        .fontColor(ShelfColors.textMain())
    }.padding({top:12,bottom:12})
    .width("100%")
    .justifyContent(FlexAlign.Start)
  }
  //作者及书名
  @Builder bookAuthor(book:readBookList){
    Column({space:12}){
      Text(book.bookName).fontSize(16).lineHeight(24).fontColor(ShelfColors.textMain())
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
        Text(schedule.toString()).fontSize(24).lineHeight(24).fontWeight(600).fontColor(ShelfColors.textMain())
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
         // ── 最后一个条目底部留白（2026-10-13 用户要求「保留最后一个书籍底部的留白」）──
         // ★ 页面盒子已 `withoutBottomInset()`（不再让出手势区）⇒ 手势区高度必须由这里补：
         //   普通态：bottomRectHeight + 16（16 = 基础呼吸位）
         //   管理态：bottomRectHeight + 80（80 = 删除浮条 48 + 上下各 16 呼吸位）
         // ⚠️ 留白必须加在**滚动内容内部**，不能加在滚动容器上：加容器等于把可视区截短，
         //    条目照样会被浮条/手势条压住；加在内容里才能滚出来。
         //    （`Scroll` **没有** `contentEndOffset` —— SDK `scroll.d.ts` 里无该声明，
         //      `list.d.ts` 才有；本工程书架是 List 所以能用 `contentEndOffset`，
         //      这里结构是 Scroll，故用"内容内边距"这条等价路径，与工程排查记录的口径一致。）
         .padding({ bottom: this.bottomRectHeight + (this.delStatus ? 80 : 16) })
       }.scrollable(ScrollDirection.Vertical)
       .scrollBar(BarState.Off)
       // ── 2026-10-13 手感对齐书架（用户反馈「读过页面滑动很生硬，没有 q 弹」）──────
       // 根因是**两个 SDK 默认值不一样**（原文均出自 SDK `.d.ts`）：
       //   · `list.d.ts`   `edgeEffect(...)`「Default value: **EdgeEffect.Spring**」
       //     ⇒ 书架是 `List`，**不写就有回弹**；
       //   · `scroll.d.ts` `edgeEffect(...)`「Default value: <em>EdgeEffect.None</em>」
       //     ⇒ 本组件是 `Scroll`，**不写就没有回弹**；旧代码还显式写了 `None`，
       //        等于把唯一的回弹可能也关掉 ⇒ 滑到底"硬停"，正是用户说的生硬。
       // ⇒ 显式给 Spring。`alwaysEnabled: false` 与 List 的默认一致
       //   （`list.d.ts` 原文「Default value: **{ alwaysEnabled: false }**」）：
       //   内容不足一屏时不弹，避免只有一两本书时整页跟手乱晃。
       .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: false })
       // ⚠️ 2026-10-13 删掉原来的 `.friction(0.6)`：
       //   `scroll.d.ts` / `list.d.ts` 的 `friction` 默认值原文一致 ——
       //   「Since API version 12, the default value for non-wearable devices is **0.75**」。
       //   书架（List）走默认 0.75，本页却写死 0.6（API 10 时代的老默认）
       //   ⇒ 同样手速滑出来的惯性距离与书架不是一个手感。
       //   删掉即继承平台默认，与书架同源；将来要单独调再显式写。
       // ── 2026-10-13 修「底部被遮住一大块」──────────────────────────────────
       // 原为 `.size({width:320, height:"80%"})` + `.padding({bottom:50})`：
       //   · 高度只占父容器的 **80%**、且 `.align(TopStart)` 贴顶
       //     ⇒ 底部约 20% 整块空出来，看起来像被一块遮罩盖住、书籍穿不到底（用户反馈）；
       //   · 再叠 50vp 内边距，"遮住"得更明显。
       // 现在：宽度仍取满（与原来 320 在 360vp 屏上等值），高度交给 `layoutWeight(1)`
       //   吃掉「表头之后」的全部剩余高度 ⇒ 列表一直铺到页面底边（与书架同一逻辑）。
       // ⚠️ 用 `layoutWeight(1)` 而**不是** `height('100%')`：百分比高度会按父容器的
       //    内容区解析，容易把表头那份高度也算进去导致溢出。
       .width(CommonConstants.FULL_WIDTH)
       .layoutWeight(1)
       .align(Alignment.TopStart)
     }
     // 根容器撑满交给它的那块「剩余高度」（由 `readStatistics.ets` 的
     // `layoutWeight(1)` 包裹层确定）⇒ 内部 `layoutWeight` 才有参照。
     .width(CommonConstants.FULL_WIDTH)
     .height('100%')
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

