import { common } from '@kit.AbilityKit';
import { resourceManager } from '@kit.LocalizationKit';
import { UIContext } from '@kit.ArkUI';
import { AppError } from './Errors';

/**
 * 资源读取工具。
 *
 * 存在的原因：CL-7 要求所有文案与颜色资源化，但服务层与 Canvas 需要拿到**具体值**：
 *   - CSV 表头/状态文字、报告标题与水印、系统通知文案 → 需要 string；
 *   - Canvas 的 fillStyle/strokeStyle → 需要数值色。
 *
 * 因此统一在此处解析。所有方法**显式要求传入 context**，
 * 不使用裸 getContext()，避免在非组件上下文中取不到资源管理器。
 *
 * 分层：本文件位于 common 层，pages / components / service 均可依赖。
 * 为保证 GradeService / StatsService / ImportService / ReportService 的纯函数性质，
 * 这些服务**不直接**调用本类，而是由页面解析好字符串后以参数传入（见 common/Vocab.ets）。
 */
export class ResUtils {
  /** 取纯文案 */
  static text(context: common.UIAbilityContext, res: Resource): string {
    return ResUtils.manager(context).getStringSync(res.id);
  }

  /** 取带占位符的文案，args 依次替换 %s / %d（getStringSync 为可变参数，需展开传入） */
  static format(context: common.UIAbilityContext, res: Resource, args: Array<string | number>): string {
    return ResUtils.manager(context).getStringSync(res.id, ...args);
  }

  /**
   * 颜色数值（0xAARRGGBB）。
   * Canvas 的 fillStyle / strokeStyle 原生支持数字色值，故直接返回数值，
   * 省去字符串拼接与格式假设，也避免各页面自行推导颜色格式。
   */
  static colorValue(context: common.UIAbilityContext, res: Resource): number {
    return ResUtils.manager(context).getColorSync(res.id);
  }

  private static manager(context: common.UIAbilityContext): resourceManager.ResourceManager {
    return context.resourceManager;
  }

  /**
   * 组件内取宿主 UIAbility 上下文 —— `getContext(this)` 的现代替代。
   *
   * 为什么迁移：`getContext(this)` 自 API 12 起被标记废弃（API 26 仍可用但官方推荐
   * 统一走 UIContext），SDK 升级到 26.0.0 后按官方迁移指引替换。
   *
   * 与裸 `getContext(this)` 的差别：`getHostContext()` 在组件**尚未挂载**时会返回 undefined。
   * 本工程所有调用点都发生在挂载之后（事件回调 / aboutToAppear 的异步链 / Canvas onReady），
   * 该分支实际不可达 —— 但仍显式抛错而非裸断言，让「不可能」的情况崩得明白、可定位。
   */
  static hostContext(ui: UIContext): common.UIAbilityContext {
    const ctx = ui.getHostContext();
    if (ctx === undefined) {
      throw new AppError(1001, 'UIContext.getHostContext() returned undefined (component not mounted yet)');
    }
    return ctx as common.UIAbilityContext;
  }
}
