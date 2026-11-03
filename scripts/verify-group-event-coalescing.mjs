// 逻辑验证：`GroupEvents.emitFromBump()` 的合并语义（与 GroupEvents.ets 实现逐行对照）。
// 无真机条件下，用 Node 复刻同一套算法跑 4 个断言；算法一旦改，这里也要同步改。
//
// 对照源码：entry/src/main/ets/common/group/GroupEvents.ets
//   private static bumpPending = false
//   static emitFromBump() {
//     if (GroupEvents.bumpPending) return
//     const versionAtSchedule = GroupEvents.version
//     GroupEvents.bumpPending = true
//     Promise.resolve().then(() => {
//       GroupEvents.bumpPending = false
//       if (GroupEvents.version !== versionAtSchedule) return
//       GroupEvents.emit([], [])
//     })
//   }

class GroupEvents {
  static version = 0
  static listeners = []
  static bumpPending = false
  static emitCount = 0

  static emit(groupIds, bookIds = []) {
    GroupEvents.version++
    GroupEvents.emitCount++
    for (const fn of GroupEvents.listeners.slice(0)) fn({ version: GroupEvents.version, groupIds, bookIds })
  }

  static emitFromBump() {
    if (GroupEvents.bumpPending) return
    const versionAtSchedule = GroupEvents.version
    GroupEvents.bumpPending = true
    Promise.resolve().then(() => {
      GroupEvents.bumpPending = false
      if (GroupEvents.version !== versionAtSchedule) return
      GroupEvents.emit([], [])
    })
  }

  static reset() { GroupEvents.version = 0; GroupEvents.emitCount = 0; GroupEvents.bumpPending = false }
}

const results = []
function check(name, cond) { results.push([name, cond]); }

async function main() {
  const calls = []

  // ① 同一微任务内连 bump 三次 ⇒ 只补发 1 次事件
  GroupEvents.reset(); calls.length = 0
  GroupEvents.listeners = [() => calls.push('x')]
  GroupEvents.emitFromBump()
  GroupEvents.emitFromBump()
  GroupEvents.emitFromBump()
  await Promise.resolve(); await Promise.resolve()
  check('① 三次 bump → 只补发 1 次事件', GroupEvents.emitCount === 1 && calls.length === 1)

  // ② bump 之后立刻有精确事件（GroupMutation）⇒ 不补发
  GroupEvents.reset(); calls.length = 0
  GroupEvents.emitFromBump()
  GroupEvents.emit([7], [9])          // 精确事件先到
  await Promise.resolve(); await Promise.resolve()
  check('② 已有精确事件 → 不补发（只 1 次）', GroupEvents.emitCount === 1 && calls.length === 1)

  // ③ 跨微任务再 bump ⇒ 新的一次补发（不会因为上次 pending 永久吞掉）
  GroupEvents.reset(); calls.length = 0
  GroupEvents.emitFromBump()
  await Promise.resolve(); await Promise.resolve()
  GroupEvents.emitFromBump()
  await Promise.resolve(); await Promise.resolve()
  check('③ 跨 tick 两次 bump → 两次事件', GroupEvents.emitCount === 2)

  // ④ 补发的 payload 是"结构变更"（空 groupIds = 全量），接收方据此清选中集
  GroupEvents.reset(); calls.length = 0
  let payload = null
  GroupEvents.listeners = [(p) => { payload = p }]
  GroupEvents.emitFromBump()
  await Promise.resolve(); await Promise.resolve()
  check('④ 补发 payload 为空数组（结构变更语义）', payload !== null && payload.groupIds.length === 0 && payload.bookIds.length === 0)

  for (const [name, ok] of results) console.log(`  ${ok ? '✅' : '❌'} ${name}`)
  const failed = results.filter(([, ok]) => !ok).length
  console.log(failed === 0 ? '✅ 全部通过（4/4）' : `❌ 失败 ${failed} 项`)
  process.exit(failed === 0 ? 0 : 1)
}

main()
