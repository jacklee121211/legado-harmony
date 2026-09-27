import { Attribute } from '../../../common/utils/Attribute'
import AppRouter, { RouteName, ReadStatisticsRouteParam } from '../../../common/router/AppRouter'
import { promptAction } from '@kit.ArkUI'
import { fileIo, fileUri } from '@kit.CoreFileKit'
import { photoAccessHelper } from '@kit.MediaLibraryKit'
import { common } from '@kit.AbilityKit'
import { PreferencesUtil } from '@pura/harmony-utils'
import ImmersiveMaterialUtil, { MaterialColumnModifier, MaterialButtonModifier } from '../../../common/utils/ImmersiveMaterialUtil'
import UiMotion, { runJellyClick } from '../../../common/utils/UiMotion'
import { dataItem } from '../../../componets/dataList/dataItem'
import BooksDao from '../../../database/dao/BooksDao'
import BookmarksDao from '../../../database/dao/BookmarksDao'
import { NightMode, ShelfColors } from '../../../common/utils/NightMode'
import { ColumnModifier } from '../../../common/utils/ComponetModifier'
import { ThemeStorageKey } from '../../../common/constants/Theme'
import { ThemeItem } from '../../../common/model/Theme'
import { image } from '@kit.ImageKit'
import { resourceManager } from '@kit.LocalizationKit'
import { BusinessError } from '@kit.BasicServicesKit'
// ── 全局震动反馈 + 听书入口解锁（2026-09-25 新增）─────────────────────────────
import { Haptics } from '../../../common/utils/Haptics'
import { ListenUnlock } from '../../../common/utils/ListenUnlock'

// T29-③（Round 40）：去掉 `@Entry`。
// 编译器原文：`It's not a recommended way to export struct with '@Entry' decorator,
//   which may cause ACE Engine error in component preview mode.`
// 实测依据：① `main_pages.json`（32 个页面）**没有** `pages/view/myCenter/MyCenter` ⇒ 它不是页面；
//          ② 它是被 `pages/Index.ets:8` **作为组件** import 的；
//          ③ 全文无 `onPageShow`/`onPageHide`/`onBackPress` 等 `@Entry` 专属生命周期。
// ⇒ 去掉 `@Entry` 后仍是被父组件渲染的普通组件，行为不变；保留 `export default`（父组件要用）。
@Component
export default struct MyCenter {
  /**
   * 三个计数的**刷新钩子**（2026-09-21 落地，解决真机「数字不实时、要杀进程重启」）。
   *
   * 为什么必须有它：`MyCenter` 是 `pages/Index.ets` 的**子组件**（不是页面，见文件头注释），
   * `aboutToAppear` 只在**组件首次创建**时触发一次 —— 读完书回来数字还是旧的。
   *
   * 机制：监听一个共享的"心跳"计数器 `myCenterTick`，值一变就重拉。
   * 谁负责 +1：
   *   · `pages/Index.ets` 的 `Tabs.onAnimationStart` —— 切到「我的」（index 3）时；
   *   · `pages/view/myCenter/readStatistics.ets` 的 `onPageHide` —— 删完书签/记录返回时。
   */
  @StorageLink('myCenterTick') @Watch('onCountsTick') myCenterTick: number = 0

  onCountsTick(): void {
    this.loadHeadCounts()
  }

  /**
   * 进入「我的」页时拉取真实计数（读过 / 读完 / 书签）。
   * 后续刷新走上面的 `myCenterTick` 钩子。
   */
  aboutToAppear(): void {
    // 头像 / 用户名（2026-09-21 新增）：从 Preferences 读回。
    // 存的是**沙箱路径**，显示时要用 `fileUri.getUriFromPath()` 转成沙箱 URI ——
    // 官方 FAQ `faqs-arkui-154` 原文：「Image组件不能直接传入应用沙箱路径，
    // 需要传入应用沙箱URI」。
    const savedAvatarPath = PreferencesUtil.getSync('MyAvatarPath', '') as string
    if (savedAvatarPath.length > 0) {
      try {
        fileIo.accessSync(savedAvatarPath) // 文件可能被系统清理过，先确认存在
        this.avatarUri = fileUri.getUriFromPath(savedAvatarPath)
      } catch (e) {
        this.avatarUri = ''
      }
    }
    this.userName = PreferencesUtil.getSync('MyUserName', this.userName) as string
    this.loadHeadCounts()
  }

