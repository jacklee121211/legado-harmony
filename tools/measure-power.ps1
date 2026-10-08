# measure-power.ps1 —— 用 hdc 直接测本机整机电流（真机实测）
#
# 数据来源：hdc shell "hidumper -s BatteryService -a -i"
#   nowCurrent     当前瞬时电流(mA，负=放电)
#   currentAverage 系统滚动平均电流(mA) —— **主指标**
#   temperature    0.1℃ 为单位
#   voltage        µV
#   chargingStatus 0=未充电（测量时**必须**为 0，否则读数被充电电流污染）
#   pluggedType    0=未插线（同上）
# 亮度来源：hdc shell "hidumper -s DisplayPowerManagerService" → Brightness=
#
# 用法：
#   pwsh -File tools\measure-power.ps1 -Label "听书-亮屏" -Seconds 60
#   pwsh -File tools\measure-power.ps1 -Label "待机基线" -Seconds 60

param(
  [int]$Seconds = 60,
  [int]$IntervalSec = 2,
  [string]$Label = "unnamed"
)

$hdc = "D:\Program Files\Huawei\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe"
if (-not (Test-Path $hdc)) { $hdc = "hdc" }

function Read-Battery {
  $o = & $hdc shell "hidumper -s BatteryService -a -i" 2>&1
  if (-not ($o -match 'nowCurrent')) { return $null }
  return [pscustomobject]@{
    Now   = [int][regex]::Match($o, 'nowCurrent: (-?\d+)').Groups[1].Value
    Avg   = [int][regex]::Match($o, 'currentAverage: (-?\d+)').Groups[1].Value
    Temp  = [int][regex]::Match($o, 'temperature: (\d+)').Groups[1].Value
    Volt  = [int][regex]::Match($o, 'voltage: (\d+)').Groups[1].Value
    Cap   = [int][regex]::Match($o, 'capacity: (\d+)').Groups[1].Value
    Chg   = [int][regex]::Match($o, 'chargingStatus: (\d+)').Groups[1].Value
    Plug  = [int][regex]::Match($o, 'pluggedType: (\d+)').Groups[1].Value
  }
}

$first = Read-Battery
if ($null -eq $first) { Write-Host "无法读取电池信息，请确认设备已连接（hdc list targets）"; exit 1 }
if ($first.Chg -ne 0 -or $first.Plug -ne 0) {
  Write-Host "[警告] 设备正在充电（chargingStatus=$($first.Chg) pluggedType=$($first.Plug)）——读数会被充电电流污染，请拔线后重测。" -ForegroundColor Yellow
}
$bright = (& $hdc shell "hidumper -s DisplayPowerManagerService" 2>&1 | Select-String 'Brightness=') -join ' '

Write-Host "===== 功耗测量：$Label =====" -ForegroundColor Cyan
Write-Host "时长 ${Seconds}s / 间隔 ${IntervalSec}s"
Write-Host "起始 电量=$($first.Cap)%  电压=$([math]::Round($first.Volt/1000000,3))V  温度=$([math]::Round($first.Temp/10,1))C"
Write-Host "显示 $bright"
Write-Host ""

$samples = @()
$n = [math]::Floor($Seconds / $IntervalSec)
for ($i = 1; $i -le $n; $i++) {
  $b = Read-Battery
  if ($null -ne $b) {
    $samples += $b
    $ts = (Get-Date).ToString('HH:mm:ss')
    Write-Host ("[{0,3}/{1}] {2}  now={3,5}mA  avg={4,5}mA  temp={5}C  cap={6}%" -f `
      $i, $n, $ts, $b.Now, $b.Avg, [math]::Round($b.Temp/10,1), $b.Cap)
  }
  if ($i -lt $n) { Start-Sleep -Seconds $IntervalSec }
}

if ($samples.Count -eq 0) { Write-Host "没有采到样本"; exit 1 }

$nowArr = $samples | ForEach-Object { [math]::Abs($_.Now) }
$avgArr = $samples | ForEach-Object { [math]::Abs($_.Avg) }
$tempArr = $samples | ForEach-Object { $_.Temp / 10.0 }

$last = $samples[-1]
Write-Host ""
Write-Host "===== 结果：$Label =====" -ForegroundColor Green
Write-Host ("样本数            : {0}" -f $samples.Count)
Write-Host ("平均电流(主指标)  : {0:N1} mA   （电流均值 {1:N1} ~ {2:N1}）" -f ($avgArr | Measure-Object -Average).Average, ($avgArr | Measure-Object -Minimum).Minimum, ($avgArr | Measure-Object -Maximum).Maximum)
Write-Host ("瞬时电流          : 均值 {0:N1} mA  最低 {1:N1}  最高 {2:N1}" -f ($nowArr | Measure-Object -Average).Average, ($nowArr | Measure-Object -Minimum).Minimum, ($nowArr | Measure-Object -Maximum).Maximum)
Write-Host ("温度              : {0:N1} C -> {1:N1} C" -f $tempArr[0], $tempArr[-1])
Write-Host ("电量              : {0}% -> {1}%" -f $first.Cap, $last.Cap)
Write-Host ("功耗(电压x平均流) : {0:N0} mW" -f (($last.Volt / 1000000.0) * (($avgArr | Measure-Object -Average).Average)))
Write-Host ""
Write-Host "官方基线(华为Mate 60 Pro，亮度50%最大、连WiFi)：亮屏音乐播放 270~300mA；偏差超过100mA建议重点关注。"
Write-Host "注意：亮度、网络(WiFi/数据)、应用是否在播 三项必须与对比组保持一致，否则数字不可比。"
