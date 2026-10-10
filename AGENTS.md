# 本项目工作规则（legado-harmony / Edge TTS 听书）

> 这些是**硬门槛**，不是建议。违反 → 该条结论无效，必须重做。

## 0. 最高优先级：禁止经验主义

任何关于 **HarmonyOS / ArkTS / ArkUI / ReaderKit / 系统行为 / API 版本 / 字体 / 排版 / 权限 / 音频 / 性能**
的技术结论，在写进回答之前**必须先取证**，并在回答里**贴出证据原文**。只承认三类证据：

1. **SDK 声明**：SDK 目录下 `*.d.ts` / `*.d.ets` 的原文（含 `@since` / `@deprecated` / `@useinstead`），
   或 MCP 工具 `hover` / `definition` / `references` 的返回。
2. **官方文档**：`devecocli docs read <documentId>` 的原文（写出 documentId）。
3. **真机日志**：`日志.md` 中的具体行（原样引用，不转述）。

**没有上述证据的技术判断，只能写成「【待验证】」，并立即去查。**
禁止用「应该是 / 一般来说 / 我记得 / 通常 / 按经验 / 大概率」下结论。

> **用户追加的铁律（2026-10-01）**：本环境具备 deveco CLI 全量接入 MCP 与鸿蒙官方 skills
> （文档直查、知识检索、DFX 分析等）。**一切以官方权威为主、一切要有据可循**：能用 MCP/CLI
> 直查官方文档或 SDK 声明的，必须直查，禁止凭记忆或经验作答；工程规范类结论以
> `docs/标准-弹窗与按钮统一规范.md` 与项目 skills 为准。

## 1. 工具调用义务（按问题类型，先查后答）

| 问题类型 | 必须先做 |
|---|---|
| 某 API 用法/签名/参数 | MCP `hover` + `definition`（工程内），或直接读 SDK `.d.ts` |
| 「改这里会影响哪里」 | MCP `references`（拿全部调用点） |
| API 版本 / 废弃 / 兼容性 | `devecocli check compat versions` + `check compat --source-version … --target-version …` |
| 改了代码 | MCP `check`（**绝对路径**）+ `devecocli build --modules entry` |
| 系统行为 / 字体 / 排版 / 音频异常 | **先读 `日志.md`**，用日志数字定位，再决定改什么 |
| 涉及 ReaderKit | 先读官方 `开发指南/Reader_Kit_阅读服务/...`（`devecocli docs`），按其契约实现 |
| **UI 布局/样式异常**（底色不对、内容被裁、遮挡、底部不贯通） | `devecocli ui layout --format json` dump **真机节点树**，把「正常页 vs 异常页」里**同一个元素**的 `bounds` 并列对比；再用 `devecocli ui screenshot` 同分辨率截图逐行采样颜色。可疑项做**单变量 A/B**：只注释掉那一行 → 重装 → 再截图。2026-10-11 就是这样定死「书架底部那条横条」的，全过程见 `docs/底部手势区贯通-排查记录.md` |

## 2. 冲突时的判定顺序（反直觉必须交叉验证）

当直觉 / 静态检查 / 官方文档 / 实测互相矛盾时，**必须贴出双方原文**，并按此排序判定：

```
真机实测 > 官方 SDK 声明(d.ts) > 官方文档 > 静态检查(lint/MCP) > 直觉
```

已知的反例（务必记住）：`NativeDecoder` 的 `await` 被 lint 报 `await-thenable`，但 NAPI 侧
`napi_create_promise` 确实返回 Promise → **lint 误报，实测优先**。

## 3. 不可本地验证的改动（音频 / 编解码 / 系统行为）

- **默认保留旧路径**，新路径做成可一键回退（常量或开关）；
- 回答里必须写清「如何回退」+「回退后要验证什么」；
- 严禁把未经真机验证的新路径设为默认值。

## 4. 连续失败熔断

同一个问题**凭经验改两次仍失败** → 第三次动手之前**必须先新增证据**（日志行 / 官方文档 / SDK 声明），
否则停下来把问题抛给用户，不允许继续试错。

## 5. 输出契约

