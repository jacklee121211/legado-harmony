/**
 * uploader.ts —— WiFi 传书页（2026-10-06 重写）
 * ============================================================================
 * 相对旧实现（整文件一个 XHR + FormData）：
 *   ① **分块上传 + 断点续传**（用户明确要求）：文件按 4 MB 切片，先 `/up/init` 拿
 *      "已收到的块表"，只补缺的块 ⇒ 断网/关页/换网络后重新选择同一个文件即可续传。
 *   ② **同名冲突弹窗**（用户拍板 C1）：服务端撞名返回 409，这里弹"改名 / 拒绝"。
 *      注意服务端在撞名时**不落盘**，所以"拒绝"不需要回滚任何文件。
 *   ③ **失败原因说人话**：401 = 未配对；413 = 超 100 MB；409 = 同名；
 *      410 = 会话过期（自动从 0 重传一次）。
 *   ④ **可一键回退**：`CHUNK_UPLOAD = false` 时完全恢复旧的单请求 FormData 行为
 *      （回退开关口径与工程规范第 3 条一致）。
 *
 * 服务端契约（`WifiBookServer.ets`）：`/up/init`、`/up/chunk?sid&i`、`/up/done`、`/up/abort`
 */

import './pages.css'
import { report } from './offline.ts'
import { authed } from './api.ts'

/** 回退开关：false ⇒ 用旧的"整文件一次 POST /upload" */
export const CHUNK_UPLOAD = true

interface Picked {
  f: File
  /** 已成功入架 */
  done: boolean
  /** 当前进度 0~100 */
  pct: number
  /** 状态文本（'' = 待传） */
  status: string
  statusKind: 'wait' | 'ok' | 'err'
  /** 已上传字节（断点续传的显示用） */
  sent: number
}

const files: Picked[] = []
/** 真机（手机端）才支持分块接口；本地 mock 服务器只有 /upload ⇒ 自动回退 */
let chunkSupported = CHUNK_UPLOAD

function $(sel: string): HTMLElement {
  const e = document.querySelector(sel)
  if (!e) throw new Error('缺少 DOM 节点: ' + sel)
  return e as HTMLElement
}

function fmt(n: number): string {
  return n > 1048576 ? (n / 1048576).toFixed(1) + ' MB' : (n / 1024).toFixed(0) + ' KB'
}

function esc(s: string): string {
  return s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;')
}

function render(): void {
  const list = $('#list')
  list.innerHTML = ''
  files.forEach((it, idx) => {
    const row = document.createElement('div')
    row.className = 'it'
    const ext = (it.f.name.split('.').pop() ?? '').toUpperCase().slice(0, 4)
    row.innerHTML =
      `<div class="ico">${esc(ext)}</div><div class="meta"><div class="nm"></div>` +
      `<div class="sz">${fmt(it.f.size)}</div><div class="bar"><i></i></div></div>` +
      `<div class="st ${it.statusKind}"></div><button class="x" title="移除">✕</button>`
    const nm = row.querySelector('.nm')
    if (nm) nm.textContent = it.f.name
    const st = row.querySelector('.st')
    if (st) st.textContent = it.status
    const bar = row.querySelector('.bar i') as HTMLElement | null
    if (bar) bar.style.width = it.pct + '%'
    row.querySelector('.x')?.addEventListener('click', () => {
      const k = files.indexOf(it)
      if (k >= 0) {
        files.splice(k, 1)
        render()
      }
    })
    list.appendChild(row)
  })
  $('#empty').style.display = files.length > 0 ? 'none' : 'block'
  ;($('#up') as HTMLButtonElement).disabled = !files.some((x) => !x.done)
}

function add(fl: FileList | null): void {
  if (!fl) return
  for (let i = 0; i < fl.length; i++) {
    const f = fl.item(i)
    if (f) files.push({ f, done: false, pct: 0, status: '待传', statusKind: 'wait', sent: 0 })
  }
  render()
}

/** 把某个文件行的 UI 状态写回去（按 File 对象身份找，避免同名文件串行） */
function patch(it: Picked): void {
  const rows = Array.from($('#list').children)
  const i = files.indexOf(it)
  const row = rows[i]
  if (!row) return
  const st = row.querySelector('.st')
  if (st) {
    st.textContent = it.status
    st.className = 'st ' + it.statusKind
  }
  const bar = row.querySelector('.bar i') as HTMLElement | null
  if (bar) bar.style.width = it.pct + '%'
}

/** 极简 XHR POST（需要真实上传进度；fetch 拿不到 upload progress） */
function xhrPost(url: string, body: Blob | string, onProgress?: (loaded: number, total: number) => void): Promise<{ status: number; text: string }> {
  return new Promise((resolve, reject) => {
    const xhr = new XMLHttpRequest()
    xhr.open('POST', authed(url))
    if (typeof body === 'string') xhr.setRequestHeader('Content-Type', 'application/json')
    if (onProgress) {
      xhr.upload.onprogress = (e: ProgressEvent): void => {
        if (e.lengthComputable) onProgress(e.loaded, e.total)
      }
    }
    xhr.onload = (): void => resolve({ status: xhr.status, text: xhr.responseText })
    xhr.onerror = (): void => reject(new Error('network'))
    xhr.onabort = (): void => reject(new Error('aborted'))
    xhr.send(body)
  })
}

