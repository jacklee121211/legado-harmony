# measure-power-all.ps1 —— 三场景引导式功耗测量（一条命令跑完）
#
# 为什么这样设计：每次测量前手机状态不同，脚本会**停下来提示你怎么做**，
# 你照着做、按回车，它就继续。全程不需要你敲别的命令。
#
# 运行：
#   pwsh -ExecutionPolicy Bypass -File tools\measure-power-all.ps1
#
# 数据来源：hdc shell "hidumper -s BatteryService -a -i"
#
# 测前请务必：
#   1) 拔掉 USB 数据线（脚本会自动检查，插着线读数会被充电电流污染）
#   2) 关掉"自动亮度"，手动固定在同一档
#   3) 全程用同一个网络（都 Wi-Fi 或都数据）

param(
  [int]$DurationA = 60,   # 场景A 亮屏·待机（秒）→ 30 个样本
  [int]$DurationE = 60,   # 场景E 亮屏·阅读（秒）→ 30 个样本
  [int]$DurationB = 60,   # 场景B 亮屏·听书（秒）→ 30 个样本
  [int]$DurationC = 120,  # 场景C 熄屏·听书 @细间隔（秒）→ 60 个样本
  [int]$DurationC2 = 160, # 场景C2 熄屏·听书 @粗间隔（秒）→ 20 个样本
  [int]$DurationC0 = 180, # 场景C0 熄屏·听书·缓存重播（零网络，秒）→ 90 个样本
  [int]$DurationD = 120,  # 场景D 熄屏·待机（秒）→ 60 个样本
  [int]$DurationR = 180,  # 场景R 熄屏·听书【系统「阅读」App 参照】(秒) → 90 个样本
  [int]$IntervalSec = 2,  # 常规采样间隔（秒）
  [int]$IntervalC2 = 8,   # 场景C2 熄屏·听书 @粗间隔（秒）—— 用于量化"测量行为本身带来的开销"
  [int]$PlausibleMax = 1500, # 放电电流合理性上限(mA)。超过即视为充电/校准异常样本并剔除
  [string[]]$Only = @()   # 只跑指定场景，如 -Only C0,C ；留空=全部跑
)

$ErrorActionPreference = 'Continue'
$hdcCandidates = @(
  "D:\Program Files\Huawei\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe",
  "C:\Users\Administrator\AppData\Local\Huawei\Sdk\openharmony\9\toolchains\hdc.exe"
)
$hdc = ($hdcCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1)
if (-not $hdc) { $hdc = "hdc" }

function Get-Battery {
  $o = & $hdc shell "hidumper -s BatteryService -a -i" 2>&1
  $s = ($o | Out-String)
  if ($s -notmatch 'nowCurrent') { return $null }
  return [pscustomobject]@{
    Now  = [int][regex]::Match($s, 'nowCurrent: (-?\d+)').Groups[1].Value
    Avg  = [int][regex]::Match($s, 'currentAverage: (-?\d+)').Groups[1].Value
    Temp = [int][regex]::Match($s, 'temperature: (\d+)').Groups[1].Value
    Volt = [int][regex]::Match($s, 'voltage: (\d+)').Groups[1].Value
    Cap  = [int][regex]::Match($s, 'capacity: (\d+)').Groups[1].Value
    Chg  = [int][regex]::Match($s, 'chargingStatus: (\d+)').Groups[1].Value
    Plug = [int][regex]::Match($s, 'pluggedType: (\d+)').Groups[1].Value
  }
}

function Get-Brightness {
  $s = (& $hdc shell "hidumper -s DisplayPowerManagerService" 2>&1 | Out-String)
  $m = [regex]::Match($s, 'Brightness=(\d+)')
  if ($m.Success) { return $m.Groups[1].Value }
  return '?'
}

$results = [ordered]@{}

# ---- 规范化 -Only：`pwsh -File x.ps1 -Only C,C0` 会把 "C,C0" 作为**单个字符串**传入，
#      `[string[]]` 绑定后得到 @('C,C0') 而不是 @('C','C0')，导致一个都匹配不上、静默跳过全部场景。
#      这里手工按逗号拆开，两种写法都支持：-Only C,C0  与  -Only C -Only C0
$onlyList = @()
foreach ($o in $Only) {
  foreach ($p in ([string]$o -split ',')) {
    $t = $p.Trim()
    if ($t.Length -gt 0) { $onlyList += $t.ToUpperInvariant() }
  }
}

