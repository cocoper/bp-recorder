import { common } from '@kit.AbilityKit';
import { reminderAgentManager } from '@kit.BackgroundTasksKit';
import { notificationManager } from '@kit.NotificationKit';
import { preferences } from '@kit.ArkData';
import { BusinessError } from '@kit.BasicServicesKit';
import { SlotInstance } from '../model/BpRecord';
import { Medication, MedPlan, ReminderCapability, ReminderSyncResult } from '../model/Med';
import { ReminderMode, parseReminderMode } from '../model/Types';
import { PrefKeys, ReminderConst } from '../common/Constants';
import { DateUtils } from '../common/DateUtils';
import { Logger } from '../common/Logger';
import { ReminderVocab } from '../common/Vocab';
import { MedService, SlotGroup } from './MedService';
import { BpDatabase } from './BpDatabase';   // 仅用于 syncFromDatabase：不反向依赖，无环
import { MedLifecycleService } from './MedLifecycleService';

/** 期望提醒的一段（时点 × 药品集合 × 生效区间），审查 R04/R03 */
export interface ExpectedReminder {
  /** 业务键：分钟@起日~止日#内容 */
  key: string;
  /** 当天分钟数 */
  minutes: number;
  fromDate: string;
  /** '' = 长期 */
  toDate: string;
  content: string;
  /** true → 用日历型提醒（有结束日或未来才开始） */
  bounded: boolean;
  /** 首次触发时刻 */
  firstTs: number;
  /** 结束时刻（0 = 长期） */
  endTs: number;
}

const TAG: string = 'ReminderService';

/**
 * 服药提醒调度（FR-9.1 / FR-8.4）。
 *
 * 双路径设计：
 * - **主路径**：系统后台代理提醒 reminderAgent —— App 未启动 / 锁屏也能触发。
 *   前置条件是**两条**，缺一条都发不出提醒（v1.14 修复「设了提醒却不响」）：
 *   ① `module.json5` 声明 `ohos.permission.PUBLISH_AGENT_REMINDER`
 *      （SDK 的 `PermissionDefinitions.json` 标注为 `grantMode: system_grant` /
 *      `availableLevel: normal`，安装即授予，**无需 AGC 开放能力或手动签名**）；
 *   ② **必须已获得通知授权** —— 官方 `publishReminder` JSDoc 写明
 *      「This API can be called only after the notificationManager.requestEnableNotification
 *      permission is obtained」，未授权时抛 `1700001 Notification is not enabled`。
 *      因此 `ensureNotificationEnabled()` 是发提醒前必须先走的一步。
 * - **回退路径**：本地通知 NotificationKit —— 到点由系统发出通知，
 *   但**前提是 App 进程存活**（无法在 App 完全退出后自行唤醒），这是平台约束。
 *
 * 首轮会做一次真实能力探测（发布一条 10 秒倒计时提醒后立即取消），
 * 结论缓存到 Preferences，避免每次启动都触发探测。设置页展示当前生效方式。
 * 探测只用于「展示与降级判断」：只要通知已授权，`rebuildAll` 仍会按计划真实发布一次，
 * 发布成功即把方式修回 AGENT（避免探测与真实闹钟类型差异造成误判）。
 *
 * 合并规则（FR-8.4）：同一时间点的多个药品合并为一条提醒。
 */
export class ReminderService {
  // ───────────────────────── 能力探测 ─────────────────────────

  /** 读取上次探测结论（未探测过返回 null） */
  static cachedMode(context: common.Context): ReminderMode | null {
    try {
      const prefs: preferences.Preferences = ReminderService.prefs(context);
      const raw: string = prefs.getSync(PrefKeys.REMINDER_MODE, '') as string;
      if (raw === null || raw === undefined || raw.length === 0) {
        return null;
      }
      return parseReminderMode(raw);
    } catch (err) {
      const e = err as BusinessError;
      Logger.warn(TAG, `read cached mode failed: ${e.message}`);
      return null;
    }
  }

  private static saveMode(context: common.Context, mode: ReminderMode): void {
    try {
      const prefs: preferences.Preferences = ReminderService.prefs(context);
      prefs.putSync(PrefKeys.REMINDER_MODE, `${mode}`);
      prefs.flush();
    } catch (err) {
      const e = err as BusinessError;
      Logger.warn(TAG, `save mode failed: ${e.message}`);
    }
  }

