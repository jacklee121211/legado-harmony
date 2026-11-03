/**
 * DB schema 版本与迁移步骤的**唯一声明处**（P4a，2026-11-04）。
 *
 * ⚠️ 这里的 `version` 指**数据库 schema 版本**，与**应用版本 3.0.12 / 1312 无关**，
 *    也**不要**去动 `AppScope/app.json5`。
 *
 * ── 为什么迁移框架是"手写"的（取证结论，别再去 StoreConfig 里找 version）─────
 * 本机 SDK `%DEVECO_SDK_HOME%/default/openharmony/ets/api/@ohos.data.relationalStore.d.ts`
 * 的 `interface StoreConfig`（:283-511）**全部成员只有**：name(:295)、securityLevel(:305)、
 * encrypt(:320)、dataGroupId(:337)、customDir(:357)、rootDir(:373)、autoCleanDirtyData(:393)、
 * allowRebuild(:408)、vector(:426)、isReadOnly(:442)、pluginLibs(:453)、cryptoParam(:470)、
 * tokenizer(:486)、persist(:500)、enableSemanticIndex(:510)
 *   ⇒ **没有 version / onUpgrade / onDowngrade**（无框架级升级回调）。
 *
 * 编译器复核（MCP check，临时探针已删除）：
 *   往 `StoreConfig` 字面量里写 `version: 1` 得到
 *   `code 2322: Object literal may only specify known properties,
 *    and 'version' does not exist in type 'StoreConfig'.`
 *
 * 能用的只有**实例属性** `RdbStore.version`：
 *   同文件 `@ohos.data.relationalStore.d.ts:3813` → `version: number;`，`@since 10`；
 *   上一行注释（:3791）原文：`Set RdbStore version. The version number must be an integer greater than 0.`
 *   官方文档（`devecocli docs read` → documentId
 *   `API参考/ArkData_方舟数据管理/ArkTS_API/ohos_data_relationalStore_关系型数据库_/Interface_RdbStore/arkts-apis-data-relationalstore-rdbstore`）
 *   原文：「version10+ | number | 否 | 否 | 设置和获取数据库版本，值为大于0的正整数。
 *   读取和设置version属性会占用数据库连接，避免对该属性进行频繁操作。使用临时变量保存读取到的
 *   version值，在数据库变更完成后将其赋值给RdbStore实例的version属性。」
 *   ⇒ 官方推荐的做法本身就是「读版本 → 自己比对 → 自己改结构 → 最后回写版本」，
 *     也就是本文件 + `DbSchemaMigrator` 实现的东西。
 */
export interface DbMigrationStep {
  /**
   * 本步骤**执行完成后**库应处于的 schema 版本。
   * 必须单调递增、从 1 起、不跳号（`DbSchemaMigrator` 按数组声明顺序执行，不排序）。
   */
  toVersion: number
  /** 步骤名，只用于 `[DB-MIGRATE]` 日志 */
  name: string
  /**
   * 幂等执行体：允许被重复执行，不产生副作用、不丢数据。
   * 抛异常 ⇒ 版本**不推进**，本次中止，下次启动重试。
   */
  run: () => Promise<void>
}

/**
 * 代码期望的**当前** schema 版本。
 *
 * ⚠️ 加新步骤时：先往 `MigrationSteps.ets` 的数组里追加一步 `toVersion = 2`，
 *    再把这个常量改成 2。**绝不能只改这个常量不补步骤** ——
 *    `DbSchemaMigrator` 会因此拒绝推进版本（防的就是"版本前进、结构没变"）。
 */
export const CURRENT_SCHEMA_VERSION: number = 1

/** 迁移日志统一前缀（排障用：`hdc hilog | findstr DB-MIGRATE`） */
export const MIGRATION_TAG: string = 'DB-MIGRATE'

/**
 * 一键回退开关。
 *
 * `false` ⇒ 完全退回"无版本管理"的老行为：不读 `RdbStore.version`、不执行迁移步骤、
 * 不回写版本。结构的保证仍由 `DataBase.doInitAllTable()` 里原有的
 * `createTable` / `existsTable` / `ensureColumn` / `ensureSiblingUniqueIndex` 提供
 * （它们本来就是每轮启动都跑的幂等 DDL）。
 *
 * 回退后需要验证的点：
 *   ① 启动日志里不再出现 `[DB-MIGRATE]`；
 *   ② 书架 / 分组 / 书签 / 阅读统计四个页面数据正常；
 *   ③ `book_groups` 的同级同名唯一索引仍在（`[GRP-INDEX] 唯一索引就绪` 照常打印）。
 */
export const ENABLE_SCHEMA_MIGRATION: boolean = true
