# 更新日志 · 版本管理器

一个**不绕过钩子**的本地小工具：看历史、改条目、改版本号，保存时自动走
`git 提交备注 → .githooks/post-commit → scripts/sync-version.ps1 → 产物` 这条唯一通路。

## 怎么用（只有一步）

**双击 `打开版本管理器.cmd`** → 浏览器自动打开 `http://127.0.0.1:8791`

- 后台服务**隐藏运行**，没有黑窗口、不用终端。
- 再次双击只是**重新打开页面**（会复用已在跑的实例，不会重复起服务、不会抢端口）。
- 端口被占用会自动顺延（8791→8792→…，最多 20 个）。

## 界面

| 区域 | 能干什么 |
|---|---|
| 顶部状态条 | `护栏：放行/卡住`、`版本一致/不一致`，一眼看出有没有问题 |
| 四张卡 | 打包版本（app.json5 + versionCode）· 页面日志显示的版本·条数 · git 里最新带版本号的提交 · 工作区改动数 |
| 提示条 | 护栏卡住 / 版本不一致时直接告诉你**原因和解开条件** |
| 左栏·编辑 | 版本号 + 条目逐条编辑（增/删/上移/下移），可一键「载入页面现有」「载入 git 最新」；下方实时预览**提交备注**与体检 |
| 右栏·历史 | 34 个版本，点标题展开条目；可「载入到编辑器 / 追加到条目」 |
| 底部动作条 | `刷新` `只提交版本+日志` `改写上一笔` `提交`；右侧常显「将提交 V… · N 条 · code …」 |

体检会实时提示：版本号格式、条目为空、条目数比页面现有少（会缩水）、版本号变了旧条目不会带过来、
条目里像工程术语（重构/迁移/真机验收…）。

## 它**不做**什么（重要）

- 不直接写 `app.json5`、不直接写 `VersionLogData.ets` —— 那是产物，交给钩子。
- 不 `git push`、不 `rebase`、不碰远程。
- 只监听 `127.0.0.1`；只操作启动时所在的那个仓库。
- `改写上一笔` 会改 hash，界面里是红色按钮并且要二次确认。

## 如果要停掉后台服务

```powershell
# 看是谁在听 8791
netstat -ano | findstr LISTENING | findstr :879
# 按 PID 结束
taskkill /F /PID <上面最后一列的 PID>
```

## 命令行方式（调试用）

```powershell
node tools/version-manager/server.mjs            # 启动器：探测/拉起服务并开浏览器
node tools/version-manager/server.mjs --serve    # 只跑服务，不自动开浏览器
node tools/version-manager/server.mjs --serve --port 9000 --no-open
```

## 为什么不用窗口 GUI

先做过一版 WinForms 桌面窗口，在这台 **150% DPI** 机器上撞了两个坑：
`SplitContainer` 的 `SplitterDistance` 在窗口未定尺寸时设值会抛
`InvalidOperationException: SplitterDistance 必须在 Panel1MinSize 和 Width - Panel2MinSize 之间`；
按手写坐标 + `Anchor` 又在 DPI 缩放下把右栏撑出屏幕。
按「连续失败熔断」停手，改用浏览器渲染 —— 布局交给 CSS，不再有 DPI 问题。

## 与钩子的兼容性

工具完全不改钩子，只做钩子看得懂的事：**写一个规范的提交消息文件**，再 `git commit -F`。
换机器 / 新 clone 时照旧跑一次 `pwsh -File scripts/setup-git-hooks.ps1`；
你哪天手敲 `git commit`，行为与本工具一致。
