// ─────────────────────────────────────────────────────────────────────────────
// scripts/tests/_ets-harness.mjs —— 纯函数单测的「真实源码加载器」+ 断言小工具
//
// ── 为什么不是「算法复刻」────────────────────────────────────────────────────
// 本项目已有 `scripts/verify-group-event-coalescing.mjs` 用「Node 里照抄一遍算法」的方式，
// 它对**不会变的**小算法够用；但这次的被测对象（GroupTree / ShelfPrefs / ShelfCollection）
// 是本轮重构的**唯一真源**，随时会被改。复刻 = 仓库里多出第二份实现：
//   · 源码改了，测试**不会红**（最大风险）；
//   · 两份实现长期必然分叉，测试反而变成"验证我抄得对不对"。
//
// ── 所以选：源码文本提取 + 类型剥离 + 沙箱执行**真源码** ───────────────────────
// 流程（全部在本进程内，无子进程、无临时文件、无 node 启动参数）：
//   ① 读 `.ets` 原文（CRLF→LF 归一，行号不变）；
//   ② 摘掉 `import` 语句，改由调用方**显式注入**同名绑定（缺一个就抛错 ⇒ 依赖漂移哨兵）；
//   ③ 摘掉 `export` / `export default` 关键字，记下导出名；
//   ④ 用 Node 官方 `node:module.stripTypeScriptTypes(code, { mode: 'transform' })`
//      擦掉 ArkTS 的类型标注 / interface / enum（`transform` 才能转 enum，`strip` 会抛）；
//   ⑤ `node:vm` 沙箱里执行这个类的**原始方法体**，把导出名返回出来。
//
// 官方声明取证（Node v22.18.0 官方文档 `doc/api/module.md`，原文）：
//   · `### module.stripTypeScriptTypes(code[, options])` — `added: v22.13.0`
//     ⇒ **需要 Node >= 22.13**（本机实测 v22.23.2 可用；CI 是 node 20，见下方 run-all 说明）
//   · 官方明确背书本用法：「It can be used to strip type annotations from TypeScript code
//     before running it with `vm.runInContext()` or `vm.compileFunction()`」
//   · 默认 `mode:'strip'`「will throw an error if the code contains TypeScript features
//     that require transformation such as `Enums`」⇒ ShelfPrefs.ets 有 3 个 enum，必须用 `transform`
//   来源：https://raw.githubusercontent.com/nodejs/node/v22.18.0/doc/api/module.md
//   ⚠️ 官方同时警告该函数输出「should not be considered stable across Node.js versions」
//     —— 本套测试断言的是**行为**，解析器输出格式变化不影响结论（若真是行为变化，测试会红）。
//
// 实测取证（本机 node v22.23.2）：
//   `node -e "const m=require('node:module'); console.log(typeof m.stripTypeScriptTypes)"`
//   → `function`；`stripTypeScriptTypes('enum A {X,Y} …', {mode:'transform'})` 正常转出 var A。
//
// ── 源码漂移防护（三层）──────────────────────────────────────────────────────
//   L1 执行的是真源码本身 ⇒ 语义一改，断言立刻红（不需要人工同步）。
//   L2 `sentinel()`：断言「关键签名原文」仍在源码里，并回报**真实行号**
//      ⇒ 一旦提取管线（import/export 正则）把函数吞掉，测试会以"签名丢失"失败，
//        而不是空跑通过（防假绿）。
//   L3 `loadEtsModule()` 严格要求注入每一个 import 绑定 ⇒ 源码新增依赖时测试立刻报
//        「未注入绑定 X」而不是静默用 undefined。
//
// ── 已知不支持（会直接抛错，不会静默降级）──────────────────────────────────
//   · 装饰器（`@Component` / `@Observed` …）：本 harness 不做 ArkUI 语境，出现即抛；
//   · 匿名 `export default class {`、`export { A, B }` 聚合导出、副作用 import；
//   · `.ets` 里 import 的模块本身是 .ets（要由调用方用本 harness 递归加载后作为绑定注入）。
// ─────────────────────────────────────────────────────────────────────────────
import fs from 'node:fs'
import path from 'node:path'
import vm from 'node:vm'
import { fileURLToPath } from 'node:url'

/** 仓库根（本文件在 <root>/scripts/tests/ 下） */
export const REPO_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..')

