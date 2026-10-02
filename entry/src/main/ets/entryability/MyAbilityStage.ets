import AbilityStage from '@ohos.app.ability.AbilityStage';
import type { Configuration } from '@ohos.app.ability.Configuration';
import { ezCustomTransition } from '../common/ezlt';

/**
 * AbilityStage（2026-10-02 新建，一镜到底官方库迁移 Step 3）。
 *
 * 此前工程没有 AbilityStage（启动日志 "Not found AbilityStage.js"）。
 * 官方库要求在 onConfigurationUpdate 里接收深浅色/语言等配置变更，
 * 转场参数才能正确刷新（skill: hmos-arkui-longtake-transition Step 3）。
 * module.json5 已注册 srcEntry。
 */
export default class MyAbilityStage extends AbilityStage {
  onConfigurationUpdate(newConfig: Configuration): void {
    ezCustomTransition.onConfigurationChanged();
  }
}
