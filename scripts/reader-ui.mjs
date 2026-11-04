// 阅读器 UI 真机操作工具（2026-11-04 固化）。说明见 docs/渲染侧重构-状态卡-2026-11-04.md
//
// 用法：
//   node scripts/reader-ui.mjs dump                     取快照并列出可点文字节点
//   node scripts/reader-ui.mjs bounds <文字>             打印该节点的 bounds 与中心
//   node scripts/reader-ui.mjs tap <文字>                取快照 → 找节点 → 点其中心
//   node scripts/reader-ui.mjs diff <a.json> <b.json>    节点树结构化对比（差异数 + 前 8 条）
//
// 纪律（两条，都是踩出来的）：
//   ① 点之前先 dump —— 面板高度随内容变化，同一控件两次 dump 能差 40~60px；
//   ② 点之后要确认 —— 用 hilog（switchReadMode / readMode loaded / setConfig）或再次 dump 验证。
import { execSync } from 'node:child_process'
import fs from 'node:fs'
import path from 'node:path'
import os from 'node:os'

const HDC_T = process.env.HDC_T || '192.168.3.241:43125'
const REMOTE = '/data/local/tmp/reader_ui.json'

function hdc(cmd) {
  return execSync(`hdc -t ${HDC_T} shell "${cmd}"`, { encoding: 'utf8' })
}

export function dumpOnce(tag = 'reader_ui') {
  hdc(`uitest dumpLayout -p ${REMOTE}`)
  const local = path.join(os.tmpdir(), `${tag}.json`)
  // 用 file recv 拉回（Windows 下用 cmd 展开路径，避免 PowerShell 引用问题）
  execSync(`hdc -t ${HDC_T} file recv ${REMOTE} "${local}"`, { shell: 'cmd.exe' })
  return { json: fs.readFileSync(local, 'utf8'), file: local }
}

/** 从 dump 里抽取 {type,text,bounds,checked,backgroundColor} 节点 */
export function nodes(json) {
  const out = []
  for (const m of json.matchAll(/\{[^{}]*\}/g)) {
    const o = m[0]
    const g = (k) => {
      const r = new RegExp(`"${k}":"([^"]*)"`).exec(o)
      return r ? r[1] : ''
    }
    const bounds = g('bounds')
    if (!bounds) continue
    out.push({
      type: g('type'),
      text: g('text') || g('originalText'),
      bounds,
      checked: g('checked'),
      bg: g('backgroundColor')
    })
  }
  return out
}

/** 解析 bounds → [x1,y1,x2,y2] / 中心 */
export function parseBounds(b) {
  const m = /\[(\d+),(\d+)\]\[(\d+),(\d+)\]/.exec(b)
  if (m === null) return null
  const [x1, y1, x2, y2] = [Number(m[1]), Number(m[2]), Number(m[3]), Number(m[4])]
  return { x1, y1, x2, y2, cx: Math.round((x1 + x2) / 2), cy: Math.round((y1 + y2) / 2) }
}

function findNode(json, label) {
  const ns = nodes(json).filter((n) => n.text === label)
  if (ns.length === 0) return null
  // 多个同名时取面积最小的（通常是真正可点的那个）
  ns.sort((a, b) => {
    const pa = parseBounds(a.bounds)
    const pb = parseBounds(b.bounds)
    return (pa.x2 - pa.x1) * (pa.y2 - pa.y1) - (pb.x2 - pb.x1) * (pb.y2 - pb.y1)
  })
  return ns[0]
}

function signature(n) {
  return [n.type, n.text, n.bounds, n.checked, n.bg].join('|')
}

function countMap(arr) {
  const m = new Map()
  for (const s of arr) m.set(s, (m.get(s) ?? 0) + 1)
  return m
}

// ── CLI ──────────────────────────────────────────────────────────────────────
const [cmd, a1, a2] = process.argv.slice(2)

if (cmd === 'dump') {
  const { json, file } = dumpOnce()
  const ns = nodes(json)
  console.log(`快照：${file}（${ns.length} 个带 bounds 的节点）`)
  const clickable = ns.filter((n) => n.text.length > 0)
  for (const n of clickable.slice(0, 40)) {
    const p = parseBounds(n.bounds)
    console.log(`  「${n.text}」 ${n.type}  bounds=${n.bounds}  center=(${p.cx},${p.cy})`)
  }
} else if (cmd === 'bounds') {
  const { json } = dumpOnce()
  const n = findNode(json, a1)
  if (n === null) { console.log(`找不到节点「${a1}」`); process.exit(1) }
  const p = parseBounds(n.bounds)
  console.log(`${n.type}「${n.text}」 bounds=${n.bounds} center=(${p.cx},${p.cy}) checked=${n.checked} bg=${n.bg}`)
} else if (cmd === 'tap') {
  const { json } = dumpOnce()
  const n = findNode(json, a1)
  if (n === null) { console.log(`找不到节点「${a1}」，先跑 dump 看看当前界面`); process.exit(1) }
  const p = parseBounds(n.bounds)
  console.log(`点击「${n.text}」(${p.cx},${p.cy})  bounds=${n.bounds}`)
  hdc(`uitest uiInput click ${p.cx} ${p.cy}`)
  console.log('（提醒：点完要用 hilog 或再 dump 确认结果，不要以"没报错"为准）')
} else if (cmd === 'diff') {
  const A = nodes(fs.readFileSync(a1, 'utf8')).map(signature)
  const B = nodes(fs.readFileSync(a2, 'utf8')).map(signature)
  const ma = countMap(A)
  const mb = countMap(B)
  let diff = 0
  for (const [k, v] of ma) {
    const w = mb.get(k) ?? 0
    if (v !== w) { console.log(`  仅 A / 数量不同：${k}  ${v} vs ${w}`); diff++ }
  }
  for (const [k, v] of mb) {
    if (!ma.has(k)) { console.log(`  仅 B：${k}`); diff++ }
  }
  console.log(`节点 A=${A.length}  B=${B.length}  差异条目=${diff}`)
  process.exit(diff === 0 ? 0 : 0) // 对比工具本身不判红，交给调用方看数字
} else {
  console.log('用法：dump | bounds <文字> | tap <文字> | diff <a.json> <b.json>')
  process.exit(1)
}
