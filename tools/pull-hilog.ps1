# 从设备拉取 hilog 归档（不受 4MB 抓取窗口限制）
#
# 背景：`deveco log` / DevEco Log 窗口有 4MB 上限，长测只能留最后 ~10 分钟。
# 设备端 /data/log/hilog 是分文件 gz 归档（实测 1.0GB / 1203 个文件 / 覆盖约 1 天），
# 用 hdc file recv 直接拉，想拉多久拉多久。
#
# 用法：
#   .\tools\pull-hilog.ps1                       # 拉最近 90 分钟
#   .\tools\pull-hilog.ps1 -Minutes 240          # 拉最近 4 小时
#   .\tools\pull-hilog.ps1 -Since 16:00          # 拉今天 16:00 之后的
#   .\tools\pull-hilog.ps1 -Out D:\logs\tts      # 指定输出目录
#
# 拉完怎么解压：
#   Get-ChildItem <输出目录>\*.gz | ForEach-Object { tar -xzf $_.FullName -C $_.DirectoryName }
# （Windows 10+ 自带 tar，支持 gz）

param(
  [int]$Minutes = 90,
  [string]$Since = '',
  [string]$Out = '',
  [string]$Device = ''
)

$ErrorActionPreference = 'Stop'

# ── 1. 定位 hdc（必须用 DevEco 自带的 3.x，PATH 里的旧版 1.2.0a 会握手失败）──
$hdcCandidates = @(
  'D:\Program Files\Huawei\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe',
  'D:\Program Files\Huawei\DevEco Studio\tools\hdc\hdc.exe'
)
$hdc = $hdcCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $hdc) { throw "未找到 DevEco 自带的 hdc.exe，请手动修改本脚本的路径" }

# ── 2. 选设备 ───────────────────────────────────────────────────────────────
if (-not $Device) {
  $targets = & $hdc list targets 2>&1 | Where-Object { $_ -and $_ -notmatch 'Empty' }
  if (-not $targets) { throw "没有已连接设备（hdc list targets 为空）" }
  $Device = @($targets)[0].Trim()
}
Write-Host "hdc    : $hdc"
Write-Host "device : $Device"

# ── 3. 输出目录 ─────────────────────────────────────────────────────────────
if (-not $Out) {
  $Out = Join-Path $PWD ("logs\hilog_" + (Get-Date -Format 'yyyyMMdd_HHmmss'))
}
New-Item -ItemType Directory -Force -Path $Out | Out-Null
Write-Host "out    : $Out"

# ── 4. 列设备上的归档文件，按文件名里的时间戳筛选 ────────────────────────────
# 文件名形如 hilog.468.20260929-160358.gz  ⇒ 时间戳 20260929-160358
$today = Get-Date -Format 'yyyyMMdd'
$listRaw = & $hdc -t $Device shell "ls /data/log/hilog" 2>&1

$cut = $null
if ($Since) {
  $cut = [datetime]::ParseExact("$today $Since", 'yyyyMMdd HH:mm', $null)
} else {
  $cut = (Get-Date).AddMinutes(-$Minutes)
}

$files = @()
foreach ($line in $listRaw) {
  $name = "$line".Trim()
  if ($name -notmatch '^hilog\.\d+\.(\d{8})-(\d{6})\.gz$') { continue }   # 跳过 hilog_kmsg.*
  $stamp = [datetime]::ParseExact($matches[1] + $matches[2], 'yyyyMMddHHmmss', $null)
  if ($stamp -ge $cut) { $files += [pscustomobject]@{ Name = $name; Time = $stamp } }
}
$files = $files | Sort-Object Time

if ($files.Count -eq 0) {
  Write-Warning "该时间范围内没有归档文件（设备只保留约 1 天）。可加大 -Minutes。"
  exit 1
}

Write-Host ("待拉取 : {0} 个文件，{1} → {2}" -f $files.Count,
  $files[0].Time.ToString('MM-dd HH:mm:ss'), $files[-1].Time.ToString('MM-dd HH:mm:ss'))

# ── 5. 逐个 file recv（远程路径用引号包住，避免 shell 解析）────────────────
$ok = 0; $fail = 0
foreach ($f in $files) {
  $remote = "/data/log/hilog/$($f.Name)"
  $local = Join-Path $Out $f.Name
  & $hdc -t $Device file recv $remote $local 2>&1 | Out-Null
  if (Test-Path $local) {
    $ok++
  } else {
    $fail++
    Write-Warning "拉取失败: $($f.Name)"
  }
}

Write-Host ""
Write-Host "完成: 成功 $ok 个，失败 $fail 个"
Write-Host "下一步解压:"
Write-Host ("  Get-ChildItem '{0}\*.gz' | ForEach-Object {{ tar -xzf `$_.FullName -C `$_.DirectoryName }}" -f $Out)
Write-Host ""
Write-Host "解压后在文本里搜这几个 tag 定位听书问题:"
Write-Host "  TtsEngine / PcmPlayer / EdgeTts / ttsdec        (应用自身)"
Write-Host "  C02D06 (XCollie 卡顿) / C01310 (AppDfr 冻结) / C02B82 (音频静音分类)"