// `node:module` 用**命名空间导入**而不是具名导入：Node < 22.13 没有 stripTypeScriptTypes，
// 具名导入会抛 "does not provide an export named"（看不出要做什么），这里改成可读的硬失败。
const nodeModule = await import('node:module')
const stripTypeScriptTypes = nodeModule.stripTypeScriptTypes
if (typeof stripTypeScriptTypes !== 'function') {
  throw new Error(
    `[harness] 本测试需要 Node >= 22.13（依赖官方 \`node:module.stripTypeScriptTypes\` 剥离 .ets 类型），` +
    `当前 Node 是 ${process.version}。\n` +
    `  · 本地：用 Node 22+ 跑（本机实测 v22.23.2 可用）；\n` +
    `  · CI：\`.github/workflows/quality-gates.yml\` 目前写的是 node-version: "20"，需要改成 "22"（该文件不在本次改动范围）。`)
}

// stripTypeScriptTypes 每次调用都会往 stderr 打一行 ExperimentalWarning；
// 单测输出要干净（check-all 只在失败时回显子进程输出，但本地手跑会看到噪音）⇒ 精确过滤这一条。
const __origEmitWarning = process.emitWarning.bind(process)
process.emitWarning = (...args) => {
  const msg = typeof args[0] === 'string' ? args[0] : ''
  if (msg.includes('stripTypeScriptTypes')) {
    return
  }
  return __origEmitWarning(...args)
}

/** 按仓库相对路径取绝对路径 */
export function repoPath(rel) {
  return path.join(REPO_ROOT, rel.split('/').join(path.sep))
}

/** 读源码（CRLF→LF 归一；行号与编辑器一致） */
export function readSource(rel) {
  return fs.readFileSync(repoPath(rel), 'utf8').replace(/\r\n/g, '\n')
}

/**
 * sentinel：断言某段「关键签名原文」仍在源码里，返回它所在的 1-based 行号。
 * 找不到 ⇒ 抛错（测试红），并说明是"源码漂移"还是"提取管线把它吃了"。
 * @param {string} source 源码全文
 * @param {RegExp} re 必须能匹配到的原文（建议写函数签名/关键分支，别写注释）
 * @param {string} why 这条哨兵在守什么
 */
export function sentinel(source, re, why) {
  // 去掉 g/y 标志，避免多次调用共享 lastIndex；在整篇源码上匹配 ⇒ 支持跨行模式（`[\s\S]*?`）
  const copy = new RegExp(re.source, re.flags.replace(/[gy]/g, ''))
  const m = copy.exec(source)
  if (m === null) {
    throw new Error(`[sentinel] 源码里找不到 ${re} —— ${why}。\n` +
      `  若这是有意的重构：请同步改测试；若是意外：说明提取管线/源码已漂移。`)
  }
  // 命中起点换算成 1-based 行号
  return source.slice(0, m.index).split('\n').length
}

/** 断言文本必须包含某个子串（逐行找，报行号） */
export function expectLine(source, needle, why) {
  const idx = source.split('\n').findIndex((l) => l.includes(needle))
  if (idx < 0) {
    throw new Error(`[expectLine] 源码里找不到 "${needle}" —— ${why}`)
  }
  return idx + 1
}

// ── import 解析 ─────────────────────────────────────────────────────────────

const IMPORT_RE = /^import\s+(.+?)\s+from\s+['"]([^'"]+)['"]\s*;?\s*$/

function parseImportClause(clause) {
  const out = { defaultName: null, ns: null, named: [] }
  let rest = clause.trim()
  if (rest.startsWith('{')) {
    // only named
  } else if (rest.startsWith('*')) {
    const m = /^\*\s+as\s+([A-Za-z_$][\w$]*)/.exec(rest)
    if (!m) throw new Error(`[harness] 无法解析 namespace import: ${clause}`)
    out.ns = m[1]
    return out
  } else {
    const comma = rest.indexOf(',')
    if (comma < 0) {
      out.defaultName = rest
      return out
    }
    out.defaultName = rest.slice(0, comma).trim()
    rest = rest.slice(comma + 1).trim()
  }
  const brace = /^\{([\s\S]*)\}$/.exec(rest)
  if (!brace) throw new Error(`[harness] 无法解析 named import: ${clause}`)
  for (const piece of brace[1].split(',')) {
    const t = piece.trim()
    if (t === '') continue
    const asMatch = /^([A-Za-z_$][\w$]*)\s+as\s+([A-Za-z_$][\w$]*)$/.exec(t)
    if (asMatch) {
      out.named.push({ imported: asMatch[1], local: asMatch[2] })
    } else if (/^[A-Za-z_$][\w$]*$/.test(t)) {
      out.named.push({ imported: t, local: t })
    } else {
      throw new Error(`[harness] 无法解析 import 成员: ${t}`)
    }
  }
  return out
}

