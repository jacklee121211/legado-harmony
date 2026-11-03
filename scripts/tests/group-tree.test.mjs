// ─────────────────────────────────────────────────────────────────────────────
// P5 纯函数单测 ①：common/group/GroupTree.ets
//
// 被测源码：entry/src/main/ets/common/group/GroupTree.ets（275 行，全纯函数）
// 运行：    node scripts/tests/group-tree.test.mjs      （全通过 exit 0，任一失败 exit 1）
//
// ── 方式：源码文本提取 + 类型剥离 + 沙箱执行**真源码**（不是算法复刻）──────────
// 理由：
//   ① 复刻 = 仓库里第二份实现，源码改了测试不会红（任务书点名的风险）；
//   ② 本类是 2026-11-01 多级分组的**唯一树真源**（`GroupStore._tree`），改它必须让测试红；
//   ③ 用 Node 官方 `node:module.stripTypeScriptTypes()` 擦类型后，类的**原始方法体**可原样执行
//      （实测本机 node v22.23.2 支持；取证见 `_ets-harness.mjs` 文件头）。
//
// ── 漂移防护 ─────────────────────────────────────────────────────────────────
//   L1 执行真源码 ⇒ 语义一改断言立刻红；
//   L2 下面的 `sentinel` 断言逐条钉住关键分支的**原文签名**，并打印真实行号
//      ⇒ 提取管线若把某方法吞掉，会以「签名丢失」失败而不是静默跳过（防假绿）；
//   L3 `loadEtsModule` 要求注入**每一个** import 绑定，并在此处断言"依赖集合 = 1 条"
//      ⇒ 源码新增依赖时本测试立刻报错。
//
// `BookGroups` 在源码里**只做类型注解**（:32/:34/:37-54/:69/:80…），类型剥离后运行期不再需要；
// 但 harness 做严格注入校验，所以注入一个空壳类（GroupTree 从不 new 它，只读
// groupId / groupName / parentId 三个字段），测试数据用普通对象字面量。
// ─────────────────────────────────────────────────────────────────────────────
import { loadEtsModule, createRunner } from './_ets-harness.mjs'

const SRC = 'entry/src/main/ets/common/group/GroupTree.ets'
class BookGroupsStub {}
const mod = loadEtsModule(SRC, { bindings: { BookGroups: BookGroupsStub } })
const { GroupTree, MAX_GROUP_DEPTH } = mod.exports
const t = createRunner('GroupTree 建树 / 深度 / 防环 / hasSiblingNamed', { source: mod.source })

/** 造一个分组（等价于 `BookGroups` 里被 GroupTree 读到的 3 个字段） */
function g(groupId, groupName, parentId) {
  return { groupId, groupName, parentId }
}
const ids = (list) => list.map((x) => x.groupId)
const names = (list) => list.map((x) => x.groupName)
/**
 * 判断 fn 是否抛「栈溢出」。
 * ⚠️ 不能写 `e instanceof RangeError`：异常是在 vm 沙箱**另一个 realm** 里构造的，
 * 它的原型是沙箱内的 RangeError ⇒ 跨 realm `instanceof` 恒为 false。按 name/消息判定。
 */
function throwsStackOverflow(fn) {
  try {
    fn()
    return false
  } catch (e) {
    return (e && e.name === 'RangeError') || /Maximum call stack/i.test(String(e && e.message))
  }
}
/** 造一条 n 层链：idBase 为根，返回 [根…叶] */
function chain(n, idBase) {
  const out = []
  for (let i = 0; i < n; i++) {
    out.push(g(idBase + i, `L${i + 1}`, i === 0 ? 0 : idBase + i - 1))
  }
  return out
}

// ═══ 0. 漂移哨兵 + 依赖集合 ══════════════════════════════════════════════════
t.group('0. 漂移哨兵（提取管线/源码依赖）')
t.sentinel('构造函数仍按 parentId 建 childrenMap', /const pid: number = this\.parentKey\(g\)/,
  '守 GroupTree.ets:47 —— 建树入口')
t.sentinel('childrenOf 仍剔除根级孤儿', /list\.filter\(\(g: BookGroups\): boolean => !this\.isOrphan\(g\)\)/,
  '守 GroupTree.ets:107 —— 根级过滤是"孤儿是否上提"的判定点')
