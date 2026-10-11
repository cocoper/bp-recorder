import { BpRecord, DailyPoint, DateRange, DistRow, MorningCompare, RangeStats } from '../model/BpRecord';
import { GradeLevel, Period } from '../model/Types';
import { DateUtils } from '../common/DateUtils';
import { AppConst } from '../common/Constants';
import { GradeService } from './GradeService';

/** 收缩压/舒张压均值对（趋势预警等场景轻量返回） */
export interface MeanPair {
  sys: number;
  dia: number;
  count: number;
}

/**
 * 统计分析（纯函数，无 UI / 无数据库依赖，CL-4 全部指标的落点）。
 *
 * 口径约定（必须唯一，否则手工核算对不上）：
 * - 标准差：总体标准差（除以 N），非样本标准差。
 * - 分级分布占比：合计由「最大余额」调整保证恰为 100.0%。
 * - 均值：算术平均，不剔除极值。
 */
export class StatsService {
  /** 分级档位顺序（0=正常 … 4=3 级），与 DistRow 行序一致 */
  private static readonly LEVELS: GradeLevel[] = [
    GradeLevel.NORMAL, GradeLevel.HIGH_NORMAL, GradeLevel.GRADE_1, GradeLevel.GRADE_2, GradeLevel.GRADE_3
  ];

  /** 枚举 → 数组下标（避免在业务代码里做枚举与数字间的类型断言） */
  private static levelIndex(level: GradeLevel): number {
    switch (level) {
      case GradeLevel.NORMAL:
        return 0;
      case GradeLevel.HIGH_NORMAL:
        return 1;
      case GradeLevel.GRADE_1:
        return 2;
      case GradeLevel.GRADE_2:
        return 3;
      default:
        return 4;
    }
  }

  /** 最近 days 个自然日（含今天）的区间，右端为今天 23:59:59.999 */
  static lastDaysRange(days: number, now: number): DateRange {
    const safeDays: number = days < 1 ? 1 : days;
    const start: number = DateUtils.addDays(DateUtils.startOfDay(now), -(safeDays - 1));
    const end: number = DateUtils.endOfDay(now);
    return { start: start, end: end, label: DateUtils.rangeLabel(start, end) };
  }

  /** 按区间过滤（左闭右闭） */
  static inRange(records: BpRecord[], range: DateRange): BpRecord[] {
    const out: BpRecord[] = [];
    for (let i = 0; i < records.length; i++) {
      const r: BpRecord = records[i];
      if (r.measureTime >= range.start && r.measureTime <= range.end) {
        out.push(r);
      }
    }
    return out;
  }

  /** 总体标准差（÷N）；空数组返回 0 */
  static stdDev(values: number[]): number {
    const n: number = values.length;
    if (n === 0) {
      return 0;
    }
    let sum: number = 0;
    for (let i = 0; i < n; i++) {
      sum += values[i];
    }
    const mean: number = sum / n;
    let acc: number = 0;
    for (let i = 0; i < n; i++) {
      const d: number = values[i] - mean;
      acc += d * d;
    }
    return Math.sqrt(acc / n);
  }

  /** 区间统计（FR-4.1） */
  static rangeStats(records: BpRecord[]): RangeStats {
    const n: number = records.length;
    if (n === 0) {
      return {
        count: 0, sysMean: 0, diaMean: 0, hrMean: null,
        sysMax: 0, sysMin: 0, diaMax: 0, diaMin: 0,
        sysStdDev: 0, diaStdDev: 0
      };
    }
    const sysList: number[] = [];
    const diaList: number[] = [];
    const hrList: number[] = [];
    let sysSum: number = 0;
    let diaSum: number = 0;
    let sysMax: number = records[0].systolic;
    let sysMin: number = records[0].systolic;
    let diaMax: number = records[0].diastolic;
    let diaMin: number = records[0].diastolic;

    for (let i = 0; i < n; i++) {
      const r: BpRecord = records[i];
      sysList.push(r.systolic);
      diaList.push(r.diastolic);
      sysSum += r.systolic;
      diaSum += r.diastolic;
      if (r.systolic > sysMax) {
        sysMax = r.systolic;
      }
      if (r.systolic < sysMin) {
        sysMin = r.systolic;
      }
      if (r.diastolic > diaMax) {
        diaMax = r.diastolic;
      }
      if (r.diastolic < diaMin) {
        diaMin = r.diastolic;
      }
      if (r.heartRate !== null && r.heartRate !== undefined) {
        hrList.push(r.heartRate);
      }
    }

    let hrMean: number | null = null;
    if (hrList.length > 0) {
      let hrSum: number = 0;
      for (let i = 0; i < hrList.length; i++) {
        hrSum += hrList[i];
      }
      hrMean = hrSum / hrList.length;
    }

    return {
      count: n,
      sysMean: sysSum / n,
      diaMean: diaSum / n,
      hrMean: hrMean,
      sysMax: sysMax,
      sysMin: sysMin,
      diaMax: diaMax,
      diaMin: diaMin,
      sysStdDev: StatsService.stdDev(sysList),
      diaStdDev: StatsService.stdDev(diaList)
    };
  }

