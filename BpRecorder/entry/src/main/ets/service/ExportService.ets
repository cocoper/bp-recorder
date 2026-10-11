import { BpRecord } from '../model/BpRecord';
import { MedLog, PlanExportRow } from '../model/Med';
import { MedLogStatus } from '../model/Types';
import { Csv } from '../common/Csv';
import { CsvVocab, periodCsvName } from '../common/Vocab';
import { DateUtils } from '../common/DateUtils';
import { MedService } from './MedService';

/** 导出范围档位（FR-6.2） */
export class ExportRangeKind {
  static readonly ALL: string = 'all';
  static readonly D30: string = 'd30';
  static readonly D90: string = 'd90';
  /** 下拉选项顺序 */
  static readonly ORDER: string[] = [ExportRangeKind.ALL, ExportRangeKind.D30, ExportRangeKind.D90];
}

/** 导出范围 → 显示名资源 */
export class ExportRangeText {
  static label(kind: string): Resource {
    switch (kind) {
      case ExportRangeKind.D30:
        return $r('app.string.export_range_30');
      case ExportRangeKind.D90:
        return $r('app.string.export_range_90');
      default:
        return $r('app.string.export_range_all');
    }
  }
}

/**
 * CSV 导出（FR-6.1 / FR-6.4）。
 *
 * 纯函数：不依赖 UI、不依赖数据库，所需文案经 CsvVocab 传入（表头、时段名、状态名）。
 * 因此「导出 → 导入」往返一致性可在本机离线用例中直接验证（CL-10）。
 * 文件写入由页面通过 picker + fs 完成（走 picker 无需持久文件权限，NFR-5）。
 */
export class ExportService {
  /** 按范围筛选血压记录；记录按测量时间升序输出，便于人工核对 */
  static filterBpByRange(records: BpRecord[], kind: string, now: number): BpRecord[] {
    if (kind === ExportRangeKind.ALL) {
      return records;
    }
    const days: number = kind === ExportRangeKind.D90 ? 90 : 30;
    const start: number = DateUtils.addDays(DateUtils.startOfDay(now), -(days - 1));
    const out: BpRecord[] = [];
    for (let i = 0; i < records.length; i++) {
      if (records[i].measureTime >= start) {
        out.push(records[i]);
      }
    }
    return out;
  }

  /** 血压 CSV 文本（UTF-8 带 BOM，字段顺序与附录 A 一致） */
  static buildBpCsv(records: BpRecord[], vocab: CsvVocab): string {
    const rows: string[][] = [vocab.bpHeaders];
    const sorted: BpRecord[] = records.slice().sort((a: BpRecord, b: BpRecord) => a.measureTime - b.measureTime);
    for (let i = 0; i < sorted.length; i++) {
      const r: BpRecord = sorted[i];
      rows.push([
        DateUtils.formatDate(r.measureTime),
        DateUtils.formatTime(r.measureTime),
        `${r.systolic}`,
        `${r.diastolic}`,
        r.heartRate === null || r.heartRate === undefined ? '' : `${r.heartRate}`,
        periodCsvName(vocab, r.period),
        r.note === null || r.note === undefined ? '' : r.note,
        // 精确 measure_time（毫秒）：保证「导出 → 原样回导」判重幂等，且同分钟的两条真实记录不被合并
        `${r.measureTime}`
      ]);
    }
    return Csv.stringify(rows, true);
  }

  /**
   * 用药打卡 CSV 文本（字段顺序与附录 A 一致）。
   * 导出的是**落库状态**而非「当前解析状态」，因此 pending 会原样导出为「待服」，
   * 保证「导出 → 原样回导」不丢行、不改变语义。
   */
  static buildMedCsv(logs: MedLog[], vocab: CsvVocab): string {
    const rows: string[][] = [vocab.medHeaders];
    const sorted: MedLog[] = logs.slice().sort((a: MedLog, b: MedLog) => a.scheduledTime - b.scheduledTime);
    for (let i = 0; i < sorted.length; i++) {
      const log: MedLog = sorted[i];
      const taken: number | null = log.takenTime;
      rows.push([
        DateUtils.formatDate(log.scheduledTime),
        DateUtils.formatTime(log.scheduledTime),
        log.medName,
        log.dosage,
        ExportService.medStatusText(log, vocab),
        taken === null || taken === undefined ? '' : DateUtils.formatTime(taken),
        log.note === null || log.note === undefined ? '' : log.note,
        // 审查 R09：完整 scheduled_time 与可空 taken_time（毫秒），避免补记时间被降级成「当天 HH:mm」
        `${log.scheduledTime}`,
        taken === null || taken === undefined ? '' : `${taken}`
      ]);
    }
    return Csv.stringify(rows, true);
  }

  /**
   * 用药计划 CSV 文本（v1.3 审查意见 P1-9）。
   *
   * 每个药品一行（对应 FR-8.2「每个药品一条生效计划」），多个时间点用分隔符连接。
   * 有了这个文件，「血压 + 打卡 + 用药计划」三件套导出即可完整还原换机前的状态。
   */
  static buildPlanCsv(rows: PlanExportRow[], vocab: CsvVocab): string {
    const out: string[][] = [vocab.planHeaders];
    const sorted: PlanExportRow[] = rows.slice().sort((a: PlanExportRow, b: PlanExportRow) => {
      if (a.medName === b.medName) {
        return 0;
      }
      return a.medName < b.medName ? -1 : 1;
    });
    for (let i = 0; i < sorted.length; i++) {
      const r: PlanExportRow = sorted[i];
      const slots: string[] = MedService.normalizeSlots(r.timeSlots);
      out.push([
        r.medName,
        r.dosage,
        `${slots.length}`,
        slots.join(vocab.slotSeparator),
        r.startDate,
        r.endDate === null || r.endDate === undefined ? '' : r.endDate,
        r.note === null || r.note === undefined ? '' : r.note
      ]);
    }
    return Csv.stringify(out, true);
  }

  /**
   * 打卡状态 → CSV 文字。
   * 「已服用(补记)」由 MedService.isMakeUp 依 taken_time 与计划时间的差值推导，
   * 保证状态文字与实际时间一致，不出现自相矛盾的行。
   */
  static medStatusText(log: MedLog, vocab: CsvVocab): string {
    if (log.status === MedLogStatus.TAKEN) {
      return MedService.isMakeUp(log) ? vocab.statusTakenMakeup : vocab.statusTaken;
    }
    if (log.status === MedLogStatus.SKIPPED) {
      return vocab.statusSkipped;
    }
    if (log.status === MedLogStatus.MISSED) {
      return vocab.statusMissed;
    }
    return vocab.statusPending;
  }
}
