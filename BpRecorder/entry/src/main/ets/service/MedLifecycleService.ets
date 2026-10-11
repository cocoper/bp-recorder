import { BpDatabase } from './BpDatabase';
import { Medication, MedLog, MedLogDraft, MedPlan } from '../model/Med';
import { SlotInstance } from '../model/BpRecord';
import { MedService } from './MedService';
import { DateUtils } from '../common/DateUtils';
import { MedLimits } from '../common/Constants';
import { Logger } from '../common/Logger';

const TAG: string = 'MedLifecycleService';

/** 一次生命周期运行的结果（供调用方记日志与判断是否需要刷新界面） */
export interface LifecycleResult {
  /** 本次补齐的应服实例条数 */
  backfilled: number;
  /** 本次落库为「漏服」的条数 */
  markedMissed: number;
  /** 本次自动停用的到期计划数 */
  deactivatedPlans: number;
}

/**
 * 用药生命周期服务（审查 R01）。
 *
 * 统一承担：**补齐应服实例 → 派生/落库漏服 → 停用到期计划**，由冷启动、回前台、
 * 页面跨日、计划保存与导入共用一份实现（不再各页面各写一份）。
 *
 * 关键口径：
 * - 计划版本的**有效下界** `effectiveFrom = max(startDate 00:00, createdAt)`：
 *   新建/修改计划在 12:00 保存、startDate 却是上月时，不会倒造出创建之前的义务（R01.2）；
 *   老数据 `createdAt` 为 0（未知）时退回 startDate，不臆造更早的义务（R01.5）。
 * - 回补窗口最多 `BACKFILL_DAYS` 天：长期未打开也不会一夜之间多出多年「漏服」（R01.5）。
 * - 先补齐、再算漏服（R01.6）；写入走 `insertMissingLogs`（单事务 + 唯一索引幂等，R01.4）。
 * - 提醒**不在此处协调**：数据库与通知系统没有共同事务边界（报告规则 6）。
 */
export class MedLifecycleService {
  /** 离线回补上限：只回补最近 N 天，避免把「长期未打开」变成大量历史漏服 */
  static readonly BACKFILL_DAYS: number = 30;

  /** 计划版本的有效下界（含） */
  static effectiveFrom(plan: MedPlan): number {
    // 审查 R01.3：优先用持久化的有效区间（schema v3 起写入/回填）；
    // 0 表示旧数据尚未回填，退回既有列推导，口径保持一致。
    const persisted: number = plan.effectiveFrom === undefined ? 0 : plan.effectiveFrom;
    if (persisted > 0) {
      return persisted;
    }
    const startTs: number | null = DateUtils.parseDate(plan.startDate);
    const start: number = startTs === null ? plan.createdAt : startTs;
    const created: number = plan.createdAt > 0 ? plan.createdAt : start;
    return start > created ? start : created;
  }

  /** 计划版本的有效上界（含）：生效计划 = 预生成窗口末；已停用 = 停用时戳（未知则退回创建时刻） */
  static effectiveTo(plan: MedPlan, now: number): number {
    const horizon: number = plan.isActive
      ? DateUtils.endOfDay(DateUtils.addDays(now, MedLimits.PRE_GEN_DAYS))
      : (plan.updatedAt > 0 ? plan.updatedAt : plan.createdAt);
    // 审查 R01.3：持久化的区间终点（结束日 23:59 或停用时刻）更早时以它为准
    const persisted: number | null = plan.effectiveTo === undefined ? null : plan.effectiveTo;
    if (persisted !== null && persisted > 0 && persisted < horizon) {
      return persisted;
    }
    return horizon;
  }

