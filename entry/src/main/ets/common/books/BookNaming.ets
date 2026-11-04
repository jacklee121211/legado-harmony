// 书名的重名消歧（2026-11-04 决策 4 新增）。
//
// ── 为什么需要它 ────────────────────────────────────────────────────────────────
// 用户拍板：本地导入**只以文件名作书名**，`author` 一律 `'暂无'`；同名即冲突，
// 冲突时按**分组样板**改名 —— `书名 (2)`、`书名 (3)`… 顺延到第一个空闲后缀。
//
// 现状（加本模块之前）：`books` 表对「书名+作者」没有任何约束，`BooksDao.isExistBooks`
// 用的是 `bookUrl AND bookName` 且参数为空时直接返回空数组 ⇒ 导入路径**没有真正的重名拦截**。
//
// ── 与分组样板的一致性 ─────────────────────────────────────────────────────────
// 分组实现见 `GroupMutation.renameAndMove()`：`n` 从 2 起、上限 99、后缀格式 `原名 (n)`、
// 用尽后**保持原名**（宁可重名也不造怪名）。本模块逐条对齐，包括 99 上限与用尽时的回退，
// 这样"分组能得到的名字，书也能得到"，两块行为不会分叉。
//
// ── 为什么独立成模块 ──────────────────────────────────────────────────────────
// 纯函数、零 IO ⇒ 可被 `scripts/tests/book-naming.test.mjs` 直接执行（P5 单测），
// 也避免"导入路径各写一遍后缀逻辑"。
//
// 回退：删除本文件并让调用方直接用原书名（`batchAdd`/导入处不做改名）。
export class BookNaming {
  /** 后缀上限，与 `GroupMutation.renameAndMove()` 的 `n <= 99` 保持一致 */
  static readonly MAX_SUFFIX: number = 99

  /**
   * 取第一个空闲书名。
   *
   * @param base  目标书名（通常是文件名，调用方负责 trim/校验非空）
   * @param taken 已占用的书名集合（**区分大小写**，与 SQLite `=` 的比较语义一致）
   * @returns 空闲书名：无冲突返回 `base`；冲突返回 `base (2)` … `base (99)`；
   *          99 个后缀全占满时**退回 `base`**（与分组样板一致，宁可重名也不造 `(100)`）
   */
  static nextFreeName(base: string, taken: string[]): string {
    const name: string = (base ?? '').trim()
    if (name === '') {
      return name
    }
    if (!BookNaming.isTaken(name, taken)) {
      return name
    }
    let n: number = 2
    while (n <= BookNaming.MAX_SUFFIX) {
      const candidate: string = name + ' (' + n + ')'
      if (!BookNaming.isTaken(candidate, taken)) {
        return candidate
      }
      n++
    }
    return name
  }

  /** 是否已被占用（大小写敏感、逐字比较） */
  static isTaken(name: string, taken: string[]): boolean {
    for (let i = 0; i < taken.length; i++) {
      if (taken[i] === name) {
        return true
      }
    }
    return false
  }
}

export default BookNaming
