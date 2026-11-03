// 2026-11-03（P1/R1）：把 BookInfos / BookInfoGrids 的 pdf 判定 + 一镜到底参数拼装
// 收进 `ReaderEntry`（唯一入口）。本脚本只做**锚点区间替换**，先 --dry-run 打印计划。
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..')
const dry = process.argv.includes('--dry-run')

const FILES = {
  list: 'entry/src/main/ets/pages/view/bookShelf/components/BookInfos.ets',
  grid: 'entry/src/main/ets/pages/view/bookShelf/components/BookInfoGrids.ets',
}

function replaceSpan(text, startAnchor, endAnchor, replacement, label) {
  const i = text.indexOf(startAnchor)
  if (i < 0) throw new Error(`[${label}] 起始锚点未找到：${startAnchor.slice(0, 40)}`)
  const j = text.indexOf(endAnchor, i)
  if (j < 0) throw new Error(`[${label}] 结束锚点未找到：${endAnchor.slice(0, 40)}`)
  const before = text.slice(0, i)
  const after = text.slice(j)
  return { text: before + replacement + after, removed: text.slice(i, j) }
}

const plan = []
let changed = 0

// ── 列表模式 ────────────────────────────────────────────────────────────────
{
  const p = path.join(ROOT, FILES.list)
  let t = fs.readFileSync(p, 'utf8')
  const orig = t

  // ① 从 PDF 判定开始，到 openReaderWhenIdle(rp, 0) 之前，整体替换
  const r1 = replaceSpan(
    t,
    '      // ── PDF：走**官方 PdfView 组件**页（2026-10-20 用户拍板：以官方为基础，推翻重做）──',
    '      this.openReaderWhenIdle(rp, 0)',
    `      // 2026-11-03（P1 / R1）：\`pdf / 其它格式\` 的入口判定**已收口到 \`ReaderEntry\`**。
      //   本处只保留两件局部职责：
      //     ① \`UnsupportedDoc\` 的 .doc/.docx 拦截（需要页面级 context，见上面的 if）
      //     ② 「转场进行中」闸（\`openReaderWhenIdle\`）—— 防"纯黑阅读器"，
      //        它只负责**延后推路由**，不再关心进哪个页面。
      //   一镜到底几何必须在**点击瞬间**拍（prepare 是同步的）；列表封面圆角 60 / 圆角参数 4。
      const launch: ReaderLaunch = ReaderEntry.prepare(this.getUIContext(), this.book,
        { longtakeId: this.longtakeId, coverWidth: 60, longtakeCorner: 4 });
`,
    'list/span1')
  t = r1.text
  plan.push(`[list] 移除 ${r1.removed.split('\n').length} 行 pdf/reader 参数拼装`)

  // ② 闸函数签名 + 推送体
  const sigOld = '  private openReaderWhenIdle(rp: ReaderRouteParam, tries: number): void {'
  const sigNew = '  private openReaderWhenIdle(launch: ReaderLaunch, tries: number): void {'
  if (!t.includes(sigOld)) throw new Error('[list] 闸函数签名未找到')
  t = t.replace(sigOld, sigNew)
  t = t.replace('        this.openReaderWhenIdle(rp, tries + 1)', '        this.openReaderWhenIdle(launch, tries + 1)')
  t = t.replace('    AppRouter.push(RouteName.READER, rp)\n', '    ReaderEntry.launch(launch)\n')
  t = t.replace('    AppRouter.push(RouteName.READER, rp)\r\n', '    ReaderEntry.launch(launch)\r\n')

  // ③ 导入
  const impAnchor = "import AppRouter, { PdfRouteParam, RouteName, ReaderRouteParam } from '../../../../common/router/AppRouter'"
  if (!t.includes(impAnchor)) throw new Error('[list] AppRouter import 锚点未找到')
  t = t.replace(impAnchor, impAnchor + "\nimport { ReaderEntry, ReaderLaunch } from '../../../../common/reader/ReaderEntry'")

  if (t !== orig) { changed++; plan.push(`[list] 共 ${t.length - orig.length} 字符变化`) }
  if (!dry) fs.writeFileSync(p, t, 'utf8')
}

