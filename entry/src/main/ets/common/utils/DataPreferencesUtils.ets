import CommonConstants from '../constants/CommonConstants';
import dataPreferences from '@ohos.data.preferences';
import { common } from '@kit.AbilityKit';
import { AppUtil } from '@pura/harmony-utils';

/**
 * ── T13/D-17b：把**模块顶层**的 `getContext()` 改为惰性求值 ──────────────────────
 * 原来这里是模块顶层一行 `let context = getContext(this);` —— 它在**模块首次被 import 时**求值。
 * SDK `…\ets\component\common.d.ts:1346-1366`（全局 `getContext`）原文明确：
 *   「The default context is the context obtained by **tracing the call chain** of the API.
 *     **If this API is used in an asynchronous callback or not initially called on the current page,
 *     the context of the instance may fail to be traced. In this case, `undefined` is returned.**」
 * ⇒ 若回溯失败，`getPreferencesSync(undefined, …)` 会在**模块求值期**抛错 = **应用启动崩溃**。
 *
 * 现在改成"**用到时才取**"：任何调用点（`set/get/delete`）都发生在 `EntryAbility.onCreate` 之后，
 * 那时 `AppUtil.init(this.context)`（`EntryAbility.ets:43`）**已经**把 Context 存好，
 * `AppUtil.getContext()`（`…/@pura/harmony-utils/src/main/ets/utils/AppUtil.ets:57-63`）
 * 返回的是**确定性**捕获的 Context，而不是靠调用链回溯。
 *
 * **默认 `false` = 旧取值语义**（`getContext()`，只是从"模块加载"推迟到"首次调用"）；
 * 回退 = 把下面这一行改回 `false`。
 * 注意：无论开关如何，**"模块顶层求值"这个结构性风险都已消除**（这是本项的主要目的）。
 */
const USE_APPUTIL_CONTEXT: boolean = false;

function appCtx(): common.Context {
  if (USE_APPUTIL_CONTEXT) {
    // onCreate 已 init ⇒ 确定性；其内部仍有 getContext() 兜底
    return AppUtil.getContext();
  }
  return getContext() as common.Context;
}

export default class bookDataPreferences {

  static shared = new bookDataPreferences();
  preferences?: dataPreferences.Preferences;
  preferencesName: string = CommonConstants.PREFERENCES_BOOK_DATA_KEY;

  // 初始化preferences实例
  initPreferences() {
    this.preferences = dataPreferences.getPreferencesSync(appCtx(), { name: this.preferencesName });
  }

  // 设置数据
  set(key: string, value: dataPreferences.ValueType) {
    if (!this.preferences) {
      this.initPreferences();
    }
    console.log('setinitPreferences', key, value)
    this.preferences?.putSync(key, value);
    this.preferences?.flush();
  }

  // 获取数据
  get(key: string): dataPreferences.ValueType | null | undefined {
    if (!this.preferences) {
      this.initPreferences();
    }
    let value = this.preferences?.getSync(key, null);;
    return value;
  }

  // 删除数据
  delete(key: string) {
    if (!this.preferences) {
      this.initPreferences();
    }
    if (this.preferences?.hasSync(key)) {
      this.preferences.deleteSync(key);
      this.preferences.flush();
    }
  }
}

