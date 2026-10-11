import { AbilityConstant, Configuration, UIAbility, Want, common } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { DateUtils } from '../common/DateUtils';
import { Logger } from '../common/Logger';
import { Prefs } from '../common/Prefs';
import { ResUtils } from '../common/ResUtils';
import { ReminderConst } from '../common/Constants';
import { VocabFactory } from '../common/Vocab';
import { Medication, MedLog, MedPlan, ReminderCapability } from '../model/Med';
import { MedLogStatus, ReminderMode } from '../model/Types';
import { BpDatabase } from '../service/BpDatabase';
import { MedService } from '../service/MedService';
import { ReminderService } from '../service/ReminderService';

const TAG: string = 'EntryAbility';

/**
 * 应用入口（stage 模型，单 EntryAbility）。
 *
 * 启动链路：
 *   1. 初始化数据库（建表 + 版本迁移），失败不阻断启动，由首页展示错误提示（CL-1）；
 *   2. 加载首页；
 *   3. 每次切到前台：标记漏服（FR-9.4）并按当前生效计划重建提醒（FR-8.3 / FR-9.1）。
 */
export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    Logger.info(TAG, 'onCreate');
    this.initDatabase();
  }

  onDestroy(): void {
    Logger.info(TAG, 'onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    windowStage.loadContent('pages/Index', (err) => {
      if (err.code !== 0) {
        Logger.error(TAG, `loadContent failed: code=${err.code}, message=${err.message}`);
        return;
      }
      Logger.info(TAG, 'page content loaded');
    });
  }

  onWindowStageDestroy(): void {
    Logger.info(TAG, 'onWindowStageDestroy');
  }

  onForeground(): void {
    Logger.info(TAG, 'onForeground');
    this.onEnterForeground();
  }

  onBackground(): void {
    Logger.info(TAG, 'onBackground');
  }

  /**
   * 系统配置变更（含**深浅色切换**）。
   *
   * 声明式组件会随配置重新解析 `$r()` 资源，但 **Canvas 是命令式绘制的，已画出的像素不会自动重来**。
   * 这里递增一个版本号写进 AppStorage，图表组件用 `@StorageProp @Watch` 监听后自行重绘
   * （见 BpLineChart 的 themeVersion）。
   */
  onConfigurationUpdate(newConfig: Configuration): void {
    const last = AppStorage.get<number>('themeVersion');
    const version: number = (last === undefined ? 0 : last) + 1;
    AppStorage.setOrCreate('themeVersion', version);
    Logger.info(TAG, `configuration updated, themeVersion=${version}, colorMode=${newConfig.colorMode}`);
  }

  /** 数据库初始化：失败仅记录日志，首页会展示「数据库初始化失败」提示 */
  private async initDatabase(): Promise<void> {
    try {
      await BpDatabase.getInstance().init(this.context);
    } catch (err) {
      const e = err as BusinessError;
      Logger.error(TAG, `database init failed: code=${e.code}, message=${e.message}`);
    }
  }

  /**
   * 前台任务：漏服标记 + 提醒重建。
   * 提醒重建带计划签名幂等判断，计划未变化时不会重复发布（见 ReminderService）。
   */
  private async onEnterForeground(): Promise<void> {
    const db: BpDatabase = BpDatabase.getInstance();
    // v1.15 修复（真机发现）：**冷启动时 onForeground 早于 onCreate 的 initDatabase 完成**
    // （实测 onCreate 22:59:05.836 → onForeground .893 → 数据库 ready .011，差近 100ms）。
    // 原先这里 `if (!db.isReady()) return;`，于是冷启动时下面这一整段前台任务会被**静默跳过**：
    // 漏服标记、过期计划自动停用、提醒重建、补发通知 —— 而「计划到期后第一次打开 App」恰恰是冷启动。
    // init 是幂等的（见 BpDatabase.init），这里等它完成再继续；真正初始化失败才放弃。
    try {
      await db.init(this.context);
    } catch (err) {
      const e = err as BusinessError;
      Logger.error(TAG, `foreground task skipped, database not ready: code=${e.code}, message=${e.message}`);
      return;
    }
    const context: common.UIAbilityContext = this.context;
    const now: number = DateUtils.now();
    try {
      // 1) 超过计划时间 2h 仍未打卡的 pending → missed
      const missed: number = await db.markMissed(now);
      if (missed > 0) {
        Logger.info(TAG, `marked ${missed} overdue logs as missed`);
      }

      // 2) 读取当前生效计划；先把 end_date 已过的计划自动停用（v1.15 / 裁决 D3）
      let plans: MedPlan[] = await db.queryActivePlans();
      const meds: Medication[] = await db.queryMedications();

      // 1b) 过期计划自愈：系统侧的每日代理闹钟（daysOfWeek 无限重复）**没有结束日期参数**，
      //     若计划过了 end_date 却仍在 isActive，用户停药后只要不再打开 App 就会一直收到提醒。
      //     这里把它停用并清掉「未来且仍 pending」的待服实例；已服 / 跳过 / 漏服等历史打卡一律不动
      //     （与 FR-8.3 手动停用同一条清理通路，见策划 §10 风险表）。
      const expiredIds: number[] = MedService.expiredPlanIds(plans, DateUtils.formatDate(now));
      if (expiredIds.length > 0) {
        for (let i = 0; i < plans.length; i++) {
          const plan: MedPlan = plans[i];
          if (expiredIds.indexOf(plan.id) < 0) {
            continue;
          }
          await db.deactivatePlan(plan.id);
          await db.deleteFuturePendingLogs(plan.medicationId, now);
        }
        plans = await db.queryActivePlans();
        Logger.info(TAG, `auto-deactivated ${expiredIds.length} expired plan(s)`);
      }

      const capability = await ReminderService.rebuildAll(context, plans, meds,
        VocabFactory.reminder(context), now, false);
      Logger.info(TAG, `reminder mode: ${capability.mode}, agentAvailable=${capability.agentAvailable}`);

      // 2b) v1.14：有生效服药计划、却因为通知未授权而发不出提醒时，主动请求一次授权。
      //     此前只有设置页那一行会请求授权，于是「从没进过设置页」的用户永远收不到提醒，
      //     且界面不报错 —— 这正是用户报的「设置了用药提醒但不生效」。
      //     用 Prefs 标记保证每次安装至多弹一次系统授权框；用户拒绝后不再骚扰，
      //     改由用药页警示卡与设置页「已登记提醒」继续如实告知（见 ReminderService）。
      const slotCount: number = MedService.planSlotsOf(now, plans, meds).length;
      if (slotCount > 0 && capability.mode !== ReminderMode.AGENT && !capability.notificationEnabled
        && !Prefs.isNotifyAsked(context)) {
        Prefs.markNotifyAsked(context);
        const granted: boolean = await ReminderService.ensureNotificationEnabled(context);
        Logger.info(TAG, `notification authorization requested at launch, granted=${granted}`);
        if (granted) {
          const repaired = await ReminderService.rebuildAll(context, plans, meds,
            VocabFactory.reminder(context), now, true);
          Logger.info(TAG, `reminders republished after grant: mode=${repaired.mode}`);
        }
      }

      // 3) 第三条回退路径：代理提醒不可用时，进入前台补发「今日漏服」提醒（每日至多一次）。
      //    这是平台能力边界内的诚实降级——API 12 的本地通知无法在进程结束后定时唤醒。
      if (capability.mode !== ReminderMode.AGENT) {
        const todayLogs: MedLog[] = await db.queryMedLogsOfDay(now);
        let missed: number = 0;
        for (let i = 0; i < todayLogs.length; i++) {
          if (MedService.resolveStatus(todayLogs[i], now) === MedLogStatus.MISSED) {
            missed++;
          }
        }
        const notified: boolean = await ReminderService.notifyCatchUpOncePerDay(context, missed,
          ResUtils.text(context, $r('app.string.reminder_catchup_title')),
          ResUtils.format(context, $r('app.string.reminder_catchup_text'), [missed]),
          ReminderConst.NOTIFICATION_BASE + 100);
        if (notified) {
          Logger.info(TAG, `catch-up notification sent for ${missed} missed doses`);
        }
      }
    } catch (err) {
      const e = err as BusinessError;
      Logger.error(TAG, `foreground task failed: code=${e.code}, message=${e.message}`);
    }
  }
}