- 每条技术结论后必须给出 `证据：<文件:行 | documentId | 日志行>`；
- 纯推测必须显式标注 `【推测】`；
- 改完代码必须给出：改动文件、验证命令、**命令返回原文**；
- 用户报告「好了/坏了」时，先看日志或截图，再说结论。

## 6. 提交规范（2026-10-05 起强制，多 agent 共用）

**提交备注的首行必须是版本号**，例如：

```
V2.0.2 封面圆角对齐 + 进场更顺
1. 一镜到底起飞首帧圆角改为书架封面当前形状
2. 去掉进场"起手回沉"，中段不再回沉
```

- `.githooks/post-commit` 钩子会把它**同步**到两处并并入**同一笔提交**
  （生成 → `git add` → `git commit --amend --no-verify --no-edit`；提交信息与内容不变，
  只有 hash 与产物变化，命令输出会打印 `旧hash -> 新hash`；rebase/merge 期间不动）：
  `AppScope/app.json5`（versionName / versionCode = major*100+minor*10+patch）
  与 `entry/src/main/ets/pages/view/myCenter/about/VersionLogData.ets`（更新日志数据，
  **只含当前版本一条**）；
  ⚠️ 为什么不是 `commit-msg`：隔离实验实测「`commit-msg`/`prepare-commit-msg` 里 `git add`
  的文件**不会**进本次提交」，而 `pre-commit` 读不到本次提交信息 ⇒ 只有 `post-commit` + amend 可行。
  ⚠️ 生成器必须**按 UTF-8 读 git 输出**（走 `cmd /c ... > 文件` + 显式 UTF-8 读取）：
  中文 Windows 上 PowerShell 默认按 GBK(936) 解外部命令输出 ⇒ 更新日志正文会乱码（已踩过）。
- **新机器 / 新 agent 先跑一次**：`pwsh -File scripts/setup-git-hooks.ps1`
  （它设置 `git config core.hooksPath .githooks` 并回填历史）；
- 首行没有版本号的提交**不会进更新日志**（内部检查点可以这样），但仍建议带上版本号；
- 更新日志页面（我的 → 关于我们 → 更新日志）**不要手改**，改提交备注即可。

## 7. 本工程已实测的坑（别再踩）

- **ReaderKit 内部是 web/CSS 排版引擎**；`fontName` / `fontPath` 只服务**自定义字体文件**，
  且**必须注册 `on('resourceRequest')`** 才会把字体交给引擎（只 `off` 不 `on` = 永远不生效）。
- `HarmonyOS Sans SC` 的真实族名是 **`鸿蒙黑体`**（`getFontByName` 实测）。
- 阅读器**可用页高**≠窗口高（实测 2150px vs 2848px）；沉浸层预算一律按**整屏**算。
- 沉浸层与普通模式**页边界同源**（都按 ReaderKit 每页行数，实测 12 行/页）；
  逐字位置因引擎不同可差 ±1 字 —— **物理极限，不必再追**。
- `HitTestMode.None` 只让**自身**退出命中测试，**子节点照样吃触摸** → 覆盖层必须放对 z 序或逐节点设 None。
- `readerSetting` 按书持久化：改默认值**必须同时迁移旧值**，否则老书不生效（实测：卸载重装才正常）。
- 详细背景：`docs/edge-tts-highlight.md`、`docs/audit-2026-09-19.md`。
- **`web/` 构建产物的占位符必须 `replaceAll` + 构建期断言**（2026-10-05 实测）：模板里任何一处
  多余的 `/*STYLES*/`（例如说明性 HTML 注释里又写了一遍）都会让 `String.replace` 只替换第一处
  ⇒ CSS/JS 被塞进注释、真正的 `<style>`/`<script>` 留空 ⇒ 页面**无样式无脚本**（表现为：工具栏
  在文档流里、标题停在"加载中…"、0%），而构建日志的字节数一切正常。`build.mjs` 现在会在占位符
  未替换时直接抛错。
- **改文件别用 PowerShell 拼字符串**：`Set-Content -Value ($a + $b)` 会把换行全丢掉（实测把
  1698 行的 `WifiBookServer.ets` 压成 1 行）。要么用编辑工具，要么 `-join "`r`n"` 显式拼接。
  抢救办法：`entry/build/.../cache/.../esmodule/debug/**/*.ts` 是**带类型与注释的完整转译源码**。