/**
 * 加载一个 .ets 模块并返回其导出。
 * @param {string} rel 仓库相对路径
 * @param {object} opts
 * @param {Record<string, any>} [opts.bindings] 注入给 `import` 的绑定（键名 = 源码里用的名字）
 * @param {Record<string, any>} [opts.globals] 额外的沙箱全局（如 AppStorage）
 * @returns {{ exports: Record<string, any>, source: string, imports: Array<{module:string,defaultName:string|null,named:Array<{imported:string,local:string}>,ns:string|null}> }}
 */
export function loadEtsModule(rel, opts = {}) {
  const raw = readSource(rel)
  const bindings = opts.bindings ?? {}

  const lines = raw.split('\n')
  const imports = []
  const importLines = []

  // ① 摘 import（全部必须单行；多行 import 直接报错，不猜）
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i]
    if (!/^import\s/.test(line)) {
      continue
    }
    const m = IMPORT_RE.exec(line)
    if (!m) {
      throw new Error(`[harness] ${rel}:${i + 1} 的 import 不是单行可解析形式（本 harness 不支持多行 import）：\n  ${line}`)
    }
    const clause = parseImportClause(m[1])
    imports.push({ module: m[2], ...clause })
    importLines.push(i)
  }
  for (const i of importLines) {
    lines[i] = ''
  }

  let code = lines.join('\n')

  // ② 装饰器不支持 ⇒ 显式失败（别静默产出错的代码）
  const deco = code.split('\n').findIndex((l) => /^\s*@[A-Za-z_$]/.test(l))
  if (deco >= 0) {
    throw new Error(`[harness] ${rel}:${deco + 1} 出现装饰器，本 harness 不支持 ArkUI 装饰器语境：\n  ${code.split('\n')[deco]}`)
  }

  // ③ export default 先处理
  let defaultName = null
  code = code.replace(/^export\s+default\s+(class|function)\s+([A-Za-z_$][\w$]*)/gm, (_all, kw, name) => {
    if (defaultName !== null) throw new Error(`[harness] ${rel} 出现多个 export default`)
    defaultName = name
    return `${kw} ${name}`
  })
  code = code.replace(/^export\s+default\s+([A-Za-z_$][\w$]*)\s*;?\s*$/gm, (_all, name) => {
    if (defaultName !== null) throw new Error(`[harness] ${rel} 出现多个 export default`)
    defaultName = name
    return ''
  })
  if (/^export\s+default/.test(code)) {
    throw new Error(`[harness] ${rel} 有未识别的 export default 形式（匿名默认导出不支持）`)
  }
  if (/^export\s*\{/m.test(code)) {
    throw new Error(`[harness] ${rel} 有 export { … } 聚合导出，本 harness 不支持`)
  }

  // ④ 收集具名导出（含 interface —— 它会被类型剥离擦掉，返回对象里要排除）
  const exported = []
  const re = /^export\s+(?:abstract\s+)?(class|const|let|var|enum|function|interface|type)\s+([A-Za-z_$][\w$]*)/gm
  let mm
  while ((mm = re.exec(code)) !== null) {
    exported.push({ kind: mm[1], name: mm[2] })
  }
  code = code.replace(/^export\s+/gm, '')

  // ⑤ 类型剥离（transform 才能处理 enum）
  let stripped
  try {
    stripped = stripTypeScriptTypes(code, { mode: 'transform' })
  } catch (e) {
    throw new Error(`[harness] ${rel} 类型剥离失败：${e.message}`)
  }
  if (/^import\s/m.test(stripped) || /^export\s/m.test(stripped)) {
    throw new Error(`[harness] ${rel} 剥离后仍残留 import/export 语句 ⇒ 提取管线失效`)
  }

  // ⑥ 校验注入：import 的每个绑定都必须由调用方提供
  const missing = []
  for (const imp of imports) {
    if (imp.defaultName && !(imp.defaultName in bindings)) missing.push(`${imp.defaultName} (default of '${imp.module}')`)
    if (imp.ns && !(imp.ns in bindings)) missing.push(`${imp.ns} (namespace of '${imp.module}')`)
    for (const n of imp.named) {
      if (!(n.local in bindings)) missing.push(`${n.local} (named '${n.imported}' of '${imp.module}')`)
    }
  }
  if (missing.length > 0) {
    throw new Error(`[harness] ${rel} 的 import 绑定未全部注入（源码依赖已漂移？）：\n  - ${missing.join('\n  - ')}`)
  }

  const bindDecls = Object.keys(bindings)
    .filter((k) => /^[A-Za-z_$][\w$]*$/.test(k))
    .map((k) => `const ${k} = __bindings[${JSON.stringify(k)}];`)
    .join('\n')

  // interface / type 被擦除，不能出现在返回对象里
  const runtimeNames = exported.filter((e) => e.kind !== 'interface' && e.kind !== 'type').map((e) => e.name)
  const returnPairs = runtimeNames.map((n) => `${JSON.stringify(n)}: ${n}`)
  if (defaultName !== null) {
    returnPairs.push(`${JSON.stringify('default')}: ${defaultName}`)
  }

  const body = `(function (__bindings) {\n"use strict";\n${bindDecls}\n${stripped}\nreturn { ${returnPairs.join(', ')} };\n})`
  const sandbox = { console, ...(opts.globals ?? {}) }
  const context = vm.createContext(sandbox)
  let fn
  try {
    fn = new vm.Script(body, { filename: rel }).runInContext(context)
  } catch (e) {
    throw new Error(`[harness] ${rel} 编译失败：${e.message}`)
  }
  const exportsObj = fn(bindings)
  return { exports: exportsObj, source: raw, imports }
}