  private static prefs(context: common.Context): preferences.Preferences {
    return preferences.getPreferencesSync(context, { name: PrefKeys.STORE });
  }

  /**
   * 探测当前可用的提醒方式。
   * @param force true 时忽略缓存，重新做一次真实探测（设置页「重新检测」使用）
   */
  static async probe(context: common.UIAbilityContext, force: boolean, vocab: ReminderVocab): Promise<ReminderCapability> {
    const notificationEnabled: boolean = await ReminderService.isNotificationEnabled();

    if (!force) {
      const cached: ReminderMode | null = ReminderService.cachedMode(context);
      if (cached !== null) {
        return {
          mode: cached,
          agentAvailable: cached === ReminderMode.AGENT,
          notificationEnabled: notificationEnabled,
          detail: 'cached'
        };
      }
    }

    let agentAvailable: boolean = false;
    let detail: string = '';
    try {
      const reminderId: number = await ReminderService.publishProbe(context, vocab);
      if (reminderId >= 0) {
        agentAvailable = true;
        try {
          await reminderAgentManager.cancelReminder(reminderId);
        } catch (cancelErr) {
          const ce = cancelErr as BusinessError;
          Logger.warn(TAG, `cancel probe reminder failed: code=${ce.code}, message=${ce.message}`);
        }
      }
    } catch (err) {
      const e = err as BusinessError;
      agentAvailable = false;
      detail = `code=${e.code}, message=${e.message}`;
      Logger.warn(TAG, `agent reminder unavailable: ${detail}`);
    }

    const mode: ReminderMode = agentAvailable ? ReminderMode.AGENT
      : (notificationEnabled ? ReminderMode.NOTIFICATION : ReminderMode.DENIED);
    ReminderService.saveMode(context, mode);
    Logger.info(TAG, `reminder mode resolved: ${mode}, detail=${detail}`);
    return {
      mode: mode,
      agentAvailable: agentAvailable,
      notificationEnabled: notificationEnabled,
      detail: detail
    };
  }

  /** 发布一条 10 秒后的倒计时提醒作为能力探测 */
  private static async publishProbe(context: common.UIAbilityContext, vocab: ReminderVocab): Promise<number> {
    const request: reminderAgentManager.ReminderRequestTimer = {
      reminderType: reminderAgentManager.ReminderType.REMINDER_TYPE_TIMER,
      triggerTimeInSeconds: 10,
      title: vocab.title,
      content: vocab.title,
      expiredContent: vocab.expiredContent,
      notificationId: ReminderConst.NOTIFICATION_BASE,
      slotType: notificationManager.SlotType.SOCIAL_COMMUNICATION,
      wantAgent: {
        pkgName: ReminderService.bundleName(context),
        abilityName: 'EntryAbility'
      },
      actionButton: [
        {
          title: vocab.actionClose,
          type: reminderAgentManager.ActionButtonType.ACTION_BUTTON_TYPE_CLOSE
        }
      ]
    };
    return reminderAgentManager.publishReminder(request);
  }

  private static bundleName(context: common.UIAbilityContext): string {
    try {
      return context.abilityInfo.bundleName;
    } catch (err) {
      const e = err as BusinessError;
      Logger.warn(TAG, `read bundleName failed: ${e.message}`);
      return '';
    }
  }

  // ───────────────────────── 通知授权 ─────────────────────────

  static async isNotificationEnabled(): Promise<boolean> {
    try {
      return await notificationManager.isNotificationEnabled();
    } catch (err) {
      const e = err as BusinessError;
      Logger.warn(TAG, `isNotificationEnabled failed: ${e.message}`);
      return false;
    }
  }

  /** 首次运行或用户点击时申请通知授权 */
  static async requestEnable(context: common.UIAbilityContext): Promise<boolean> {
    try {
      await notificationManager.requestEnableNotification(context);
      return true;
    } catch (err) {
      const e = err as BusinessError;
      Logger.warn(TAG, `requestEnableNotification failed: code=${e.code}, message=${e.message}`);
      return false;
    }
  }

