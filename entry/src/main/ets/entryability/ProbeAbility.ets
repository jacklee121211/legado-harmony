/**
 * ⚠️ POC 取证 Ability（2026-10-19）：验证「PDF 页图 → epub → ReaderKit」这条路。
 *    POC 结束后应删除本文件、PdfProbePage.ets、rawfile/poc_pages.epub、rawfile/poc_sample.pdf
 *    与 module.json5 里的对应条目。
 *    启动方式：hdc shell aa start -a ProbeAbility -b com.jk.reader
 */
import { UIAbility, AbilityConstant, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';

const DOMAIN: number = 0x0000;
const TAG: string = 'PdfProbe';

export default class ProbeAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(DOMAIN, TAG, 'ProbeAbility onCreate');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    hilog.info(DOMAIN, TAG, 'ProbeAbility onWindowStageCreate');
    windowStage.loadContent('pages/PdfProbePage', (err: BusinessError) => {
      if (err.code) {
        hilog.error(DOMAIN, TAG, 'loadContent failed: %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(DOMAIN, TAG, 'loadContent ok');
    });
  }

  onWindowStageDestroy(): void {
    hilog.info(DOMAIN, TAG, 'ProbeAbility onWindowStageDestroy');
  }

  onDestroy(): void {
    hilog.info(DOMAIN, TAG, 'ProbeAbility onDestroy');
  }
}
