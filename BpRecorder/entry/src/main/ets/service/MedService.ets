import { MedLimits } from '../common/Constants';
import { DateUtils } from '../common/DateUtils';
import { Adherence, SlotInstance, ValidationResult } from '../model/BpRecord';
import { Medication, MedLog, MedLogDraft, MedPlan, TodayMedLine } from '../model/Med';
import { CheckInAction, MedLogStatus } from '../model/Types';

/** 同一计划时间点的药品集合（FR-8.4 合并提醒的输入） */
export interface SlotGroup {
  scheduledTime: number;
  items: SlotInstance[];
}

/** 字段级错误条目 */
interface FieldError {
  field: string;
  res: Resource;
}

/**
 * 用药业务逻辑（状态机 / 依从率 / 计划展开 / 预生成，以纯函数为主，可单测）。
 *
 * 状态机（§3.4）：
 *   pending ──「已服用」──▶ taken
 *   pending ──「跳过」────▶ skipped
 *   pending ──超时 2h────▶ missed（系统自动）
 *   missed / skipped ──「补记」──▶ taken
 *
 * 依从率口径（FR-9.5，v1.4 修订）：
 *   计划总量 expected = taken + skipped + missed + 未到期的 pending（仅供展示）；
 *   已到期义务 due    = taken + skipped + missed（计划时间 + 2h 宽限期已过）；
 *   依从率 rate       = taken / due × 100。分母不含未到期的 pending，
 *   否则白天查询时比率会随查询时刻自行变化（报告是打印给医生看的）。
 * 残余已知行为：计划时间刚过、仍在 2h 宽限期内的那条算未到期，该 2h 窗口内数字仍会变。
 */
export class MedService {
  static readonly FIELD_NAME: string = 'name';
  static readonly FIELD_DOSAGE: string = 'dosage';
  static readonly FIELD_NOTE: string = 'note';
  static readonly FIELD_SLOTS: string = 'timeSlots';
  static readonly FIELD_START: string = 'startDate';
  static readonly FIELD_END: string = 'endDate';

  private static buildResult(entries: FieldError[]): ValidationResult {
    const map: Map<string, Resource> = new Map<string, Resource>();
    for (let i = 0; i < entries.length; i++) {
      map.set(entries[i].field, entries[i].res);
    }
    const first: Resource | null = entries.length > 0 ? entries[0].res : null;
    return { ok: entries.length === 0, fieldErrors: map, firstError: first };
  }

  // ───────────────────────── 状态机 ─────────────────────────

  /** 是否已超过计划时间 + 2h（漏服判定的唯一条件） */
  static isOverdue(log: MedLog, now: number): boolean {
    return now > log.scheduledTime + MedLimits.MISS_GRACE_MS;
  }

  /**
   * 解析记录当前的**有效状态**（纯函数，不写库）。
   * - taken / skipped / missed：以落库状态为准，直接返回；
   * - pending：超时 2h → missed，否则仍为 pending。
   */
  static resolveStatus(log: MedLog, now: number): MedLogStatus {
    if (log.status === MedLogStatus.PENDING) {
      return MedService.isOverdue(log, now) ? MedLogStatus.MISSED : MedLogStatus.PENDING;
    }
    return log.status;
  }

  /**
   * 是否为「补记」：状态为 taken 且实际打卡时间晚于计划时间 + 2h。
   * 补记仍计入依从率分子，但 UI 需标注「补记」（§3.4）。
   */
  static isMakeUp(log: MedLog): boolean {
    if (log.status !== MedLogStatus.TAKEN) {
      return false;
    }
    const taken: number | null = log.takenTime;
    if (taken === null || taken === undefined) {
      return false;
    }
    return taken > log.scheduledTime + MedLimits.MISS_GRACE_MS;
  }

  /** 该状态下是否允许打卡操作（taken 后仍允许改判，避免误点无法纠正） */
  static canCheckIn(status: MedLogStatus): boolean {
    return status === MedLogStatus.PENDING || status === MedLogStatus.MISSED
      || status === MedLogStatus.SKIPPED || status === MedLogStatus.TAKEN;
  }

