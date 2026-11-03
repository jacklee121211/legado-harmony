/**
 * **schema 迁移执行器**（P4a，2026-11-04）。
 *
 * 调用点：`DataBase.doInitAllTable()` 的**最后一行**（见 `database/index.ets`）——
 * 必须排在所有 `initXxxTable()` 之后，因为迁移步骤可能依赖表/列已经存在。
 *
 * ── 为什么是这样写的（不是"框架不支持"）──────────────────────────────────────
 * `StoreConfig` 没有 `version` / `onUpgrade` / `onDowngrade`（取证原文见 `SchemaVersion.ets` 顶部），
 * **没有任何框架回调**。可用的只有实例属性 `RdbStore.version`（`@ohos.data.relationalStore.d.ts:3813`，
 * `@since 10`，注释 :3791「must be an integer greater than 0」），
 * 官方文档明确要求开发者自己比对并在"数据库变更完成后"回写。
 * ⇒ 本类的 `run()` 就是那个"手写的 onUpgrade(db, oldVersion, newVersion)"：
 *     `db` = `DbUtil.rdbStore`，`oldVersion` = 读到的 `store.version`，
 *     `newVersion` = `CURRENT_SCHEMA_VERSION`。
 *
 * ── 与老实现的关系（默认保留旧路径）──────────────────────────────────────────
 * 本类**不替代**任何既有 DDL。表 / 列的"存在性"仍由
 * `createTable()` + `AppDatabaseUtil.existsTable()` + `BooksDao.ensureColumn()` 每轮启动保证；
 * 本类只负责"**必须恰好按版本执行一次**"的那类步骤（例如建索引、数据回填），
 * 并把版本号落库，为后续 schema 演进留出可累加的插槽。
 * ⇒ 即使本类完全失效（开关关闭 / 读版本抛异常 / 步骤表缺项），
 *   老库也不会因此缺表缺列 —— 这是刻意的失效安全设计。
 */
import { relationalStore } from '@kit.ArkData'
import DbUtil from '../../common/utils/DbUtil'
import {
  CURRENT_SCHEMA_VERSION,
  DbMigrationStep,
  ENABLE_SCHEMA_MIGRATION,
  MIGRATION_TAG
} from './SchemaVersion'
import { MIGRATION_STEPS } from './MigrationSteps'

