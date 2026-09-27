import { promptAction } from '@kit.ArkUI'
import ImmersiveMaterialUtil from '../../common/utils/ImmersiveMaterialUtil'

/**
 * 自定义提示
 * @param message
 *
 * 2026-09-21：接入**沉浸光感**（API 26 新增的系统材质）。
 * 官方文档 `…/沉浸光感开发指导/组件适配沉浸光感/…`「即时反馈（Toast）」一节原文：
 *   「组件级开启：Toast 支持通过 `ShowToastOptions` 中的 `systemMaterial` 字段设置沉浸光感效果。」
 *   「沉浸光感开启后，如果已主动设置 `ShowToastOptions` 中的 `backgroundBlurStyle` 或
 *     `backgroundColor`，则**不呈现**沉浸光感效果」——所以这里刻意**不设**这两个属性。
 * 关闭方式见 `ImmersiveMaterialUtil.ENABLED`（改 false 即全工程回退）。
 */
export function showMessage(message:string ,showDuration:number = 1000){
  promptAction.showToast({
    message: message,
    duration: showDuration,
    systemMaterial: ImmersiveMaterialUtil.feedbackMaterial(),
  })
}