  /**
   * 当前应存在的应服实例（含过去、用于补齐）：每个生效计划按自己的有效区间展开，
   * 下界再收紧到 `now - BACKFILL_DAYS`，不会因长期未打开而倒造多年义务。
   */
  static obligations(plans: MedPlan[], meds: Medication[], now: number): MedLogDraft[] {
    const drafts: MedLogDraft[] = [];
    const globalFloor: number = DateUtils.startOfDay(DateUtils.addDays(now, -MedLifecycleService.BACKFILL_DAYS));
    for (let i = 0; i < plans.length; i++) {
      const plan: MedPlan = plans[i];
      if (!plan.isActive) {
        continue;
      }
      const from: number = Math.max(MedLifecycleService.effectiveFrom(plan), globalFloor);
      const to: number = MedLifecycleService.effectiveTo(plan, now);
      if (to < from) {
        continue;
      }
      let dayTs: number = DateUtils.startOfDay(from);
      const lastDay: number = DateUtils.startOfDay(to);
      while (dayTs <= lastDay) {
        const slots: SlotInstance[] = MedService.planSlotsOf(dayTs, [plan], meds);
        for (let k = 0; k < slots.length; k++) {
          const s: SlotInstance = slots[k];
          if (s.scheduledTime < from || s.scheduledTime > to) {
            continue;
          }
          drafts.push({
            medicationId: s.medicationId,
            medName: s.medName,
            dosage: s.dosage,
            scheduledTime: s.scheduledTime
          });
        }
        dayTs = DateUtils.addDays(dayTs, 1);
      }
    }
    return drafts;
  }

  /** 差集：`wanted` 中数据库里还没有的（键与 insertMissingLogs 的唯一索引一致） */
  static missingOf(existing: MedLog[], wanted: MedLogDraft[]): MedLogDraft[] {
    const keys: Set<string> = new Set<string>();
    for (let i = 0; i < existing.length; i++) {
      keys.add(`${existing[i].medicationId}_${existing[i].scheduledTime}`);
    }
    const missing: MedLogDraft[] = [];
    for (let i = 0; i < wanted.length; i++) {
      const d: MedLogDraft = wanted[i];
      if (!keys.has(`${d.medicationId}_${d.scheduledTime}`)) {
        missing.push(d);
      }
    }
    return missing;
  }

  /**
   * 执行一次生命周期（幂等，可反复调用）：
   * 1) 补齐应存在的应服实例；2) 超过宽限期的 pending 落库为 missed；3) 停用 end_date 已过的计划。
   */
  static async run(db: BpDatabase, now: number): Promise<LifecycleResult> {
    const plans: MedPlan[] = await db.queryActivePlans();
    const meds: Medication[] = await db.queryMedications();

    // 1) 先补齐应存在的记录（R01.6：补齐必须在算漏服之前）
    let backfilled: number = 0;
    const wanted: MedLogDraft[] = MedLifecycleService.obligations(plans, meds, now);
    if (wanted.length > 0) {
      const minTs: number = wanted[0].scheduledTime;
      const maxTs: number = wanted[wanted.length - 1].scheduledTime;
      const existing: MedLog[] = await db.queryMedLogsBetween(minTs, maxTs);
      const missing: MedLogDraft[] = MedLifecycleService.missingOf(existing, wanted);
      if (missing.length > 0) {
        backfilled = await db.insertMissingLogs(missing);
        Logger.info(TAG, `backfilled ${backfilled} missing dose instance(s)`);
      }
    }

    // 2) 再派生漏服
    const markedMissed: number = await db.markMissed(now);
    if (markedMissed > 0) {
      Logger.info(TAG, `marked ${markedMissed} overdue log(s) as missed`);
    }

    // 3) 到期计划停用（与 v1.15 裁决 D3 同一条通路：清未来 pending，历史打卡不动）
    let deactivatedPlans: number = 0;
    const expiredIds: number[] = MedService.expiredPlanIds(plans, DateUtils.formatDate(now));
    if (expiredIds.length > 0) {
      for (let i = 0; i < plans.length; i++) {
        const plan: MedPlan = plans[i];
        if (expiredIds.indexOf(plan.id) < 0) {
          continue;
        }
        await db.deactivatePlan(plan.id);
        await db.deleteFuturePendingLogs(plan.medicationId, now);
        deactivatedPlans++;
      }
      Logger.info(TAG, `auto-deactivated ${deactivatedPlans} expired plan(s)`);
    }

    return { backfilled: backfilled, markedMissed: markedMissed, deactivatedPlans: deactivatedPlans };
  }
}
