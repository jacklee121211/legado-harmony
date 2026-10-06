/**
 * offline 单测 —— 断线/未配对提示条的状态机（纯函数部分，不碰 DOM）
 * 运行：cd web && npm test
 */
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { nextState, OFFLINE_THRESHOLD } from '../src/offline.ts'

test('下一次成功立刻回到 ok，并把连续失败清零', () => {
  assert.deepEqual(nextState('ok', 0, 'ok'), { state: 'ok', failures: 0 })
  assert.deepEqual(nextState('offline', 9, 'ok'), { state: 'ok', failures: 0 })
})

test('未配对（401）优先级最高且立刻生效，不看失败计数', () => {
  assert.deepEqual(nextState('ok', 0, 'unauth'), { state: 'unauth', failures: 0 })
  assert.deepEqual(nextState('offline', 5, 'unauth'), { state: 'unauth', failures: 0 })
})

test('网络失败要连续到阈值才判 offline（防一次抖动就弹条）', () => {
  let s = 'ok' as 'ok' | 'offline' | 'unauth'
  let f = 0
  for (let i = 1; i < OFFLINE_THRESHOLD; i++) {
    const r = nextState(s, f, 'offline')
    s = r.state
    f = r.failures
    assert.equal(s, 'ok', `第 ${i} 次失败还不该弹条`)
    assert.equal(f, i)
  }
  const last = nextState(s, f, 'offline')
  assert.equal(last.state, 'offline')
  assert.equal(last.failures, OFFLINE_THRESHOLD)
})

test('已处于 offline 时继续失败仍是 offline；中途成功会重新计数', () => {
  const r = nextState('offline', OFFLINE_THRESHOLD + 2, 'offline')
  assert.equal(r.state, 'offline')
  // 成功一次清零
  const ok = nextState('offline', r.failures, 'ok')
  assert.deepEqual(ok, { state: 'ok', failures: 0 })
  // 再失败一次：只算 1 次，不该立刻回到 offline
  assert.equal(nextState(ok.state, ok.failures, 'offline').state, 'ok')
})

test('未配对状态不被网络失败覆盖（否则用户会看到错误的"已断开"）', () => {
  let s: 'ok' | 'offline' | 'unauth' = 'unauth'
  let f = 0
  for (let i = 0; i < OFFLINE_THRESHOLD + 2; i++) {
    const r = nextState(s, f, 'offline')
    s = r.state
    f = r.failures
  }
  assert.equal(s, 'unauth')
})