// ── 宫格模式 ────────────────────────────────────────────────────────────────
{
  const p = path.join(ROOT, FILES.grid)
  let t = fs.readFileSync(p, 'utf8')
  const orig = t

  // ① 删掉 pdf 立即推 + 死回退分支（253-282 那段）
  const r1 = replaceSpan(
    t,
    '      // PDF ⇒ 官方 PdfView 组件页（2026-10-20，与列表模式 `BookInfos` 同款；理由见其注释）',
    '      clickUtil.preventClick(()=>{',
    `      // 2026-11-03（P1 / R1）：pdf 判定收口到 \`ReaderEntry\`（宫格不再单独判 pdf / 不再有自研回退分支）。
      //   原先 pdf 分支是**立即推**、其它格式走「转场进行中」闸 ⇒ 两条路径不一致；现在统一进闸。
`,
    'grid/span1')
  t = r1.text
  plan.push(`[grid] 移除 ${r1.removed.split('\n').length} 行 pdf 立即推 + 自研回退`)

  // ② 把 closure 里那段 rp 拼装（含 longtake）替换成 prepare，并把闸调用参数换掉
  const r2 = replaceSpan(
    t,
    '        // ── 需求第 6 项修复（2026-09-24）──────────────────────────────────────',
    '        this.openReaderWhenIdle(rp, 0)',
    `        // 2026-11-03（P1 / R1）：与列表模式同一个入口；宫格封面圆角 100 / 圆角参数 10。
        const launch: ReaderLaunch = ReaderEntry.prepare(this.getUIContext(), this.book,
          { longtakeId: this.longtakeId, coverWidth: 100, longtakeCorner: 10 });
`,
    'grid/span2')
  t = r2.text
  plan.push(`[grid] 移除 ${r2.removed.split('\n').length} 行 reader 参数拼装`)
  t = t.replace('        this.openReaderWhenIdle(rp, 0)', '        this.openReaderWhenIdle(launch, 0)')

  // ③ 闸函数
  const sigOld = '  private openReaderWhenIdle(rp: ReaderRouteParam, tries: number): void {'
  if (!t.includes(sigOld)) throw new Error('[grid] 闸函数签名未找到')
  t = t.replace(sigOld, '  private openReaderWhenIdle(launch: ReaderLaunch, tries: number): void {')
  t = t.replace('        this.openReaderWhenIdle(rp, tries + 1)', '        this.openReaderWhenIdle(launch, tries + 1)')
  t = t.replace('    AppRouter.push(RouteName.READER, rp)\n', '    ReaderEntry.launch(launch)\n')
  t = t.replace('    AppRouter.push(RouteName.READER, rp)\r\n', '    ReaderEntry.launch(launch)\r\n')

  // ④ 导入
  const impAnchor = "import AppRouter, { PdfRouteParam, RouteName, ReaderRouteParam } from '../../../../common/router/AppRouter'"
  if (!t.includes(impAnchor)) {
    const alt = t.match(/^import AppRouter.*AppRouter'$/m)
    plan.push(`[grid] ⚠️ AppRouter import 形态不同：${alt ? alt[0] : '未找到'}`)
  } else {
    t = t.replace(impAnchor, impAnchor + "\nimport { ReaderEntry, ReaderLaunch } from '../../../../common/reader/ReaderEntry'")
  }

  if (t !== orig) { changed++; plan.push(`[grid] 共 ${t.length - orig.length} 字符变化`) }
  if (!dry) fs.writeFileSync(p, t, 'utf8')
}

console.log(plan.join('\n'))
console.log(`\n${dry ? '[dry-run] ' : ''}改动文件数 ${changed}/2`)
