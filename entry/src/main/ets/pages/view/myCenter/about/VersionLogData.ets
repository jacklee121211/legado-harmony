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
export const APP_VERSION_FALLBACK: string = 'V3.0.4'

/** 更新日志（默认只含**当前版本**一条；-MaxVersions 调大才有多条历史） */
export const VERSION_LOGS: VersionEntry[] = [
  {
    version: 'V3.0.4 听书体系重构：锁死无动画 + 长按从此处听 + 定位精度修复',
    date: '2026-10-28',
    items: [
      '听书模式锁死无动画：switchReadMode 拦截切到其它档位并提示「听书模式固定使用无动画，关闭听书后会自动切回」，退出听书时自动还原原档位',
      'enterListenMode 判据从 selfDrawnModeOn 改为 noAnimModeOn：横滑/仿真/上下开听书一律切到无动画',
      '修复切档后不自动翻页：applySelfDrawnPos 把「切档」误判成「用户手动翻走」导致 followSuspended=true、autoFollowTts 首行直接 return',
      '新增 rearmListenFollow 在切档后清除挂起并刷新 lastNavMs',
      '听书高亮体系统一：删除「沉浸听读」开关（TtsControlPanel），immersiveActive 恒 false —— 听书永远走自绘 Span 高亮，ReaderKit 的栅格色块/沉浸层不再有机会激活',
      '新增长按「从此处听书」：长按正文任意一行弹出圆角胶囊气泡，点击后 TtsEngine.seekToChapter 从该段开始读。气泡挂在触摸分区层并用落点 y 逐行累加反算命中行（正文 Text 在 Stack 中层，收不到手势）',
      '修复「从本页开始读跳到上一页」：applySelfDrawnPos 的 startChar 不再写死 0，改由 reportAt 上报页首行 charFrom',
      'onPos 签名扩展为 (spine,node,endNode,startChar,endChar)',
      '修复切档后落到上一页：新增 indexOfNode 的 char 参数，按「包含该字符」的页定位而非「该段起始页」',
      'switchReadMode 交接时传递 scrollInitChar',
      '修复点击书签后一路播放翻页动画：书签 char 恒为 0，与「页首是续段（startChar>0）」冲突时 rangeCovers 判为未落位 ⇒ 触发 beginSearch 逐页逼近（上限 60 页）。新增 locateHit：char<=0 时只按段号判定',
      '书签弹窗入口补 noFallback',
      '迷你条字幕改为「正在朗读的章节名」：ArkUI 原生 marqueeOptions（@since 18），放得下静态、放不下缓慢循环滚动，替代原先按字符比例滚动的跑马灯',
      '悬浮条「从此页开始」改为「回当前进度」并修正行为：原实现是 playFromCurrentPage（从当前页开始读），改为解除挂起 + requestLocate 跳回朗读位置',
      '设置页：QQ群 / 登录 / QQ群号整块从列表底部移到第一个 ListItem',
      '删除后门里的「打开标定模式」（标尺/几何校准）开关及其 switch 分支、calibDevWrite、CalibMode import',
    ]
  },
]

