import MySetConstants from '../../../common/constants/MySetConstants'
import { Attribute } from '../../../common/utils/Attribute'
import { SetList, SetGroupList } from '../../../componets/dataList/SetListGroup'
import { SetHead } from '../../../componets/myset/SetHead'
import { SetListView } from '../../../componets/myset/SetListView'
// ── 全局震动反馈（2026-09-25 新增）────────────────────────────────────────────
import { Haptics } from '../../../common/utils/Haptics'
import { PreferencesUtil } from '@pura/harmony-utils'
// ── 听书双引擎（2026-09-25 新增）──────────────────────────────────────────────
// 默认=系统本地引擎（Core Speech Kit，离线可用）；Edge TTS 仅暗门解锁后出现在此切换。
import { ListenUnlock } from '../../../common/utils/ListenUnlock'
import { loadTtsPrefs, saveTtsPrefs } from '../../../tts/TtsPrefs'
import { NightMode } from '../../../common/utils/NightMode'
// ── 测试账号（2026-09-28 迁入）：登录下线后，测试登录+彩蛋解锁入口迁到本页顶部 ──
import UiMotion from '../../../common/utils/UiMotion'
import ImmersiveMaterialUtil from '../../../common/utils/ImmersiveMaterialUtil'
import { TestAccountDialog } from '../../../componets/myCenter/TestAccountDialog'

// 迁 Navigation 第 4 期：去掉 `@Entry` + 补 `export default`（被 Index.ets import 当组件用）。
@Component
export default struct MySetPage{
  // 2026-09-21 精简（用户决定）：随「缓存下载」「网络」两组与「语言」一起删除的状态 ——
  // `isShowPreDon` / `isShowLanguage` / `setImgAnti` / `select` / `selectLanguage` /
  // `tempNum` / `preDow` / `fruits` / `languageList`，以及对应的两个半模态
  // `preDowSheet()` / `languageSheet()`。
  @StorageLink(MySetConstants.SET_REFRESH) setRefresh: boolean = true
  /** 书架书名显示拓展名（2026-09-27 新增，默认关；Preferences 持久化） */
  @StorageLink(MySetConstants.SET_EXT_NAME) setExtName: boolean = false
  @StorageLink(MySetConstants.SET_JUMP) setJump: boolean = true
  @StorageLink(MySetConstants.SET_REPLACE) setReplace: boolean = true
  @StorageLink(MySetConstants.SET_TIP) setTip: boolean = true
  @StorageLink(MySetConstants.SET_HEAD) setHead: boolean = true
  @StorageLink(MySetConstants.SET_SEARCH) setSearch: boolean = true

  @StorageLink('bottomRectHeight') bottomRectHeight: number = 0
  @StorageLink('topRectHeight') topRectHeight: number = 0
  /** App 级夜间开关：测试账号弹窗深浅适配用（2026-09-28） */
  @StorageLink(NightMode.KEY) nightOn: boolean = false

  // ── 全局震动反馈（2026-09-25 新增，用户需求）────────────────────────────────
  // 开关 + 0-500 强度滑块（每 50 一档）。真正落盘到 Preferences（键 HapticsEnabled /
  // HapticsStrength），与 Haptics 模块共用 —— 旧 SET_* 键只存 AppStorage、重启即丢，
  // 本组设置必须跨启动生效，所以单独走 PreferencesUtil。
  @StorageLink(MySetConstants.SET_HAPTICS) setHaptics: boolean = true
  @State hapticStrength: number = Haptics.STRENGTH_DEFAULT
  /** 震感模式滑块值 0-500（每 50 一档 → 10 种官方预置效果拼配，见 Haptics.MODE_TABLE） */
  @State hapticMode: number = Haptics.MODE_DEFAULT
  /** 记录上次滑块所在档位（用于"跨档才震动一次"） */
  private lastStrengthStep: number = Haptics.STRENGTH_DEFAULT / Haptics.STRENGTH_STEP
  /** 记录上次模式滑块所在档位 */
  private lastModeStep: number = Haptics.MODE_DEFAULT / Haptics.STRENGTH_STEP

  // ── 听书双引擎（2026-09-25 新增）────────────────────────────────────────────
  // 整组仅在暗门解锁后出现（listenEntryUnlocked）；开关=切 Edge/本地引擎，
  // 落盘 TtsPrefs.ttsEngine（TtsEngine.activeEngineId() 还有解锁二次校验兜底）。
  @StorageLink('listenEntryUnlocked') listenUnlocked: boolean = false
  @State edgeTtsOn: boolean = false
  /** 标定模式（开发者）开关（2026-09-26 迁入，仅解锁后随组出现） */
  @State calibDevOn: boolean = false

