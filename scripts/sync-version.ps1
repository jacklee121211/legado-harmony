<#
  scripts/sync-version.ps1 —— 版本号 + 更新日志的**唯一生成器**
  ============================================================================
  谁是权威：**git 提交备注**。本脚本把它同步到两个地方，再由 `commit-msg` 钩子
  在每次提交时自动执行（并 `git add` 进同一笔提交）⇒ 谁提交都同步，不靠人记得。

  产出：
    ① AppScope/app.json5                       —— versionName / versionCode
    ② entry/src/main/ets/pages/view/myCenter/about/VersionLogData.ets
                                               —— 更新日志数据（新版本在前）

  规则（用户 2026-10-05 定的规范）：
    · **提交首行必须以版本号开头**：`V2.0.2 封面圆角对齐` 或 `2.0.2` 都能解析；
    · 找不到版本号的提交**不进更新日志**（如内部检查点），只在控制台提示；
    · 同一版本号只保留**最新**一条提交，条目做并集 ⇒ 历史里 V2.0.0 的十几次重复
      提交不会把日志刷屏；
    · `versionCode = major*100 + minor*10 + patch`（2.0.0→200，与既有 200 衔接）；
    · **更新日志只展示「当前版本」一条，不保留历史**（2026-10-05 用户定：
      "在更新日志中，不保留历史日志，只展示当前版本日志"）⇒ `-MaxVersions` 默认 **1**；
      同一版本号的多次提交**合并条目**，所以一个版本内的多条改动不会丢。
      哪天真要放历史，把 `-MaxVersions` 调大即可（`-Since` 仍然挡着上游历史）；
    · **上游历史不进更新日志**（2026-10-05 用户定："版本完全以 git commit 首行为标准，上游什么样不管了"）
      —— 上游仓库的 V2.0.5 等版本（2026-09-28 及更早）与我们的版本号序列无关，混在一起会让人看不懂。
      分界点见 `-Since`（默认 2026-10-01 = 本工程自研 V2.0.0 的首个提交日）。

  用法：
    · 手动刷新/回填： pwsh -File scripts/sync-version.ps1
    · 钩子（commit-msg）： pwsh -File scripts/sync-version.ps1 <commit-msg 文件>
      —— 会把"正在提交的这条备注"当作最新一条参与生成（它此时还不在 git log 里）。
#>
param(
  [string]$CommitMsgFile = '',
  [int]$MaxVersions = 1,
  [string]$Since = '2026-10-01'
)

$ErrorActionPreference = 'Stop'

$root = (git rev-parse --show-toplevel).Trim()
if (-not $root) { throw 'not a git repository' }
$appJson   = Join-Path $root 'AppScope/app.json5'
$dataFile  = Join-Path $root 'entry/src/main/ets/pages/view/myCenter/about/VersionLogData.ets'

# ── 1. 取所有提交（新→旧）──────────────────────────────────────────────────
$SEP_FIELD = [char]0x1f
$SEP_REC   = [char]0x1e
$raw = git -C $root log --date=short --pretty=format:"%H$SEP_FIELD%ad$SEP_FIELD%s$SEP_FIELD%b$SEP_REC"
$records = @()
foreach ($chunk in ($raw -split $SEP_REC)) {
  $c = $chunk.Trim("`r", "`n", $SEP_REC)
  if ($c -eq '') { continue }
  $f = $c -split $SEP_FIELD
  if ($f.Count -lt 4) { continue }
  $records += [pscustomobject]@{ hash = $f[0]; date = $f[1]; subject = $f[2]; body = $f[3] }
}

# 正在提交的那条排最前（若有）：它就是"最新版本"的来源
if ($CommitMsgFile -ne '' -and (Test-Path $CommitMsgFile)) {
  $msgText = Get-Content $CommitMsgFile -Raw
  # 去掉 git 默认的注释行（以 # 开头）
  $lines = ($msgText -split "`r?`n") | Where-Object { $_ -notmatch '^\s*#' }
  $msgText = ($lines -join "`n").Trim()
  if ($msgText -ne '') {
    $subj = ($msgText -split "`r?`n")[0]
    $bdy  = (($msgText -split "`r?`n") | Select-Object -Skip 1) -join "`n"
    $records = ,([pscustomobject]@{ hash = 'PENDING'; date = (Get-Date -Format 'yyyy-MM-dd'); subject = $subj; body = $bdy }) + $records
  }
}

# ── 2. 解析每条提交 → 版本 / 标题 / 条目 ────────────────────────────────────
function Strip-Number([string]$s) {
  return ($s -replace '^\s*\d+\s*[\.、\)]\s*', '').Trim()
}
$byVersion = [ordered]@{}          # version → @{ date; title; items=List }
$skipped = 0
$skippedUpstream = 0
foreach ($r in $records) {
  # 上游历史（早于 $Since）不进更新日志 —— 它们的版本号序列与我们无关
  if ($Since -ne '' -and $r.hash -ne 'PENDING' -and $r.date -lt $Since) { $skippedUpstream++; continue }
  $m = [regex]::Match($r.subject, '(\d+\.\d+\.\d+)')
  if (-not $m.Success) { $skipped++; continue }          # 无版本号 ⇒ 不进日志
  $ver = "V$($m.Groups[1].Value)"
  $rest = $r.subject.Substring($m.Index + $m.Length).Trim()

  # 标题 = 版本号之后、第一个编号条目之前的那段（旧格式）；没有编号则整段都是标题（新格式）
  $title = ''
  $mm = [regex]::Match($rest, '^(.*?)\s*(?=\d+\s*[\.、\)])')
  if ($mm.Success) {
    # ⚠️ 匹配成功但捕获组为空 = "版本号后面直接就是条目"（如 `V2.0.1 1.UI全面优化…`）
    #    ⇒ 标题为空，**不能**把整段当标题（否则 version 字段会塞进整篇变更列表）
    $t = $mm.Groups[1].Value.Trim()
    if ($t -ne '') { $title = $t }
    $rest = $rest.Substring($mm.Length)
  } else {
    $title = $rest
    $rest  = ''
  }

  $items = New-Object System.Collections.Generic.List[string]
  # 分隔符：分号/换行；另加"空格 + 编号 + ."这种漏了分号的写法（如 `…排布 9.增加本地TTS方案`）
  # ⚠️ 只认"编号后面跟非数字"，避免把条目里的版本号（`鸿蒙7.0沉浸式`）切开
  foreach ($piece in (($rest + ';' + $r.body) -split '[;；\n\r]|\s+(?=\d+\s*[\.、\)]\s*\D)')) {
    $t = Strip-Number $piece
    if ($t -ne '' -and -not $items.Contains($t)) { $items.Add($t) }
  }

  if ($byVersion.Contains($ver)) {
    $e = $byVersion[$ver]
    foreach ($it in $items) { if (-not $e.items.Contains($it)) { $e.items.Add($it) } }
    if ($e.title -eq '' -and $title -ne '') { $e.title = $title }
  } else {
    $byVersion[$ver] = [pscustomobject]@{ date = $r.date; title = $title; items = $items }
  }
}

