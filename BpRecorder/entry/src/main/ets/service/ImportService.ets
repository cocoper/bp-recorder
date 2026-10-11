import { BpDedupeTuple, BpRecordDraft, ValidationResult } from '../model/BpRecord';
import { MedDedupeTuple, Medication, MedicationDraft, MedPlan, PlanExportRow } from '../model/Med';
import { MedLogStatus, Period } from '../model/Types';
import { Csv } from '../common/Csv';
import { CsvVocab, parsePeriodCsvName } from '../common/Vocab';
import { DateUtils } from '../common/DateUtils';
import { MedLimits } from '../common/Constants';
import { Logger } from '../common/Logger';
import { BpValidator } from './BpValidator';
import { BpDatabase, TxSession } from './BpDatabase';
import { MedService } from './MedService';

const TAG: string = 'ImportService';

/** 跨零点补记判定阈值：计划时刻与打卡时刻「同日差值」超过 12h，判定为次日打卡 */
const NEXT_DAY_GAP_MS: number = 12 * 60 * 60 * 1000;

/** 单行错误（FR-6.6：逐行列出原因，不中断整批导入） */
export interface ImportIssue {
  /** CSV 文件中的物理行号（1 基，含表头行） */
  lineNo: number;
  /** 错误原因文案资源 */
  reason: Resource;
  /** 出错的原始值，便于用户定位 */
  detail: string;
}

/** 血压导入预览（FR-6.5） */
export interface BpImportPreview {
  /** 有效且未重复、将通过事务入库的记录 */
  drafts: BpRecordDraft[];
  duplicateCount: number;
  errors: ImportIssue[];
  /** 前 5 行预览文本 */
  previewLines: string[];
  /** 数据行总数（不含表头） */
  totalRows: number;
  /** 旧格式（无毫秒时间戳列）的行数：>0 时界面应提示「仅分钟精度」（审查 R08） */
  legacyMinuteRows?: number;
}

/** 用药打卡导入草稿 */
export interface MedImportDraft {
  medName: string;
  dosage: string;
  scheduledTime: number;
  status: MedLogStatus;
  takenTime: number | null;
  note: string | null;
}

/** 用药打卡导入预览 */
export interface MedImportPreview {
  drafts: MedImportDraft[];
  duplicateCount: number;
  errors: ImportIssue[];
  previewLines: string[];
  totalRows: number;
}

/** 用药计划导入预览（v1.3 审查意见 P1-9） */
export interface PlanImportPreview {
  drafts: PlanExportRow[];
  duplicateCount: number;
  errors: ImportIssue[];
  previewLines: string[];
  totalRows: number;
}

/** 导入结果（FR-6.5 结果页） */
export interface ImportResult {
  inserted: number;
  skippedDuplicate: number;
  failed: number;
  issues: ImportIssue[];
  /** 本次自动创建的药品档案名（FR-6.7） */
  createdMedications: string[];
}

/**
 * CSV 导入（FR-6.5–FR-6.8）。
 *
 * 分层：
 * - 解析与判重为**纯函数**（parseBpTable / parseMedTable），可在本机离线用例中验证；
 * - 入库为异步方法，整体包在一个数据库事务内，任一系统级失败即回滚（FR-6.8）。
 *
 * 错误行处理原则：格式类问题（缺列 / 越界 / 时间非法）在解析阶段逐行隔离并记录原因，
 * 绝不因单行错误中断整批导入。
 */
export class ImportService {
  // ───────────────────────── 判重键 ─────────────────────────

  /** 血压判重键：测量时间戳 + 收缩压 + 舒张压（FR-6.6 三元组） */
  static bpKey(measureTime: number, systolic: number, diastolic: number): string {
    return `${measureTime}_${systolic}_${diastolic}`;
  }

  /** 用药判重键（按药品 id）：药品 + 计划时间 */
  static medKeyById(medicationId: number, scheduledTime: number): string {
    return `i:${medicationId}_${scheduledTime}`;
  }

  /** 用药判重键（按药品名），用于药品尚未建档或档案被改名的情况 */
  static medKeyByName(medName: string, scheduledTime: number): string {
    return `n:${medName}_${scheduledTime}`;
  }

