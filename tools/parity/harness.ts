// 离线边界用例（对真实 .ets 纯逻辑源码执行）。
// 覆盖策划文档第 7 章：CL-2 时段边界、CL-4 统计口径、CL-5 医学分级边界、CL-10 CSV 解析。
import './preload';
import { DateUtils } from './src/common/DateUtils';
import { Csv } from './src/common/Csv';
import { GradeService } from './src/service/GradeService';
import { StatsService } from './src/service/StatsService';
import { MedService } from './src/service/MedService';
import { BpValidator } from './src/service/BpValidator';
import { ExportService } from './src/service/ExportService';
import { ImportService, MedImportDraft } from './src/service/ImportService';
import { ReportService } from './src/service/ReportService';
import { CsvVocab, ImportVocab } from './src/common/Vocab';
import { CheckInAction, GradeLevel, GradeStandard, MedLogStatus, Period } from './src/model/Types';
import { RefBasis, ImportAliasRes, ImportKind, ImportUnit, MedLimits } from './src/common/Constants';
import { LooseParse, BpPairValue } from './src/common/LooseParse';
import {
  ColRole, GenericImportService, GenericBpPreview, Detection, MappingPlan, ROLE_COUNT
} from './src/service/GenericImportService';
import { BpRecord } from './src/model/BpRecord';
import { Medication, MedLog, MedPlan, PlanExportRow } from './src/model/Med';
import { BpDatabase, TxSession } from './src/service/BpDatabase';
import { common } from '@kit.AbilityKit';
import { relationalStore } from '@kit.ArkData';

let passCount = 0;
const failures: string[] = [];
let groupName = '';

function group(name: string): void {
  groupName = name;
}
function ok(cond: boolean, name: string, extra?: string): void {
  if (cond) {
    passCount++;
  } else {
    failures.push(`[${groupName}] ${name}${extra === undefined ? '' : ' :: ' + extra}`);
  }
}
function eq(actual: unknown, expected: unknown, name: string): void {
  ok(actual === expected, name, `期望 ${String(expected)}，实际 ${String(actual)}`);
}
function near(actual: number, expected: number, name: string, tol: number = 1e-9): void {
  ok(Math.abs(actual - expected) <= tol, name, `期望 ${expected}，实际 ${actual}`);
}

/** 本地时间戳构造 */
function ts(y: number, m: number, d: number, hh: number, mm: number): number {
  return new Date(y, m - 1, d, hh, mm, 0, 0).getTime();
}

function rec(measureTime: number, sys: number, dia: number, hr: number | null, id: number = 1): BpRecord {
  return {
    id: id, systolic: sys, diastolic: dia, heartRate: hr, measureTime: measureTime,
    period: DateUtils.periodOf(measureTime), note: null, userId: 1, source: 'manual',
    createdAt: measureTime, updatedAt: measureTime
  };
}

function med(id: number, name: string, active: boolean = true): Medication {
  return {
    id: id, name: name, dosage: '1片', note: null, isActive: active, createdAt: 0, updatedAt: 0
  };
}

function plan(id: number, medId: number, slots: string[], start: string, end: string | null,
  active: boolean = true): MedPlan {
  return {
    id: id, medicationId: medId, timeSlots: slots, startDate: start, endDate: end,
    isActive: active, createdAt: 0, updatedAt: 0
  };
}

function mlog(scheduledTime: number, status: MedLogStatus, takenTime: number | null, id: number = 1,
  medId: number = 1, name: string = '缬沙坦'): MedLog {
  return {
    id: id, medicationId: medId, medName: name, dosage: '1片', scheduledTime: scheduledTime,
    takenTime: takenTime, status: status, note: null, createdAt: scheduledTime, updatedAt: scheduledTime
  };
}

// ═══════════════════ 1. 时段自动推断（CL-2：六个边界时刻） ═══════════════════
group('时段推断 DateUtils.periodOf');
const D: number = 6;
eq(DateUtils.periodOf(ts(2026, 10, D, 4, 59)), Period.OTHER, '04:59 → other');
eq(DateUtils.periodOf(ts(2026, 10, D, 5, 0)), Period.MORNING, '05:00 → morning');
eq(DateUtils.periodOf(ts(2026, 10, D, 8, 59)), Period.MORNING, '08:59 → morning');
eq(DateUtils.periodOf(ts(2026, 10, D, 9, 0)), Period.FORENOON, '09:00 → forenoon');
eq(DateUtils.periodOf(ts(2026, 10, D, 13, 59)), Period.FORENOON, '13:59 → forenoon');
eq(DateUtils.periodOf(ts(2026, 10, D, 14, 0)), Period.AFTERNOON, '14:00 → afternoon');
eq(DateUtils.periodOf(ts(2026, 10, D, 17, 59)), Period.AFTERNOON, '17:59 → afternoon');
eq(DateUtils.periodOf(ts(2026, 10, D, 18, 0)), Period.NIGHT, '18:00 → night');
eq(DateUtils.periodOf(ts(2026, 10, D, 22, 59)), Period.NIGHT, '22:59 → night');
eq(DateUtils.periodOf(ts(2026, 10, D, 23, 0)), Period.NIGHT, '23:00 → night（D3：睡前延至 24:00）');
eq(DateUtils.periodOf(ts(2026, 10, D, 23, 59)), Period.NIGHT, '23:59 → night（D3 边界）');
eq(DateUtils.periodOf(ts(2026, 10, D, 0, 0)), Period.OTHER, '00:00 → other（跨日后归其他）');
eq(DateUtils.periodOf(ts(2026, 10, D, 2, 30)), Period.OTHER, '02:30 → other');

// ═══════════════════ 2. 日期工具 ═══════════════════
group('日期工具');
eq(DateUtils.formatDate(ts(2026, 10, D, 8, 12)), '2026-10-06', 'formatDate');
eq(DateUtils.formatTime(ts(2026, 10, D, 8, 12)), '08:12', 'formatTime');
eq(DateUtils.startOfWeek(ts(2026, 10, 6, 10, 0)), ts(2026, 10, 5, 0, 0), '周二所在周起点为周一 10-05');
ok(new Date(DateUtils.startOfWeek(ts(2026, 10, 6, 10, 0))).getDay() === 1, '周起点 getDay()===1');
eq(DateUtils.startOfWeek(ts(2026, 10, 11, 10, 0)), ts(2026, 10, 5, 0, 0), '周日归属上一周（周一 10-05）');
eq(DateUtils.endOfWeek(ts(2026, 10, 6, 10, 0)), ts(2026, 10, 11, 23, 59) + 59 * 1000 + 999, '周终点为周日 23:59:59.999');
eq(DateUtils.formatDate(DateUtils.startOfMonth(ts(2026, 10, 6, 10, 0))), '2026-10-01', '月初');
eq(DateUtils.formatDate(DateUtils.endOfMonth(ts(2026, 10, 6, 10, 0))), '2026-10-31', '月末（31 天月）');
eq(DateUtils.formatDate(DateUtils.endOfMonth(ts(2026, 2, 10, 10, 0))), '2026-02-28', '月末（平年 2 月）');
eq(DateUtils.formatDate(DateUtils.endOfMonth(ts(2028, 2, 10, 10, 0))), '2028-02-29', '月末（闰年 2 月）');
eq(DateUtils.daysInclusive(ts(2026, 9, 28, 0, 0), ts(2026, 10, 4, 23, 0)), 7, '自然周 7 天');
eq(DateUtils.daysInclusive(ts(2026, 10, 6, 8, 0), ts(2026, 10, 6, 20, 0)), 1, '同日为 1 天');
eq(DateUtils.addDays(ts(2026, 12, 31, 8, 0), 1), ts(2027, 1, 1, 8, 0), '跨年加一天');
eq(DateUtils.formatDate(DateUtils.addMonths(ts(2026, 1, 31, 8, 0), 1)), '2026-03-03', '月末加月溢出（1-31 + 1 月）');
ok(DateUtils.parseDate('2026-02-30') === null, '拒绝不存在的日期 2026-02-30');
ok(DateUtils.parseDate('2026-13-01') === null, '拒绝非法月份 2026-13-01');
ok(DateUtils.parseDate('2026-1-1') === null, '拒绝非补零日期');
ok(DateUtils.parseDate('abc') === null, '拒绝非日期串');
ok(DateUtils.parseDate('2028-02-29') !== null, '接受闰年 2028-02-29');
eq(DateUtils.hhmmToMinutes('07:30'), 450, 'hhmm→分钟');
eq(DateUtils.hhmmToMinutes('24:00'), -1, '拒绝 24:00');
eq(DateUtils.hhmmToMinutes('7:30'), -1, '拒绝非补零时间');
eq(DateUtils.hhmmToMinutes('07:60'), -1, '拒绝 07:60');
eq(DateUtils.minutesToHhmm(450), '07:30', '分钟→hhmm');
eq(DateUtils.parseDateTime('2026-10-06', '07:30'), ts(2026, 10, 6, 7, 30), '日期+时间→时间戳');
eq(DateUtils.parseDateTime('2026-02-30', '07:30'), null, '非法日期返回 null');
eq(DateUtils.eachDayStart(ts(2026, 9, 28, 0, 0), ts(2026, 10, 4, 0, 0)).length, 7, 'eachDayStart 生成 7 天');

// ═══════════════════ 3. 医学分级（CL-5 六个边界值 + 全档边界） ═══════════════════
group('分级判定 GradeService（诊室表，唯一分级表）');
const CN: GradeStandard = GradeStandard.CN_GUIDELINE;
const HOME_BASIS: GradeStandard = GradeStandard.HOME_MONITOR;
// ── 决策 D1：参考口径只影响参考阈值与文案，**不影响分级** ──
eq(RefBasis.of(CN).sys, 140, 'D1: 诊室口径 → 参考线 140');
eq(RefBasis.of(CN).dia, 90, 'D1: 诊室口径 → 参考线 90');
eq(RefBasis.of(HOME_BASIS).sys, 135, 'D1: 家庭口径 → 参考线 135');
eq(RefBasis.of(HOME_BASIS).dia, 85, 'D1: 家庭口径 → 参考线 85');
eq(RefBasis.DEFAULT, HOME_BASIS, 'D1: 参考口径默认值 = 家庭自测');
eq(GradeService.gradeOf(119, 79), GradeLevel.NORMAL, 'CL-5: 119/79 → 正常');
eq(GradeService.gradeOf(120, 80), GradeLevel.HIGH_NORMAL, 'CL-5: 120/80 → 正常高值');
eq(GradeService.gradeOf(140, 90), GradeLevel.GRADE_1, 'CL-5: 140/90 → 1 级');
eq(GradeService.gradeOf(160, 100), GradeLevel.GRADE_2, 'CL-5: 160/100 → 2 级');
eq(GradeService.gradeOf(180, 110), GradeLevel.GRADE_3, 'CL-5: 180/110 → 3 级');
eq(GradeService.gradeOf(135, 85), GradeLevel.HIGH_NORMAL, 'CL-5: 135/85 → 正常高值（诊室口径）');
eq(GradeService.gradeOf(139, 89), GradeLevel.HIGH_NORMAL, '139/89 → 正常高值上界');
eq(GradeService.gradeOf(159, 99), GradeLevel.GRADE_1, '159/99 → 1 级上界');
eq(GradeService.gradeOf(179, 109), GradeLevel.GRADE_2, '179/109 → 2 级上界');
eq(GradeService.gradeOf(180, 70), GradeLevel.GRADE_3, '收缩压单独达 3 级');
eq(GradeService.gradeOf(110, 110), GradeLevel.GRADE_3, '舒张压单独达 3 级');
eq(GradeService.gradeOf(118, 95), GradeLevel.GRADE_1, '取高者：收缩正常 / 舒张 1 级 → 1 级');
eq(GradeService.gradeOf(165, 70), GradeLevel.GRADE_2, '取高者：收缩 2 级 / 舒张正常 → 2 级');
eq(GradeService.gradeOf(139, 90), GradeLevel.GRADE_1, '取高者：收缩正常高值 / 舒张 1 级 → 1 级');
eq(GradeService.gradeOf(140, 89), GradeLevel.GRADE_1, '取高者：收缩 1 级 / 舒张正常高值 → 1 级');

// ── 决策 D1：家庭口径不再产生第二套分级表（原「阈值整体下移 5」已移除）──
// 原家庭表下的边界数值保留为回归用例：现在都应落到**诊室表**的对应档，
// 即「切换参考口径不会改变任何一条记录的分级」。
group('分级判定：参考口径不影响分级（D1 回归）');
eq(GradeService.gradeOf(114, 74), GradeLevel.NORMAL, '114/74 → 正常（诊室表）');
eq(GradeService.gradeOf(135, 85), GradeLevel.HIGH_NORMAL, '135/85 → 正常高值（原家庭表会判 1 级，已修正）');
eq(GradeService.gradeOf(154, 94), GradeLevel.GRADE_1, '154/94 → 1 级（原家庭表边界，现按诊室表）');
eq(GradeService.gradeOf(155, 95), GradeLevel.GRADE_1, '155/95 → 1 级（不再下移为 2 级）');
eq(GradeService.gradeOf(175, 105), GradeLevel.GRADE_2, '175/105 → 2 级（不再下移为 3 级）');
eq(GradeService.gradeOf(140, 90), GradeLevel.GRADE_1, '140/90 → 1 级（固定诊室表）');

