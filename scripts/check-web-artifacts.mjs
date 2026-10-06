/**
 * check-web-artifacts.mjs —— 防「改了 web/ 却忘了重建 rawfile」的**产物新鲜度闸门**
 * ============================================================================
 * 背景（本次全量审计的 D2 项）：手机端 Web 服务发出去的是 `web/` 真前端工程的构建产物
 * （`entry/src/main/resources/rawfile/{reader,library,upload}_v3.html`）。**没有任何自动化**
 * 保证这两者同步 —— 忘了跑构建，用户看到的就是旧页面，而构建日志一切正常。
 *
 * 为什么不直接改 `hvigorfile.ts` 挂 hook：
 *   本工程 `hvigorfile.ts` 只有一行 `export { hapTasks } from '@ohos/hvigor-ohos-plugin'`，
 *   工程内**没有** `node_modules/@ohos/hvigor`（实测 `Test-Path` = False），而 hvigor 的
 *   插件 API 只能从随 DevEco 安装的工具链里取。改动构建入口一旦失败会**直接打断整个构建**
 *   （风险高于收益）⇒ 采用**可独立运行、失败只报告不改构建**的替代方案：
 *     ① 本脚本：比对 `web/src/*`、模板、build.mjs 与三个产物的 mtime，旧了就**非零退出**；
 *     ② `.githooks/pre-commit`：提交前自动跑一次 `node web/build.mjs`（真正修好，而非只报错）。
 *
 * 用法：
 *   node scripts/check-web-artifacts.mjs          # 检查（旧 ⇒ exit 1）
 *   node scripts/check-web-artifacts.mjs --quiet  # 只在不新鲜时输出
 */
import { statSync, readdirSync, existsSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'

const here = dirname(fileURLToPath(import.meta.url))
const root = join(here, '..')
const webSrc = join(root, 'web', 'src')
const outDir = join(root, 'entry', 'src', 'main', 'resources', 'rawfile')
const quiet = process.argv.includes('--quiet')

/** 产物 → 它由哪些源文件生成（粗略但足够：任一源比产物新即视为"旧"） */
const ARTIFACTS = ['reader_v3.html', 'library_v3.html', 'upload_v3.html']

function sources() {
  const list = []
  if (existsSync(webSrc)) {
    for (const f of readdirSync(webSrc)) list.push(join(webSrc, f))
  }
  for (const extra of ['build.mjs', 'index.html', 'library.html', 'upload.html', 'package.json']) {
    const p = join(root, 'web', extra)
    if (existsSync(p)) list.push(p)
  }
  return list
}

const stale = []
let newestSrc = 0
for (const s of sources()) {
  const t = statSync(s).mtimeMs
  if (t > newestSrc) newestSrc = t
}

for (const name of ARTIFACTS) {
  const out = join(outDir, name)
  if (!existsSync(out)) {
    stale.push(`${name} 不存在`)
    continue
  }
  if (statSync(out).mtimeMs < newestSrc) {
    stale.push(`${name} 早于 web/ 最新改动`)
  }
}

if (stale.length > 0) {
  console.error('[web-artifacts] 构建产物已过期（用户会看到旧页面）：')
  for (const s of stale) console.error('  · ' + s)
  console.error('  修复： cd web && node build.mjs        （然后重新构建 HAP）')
  process.exit(1)
}

if (!quiet) {
  console.log(`[web-artifacts] OK：3 个 *_v3.html 均新于 web/ 源文件`)
}
