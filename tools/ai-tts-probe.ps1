<#
  AI 听书 —— 服务商探针（PC 侧，纯 PowerShell，无第三方依赖）

  目的：在把 key 填进 App **之前**，先确认三件事：
    1. 这把 key 到底属于哪家？（认证通过与否）
    2. 端点写对了没？（404 = 端点不对，跟 key 无关）
    3. 返回体长什么样？（决定 App 里 provider 解析器要不要改）

  为什么在 PC 上做而不是在 App 里做：
    App 里失败会混进「音频解码 / 规格归一化 / 渲染器」等下游变量，
    分不清是 key 错、端点错还是解析错。PC 探针只看 HTTP 这一层，变量最少。

  用法：
    # 1) key 走环境变量（**不要写进命令行**，命令行会进 PowerShell 历史）
    $env:DASHSCOPE_KEY = 'sk-xxxxxxxx'
    .\tools\ai-tts-probe.ps1 -Provider dashscope

    # 2) 一次全跑（测所有已配置 key 的服务商）
    .\tools\ai-tts-probe.ps1 -Provider all

    # 3) 只做连通性（不发合成请求、不烧钱）
    .\tools\ai-tts-probe.ps1 -Provider dashscope -PingOnly

  输出：屏幕摘要 + 完整证据落盘到 .\logs\probe-<时间>.log
        （每家的 HTTP 状态码、响应头、响应体前若干字节、音频魔数）

  ⚠️ 本脚本**不会**把 key 写进日志（只打前 6 位 + 长度）。
  ⚠️ 合成请求会**真实计费**（每次几分钱）。默认发一句 12 字短文本。
#>

param(
  # 要测的服务商：openai | minimax | dashscope | volcengine | mimo | all
  [string]$Provider = 'dashscope',

  # 探针文本（越短越省钱）
  [string]$Text = '这是一段探针测试文本。',

  # 只做连通性检查（对端点发 GET/HEAD，不触发合成计费）
  [switch]$PingOnly,

  # 自定义 baseUrl（覆盖该服务商默认值；用于试中转/自建）
  [string]$BaseUrl = '',

  # 自定义模型名
  [string]$Model = '',

  # 超时（秒）
  [int]$TimeoutSec = 60
)

$ErrorActionPreference = 'Stop'

# ── 输出日志（证据落盘）──────────────────────────────────────────────────────
$logDir = Join-Path $PWD 'logs'
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$logPath = Join-Path $logDir ('probe-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.log')
$script:logLines = New-Object System.Collections.Generic.List[string]

function Log([string]$msg) {
  $script:logLines.Add($msg)
  Write-Host $msg
}

function Save-Log() {
  $script:logLines -join "`r`n" | Set-Content -Path $logPath -Encoding utf8
  Write-Host ""
  Write-Host "证据已落盘：$logPath" -ForegroundColor Cyan
}

# ── key 脱敏 ────────────────────────────────────────────────────────────────
function Mask([string]$k) {
  if ([string]::IsNullOrEmpty($k)) { return '(空)' }
  if ($k.Length -le 8) { return '***' }
  return $k.Substring(0, 6) + '...(' + $k.Length + ' 字符)'
}