group('强警示 / 异常清单');
ok(GradeService.isSevere(180, 70), '≥180 → 强警示');
ok(GradeService.isSevere(120, 110), '≥110 → 强警示');
ok(!GradeService.isSevere(179, 109), '179/109 → 不触发强警示');
ok(!GradeService.isSevere(180 - 1, 110 - 1), '恰好低于双阈值 → 不触发');
ok(GradeService.isSevere(200, 130), '远超阈值 → 强警示');
ok(GradeService.isAbnormal(140, 80), '异常清单：收缩 ≥140');
ok(GradeService.isAbnormal(139, 90), '异常清单：舒张 ≥90');
ok(!GradeService.isAbnormal(139, 89), '异常清单：139/89 不算异常');
ok(!GradeService.isAbnormal(120, 80), '异常清单：120/80 不算异常');

// ═══════════════════ 4. 统计口径（CL-4） ═══════════════════
group('统计分析 StatsService');
near(StatsService.stdDev([100, 110, 120, 130, 140]), 14.142135623730951, '总体标准差（÷N）五元素');
near(StatsService.stdDev([120, 130, 140]), 8.16496580927726, '总体标准差三元素');
near(StatsService.stdDev([128]), 0, '单元素标准差为 0');
near(StatsService.stdDev([]), 0, '空数组标准差为 0');

const day1: number = ts(2026, 10, 6, 8, 0);
const day2: number = ts(2026, 10, 5, 21, 40);
const rs1: BpRecord[] = [
  rec(day1, 128, 82, 72, 1),
  rec(day1 + 3600000, 132, 84, 76, 2),
  rec(day2, 140, 90, null, 3)
];
const st = StatsService.rangeStats(rs1);
eq(st.count, 3, 'count');
near(st.sysMean, 133.33333333333334, 'sysMean');
near(st.diaMean, 85.33333333333333, 'diaMean');
near(st.hrMean as number, 74, 'hrMean 忽略空心率');
eq(st.sysMax, 140, 'sysMax');
eq(st.sysMin, 128, 'sysMin');
eq(st.diaMax, 90, 'diaMax');
eq(st.diaMin, 82, 'diaMin');
near(st.sysStdDev, Math.sqrt(((128 - 400 / 3) ** 2 + (132 - 400 / 3) ** 2 + (140 - 400 / 3) ** 2) / 3), 'sysStdDev 交叉核算');

const rsEmpty = StatsService.rangeStats([]);
eq(rsEmpty.count, 0, '空集 count=0');
eq(rsEmpty.hrMean, null, '空集 hrMean=null');
eq(rsEmpty.sysStdDev, 0, '空集标准差 0');

group('每日均值与服药标记');
const dm = StatsService.dailyMeans(rs1, [DateUtils.startOfDay(day1)]);
eq(dm.length, 2, '两天 → 2 个点');
eq(dm[0].count, 1, '10-05 仅 1 条');
near(dm[0].sysAvg, 140, '10-05 均值');
eq(dm[1].count, 2, '10-06 有 2 条');
near(dm[1].sysAvg, 130, '10-06 收缩压均值 (128+132)/2');
near(dm[1].diaAvg, 83, '10-06 舒张压均值');
near(dm[1].hrAvg as number, 74, '10-06 心率均值');
eq(dm[0].medComplete, false, '10-05 无服药标记');
eq(dm[1].medComplete, true, '10-06 有服药标记');
eq(StatsService.dailyMeans([], []).length, 0, '空数据 → 空序列');

group('当日逐次序列（今天档）');
{
  // 同日三次测量（含一次无心率）：每次测量各占一个点，不做同日聚合
  const t1: number = ts(2026, 10, 6, 8, 0);
  const t2: number = ts(2026, 10, 6, 12, 30);
  const t3: number = ts(2026, 10, 6, 21, 40);
  const source: BpRecord[] = [
    rec(t3, 138, 88, 80, 3), rec(t1, 128, 82, 72, 1), rec(t2, 132, 84, null, 2)
  ];
  const ip = StatsService.intradayPoints(source, [DateUtils.startOfDay(t1)]);
  eq(ip.length, 3, '同日三次测量 → 3 个点');
  eq(ip[0].dayStart, t1, '第 1 点 dayStart = 实际测量时刻 08:00');
  eq(ip[1].dayStart, t2, '第 2 点 dayStart = 实际测量时刻 12:30');
  eq(ip[2].dayStart, t3, '第 3 点 dayStart = 实际测量时刻 21:40');
  eq(ip[0].count, 1, 'count 恒为 1（第 1 点）');
  eq(ip[1].count, 1, 'count 恒为 1（第 2 点）');
  eq(ip[2].count, 1, 'count 恒为 1（第 3 点）');
  eq(ip[0].sysAvg, 128, '逐次收缩压取原值');
  eq(ip[1].diaAvg, 84, '逐次舒张压取原值');
  eq(ip[0].hrAvg, 72, '有心率时取原值');
  eq(ip[1].hrAvg, null, '无心率 → null');
  eq(ip[2].hrAvg, 80, '有心率时取原值');
  eq(ip[0].medComplete, true, 'medCompleteDays 含该日 → true');
  eq(ip[2].medComplete, true, 'medCompleteDays 含该日 → 每个点都标 true');
  eq(source[0].measureTime, t3, '不就地修改入参顺序（slice 后排序）');
}
{
  // 跨天数据：只保留最后一条记录所在自然日
  const prev: number = ts(2026, 10, 5, 21, 40);
  const t1: number = ts(2026, 10, 6, 8, 0);
  const t2: number = ts(2026, 10, 6, 20, 0);
  const ip = StatsService.intradayPoints([
    rec(prev, 140, 90, null, 1), rec(t1, 128, 82, 72, 2), rec(t2, 130, 84, 76, 3)
  ], [DateUtils.startOfDay(t1)]);
  eq(ip.length, 2, '跨天数据 → 只留最后一条所在日 10-06');
  eq(ip[0].dayStart, t1, '跨天兜底：第 1 点为 10-06 08:00');
  eq(ip[1].dayStart, t2, '跨天兜底：第 2 点为 10-06 20:00');
}
{
  // medCompleteDays 不含该日 → 标记为 false
  const t1: number = ts(2026, 10, 6, 8, 0);
  const otherDay: number = DateUtils.startOfDay(ts(2026, 10, 5, 8, 0));
  const ip = StatsService.intradayPoints([rec(t1, 128, 82, 72, 1)], [otherDay]);
  eq(ip.length, 1, '单条记录亦返回一个点');
  eq(ip[0].medComplete, false, 'medCompleteDays 不含该日 → false');
}
eq(StatsService.intradayPoints([], []).length, 0, '空数据 → 空序列');

group('分级分布（合计恰为 100.0%）');
const dist7: BpRecord[] = [
  rec(day1, 110, 70, null, 1), rec(day1, 115, 75, null, 2),
  rec(day1, 118, 78, null, 3), rec(day1, 119, 79, null, 4),
  rec(day1, 125, 82, null, 5), rec(day1, 130, 85, null, 6),
  rec(day1, 145, 92, null, 7)
];
const d7 = StatsService.gradeDistribution(dist7);
eq(d7.length, 5, '固定返回 5 行');
eq(d7[0].count, 4, '正常 4 条');
eq(d7[1].count, 2, '正常高值 2 条');
eq(d7[2].count, 1, '1 级 1 条');
near(d7[0].percent, 57.1, '正常 57.1%');
near(d7[1].percent, 28.6, '正常高值 28.6%');
near(d7[2].percent, 14.3, '1 级 14.3%');
near(d7.reduce((a, r) => a + r.percent, 0), 100, '合计 100.0%', 1e-6);

const dist3: BpRecord[] = [rec(day1, 110, 70, null, 1), rec(day1, 112, 72, null, 2), rec(day1, 114, 74, null, 3)];
const d3 = StatsService.gradeDistribution(dist3);
near(d3.reduce((a, r) => a + r.percent, 0), 100, '全同档时合计仍为 100.0%', 1e-6);
near(d3[0].percent, 100, '最大余额调整后正常档为 100.0%');

const distMix: BpRecord[] = [
  rec(day1, 110, 70, null, 1), rec(day1, 112, 72, null, 2), rec(day1, 125, 82, null, 3),
  rec(day1, 145, 92, null, 4), rec(day1, 165, 102, null, 5), rec(day1, 185, 115, null, 6)
];
const dmix = StatsService.gradeDistribution(distMix);
near(dmix.reduce((a, r) => a + r.percent, 0), 100, '六条混合数据合计 100.0%', 1e-6);
eq(dmix[4].count, 1, '3 级 1 条');

const distEmpty = StatsService.gradeDistribution([]);
near(distEmpty.reduce((a, r) => a + r.percent, 0), 0, '空数据合计 0');

group('晨起 / 全天对比（仅统计 morning；v1.3 由「晨峰」更名）');
const surgeRecs: BpRecord[] = [
  rec(ts(2026, 10, 6, 6, 30), 140, 90, null, 1),
  rec(ts(2026, 10, 5, 7, 0), 130, 86, null, 2),
  rec(ts(2026, 10, 3, 20, 0), 120, 78, null, 3),
  rec(ts(2026, 10, 4, 15, 0), 110, 70, null, 4)
];
const sg = StatsService.morningVsOverall(surgeRecs);
eq(sg.morningCount, 2, '晨起 2 条');
near(sg.morningSys, 135, '晨起收缩压均值');
near(sg.overallSys, 125, '全天收缩压均值');
near(sg.deltaSys, 10, '晨起与全天差值收缩 +10（135−125）');
near(sg.deltaDia, 7, '晨起与全天差值舒张 +7（88−81）');
const sgNone = StatsService.morningVsOverall([rec(ts(2026, 10, 6, 20, 0), 120, 78, null, 1)]);
eq(sgNone.morningCount, 0, '无晨起记录时 morningCount=0');
near(sgNone.deltaSys, 0, '无晨起记录时差值为 0');

group('趋势预警（FR-5.3）');
const now = ts(2026, 10, 6, 12, 0);
ok(StatsService.isTrendWarning([rec(ts(2026, 10, 6, 8, 0), 135, 85, null, 1)], now, 7), '均值恰为 135/85 → 预警');
ok(StatsService.isTrendWarning([rec(ts(2026, 10, 6, 8, 0), 130, 90, null, 1)], now, 7), '舒张 90 ≥85 → 预警');
ok(!StatsService.isTrendWarning([rec(ts(2026, 10, 6, 8, 0), 134, 84, null, 1)], now, 7), '134/84 → 不预警');
ok(!StatsService.isTrendWarning([], now, 7), '无数据 → 不预警');
ok(!StatsService.isTrendWarning([rec(ts(2026, 9, 20, 8, 0), 150, 95, null, 1)], now, 7), '7 天窗口外的高值不影响预警');
near(StatsService.meanOf([]).count, 0, '空集均值 count=0');

// ═══════════════════ 5. 打卡状态机与依从率（CL-8） ═══════════════════
group('打卡状态机');
const s2350 = ts(2026, 10, 5, 23, 50);
eq(MedService.resolveStatus(mlog(s2350, MedLogStatus.PENDING, null), ts(2026, 10, 6, 1, 49)), MedLogStatus.PENDING, '跨天：+1h59m 仍为待服');
eq(MedService.resolveStatus(mlog(s2350, MedLogStatus.PENDING, null), ts(2026, 10, 6, 1, 50)), MedLogStatus.PENDING, '跨天：恰好 +2h 仍为待服（严格大于才判漏服）');
eq(MedService.resolveStatus(mlog(s2350, MedLogStatus.PENDING, null), ts(2026, 10, 6, 1, 51)), MedLogStatus.MISSED, '跨天：+2h01m 判漏服');
eq(MedService.resolveStatus(mlog(s2350, MedLogStatus.TAKEN, s2350), ts(2026, 10, 6, 12, 0)), MedLogStatus.TAKEN, '已服不受超时影响');
eq(MedService.resolveStatus(mlog(s2350, MedLogStatus.SKIPPED, null), ts(2026, 10, 6, 12, 0)), MedLogStatus.SKIPPED, '跳过不受超时影响');
eq(MedService.resolveStatus(mlog(s2350, MedLogStatus.MISSED, null), ts(2026, 10, 6, 12, 0)), MedLogStatus.MISSED, '漏服状态保持');