// ── 断言小工具（每个测试文件各自的计数与退出码）──────────────────────────────

/**
 * 建一个测试运行器。用法：
 *   const t = createRunner('GroupTree 建树', { source: mod.source })
 *   t.check('label', cond, '证据：GroupTree.ets:104-107')
 *   t.sentinel('键名仍存在', /K_GRID_COLUMNS/, '守 ShelfPrefs.ets:78')
 *   t.done()
 * @param {string} title
 * @param {{ source?: string }} [opts] 传入源码后可启用 `t.sentinel` / `t.sourceLine`
 */
export function createRunner(title, opts = {}) {
  const results = []
  let currentGroup = ''
  const source = opts.source
  /** 统一证据行的前缀，避免打印出「证据：证据：…」 */
  const ev = (e) => (String(e).startsWith('证据：') ? String(e) : `证据：${e}`)

  const api = {
    /** 分组标题（只影响打印，不影响断言） */
    group(name) {
      currentGroup = name
      console.log(`\n── ${name} ──`)
    },
    /**
     * @param {string} label 断言描述
     * @param {boolean} cond 结果
     * @param {string} evidence 源码依据（`文件:行`）—— 必填，空则视为测试自身缺陷
     */
    check(label, cond, evidence) {
      if (!evidence) {
        throw new Error(`[runner] 断言「${label}」缺少证据引用（源码 文件:行）`)
      }
      const ok = cond === true
      results.push({ label, ok, evidence, group: currentGroup })
      console.log(`  ${ok ? '✅' : '❌'} ${label}`)
      if (!ok) {
        console.log(`     ${ev(evidence)}`)
      }
    },
    /** 断言"值相等"，失败时打印期望/实际，值用 JSON 表示便于定位 */
    eq(label, actual, expected, evidence) {
      const ok = JSON.stringify(actual) === JSON.stringify(expected)
      api.check(label, ok, evidence)
      if (!ok) {
        console.log(`     期望：${JSON.stringify(expected)}`)
        console.log(`     实际：${JSON.stringify(actual)}`)
      }
    },
    /**
     * 源码漂移哨兵：断言关键签名原文还在，并打印它的**真实行号**。
     * 与 `loadEtsModule` 的"注入缺一个就抛"合起来，保证"执行的是真源码"而不是空跑通过。
     * @param {string} label
     * @param {RegExp} re
     * @param {string} why 守的是什么（同时作为证据）
     */
    sentinel(label, re, why) {
      if (typeof source !== 'string') {
        throw new Error('[runner] 没给 createRunner 传 source，无法做 sentinel')
      }
      let ok = false
      let lineNo = 0
      let err = ''
      try {
        lineNo = sentinel(source, re, why)
        ok = true
      } catch (e) {
        err = e.message
      }
      api.check(label, ok, why)
      if (ok) {
        console.log(`     源码命中：第 ${lineNo} 行`)
      } else {
        console.log(`     ${err}`)
      }
    },
    /** 收尾：打印汇总并按失败数决定退出码 */
    done() {
      const failed = results.filter((r) => !r.ok)
      console.log(`\n═══ ${title} ═══`)
      console.log(`  断言 ${results.length} 条：通过 ${results.length - failed.length}，失败 ${failed.length}`)
      if (failed.length === 0) {
        console.log(`✅ 全部通过（${results.length}/${results.length}）`)
        process.exit(0)
      }
      console.log(`\n❌ 失败 ${failed.length} 条：`)
      for (const f of failed) {
        console.log(`  · [${f.group || 'default'}] ${f.label}`)
        console.log(`    ${ev(f.evidence)}`)
      }
      process.exit(1)
    },
  }
  return api
}
