<#
  scripts/setup-git-hooks.ps1 —— 一次性启用仓库内版本化钩子（每个 clone 跑一次）
  ============================================================================
  做三件事：
    ① git config core.hooksPath .githooks   —— 让 `.githooks/post-commit` 生效
       （钩子随仓库提交，任何 agent/机器 clone 后跑一次就都有；
         不写进 core.hooksPath 的话 .githooks 只是普通目录，不会被执行）
    ② 给钩子打上可执行位（跨平台 clone 需要；Windows 上 git 不依赖权限位）
    ③ 立刻跑一次 scripts/sync-version.ps1 —— 用 HEAD 的提交信息同步版本号 + 更新日志

  为什么是 post-commit 而不是 commit-msg（2026-10-05 隔离实验实测）：
    · `commit-msg` / `prepare-commit-msg` 里 `git add` 的文件**不会**进本次提交
      ⇒ 原 commit-msg 方案实测无效（V2.1.0 那笔提交里 app.json5 仍是 2.0.1）；
    · `pre-commit` 里 `git add` 能进提交，但那时读不到本次提交信息（COMMIT_EDITMSG 还是上一条）；
    · `post-commit` 生成 + `git add` + `git commit --amend --no-verify --no-edit`
      ⇒ 提交信息不变、产物并入本次提交（实测：提交号改写、工作区干净、递归自终止）。
  用法：pwsh -File scripts/setup-git-hooks.ps1
#>
$ErrorActionPreference = 'Stop'
$root = (git rev-parse --show-toplevel).Trim()
if (-not $root) { throw 'not a git repository' }

git -C $root config core.hooksPath .githooks
Write-Host "[setup-git-hooks] core.hooksPath = $(git -C $root config --get core.hooksPath)"

# 让钩子可执行（Windows 上 git 不依赖权限位，但跨平台 clone 需要）
foreach ($name in @('post-commit', 'pre-commit', 'prepare-commit-msg', 'commit-msg')) {
  $hook = Join-Path $root ".githooks/$name"
  if (Test-Path $hook) {
    git -C $root update-index --chmod=+x -- ".githooks/$name" 2>$null | Out-Null
    Write-Host "[setup-git-hooks] $name 就位：$hook"
  }
}

$env:SYNC_VERSION_NO_ADD = '1'
& (Join-Path $root 'scripts/sync-version.ps1')
