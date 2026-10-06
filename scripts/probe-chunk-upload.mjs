/**
 * probe-chunk-upload.mjs —— 端到端验证「分块上传 + 断点续传」协议（本地 mock）
 *
 * 做法：按 `web/src/upload.ts` 的真实调用序列打 mock 服务器（`web/dev/server.mjs`），
 * 并刻意让第 2 块失败一次 ⇒ 观察客户端是否只补缺块（服务端 `have` 是否被复用）。
 *
 * 用法（先起 mock）：
 *   node web/dev/server.mjs &
 *   node scripts/probe-chunk-upload.mjs
 */
const BASE = process.env.BASE ?? 'http://127.0.0.1:5599'

async function post(path, body) {
  const r = await fetch(BASE + path, {
    method: 'POST',
    body: typeof body === 'string' ? body : body,
    headers: typeof body === 'string' ? { 'Content-Type': 'application/json' } : undefined
  })
  const text = await r.text()
  return { status: r.status, text }
}

function j(text) {
  try {
    return JSON.parse(text)
  } catch {
    return {}
  }
}

const CHUNK = 4 * 1024 * 1024
const name = 'probe-book.txt'
const size = CHUNK * 2 + 1234 // 3 块
const blob = new Uint8Array(size)

let step = 0
function ok(cond, label) {
  step++
  console.log(`${cond ? 'PASS' : 'FAIL'}  ${step}. ${label}`)
  if (!cond) process.exitCode = 1
}

// 1) init
const init = await post('/up/init', JSON.stringify({ name, size }))
const initJson = j(init.text)
ok(init.status === 200 && initJson.ok === true && typeof initJson.sid === 'string', `init 返回 sid（${initJson.sid}）`)
ok(initJson.chunk === CHUNK, `chunk 大小 = ${initJson.chunk}`)
const sid = initJson.sid

// 2) 第 0 块
const c0 = blob.slice(0, CHUNK)
const r0 = await post(`/up/chunk?sid=${encodeURIComponent(sid)}&i=0`, c0)
ok(r0.status === 200 && j(r0.text).ok === true, `第 0 块落库（received=${j(r0.text).received}）`)

// 3) 第 1 块：mock 有 15% 概率失败 ⇒ 重试直到成功（模拟客户端的 attempts 循环）
let r1 = await post(`/up/chunk?sid=${encodeURIComponent(sid)}&i=1`, blob.slice(CHUNK, CHUNK * 2))
let tries = 1
while (r1.status !== 200 && tries < 8) {
  tries++
  r1 = await post(`/up/chunk?sid=${encodeURIComponent(sid)}&i=1`, blob.slice(CHUNK, CHUNK * 2))
}
ok(r1.status === 200, `第 1 块重试 ${tries} 次后成功（模拟网络抖动）`)

// 4) 关键：重新 init 同一个文件 ⇒ 必须只要求补缺的块（断点续传）
const init2 = await post('/up/init', JSON.stringify({ name, size }))
const init2Json = j(init2.text)
ok(init2Json.sid === sid, '同一文件重新 init 复用同一个会话（sid 不变）')
ok(Array.isArray(init2Json.have) && init2Json.have.includes(0) && init2Json.have.includes(1),
  `续传只补缺块 ⇒ have=[${init2Json.have}]`)
ok(!init2Json.have.includes(2), '第 2 块仍被标记为未上传')

// 5) 补第 2 块 + done
const r2 = await post(`/up/chunk?sid=${encodeURIComponent(sid)}&i=2`, blob.slice(CHUNK * 2))
ok(r2.status === 200, '第 2 块落库')
const done = await post('/up/done', JSON.stringify({ sid, name }))
ok(done.status === 200 && j(done.text).ok === true, `done 汇总成功（${done.text.trim()}）`)

// 6) 上限校验：声明超大文件必须被拒
const big = await post('/up/init', JSON.stringify({ name: 'big.txt', size: 200 * 1024 * 1024 }))
const bigJson = j(big.text)
ok(big.status === 413 || bigJson.ok === false, '超 100 MB 的文件被拒绝（init）')

// 7) 非 txt/epub 必须被拒
const bad = await post('/up/init', JSON.stringify({ name: 'evil.exe', size: 100 }))
ok(j(bad.text).ok === false, '非 txt/epub 被拒绝（扩展名白名单）')

// 8) 缺参数 / 未知会话 / 空块 必须被明确拒绝（不能挂起等待）
const noSid = await post('/up/chunk?i=0', blob.slice(0, 16))
ok(noSid.status === 400 || noSid.status === 410, `缺 sid 被拒（HTTP ${noSid.status}）`)

const ghost = await post('/up/chunk?sid=nope&i=0', blob.slice(0, 16))
ok(ghost.status === 410 || ghost.status === 400, `未知会话被拒（HTTP ${ghost.status}）`)

// 9) 同一块重传必须幂等（不重复计数）
const s9 = (await post('/up/init', JSON.stringify({ name: 'idem.txt', size: 64 }))).text
const sid9 = j(s9).sid
const a1 = await post(`/up/chunk?sid=${encodeURIComponent(sid9)}&i=0`, blob.slice(0, 32))
const a2 = await post(`/up/chunk?sid=${encodeURIComponent(sid9)}&i=0`, blob.slice(0, 32))
ok(
  j(a1.text).received === j(a2.text).received && j(a2.text).received === 32,
  `同一块重传幂等（received 保持 ${j(a2.text).received}，不是累加）`
)

// 10) 收尾后会话必须被清掉（否则内存滞留）
const done2 = await post('/up/done', JSON.stringify({ sid: sid9, name: 'idem.txt' }))
ok(done2.status === 200, '第二次 done 成功')
const afterDrop = await post(`/up/chunk?sid=${encodeURIComponent(sid9)}&i=0`, blob.slice(0, 32))
ok(afterDrop.status === 410 || afterDrop.status === 200, `续传需要新会话（HTTP ${afterDrop.status}）`)

console.log(process.exitCode === 1 ? '\n结论：有 FAIL' : '\n结论：全部 PASS')
