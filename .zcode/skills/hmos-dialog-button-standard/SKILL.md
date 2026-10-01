---
name: hmos-dialog-button-standard
description: 本项目（legado-harmony 鸿蒙阅读器）弹窗与按钮统一规范。当用户要求创建/修改 ArkTS 弹窗（CustomDialog/bindSheet）、弹窗按钮、图标按钮、弹窗材质（沉浸光感/高斯玻璃）、父子弹窗联动（子进父退/子退父进）、弹窗间距、或报告弹窗显示异常（透明/白底/溢出/不刷新/闪退）时使用。
---

# 弹窗与按钮统一规范（项目级 Skill）

**第一步永远是读完整规范文档**：[docs/标准-弹窗与按钮统一规范.md](../../../../docs/标准-弹窗与按钮统一规范.md)（相对本文件；绝对路径 `D:\Arkts\3.8.11\legado-harmonydsh\docs\标准-弹窗与按钮统一规范.md`）。文档含全部 SDK 证据、代码配方、地雷清单、自检清单。本 SKILL 只是速查卡，与文档冲突时以文档为准。

## 十条铁律（速查）

1. **按钮三件套**：SymbolGlyph（`sys.symbol.*`）+ `Haptics.tap()` + `runJellyClick`；弹窗网格按钮直接用 `componets/common/MarkToolButton.ets`。
2. **弹窗必须是 `@CustomDialog` struct**；普通 `@Component` 进 `builder:` 字段初始化器 = 真机闪退 `TypeError: class constructor cannot called without 'new'`（2026-10-01 真机日志）。
3. **材质四件套 options**：`customStyle: false` + `cornerRadius: 20` + `systemMaterial: ImmersiveMaterialUtil.sheetMaterial()` + `openAnimation/closeAnimation: UiMotion.motionParam(UiMotion.SPRING_FAST)`。
4. **内容层让出背景**：根节点 `MaterialColumnModifier(Color.White, true)` + `.borderRadius(20)`，绝不 `.backgroundColor()`。
5. **含 Scroll 的弹窗 options 给 `height: 400`**、包装层 `.height('100%')`，否则百分比高撑满整屏。材质弹窗禁用 bindSheet（SheetOptions 无 systemMaterial 字段）。
6. **间距分组模型**：同功能组内部小（GridRow `gutter: { x: 0, y: 12 }`、区 padding 12/8）；组间大（图标区→取消键 `margin top 24`）。
7. **子进父退/子退父进**：父弹窗备 `openChildDialog(ctrl)`；恢复一律**真开真关**（2026-10-01 用户方案）——父弹窗提供 `reopen` 回调，创建者重查数据后**新建 controller 全新实例**打开；移动/删除/隐藏/解散确认后不恢复父弹窗；瞬时确认框可叠放。
8. **options 上绝不挂 `onDidAppear` 重开父弹窗**；options 也没有 `onDisappear` 字段。**弹窗组件禁用 `@Consume`**（close→open 重建时 140112 真机闪退）。
9. **参数会变的弹窗在打开瞬间 new 新 controller**（SDK：Custom dialog box parameters do not support dynamic updates）；父弹窗恢复前**重查数据库**再赋 @Prop。
10. **数据变更必须广播 AppStorage**：书 → `BOOK_IS_BOOK_REFRESHING` 自增，分组 → `BOOK_IS_BOOK_GROUPS_REFRESHING` 自增；LazyForEach/ForEach 键值必须并入影响显示的新字段。
11. **广播必须发生在 DB 提交之后**：DAO 写库路径里裸调 async（不 await）= 提前 resolve = 重查读到旧值（案例：BooksDao.insert 更新分支、bookGroupUtils.updatePartialGroup，2026-10-01）。
12. **弹窗内开二级全屏用 CustomDialog，禁用 bindContentCover**（页面级模态盖不过弹窗，案例：加入书单→新建书单"点击没用"→ `NewBookShelfDialog`）；`default://` 封面协议解析全工程只走 `CoverSource`，禁止手写 substring。

## 参考实现（照抄级别）

- 弹窗图标按钮组件：`entry/src/main/ets/componets/common/MarkToolButton.ets`
- 材质基准（用户指定）：`pages/view/Reader/ReaderListenDialog.ets`、`components/tts/TtsControlPanel.ets`
- 结构与联动最完整范例：`pages/view/bookShelf/components/dialog/FolderInfoDialog.ets`（子进父退）、`BookInfoDialogs.ets`（封面子弹窗 + 恢复前重查）
- 通用包装范例：`pages/view/bookShelf/components/dialog/AddToBookListDialog.ets`（普通组件包 @CustomDialog + 固定高 + 材质）
- 页面级按钮三件套：`componets/group/GroupType.ets`（书架"更多"按钮）

## 改完必做

MCP `check`（绝对路径）+ `devecocli build --modules entry` 至 BUILD SUCCESSFUL，并把命令返回原文贴给用户（AGENTS.md 输出契约）。