interface InitResp {
  ok?: boolean
  sid?: string
  chunk?: number
  have?: number[]
  msg?: string
}

interface ConflictDecision {
  kind: ConflictChoice
  /** 用户填的新文件名（kind = 'retry' 时有效） */
  newName: string
}

type ConflictChoice = 'retry' | 'cancel'

function askConflict(fileName: string, existingId: number): Promise<ConflictDecision> {
  return new Promise((resolve) => {
    const mask = document.createElement('div')
    mask.style.cssText =
      'position:fixed;inset:0;background:rgba(0,0,0,.35);z-index:10000;display:flex;align-items:center;' +
      'justify-content:center;padding:20px;font-family:-apple-system,"PingFang SC",sans-serif'
    mask.innerHTML =
      '<div style="background:#fff;border-radius:16px;max-width:420px;width:100%;padding:22px">' +
      '<div style="font-size:16px;font-weight:700;margin-bottom:8px">书架里已有同名书籍</div>' +
      '<div class="mrName" style="font-size:13px;color:#8a8f99;margin-bottom:14px"></div>' +
      '<input class="mrNew" style="width:100%;height:40px;border:1px solid #D8DBE2;border-radius:10px;' +
      'padding:0 12px;font-size:14px;outline:none;box-sizing:border-box" />' +
      '<div style="display:flex;gap:10px;margin-top:16px">' +
      '<button class="mrCancel" style="flex:1;height:42px;border:0;border-radius:10px;background:#F0F1F5;' +
      'font-size:15px;font-weight:600;color:#555;cursor:pointer">拒绝</button>' +
      '<button class="mrOk" style="flex:1;height:42px;border:0;border-radius:10px;background:#0A84FF;' +
      'font-size:15px;font-weight:600;color:#fff;cursor:pointer">改名后上传</button>' +
      '</div></div>'
    const nameEl = mask.querySelector('.mrName')
    if (nameEl) nameEl.textContent = fileName + (existingId > 0 ? `（书架 id=${existingId}）` : '')
    const input = mask.querySelector('.mrNew') as HTMLInputElement
    const dot = fileName.lastIndexOf('.')
    const suggest = dot > 0
      ? fileName.slice(0, dot) + '(2)' + fileName.slice(dot)
      : fileName + '(2)'
    input.value = suggest
    const close = (kind: ConflictChoice): void => {
      // ⚠️ 必须在 **remove() 之前**读输入框：remove 之后 querySelector 拿不到节点
      const v = input.value.trim()
      mask.remove()
      resolve({ kind, newName: v !== '' ? v : suggest })
    }
    mask.querySelector('.mrCancel')?.addEventListener('click', () => close('cancel'))
    mask.querySelector('.mrOk')?.addEventListener('click', () => close('retry'))
    document.body.appendChild(mask)
    input.focus()
    input.select()
  })
}

/**
 * 分块上传一个文件（含断点续传）。
 * @returns 是否成功入架
 */
