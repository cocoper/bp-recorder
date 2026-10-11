import { MedLogStatus, Period, ReminderMode } from './Types';
import { Adherence, DailyPoint, DateRange, DistRow, MorningCompare, RangeStats } from './BpRecord';

/** 药品档案（对应表 medication） */
export interface Medication {
  id: number;
  /** 药品名称，≤30 字 */
  name: string;
  /** 单次剂量文字，如「1 片 / 5mg」 */
  dosage: string;
  note: string | null;
  /** true=启用，false=停用（归档，历史打卡保留） */
  isActive: boolean;
  createdAt: number;
  updatedAt: number;
}

/** 药品档案草稿 */
export interface MedicationDraft {
  name: string;
  dosage: string;
  note: string | null;
}

/** 服药计划（对应表 med_plan），每个药品一条生效计划 */
export interface MedPlan {
  id: number;
  medicationId: number;
  /** 每日时间点 HH:mm，长度 1–4，升序 */
  timeSlots: string[];
  /** 开始日期 YYYY-MM-DD */
  startDate: string;
  /** 结束日期 YYYY-MM-DD；null = 长期 */
  endDate: string | null;
  isActive: boolean;
  createdAt: number;
  updatedAt: number;
}

/** 计划草稿 */
export interface MedPlanDraft {
  medicationId: number;
  timeSlots: string[];
  startDate: string;
  endDate: string | null;
}

/** 服药打卡记录（对应表 med_log） */
export interface MedLog {
  id: number;
  medicationId: number;
  /** 药品名称快照 */
  medName: string;
  /** 剂量快照 */
  dosage: string;
  /** 计划服药时间，Unix 毫秒时间戳 */
  scheduledTime: number;
  /** 实际打卡时间戳，未打卡为 null */
  takenTime: number | null;
  status: MedLogStatus;
  note: string | null;
  createdAt: number;
  updatedAt: number;
}

/** 打卡记录草稿（预生成用） */
export interface MedLogDraft {
  medicationId: number;
  medName: string;
  dosage: string;
  scheduledTime: number;
}

/** 首页「今日服药」卡片的一行（§5.1 / FR-9.3） */
export interface TodayMedLine {
  logId: number;
  medName: string;
  dosage: string;
  scheduledTime: number;
  status: MedLogStatus;
  /** 是否补记（taken 且 taken_time 晚于计划时间 + 2h） */
  isMakeUp: boolean;
  /** 该时间点在当日所有时间点中的序号（1 起） */
  slotSeq: number;
  /** 同一时间点下的第几个药品（1 起） */
  medSeq: number;
  /** 同一时间点的药品总数 */
  medCountInSlot: number;
}

/** 药品 + 其生效计划 */
export interface MedWithPlan {
  medication: Medication;
  plan: MedPlan | null;
}

/** 用药管理页行（已格式化的展示态） */
export interface MedListRow {
  medication: Medication;
  plan: MedPlan | null;
  /** 生效中 = 药品启用 且 存在生效计划 */
  active: boolean;
  /** 剂量行，如「1片/80mg · 每日2次」 */
  dosageLine: string;
  /** 计划行，如「07:30 / 18:00 · 长期」 */
  planLine: string;
  /** v1.15：该药品没有生效计划、但存在 end_date 已过的计划时，说明它是被「到期自动停用」的；无则空串 */
  expiredLine: string;
}

/** 提醒方式探测结论（FR-9.1 / §5.9） */
export interface ReminderCapability {
  /** 最终选定的提醒方式 */
  mode: ReminderMode;
  /** 代理提醒能力是否可用（已申请开放能力且发布成功过） */
  agentAvailable: boolean;
  /** 通知是否已授权 */
  notificationEnabled: boolean;
  /** 探测失败原因，用于设置页提示与日志排查 */
  detail: string;
}

/** 用药计划导出 / 导入行（v1.3 审查意见 P1-9） */
export interface PlanExportRow {
  medName: string;
  dosage: string;
  /** 每日时间点 HH:mm，长度 1–4 */
  timeSlots: string[];
  /** 开始日期 YYYY-MM-DD */
  startDate: string;
  /** 结束日期 YYYY-MM-DD；null = 长期 */
  endDate: string | null;
  note: string | null;
}

/** 去重用轻量元组（用药打卡 CSV 导入判重，FR-6.7） */
export interface MedDedupeTuple {
  medicationId: number;
  medName: string;
  scheduledTime: number;
}

/** 报告异常清单行（FR-10.2 板块 7） */
export interface AbnormalItem {
  measureTime: number;
  systolic: number;
  diastolic: number;
  period: Period;
}

/** 报告展示数据（FR-10.2 九个板块） */
export interface ReportData {
  /** 周期类型：week / month / custom */
  kind: string;
  /** 报告标题，如「血压周报」 */
  title: string;
  range: DateRange;
  generatedAt: number;
  /** 板块 2：核心指标卡 */
  stats: RangeStats;
  /** 板块 4：分级分布 */
  distribution: DistRow[];
  /** 板块 5：晨起 / 全天对比（原「晨峰分析」） */
  morningCompare: MorningCompare;
  /** 板块 6：环比对比 */
  hasPrev: boolean;
  prevLabel: string;
  prevSysMean: number;
  prevDiaMean: number;
  deltaSys: number;
  deltaDia: number;
  /** 板块 3：周期内每日均值折线数据 */
  dailyPoints: DailyPoint[];
  /** 板块 7：异常清单（≥140/90） */
  abnormals: AbnormalItem[];
  /** 板块 8：用药小结 */
  adherence: Adherence;
  /** 该周期是否存在生效用药计划（决定用药板块是否展示） */
  hasMedPlan: boolean;
  /** 分享图/长图水印行（FR-11.2） */
  watermark: string;
}
