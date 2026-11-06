#!/usr/bin/env node
/**
 * tools/version-manager/server.mjs
 * ============================================================================
 * 版本管理器（本地小服务 + 单页 UI）
 *
 * ★ 设计铁律：**不绕过钩子、不手写产物**
 *   本工具只做两件事：
 *     ① 读：git 提交历史 / AppScope/app.json5 / VersionLogData.ets
 *     ② 写：把你在界面上编辑好的内容落成一条**符合规范提交备注**的提交消息文件，
 *        然后调用 `git commit -F <文件>` —— 让 `.githooks/post-commit` 去跑
 *        `scripts/sync-version.ps1`，由它生成 app.json5 与 VersionLogData.ets。
 *   所以它和手敲 `git commit` 是**同一条通路**，产物永远一致。
 *
 * 启动： node tools/version-manager/server.mjs [--port 8791] [--no-open]
 * ============================================================================
 */
import http from 'node:http';
import { spawn } from 'node:child_process';
import { readFile, writeFile, mkdtemp, rm } from 'node:fs/promises';
import { existsSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';

const REPO = path.resolve(path.dirname(process.argv[1]), '..', '..');
const APP_JSON = path.join(REPO, 'AppScope/app.json5');
const DATA_ETS = path.join(REPO, 'entry/src/main/ets/pages/view/myCenter/about/VersionLogData.ets');
const PUBLIC = path.join(REPO, 'tools/version-manager/public/index.html');
const SINCE = '2026-10-01';   // 与 scripts/sync-version.ps1 的 -Since 保持一致

const argv = process.argv.slice(2);
const argOf = (name, dflt) => {
  const i = argv.indexOf(name);
  return i >= 0 && argv[i + 1] ? argv[i + 1] : dflt;
};
const PORT = Number(argOf('--port', process.env.VM_PORT || 8791));
const NO_OPEN = argv.includes('--no-open');

// ── git 调用：收 Buffer 再按 UTF-8 解（不吃 PowerShell 的 GBK 坑）──────────────
function git(args, opts = {}) {
  return new Promise((resolve) => {
    const child = spawn('git', ['-C', REPO, ...args], {
      shell: false,
      windowsHide: true,
      env: { ...process.env, GIT_PAGER: 'cat' },
    });
    const out = [];
    const err = [];
    child.stdout.on('data', (b) => out.push(b));
    child.stderr.on('data', (b) => err.push(b));
    child.on('error', (e) =>
      resolve({ code: -1, stdout: '', stderr: String(e && e.message ? e.message : e) }));
    child.on('close', (code) =>
      resolve({
        code,
        stdout: Buffer.concat(out).toString('utf8'),
        stderr: Buffer.concat(err).toString('utf8'),
      }));
    if (opts.stdin != null) {
      child.stdin.write(opts.stdin, 'utf8');
    }
    child.stdin.end();
  });
}

// ── 解析 git log（逐行对齐 scripts/sync-version.ps1 的语义）──────────────────
const US = '\x1f';
const RS = '\x1e';
const RE_VER = /(\d+\.\d+\.\d+)/;
const stripNum = (s) => s.replace(/^\s*\d+\s*[\.、\)]\s*/, '').trim();

function codeOf(ver) {
  const p = String(ver).replace(/^V/i, '').split('.').map(Number);
  if (p.length < 3 || p.some((n) => !Number.isFinite(n))) return 0;
  return p[0] * 1000000 + p[1] * 1000 + p[2];
}

function parseOne(subject, body) {
  const m = RE_VER.exec(subject);
  if (!m) return null;
  const version = 'V' + m[1];
  let rest = subject.slice(m.index + m.length).trim();

  // 标题：版本号之后、第一个编号条目之前（旧格式）；没有编号则整段都是标题
  let title = '';
  const mm = /^(.*?)\s*(?=\d+\s*[\.、\)])/.exec(rest);
  if (mm) {
    const t = mm[1].trim();
    if (t !== '') title = t;
    rest = rest.slice(mm.length);
  } else {
    title = rest;
    rest = '';
  }

  rest = rest.replace(/ \d+$/, '');           // 剥掉历史里的「末尾 AI 序号」
  const items = [];
  const pieces = (rest + ';' + body).split(/[;；\n\r]|\s+(?=\d+\s*[\.、\)]\s*\D)/);
  for (const p of pieces) {
    const t = stripNum(p);
    if (t === '' || /^\d+$/.test(t)) continue;
    if (!items.includes(t)) items.push(t);
  }
  return { version, title, items };
}