async function uploadChunked(it: Picked): Promise<boolean> {
  const name = it.f.name
  const total = it.f.size
  let init: InitResp
  try {
    const r = await xhrPost('/up/init', JSON.stringify({ name, size: total }))
    if (r.status === 401 || r.status === 403) {
      report('unauth')
      it.status = '未配对'
      it.statusKind = 'err'
      return false
    }
    init = JSON.parse(r.text) as InitResp
    if (r.status !== 200 || init.ok !== true || !init.sid) {
      it.status = init.msg ?? '初始化失败'
      it.statusKind = 'err'
      chunkSupported = false
      return false
    }
  } catch {
    report('offline')
    it.status = '连接失败'
    it.statusKind = 'err'
    return false
  }
  report('ok')
  const sid = init.sid
  const chunk = init.chunk && init.chunk > 0 ? init.chunk : 4 * 1024 * 1024
  const have = new Set<number>(Array.isArray(init.have) ? init.have : [])
  const count = Math.max(1, Math.ceil(total / chunk))
  if (have.size > 0) {
    it.status = `续传（已完成 ${have.size}/${count} 块）`
    it.statusKind = 'wait'
    patch(it)
  }
  let sentBytes = have.size * chunk
  for (let i = 0; i < count; i++) {
    if (have.has(i)) continue
    const blob = it.f.slice(i * chunk, Math.min(total, (i + 1) * chunk))
    let ok = false
    let attempts = 0
    while (!ok && attempts < 2) {
      attempts++
      try {
        const r = await xhrPost('/up/chunk?sid=' + encodeURIComponent(sid) + '&i=' + i, blob, (loaded) => {
          const base = Math.min(total, sentBytes + loaded)
          it.pct = total > 0 ? Math.round((base / total) * 100) : 0
          it.status = `上传 ${it.pct}%`
          patch(it)
        })
        if (r.status === 200) {
          ok = true
          sentBytes = Math.min(total, sentBytes + blob.size)
        } else if (r.status === 410) {
          // 会话过期（服务重启）：清空重来一次
          it.status = '会话过期，重新开始'
          it.statusKind = 'wait'
          have.clear()
          return await uploadChunked(it)
        } else {
          it.status = '第 ' + (i + 1) + ' 块失败'
          it.statusKind = 'err'
          patch(it)
        }
      } catch {
        report('offline')
        it.status = '网络中断（可重试续传）'
        it.statusKind = 'err'
        patch(it)
      }
    }
    if (!ok) return false
    it.pct = total > 0 ? Math.round((sentBytes / total) * 100) : 100
    patch(it)
  }
  it.status = '手机处理中…'
  it.statusKind = 'wait'
  patch(it)
  try {
    const r = await xhrPost('/up/done', JSON.stringify({ sid, name }))
    if (r.status === 409) {
      // 同名：服务端**未落盘** ⇒ 弹窗让用户决定改名或拒绝
      const j = JSON.parse(r.text) as { existingId?: number }
      const decision = await askConflict(name, Number(j?.existingId ?? -1))
      await xhrPost('/up/abort', JSON.stringify({ sid })).catch(() => undefined)
      if (decision.kind === 'cancel') {
        it.status = '已拒绝（书架未改动）'
        it.statusKind = 'err'
        return false
      }
      // 改名 = 用新名字包一份 File，重新走一遍 init/chunk/done（内容字节不变）
      it.f = new File([it.f], decision.newName, { type: it.f.type })
      it.pct = 0
      it.status = '改名后重传…'
      return await uploadChunked(it)
    }
    if (r.status !== 200) {
      const j = JSON.parse(r.text) as { msg?: string }
      it.status = j?.msg ?? '导入失败'
      it.statusKind = 'err'
      return false
    }
    it.done = true
    it.pct = 100
    it.status = '已入架'
    it.statusKind = 'ok'
    report('ok')
    return true
  } catch {
    report('offline')
    it.status = '提交失败'
    it.statusKind = 'err'
    return false
  }
}

/** 回退路径：旧行为（整文件一次 POST /upload 的 FormData） */
function uploadWhole(it: Picked): Promise<boolean> {
  return new Promise((resolve) => {
    const fd = new FormData()
    fd.append('file', it.f)
    const xhr = new XMLHttpRequest()
    xhr.open('POST', authed('/upload'))
    xhr.upload.onprogress = (e: ProgressEvent): void => {
      if (!e.lengthComputable) return
      it.pct = Math.round((e.loaded / e.total) * 100)
      it.status = '发送 ' + it.pct + '%'
      patch(it)
    }
    xhr.onload = (): void => {
      it.done = true
      try {
        const j = JSON.parse(xhr.responseText) as { ok?: boolean; msg?: string }
        it.status = j.ok === true ? '已入架' : (j.msg ?? '失败')
        it.statusKind = j.ok === true ? 'ok' : 'err'
      } catch {
        it.status = '失败'
        it.statusKind = 'err'
      }
      patch(it)
      resolve(it.statusKind === 'ok')
    }
    xhr.onerror = (): void => {
      it.done = true
      it.status = '失败'
      it.statusKind = 'err'
      patch(it)
      resolve(false)
    }
    xhr.send(fd)
  })
}

async function startUpload(): Promise<void> {
  const btn = $('#up') as HTMLButtonElement
  btn.disabled = true
  const pending = files.filter((x) => !x.done)
  for (const it of pending) {
    it.status = chunkSupported ? '准备中…' : '连接中…'
    it.statusKind = 'wait'
    patch(it)
    if (chunkSupported) {
      const ok = await uploadChunked(it)
      if (!ok && it.status === '初始化失败') {
        // 服务端不支持分块（例如本地 mock）⇒ 本会话内回退旧路径
        it.status = '连接中…'
        patch(it)
        await uploadWhole(it)
      }
    } else {
      await uploadWhole(it)
    }
  }
  btn.disabled = false
  render()
}

function bind(): void {
  const drop = $('#drop')
  const fi = $('#f') as HTMLInputElement
  drop.addEventListener('click', () => fi.click())
  drop.addEventListener('dragover', (e) => {
    e.preventDefault()
    drop.classList.add('on')
  })
  drop.addEventListener('dragleave', () => drop.classList.remove('on'))
  drop.addEventListener('drop', (e) => {
    e.preventDefault()
    drop.classList.remove('on')
    add(e.dataTransfer?.files ?? null)
  })
  fi.addEventListener('change', () => {
    add(fi.files)
    fi.value = ''
  })
  $('#up').addEventListener('click', () => void startUpload())
}

bind()
render()