  /**
   * 确保通知已授权（v1.14：代理提醒的前置条件，见类头注释）。
   *
   * 已授权时直接返回 `true`，**不弹窗**；未授权时才弹一次系统授权框并复查结果。
   * 调用点：用药计划保存后（用户刚设完提醒时间，授权意图最明确）、
   *         用药页警示卡的「开启提醒」按钮、设置页「通知授权」行。
   */
  static async ensureNotificationEnabled(context: common.UIAbilityContext): Promise<boolean> {
    if (await ReminderService.isNotificationEnabled()) {
      return true;
    }
    Logger.info(TAG, 'notification not enabled, requesting authorization');
    await ReminderService.requestEnable(context);
    const enabled: boolean = await ReminderService.isNotificationEnabled();
    Logger.info(TAG, `notification enabled after request: ${enabled}`);
    return enabled;
  }

  /**
   * 系统当前仍有效（未过期）的代理提醒条数（v1.14，设置页/用药页自查用）。
   * 0 条 = 提醒没有真正登记到系统里；-1 = 查询失败（无权限或系统不支持）。
   */
  static async validReminderCount(): Promise<number> {
    try {
      const list: reminderAgentManager.ReminderInfo[] = await reminderAgentManager.getAllValidReminders();
      return list.length;
    } catch (err) {
      const e = err as BusinessError;
      Logger.warn(TAG, `getAllValidReminders failed: code=${e.code}, message=${e.message}`);
      return -1;
    }
  }

  // ───────────────────────── 提醒重建 ─────────────────────────

  /**
   * 新增 / 修改 / 停用计划后重建全部提醒（FR-9.1）。
   * 重建策略：先取消本应用全部代理提醒，再按当前生效计划重新发布，避免残留。
   *
   * 优化：以「影响提醒的字段」签名做幂等判断 —— 计划未变化时直接跳过重建，
   * 避免每次切回前台都重新发布全部提醒；签名相同但系统里查不到有效提醒时仍会重建（自愈，v1.14）。
   *
   * @param force true 时忽略签名，强制重建（设置页「重新检测」使用）
   */
  /**
   * 按**当前全量生效计划**协调系统提醒（审查 R02）。
   *
   * 归档 / 停用 / 恢复药品后必须走这里，而不是 `cancelAll()`：
   * - 先原子改数据库（由调用方完成），再读**最新全量**生效计划；
   * - 期望集合与系统实际提醒做协调，只有「所有计划都无需提醒」或清空数据时期望集合才为空；
   * - 单药停用**不允许**实现成最终的全量取消（B 的提醒必须完整保留）。
   */
  static async syncFromDatabase(context: common.UIAbilityContext, db: BpDatabase,
    vocab: ReminderVocab, now: number): Promise<ReminderSyncResult> {
    const plans: MedPlan[] = await db.queryActivePlans();
    const meds: Medication[] = await db.queryMedications();
    const result: ReminderSyncResult = await ReminderService.sync(context, plans, meds, vocab, now, true);
    Logger.info(TAG, `reminders synced from database: activePlans=${plans.length}, status=${result.status}`);
    return result;
  }

  /** 提醒协调串行队列（审查 R05.3）：两个 cancelAll→publish 流程不得交错执行 */
  private static syncQueue: Promise<void> = Promise.resolve();

  private static async runExclusive<T>(work: () => Promise<T>): Promise<T> {
    const previous: Promise<void> = ReminderService.syncQueue;
    let release: () => void = () => {};
    ReminderService.syncQueue = new Promise<void>((resolve: () => void) => {
      release = resolve;
    });
    await previous;
    try {
      return await work();
    } finally {
      release();
    }
  }