  /** 由数据库查询结果构造血压判重键集合 */
  static buildBpKeySet(tuples: BpDedupeTuple[]): Set<string> {
    const keys: Set<string> = new Set<string>();
    for (let i = 0; i < tuples.length; i++) {
      const t: BpDedupeTuple = tuples[i];
      keys.add(ImportService.bpKey(t.measureTime, t.systolic, t.diastolic));
    }
    return keys;
  }

  /** 由数据库查询结果构造用药判重键集合（同时登记 id 键与名称键，兼容改名场景） */
  static buildMedKeySet(tuples: MedDedupeTuple[]): Set<string> {
    const keys: Set<string> = new Set<string>();
    for (let i = 0; i < tuples.length; i++) {
      const t: MedDedupeTuple = tuples[i];
      keys.add(ImportService.medKeyById(t.medicationId, t.scheduledTime));
      keys.add(ImportService.medKeyByName(t.medName, t.scheduledTime));
    }
    return keys;
  }

  // ───────────────────────── 血压解析 ─────────────────────────

  /**
   * 解析血压 CSV。
   * @param rows Csv.parse 的原始输出
   * @param vocab CSV 文案词表
   * @param existingKeys 库内已有记录的判重键集合
   */
  static parseBpTable(rows: string[][], vocab: CsvVocab, existingKeys: Set<string>): BpImportPreview {
    const data: string[][] = Csv.normalize(rows);
    const drafts: BpRecordDraft[] = [];
    const errors: ImportIssue[] = [];
    const previewLines: string[] = [];
    const seen: Set<string> = new Set<string>();
    let duplicateCount: number = 0;
    /** 旧格式（无毫秒时间戳列）的行数：这些行只能按分钟精度解析 */
    let legacyMinuteRows: number = 0;

    let start: number = 0;
    if (data.length > 0 && ImportService.isBpHeader(data[0], vocab)) {
      start = 1;
    }
    const totalRows: number = data.length - start;

    for (let i = start; i < data.length; i++) {
      const lineNo: number = i + 1;
      const row: string[] = data[i];

      // 缺列：日期 / 时间 / 收缩压 / 舒张压 四列必须有
      if (row.length < 4) {
        errors.push({
          lineNo: lineNo,
          reason: $r('app.string.err_imp_missing_column'),
          detail: row.length === 0 ? '' : row.join(',')
        });
        continue;
      }

      const dateStr: string = Csv.cell(row, 0);
      const timeStr: string = Csv.cell(row, 1);
      // 审查 R08：新版文件带精确毫秒时间戳，优先用它（保证原样回导判重、同分钟不同秒不合并）；
      // 旧文件没有这一列，退回「日期+时间」解析 —— 只有分钟精度，导入预览里会明确提示。
      let measureTime: number | null = null;
      const exactText: string = row.length > 7 ? Csv.cell(row, row.length - 1) : '';
      if (exactText.length > 0) {
        const exact: number = Number.parseInt(exactText, 10);
        if (!Number.isNaN(exact) && exact > 1000000000000) {
          measureTime = exact;
        }
      }
      if (measureTime === null) {
        measureTime = DateUtils.parseDateTime(dateStr, timeStr);
        legacyMinuteRows++;
      }
      if (measureTime === null) {
        errors.push({
          lineNo: lineNo,
          reason: $r('app.string.err_imp_time_invalid'),
          detail: `${dateStr} ${timeStr}`.trim()
        });
        continue;
      }

      // 复用录入时的同一套校验规则，保证「导入校验 == 录入校验」
      const core: ValidationResult = BpValidator.validateCore(Csv.cell(row, 2), Csv.cell(row, 3), Csv.cell(row, 4));
      if (!core.ok) {
        const reason: Resource = core.firstError === null ? $r('app.string.err_imp_unknown') : core.firstError;
        errors.push({ lineNo: lineNo, reason: reason, detail: `${Csv.cell(row, 2)}/${Csv.cell(row, 3)}` });
        continue;
      }

      const systolic: number | null = BpValidator.parsePositiveInt(Csv.cell(row, 2));
      const diastolic: number | null = BpValidator.parsePositiveInt(Csv.cell(row, 3));
      if (systolic === null || diastolic === null) {
        // 理论不可达（validateCore 已通过），保留兜底避免脏数据引发后续空指针
        errors.push({ lineNo: lineNo, reason: $r('app.string.err_imp_unknown'), detail: '' });
        continue;
      }

      const hrText: string = Csv.cell(row, 4);
      const heartRate: number | null = hrText.length === 0 ? null : BpValidator.parsePositiveInt(hrText);

      // 时段：优先用文件中的文字；无法识别或留空时按测量时间自动推断，避免丢信息
      const periodFromFile: Period | null = parsePeriodCsvName(vocab, Csv.cell(row, 5));
      const period: Period = periodFromFile === null ? DateUtils.periodOf(measureTime) : periodFromFile;

      const noteText: string = Csv.cell(row, 6);
      const note: string | null = noteText.length === 0 ? null : noteText;

      const key: string = ImportService.bpKey(measureTime, systolic, diastolic);
      if (existingKeys.has(key) || seen.has(key)) {
        duplicateCount++;
        seen.add(key);
        continue;
      }
      seen.add(key);
      drafts.push({
        systolic: systolic,
        diastolic: diastolic,
        heartRate: heartRate,
        measureTime: measureTime,
        period: period,
        note: note
      });
    }

    for (let i = 0; i < drafts.length && i < 5; i++) {
      previewLines.push(ImportService.bpPreviewLine(drafts[i], vocab));
    }
    Logger.info(TAG, `parse bp csv: total=${totalRows}, valid=${drafts.length}, dup=${duplicateCount}, err=${errors.length}`);
    return {
      drafts: drafts,
      duplicateCount: duplicateCount,
      errors: errors,
      previewLines: previewLines,
      totalRows: totalRows,
      // 旧格式（无毫秒时间戳列）的行数：界面据此提示「仅分钟精度」（审查 R08）
      legacyMinuteRows: legacyMinuteRows
    };
  }

