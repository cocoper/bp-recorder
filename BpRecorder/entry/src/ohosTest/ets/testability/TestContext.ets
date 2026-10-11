import { common } from '@kit.AbilityKit';

/**
 * TestAbility 的真实 UIAbilityContext 持有器。
 *
 * 背景（2026-10-08）：在 `aa test` 启动的测试进程里，无论
 * `abilityDelegatorRegistry.getAbilityDelegator().getAppContext()` 还是
 * `getCurrentTopAbility().context`，都会被 `relationalStore.getRdbStore`
 * 判为「Parameter error. Illegal context.」。唯一被 relationalStore 接受的
 * 是 Ability 自己在 `onCreate` 里拿到的 `this.context`（与生产路径
 * `EntryAbility` 完全一致），因此在 TestAbility 创建时把它存到此处。
 *
 * 仅供 ohosTest 使用；主流程代码不得引用本模块。
 */
let stored: common.Context | null = null;

export function setTestAbilityContext(context: common.Context): void {
  stored = context;
}

export function getTestAbilityContext(): common.Context | null {
  return stored;
}
