/**
 * paging 单测 —— 钉住 B3「翻页回跳」与 B2「切模式丢位置」这两类回归
 * 核心不变量：**位置锚是段落下标**；布局变化只改变"段→页"的映射，不改变段本身。
 */
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { buildPageMap, pageOfPara, firstParaOfPage, snapPage, emptyPageMap } from '../src/paging.ts'

test('buildPageMap：按 stride 切页，firstPara 单调不减', () => {
  // 每页 2 段：横向坐标 0,0,100,100,200,200
  const lefts = [0, 0, 100, 100, 200, 200]
  const m = buildPageMap(lefts, 100, lefts.length)
  assert.equal(m.pageCount, 3)
  assert.deepEqual(m.firstPara, [0, 2, 4])
  for (let i = 1; i < m.firstPara.length; i++) assert.ok(m.firstPara[i]! >= m.firstPara[i - 1]!)
})

test('pageOfPara / firstParaOfPage 往返一致（含边界与越界）', () => {
  const lefts = [0, 0, 100, 100, 200, 200]
  const m = buildPageMap(lefts, 100, lefts.length)
  assert.equal(pageOfPara(m, 0), 0)
  assert.equal(pageOfPara(m, 1), 0)
  assert.equal(pageOfPara(m, 2), 1)
  assert.equal(pageOfPara(m, 5), 2)
  assert.equal(pageOfPara(m, 999), 2)
  assert.equal(pageOfPara(m, -5), 0)
  assert.equal(firstParaOfPage(m, 1), 2)
  assert.equal(firstParaOfPage(m, 99), 4)
  assert.equal(firstParaOfPage(m, -1), 0)
})

test('B3 回归：布局变化后，同一个段落下标仍指向同一段（只是页号变了）', () => {
  const para = 5
  // 同一份内容、两种布局（每页 3 段 / 每页 2 段）⇒ 段 5 所在"页"不同，但"所在段"不变
  const wide = buildPageMap([0, 0, 0, 100, 100, 100, 200], 100, 7)   // firstPara = [0,3,6]
  const narrow = buildPageMap([0, 0, 100, 100, 200, 200, 300], 100, 7) // firstPara = [0,2,4,6]
  assert.equal(pageOfPara(wide, para), 1)
  assert.equal(firstParaOfPage(wide, pageOfPara(wide, para)), 3)
  assert.equal(pageOfPara(narrow, para), 2)
  assert.equal(firstParaOfPage(narrow, pageOfPara(narrow, para)), 4)
  // 关键不变量：任何布局下，段 N 都必须落在一个"首段 <= N"且"下一页首段 > N"的页里
  for (const m of [wide, narrow]) {
    const p = pageOfPara(m, para)
    const first = firstParaOfPage(m, p)
    assert.ok(first <= para)
    assert.ok(p + 1 >= m.pageCount || firstParaOfPage(m, p + 1) > para)
  }
})

test('未布局（stride<=0）或空书：安全退化为单页，绝不返回 NaN/越界', () => {
  assert.deepEqual(emptyPageMap(), { pageCount: 1, stride: 0, firstPara: [0] })
  const m = buildPageMap([], 0, 0)
  assert.equal(m.pageCount, 1)
  assert.equal(pageOfPara(m, 0), 0)
  const m2 = buildPageMap([0, 0, 0], 0, 3)
  assert.equal(m2.pageCount, 1)
  const m3 = buildPageMap([Number.NaN, 50, Number.POSITIVE_INFINITY], 50, 3)
  assert.ok(m3.pageCount >= 1)
  assert.ok(m3.firstPara.every((v) => Number.isFinite(v)))
})

test('snapPage：双页模式吸附偶数页', () => {
  assert.equal(snapPage(0, true), 0)
  assert.equal(snapPage(1, true), 0)
  assert.equal(snapPage(2, true), 2)
  assert.equal(snapPage(3, true), 2)
  assert.equal(snapPage(3, false), 3)
  assert.equal(snapPage(-1, true), 0)
})
