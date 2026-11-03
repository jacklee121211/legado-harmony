// 真机 dumpLayout 节点定位小工具（2026-11-04 新增）。
//
// 为什么需要它：`uitest dumpLayout` 出来的 JSON 里，很多可点元素**没有 text**（图标是
// SymbolGlyph / Image），靠眼睛翻 JSON 找坐标既慢又容易点空。这个脚本把"按文本找中心点"
// 与"按区域列可点节点"两件事固定下来，验证批次可复现。
//
// 用法：
//   node scripts/device-locate.mjs <dump.json> --text=三横
//   node scripts/device-locate.mjs <dump.json> --region=700,120,1320,400
//   node scripts/device-locate.mjs <dump.json> --text=显示设置 --json
//
// 输出：
//   --text 命中 → `x y [bounds]` 一行（可直接喂 `uitest uiInput click x y`）
//   --region   → 该区域内所有带 bounds 的节点（一行一个，含 type/text/id）
//   未命中 → `NOTFOUND`，退出码 1
import fs from 'node:fs'

const args = process.argv.slice(2)
const file = args.find((a) => !a.startsWith('--'))
if (!file) {
  console.error('用法: node scripts/device-locate.mjs <dump.json> --text=xxx | --region=x1,y1,x2,y2')
  process.exit(2)
}
const textArg = (args.find((a) => a.startsWith('--text=')) ?? '').slice('--text='.length)
const regionArg = (args.find((a) => a.startsWith('--region=')) ?? '').slice('--region='.length)
const asJson = args.includes('--json')

const json = JSON.parse(fs.readFileSync(file, 'utf8'))
const nodes = []
;(function walk(n) {
  const a = n.attributes ?? {}
  if (a.bounds) {
    const m = [...String(a.bounds).matchAll(/\d+/g)].map((x) => +x[0])
    if (m.length >= 4) {
      nodes.push({
        type: a.type ?? '',
        text: a.text ?? '',
        id: a.id ?? '',
        x1: m[0],
        y1: m[1],
        x2: m[2],
        y2: m[3],
        cx: Math.round((m[0] + m[2]) / 2),
        cy: Math.round((m[1] + m[3]) / 2),
      })
    }
  }
  for (const c of n.children ?? []) walk(c)
})(json)

if (textArg) {
  const hit = nodes.find((n) => n.text === textArg)
  if (!hit) {
    console.log('NOTFOUND')
    process.exit(1)
  }
  if (asJson) {
    console.log(JSON.stringify(hit))
  } else {
    console.log(`${hit.cx} ${hit.cy} [${hit.x1},${hit.y1}][${hit.x2},${hit.y2}]`)
  }
  process.exit(0)
}

if (regionArg) {
  const [x1, y1, x2, y2] = regionArg.split(',').map(Number)
  const inRegion = nodes.filter((n) => n.x1 >= x1 && n.y1 >= y1 && n.x2 <= x2 && n.y2 <= y2)
  if (asJson) {
    console.log(JSON.stringify(inRegion))
  } else {
    for (const n of inRegion) {
      console.log(`${n.type} [${n.x1},${n.y1}][${n.x2},${n.y2}] text=${n.text} id=${n.id}`)
    }
  }
  process.exit(inRegion.length ? 0 : 1)
}

console.error('需要 --text=xxx 或 --region=x1,y1,x2,y2')
process.exit(2)