  /** 状态迁移：目标状态只由用户动作决定 */
  static nextStatus(action: CheckInAction): MedLogStatus {
    return action === CheckInAction.TAKE ? MedLogStatus.TAKEN : MedLogStatus.SKIPPED;
  }

  // ───────────────────────── 依从率 ─────────────────────────

  /** 依从率统计（FR-9.5）。调用方负责传入目标区间内的打卡记录。 */
  static adherence(logs: MedLog[], now: number): Adherence {
    let taken: number = 0;
    let skipped: number = 0;
    let missed: number = 0;
    let pendingNotDue: number = 0;

    for (let i = 0; i < logs.length; i++) {
      const status: MedLogStatus = MedService.resolveStatus(logs[i], now);
      if (status === MedLogStatus.TAKEN) {
        taken++;
      } else if (status === MedLogStatus.SKIPPED) {
        skipped++;
      } else if (status === MedLogStatus.MISSED) {
        missed++;
      } else {
        pendingNotDue++;
      }
    }

    const expected: number = taken + skipped + missed + pendingNotDue;
    // 依从率分母只算「已到期义务」：未到期的 pending 不是用户的义务，不应拉低比率
    const due: number = taken + skipped + missed;
    const rate: number | null = due === 0 ? null : (taken * 100) / due;
    return {
      expected: expected,
      taken: taken,
      skipped: skipped,
      missed: missed,
      pendingNotDue: pendingNotDue,
      due: due,
      rate: rate
    };
  }

  // ───────────────────────── 计划展开与预生成 ─────────────────────────

  /** 计划在指定自然日是否生效（start ≤ day ≤ end，end 为 null 表示长期） */
  static isPlanActiveOn(plan: MedPlan, dayTs: number): boolean {
    const dayStart: number = DateUtils.startOfDay(dayTs);
    const start: number | null = DateUtils.parseDate(plan.startDate);
    if (start === null || dayStart < start) {
      return false;
    }
    if (plan.endDate === null || plan.endDate === undefined || plan.endDate.length === 0) {
      return true;
    }
    const end: number | null = DateUtils.parseDate(plan.endDate);
    if (end === null) {
      // 结束日期非法时按「长期」处理，避免计划因脏数据整条失效
      return true;
    }
    return dayStart <= end;
  }

  /**
   * 已过期但仍生效的计划 id（v1.15 / 裁决 D3：进入前台时自动停用）。
   *
   * 判定：`endDate` **严格早于** today（按自然日边界）且计划仍 `isActive`。
   * 边界语义（与 isPlanActiveOn 的 `end ≤ day` 互补，二者不会同时成立）：
   *   - `endDate` = 昨天 → **命中**（今天起不再是服药日）
   *   - `endDate` = 今天 → **不命中**（今天仍要服药，只到明天才过期）
   *   - `endDate` = null / 空 / 非法 → **不命中**（视为长期计划；非法值沿用 isPlanActiveOn 的宽容处理）
   * 本函数只做判定、不写库；调用方负责置 `isActive = 0` 并清理未来 pending。
   */
  /** "HH:mm" → 当天分钟数；格式非法返回 null（提醒协调用） */
  static slotMinutes(slot: string): number | null {
    const parts: string[] = slot.split(':');
    if (parts.length !== 2) {
      return null;
    }
    const hh: number = Number.parseInt(parts[0], 10);
    const mm: number = Number.parseInt(parts[1], 10);
    if (Number.isNaN(hh) || Number.isNaN(mm) || hh < 0 || hh > 23 || mm < 0 || mm > 59) {
      return null;
    }
    return hh * 60 + mm;
  }

  /** 计划结束日的当天 23:59；无结束日期返回 null（长期计划用无限重复闹钟） */
  static endInstantOf(plan: MedPlan): number | null {
    if (plan.endDate === null || plan.endDate.length === 0) {
      return null;
    }
    const ts: number | null = DateUtils.parseDate(plan.endDate);
    return ts === null ? null : DateUtils.endOfDay(ts);
  }

