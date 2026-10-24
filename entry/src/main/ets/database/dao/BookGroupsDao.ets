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
      this.initGroupData()
    } catch (err) {
      console.info('TagInfo', JSON.stringify(err))
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

  //删除订阅源历史记录
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
    let initGroup = ['分组','全部','未分组','本地']
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
  //校验唯一性,同时进行更新
  async onlyGroupUpdateName(groupId: number, newGroupName: string) {
    try {
      const column: ColumnInfo[] = AppDatabaseUtil.getColumn(this.TABLE_NAME);
      const predicates = DbUtil.getPredicates(this.TABLE_NAME);
      predicates.equalTo('groupName', newGroupName)
      const groups = await DbUtil.queryForList<BookGroupDb>(predicates, column);
      if (groups.length > 1) return false
      if (groups.length === 0){
        const predicates = DbUtil.getPredicates(this.TABLE_NAME);
        predicates.equalTo('groupId', groupId)
        const groupDate = await DbUtil.queryForList<BookGroupDb>(predicates, column);
        groupDate[0].groupName = newGroupName
        return await this.update(ToBookGroups(groupDate[0]))
      }
      if ((groups.length === 1 && groups[0].groupId && groups[0].groupId === groupId)) {
        groups[0].groupName = newGroupName
        return await this.update(ToBookGroups(groups[0]))
      }
      return false
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
    return AppDatabaseUtil.getAssignColumn(this.TABLE_NAME, ['groupId',
      'groupName', 'coverOnly', 'coverType','coverUrl','groupDescribe',
      'enableRefresh','canUpdate'
    ]);
  }

}

const bookGroupsDao = new BookGroupsDao()
export default bookGroupsDao as BookGroupsDao