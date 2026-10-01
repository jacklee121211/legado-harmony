import { BusinessError } from '@ohos.base';
import fs, { Options } from '@ohos.file.fs';
import { common, Context } from '@kit.AbilityKit';
import { chaptersItem } from 'ets/componets/dataList/ReaderChaptersItem';
import { showMessage } from '../../componets/common/promptShow';
import { picker } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { buffer } from '@kit.ArkTS'
import { Books } from '../../database/entities/Books';
import booksUtil from './booksUtils';
import booksDao from '../../database/dao/BooksDao';
import { AppUtil, PreferencesUtil } from '@pura/harmony-utils';

/**
 * ── T13/D-17b：把**模块顶层**的 `getContext()` + `context.filesDir` 改为惰性求值 ──────────
 * 原来这里是模块顶层两行：
 *   `let context = getContext(this) as common.UIAbilityContext;`
 *   `let filePath = context.filesDir;`
 * 它们在**模块首次被 import 时**求值。SDK `…\ets\component\common.d.ts:1346-1366`（全局 `getContext`）原文：
 *   「The default context is the context obtained by **tracing the call chain** of the API.
 *     **If this API is used in an asynchronous callback or not initially called on the current page,
 *     the context of the instance may fail to be traced. In this case, `undefined` is returned.**」
 * ⇒ 若回溯失败，`context.filesDir` 会在**模块求值期**抛 `TypeError` = **应用启动崩溃**
 *   （而不是某个功能不可用）。
 *
 * 现在改为"**调用时才取**"：`CopyFile` / `documentPickerFile` 都发生在应用起来之后，
 * 那时 `AppUtil.init(this.context)`（`EntryAbility.ets:43`）已把 Context 存好，
 * `AppUtil.getContext()`（`…/harmony-utils/src/main/ets/utils/AppUtil.ets:57-63`）是**确定性**取值。
 *
 * **默认 `false` = 旧取值语义**（`getContext()`，只是从"模块加载"推迟到"首次调用"）；
 * 回退 = 把下面这一行改回 `false`。
 * 无论开关如何，**"模块顶层求值"这个结构性风险都已消除**（本项主要目的）。
 * 说明：`context` / `filePath` 都是**模块私有**（无 `export`），故本次改动的影响面仅限本文件。
 */
const USE_APPUTIL_CONTEXT: boolean = false;

function appCtx(): common.Context {
  if (USE_APPUTIL_CONTEXT) {
    // onCreate 已 init ⇒ 确定性；其内部仍有 getContext() 兜底
    return AppUtil.getContext();
  }
  return getContext() as common.Context;
}

let options: Options = {
  encoding: 'utf-8'
};

export class FileHandler {
  /**
   * 拷贝单本书进沙箱并写入书架数据库。
   *
   * ⚠️ 2026-09-24 导入竞态修复：旧实现是"先写库、拷贝不等待、逐个弹 toast"，
   * 调用方（IndexShelf.pickLocalBooks）只能靠固定 500ms 定时器盲刷 UI ⇒ 批量导入时
   * 刷新查询落在写库完成之前，书架只出现一部分。现在：
   *   ① 先 `await` 拷贝、拷贝**成功后**再写库（失败不留脏书目）；
   *   ② `booksUtil.addBooks` 内部也改为 `await BooksDao.insert`；
   *   ③ resolve 即代表"该书已完整入库"，调用方 await 全部完成后再刷 UI，不再猜时间。
   *
   * @returns true = 已入库；false = 拷贝或写库失败（未入库）
   */
  static async CopyFile(srcUrl: string, currentIndex: number): Promise<boolean> {
    let file: fs.File | null = null;
    try {
      file = fs.openSync(srcUrl, fs.OpenMode.READ_WRITE);
      const dstPath = appCtx().filesDir + '/' + file.name; // file.name:《幽影之冰》.txt
      await fs.copyFile(file.fd, dstPath, 0);
      const book: Books = {
        bookName: file.name,
        bookUrl: dstPath,
        author: '暂无',
        bookGroup: 3,  // v3.21：导入默认「未分组」组（3）——用户心智：未归组即未分组（原 4=本地）
        latestChapterTime: 0,
        totalChapterNum: 0,
        durChapterIndex: 0,
        durChapterPos: 0,
        durChapterTime: 0,
        canUpdate: false,
        sort: 0,
        originOrder: 0,
        syncTime: 0,
        bookType: currentIndex,
        isTop: false,
        isJoin: true,
        isLocalBook: true
      }
      await booksUtil.addBooks(book)
      return true
    } catch (err) {
      const e = err as BusinessError;
      showMessage('导入失败：' + (e && e.message ? e.message : String(err)))
      console.error("copy file failed with error message: " + (e && e.message ? e.message : String(err))
        + ", error code: " + (e && e.code ? e.code : ''));
      return false
    } finally {
      // ⚠️ 源句柄必须在拷贝**结束后**关闭。
      //    SDK `@ohos.file.fs.d.ts`：`openSync(path, mode?): File` / `closeSync(file: number | File): void`
      //    —— openSync 返回的 File 占用一个 fd。旧实现全程无 closeSync ⇒ 每次导入书籍泄漏 1 个 fd。
      if (file !== null) {
        try {
          fs.closeSync(file);
        } catch (e) {
          // 已关闭则忽略
        }
      }
    }
  }