  aboutToAppear(): void {
    // 冷启动回填：AppStorage 的 setHaptics 初值与 Preferences 对齐
    this.setHaptics = Haptics.isEnabled()
    this.hapticStrength = Haptics.getStrength()
    this.lastStrengthStep = Math.round(this.hapticStrength / Haptics.STRENGTH_STEP)
    this.hapticMode = Haptics.getMode()
    this.lastModeStep = Math.round(this.hapticMode / Haptics.STRENGTH_STEP)
    // 听书引擎开关初值（未解锁恒为关=本地引擎）
    this.edgeTtsOn = ListenUnlock.isUnlocked() && loadTtsPrefs().ttsEngine === 'edge'
    // 标定模式开关初值（2026-09-26 迁入：读 TtsHlCalibV3 的 dev 字段，与阅读页同一存储）
    this.calibDevOn = this.calibDevRead()
    // 书架拓展名开关初值（2026-09-27，默认关=隐藏后缀）
    this.setExtName = PreferencesUtil.getSync('setExtName', false) as boolean
    if (ListenUnlock.isUnlocked()) {
      this.engineSetList = [
        new SetList(false, '使用 Edge TTS 引擎', this.edgeTtsOn, '',
          '联网云端合成，音色更丰富、句级进度更准；关闭=系统本地引擎（离线可用）。仅供学习测试，禁止商用',
          MySetConstants.SET_EDGE_TTS),
        // 标定模式（2026-09-26 从阅读器-设置迁来）：开 = 阅读器-设置里出现几何标定那一套
        new SetList(false, '打开标定模式', this.calibDevOn, '',
          '阅读器-设置里出现首行标定/行高系数等开发者工具（HL 高亮对齐用）',
          MySetConstants.SET_CALIB_DEV)
      ]
      this.setGroupList = this.setGroupList.concat(
        [new SetGroupList('听书引擎（进阶）', this.engineSetList)])
    }
  }

  /**
   * 标定模式（开发者）标志读写 —— 与 `ReaderPage3` 的 `saveCalib()/loadCalib()` 共用
   * 同一个键（`TtsHlCalibV3`，HL_CALIB_KEY），**读改写**保留 topPx/widthRatio 等其他字段。
   * ⚠️ 键为字面量重复（ReaderPage3.ets 的模块常量不跨页导出），改键时两处必须同步。
   */
  private calibDevRead(): boolean {
    try {
      const raw = PreferencesUtil.getSync('TtsHlCalibV3', '') as string
      if (typeof raw !== 'string' || raw.length === 0) {
        return false
      }
      const o = JSON.parse(raw) as Record<string, Object>
      const d = o['dev']
      return typeof d === 'number' && (d as number) > 0
    } catch (e) {
      return false
    }
  }

  private calibDevWrite(v: boolean): void {
    try {
      let o: Record<string, Object> = {}
      const raw = PreferencesUtil.getSync('TtsHlCalibV3', '') as string
      if (typeof raw === 'string' && raw.length > 0) {
        const p = JSON.parse(raw) as Record<string, Object>
        if (p !== null && p !== undefined) {
          o = p
        }
      }
      o['dev'] = v ? 1 : 0
      PreferencesUtil.putSync('TtsHlCalibV3', JSON.stringify(o))
    } catch (e) {
      // 落盘失败不阻断 UI
    }
  }


  // 2026-09-21 精简（用户决定）：
  //  · 「缓存下载」整组删除 —— 4 项里「书籍保存位置」「图片缓存」的 switch 分支本来就是
  //    **空 break**，「预下载」只改一个显示文案、「图片抗锯齿」只翻转一个布尔，全都不落盘、
  //    不影响任何行为；
  //  · 「网络」整组删除 —— 「Web端口」文案写死「当前端口1122」但全工程没有任何服务端实现、
  //    「清除webview数据」「用户代理」的 case 都是空 break；
  //  · 「其他」里的「语言」删除 —— `languageSheet` 只有 4 行不可点的 Text，选完没有任何效果。
  @State bookSetList: SetList[]=[
    new SetList(false,'自动刷新',this.setRefresh,'','打开软件时自动更新书籍',MySetConstants.SET_REFRESH),
    new SetList(false,'自动跳转最近阅读',this.setJump,'','关闭将以底部弹窗形式提示',MySetConstants.SET_JUMP),
    new SetList(false,'默认启用替换净化',this.setReplace,'','新加入书架的书是否启用替换净化',MySetConstants.SET_REPLACE),
    new SetList(false,'返回时提示放入书架',this.setTip,'','',MySetConstants.SET_TIP),
    new SetList(false,'显示文件拓展名',this.setExtName,'','书架上书名是否显示 .txt 等后缀',MySetConstants.SET_EXT_NAME)
  ]

