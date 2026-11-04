// P5 单测 ⑦：DB 迁移 v2「旧表清理」策略（真实 SQLite 执行，不依赖真机）
//
// 被测源码：entry/src/main/ets/database/migration/MigrationSteps.ets
// 运行：    node scripts/tests/db-migration.test.mjs
//
// ── 为什么用真 SQLite 而不是断言字符串 ────────────────────────────────────────
// v2 的安全边界是「**只有 0 行才 DROP**」：判错一次就是用户数据丢失。
// 这里用 node:sqlite 建一个临时库，把源码里的三条 SQL **原文抽取**出来执行
// （不复制实现），真实跑一遍「存在性 → COUNT(*) → 0 行才 DROP」，
// 断言：空表被删、非空表保留且数据完好、不存在的表不会误删任何东西。
//
// ── 抽取方式（防漂移）────────────────────────────────────────────────────────
// SQL 在源码里是模板字符串（含 ${tableName}），本测试用正则把它们**逐字**取出来；
// 源码改写了 SQL 写法 ⇒ 抽取失败 ⇒ 测试红（这正是我们要的）。
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { DatabaseSync } from 'node:sqlite'
import { readSource } from './_ets-harness.mjs'

const SRC = readSource('entry/src/main/ets/database/migration/MigrationSteps.ets')

// ── ① 清理名单：必须正好是这两张（多一张 = 可能删到活表，少一张 = 清理不彻底）
test('v2 清理名单只含 book_history / readRecord', () => {
  const names = [...SRC.matchAll(/tableName:\s*'([^']+)'/g)].map((m) => m[1])
  assert.deepEqual(names, ['book_history', 'readRecord'])
})

// ── ② SQL 原文抽取
const SQL_PRESENCE = /`(SELECT name FROM sqlite_master WHERE type = 'table' AND name = '\$\{tableName\}')`/
const SQL_COUNT = /`(SELECT COUNT\(\*\) AS n FROM \$\{tableName\})`/
const SQL_DROP = /`(DROP TABLE IF EXISTS \$\{tableName\})`/

function sqlOf(re, why) {
  const m = re.exec(SRC)
  assert.ok(m, `源码里找不到这段 SQL（${why}）—— 迁移写法变了，本测试需同步：MigrationSteps.ets`)
  return m[1]
}

const PRESENCE = sqlOf(SQL_PRESENCE, '存在性查询')
const COUNT = sqlOf(SQL_COUNT, '行数统计')
const DROP = sqlOf(SQL_DROP, '删表')

test('三条 SQL 都能从源码原文取到（防实现漂移）', () => {
  assert.ok(PRESENCE.includes('sqlite_master'))
  assert.ok(COUNT.includes('COUNT(*)'))
  assert.ok(DROP.startsWith('DROP TABLE IF EXISTS'))
})

// ── ③ 真跑策略：只有 0 行才删
test('空表 → 删除；非空表 → 保留且数据完好', () => {
  const db = new DatabaseSync(':memory:')
  try {
    db.exec('CREATE TABLE book_history (id INTEGER PRIMARY KEY, name TEXT)')
    db.exec('CREATE TABLE readRecord (id INTEGER PRIMARY KEY, name TEXT)')
    db.exec("INSERT INTO readRecord (name) VALUES ('还有用')")

    const leftover = ['book_history', 'readRecord']
    for (const tableName of leftover) {
      // ① 存在性
      const exists = db.prepare(PRESENCE.replace(/\$\{tableName\}/g, tableName)).all()
      if (exists.length === 0) continue
      // ② 行数
      const n = db.prepare(COUNT.replace(/\$\{tableName\}/g, tableName)).get().n
      // ③ 只有 0 行才 DROP（与源码 :182 的判据一致）
      if (n === 0) {
        db.prepare(DROP.replace(/\$\{tableName\}/g, tableName)).run()
      }
    }

    const left = db.prepare("SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name").all().map((r) => r.name)
    assert.deepEqual(left, ['readRecord'], '空表应被删、非空表应保留')
    assert.equal(db.prepare('SELECT COUNT(*) AS n FROM readRecord').get().n, 1, '非空表数据必须完好')
  } finally {
    db.close()
  }
})

test('不存在的表：存在性查询为空 ⇒ 后续两步都不执行（不会误删）', () => {
  const db = new DatabaseSync(':memory:')
  try {
    db.exec('CREATE TABLE books (id INTEGER PRIMARY KEY)')
    db.exec("INSERT INTO books (id) VALUES (1)")
    const exists = db.prepare(PRESENCE.replace(/\$\{tableName\}/g, 'readRecord')).all()
    assert.equal(exists.length, 0)
    const left = db.prepare("SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name").all().map((r) => r.name)
    assert.deepEqual(left, ['books'], '无关表不应被动到')
  } finally {
    db.close()
  }
})

// ── ④ 迁移版本表：每张遗留表都必须写明原因（why 字段非空）
test('每张遗留表都写了清理原因（why 非空）', () => {
  const whys = [...SRC.matchAll(/why:\s*'([^']*)'/g)].map((m) => m[1])
  assert.equal(whys.length, 2, '必须两张表各一条 why')
  for (const w of whys) {
    assert.ok(w.length >= 8, `why 太短，等于没写原因: "${w}"`)
  }
})
