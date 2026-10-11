<#
  AI 听书音色数据抓取（官方源，可复现）

  用途：重新抓取各服务商的官方音色清单，写入 tools/voice-data/，
        用于核对内置精选表、以及将来 UI「更多音色」弹窗的数据源。

  用法：
    pwsh -File tools/fetch-voice-data.ps1

  覆盖：
    · 阿里通义 DashScope —— 抓官方音色列表页（HTML 解析）
    · 火山引擎          —— 抓官方文档接口 getDocDetail（Markdown 表格解析）
    · 小米 MiMo         —— 【跳过】官方站为纯前端 SPA，抓不到正文，会打印提示
    · MiniMax           —— 【跳过】有官方 API，由 App 运行时拉取（见 AiVoiceCatalog.ets）
    · OpenAI 兼容       —— 【跳过】音色名极少，直接内置在 AiTtsVoices.ets

  注意：本脚本只做"抓取 + 落盘原始数据"，**不做精选筛选**。
        精选（哪些进代码）是人工决策，见 tools/voice-data/README.md。
#>

$ErrorActionPreference = 'Stop'

$outDir = Join-Path $PSScriptRoot 'voice-data'
$outDir = [System.IO.Path]::GetFullPath($outDir)
New-Item -ItemType Directory -Force -Path $outDir | Out-Null

Write-Host "输出目录: $outDir"
Write-Host ""

# 把 HTML 压成一行纯文本（去 script/style/标签）
function Get-PlainText([string]$html) {
  $t = [regex]::Replace($html, '<script[\s\S]*?</script>', ' ')
  $t = [regex]::Replace($t, '<style[\s\S]*?</style>', ' ')
  $t = [regex]::Replace($t, '<[^>]+>', ' ')
  $t = [System.Net.WebUtility]::HtmlDecode($t)
  return [regex]::Replace($t, '\s+', ' ')
}

# ── 1. 阿里通义 DashScope ───────────────────────────────────────────────────
Write-Host '=== [1/2] 阿里通义 DashScope ===' -ForegroundColor Cyan
$qwenUrl = 'https://help.aliyun.com/zh/model-studio/qwen-tts-voice-list'
$r = Invoke-WebRequest -Uri $qwenUrl -TimeoutSec 30 -SkipHttpErrorCheck
if ($r.StatusCode -ne 200) {
  Write-Host "  ✗ HTTP $($r.StatusCode) —— 抓取失败" -ForegroundColor Red
} else {
  $t = Get-PlainText $r.Content
  $rx = '名称\s*：\s*(.*?)\s*voice\s*参数\s*：\s*(.*?)\s*描述\s*：\s*(.*?)(?=\s*中文（普通话）|\s*名称\s*：|$)'
  $ms = [regex]::Matches($t, $rx)
  $all = @()
  foreach ($m in $ms) {
    $desc = $m.Groups[3].Value.Trim()
    $gender = ''
    if ($desc -match '（女性）') { $gender = 'female' }
    elseif ($desc -match '（男性）') { $gender = 'male' }
    $all += [pscustomobject]@{
      nameZh = $m.Groups[1].Value.Trim()
      id     = $m.Groups[2].Value.Trim()
      desc   = $desc
      gender = $gender
    }
  }
  # 页面含"实时/非实时"两个分节，同一音色会重复出现 ⇒ 去重
  $uniq = $all | Sort-Object id -Unique
  $uniq | ConvertTo-Json -Depth 3 | Set-Content (Join-Path $outDir 'dashscope-voices-full.json') -Encoding utf8
  Write-Host "  ✓ 抓取 $($all.Count) 条，去重后 $($uniq.Count) 条 -> dashscope-voices-full.json" -ForegroundColor Green
}

# ── 2. 火山引擎 ─────────────────────────────────────────────────────────────
Write-Host ''
Write-Host '=== [2/2] 火山引擎（豆包语音合成）===' -ForegroundColor Cyan

