// P2 批次 1：删除「只写不读」的 AppStorage 死键写入（逐个断言，自下而上删）
// 判据：全仓代码命中数 = 1（只有写入处），且没有任何 AppStorage.get/@StorageProp/@StorageLink 读取。
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..')
const ETS = path.join(ROOT, 'entry/src/main/ets')
const dry = process.argv.includes('--dry-run')

/** 每项：[文件, 起始行, 结束行, 必须包含的子串, 说明]（1-based 闭区间） */
const DEL = [
  ['pages/view/Reader/ReaderPage3.ets', 5546, 5546, "isDensityChange", 'isDensityChange 死键写入'],
  ['pages/view/Reader/ReaderPageNoAnim.ets', 1204, 1210, 'NOANIM_SWIPE_AT', 'NOANIM_SWIPE_AT 两个手势打点（已无读取方）'],
  ['pages/Index.ets', 2778, 2778, 'ltArmReleasedAt', 'ltArmReleasedAt 死键写入'],
  ['componets/group/GroupType.ets', 691, 695, 'shelfGroupRowBottom', 'shelfGroupRowBottom 死键写入（三横弹窗已不读）'],
  ['entryability/EntryAbility.ets', 626, 629, 'avoidHeight', 'avoidHeight 死键（navi/total 仅服务它）'],
  ['entryability/EntryAbility.ets', 509, 511, 'pathDir', 'pathDir 死键写入'],
  ['entryability/WindowAbility.ets', 62, 65, 'navigationAiBarHeight', 'navigationAiBarHeight 死键写入'],
  ['entryability/WindowAbility.ets', 49, 52, 'statusBarHeight', 'statusBarHeight 死键写入'],
  ['entryability/WindowAbility.ets', 43, 44, 'statusBarHeight', '两个避让高度默认值（无读取方）'],
  ['storage/findData.ets', 4, 4, 'HAS_EXPLORE_URL', 'HAS_EXPLORE_URL 死键写入'],
  ['common/constants/CommonConstants.ets', 236, 236, 'HAS_EXPLORE_URL', 'HAS_EXPLORE_URL 常量'],
]

const byFile = new Map()
for (const item of DEL) {
  if (!byFile.has(item[0])) byFile.set(item[0], [])
  byFile.get(item[0]).push(item)
}

let total = 0
for (const [rel, items] of byFile) {
  const abs = path.join(ETS, rel)
  const raw = fs.readFileSync(abs, 'utf8')
  const lines = raw.split(/\r?\n/)
  // 校验
  for (const [, from, to, expect] of items) {
    const seg = lines.slice(from - 1, to).join('\n')
    if (!seg.includes(expect)) throw new Error(`${rel} L${from}-${to} 断言失败：缺「${expect}」→ 实际「${seg.slice(0, 80)}」`)
  }
  // 自下而上删
  for (const [, from, to] of items.slice().sort((a, b) => b[1] - a[1])) {
    lines.splice(from - 1, to - from + 1)
    total += to - from + 1
  }
  if (lines.length < 5) throw new Error(`${rel} 删除后行数异常：${lines.length}`)
  if (!dry) fs.writeFileSync(abs, lines.join('\n'), 'utf8')
  console.log(`  ✓ ${rel}：删 ${items.length} 段 → ${lines.length} 行`)
}
console.log(`${dry ? '[dry-run] ' : ''}共删除 ${total} 行`)
