import { UIAbility, Want, AbilityConstant } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { setTestAbilityContext } from './TestContext';

const DOMAIN: number = 0xB000;
const TAG: string = 'TestAbility';

/** ohosTest 的入口 Ability：加载测试页，实际测试由 OpenHarmonyTestRunner 驱动 */
export default class TestAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'TestAbility onCreate');
    // 把本 Ability 的真实 context 暴露给需要系统能力的单测（如 relationalStore）。
    // aa test 进程里 delegator 拿来的 context 会被 native 层判为 Illegal context。
    setTestAbilityContext(this.context);
  }

  onDestroy(): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'TestAbility onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'TestAbility onWindowStageCreate');
    windowStage.loadContent('testability/pages/Index', (err) => {
      if (err.code !== 0) {
        hilog.error(DOMAIN, TAG, 'loadContent failed: %{public}s', err.message);
      }
    });
  }

  onWindowStageDestroy(): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'TestAbility onWindowStageDestroy');
  }
}
