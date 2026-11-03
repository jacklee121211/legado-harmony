import { AppDataBaseType } from '../types/AppDatabaseType'

export default {
  "formatVersion": 1,
  "database": {
    "version": 1,
    "identityHash": "6e17b5366286b868f2912c12d6d8e467",
    "entities": [
      {
        "tableName": "books",
        "createSql": "CREATE TABLE IF NOT EXISTS `${TABLE_NAME}` ( `id` INTEGER NOT NULL, `bookUrl` TEXT, `toUrl` TEXT, `origin` TEXT, `originName` TEXT, `bookName` TEXT NOT NULL, `author` TEXT, `cover` TEXT, `customTag` TEXT, `coverUrl` TEXT, `customCoverUrl` TEXT, `builtinCoverUrl` TEXT, `intro` TEXT, `customIntro` TEXT, `charset` TEXT, `bookGroup` INTEGER NOT NULL DEFAULT 3, `latestChapterTitle` TEXT, `latestChapterTime` INTEGER NOT NULL DEFAULT 0, `lastCheckTime` INTEGER NOT NULL DEFAULT 0, `lastCheckCount` INTEGER NOT NULL DEFAULT 0, `totalChapterNum` INTEGER NOT NULL DEFAULT 0, `durChapterTitle` TEXT, `durChapterIndex` INTEGER NOT NULL DEFAULT 0, `durChapterPos` INTEGER NOT NULL DEFAULT 0, `durChapterTime` INTEGER NOT NULL DEFAULT 0, `wordCount` TEXT, `canUpdate` INTEGER NOT NULL DEFAULT 1, `sort` INTEGER NOT NULL DEFAULT 0, `originOrder` INTEGER NOT NULL DEFAULT 0, `syncTime` INTEGER NOT NULL DEFAULT 0, `bookType` INTEGER NOT NULL DEFAULT 0, `isTop` INTEGER NOT NULL DEFAULT 0, `createTime` INTEGER NOT NULL DEFAULT 0,`updateTime` INTEGER NOT NULL DEFAULT 0,`isJoin` INTEGER NOT NULL DEFAULT 1, `isLocalBook` INTEGER NOT NULL DEFAULT 0, `finishedTime` INTEGER NOT NULL DEFAULT 0, `fileSize` INTEGER NOT NULL DEFAULT 0, PRIMARY KEY ( `id` ))",
        "fields": [
          {
            "fieldPath": "id",
            "columnName": "id",
            "affinity": "INTEGER",
            "notNull": true
          },
          {
            "fieldPath": "bookUrl",
            "columnName": "bookUrl",
            "affinity": "TEXT",
            "notNull": false
          },
          {
            "fieldPath": "toUrl",
            "columnName": "toUrl",
            "affinity": "TEXT",
            "notNull": false
          },
          {
            "fieldPath": "origin",
            "columnName": "origin",
            "affinity": "TEXT",
            "notNull": false
          },
          {
            "fieldPath": "originName",
            "columnName": "originName",
            "affinity": "TEXT",
            "notNull": false
          },
          {
            "fieldPath": "bookName",
            "columnName": "bookName",
            "affinity": "TEXT",
            "notNull": true,
            "defaultValue":""
          },
          {
            "fieldPath": "author",
            "columnName": "author",
            "affinity": "TEXT",
            "notNull": true,
            "defaultValue": ""
          },
          {
            "fieldPath": "cover",
            "columnName": "cover",
            "affinity": "TEXT",
            "notNull": false
          },
          {
            "fieldPath": "customTag",
            "columnName": "customTag",
            "affinity": "TEXT",
            "notNull": false
          },
          {
            "fieldPath": "coverUrl",
            "columnName": "coverUrl",
            "affinity": "TEXT",
            "notNull": false
          },
          {
            "fieldPath": "customCoverUrl",
            "columnName": "customCoverUrl",
            "affinity": "TEXT",
            "notNull": false
          },
          {
            "fieldPath": "builtinCoverUrl",
            "columnName": "builtinCoverUrl",
            "affinity": "TEXT",
            "notNull": false
          },
          {
            "fieldPath": "intro",
            "columnName": "intro",
            "affinity": "TEXT",
            "notNull": false
          },
          {
            "fieldPath": "customIntro",
            "columnName": "customIntro",
            "affinity": "TEXT",
            "notNull": false
          },
          {
            "fieldPath": "charset",
            "columnName": "charset",
            "affinity": "TEXT",
            "notNull": false
          },
          {
            "fieldPath": "bookGroup",
            "columnName": "bookGroup",
            "affinity": "INTEGER",
            "notNull": true,
            "defaultValue": "3"
          },
          {
            "fieldPath": "latestChapterTitle",
            "columnName": "latestChapterTitle",
            "affinity": "TEXT",
            "notNull": false
          },
          {
            "fieldPath": "latestChapterTime",
            "columnName": "latestChapterTime",
            "affinity": "INTEGER",
            "notNull": true,
            "defaultValue": "0"
          },
          {
            "fieldPath": "lastCheckTime",
            "columnName": "lastCheckTime",
            "affinity": "INTEGER",
            "notNull": true,
            "defaultValue": "0"
          },
          {
            "fieldPath": "lastCheckCount",
            "columnName": "lastCheckCount",
            "affinity": "INTEGER",
            "notNull": true,
            "defaultValue": "0"
          },
          {
            "fieldPath": "totalChapterNum",
            "columnName": "totalChapterNum",
            "affinity": "INTEGER",
            "notNull": true,
            "defaultValue": "0"
          },
          {
            "fieldPath": "durChapterTitle",
            "columnName": "durChapterTitle",
            "affinity": "TEXT",
            "notNull": false
          },
          {
            "fieldPath": "durChapterIndex",
            "columnName": "durChapterIndex",
            "affinity": "INTEGER",
            "notNull": true,
            "defaultValue": "0"
          },
          {
            "fieldPath": "durChapterPos",
            "columnName": "durChapterPos",
            "affinity": "INTEGER",
            "notNull": true,
            "defaultValue": "0"
          },
          {
            "fieldPath": "durChapterTime",
            "columnName": "durChapterTime",
            "affinity": "INTEGER",
            "notNull": true,
            "defaultValue": "0"
          },
          {
            "fieldPath": "wordCount",
            "columnName": "wordCount",
            "affinity": "TEXT",
            "notNull": false
          },
          {
            "fieldPath": "canUpdate",
            "columnName": "canUpdate",
            "affinity": "INTEGER",
            "boolean": true,
            "notNull": true,
            "defaultValue": "1"
          },
          {
            "fieldPath": "sort",
            "columnName": "sort",
            "affinity": "INTEGER",
            "notNull": true,
            "defaultValue": "0"
          },
          {
            "fieldPath": "originOrder",
            "columnName": "originOrder",
            "affinity": "INTEGER",
            "notNull": true,
            "defaultValue": "0"
          },
          {
            "fieldPath": "syncTime",
            "columnName": "syncTime",
            "affinity": "INTEGER",
            "notNull": true,
            "defaultValue": "0"
          },
          {
            "fieldPath": "bookType",
            "columnName": "bookType",
            "affinity": "INTEGER",
            "notNull": true,
            "defaultValue": "0"
          },
          {
            "fieldPath": "isTop",
            "columnName": "isTop",
            "affinity": "INTEGER",
            "boolean": true,
            "notNull": true,
            "defaultValue": "1"
          },
          {
            "fieldPath": "createTime",
            "columnName": "createTime",
            "affinity": "INTEGER",
            "notNull": false
          },
          {
            "fieldPath": "updateTime",
            "columnName": "updateTime",
            "affinity": "INTEGER",
            "notNull": false
          },
          {
            "fieldPath": "isJoin",
            "columnName": "isJoin",
            "affinity": "INTEGER",
            "boolean": true,
            "notNull": true,
            "defaultValue": "1"
          },
          {
            "fieldPath": "isLocalBook",
            "columnName": "isLocalBook",
            "affinity": "INTEGER",
            "boolean": true,
            "notNull": true,
            "defaultValue": "0"
          },
          {
            "fieldPath": "finishedTime",
            "columnName": "finishedTime",
            "affinity": "INTEGER",
            "notNull": true,
            "defaultValue": "0"
          },
          {
            "fieldPath": "fileSize",
            "columnName": "fileSize",
            "affinity": "INTEGER",
            "notNull": true,
            "defaultValue": "0"
          }
        ],
        "primaryKey": {
          "autoGenerate": false,
          "columnNames": [
            "id"
          ]
        },
        "indices": [
          {
            "name": "index_books_bookName_author",
            "unique": true,
            "columnNames": [
              "bookName",
              "author"
            ],
            "orders": [],
            "createSql": "CREATE UNIQUE INDEX IF NOT EXISTS `index_books_bookName_author` ON `${TABLE_NAME}` (`bookName`, `author`)"
          }
        ],
        "foreignKeys": []
      },
      {
        "tableName": "book_groups",
        "createSql": "CREATE TABLE IF NOT EXISTS `${TABLE_NAME}` (`groupId` INTEGER NOT NULL, `groupName` TEXT NOT NULL, `coverUrl` TEXT, `groupDescribe` TEXT, `sort` INTEGER NOT NULL, `enableRefresh` INTEGER NOT NULL DEFAULT 1, `show` INTEGER NOT NULL DEFAULT 1, `groupType` INTEGER NOT NULL DEFAULT 0, `createTime` INTEGER NOT NULL DEFAULT 0, `updateTime` INTEGER NOT NULL DEFAULT 0, `bookSort` INTEGER NOT NULL DEFAULT -1, `canUpdate` INTEGER NOT NULL DEFAULT 0, `coverOnly` INTEGER NOT NULL DEFAULT 0, `coverType` INTEGER NOT NULL DEFAULT 0, `canDelete` INTEGER NOT NULL DEFAULT 1, `isTop` INTEGER NOT NULL DEFAULT 0,`isSystem` INTEGER NOT NULL DEFAULT 0,`parentId` INTEGER NOT NULL DEFAULT 0,`bookIds` TEXT,PRIMARY KEY(`groupId`))",
        "fields": [
          {
            "fieldPath": "groupId",
            "columnName": "groupId",
            "affinity": "INTEGER",
            "notNull": true
          },
          {
            "fieldPath": "groupName",
            "columnName": "groupName",
            "affinity": "TEXT",
            "notNull": true
          },
          {
            "fieldPath": "coverUrl",
            "columnName": "coverUrl",
            "affinity": "TEXT",
            "notNull": false
          },
          {
            "fieldPath":"groupDescribe",
            "columnName": "groupDescribe",
            "affinity": "TEXT",
            "notNull": false
          },
          {
            "fieldPath": "sort",
            "columnName": "sort",
            "affinity": "INTEGER",
            "notNull": true
          },
          {
            "fieldPath": "enableRefresh",
            "columnName": "enableRefresh",
            "affinity": "INTEGER",
            "notNull": true,
            "defaultValue": "1"
          },
          {
            "fieldPath": "show",
            "columnName": "show",
            "affinity": "INTEGER",
            "notNull": true,
            "defaultValue": "1"
          },
          {
            "fieldPath": "groupType",
            "columnName": "groupType",
            "affinity": "INTEGER",
            "notNull": true,
            "defaultValue": "0"
          },
          {
            "fieldPath": "createTime",
            "columnName": "createTime",
            "affinity": "INTEGER",
            "notNull": true,
            "defaultValue": "0"
          },
          {
            "fieldPath": "updateTime",
            "columnName": "updateTime",
            "affinity": "INTEGER",
            "notNull": true,
            "defaultValue": "0"
          },
          {
            "fieldPath": "bookSort",
            "columnName": "bookSort",
            "affinity": "INTEGER",
            "notNull": true,
            "defaultValue": "-1"
          },
          {
            "fieldPath": "coverOnly",
            "columnName": "coverOnly",
            "affinity": "INTEGER",
            "boolean": true,
            "notNull": true,
            "defaultValue": "0"
          },
          {
            "fieldPath": "coverType",
            "columnName": "coverType",
            "affinity": "INTEGER",
            "notNull": true,
            "defaultValue": "0"
          }
          ,
          {
            "fieldPath": "canUpdate",
            "columnName": "canUpdate",
            "affinity": "INTEGER",
            "boolean": true,
            "notNull": true,
            "defaultValue": "0"
          },
          {
            "fieldPath": "canDelete",
            "columnName": "canDelete",
            "affinity": "INTEGER",
            "boolean": true,
            "notNull": true,
            "defaultValue": "1"
          },
          {
            "fieldPath": "isTop",
            "columnName": "isTop",
            "affinity": "INTEGER",
            "boolean": true,
            "notNull": true,
            "defaultValue": "0"
          },
          {
            "fieldPath": "isSystem",
            "columnName": "isSystem",
            "affinity": "INTEGER",
            "boolean": true,
            "notNull": true,
            "defaultValue": "0"
          },
          {
            "fieldPath": "parentId",
            "columnName": "parentId",
            "affinity": "INTEGER",
            "notNull": true,
            "defaultValue": "0"
          },
          {
            "fieldPath": "bookIds",
            "columnName": "bookIds",
            "affinity": "TEXT",
            "notNull": false
          }
        ],
        "primaryKey": {
          "autoGenerate": false,
          "columnNames": [
            "groupId"
          ]
        },
        "indices": [],
        "foreignKeys": []
      },
      {
        "tableName": "bookmarks",
        "createSql": "CREATE TABLE IF NOT EXISTS `${TABLE_NAME}` (`time` INTEGER NOT NULL, `bookName` TEXT NOT NULL, `bookAuthor` TEXT NOT NULL, `chapterIndex` INTEGER NOT NULL, `chapterPos` INTEGER NOT NULL, `chapterName` TEXT NOT NULL, `bookText` TEXT NOT NULL, `content` TEXT NOT NULL, PRIMARY KEY(`time`))",
        "fields": [
          {
            "fieldPath": "time",
            "columnName": "time",
            "affinity": "INTEGER",
            "notNull": true
          },
          {
            "fieldPath": "bookName",
            "columnName": "bookName",
            "affinity": "TEXT",
            "notNull": true
          },
          {
            "fieldPath": "bookAuthor",
            "columnName": "bookAuthor",
            "affinity": "TEXT",
            "notNull": true
          },
          {
            "fieldPath": "chapterIndex",
            "columnName": "chapterIndex",
            "affinity": "INTEGER",
            "notNull": true
          },
          {
            "fieldPath": "chapterPos",
            "columnName": "chapterPos",
            "affinity": "INTEGER",
            "notNull": true
          },
          {
            "fieldPath": "chapterName",
            "columnName": "chapterName",
            "affinity": "TEXT",
            "notNull": true
          },
          {
            "fieldPath": "bookText",
            "columnName": "bookText",
            "affinity": "TEXT",
            "notNull": true
          },
          {
            "fieldPath": "content",
            "columnName": "content",
            "affinity": "TEXT",
            "notNull": true
          }
        ],
        "primaryKey": {
          "autoGenerate": false,
          "columnNames": [
            "time"
          ]
        },
        "indices": [
          {
            "name": "index_bookmarks_bookName_bookAuthor",
            "unique": false,
            "columnNames": [
              "bookName",
              "bookAuthor"
            ],
            "orders": [],
            "createSql": "CREATE INDEX IF NOT EXISTS `index_bookmarks_bookName_bookAuthor` ON `${TABLE_NAME}` (`bookName`, `bookAuthor`)"
          }
        ],
        "foreignKeys": []
      },
      {
        "tableName": "readDaily",
        "createSql": "CREATE TABLE IF NOT EXISTS `${TABLE_NAME}` (`dayKey` TEXT NOT NULL, `hourKey` INTEGER NOT NULL DEFAULT 0, `bookId` INTEGER NOT NULL, `seconds` INTEGER NOT NULL DEFAULT 0, `sessionNum` INTEGER NOT NULL DEFAULT 0, `maxSession` INTEGER NOT NULL DEFAULT 0, `lastAt` INTEGER NOT NULL DEFAULT 0, PRIMARY KEY(`dayKey`, `hourKey`, `bookId`))",
        "fields": [
          {
            "fieldPath": "dayKey",
            "columnName": "dayKey",
            "affinity": "TEXT",
            "notNull": true
          },
          {
            "fieldPath": "hourKey",
            "columnName": "hourKey",
            "affinity": "INTEGER",
            "notNull": true,
            "defaultValue": "0"
          },
          {
            "fieldPath": "bookId",
            "columnName": "bookId",
            "affinity": "INTEGER",
            "notNull": true
          },
          {
            "fieldPath": "seconds",
            "columnName": "seconds",
            "affinity": "INTEGER",
            "notNull": true,
            "defaultValue": "0"
          },
          {
            "fieldPath": "sessionNum",
            "columnName": "sessionNum",
            "affinity": "INTEGER",
            "notNull": true,
            "defaultValue": "0"
          },
          {
            "fieldPath": "maxSession",
            "columnName": "maxSession",
            "affinity": "INTEGER",
            "notNull": true,
            "defaultValue": "0"
          },
          {
            "fieldPath": "lastAt",
            "columnName": "lastAt",
            "affinity": "INTEGER",
            "notNull": true,
            "defaultValue": "0"
          }
        ],
        "primaryKey": {
          "autoGenerate": false,
          "columnNames": [
            "dayKey",
            "hourKey",
            "bookId"
          ]
        },
        "indices": [],
        "foreignKeys": []
      }
    ],
    "views": [],
    "setupQueries": [
      "CREATE TABLE IF NOT EXISTS room_master_table (id INTEGER PRIMARY KEY,identity_hash TEXT)",
      "INSERT OR REPLACE INTO room_master_table (id,identity_hash) VALUES(42, '6e17b5366286b868f2912c12d6d8e467')"
    ]
  }
} as AppDataBaseType