# 场景过滤器：$Only 为空则全部跑；否则只跑列出的场景（如 -Only C,C0）
function Maybe-Scenario {
  param([string]$Key, [string]$Title, [string[]]$Steps, [int]$Seconds, [int]$Interval = $IntervalSec)
  if ($onlyList.Count -gt 0 -and -not ($onlyList -contains $Key.ToUpperInvariant())) {
    Write-Host "  [跳过] 场景 $Key（-Only 未选中）" -ForegroundColor DarkGray
    return
  }
  Invoke-Scenario -Key $Key -Title $Title -Steps $Steps -Seconds $Seconds -Interval $Interval
}

function Invoke-Scenario {
  param([string]$Key, [string]$Title, [string[]]$Steps, [int]$Seconds, [int]$Interval = $IntervalSec)

  Write-Host ""
  Write-Host ("=" * 68) -ForegroundColor Cyan
  Write-Host "  场景 $Key ：$Title" -ForegroundColor Cyan
  Write-Host ("=" * 68) -ForegroundColor Cyan
  foreach ($s in $Steps) { Write-Host "  $s" }
  Write-Host ""
  Read-Host "  按【回车】开始测量（$Seconds 秒 / 每 $Interval 秒采一次）" | Out-Null

  $b0 = Get-Battery
  if ($null -eq $b0) {
    Write-Host "  [错误] 读不到设备数据，请确认手机已连接（hdc list targets）" -ForegroundColor Red
    $results[$Key] = $null
    return
  }
  if ($b0.Chg -ne 0 -or $b0.Plug -ne 0) {
    Write-Host "  [警告] 正在充电（chargingStatus=$($b0.Chg) pluggedType=$($b0.Plug)），读数不准，建议拔线重测。" -ForegroundColor Yellow
  }
  $br = Get-Brightness
  Write-Host "  起始：电量 $($b0.Cap)%  电压 $([math]::Round($b0.Volt/1000000,3))V  温度 $([math]::Round($b0.Temp/10,1))C  亮度 $br"
  Write-Host ""

  $samples = @()
  $n = [math]::Max(1, [math]::Floor($Seconds / $Interval))
  for ($i = 1; $i -le $n; $i++) {
    $b = Get-Battery
    if ($null -ne $b) {
      $samples += $b
      $flag = ''
      if ([math]::Abs($b.Now) -gt $PlausibleMax) { $flag = '  <== 不合理，疑为充电/校准，已剔除' }
      elseif ($b.Avg -gt 0) { $flag = '  <== 系统均流为正=正在充电' }
      Write-Host ("    [{0,3}/{1}] now={2,5}mA  avg={3,5}mA  temp={4}C  cap={5}%{6}" -f `
        $i, $n, $b.Now, $b.Avg, [math]::Round($b.Temp/10,1), $b.Cap, $flag)
    } else {
      Write-Host "    [$i/$n] 设备无响应（可能熄屏后 Wi-Fi 断开）" -ForegroundColor Yellow
    }
    if ($i -lt $n) { Start-Sleep -Seconds $Interval }
  }

  if ($samples.Count -eq 0) { $results[$Key] = $null; return }

  # ---- 合理性过滤：放电电流不该超过 PlausibleMax；且系统均流为正说明在充电 ----
  $usable   = @($samples | Where-Object { [math]::Abs($_.Now) -le $PlausibleMax -and $_.Avg -le 0 })
  $excluded = $samples.Count - $usable.Count
  if ($excluded -gt 0) {
    Write-Host ("  [已剔除 {0}/{1} 个不合理样本]" -f $excluded, $samples.Count) -ForegroundColor Yellow
  }
  if ($usable.Count -lt 5) {
    Write-Host "  [警告] 有效样本不足 5 个，本场景结果不可用，请重测。" -ForegroundColor Red
    $results[$Key] = $null
    return
  }
  $samples = $usable

  $avgArr = $samples | ForEach-Object { [math]::Abs($_.Avg) }
  $nowArr = $samples | ForEach-Object { [math]::Abs($_.Now) }
  $results[$Key] = [pscustomobject]@{
    Label   = $Title
    # 主指标：中位数。`nowCurrent` 是瞬时值，偶发尖峰（实测见过 1593mA）会把均值抬高几十 mA，
    # 中位数对尖峰免疫；同时给出「去极值均值」（去掉最大/最小各 2 个）作为对照。
    Median  = ($nowArr | Sort-Object)[[int]($nowArr.Count / 2)]
    TrimMean = if ($nowArr.Count -ge 6) {
                 (($nowArr | Sort-Object)[2..($nowArr.Count - 3)] | Measure-Object -Average).Average
               } else { ($nowArr | Measure-Object -Average).Average }
    AvgMean = ($avgArr | Measure-Object -Average).Average
    AvgStart = [math]::Abs($samples[0].Avg)
    AvgEnd   = [math]::Abs($samples[-1].Avg)
    NowMean = ($nowArr | Measure-Object -Average).Average
    NowMin  = ($nowArr | Measure-Object -Minimum).Minimum
    NowMax  = ($nowArr | Measure-Object -Maximum).Maximum
    TempA   = [math]::Round($samples[0].Temp / 10.0, 1)
    TempB   = [math]::Round($samples[-1].Temp / 10.0, 1)
    CapA    = $samples[0].Cap
    CapB    = $samples[-1].Cap
    Volt    = $samples[-1].Volt / 1000000.0
    N       = $samples.Count
  }
}

Write-Host ""
Write-Host "################  听书功耗测量（多场景引导）  ################" -ForegroundColor Green
Write-Host ""
Write-Host "测前确认三件事（不一致的话数字不可比）："
Write-Host "  1) 手机已拔掉 USB 线"
Write-Host "  2) 已关闭自动亮度，亮度固定在同一档"
Write-Host "  3) 全程同一个网络（都 Wi-Fi 或都数据）"
Write-Host ""
Read-Host "准备好了按【回车】开始" | Out-Null

Maybe-Scenario -Key 'A' -Title '亮屏 · 待机（不播放）' -Seconds $DurationA -Steps @(
  '手机保持亮屏，停在书架页，【不要播放听书】',
  '（这是"亮屏什么都不做"的基线）'
)

Maybe-Scenario -Key 'E' -Title '亮屏 · 阅读（不播放）' -Seconds $DurationE -Steps @(
  '进入书籍，进入阅读页',
  '【不要播放听书】，你就像平时一样手动翻页看书',
  '（这是你亮屏时的主力场景，用来量"看书本身"花多少）'
)

Maybe-Scenario -Key 'B' -Title '亮屏 · 听书' -Seconds $DurationB -Steps @(
  '保持阅读页，点【开始听书】',
  '让屏幕保持亮着（不要让它自动熄灭）'
)

Maybe-Scenario -Key 'C' -Title '熄屏 · 听书（细间隔采样）' -Seconds $DurationC -Steps @(
  '保持听书在播',
  '按【电源键】熄屏，等 10 秒',
  '（若熄屏后 Wi-Fi 断开，脚本会显示"设备无响应"，属正常）'
)

Maybe-Scenario -Key 'C2' -Title "熄屏 · 听书（粗间隔采样 ${IntervalC2}s）" -Seconds $DurationC2 -Interval $IntervalC2 -Steps @(
  '【什么都不用改】—— 保持熄屏、保持听书在播',
  "这一轮只是把采样间隔拉长到 ${IntervalC2} 秒，用来判断我的采样本身有没有干扰读数",
  '（若 C2 明显低于 C，说明测量行为确实抬高了读数，真实功耗更好）'
)

Maybe-Scenario -Key 'C0' -Title '熄屏 · 听书【零网络·缓存重播】' -Seconds $DurationC0 -Steps @(
  '★ 这是关键场景，用来量出"网络到底占多少" ★',
  '① 【停止听书】',
  '② 回到【本章开头】（同一个章节，不要换章）',
  '③ 【开始听书】，然后【立刻按电源键熄屏】',
  '④ 等 10 秒再开始测量',
  '',
  '原理：同一章的音频已在本地缓存（cacheDir/tts/*.mp3 + *.json），',
  '     重播时走到 TtsEngine.ets:939 的缓存命中分支直接返回，',
  '     完全不调用 Edge TTS ⇒ 零 WebSocket 连接 ⇒ 只测音频管线本身。',
  '验证：跑完请检查日志里 power: ws connect 的序号有没有增长；',
  '     若几乎不增长 ⇒ 缓存命中成功，本场景有效；若持续增长 ⇒ 无效，请重做。'
)

Maybe-Scenario -Key 'D' -Title '熄屏 · 待机（不播放）' -Seconds $DurationD -Steps @(
  '【停止听书】（完全停止播放）',
  '保持熄屏状态，等 10 秒'
)

Maybe-Scenario -Key 'R' -Title '熄屏 · 听书【系统「阅读」App 参照】' -Seconds $DurationR -Steps @(
  '★ 这是【参照组】—— 用手机自带的「阅读」App 做同机同场景对照 ★',
  '① 先【完全退出本 App】（从最近任务里划掉，避免它还在耗电）',
  '② 打开系统自带的「阅读」App，选一本书，用它的【听书 / 朗读】功能播放',
  '③ 确认在正常出声后，按【电源键】熄屏，等 10 秒',
  '④ 然后按回车开始测量',
  '',
  '注意：这一组的数据只作**参照**，不是严格对照实验 ——',
  '     系统阅读可能用本地 TTS/离线音频，而我们是联网流式合成，',
  '     所以它天然会低一些。我们要看的是"低多少"。',
  '有效性：若 R 的读数接近 D（熄屏待机 ≈88mA），说明它根本没在播，请重做。'
)

# ---- 安全网：如果 -Only 一个场景都没匹配上，必须显式报错，不能静默出空报告 ----
if ($onlyList.Count -gt 0 -and $results.Count -eq 0) {
  Write-Host ""
  Write-Host ("[错误] -Only 指定的场景一个都没匹配上：{0}" -f ($onlyList -join ', ')) -ForegroundColor Red
  Write-Host "       可用场景键：A, E, B, C, C2, C0, D" -ForegroundColor Red
  Write-Host "       正确写法（两种都行）：" -ForegroundColor Yellow
  Write-Host "         -Only C,C0" -ForegroundColor Yellow
  Write-Host "         -Only C -Only C0" -ForegroundColor Yellow
  exit 1
}

Write-Host ""
Write-Host ("=" * 68) -ForegroundColor Green
Write-Host "  结果汇总" -ForegroundColor Green
Write-Host ("=" * 68) -ForegroundColor Green
Write-Host ("{0,-20} {1,11} {2,11} {3,12} {4,12} {5,8}" -f '场景', '中位数', '去极值均值', '均值(参考)', '瞬时范围', '温度')
Write-Host ("{0,-20} {1,11}" -f '', '(主指标)')
foreach ($k in $results.Keys) {
  $r = $results[$k]
  if ($null -eq $r) {
    Write-Host ("{0,-20} {1,11}" -f "$k $([char]0x2014)", '无数据') -ForegroundColor Yellow
    continue
  }
  Write-Host ("{0,-20} {1,8:N1}mA {2,8:N1}mA {3,9:N1}mA {4,12} {5,7:N1}C" -f `
    "$k $($r.Label)", $r.Median, $r.TrimMean, $r.NowMean,
    ("{0:N0}~{1:N0}" -f $r.NowMin, $r.NowMax), $r.TempB)
}

$A = $results['A']; $B = $results['B']; $C = $results['C']; $D = $results['D']
$E = $results['E']; $C2 = $results['C2']; $C0 = $results['C0']; $R = $results['R']
Write-Host ""
Write-Host "关键差值（同机同条件，已抵消机型/亮度差异；均以【中位数】为准）：" -ForegroundColor Cyan
if ($null -ne $A -and $null -ne $B) {
  Write-Host ("  B - A  = 听书播放净开销（屏幕亮着这条路的账）: {0:N1} mA" -f ($B.Median - $A.Median))
}
if ($null -ne $D -and $null -ne $C) {
  Write-Host ("  C - D  = 听书播放净开销（熄屏这条路的账）    : {0:N1} mA" -f ($C.Median - $D.Median))
}
if ($null -ne $A -and $null -ne $D) {
  Write-Host ("  A - D  = 亮屏（亮度=当时档位）本身的成本      : {0:N1} mA" -f ($A.Median - $D.Median))
}
if ($null -ne $E -and $null -ne $A) {
  Write-Host ("  E - A  = 【阅读】比【书架待机】多花的         : {0:N1} mA" -f ($E.Median - $A.Median))
}
if ($null -ne $E -and $null -ne $B) {
  Write-Host ("  B - E  = 在阅读页上【加听书】多花的           : {0:N1} mA" -f ($B.Median - $E.Median))
}

Write-Host ""
Write-Host "四宫格（2x2）拆分：" -ForegroundColor Cyan
if ($null -ne $A -and $null -ne $D) {
  Write-Host ("  屏幕亮着            : {0,7:N1} mA" -f ($A.Median - $D.Median))
}
if ($null -ne $D) { Write-Host ("  熄屏·不播放(基础)   : {0,7:N1} mA" -f $D.Median) }
if ($null -ne $A -and $null -ne $B -and $null -ne $C -and $null -ne $D) {
  $playOn  = $B.Median - $A.Median
  $playOff = $C.Median - $D.Median
  Write-Host ("  播放开销·亮屏       : {0,7:N1} mA" -f $playOn)
  Write-Host ("  播放开销·熄屏       : {0,7:N1} mA" -f $playOff)
  Write-Host ""
  Write-Host ("  >>> 同一次播放，熄屏比亮屏 [省/费] : {0:N1} mA" -f ($playOn - $playOff)) -ForegroundColor Yellow
  Write-Host "      （正数=熄屏更省。若两者接近，说明熄屏没吃到低功耗大缓冲）" -ForegroundColor DarkGray
}
if ($null -ne $E) {
  Write-Host ""
  Write-Host "亮屏场景三档对照（你的亮屏主力是【阅读】，不是听书）：" -ForegroundColor Cyan
  if ($null -ne $A) { Write-Host ("  A 书架待机   : {0,7:N1} mA" -f $A.Median) }
  Write-Host ("  E 阅读页不播 : {0,7:N1} mA" -f $E.Median)
  if ($null -ne $B) { Write-Host ("  B 阅读页听书 : {0,7:N1} mA" -f $B.Median) }
}

Write-Host ""
Write-Host "观察者效应检验（同一状态、只改采样间隔）：" -ForegroundColor Cyan
if ($null -ne $C -and $null -ne $C2) {
  $obs = $C.Median - $C2.Median
  Write-Host ("  C  熄屏听书 @${IntervalSec}s  (n=$($C.N)) : {0,7:N1} mA" -f $C.Median)
  Write-Host ("  C2 熄屏听书 @${IntervalC2}s (n=$($C2.N)) : {0,7:N1} mA" -f $C2.Median)
  Write-Host ("  差值 C - C2 : {0:N1} mA" -f $obs) -ForegroundColor Yellow
  if ([math]::Abs($obs) -le 15) {
    Write-Host "  => 差值 ≤15mA：采样间隔对结果影响很小，前面的读数可信。" -ForegroundColor Green
  } elseif ($obs -gt 15) {
    Write-Host "  => C 明显高于 C2：密采样确实抬高了读数，真实功耗好于 C。" -ForegroundColor Yellow
    Write-Host "     建议以 C2（粗间隔）作为熄屏听书的更可信估计。" -ForegroundColor Yellow
  } else {
    Write-Host "  => C2 高于 C：反常，可能是期间有其他后台活动，建议重测。" -ForegroundColor Yellow
  }
  Write-Host "     注：C2 样本较少（n=$($C2.N)），中位数本身有 ±10mA 量级的不确定度。" -ForegroundColor DarkGray
}

Write-Host ""
Write-Host "★ 网络成本隔离（C0 = 缓存重播·零网络）★" -ForegroundColor Magenta
if ($null -ne $C -and $null -ne $C0) {
  $net = $C.Median - $C0.Median
  $playOffPct = 0
  if ($null -ne $D) { $playOffPct = 100.0 * $net / [math]::Max(1, ($C.Median - $D.Median)) }
  Write-Host ("  C  熄屏听书·正常联网       (n=$($C.N)) : {0,7:N1} mA" -f $C.Median)
  Write-Host ("  C0 熄屏听书·缓存重播(零网) (n=$($C0.N)) : {0,7:N1} mA" -f $C0.Median)
  Write-Host ("  >>> 网络成本 = C - C0 : {0:N1} mA" -f $net) -ForegroundColor Yellow
  if ($null -ne $D) {
    Write-Host ("      （占熄屏播放开销 {0:N0}%）" -f $playOffPct) -ForegroundColor Yellow
  } else {
    Write-Host "      （未测 D，无法算占熄屏播放开销的比例）" -ForegroundColor DarkGray
  }
  if ($net -ge 40) {
    Write-Host "  => 网络占比很大 ⇒ 连接复用值得做，收益明确。" -ForegroundColor Green
  } elseif ($net -ge 15) {
    Write-Host "  => 网络占比中等 ⇒ 可以做，但收益有限，需权衡协议改动风险。" -ForegroundColor Yellow
  } else {
    Write-Host "  => 网络占比很小 ⇒ 【不建议】改协议，把精力放到别处。" -ForegroundColor Yellow
  }
} elseif ($null -ne $C0) {
  Write-Host ("  C0 熄屏听书·缓存重播(零网) : {0,7:N1} mA" -f $C0.Median)
  Write-Host "  （未测 C，无法算网络成本）" -ForegroundColor DarkGray
} else {
  Write-Host "  （未测 C0，无法隔离网络成本）" -ForegroundColor DarkGray
}

Write-Host ""
Write-Host "★ 与系统「阅读」App 对照（R，同机同场景参照）★" -ForegroundColor Magenta
if ($null -ne $R) {
  Write-Host ("  系统阅读 · 熄屏听书 (R) : {0,7:N1} mA   (n=$($R.N))" -f $R.Median)
  if ($null -ne $D -and ($R.Median - $D.Median) -lt 20) {
    Write-Host ("  [警告] R 与熄屏待机 D({0:N0}mA) 相差不到 20mA ⇒ 参照 App 很可能【没在播放】，本组无效，请重做。" -f $D.Median) -ForegroundColor Red
  }
  if ($null -ne $C) {
    $gap = $C.Median - $R.Median
    Write-Host ("  我们   · 熄屏听书 (C) : {0,7:N1} mA" -f $C.Median)
    Write-Host ("  >>> 差值 = C - R : {0:N1} mA" -f $gap) -ForegroundColor Yellow
    if ($gap -le 20) {
      Write-Host "  => 与系统级应用基本持平 ⇒ 熄屏听书功耗已属优秀，无需再优化。" -ForegroundColor Green
    } elseif ($gap -le 60) {
      Write-Host "  => 略高于系统应用 ⇒ 有空间，但不算离谱（我们是联网流式合成，天然更高）。" -ForegroundColor Yellow
    } else {
      Write-Host "  => 明显高于系统应用 ⇒ 值得继续查（优先看网络与解码唤醒）。" -ForegroundColor Yellow
    }
    Write-Host "     注：系统阅读可能用本地/离线音频，我们必走网络 ⇒ 这是【参照】不是严格对照。" -ForegroundColor DarkGray
  }
} else {
  Write-Host "  （未测 R。跑法：pwsh -File tools\measure-power-all.ps1 -Only C,R）" -ForegroundColor DarkGray
}

if ($null -ne $B) {
  Write-Host ""
  Write-Host ("  B 整机功耗 ≈ {0:N0} mW （{1:N0}mA x {2:N2}V）" -f ($B.Volt * $B.NowMean), $B.NowMean, $B.Volt)
}
Write-Host ""
Write-Host "官方基线（华为Mate 60 Pro，亮度50%、Wi-Fi）：亮屏音乐播放 270~300mA；偏差>100mA建议重点关注。"
Write-Host "注意：跨机型/跨亮度不可直接比，应以本轮【同机差值】为准。"
Write-Host "把【结果汇总】+【关键差值】+【四宫格】+【观察者效应检验】整段复制发我即可。"