async function collectHistory() {
  const fmt = ['%H', '%ad', '%s', '%b'].join(US) + RS;
  const r = await git(['-c', 'i18n.logOutputEncoding=UTF-8', 'log', '--date=short',
    `--pretty=format:${fmt}`]);
  const byVersion = new Map();   // 保持 git 顺序（新→旧）
  for (const chunk of r.stdout.split(RS)) {
    const c = chunk.replace(/^[\r\n]+|[\r\n]+$/g, '');
    if (!c) continue;
    const f = c.split(US);
    if (f.length < 4) continue;
    const [hash, date, subject, body] = f;
    const parsed = parseOne(subject, body);
    if (!parsed) continue;
    const upstream = date < SINCE;
    const prev = byVersion.get(parsed.version);
    if (prev) {
      for (const it of parsed.items) if (!prev.items.includes(it)) prev.items.push(it);
      if (!prev.title && parsed.title) prev.title = parsed.title;
      prev.commits.push({ hash: hash.slice(0, 7), date, subject });
    } else {
      byVersion.set(parsed.version, {
        version: parsed.version,
        title: parsed.title,
        date,
        upstream,
        items: parsed.items,
        commits: [{ hash: hash.slice(0, 7), date, subject }],
      });
    }
  }
  return [...byVersion.values()];
}

// ── 读 app.json5 ────────────────────────────────────────────────────────────
async function readApp() {
  const txt = await readFile(APP_JSON, 'utf8');
  return {
    versionName: (/"versionName"\s*:\s*"([^"]*)"/.exec(txt) || [])[1] || '',
    versionCode: Number((/"versionCode"\s*:\s*(\d+)/.exec(txt) || [])[1] || 0),
  };
}

// ── 读 VersionLogData.ets（当前页面真实显示的内容）───────────────────────────
async function readVersionLog() {
  const txt = await readFile(DATA_ETS, 'utf8');
  const entries = [];
  const re = /version:\s*'((?:[^'\\]|\\.)*)',\s*[\r\n]+\s*date:\s*'([^']*)',\s*[\r\n]+\s*items:\s*\[([\s\S]*?)\]/g;
  let m;
  while ((m = re.exec(txt)) !== null) {
    const items = [];
    const ir = /'((?:[^'\\]|\\.)*)'/g;
    let im;
    while ((im = ir.exec(m[3])) !== null) items.push(im[1].replace(/\\'/g, "'").replace(/\\\\/g, '\\'));
    entries.push({ version: m[1], date: m[2], items });
  }
  return entries;
}

async function readWorktreeStatus() {
  const r = await git(['status', '--porcelain']);
  const staged = [];
  const unstaged = [];
  const untracked = [];
  for (const line of r.stdout.split(/\r?\n/)) {
    if (!line.trim()) continue;
    const x = line[0];
    const y = line[1];
    const p = line.slice(3);
    if (x === '?') untracked.push(p);
    else {
      if (x !== ' ' && x !== '?') staged.push(p);
      if (y !== ' ' && y !== '?') unstaged.push(p);
    }
  }
  return { staged, unstaged, untracked };
}

// ── 护栏复刻（必须与 sync-version.ps1 L187-205 一致）──────────────────────────
function computeGuard(app, history) {
  const latest = history.find((h) => !h.upstream) || history[0] || null;
  const latestCode = latest ? codeOf(latest.version) : 0;
  const blocked = latestCode > 0 && app.versionCode > 0 && latestCode < app.versionCode;
  return {
    latestVersionInGit: latest ? latest.version : '',
    latestCode,
    currentCode: app.versionCode,
    blocked,
    note: blocked
      ? `git 里最新带版本号的提交是 ${latest.version}（code=${latestCode}），小于 app.json5 当前的 ${app.versionCode}`
        + ` ⇒ 生成器会「拒绝降级」，两个产物都不动。要解开：提交一条首行版本 >= ${app.versionName} 的提交。`
      : '',
  };
}

// ── 组装提交备注 + 体检 ──────────────────────────────────────────────────────
function buildMessage(version, items) {
  const v = String(version || '').trim().replace(/^V/i, '');
  const list = (items || []).map((s) => String(s).trim()).filter((s) => s !== '');
  const lines = ['V' + v];
  list.forEach((it, i) => lines.push(`${i + 1}.${it}`));
  return lines.join('\n') + '\n';
}

