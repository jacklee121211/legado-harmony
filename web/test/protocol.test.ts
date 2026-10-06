/**
 * protocol 单测 —— v3 架构的第一个收益：**位置/同步算法第一次可本地验证**
 * 运行：cd web && npm test   （Node 22 原生跑 .ts，无需额外依赖）
 */
import { test } from 'node:test'
import assert from 'node:assert/strict'
import {
  normEx, excerptKey, clampRatio, ratioToIndex, indexToRatio,
  isNearSamePlace, hasAnchor, pickPending, parseLegacyPos, SAME_CHAPTER_RATIO_EPS
} from '../src/protocol.ts'
import type { SyncPos } from '../src/protocol.types.ts'

function pos(over: Partial<SyncPos> = {}): SyncPos {
  return {
    v: 2, seq: 10, chTitle: '第三章 夜行', chIndex: 2, chCount: 100, ratio: 0.02,
    topEx: '他说这话时', botEx: '雨还没停', posRatio: 0.5, ts: 1000, writer: 'web:w1',
    ...over
  }
}

test('normEx 去掉所有空白；excerptKey 默认取 20 字（v3 从 14 提到 20）', () => {
  assert.equal(normEx(' 他 说\n这 话\t时 '), '他说这话时')
  const long = '他'.repeat(30)
  assert.equal(excerptKey(long).length, 20)
  assert.equal(excerptKey(long, 14).length, 14)
  assert.equal(excerptKey('  短  '), '短')
})

test('clampRatio / ratioToIndex / indexToRatio 边界', () => {
  assert.equal(clampRatio(-1), 0)
  assert.equal(clampRatio(2), 1)
  assert.equal(clampRatio(NaN), 0)
  assert.equal(clampRatio('0.5'), 0.5)
  assert.equal(ratioToIndex(0, 10), 0)
  assert.equal(ratioToIndex(1, 10), 9)
  assert.equal(ratioToIndex(0.5, 11), 5)
  assert.equal(ratioToIndex(0.5, 0), 0)
  assert.equal(indexToRatio(0, 10), 0)
  assert.equal(indexToRatio(9, 10), 1)
  assert.equal(indexToRatio(0, 1), 0)
})

test('isNearSamePlace：必须同章 + 章内比例都已知 + 差值小于阈值', () => {
  assert.equal(isNearSamePlace('第三章 夜行', 0.5, pos({ posRatio: 0.5 + SAME_CHAPTER_RATIO_EPS / 2 })), true)
  assert.equal(isNearSamePlace('第三章 夜行', 0.5, pos({ posRatio: 0.9 })), false)
  assert.equal(isNearSamePlace('第四章 别的', 0.5, pos()), false)
  assert.equal(isNearSamePlace('', 0.5, pos()), false)
  assert.equal(isNearSamePlace('第三章 夜行', -1, pos()), false)
  assert.equal(isNearSamePlace('第三章 夜行', 0.5, pos({ posRatio: -1 })), false)
})

test('hasAnchor：三个锚全空视为无数据', () => {
  assert.equal(hasAnchor(pos()), true)
  assert.equal(hasAnchor(pos({ topEx: '', botEx: '', chTitle: '' })), false)
})

test('pickPending：水位决定"新不新"，取 seq 最大者（排序用 seq，不用时钟）', () => {
  const slots = { w1: pos({ seq: 3, ts: 9_999_999 }), w2: pos({ seq: 7, ts: 1000, writer: 'web:w2' }) }
  // 故意让 ts 与 seq 相反：w1 的时钟很远（甚至更晚），但 seq 更小 ⇒ 必须选 w2
  const got = pickPending(slots, {}, '别的章', 0.1, 3000)
  assert.equal(got?.id, 'w2')
  assert.equal(got?.pos.seq, 7)
})

test('pickPending R1（中继站）：最新进度不在手机 ⇒ 电脑不弹（"谁最新谁不弹"）', () => {
  const slots = { phone: pos({ seq: 9 }) }
  // latestWriter = 某台电脑 ⇒ 电脑自己就是最新 ⇒ 不弹
  assert.equal(pickPending(slots, {}, '别的章', 0.1, 3000, 'web:w1'), null)
  // latestWriter = phone ⇒ 手机是最新 ⇒ 弹
  assert.equal(pickPending(slots, {}, '别的章', 0.1, 3000, 'phone')?.id, 'phone')
  // latestWriter 未知（旧服务端）⇒ 退回只看水位
  assert.equal(pickPending(slots, {}, '别的章', 0.1, 3000, '')?.id, 'phone')
})

test('pickPending：已被水位消费的槽不再提示', () => {
  const slots = { w1: pos({ seq: 5 }) }
  assert.equal(pickPending(slots, { w1: 5 }, '别的章', 0.1, 3000), null)
  assert.equal(pickPending(slots, { w1: 4 }, '别的章', 0.1, 3000)?.id, 'w1')
})

test('pickPending：同一处（同章 + 足够近）不提示 —— R3 阈值', () => {
  const slots = { w1: pos({ chTitle: '第三章 夜行', posRatio: 0.5 }) }
  // 我就在同一章同一位置附近
  assert.equal(pickPending(slots, {}, '第三章 夜行', 0.55, 3000), null)
  // 同一章但隔得远 ⇒ 要提示
  assert.equal(pickPending(slots, {}, '第三章 夜行', 0.9, 3000)?.id, 'w1')
})

test('pickPending：时钟畸变（ts 远超现在）的坏数据被跳过；但 24h 容差下跨设备时钟偏差仍可提示', () => {
  const now = 1_000_000
  // 远超容差 ⇒ 跳过
  const bad = { w1: pos({ seq: 5, ts: now + 100 * 60 * 60 * 1000 }) }
  assert.equal(pickPending(bad, {}, '别的章', 0.1, now, '', 24 * 60 * 60 * 1000), null)
  // 手机快 30 分钟：在 24h 容差内 ⇒ 必须仍然提示（排序用 seq，与时钟无关）
  const skewed = { phone: pos({ seq: 5, ts: now + 30 * 60 * 1000 }) }
  assert.equal(pickPending(skewed, {}, '别的章', 0.1, now, 'phone', 24 * 60 * 60 * 1000)?.id, 'phone')
  // 同一份数据在旧的 5 分钟容差下会被丢掉（这正是本轮修掉的坑）
  assert.equal(pickPending(skewed, {}, '别的章', 0.1, now, 'phone', 5 * 60 * 1000), null)
})

test('pickPending：无锚的槽跳过；空槽表返回 null', () => {
  assert.equal(pickPending({ w1: pos({ topEx: '', botEx: '', chTitle: '' }) }, {}, 'x', 0.1, 3000), null)
  assert.equal(pickPending({}, {}, 'x', 0.1, 3000), null)
})

test('parseLegacyPos：v1 老键只在 src!=phone 时当网页槽；坏 JSON 返回 null', () => {
  assert.equal(parseLegacyPos(JSON.stringify({ title: 't', topEx: 'a', ts: 5, src: 'web' }))?.writer, 'web:v1')
  assert.equal(parseLegacyPos(JSON.stringify({ title: 't', topEx: 'a', ts: 5, src: 'phone' })), null)
  assert.equal(parseLegacyPos(JSON.stringify({ title: 't', ts: 0 })), null)
  assert.equal(parseLegacyPos('{oops'), null)
  assert.equal(parseLegacyPos(''), null)
})
