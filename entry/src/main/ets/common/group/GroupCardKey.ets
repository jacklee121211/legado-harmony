import { BookGroups } from '../../database/entities/BookGroups';

/**
 * 分组卡片 `ForEach` 键 —— **唯一实现**（2026-11-03 抽取）。
 *
 * ── 为什么必须集中到一处 ────────────────────────────────────────────────────
 * 官方《ForEach：循环渲染》原文（documentId `开发指南/…/ForEach_循环渲染/arkts-rendering-control-foreach`）：
 * 「它会检查新生成的键值是否在上次渲染中已经存在。如果键值不存在，则会创建一个新的组件；
 *   **如果键值存在，则不会创建新的组件，而是直接渲染该键值所对应的组件**。」
 * ⇒ **键里少一个"影响显示的字段"，那个字段变了也不会重绘**。`BookGroups` 是普通类
 *   （字段变更不是 `@State` 可观测），所以这条规则在本工程里是硬约束。
 *
 * ── 本工程为此踩过的三次（都在真机上）────────────────────────────────────────
 * ① 2026-10-06：新建分组卡片恒「共0本」——键少了 `bookIds` 计数；
 * ② 2026-11-02：把分组从根页移进「1」后，根页**一直残留**旧卡片——键少了 `parentId`
 *    （本 ForEach 的 itemGenerator 里有 `parentId === 0` 的显示过滤，故它属"影响显示"）；
 * ③ 2026-11-03（本轮基线）：长按分组改名后，书架页**仍显示旧名**——`BookContentRefresh`
 *    的子分组宫格键只写了 `show + 计数`，漏了 `groupName`。
 *    真机证据：DB 已 `T1x`、`[PROBE] childGroups=…|31:T1xx`（数据已新），但卡片文案停在 `T1x`。
 *
 * ── 结论 ───────────────────────────────────────────────────────────────────
 * 任何"分组卡片"的 `ForEach` 都必须用本函数，**不许再各写一份**（三处各写一份正是 ③ 的成因）。
 *
 * @param item   分组实体
 * @param prefix 键前缀（仅用于区分不同列表，避免同页多列表键值相同）
 */
export function groupCardKeyOf(item: BookGroups, prefix: string = 'g'): string {
  return prefix + (item.groupId !== undefined ? item.groupId : (item.groupName ?? ''))
    + '|' + (item.groupName ?? '')
    + '|' + (item.isTop ? 'T' : 'F')
    + '|' + (item.show ? '1' : '0')
    + '|p' + (item.parentId ?? 0)
    + '|' + (item.coverUrl ?? '')
    + '|' + item.coverType
    + '|' + (item.bookIds?.length ?? 0)
    + '|' + (item.isSystem ? 'S' : 'C');
}