  private static isBpHeader(row: string[], vocab: CsvVocab): boolean {
    return ImportService.headerMatches(row, vocab.bpHeaders);
  }

  /** 表头判定：至少两列与期望表头一致即视为表头行（容忍 Excel 编辑后的列顺序/空列） */
  private static headerMatches(row: string[], headers: string[]): boolean {
    let matches: number = 0;
    const n: number = row.length < headers.length ? row.length : headers.length;
    for (let i = 0; i < n; i++) {
      if (Csv.cell(row, i) === headers[i]) {
        matches++;
      }
    }
    return matches >= 2;
  }

  /** 血压草稿 → 预览行（外部来源导入 GenericImportService 也复用，保证两条导入路径预览格式一致） */
  static bpPreviewLine(draft: BpRecordDraft, vocab: CsvVocab): string {
    const hr: string = draft.heartRate === null ? '' : ` / ${draft.heartRate}`;
    return `${DateUtils.formatMonthDay(draft.measureTime)} ${DateUtils.formatTime(draft.measureTime)}  ${draft.systolic}/${draft.diastolic}${hr}  ${ImportService.periodName(draft.period, vocab)}`;
  }

  /**
   * 跨零点补记判定（唯一实现，两条导入路径共用）。
   *
   * 语义：计划时刻与打卡时刻的「同日差值」超过 12h，说明打卡发生在次日
   * （例如 23:00 的药在次日 07:00 才打卡），把打卡日期顺延一天，
   * 使库内「按日归集」的依从率统计不把这次打卡算到次日。
   */
  static adjustTakenTime(scheduledTime: number, takenTime: number): number {
    return scheduledTime - takenTime > NEXT_DAY_GAP_MS ? DateUtils.addDays(takenTime, 1) : takenTime;
  }

  private static periodName(period: Period, vocab: CsvVocab): string {
    switch (period) {
      case Period.MORNING:
        return vocab.periodMorning;
      case Period.FORENOON:
        return vocab.periodForenoon;
      case Period.AFTERNOON:
        return vocab.periodAfternoon;
      case Period.NIGHT:
        return vocab.periodNight;
      default:
        return vocab.periodOther;
    }
  }