# ── 服务商定义表 ────────────────────────────────────────────────────────────
# 每家的：环境变量名 / 默认 baseUrl / 合成端点 / 鉴权方式 / 请求体构造函数
# 端点与字段**全部抄自工程内 provider 实现**（见注释里的文件:行），
# 不是凭记忆写的 —— 这样探针与 App 走的是同一套协议假设，
# 探针通了 App 就该通；探针不通则 App 必然不通，且能立刻定位是哪一层。
function Get-ProviderTable {
  $table = @{}

  # ── OpenAI 兼容（工程: AiTtsProviders.ets:88, 199）
  #    POST {base}/audio/speech，Authorization: Bearer
  $table['openai'] = @{
    label    = 'OpenAI 兼容 / 通义 OpenAI 兼容端点'
    envKey   = 'OPENAI_TTS_KEY'
    baseUrl  = 'https://api.openai.com/v1'
    endpoint = '/audio/speech'
    altBase  = @(
      'https://dashscope.aliyuncs.com/compatible-mode/v1'   # 通义 OpenAI 兼容模式
    )
    auth     = 'bearer'
    buildBody = {
      param($model, $text, $voice)
      @{
        model           = $model
        input           = $text
        voice           = $voice
        response_format = 'mp3'
      } | ConvertTo-Json -Compress
    }
    defaultModel = 'tts-1'
    defaultVoice = 'alloy'
  }

  # ── 阿里通义 DashScope（工程: DashscopeTts.ets:28, 104-114）
  #    POST 该完整 URL；Bearer + X-DashScope-SSE: enable
  #    体: {"model":..., "input":{"text":...,"voice":...}}  → SSE 流，base64 PCM
  $table['dashscope'] = @{
    label    = '阿里通义 DashScope (Qwen3-TTS)'
    envKey   = 'DASHSCOPE_KEY'
    baseUrl  = 'https://dashscope.aliyuncs.com/api/v1/services/aigc/multimodal-generation/generation'
    endpoint = ''
    altBase  = @()
    auth     = 'dashscope'
    buildBody = {
      param($model, $text, $voice)
      @{
        model = $model
        input = @{ text = $text; voice = $voice }
      } | ConvertTo-Json -Compress -Depth 5
    }
    defaultModel = 'qwen3-tts-flash'
    defaultVoice = 'Cherry'
  }

  # ── MiniMax（工程: MiniMaxTts.ets:26, 66, 71-77）
  #    POST {base}/t2a_v2；Bearer
  #    体: {model,text,stream,voice_setting:{voice_id,speed},audio_setting:{...}}
  $table['minimax'] = @{
    label    = 'MiniMax'
    envKey   = 'MINIMAX_KEY'
    baseUrl  = 'https://api.minimaxi.com/v1'
    endpoint = '/t2a_v2'
    altBase  = @('https://api.minimax.chat/v1')
    auth     = 'bearer'
    buildBody = {
      param($model, $text, $voice)
      @{
        model         = $model
        text          = $text
        stream        = $false
        voice_setting = @{ voice_id = $voice; speed = 1.0 }
        audio_setting = @{ sample_rate = 32000; format = 'mp3'; channel = 1 }
      } | ConvertTo-Json -Compress -Depth 5
    }
    defaultModel = 'speech-2.8-turbo'
    defaultVoice = 'Chinese (Mandarin)_Male_Announcer'
  }

  # ── 火山引擎（工程: VolcengineTts.ets:27, 43, 54-73）
  #    POST 该完整 URL；X-Api-Key + X-Api-Resource-Id + X-Api-Request-Id
  #    体: {req_params:{text,speaker,audio_params:{...}}}  → NDJSON
  $table['volcengine'] = @{
    label    = '火山引擎 豆包语音 (seed-tts-2.0)'
    envKey   = 'VOLCENGINE_KEY'
    baseUrl  = 'https://openspeech.bytedance.com/api/v3/tts/unidirectional'
    endpoint = ''
    altBase  = @()
    auth     = 'volcengine'
    buildBody = {
      param($model, $text, $voice)
      @{
        req_params = @{
          text         = $text
          speaker      = $voice
          audio_params = @{ format = 'pcm'; sample_rate = 24000; speech_rate = 0 }
        }
      } | ConvertTo-Json -Compress -Depth 5
    }
    defaultModel = 'seed-tts-2.0'
    defaultVoice = 'zh_male_ruyayichen_uranus_bigtts'
  }

  # ── 小米 MiMo（工程: MimoTts.ets:27, 50-63）
  #    POST {base}/chat/completions；**api-key** 头（不是 Bearer）
  #    体: {model,messages:[{role:assistant,content:text}],audio:{...}}
  $table['mimo'] = @{
    label    = '小米 MiMo'
    envKey   = 'MIMO_KEY'
    baseUrl  = 'https://api.xiaomimimo.com/v1'
    endpoint = '/chat/completions'
    altBase  = @()
    auth     = 'apikey'
    buildBody = {
      param($model, $text, $voice)
      @{
        model    = $model
        messages = @(@{ role = 'assistant'; content = $text })
        audio    = @{ format = 'wav'; voice = $voice }
      } | ConvertTo-Json -Compress -Depth 5
    }
    defaultModel = 'mimo-v2.5-tts'
    defaultVoice = '冰糖'
  }

  return $table
}