ok(MedService.isMakeUp(mlog(s2350, MedLogStatus.TAKEN, s2350 + 2 * 3600000 + 1)), '补记：晚于 +2h 判定为补记');
ok(!MedService.isMakeUp(mlog(s2350, MedLogStatus.TAKEN, s2350 + 2 * 3600000)), '恰好 +2h 不算补记');
ok(!MedService.isMakeUp(mlog(s2350, MedLogStatus.TAKEN, s2350 + 60000)), '准时服用不算补记');
ok(!MedService.isMakeUp(mlog(s2350, MedLogStatus.TAKEN, null)), 'taken 但无打卡时间不算补记');
ok(!MedService.isMakeUp(mlog(s2350, MedLogStatus.SKIPPED, null)), '跳过不算补记');

eq(MedService.nextStatus(CheckInAction.TAKE), MedLogStatus.TAKEN, 'pending → taken');
eq(MedService.nextStatus(CheckInAction.SKIP), MedLogStatus.SKIPPED, 'pending → skipped');
ok(MedService.canCheckIn(MedLogStatus.MISSED), 'missed 可补记');
ok(MedService.canCheckIn(MedLogStatus.SKIPPED), 'skipped 可改判');
ok(MedService.canCheckIn(MedLogStatus.PENDING), 'pending 可打卡');

group('依从率（7 天混合数据手工核对）');
const nowA = ts(2026, 10, 6, 12, 0);
const logsA: MedLog[] = [];
let idSeq = 1;
for (let i = 0; i < 14; i++) {
  const sched: number = ts(2026, 9, 30 + i, 7, 30);
  if (i < 12) {
    logsA.push(mlog(sched, MedLogStatus.TAKEN, sched + 600000, idSeq++));
  } else if (i === 12) {
    logsA.push(mlog(sched, MedLogStatus.SKIPPED, null, idSeq++));
  } else {
    logsA.push(mlog(sched, MedLogStatus.MISSED, null, idSeq++));
  }
}
const adhA = MedService.adherence(logsA, nowA);
eq(adhA.expected, 14, '计划总量 14 次（全部已到期时与已到期义务同值）');
eq(adhA.due, 14, '已到期义务 14 次');
eq(adhA.taken, 12, '已服 12 次');
eq(adhA.skipped, 1, '跳过 1 次');
eq(adhA.missed, 1, '漏服 1 次');
eq(adhA.pendingNotDue, 0, '未到期 0 次');
near(adhA.rate as number, 1200 / 14, '依从率 12/14');

const logsB: MedLog[] = logsA.slice();
logsB.push(mlog(ts(2026, 10, 6, 13, 0), MedLogStatus.PENDING, null, 99));
const adhB = MedService.adherence(logsB, nowA);
// v1.4 口径：未到期的 pending 只进「计划总量」，不进依从率分母（FR-9.5 修订）
eq(adhB.expected, 15, '计划总量 15 次（未到期 pending 计入计划总量）');
eq(adhB.due, 14, '已到期义务 14 次（未到期的 pending 不算义务、不入分母）');
eq(adhB.pendingNotDue, 1, '未到期计数 1');
near(adhB.rate as number, 1200 / 14, '依从率看已到期义务 12/14，不再被未到期 pending 拉低到 12/15');

const adhC = MedService.adherence([mlog(ts(2026, 10, 1, 7, 0), MedLogStatus.PENDING, null, 1)], nowA);
eq(adhC.missed, 1, '已超时的 pending 在统计中计为漏服');
eq(adhC.expected, 1, '计划总量 1 次');
eq(adhC.due, 1, '已到期义务 1 次（超时 pending 已转为漏服）');
eq(adhC.rate, 0, '依从率 0%');
eq(MedService.adherence([], nowA).rate, null, '空数据依从率为 null');
eq(MedService.adherence([], nowA).expected, 0, '空数据计划总量 0');
eq(MedService.adherence([], nowA).due, 0, '空数据已到期义务 0');

// 全部义务都还没到期：due = 0 → rate = null，UI 需显示占位符而不是「依从率 -%」
const adhDue0 = MedService.adherence([mlog(ts(2026, 10, 6, 13, 0), MedLogStatus.PENDING, null, 100)], nowA);
eq(adhDue0.expected, 1, '仅未到期 pending 时计划总量为 1');
eq(adhDue0.due, 0, '仅未到期 pending 时已到期义务为 0');
eq(adhDue0.pendingNotDue, 1, '仅未到期 pending 时未到期计数为 1');
eq(adhDue0.rate, null, '已到期义务为 0 时依从率为 null（UI 显示 —）');

group('计划展开 / 生效判定');
eq(MedService.isPlanActiveOn(plan(1, 1, ['07:30'], '2026-10-01', null), ts(2026, 9, 30, 12, 0)), false, '开始日之前不生效');
eq(MedService.isPlanActiveOn(plan(1, 1, ['07:30'], '2026-10-01', null), ts(2026, 10, 1, 12, 0)), true, '开始日当天生效');
eq(MedService.isPlanActiveOn(plan(1, 1, ['07:30'], '2026-10-01', null), ts(2026, 12, 31, 12, 0)), true, '长期计划无限期生效');
eq(MedService.isPlanActiveOn(plan(1, 1, ['07:30'], '2026-10-01', '2026-10-05'), ts(2026, 10, 5, 12, 0)), true, '结束日当天仍生效');
eq(MedService.isPlanActiveOn(plan(1, 1, ['07:30'], '2026-10-01', '2026-10-05'), ts(2026, 10, 6, 12, 0)), false, '结束日次日不再生效');

const meds: Medication[] = [med(1, '缬沙坦', true), med(2, '阿司匹林', false), med(3, '二甲双胍', true)];
const plans: MedPlan[] = [
  plan(1, 1, ['18:00', '07:30'], '2026-10-01', null, true),
  plan(2, 2, ['12:00'], '2026-10-01', null, true),
  plan(3, 1, ['09:00'], '2026-01-01', '2026-06-30', true),
  plan(4, 3, ['20:00'], '2026-10-01', null, false)
];
const slots = MedService.planSlotsOf(ts(2026, 10, 6, 12, 0), plans, meds);
eq(slots.length, 2, '仅展开有效计划的合法时间点');
eq(slots[0].scheduledTime, ts(2026, 10, 6, 7, 30), '时间点升序：第一个为 07:30');
eq(slots[1].scheduledTime, ts(2026, 10, 6, 18, 0), '时间点升序：第二个为 18:00');
eq(slots[0].medName, '缬沙坦', '药品名快照正确');

const drafts = MedService.pendingDrafts([plan(1, 1, ['07:30', '18:00'], '2026-10-01', null, true)], meds, ts(2026, 10, 6, 12, 0), 7);
eq(drafts.length, 14, '7 天 × 2 次 = 14 条预生成');
eq(drafts[0].scheduledTime, ts(2026, 10, 6, 7, 30), '预生成首条为当天 07:30');
eq(drafts[13].scheduledTime, ts(2026, 10, 12, 18, 0), '预生成末条为第 7 天 18:00');

const draftsEnd = MedService.pendingDrafts([plan(1, 1, ['08:00'], '2026-10-01', '2026-10-03', true)], meds, ts(2026, 10, 1, 12, 0), 7);
eq(draftsEnd.length, 3, '结束日期截断预生成（10-01~10-03）');

// v1.15 / 裁决 D3：进入前台时把 end_date 已过的计划自动停用（每日代理闹钟没有结束日期参数）
group('过期计划自动停用（FR-8.3）');
const expToday: string = '2026-10-07';
const expPlans: MedPlan[] = [
  plan(11, 1, ['07:30'], '2026-09-01', '2026-10-06', true),
  plan(12, 2, ['07:30'], '2026-09-01', '2026-10-07', true),
  plan(13, 3, ['07:30'], '2026-09-01', null, true),
  plan(14, 4, ['07:30'], '2026-09-01', '2026-10-01', false)
];
const expIds = MedService.expiredPlanIds(expPlans, expToday);
eq(expIds.length, 1, '只有「昨天已过期且仍生效」的计划被判定为过期');
eq(expIds[0], 11, '命中 10-06 到期那条');
eq(MedService.expiredPlanIds([plan(15, 1, ['07:30'], '2026-09-01', '2026-10-08', true)], expToday).length, 0,
  '明天才到期的计划不判定');
eq(MedService.expiredPlanIds(expPlans, '2026-10-08').length, 2,
  '再过一天：10-06 与 10-07 两条都命中，已停用那条（10-01）不重复计数');
eq(MedService.expiredPlanIds(expPlans, 'not-a-date').length, 0, 'today 非法时一律不判定（宁可不停用，也不误停用）');
eq(MedService.expiredPlanIds([], expToday).length, 0, '空计划列表返回空');
// 展示用：自动停用后 isActive 已是 false，仍要能认出「它是到期停用的」，否则用户只看到「未设置服药计划」
eq(MedService.expiredEndDate(expPlans, 4, expToday), '2026-10-01', '已停用的过期计划仍能被 expiredEndDate 认出');
eq(MedService.expiredEndDate(expPlans, 1, expToday), '2026-10-06', '生效中但已到期的计划同样可认出');
eq(MedService.expiredEndDate(expPlans, 3, expToday), null, '长期计划（endDate=null）不会被认作到期');
eq(MedService.expiredEndDate(expPlans, 99, expToday), null, '其它药品返回 null');

group('提醒合并（FR-8.4）');
const merged = MedService.groupBySlot([
  { medicationId: 1, medName: '缬沙坦', dosage: '1片', scheduledTime: ts(2026, 10, 6, 7, 30), planId: 1 },
  { medicationId: 3, medName: '二甲双胍', dosage: '1片', scheduledTime: ts(2026, 10, 6, 7, 30), planId: 4 },
  { medicationId: 1, medName: '缬沙坦', dosage: '1片', scheduledTime: ts(2026, 10, 6, 18, 0), planId: 1 }
]);
eq(merged.length, 2, '同一时间点合并为 1 组');
eq(merged[0].items.length, 2, '07:30 含 2 个药品');
eq(merged[1].items.length, 1, '18:00 含 1 个药品');

group('今日服药卡片');
const s1800 = ts(2026, 10, 6, 18, 0);
const todayLogs: MedLog[] = [
  mlog(s1800, MedLogStatus.PENDING, null, 1, 1, '缬沙坦'),
  mlog(s1800, MedLogStatus.TAKEN, s1800, 2, 3, '二甲双胍'),
  mlog(ts(2026, 10, 6, 7, 30), MedLogStatus.TAKEN, ts(2026, 10, 6, 7, 32), 3, 1, '缬沙坦')
];
const lines = MedService.todayLines(todayLogs, ts(2026, 10, 6, 18, 30));
eq(lines.length, 3, '3 行');
eq(lines[0].slotSeq, 1, '第 1 个时间点');
eq(lines[0].medCountInSlot, 1, '07:30 仅 1 个药品');
eq(lines[1].slotSeq, 2, '第 2 个时间点');
eq(lines[1].medSeq, 1, '18:00 第 1 个药品');
eq(lines[2].medSeq, 2, '18:00 第 2 个药品');
eq(lines[2].medCountInSlot, 2, '18:00 共 2 个药品');
eq(lines[1].status, MedLogStatus.PENDING, '18:00 缬沙坦待服');
eq(lines[2].status, MedLogStatus.TAKEN, '18:00 二甲双胍已服');

// ═══════════════════ 6. 表单校验（CL-2 / CL-8） ═══════════════════
group('血压录入校验 BpValidator');
ok(BpValidator.validateCore('120', '80', '72').ok, '合法输入通过');
ok(BpValidator.validateCore('40', '30', '').ok, '下限边界通过（40/30，心率留空）');
ok(BpValidator.validateCore('300', '200', '220').ok, '上限边界通过（300/200/220）');
ok(!BpValidator.validateCore('39', '30', '').ok, '收缩压 39 越界拒绝');
ok(!BpValidator.validateCore('301', '30', '').ok, '收缩压 301 越界拒绝');
ok(!BpValidator.validateCore('120', '29', '').ok, '舒张压 29 越界拒绝');
ok(!BpValidator.validateCore('120', '201', '').ok, '舒张压 201 越界拒绝');
ok(!BpValidator.validateCore('120', '80', '29').ok, '心率 29 越界拒绝');
ok(!BpValidator.validateCore('120', '80', '221').ok, '心率 221 越界拒绝');
ok(BpValidator.validateCore('120', '80', '30').ok, '心率 30 下限通过');
ok(!BpValidator.validateCore('120', '120', '').ok, '收缩压 = 舒张压拒绝');
ok(!BpValidator.validateCore('100', '120', '').ok, '收缩压 < 舒张压拒绝');
ok(BpValidator.validateCore('121', '120', '').ok, '收缩压略大于舒张压通过');
ok(!BpValidator.validateCore('', '80', '').ok, '收缩压必填');
ok(!BpValidator.validateCore('120', '', '').ok, '舒张压必填');
ok(!BpValidator.validateCore('abc', '80', '').ok, '非数字拒绝');
ok(!BpValidator.validateCore('12.5', '80', '').ok, '小数拒绝');
ok(!BpValidator.validateCore('-120', '80', '').ok, '负数拒绝');
ok(!BpValidator.validateCore(' 1 2 0 ', '80', '').ok, '含空格数字拒绝');
ok(BpValidator.validateCore(' 120 ', ' 80 ', ' 72 ').ok, '首尾空格被裁剪后通过');
ok(BpValidator.validateCore('120', '80', '').fieldErrors.get('heartRate') === undefined, '心率留空不报错');

