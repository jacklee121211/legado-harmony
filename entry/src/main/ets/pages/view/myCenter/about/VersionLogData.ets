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
export const APP_VERSION_FALLBACK: string = 'V2.2.4'

/** 更新日志（默认只含**当前版本**一条；-MaxVersions 调大才有多条历史） */
export const VERSION_LOGS: VersionEntry[] = [
  {
    version: 'V2.2.4 补齐 GPL-',
    date: '2026-10-24',
    items: [
      '0 许可证全文入口',
      '应用内「开源许可」页新增「许可证全文」卡：GPL-3.0 / MPL-2.0 / Apache-2.0 / MIT 四条，标注各自覆盖范围，点击经 openLink 打开官方全文页，地址行可长按复制兜底',
      '该项补齐 GPL-3.0 §5(d) 强制要求：§0 对 Appropriate Legal Notices 的定义含「how to view a copy of this License」，此前应用内只写「以官方仓库许可证原文为准」而无任何可点击入口',
      'THIRD_PARTY_NOTICES 新增第 6 节「许可证全文入口」表格，并把「更新方式」从两处同步改为三处（依赖清单 / LICENSES / LICENSE_TEXTS）',
    ]
  },
]

