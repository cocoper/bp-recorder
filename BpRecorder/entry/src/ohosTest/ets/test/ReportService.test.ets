import { describe, expect, it } from '@ohos/hypium';
import { ReportService } from '../../../main/ets/service/ReportService';
import { StatsService } from '../../../main/ets/service/StatsService';
import { DateUtils } from '../../../main/ets/common/DateUtils';
import { ReportKind } from '../../../main/ets/common/Constants';
import { ReportVocab } from '../../../main/ets/common/Vocab';
import { BpRecord } from '../../../main/ets/model/BpRecord';
import { MedLog, MedPlan } from '../../../main/ets/model/Med';
import { MedLogStatus } from '../../../main/ets/model/Types';

/** 周期报告单测（CL-9：自然周/月边界、环比、异常清单、无数据拦截） */
export default function reportServiceTest() {
  const ts = (y: number, m: number, d: number, hh: number, mm: number): number =>
    new Date(y, m - 1, d, hh, mm, 0, 0).getTime();

  const rec = (t: number, sys: number, dia: number, hr: number | null, id: number): BpRecord => ({
    id: id, systolic: sys, diastolic: dia, heartRate: hr, measureTime: t,
    period: DateUtils.periodOf(t), note: null, userId: 1, source: 'manual',
    createdAt: t, updatedAt: t
  });

  const mlog = (scheduled: number, status: MedLogStatus, taken: number | null, id: number): MedLog => ({
    id: id, medicationId: 1, medName: '缬沙坦', dosage: '1片', scheduledTime: scheduled,
    takenTime: taken, status: status, note: null, createdAt: scheduled, updatedAt: scheduled
  });

  const vocab: ReportVocab = {
    titleWeek: '血压周报', titleMonth: '血压月报', titleCustom: '血压报告',
    watermarkSuffix: '由「血压助手」生成，仅供参考', separator: ' · '
  };

  describe('ReportServiceTest', () => {
    it('week_and_month_range', 0, () => {
      const anchor: number = ts(2026, 10, 6, 12, 0);
      const wk = ReportService.weekRange(anchor);
      expect(DateUtils.formatDate(wk.start)).assertEqual('2026-10-05');
      expect(DateUtils.formatDate(wk.end)).assertEqual('2026-10-11');
      const mo = ReportService.monthRange(anchor);
      expect(DateUtils.formatDate(mo.start)).assertEqual('2026-10-01');
      expect(DateUtils.formatDate(mo.end)).assertEqual('2026-10-31');
    });

    it('prev_range_cross_year', 0, () => {
      const wk = ReportService.weekRange(ts(2027, 1, 1, 12, 0));
      expect(DateUtils.formatDate(wk.start)).assertEqual('2026-12-28');
      expect(DateUtils.formatDate(wk.end)).assertEqual('2027-01-03');
      const prev = ReportService.prevRange(wk, ReportKind.WEEK);
      expect(DateUtils.formatDate(prev.start)).assertEqual('2026-12-21');
      expect(DateUtils.formatDate(prev.end)).assertEqual('2026-12-27');
      const prevMonth = ReportService.prevRange(ReportService.monthRange(ts(2026, 1, 15, 12, 0)), ReportKind.MONTH);
      expect(DateUtils.formatDate(prevMonth.start)).assertEqual('2025-12-01');
      expect(DateUtils.formatDate(prevMonth.end)).assertEqual('2025-12-31');
    });

    it('recent_periods', 0, () => {
      const anchor: number = ts(2026, 10, 6, 12, 0);
      const weeks = ReportService.recentWeeks(anchor, 4);
      expect(weeks.length).assertEqual(4);
      expect(DateUtils.formatDate(weeks[0].start)).assertEqual('2026-09-14');
      expect(DateUtils.formatDate(weeks[3].start)).assertEqual('2026-10-05');
      const months = ReportService.recentMonths(anchor, 3);
      expect(months.length).assertEqual(3);
      expect(DateUtils.formatDate(months[0].start)).assertEqual('2026-08-01');
    });

    it('custom_range_validation', 0, () => {
      expect(ReportService.isCustomRangeValid(ts(2026, 1, 1, 0, 0), ts(2026, 4, 2, 0, 0))).assertTrue();
      expect(ReportService.isCustomRangeValid(ts(2026, 1, 1, 0, 0), ts(2026, 4, 3, 0, 0))).assertFalse();
      expect(ReportService.isCustomRangeValid(ts(2026, 4, 3, 0, 0), ts(2026, 1, 1, 0, 0))).assertFalse();
    });

    it('build_report_sections', 0, () => {
      const anchor: number = ts(2026, 10, 6, 12, 0);
      const wk = ReportService.weekRange(anchor);
      const records: BpRecord[] = [
        rec(ts(2026, 10, 5, 6, 40), 145, 95, 80, 1),
        rec(ts(2026, 10, 6, 7, 10), 132, 86, 76, 2),
        rec(ts(2026, 10, 7, 12, 0), 128, 82, null, 3),
        rec(ts(2026, 9, 30, 8, 0), 150, 96, 78, 4)
      ];
      const logs: MedLog[] = [
        mlog(ts(2026, 10, 5, 7, 30), MedLogStatus.TAKEN, ts(2026, 10, 5, 7, 35), 1),
        mlog(ts(2026, 10, 6, 7, 30), MedLogStatus.TAKEN, ts(2026, 10, 6, 7, 35), 2),
        mlog(ts(2026, 10, 7, 7, 30), MedLogStatus.MISSED, null, 3)
      ];
      const plans: MedPlan[] = [{
        id: 1, medicationId: 1, timeSlots: ['07:30'], startDate: '2026-10-01', endDate: null,
        isActive: true, createdAt: 0, updatedAt: 0
      }];

      const report = ReportService.build(ReportKind.WEEK, wk, records, logs, plans,
        vocab, anchor);
      expect(report !== null).assertTrue();
      if (report === null) {
        return;
      }
      expect(report.title).assertEqual('血压周报');
      expect(report.stats.count).assertEqual(3);
      expect(report.stats.sysMean).assertEqual(135);
      expect(report.hasPrev).assertTrue();
      expect(report.prevLabel).assertEqual('2026.09.28 – 10.04');
      expect(report.deltaSys).assertEqual(-15);
      expect(report.dailyPoints.length).assertEqual(3);
      expect(report.abnormals.length).assertEqual(1);
      expect(report.adherence.expected).assertEqual(3);
      expect(report.adherence.due).assertEqual(3); // 无未到期 pending 时二者同值
      expect(report.adherence.taken).assertEqual(2);
      expect(report.adherence.missed).assertEqual(1);
      expect(report.hasMedPlan).assertTrue();
      expect(report.watermark.indexOf('2026.10.05') === 0).assertTrue();
    });

    it('no_data_returns_null', 0, () => {
      const anchor: number = ts(2026, 10, 6, 12, 0);
      const report = ReportService.build(ReportKind.WEEK, ReportService.weekRange(anchor),
        [rec(ts(2026, 1, 1, 8, 0), 130, 85, 70, 1)], [], [],
        vocab, anchor);
      expect(report).assertNull();
    });

    it('med_complete_days', 0, () => {
      const logs: MedLog[] = [
        mlog(ts(2026, 10, 5, 7, 30), MedLogStatus.TAKEN, ts(2026, 10, 5, 7, 35), 1),
        mlog(ts(2026, 10, 6, 7, 30), MedLogStatus.TAKEN, ts(2026, 10, 6, 7, 35), 2),
        mlog(ts(2026, 10, 7, 7, 30), MedLogStatus.MISSED, null, 3)
      ];
      const days = ReportService.medCompleteDays(logs, ts(2026, 10, 8, 12, 0));
      expect(days.length).assertEqual(2);
      expect(days[0]).assertEqual(DateUtils.startOfDay(ts(2026, 10, 5, 0, 0)));

      const points = StatsService.dailyMeans([
        rec(ts(2026, 10, 5, 6, 40), 145, 95, 80, 1),
        rec(ts(2026, 10, 6, 7, 10), 132, 86, 76, 2),
        rec(ts(2026, 10, 7, 12, 0), 128, 82, null, 3)
      ], days);
      expect(points[0].medComplete).assertTrue();
      expect(points[2].medComplete).assertFalse();
    });
  });
}
