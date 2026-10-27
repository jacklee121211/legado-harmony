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
export const APP_VERSION_FALLBACK: string = 'V3.0.5'

/** 更新日志（默认只含**当前版本**一条；-MaxVersions 调大才有多条历史） */
export const VERSION_LOGS: VersionEntry[] = [
  {
    version: 'V3.0.5 新增阅读器交接文档 + 标注废弃方案',
    date: '2026-10-28',
    items: [
      '新增 docs/阅读器翻页自研-交接文档-2026-10-28.md：换会话时让 agent 首读，含当前双引擎架构、版式对齐五参数、已否决方案、9 个实测坑、新方向（drawPixelMapMesh 真 mesh warp）、残留问题清单、验证命令、用户偏好',
      'docs/最终方案-横滑仿真移植.md 顶部标注【已废弃】：移植基座 readerLibrary 方案经真机实测否决（逐列 drawImage 拼条带 → 接缝/断裂/无透视',
      '横滑无阻尼无惯性），且基座 readerLibrary 本身是无路由的废弃模块',
      'AGENTS.md 新增第 7 节「阅读器：先读交接文档」并重编号（原 7/8 → 8/9），把「动阅读器前必读交接文档」升为硬门槛',
      '技术结论记录：官方 drawPixelMapMesh（@since 12，colors @since 20）是仿真卷曲的正确底层，可一次绘制整张变形图、无接缝',
      'drawVertices 是 @since 23 超出兼容线不可用',
    ]
  },
]

