/**
 * DOC / DOCX 不再支持（2026-10-31 用户拍板）。
 *
 * 为什么要单独一个模块：
 *  · 导入层已从白名单移除（`FormatFlags.FMT_DOCX_ENABLED/FMT_DOC_PREVIEW_ONLY = false`），
 *    但**老用户书架里可能已经有** `.doc/.docx` 书；
 *  · 点击这种书时不能静默失败/闪退，必须给明确出口：**导出原文件** 或 **从书架删除**；
 *  · 这里只做这两件事 + 弹窗，不碰阅读器/排版/别的格式。
 *
 * 导出走系统保存器（`DocumentViewPicker.save` + `fs.copyFile`）：
 *  - SDK 声明 `DocumentViewPicker.save(option?: DocumentSaveOptions): Promise<Array<string>>`
 *    （`@ohos.file.picker.d.ts:721`，`DocumentSaveOptions.newFileNames` :573）；
 *  - `fs.copyFile(src: string | number, dest: string | number, mode?: number)`（`@ohos.file.fs.d.ts:761`）。
 * 源文件始终是数据库里的原始 `bookUrl`（不导出转换缓存）。
 */
import { common } from '@kit.AbilityKit';
import { picker } from '@kit.CoreFileKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { UIContext } from '@kit.ArkUI';
import { Books } from '../../database/entities/Books';
import { extOf } from '../format/FormatFlags';
import booksUtil from './booksUtils';

export class UnsupportedDoc {
  /** 是否是已取消支持的 DOC/DOCX（只看原始 bookUrl 后缀） */
  static isUnsupported(path: string): boolean {
    const e: string = extOf(path ?? '');
    return e === '.doc' || e === '.docx';
  }

  /** 书架点击这类书：弹「不再支持」，给导出/删除两个出口 */
  static show(book: Books, ctx: common.UIAbilityContext, ui: UIContext): void {
    // 2026-11-02 第 25 轮（P3 B5）：全局 `AlertDialog.show` 已废弃，改用传入的 UIContext 作用域版本
    // 证据：SDK `api/@ohos.arkui.UIContext.d.ts:4715` `showAlertDialog(options): void`
    ui.showAlertDialog({
      title: '格式不再支持',
      message: `${book.bookName}\n\nDOC/DOCX 格式已取消支持。\n可以导出原文件备份，或从书架删除。`,
      primaryButton: {
        value: '导出原文件',
        action: (): void => {
          void UnsupportedDoc.exportFile(book, ctx, ui);
        }
      },
      secondaryButton: {
        value: '删除',
        action: (): void => {
          void UnsupportedDoc.deleteBook(book, ui);
        }
      },
      cancel: (): void => {}
    });
  }

  /** 导出原始 .doc/.docx：系统保存器选目标，再复制文件 */
  static async exportFile(book: Books, ctx: common.UIAbilityContext, ui: UIContext): Promise<void> {
    const srcPath: string = book.bookUrl ?? '';
    if (srcPath.length === 0) {
      ui.getPromptAction().showToast({ message: '原文件路径为空' });
      return;
    }
    try {
      const p = new picker.DocumentViewPicker(ctx);
      const o = new picker.DocumentSaveOptions();
      o.newFileNames = [book.bookName];
      const uris: string[] = await p.save(o);
      if (uris.length === 0) {
        return;
      }
      const dst: string = uris[0];
      const srcFile = fs.openSync(srcPath, fs.OpenMode.READ_ONLY);
      const dstFile = fs.openSync(dst, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      try {
        await fs.copyFile(srcFile.fd, dstFile.fd);
      } finally {
        fs.closeSync(srcFile);
        fs.closeSync(dstFile);
      }
      ui.getPromptAction().showToast({ message: '已导出' });
    } catch (e) {
      ui.getPromptAction().showToast({ message: '导出失败，可重试或在文件管理里备份' });
    }
  }

  /** 从书架删除（走现有 delBooksById：DB + 派生数据 + 封面一起清） */
  static async deleteBook(book: Books, ui: UIContext): Promise<void> {
    try {
      if (book.id !== undefined && book.id !== null) {
        await booksUtil.delBooksById(book.id);
      }
      AppStorage.setOrCreate('BOOK_IS_BOOK_REFRESHING',
        (AppStorage.get<number>('BOOK_IS_BOOK_REFRESHING') ?? 0) + 1);
      ui.getPromptAction().showToast({ message: '已删除' });
    } catch (e) {
      ui.getPromptAction().showToast({ message: '删除失败，请重试' });
    }
  }
}