  // ───────────────────────── 用药解析 ─────────────────────────

  /**
   * 解析用药打卡 CSV。
   * @param nameToId 现有药品「名称 → id」映射（用于判重与建关联）
   */
  static parseMedTable(rows: string[][], vocab: CsvVocab, existingKeys: Set<string>,
    nameToId: Map<string, number>): MedImportPreview {
    const data: string[][] = Csv.normalize(rows);
    const drafts: MedImportDraft[] = [];
    const errors: ImportIssue[] = [];
    const previewLines: string[] = [];
    const seen: Set<string> = new Set<string>();
    let duplicateCount: number = 0;

    let start: number = 0;
    if (data.length > 0 && ImportService.headerMatches(data[0], vocab.medHeaders)) {
      start = 1;
    }
    const totalRows: number = data.length - start;

    for (let i = start; i < data.length; i++) {
      const lineNo: number = i + 1;
      const row: string[] = data[i];

      if (row.length < 5) {
        errors.push({
          lineNo: lineNo,
          reason: $r('app.string.err_imp_missing_column'),
          detail: row.length === 0 ? '' : row.join(',')
        });
        continue;
      }

      const dateStr: string = Csv.cell(row, 0);
      const planTimeStr: string = Csv.cell(row, 1);
      const scheduledTime: number | null = DateUtils.parseDateTime(dateStr, planTimeStr);
      if (scheduledTime === null) {
        errors.push({
          lineNo: lineNo,
          reason: $r('app.string.err_imp_time_invalid'),
          detail: `${dateStr} ${planTimeStr}`.trim()
        });
        continue;
      }

      const medName: string = Csv.cell(row, 2);
      if (medName.length === 0) {
        errors.push({ lineNo: lineNo, reason: $r('app.string.err_imp_med_name_required'), detail: '' });
        continue;
      }

      const statusText: string = Csv.cell(row, 4);
      const status: MedLogStatus | null = ImportService.mapStatusText(statusText, vocab);
      if (status === null) {
        errors.push({ lineNo: lineNo, reason: $r('app.string.err_imp_status_unknown'), detail: statusText });
        continue;
      }

      // 实际打卡时间：留空时按状态推导，保证「补记」语义不丢失
      let takenTime: number | null = null;
      const takenText: string = Csv.cell(row, 5);
      if (takenText.length > 0) {
        const parsed: number | null = DateUtils.parseDateTime(dateStr, takenText);
        if (parsed === null) {
          errors.push({ lineNo: lineNo, reason: $r('app.string.err_imp_taken_time_invalid'), detail: takenText });
          continue;
        }
        takenTime = ImportService.adjustTakenTime(scheduledTime, parsed);
      } else if (statusText === vocab.statusTakenMakeup) {
        // 文件中标注「补记」但未给时间：取宽限期后 1ms，使补记判定在库内仍然成立
        takenTime = scheduledTime + MedLimits.MISS_GRACE_MS + 1;
      }

      const dosage: string = Csv.cell(row, 3);
      const noteText: string = Csv.cell(row, 6);
      const note: string | null = noteText.length === 0 ? null : noteText;

      const idKey: string | null = ImportService.nameKeyOf(medName, scheduledTime, nameToId);
      const nameKey: string = ImportService.medKeyByName(medName, scheduledTime);
      const isDup: boolean = existingKeys.has(nameKey) || seen.has(nameKey)
        || (idKey !== null && (existingKeys.has(idKey) || seen.has(idKey)));
      if (isDup) {
        duplicateCount++;
        seen.add(nameKey);
        continue;
      }
      seen.add(nameKey);
      drafts.push({
        medName: medName,
        dosage: dosage,
        scheduledTime: scheduledTime,
        status: status,
        takenTime: takenTime,
        note: note
      });
    }

    for (let i = 0; i < drafts.length && i < 5; i++) {
      const d: MedImportDraft = drafts[i];
      previewLines.push(`${DateUtils.formatMonthDay(d.scheduledTime)} ${DateUtils.formatTime(d.scheduledTime)}  ${d.medName}  ${ImportService.statusName(d.status, vocab)}`);
    }
    Logger.info(TAG, `parse med csv: total=${totalRows}, valid=${drafts.length}, dup=${duplicateCount}, err=${errors.length}`);
    return {
      drafts: drafts,
      duplicateCount: duplicateCount,
      errors: errors,
      previewLines: previewLines,
      totalRows: totalRows
    };
  }