  /** 轻量均值（趋势预警 FR-5.3） */
  static meanOf(records: BpRecord[]): MeanPair {
    const n: number = records.length;
    if (n === 0) {
      return { sys: 0, dia: 0, count: 0 };
    }
    let sysSum: number = 0;
    let diaSum: number = 0;
    for (let i = 0; i < n; i++) {
      sysSum += records[i].systolic;
      diaSum += records[i].diastolic;
    }
    return { sys: sysSum / n, dia: diaSum / n, count: n };
  }

  /**
   * 每日均值序列（FR-3.3：同日多次测量取平均值）。
   * 实现方式：先按测量时间升序排序，再线性分组，避免依赖 Map 迭代顺序。
   * @param medCompleteDays 当日已完成全部服药打卡的「当日 00:00」时间戳集合
   */
  static dailyMeans(records: BpRecord[], medCompleteDays: number[]): DailyPoint[] {
    if (records.length === 0) {
      return [];
    }
    const sorted: BpRecord[] = records.slice().sort((a: BpRecord, b: BpRecord) => a.measureTime - b.measureTime);
    const result: DailyPoint[] = [];

    let curDay: number = DateUtils.startOfDay(sorted[0].measureTime);
    let sysSum: number = 0;
    let diaSum: number = 0;
    let hrSum: number = 0;
    let hrCount: number = 0;
    let count: number = 0;

    for (let i = 0; i < sorted.length; i++) {
      const r: BpRecord = sorted[i];
      const dayStart: number = DateUtils.startOfDay(r.measureTime);
      if (dayStart !== curDay) {
        result.push(StatsService.buildPoint(curDay, sysSum, diaSum, hrSum, hrCount, count, medCompleteDays));
        curDay = dayStart;
        sysSum = 0;
        diaSum = 0;
        hrSum = 0;
        hrCount = 0;
        count = 0;
      }
      sysSum += r.systolic;
      diaSum += r.diastolic;
      count++;
      if (r.heartRate !== null && r.heartRate !== undefined) {
        hrSum += r.heartRate;
        hrCount++;
      }
    }
    result.push(StatsService.buildPoint(curDay, sysSum, diaSum, hrSum, hrCount, count, medCompleteDays));
    return result;
  }

  private static buildPoint(dayStart: number, sysSum: number, diaSum: number, hrSum: number,
    hrCount: number, count: number, medCompleteDays: number[]): DailyPoint {
    return {
      dayStart: dayStart,
      sysAvg: count === 0 ? 0 : sysSum / count,
      diaAvg: count === 0 ? 0 : diaSum / count,
      hrAvg: hrCount === 0 ? null : hrSum / hrCount,
      count: count,
      medComplete: medCompleteDays.indexOf(dayStart) >= 0
    };
  }

  /**
   * 当日逐次测量序列（v1.13 趋势页「今天」档）。
   * - 只保留**最后一条记录所在自然日**的测量（调用方通常会先按当日过滤，这里再兜一层）；
   * - 每次测量各占一个点，**不做同日聚合**：一天的曲线不该被压成一个点；
   * - 返回点的 `dayStart` 字段放该次测量的**实际时刻**（measureTime），于是 X 轴相邻点间距 = 真实时间差；
   * - `count` 恒为 1；`hrAvg` 无心率时为 null；`medComplete` 取自 medCompleteDays 是否含该日 00:00。
   */
  static intradayPoints(records: BpRecord[], medCompleteDays: number[]): DailyPoint[] {
    if (records.length === 0) {
      return [];
    }
    const sorted: BpRecord[] = records.slice().sort((a: BpRecord, b: BpRecord) => a.measureTime - b.measureTime);
    const targetDay: number = DateUtils.startOfDay(sorted[sorted.length - 1].measureTime);
    const medComplete: boolean = medCompleteDays.indexOf(targetDay) >= 0;
    const result: DailyPoint[] = [];

    for (let i = 0; i < sorted.length; i++) {
      const r: BpRecord = sorted[i];
      if (DateUtils.startOfDay(r.measureTime) !== targetDay) {
        continue;
      }
      result.push({
        dayStart: r.measureTime,
        sysAvg: r.systolic,
        diaAvg: r.diastolic,
        hrAvg: (r.heartRate === null || r.heartRate === undefined) ? null : r.heartRate,
        count: 1,
        medComplete: medComplete
      });
    }
    return result;
  }

