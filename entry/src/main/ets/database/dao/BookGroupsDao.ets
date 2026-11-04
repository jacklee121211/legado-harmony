/**
 * @author 2008
 * @datetime 2024/7/24 21:16
 * @className: BookGroupsDao
 */
import DbUtil from '../../common/utils/DbUtil';
import AppDatabaseUtil from '../AppDatabaseUtil';
import { BookGroupDb, BookGroups, ToBookGroups, ToBookGroupsDb } from '../entities/BookGroups';
import { BookGroupTypeParams } from '../types/BookGroupType';
import { ColumnInfo } from '../types/ColumnInfo';

class BookGroupsDao{
  TABLE_NAME: string = 'book_groups'

  // 创建books数据表
  async initGroupTable() {
    try {
      const createSql = AppDatabaseUtil.getCreateSql(this.TABLE_NAME);
      if (!createSql) {
        return
      }
      await DbUtil.createTable(createSql)
      await AppDatabaseUtil.existsTable(this.TABLE_NAME)
      // 2026-11-03：改成 await —— 后面要建唯一索引，必须等系统分组落库完再建，
      //   否则「空表插入 4 个系统分组」与「建索引」并发时会互相踩（虽然名字不冲突，
      //   但顺序确定下来更好排查）。initGroupData 内部本来就只有一次 search + 最多 4 insert。
      await this.initGroupData()
      await this.ensureSiblingUniqueIndex()
    } catch (err) {
      console.info('TagInfo', JSON.stringify(err))
    }

  }

