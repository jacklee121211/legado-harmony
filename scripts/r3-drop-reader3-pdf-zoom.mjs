// 2026-11-03（R3 收尾）：删除 ReaderPage3 里已不可达的 PDF 原地缩放/双击放大体系。
// 前置证据：入口统一走 ReaderEntry 后，PDF 一律进 PdfViewerPage；真机 hilog 无 [READER-ENTRY] 告警。
// 做法：按「块」删除（自下而上，保持前面的行号有效），每块都断言标志串，防止删错。
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..')
const FILE = path.join(ROOT, 'entry/src/main/ets/pages/view/Reader/ReaderPage3.ets')
const dry = process.argv.includes('--dry-run')

const raw = fs.readFileSync(FILE, 'utf8')
const nl = raw.includes('\r\n') ? '\r\n' : '\n'
const lines = raw.split(/\r?\n/)

// 1-based 闭区间；每个块要求包含 expect 里的全部子串
const BLOCKS = [
  { from: 1325, to: 1345, expect: ['isPdfBook', 'pdfZoomPct', 'pdfPageIdx'], why: 'PDF 缩放状态字段' },
  { from: 5720, to: 5724, expect: ['pdfPageIdx'], why: 'spine→PDF 页码反推' },
  { from: 8464, to: 8556, expect: ['FMT_ZOOM_ENABLED', 'monopolizeEvents'], why: '捏合层 + >100% 独占手势层' },
  { from: 8557, to: 8613, expect: ["'重置'", 'bottomRectHeight'], why: '百分比 + 重置浮层' },
  { from: 9236, to: 9247, expect: ['pdfLastTapAt', 'zoomTo'], why: 'Blank 单击里的双击放大判定' },
  { from: 9482, to: 9492, expect: ['pdfLastTapAt', 'zoomTo'], why: 'content 单击里的双击放大判定' },
  { from: 12601, to: 12610, expect: ['isPdfBook', 'FMT_PDF_PAGES_PER_CHAPTER'], why: 'PDF 按页定位（seekToChapterRatio）' },
  { from: 12753, to: 12763, expect: ['private pdfScale'], why: 'pdfScale（PDF 满宽基准）' },
  { from: 12765, to: 12818, expect: ['readerKitScale', 'isPdfZoomed', 'zoomTo', 'publishPdfZoomState'], why: '缩放入口与状态广播' },
  { from: 12838, to: 12889, expect: ['pdfMaxOffsetX', 'snapBackPdfOffset'], why: '平移夹取/软边界/回弹' },
  { from: 12891, to: 12909, expect: ['resetPdfZoom'], why: 'resetPdfZoom（唯一出口已不存在）' },
]

for (const b of BLOCKS) {
  const seg = lines.slice(b.from - 1, b.to).join('\n')
  for (const e of b.expect) {
    if (!seg.includes(e)) throw new Error(`块对不上 L${b.from}-${b.to}（缺「${e}」）`)
  }
}

let out = lines.slice()
// 自下而上删除
for (const b of BLOCKS.slice().sort((x, y) => y.from - x.from)) {
  out.splice(b.from - 1, b.to - b.from + 1, `  // 2026-11-03（R3 收尾）：${b.why} —— PDF 已统一进 PdfViewerPage，此段不可达，已删除。`)
}

let text = out.join(nl)

