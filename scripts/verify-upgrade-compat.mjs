// 升级兼容性验证：模拟「3.0.0 老库 → 当前版本」的两次迁移，验证进度/书签不丢、唯一索引能建。
// 依据（仓库原文）：
//   · V3.0.0 (7c8af07) 的 books / bookmarks createSql 与当前**逐列相同**；book_groups 缺 parentId
//   · AppDatabaseUtil.existsTable() 是唯一的 schema 迁移实现，只做 ALTER TABLE ADD COLUMN
//   · 快照里的 indices 全工程没有执行者 ⇒ 索引要显式 CREATE UNIQUE INDEX
import { DatabaseSync } from 'node:sqlite'
import fs from 'node:fs'
import path from 'node:path'

const dir = process.argv[2]
if (!dir) { console.error('用法: node verify-upgrade-compat.mjs <设备库快照目录>'); process.exit(2) }

const V300_BOOKS = "CREATE TABLE IF NOT EXISTS books (`id` INTEGER NOT NULL, `bookUrl` TEXT, `toUrl` TEXT, `origin` TEXT, `originName` TEXT, `bookName` TEXT NOT NULL, `author` TEXT, `cover` TEXT, `customTag` TEXT, `coverUrl` TEXT, `customCoverUrl` TEXT, `builtinCoverUrl` TEXT, `intro` TEXT, `customIntro` TEXT, `charset` TEXT, `bookGroup` INTEGER NOT NULL DEFAULT 3, `latestChapterTitle` TEXT, `latestChapterTime` INTEGER NOT NULL DEFAULT 0, `lastCheckTime` INTEGER NOT NULL DEFAULT 0, `lastCheckCount` INTEGER NOT NULL DEFAULT 0, `totalChapterNum` INTEGER NOT NULL DEFAULT 0, `durChapterTitle` TEXT, `durChapterIndex` INTEGER NOT NULL DEFAULT 0, `durChapterPos` INTEGER NOT NULL DEFAULT 0, `durChapterTime` INTEGER NOT NULL DEFAULT 0, `wordCount` TEXT, `canUpdate` INTEGER NOT NULL DEFAULT 1, `sort` INTEGER NOT NULL DEFAULT 0, `originOrder` INTEGER NOT NULL DEFAULT 0, `syncTime` INTEGER NOT NULL DEFAULT 0, `bookType` INTEGER NOT NULL DEFAULT 0, `isTop` INTEGER NOT NULL DEFAULT 0, `createTime` INTEGER NOT NULL DEFAULT 0,`updateTime` INTEGER NOT NULL DEFAULT 0,`isJoin` INTEGER NOT NULL DEFAULT 1, `isLocalBook` INTEGER NOT NULL DEFAULT 0, `finishedTime` INTEGER NOT NULL DEFAULT 0, `fileSize` INTEGER NOT NULL DEFAULT 0, PRIMARY KEY (`id`))"
const V300_GROUPS = "CREATE TABLE IF NOT EXISTS book_groups (`groupId` INTEGER NOT NULL, `groupName` TEXT NOT NULL, `coverUrl` TEXT, `groupDescribe` TEXT, `sort` INTEGER NOT NULL, `enableRefresh` INTEGER NOT NULL DEFAULT 1, `show` INTEGER NOT NULL DEFAULT 1, `groupType` INTEGER NOT NULL DEFAULT 0, `createTime` INTEGER NOT NULL DEFAULT 0, `updateTime` INTEGER NOT NULL DEFAULT 0, `bookSort` INTEGER NOT NULL DEFAULT -1, `canUpdate` INTEGER NOT NULL DEFAULT 0, `coverOnly` INTEGER NOT NULL DEFAULT 0, `coverType` INTEGER NOT NULL DEFAULT 0, `canDelete` INTEGER NOT NULL DEFAULT 1, `isTop` INTEGER NOT NULL DEFAULT 0,`isSystem` INTEGER NOT NULL DEFAULT 0,`bookIds` TEXT,PRIMARY KEY(`groupId`))"
const V300_BOOKMARKS = "CREATE TABLE IF NOT EXISTS bookmarks (`time` INTEGER NOT NULL, `bookName` TEXT NOT NULL, `bookAuthor` TEXT NOT NULL, `chapterIndex` INTEGER NOT NULL, `chapterPos` INTEGER NOT NULL, `chapterName` TEXT NOT NULL, `bookText` TEXT NOT NULL, `content` TEXT NOT NULL, PRIMARY KEY(`time`))"

