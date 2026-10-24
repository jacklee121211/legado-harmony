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
export const APP_VERSION_FALLBACK: string = 'V2.2.3'

/** 更新日志（默认只含**当前版本**一条；-MaxVersions 调大才有多条历史） */
export const VERSION_LOGS: VersionEntry[] = [
  {
    version: 'V2.2.3 合规修正与听书算法重构',
    date: '2026-10-24',
    items: [
      '更正 THIRD_PARTY_NOTICES / README / 应用内许可页对 ColorTxt 的失实表述（原写「无代码复制」「MPL-2.0 带 Exhibit B」），改为如实披露：PauseSplicer.ets 含其 src/shared/voiceReadPunctuationPauses.ts 的衍生代码',
      '补登记 @hmanimations/ezcustomtransition v1.3.0（Apache-2.0），此前两处均遗漏',
      'PauseSplicer.ets 文件头补 MPL-2.0 Exhibit A 通知与上游来源（项目地址/文件地址/引入与修改日期），并说明依 MPL-2.0 §3.3 同时以 GPL-3.0 提供',
      '重写 collectPauseRuns（逐字符状态机→单条全局正则切簇）、alignWords（reduce 折叠）、mergeRanges（reduce 返回新数组）、scaledPauseMs（分步守卫），与 ColorTxt 文件级重合 20.8%→7.3%',
      '许可页每条增加上游地址并支持点击跳转（openLink），此前「项目地址」卡仅有文本、点击无反应',
      '新增 scripts/tts-verify 三支等价性验证脚本：346 检查点含 PCM 逐字节比对，确认重构后输出与重构前完全一致',
    ]
  },
]