const nowV = ts(2026, 10, 6, 12, 0);
ok(BpValidator.validateForm({ systolicText: '120', diastolicText: '80', heartRateText: '', measureTime: nowV, note: '' }, nowV).ok, '完整表单通过');
ok(!BpValidator.validateForm({ systolicText: '120', diastolicText: '80', heartRateText: '', measureTime: 0, note: '' }, nowV).ok, '时间戳为 0 拒绝');
ok(!BpValidator.validateForm({ systolicText: '120', diastolicText: '80', heartRateText: '', measureTime: nowV + 120000, note: '' }, nowV).ok, '未来时间拒绝');
ok(BpValidator.validateForm({ systolicText: '120', diastolicText: '80', heartRateText: '', measureTime: nowV - 5 * 365 * 86400000, note: '' }, nowV).ok, '过去任意时刻允许（CL-2）');
ok(BpValidator.validateForm({ systolicText: '120', diastolicText: '80', heartRateText: '', measureTime: nowV, note: 'a'.repeat(100) }, nowV).ok, '备注 100 字通过');
ok(!BpValidator.validateForm({ systolicText: '120', diastolicText: '80', heartRateText: '', measureTime: nowV, note: 'a'.repeat(101) }, nowV).ok, '备注 101 字拒绝');

group('药品与计划校验 MedService');
ok(MedService.validateMedicationForm('缬沙坦', '1片/80mg', '').ok, '合法药品档案通过');
ok(!MedService.validateMedicationForm('', '1片', '').ok, '药品名必填');
ok(!MedService.validateMedicationForm('a'.repeat(31), '1片', '').ok, '药品名超 30 字拒绝');
ok(!MedService.validateMedicationForm('缬沙坦', '', '').ok, '剂量必填');
ok(!MedService.validateMedicationForm('缬沙坦', '1片', 'a'.repeat(101)).ok, '药品备注超 100 字拒绝');

ok(MedService.validatePlanForm(['07:30'], '2026-10-06', null).ok, '每日 1 次合法');
ok(MedService.validatePlanForm(['07:30', '12:00', '18:00', '22:00'], '2026-10-06', null).ok, '每日 4 次合法');
ok(!MedService.validatePlanForm([], '2026-10-06', null).ok, '每日 0 次拒绝');
ok(!MedService.validatePlanForm(['07:30', '12:00', '18:00', '22:00', '23:30'], '2026-10-06', null).ok, '每日 5 次拒绝');
ok(!MedService.validatePlanForm(['07:30', '07:30'], '2026-10-06', null).ok, '重复时间点拒绝');
ok(!MedService.validatePlanForm(['7:30'], '2026-10-06', null).ok, '非法时间格式拒绝');
ok(!MedService.validatePlanForm(['24:00'], '2026-10-06', null).ok, '24:00 拒绝');
ok(!MedService.validatePlanForm(['07:30'], '2026-13-01', null).ok, '非法开始日期拒绝');
ok(!MedService.validatePlanForm(['07:30'], '2026-10-06', '2026-10-05').ok, '结束日期早于开始日期拒绝');
ok(MedService.validatePlanForm(['07:30'], '2026-10-06', '2026-10-06').ok, '结束日期等于开始日期通过');
ok(!MedService.validatePlanForm(['07:30'], '2026-10-06', '2026-02-30').ok, '非法结束日期拒绝');

const norm = MedService.normalizeSlots([' 18:00 ', '07:30', '18:00', 'abc', '25:00', '07:30']);
eq(norm.length, 2, '规范化后去重去非法');
eq(norm[0], '07:30', '规范化后升序第一项');
eq(norm[1], '18:00', '规范化后升序第二项');
eq(MedService.normalizeSlots([]).length, 0, '空数组规范化');

// ═══════════════════ 7. CSV 编解码（CL-10） ═══════════════════
group('CSV 解析 Csv');
eq(Csv.parse('a,b\r\nc,d\r\n').length, 2, 'CRLF 两行');
eq(Csv.parse('a,b\nc,d').length, 2, 'LF 两行');
eq(Csv.parse('a,b\rc,d').length, 2, 'CR 两行');
eq(Csv.parse('\uFEFFa,b').length, 1, '剥离 BOM');
eq(Csv.parse('\uFEFFa,b')[0][0], 'a', '剥离 BOM 后首字段正确');
eq(Csv.parse('"a""b",c')[0][0], 'a"b', '双引号转义');
eq(Csv.parse('"a\nb",c').length, 1, '字段内换行不拆行');
eq(Csv.parse('"a\nb",c')[0][0], 'a\nb', '字段内换行保留');
eq(Csv.parse('"a,b",c')[0].length, 2, '引号内逗号不拆列');
eq(Csv.parse('a,,c')[0][1], '', '空字段');
eq(Csv.parse('').length, 0, '空串解析为空');
eq(Csv.parse('a,b').length, 1, '无尾换行也能解析');
eq(Csv.cell(['a'], 5), '', '越界取单元格返回空串');
eq(Csv.cell([' a '], 0), 'a', '单元格自动裁剪空白');

const tricky = [['日期', '时间', '备注'], ['2026-10-06', '08:12', '含,逗号与"引号"及\n换行']];
const csvText = Csv.stringify(tricky, true);
ok(csvText.charCodeAt(0) === 0xFEFF, '导出带 UTF-8 BOM');
const back = Csv.parse(csvText);
eq(back.length, 2, '回读行数一致');
eq(back[1][2], '含,逗号与"引号"及\n换行', '特殊字符原样回读');
eq(Csv.normalize(Csv.parse('a,b\n\n \n c,d\n')).length, 2, 'normalize 去除空白行');

// ═══════════════════ 8. 导出 → 导入 往返一致性（CL-10） ═══════════════════
// 说明：本节的 CSV 文案词表由用例直接构造（真实运行时由 VocabFactory 从资源解析），
// 词表内容与 resources 中 zh_CN 的字面量一致，因此往返结论对真实环境同样成立。
const VOCAB: CsvVocab = {
  bpHeaders: ['日期', '时间', '收缩压(mmHg)', '舒张压(mmHg)', '心率(bpm)', '时段', '备注'],
  medHeaders: ['日期', '计划时间', '药品', '剂量', '状态', '实际打卡时间', '备注'],
  planHeaders: ['药品', '剂量', '每日次数', '时间点', '开始日期', '结束日期', '备注'],
  slotSeparator: ';',
  periodMorning: '晨起',
  periodForenoon: '上午',
  periodAfternoon: '下午',
  periodNight: '睡前',
  periodOther: '其他',
  statusTaken: '已服用',
  statusTakenMakeup: '已服用(补记)',
  statusSkipped: '跳过',
  statusMissed: '漏服',
  statusPending: '待服'
};

group('血压导出 → 导入 往返');
const bpExport: BpRecord[] = [
  rec(ts(2026, 10, 1, 6, 30), 132, 86, 74, 1),
  rec(ts(2026, 10, 2, 12, 10), 128, 82, null, 2),
  rec(ts(2026, 10, 3, 15, 20), 145, 92, 88, 3),
  rec(ts(2026, 10, 4, 21, 40), 138, 88, 76, 4),
  rec(ts(2026, 10, 5, 7, 5), 121, 79, 70, 5)
];
bpExport[2].note = '含,逗号与"引号"及\n换行';
bpExport[3].note = '服药后';
const bpCsv: string = ExportService.buildBpCsv(bpExport, VOCAB);
const bpRows: string[][] = Csv.parse(bpCsv);
eq(bpRows.length, bpExport.length + 1, '导出含表头，共 N+1 行');

const bpImport1 = ImportService.parseBpTable(bpRows, VOCAB, new Set<string>());
eq(bpImport1.totalRows, bpExport.length, '数据行数正确');
eq(bpImport1.errors.length, 0, '导出文件原样回导：0 错误');
eq(bpImport1.duplicateCount, 0, '首次导入无重复');
eq(bpImport1.drafts.length, bpExport.length, '全部有效');
eq(bpImport1.previewLines.length, 5, '预览给出前 5 行');
eq(bpImport1.drafts[0].systolic, 132, '数值无损');
eq(bpImport1.drafts[0].heartRate, 74, '心率无损');
eq(bpImport1.drafts[1].heartRate, null, '空心率仍为空');
eq(bpImport1.drafts[0].period, Period.MORNING, '时段文字回读为晨起');
eq(bpImport1.drafts[3].period, Period.NIGHT, '时段文字回读为睡前');
eq(bpImport1.drafts[2].note, '含,逗号与"引号"及\n换行', '特殊字符备注无损');

const bpKeys: Set<string> = new Set<string>();
for (let i = 0; i < bpImport1.drafts.length; i++) {
  const d = bpImport1.drafts[i];
  bpKeys.add(ImportService.bpKey(d.measureTime, d.systolic, d.diastolic));
}
const bpImport2 = ImportService.parseBpTable(bpRows, VOCAB, bpKeys);
eq(bpImport2.drafts.length, 0, '原样回导：0 条新增');
eq(bpImport2.duplicateCount, bpExport.length, '原样回导：重复数 = 总条数（幂等，CL-10）');
eq(bpImport2.errors.length, 0, '原样回导：0 错误');

group('血压判重三元组');
const sameTime = '2026-10-06,08:12,128,82,72,晨起,\r\n2026-10-06,08:12,128,82,72,晨起,\r\n2026-10-06,08:12,135,88,72,晨起,\r\n';
const dedupPreview = ImportService.parseBpTable(Csv.parse(sameTime), VOCAB, new Set<string>());
eq(dedupPreview.totalRows, 3, '共 3 行');
eq(dedupPreview.duplicateCount, 1, '同时间同数值判为重复');
eq(dedupPreview.drafts.length, 2, '同时间不同数值入库');

group('脏 CSV 逐行隔离（CL-10：不中断整批）');
const dirty = '日期,时间,收缩压(mmHg),舒张压(mmHg),心率(bpm),时段,备注\r\n'
  + '2026-10-01,08:00,128,82,72,晨起,正常行\r\n'
  + '2026-10-02,08:00,350,82,72,晨起,越界\r\n'
  + '2026-13-01,08:00,128,82,72,晨起,月份非法\r\n'
  + 'abc,def,128,82,72,晨起,时间非法\r\n'
  + '2026-10-03\r\n'
  + '2026-10-04,09:00,100,105,72,晨起,收缩压小于舒张压\r\n'
  + '2026-10-05,10:00,130,85,999,晨起,心率越界\r\n'
  + '2026-10-06,11:00,124,80,68,不明时段,时段文字无法识别\r\n'
  + '2026-10-06,20:30,126,81,70,晨起,文件时段覆盖自动推断\r\n';
const dirtyPreview = ImportService.parseBpTable(Csv.parse(dirty), VOCAB, new Set<string>());
eq(dirtyPreview.totalRows, 9, '统计 9 行数据');
eq(dirtyPreview.errors.length, 6, '6 行格式/范围错误被隔离');
eq(dirtyPreview.drafts.length, 3, '3 行有效');
eq(dirtyPreview.errors[0].lineNo, 3, '错误行号指向物理行（含表头计数）');
eq(dirtyPreview.drafts[1].period, Period.FORENOON, '无法识别的时段回退为按时间自动推断');
eq(dirtyPreview.drafts[2].period, Period.MORNING, '文件中的时段文字优先于自动推断');
ok(dirtyPreview.errors.every((e) => e.lineNo > 1), '所有错误均带行号');

group('用药打卡导出 → 导入 往返');
const medLogs: MedLog[] = [
  mlog(ts(2026, 10, 1, 7, 30), MedLogStatus.TAKEN, ts(2026, 10, 1, 7, 35), 1, 1, '缬沙坦'),
  mlog(ts(2026, 10, 1, 12, 0), MedLogStatus.TAKEN, ts(2026, 10, 1, 21, 10), 2, 2, '二甲双胍'),
  mlog(ts(2026, 10, 1, 18, 0), MedLogStatus.SKIPPED, null, 3, 1, '缬沙坦'),
  mlog(ts(2026, 10, 2, 7, 30), MedLogStatus.MISSED, null, 4, 1, '缬沙坦'),
  mlog(ts(2026, 10, 2, 12, 0), MedLogStatus.PENDING, null, 5, 2, '二甲双胍'),
  mlog(ts(2026, 10, 5, 23, 50), MedLogStatus.TAKEN, ts(2026, 10, 6, 0, 10), 6, 1, '缬沙坦')
];
medLogs[1].note = '聚餐后补服';
eq(ExportService.medStatusText(medLogs[0], VOCAB), '已服用', '准时服用导出为「已服用」');
eq(ExportService.medStatusText(medLogs[1], VOCAB), '已服用(补记)', '超时 2h 导出为「已服用(补记)」');
eq(ExportService.medStatusText(medLogs[2], VOCAB), '跳过', '跳过状态导出');
eq(ExportService.medStatusText(medLogs[3], VOCAB), '漏服', '漏服状态导出');
eq(ExportService.medStatusText(medLogs[4], VOCAB), '待服', '未到期 pending 导出为「待服」');