// ── 场景 A：设备库快照（当前版本跑一遍迁移，确认幂等）────────────────────────────
function runMigration(db, label) {
  // ① existsTable 的等价物：只补缺列
  const cols = db.prepare('PRAGMA table_info(book_groups)').all().map(c => c.name)
  if (!cols.includes('parentId')) {
    db.exec("ALTER TABLE book_groups ADD COLUMN 'parentId' INTEGER DEFAULT '0'")
    console.log(`  [${label}] existsTable: book_groups 缺 parentId → ALTER TABLE ADD COLUMN（默认 '0'）`)
  } else {
    console.log(`  [${label}] existsTable: parentId 已存在，无需补列`)
  }
  // ② ensureSiblingUniqueIndex 三步
  db.exec('UPDATE book_groups SET parentId = 0 WHERE parentId IS NULL')
  db.exec("UPDATE book_groups SET parentId = 0 WHERE typeof(parentId) = 'text' AND TRIM(parentId) = ''")
  const rows = db.prepare('SELECT groupId, groupName, parentId FROM book_groups ORDER BY groupId ASC').all()
  const used = new Map()
  let renamed = 0
  for (const r of rows) {
    const pid = r.parentId ?? 0
    const name = String(r.groupName ?? '').trim()
    const key = `${pid}|${name}`
    if (!used.has(key)) { used.set(key, true); continue }
    let n = 2
    let candidate = `${name} (${n})`
    while (used.has(`${pid}|${candidate}`) && n <= 99) { n++; candidate = `${name} (${n})` }
    used.set(`${pid}|${candidate}`, true)
    db.prepare('UPDATE book_groups SET groupName = ? WHERE groupId = ?').run(candidate, r.groupId)
    console.log(`  [${label}] 去重改名 groupId=${r.groupId} 「${name}」→「${candidate}」`)
    renamed++
  }
  db.exec('CREATE UNIQUE INDEX IF NOT EXISTS index_book_groups_parentId_groupName ON book_groups (parentId, groupName)')
  console.log(`  [${label}] 唯一索引已建；本次改名 ${renamed} 行`)
}

console.log('=== 场景 A：当前设备库快照跑同一套迁移（应幂等、零改名）===')
const a = path.join(dir, 'novel.db')
if (fs.existsSync(a)) {
  const tmpA = path.join(dir, 'A-copy.db')
  fs.copyFileSync(a, tmpA)
  for (const suf of ['-wal', '-shm']) {
    const s = path.join(dir, 'novel.db' + suf)
    if (fs.existsSync(s)) fs.copyFileSync(s, path.join(dir, 'A-copy.db' + suf))
  }
  const db = new DatabaseSync(tmpA)
  const before = {
    books: db.prepare('SELECT COUNT(*) n FROM books').get().n,
    bm: db.prepare('SELECT COUNT(*) n FROM bookmarks').get().n,
  }
  runMigration(db, 'A')
  const after = {
    books: db.prepare('SELECT COUNT(*) n FROM books').get().n,
    bm: db.prepare('SELECT COUNT(*) n FROM bookmarks').get().n,
    idx: db.prepare("SELECT name FROM sqlite_master WHERE type='index' AND name='index_book_groups_parentId_groupName'").all(),
    dup: db.prepare('SELECT parentId, groupName, COUNT(*) n FROM book_groups GROUP BY parentId, groupName HAVING n > 1').all(),
  }
  console.log(`  书 ${before.books}→${after.books} / 书签 ${before.bm}→${after.bm}（应相等）`)
  console.log(`  唯一索引存在: ${after.idx.length === 1} / 同父同名重复: ${after.dup.length}`)
  db.close()
  for (const suf of ['', '-wal', '-shm']) { const p = path.join(dir, 'A-copy.db' + suf); if (fs.existsSync(p)) fs.unlinkSync(p) }
}