  @State head_list: dataItem[] = [
    new dataItem("读过", 0),
    new dataItem("读完", 0),
    new dataItem("书签", 0),
    // 「勋章」已移除（2026-09-21）：原为硬编码的假数据，点进去是空分支（见 head_onclick），
    // 无数据源、无功能，属纯占位符。索引保持 0=读过 / 1=读完 / 2=书签 不变。
  ]
  // 2026-09-21 精简：原 4 项里「备份」「书源」「净化」已删 ——
  //   · 备份 → `cloudDisk.ets` 整页无任何 WebDAV 实现（假设备名/假备份列表，
  //     「立刻备份」只是转 720° + toast「备份成功」）；
  //   · 书源 / 净化 → `centerOnclick` 里本来就是 `case 3/4: break` **空分支**，点了没反应。
  @State center_list: dataItem[] = [
    new dataItem("主题", 2, $r("app.media.my_center_book_icon")),
  ]
  // 「关于我们」入口已于 2026-09-21 删除（用户决定），`end_list` 整块随之移除
  //（它原来也只承载这一个入口）。
  @StorageLink('topRectHeight') topRectHeight: number = 0
  Column = new ColumnModifier()
  // 主题颜色
  // 亮暗色重构（2026-09-23）：订阅派生深色键 —— 渐变背景（ShelfColors.gradientStart/End）
  // 需要在深浅翻转时重绘；不订阅的话"自动"档跟随系统时会滞后到下一次重建。
  @StorageLink(NightMode.KEY) nightOn: boolean = false
  @StorageProp(ThemeStorageKey.THEME) theme: ThemeItem = {} as ThemeItem

  // ── 头像 / 用户名（2026-09-21 重建，改用华为官方 API）──────────────────────
  /** 头像的**沙箱 URI**（`fileUri.getUriFromPath()` 的结果）。空 = 用默认头像。 */
  @State avatarUri: string = ''
  /** 用户名（可改，默认「阅读者」） */
  @State userName: string = '阅读者'
  /** 改名半模态开关 */
  @State isShowNameEdit: boolean = false
  /** 改名草稿（点「保存」才落盘） */
  @State nameDraft: string = ''
  /** 设置图标的 Q弹缩放值（2026-09-25 二次调优，`runJellyClick` 自驱 `.scale()`） */
  @State setIconScale: number = 1