- **ArkTS 里"可选的函数形参"会把函数实参误判成 string**（2026-10-06 实测）：形如
  `f(a: number, onDone?: (c: X) => void, s?: string)` 的签名，调用 `f(c, 1, body, undefined, cb)`
  会被 `check` 报 `2345 Argument of type '() => void' is not assignable to parameter of type 'string'`
  （指向 `cb`，位置与实参都对不上）。改成**必填形参 + 显式空实现**（`noop`）即恢复正常。
  同类坑：`forEach` 闭包里给外层 `let x: T | null` 赋值，之后读 `x` 会被窄化成 `never`
  （报 `2339 Property 'sid' does not exist on type 'never'`）⇒ 用 `for` 循环 + 显式判空。
- **DevEco 开着时编辑工具可能偶发 `ReplaceFileW EIO (Win32 1175)`**（原子替换被占用）：
  文件**不会**被损坏，直接重试同一次编辑即可（实测两次都成功）。
- **底部"手势条那一行"有东西 / 内容画不到屏幕最底 = 两个独立元凶**（2026-10-11 真机 dump + 像素双证，
  详见 `docs/底部手势区贯通-排查记录.md`）：
  1. **HDS 悬浮页签自带的背板蒙层** `HdsTabsFloatingStyle.gradientMask` —— **不写就是官方默认**：
     浅色 `#CCF1F3F5`、深色 `#99000000`，高度 = 页签栏默认高 + 16vp，全宽铺在屏幕最底，画在**内容之上**
     ⇒ 压在主题色底（书架 `#ffece0`）上就是一条灰白"横条"，压在设置页灰底 `#F5F5F5` 上几乎同色
     ⇒ **同一层蒙层，只有书架显形**。官方写明「蒙层高度**不可设置为 0**」⇒ 唯一关法是
     `gradientMask: { maskColor: Color.Transparent }`（只传颜色、不传高度），见 `pages/Index.ets`
     的 `hdsFloatingStyle()`。
  2. **滚动容器盒子自己的底部 `margin`/`padding`** 会把内容截在屏幕底以上（`BookContent` 的 List 曾带
     `.margin({ bottom: 20 })`，2025-12-23 首次导入时的老代码）⇒ 最后一行书永远画不进那一条。
     悬浮 dock 时代**避让一律走 `contentEndOffset`**（只偏移内容末尾、不动盒子），盒子不要再留底部外边距。
  ⚠️ 曾一度误判成"`linearGradient` 0.2 之后重复着色"—— **错**：`repeating` 默认 `false`
  （官方 `…/视效与模糊/颜色渐变/ts-universal-attributes-gradient-color`），实测 y=660 以下恒为第二色。
- **组件换代（ArkUI 原生 → HDS）时必须逐条复查旧代码里"显式关掉的系统默认效果"**（2026-10-09
  `Tabs` → `HdsTabs` 时漏迁 `maskColor: Color.Transparent` ⇒ 底部蒙层静默回归，两天后才被用户发现）。
  老实现 `ImmersiveMaterialUtil.tabsFloatingStyle()` 关了什么（遮罩），新实现
  `Index.ets hdsFloatingStyle()` 就要一一对照；**字段改名 + 默认值变化**都要查 API 参考的"默认值"列，
  不要以为"没写=没效果"。
- **Web 服务产物新鲜度闸门**（2026-10-06 新增）：`node scripts/check-web-artifacts.mjs` 比对
  `web/src/*` 与 `rawfile/*_v3.html` 的 mtime，旧了就非零退出；`.githooks/pre-commit` 会在
  提交含 `web/` 改动时自动 `node web/build.mjs` 并 `git add` 产物。**没挂 hvigor hook**：
  工程内没有 `@ohos/hvigor`（`hvigorfile.ts` 是插件生成的一行），改构建入口风险高于收益。
- **分块上传协议端到端自检**：`node web/dev/server.mjs` 起 mock，再 `node scripts/probe-chunk-upload.mjs`
  （11 条断言，覆盖 init/落块/重试/**断点续传只补缺块**/done/100 MB 上限/扩展名白名单）。
