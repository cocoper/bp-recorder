import { describe, expect, it } from '@ohos/hypium';
import { MedService } from '../../../main/ets/service/MedService';
import { Medication, MedLog, MedPlan } from '../../../main/ets/model/Med';
import { CheckInAction, MedLogStatus } from '../../../main/ets/model/Types';

/** 打卡状态机与依从率单测（CL-8：状态机全部路径 + 7 天混合数据核对） */
export default function medServiceTest() {
  const ts = (y: number, m: number, d: number, hh: number, mm: number): number =>
    new Date(y, m - 1, d, hh, mm, 0, 0).getTime();

  const log = (scheduled: number, status: MedLogStatus, taken: number | null, id: number): MedLog => ({
    id: id, medicationId: 1, medName: '缬沙坦', dosage: '1片', scheduledTime: scheduled,
    takenTime: taken, status: status, note: null, createdAt: scheduled, updatedAt: scheduled
  });

  const med = (id: number, name: string, active: boolean): Medication => ({
    id: id, name: name, dosage: '1片', note: null, isActive: active, createdAt: 0, updatedAt: 0
  });

  const plan = (id: number, medId: number, slots: string[], start: string, end: string | null, active: boolean): MedPlan => ({
    id: id, medicationId: medId, timeSlots: slots, startDate: start, endDate: end,
    isActive: active, createdAt: 0, updatedAt: 0
  });

  describe('MedServiceTest', () => {
    const s2350: number = ts(2026, 10, 5, 23, 50);

    it('state_machine_pending_to_taken', 0, () => {
      expect(MedService.nextStatus(CheckInAction.TAKE)).assertEqual(MedLogStatus.TAKEN);
    });

    it('state_machine_pending_to_skipped', 0, () => {
      expect(MedService.nextStatus(CheckInAction.SKIP)).assertEqual(MedLogStatus.SKIPPED);
    });

    it('state_machine_pending_to_missed_after_2h', 0, () => {
      // 跨天边界：23:50 计划 → 次日 01:50 恰好 2h 仍为待服；01:51 判漏服
      expect(MedService.resolveStatus(log(s2350, MedLogStatus.PENDING, null, 1),
        ts(2026, 10, 6, 1, 49))).assertEqual(MedLogStatus.PENDING);
      expect(MedService.resolveStatus(log(s2350, MedLogStatus.PENDING, null, 1),
        ts(2026, 10, 6, 1, 50))).assertEqual(MedLogStatus.PENDING);
      expect(MedService.resolveStatus(log(s2350, MedLogStatus.PENDING, null, 1),
        ts(2026, 10, 6, 1, 51))).assertEqual(MedLogStatus.MISSED);
    });

    it('state_machine_settled_status_stable', 0, () => {
      expect(MedService.resolveStatus(log(s2350, MedLogStatus.TAKEN, s2350, 1),
        ts(2026, 10, 6, 12, 0))).assertEqual(MedLogStatus.TAKEN);
      expect(MedService.resolveStatus(log(s2350, MedLogStatus.SKIPPED, null, 1),
        ts(2026, 10, 6, 12, 0))).assertEqual(MedLogStatus.SKIPPED);
    });

    it('makeup_detection', 0, () => {
      expect(MedService.isMakeUp(log(s2350, MedLogStatus.TAKEN, s2350 + 2 * 3600000 + 1, 1))).assertTrue();
      expect(MedService.isMakeUp(log(s2350, MedLogStatus.TAKEN, s2350 + 2 * 3600000, 1))).assertFalse();
      expect(MedService.isMakeUp(log(s2350, MedLogStatus.TAKEN, s2350 + 60000, 1))).assertFalse();
      expect(MedService.isMakeUp(log(s2350, MedLogStatus.TAKEN, null, 1))).assertFalse();
    });

    it('adherence_seven_day_mixed', 0, () => {
      const nowA: number = ts(2026, 10, 6, 12, 0);
      const logs: MedLog[] = [];
      for (let i = 0; i < 14; i++) {
        const sched: number = ts(2026, 9, 30 + i, 7, 30);
        if (i < 12) {
          logs.push(log(sched, MedLogStatus.TAKEN, sched + 600000, i + 1));
        } else if (i === 12) {
          logs.push(log(sched, MedLogStatus.SKIPPED, null, i + 1));
        } else {
          logs.push(log(sched, MedLogStatus.MISSED, null, i + 1));
        }
      }
      const adh = MedService.adherence(logs, nowA);
      expect(adh.expected).assertEqual(14);
      expect(adh.due).assertEqual(14); // 全部已到期时，已到期义务与计划总量同值
      expect(adh.taken).assertEqual(12);
      expect(adh.skipped).assertEqual(1);
      expect(adh.missed).assertEqual(1);
      expect(Math.abs((adh.rate as number) - 1200 / 14) < 1e-9).assertTrue();

      // v1.4 口径：未到期的 pending 只计入「计划总量 expected」，不进依从率分母
      logs.push(log(ts(2026, 10, 6, 13, 0), MedLogStatus.PENDING, null, 99));
      const adh2 = MedService.adherence(logs, nowA);
      expect(adh2.expected).assertEqual(15);
      expect(adh2.due).assertEqual(14);
      expect(adh2.pendingNotDue).assertEqual(1);
      expect(Math.abs((adh2.rate as number) - 1200 / 14) < 1e-9).assertTrue();
    });

    it('adherence_empty', 0, () => {
      const adh = MedService.adherence([], ts(2026, 10, 6, 12, 0));
      expect(adh.expected).assertEqual(0);
      expect(adh.due).assertEqual(0);
      expect(adh.rate).assertNull();
    });

    it('adherence_all_pending_zero_due', 0, () => {
      const now: number = ts(2026, 10, 6, 12, 0);
      const logs: MedLog[] = [log(ts(2026, 10, 6, 13, 0), MedLogStatus.PENDING, null, 1)];
      const adh = MedService.adherence(logs, now);
      expect(adh.expected).assertEqual(1);
      expect(adh.due).assertEqual(0);
      expect(adh.pendingNotDue).assertEqual(1);
      expect(adh.rate).assertNull();
    });

    it('plan_active_window', 0, () => {
      expect(MedService.isPlanActiveOn(plan(1, 1, ['07:30'], '2026-10-01', null, true),
        ts(2026, 9, 30, 12, 0))).assertFalse();
      expect(MedService.isPlanActiveOn(plan(1, 1, ['07:30'], '2026-10-01', null, true),
        ts(2026, 10, 1, 12, 0))).assertTrue();
      expect(MedService.isPlanActiveOn(plan(1, 1, ['07:30'], '2026-10-01', '2026-10-05', true),
        ts(2026, 10, 5, 12, 0))).assertTrue();
      expect(MedService.isPlanActiveOn(plan(1, 1, ['07:30'], '2026-10-01', '2026-10-05', true),
        ts(2026, 10, 6, 12, 0))).assertFalse();
    });

    it('plan_slots_filter_and_sort', 0, () => {
      const meds: Medication[] = [med(1, '缬沙坦', true), med(2, '阿司匹林', false), med(3, '二甲双胍', true)];
      const plans: MedPlan[] = [
        plan(1, 1, ['18:00', '07:30'], '2026-10-01', null, true),
        plan(2, 2, ['12:00'], '2026-10-01', null, true),
        plan(3, 1, ['09:00'], '2026-01-01', '2026-06-30', true),
        plan(4, 3, ['20:00'], '2026-10-01', null, false)
      ];
      const slots = MedService.planSlotsOf(ts(2026, 10, 6, 12, 0), plans, meds);
      expect(slots.length).assertEqual(2);
      expect(slots[0].scheduledTime).assertEqual(ts(2026, 10, 6, 7, 30));
      expect(slots[1].scheduledTime).assertEqual(ts(2026, 10, 6, 18, 0));
    });

    it('pending_drafts_rolling_window', 0, () => {
      const meds: Medication[] = [med(1, '缬沙坦', true)];
      const drafts = MedService.pendingDrafts([plan(1, 1, ['07:30', '18:00'], '2026-10-01', null, true)],
        meds, ts(2026, 10, 6, 12, 0), 7);
      expect(drafts.length).assertEqual(14);
      expect(drafts[0].scheduledTime).assertEqual(ts(2026, 10, 6, 7, 30));
      expect(drafts[13].scheduledTime).assertEqual(ts(2026, 10, 12, 18, 0));

      const truncated = MedService.pendingDrafts([plan(1, 1, ['08:00'], '2026-10-01', '2026-10-03', true)],
        meds, ts(2026, 10, 1, 12, 0), 7);
      expect(truncated.length).assertEqual(3);
    });

    it('merge_same_slot', 0, () => {
      const groups = MedService.groupBySlot([
        { medicationId: 1, medName: '缬沙坦', dosage: '1片', scheduledTime: ts(2026, 10, 6, 7, 30), planId: 1 },
        { medicationId: 3, medName: '二甲双胍', dosage: '1片', scheduledTime: ts(2026, 10, 6, 7, 30), planId: 4 },
        { medicationId: 1, medName: '缬沙坦', dosage: '1片', scheduledTime: ts(2026, 10, 6, 18, 0), planId: 1 }
      ]);
      expect(groups.length).assertEqual(2);
      expect(groups[0].items.length).assertEqual(2);
      expect(groups[1].items.length).assertEqual(1);
    });

    it('plan_validation', 0, () => {
      expect(MedService.validatePlanForm(['07:30'], '2026-10-06', null).ok).assertTrue();
      expect(MedService.validatePlanForm(['07:30', '12:00', '18:00', '22:00'], '2026-10-06', null).ok).assertTrue();
      expect(MedService.validatePlanForm([], '2026-10-06', null).ok).assertFalse();
      expect(MedService.validatePlanForm(['07:30', '12:00', '18:00', '22:00', '23:30'], '2026-10-06', null).ok).assertFalse();
      expect(MedService.validatePlanForm(['07:30', '07:30'], '2026-10-06', null).ok).assertFalse();
      expect(MedService.validatePlanForm(['7:30'], '2026-10-06', null).ok).assertFalse();
      expect(MedService.validatePlanForm(['07:30'], '2026-10-06', '2026-10-05').ok).assertFalse();
    });

    it('normalize_slots', 0, () => {
      const norm = MedService.normalizeSlots([' 18:00 ', '07:30', '18:00', 'abc', '25:00', '07:30']);
      expect(norm.length).assertEqual(2);
      expect(norm[0]).assertEqual('07:30');
      expect(norm[1]).assertEqual('18:00');
    });

    it('today_lines_sequence', 0, () => {
      const s1800: number = ts(2026, 10, 6, 18, 0);
      const lines = MedService.todayLines([
        log(s1800, MedLogStatus.PENDING, null, 1),
        log(s1800, MedLogStatus.TAKEN, s1800, 2),
        log(ts(2026, 10, 6, 7, 30), MedLogStatus.TAKEN, ts(2026, 10, 6, 7, 32), 3)
      ], ts(2026, 10, 6, 18, 30));
      expect(lines.length).assertEqual(3);
      expect(lines[0].slotSeq).assertEqual(1);
      expect(lines[1].slotSeq).assertEqual(2);
      expect(lines[1].medCountInSlot).assertEqual(2);
      expect(lines[2].medSeq).assertEqual(2);
    });

    // v1.15 / 裁决 D3：过期计划自动停用（每日代理闹钟没有结束日期参数）
    it('expired_plan_detection_boundaries', 0, () => {
      const today: string = '2026-10-07';
      const plans: MedPlan[] = [
        plan(11, 1, ['07:30'], '2026-09-01', '2026-10-06', true),
        plan(12, 2, ['07:30'], '2026-09-01', '2026-10-07', true),
        plan(13, 3, ['07:30'], '2026-09-01', null, true),
        plan(14, 4, ['07:30'], '2026-09-01', '2026-10-01', false)
      ];
      // 昨天到期 → 命中；今天到期 / 长期 / 已停用 → 都不命中
      const ids = MedService.expiredPlanIds(plans, today);
      expect(ids.length).assertEqual(1);
      expect(ids[0]).assertEqual(11);
      expect(MedService.expiredPlanIds(plans, '2026-10-08').length).assertEqual(2);
      expect(MedService.expiredPlanIds(plans, 'not-a-date').length).assertEqual(0);
      expect(MedService.expiredPlanIds([], today).length).assertEqual(0);
    });

    it('expired_end_date_for_badge', 0, () => {
      // 自动停用后 isActive 已是 false，用药页仍要能认出「它是到期停用的」
      const today: string = '2026-10-07';
      const plans: MedPlan[] = [
        plan(11, 1, ['07:30'], '2026-09-01', '2026-10-06', true),
        plan(14, 4, ['07:30'], '2026-09-01', '2026-10-01', false),
        plan(13, 3, ['07:30'], '2026-09-01', null, true)
      ];
      expect(MedService.expiredEndDate(plans, 4, today)).assertEqual('2026-10-01');
      expect(MedService.expiredEndDate(plans, 1, today)).assertEqual('2026-10-06');
      expect(MedService.expiredEndDate(plans, 3, today)).assertEqual(null);
      expect(MedService.expiredEndDate(plans, 99, today)).assertEqual(null);
    });
  });
}
