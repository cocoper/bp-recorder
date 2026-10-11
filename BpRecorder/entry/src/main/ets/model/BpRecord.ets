import { GradeLevel, Period } from './Types';

/** 血压记录（对应表 bp_record） */
export interface BpRecord {
  id: number;
  systolic: number;
  diastolic: number;
  /** 心率，可留空 */
  heartRate: number | null;
  /** 测量时间，Unix 毫秒时间戳 */
  measureTime: number;
  period: Period;
  /** 备注，≤100 字 */
  note: string | null;
  /** 预留：多用户扩展 */
  userId: number;
  /** 预留：manual / bluetooth */
  source: string;
  createdAt: number;
  updatedAt: number;
}

/** 新增记录草稿（无 id） */
export interface BpRecordDraft {
  systolic: number;
  diastolic: number;
  heartRate: number | null;
  measureTime: number;
  period: Period;
  note: string | null;
}

/** 分页查询结果 */
export interface PageResult<T> {
  items: T[];
  total: number;
  offset: number;
  limit: number;
  hasMore: boolean;
}

/** 录入校验结果 */
export interface ValidationResult {
  ok: boolean;
  /** 字段名 → 错误提示资源（用于逐项红色描边 + 红字） */
  fieldErrors: Map<string, Resource>;
  /** 首个错误的兜底提示 */
  firstError: Resource | null;
}

/** 图表单个数据点（同日多次测量取平均，策划文档 FR-3.3） */
export interface DailyPoint {
  /** 当日 00:00 的时间戳，作为 x 轴键 */
  dayStart: number;
  sysAvg: number;
  diaAvg: number;
  /** 当日有心率数据的平均值；无数据为 null */
  hrAvg: number | null;
  /** 当日测量次数 */
  count: number;
  /** 当日是否已完成全部服药打卡（用于 FR-9.6 图表药丸标记） */
  medComplete: boolean;
}

/** 区间统计结果（FR-4.1） */
export interface RangeStats {
  count: number;
  sysMean: number;
  diaMean: number;
  hrMean: number | null;
  sysMax: number;
  sysMin: number;
  diaMax: number;
  diaMin: number;
  /** 收缩压总体标准差（÷N，口径固定，见实现方案 §8.3） */
  sysStdDev: number;
  diaStdDev: number;
}

/** 分级分布单行（FR-4.2） */
export interface DistRow {
  level: GradeLevel;
  count: number;
  /** 占比，%，保留 1 位；末位做余额调整保证合计 100.0 */
  percent: number;
}

/**
 * 晨起 / 全天对比结果（FR-4.3；v1.3 由「晨峰分析」更名，见决策 D2）。
 * 口径为「晨起时段均值 − 全天均值」，**不是临床血压晨峰**（本 App 取不到夜间最低血压）。
 */
export interface MorningCompare {
  morningCount: number;
  morningSys: number;
  morningDia: number;
  overallSys: number;
  overallDia: number;
  /** 晨起均值 − 全天均值，可为负 */
  deltaSys: number;
  deltaDia: number;
}

// 说明：PeriodStats.surge 与 ReportData.surge 已随更名改为 morningCompare，
// 字段类型统一为 MorningCompare。

/** 周期统计聚合包（统计页与报告页共用同一口径） */
export interface PeriodStats {
  range: DateRange;
  stats: RangeStats;
  distribution: DistRow[];
  morningCompare: MorningCompare;
}

/** 时间区间（左闭右闭，毫秒时间戳） */
export interface DateRange {
  start: number;
  end: number;
  /** 展示用标签，如 2026-09-28 ~ 10-04 */
  label: string;
}

/** 单个药品在某日的应服实例（由计划展开而来） */
export interface SlotInstance {
  medicationId: number;
  medName: string;
  dosage: string;
  /** 计划服药时间戳 */
  scheduledTime: number;
  /** 该药品计划的 id，用于追溯 */
  planId: number;
}

/** 去重用轻量三元组（CSV 导入判重，FR-6.6 / CL-10） */
export interface BpDedupeTuple {
  measureTime: number;
  systolic: number;
  diastolic: number;
}

/** 依从率统计（FR-9.5） */
export interface Adherence {
  /** 计划总量（含未到期的 pending）——仅供展示，不参与比率 */
  expected: number;
  taken: number;
  skipped: number;
  missed: number;
  /** 尚未到计划时间、仍处 pending 的次数：计入 expected，不计入 due（v1.4 口径，见实现方案 §8） */
  pendingNotDue: number;
  /** 已到期义务 = taken + skipped + missed（依从率分母） */
  due: number;
  /** 已服 ÷ 已到期义务 × 100；分母为 0 时返回 null（UI 显示 —） */
  rate: number | null;
}
