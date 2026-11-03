// 2026-11-03（双轨收口·三）：把最后 8 处 @StorageLink(@Watch) 订阅迁到 GroupEvents 监听器。
// 每个站点：@StorageLink(KEY) @Watch('cb') VAR  →  @State @Watch('cb') VAR
//          + 监听器字段（按 refreshGroups/refreshBooks 过滤后 VAR++）
//          + aboutToAppear 订阅 / aboutToDisappear 取消订阅
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..')
const ETS = path.join(ROOT, 'entry/src/main/ets')
const dry = process.argv.includes('--dry-run')

const SITES = [
  { file: 'componets/group/GroupType.ets', key: 'BOOK_IS_BOOK_GROUPS_REFRESHING', v: 'BOOK_IS_BOOK_GROUPS_REFRESHING', kind: 'groups', cb: 'changeRefresh' },
  { file: 'pages/view/BookDetailPage.ets', key: 'BOOK_IS_BOOK_REFRESHING', v: 'isBookRefreshing', kind: 'books', cb: 'onShelfBroadcast' },
  { file: 'pages/view/bookShelf/BookFolder.ets', key: 'BOOK_IS_BOOK_GROUPS_REFRESHING', v: 'BOOK_IS_BOOK_GROUPS_REFRESHING', kind: 'groups', cb: 'getGroupList' },
  { file: 'pages/view/bookShelf/BookFolder.ets', key: 'BOOK_IS_BOOK_REFRESHING', v: 'BOOK_IS_BOOK_REFRESHING', kind: 'books', cb: 'refreshGroupCounts' },
  { file: 'pages/view/bookShelf/components/BookContent.ets', key: 'BOOK_IS_BOOK_REFRESHING', v: 'isBookRefreshing', kind: 'books', cb: 'isRefresh' },
  { file: 'pages/view/bookShelf/components/BookContentRefresh.ets', key: 'BOOK_IS_BOOK_GROUPS_REFRESHING', v: 'groupRefreshing', kind: 'groups', cb: 'onShelfRefresh' },
  { file: 'pages/view/bookShelf/components/BookContentRefresh.ets', key: 'BOOK_IS_BOOK_REFRESHING', v: 'bookRefreshing', kind: 'books', cb: 'onShelfRefresh' },
  { file: 'pages/view/bookShelf/Manage/BookManagePage.ets', key: 'BOOK_IS_BOOK_GROUPS_REFRESHING', v: 'BOOK_IS_BOOK_GROUPS_REFRESHING', kind: 'groups', cb: 'getGroupList' },
]

// 按文件聚合
const byFile = new Map()
for (const s of SITES) {
  if (!byFile.has(s.file)) byFile.set(s.file, [])
  byFile.get(s.file).push(s)
}

function relImport(file) {
  // file: entry/src/main/ets/<sub>；目标：entry/src/main/ets/common/group/GroupEvents
  const depth = file.split('/').length - 1 // 相对 ets 根的子目录层数
  return '../'.repeat(depth) + 'common/group/GroupEvents'
}

let changed = 0
for (const [file, sites] of byFile) {
  const abs = path.join(ETS, file)
  let text = fs.readFileSync(abs, 'utf8')
  const nl = text.includes('\r\n') ? '\r\n' : '\n'
  const lines = text.split(/\r?\n/)

  // ① 逐个装饰器行替换（按 key+var 精确定位，且必须含 @Watch）
  const bumps = []
  for (const s of sites) {
    const idx = lines.findIndex((l) => l.includes(`@StorageLink('${s.key}')`) && l.includes(s.v) && l.includes('@Watch'))
    if (idx < 0) throw new Error(`${file}: 找不到 ${s.key} / ${s.v} 的 @StorageLink@Watch 行`)
    const original = lines[idx]
    const m = original.match(/@Watch\(\s*(['"])([^'"]+)\1\s*\)/)
    lines[idx] = `  @State @Watch('${m ? m[2] : s.cb}') ${s.v}: number = 0`
    bumps.push({ v: s.v, kind: s.kind })
  }

  // ② 监听器字段（插在最后一个被替换行之后）
  const lastIdx = Math.max(...sites.map((s) => lines.findIndex((l) => l.includes(`@State @Watch`) && l.includes(s.v))))
  const conds = bumps.map((b) => `    if (p.${b.kind === 'groups' ? 'refreshGroups' : 'refreshBooks'}) { this.${b.v}++ }`).join(nl)
  const listener = [
    '  /**',
    '   * 2026-11-03（双轨收口）：由 `GroupEvents` 事件驱动刷新（替代 AppStorage 计数器 + @StorageLink）。',
    '   * 语义不变：意图命中就把 tick 加一 ⇒ 上面的 `@Watch` 回调照旧触发重查。',
    '   */',
    '  private shelfListener: GroupChangedListener = (p: GroupChangedPayload): void => {',
    conds,
    '  }',
  ].join(nl)
  lines.splice(lastIdx + 1, 0, listener)

  // ③ import
  const imp = `import { GroupEvents, GroupChangedListener, GroupChangedPayload } from '${relImport(file)}'`
  if (!lines.some((l) => l.includes('GroupChangedListener'))) {
    const firstImport = lines.findIndex((l) => l.startsWith('import '))
    lines.splice(firstImport, 0, imp)
  }

  // ④ 生命周期挂载
  const find = (re) => lines.findIndex((l) => re.test(l))
  const appear = find(/^\s{2}(async\s+)?aboutToAppear\s*\(/)
  if (appear >= 0) {
    lines.splice(appear + 1, 0, '    GroupEvents.subscribe(this.shelfListener)')
  } else {
    const buildIdx = find(/^\s{2}build\s*\(/)
    lines.splice(buildIdx, 0,
      '  aboutToAppear(): void {',
      '    GroupEvents.subscribe(this.shelfListener)',
      '  }', '')
  }
  const disappear = find(/^\s{2}aboutToDisappear\s*\(/)
  if (disappear >= 0) {
    lines.splice(disappear + 1, 0, '    GroupEvents.unsubscribe(this.shelfListener)')
  } else {
    const buildIdx = find(/^\s{2}build\s*\(/)
    lines.splice(buildIdx, 0,
      '  aboutToDisappear(): void {',
      '    GroupEvents.unsubscribe(this.shelfListener)',
      '  }', '')
  }

  changed++
  console.log(`  ✓ ${file}（${sites.length} 个订阅）`)
  if (!dry) fs.writeFileSync(abs, lines.join(nl), 'utf8')
}
console.log(`${dry ? '[dry-run] ' : ''}共处理 ${changed} 个文件`)