const medCsv: string = ExportService.buildMedCsv(medLogs, VOCAB);
const medRows: string[][] = Csv.parse(medCsv);
const medImport1 = ImportService.parseMedTable(medRows, VOCAB, new Set<string>(), new Map<string, number>());
eq(medImport1.totalRows, medLogs.length, '打卡数据行数一致');
eq(medImport1.errors.length, 0, '打卡导出原样回导：0 错误');
eq(medImport1.duplicateCount, 0, '打卡首次导入无重复');
eq(medImport1.drafts.length, medLogs.length, '打卡全部有效');
eq(medImport1.drafts[0].status, MedLogStatus.TAKEN, '已服用状态回读');
eq(medImport1.drafts[1].status, MedLogStatus.TAKEN, '已服用(补记) 回读为已服用');
eq(medImport1.drafts[1].note, '聚餐后补服', '打卡备注无损');
eq(medImport1.drafts[2].status, MedLogStatus.SKIPPED, '跳过状态回读');
eq(medImport1.drafts[3].status, MedLogStatus.MISSED, '漏服状态回读');
eq(medImport1.drafts[4].status, MedLogStatus.PENDING, '待服状态回读');
eq(medImport1.drafts[5].takenTime, ts(2026, 10, 6, 0, 10), '跨零点打卡时间还原为次日');
eq(medImport1.drafts[0].takenTime, ts(2026, 10, 1, 7, 35), '同日打卡时间保持原值');

const medTuples = medLogs.map((l) => ({ medicationId: l.medicationId, medName: l.medName, scheduledTime: l.scheduledTime }));
const medKeys: Set<string> = ImportService.buildMedKeySet(medTuples);
const nameToId: Map<string, number> = new Map<string, number>();
nameToId.set('缬沙坦', 1);
const medImport2 = ImportService.parseMedTable(medRows, VOCAB, medKeys, nameToId);
eq(medImport2.drafts.length, 0, '打卡原样回导：0 条新增');
eq(medImport2.duplicateCount, medLogs.length, '打卡原样回导：重复数 = 总条数（幂等）');
eq(medImport2.errors.length, 0, '打卡原样回导：0 错误');

group('打卡导入异常分支');
const medDirty = '日期,计划时间,药品,剂量,状态,实际打卡时间,备注\r\n'
  + '2026-10-01,07:30,缬沙坦,1片,已服用,07:35,\r\n'
  + '2026-10-01,25:00,缬沙坦,1片,已服用,,\r\n'
  + '2026-10-01,12:00,,1片,已服用,,\r\n'
  + '2026-10-01,18:00,缬沙坦,1片,吃了,,\r\n'
  + '2026-10-01,19:00,缬沙坦,1片,已服用,xx:yy,\r\n'
  + '2026-10-02,07:30,未知药,1片,已服用,,\r\n';
const medDirtyPreview = ImportService.parseMedTable(Csv.parse(medDirty), VOCAB, new Set<string>(), new Map<string, number>());
eq(medDirtyPreview.totalRows, 6, '打卡脏文件 6 行');
eq(medDirtyPreview.errors.length, 4, '4 行错误被隔离');
eq(medDirtyPreview.drafts.length, 2, '2 行有效（含药品名无匹配的一行）');
eq(medDirtyPreview.drafts[1].medName, '未知药', '药品名无匹配的行仍可入库（后续自动建停用档案）');
eq(ImportService.mapStatusText('已服用(补记)', VOCAB), MedLogStatus.TAKEN, '状态文字映射：补记 → taken');
eq(ImportService.mapStatusText('飞了', VOCAB), null, '未知状态文字返回 null');
eq(ImportService.medKeyById(1, 100), 'i:1_100', '判重键（按 id）');
eq(ImportService.medKeyByName('缬沙坦', 100), 'n:缬沙坦_100', '判重键（按名称）');
eq(ImportService.bpKey(100, 128, 82), '100_128_82', '血压判重键三元组');

group('导出范围筛选');
const exportNow = ts(2026, 10, 6, 12, 0);
const rangeSource: BpRecord[] = [
  rec(ts(2026, 10, 6, 8, 0), 120, 80, null, 1),
  rec(ts(2026, 9, 10, 8, 0), 120, 80, null, 2),
  rec(ts(2026, 7, 1, 8, 0), 120, 80, null, 3)
];
eq(ExportService.filterBpByRange(rangeSource, 'all', exportNow).length, 3, '全部范围');
eq(ExportService.filterBpByRange(rangeSource, 'd30', exportNow).length, 2, '近 30 天范围（09-10 在窗口内，07-01 不在）');
eq(ExportService.filterBpByRange(rangeSource, 'd90', exportNow).length, 2, '近 90 天范围（07-01 在窗口外）');
eq(ExportService.filterBpByRange(rangeSource, 'd30', exportNow)[0].id, 1, '范围筛选保持原数组顺序');

// ═══════════════════ 9. 周期报告（CL-9） ═══════════════════
group('报告周期计算');
const anchorTue = ts(2026, 10, 6, 12, 0);
const wk = ReportService.weekRange(anchorTue);
eq(DateUtils.formatDate(wk.start), '2026-10-05', '周报起点为周一 10-05');
eq(DateUtils.formatDate(wk.end), '2026-10-11', '周报终点为周日 10-11');
eq(DateUtils.daysInclusive(wk.start, wk.end), 7, '周报跨 7 天');
const mo = ReportService.monthRange(anchorTue);
eq(DateUtils.formatDate(mo.start), '2026-10-01', '月报起点为月初');
eq(DateUtils.formatDate(mo.end), '2026-10-31', '月报终点为月末');

const prevWk = ReportService.prevRange(wk, 'week');
eq(DateUtils.formatDate(prevWk.start), '2026-09-28', '上一周起点');
eq(DateUtils.formatDate(prevWk.end), '2026-10-04', '上一周终点');
const prevMo = ReportService.prevRange(mo, 'month');
eq(DateUtils.formatDate(prevMo.start), '2026-09-01', '上一个月起点');
eq(DateUtils.formatDate(prevMo.end), '2026-09-30', '上一个月终点');
// 2027-01-01 为周五 → 所属周为 2026-12-28 ~ 2027-01-03，上一周应回退到 12-21 ~ 12-27
const crossYearRange = ReportService.weekRange(ts(2027, 1, 1, 12, 0));
eq(DateUtils.formatDate(crossYearRange.start), '2026-12-28', '跨年所在周起点');
eq(DateUtils.formatDate(crossYearRange.end), '2027-01-03', '跨年所在周终点');
const crossYear = ReportService.prevRange(crossYearRange, 'week');
eq(DateUtils.formatDate(crossYear.start), '2026-12-21', '跨年上一周起点');
eq(DateUtils.formatDate(crossYear.end), '2026-12-27', '跨年上一周终点');
const janCustom = ReportService.prevRange(ReportService.customRange(ts(2026, 1, 1, 0, 0), ts(2026, 1, 3, 0, 0)), 'custom');
eq(DateUtils.formatDate(janCustom.start), '2025-12-29', '自定义周期跨年回退');
eq(DateUtils.formatDate(janCustom.end), '2025-12-31', '自定义周期上一期终点');

eq(ReportService.recentWeeks(anchorTue, 4).length, 4, '最近 4 周');
eq(DateUtils.formatDate(ReportService.recentWeeks(anchorTue, 4)[0].start), '2026-09-14', '最近 4 周最早一期起点');
eq(DateUtils.formatDate(ReportService.recentWeeks(anchorTue, 4)[3].start), '2026-10-05', '最近 4 周最晚一期为本周');
eq(ReportService.recentMonths(anchorTue, 3).length, 3, '最近 3 个月');
eq(DateUtils.formatDate(ReportService.recentMonths(anchorTue, 3)[0].start), '2026-08-01', '最近 3 个月最早一期起点');
ok(ReportService.isCustomRangeValid(ts(2026, 1, 1, 0, 0), ts(2026, 4, 2, 0, 0)), '自定义 92 天合法');
ok(!ReportService.isCustomRangeValid(ts(2026, 1, 1, 0, 0), ts(2026, 4, 3, 0, 0)), '自定义 93 天非法');
ok(!ReportService.isCustomRangeValid(ts(2026, 4, 3, 0, 0), ts(2026, 1, 1, 0, 0)), '起点晚于终点非法');

group('报告数据组装');
const RPT_VOCAB = {
  titleWeek: '血压周报', titleMonth: '血压月报', titleCustom: '血压报告',
  watermarkSuffix: '由「血压助手」生成，仅供参考', separator: ' · '
};
const rptRecords: BpRecord[] = [
  rec(ts(2026, 10, 5, 6, 40), 145, 95, 80, 1),
  rec(ts(2026, 10, 6, 7, 10), 132, 86, 76, 2),
  rec(ts(2026, 10, 7, 12, 0), 128, 82, null, 3),
  rec(ts(2026, 9, 30, 8, 0), 150, 96, 78, 4)
];
const rptLogs: MedLog[] = [
  mlog(ts(2026, 10, 5, 7, 30), MedLogStatus.TAKEN, ts(2026, 10, 5, 7, 35), 1, 1, '缬沙坦'),
  mlog(ts(2026, 10, 6, 7, 30), MedLogStatus.TAKEN, ts(2026, 10, 6, 7, 35), 2, 1, '缬沙坦'),
  mlog(ts(2026, 10, 7, 7, 30), MedLogStatus.MISSED, null, 3, 1, '缬沙坦')
];
const rptPlans: MedPlan[] = [plan(1, 1, ['07:30'], '2026-10-01', null, true)];

const rpt = ReportService.build('week', wk, rptRecords, rptLogs, rptPlans, RPT_VOCAB, anchorTue);
ok(rpt !== null, '周期内有数据时生成报告');
const r1 = rpt as unknown as {
  title: string; hasPrev: boolean; prevLabel: string; deltaSys: number; deltaDia: number;
  stats: { count: number; sysMean: number }; dailyPoints: unknown[]; abnormals: unknown[];
  adherence: { expected: number; due: number; taken: number; missed: number }; hasMedPlan: boolean; watermark: string;
};
eq(r1.title, '血压周报', '周报标题来自词表');
eq(r1.stats.count, 3, '仅统计周期内记录（09-30 不计入）');
near(r1.stats.sysMean, 135, '报告均值与统计页同口径 (145+132+128)/3');
eq(r1.hasPrev, true, '存在上一周期数据');
eq(r1.prevLabel, '2026.09.28 – 10.04', '上一周期标签');
near(r1.deltaSys, 135 - 150, '环比差值（本期 − 上期）');
eq(r1.dailyPoints.length, 3, '周期内 3 天有数据');
eq(r1.abnormals.length, 1, '异常清单仅含 ≥140/90 的记录');
eq(r1.adherence.expected, 3, '计划总量 3 次');
eq(r1.adherence.due, 3, '已到期义务 3 次（报告用药小结取 due）');
eq(r1.adherence.taken, 2, '依从率已服 2 次');
eq(r1.adherence.missed, 1, '依从率漏服 1 次');
eq(r1.hasMedPlan, true, '存在生效计划');
ok(r1.watermark.indexOf('2026.10.05') === 0, '水印以周期范围开头');
ok(r1.watermark.indexOf('由「血压助手」生成，仅供参考') > 0, '水印含免责尾句');

const rptNoPrev = ReportService.build('week', ReportService.weekRange(ts(2026, 5, 6, 12, 0)),
  [rec(ts(2026, 5, 6, 8, 0), 130, 85, 70, 1)], [], [], RPT_VOCAB, ts(2026, 5, 6, 12, 0));
ok(rptNoPrev !== null, '有数据即可生成');
eq(rptNoPrev === null ? true : rptNoPrev.hasPrev, false, '无上一周期数据时 hasPrev=false');
eq(rptNoPrev === null ? 0 : rptNoPrev.hasMedPlan, false, '无生效计划时 hasMedPlan=false');

const rptEmpty = ReportService.build('week', wk, [rec(ts(2026, 1, 1, 8, 0), 130, 85, 70, 1)],
  [], [], RPT_VOCAB, anchorTue);
eq(rptEmpty, null, '周期内无数据时返回 null（FR-10.4 不生成报告）');

group('服药完成日均值标记（FR-9.6）');
const completeDays = ReportService.medCompleteDays(rptLogs, ts(2026, 10, 8, 12, 0));
eq(completeDays.length, 2, '10-05 与 10-06 全部完成打卡');
eq(completeDays[0], DateUtils.startOfDay(ts(2026, 10, 5, 0, 0)), '完成日 1');
eq(completeDays[1], DateUtils.startOfDay(ts(2026, 10, 6, 0, 0)), '完成日 2');
eq(ReportService.medCompleteDays([], ts(2026, 10, 8, 12, 0)).length, 0, '无打卡记录时无完成日');

