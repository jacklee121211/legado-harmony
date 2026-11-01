/**
 * 批量管理「选择键」编码（2026-11-01 新增）
 *
 * ── 为什么需要它 ────────────────────────────────────────────────────────────
 * 旧实现把**分组 id 与书籍 id 塞进同一个 `Record<number, boolean>`**：

 *   ```
 *   checked={"2":false,"3":false,"4":false,"8":false,"9":true,"11":true}
 *   ```
 *   （真机日志，书籍 2/3/4/8 与分组 9/11 混在一起）
 *
 * 两套 id 来自**独立自增序列**，一旦某本书的 id 恰好等于某个分组 id：
 *   · 勾书会点亮分组；
 *   · 删书会误删分组的选择；
 *   · 分享/移动取到的集合会串味。
 * 目前没出事只是**没撞号**，属于随时会炸的隐患。
 *
 * ── 编码规则 ────────────────────────────────────────────────────────────────
 *   分组：**正数**  → gKey(id) = id
 *   书籍：**负数**  → bKey(id) = -id
 * 用正负号分区的好处：`Record<number, boolean>` 的类型不变 ⇒ 所有组件的
 * `@Link / @Prop` 签名不用改，只需要改"真正写键/读键"的地方。
 *
 * ── 迁移清单（64 处，按文件）────────────────────────────────────────────────
 *   BookManagePage.ets(30) / BookInfoGridManage(7) / BookFolderGridManage(6) /
 *   BookFolderManages(6) / bookListManage(5) / BookInfoManage(3) /
 *   BookFolderInfoManage(3) / ManageBrush(3) / BookContentRefresh(1)
 *
 * ── 一键回退 ────────────────────────────────────────────────────────────────
 *   把 `USE_SEPARATED_KEYS` 改回 `false` ⇒ `gKey/bKey` 都返回 `id`
 *   （即旧的"裸数字、共用空间"行为），其余逻辑不用动。
 */

/** 是否启用分组/书籍分段编码（改 false 即完全回到旧行为） */
export const USE_SEPARATED_KEYS: boolean = true

/** 分组的键（正数） */
export function gKey(groupId: number): number {
  return groupId
}

/** 书籍的键（负数；回退时退化为裸 id） */
export function bKey(bookId: number): number {
  return USE_SEPARATED_KEYS ? -bookId : bookId
}

/** 该键是否属于分组 */
export function isGroupKey(key: number): boolean {
  return key > 0
}

/** 从键还原出原始 id（分组/书籍都用绝对值） */
export function idOfKey(key: number): number {
  return key < 0 ? -key : key
}