  static expiredPlanIds(plans: MedPlan[], today: string): number[] {
    const todayStart: number | null = DateUtils.parseDate(today);
    if (todayStart === null) {
      return [];
    }
    const out: number[] = [];
    for (let i = 0; i < plans.length; i++) {
      const plan: MedPlan = plans[i];
      if (!plan.isActive) {
        continue;
      }
      if (MedService.isExpiredEndDate(plan.endDate, todayStart)) {
        out.push(plan.id);
      }
    }
    return out;
  }

  /**
   * 某药品最近一条「已到期」计划的结束日期（v1.15 / 裁决 D3），供用药页标注「已到期自动停用」。
   *
   * 与 `expiredPlanIds` 的区别：**不看 isActive** —— 自动停用之后计划已经是 `isActive = 0`，
   * 而药用页恰恰要在这个状态下把它认出来，否则用户只会看到一行「无计划」，误以为是自己停的。
   * 返回 `null` 表示该药品没有已到期的计划。
   */
  static expiredEndDate(plans: MedPlan[], medicationId: number, today: string): string | null {
    const todayStart: number | null = DateUtils.parseDate(today);
    if (todayStart === null) {
      return null;
    }
    let best: string | null = null;
    let bestTs: number = 0;
    for (let i = 0; i < plans.length; i++) {
      const plan: MedPlan = plans[i];
      if (plan.medicationId !== medicationId) {
        continue;
      }
      const endRaw: string | null = plan.endDate;
      if (endRaw === null || endRaw === undefined || endRaw.length === 0) {
        continue;
      }
      const end: number | null = DateUtils.parseDate(endRaw);
      if (end === null || end >= todayStart) {
        continue;
      }
      if (best === null || end > bestTs) {
        bestTs = end;
        best = endRaw;
      }
    }
    return best;
  }

  /** 结束日期是否已过期（严格早于 todayStart；null / 空 / 非法一律视为未过期） */
  private static isExpiredEndDate(endDate: string | null, todayStart: number): boolean {
    if (endDate === null || endDate === undefined || endDate.length === 0) {
      return false;
    }
    const end: number | null = DateUtils.parseDate(endDate);
    if (end === null) {
      return false;
    }
    return end < todayStart;
  }

  /** 展开某日全部应服实例（FR-8.2 / FR-8.3） */
  static planSlotsOf(dayTs: number, plans: MedPlan[], meds: Medication[]): SlotInstance[] {
    const medIndex: Map<number, Medication> = new Map<number, Medication>();
    for (let i = 0; i < meds.length; i++) {
      medIndex.set(meds[i].id, meds[i]);
    }

    const dateStr: string = DateUtils.formatDate(dayTs);
    const out: SlotInstance[] = [];

    for (let i = 0; i < plans.length; i++) {
      const plan: MedPlan = plans[i];
      if (!plan.isActive) {
        continue;
      }
      if (!MedService.isPlanActiveOn(plan, dayTs)) {
        continue;
      }
      const med: Medication | undefined = medIndex.get(plan.medicationId);
      // 药品已停用则不再产生新的应服实例（历史打卡不受影响）
      if (med === undefined || !med.isActive) {
        continue;
      }
      for (let j = 0; j < plan.timeSlots.length; j++) {
        const ts: number | null = DateUtils.parseDateTime(dateStr, plan.timeSlots[j]);
        if (ts === null) {
          // 单个时间点非法时跳过该点，不影响同计划其它时间点
          continue;
        }
        out.push({
          medicationId: med.id,
          medName: med.name,
          dosage: med.dosage,
          scheduledTime: ts,
          planId: plan.id
        });
      }
    }

    out.sort((a: SlotInstance, b: SlotInstance) => a.scheduledTime - b.scheduledTime);
    return out;
  }