  build() {
    Column() {
      // Blank(this.topRectHeight-20)
      //右上角模式图标
      Row({ space: 10 }) {
        //设置图标（2026-09-25：换成 SymbolGlyph，用户要求与书架页同批换 symbol。
        //符号名 `gearshape` 在 SDK 符号表 `…\Sdk\23\previewer\common\resources\entry\resources.txt`
        //查得，不猜名字。点击 Q弹缩放由 `.scale()` + `runJellyClick` 驱动（2026-09-25 二次调优：
        //内置 ScaleSymbolEffect 节奏定死太慢，借参考工程同款实现）。
        SymbolGlyph($r('sys.symbol.gearshape'))
          .fontSize(26)
          .fontColor([ShelfColors.icon()])
          .scale({ x: this.setIconScale, y: this.setIconScale })
          .onClick(() => {
            Haptics.tap();
            runJellyClick((v: number) => {
              this.setIconScale = v
            })
            this.toMySetPage()
          })
          .clickEffect(UiMotion.CLICK)
      //夜间模式图标（2026-09-21 删除）：`night_onclick()` 是**空函数体**，
      //点了什么都不发生；整片右上角区域还绑着同一个空回调。
      }.justifyContent(FlexAlign.End).width("100%")

      Scroll() {
        // 整页**向上对齐**（用户要求）：内层 Column 显式撑满高度 + Start 对齐，
        // 并去掉原来垫在最上面的 `Blank(24)`，内容直接从顶部开始排。
        Column() {
          // ── 头像 + 用户名（2026-09-21 用华为官方 API 重建）──────────────
          // 之前那版是空壳（`avatar_onclick()` 空函数体、昵称写死「夏目友人」、
          // `reading_time` 无写入方 ⇒ 恒显「今日阅读0分钟」）。现在换成：
          //   ① 点头像 → 系统相册选图，**带系统内置裁切编辑**；
          //   ② 点名字 → 改名；
          //   ③ 两者都持久化到 Preferences。
          // 用到的两个官方 API 的声明原文见 `pickAvatar()` 的注释。
          Row({ space: 14 }) {
            Image(this.avatarUri.length > 0 ? this.avatarUri : $r('app.media.user_avatar'))
              .width(64)
              .height(64)
              .borderRadius(64)
              .interpolation(ImageInterpolation.Medium)
              .onClick(() => {
                Haptics.tap();
                this.pickAvatar()
              })
            Row({ space: 6 }) {
              Text(this.userName)
                .fontSize(18)
                .fontWeight(600)
                .lineHeight(26)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
              Image($r('app.media.ic_public_edit')).width(16).height(16).opacity(0.5)
            }.onClick(() => {
              Haptics.tap();
              this.openNameEditor()
            })
            .clickEffect(UiMotion.CLICK)
          }
          // 2026-09-24：删掉了头像下方的「点头像换头像…」提示行（用户要求），
          // 用户名行与 64vp 头像垂直居中对齐（Row 的 alignItems 显式声明，避免依赖默认值）。
          .alignItems(VerticalAlign.Center)
          .width('100%')
          .padding({ left: 20, right: 20, top: 8, bottom: 8 })

          // 统计数据
          Row() {
            ForEach(this.head_list, (item: dataItem, index: number) => {
              Column({ space: 5 }) {
                Text(item.value.toString())
                  .fontSize(20)
                  .fontWeight(600)
                  // 数字翻滚动效（2026-09-21）。依据（SDK 原文）：
                  //   `contentTransition(transition: Optional<ContentTransition>)`
                  //     （`…\ets\component\text.d.ts:1248`，`@since 20`）
                  //   `declare class NumericTextTransition extends ContentTransition`
                  //     （`…\ets\component\text_common.d.ts:1971`，`@since 20`）
                  //   官方对它的限制原文：「It applies **only to positive integers** (decimals and
                  //   negative numbers are **not supported**)… The flip animation **fails if the text
                  //   contains child components** or is set via a styled string.」
                  // ⇒ 恰好匹配这三个计数：纯正整数、纯字符串、无子组件。
                  //   `enableBlur` 打开后翻转过程带一点模糊，观感更"高级"（默认 false）。
                  // 不想要就删掉这一行（`contentTransition` 是纯增量的属性）。
                  .contentTransition(new NumericTextTransition({
                    flipDirection: FlipDirection.DOWN,
                    enableBlur: true
                  }))
                Text(item.title).fontSize(10).fontWeight(500)
              }.onClick(() => {
                Haptics.tap();
                this.head_onclick(index)
              })
              .clickEffect(UiMotion.CLICK)
            })
          }.justifyContent(FlexAlign.SpaceBetween).width("100%").padding({ left: 20, right: 20 })

          // 固定高度间隔（**绝对不能用 `Blank`**）：
          // 本 Column 是 `height('100%')`，而 `Blank` 的语义是**撑满剩余空间**，
          // ⇒ 真机表现就是「主题」卡片被顶到页面最底部、与上面三个统计数字之间空出一大片
          //   （用户截图反馈「主题不够靠上」）。改成定高占位即可。
          Row().width('100%').height(16)

          //云盘 书源 主题 净化设置
          // 2026-09-24（用户反馈）：列表精简到只剩「主题」一项后，`SpaceBetween` 会把它
          //   排到整张卡片的最左边，且只有图标那 80vp 宽的小块能点。
          // ⇒ ① `justifyContent(Center)`：图标在整张卡里居中；
          //   ② 每项 `layoutWeight(1)`：单项时占满整行 = **整张卡片可点**，
          //      将来加回第二项也自动均分、各自可点。
          Row() {
            ForEach(this.center_list, (item: dataItem) => {
              Column({ space: 4 }) {
                Image(item.icon).size({ width: 24, height: 24 })
                Text(item.title).fontSize(12)
              }
              .height(48)
              .justifyContent(FlexAlign.Center)
              .layoutWeight(1)
              .onClick(() => {
                Haptics.tap();
                this.centerOnclick(item.value)
              })
              .clickEffect(UiMotion.CLICK)
            })
          }
          .width("100%")
          .justifyContent(FlexAlign.Center)
          .padding({ top: 16, bottom: 16 })
          .backgroundColor($r('app.color.card_bg'))
          .borderRadius(10)
          // 卡片层次（2026-09-21）：与封面投影同一套视觉语言，给白色卡片一点"浮起来"的层次。
          // 纯增量属性、不动尺寸/布局 ⇒ 零回归风险；不想要就删这一行。
          // 用很淡的 0.06 透明度，避免在浅色渐变背景上显脏。
          .shadow({ radius: 12, color: 'rgba(0, 0, 0, 0.06)', offsetX: 0, offsetY: 4 })

        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Start)
        .alignItems(HorizontalAlign.Start)
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .padding({ bottom: 10 })
    }
    .attributeModifier(this.Column)
    .linearGradient({
      direction: GradientDirection.Bottom, // 渐变方向
      // 亮暗色重构（2026-09-23，用户拍板"深色底+主题色点缀"）：深色档换成中性深灰渐变，
      // 主题色只保留在图标/按钮等点缀处；日间档与原来逐字一致。
      colors: [[ShelfColors.gradientStart(this.theme.mainColor), 0.0],
        [ShelfColors.gradientEnd(this.theme.secondColor), 0.2]]
    })
    .height('100%')
    // 改名半模态（2026-09-21 接入沉浸光感）。
    // 官方对「弹出框（Dialog）」的原文：「弹出框支持通过弹出框 options 参数中的
    // systemMaterial 字段设置沉浸光感效果，如 CustomDialogControllerOptions、
    // AlertDialogParam、ActionSheetOptions、**SheetOptions** 等。」
    // ⚠️ 两条硬约束都遵守了：
    //   ① 这里**没有**设置 backgroundColor / backgroundBlurStyle
    //      （官方：「已主动设置背景色、背景模糊等自定义样式属性，则不呈现沉浸光感效果」）；
    //   ② **没有**给内容 Column 另设材质（官方禁止材质嵌套，同一子树只设最外层一次）。
    // 关闭（回退）时 sheetMaterial() 返回 undefined，sheet 自动回到系统默认底。
    .bindSheet($$this.isShowNameEdit, this.nameEditorSheet(), {
      height: 220,
      dragBar: false,
      showClose: false,
      systemMaterial: ImmersiveMaterialUtil.sheetMaterial(),
    })
  }

  /**
   * 拉取「读过 / 读完 / 书签」真实计数。
   *
   * 三项**相互独立**（2026-09-21 用户明确要求）：
   *  · 读过 = `Books.durChapterTime > 0` 的书数
   *  · 读完 = `Books.finishedTime > 0` 的书数（"曾经读到末章"，只写一次）
   *  · 书签 = `bookmarks` 表条数
   *
   * ⚠️ 书签在**书签功能落地之前恒为 0** —— 底座没有书签功能，
   * `bookmarks` 表是移植时带过来的遗留物、无任何写入端。
   * 这里刻意走**真实查询**而不是硬编码 0，等写入端做好后无需再改。
   */
  async loadHeadCounts(): Promise<void> {
    try {
      const read = await BooksDao.countRead()
      const finished = await BooksDao.countFinished()
      const marks = await BookmarksDao.count()
      this.head_list = [
        new dataItem("读过", read),
        new dataItem("读完", finished),
        new dataItem("书签", marks),
      ]
    } catch (e) {
      console.log('loadHeadCounts, Error, ', JSON.stringify(e))
    }
  }

  //读过/读完/书签点击事件（0=读过 1=读完 2=书签）
  //「勋章」已于 2026-09-21 移除，故不再需要 `value == 3` 的空分支。
  head_onclick(value: number) {
    console.log("点击了" + value)
    // 迁 Navigation 第 4 期：readStatistics 已改为 NavDestination，改走路由门面。
    // ⚠️ 字段名必须用 `type`：目标页读的是 `(router.getParams() as dataItem).value`
    //    （`dataItem` 的字段就叫 `value`），而它的 `initParam` 类型是
    //    `ReadStatisticsRouteParam { type: number }` —— 两边字段名不同，
    //    这里刻意用 `type` 与接口对齐，值仍是原来的 `value`。
    AppRouter.push(RouteName.READ_STATISTICS, { type: value } as ReadStatisticsRouteParam)
  }

  //主题点击事件（2026-09-21 精简：只剩「主题」一项；
  //原「备份」「书源」「净化」的 case 1/3/4 已删除）
  centerOnclick(value: number | string) {
    switch (value) {
    // 点击主题
      case 2:
        // 迁 Navigation 第 4 期：主题配置页已改为 NavDestination，改走路由门面。
        AppRouter.push(RouteName.THEME_CONFIG)
        break
    }
  }

  // ── 头像 / 用户名（2026-09-21 新增，华为官方 API）─────────────────────────

  /**
   * 换头像：**系统相册选图 + 系统内置裁切编辑**，结果拷进应用沙箱后持久化。
   *
   * 用到的两个官方 API（SDK 声明原文，文件
   * `…\sdk\default\openharmony\ets\api\@ohos.file.photoAccessHelper.d.ts`）：
   *
   *  ① **相册选择**
   *     `class PhotoViewPicker { select(option?: PhotoSelectOptions): Promise<PhotoSelectResult>; }`
   *     （`:4443` / `:4474`；`@since 10`；`@syscap SystemCapability.FileManagement.PhotoAccessHelper.Core`）
   *
   *  ② **裁切 / 编辑**
   *     `PhotoSelectOptions.isEditSupported?: boolean;`
   *     原文：`Whether the image can be edited. true if editable, false otherwise.`
   *     （`:4219`-`:4227`；`@since 11`）
   *     置 `true` 后系统选择器会带上「编辑」能力（可在选图时裁切）再返回结果。
   *
   * ⚠️ **为什么还要再拷一次进沙箱**：同一个 `select()` 的 NOTE 原文写着 ——
   *   `photoUris in the PhotoSelectResult object returned by this API has permanent
   *    authorization and can be used only by calling photoAccessHelper.getAssets(...)`
   *   ⇒ 这个 URI **不能直接当图片地址**喂给 `Image()`。所以先 `fileIo` 拷进 `filesDir`，
   *   再用 `fileUri.getUriFromPath()` 转成**应用沙箱 URI** 显示。
   *   官方 FAQ `faqs-arkui-154` 原文：「Image组件不能直接传入应用沙箱路径，需要传入
   *   应用沙箱URI。…然后调用 fileUri.getUriFromPath 方法将沙箱路径转化为沙箱URI，
   *   传入之后即可正常显示沙箱图片。」
   */
  private async pickAvatar(): Promise<void> {
    try {
      // 能力守卫：新 API 的 syscap 是 `SystemCapability.FileManagement.PhotoAccessHelper.Core`
      // （见上面 `select()` 的 SDK 原文）。工程里 `common/utils/photoViewPicker.ets` 正是
      // 因为这条 syscap 与旧实现的 `…UserFileService` 不同，才默认走旧 API 的。
      // 这里先判一次，能力缺失时给明确提示，而不是让它抛异常。
      if (!canIUse('SystemCapability.FileManagement.PhotoAccessHelper.Core')) {
        this.getUIContext().getPromptAction().showToast({
          message: '当前设备不支持相册选择能力'
        })
        return
      }
      const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext
      const options = new photoAccessHelper.PhotoSelectOptions()
      options.MIMEType = photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE
      options.maxSelectNumber = 1
      options.isEditSupported = true // ★ API②：让系统选择器带裁切/编辑
      const pickerView = new photoAccessHelper.PhotoViewPicker()
      const res = await pickerView.select(options) // ★ API①
      if (res.photoUris === undefined || res.photoUris.length === 0) {
        return // 用户取消
      }
      const newPath = `${ctx.filesDir}/avatar_${Date.now()}.jpg`
      // 按 fd 拷贝：`openSync` 支持带授权的媒体 URI；fd→fd 的 `copyFileSync` 最稳
      const src = fileIo.openSync(res.photoUris[0], fileIo.OpenMode.READ_ONLY)
      try {
        const dst = fileIo.openSync(newPath,
          fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE)
        try {
          fileIo.copyFileSync(src.fd, dst.fd)
        } finally {
          fileIo.closeSync(dst)
        }
      } finally {
        fileIo.closeSync(src)
      }
      // 删掉上一张，避免沙箱里越积越多
      const oldPath = PreferencesUtil.getSync('MyAvatarPath', '') as string
      if (oldPath.length > 0 && oldPath !== newPath) {
        try {
          fileIo.unlinkSync(oldPath)
        } catch (e) {
          // 旧文件不在了就算了
        }
      }
      PreferencesUtil.putSync('MyAvatarPath', newPath)
      this.avatarUri = fileUri.getUriFromPath(newPath)
      this.getUIContext().getPromptAction().showToast({ message: '头像已更新' })
    } catch (e) {
      this.getUIContext().getPromptAction().showToast({
        message: '换头像失败：' + (e instanceof Error ? e.message : String(e))
      })
    }
  }

  /** 打开改名半模态（内容见 `nameEditorSheet()`） */
  private openNameEditor(): void {
    this.nameDraft = this.userName
    this.isShowNameEdit = true
  }

  /** 保存用户名（空名拒绝；限 20 字）。改名命中暗号时触发听书入口解锁（2026-09-25） */
  private saveName(): void {
    const n = this.nameDraft.trim()
    if (n.length === 0) {
      this.getUIContext().getPromptAction().showToast({ message: '名字不能为空' })
      return
    }
    this.userName = n.length > 20 ? n.substring(0, 20) : n
    PreferencesUtil.putSync('MyUserName', this.userName)
    this.isShowNameEdit = false
    // ── 听书入口解锁（2026-09-25，暗号方案）──────────────────────────────
    // tryUnlock 只在「尚未解锁 且 名字命中暗号」时返回 true ⇒ 解锁成功只弹一次；
    // 之后改名（改成什么都好）不再弹、也不再影响解锁位（与用户名解耦）。
    if (ListenUnlock.tryUnlock(this.userName)) {
      Haptics.success();
      this.getUIContext().showAlertDialog({
        title: '🎉 解锁成功',
        // 免责声明（2026-09-25 用户要求）：解锁面参数明用途边界——学习测试可用、禁商用。
        message: `「${this.userName}」，你已永久解锁听书功能！\n打开任意书籍的阅读界面，底部就能看到「听书」按钮了。\n\n【免责声明】\n· 本功能（含 Edge TTS 云端合成）仅供个人学习与技术测试；\n· 严禁用于任何商业用途；\n· 音频内容的合规性由使用者自行负责；\n· 本应用与微软、华为无隶属或合作关系。`,
        autoCancel: false,
        confirm: {
          value: '太好了',
          action: () => {
            Haptics.tap();
          }
        }
      })
    }
  }

  /** 改名半模态内容（`$$` 是 ArkUI 官方双向绑定写法） */
  @Builder
  nameEditorSheet() {
    Column({ space: 16 }) {
      Text('修改用户名').fontSize(16).fontWeight(600)
      TextInput({ text: $$this.nameDraft, placeholder: '请输入用户名（最多 20 字）' })
        .maxLength(20)
        .height(40)
      Row({ space: 16 }) {
        Button('取消')
          .backgroundColor($r('app.color.sub_btn_bg'))
          .fontColor($r('app.color.text_primary'))
          .layoutWeight(1)
          .onClick(() => {
            Haptics.tap();
            this.isShowNameEdit = false
          })
        Button('保存')
          .layoutWeight(1)
          .onClick(() => {
            Haptics.tap();
            this.saveName()
          })
          // 主题色沉浸光感材质（用户拍板）。开启时由 buttonMaterial 喂半透明主题色，
          // 关闭时回落到原来的主题色实底 + 白字（见 MaterialButtonModifier）。
          .attributeModifier(new MaterialButtonModifier(this.theme.mainColor, Color.White,
            ImmersiveMaterialUtil.tint(this.theme.mainColor, 0.75)))
      }.width('100%')
    }
    .width('100%')
    .height(220)
    .padding({ left: 20, right: 20, top: 16, bottom: 16 })
  }

  toMySetPage() {
    // 迁 Navigation 第 4 期：我的设置已改为 NavDestination，改走路由门面。
    AppRouter.push(RouteName.MY_SET)
  }
}