  @State otherSetList: SetList[]=[
    new SetList(false,'全程响应耳机按键',this.setHead,'','即使退出也响应耳机按键',MySetConstants.SET_HEAD),
    new SetList(false,'文字操作显示搜索',this.setSearch,'','长按文字在操作菜单中显示阅读搜索',MySetConstants.SET_SEARCH),
  ]

  /** 震动反馈组（2026-09-25 新增）：开关项；强度滑块单独渲染（见 build 末尾的自绘卡片） */
  @State hapticSetList: SetList[]=[
    new SetList(false,'震动反馈',this.setHaptics,'','按键与滑动时的物理震动反馈',MySetConstants.SET_HAPTICS),
  ]

  /** 听书引擎组（2026-09-25 新增）：仅解锁后在 aboutToAppear 里填充并追加到分组列表 */
  @State engineSetList: SetList[]=[]

  @State setGroupList: SetGroupList[] = [
    new SetGroupList('书架',this.bookSetList),
    new SetGroupList('其他',this.otherSetList),
    new SetGroupList('震动反馈',this.hapticSetList)
  ]

  // 定义分组设置头部
  @Builder itemHead(text: string) {
    // 分组设置头部组件
    Text(text)
      .fontSize(12)
      .fontColor($r('app.color.text_tertiary'))
      .backgroundColor($r('app.color.page_bg_alt'))
      .width('100%')
      .padding({left:40,right:40,top:16,bottom:8})
  }


  // ── 测试账号（2026-09-28 迁入）────────────────────────────────────────────
  // 登录从「我的」页下线后，测试账号表单（登录 + 彩蛋解锁双职能）迁到本页顶部。
  private testAccountDialog: CustomDialogController | null = null

  private openTestAccountDialog(): void {
    this.testAccountDialog = new CustomDialogController({
      builder: TestAccountDialog({
        dark: this.nightOn, // 深浅适配（2026-09-28 用户反馈：黑底黑字修复）
        onClose: (): void => {
          this.testAccountDialog?.close()
          this.testAccountDialog = null
        },
        onUnlocked: (): void => {
          // ⚠️ 先 close 再清引用：只置 null 不 close 会留下关不掉的孤儿弹窗
          this.testAccountDialog?.close()
          this.testAccountDialog = null
          this.showUnlockAlert()
        },
        onLoginOk: (): void => {
          this.testAccountDialog?.close()
          this.testAccountDialog = null
          this.getUIContext().getPromptAction().showToast({ message: '测试账号登录成功' })
        }
      }),
      autoCancel: true,
      alignment: DialogAlignment.Center,
      width: '88%',
      cornerRadius: 20,
      customStyle: false,
      systemMaterial: ImmersiveMaterialUtil.sheetMaterial(),
      openAnimation: UiMotion.motionParam(UiMotion.SPRING_FAST),
      closeAnimation: UiMotion.motionParam(UiMotion.SPRING_FAST),
      cancel: (): void => {
        this.testAccountDialog = null
      }
    })
    this.testAccountDialog.open()
  }

  /** 彩蛋解锁成功弹窗（原「改名解锁」文案，2026-09-28 随入口迁入） */
  private showUnlockAlert(): void {
    Haptics.success();
    this.getUIContext().showAlertDialog({
      title: '🎉 解锁成功',
      // 免责声明（2026-09-25 用户要求）：解锁面参数明用途边界——学习测试可用、禁商用。
      message: `你已永久解锁隐藏功能！\n「我的-设置」里会出现 Edge TTS 引擎与标定模式开关，阅读界面底部也能看到「听书」按钮。\n\n【免责声明】\n· 本功能（含 Edge TTS 云端合成）仅供个人学习与技术测试；\n· 严禁用于任何商业用途；\n· 音频内容的合规性由使用者自行负责；\n· 本应用与微软、华为无隶属或合作关系。`,
      autoCancel: false,
      confirm: {
        value: '太好了',
        action: () => {
          Haptics.tap();
        }
      }
    })
  }