  /**
   * 期望提醒集合（审查 R04.3 / R03.2）：把「时间点 × 药品生效区间」展开成段，
   * 同一时点的药品按各自有效区间切成区段 —— 例如 A 长期 08:00、B 仅 10-11 一天：
   * 11 日那一段内容为 A+B，12 日起只剩 A。这样签名的依据是**期望集合**，而不是源计划文本。
   */
  static expectedReminders(plans: MedPlan[], meds: Medication[], now: number): ExpectedReminder[] {
    interface Item { minutes: number; from: number; to: number; text: string; }
    const items: Item[] = [];
    const medIndex: Map<number, Medication> = new Map<number, Medication>();
    for (let i = 0; i < meds.length; i++) {
      medIndex.set(meds[i].id, meds[i]);
    }
    for (let i = 0; i < plans.length; i++) {
      const plan: MedPlan = plans[i];
      if (!plan.isActive) {
        continue;
      }
      const med: Medication | undefined = medIndex.get(plan.medicationId);
      if (med === undefined || !med.isActive) {
        continue;
      }
      const winFrom: number = Math.max(MedLifecycleService.effectiveFrom(plan), now);
      // 有结束日期 → 以结束日当天 23:59 为界；无结束日期 → 0 表示长期
      const endTs: number | null = MedService.endInstantOf(plan);
      if (endTs !== null && endTs < now) {
        continue;
      }
      const to: number = endTs === null ? 0 : endTs;
      for (let k = 0; k < plan.timeSlots.length; k++) {
        const minutes: number | null = MedService.slotMinutes(plan.timeSlots[k]);
        if (minutes === null) {
          continue;
        }
        items.push({ minutes: minutes, from: winFrom, to: to, text: `${med.name} ${med.dosage}` });
      }
    }

    // 同一分钟按时点/区间边界切段
    const byMinute: Map<number, Item[]> = new Map<number, Item[]>();
    for (let i = 0; i < items.length; i++) {
      const it: Item = items[i];
      const bucket: Item[] | undefined = byMinute.get(it.minutes);
      if (bucket === undefined) {
        byMinute.set(it.minutes, [it]);
      } else {
        bucket.push(it);
      }
    }

    const out: ExpectedReminder[] = [];
    const minutesList: number[] = Array.from(byMinute.keys()).sort((a: number, b: number) => a - b);
    for (let mi = 0; mi < minutesList.length; mi++) {
      const minutes: number = minutesList[mi];
      const group: Item[] = byMinute.get(minutes) as Item[];
      // 边界：所有 from 与 to（0 当无穷大）的集合
      const bounds: number[] = [];
      for (let i = 0; i < group.length; i++) {
        bounds.push(group[i].from);
        if (group[i].to > 0) {
          bounds.push(group[i].to);
        }
      }
      bounds.sort((a: number, b: number) => a - b);
      // 去重：多个药品共用同一有效区间时，边界只有一个，否则会切出零长区段
      const uniq: number[] = [];
      for (let i = 0; i < bounds.length; i++) {
        if (i === 0 || bounds[i] !== bounds[i - 1]) {
          uniq.push(bounds[i]);
        }
      }
      for (let bi = 0; bi < uniq.length; bi++) {
        const segStart: number = uniq[bi];
        const segEnd: number = bi + 1 < uniq.length ? uniq[bi + 1] : 0;
        if (segEnd > 0 && segEnd <= segStart) {
          continue;
        }
        if (segEnd === 0) {
          // 开放的尾段：只有当确实存在「没有结束日期」的药品时才成立
          let hasOpen: boolean = false;
          for (let i = 0; i < group.length; i++) {
            if (group[i].to === 0) {
              hasOpen = true;
            }
          }
          if (!hasOpen) {
            continue;
          }
        }
        const names: string[] = [];
        for (let i = 0; i < group.length; i++) {
          const it: Item = group[i];
          if (it.from <= segStart && (it.to === 0 || it.to >= segStart)) {
            names.push(it.text);
          }
        }
        if (names.length === 0) {
          continue;
        }
        const fromDate: string = DateUtils.formatDate(segStart);
        const toDate: string = segEnd === 0 ? '' : DateUtils.formatDate(segEnd);
        const content: string = names.join('|');
        const bounded: boolean = segEnd > 0 || segStart > now;
        out.push({
          key: `${minutes}@${fromDate}~${toDate}#${content}`,
          minutes: minutes,
          fromDate: fromDate,
          toDate: toDate,
          content: content,
          bounded: bounded,
          firstTs: ReminderService.firstTrigger(segStart, minutes, now),
          endTs: segEnd
        });
      }
    }
    return out;
  }

  /** 首次触发时刻：从区间起点当天起，取第一个「>= now」的该时点 */
  static firstTrigger(segStart: number, minutes: number, now: number): number {
    let ts: number = DateUtils.atMinutesOfDay(segStart, minutes);
    while (ts < now) {
      ts = DateUtils.addDays(ts, 1);
    }
    return ts;
  }

  /** 期望集合的规范化签名（审查 R04.3）：排序后拼接，与源计划文本无关 */
  static signatureOf(expected: ExpectedReminder[]): string {
    const keys: string[] = [];
    for (let i = 0; i < expected.length; i++) {
      keys.push(`${expected[i].key}|${expected[i].bounded ? 'cal' : 'alarm'}`);
    }
    keys.sort();
    return keys.join(';');
  }

