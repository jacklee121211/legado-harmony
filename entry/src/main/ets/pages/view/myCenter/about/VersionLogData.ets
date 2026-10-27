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
export const APP_VERSION_FALLBACK: string = 'V3.0.6'

/** 更新日志（默认只含**当前版本**一条；-MaxVersions 调大才有多条历史） */
export const VERSION_LOGS: VersionEntry[] = [
  {
    version: 'V3.0.6 交接文档强制纳入版本控制',
    date: '2026-10-28',
    items: [
      'docs/ 整个目录在 .gitignore 第 16 行被忽略，导致 AGENTS.md 第 7 节引用的交接文档不跟踪 —— 换机器 clone 后会指向不存在的文件',
      '按项目已有先例（docs/底部手势区贯通-排查记录.md 曾强制跟踪）用 git add -f 纳入：docs/阅读器翻页自研-交接文档-2026-10-28.md、docs/最终方案-横滑仿真移植.md',
      '仅这两份纳入，docs/ 其余 84 个文件维持忽略不变',
    ]
  },
]