  /**
   * 2026-11-03（「分级唯一」落地到库层）：给 `book_groups` 建 `(parentId, groupName)` 唯一索引。
   *
   * ── 为什么必须写显式 DDL ────────────────────────────────────────────────────
   * 快照里的 `indices` 数组**全工程没有任何代码执行**（`doInitAllTable()` 只调各 DAO 的
   * `initXxxTable()`，它们只跑 `createSql` 建表）。真机实测：设备库 `sqlite_master` 里
   * `book_groups` 一条自定义索引都没有，连 `books` 的 `index_books_bookName_author` 也不存在
   * ⇒ 只往快照里加一条索引 = **空操作**，必须在这里显式 `CREATE UNIQUE INDEX`。
   *
   * ── 三步（全部幂等，失败只记日志，绝不卡启动）─────────────────────────────────
   * ① `parentId` 归一：NULL / ''（空串）→ 0。3.0.0 老库里根本没有这一列，
   *    由 `AppDatabaseUtil.existsTable()` 走 `ALTER TABLE ADD COLUMN` 补上（快照默认值 "0"）；
   *    但历史脏数据里若存过空串，会让 `hasSiblingNamed(parentId=0, …)` 一条都查不到 ⇒ 先归一。
   * ② 同父同名去重：**保留先建的那个原名**，后建的顺延 `名 (2)` / `名 (3)` …
   *    —— 只改名字，不动书、不删组、不并组（对老用户零数据损失）。
   * ③ `CREATE UNIQUE INDEX IF NOT EXISTS`。
   *
   * 为什么要去重才能建索引：3.0.0 时分组按「分类页签（bookType）」分开判重，
   * 同名分组可以同时存在于「书架 / 漫画」两个页签；后来页签合并（`migrateBookTypeToShelf`）
   * 把它们归一到同一父级 ⇒ 老库里**可能真的存在同父同名**两行，直接建唯一索引会失败。
   */
  async ensureSiblingUniqueIndex(): Promise<void> {
    const INDEX_NAME: string = 'index_book_groups_parentId_groupName'
    try {
      // ① parentId 归一
      await DbUtil.executeSql(`UPDATE ${this.TABLE_NAME} SET parentId = 0 WHERE parentId IS NULL`)
      await DbUtil.executeSql(`UPDATE ${this.TABLE_NAME} SET parentId = 0 WHERE typeof(parentId) = 'text' AND TRIM(parentId) = ''`)
      // ② 同父同名去重（先建的保留原名）
      const column: ColumnInfo[] = AppDatabaseUtil.getColumn(this.TABLE_NAME)
      const rows = await DbUtil.querySqlForList<BookGroupDb>(
        `SELECT * FROM ${this.TABLE_NAME} ORDER BY groupId ASC`, column)
      const used: Record<string, boolean> = {}
      let renamed: number = 0
      for (const r of rows) {
        const pid: number = r.parentId ?? 0
        const name: string = (r.groupName ?? '').trim()
        const key: string = `${pid}|${name}`
        if (used[key] !== true) {
          used[key] = true
          continue
        }
        // 冲突：找一个空闲后缀
        let n: number = 2
        let candidate: string = `${name} (${n})`
        while (used[`${pid}|${candidate}`] === true && n <= 99) {
          n++
          candidate = `${name} (${n})`
        }
        used[`${pid}|${candidate}`] = true
        const safeName: string = candidate.replace(/'/g, "''")
        await DbUtil.executeSql(
          `UPDATE ${this.TABLE_NAME} SET groupName = '${safeName}' WHERE groupId = ${r.groupId}`)
        renamed++
        console.info(`[GRP-INDEX] 同父同名去重：groupId=${r.groupId} 「${name}」→「${candidate}」(parentId=${pid})`)
      }
      // ③ 建唯一索引
      await DbUtil.executeSql(
        `CREATE UNIQUE INDEX IF NOT EXISTS ${INDEX_NAME} ON ${this.TABLE_NAME} (parentId, groupName)`)
      // 常驻一行巡检定痕（不是探针）：运维/排障时能确认"这次启动确实跑过索引迁移"，
      //   以及老库同父同名被改名的行数（0 = 干净库）。
      console.info(`[GRP-INDEX] 唯一索引就绪 index=${INDEX_NAME} 去重改名=${renamed} 行`)
    } catch (e) {
      // 唯一性不是安全边界：建失败只记日志，绝不能让 doInitAllTable 抛错卡死首屏
      console.error(`[GRP-INDEX] 建 (parentId, groupName) 唯一索引失败（应用层判定仍然生效）：`, JSON.stringify(e))
    }
  }

  async search(params?:BookGroupTypeParams) {
    const type = params?.type
    try {
      const column: ColumnInfo[] = AppDatabaseUtil.getColumn(this.TABLE_NAME);
      let sql = `SELECT * FROM ${this.TABLE_NAME}`;
      // 动态添加 WHERE 子句
      let whereClause: string[] = [];
      if (type !== undefined){
        whereClause.push(`groupType = ${type} OR groupType = 123`);
      }
      // 如果有 where 子句，添加 WHERE 关键字
      if (whereClause.length > 0) {
        sql += ` WHERE ${whereClause.join(' AND ')}`;
      }

      sql += `
  ORDER BY
    isSystem DESC,
    isTop DESC,
    sort ASC
`;
      const groupDbList = await DbUtil.querySqlForList<BookGroupDb>(sql, column);
      const groupList = groupDbList.map((item): BookGroups => ToBookGroups(item));
      console.log("TagInfo", '书籍：' + groupDbList.length)
      return groupList
    } catch (err) {
      console.log("TagInfo", JSON.stringify(err))
      return []
    }
  }

  async searchHide(params?:BookGroupTypeParams) {
    const type = params?.type
    const show = params?.show
    try {
      const column: ColumnInfo[] = AppDatabaseUtil.getColumn(this.TABLE_NAME);
      let sql = `SELECT * FROM ${this.TABLE_NAME}`;
      // 动态添加 WHERE 子句
      let whereClause: string[] = [];

      if (type !== undefined){
        whereClause.push(`groupType = ${type}`);
      }
      if (show !== undefined){
        whereClause.push(`show = ${show}`);
      }
      // 如果有 where 子句，添加 WHERE 关键字
      if (whereClause.length > 0) {
        sql += ` WHERE ${whereClause.join(' AND ')}`;
      }

      sql += `
  ORDER BY
    sort ASC
`;
      const groupDbList = await DbUtil.querySqlForList<BookGroupDb>(sql, column);
      const groupList = groupDbList.map((item): BookGroups => ToBookGroups(item));
      console.log("TagInfo", '书籍：' + groupList.length)
      return groupList
    } catch (err) {
      console.log("TagInfo", JSON.stringify(err))
      return []
    }
  }


  async batchInsert(group: BookGroups[]) {
    try {
      for (let index = 0; index < group.length; index++) {
        const data = group[index];
        await this.insert(data)
      }
      return true
    } catch (err) {
      console.log('TagInfo, Error, ', JSON.stringify(err))
      return false
    }
  }

  async insert(group: BookGroups) {
    try {
      const column: ColumnInfo[] = AppDatabaseUtil.getColumn(this.TABLE_NAME);
      if (group.groupId) {
        const predicates = DbUtil.getPredicates(this.TABLE_NAME);
        predicates.equalTo('groupId', group.groupId)
        const count = await DbUtil.queryForCount(predicates, column)
        if (count > 0) {
          this.update(group)
          return true
        }
      }
      const bookGroupsDb = ToBookGroupsDb(group)
      bookGroupsDb.createTime = Date.now()
      await DbUtil.insert(this.TABLE_NAME, bookGroupsDb, column)
      console.log('TagInfo', '创建成功')
      return true
    } catch (err) {
      console.log('TagInfo, Error, ', JSON.stringify(err))
      return false
    }
  }

  async update(group: BookGroups) {
    try {
      const column: ColumnInfo[] = AppDatabaseUtil.getColumn(this.TABLE_NAME);
      const predicates = DbUtil.getPredicates(this.TABLE_NAME);
      predicates.equalTo('groupId', group.groupId)
      const count = await DbUtil.queryForCount(predicates, column)
      if (count === 0) {
        this.insert(group)
        return true
      }
      const bookGroupsDb = ToBookGroupsDb(group)
      bookGroupsDb.updateTime = Date.now()
      await DbUtil.update(predicates, bookGroupsDb, column)
      return true
    } catch (err) {
      console.log('TagInfo, Error, ', JSON.stringify(err))
      return false
    }

  }

  // 2026-11-03（P8/L2）：原注释误写「删除订阅源历史记录」（Legado 残留），实际是按 id 批量删
  //   （BookGroupsDao 删分组 / BooksDao 删书籍）。仅改注释，行为不变。
  async deleteBook(id: number[]) {
    try {
      const predicates = DbUtil.getPredicates(this.TABLE_NAME);
      predicates.in('groupId', id)
      await DbUtil.delete(predicates)
      return true
    }  catch (err) {
      console.log('TagInfo, Error, ', JSON.stringify(err))
      return false
    }
  }

  //置顶
  // ⚠️ 逐条 await 写入（2026-09-29，审核问题②）：forEach 裸调不等待 ⇒ 调用方
  // resolve 后立即重查列表会查到旧 isTop（"置顶后不实时更新"根因之一）。
  async isUpdateGroupTop(id: number, isTop: boolean) {
    try {
      const column: ColumnInfo[] = AppDatabaseUtil.getColumn(this.TABLE_NAME);
      const predicates = DbUtil.getPredicates(this.TABLE_NAME);
      predicates.equalTo('groupId', id)
      const count = await DbUtil.queryForList<BookGroups>(predicates, column)
      // 旧实现误判 `column.length > 0`（列定义恒非空）—— 应判**查询结果**
      if (count.length > 0) {
        for (const item of count) {
          item.isTop = isTop
          item.updateTime = Date.now()
          await this.update(item)
        }
        return true
      }
      return false
    } catch (err) {
      console.log('TagInfo, Error, ', JSON.stringify(err))
      return false
    }
  }

  /**
   * 更新分组显示状态。
   *
   * 2026-10-13 修三处（书架分组管理面板改成"点击即隐藏/恢复"后必须精准）：
   * ① `show || !item.show` ⇒ `show === undefined ? !item.show : show`
   *    旧写法在 **`show = false` 且该分组已经是隐藏态**时算成 `false || true = true`，
   *    把"隐藏"反向写成"显示"；未传 `show` 时仍保持旧的"翻转"语义（其它调用点依赖它）；
   * ② 判空用**查询结果** `count.length`（旧写法判 `column` 恒非空，是工程记录过的笔误）；
   * ③ 逐条 `await this.update(item)`（旧写法裸调 ⇒ 调用方重查可能读到未提交的旧值）。
   */
  async updateGroupShow(id: number, show?: boolean) {
    try {
      const column: ColumnInfo[] = AppDatabaseUtil.getColumn(this.TABLE_NAME);
      const predicates = DbUtil.getPredicates(this.TABLE_NAME);
      predicates.equalTo('groupId', id)
      const count = await DbUtil.queryForList<BookGroups>(predicates, column)
      if (count.length > 0)
        for (const item of count) {
          item.show = show === undefined ? !item.show : show
          item.updateTime = Date.now()
          await this.update(item)
        }
    } catch (e){
      console.log('TagInfo, Error, ', JSON.stringify(e))
    }
  }

  //系统初始分组数据
  async initGroupData() {
    // 2026-10-25：`'书单'` 已从初始系统分组里移除（书单功能整体下线）。
    //   ⚠️ 只影响**新装**：老库里那一行 `book_groups` 记录仍在（不改用户数据），
    //   但它在渲染层本来就被跳过（`GroupType.sortSystemChips` 的 `continue`、
    //   `groupTypePanel.HIDDEN_UNIT_NAMES`），所以观感零变化。
    let initGroup = ['分组','全部','未分组']
    try {
      const groupList = await this.search()
      if (groupList.length > 0) {
        return
      }
      for (let index = 0; index < initGroup.length; index++) {
          let group = new BookGroups()
          group.groupName = initGroup[index]
          group.sort = 0
          group.show = true
          group.groupType = 123
          group.canDelete = false
          group.isSystem = true
          group.isTop = true
          group.bookIds = []
          await bookGroupsDao.insert(group)
      }
    }catch (e){
      console.log('TagInfo, Error, ', JSON.stringify(e))
    }
  }
  //根据分组groupId更新bookIds书籍id存在不做更新
  updateAddBookIds(groupId: number, bookIds: string[]) {
    try {
      const column: ColumnInfo[] = AppDatabaseUtil.getColumn(this.TABLE_NAME);
      const predicates = DbUtil.getPredicates(this.TABLE_NAME);
      predicates.equalTo('groupId', groupId)
      //查询出来只有一个值
      DbUtil.queryForList<BookGroupDb>(predicates, column).then((data) => {
        data.forEach((item) => {
          const groupList = ToBookGroups(item);
          bookIds.forEach((bookId) => {
            //存在将bookId不做添加
            if (groupList.bookIds?.includes(bookId)) {
              return
            }
            if (groupList.bookIds) {
              groupList.bookIds.push(bookId)
            } else {
              groupList.bookIds = [bookId]
            }
          })
          this.update(groupList)
          console.log("TagInfo", '书籍bookIds：' + groupList.bookIds?.length + JSON.stringify(groupList.bookIds))
        })
      })
    } catch (e){
      console.log('TagInfo, Error, ', JSON.stringify(e))
    }
  }
  //同时在更新后将旧的分组的bookIds中的书籍id移除
  async updateMoveBookIdsByGroupId(data: Record<number, number>) {
    try {
      const column: ColumnInfo[] = AppDatabaseUtil.getColumn(this.TABLE_NAME);

      const bookIds = Object.keys(data);

      for (const bookIdStr of bookIds) {
        const bookId = Number(bookIdStr);
        const oldGroupId = data[bookId];

        const predicates = DbUtil.getPredicates(this.TABLE_NAME);
        predicates.equalTo('groupId', oldGroupId);

        // 查询旧分组
        const groups = await DbUtil.queryForList<BookGroupDb>(predicates, column);
        if (groups.length > 0) {
          const group = groups[0];
          const groupList = ToBookGroups(group);

          if (groupList.bookIds?.includes(bookId.toString())) {
            // 移除旧分组中的 bookId
            groupList.bookIds = groupList.bookIds.filter(item => item !== bookId.toString());
            await this.update(groupList);
          }
        }
      }
    } catch (e) {
      console.log('updateMoveBookIdsByGroupId, Error, ', JSON.stringify(e));
    }
  }

  async updateMoveGroupBookIds(ids: number[]) {
    try {
      const column: ColumnInfo[] = AppDatabaseUtil.getColumn(this.TABLE_NAME);
      const predicates = DbUtil.getPredicates(this.TABLE_NAME);
      // 确保 ids 数组的每个元素都是数字
      const validIds = ids.filter(id => typeof id === 'number');
      predicates.in('groupId', validIds);  // 使用 in 条件一次性查找多个 id
      // 执行一次查询获取所有匹配的分组
      const groups = await DbUtil.queryForList<BookGroupDb>(predicates, column);

      if (groups.length > 0) {
        for (const group of groups) {
          const groupList = ToBookGroups(group);
          groupList.bookIds = [];
          await this.update(groupList); // 确保逐个更新
        }
      }
    } catch (e) {
      console.log('updateMoveBookIdsByGroupId, Error, ', JSON.stringify(e));
    }
  }
  /**
   * **同级同名判定**（2026-11-03 分级唯一口径的唯一实现）。
   *
   * 为什么放在 DAO：创建 / 改名 / 「同名重命名再移动」三条路径都要用它，
   * 各写一份必然漂（历史上就是"改名全表查、创建按列表查、移动按同级查"三套口径）。
   * @param parentId 目标父级（0 = 根级）
   * @param groupName 待判定的分组名（自动 trim）
   * @param excludeId 排除自身（移动/改名时传本组 id）
   */
  async hasSiblingNamed(parentId: number, groupName: string, excludeId?: number): Promise<boolean> {
    const name: string = (groupName ?? '').trim()
    if (name === '') {
      return false
    }
    try {
      const column: ColumnInfo[] = AppDatabaseUtil.getColumn(this.TABLE_NAME);
      const predicates = DbUtil.getPredicates(this.TABLE_NAME);
      predicates.equalTo('groupName', name)
      predicates.equalTo('parentId', parentId > 0 ? parentId : 0)
      const rows = await DbUtil.queryForList<BookGroupDb>(predicates, column);
      for (const r of rows) {
        if (excludeId !== undefined && r.groupId === excludeId) {
          continue
        }
        return true
      }
      return false
    } catch (e) {
      console.log('hasSiblingNamed, Error, ', JSON.stringify(e))
      // 查库失败按"不重名"放行：唯一性不是安全边界，宁可让用户改名成功也不能卡死
      return false
    }
  }
  /**
   * 校验唯一性 + 改名（**分级唯一**，2026-11-03 改口径）。
   *
   * ── 旧口径（已废弃）───────────────────────────────────────────────────────
   * 原先按 `groupName = newName` **全表**查重：只要别的分组（哪怕挂在不同父级下）
   * 叫这个名字就拒绝。真机上表现为「`1/33` 存在时，把 `2/331` 改名成 `33` 被拒」
   * —— 明明两者不是同级兄弟，却被当成重名。
   *
   * ── 新口径（**分级唯一**）──────────────────────────────────────────────────
   * 只和**同一父级下的兄弟**比较：先取本分组的 `parentId`，再查
   * `groupName = newName AND parentId = 本组.parentId`；命中非自身 ⇒ 拒绝。
   * 与本工程既有的「移动分组」口径对齐（`FolderInfoDialog.doMoveGroupNode` 用的就是
   * `GroupTree.hasSiblingNamed(targetParentId, name, excludeId)` 这套同级判定）。
   *
   * @returns true = 已改名；false = 同级已有同名（或分组不存在/异常）
   */
  async onlyGroupUpdateName(groupId: number, newGroupName: string) {
    try {
      const column: ColumnInfo[] = AppDatabaseUtil.getColumn(this.TABLE_NAME);
      // ① 先取本分组自己（拿 parentId 决定"同级"范围；顺手确认它存在）
      const selfPred = DbUtil.getPredicates(this.TABLE_NAME);
      selfPred.equalTo('groupId', groupId)
      const selfRows = await DbUtil.queryForList<BookGroupDb>(selfPred, column);
      if (selfRows.length !== 1) {
        return false
      }
      const self: BookGroupDb = selfRows[0]
      const pid: number = self.parentId ?? 0
      // ② 同级唯一：同一 parentId 下不允许同名（排除自己）
      const dupPred = DbUtil.getPredicates(this.TABLE_NAME);
      dupPred.equalTo('groupName', newGroupName)
      dupPred.equalTo('parentId', pid)
      const dups = await DbUtil.queryForList<BookGroupDb>(dupPred, column);
      for (const d of dups) {
        if (d.groupId !== groupId) {
          return false
        }
      }
      // ③ 通过 ⇒ 写回（整行写，`update` 内部按 groupId 定位）
      self.groupName = newGroupName
      self.updateTime = Date.now()
      return await this.update(ToBookGroups(self))
    } catch (e){
      console.log('onlyGroupName, Error, ', JSON.stringify(e))
      return false
    }
  }
  /**
   * 分组id查询分组下的书籍Id然后去重
   * @param ids
   */
  async queryBookByGroup(ids:number[]){
    try {
      const column: ColumnInfo[] = AppDatabaseUtil.getColumn(this.TABLE_NAME);
      const predicates = DbUtil.getPredicates(this.TABLE_NAME);
      const validIds = ids.filter(id => typeof id === 'number');
      predicates.in('groupId', validIds);
      const groups = await DbUtil.queryForList<BookGroupDb>(predicates, column);
      const bookIds:number[] = []
      if (groups.length > 0) {
        groups.forEach((item) => {
          ToBookGroups(item).bookIds?.forEach((bookId) => {
            if (!bookIds.includes(Number(bookId))) {
              bookIds.push(Number(bookId))
            }
          })
        })
      }
      return bookIds
    } catch (e){
      console.log('queryBookByGroup, Error, ', JSON.stringify(e))
      return []
    }
  }

  async updatePartialGroup(group: BookGroups) {
    // if (!(group instanceof BookGroups)) {
    //   console.warn('Invalid group instance.');
    //   return;
    // }

    const column = this.getPartialColumn();
    const predicates = DbUtil.getPredicates(this.TABLE_NAME);
    predicates.equalTo('groupId', group.groupId);

    try {
      const count = await DbUtil.queryForCount(predicates, column);
      if (count > 0) {
        await DbUtil.update(predicates, ToBookGroupsDb(group), column);
      } else {
        console.warn('No records found for update.');
      }
    } catch (err) {
      console.error('Error in partialUpdate:', err);
    }
  }

  getPartialColumn(): ColumnInfo[] {
    // 2026-11-01：多级分组 —— `parentId` 必须在这里，否则 `updatePartialGroup` 写不进去
    return AppDatabaseUtil.getAssignColumn(this.TABLE_NAME, ['groupId',
      'groupName', 'coverOnly', 'coverType','coverUrl','groupDescribe',
      'enableRefresh','canUpdate','parentId'
    ]);
  }

}

const bookGroupsDao = new BookGroupsDao()
export default bookGroupsDao as BookGroupsDao