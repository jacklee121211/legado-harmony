# 提交前护栏：检测"源文件被截断"（近期多次发生，见 docs/阅读器跨设备参数实测-2026-11-01.md 第 6 节事故记录）
# 规则：任何已跟踪的 .ets/.ts 文件，若本次暂存内容**少于 HEAD 版本行数的 80%**，判定为疑似截断。
# 用法：pwsh -File scripts/check-file-truncation.ps1        （退出码 1 = 发现疑似截断）
$ErrorActionPreference = 'Stop'
$root = git rev-parse --show-toplevel
Set-Location $root
$staged = git diff --cached --name-only --diff-filter=AM | Where-Object { $_ -match '\.(ets|ts)$' }
$bad = @()
foreach ($f in $staged) {
  $headLines = 0
  try { $headLines = (git show "HEAD:$f" 2>$null | Measure-Object -Line).Lines } catch { $headLines = 0 }
  if ($headLines -lt 100) { continue }
  $stagedText = git show ":$f" 2>$null
  $stagedLines = ($stagedText | Measure-Object -Line).Lines
  $ratio = [math]::Round($stagedLines / $headLines, 3)
  if ($ratio -lt 0.8) { $bad += "$f  行数 $headLines → $stagedLines（保留 $([math]::Round($ratio*100))%）" }
}
if ($bad.Count -gt 0) {
  Write-Host "❌ 疑似文件截断，已阻断提交：" -ForegroundColor Red
  $bad | ForEach-Object { Write-Host "   $_" }
  Write-Host "如需确认无误，请用 git commit --no-verify。" -ForegroundColor Yellow
  exit 1
}
Write-Host "✅ 未发现文件截断"
exit 0