// ── 场景 B：伪造 3.0.0 老库（无 parentId、有同名分组、有进度与书签）→ 升级 ────────────
console.log('\n=== 场景 B：伪造 3.0.0 老库 → 升级到当前版本 ===')
const tmpB = path.join(dir, 'B-v300.db')
if (fs.existsSync(tmpB)) fs.unlinkSync(tmpB)
const b = new DatabaseSync(tmpB)
b.exec(V300_BOOKS); b.exec(V300_GROUPS); b.exec(V300_BOOKMARKS)
b.exec("INSERT INTO books (id, bookName, author, bookUrl, bookGroup, durChapterIndex, durChapterPos, durChapterTitle, durChapterTime, bookType) VALUES (1,'老书甲','作者甲','/a.txt',5,12,345,'第三章',1700000000,0)")
b.exec("INSERT INTO books (id, bookName, author, bookUrl, bookGroup, durChapterIndex, durChapterPos, durChapterTitle, durChapterTime, bookType) VALUES (2,'老书乙','作者乙','/b.txt',6,7,88,'第二章',1700000001,1)")
b.exec("INSERT INTO bookmarks (time, bookName, bookAuthor, chapterIndex, chapterPos, chapterName, bookText, content) VALUES (1700000100,'老书甲','作者甲',12,100,'第三章','原文','备注')")
// 3.0.0 按分类页签分开判重 ⇒ 两个不同页签可以有同名分组
b.exec("INSERT INTO book_groups (groupId, groupName, sort, groupType, isSystem) VALUES (5,'我的分组',1,0,0)")
b.exec("INSERT INTO book_groups (groupId, groupName, sort, groupType, isSystem) VALUES (6,'我的分组',1,1,0)")
b.exec("INSERT INTO book_groups (groupId, groupName, sort, groupType, isSystem) VALUES (7,'唯一分组',1,0,0)")
console.log(`  造好老库：books=2 / bookmarks=1 / book_groups=3（其中 2 个同名「我的分组」，分属不同页签）`)
// 当前版本 doInitAllTable：CREATE TABLE IF NOT EXISTS（列相同 → 不动）→ 补 parentId → migrateBookTypeToShelf → 建索引
b.exec(V300_BOOKS); b.exec(V300_GROUPS); b.exec(V300_BOOKMARKS)
// migrateBookTypeToShelf：bookType/groupType → 0（这次两个同名分组会落到同一父级）
b.exec('UPDATE books SET bookType = 0 WHERE bookType = 1 OR bookType = 2')
b.exec('UPDATE book_groups SET groupType = 0 WHERE groupType = 1 OR groupType = 2')
runMigration(b, 'B')
console.log('  迁移后：')
console.log('   books:', JSON.stringify(b.prepare('SELECT bookName, durChapterIndex, durChapterPos, durChapterTitle, bookGroup FROM books ORDER BY id').all()))
console.log('   bookmarks:', JSON.stringify(b.prepare('SELECT bookName, chapterIndex, chapterPos, content FROM bookmarks').all()))
console.log('   book_groups:', JSON.stringify(b.prepare('SELECT groupId, groupName, parentId FROM book_groups ORDER BY groupId').all()))
console.log('   唯一索引存在:', b.prepare("SELECT name FROM sqlite_master WHERE type='index' AND name='index_book_groups_parentId_groupName'").all().length === 1)
b.close()
fs.unlinkSync(tmpB)
