// 只读审计：统计真机库当前基线（书 / 分组 / 书签 / 阅读日）
import { DatabaseSync } from 'node:sqlite'
import path from 'node:path'
import fs from 'node:fs'

const dir = process.argv[2]
if (!dir) { console.error('用法: node audit-db.mjs <db目录>'); process.exit(2) }
const dbPath = path.join(dir, 'novel.db')
const db = new DatabaseSync(dbPath, { readOnly: false })

const tables = db.prepare("SELECT name FROM sqlite_master WHERE type='table' ORDER BY name").all().map(r => r.name)
console.log('表清单:', tables.join(', '))

const q = (sql) => { try { return db.prepare(sql).all() } catch (e) { return [{ err: String(e.message) }] } }

for (const sql of [
  'SELECT COUNT(*) AS n FROM books',
  'SELECT COUNT(*) AS n FROM books WHERE isJoin = 1',
  'SELECT COUNT(*) AS n FROM book_groups',
  'SELECT COUNT(*) AS n FROM bookmarks',
  'SELECT COUNT(*) AS n FROM readDaily',
]) {
  const r = q(sql)[0]
  console.log(sql.replace('SELECT ', '').replace(' FROM ', ' @ ') + ' → ' + JSON.stringify(r))
}

console.log('分组行（id / parentId / name / isSystem / show）:')
for (const r of q('SELECT groupId, parentId, groupName, isSystem, show FROM book_groups ORDER BY groupId')) {
  console.log('  ', JSON.stringify(r))
}
console.log('书籍按分组计数:')
for (const r of q('SELECT bookGroup, COUNT(*) AS n FROM books GROUP BY bookGroup ORDER BY n DESC')) {
  console.log('  ', JSON.stringify(r))
}
db.close()
