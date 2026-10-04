<#
  scripts/setup-git-hooks.ps1 —— 一次性启用仓库内版本化钩子（每个 clone 跑一次）
  ============================================================================
  做两件事：
    ① git config core.hooksPath .githooks   —— 让 `.githooks/commit-msg` 生效
       （钩子随仓库提交，任何 agent/机器 clone 后跑一次就都有；
         不写进 core.hooksPath 的话 .githooks 只是普通目录，不会被执行）
    ② 立刻跑一次 scripts/sync-version.ps1 —— 回填历史提交、同步版本号
  用法：pwsh -File scripts/setup-git-hooks.ps1
#>
$ErrorActionPreference = 'Stop'
$root = (git rev-parse --show-toplevel).Trim()
if (-not $root) { throw 'not a git repository' }

git -C $root config core.hooksPath .githooks
Write-Host "[setup-git-hooks] core.hooksPath = $(git -C $root config --get core.hooksPath)"

# 让钩子可执行（Windows 上 git 不依赖权限位，但跨平台 clone 需要）
$hook = Join-Path $root '.githooks/commit-msg'
if (Test-Path $hook) {
  git -C $root update-index --chmod=+x -- '.githooks/commit-msg' 2>$null | Out-Null
  Write-Host "[setup-git-hooks] commit-msg 就位：$hook"
}

$env:SYNC_VERSION_NO_ADD = '1'
& (Join-Path $root 'scripts/sync-version.ps1')
