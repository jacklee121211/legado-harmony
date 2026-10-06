/**
 * upload.ts —— WiFi 传书页（从旧内嵌页搬迁，行为不变）
 * 点击/拖放选文件 → 列表预览（名/大小/删除）→ XHR 逐文件上传（真实进度条）→ 状态徽章。
 */
import './pages.css'

interface Picked {
  f: File
  done: boolean
}

const files: Picked[] = []

function $(sel: string): HTMLElement {
  const e = document.querySelector(sel)
  if (!e) throw new Error('缺少 DOM 节点: ' + sel)
  return e as HTMLElement
}

function fmt(n: number): string {
  return n > 1048576 ? (n / 1048576).toFixed(1) + ' MB' : (n / 1024).toFixed(0) + ' KB'
}

function render(): void {
  const list = $('#list')
  list.innerHTML = ''
  files.forEach((it) => {
    const d = document.createElement('div')
    d.className = 'it'
    const ext = (it.f.name.split('.').pop() ?? '').toUpperCase().slice(0, 4)
    d.innerHTML =
      `<div class="ico">${ext}</div><div class="meta"><div class="nm"></div>` +
      `<div class="sz">${fmt(it.f.size)}</div><div class="bar"><i></i></div></div>` +
      `<div class="st wait">待传</div><button class="x">✕</button>`
    const nm = d.querySelector('.nm')
    if (nm) nm.textContent = it.f.name
    d.querySelector('.x')?.addEventListener('click', () => {
      const k = files.indexOf(it)
      if (k >= 0) {
        files.splice(k, 1)
        render()
      }
    })
    list.appendChild(d)
  })
  $('#empty').style.display = files.length > 0 ? 'none' : 'block'
  ;($('#up') as HTMLButtonElement).disabled = !files.some((x) => !x.done)
}

function add(fl: FileList | null): void {
  if (!fl) return
  for (let i = 0; i < fl.length; i++) {
    const f = fl.item(i)
    if (f) files.push({ f, done: false })
  }
  render()
}

function statusOf(fileName: string): { st: HTMLElement | null; bar: HTMLElement | null } {
  const rows = Array.from($('#list').children)
  for (const row of rows) {
    const nm = row.querySelector('.nm')
    if (nm && nm.textContent === fileName) {
      return { st: row.querySelector('.st'), bar: row.querySelector('.bar i') }
    }
  }
  return { st: null, bar: null }
}

function uploadOne(it: Picked): Promise<void> {
  return new Promise((resolve) => {
    const { st, bar } = statusOf(it.f.name)
    if (st) {
      st.textContent = '连接中…'
      st.className = 'st wait'
    }
    if (bar) bar.style.width = '0%'
    const fd = new FormData()
    fd.append('file', it.f)
    const xhr = new XMLHttpRequest()
    xhr.open('POST', '/upload')
    xhr.upload.onloadstart = (): void => {
      if (st) st.textContent = '发送 0%'
    }
    xhr.upload.onprogress = (e: ProgressEvent): void => {
      if (!e.lengthComputable) return
      const p = Math.round((e.loaded / e.total) * 100)
      if (bar) bar.style.width = p + '%'
      if (st) st.textContent = '发送 ' + p + '%'
    }
    xhr.upload.onload = (): void => {
      if (bar) bar.style.width = '100%'
      if (st) st.textContent = '手机处理中…'
    }
    xhr.onload = (): void => {
      it.done = true
      if (st) {
        try {
          const j = JSON.parse(xhr.responseText) as { ok?: boolean }
          st.textContent = j.ok === true ? '已入架' : '失败'
          st.className = 'st ' + (j.ok === true ? 'ok' : 'err')
        } catch {
          st.textContent = '失败'
          st.className = 'st err'
        }
      }
      resolve()
    }
    xhr.onerror = (): void => {
      it.done = true
      if (st) {
        st.textContent = '失败'
        st.className = 'st err'
      }
      resolve()
    }
    xhr.send(fd)
  })
}

async function startUpload(): Promise<void> {
  const btn = $('#up') as HTMLButtonElement
  btn.disabled = true
  const pending = files.filter((x) => !x.done)
  for (const it of pending) {
    await uploadOne(it)
  }
  btn.disabled = false
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