  /** 把毫秒时间戳转成 SDK 的 LocalDateTime（月从 1 开始） */
  static localDateTime(ts: number): reminderAgentManager.LocalDateTime {
    const d: Date = new Date(ts);
    return {
      year: d.getFullYear(),
      month: d.getMonth() + 1,
      day: d.getDate(),
      hour: d.getHours(),
      minute: d.getMinutes(),
      second: 0
    };
  }

  /**
   * 协调入口：所有调用都排队执行（内部实现见 rebuildAllLocked）。
   * `sync` 返回结构化结果（审查 R04/R05.1），`rebuildAll` 保留旧签名兼容既有调用方。
   */
  static async sync(context: common.UIAbilityContext, plans: MedPlan[], meds: Medication[],
    vocab: ReminderVocab, now: number, force: boolean = false): Promise<ReminderSyncResult> {
    return ReminderService.runExclusive<ReminderSyncResult>(() =>
      ReminderService.syncLocked(context, plans, meds, vocab, now, force));
  }

  /** 协调入口：所有调用都排队执行（内部实现见 rebuildAllLocked） */
  static async rebuildAll(context: common.UIAbilityContext, plans: MedPlan[], meds: Medication[],
    vocab: ReminderVocab, todayTs: number, force: boolean = false): Promise<ReminderCapability> {
    const result: ReminderSyncResult = await ReminderService.sync(context, plans, meds, vocab, todayTs, force);
    return result.capability;
  }

  /**
   * 协调实现（审查 R04/R03）：期望集合 → 与系统实际提醒比较 → 取消旧项 + 发布缺失项 → 结构化结果。
   * 只有「全部成功」或「本就没有需要提醒的时点」才写签名。
   */
  private static async syncLocked(context: common.UIAbilityContext, plans: MedPlan[], meds: Medication[],
    vocab: ReminderVocab, now: number, force: boolean): Promise<ReminderSyncResult> {
    let capability: ReminderCapability = await ReminderService.probe(context, force, vocab);
    const expected: ExpectedReminder[] = ReminderService.expectedReminders(plans, meds, now);
    const signature: string = ReminderService.signatureOf(expected);
    const base: ReminderSyncResult = {
      expected: expected.length,
      registered: 0,
      failedKeys: [],
      staleKeys: [],
      status: 'complete',
      errors: [],
      capability: capability
    };

    // 通知未授权且代理不可用：如实返回，调用方负责提示
    if (capability.mode !== ReminderMode.AGENT && !capability.notificationEnabled) {
      Logger.warn(TAG, `agent unavailable and notification disabled, skip publishing: ${capability.detail}`);
      base.status = 'permissionDenied';
      base.failedKeys = expected.map((e: ExpectedReminder) => e.key);
      return base;
    }

    const same: boolean = !force && ReminderService.cachedSignature(context) === signature
      && await ReminderService.systemMatches(expected);
    if (same) {
      Logger.info(TAG, 'expected reminder set already registered, skip rebuilding');
      base.registered = expected.length;
      return base;
    }

    try {
      await reminderAgentManager.cancelAllReminders();
    } catch (err) {
      const e = err as BusinessError;
      Logger.error(TAG, `cancelAllReminders failed, abort this round: code=${e.code}, message=${e.message}`);
      base.status = 'failed';
      base.staleKeys = expected.map((item: ExpectedReminder) => item.key);
      base.errors.push(`cancelAllReminders failed: code=${e.code}`);
      return base;
    }

    const pkg: string = ReminderService.bundleName(context);
    for (let i = 0; i < expected.length; i++) {
      const item: ExpectedReminder = expected[i];
      const hour: number = Math.floor(item.minutes / 60);
      const minute: number = item.minutes % 60;
      const want: reminderAgentManager.WantAgent = { pkgName: pkg, abilityName: 'EntryAbility' };
      const notifId: number = ReminderConst.NOTIFICATION_BASE + i;
      let request: reminderAgentManager.ReminderRequestAlarm | reminderAgentManager.ReminderRequestCalendar;
      if (item.bounded) {
        const cal: reminderAgentManager.ReminderRequestCalendar = {
          reminderType: reminderAgentManager.ReminderType.REMINDER_TYPE_CALENDAR,
          dateTime: ReminderService.localDateTime(item.firstTs),
          daysOfWeek: [1, 2, 3, 4, 5, 6, 7],
          title: vocab.title,
          content: item.content,
          expiredContent: vocab.expiredContent,
          snoozeContent: vocab.snoozeContent,
          notificationId: notifId,
          slotType: notificationManager.SlotType.SOCIAL_COMMUNICATION,
          ringDuration: 5,
          wantAgent: want,
          actionButton: [
            { title: vocab.actionClose, type: reminderAgentManager.ActionButtonType.ACTION_BUTTON_TYPE_CLOSE }
          ]
        };
        if (item.endTs > 0) {
          cal.endDateTime = ReminderService.localDateTime(item.endTs);
        }
        request = cal;
      } else {
        const alarm: reminderAgentManager.ReminderRequestAlarm = {
          reminderType: reminderAgentManager.ReminderType.REMINDER_TYPE_ALARM,
          hour: hour,
          minute: minute,
          daysOfWeek: [1, 2, 3, 4, 5, 6, 7],
          title: vocab.title,
          content: item.content,
          expiredContent: vocab.expiredContent,
          snoozeContent: vocab.snoozeContent,
          notificationId: notifId,
          slotType: notificationManager.SlotType.SOCIAL_COMMUNICATION,
          ringDuration: 5,
          wantAgent: want,
          actionButton: [
            { title: vocab.actionClose, type: reminderAgentManager.ActionButtonType.ACTION_BUTTON_TYPE_CLOSE }
          ]
        };
        request = alarm;
      }
      try {
        await reminderAgentManager.publishReminder(request);
        base.registered++;
      } catch (err) {
        const e = err as BusinessError;
        base.failedKeys.push(item.key);
        base.errors.push(`publish failed: code=${e.code}, key=${item.key}`);
        Logger.error(TAG, `publish reminder failed: code=${e.code}, message=${e.message}, key=${item.key}`);
      }
    }

    if (base.failedKeys.length === 0 || expected.length === 0) {
      ReminderService.saveSignature(context, signature);
      base.status = 'complete';
    } else if (base.registered === 0) {
      base.status = 'failed';
    } else {
      base.status = 'partial';
    }

    if (base.registered > 0 && capability.mode !== ReminderMode.AGENT) {
      Logger.info(TAG, 'real reminders published although probe failed, mode repaired to agent');
      ReminderService.saveMode(context, ReminderMode.AGENT);
      capability = {
        mode: ReminderMode.AGENT,
        agentAvailable: true,
        notificationEnabled: true,
        detail: 'repaired: real publish succeeded'
      };
      base.capability = capability;
    }
    Logger.info(TAG, `reminder sync: expected=${base.expected}, registered=${base.registered}, status=${base.status}`);
    return base;
  }