class DbSchemaMigrator {
  /**
   * 按版本执行待应用的迁移步骤，全部成功后回写 `RdbStore.version`。
   *
   * @returns true = 版本已是最新（或已成功推进到最新）；false = 本次未完成，下次启动重试。
   *          ⚠️ **绝不 reject**：调用方 `doInitAllTable()` 没有包 try/catch 的兜底，
   *          抛出去就是 unhandled rejection，会连累首屏。
   */
  async run(): Promise<boolean> {
    if (!ENABLE_SCHEMA_MIGRATION) {
      console.info(`[${MIGRATION_TAG}] 迁移框架已关闭（ENABLE_SCHEMA_MIGRATION=false）` +
        `⇒ 保持老行为：不读不写 schema 版本、不执行迁移步骤`)
      return true
    }

    const store: relationalStore.RdbStore | undefined = DbUtil.rdbStore
    if (store === undefined) {
      // 正常流程不会走到：initAllTable 一定在 initDB 之后。留作防御。
      console.error(`[${MIGRATION_TAG}] rdbStore 未就绪 ⇒ 跳过本次 schema 迁移（下次启动重试）`)
      return false
    }

    // ── ① 读库上的 schema 版本 ────────────────────────────────────────────────
    // 官方文档：读取 version 会占用数据库连接，避免频繁操作 ⇒ 每轮启动只读这一次。
    // 从没被本框架写过版本的库（含 3.0.12 及以前的全部老库）读到的是 SQLite 的默认 user_version(0)，
    // 也可能是其它值 —— 所以下面一律按 `< 1` 判"未纳管"，不写死等于 0。
    let dbVersion: number = -1
    try {
      dbVersion = store.version
    } catch (e) {
      console.error(`[${MIGRATION_TAG}] 读取 schema 版本失败 ⇒ 跳过迁移、不回写版本（下次启动重试）`,
        JSON.stringify(e))
      return false
    }

    // ── ② 降级安装：库比代码新 ⇒ 什么都不动 ──────────────────────────────────
    // 严格"不回写版本"：把版本改小会让下一轮的步骤在**已经包含新结构**的库上重跑，
    // 对"加列"类步骤还好（幂等），对"回填数据"类步骤就是重复执行。
    if (dbVersion > CURRENT_SCHEMA_VERSION) {
      console.error(`[${MIGRATION_TAG}] 库 schema 版本 v${dbVersion} 高于代码期望 v${CURRENT_SCHEMA_VERSION}` +
        `（疑似降级安装）⇒ 不改结构、不回写版本；新版本写入的数据可能无法被当前版本正确读取`)
      return true
    }

    if (dbVersion === CURRENT_SCHEMA_VERSION) {
      console.info(`[${MIGRATION_TAG}] schema 已是 v${CURRENT_SCHEMA_VERSION}，无待执行步骤`)
      return true
    }

    // ── ③ 老库基线判定 ──────────────────────────────────────────────────────
    // `dbVersion < 1` 有两种来源，**走同一条路径**（因为 v1 基线步骤是幂等的）：
    //   (a) 3.0.12 及以前装过、从没写过版本的**老库** —— 这里必须补上索引这类历史欠账；
    //   (b) 本次启动**新建**的空库（建表语句刚跑过）—— 基线对它基本是空操作。
    const isBaseline: boolean = dbVersion < 1
    if (isBaseline) {
      console.info(`[${MIGRATION_TAG}] 库未登记 schema 版本（读到 v${dbVersion}）` +
        `⇒ 判定为「老库 / 首次纳入版本管理」，从基线 v1 起执行（每步幂等，可安全重跑）`)
    }

    // ── ④ 取待执行步骤（按声明顺序 = 版本升序）──────────────────────────────
    // 不用 Array.sort：声明顺序就是执行顺序，避免引入"排序不稳定"这种不可控因素。
    const pending: DbMigrationStep[] = []
    for (let i = 0; i < MIGRATION_STEPS.length; i++) {
      const step: DbMigrationStep = MIGRATION_STEPS[i]
      if (step.toVersion > dbVersion) {
        pending.push(step)
      }
    }

    if (pending.length === 0) {
      console.error(`[${MIGRATION_TAG}] 库 v${dbVersion} 落后于代码 v${CURRENT_SCHEMA_VERSION}，` +
        `但 MIGRATION_STEPS 里没有对应步骤 ⇒ 拒绝推进版本（先补 MigrationSteps.ets）`)
      return false
    }

    // ★ 关键的防错闸门：步骤表必须能走到代码期望的版本。
    //   防的就是最容易出事的那个错——代码把 CURRENT_SCHEMA_VERSION 调大了、却忘了补步骤，
    //   于是版本被推进、结构却没变，下一轮就"以为已经升级好了"，永远不会再修。
    const lastToVersion: number = pending[pending.length - 1].toVersion
    if (lastToVersion < CURRENT_SCHEMA_VERSION) {
      console.error(`[${MIGRATION_TAG}] 步骤表最高只到 v${lastToVersion}，` +
        `但代码期望 v${CURRENT_SCHEMA_VERSION} ⇒ 拒绝推进版本（补步骤后下次启动重试）`)
      return false
    }

    // ── ⑤ 顺序执行，任一失败即中止（版本保持不动）────────────────────────────
    for (let i = 0; i < pending.length; i++) {
      const step: DbMigrationStep = pending[i]
      const startedAt: number = Date.now()
      try {
        await step.run()
        console.info(`[${MIGRATION_TAG}] 步骤 v${step.toVersion}「${step.name}」完成` +
          `（${Date.now() - startedAt}ms）`)
      } catch (e) {
        console.error(`[${MIGRATION_TAG}] 步骤 v${step.toVersion}「${step.name}」失败 ⇒ 中止迁移，` +
          `版本保持 v${dbVersion}（下次启动重试）`, JSON.stringify(e))
        return false
      }
    }

    // ── ⑥ 全部成功才回写版本（官方文档：「在数据库变更完成后将其赋值给 version 属性」）──
    // 注意：`version` 必须 > 0，写 0 会报 401（.d.ts:3791 注释原文）。
    try {
      store.version = CURRENT_SCHEMA_VERSION
      console.info(`[${MIGRATION_TAG}] schema 版本 v${dbVersion} → v${CURRENT_SCHEMA_VERSION} 已回写` +
        `（基线=${isBaseline}）`)
      return true
    } catch (e) {
      // 结构已经改好了，只是版本没落库 ⇒ 下一轮会重跑这些幂等步骤（可接受），所以不算致命
      console.error(`[${MIGRATION_TAG}] 回写 schema 版本失败（结构已就绪，下次启动会重跑幂等步骤）`,
        JSON.stringify(e))
      return false
    }
  }
}

const dbSchemaMigrator = new DbSchemaMigrator()
export default dbSchemaMigrator as DbSchemaMigrator
