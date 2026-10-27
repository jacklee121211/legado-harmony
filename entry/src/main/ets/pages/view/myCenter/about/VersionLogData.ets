/**
 * ⚠️ 本文件由 `scripts/sync-version.ps1` **自动生成**（git `commit-msg` 钩子每次提交都会刷新）。
 * 请勿手改 —— 要改内容就改提交备注（首行必须以版本号开头，见脚本头注释）。
 */

/** 一条版本记录（更新日志的一行卡片） */
export interface VersionEntry {
  /** 形如 `V2.0.2 封面圆角对齐` */
  version: string
  /** 提交日期 yyyy-MM-dd（空串 = 不显示） */
  date: string
  /** 该版本的变更条目 */
  items: string[]
}

/** 读不到 bundle 信息时的兜底版本号（与 app.json5 同源） */
export const APP_VERSION_FALLBACK: string = 'V3.0.8'

/** 更新日志（默认只含**当前版本**一条；-MaxVersions 调大才有多条历史） */
export const VERSION_LOGS: VersionEntry[] = [
  {
    version: 'V3.0.8 设置页 VIP 入口 + 布局胶囊夜间对齐 + 关于页顶部对齐 + 阅读里程碑推广',
    date: '2026-10-28',
    items: [
      '设置页「加入QQ群」左侧新增「开通VIP」胶囊：未开通 = 空心皇冠（sys.symbol.crown）+「开通VIP」，已开通 = 实心皇冠（crown_fill）+「VIP」',
      'padding/圆角22/card_bg/阴影/clickEffect/Q弹缩放与 QQ 群按钮逐字对齐，行内顺序 VIP｜加入QQ群｜登录',
      'VIP 状态实时：@StorageLink(\'vipUnlocked\') + aboutToAppear 从 VipManager.isVip() 回填（冷启动首帧即正确），买完关窗幂等对账立刻变实心皇冠',
      '已开通点击只提示「你已是永久会员」，不再弹购买窗',
      '布局组「首页三段按钮排序」卡片底从 app.color.card_bg（夜间不透明 #26262A、无模糊）改为 ShelfColors.surface() + backgroundBlurStyle(COMPONENT_REGULAR)，与同页 SetListView 各行同一套材质',
      '真机像素复核：布局卡 #171719 vs 邻居 #151517（改前 #26262A，差 0x11），日间肉眼无差异',
      '新增 common/utils/ReadPromo.ets（唯一调度/持久化层）：累计阅读 ≥1h 弹「喜欢喵阅吗？」评分软引导（复用 RatingPromptDialog + AppGalleryUtil 错误码语义），未评价/拒绝后每 30 天一次直到评分',
      '≥10h 弹 VIP 开通弹窗，关闭后 90 天再自动弹第二次、此后不再主动弹，关窗时已是 VIP 则永久停推',
      '老用户「装上新版本一进就弹」：ReadPromo.init() 用 ReadDailyDao.totals(mode:\'all\')（先 await DataBase.whenReady()）把历史时长并入本地值（取 max、幂等），冷启动 1.2s 起判 + 最多 13 次 800ms 重试以覆盖 DB 8s 看门狗',
      'ReadTimeRecorder 两处埋点：commitSegment 把同一 sec 交给 ReadPromo.addSeconds',
      'detach 末尾自增 AppStorage \'readPromoTick\' 作为「刚退书」广播',
      'Index.ets 做唯一弹窗宿主：@StorageProp(\'readPromoTick\') @Watch 触发 + 冷启动判定',
      'readerActive 闸（阅读器在栈顶绝不弹）、首启弹窗让位、单弹窗互斥、每条关闭路径（onClose / 遮罩 cancel）都记账且幂等',
      '关于我们页标题居中：共用页头 SetHead 改 Stack（标题整行宽 + textAlign Center ⇒ 文字中心恒等于屏幕中心）',
      '真机 bounds 实测标题中心 x 579→660（旧 Flex 80% 方案系统性偏左 25vp），5 个引用页统一生效',
      '关于我们页整页顶部对齐：AboutPage 去掉弹性 Blank（实测未被拉伸，改为固定 padding-top，与 MySetPage 同写法），并按官方 faqs-arkui-725 给 Scroll 加 .align(Alignment.Top)——Scroll 被 layoutWeight 限高后内容不足一屏时默认居中，这是「整页居中」的真因',
      '真机 bounds 实测首行 y 910→274',
      '更新日志 / 开源许可两页同补该属性',
      '一键回退：ReadPromo.ENABLED=false 停全部主动推广',
      '关于页删掉 Scroll 的 .align(Alignment.Top) 即回旧排布',
      'SetHead 改动随 5 个引用页统一',
      '开发者暗门：长按「离线模式」在原有「重放首启引导」之外顺带 ReadPromo.debugReset()（清 5 个 readPromo* 键、不动 readDaily 表）',
      '清理 V3.0.5 被误提交的真机验证临时开关：删除 VipManager.FORCE_NOT_VIP_TEMP（强制 isVip()=false），ReadPromo 阈值恢复 1h / 10h / 30天 / 90天（验证期曾临时改为 20s/40s/60s 并旁路系统评分冷却）',
      '真机验证（Mate 80 Pro Max / 1320×2848）：评分引导 1h 门槛（验证期 48s）触发、30 天重试循环、去评分走 1021500009 后钉终态、VIP 弹窗第 1/2 次与「第 3 次不再弹」（日志 kind=1/2/0）、未开通与已开通两种胶囊形态、布局卡与邻居像素对齐、关于页标题中心 660 与首行 y=274',
    ]
  },
]