  private static nameKeyOf(medName: string, scheduledTime: number, nameToId: Map<string, number>): string | null {
    const id: number | undefined = nameToId.get(medName);
    if (id === undefined) {
      return null;
    }
    return ImportService.medKeyById(id, scheduledTime);
  }

  static mapStatusText(text: string, vocab: CsvVocab): MedLogStatus | null {
    if (text === vocab.statusTaken || text === vocab.statusTakenMakeup) {
      return MedLogStatus.TAKEN;
    }
    if (text === vocab.statusSkipped) {
      return MedLogStatus.SKIPPED;
    }
    if (text === vocab.statusMissed) {
      return MedLogStatus.MISSED;
    }
    if (text === vocab.statusPending) {
      return MedLogStatus.PENDING;
    }
    return null;
  }

  static statusName(status: MedLogStatus, vocab: CsvVocab): string {
    switch (status) {
      case MedLogStatus.TAKEN:
        return vocab.statusTaken;
      case MedLogStatus.SKIPPED:
        return vocab.statusSkipped;
      case MedLogStatus.MISSED:
        return vocab.statusMissed;
      default:
        return vocab.statusPending;
    }
  }

  // ───────────────────────── 用药计划解析（P1-9） ─────────────────────────

  /** 计划判重键：药品名 + 规范化后的时间点集合 */
  static planKey(medName: string, timeSlots: string[]): string {
    return `${medName}||${MedService.normalizeSlots(timeSlots).join(';')}`;
  }

  /** 由库内现有药品与计划构造计划判重键集合 */
  static buildPlanKeySet(meds: Medication[], plans: MedPlan[]): Set<string> {
    const nameOf: Map<number, string> = new Map<number, string>();
    for (let i = 0; i < meds.length; i++) {
      nameOf.set(meds[i].id, meds[i].name);
    }
    const keys: Set<string> = new Set<string>();
    for (let i = 0; i < plans.length; i++) {
      const p: MedPlan = plans[i];
      if (!p.isActive) {
        continue;
      }
      const name: string | undefined = nameOf.get(p.medicationId);
      if (name === undefined) {
        continue;
      }
      keys.add(ImportService.planKey(name, p.timeSlots));
    }
    return keys;
  }