// rptRecords 含 09-30 一条，故每日均值序列为 [09-30, 10-05, 10-06, 10-07]
const dmMed = StatsService.dailyMeans(rptRecords, completeDays);
eq(dmMed.length, 4, '每日均值序列 4 天');
eq(dmMed[0].medComplete, false, '09-30 无打卡记录 → 无标记');
eq(dmMed[1].medComplete, true, '10-05 每日均值带服药标记');
eq(dmMed[2].medComplete, true, '10-06 每日均值带服药标记');
eq(dmMed[3].medComplete, false, '10-07 有漏服 → 无标记');

// ═══════════════════ 10. 用药计划导出 → 导入 往返（v1.3 审查意见 P1-9） ═══════════════════
group('用药计划导出 → 导入 往返');
const planRows: PlanExportRow[] = [
  {
    medName: '缬沙坦', dosage: '1片/80mg', timeSlots: ['07:30', '18:00'],
    startDate: '2026-10-01', endDate: null, note: '早餐后'
  },
  {
    medName: '二甲双胍', dosage: '1片/0.5g', timeSlots: ['12:00'],
    startDate: '2026-10-01', endDate: '2026-12-31', note: null
  }
];
const planCsv: string = ExportService.buildPlanCsv(planRows, VOCAB);
ok(planCsv.charCodeAt(0) === 0xFEFF, '计划 CSV 带 BOM');

const planParsed = ImportService.parsePlanTable(Csv.parse(planCsv), VOCAB, new Set<string>());
eq(planParsed.totalRows, 2, '计划文件 2 行');
eq(planParsed.errors.length, 0, '计划导出原样回导：0 错误');
eq(planParsed.drafts.length, 2, '计划全部有效');
const vPlan = planParsed.drafts.find((p: PlanExportRow) => p.medName === '缬沙坦');
const mPlan = planParsed.drafts.find((p: PlanExportRow) => p.medName === '二甲双胍');
ok(vPlan !== undefined, '回读到缬沙坦计划');
ok(mPlan !== undefined, '回读到二甲双胍计划');
if (vPlan !== undefined) {
  eq(vPlan.timeSlots.length, 2, '时间点数量无损');
  eq(vPlan.timeSlots[0], '07:30', '时间点内容无损（升序）');
  eq(vPlan.dosage, '1片/80mg', '剂量无损');
  eq(vPlan.endDate, null, '长期计划回读为 null');
  eq(vPlan.note, '早餐后', '备注无损');
}
if (mPlan !== undefined) {
  eq(mPlan.endDate, '2026-12-31', '结束日期无损');
}

// 幂等：库内时间点顺序不同也应判为同一计划（判重键先规范化时间点）
const existingPlanKeys: Set<string> = ImportService.buildPlanKeySet(
  [
    { id: 1, name: '缬沙坦', dosage: '1片/80mg', note: null, isActive: true, createdAt: 0, updatedAt: 0 },
    { id: 2, name: '二甲双胍', dosage: '1片/0.5g', note: null, isActive: true, createdAt: 0, updatedAt: 0 }
  ],
  [
    {
      id: 1, medicationId: 1, timeSlots: ['18:00', '07:30'], startDate: '2026-10-01',
      endDate: null, isActive: true, createdAt: 0, updatedAt: 0
    },
    {
      id: 2, medicationId: 2, timeSlots: ['12:00'], startDate: '2026-10-01',
      endDate: '2026-12-31', isActive: true, createdAt: 0, updatedAt: 0
    }
  ]
);
const planAgain = ImportService.parsePlanTable(Csv.parse(planCsv), VOCAB, existingPlanKeys);
eq(planAgain.drafts.length, 0, '计划原样回导：0 条新增');
eq(planAgain.duplicateCount, 2, '计划原样回导：重复数 = 总条数（幂等）');
eq(planAgain.errors.length, 0, '计划原样回导：0 错误');
eq(ImportService.planKey('缬沙坦', ['18:00', '07:30']), '缬沙坦||07:30;18:00', '计划判重键先规范化时间点');

group('用药计划脏数据逐行隔离');
const planDirty = '药品,剂量,每日次数,时间点,开始日期,结束日期,备注\r\n'
  + '缬沙坦,1片,2,07:30;18:00,2026-10-01,,正常行\r\n'
  + '缬沙坦,1片,3,07:30;18:00,2026-10-01,,次数与时间点不一致\r\n'
  + '缬沙坦,1片,2,07:30;25:00,2026-10-01,,时间非法\r\n'
  + '缬沙坦,1片,2,07:30;07:30,2026-10-01,,重复时间点\r\n'
  + ',1片,1,12:00,2026-10-01,,药品名为空\r\n'
  + '缬沙坦,1片,1,12:00,2026-02-30,,开始日期非法\r\n'
  + '缬沙坦,1片,1,12:00,2026-10-01,2026-09-01,结束早于开始\r\n'
  + '缬沙坦,1片,5,07:30;12:00;15:00;18:00;21:00,2026-10-01,,次数超限\r\n';
const planDirtyPreview = ImportService.parsePlanTable(Csv.parse(planDirty), VOCAB, new Set<string>());
eq(planDirtyPreview.totalRows, 8, '计划脏文件 8 行');
eq(planDirtyPreview.errors.length, 7, '7 行被隔离');
eq(planDirtyPreview.drafts.length, 1, '1 行有效');

// ═══════════════════ 12. 外部来源导入（v1.4） ═══════════════════
// 说明：本节的 CSV 文案词表与别名表由用例直接构造（真实运行时由 VocabFactory 从资源解析），
// 内容与 resources/base/element/string.json 一致；别名表与 ColRole 的对应关系
// 另由 tools/check-resources.mjs 逐条核对，防止两边漂移。

group('宽容解析 LooseParse：字符归一');
eq(LooseParse.toHalfWidth('１２８'), '128', '全角数字转半角');
eq(LooseParse.toHalfWidth('（16.9）'), '(16.9)', '全角括号转半角');
eq(LooseParse.normalizeKey('收缩压(mmHg)'), '收缩压', '表头去括号与单位');
eq(LooseParse.normalizeKey('舒张压 （kPa）'), '舒张压', '全角括号加空格同样归一');
eq(LooseParse.normalizeKey('SBP'), 'sbp', '英文别名转小写');
eq(LooseParse.normalizeKey(' 心 率 (bpm) '), '心率', '去空白与单位');
eq(LooseParse.normalizeKey('每日次数'), '每日次数', '不去掉「次」字（否则别名匹配会失效）');

group('宽容解析 LooseParse：日期（多种写法）');
const d1006: number = ts(2026, 10, 6, 0, 0);
eq(LooseParse.parseDateLoose('2026-10-06'), d1006, 'YYYY-MM-DD');
eq(LooseParse.parseDateLoose('2026/10/6'), d1006, '斜杠且月日不补零');
eq(LooseParse.parseDateLoose('2026.10.6'), d1006, '点分隔');
eq(LooseParse.parseDateLoose('2026年10月6日'), d1006, '中文年月日');
eq(LooseParse.parseDateLoose('20261006'), d1006, '紧凑 8 位');
eq(LooseParse.parseDateLoose('10/6/2026'), d1006, '末段 4 位按 月-日-年');
eq(LooseParse.parseDateLoose('13/6/2026'), ts(2026, 6, 13, 0, 0), '首段大于 12 按 日-月-年');
eq(LooseParse.parseDateLoose('2026-02-30'), null, '不存在的日期被拒绝');
eq(LooseParse.parseDateLoose('10/06'), null, '缺年份不猜，判为非法');
eq(LooseParse.parseDateLoose('26/10/06'), null, '2 位年份不猜，判为非法');
eq(LooseParse.parseDateLoose(''), null, '空串非法');
eq(LooseParse.civilFromExcelSerial(45292), ts(2024, 1, 1, 0, 0), 'Excel 序列号锚点（45292 = 2024-01-01）');
eq(LooseParse.parseEpochOrSerial('45292'), ts(2024, 1, 1, 0, 0), '5 位整数按 Excel 序列号');
eq(LooseParse.parseDateLoose(`${Math.floor(ts(2026, 10, 6, 9, 30) / 1000)}`), d1006, '10 位整数按 Unix 秒');

group('宽容解析 LooseParse：时间（多种写法）');
eq(LooseParse.minutesLoose('08:30'), 510, 'HH:mm');
eq(LooseParse.minutesLoose('8:30'), 510, 'H:mm');
eq(LooseParse.minutesLoose('0830'), 510, '紧凑 4 位');
eq(LooseParse.minutesLoose('8时30分'), 510, '中文时分');
eq(LooseParse.minutesLoose('08:30:00'), 510, '带秒不把秒并进分钟');
eq(LooseParse.minutesLoose('下午3:20'), 15 * 60 + 20, '下午 +12 小时');
eq(LooseParse.minutesLoose('上午12:10'), 10, '上午 12 点归 0 点');
eq(LooseParse.minutesLoose('PM 8:30'), 20 * 60 + 30, '英文 PM');
eq(LooseParse.minutesLoose('25:00'), -1, '小时越界非法');
eq(LooseParse.minutesLoose('08:75'), -1, '分钟越界非法');
eq(LooseParse.isTimeToken('0830'), true, '4 位且时分合法 → 时间');
eq(LooseParse.isTimeToken('830'), false, '3 位紧凑形式不自动判为时间（避免与心率混淆）');
eq(LooseParse.isTimeToken('128'), false, '裸数值不判为时间');
eq(LooseParse.hasTimePart('2026-10-06 08:30'), true, '含时间部分');
eq(LooseParse.hasTimePart('2026-10-06'), false, '纯日期');

group('宽容解析 LooseParse：日期时间合并写法');
eq(LooseParse.parseDateTimeLoose('2026-10-06 08:30'), ts(2026, 10, 6, 8, 30), '空格分隔');
eq(LooseParse.parseDateTimeLoose('2026/10/6 8:30:00'), ts(2026, 10, 6, 8, 30), '斜杠 + 秒');
eq(LooseParse.parseDateTimeLoose('2026年10月6日8时30分'), ts(2026, 10, 6, 8, 30), '中文无空格');
eq(LooseParse.parseDateTimeLoose('2026-10-06T08:30:00'), ts(2026, 10, 6, 8, 30), 'ISO T 分隔');
eq(LooseParse.parseDateTimeLoose('2026-10-06 0830'), ts(2026, 10, 6, 8, 30), '紧凑时间尾部');
eq(LooseParse.parseDateTimeLoose('2026-10-06'), ts(2026, 10, 6, 0, 0), '只有日期按 00:00');
eq(LooseParse.parseDateTimeLoose('2026-10-06 25:00'), null, '时间非法则整体非法');

group('宽容解析 LooseParse：数值与血压组合值');
eq(LooseParse.parseIntLoose('128'), 128, '整数');
eq(LooseParse.parseIntLoose('１２８'), 128, '全角整数');
eq(LooseParse.parseIntLoose('128mmHg'), 128, '带单位');
eq(LooseParse.parseIntLoose('72 次/分'), 72, '带中文单位');
eq(LooseParse.parseIntLoose('128.0'), 128, '.0 结尾视为整数');
eq(LooseParse.parseIntLoose('16.9'), null, '有效小数位不按整数解析');
eq(LooseParse.parseIntLoose('abc'), null, '非数字');
eq(LooseParse.parseFloatLoose('16.9'), 16.9, '小数');
const pair1: BpPairValue | null = LooseParse.parseBpPair('128/82');
ok(pair1 !== null && pair1.systolic === 128 && pair1.diastolic === 82, '「128/82」拆分正确');
ok(pair1 !== null && pair1.heartRate === null && pair1.decimal === false, '无括号心率且非小数');
const pair2: BpPairValue | null = LooseParse.parseBpPair('120 / 80 mmHg(72)');
ok(pair2 !== null && pair2.heartRate === 72, '括号内数值识别为心率');
const pair3: BpPairValue | null = LooseParse.parseBpPair('16.9/10.7');
ok(pair3 !== null && pair3.decimal === true, 'kPa 组合值按小数识别');
eq(LooseParse.parseBpPair('2026/10/06'), null, '两个分隔符不当作血压组合值');
eq(LooseParse.parseBpPair('10/6'), null, '量级不合理不当作血压组合值');
near(LooseParse.KPA_TO_MMHG, 7.50062, 'kPa → mmHg 换算系数');
eq(Math.round(16.8 * LooseParse.KPA_TO_MMHG), 126, '16.8 kPa ≈ 126 mmHg');

