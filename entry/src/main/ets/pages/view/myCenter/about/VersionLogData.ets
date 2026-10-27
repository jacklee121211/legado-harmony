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
export const APP_VERSION_FALLBACK: string = 'V3.0.9'

/** 更新日志（默认只含**当前版本**一条；-MaxVersions 调大才有多条历史） */
export const VERSION_LOGS: VersionEntry[] = [
  {
    version: 'V3.0.9 主题三档持久化修复 + 三胶囊等宽 + 评分引导改为「未评分且超 30 天就再推」',
    date: '2026-10-28',
    items: [
      '修复「亮/暗色选择重启后被还原成自动」：根因是 `NightMode.init()` 用 `PersistentStorage.persistProp` 落盘，而它在 `loadContent` 之前被调用 —— 官方原文（documentId `FAQ/本地数据和文件/本地数据库管理/如何解决PersistentStorage在EntryAbility中获取持久化数据失败的问题/faqs-local-database-management-60`）：「持久化操作需要在 UI 实例初始化成功后（即 loadContent 传入的回调被调用时）才可以被调用，早于该时机调用会导致持久化失败」⇒ 写不进也读不回',
      '改为显式 Preferences 通道（与 FirstRunMode / ReadPromo / VipManager 同一落盘方式）：init() 从 Preferences 读回三档并写 AppStorage，setMode() 先 putSync 再写 AppStorage 再 sync',
      'AppStorage 仍作运行期广播键。真机实证：选暗色→杀进程重进 `init mode=dark`、选亮色→重进 `init mode=light`（系统是深色，只有持久化成功才会亮）、选自动→重进 `init mode=auto`，日志三条齐全',
      'EntryAbility 里「必须在 loadContent 之前建好」的旧注释与官方时机约束冲突，已按事实改写（保留"必须在 loadContent 之前"的理由，但落盘不再依赖 PersistentStorage）',
      '设置页三胶囊等宽居中：VIP / 加入Q群 / 登录 各 `.layoutWeight(1)`（父 Row 三等分自适应，不再写死宽度）＋内部 `justifyContent(Center)`',
      '横向 padding 20→8（等宽后不能再吃 20）',
      '字号统一 13 号 600（旧「登录」是 14 号，三枚并排显高矮不齐）',
      '行左右各留 16。真机 bounds：三枚各 377px、间距 41px、左右留白各 54px',
      '「加入QQ群」文案按用户口径改为「加入Q群」（群号文案不变）',
      '评分引导口径改为用户拍板版：**不需要知道用户是否真的评价了**，只看「未评分 && 上次推送超过 30 天」就再推 ⇒ 点「去评分」只记 `markRatingShown()`（30 天计时清零），**不再**写 `markRatingDone()`',
      '是否已评分仍由既有判断 `AppGalleryUtil.shouldSkipPrompt()`（系统错误码 0007/0009/0008 落盘）决定，命中才钉终态',
      '0006 未登录 / 0001-0005 不可用都按 30 天后再来',
      '真机验证（Mate 80 Pro Max）：三档持久化三次冷启动全通过',
      '三胶囊等宽 bounds 已量',
      '构建 BUILD SUCCESSFUL，mcp check 0 error（仅既有 severity 2 警告）',
    ]
  },
]