  build() {
    Column(){
      SetHead({titleName:'我的设置'}).height(48).padding({left:20})

      // ── 测试账号入口（2026-09-28 迁入，置于页首；UI 不留彩蛋提示）────────────
      Row({ space: 12 }) {
        Text('测试账号')
          .fontSize(14)
          .fontColor($r('app.color.text_primary'))
        Blank()
        Text('›')
          .fontSize(16)
          .fontColor($r('app.color.text_primary'))
          .opacity(0.4)
      }
      .width('100%')
      .padding({ left: 20, right: 20, top: 12, bottom: 12 })
      .onClick(() => {
        Haptics.tap();
        this.openTestAccountDialog()
      })

      List(){

        ForEach(this.setGroupList,(group:SetGroupList)=>{
          //分组头部
          ListItemGroup({header:this.itemHead(group.groupValue)}){

            if(group.setList){
              ForEach(group.setList,(item:SetList)=>{
                ListItem(){//设置内容，首尾裁剪
                  if (group.setList.indexOf(item) == 0){
                    SetListView({setList:item,topLeft:20,topRight:20})
                      .onClick(()=>{Haptics.tap(); this.itemOnclick(item.storageName)})

                  }else if (group.setList.indexOf(item) == group.setList.length - 1){
                    SetListView({setList:item,bottomLeft:20,bottomRight:20})
                      .onClick(()=>{Haptics.tap(); this.itemOnclick(item.storageName)})
                  }else {
                    SetListView({setList:item})
                      .onClick(()=>{Haptics.tap(); this.itemOnclick(item.storageName)})
                  }
                }.padding({left:20,right:20})
              }, (item: SetList): string => item.value)

              // ── 震动强度滑块行（2026-09-25 新增）──────────────────────────────
              // 用户需求：「0-500 无极调整滑块（每 50 一个档，自由调节震动强度）」。
              // 只有「震动反馈」组有这一行；开关关着时整行禁用 + 变淡。
              // SetListView 只支持 文案+Toggle/箭头，滑块行只能自绘（卡片样式对齐上面各行的
              // `card_bg` + 20 圆角：开关行占上圆角、本行占下圆角，拼成一张完整卡片）。
              if (group.groupValue === '震动反馈'){
                ListItem(){
                  Column({ space: 4 }){
                    Row(){
                      Text('震动强度').fontSize(16)
                      Blank()
                      Text(`${this.hapticStrength}`)
                        .fontSize(13)
                        .fontColor($r('app.color.text_tertiary'))
                    }.width('100%')
                    Slider({
                      value: this.hapticStrength,
                      min: 0,
                      max: Haptics.STRENGTH_MAX,
                      step: Haptics.STRENGTH_STEP,
                      style: SliderStyle.InSet
                    })
                      .width('100%')
                      .enabled(this.setHaptics)
                      .opacity(this.setHaptics ? 1 : 0.4)
                      // 滑动时每**跨一档**（50）震一次（Haptics 内部还有 80ms 节流兜底）；
                      // 落盘只在松手（End）/点击（Click）时做，避免拖动过程频繁 flush。
                      .onChange((value: number, mode: SliderChangeMode) => {
                        this.hapticStrength = Math.round(value)
                        const step = Math.round(this.hapticStrength / Haptics.STRENGTH_STEP)
                        if (step !== this.lastStrengthStep) {
                          this.lastStrengthStep = step
                          Haptics.tick()
                        }
                        if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) {
                          PreferencesUtil.putSync(Haptics.KEY_STRENGTH, this.hapticStrength)
                        }
                      })

                    Row(){
                      Text('震感模式').fontSize(16)
                      Blank()
                      Text(`${Haptics.modeName()}`)
                        .fontSize(13)
                        .fontColor($r('app.color.text_tertiary'))
                    }.width('100%')
                    Slider({
                      value: this.hapticMode,
                      min: 0,
                      max: Haptics.STRENGTH_MAX,
                      step: Haptics.STRENGTH_STEP,
                      style: SliderStyle.InSet
                    })
                      .width('100%')
                      .enabled(this.setHaptics)
                      .opacity(this.setHaptics ? 1 : 0.4)
                      // 滑动跨档即以**新模式**试震一次（即时对比手感）；落盘只在松手/点击时
                      .onChange((value: number, mode: SliderChangeMode) => {
                        this.hapticMode = Math.round(value)
                        const step = Math.round(this.hapticMode / Haptics.STRENGTH_STEP)
                        if (step !== this.lastModeStep) {
                          this.lastModeStep = step
                          Haptics.tick()
                        }
                        if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) {
                          PreferencesUtil.putSync(Haptics.KEY_MODE, this.hapticMode)
                        }
                      })
                  }
                  .width('100%')
                  .padding({ left: 20, right: 20, top: 12, bottom: 12 })
                  .backgroundColor($r('app.color.card_bg'))
                  .borderRadius({ bottomLeft: 20, bottomRight: 20 })
                  .opacity(this.setHaptics ? 1 : 0.55)
                }.padding({left:20,right:20})
              }
            }

          }
        }, (group: SetGroupList): string => group.groupValue)

      }.width('100%')
      .height('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Off)
    }
    .padding({
      top:this.topRectHeight,
      bottom: this.bottomRectHeight,
    })
    .backgroundColor($r('app.color.page_bg_alt'))
  }



  // `preDowSheet()`（预下载）与 `languageSheet()`（语言）两个半模态已于 2026-09-21 删除 ——
  // 它们服务的两个设置项都已移除。顺带记一笔原实现的问题：
  // 「语言」半模态里只有 4 行**不可点击**的 `Text`，选完没有任何效果；
  // 「预下载」只把数字写进一个 `@State` 和一处显示文案，全工程无人消费。

  /**
   * 设置列表点击事件
   * @param value
   */
  itemOnclick(value:string){
    // 全局震动方案（2026-09-25）：每个设置项点击都给一次反馈。
    // 顺序说明：先 tap 再翻转 —— 关闭震动反馈时还能感受到"最后一下"。
    Haptics.tap();
    switch (value){
      case MySetConstants.SET_REFRESH:
        this.setRefresh = !this.setRefresh
        this.bookSetList[0].toggleStatus = this.setRefresh;
        break;
      case MySetConstants.SET_JUMP:
        this.setJump = !this.setJump
        this.bookSetList[1].toggleStatus = this.setJump;
        break;
      case MySetConstants.SET_REPLACE:
        this.setReplace = !this.setReplace
        this.bookSetList[2].toggleStatus = this.setReplace;
        break;
      case MySetConstants.SET_TIP:
        this.setTip = !this.setTip
        this.bookSetList[3].toggleStatus = this.setTip;
        break;
      case MySetConstants.SET_HEAD:
        this.setHead = !this.setHead
        this.otherSetList[0].toggleStatus = this.setHead;
        break;
      case MySetConstants.SET_SEARCH:
        this.setSearch = !this.setSearch
        this.otherSetList[1].toggleStatus = this.setSearch;
        break;
      case MySetConstants.SET_HAPTICS:
        this.setHaptics = !this.setHaptics
        this.hapticSetList[0].toggleStatus = this.setHaptics;
        // 真正落盘（旧 SET_* 键不落盘是历史现状，震动开关必须跨启动生效）
        PreferencesUtil.putSync(Haptics.KEY_ENABLED, this.setHaptics)
        break;
      case MySetConstants.SET_EDGE_TTS:
        // 听书引擎切换（仅解锁后可见；TtsEngine.activeEngineId() 另有解锁二次校验）。
        // 立即落盘；正在播放的句子播完后，下一块合成即走新引擎（缓存键含引擎名，互不污染）。
        this.edgeTtsOn = !this.edgeTtsOn
        this.engineSetList[0].toggleStatus = this.edgeTtsOn
        const prefs = loadTtsPrefs()
        prefs.ttsEngine = this.edgeTtsOn ? 'edge' : 'local'
        saveTtsPrefs(prefs)
        break;
      case MySetConstants.SET_EXT_NAME:
        // 书架书名拓展名（2026-09-27）：AppStorage（@StorageLink）即时驱动书架刷新，
        // Preferences 持久化跨启动（aboutToAppear 回读）。
        this.setExtName = !this.setExtName
        this.bookSetList[4].toggleStatus = this.setExtName
        PreferencesUtil.putSync('setExtName', this.setExtName)
        break;
      case MySetConstants.SET_CALIB_DEV:
        // 标定模式（2026-09-26 从阅读器-设置迁来）：写 TtsHlCalibV3 的 dev 字段，
        // 阅读页 loadCalib 打开时照读 ⇒ 开 = 阅读器-设置出现标定功能区。
        this.calibDevOn = !this.calibDevOn
        this.engineSetList[1].toggleStatus = this.calibDevOn
        this.calibDevWrite(this.calibDevOn)
        break;
    }
  }
}