/** 外部来源导入词表夹具（内容与 resources 中的定义一致，别名已归一化） */
const IMPV: ImportVocab = {
  roleNames: ['', '日期时间', '日期', '时间', '收缩压', '舒张压', '血压', '心率', '时段', '备注',
    '药品', '剂量', '状态', '实际打卡时间', '时间点', '每日次数', '开始日期', '结束日期'],
  roleAliases: [
    [],
    ['日期时间', '时间戳', 'datetime', 'timestamp', 'measuretime', 'recordtime'],
    ['日期', '测量日期', '年月日', 'date', 'day'],
    ['时间', '时刻', '测量时刻', 'time', 'clock'],
    ['收缩压', '高压', '收缩', '上压', '最高压', '最高血压', 'sys', 'sbp'],
    ['舒张压', '低压', '舒张', '下压', '最低压', '最低血压', 'dia', 'dbp'],
    ['血压', '血压值', '血压读数', '测量值', '读数', 'bp', 'bloodpressure'],
    ['心率', '脉率', '脉搏', '心率值', 'hr', 'bpm', 'heartrate', 'pulse'],
    ['时段', '时间段', '测量时段', 'period'],
    ['备注', '说明', '注释', '备注说明', 'note', 'remark', 'comment'],
    ['药品', '药品名', '药品名称', '药物', '药名', 'medication', 'medicine', 'drug'],
    ['剂量', '用量', '每次剂量', '单次剂量', 'dosage', 'dose'],
    ['状态', '打卡状态', '服药状态', 'status'],
    ['实际打卡时间', '打卡时间', '实际时间', '服药时间', 'takentime', 'actualtime', 'taken'],
    ['时间点', '服药时间点', '时点', 'slots', 'times', 'schedule'],
    ['每日次数', '每天次数', '每日频次', '次数', '频次', 'timesperday'],
    ['开始日期', '起始日期', '开始时间', 'startdate', 'start'],
    ['结束日期', '截止日期', '终止日期', 'enddate', 'end']
  ],
  statusTaken: ['已服用', '已服', '已吃', '已用', '吃过', '服用了', '已完成', 'taken', 'done'],
  statusSkipped: ['跳过', '已跳过', '略过', 'skip', 'skipped'],
  statusMissed: ['漏服', '未服用', '未服', '漏吃', 'missed', 'miss'],
  statusPending: ['待服', '未到', '待服用', 'pending', 'due'],
  statusMakeup: ['补记', '补录', '补打卡', '补登']
};

group('列角色枚举与资源顺序对齐');
eq(ROLE_COUNT, ImportAliasRes.ORDER.length, 'ROLE_COUNT == ImportAliasRes.ORDER.length');
eq(ROLE_COUNT, 17, '角色数锁定为 17（新增角色必须同步别名资源与词表）');
eq(IMPV.roleNames.length, ROLE_COUNT + 1, '词表显示名数量 == 角色数 + 1（下标 0 为空占位）');
eq(IMPV.roleAliases.length, ROLE_COUNT + 1, '词表别名组数量 == 角色数 + 1');
eq(ColRole.NONE, 0, 'ColRole.NONE 为 0（词表下标 0 的占位依据）');

group('外部来源：按表头别名 + 内容画像识别列');
const alt: string = '测量日期,测量时间,高压,低压,脉搏,备注\r\n'
  + '2026/10/1,6:30,132,86,74,起床后\r\n'
  + '2026/10/2,12:10,128,82,70,午休前\r\n';
const altRows: string[][] = Csv.parse(alt);
const altDet: Detection = GenericImportService.detect(altRows, IMPV, VOCAB);
eq(altDet.kind, ImportKind.BP, '识别为血压记录');
eq(altDet.hasHeader, true, '识别出表头');
eq(altDet.roleIndex[ColRole.DATE], 0, '「测量日期」→ 日期列');
eq(altDet.roleIndex[ColRole.TIME], 1, '「测量时间」→ 时间列（内容无日期，不误判为日期时间）');
eq(altDet.roleIndex[ColRole.SYSTOLIC], 2, '「高压」→ 收缩压列');
eq(altDet.roleIndex[ColRole.DIASTOLIC], 3, '「低压」→ 舒张压列');
eq(altDet.roleIndex[ColRole.HEART_RATE], 4, '「脉搏」→ 心率列');
eq(altDet.roleIndex[ColRole.NOTE], 5, '「备注」→ 备注列');
eq(altDet.roleIndex[ColRole.PERIOD], -1, '无「时段」列时不强指认');
eq(altDet.unit, ImportUnit.MMHG, '默认单位为 mmHg');
eq(altDet.missing.length, 0, '必需列全部识别');

const altPreview: GenericBpPreview = GenericImportService.parseBp(
  altRows, VOCAB, altDet, new Set<string>());
eq(altPreview.totalRows, 2, '数据行 2 行');
eq(altPreview.drafts.length, 2, '2 条有效');
eq(altPreview.errors.length, 0, '0 条错误');
eq(altPreview.drafts[0].systolic, 132, '收缩压正确');
eq(altPreview.drafts[0].diastolic, 86, '舒张压正确');
eq(altPreview.drafts[0].heartRate, 74, '心率正确');
eq(altPreview.drafts[0].measureTime, ts(2026, 10, 1, 6, 30), '日期时间合并正确');
eq(altPreview.drafts[0].period, Period.MORNING, '无时段列时按测量时间推断（6:30 → 晨起）');
eq(altPreview.drafts[0].note, '起床后', '备注保留');
eq(altPreview.drafts[1].period, Period.FORENOON, '12:10 → 上午');
eq(altPreview.noTimeColumn, false, '有时间列');

group('外部来源：无表头 + 单列血压 + kPa');
const kpaRows: string[][] = Csv.parse('2026-10-01,06:30,16.8/10.5\r\n2026-10-02,12:10,17.2/10.9\r\n');
const kpaDet: Detection = GenericImportService.detect(kpaRows, IMPV, VOCAB);
eq(kpaDet.hasHeader, false, '无表头文件不被误判为有表头');
eq(kpaDet.kind, ImportKind.BP, '无表头也能识别为血压记录');
eq(kpaDet.roleIndex[ColRole.DATE], 0, '第 1 列按内容判为日期');
eq(kpaDet.roleIndex[ColRole.TIME], 1, '第 2 列按内容判为时间');
eq(kpaDet.roleIndex[ColRole.BP_PAIR], 2, '第 3 列按内容判为血压组合值');
eq(kpaDet.unit, ImportUnit.KPA, '按数值量级判定为 kPa');
{
  const kpaPreview: GenericBpPreview = GenericImportService.parseBp(
    kpaRows, VOCAB, kpaDet, new Set<string>());
  eq(kpaPreview.errors.length, 0, 'kPa 行无错误');
  eq(kpaPreview.drafts.length, 2, 'kPa 2 条有效');
  eq(kpaPreview.drafts[0].systolic, 126, '16.8 kPa → 126 mmHg（四舍五入）');
  eq(kpaPreview.drafts[0].diastolic, 79, '10.5 kPa → 79 mmHg');
  eq(kpaPreview.drafts[0].heartRate, null, '无心率列为 null');
  eq(kpaPreview.convertedFromKpa, true, '标记已由 kPa 换算');
  eq(kpaPreview.roundedCount, 2, '标记 2 条为小数取整');
}

group('外部来源：日期时间合并列 / 无时间列');
const dtRows: string[][] = Csv.parse('记录时间,收缩压,舒张压\r\n2026-10-05 21:40,138,88\r\n');
const dtDet: Detection = GenericImportService.detect(dtRows, IMPV, VOCAB);
eq(dtDet.roleIndex[ColRole.DATETIME], 0, '「记录时间」→ 日期时间合并列');
eq(dtDet.roleIndex[ColRole.SYSTOLIC], 1, '收缩压列');
{
  const dtPreview: GenericBpPreview = GenericImportService.parseBp(dtRows, VOCAB, dtDet, new Set<string>());
  eq(dtPreview.drafts.length, 1, '1 条有效');
  eq(dtPreview.drafts[0].measureTime, ts(2026, 10, 5, 21, 40), '合并列时间正确');
  eq(dtPreview.drafts[0].period, Period.NIGHT, '21:40 → 睡前');
}

const noTimeRows: string[][] = Csv.parse('日期,高压,低压\r\n2026-10-05,138,88\r\n');
const noTimeDet: Detection = GenericImportService.detect(noTimeRows, IMPV, VOCAB);
eq(noTimeDet.roleIndex[ColRole.TIME], -1, '不存在时间列');
eq(noTimeDet.missing.length, 0, '没有时间列不算缺必需项（日期已足够）');
{
  const ntPreview: GenericBpPreview = GenericImportService.parseBp(noTimeRows, VOCAB, noTimeDet, new Set<string>());
  eq(ntPreview.drafts.length, 1, '无时间列仍可导入');
  eq(ntPreview.drafts[0].measureTime, ts(2026, 10, 5, 0, 0), '时间统一记为 00:00（不臆造）');
  eq(ntPreview.noTimeColumn, true, '标记「无时间列」供界面提示');
}

group('外部来源：列序打乱 + 多余列');
const messyRows: string[][] = Csv.parse('备注,备用列,收缩压,测量日期,测量时间,舒张压,心率\r\n'
  + '还行,x,132,2026-10-01,6:30,86,74\r\n');
const messyDet: Detection = GenericImportService.detect(messyRows, IMPV, VOCAB);
eq(messyDet.roleIndex[ColRole.SYSTOLIC], 2, '收缩压在第 3 列');
eq(messyDet.roleIndex[ColRole.DATE], 3, '日期在第 4 列');
eq(messyDet.roleIndex[ColRole.TIME], 4, '时间在第 5 列');
eq(messyDet.roleIndex[ColRole.DIASTOLIC], 5, '舒张压在第 6 列');
eq(messyDet.roleIndex[ColRole.HEART_RATE], 6, '心率在第 7 列');
eq(messyDet.roleIndex[ColRole.NOTE], 0, '备注在第 1 列');
{
  const messyPreview: GenericBpPreview = GenericImportService.parseBp(messyRows, VOCAB, messyDet, new Set<string>());
  eq(messyPreview.drafts.length, 1, '打乱列序后仍正确解析');
  eq(messyPreview.drafts[0].systolic, 132, '数值未错位');
  eq(messyPreview.drafts[0].measureTime, ts(2026, 10, 1, 6, 30), '时间未错位');
}

group('外部来源：脏行逐行隔离（不中断整批）');
const dirtyRows: string[][] = Csv.parse('日期,时间,收缩压,舒张压\r\n'
  + '2026-10-01,6:30,132,86\r\n'
  + '2026-02-30,6:30,132,86\r\n'
  + '2026-10-03,25:00,132,86\r\n'
  + '2026-10-04,6:30,86,132\r\n'
  + ',6:30,132,86\r\n');
const dirtyDet: Detection = GenericImportService.detect(dirtyRows, IMPV, VOCAB);
{
  const dirtyPreview: GenericBpPreview = GenericImportService.parseBp(dirtyRows, VOCAB, dirtyDet, new Set<string>());
  eq(dirtyPreview.totalRows, 5, '数据 5 行');
  eq(dirtyPreview.drafts.length, 1, '仅 1 行可入库');
  eq(dirtyPreview.errors.length, 4, '4 行被逐行隔离');
  ok(dirtyPreview.errors[0].lineNo === 3, '错误行号指向原始文件行号（含表头偏移）');
}

group('外部来源：与自家导出格式互认（两条路径口径一致）');
const own: string = '日期,时间,收缩压(mmHg),舒张压(mmHg),心率(bpm),时段,备注\r\n'
  + '2026-10-01,06:30,132,86,74,晨起,起床后\r\n'
  + '2026-10-02,12:10,128,82,,午休前\r\n';
const ownRows: string[][] = Csv.parse(own);
const ownDet: Detection = GenericImportService.detect(ownRows, IMPV, VOCAB);
eq(ownDet.kind, ImportKind.BP, '自家格式也能被智能识别吃下');
eq(ownDet.roleIndex[ColRole.SYSTOLIC], 2, '「收缩压(mmHg)」去括号与单位后识别');
eq(ownDet.roleIndex[ColRole.PERIOD], 5, '「时段」列识别');
{
  const ownGeneric: GenericBpPreview = GenericImportService.parseBp(ownRows, VOCAB, ownDet, new Set<string>());
  const ownStrict = ImportService.parseBpTable(ownRows, VOCAB, new Set<string>());
  eq(ownGeneric.drafts.length, ownStrict.drafts.length, '两条路径有效条数一致');
  eq(ownGeneric.drafts[0].period, Period.MORNING, '时段文字被识别（非按时间推断）');
  eq(ownGeneric.drafts[0].note, '起床后', '备注一致');
  // 口径一致性：两条路径产出的判重键必须完全相同，否则同一份数据会重复入库
  let sameKeys: boolean = ownGeneric.drafts.length === ownStrict.drafts.length;
  for (let i = 0; i < ownGeneric.drafts.length && sameKeys; i++) {
    const a = ownGeneric.drafts[i];
    const b = ownStrict.drafts[i];
    sameKeys = ImportService.bpKey(a.measureTime, a.systolic, a.diastolic)
      === ImportService.bpKey(b.measureTime, b.systolic, b.diastolic);
  }
  ok(sameKeys, '两条导入路径的判重键完全一致（同一份数据不会重复入库）');
}

