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

- `.githooks/commit-msg` 钩子会把它**同步**到两处并 `git add` 进同一笔提交：
  `AppScope/app.json5`（versionName / versionCode = major*100+minor*10+patch）
  与 `entry/src/main/ets/pages/view/myCenter/about/VersionLogData.ets`（更新日志数据）；
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
