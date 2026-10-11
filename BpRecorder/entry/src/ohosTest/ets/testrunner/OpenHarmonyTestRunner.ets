import { abilityDelegatorRegistry, TestRunner } from '@kit.TestKit';
import { UIAbility, Want, AbilityConstant } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { resourceManager } from '@kit.LocalizationKit';
import { Hypium } from '@ohos/hypium';
import testsuite from '../test/List.test';

const DOMAIN: number = 0xB000;
const TAG: string = 'OpenHarmonyTestRunner';

/**
 * Hypium 测试运行器。
 * 由 DevEco Studio 在运行 ohosTest 时自动加载，无需手动调用。
 */
export default class OpenHarmonyTestRunner implements TestRunner {
  constructor() {
  }

  onPrepare(): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'onPrepare');
  }

  async onRun(): Promise<void> {
    hilog.info(DOMAIN, TAG, '%{public}s', 'onRun');
    const abilityDelegator: abilityDelegatorRegistry.AbilityDelegator = abilityDelegatorRegistry.getAbilityDelegator();
    const context = abilityDelegator.getAppContext();
    const resMgr: resourceManager.ResourceManager = context.resourceManager;
    Hypium.hypiumTest(abilityDelegator, resMgr, testsuite);
  }

  onDestroy(): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'onDestroy');
  }
}

/** 测试用 UIAbility：仅用于承载测试运行环境，无界面逻辑 */
export class TestAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'TestAbility onCreate');
  }

  onDestroy(): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'TestAbility onDestroy');
  }

  onWindowStageCreate(): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'TestAbility onWindowStageCreate');
  }
}