  /**
   * 预生成打卡记录草稿（§3.1）：从 fromTs 起滚动 days 天。
   * 幂等性由 BpDatabase 的 UNIQUE(medication_id, scheduled_time) + INSERT OR IGNORE 保证，
   * 本方法只负责「算出应存在的记录」，重复调用不会产生重复数据。
   */
  /**
   * 首次生成某个计划版本的应服实例（保存计划 / 导入计划时调用）。
   *
   * **审查 R01.2**：新版本计划的生效下界 = max(保存时刻 `fromTs`, `startDate`)，因此
   * **今天已经过去的时点不生成**（过去只有「12:00 建 08:00 计划」会倒造出一条创建前的义务）；
   * 也不能只把 `now` 截到日初。旧版本的离线缺口由 `MedLifecycleService` 按各自的有效区间补齐。
   */
  static pendingDrafts(plans: MedPlan[], meds: Medication[], fromTs: number, days: number): MedLogDraft[] {
    const drafts: MedLogDraft[] = [];
    const dayCount: number = days < 1 ? 1 : days;
    const base: number = DateUtils.startOfDay(fromTs);
    for (let d = 0; d < dayCount; d++) {
      const dayTs: number = DateUtils.addDays(base, d);
      const slots: SlotInstance[] = MedService.planSlotsOf(dayTs, plans, meds);
      for (let i = 0; i < slots.length; i++) {
        const s: SlotInstance = slots[i];
        if (s.scheduledTime < fromTs) {
          // 生效时刻之前的义务不属于这个版本（历史义务由生命周期服务按有效区间补齐）
          continue;
        }
        drafts.push({
          medicationId: s.medicationId,
          medName: s.medName,
          dosage: s.dosage,
          scheduledTime: s.scheduledTime
        });
      }
    }
    return drafts;
  }

  /** 按计划时间点分组，供提醒合并使用（FR-8.4：同一时间点合并为一条提醒） */
  static groupBySlot(instances: SlotInstance[]): SlotGroup[] {
    const sorted: SlotInstance[] = instances.slice().sort((a: SlotInstance, b: SlotInstance) => a.scheduledTime - b.scheduledTime);
    const groups: SlotGroup[] = [];
    for (let i = 0; i < sorted.length; i++) {
      const it: SlotInstance = sorted[i];
      const last: SlotGroup | undefined = groups.length > 0 ? groups[groups.length - 1] : undefined;
      if (last !== undefined && last.scheduledTime === it.scheduledTime) {
        last.items.push(it);
      } else {
        groups.push({ scheduledTime: it.scheduledTime, items: [it] });
      }
    }
    return groups;
  }

  /** 补全「今日服药」卡片的展示信息（序号、补记标记） */
  static todayLines(logs: MedLog[], now: number): TodayMedLine[] {
    const sorted: MedLog[] = logs.slice().sort((a: MedLog, b: MedLog) => a.scheduledTime - b.scheduledTime);

    const counts: Map<number, number> = new Map<number, number>();
    for (let i = 0; i < sorted.length; i++) {
      const key: number = sorted[i].scheduledTime;
      const c: number | undefined = counts.get(key);
      counts.set(key, c === undefined ? 1 : c + 1);
    }

    const lines: TodayMedLine[] = [];
    let curSlot: number = -1;
    let slotSeq: number = 0;
    let medSeq: number = 0;

    for (let i = 0; i < sorted.length; i++) {
      const log: MedLog = sorted[i];
      if (log.scheduledTime !== curSlot) {
        curSlot = log.scheduledTime;
        slotSeq++;
        medSeq = 1;
      } else {
        medSeq++;
      }
      const total: number | undefined = counts.get(curSlot);
      lines.push({
        logId: log.id,
        medName: log.medName,
        dosage: log.dosage,
        scheduledTime: log.scheduledTime,
        status: MedService.resolveStatus(log, now),
        isMakeUp: MedService.isMakeUp(log),
        slotSeq: slotSeq,
        medSeq: medSeq,
        medCountInSlot: total === undefined ? 1 : total
      });
    }
    return lines;
  }

  // ───────────────────────── 表单校验 ─────────────────────────

