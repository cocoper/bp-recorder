import { describe, expect, it } from '@ohos/hypium';
import { StatsService } from '../../../main/ets/service/StatsService';
import { DateUtils } from '../../../main/ets/common/DateUtils';
import { BpRecord } from '../../../main/ets/model/BpRecord';
import { Period } from '../../../main/ets/model/Types';

/** 统计口径单测（CL-4：均值/极值/标准差与手工核算一致） */
export default function statsServiceTest() {
  const ts = (y: number, m: number, d: number, hh: number, mm: number): number =>
    new Date(y, m - 1, d, hh, mm, 0, 0).getTime();

  const rec = (t: number, sys: number, dia: number, hr: number | null, id: number): BpRecord => ({
    id: id, systolic: sys, diastolic: dia, heartRate: hr, measureTime: t,
    period: DateUtils.periodOf(t), note: null, userId: 1, source: 'manual',
    createdAt: t, updatedAt: t
  });

  describe('StatsServiceTest', () => {
    it('stddev_is_population_sigma', 0, () => {
      // 手工核算：[100,110,120,130,140] → sqrt(1000/5) = 14.142135623730951
      expect(Math.abs(StatsService.stdDev([100, 110, 120, 130, 140]) - 14.142135623730951) < 1e-9).assertTrue();
      // [120,130,140] → sqrt(200/3)
      expect(Math.abs(StatsService.stdDev([120, 130, 140]) - Math.sqrt(200 / 3)) < 1e-9).assertTrue();
      expect(StatsService.stdDev([128])).assertEqual(0);
      expect(StatsService.stdDev([])).assertEqual(0);
    });

    it('range_stats', 0, () => {
      const d1: number = ts(2026, 10, 6, 8, 0);
      const d2: number = ts(2026, 10, 5, 21, 40);
      const stats = StatsService.rangeStats([
        rec(d1, 128, 82, 72, 1), rec(d1 + 3600000, 132, 84, 76, 2), rec(d2, 140, 90, null, 3)
      ]);
      expect(stats.count).assertEqual(3);
      expect(Math.abs(stats.sysMean - 400 / 3) < 1e-9).assertTrue();
      expect(stats.sysMax).assertEqual(140);
      expect(stats.sysMin).assertEqual(128);
      expect(stats.diaMax).assertEqual(90);
      expect(stats.diaMin).assertEqual(82);
      expect(stats.hrMean).assertEqual(74);
    });

    it('empty_range', 0, () => {
      const stats = StatsService.rangeStats([]);
      expect(stats.count).assertEqual(0);
      expect(stats.hrMean).assertNull();
      expect(stats.sysStdDev).assertEqual(0);
    });

    it('daily_means_average_same_day', 0, () => {
      const d1: number = ts(2026, 10, 6, 8, 0);
      const d2: number = ts(2026, 10, 5, 21, 40);
      const points = StatsService.dailyMeans([
        rec(d1, 128, 82, 72, 1), rec(d1 + 3600000, 132, 84, 76, 2), rec(d2, 140, 90, null, 3)
      ], [DateUtils.startOfDay(d1)]);
      expect(points.length).assertEqual(2);
      expect(points[1].count).assertEqual(2);
      expect(points[1].sysAvg).assertEqual(130);
      expect(points[1].diaAvg).assertEqual(83);
      expect(points[1].medComplete).assertTrue();
      expect(points[0].medComplete).assertFalse();
    });

    it('intraday_points_keep_each_measurement', 0, () => {
      const t1: number = ts(2026, 10, 6, 8, 0);
      const t2: number = ts(2026, 10, 6, 12, 30);
      const t3: number = ts(2026, 10, 6, 21, 40);
      // 入参故意乱序：函数内部应先按 measureTime 升序排序
      const points = StatsService.intradayPoints([
        rec(t3, 138, 88, 80, 3), rec(t1, 128, 82, 72, 1), rec(t2, 132, 84, null, 2)
      ], [DateUtils.startOfDay(t1)]);
      expect(points.length).assertEqual(3);
      // dayStart 放的是实际测量时刻，不是当日 00:00
      expect(points[0].dayStart).assertEqual(t1);
      expect(points[1].dayStart).assertEqual(t2);
      expect(points[2].dayStart).assertEqual(t3);
      // 不做同日聚合：每次测量各占一点
      expect(points[0].count).assertEqual(1);
      expect(points[1].count).assertEqual(1);
      expect(points[2].count).assertEqual(1);
      expect(points[0].sysAvg).assertEqual(128);
      expect(points[0].diaAvg).assertEqual(82);
      expect(points[0].hrAvg).assertEqual(72);
      expect(points[1].hrAvg).assertNull();
      expect(points[2].hrAvg).assertEqual(80);
      expect(points[0].medComplete).assertTrue();
      expect(points[2].medComplete).assertTrue();
    });

    it('intraday_points_only_last_day', 0, () => {
      const prev: number = ts(2026, 10, 5, 21, 40);
      const t1: number = ts(2026, 10, 6, 8, 0);
      const t2: number = ts(2026, 10, 6, 20, 0);
      const points = StatsService.intradayPoints([
        rec(prev, 140, 90, null, 1), rec(t1, 128, 82, 72, 2), rec(t2, 130, 84, 76, 3)
      ], [DateUtils.startOfDay(t1)]);
      expect(points.length).assertEqual(2);
      expect(points[0].dayStart).assertEqual(t1);
      expect(points[1].dayStart).assertEqual(t2);
    });

    it('intraday_points_empty', 0, () => {
      expect(StatsService.intradayPoints([], []).length).assertEqual(0);
      expect(StatsService.intradayPoints([], [DateUtils.startOfDay(ts(2026, 10, 6, 8, 0))]).length).assertEqual(0);
    });

    it('intraday_points_med_not_complete', 0, () => {
      const t1: number = ts(2026, 10, 6, 8, 0);
      const otherDay: number = DateUtils.startOfDay(ts(2026, 10, 5, 8, 0));
      const points = StatsService.intradayPoints([rec(t1, 128, 82, 72, 1)], [otherDay]);
      expect(points.length).assertEqual(1);
      expect(points[0].medComplete).assertFalse();
    });

    it('distribution_sums_to_100', 0, () => {
      const d1: number = ts(2026, 10, 6, 8, 0);
      const rows = StatsService.gradeDistribution([
        rec(d1, 110, 70, null, 1), rec(d1, 115, 75, null, 2), rec(d1, 118, 78, null, 3),
        rec(d1, 119, 79, null, 4), rec(d1, 125, 82, null, 5), rec(d1, 130, 85, null, 6),
        rec(d1, 145, 92, null, 7)
      ]);
      expect(rows.length).assertEqual(5);
      let sum: number = 0;
      for (let i = 0; i < rows.length; i++) {
        sum += rows[i].percent;
      }
      expect(Math.abs(sum - 100) < 1e-6).assertTrue();
      expect(rows[0].count).assertEqual(4);
    });

    it('distribution_all_same_band', 0, () => {
      const d1: number = ts(2026, 10, 6, 8, 0);
      const rows = StatsService.gradeDistribution([
        rec(d1, 110, 70, null, 1), rec(d1, 112, 72, null, 2), rec(d1, 114, 74, null, 3)
      ]);
      let sum: number = 0;
      for (let i = 0; i < rows.length; i++) {
        sum += rows[i].percent;
      }
      expect(Math.abs(sum - 100) < 1e-6).assertTrue();
    });

    it('morning_vs_overall_only_morning', 0, () => {
      const surge = StatsService.morningVsOverall([
        rec(ts(2026, 10, 6, 6, 30), 140, 90, null, 1),
        rec(ts(2026, 10, 5, 7, 0), 130, 86, null, 2),
        rec(ts(2026, 10, 3, 20, 0), 120, 78, null, 3),
        rec(ts(2026, 10, 4, 15, 0), 110, 70, null, 4)
      ]);
      expect(surge.morningCount).assertEqual(2);
      expect(surge.morningSys).assertEqual(135);
      expect(surge.overallSys).assertEqual(125);
      expect(surge.deltaSys).assertEqual(10);
      expect(surge.deltaDia).assertEqual(7);
    });

    it('trend_warning_threshold', 0, () => {
      const now: number = ts(2026, 10, 6, 12, 0);
      expect(StatsService.isTrendWarning([rec(ts(2026, 10, 6, 8, 0), 135, 85, null, 1)], now, 7)).assertTrue();
      expect(StatsService.isTrendWarning([rec(ts(2026, 10, 6, 8, 0), 134, 84, null, 1)], now, 7)).assertFalse();
      expect(StatsService.isTrendWarning([], now, 7)).assertFalse();
      expect(StatsService.isTrendWarning([rec(ts(2026, 9, 20, 8, 0), 150, 95, null, 1)], now, 7)).assertFalse();
    });

    it('period_field_is_morning', 0, () => {
      expect(DateUtils.periodOf(ts(2026, 10, 6, 6, 30))).assertEqual(Period.MORNING);
    });
  });
}