  /** 系统里的提醒是否已与期望集合一致（按业务键逐条比对，而不是只看条数） */
  private static async systemMatches(expected: ExpectedReminder[]): Promise<boolean> {
    try {
      const list: Array<reminderAgentManager.ReminderInfo> = await reminderAgentManager.getAllValidReminders();
      const actual: Set<string> = new Set<string>();
      for (let i = 0; i < list.length; i++) {
        const alarmReq: reminderAgentManager.ReminderRequestAlarm =
          list[i].reminderReq as reminderAgentManager.ReminderRequestAlarm;
        const hour: number = alarmReq.hour === undefined ? 0 : alarmReq.hour;
        const minute: number = alarmReq.minute === undefined ? 0 : alarmReq.minute;
        const minutes: number = hour * 60 + minute;
        const content: string = alarmReq.content === undefined ? '' : alarmReq.content;
        actual.add(`${minutes}#${content}`);
      }
      for (let i = 0; i < expected.length; i++) {
        const item: ExpectedReminder = expected[i];
        if (!actual.has(`${item.minutes}#${item.content}`)) {
          return false;
        }
      }
      return list.length >= expected.length;
    } catch (err) {
      const e = err as BusinessError;
      Logger.warn(TAG, `read valid reminders failed: code=${e.code}, message=${e.message}`);
      return false;
    }
  }

  /**
   * 计划签名：仅包含影响提醒的字段（药品启停/名称/剂量、计划时间点与起止日期）。
   * 仅用于判断「是否需要重建提醒」，不参与业务数据。
   */
  static signature(plans: MedPlan[], meds: Medication[]): string {
    let out: string = '';
    for (let i = 0; i < meds.length; i++) {
      const m: Medication = meds[i];
      if (m.isActive) {
        out += `M${m.id}:${m.name}:${m.dosage};`;
      }
    }
    for (let i = 0; i < plans.length; i++) {
      const p: MedPlan = plans[i];
      if (p.isActive) {
        out += `P${p.id}:${p.medicationId}:${p.timeSlots.join(',')}:${p.startDate}:${p.endDate};`;
      }
    }
    return out;
  }

