/**
 * 听书入口解锁（2026-09-25 新增，用户需求）。
 *
 * 需求原文：「增加听书入口的解锁方式，新用户默认安装，阅读器界面没有听书按钮，
 * 只有目录、日间夜间自由、设置这三个按钮。解锁方式为，将用户名改成**我爱李杰克**或者
 * **我爱小妖**，立刻解锁；并且解锁后，用户改名也不受影响，永远开放听书按钮，
 * 除非软件重装。在用户解锁后，弹窗解锁成功。」
 *
 * 实现：
 *  · 判定时机：`MyCenter.saveName()` 保存用户名后调 `tryUnlock(新名字)` ——
 *    改成两个暗号之一且**尚未解锁** ⇒ 落盘解锁位并返回 true（调用方弹"解锁成功"）。
 *  · "改名也不受影响"：解锁后只认这个持久化标志位，与用户名**彻底解耦**
 *    （`isUnlocked()` 只读标志位，不再比对用户名）。
 *  · "除非软件重装"：标志位存 Preferences（应用沙箱内），卸载即清 —— 天然满足。
 *    （换设备/卸载重装后回到未解锁态，属用户认可的语义。）
 *  · 只藏**阅读器底栏的「听书」按钮**这一个入口：`ReaderPage3` 底栏按解锁位渲染。
 *    其余听书能力（TtsEngine、桌面快速听书快捷方式、TtsMiniBar）一律不动 —— 不影响功能。
 */
import { PreferencesUtil } from '@pura/harmony-utils';

export class ListenUnlock {
  /** 解锁暗号（用户名精确匹配，trim 后比对） */
  static readonly NAMES: string[] = ['我爱李杰克', '我爱小妖'];
  /** 持久化键（Preferences 沙箱内，卸载即清） */
  private static readonly KEY: string = 'ListenEntryUnlocked';
  /** AppStorage 键：解锁瞬间广播给已打开的页面（阅读页据此刷新底栏） */
  static readonly STORAGE_KEY: string = 'listenEntryUnlocked';

  /** 是否已解锁（只认标志位 —— 解锁后改名不影响） */
  static isUnlocked(): boolean {
    try {
      return PreferencesUtil.getSync(ListenUnlock.KEY, false) as boolean;
    } catch (e) {
      return false;
    }
  }

  /**
   * 用新用户名尝试解锁。仅当【尚未解锁 且 名字命中暗号】时落盘并返回 true
   * （调用方据此只弹一次"解锁成功"）。已解锁时改名永远返回 false。
   */
  static tryUnlock(name: string): boolean {
    if (ListenUnlock.isUnlocked()) {
      return false;
    }
    const n = name.trim();
    if (ListenUnlock.NAMES.indexOf(n) < 0) {
      return false;
    }
    PreferencesUtil.putSync(ListenUnlock.KEY, true);
    // ⚠️ 这里的字符串必须与 `ReaderPage3` 里 `@StorageLink('listenEntryUnlocked')` 的字面量一致
    //   （@StorageLink 的键要求编译期字面量，不能引本类的静态常量）。
    AppStorage.setOrCreate('listenEntryUnlocked', true);
    return true;
  }
}