# ── 3. 生成 VersionLogData.ets ─────────────────────────────────────────────
function Esc-Ats([string]$s) {
  return ($s -replace '\\', '\\\\') -replace "'", "\'"
}
$sb = New-Object System.Text.StringBuilder
[void]$sb.AppendLine('/**')
[void]$sb.AppendLine(' * ⚠️ 本文件由 `scripts/sync-version.ps1` **自动生成**（git `commit-msg` 钩子每次提交都会刷新）。')
[void]$sb.AppendLine(' * 请勿手改 —— 要改内容就改提交备注（首行必须以版本号开头，见脚本头注释）。')
[void]$sb.AppendLine(' */')
[void]$sb.AppendLine('')
[void]$sb.AppendLine('/** 一条版本记录（更新日志的一行卡片） */')
[void]$sb.AppendLine('export interface VersionEntry {')
[void]$sb.AppendLine('  /** 形如 `V2.0.2 封面圆角对齐` */')
[void]$sb.AppendLine('  version: string')
[void]$sb.AppendLine('  /** 提交日期 yyyy-MM-dd（空串 = 不显示） */')
[void]$sb.AppendLine('  date: string')
[void]$sb.AppendLine('  /** 该版本的变更条目 */')
[void]$sb.AppendLine('  items: string[]')
[void]$sb.AppendLine('}')
[void]$sb.AppendLine('')
$newest = ($byVersion.Keys | Select-Object -First 1)
[void]$sb.AppendLine("/** 读不到 bundle 信息时的兜底版本号（与 app.json5 同源） */")
[void]$sb.AppendLine("export const APP_VERSION_FALLBACK: string = 'V$(([regex]::Match($newest, '\d+\.\d+\.\d+')).Value)'")
[void]$sb.AppendLine('')
[void]$sb.AppendLine('/** 更新日志（默认只含**当前版本**一条；-MaxVersions 调大才有多条历史） */')
[void]$sb.AppendLine('export const VERSION_LOGS: VersionEntry[] = [')
$n = 0
foreach ($ver in $byVersion.Keys) {
  if ($n -ge $MaxVersions) { break }
  $e = $byVersion[$ver]
  $v = $ver
  if ($e.title -ne '') { $v = "$ver $($e.title)" }
  [void]$sb.AppendLine('  {')
  [void]$sb.AppendLine("    version: '$(Esc-Ats $v)',")
  [void]$sb.AppendLine("    date: '$($e.date)',")
  [void]$sb.AppendLine('    items: [')
  foreach ($it in $e.items) { [void]$sb.AppendLine("      '$(Esc-Ats $it)',") }
  [void]$sb.AppendLine('    ]')
  [void]$sb.AppendLine('  },')
  $n++
}
[void]$sb.AppendLine(']')
[void]$sb.AppendLine('')
[System.IO.File]::WriteAllText($dataFile, $sb.ToString(), (New-Object System.Text.UTF8Encoding($false)))

# ── 4. 同步 AppScope/app.json5 ─────────────────────────────────────────────
$verNums = [regex]::Match($newest, '\d+\.\d+\.\d+').Value
if ($verNums -ne '') {
  $p = $verNums.Split('.')
  $code = [int]$p[0] * 100 + [int]$p[1] * 10 + [int]$p[2]
  $json = [System.IO.File]::ReadAllText($appJson)
  $json = [regex]::Replace($json, '("versionCode"\s*:\s*)\d+', "`${1}$code")
  $json = [regex]::Replace($json, '("versionName"\s*:\s*")[^"]*(")', "`${1}$verNums`${2}")
  [System.IO.File]::WriteAllText($appJson, $json, (New-Object System.Text.UTF8Encoding($false)))
  Write-Host "[sync-version] versionName=$verNums versionCode=$code ; 更新日志 $n 个版本（跳过 $skipped 条无版本号提交、$skippedUpstream 条上游历史）"
} else {
  Write-Host "[sync-version] 未找到版本号，未改 app.json5；更新日志 $n 个版本（跳过 $skipped 条、上游 $skippedUpstream 条）"
}

# ── 5. 钩子模式：把产物并入本次提交 ────────────────────────────────────────
if ($CommitMsgFile -ne '' -and $env:SYNC_VERSION_NO_ADD -ne '1') {
  git -C $root add -- 'AppScope/app.json5' 'entry/src/main/ets/pages/view/myCenter/about/VersionLogData.ets' | Out-Null
}
