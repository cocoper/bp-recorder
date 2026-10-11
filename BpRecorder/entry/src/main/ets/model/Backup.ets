/**
 * 完整备份文件结构（审查 R10）。
 *
 * 定位：**唯一**能兑现「换机完整恢复」的载体 —— 三份 CSV 只是交换格式（人类可读、可丢字段）。
 * 设计要点：
 * - 备份按**稳定 ID**导出（medication/plan/log 的 id 原样保留），并保留启停状态、毫秒时间戳与计划版本区间；
 * - `formatVersion` 只管文件格式，`schemaVersion` 记录导出时的数据库结构版本，恢复时据此判断兼容性；
 * - 结构是 JSON 单文件，字段名稳定、可逐字段校验。
 */
export const BACKUP_FORMAT_VERSION: number = 1;

/** 备份计数（meta 里冗余一份，便于人工核对与冲突预览对账） */
export interface BackupCounts {
  bp: number;
  meds: number;
  plans: number;
  logs: number;
}

export interface BackupMeta {
  /** 文件格式版本（本结构为 1） */
  formatVersion: number;
  /** 导出时数据库结构版本（DbConst.SCHEMA_VERSION） */
  schemaVersion: number;
  /** 应用版本（由调用方从包信息传入；取不到时为空串） */
  appVersion: string;
  /** 导出时刻（毫秒） */
  exportedAt: number;
  /** 各表条数 */
  counts: BackupCounts;
}

/** 血压记录（逐字段） */
export interface BackupBp {
  measureTime: number;
  systolic: number;
  diastolic: number;
  heartRate: number | null;
  period: string;
  note: string | null;
}

/** 药品档案（含启停状态与时间戳） */
export interface BackupMed {
  id: number;
  name: string;
  dosage: string;
  note: string | null;
  isActive: boolean;
  createdAt: number;
  updatedAt: number;
}

/** 用药计划（含版本区间：startDate/endDate 与 isActive 原样保留） */
export interface BackupPlan {
  id: number;
  medicationId: number;
  timeSlots: string[];
  startDate: string;
  endDate: string | null;
  isActive: boolean;
  createdAt: number;
  updatedAt: number;
}

/** 用药打卡记录（毫秒计划/打卡时间，含状态与备注） */
export interface BackupLog {
  id: number;
  medicationId: number;
  medName: string;
  dosage: string;
  scheduledTime: number;
  takenTime: number | null;
  status: string;
  note: string | null;
  createdAt: number;
  updatedAt: number;
  /** 来源计划 id（审查 R01.3；历史数据可缺省） */
  sourcePlanId?: number;
}

/** 备份文件本体 */
export interface BackupFile {
  meta: BackupMeta;
  bp: BackupBp[];
  meds: BackupMed[];
  plans: BackupPlan[];
  logs: BackupLog[];
}

/** 逐字段校验问题（path 形如 logs[3].scheduledTime） */
export interface BackupIssue {
  path: string;
  reason: string;
}

/** 解析结果：结构不合法或版本不支持时 file 为 null，原因在 issues 里 */
export interface BackupParseResult {
  file: BackupFile | null;
  issues: BackupIssue[];
}

/** 冲突预览：按稳定身份判定新增/覆盖/冲突 */
export interface BackupPreview {
  /** 将新增的记录数（按表） */
  addCounts: BackupCounts;
  /** 将覆盖的已有记录数（按表） */
  overwriteCounts: BackupCounts;
  /** 备份内部的重复项（同一身份出现多次） */
  internalDuplicates: number;
  /** 逐字段校验问题 */
  issues: BackupIssue[];
  /** 是否可执行恢复（issues 为空才允许） */
  restorable: boolean;
}

/** 恢复结果：明确「新增 / 覆盖 / 忽略」数量，不接受「插入成功」这种模糊结论 */
export interface BackupRestoreResult {
  /** 本次新增的条数（按表） */
  added: BackupCounts;
  /** 本次按稳定身份覆盖的条数（按表） */
  overwritten: BackupCounts;
  /** 备份内部重复而被忽略的条数 */
  ignored: number;
  /** 逐字段校验问题；非空表示**未写入任何数据** */
  issues: BackupIssue[];
}
