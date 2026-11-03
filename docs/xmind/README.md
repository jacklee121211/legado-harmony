# 工程总览 · 总线图（xmind）

## 这是什么

`工程总览-总线图.md` 是**源**，`legado-harmony-工程总览-2026-11-03.xmind` 是由它生成的**图**。

它不索引代码，而是回答三个问题：**事实在哪 / 谁只准写一次 / 用户看到的口径是什么**。
主干是数据总线（SQLite → DAO → 内存真源 → 事件 → 视图），分支是挂在这条线上的功能与 UI，
每个节点标题就是它的一句话结论（例：`浏览态：只说这一层`、`父层批量不穿透`）。

## 重新生成（本地 CLI，不动 Xmind 窗口）

```powershell
$src   = 'docs\xmind\工程总览-总线图.md'
$draft = Join-Path $env:TEMP 'xmind-draft-overview.md'
$spec  = Join-Path $env:TEMP 'xmind-generate-overview.json'
$out   = 'C:\Users\Administrator\Documents\1A文档\0脚本\legado-harmony-工程总览-<日期>.xmind'

Copy-Item $src $draft -Force
@{
  version  = 1
  markdown = @{ path = $draft }
  recipe   = @{ name='recipe/code-architecture'; effective='recipe/code-architecture'; createSkill='recipe-code-architecture' }
  route    = @{ structuralType='mixed_modular'; structureCommitment='preferred'; toneTag='tech'; density='standard' }
  baseline = @{ skeleton='auto'; color='Dawn-#ffffff-MULTI_LINE_COLORS'; diversify=$true; seed='legado-overview-20261103' }
  anchors  = @{
    layout = @(
      @{ topic='一条流水线'; layout='logic-right' },
      @{ topic='改名是一条级联事务'; layout='logic-right' }
    )
    group  = @()
    focus  = @(@{ kind='callout'; topic='【待验证】'; text='本轮 A/B 改动均未上真机：闸门绿 ≠ 真机正确' })
    image  = @()
  }
} | ConvertTo-Json -Depth 8 | Set-Content $spec -Encoding utf8

xmind generate check --spec $spec
xmind generate --spec $spec -o $out
xmind validate $out --quiet
```

免费档 `xmind create`/`generate` 不带付费技能时 `billing.charged=false`（本次实测 0 credits）。
生成后**不要**用命令行拉 Xmind（`Xmind.exe <file>` 实测不加载目标文件），交给人在 Xmind 里打开。

## 维护约定

- **改内容只改 md**，再重新生成；不要反过来在 Xmind 里改完不回写 md（否则两边分叉）。
- 节点标题写"结论"，证据写进备注（`>` 行）；未证实的标 `【待验证】`。
- 口径类结论（计数、父子架构、批量不穿透）若产品定义变化，**先改 md 再生成**，
  并同步 `docs/架构-分组系统-00-真源.md` 的记录。