# ── 音频魔数识别（把返回体是 mp3 / wav / pcm / 错误 判出来）────────────────
function Get-AudioMagic([byte[]]$bytes) {
  if ($null -eq $bytes -or $bytes.Length -lt 2) { return '空/过短' }
  if ($bytes.Length -ge 12 -and
      $bytes[0] -eq 0x52 -and $bytes[1] -eq 0x49 -and $bytes[2] -eq 0x46 -and $bytes[3] -eq 0x46 -and
      $bytes[8] -eq 0x57 -and $bytes[9] -eq 0x41 -and $bytes[10] -eq 0x56 -and $bytes[11] -eq 0x45) {
    return 'WAV (RIFF/WAVE)'
  }
  if ($bytes.Length -ge 3 -and $bytes[0] -eq 0x49 -and $bytes[1] -eq 0x44 -and $bytes[2] -eq 0x33) {
    return 'MP3 (ID3 头)'
  }
  if (($bytes[0] -eq 0xFF) -and (($bytes[1] -band 0xE0) -eq 0xE0)) {
    return 'MP3 (MPEG 帧同步)'
  }
  if ($bytes[0] -eq 0x7B) { return 'JSON (以 { 开头)' }
  if ($bytes[0] -eq 0x5B) { return 'JSON (以 [ 开头)' }
  if ($bytes[0] -eq 0x64 -and $bytes[1] -eq 0x61 -and $bytes[2] -eq 0x74 -and $bytes[3] -eq 0x61) {
    return 'SSE 文本流 (data: 开头)'
  }
  $head = ($bytes[0..([Math]::Min(15, $bytes.Length - 1))] | ForEach-Object { $_.ToString('X2') }) -join ' '
  return "未知（首字节: $head）"
}

