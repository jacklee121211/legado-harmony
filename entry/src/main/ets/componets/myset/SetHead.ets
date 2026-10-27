import AppRouter from '../../common/router/AppRouter'

@Component
export struct SetHead{


  titleName: string ='标题'

  rightString?: string = ''


  build() {
    // ══ 标题"真居中"重构（2026-10-28，用户反馈「顶部关于我们的标题没有居中」）══════════
    // ── 旧实现为什么偏左（已核对 SDK 原文，不是猜）─────────────────────────────
    //   旧代码：Flex({alignItems:ItemAlign.End}){ Image(箭头) ; Text(title).width('80%') ;
    //           Text(rightString).width('10%') }，**未设 justifyContent**。
    //   证据：SDK `ets/component/flex.d.ts:57-66`
    //         "Alignment mode of the child components in the **Flex** component along the main axis.
    //          ... Default value: **FlexAlign.Start**."
    //   ⇒ 三个子项首尾相接地从 Flex 左端排起（宽度合计 = 0.9W + arrowW）：
    //         箭头 [0, arrowW]、标题 [arrowW, arrowW+0.8W]、右文本 [… +0.8W, … +0.9W]
    //     标题盒中心 = arrowW + 0.4W（相对 Flex 左端）。两种可能的容器宽度模型都算一遍：
    //       · Flex 被撑满整屏（左端 = 0）      ⇒ 中心 = 0.4W + arrowW ＜ 0.5W
    //       · Flex 按内容宽度被 Column 居中     ⇒ 左端 = (W − 0.9W − arrowW)/2
    //                                           ⇒ 中心 = 0.45W + arrowW/2 ＜ 0.5W
    //   ⇒ **两种模型都恒偏左**（箭头越宽偏得越多），调 80%/10% 只能减轻、不能消除。
    //   官方同类结论：FAQ `faqs-arkui-713`
    //     「FlexAlign.SpaceBetween ... 当其子组件长度不一致时，并不能实现居中显示的效果」
    // ── 新实现：Stack 分成"居中标题层"+"两端层"，标题位置不依赖任何兄弟节点的宽度 ──────
    //   ① 标题自己占满整行（width 100%），文本在盒内居中（textAlign Center）
    //      ⇒ 文本中心 = 容器宽 W 的中心 = W/2 = 屏幕中心。**与箭头宽度、右侧文字宽度无关。**
    //   ② 箭头/右侧文字放进覆盖层的 Row（两端贴边），不再参与标题的水平定位。
    //   官方推荐做法正是这个结构：FAQ `faqs-arkui-713` 方案一
    //     「通过 Stack 组件将需要对齐的子组件单独居中布局，其它子组件两端布局」。
    //   Stack 的默认对齐 = 子组件在容器内居中：
    //     证据：SDK `ets/component/stack.d.ts:39-46`（StackOptions.alignContent）
    //           "Alignment of child components in the container. Default value: Alignment.Center."
    //           `stack.d.ts:100-105` 同名属性 alignContent(value: Alignment) 默认值同为 Alignment.Center。
    //   先入栈者在下的顺序保证箭头可点：`stack.d.ts:124-129`
    //     "The Stack component provides a stack container where child components are successively
    //      stacked and **the latter one overwrites the previous one**."
    //   ⇒ 标题层先写、两端层后写 ⇒ 箭头/右文本画在标题之上，标题的整行盒子不会截走箭头的点击。
    Stack({ alignContent: Alignment.Center }) {
      // ① 居中标题：整行宽 + 文本居中 ⇒ 文本中心恒等于整行中心（= 屏幕中心）
      Text(this.titleName)
        .width('100%')
        .textAlign(TextAlign.Center)
        .fontSize(16)
        .fontColor($r('app.color.text_primary'))
        .fontWeight(600)

      // ② 两端层：左箭头 / 右文案，覆盖层，不参与标题定位。
      //    说明：标题是整行宽的盒子，标题极长时会与右侧 rightString 在视觉上接近；
      //    现有 5 个调用点（AboutPage/PrivacyPage/ContactPage/VersionLogPage/LicensePage）
      //    都只传 titleName、rightString 为空串，故无重叠；将来若要用 rightString 承载长文本，
      //    请改为"左右等宽占位 + 中间 layoutWeight"结构（FAQ faqs-arkui-713 方案二）。
      Row() {
        Image($r('app.media.return_left'))
          .height(15)
          .onClick(()=>{
            // 迁 Navigation 第 4 期：`MySetPage` 现在是 NavDestination，
            // 原来的 `router.back()` 会把整个 Index 弹掉（直接回桌面）。
            // `AppRouter.back()` 自适应判断该弹哪个栈。
            AppRouter.back();
          })

        Text(this.rightString).textAlign(TextAlign.Center)
      }
      .width('100%')
      // SpaceBetween：首元素贴行首、末元素贴行尾 —— 与旧版"箭头在最左"的观感一致。
      // 证据：SDK `ets/component/enums.d.ts:2025-2036`（FlexAlign.SpaceBetween）
      .justifyContent(FlexAlign.SpaceBetween)
    }
    .width('100%')
    .padding({top:12,bottom:12})

  }
}