function lintMessage(version, items) {
  const warn = [];
  const v = String(version || '').trim().replace(/^V/i, '');
  if (!/^\d+\.\d+\.\d+$/.test(v)) warn.push({ level: 'error', text: `版本号格式必须是 x.y.z（当前：${version || '空'}）` });
  const list = (items || []).map((s) => String(s).trim()).filter(Boolean);
  if (list.length === 0) warn.push({ level: 'error', text: '条目为空 —— 更新日志会变成空卡片' });
  // 注：本工具**不**对「条目里含 26.0.0 这类版本号形态」告警，但理由不是"正文不参与解析"：
  //   git 在多行消息**没有空行**时会把整段当 subject（`%s`），实测 72 行消息 → %s 1956 字符，
  //   scripts/sync-version.ps1 L117 用 `[regex]::Match($r.subject, ...)` **取第一个**匹配。
  //   本工具生成的首行恒为 `V<x.y.z>`（见 buildMessage）⇒ 第一个匹配就是它，后面的 26.0.0 抢不到。
  //   ⚠️ 反过来：**非发版提交**（docs/fix）若首行没有版本号，正文里任何 x.y.z 都会被当版本号
  //      —— 这就是 §6 记的两次事故机制，所以手写提交时仍必须脱敏。
  const engWords = ['重构', '迁移', '抽成组件', '脚手架', '测试通过', '真机验收', '字段迁到', '口径统一', '组件化'];
  list.forEach((it, i) => {
    const hit = engWords.find((w) => it.includes(w));
    if (hit) warn.push({ level: 'warn', text: `第 ${i + 1} 条像工程/内部术语（「${hit}」）：更新日志只写用户能感知的变化（§6）` });
  });
  return warn;
}

// ── HTTP ────────────────────────────────────────────────────────────────────
const json = (res, code, obj) => {
  const body = JSON.stringify(obj);
  res.writeHead(code, {
    'Content-Type': 'application/json; charset=utf-8',
    'Cache-Control': 'no-store',
  });
  res.end(body);
};

async function readBody(req) {
  const chunks = [];
  for await (const c of req) chunks.push(c);
  const raw = Buffer.concat(chunks).toString('utf8');
  if (!raw.trim()) return {};
  try { return JSON.parse(raw); } catch { return {}; }
}

async function handleState() {
  const [app, log, history, status] = await Promise.all([
    readApp(), readVersionLog(), collectHistory(), readWorktreeStatus(),
  ]);
  const branch = (await git(['rev-parse', '--abbrev-ref', 'HEAD'])).stdout.trim();
  const head = (await git(['log', '-1', '--format=%h|%ad|%s', '--date=short'])).stdout.trim();
  const [headHash, headDate, ...headRest] = head.split('|');
  return {
    repoRoot: REPO,
    branch,
    head: { hash: headHash, date: headDate, subject: (headRest.join('|') || '').slice(0, 120) },
    app,
    currentLog: log,
    history,
    guard: computeGuard(app, history),
    status,
    meta: { since: SINCE, dataFile: 'entry/src/main/ets/pages/view/myCenter/about/VersionLogData.ets' },
  };
}

async function handleApply(payload) {
  const version = String(payload.version || '').trim();
  const items = Array.isArray(payload.items) ? payload.items : [];
  const mode = payload.mode === 'amend' ? 'amend' : payload.mode === 'empty' ? 'empty' : 'commit';
  const dryRun = payload.dryRun === true;

  const errs = lintMessage(version, items).filter((w) => w.level === 'error');
  if (errs.length) return { ok: false, step: 'lint', warnings: errs, output: '' };

  const message = buildMessage(version, items);
  const dir = await mkdtemp(path.join(os.tmpdir(), 'vm-'));
  const msgFile = path.join(dir, 'commit-msg.txt');
  await writeFile(msgFile, message, 'utf8');

  const commitArgs =
    mode === 'amend' ? ['commit', '--amend', '-F', msgFile]
    : mode === 'empty' ? ['commit', '--allow-empty', '-F', msgFile]
    : ['commit', '-F', msgFile];

  const plan = [`git commit ${mode === 'amend' ? '--amend ' : mode === 'empty' ? '--allow-empty ' : ''}-F <临时消息文件>`];
  if (dryRun) {
    await rm(dir, { recursive: true, force: true });
    return { ok: true, dryRun: true, message, plan, warnings: lintMessage(version, items), output: '(dry-run：未执行任何命令)' };
  }

  const r = await git(commitArgs);
  await rm(dir, { recursive: true, force: true });

  const after = await handleState();
  return {
    ok: r.code === 0,
    message,
    plan,
    warnings: lintMessage(version, items),
    output: (r.stdout || '') + (r.stderr || ''),
    exitCode: r.code,
    after,
  };
}