t.sentinel('parentKey 仍把"父级缺失/自环"兜底成 0', /private parentKey\(g: BookGroups\): number \{/,
  '守 GroupTree.ets:80-92 —— 兜底口径')
t.sentinel('depthOf 仍带 guard 上界', /while \(cur !== undefined && guard <= MAX_GROUP_DEPTH \+ 1\)/,
  '守 GroupTree.ets:126 —— 深度循环的防环保险')
t.sentinel('hasSiblingNamed 仍对两侧 trim 后严格比较', /if \(\(g\.groupName \?\? ''\)\.trim\(\) === target\) \{/,
  '守 GroupTree.ets:269 —— 重名口径（大小写/空格）')
t.check('源码依赖集合未漂移（仍只有 BookGroups 一条 import）',
  mod.imports.length === 1 && mod.imports[0].module === '../../database/entities/BookGroups',
  '证据：GroupTree.ets:14；多余依赖会让 harness 抛「未注入绑定」')
t.eq('MAX_GROUP_DEPTH 仍为 10', MAX_GROUP_DEPTH, 10, '证据：GroupTree.ets:17')

// ═══ 1. 建树：父子挂载 / 根级 ═══════════════════════════════════════════════
t.group('1. 建树：父子挂载与根级')
const normal = GroupTree.build([
  g(1, '文学', 0), g(2, '小说', 1), g(3, '科幻', 2), g(4, '历史', 0),
])
t.eq('roots() 只吐根级，且保持传入顺序', ids(normal.roots()), [1, 4],
  '证据：GroupTree.ets:43-54（childrenMap 按传入顺序 push）+ :113-115')
t.eq('childrenOf(1) = 直接子级（不含孙级）', ids(normal.childrenOf(1)), [2], '证据：GroupTree.ets:102-110')
t.eq('childrenOf(2) = 孙级', ids(normal.childrenOf(2)), [3], '证据：GroupTree.ets:102-110')
t.eq('childrenOf(叶) = 空数组', ids(normal.childrenOf(3)), [], '证据：GroupTree.ets:103')
t.eq('childrenOf(0) 与 roots() 等价', ids(normal.childrenOf(0)), ids(normal.roots()), '证据：GroupTree.ets:113-115')
t.eq('childrenOf(负数) 归一成根级', ids(normal.childrenOf(-1)), [1, 4], '证据：GroupTree.ets:103 `parentId > 0 ? parentId : 0`')
t.eq('childrenOf(不存在的父级) = 空数组', ids(normal.childrenOf(999)), [], '证据：GroupTree.ets:103 `?? []`')
t.check('get(2) 与 childrenOf(1)[0] 是同一对象引用（不做拷贝）',
  normal.get(2) === normal.childrenOf(1)[0], '证据：GroupTree.ets:41/52（同一个 g 同时塞进 byId 与 childrenMap）+ :98')
t.eq('get(undefined) = undefined', normal.get(undefined), undefined, '证据：GroupTree.ets:95-97')
t.eq('get(999) = undefined', normal.get(999), undefined, '证据：GroupTree.ets:98')
t.eq('parentId 缺省（undefined）当根级', ids(GroupTree.build([{ groupId: 7, groupName: '无父字段' }]).roots()), [7],
  '证据：GroupTree.ets:81 `g.parentId ?? 0` + :82-84')
t.eq('parentId 为负数当根级', ids(GroupTree.build([g(8, '负父', -5)]).roots()), [8], '证据：GroupTree.ets:82-83 `pid <= 0 → 0`')

// ═══ 2. 深度 ═════════════════════════════════════════════════════════════════
t.group('2. 深度')
t.eq('depthOf 根级 = 1', normal.depthOf(1), 1, '证据：GroupTree.ets:122 `let depth = 1` + :128-130')
t.eq('depthOf 子级 = 2', normal.depthOf(2), 2, '证据：GroupTree.ets:131-132')
t.eq('depthOf 孙级 = 3', normal.depthOf(3), 3, '证据：GroupTree.ets:126-134')
t.eq('depthOf(undefined) = 0', normal.depthOf(undefined), 0, '证据：GroupTree.ets:119-121')
t.eq('depthOf(0) = 0', normal.depthOf(0), 0, '证据：GroupTree.ets:119-121')
t.eq('depthOf(负数) = 0', normal.depthOf(-3), 0, '证据：GroupTree.ets:119-121')
// ⚠️ 语义可疑点（已在报告登记，未改源码）：:117 注释写「找不到返回 0」，
//    但 byId 取不到时 while 体一次都不进 ⇒ 直接 return depth = 1。
t.eq('depthOf(不存在的 id) = 1（与 :117 注释「找不到返回 0」不符）', normal.depthOf(999), 1,
  '证据：GroupTree.ets:122-135（cur=undefined ⇒ 跳过循环 ⇒ 返回初始 depth=1）；注释在 :117')

// ═══ 3. 路径 / 子树 ══════════════════════════════════════════════════════════
t.group('3. 路径与子树')
t.eq('pathNames(3) = 根→自身', names(normal.pathOf(3)), ['文学', '小说', '科幻'], '证据：GroupTree.ets:139-161')
t.eq('pathNames(1) = 只有自己', names(normal.pathOf(1)), ['文学'], '证据：GroupTree.ets:146-154')
t.eq('pathNames(0) = 空数组', names(normal.pathOf(0)), [], '证据：GroupTree.ets:141-143')
t.eq('pathNames(undefined) = 空数组', names(normal.pathOf(undefined)), [], '证据：GroupTree.ets:141-143')
t.eq('descendantIds(1) 深度优先 = [2,3]', normal.descendantIds(1), [2, 3], '证据：GroupTree.ets:185-197')
t.eq('descendantIds(叶) = []', normal.descendantIds(3), [], '证据：GroupTree.ets:185-197')
t.eq('subtreeIds(1) = 自身 + 子孙', normal.subtreeIds(1), [1, 2, 3], '证据：GroupTree.ets:200-206')
t.eq('subtreeHeight(1) = 3', normal.subtreeHeight(1), 3, '证据：GroupTree.ets:209-220')
t.eq('subtreeHeight(叶) = 1', normal.subtreeHeight(3), 1, '证据：GroupTree.ets:210 `let h = 1`')
t.eq('isDescendantOf(3,1) = true', normal.isDescendantOf(3, 1), true, '证据：GroupTree.ets:164-182')
t.eq('isDescendantOf(1,3) = false（反向）', normal.isDescendantOf(1, 3), false, '证据：GroupTree.ets:171-173（走到根就 false）')
t.eq('isDescendantOf(1,1) = false（不含自身）', normal.isDescendantOf(1, 1), false, '证据：GroupTree.ets:165-167')

// ═══ 4. 防环：自环脏数据 ════════════════════════════════════════════════════
t.group('4. 防环：自环（parentId === groupId）')
const selfLoop = g(201, '自环', 201)
const tSelf = GroupTree.build([selfLoop, g(1, '文学', 0)])
t.eq('自环被 parentKey 兜底成根级 ⇒ childrenMap[0]', ids(tSelf.childrenOf(201)), [], '证据：GroupTree.ets:88-90（`pid === groupId → 0`）')
t.eq('自环 isOrphan = true', tSelf.isOrphan(selfLoop), true, '证据：GroupTree.ets:74-76')
t.eq('自环**不出现在 roots()**（被根级孤儿过滤剔除）', ids(tSelf.roots()), [1], '证据：GroupTree.ets:106-108 + :74-76')
t.eq('自环 depthOf 有界 = 1（不死循环）', tSelf.depthOf(201), 1, '证据：GroupTree.ets:88-90 + :126-134')

// ═══ 5. 防环：互指环脏数据 ══════════════════════════════════════════════════
t.group('5. 防环：互指环（A.parent=B，B.parent=A）')
const cycA = g(101, 'A', 102)
const cycB = g(102, 'B', 101)
const tCycle = GroupTree.build([cycA, cycB, g(1, '文学', 0)])
t.eq('互指环 depthOf(A) 终止且被 guard 截断 = MAX+3', tCycle.depthOf(101), MAX_GROUP_DEPTH + 3,
  '证据：GroupTree.ets:124-135（`guard <= MAX_GROUP_DEPTH + 1` ⇒ 12 次循环 ⇒ depth = 1+12）')
t.eq('互指环 depthOf(B) 同样有界', tCycle.depthOf(102), MAX_GROUP_DEPTH + 3, '证据：GroupTree.ets:124-135')
t.eq('互指环 pathOf 也有界（不会挂死）', tCycle.pathOf(101).length, 12, '证据：GroupTree.ets:145-154')
t.eq('互指环**不在 roots() 里**', ids(tCycle.roots()), [1], '证据：GroupTree.ets:43-54（两者互相挂在对方 childrenMap 下）+ :102-110')
t.eq('互指环 isOrphan(A) = **false**（父级确实存在）', tCycle.isOrphan(cycA), false,
  '证据：GroupTree.ets:77 `!this.byId.has(pid)` —— 父级存在 ⇒ 不算孤儿')
t.check('已知缺陷：descendantIds 在互指环上栈溢出（无 guard 递归）',
  throwsStackOverflow(() => tCycle.descendantIds(101)),
  '证据：GroupTree.ets:185-197（walk 递归调 childrenOf，全函数无 guard）— 已报告未修')
t.check('已知缺陷：subtreeIds 继承同一栈溢出（内部调 descendantIds）',
  throwsStackOverflow(() => tCycle.subtreeIds(101)),
  '证据：GroupTree.ets:200-206 → :185-197')
t.check('已知缺陷：subtreeHeight 在互指环上栈溢出（无 guard 递归）',
  throwsStackOverflow(() => tCycle.subtreeHeight(101)),
  '证据：GroupTree.ets:209-220 — 已报告未修')
const threeCycle = GroupTree.build([g(1, 'A', 3), g(2, 'B', 1), g(3, 'C', 2)])
t.eq('三节点环 depthOf 也有界 = MAX+3', threeCycle.depthOf(1), MAX_GROUP_DEPTH + 3, '证据：GroupTree.ets:124-135')
t.eq('三节点环整体不在 roots()（全环不可达）', ids(threeCycle.roots()), [], '证据：GroupTree.ets:43-54 + :102-110')

// ═══ 6. 孤儿分组 ════════════════════════════════════════════════════════════
t.group('6. 孤儿分组（父级不在列表）')
const orphan = g(301, '孤儿', 999)
const orphanParent = g(401, '孤儿父', 998)   // 父级 998 同样不在列表
const orphanChild = g(402, '孤儿孙', 401)
const tOrphan = GroupTree.build([orphan, orphanParent, orphanChild, g(1, '文学', 0)])
// ⚠️ 与任务书/`:62-63` 注释的「父组不存在时按根级处理，避免整棵树消失」**不一致**：
//    实际语义是「隐藏」而非「上提」——根级过滤器把孤儿整条剔掉了。
//    项目内 `GroupStore.keptGroups()`（GroupStore.ets:129-142）的注释也写的是「剔除孤儿分组」⇒ 实现与后者一致。
t.eq('孤儿**不上提**为根级（roots 里没有它）', ids(tOrphan.roots()), [1],
  '证据：GroupTree.ets:106-108（根级 filter 剔除孤儿）；同口径见 GroupStore.ets:129-142「剔除孤儿分组」')
t.eq('孤儿 isOrphan = true', tOrphan.isOrphan(orphan), true, '证据：GroupTree.ets:77')
t.eq('孤儿子树结构本身还在（能取到子级）', ids(tOrphan.childrenOf(401)), [402], '证据：GroupTree.ets:102-110（parentId>0 不过滤）')
t.eq('孤儿孙自身 isOrphan = false（只查直接父）', tOrphan.isOrphan(orphanChild), false,
  '证据：GroupTree.ets:69-78（只看本节点 parentId）')
t.eq('⇒ 孤儿子树整棵从 roots 不可达（父不可见则子树不可见）', ids(tOrphan.roots()).includes(401), false,
  '证据：GroupTree.ets:106-108 + :69-78；已在报告登记')

// ═══ 7. canMoveTo / canCreateChild（hasSiblingNamed 的同级校验伴侣）════════════
t.group('7. 移动/新建校验')
t.eq('canMoveTo(自身) 拒绝', normal.canMoveTo(1, 1), { ok: false, reason: '不能移动到自身' }, '证据：GroupTree.ets:230-232')
t.eq('canMoveTo(源不存在) 拒绝', normal.canMoveTo(99, 0), { ok: false, reason: '分组不存在' }, '证据：GroupTree.ets:227-229')
t.eq('canMoveTo(目标不存在) 拒绝', normal.canMoveTo(3, 99), { ok: false, reason: '目标分组不存在' }, '证据：GroupTree.ets:233-235')
t.eq('canMoveTo(自己的子孙下) 拒绝（防环）', normal.canMoveTo(1, 3), { ok: false, reason: '不能移动到自己的子目录里' },
  '证据：GroupTree.ets:236-238')
t.eq('canMoveTo(根级) 放行且 reason 为空串', normal.canMoveTo(1, 0), { ok: true, reason: '' }, '证据：GroupTree.ets:239-244')
const depthChain = GroupTree.build([...chain(10, 1000), g(11, '旁根', 0)])
t.eq('10 层链：canCreateChild(第 10 层) 拒绝', depthChain.canCreateChild(1009),
  { ok: false, reason: `最多 ${MAX_GROUP_DEPTH} 层，不能继续嵌套` }, '证据：GroupTree.ets:253-255')
t.eq('10 层链：canCreateChild(第 9 层) 放行', depthChain.canCreateChild(1008), { ok: true, reason: '' },
  '证据：GroupTree.ets:253-256')
t.eq('10 层子树移到第 1 层下 ⇒ 超 10 层，拒绝', depthChain.canMoveTo(1000, 11),
  { ok: false, reason: `最多 ${MAX_GROUP_DEPTH} 层，移动后会超出` }, '证据：GroupTree.ets:239-243')
t.eq('单层分组移到第 1 层下 ⇒ 深度 2，放行', depthChain.canMoveTo(11, 1000), { ok: true, reason: '' },
  '证据：GroupTree.ets:239-244')

// ═══ 8. hasSiblingNamed：同级同名判定 ═══════════════════════════════════════
t.group('8. hasSiblingNamed：同级同名')
const sib = GroupTree.build([
  g(1, '文学', 0), g(2, '小说', 1), g(3, '小说', 0), g(4, '  带空格  ', 1),
  g(5, 'AB', 1), g(6, '有 空格', 1), g(7, '小说 ', 0),
])
t.eq('同级同名 ⇒ true', sib.hasSiblingNamed(1, '小说'), true, '证据：GroupTree.ets:265-271')
t.eq('根级同名（3 号「小说」）⇒ true', sib.hasSiblingNamed(0, '小说'), true, '证据：GroupTree.ets:265-271')
t.eq('非同级不拦（父级 2 下没有「小说」）', sib.hasSiblingNamed(2, '小说'), false,
  '证据：GroupTree.ets:265 `this.childrenOf(parentId)`')
t.eq('待判定名两端空白被 trim 后命中', sib.hasSiblingNamed(1, '  小说  '), true, '证据：GroupTree.ets:261 `(name ?? \'\').trim()`')
t.eq('已有分组名两端空白被 trim 后命中', sib.hasSiblingNamed(0, '小说'), true,
  '证据：GroupTree.ets:269 `(g.groupName ?? \'\').trim() === target`（7 号存的是「小说 」）')
t.eq('内部空格**不**归一（只 trim 首尾）', sib.hasSiblingNamed(1, '有空格'), false,
  '证据：GroupTree.ets:261/269 —— 只用 trim，无 replace/正则压缩')
t.eq('大小写敏感（AB vs ab ⇒ false）', sib.hasSiblingNamed(1, 'ab'), false,
  '证据：GroupTree.ets:269 `===` 严格比较，全函数无 toLowerCase')
t.eq('空名 ⇒ false（不做"同名"判定）', sib.hasSiblingNamed(1, ''), false, '证据：GroupTree.ets:262-264')
t.eq('纯空白名 ⇒ false', sib.hasSiblingNamed(1, '   '), false, '证据：GroupTree.ets:261-264')
t.eq('name 为 undefined ⇒ false（`?? \'\'` 兜底）', sib.hasSiblingNamed(1, undefined), false, '证据：GroupTree.ets:261')
t.eq('excludeId 排除自身 ⇒ false', sib.hasSiblingNamed(1, '小说', 2), false, '证据：GroupTree.ets:266-268')
t.eq('excludeId 指向别的组 ⇒ 不影响命中', sib.hasSiblingNamed(1, '小说', 5), true, '证据：GroupTree.ets:266-268')
t.eq('parentId 传负数 ⇒ 按根级查（能命中根级同名）', sib.hasSiblingNamed(-1, '小说'), true,
  '证据：GroupTree.ets:102-103 `parentId > 0 ? parentId : 0`')
// ⚠️ 语义可疑点（已报告）：根级孤儿被 childrenOf(0) 剔除 ⇒ 与之重名抓不到。
const tOrphanDup = GroupTree.build([g(1, '文学', 0), g(301, '玄幻', 999)])
t.eq('已知缺陷：与"根级孤儿"同名 ⇒ false（漏判重复）', tOrphanDup.hasSiblingNamed(0, '玄幻'), false,
  '证据：GroupTree.ets:265 → :102-110（childrenOf(0) 已剔孤儿）—— 已在报告登记，未改源码')

t.done()