  /**
   * 解析用药计划 CSV。
   * 列顺序：药品 / 剂量 / 每日次数 / 时间点 / 开始日期 / 结束日期 / 备注
   * 「每日次数」仅供人阅读，导入时会与「时间点」实际数量交叉校验，不一致按错误行处理。
   */
  static parsePlanTable(rows: string[][], vocab: CsvVocab, existingKeys: Set<string>): PlanImportPreview {
    const data: string[][] = Csv.normalize(rows);
    const drafts: PlanExportRow[] = [];
    const errors: ImportIssue[] = [];
    const previewLines: string[] = [];
    const seen: Set<string> = new Set<string>();
    let duplicateCount: number = 0;

    let start: number = 0;
    if (data.length > 0 && ImportService.headerMatches(data[0], vocab.planHeaders)) {
      start = 1;
    }
    const totalRows: number = data.length - start;

    for (let i = start; i < data.length; i++) {
      const lineNo: number = i + 1;
      const row: string[] = data[i];

      if (row.length < 5) {
        errors.push({
          lineNo: lineNo,
          reason: $r('app.string.err_imp_missing_column'),
          detail: row.length === 0 ? '' : row.join(',')
        });
        continue;
      }

      const medName: string = Csv.cell(row, 0);
      if (medName.length === 0) {
        errors.push({ lineNo: lineNo, reason: $r('app.string.err_imp_med_name_required'), detail: '' });
        continue;
      }

      // 时间点：按分隔符拆分后逐项校验，不用 normalizeSlots 直接吞掉非法项，
      // 否则「格式错误的行」会被静默修正成合法数据
      const rawSlots: string[] = Csv.cell(row, 3).split(vocab.slotSeparator);
      const slots: string[] = [];
      const seenMinutes: Map<number, boolean> = new Map<number, boolean>();
      let invalid: boolean = false;
      let duplicated: boolean = false;
      for (let j = 0; j < rawSlots.length; j++) {
        const t: string = rawSlots[j].trim();
        if (t.length === 0) {
          continue;
        }
        const minutes: number = DateUtils.hhmmToMinutes(t);
        if (minutes < 0) {
          invalid = true;
          break;
        }
        if (seenMinutes.get(minutes) === true) {
          duplicated = true;
          break;
        }
        seenMinutes.set(minutes, true);
        slots.push(t);
      }
      if (invalid) {
        errors.push({ lineNo: lineNo, reason: $r('app.string.err_slot_invalid'), detail: Csv.cell(row, 3) });
        continue;
      }
      if (duplicated) {
        errors.push({ lineNo: lineNo, reason: $r('app.string.err_slot_dup'), detail: Csv.cell(row, 3) });
        continue;
      }
      if (slots.length < MedLimits.MIN_SLOTS || slots.length > MedLimits.MAX_SLOTS) {
        errors.push({ lineNo: lineNo, reason: $r('app.string.err_slot_count'), detail: Csv.cell(row, 3) });
        continue;
      }
      const declaredCount: string = Csv.cell(row, 2);
      if (declaredCount.length > 0 && Number.parseInt(declaredCount, 10) !== slots.length) {
        errors.push({
          lineNo: lineNo,
          reason: $r('app.string.err_slot_count_mismatch'),
          detail: `${declaredCount} vs ${slots.length}`
        });
        continue;
      }
      const timeSlots: string[] = MedService.normalizeSlots(slots);

      const startDate: string = Csv.cell(row, 4);
      const startTs: number | null = DateUtils.parseDate(startDate);
      if (startTs === null) {
        errors.push({ lineNo: lineNo, reason: $r('app.string.err_start_date_invalid'), detail: startDate });
        continue;
      }
      const endDateText: string = Csv.cell(row, 5);
      let endDate: string | null = null;
      if (endDateText.length > 0) {
        const endTs: number | null = DateUtils.parseDate(endDateText);
        if (endTs === null) {
          errors.push({ lineNo: lineNo, reason: $r('app.string.err_end_date_invalid'), detail: endDateText });
          continue;
        }
        if (endTs < startTs) {
          errors.push({ lineNo: lineNo, reason: $r('app.string.err_end_before_start'), detail: endDateText });
          continue;
        }
        endDate = endDateText;
      }

      const noteText: string = Csv.cell(row, 6);
      const key: string = ImportService.planKey(medName, timeSlots);
      if (existingKeys.has(key) || seen.has(key)) {
        duplicateCount++;
        seen.add(key);
        continue;
      }
      seen.add(key);
      drafts.push({
        medName: medName,
        dosage: Csv.cell(row, 1),
        timeSlots: timeSlots,
        startDate: startDate,
        endDate: endDate,
        note: noteText.length === 0 ? null : noteText
      });
    }

    for (let i = 0; i < drafts.length && i < 5; i++) {
      const d: PlanExportRow = drafts[i];
      previewLines.push(`${d.medName}  ${d.timeSlots.join(' / ')}  ${d.startDate}`);
    }
    Logger.info(TAG, `parse plan csv: total=${totalRows}, valid=${drafts.length}, dup=${duplicateCount}, err=${errors.length}`);
    return {
      drafts: drafts,
      duplicateCount: duplicateCount,
      errors: errors,
      previewLines: previewLines,
      totalRows: totalRows
    };
  }