# 第一步：把 URL 里的数字 id 换成官方 API 要的 Code
$libId = '6561'
$docId = '1257544'
$codeApi = "https://docs.volcengine.com/api/doc/getDocumentCode?LibraryID=$libId&DocumentID=$docId"
$codeResp = Invoke-WebRequest -Uri $codeApi -TimeoutSec 20 -SkipHttpErrorCheck
$codeJson = $codeResp.Content | ConvertFrom-Json
$libCode = $codeJson.Result.LibraryCode
$docCode = $codeJson.Result.DocumentCode
Write-Host "  LibraryCode=$libCode  DocumentCode=$docCode"

if (-not $libCode -or -not $docCode) {
  Write-Host '  ✗ 未能解析出文档编码 —— 火山侧接口可能已变，请手工核对' -ForegroundColor Red
} else {
  $detailApi = "https://docs.volcengine.com/api/doc/getDocDetail?LibraryCode=$libCode&DocumentCode=$docCode"
  $d = (Invoke-WebRequest -Uri $detailApi -TimeoutSec 30 -SkipHttpErrorCheck).Content | ConvertFrom-Json
  $md = $d.Result.MDContent
  if (-not $md) { $md = $d.Result.Content }
  $md | Set-Content (Join-Path $outDir 'volcengine-voices-official.md') -Encoding utf8
  Write-Host "  ✓ 原始 Markdown ($($md.Length) 字符) -> volcengine-voices-official.md"
  Write-Host "    官方 UpdatedTime: $($d.Result.UpdatedTime)"

  # 解析 Markdown 表格：第 3 列是 voice_type
  $lines = $md -split "`n"
  $curSec = ''
  $rows = @()
  foreach ($l in $lines) {
    $s = $l.Trim()
    if ($s -match '^#{1,3}\s+(.*)$') {
      $curSec = ($matches[1] -replace '\*\*', '' -replace '\\', '').Trim()
      continue
    }
    if (-not $s.StartsWith('|')) { continue }
    $cells = $s.Trim('|') -split '\|'
    if ($cells.Count -lt 4) { continue }
    $type = $cells[2].Trim() -replace '\*\*', ''
    if ($type -match '^-+$' -or $type -eq 'voice_type') { continue }
    if ($type -match '^[a-zA-Z0-9_\-]+$' -and $type.Length -gt 4) {
      $rows += [pscustomobject]@{
        sec   = $curSec
        scene = $cells[0].Trim()
        name  = $cells[1].Trim()
        type  = $type
        lang  = $cells[3].Trim()
      }
    }
  }
  # 情感参数表不是音色，剔除
  $real = $rows | Where-Object { $_.sec -notlike '*情感参数*' }
  $uniq = $real | Sort-Object type -Unique
  $uniq | ConvertTo-Json -Depth 3 | Set-Content (Join-Path $outDir 'volcengine-voices-full.json') -Encoding utf8
  Write-Host "  ✓ 解析 $($rows.Count) 条，剔除情感表后 $($real.Count) 条，去重后 $($uniq.Count) 条 -> volcengine-voices-full.json" -ForegroundColor Green
}

# ── 未覆盖的服务商提示 ──────────────────────────────────────────────────────
Write-Host ''
Write-Host '--- 未抓取的服务商（原因见下）---' -ForegroundColor Yellow
Write-Host '  小米 MiMo : 官方站 platform.xiaomimimo.com 为纯前端 SPA，正文靠 JS 渲染，'
Write-Host '              HTTP 直取只有 18 字节壳页 ⇒ 本脚本跳过。'
Write-Host '  MiniMax   : 有官方列音色接口 /v1/get_voice，由 App 运行时拉取，无需静态抓取。'
Write-Host '  OpenAI兼容: 音色名极少，直接内置在 AiTtsVoices.ets。'
Write-Host ''
Write-Host '完成。' -ForegroundColor Cyan

