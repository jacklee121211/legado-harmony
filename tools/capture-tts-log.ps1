# 听书日志捕获：流式抓文本，**不限时长**（替代 deveco log 的 4MB 窗口）
#
# 为什么要这个：
#   · `deveco log` / DevEco Log 窗口有 4MB 上限 —— 实测长测只留最后 ~10 分钟
#     （`Downloads/2.md` 3.99MB = 9 分 52 秒，而进程已经活了 8777 秒）；
#   · 设备端 /data/log/hilog/*.gz 是 hilog **二进制**持久化格式（实测首字节
#     1F 8B 08 = gzip 合法，但解出来是 hilog 内部记录流，**无法当文本读**）；
#   · 本脚本用 `hdc shell hilog` **实时流式**输出，是标准文本行，
#     只在设备端按 tag 过滤（不是把全量日志搬回 PC 再筛），所以可以抓几小时。
#
# 用法：
#   .\tools\capture-tts-log.ps1                     # 默认抓到 .\logs\tts-*.log，Ctrl+C 停
#   .\tools\capture-tts-log.ps1 -Minutes 180        # 抓 3 小时后自动停
#   .\tools\capture-tts-log.ps1 -Full              # 抓全量（不加 tag 过滤，用于排查别的模块）
#
# 建议：**开始听书前就先跑起来**，然后锁屏睡觉。醒来 Ctrl+C。
# 抓完把文件名（含时间）告我，我按需分析 —— 不需要你手动截取。
#
# ⚠️ 一个已实测的行为（别被吓到）：`hilog` 不带 `-x` 时，会**先把设备上持久化的
#    历史日志回放一遍**，所以文件开头的行可能是几天前的（实测对照组第一行是
#    `09-25 03:38:17`）。这**不是**抓错了，是设备 logd 的缓冲回放；
#    每行自带时间戳，按时间戳取你关心的那段即可，不用管前面的旧行。
#    实测 `-x`（只 dump 缓冲不跟随）在只筛我们 tag 时只有 4 行 —— 说明历史已滚出，
#    所以长测必须**边听边抓**，事后是捞不回来的（设备上的 .gz 归档是二进制格式，
#    实测无法解码成文本）。

param(
  [int]$Minutes = 0,          # 0 = 一直抓，直到 Ctrl+C
  [string]$Out = '',
  [string]$Device = '',
  [switch]$Full,              # 全量日志（默认只抓 TTS 相关 + 卡顿/冻结）
  [int]$SplitMB = 64          # 单文件到该大小就滚动，避免一个文件过大
)

$ErrorActionPreference = 'Stop'

# ── 1. hdc：必须 DevEco 自带的 3.x（PATH 里的 1.2.0a 握手失败）──────────────
$hdc = @(
  'D:\Program Files\Huawei\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe',
  'D:\Program Files\Huawei\DevEco Studio\tools\hdc\hdc.exe'
) | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $hdc) { throw '未找到 DevEco 自带 hdc.exe，请改本脚本路径' }

if (-not $Device) {
  $t = & $hdc list targets 2>&1 | Where-Object { $_ -and $_ -notmatch 'Empty' }
  if (-not $t) { throw '没有已连接设备' }
  $Device = @($t)[0].Trim()
}

# ── 2. 输出文件 ─────────────────────────────────────────────────────────────
if (-not $Out) {
  $dir = Join-Path $PWD 'logs'
  New-Item -ItemType Directory -Force -Path $dir | Out-Null
  $Out = Join-Path $dir ("tts-" + (Get-Date -Format 'yyyyMMdd-HHmmss') + ".log")
}