  /**
   * 分级分布（FR-4.2）。
   * 固定返回 5 行（正常 / 正常高值 / 1 级 / 2 级 / 3 级），占比合计经最大余额调整后为 100.0%。
   *
   * 分级固定按诊室表判定，**不接收「参考口径」参数**（决策 D1）：
   * 口径设置只影响参考线表述，不影响分布统计，否则同一批数据会随设置得出不同分布。
   */
  static gradeDistribution(records: BpRecord[]): DistRow[] {
    const counts: number[] = [0, 0, 0, 0, 0];
    const total: number = records.length;
    for (let i = 0; i < total; i++) {
      const r: BpRecord = records[i];
      const level: number = StatsService.levelIndex(GradeService.gradeOf(r.systolic, r.diastolic));
      if (level >= 0 && level <= 4) {
        counts[level] = counts[level] + 1;
      }
    }

    const percents: number[] = [0, 0, 0, 0, 0];
    let sum: number = 0;
    for (let i = 0; i < 5; i++) {
      if (total === 0) {
        percents[i] = 0;
      } else {
        percents[i] = Math.round((counts[i] * 1000) / total) / 10;
      }
      sum += percents[i];
    }

    if (total > 0) {
      // 最大余额调整：把舍入残差补给样本量最大的档，保证合计恰为 100.0%
      let maxIdx: number = 0;
      for (let i = 1; i < 5; i++) {
        if (counts[i] > counts[maxIdx]) {
          maxIdx = i;
        }
      }
      const residual: number = Math.round((100 - sum) * 10) / 10;
      if (residual !== 0 && counts[maxIdx] > 0) {
        percents[maxIdx] = Math.round((percents[maxIdx] + residual) * 10) / 10;
      }
    }

    const rows: DistRow[] = [];
    for (let i = 0; i < 5; i++) {
      rows.push({ level: StatsService.LEVELS[i], count: counts[i], percent: percents[i] });
    }
    return rows;
  }

  /**
   * 晨起 / 全天对比（FR-4.3，v1.3 由「晨峰分析」更名）。
   *
   * 口径：仅统计 period === morning 的记录，与全天均值作差。
   * 无晨起记录时 morningCount = 0，UI 据此显示「—」。
   *
   * **不是临床「血压晨峰」**：临床晨峰需要夜间最低血压与晨起后峰值的对比，
   * 本 App 无夜间连续监测能力、取不到夜间最低值。更名与口径说明正是为此
   * （审查意见 P2-4 / 决策 D2）——报告会打印给医生看，术语不能误导。
   */
  static morningVsOverall(records: BpRecord[]): MorningCompare {
    const morning: BpRecord[] = [];
    for (let i = 0; i < records.length; i++) {
      if (records[i].period === Period.MORNING) {
        morning.push(records[i]);
      }
    }
    const overall: MeanPair = StatsService.meanOf(records);
    const morningMean: MeanPair = StatsService.meanOf(morning);
    const hasMorning: boolean = morning.length > 0;
    return {
      morningCount: morning.length,
      morningSys: hasMorning ? morningMean.sys : 0,
      morningDia: hasMorning ? morningMean.dia : 0,
      overallSys: overall.sys,
      overallDia: overall.dia,
      deltaSys: hasMorning ? morningMean.sys - overall.sys : 0,
      deltaDia: hasMorning ? morningMean.dia - overall.dia : 0
    };
  }

  /**
   * 趋势预警判定（FR-5.3）：近 N 天（含今天）均值 ≥135/85 时返回 true。
   * 无任何记录时返回 false（不预警）。
   *
   * 阈值固定取**家庭自测界值 135/85**，不随「参考口径」设置变化：
   * 本 App 数据全部为居家自测，若改用诊室阈值 140/90 判定家庭数据，
   * 会系统性漏报（审查意见 P1-6 的底层诉求，见决策记录 D1）。
   */
  static isTrendWarning(records: BpRecord[], now: number, days: number): boolean {
    const range: DateRange = StatsService.lastDaysRange(days, now);
    const scoped: BpRecord[] = StatsService.inRange(records, range);
    if (scoped.length === 0) {
      return false;
    }
    const mean: MeanPair = StatsService.meanOf(scoped);
    return mean.sys >= AppConst.REF_HOME_SYS || mean.dia >= AppConst.REF_HOME_DIA;
  }
}
