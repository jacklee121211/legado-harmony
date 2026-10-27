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
export const APP_VERSION_FALLBACK: string = 'V3.0.7'

/** 更新日志（默认只含**当前版本**一条；-MaxVersions 调大才有多条历史） */
export const VERSION_LOGS: VersionEntry[] = [
  {
    version: 'V3.0.7 交接文档补充「效果上限」评估',
    date: '2026-10-28',
    items: [
      '新增 §5.3 效果上限：明确 drawPixelMapMesh 能到 80~85 分，做不到逐像素物理模拟',
      '记录能力边界证据：@ohos.graphics.drawing 无 shader/RuntimeEffect/实时光照（检索仅命中 FilterMode/MaskFilter/Brush），drawPixelMapMesh 无法线无光照模型',
      '分列能做（几何/明暗渐变/背面/透视）与做不到（纸张透光/锐利高光/法线实时变化/多层折痕）及各自原因',
      '记录 95 分的唯一路径：XComponent + OpenGL ES 自定义 fragment shader，代价 2~4 周 + C++ 管线 + black-screen 调试',
      '原 5.3 终局形态顺延为 5.4',
      '标注「iBooks/掌阅高级感主要来自贴图与美术调校」为【推测】，未取证',
    ]
  },
]

