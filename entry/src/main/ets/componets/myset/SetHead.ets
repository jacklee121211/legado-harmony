import AppRouter from '../../common/router/AppRouter'

@Component
export struct SetHead{


  titleName: string ='标题'

  rightString?: string = ''


  build() {
    Flex({alignItems:ItemAlign.End}){
      Image($r('app.media.return_left'))
        .height(15)
        .onClick(()=>{
          // 迁 Navigation 第 4 期：`MySetPage` 现在是 NavDestination，
          // 原来的 `router.back()` 会把整个 Index 弹掉（直接回桌面）。
          // `AppRouter.back()` 自适应判断该弹哪个栈。
          AppRouter.back();
        })

      Text(this.titleName).width('80%').textAlign(TextAlign.Center)
        .fontSize(16)
        .fontColor($r('app.color.text_primary'))
        .fontWeight(600)

      Text(this.rightString).width('10%').textAlign(TextAlign.Center)
    }.padding({top:12,bottom:12})

  }
}