# ── 3. 构建设备端过滤参数 ───────────────────────────────────────────────────
# 只抓和我们有关的东西，设备端就筛掉，网络传输量极小：
#   TtsEngine / PcmPlayer / EdgeTts / ttsdec  —— 应用自身
#   XCollie    —— 卡顿/冻结（C02D06）
#   AppDfr     —— AppFreeze（C01310）
#   AudioLogUtils —— 音频服务静音分类（C02B82，判断垫片是否被判 slient）
# ⚠️⚠️ 实测硬限制：`hilog -T` 的 tag **最多 10 个**，超了整个命令直接失败，
#   只回一行 `Max tag count is 10 [CODE: -42]`，**文件会是 0 字节**。
#   （2026-10-09 踩过：我一次写到 15 个，抓取全程 0 行，白跑一轮。）
# ⇒ 这里固定 ≤10 个。要换组合请改下面这一行，**并且数一下别超 10**。
#
# 默认组合（阅读器 / 书架听书 dock 排查用）：
#   testTag            阅读器全部行为打点（locate / imm: / LTBOOK / reader: / pageShow）
#   TtsEngine          听书引擎状态机（chapter / splice / bg task）
#   listen             书架听书启动器（start from spine=…）
#   JSAPP              前端 console.info（LISTENDOCK 迷你栏折叠展开）
#   bookparser         ReaderKit 解析器（Open book / getContent / release）
#   ReadPageComponent  阅读组件（registerBookParser / startPlay 被拒 / pageShow）
#   ReaderKitManager   releaseBook 生命周期
#   WindowAbility      freezeTopRect / restoreTopRect（一镜到底几何依赖的避让值）
#   NightMode          配色切换时序
#   XCollie            卡顿 / 冻结
# 音频类（PcmPlayer / EdgeTts / ttsdec / AppDfr / AudioLogUtils）没位置了，
# 需要时替换掉上面几个不用的（一次仍不许超 10）。
$readerTags = 'testTag,TtsEngine,listen,JSAPP,bookparser,ReadPageComponent,ReaderKitManager,WindowAbility,NightMode,XCollie'
$hilogArgs = if ($Full) {
  'hilog'
} else {
  "hilog -T $readerTags"
}

Write-Host "hdc    : $hdc"
Write-Host "device : $Device"
Write-Host "filter : $hilogArgs"
Write-Host "out    : $Out"
if ($Minutes -gt 0) { Write-Host "时长   : $Minutes 分钟" } else { Write-Host "时长   : 一直抓（Ctrl+C 停止）" }
Write-Host ""
Write-Host ">>> 现在去听书 / 锁屏。抓完按 Ctrl+C。"
Write-Host ""

# ── 4. 流式抓取（按大小滚动）───────────────────────────────────────────────
$deadline = if ($Minutes -gt 0) { (Get-Date).AddMinutes($Minutes) } else { [datetime]::MaxValue }
$splitBytes = $SplitMB * 1MB
$fileIndex = 0
$currentPath = $Out
$sw = New-Object System.IO.StreamWriter($currentPath, $false, [System.Text.UTF8Encoding]::new($false))
$sw.AutoFlush = $true
$lineCount = 0

# hdc shell 的长驻进程：用 Start-Process 重定向会更稳，但这里直接读 stdout 管道
$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = $hdc
$psi.Arguments = "-t `"$Device`" shell `"$hilogArgs`""
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError = $true
$psi.UseShellExecute = $false
$proc = [System.Diagnostics.Process]::Start($psi)

# PC 侧二次过滤：只留本应用（com.jk.reader）的行。
# 设备端 tag 过滤是「全局 tag」（如 XCollie 每个系统进程都会打），不过滤包名的话
# 长测文件里 90% 是别的进程。这里保留：
#   · 含 "com.jk.reader" 的行（应用自身的 TtsEngine/PcmPlayer/EdgeTts/ttsdec
#     以及属于本进程的 XCollie/AppDfr/AudioLogUtils）
#   · 含 'freeze' / 'THREAD_BLOCK' / 'APPFREEZE' 的行（冻结报告即使包名被截断也留）
$keepPattern = 'com\.jk\.reader|freeze|THREAD_BLOCK|APPFREEZE|MAIN_THREAD_JANK'
$dropped = 0

try {
  while (-not $proc.StandardOutput.EndOfStream) {
    if ((Get-Date) -gt $deadline) { Write-Host "`n到时停止。"; break }
    $line = $proc.StandardOutput.ReadLine()
    if ($null -eq $line) { break }
    if ($Full -or ($line -match $keepPattern)) {
      $sw.WriteLine($line)
      $lineCount++
    } else {
      $dropped++
    }
    if (($sw.BaseStream.Length) -gt $splitBytes) {
      $sw.Close()
      $fileIndex++
      $currentPath = [System.IO.Path]::ChangeExtension($Out, $null) + ".$fileIndex.log"
      $sw = New-Object System.IO.StreamWriter($currentPath, $false, [System.Text.UTF8Encoding]::new($false))
      $sw.AutoFlush = $true
      Write-Host "滚动到新文件: $currentPath"
    }
  }
} finally {
  try { $sw.Close() } catch {}
  try { if (-not $proc.HasExited) { $proc.Kill() } } catch {}
}

Write-Host ""
Write-Host "完成：保留 $lineCount 行，丢弃 $dropped 行（非本应用）"
Write-Host "文件：$Out" + $(if ($fileIndex -gt 0) { " （+ $fileIndex 个滚动文件）" } else { "" })
