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
export const APP_VERSION_FALLBACK: string = 'V3.0.3'

/** 更新日志（默认只含**当前版本**一条；-MaxVersions 调大才有多条历史） */
export const VERSION_LOGS: VersionEntry[] = [
  {
    version: 'V3.0.3 阅读器双引擎版式对齐 + 章标题样式 + 听书跟随修复',
    date: '2026-10-28',
    items: [
      '新增 EngineLines.ets：用 @ohos.graphics.text 建立「引擎排行」层（layoutSync + getLineMetrics），产出每行文本/段首标记/段内字符区间/真实行高，作为自绘两档唯一的排版权威',
      '「无动画」与「上下」两档改为同源消费该行数据，渲染从「每段一个 Text」改为「每行一个 Text」，彻底解决字号放大溢出、缩小下半屏空白',
      '修复 StrutStyle 只给 height 不生效（实测 m.height 仅返回字体自然高度 95px，配置 193.61px 被忽略）：必须同时给 enabled/heightOverride/forceHeight，修复后 194px 与配置吻合',
      '分页改用引擎实测的 LineMetrics.height 累加（而非配置行高），消除最后一行溢出到 dock 下方',
      '新增正文字距 LETTER_SPACING_FP=1.7fp：实测同字号下 ReaderKit 86.2px/字、我们 80.4px/字，导致每行多塞 1 字、页边界系统性错位',
      '行高去掉 effectiveLineMul()：该系数是旧架构「用 ReaderKit 每页行数反推行高」的产物，新架构下把行距撑大 25%（193px vs ReaderKit 154px）',
      '段间距 SCROLL_PARA_GAP_EM 0.45→0.95',
      '章标题样式：ChapterNodes 新增 isTitle[]，HTML 走 h1-h6 标签',
      'TXT 因 getSpineItemContent 返回纯文本（探针实证 hasTag=NO），改用 ReaderKit 的目录名反查章首段。标题按 TITLE_FONT_SCALE=1.33、TITLE_FONT_WEIGHT=600、顶格不缩进渲染，实测标题宽度 775px vs ReaderKit 776px',
      '自绘两档上下 inset 微调（SELF_DRAWN_TOP_TRIM_VP=10 / SELF_DRAWN_BOTTOM_PAD_VP=30）：章标题顶部 385px vs ReaderKit 384px，且消除第 3 页起「每页多装 1 行」的分叉',
      'fontSerial/fontName/fontPath/fontSize/lineHeightFp/indentFp/gapEm 全部挂 @Watch：原来改字号只重建不重排，页面仍按旧字号行数渲染',
      '修复 applySelfDrawnPos 的 endChar 恒为 0：rangeCovers 会把「朗读在页末段第 5 个字」误判为不在当前页，导致 autoFollowTts 白翻一页',
      '新增 scrollFontPath()：自绘排版层需要真实字体文件路径给 FontCollection.loadFontSync 注册，否则引擎回落默认字体、字宽不同、断行全错',
      '已知残留：段间距仍为 0.95em（ReaderKit 实测约 93px / 我们 77px），当前靠底部 inset 补偿维持页码对齐',
      '换段落密度差异大的书需重新验证',
    ]
  },
]