# ── 单家测试 ────────────────────────────────────────────────────────────────
function Test-Provider([string]$id, $def) {
  Log ''
  Log ('=' * 78)
  Log "服务商 : $id  ($($def.label))"
  Log ('=' * 78)

  $key = [Environment]::GetEnvironmentVariable($def.envKey)
  if ([string]::IsNullOrWhiteSpace($key)) {
    Log "  ✗ 跳过：环境变量 $($def.envKey) 未设置"
    Log "    设置方法：`$env:$($def.envKey) = '你的key'"
    return $false
  }
  Log "  Key    : $(Mask $key)"

  $useBase = if ($BaseUrl) { $BaseUrl } else { $def.baseUrl }
  $useModel = if ($Model) { $Model } else { $def.defaultModel }
  $useVoice = $def.defaultVoice

  $urls = @()
  $urls += ($useBase.TrimEnd('/') + $def.endpoint)
  if (-not $BaseUrl -and $def.altBase.Count -gt 0) {
    foreach ($alt in $def.altBase) { $urls += ($alt.TrimEnd('/') + $def.endpoint) }
  }

  # 请求头
  $headers = @{}
  switch ($def.auth) {
    'bearer'     { $headers['Authorization'] = "Bearer $key" }
    'apikey'     { $headers['api-key'] = $key }
    'dashscope'  {
      $headers['Authorization'] = "Bearer $key"
      $headers['X-DashScope-SSE'] = 'enable'
    }
    'volcengine' {
      $headers['X-Api-Key'] = $key
      $headers['X-Api-Resource-Id'] = 'seed-tts-2.0'
      $headers['X-Api-Request-Id'] = [guid]::NewGuid().ToString()
    }
  }
  $headers['Content-Type'] = 'application/json'

  $anyOk = $false
  foreach ($u in $urls) {
    Log ''
    Log "  → POST $u"
    Log "    鉴权头 : $($def.auth)  |  模型: $useModel  |  音色: $useVoice"

    if ($PingOnly) {
      Log "    [PingOnly] 只测 DNS/TCP/TLS，不发合成请求"
      try {
        $h = Invoke-WebRequest -Uri $u -Method Head -TimeoutSec $TimeoutSec -SkipHttpErrorCheck
        # ⚠️ 这里**不能**把任意 HTTP 码都算通过（实测 401 也会走到这一支）。
        #    401/403 说明"端点存在、且服务器认出了鉴权失败"⇒ 只证明**端点可达**，
        #    不证明 key 有效；必须分开报告，否则会给出"通过了"的假信号。
        Log "    HTTP $($h.StatusCode) $($h.StatusDescription)"
        if ($h.StatusCode -eq 401 -or $h.StatusCode -eq 403) {
          Log "    ⚠ 端点可达，但鉴权失败（key 无效/未开通该产品）—— 端点本身是对的" -ForegroundColor Yellow
        } elseif ($h.StatusCode -eq 404) {
          Log "    ✗ 404 —— 端点地址不对（与 key 无关）" -ForegroundColor Red
        } else {
          Log "    ✓ 端点可达（HTTP $($h.StatusCode)）"
          $anyOk = $true
        }
      } catch {
        Log "    ✗ 不可达：$($_.Exception.Message)"
      }
      continue
    }

    $body = & $def.buildBody $useModel $Text $useVoice
    Log "    请求体 : $body"

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
      $resp = Invoke-WebRequest -Uri $u -Method Post -Headers $headers -Body $body `
        -TimeoutSec $TimeoutSec -SkipHttpErrorCheck
      $sw.Stop()
      $bytes = $resp.RawContentStream.ToArray()

      Log "    HTTP $($resp.StatusCode) $($resp.StatusDescription)   耗时 $($sw.ElapsedMilliseconds) ms"
      Log "    字节数 : $($bytes.Length)"
      Log "    魔数   : $(Get-AudioMagic $bytes)"

      # 响应体预览（文本类直接给前 400 字；二进制给 hex 头）
      $preview = ''
      if ($bytes.Length -gt 0) {
        $asText = [System.Text.Encoding]::UTF8.GetString($bytes[0..([Math]::Min(399, $bytes.Length - 1))])
        $printable = ($asText.ToCharArray() | Where-Object { $_ -ge ' ' -or $_ -eq "`n" -or $_ -eq "`t" }).Count
        if ($printable -gt ($asText.Length * 0.85)) {
          $preview = $asText -replace "`r?`n", ' '
        } else {
          $preview = '<二进制> ' + (($bytes[0..([Math]::Min(31, $bytes.Length - 1))] |
            ForEach-Object { $_.ToString('X2') }) -join ' ')
        }
      }
      Log "    预览   : $preview"

      if ($resp.StatusCode -ge 200 -and $resp.StatusCode -lt 300) {
        $magic = Get-AudioMagic $bytes
        if ($magic -like 'MP3*' -or $magic -like 'WAV*' -or $magic -like 'SSE*') {
          Log "    ✓ 通过：拿到音频（或音频流）" -ForegroundColor Green
          $anyOk = $true
        } elseif ($magic -like 'JSON*') {
          # 2xx + JSON：可能音频在 JSON 字段里（MiniMax/MiMo），也可能是业务错误
          Log "    ⚠ 2xx 但返回 JSON —— 需检查是业务错误还是 base64 音频字段" -ForegroundColor Yellow
          $anyOk = $true
        } else {
          Log "    ⚠ 2xx 但内容不认（裸 PCM 无魔数属正常；否则要看预览）" -ForegroundColor Yellow
          $anyOk = $true
        }
      } else {
        Log "    ✗ HTTP $($resp.StatusCode) —— 见上方预览（401/403=key 问题，404=端点问题，400=字段问题）" -ForegroundColor Red
      }
    } catch {
      $sw.Stop()
      Log "    ✗ 请求异常（$($sw.ElapsedMilliseconds) ms）：$($_.Exception.Message)" -ForegroundColor Red
      if ($_.Exception.InnerException) {
        Log "      内层：$($_.Exception.InnerException.Message)"
      }
    }
  }
  return $anyOk
}

# ── 主流程 ──────────────────────────────────────────────────────────────────
Log '================================================================'
Log ' AI 听书服务商探针'
Log " 时间   : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Log " 模式   : $(if ($PingOnly) { '连通性检查（不计费）' } else { '真实合成（会计费）' })"
Log " 文本   : $Text"
Log " 日志   : $logPath"
Log '================================================================'

$table = Get-ProviderTable
$targets = if ($Provider -eq 'all') { @('dashscope', 'openai', 'minimax', 'volcengine', 'mimo') }
           else { @($Provider) }

# 环境自检：先确认这台机器能出网（不能出网则一切无从谈起）
Log ''
Log '[环境自检] 测试到 dashscope.aliyuncs.com 的 TLS 连通性…'
try {
  $t = Test-NetConnection -ComputerName 'dashscope.aliyuncs.com' -Port 443 -WarningAction SilentlyContinue
  if ($t.TcpTestSucceeded) {
    Log '  ✓ TCP 443 可达'
  } else {
    Log '  ✗ TCP 443 不可达 —— 本机无法访问该域名（防火墙/代理问题）'
  }
} catch {
  Log "  ⚠ Test-NetConnection 不可用：$($_.Exception.Message)"
  Log '    （跳过；PowerShell 5.1 与 7.x 行为不同，不影响后续测试）'
}

$okList = @()
foreach ($id in $targets) {
  if (-not $table.ContainsKey($id)) {
    Log "未知服务商：$id（可选：openai|minimax|dashscope|volcengine|mimo|all）"
    continue
  }
  if (Test-Provider $id $table[$id]) { $okList += $id }
}

Log ''
Log '================================================================'
Log ' 汇总'
Log '================================================================'
if ($okList.Count -eq 0) {
  Log ' 没有服务商通过。请检查：key 是否正确 / 是否已开通对应产品 / 本机能否出网。'
} else {
  foreach ($k in $okList) { Log "  ✓ $k" }
  Log ''
  Log ' 下一步：把通过的这家，按下面填进 App 的「AI 语音」面板'
  Log '   · 服务商：见上表 id 对应的 chips 名称'
  Log '   · 接口地址 / 模型 / 音色：见上方日志里实际发出的 URL 与请求体'
}
Save-Log
