/**
 * build.mjs —— 构建：esbuild 打包 TS + CSS → **单文件 HTML** → 落到 App 的 rawfile
 * ============================================================================
 * 三个页面（都是**自带全部 CSS/JS、无外链**的单文件）：
 *   `reader_v3.html`   阅读页（/read?id=）
 *   `library_v3.html`  书库页（/library）
 *   `upload_v3.html`   传书页（/ 与 /index.html）
 *
 * 为什么这样做（对比旧的"把整页 HTML/JS 塞进 ArkTS 模板字符串"）：
 *   · 前端代码第一次能被 lint / 类型检查 / 单测（`web/test`）/ 浏览器断点；
 *   · 服务端**零字符串拼接**（我曾在模板字符串的注释里打反引号，直接把字符串截断、编译失败）；
 *   · 与手机端无关的页面也能离线本地跑（`web/dev/server.mjs` + mock）。
 *
 * 用法：
 *   node build.mjs            一次性构建（写 rawfile）
 *   node build.mjs --dev      构建到 dev/out/（本地 mock 用，不写 rawfile）
 *   node build.mjs --watch    监听重建（配合 dev/server.mjs）
 */
import { build } from 'esbuild'
import { readFile, writeFile, mkdir } from 'node:fs/promises'
import { watch } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { dirname, resolve, join } from 'node:path'

const here = dirname(fileURLToPath(import.meta.url))
const args = new Set(process.argv.slice(2))
const isDev = args.has('--dev') || args.has('--watch')
const outDir = isDev
  ? join(here, 'dev', 'out')
  : resolve(here, '..', 'entry', 'src', 'main', 'resources', 'rawfile')

/** name → { entry, shell, out } */
const PAGES = [
  { name: 'reader', entry: 'src/main.ts', shell: 'index.html', out: 'reader_v3.html' },
  { name: 'library', entry: 'src/library.ts', shell: 'library.html', out: 'library_v3.html' },
  { name: 'upload', entry: 'src/upload.ts', shell: 'upload.html', out: 'upload_v3.html' }
]

async function emitOne(page) {
  const result = await build({
    entryPoints: [join(here, page.entry)],
    bundle: true,
    format: 'iife',
    target: ['es2020'],
    minify: !isDev,
    sourcemap: isDev ? 'inline' : false,
    // esbuild 需要 outfile/outdir 才会产出 CSS 条目（write:false ⇒ 只进内存，不落盘）
    outfile: join(outDir, '_' + page.name + '.js'),
    write: false,
    logLevel: 'warning'
  })
  const js = result.outputFiles.find((f) => f.path.endsWith('.js'))?.text ?? ''
  const css = result.outputFiles.find((f) => f.path.endsWith('.css'))?.text ?? ''
  if (css === '' || js === '') {
    throw new Error(`${page.name}: 打包产物为空（css=${css.length} js=${js.length}）`)
  }
  const shell = await readFile(join(here, page.shell), 'utf8')
  // ⚠️ 用 replaceAll + 断言：模板里**任何**一处多余的占位符（例如说明性 HTML 注释里也写了
  //    /*STYLES*/）都会让 replace 只替换第一处 ⇒ CSS/JS 被塞进注释、真正的 <style>/<script>
  //    留空 ⇒ 页面无样式无脚本。2026-10-05 真实踩过，用户截图才暴露 ⇒ 这里直接构建期报错。
  const html = shell.replaceAll('/*STYLES*/', () => css).replaceAll('/*BUNDLE*/', () => js)
  if (html.includes('/*STYLES*/') || html.includes('/*BUNDLE*/')) {
    throw new Error(`${page.name}: 模板 ${page.shell} 里的占位符未被完全替换（检查是否有重复占位符）`)
  }
  const file = join(outDir, page.out)
  await writeFile(file, html, 'utf8')
  const kb = (Buffer.byteLength(html, 'utf8') / 1024).toFixed(1)
  console.log(`[build] ${page.out}  (${kb} KB, css=${css.length}B js=${js.length}B)`)
}

async function emitAll() {
  await mkdir(outDir, { recursive: true })
  for (const page of PAGES) {
    await emitOne(page)
  }
}

if (args.has('--watch')) {
  let timer = null
  const kick = () => {
    if (timer) clearTimeout(timer)
    timer = setTimeout(() => {
      emitAll().catch((e) => console.error('[build] failed:', e))
    }, 80)
  }
  watch(join(here, 'src'), { recursive: true }, kick)
  for (const page of PAGES) watch(join(here, page.shell), kick)
  await emitAll()
  console.log('[build] watching src/ + *.html …')
} else {
  await emitAll()
}
