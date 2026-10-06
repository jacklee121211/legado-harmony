/**
 * offline.ts —— 断线 / 未配对的**统一提示条**（2026-10-06 审计后新增）
 *
 * 为什么需要它：旧前端所有 `catch` 都是**静默返回**（`api.ts` 的 `catch {}`、
 * `library.ts` 只提示"读取失败"），所以手机端服务停掉/被系统冻结、或这台电脑
 * 没配对时，电脑上表现为"页面卡着不动、没有任何说明"，用户无法判断该怎么办。
 *
 * 三种状态，一个极简提示条（DOM 动态创建 ⇒ 三个 HTML 模板都不用改）：
 *   · offline   —— 连续 N 次请求失败（手机端可能已关服务/断网/息屏被冻结）
 *   · unauth    —— 服务端返回 401（这台电脑还没配对）
 *   · recovered —— 恢复后自动隐藏
 *
 * 纯 DOM，不依赖框架；所有文本都用 textContent 写入（不拼 HTML）。
 */

export type GuardState = 'ok' | 'offline' | 'unauth'

export const OFFLINE_THRESHOLD = 3

/**
 * **纯状态机**（无 DOM ⇒ 可单测）：把"本次结果 + 当前连续失败数"映射成新状态。
 *
 * 规则：
 *  · 未配对（401）优先级最高，且**立刻**显示（不做连续计数）；
 *  · 网络失败要连续 `threshold` 次才判定 offline（避免一次抖动就弹条）；
 *  · 任何一次成功立刻回到 ok（失败计数清零）。
 */
export function nextState(
  prev: GuardState,
  failures: number,
  now: 'ok' | 'offline' | 'unauth',
  threshold: number = OFFLINE_THRESHOLD
): { state: GuardState; failures: number } {
  if (now === 'unauth') {
    return { state: 'unauth', failures: 0 }
  }
  if (now === 'ok') {
    return { state: 'ok', failures: 0 }
  }
  // ⚠️ 已判定"未配对"时，后续网络失败**不得**把提示改成"已断开"：
  //    用户的真实问题是"没配对"，而不是"断网"（实测单测钉住了这条）。
  if (prev === 'unauth') {
    return { state: 'unauth', failures: failures + 1 }
  }
  const n = failures + 1
  if (n >= threshold) {
    return { state: 'offline', failures: n }
  }
  // 还没到阈值：保持原状态
  return { state: prev, failures: n }
}

let failures = 0
let state: GuardState = 'ok'
let timer: number | null = null
const BANNER_ID = 'mrGuardBanner'

function banner(): HTMLElement {
  let el = document.getElementById(BANNER_ID)
  if (el === null) {
    el = document.createElement('div')
    el.id = BANNER_ID
    el.style.cssText =
      'position:fixed;left:50%;transform:translateX(-50%);top:10px;z-index:9999;' +
      'max-width:88%;padding:10px 16px;border-radius:12px;font-size:13px;line-height:1.5;' +
      'box-shadow:0 6px 24px rgba(0,0,0,.18);display:none;color:#fff;background:#8a8f99;' +
      'font-family:-apple-system,"HarmonyOS Sans SC","PingFang SC","Microsoft YaHei",sans-serif'
    document.body.appendChild(el)
  }
  return el
}

function render(): void {
  const el = banner()
  if (state === 'ok') {
    el.style.display = 'none'
    return
  }
  if (state === 'unauth') {
    el.style.background = '#E0A020'
    el.textContent = '这台电脑还没有配对：请在手机的「Web 服务 · WiFi 传书」里复制完整地址（带配对码）重新打开。'
  } else {
    el.style.background = '#EF4444'
    el.textContent = '与手机断开：手机端可能已关闭 Web 服务、切换了网络或进入省电休眠。恢复后本提示会自动消失。'
  }
  el.style.display = 'block'
}

/** 每次 HTTP 结果都上报一次；自动做"连续失败计数 + 去抖" */
export function report(stateNow: GuardState): void {
  const r = nextState(state, failures, stateNow)
  failures = r.failures
  if (r.state === state) {
    return
  }
  if (r.state === 'offline') {
    // 去抖：避免一次网络抖动就闪提示
    if (timer !== null) window.clearTimeout(timer)
    timer = window.setTimeout(() => {
      timer = null
      if (state !== 'unauth') {
        state = 'offline'
        render()
      }
    }, 600)
    return
  }
  state = r.state
  render()
}

/** 供 UI 查询当前状态（例如决定是否隐藏"手机进度"提示条） */
export function currentState(): GuardState {
  return state
}