  /** 药品档案校验（FR-8.1） */
  static validateMedicationForm(name: string, dosage: string, note: string): ValidationResult {
    const entries: FieldError[] = [];
    const n: string = name === null || name === undefined ? '' : name.trim();
    const d: string = dosage === null || dosage === undefined ? '' : dosage.trim();
    const noteText: string = note === null || note === undefined ? '' : note;

    if (n.length === 0) {
      entries.push({ field: MedService.FIELD_NAME, res: $r('app.string.err_med_name_required') });
    } else if (n.length > MedLimits.NAME_MAX_LEN) {
      entries.push({ field: MedService.FIELD_NAME, res: $r('app.string.err_med_name_too_long') });
    }

    if (d.length === 0) {
      entries.push({ field: MedService.FIELD_DOSAGE, res: $r('app.string.err_med_dosage_required') });
    } else if (d.length > MedLimits.DOSAGE_MAX_LEN) {
      entries.push({ field: MedService.FIELD_DOSAGE, res: $r('app.string.err_med_dosage_too_long') });
    }

    if (noteText.length > MedLimits.NOTE_MAX_LEN) {
      entries.push({ field: MedService.FIELD_NOTE, res: $r('app.string.err_note_too_long') });
    }

    return MedService.buildResult(entries);
  }

  /**
   * 服药计划校验（FR-8.2 / CL-8）：
   * 每日次数 1–4 与时间点数量联动；时间点格式合法且不重复；结束日期不早于开始日期。
   */
  static validatePlanForm(timeSlots: string[], startDate: string, endDate: string | null): ValidationResult {
    const entries: FieldError[] = [];
    const slots: string[] = timeSlots === null || timeSlots === undefined ? [] : timeSlots;

    if (slots.length < MedLimits.MIN_SLOTS || slots.length > MedLimits.MAX_SLOTS) {
      entries.push({ field: MedService.FIELD_SLOTS, res: $r('app.string.err_slot_count') });
    } else {
      const seen: Map<number, boolean> = new Map<number, boolean>();
      let invalid: boolean = false;
      let duplicated: boolean = false;
      for (let i = 0; i < slots.length; i++) {
        const minutes: number = DateUtils.hhmmToMinutes(slots[i]);
        if (minutes < 0) {
          invalid = true;
          break;
        }
        if (seen.get(minutes) === true) {
          duplicated = true;
          break;
        }
        seen.set(minutes, true);
      }
      if (invalid) {
        entries.push({ field: MedService.FIELD_SLOTS, res: $r('app.string.err_slot_invalid') });
      } else if (duplicated) {
        entries.push({ field: MedService.FIELD_SLOTS, res: $r('app.string.err_slot_dup') });
      }
    }

    const start: number | null = startDate === null || startDate === undefined ? null : DateUtils.parseDate(startDate);
    if (start === null) {
      entries.push({ field: MedService.FIELD_START, res: $r('app.string.err_start_date_invalid') });
    }

    if (endDate !== null && endDate !== undefined && endDate.length > 0) {
      const end: number | null = DateUtils.parseDate(endDate);
      if (end === null) {
        entries.push({ field: MedService.FIELD_END, res: $r('app.string.err_end_date_invalid') });
      } else if (start !== null && end < start) {
        entries.push({ field: MedService.FIELD_END, res: $r('app.string.err_end_before_start') });
      }
    }

    return MedService.buildResult(entries);
  }

  /** 时间点规范化：去空白 → 去非法 → 去重 → 按时间升序 */
  static normalizeSlots(slots: string[]): string[] {
    const minutes: number[] = [];
    const seen: Map<number, boolean> = new Map<number, boolean>();
    for (let i = 0; i < slots.length; i++) {
      const raw: string = slots[i] === null || slots[i] === undefined ? '' : slots[i].trim();
      const m: number = DateUtils.hhmmToMinutes(raw);
      if (m < 0 || seen.get(m) === true) {
        continue;
      }
      seen.set(m, true);
      minutes.push(m);
    }
    minutes.sort((a: number, b: number) => a - b);
    const out: string[] = [];
    for (let i = 0; i < minutes.length; i++) {
      out.push(DateUtils.minutesToHhmm(minutes[i]));
    }
    return out;
  }
}