// ── 逐点收尾（小块替换）──────────────────────────────────────────────────────
const subs = [
  // ① 缩放/位移绑定：去掉 PDF 分支
  {
    from: `          .scale({
            x: this.readerKitScale(),
            y: this.readerKitScale(),
            centerX: '50%',
            centerY: this.isPdfBook ? '50%' : 0
          })
          .translate({ x: this.pdfOffX, y: this.pdfOffY + this.readerKitInfoWinShiftY() })`,
    to: `          .scale({ x: READER_ZOOM, y: READER_ZOOM, centerX: '50%', centerY: 0 })
          .translate({ y: this.readerKitInfoWinShiftY() })`,
    label: 'scale/translate 去 PDF 分支',
  },
  // ② enterListenMode 的 PDF 拦截
  { from: `    if (this.isPdfBook) {\n      return;\n    }`, to: `    // （PDF 拦截已随 R3 删除：PDF 不进本页）`, label: 'enterListenMode 守卫' },
  // ③ 读模式回落的 PDF 拦截
  {
    from: `    if (this.isPdfBook && (m === READ_MODE_SCROLL || m === READ_MODE_NONE)) {
      hilog.info(0x0000, 'testTag', 'readMode: PDF 不支持自绘阅读（%{public}d），回落到横滑', m);
      m = READ_MODE_FLIP_SLIDE;
    }`,
    to: `    // （PDF 读模式回落已随 R3 删除）`,
    label: 'readMode 回落',
  },
  // ④ switchReadMode 的 PDF 拦截
  {
    from: `    if (this.isPdfBook && (next === READ_MODE_SCROLL || next === READ_MODE_NONE)) {
      this.getUIContext().getPromptAction().showToast({ message: 'PDF 请用双指缩放阅读' });
      return;
    }`,
    to: `    // （PDF 切档拦截已随 R3 删除）`,
    label: 'switchReadMode 拦截',
  },
  // ⑤ 整页位移的 PDF 分支
  { from: `    if (this.isPdfBook) {\n      return 0\n    }`, to: `    // （PDF 整页位移分支已随 R3 删除）`, label: 'readerKitInfoWinShiftY' },
  // ⑥ 进书时那一段「PDF 判定 + 全局缩放标志清理」→ 只保留"清阅读模式标志"（其它格式仍需要）
  {
    from: `    // PDF 书 ⇒ 挂上"点图放大"入口（开关 \`FMT_ZOOM_ENABLED\` 可一键关掉）
    this.isPdfBook = FMT_MASTER_ENABLED && FMT_PDF_ENABLED && isPdfPath(this.bookData.bookUrl ?? '');
    // 2026-11-03（P2/R3）：PDF 不再由任何入口进这里（统一 ReaderEntry -> PdfViewerPage）。
    //   保留判定只作防御：若将来出现漏网入口，这里会打明显告警，避免再次出现两套 PDF 体验并存。
    if (this.isPdfBook) {
      console.error('[READER-ENTRY] PDF 误入 ReaderPage3（入口应走 ReaderEntry -> PDF_VIEWER）：'
        + (this.bookData.bookName ?? ''));
    }
    // ⚠️ 缩放态是"另一方天地"，但它是**按书**的：换书/非 PDF 时必须把全局标志清掉，
    //    否则上一本 PDF 停在 150% 直接返回书架时，\`PDF_ZOOM_ACTIVE\` 会残留为 true
    //    ⇒ 下一本 txt 的"右滑返回书架"（CardLongTakeDelegate 的手势）会被误禁。
    if (!this.isPdfBook) {
      AppStorage.setOrCreate('PDF_ZOOM_ACTIVE', false);
    // ★ 同理清掉「无动画档」标志（2026-10-26）：它决定 \`Index.onBackPress()\` 要不要
    //   吞掉侧滑返回。若退出时残留 'none'，下一本用其它阅读方式的书**右滑就退不出去**。
    AppStorage.setOrCreate('READER_READ_MODE', '');
    }`,
    to: `    // 2026-11-03（R3 收尾）：PDF 判定与原地缩放体系已整块删除（PDF 一律进 PdfViewerPage）。
    // ★ 清掉「无动画档」标志（2026-10-26）：它决定 \`Index.onBackPress()\` 要不要吞掉侧滑返回。
    //   若退出时残留 'none'，下一本用其它阅读方式的书**右滑就退不出去**。
    AppStorage.setOrCreate('READER_READ_MODE', '');`,
    label: '进书时的 PDF 判定段',
  },
  // ⑦ import 里去掉 FMT_ZOOM_ENABLED
  { from: `FMT_ZOOM_ENABLED, `, to: ``, label: 'import 去掉 FMT_ZOOM_ENABLED' },
  // ⑧ 退书时那一条 PDF_ZOOM_ACTIVE 清理（连同它上面的注释两行）
  {
    from: `    // ★ 退出阅读页 ⇒ 清掉"PDF 放大中"这个全局标志（2026-10-19）：
    //   它同时被 \`CardLongTakeDelegate\`（右滑返回手势）与 \`Index.onBackPress\` 读取，
    //   若在 150% 直接返回书架而残留为 true，下一本书（尤其非 PDF）的右滑返回会被误禁。
    AppStorage.setOrCreate('PDF_ZOOM_ACTIVE', false);`,
    to: `    // 2026-11-03（R3 收尾）：\`PDF_ZOOM_ACTIVE\` 已不存在（PDF 放大体系删除）`,
    label: '退书时的缩放标志清理',
  },
]
for (const s of subs) {
  const f = s.from.split('\n').join(nl)
  if (!text.includes(f)) { console.log(`⚠️ 未命中：${s.label}`); continue }
  text = text.replace(f, s.to.split('\n').join(nl))
  console.log(`✓ ${s.label}`)
}

// ⑥ 清掉 `&& !this.isPdfBook` / `&& this.pdfZoomPct...` 这类残留子句
text = text.replace(/\n\s*&& !this\.isPdfBook/g, '')
// ⑦ 剩余 isPdfBook 引用清点（应为 0，否则说明还有块没删）
const left = (text.match(/isPdfBook|pdfZoomPct|pdfOffX|pdfOffY|pdfPinching|pdfZoomBase|pdfOffBase|pdfLastTapAt|pdfPageIdx|PDF_ZOOM_ACTIVE|FMT_ZOOM_ENABLED/g) ?? [])
console.log(`剩余 PDF 相关标识符：${left.length} → ${[...new Set(left)].join(', ')}`)
console.log(`行数：${lines.length} → ${text.split(/\r?\n/).length}`)

if (!dry) {
  fs.writeFileSync(FILE, text, 'utf8')
  console.log('已写入')
} else {
  console.log('[dry-run] 未写入')
}
