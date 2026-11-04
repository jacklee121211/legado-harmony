// P5 纯函数单测 ⑥：common/books/BookNaming.ets —— 书名胜任消歧（`书名 (2)` 顺延）
//
// 被测源码：entry/src/main/ets/common/books/BookNaming.ets
// 运行：    node scripts/tests/book-naming.test.mjs
//
// ── 方式：执行真源码（不是算法复刻）────────────────────────────────────────────
// `BookNaming` 零 import、纯静态方法 ⇒ 用 harness 的 `loadEtsModule` 直接跑真类体。
//
// ── 判据（用户 2026-11-04 拍板 + 分组样板）────────────────────────────────────
//   1. 同名即冲突；`author` 恒为 `'暂无'`，书名为文件名 ⇒ 只比书名
//   2. 后缀格式 `原名 (n)`，n 从 2 起，与 `GroupMutation.renameAndMove()`（:138-148）一致
//   3. 上限 99；用尽时**退回原名**（分组也是这个行为，宁可重名不造 `(100)`）
//   4. 大小写敏感（与 SQLite `=` 的语义一致）
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { loadEtsModule } from './_ets-harness.mjs'

const SRC = 'entry/src/main/ets/common/books/BookNaming.ets'
const mod = loadEtsModule(SRC)
const { BookNaming } = mod.exports

test('无冲突：直接返回原名（并 trim 两端空白）', () => {
  assert.equal(BookNaming.nextFreeName('恶汉.txt', []), '恶汉.txt')
  assert.equal(BookNaming.nextFreeName('  恶汉.txt  ', []), '恶汉.txt')
  assert.equal(BookNaming.nextFreeName('恶汉.txt', ['别的书.txt']), '恶汉.txt')
})

test('一次冲突：得到「书名 (2)」（与分组后缀格式一致）', () => {
  assert.equal(BookNaming.nextFreeName('恶汉.txt', ['恶汉.txt']), '恶汉.txt (2)')
})

test('连续冲突：顺延到第一个空闲后缀', () => {
  const taken = ['恶汉.txt', '恶汉.txt (2)', '恶汉.txt (3)']
  assert.equal(BookNaming.nextFreeName('恶汉.txt', taken), '恶汉.txt (4)')
})

test('中间有空缺：优先用空缺位（不跳到末尾）', () => {
  const taken = ['恶汉.txt', '恶汉.txt (3)']
  assert.equal(BookNaming.nextFreeName('恶汉.txt', taken), '恶汉.txt (2)')
})

test('大小写敏感：与 SQLite "=" 语义一致', () => {
  assert.equal(BookNaming.nextFreeName('ABC.txt', ['abc.txt']), 'ABC.txt')
})

test('上限 99：99 被占用时退回原名（不造 (100)）', () => {
  const taken = ['书']
  for (let n = 2; n <= 99; n++) {
    taken.push('书 (' + n + ')')
  }
  assert.equal(BookNaming.nextFreeName('书', taken), '书')
})

test('空名：原样返回空串（调用方负责拦截，本函数不抛）', () => {
  assert.equal(BookNaming.nextFreeName('', ['x']), '')
  assert.equal(BookNaming.nextFreeName('   ', ['x']), '')
})

test('漂移防护：后缀格式与上限的字面值被钉住', () => {
  // 与 GroupMutation.renameAndMove 的 `' (' + n + ')'` 和 `n <= 99` 必须一致
  assert.equal(BookNaming.MAX_SUFFIX, 99)
  assert.equal(BookNaming.nextFreeName('书', ['书']), '书 (2)')
})