group('外部来源：用药打卡外部写法');
const medAltRows: string[][] = Csv.parse('日期,时间,药品,剂量,状态,实际打卡时间\r\n'
  + '2026-10-01,07:30,缬沙坦,1片,已服,07:35\r\n'
  + '2026-10-01,18:00,缬沙坦,1片,漏服,\r\n'
  + '2026-10-02,07:30,缬沙坦,1片,已服(补记),09:05\r\n');
const medAltDet: Detection = GenericImportService.detect(medAltRows, IMPV, VOCAB);
eq(medAltDet.kind, ImportKind.MED, '识别为用药打卡记录');
eq(medAltDet.roleIndex[ColRole.MED_NAME], 2, '药品列');
eq(medAltDet.roleIndex[ColRole.STATUS], 4, '状态列');
eq(medAltDet.roleIndex[ColRole.TAKEN_TIME], 5, '实际打卡时间列');
{
  const medPreview = GenericImportService.parseMed(
    medAltRows, VOCAB, IMPV, medAltDet, new Set<string>(), new Map<string, number>());
  eq(medPreview.errors.length, 0, '外部状态写法无错误行');
  eq(medPreview.drafts.length, 3, '3 条有效');
  const d0: MedImportDraft = medPreview.drafts[0];
  eq(d0.status, MedLogStatus.TAKEN, '「已服」→ 已服用');
  eq(d0.takenTime, ts(2026, 10, 1, 7, 35), '实际打卡时间按行内日期补全');
  const d1: MedImportDraft = medPreview.drafts[1];
  eq(d1.status, MedLogStatus.MISSED, '「漏服」→ 漏服');
  eq(d1.takenTime, null, '漏服无实际打卡时间');
  const d2: MedImportDraft = medPreview.drafts[2];
  eq(d2.status, MedLogStatus.TAKEN, '「已服(补记)」→ 已服用');
  eq(d2.takenTime, ts(2026, 10, 2, 9, 5), '补记行保留真实打卡时间');
}

const medMakeupRows: string[][] = Csv.parse('日期,时间,药品,状态\r\n'
  + '2026-10-01,07:30,缬沙坦,已服(补记)\r\n'
  + '2026-10-01,18:00,缬沙坦,已服\r\n');
const medMakeupDet: Detection = GenericImportService.detect(medMakeupRows, IMPV, VOCAB);
{
  const p = GenericImportService.parseMed(
    medMakeupRows, VOCAB, IMPV, medMakeupDet, new Set<string>(), new Map<string, number>());
  eq(p.drafts.length, 2, '2 条有效');
  eq(p.drafts[0].takenTime, ts(2026, 10, 1, 7, 30) + MedLimits.MISS_GRACE_MS + 1,
    '无打卡时间列时「补记」取宽限期后 1ms（库内补记判定成立）');
  eq(p.drafts[1].takenTime, null, '非补记的「已服」不设置打卡时间（视为按时）');
}

group('外部来源：识别为用药计划时给出明确指引（不误判入库）');
const extPlanRows: string[][] = Csv.parse('药品,剂量,每日次数,时间点,开始日期\r\n缬沙坦,1片,2,07:30;18:00,2026-10-01\r\n');
const planDet: Detection = GenericImportService.detect(extPlanRows, IMPV, VOCAB);
eq(planDet.kind, ImportKind.PLAN, '识别为用药计划');
eq(planDet.roleIndex[ColRole.SLOTS], 3, '时间点列');
eq(planDet.roleIndex[ColRole.START_DATE], 4, '开始日期列');

group('外部来源：用户手工改列对应后结果随之变化');
{
  // 自动识别把「舒张压」列当成收缩压时，用户改选后应立刻得到正确结果
  const swap: string[][] = Csv.parse('日期,时间,甲列,乙列\r\n2026-10-01,6:30,86,132\r\n');
  const swapDet: Detection = GenericImportService.detect(swap, IMPV, VOCAB);
  const forced: MappingPlan = {
    hasHeader: swapDet.hasHeader,
    roleIndex: swapDet.roleIndex.slice(),
    unit: swapDet.unit,
    unitScale: swapDet.unitScale
  };
  forced.roleIndex[ColRole.SYSTOLIC] = 3;
  forced.roleIndex[ColRole.DIASTOLIC] = 2;
  const forcedPreview: GenericBpPreview = GenericImportService.parseBp(swap, VOCAB, forced, new Set<string>());
  eq(forcedPreview.drafts.length, 1, '手工指定列对应后可正常解析');
  eq(forcedPreview.drafts[0].systolic, 132, '收缩压取自手工指定的列');
  eq(forcedPreview.drafts[0].diastolic, 86, '舒张压取自手工指定的列');
  ok(GenericImportService.missingRolesFor(ImportKind.BP, forced.roleIndex).length === 0,
    '手工指定后不再缺必需列');
}

// ═══════════════════ 审查反例迁移（R20.2）═══════════════════
// 来源：《全面审查报告与修改要求-2026-10-11.md》19 个反例（docs/review-2026-10-11/repro.cjs）。
// 迁入正式回归时保留业务断言含义；编号 Rxx-y 与报告、docs/审查整改执行记录.md 的映射表一一对应。
async function reviewScenarios(): Promise<void> {
  const ctxStub = {} as unknown as common.Context;

  group('审查反例 R17（测试实例隔离）');
  {
    let prefixRejected = false;
    try {
      BpDatabase.createIsolated('bp_recorder.db');
    } catch (err) {
      prefixRejected = true;
    }
    ok(prefixRejected, 'R17 用生产库名创建测试实例必须被拒绝');

    const iso: BpDatabase = BpDatabase.createIsolated('bp_recorder_unittest.parity.db');
    ok(iso.isTestInstance(), 'R17 createIsolated 产出测试实例');
    ok(iso !== BpDatabase.getInstance(), 'R17 测试实例不得是生产单例');

    let switchRejected = false;
    iso.attachStoreStub({ auditOnly: true });
    try {
      await iso.init(ctxStub, 'bp_recorder_unittest.other.db');
    } catch (err) {
      switchRejected = true;
    }
    ok(switchRejected, 'R17-a 已初始化实例切换库名必须被拒绝（不得静默复用连接）');

    let clearGuarded = false;
    try {
      BpDatabase.getInstance().requireTestInstance('clearAll');
    } catch (err) {
      clearGuarded = true;
    }
    ok(clearGuarded, 'R17 生产实例上的 clearAll 身份核验必须拒绝');
  }

  group('审查反例 R18（初始化失败可重试）');
  {
    let opens = 0;
    const arkStore = relationalStore as unknown as Record<string, unknown>;
    // 桩模块是空对象（见 tools/parity/run.mjs 的 STUBS）：注入到 doInit 用得到的常量
    arkStore['SecurityLevel'] = { S1: 1 };
    const original = arkStore['getRdbStore'];
    arkStore['getRdbStore'] = async () => {
      opens++;
      throw new Error('injected open failure');
    };
    const db: BpDatabase = new BpDatabase();
    let firstThrew = false;
    let secondThrew = false;
    try {
      await db.init(ctxStub);
    } catch (err) {
      firstThrew = true;
    }
    try {
      await db.init(ctxStub);
    } catch (err) {
      secondThrew = true;
    }
    eq(opens, 2, 'R18-a 一次初始化失败后再次 init 必须重新尝试打开数据库');
    ok(firstThrew && secondThrew, 'R18-a 两次失败都必须抛给调用方（不得静默成功）');
    arkStore['getRdbStore'] = original;
  }

  group('审查反例 R06（写操作串行队列与事务隔离）');
  {
    const db: BpDatabase = new BpDatabase();
    const rows: string[] = [];
    let begins = 0;
    db.attachStoreStub({
      beginTransaction: async () => {
        begins++;
      },
      commit: async () => {},
      rollBack: async () => {
        rows.length = 0;
      }
    });
    let release: () => void = () => {};
    let entered: () => void = () => {};
    const hold = new Promise<void>((r: () => void) => {
      release = r;
    });
    const started = new Promise<void>((r: () => void) => {
      entered = r;
    });
    const a = db.runInTransaction(async (tx: TxSession) => {
      entered();
      await hold;
      throw new Error('A fails');
    }).catch(() => {});
    const b = db.runInTransaction(async (tx: TxSession) => {
      rows.push('B');
    }).catch(() => {});
    await started;
    release();
    await a;
    await b;
    eq(rows.length, 1, 'R06-a B 的写入必须保留');
    eq(rows[0], 'B', 'R06-a B 的写入不得被 A 的回滚带走');
    eq(begins, 2, 'R06-a B 必须开自己的事务（不得并入 A 的事务）');

    const db2: BpDatabase = new BpDatabase();
    let calls = 0;
    db2.attachStoreStub({
      beginTransaction: async () => {
        calls++;
        if (calls === 1) {
          throw new Error('begin fails');
        }
      },
      commit: async () => {},
      rollBack: async () => {}
    });
    await db2.runInTransaction(async (tx: TxSession) => {}).catch(() => {});
    await db2.runInTransaction(async (tx: TxSession) => {});
    eq(calls, 2, 'R06-b begin 失败后下一独立事务仍必须调用 begin（队列未被堵死）');
  }

  group('审查反例 R07（保存药品+计划的领域命令）');
  {
    // 桩模块是空对象：先补一个最小的 RdbPredicates（只提供签名，不做筛选）
    const arkRel = (relationalStore as unknown as Record<string, unknown>);
    if (arkRel['RdbPredicates'] === undefined) {
      arkRel['RdbPredicates'] = class {
        constructor(table: string) {}
        private self(): unknown {
          return this;
        }
        equalTo(field: string, value: unknown): unknown { return this.self(); }
        notEqualTo(field: string, value: unknown): unknown { return this.self(); }
        greaterThan(field: string, value: unknown): unknown { return this.self(); }
        greaterThanOrEqualTo(field: string, value: unknown): unknown { return this.self(); }
        lessThan(field: string, value: unknown): unknown { return this.self(); }
        lessThanOrEqualTo(field: string, value: unknown): unknown { return this.self(); }
        between(field: string, low: unknown, high: unknown): unknown { return this.self(); }
        in(field: string, value: unknown): unknown { return this.self(); }
        orderByAsc(field: string): unknown { return this.self(); }
        orderByDesc(field: string): unknown { return this.self(); }
        limitAs(value: number): unknown { return this.self(); }
        offsetAs(value: number): unknown { return this.self(); }
      };
    }
    const db: BpDatabase = new BpDatabase();
    let begins = 0;
    let commits = 0;
    const updates: Array<Record<string, unknown>> = [];
    let deletes = 0;
    db.attachStoreStub({
      beginTransaction: async () => {
        begins++;
      },
      commit: async () => {
        commits++;
      },
      rollBack: async () => {},
      insert: async (table: string, values: unknown) => (table === 'med_plan' ? 7 : 1),
      update: async (values: Record<string, unknown>, predicates: unknown) => {
        updates.push(values);
        return 1;
      },
      delete: async (predicates: unknown) => {
        deletes++;
        return 0;
      },
      executeSql: async (sql: string, args?: unknown) => {},
      querySql: async (sql: string) => {
        throw new Error('unused');
      }
    });
    const result = await db.saveMedicationAndPlan({
      medicationId: 5,
      medication: { name: '测试药5', dosage: '2片', note: null },
      plan: { medicationId: 5, timeSlots: ['08:00'], startDate: '2026-10-01', endDate: null },
      regenerateFrom: 0,
      preGenDays: 7
    }, async (tx: TxSession, medicationId: number) => 3);
    eq(begins, 1, 'R07 保存药品+计划只开一个事务');
    eq(commits, 1, 'R07 提交一次');
    eq(result.medicationId, 5, 'R07 既有药品保存后仍返回同一 id');
    eq(result.generatedPending, 3, 'R07 生成结果原样带回');
    let reactivated = false;
    for (const u of updates) {
      if (u['is_active'] === 1 && u['name'] === '测试药5') {
        reactivated = true;
      }
    }
    ok(reactivated, 'R07 保存时显式写入 is_active=1（归档药品可复活）');
    ok(deletes > 0, 'R07 同事务内清理按旧计划生成的未来待服');
  }
}

function finish(): void {
// ═══════════════════ 汇总 ═══════════════════
const total = passCount + failures.length;
process.stdout.write(`\n================ 离线校验结果 ================\n`);
process.stdout.write(`断言总数：${total}    通过：${passCount}    失败：${failures.length}\n`);
if (failures.length > 0) {
  process.stdout.write(`\n失败明细：\n`);
  for (const f of failures) {
    process.stdout.write(`  ✗ ${f}\n`);
  }
} else {
  process.stdout.write(`全部通过。\n`);
}
process.stdout.write(`==============================================\n`);
process.exit(failures.length === 0 ? 0 : 1);
}

reviewScenarios().then(() => finish()).catch((err) => {
  failures.push(`[审查反例迁移] harness 异常：${String(err)}`);
  finish();
});