  /**
   * 用药计划入库。整批一个事务。
   * 药品名无匹配时自动创建**启用**档案（与打卡导入相反：这里导入的就是"当前生效计划"，
   * 档案必须是启用状态，否则计划不生效）。
   */
  static async commitPlan(db: BpDatabase, preview: PlanImportPreview): Promise<ImportResult> {
    const created: string[] = [];
    let inserted: number = 0;
    const now: number = DateUtils.now();
    if (preview.drafts.length > 0) {
      await db.runInTransaction(async (tx: TxSession) => {
        const meds: Medication[] = await db.queryMedications();
        const nameToId: Map<string, number> = new Map<string, number>();
        for (let i = 0; i < meds.length; i++) {
          nameToId.set(meds[i].name, meds[i].id);
        }
        for (let i = 0; i < preview.drafts.length; i++) {
          const d: PlanExportRow = preview.drafts[i];
          let medId: number | undefined = nameToId.get(d.medName);
          if (medId === undefined) {
            const draft: MedicationDraft = { name: d.medName, dosage: d.dosage, note: d.note };
            medId = await db.insertMedication(draft, true, tx);
            nameToId.set(d.medName, medId);
            created.push(d.medName);
          } else {
            // 已有档案：确保启用，并按导入内容同步剂量
            await db.setMedicationActive(medId, true, tx);
          }
          // 计划整体替换：先清掉按旧计划生成的未来待服记录（P1-3），再写入新计划
          await db.deleteFuturePendingLogs(medId, now, tx);
          await db.upsertPlan({
            medicationId: medId,
            timeSlots: d.timeSlots,
            startDate: d.startDate,
            endDate: d.endDate
          }, tx);
          inserted++;
        }
      });
    }
    Logger.info(TAG, `commit plan import: inserted=${inserted}, createdMeds=${created.length}`);
    return {
      inserted: inserted,
      skippedDuplicate: preview.duplicateCount,
      failed: preview.errors.length,
      issues: preview.errors,
      createdMedications: created
    };
  }

  // ───────────────────────── 事务入库 ─────────────────────────

  /**
   * 血压批量入库。整批一个事务，任一失败回滚（FR-6.8）。
   */
  static async commitBp(db: BpDatabase, preview: BpImportPreview): Promise<ImportResult> {
    let inserted: number = 0;
    if (preview.drafts.length > 0) {
      await db.runInTransaction(async (tx: TxSession) => {
        const affected: number = await db.batchInsertBp(preview.drafts, tx);
        if (affected < 0) {
          throw new Error('BP_IMPORT_BATCH_FAILED');
        }
        inserted = preview.drafts.length;
      });
    }
    Logger.info(TAG, `commit bp import: inserted=${inserted}`);
    return {
      inserted: inserted,
      skippedDuplicate: preview.duplicateCount,
      failed: preview.errors.length,
      issues: preview.errors,
      createdMedications: []
    };
  }

  /**
   * 用药打卡入库。整批一个事务（FR-6.8）。
   * 药品名无匹配档案时自动创建（仅档案、状态停用、不建计划，FR-6.7）。
   */
  static async commitMed(db: BpDatabase, preview: MedImportPreview): Promise<ImportResult> {
    const created: string[] = [];
    let inserted: number = 0;
    if (preview.drafts.length > 0) {
      await db.runInTransaction(async (tx: TxSession) => {
        const meds = await db.queryMedications();
        const nameToId: Map<string, number> = new Map<string, number>();
        for (let i = 0; i < meds.length; i++) {
          nameToId.set(meds[i].name, meds[i].id);
        }

        for (let i = 0; i < preview.drafts.length; i++) {
          const d: MedImportDraft = preview.drafts[i];
          let medId: number | undefined = nameToId.get(d.medName);
          if (medId === undefined) {
            const draft: MedicationDraft = { name: d.medName, dosage: d.dosage, note: null };
            medId = await db.insertMedication(draft, false, tx);
            nameToId.set(d.medName, medId);
            created.push(d.medName);
          }
          await db.insertMedLogForImport(medId, d.medName, d.dosage, d.scheduledTime,
            d.status, d.takenTime, d.note, tx);
          inserted++;
        }
      });
    }
    Logger.info(TAG, `commit med import: inserted=${inserted}, createdMeds=${created.length}`);
    return {
      inserted: inserted,
      skippedDuplicate: preview.duplicateCount,
      failed: preview.errors.length,
      issues: preview.errors,
      createdMedications: created
    };
  }
}