  /**
   * 新用户种子书（2026-09-27 定稿）：把 rawfile 里的《默认协议》以**"用户导入"同款流程**
   * 拷进沙箱并入库书架 —— 调用点在 `BookContent.aboutToAppear`（书架组件加载最前，
   * await 串行 ⇒ 必然先于书架查询，新用户首启即见）。
   * · 幂等：Preferences 标志 + 静态 Promise 去重（并发调用复用同一次执行）；
   * · 老用户不受影响；用户删书后不会复活（标志已置位）；
   * · 失败不打标志 ⇒ 下次启动自动重试；**每一步都留日志**（教训：上一版全静默，
   *   accessSync 抛异常吞掉后无从排查）。
   */
  private static seedPromise: Promise<void> | null = null;

  static seedDefaultBook(): Promise<void> {
    if (FileHandler.seedPromise === null) {
      FileHandler.seedPromise = FileHandler.doSeed();
    }
    return FileHandler.seedPromise;
  }

  private static async doSeed(): Promise<void> {
    try {
      if (PreferencesUtil.getSync('defaultBookSeededV3', false) === true) {
        console.info('seedDefaultBook: already seeded, skip');
        return;
      }
      // ⚠️ 上下文必须走 AppUtil（EntryAbility.onCreate 已 init ⇒ 确定性）。
      //   `getContext()` 在模块级函数的异步链里链路回溯不可靠（FileHandler 文件头注释），
      //   上一版正是它拿到 undefined 导致种子静默失败（真机日志 09-27 08:31 新装无书）。
      const ctx = AppUtil.getContext() as common.UIAbilityContext;
      const dstPath = ctx.filesDir + '/默认协议.txt';
      // ⚠️ accessSync 在文件**不存在时抛异常**而非返回 false（ReaderFontLib 同款教训）
      //   —— 首启时目标文件必不存在，裸调必抛。
      let dstExists: boolean = false;
      try {
        dstExists = fs.accessSync(dstPath);
      } catch (e) {
        dstExists = false;
      }
      if (!dstExists) {
        const v: Uint8Array = ctx.resourceManager.getRawFileContentSync('default_agreement.txt');
        console.info('seedDefaultBook: rawfile bytes=' + v.byteLength);
        if (v.byteLength === 0) {
          console.error('seedDefaultBook: rawfile empty, abort (will retry next launch)');
          return;
        }
        const f = fs.openSync(dstPath, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
        try {
          fs.writeSync(f.fd, v.buffer as ArrayBuffer);
        } finally {
          fs.closeSync(f);
        }
        console.info('seedDefaultBook: copied to ' + dstPath);
      }
      // 插入 + **验证落库**（2026-09-27 教训：首启窗口里建表/加列迁移与插入并发，
      //   日志 09-27 17:23 实证插入失败 14800021 但被 DAO 吞错、标志被误置 ⇒ 死循环）。
      // isExistBooks 的守卫要求 bookUrl 与 bookName **都非空**（缺一返回空数组）。
      for (let attempt = 1; attempt <= 3; attempt++) {
        const existed: Books[] = await booksDao.isExistBooks(dstPath, '默认协议.txt');
        if (existed.length > 0) {
          const row = existed[0];
          if (row.bookType !== 0) {
            row.bookType = 0;
            await booksDao.partialUpdate(row);
            console.info('seedDefaultBook: legacy row fixed, bookType -> 0');
          }
          PreferencesUtil.putSync('defaultBookSeededV3', true);
          console.info('seedDefaultBook: book verified in db, done');
          return;
        }
        const book: Books = {
          bookName: '默认协议.txt',
          bookUrl: dstPath,
          author: '暂无',
          bookGroup: 3,  // v3.21：导入默认「未分组」组（3）——用户心智：未归组即未分组（原 4=本地）
          latestChapterTime: 0,
          totalChapterNum: 0,
          durChapterIndex: 0,
          durChapterPos: 0,
          durChapterTime: 0,
          canUpdate: false,
          sort: 0,
          originOrder: 0,
          syncTime: 0,
          // ⚠️ bookType = 书架页签（0=小说 1=漫画 2=有声书）。新用户默认停在**小说**页签，
          //   BookContent 按 `bookType = 当前页签` 查询 ⇒ 种子书必须落 0，否则永远不显示。
          bookType: 0,
          isTop: false,
          isJoin: true,
          isLocalBook: true
        };
        await booksUtil.addBooks(book);
        const check: Books[] = await booksDao.isExistBooks(dstPath, '默认协议.txt');
        if (check.length > 0) {
          PreferencesUtil.putSync('defaultBookSeededV3', true);
          console.info('seedDefaultBook: verified inserted, done');
          return;
        }
        console.error('seedDefaultBook: insert not landed (attempt ' + attempt + '/3), wait 1.5s and retry');
        await new Promise<void>((resolve: () => void) => setTimeout(resolve, 1500));
      }
      console.error('seedDefaultBook: all attempts failed, flag NOT set ⇒ next launch retries');
    } catch (e) {
      // 失败不打标志 ⇒ 下次启动重试；但必须留下原因（上一版全静默无法排查）
      const msg = e instanceof Error ? e.message : String(e);
      console.error('seedDefaultBook failed: ' + msg);
    }
  }

  //动态获取文件大小
  static async ReadJSONFile(srcUrl: string) {
    let file: fs.File | null = null;
    try {
      file = fs.openSync(srcUrl, fs.OpenMode.READ_WRITE);
      let stat = fs.statSync(file.path)
      let arrayBuffer = new ArrayBuffer(stat.size);
      let readLen: number = await fs.read(file.fd, arrayBuffer)
      let JSONString = buffer.from(arrayBuffer, 0, readLen).toString();
      return JSONString
    } catch (e) {
      console.error(`读取失败：${e}`);
      return ''
    } finally {
      // ⚠️ 句柄必须关闭（旧实现只 open 不 close ⇒ 每次调用泄漏 1 个 fd）
      if (file !== null) {
        try {
          fs.closeSync(file);
        } catch (e) {
          // 已关闭则忽略
        }
      }
    }
  }

  static async readFile(readFileUrl: string) {
    let chapterNumber = 0
    const chapters: chaptersItem[] = [];
    console.info('readFileUrl:' + readFileUrl)
    //const regex = /===第(.*?)章 (.*?)===/g;
    const regex =
      /^[=|<]{0,4}((?:序章|楔子|番外|第\s{0,4})([\d〇零一二两三四五六七八九十百千万壹贰叁肆伍陆柒捌玖拾佰仟]+?\s{0,4})(?:章|回(?!合)|话(?!说)|节(?!课)|卷|篇(?!张)))(.{0,30})/g;
    await fs.readLines(readFileUrl, options).then((readerIterator: fs.ReaderIterator) => {
      for (let it = readerIterator.next();!it.done; it = readerIterator.next()) {
        const match = regex.exec(it.value);
        if (match) {
          const chapterTitleNumber = match[1]; // 书源内部章节
          const chapterTitle = match[3];
          chapterNumber++
          chapters.push(new chaptersItem(chapterNumber, chapterTitle, chapterTitleNumber, ''))
        } else {
          if (chapters.length > 0) {
            chapters[chapters.length - 1].content += it.value
          }
        }
      }
    }).catch((err: BusinessError) => {
      console.error("readLines failed with error message: " + err.message + ", error code: " + err.code);
    });
    // 移除chapters中content内容字符不超过5个字符的删除
    for (let i = 0; i < chapters.length; i++) {
      if (chapters[i].content.length < 5) {
        chapters.splice(i, 1)
        i--
      }
    }
    return chapters
  }

  static async documentPickerFile(maxSelectNumber: number | undefined = undefined, fileSuffixFilters: Array<string>) {
    // 尝试写一个通用的picker
    try {
      const documentSelectOptions = new picker.DocumentSelectOptions();
      // 选择文档的最大数目（可选）
      documentSelectOptions.maxSelectNumber = maxSelectNumber;
      // 选择文件的后缀类型，若选择项存在多个后缀名，则每一个后缀名之间用英文逗号进行分隔（可选），后缀类型名不能超过100
      documentSelectOptions.fileSuffixFilters = fileSuffixFilters;
      let documentViewPicker = new picker.DocumentViewPicker(appCtx());
      const documentSelectResult: Array<string> = await documentViewPicker.select(documentSelectOptions)
      return documentSelectResult
    } catch (err) {
      console.error(`读取失败：${err}`);
      return Promise.reject(err)
    }
  }

  static async pickerFile(context: Context) {
    try {
      const documentSelectOptions = new picker.DocumentSelectOptions();
      // 选择文档的最大数目（可选）
      documentSelectOptions.maxSelectNumber = 1;
      // 选择文件的后缀类型，若选择项存在多个后缀名，则每一个后缀名之间用英文逗号进行分隔（可选），后缀类型名不能超过100
      documentSelectOptions.fileSuffixFilters = ['.json'];
      let documentViewPicker = new picker.DocumentViewPicker(context);
      const documentSelectResult: Array<string> = await documentViewPicker.select(documentSelectOptions)
      const pathUrl = documentSelectResult[0];
      console.info('文件目录：' + pathUrl);
      let file = fs.openSync(pathUrl, fs.OpenMode.READ_WRITE);
      let buf: ArrayBuffer = new ArrayBuffer(0);
      try {
        // 按文件真实大小分配：旧实现无条件 `new ArrayBuffer(40960000)`（≈39MB 峰值）
        buf = new ArrayBuffer(fs.statSync(file.path).size);
        fs.readSync(file.fd, buf);
      } finally {
        // ⚠️ 异常路径也必须关闭句柄：旧实现只在正常路径 closeSync，抛错即泄漏
        try {
          fs.closeSync(file);
        } catch (e) {
          // 已关闭则忽略
        }
      }
      let uint8View = new Uint8Array(buf);
      // 设置编码格式为“utf-8”
      let textDecoder = util.TextDecoder.create('utf-8', { ignoreBOM: true });
      // 解码输后获取对应文本
      let readString = textDecoder.decodeWithStream(uint8View, { stream: false });
      console.log('读取的数据内容：' + readString);
      return JSON.parse(readString)
    } catch (err) {
      console.error(`读取失败：${err}`);
      return Promise.reject(err)
    }
  }

  static async readJsonFile<T>(pathUrl: string): Promise<T | undefined> {
    console.info('TagInfo', '文件路径：' + pathUrl);
    try {
      const readString = await fs.readText(pathUrl);
      console.info('TagInfo', '读取的数据内容：' + readString);
      const data: T = JSON.parse(readString)
      return data
    } catch (err) {
      console.error('TagInfo', `未读取到：${err}`);
      return undefined
    }
  }

  static writeJsonFile(pathUrl: string, context: ArrayBuffer | string) {
    console.info('TagInfo', '文件地址：' + pathUrl);
    try {
      // 创建文件，并且写入内容，若是存在则重写内容
      let res = fs.accessSync(pathUrl);
      let file: fs.File
      if (res) {
        file = fs.openSync(pathUrl, fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
      } else {
        file = fs.openSync(pathUrl, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE);
      }
      fs.writeSync(file.fd, context)
      fs.close(file);
      return '写入成功'
    } catch (e) {
      console.error('TagInfo', '写入失败' + JSON.stringify(e))
      return '写入失败' + JSON.stringify(e)
    }
  }

  static deleteJsonFile(pathUrl: string) {
    try {
      fs.unlinkSync(pathUrl);
      return '删除成功'
    } catch (e) {
      console.error('TagError', '删除失败' + JSON.stringify(e))
      return '删除失败'
    }
  }
}