  private static cachedSignature(context: common.Context): string {
    try {
      const raw: string = ReminderService.prefs(context).getSync(PrefKeys.REMINDER_SIG, '') as string;
      return raw === null || raw === undefined ? '' : raw;
    } catch (err) {
      const e = err as BusinessError;
      Logger.warn(TAG, `read reminder signature failed: ${e.message}`);
      return '';
    }
  }

  private static saveSignature(context: common.Context, signature: string): void {
    try {
      const store: preferences.Preferences = ReminderService.prefs(context);
      store.putSync(PrefKeys.REMINDER_SIG, signature);
      store.flush();
    } catch (err) {
      const e = err as BusinessError;
      Logger.warn(TAG, `save reminder signature failed: ${e.message}`);
    }
  }

  /** 同一时间点的多个药品合并为一条提醒文案（FR-8.4） */
  static buildContent(group: SlotGroup, vocab: ReminderVocab): string {
    let out: string = '';
    for (let i = 0; i < group.items.length; i++) {
      if (i > 0) {
        out += vocab.separator;
      }
      out += `${group.items[i].medName} ${group.items[i].dosage}`;
    }
    return out;
  }

  /** 取消本应用全部代理提醒（清空数据 / 无生效计划时调用） */
  static async cancelAll(): Promise<void> {
    try {
      await reminderAgentManager.cancelAllReminders();
      Logger.info(TAG, 'all agent reminders cancelled');
    } catch (err) {
      const e = err as BusinessError;
      Logger.warn(TAG, `cancelAllReminders failed: code=${e.code}, message=${e.message}`);
    }
  }

  // ───────────────────────── 回退路径：本地通知 ─────────────────────────

  /**
   * 发布一条即时本地通知。
   * 注意：本地通知由应用进程发布，**进程不存活就发不出来**；
   * `NotificationRequest.deliveryTime` 是系统落库时自动生成的时间戳，
   * 不是可供应用预约的发送时间。因此到点唤醒只能依赖代理提醒。
   */
  static async notifyText(title: string, text: string, notificationId: number): Promise<boolean> {
    const request: notificationManager.NotificationRequest = {
      id: notificationId,
      content: {
        notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
        normal: {
          title: title,
          text: text
        }
      }
    };
    // 审查 R05.5：发送失败必须让调用方看见（过去这里吞掉异常，结果「今日已发送」照样被写上，
    // 当天的补发通知再也不会重试）。
    await notificationManager.publish(request);
    Logger.info(TAG, `local notification published: id=${notificationId}`);
    return true;
  }

  /**
   * 第三条回退路径：每日至多一次的「漏服补发」通知（v1.3 审查意见 P0-1）。
   *
   * 使用场景：代理提醒探测失败时的兜底触达（可用性以真机 V1 结论为准，见 docs/运行与部署说明 §6），
   * 且本地通知无法在进程结束后定时唤醒。
   * 此时唯一能真实生效的触达是「用户打开 App 时把错过的服药一并告知」，
   * 而不是假装提醒仍然准时。为避免同一天反复打扰，按自然日去重。
   *
   * @returns 是否真的发出了通知
   */
  static async notifyCatchUpOncePerDay(context: common.Context, missedCount: number,
    title: string, text: string, notificationId: number): Promise<boolean> {
    if (missedCount <= 0) {
      return false;
    }
    const today: string = DateUtils.formatDate(DateUtils.now());
    try {
      const store: preferences.Preferences = ReminderService.prefs(context);
      const last: string = store.getSync(PrefKeys.CATCHUP_DATE, '') as string;
      if (last === today) {
        return false;
      }
      await ReminderService.notifyText(title, text, notificationId);
      store.putSync(PrefKeys.CATCHUP_DATE, today);
      // 审查 R05.5：Preferences 的 flush 是异步的，同步 try/catch 捕不到它的拒绝，必须 await
      await store.flush();
      return true;
    } catch (err) {
      const e = err as BusinessError;
      Logger.warn(TAG, `catch-up notification failed: code=${e.code}, message=${e.message}`);
      return false;
    }
  }
}
