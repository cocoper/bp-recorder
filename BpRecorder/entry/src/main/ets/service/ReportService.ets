import { Adherence, BpRecord, DateRange, DailyPoint, DistRow, MorningCompare, RangeStats } from '../model/BpRecord';
import { AbnormalItem, MedLog, MedPlan, ReportData } from '../model/Med';
import { MedLogStatus } from '../model/Types';
import { DateUtils } from '../common/DateUtils';
import { AppConst, ReportKind } from '../common/Constants';
import { ReportVocab } from '../common/Vocab';
import { GradeService } from './GradeService';
import { MedService } from './MedService';
import { StatsService } from './StatsService';

/**
 * 周期报告数据组装（FR-10）。
 *
 * 纯函数：不依赖 UI 与数据库，输入为已取出的数据数组，输出为 ReportData。
 * 因此报告口径与统计页共用同一套 StatsService，保证「报告数值 == 统计页数值」（CL-9）。
 *
 * 周期定义：周报 = 自然周（周一至周日）；月报 = 自然月；自定义 ≤92 天（FR-10.1）。
 */
export class ReportService {
  // ───────────────────────── 周期计算 ─────────────────────────

  static weekRange(anchor: number): DateRange {
    const start: number = DateUtils.startOfWeek(anchor);
    const end: number = DateUtils.endOfWeek(anchor);
    return { start: start, end: end, label: DateUtils.rangeLabel(start, end) };
  }

  static monthRange(anchor: number): DateRange {
    const start: number = DateUtils.startOfMonth(anchor);
    const end: number = DateUtils.endOfMonth(anchor);
    return { start: start, end: end, label: DateUtils.rangeLabel(start, end) };
  }

  /** 自定义区间：入参为日粒度时间戳，内部对齐到当日 00:00 / 23:59:59.999 */
  static customRange(startDay: number, endDay: number): DateRange {
    const start: number = DateUtils.startOfDay(startDay);
    const end: number = DateUtils.endOfDay(endDay);
    return { start: start, end: end, label: DateUtils.rangeLabel(start, end) };
  }

  /** 自定义区间合法性（FR-10.1：≤92 天，且起点不晚于终点） */
  static isCustomRangeValid(startDay: number, endDay: number): boolean {
    if (endDay < startDay) {
      return false;
    }
    return DateUtils.daysInclusive(startDay, endDay) <= AppConst.REPORT_MAX_DAYS;
  }

  /** 上一周期（用于环比，FR-10.2 板块 6） */
  static prevRange(range: DateRange, kind: string): DateRange {
    if (kind === ReportKind.WEEK) {
      return ReportService.weekRange(DateUtils.addDays(range.start, -1));
    }
    if (kind === ReportKind.MONTH) {
      return ReportService.monthRange(DateUtils.addDays(range.start, -1));
    }
    const days: number = DateUtils.daysInclusive(range.start, range.end);
    const end: number = range.start - 1;
    const start: number = DateUtils.startOfDay(DateUtils.addDays(end, -(days - 1)));
    return { start: start, end: end, label: DateUtils.rangeLabel(start, end) };
  }

  /** 最近 count 个自然周（旧 → 新，供「最近 4 周」快选） */
  static recentWeeks(anchor: number, count: number): DateRange[] {
    const out: DateRange[] = [];
    const base: number = DateUtils.addDays(DateUtils.startOfWeek(anchor), -(count - 1) * 7);
    for (let i = 0; i < count; i++) {
      out.push(ReportService.weekRange(DateUtils.addDays(base, i * 7)));
    }
    return out;
  }

  /** 最近 count 个自然月（旧 → 新，供「最近 3 个月」快选） */
  static recentMonths(anchor: number, count: number): DateRange[] {
    const out: DateRange[] = [];
    const base: number = DateUtils.addMonths(DateUtils.startOfMonth(anchor), -(count - 1));
    for (let i = 0; i < count; i++) {
      out.push(ReportService.monthRange(DateUtils.addMonths(base, i)));
    }
    return out;
  }

  // ───────────────────────── 数据组装 ─────────────────────────