async function handlePreview(payload) {
  const version = String(payload.version || '').trim();
  const items = Array.isArray(payload.items) ? payload.items : [];
  const warnings = lintMessage(version, items);

  // 防「更新日志缩水」（§6 V3.0.13 事故）：新条目比页面上现有的少，就提醒
  try {
    const cur = await readVersionLog();
    const curCount = cur[0] ? cur[0].items.length : 0;
    const nextCount = items.map((s) => String(s).trim()).filter(Boolean).length;
    if (curCount > 0 && nextCount < curCount) {
      warnings.push({
        level: 'warn',
        text: `条目从 ${curCount} 条减到 ${nextCount} 条 —— 页面只显示「当前版本」一条，`
          + `删掉的条目就从更新日志里消失了。确认这是你要的。`,
      });
    }
    if (cur[0] && ('V' + version.replace(/^V/i, '')) !== cur[0].version) {
      warnings.push({
        level: 'warn',
        text: `版本号将从 ${cur[0].version} 变为 V${version.replace(/^V/i, '')} `
          + `—— 旧版本的条目不会自动带过来（脚本默认只保留当前版本一条）。`,
      });
    }
  } catch { /* 读不到日志就算了，不影响预览 */ }

  return { message: buildMessage(version, items), code: codeOf(version), warnings };
}

const server = http.createServer(async (req, res) => {  try {
    const url = new URL(req.url, 'http://127.0.0.1');
    if (req.method === 'GET' && (url.pathname === '/' || url.pathname === '/index.html')) {
      const html = await readFile(PUBLIC, 'utf8');
      res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8', 'Cache-Control': 'no-store' });
      return res.end(html);
    }
    if (req.method === 'GET' && url.pathname === '/api/state') {
      return json(res, 200, await handleState());
    }
    if (req.method === 'POST' && url.pathname === '/api/preview') {
      return json(res, 200, await handlePreview(await readBody(req)));
    }
    if (req.method === 'POST' && url.pathname === '/api/apply') {
      return json(res, 200, await handleApply(await readBody(req)));
    }
    if (url.pathname === '/api/health') return json(res, 200, { ok: true, repo: REPO });
    json(res, 404, { error: 'not found' });
  } catch (e) {
    json(res, 500, { error: String(e && e.message ? e.message : e) });
  }
});

// ── 监听：端口被占就自动顺延（2026-11-06 实测 EADDRINUSE 后加的）──────────────
function listenFrom(port, triesLeft) {
  const onError = (e) => {
    server.removeListener('error', onError);
    if (e && e.code === 'EADDRINUSE' && triesLeft > 0) {
      console.warn(`[version-manager] 端口 ${port} 被占用，尝试 ${port + 1} …`);
      listenFrom(port + 1, triesLeft - 1);
      return;
    }
    console.error(`[version-manager] 监听失败：${e && e.code ? e.code : e}`);
    process.exit(1);
  };
  server.once('error', onError);
  server.listen(port, '127.0.0.1', () => {
    server.removeListener('error', onError);
    const url = `http://127.0.0.1:${port}`;
    console.log(`[version-manager] repo = ${REPO}`);
    console.log(`[version-manager] ${url}`);
    if (!NO_OPEN) openBrowser(url);
  });
}

// ── 启动器模式（默认）：已有实例就直接开浏览器；没有就后台起一个再开浏览器 ──────
function openBrowser(url) {
  if (NO_OPEN) return;
  spawn('cmd', ['/c', 'start', '', url], { detached: true, stdio: 'ignore', windowsHide: true }).unref();
}

async function probeExisting() {
  for (let p = PORT; p < PORT + 20; p++) {
    try {
      const ctl = new AbortController();
      const t = setTimeout(() => ctl.abort(), 500);
      const r = await fetch(`http://127.0.0.1:${p}/api/health`, { signal: ctl.signal });
      clearTimeout(t);
      if (r.ok) {
        const j = await r.json();
        if (j && j.repo === REPO) return p;
      }
    } catch { /* 这个端口没有我们的实例 */ }
  }
  return 0;
}

const IS_SERVE = argv.includes('--serve');

if (!IS_SERVE) {
  (async () => {
    const existing = await probeExisting();
    if (existing) {
      console.log(`[version-manager] 已有实例在跑：http://127.0.0.1:${existing}`);
      openBrowser(`http://127.0.0.1:${existing}`);
      process.exit(0);
    }
    // 后台拉起真正的服务（detached、无窗口），再等它就绪
    const child = spawn(process.execPath, [process.argv[1], '--serve'], {
      detached: true, stdio: 'ignore', windowsHide: true, cwd: REPO,
    });
    child.unref();
    for (let i = 0; i < 60; i++) {
      await new Promise((r) => setTimeout(r, 200));
      const p = await probeExisting();
      if (p) {
        console.log(`[version-manager] 已启动：http://127.0.0.1:${p}`);
        openBrowser(`http://127.0.0.1:${p}`);
        process.exit(0);
      }
    }
    console.error('[version-manager] 启动超时，请手动运行：node server.mjs --serve');
    process.exit(1);
  })();
} else {
  listenFrom(PORT, 20);
}
