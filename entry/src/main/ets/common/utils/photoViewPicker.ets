/**
 * @author 2008
 * @datetime 2024/5/27 0:09
 * @className: photoViewPicker
 * 图片选择工具
 *
 * ── T13/D-18（Round 38）：从 `@ohos.file.picker` 迁到 `photoAccessHelper` ────────────────
 * 官方依据（SDK 原文，逐符号核对 `…\ets\api\@ohos.file.picker.d.ts`）：
 *  · `PhotoViewMIMETypes`            `@deprecated since 12` → `@useinstead photoAccessHelper.PhotoViewMIMETypes`
 *    （`.` 成员 `IMAGE_TYPE` 另标 `@deprecated since 18` → `…PhotoViewMIMETypes.IMAGE_TYPE`，`d.ts:41-52`）
 *  · `PhotoSelectOptions`            `@deprecated since 12` → `photoAccessHelper.PhotoSelectOptions`（`d.ts:82-85`）
 *    （`.MIMEType` / `.maxSelectNumber` 另标 `@deprecated since 18` → `…PhotoSelectOptions#MIMEType/#maxSelectNumber`，`d.ts:94-108`）
 *  · `PhotoViewPicker`               `@deprecated since 12` → `photoAccessHelper.PhotoViewPicker`（`d.ts:173-176`）
 *    （`select()` 另标 `@deprecated since 18`，`d.ts:215-216`）
 *  · `PhotoSelectResult` / `photoUris` `@deprecated since 12 / 18` → `photoAccessHelper.PhotoSelectResult#photoUris`（`d.ts:116-132`）
 *
 * **形状完全一致**（`…\ets\api\@ohos.file.photoAccessHelper.d.ts`）：
 *  · `class PhotoViewPicker { select(option?: PhotoSelectOptions): Promise<PhotoSelectResult>; … }`（L4443/L4474），
 *    类体内**没有显式 constructor** ⇒ 与旧版一样 `new PhotoViewPicker()` 无参可构造；
 *  · `class BaseSelectOptions { MIMEType?: PhotoViewMIMETypes; maxSelectNumber?: number; }`（L3701/L3710/L3719，`@since 10`）；
 *  · `class PhotoSelectResult { photoUris: Array<string>; … }`（L4387/L4401，`@since 10`）。
 *
 * ⚠️ **唯一实质差异：`@syscap` 不同** ——
 *    旧 `select` 是 `SystemCapability.FileManagement.UserFileService`（`@ohos.file.picker.d.ts:212`），
 *    新的是 `SystemCapability.FileManagement.PhotoAccessHelper.Core`（`@ohos.file.photoAccessHelper.d.ts:4469`）。
 *    系统选择器属"系统行为"，无法本地验证 ⇒ **默认关闭**，待真机验证后再改 `true`。
 *    回退 = 把下面这一行改回 `false`（旧路径逐字保留）。
 *
 * 另外记一笔（**与本迁移无关的既有风险**，两版 NOTE 措辞相同）：
 *  `photoUris` 原文均写「can be used only by calling `photoAccessHelper.getAssets`」，
 *  而调用方 `coverInfoDialog.ets:131-132` 是**直接把它当图片地址**存进 `coverUrl`。
 *  该用法是否需要改（例如先经 `getAssets` 换成本地路径）**需真机验证**，见审计 §27-4。
 */
import picker from '@ohos.file.picker';
import { photoAccessHelper } from '@kit.MediaLibraryKit';

/** T13/D-18：图片选择器实现开关。`false` = 旧行为（`@ohos.file.picker`）。 */
const PHOTO_PICKER_USE_PHOTOACCESSHELPER: boolean = false;

/**
 * 新路径所需的 SysCap —— 这是新旧实现的**唯一实质差异**（见文件头 §syscap 说明）。
 * SDK `@ohos.file.photoAccessHelper.d.ts:4469` 原文：`@syscap SystemCapability.FileManagement.PhotoAccessHelper.Core`。
 * 开关打开时先用 `canIUse` 预判：能力缺失则**自动回退**旧实现
 * （与 D-19 音频 SysCap 的做法一致；`canIUse` 是全局函数，声明见
 * `…\ets\api\@internal\full\global.d.ts:374`，无需 import）。
 */
const SYSCAP_PHOTO_ACCESS_HELPER: string = 'SystemCapability.FileManagement.PhotoAccessHelper.Core';

/**
 * 让用户从系统相册选一张图片。
 * @returns 所选图片的 URI 列表；用户取消时为空数组（**调用方据此把封面清空**，与旧行为一致）
 */
export const pickerAvatar = async (): Promise<string[]> => {
  // 开关打开 **且** 设备具备 `PhotoAccessHelper.Core` 时才走新路径；否则回退旧实现。
  if (PHOTO_PICKER_USE_PHOTOACCESSHELPER && canIUse(SYSCAP_PHOTO_ACCESS_HELPER)) {
    // ---------- 新路径：photoAccessHelper（官方 @useinstead）----------
    // 实例化选项对象
    const options = new photoAccessHelper.PhotoSelectOptions();
    // 过滤选择媒体文件类型为 IMAGE——只能选择图片类型的资源
    options.MIMEType = photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE;
    // 只能选择一张系统相册中的照片
    options.maxSelectNumber = 1;
    // 利用 PhotoViewPicker 对象实例中的 select 自动获取到用户选择的那张图片的地址
    const pickerView = new photoAccessHelper.PhotoViewPicker();
    const urls = await pickerView.select(options);
    return urls.photoUris;
  }

  // ---------- 旧路径（默认，逐字保留）----------
  // 实例化选项对象
  const options = new picker.PhotoSelectOptions()
  // 过滤选择媒体文件类型为IMAGE——只能选择图片类型的资源
  options.MIMEType = picker.PhotoViewMIMETypes.IMAGE_TYPE
  // 只能选择一张系统相册中的照片
  options.maxSelectNumber = 1

  // 利用PhotoViewPicker对象实例中的select自动获取到用户选择的那张图片的地址
  const pickerView = new picker.PhotoViewPicker()
  const urls = await pickerView.select(options)
  return urls.photoUris
}