  /**
   * 组装报告数据。区间内无血压记录时返回 null（FR-10.4：不生成报告，提示「该周期暂无数据」）。
   */
  static build(kind: string, range: DateRange, records: BpRecord[], logs: MedLog[], plans: MedPlan[],
    vocab: ReportVocab, now: number): ReportData | null {
    const scoped: BpRecord[] = StatsService.inRange(records, range);
    if (scoped.length === 0) {
      return null;
    }

    const scopedLogs: MedLog[] = ReportService.logsInRange(logs, range);
    const stats: RangeStats = StatsService.rangeStats(scoped);
    const distribution: DistRow[] = StatsService.gradeDistribution(scoped);
    const morningCompare: MorningCompare = StatsService.morningVsOverall(scoped);
    const dailyPoints: DailyPoint[] = StatsService.dailyMeans(scoped, ReportService.medCompleteDays(scopedLogs, now));
    const abnormals: AbnormalItem[] = ReportService.buildAbnormals(scoped);
    const adherence: Adherence = MedService.adherence(scopedLogs, now);

    const prev: DateRange = ReportService.prevRange(range, kind);
    const prevScoped: BpRecord[] = StatsService.inRange(records, prev);
    const hasPrev: boolean = prevScoped.length > 0;
    const prevStats: RangeStats = StatsService.rangeStats(prevScoped);

    const title: string = kind === ReportKind.WEEK ? vocab.titleWeek
      : (kind === ReportKind.MONTH ? vocab.titleMonth : vocab.titleCustom);
    const watermark: string = `${range.label}${vocab.separator}${DateUtils.formatDateTime(now)}${vocab.separator}${vocab.watermarkSuffix}`;

    return {
      kind: kind,
      title: title,
      range: range,
      generatedAt: now,
      stats: stats,
      distribution: distribution,
      morningCompare: morningCompare,
      hasPrev: hasPrev,
      prevLabel: hasPrev ? prev.label : '',
      prevSysMean: prevStats.sysMean,
      prevDiaMean: prevStats.diaMean,
      deltaSys: hasPrev ? stats.sysMean - prevStats.sysMean : 0,
      deltaDia: hasPrev ? stats.diaMean - prevStats.diaMean : 0,
      dailyPoints: dailyPoints,
      abnormals: abnormals,
      adherence: adherence,
      // 审查 R11：小结看「周期内有没有用药数据」，而不是「当前有没有生效计划」。
      // 过去归档/计划到期后，同一历史周期的用药小结会凭空消失（数字前后不一致）。
      hasMedicationData: scopedLogs.length > 0,
      medPendingNotDue: ReportService.countPendingNotDue(scopedLogs, now),
      hasMedPlan: scopedLogs.length > 0,
      watermark: watermark
    };
  }

  /**
   * 周期内「尚未到期」的待服条数（审查 R11）：
   * 用于把「本期有义务但还没到点」与「本期完全没有用药数据」区分开来展示。
   */
  static countPendingNotDue(logs: MedLog[], now: number): number {
    let count: number = 0;
    for (let i = 0; i < logs.length; i++) {
      const log: MedLog = logs[i];
      if (log.status === MedLogStatus.PENDING && log.scheduledTime > now) {
        count++;
      }
    }
    return count;
  }

  /** 区间内的打卡记录 */
  static logsInRange(logs: MedLog[], range: DateRange): MedLog[] {
    const out: MedLog[] = [];
    for (let i = 0; i < logs.length; i++) {
      const t: number = logs[i].scheduledTime;
      if (t >= range.start && t <= range.end) {
        out.push(logs[i]);
      }
    }
    return out;
  }

  /**
   * 当日已完成全部服药打卡的日期集合（FR-9.6 图表药丸标记）。
   * 判定：该日所有打卡记录的有效状态均为 taken。
   */
  static medCompleteDays(logs: MedLog[], now: number): number[] {
    if (logs.length === 0) {
      return [];
    }
    const sorted: MedLog[] = logs.slice().sort((a: MedLog, b: MedLog) => a.scheduledTime - b.scheduledTime);
    const out: number[] = [];
    let curDay: number = DateUtils.startOfDay(sorted[0].scheduledTime);
    let allTaken: boolean = true;

    for (let i = 0; i < sorted.length; i++) {
      const day: number = DateUtils.startOfDay(sorted[i].scheduledTime);
      if (day !== curDay) {
        if (allTaken) {
          out.push(curDay);
        }
        curDay = day;
        allTaken = true;
      }
      if (MedService.resolveStatus(sorted[i], now) !== MedLogStatus.TAKEN) {
        allTaken = false;
      }
    }
    if (allTaken) {
      out.push(curDay);
    }
    return out;
  }

  /** 异常清单（FR-10.2 板块 7）：仅含 ≥140/90 的记录，按时间升序 */
  private static buildAbnormals(records: BpRecord[]): AbnormalItem[] {
    const sorted: BpRecord[] = records.slice().sort((a: BpRecord, b: BpRecord) => a.measureTime - b.measureTime);
    const out: AbnormalItem[] = [];
    for (let i = 0; i < sorted.length; i++) {
      const r: BpRecord = sorted[i];
      if (GradeService.isAbnormal(r.systolic, r.diastolic)) {
        out.push({
          measureTime: r.measureTime,
          systolic: r.systolic,
          diastolic: r.diastolic,
          period: r.period
        });
      }
    }
    return out;
  }

  private static countActivePlans(plans: MedPlan[]): number {
    let count: number = 0;
    for (let i = 0; i < plans.length; i++) {
      if (plans[i].isActive) {
        count++;
      }
    }
    return count;
  }
}
