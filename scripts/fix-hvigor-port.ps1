# 修复 hvigor daemon 端口被 Windows 保留导致构建变慢
#
# ── 问题现象 ────────────────────────────────────────────────────────────────
# 构建从"几秒"变成"几十秒"，日志里反复出现：
#   hvigor WARN: hvigor client: daemon failed to listen on the port.
#     Build will be started in no-daemon mode.
#     Reason: LISTEN_ERROR:hvigor daemon: No available port was found in the range: 45000 - 45099
#   hvigor WARN: hvigor client: Failed to find or create an available daemon.
#
# ── 根因（本机实测证据，2026-10-21）────────────────────────────────────────
# ① hvigor 的 daemon 端口范围**写死在代码里**：
#    `D:\Program Files\Huawei\DevEco Studio\tools\hvigor\hvigor\src\base\daemon\const\daemon-const.js`
#      exports.DAEMON_SERVER_MIN_LISTEN_PORT = 45e3     // 45000
#      exports.DAEMON_SERVER_MAX_LISTEN_PORT = 45099
# ② Windows 把这一段**保留（excluded）**了，实测：
#      netsh int ipv4 show excludedportrange protocol=tcp
#        Start Port    End Port
#             44913       45012      ← 覆盖 45000-45012
#             45013       45112      ← 覆盖 45013-45099
# ③ 实测绑定 45000 直接失败：
#      "以一种访问权限不允许的方式做了一个访问套接字的尝试。"
#    ⇒ 不是"被别的进程占用"，而是**被系统独占**，普通进程无法绑定。
# ④ 后果链：
#      端口不可用 → daemon 起不来 → 退回 no-daemon → 每次全新启动 JVM/Node
#      → 没有增量缓存 → 构建几十秒
#
# 这类保留通常由 Hyper-V / WSL2 / Docker 在**开机时**动态申请（服务 winnat）。
#
# ── 本脚本做什么 ────────────────────────────────────────────────────────────
#   1. 停 winnat（释放它持有的动态端口保留）
#   2. 把 45000-45099 显式加进 excludedportrange（store=persistent）
#      ⚠️ 这一步是"把这 100 个端口**从动态分配池里划出来**"，
#         让 Hyper-V 下次开机不再抢它，而 hvigor 可以正常绑定。
#   3. 重启 winnat
#   4. 验证 45000 能否绑定
#
# ── 用法（必须管理员）──────────────────────────────────────────────────────
#   右键"以管理员身份运行 PowerShell"，然后：
#     cd D:\Arkts\3.8.11\legado-harmonydsh
#     pwsh -File scripts\fix-hvigor-port.ps1
#
# ── 回退 ────────────────────────────────────────────────────────────────────
#   netsh int ipv4 delete excludedportrange protocol=tcp startport=45000 numberofports=100
#   （删掉这条保留即可；重启后 Hyper-V 会重新按需分配）
#
# ── 若本脚本无效 ────────────────────────────────────────────────────────────
#   Hyper-V 的保留是**开机时**分配的，`net stop winnat` 有时不释放干净。
#   ⇒ 先重启 Windows，**重启后立刻**（趁 Hyper-V 还没抢回）再跑一次本脚本。

$ErrorActionPreference = 'Stop'

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-Port45000 {
    try {
        $l = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 45000)
        $l.Start()
        $l.Stop()
        return $true
    } catch {
        return $false
    }
}

Write-Host "=== hvigor 端口修复 ===" -ForegroundColor Cyan
Write-Host ""

if (-not (Test-Admin)) {
    Write-Host "[失败] 需要管理员权限。" -ForegroundColor Red
    Write-Host "请右键 PowerShell -> 以管理员身份运行，然后重新执行本脚本。" -ForegroundColor Yellow
    exit 1
}

Write-Host "[1/4] 修复前状态："
$before = Test-Port45000
if ($before) {
    Write-Host "  45000 已可绑定 —— 可能已经修好了，无需操作。" -ForegroundColor Green
} else {
    Write-Host "  45000 不可绑定（符合预期，需要修复）" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "[2/4] 停止 winnat（释放动态端口保留）..."
try {
    Stop-Service winnat -Force -ErrorAction Stop
    Write-Host "  winnat 已停止" -ForegroundColor Green
} catch {
    Write-Host "  停止 winnat 失败（可能未启用 Hyper-V，可忽略）: $($_.Exception.Message)" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "[3/4] 为 hvigor 预留 45000-45099（persistent）..."
# 先尝试删除可能已存在的同段记录（避免重复添加报错）
netsh int ipv4 delete excludedportrange protocol=tcp startport=45000 numberofports=100 2>&1 | Out-Null
$addResult = netsh int ipv4 add excludedportrange protocol=tcp startport=45000 numberofports=100 store=persistent 2>&1
Write-Host "  $addResult"
if ($LASTEXITCODE -eq 0) {
    Write-Host "  已添加端口保留" -ForegroundColor Green
} else {
    Write-Host "  添加失败（退出码 $LASTEXITCODE）" -ForegroundColor Red
}

Write-Host ""
Write-Host "[4/4] 重启 winnat..."
try {
    Start-Service winnat -ErrorAction Stop
    Write-Host "  winnat 已启动" -ForegroundColor Green
} catch {
    Write-Host "  启动 winnat 失败（可忽略）: $($_.Exception.Message)" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "=== 验证 ===" -ForegroundColor Cyan
$after = Test-Port45000
if ($after) {
    Write-Host "[成功] 45000 现在可以绑定了！" -ForegroundColor Green
    Write-Host "请重新构建一次，daemon 应该能正常启动，构建速度恢复。" -ForegroundColor Green
    Write-Host ""
    Write-Host "验证方式：构建日志里不应再出现下面这几行 ——" -ForegroundColor Gray
    Write-Host "  daemon failed to listen on the port" -ForegroundColor Gray
    Write-Host "  Build will be executed in no-daemon mode" -ForegroundColor Gray
} else {
    Write-Host "[失败] 45000 仍不可绑定。" -ForegroundColor Red
    Write-Host ""
    Write-Host "下一步建议：" -ForegroundColor Yellow
    Write-Host "  1. 重启 Windows，**重启后立刻**再跑一次本脚本（趁 Hyper-V 还没抢回端口）" -ForegroundColor Yellow
    Write-Host "  2. 若仍失败，查看当前保留段：" -ForegroundColor Yellow
    Write-Host "     netsh int ipv4 show excludedportrange protocol=tcp" -ForegroundColor Gray
}

Write-Host ""
Write-Host "=== 当前端口保留表 ===" -ForegroundColor Cyan
netsh int ipv4 show excludedportrange protocol=tcp
