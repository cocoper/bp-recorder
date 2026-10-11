import {
  BACKUP_FORMAT_VERSION, BackupBp, BackupCounts, BackupFile, BackupIssue, BackupLog, BackupMed,
  BackupMeta, BackupParseResult, BackupPlan, BackupPreview
} from '../model/Backup';
import { Medication, MedLog, MedPlan } from '../model/Med';
import { BpRecord } from '../model/BpRecord';
import { BackupTarget, TxSession } from './BpDatabase';
import { DbConst, MedLimits } from '../common/Constants';
import { BackupRestoreResult } from '../model/Backup';
import { DateUtils } from '../common/DateUtils';
import { Logger } from '../common/Logger';

const TAG: string = 'BackupService';

/**
 * 完整备份的构建、序列化、解析与校验（审查 R10）。
 *
 * 分层：本服务只做**纯数据**变换（构建/序列化/解析/逐字段校验/冲突预览），
 * 落库由 BpDatabase 的事务方法完成 —— 这样恢复前的校验与预览可以在无数据库环境下被回归覆盖。
 * 校验规则与录入/导入契约保持一致：时间戳必须是有限正数、文本不超限、引用必须存在。
 */
export class BackupService {
  /** 由查询结果构建备份文件（调用方负责查询；appVersion 由页面从包信息传入） */
  static build(bp: BpRecord[], meds: Medication[], plans: MedPlan[], logs: MedLog[],
    appVersion: string, now: number): BackupFile {
    const bpOut: BackupBp[] = [];
    for (let i = 0; i < bp.length; i++) {
      const r: BpRecord = bp[i];
      bpOut.push({
        measureTime: r.measureTime, systolic: r.systolic, diastolic: r.diastolic,
        heartRate: r.heartRate === undefined ? null : r.heartRate,
        period: `${r.period}`, note: r.note === undefined ? null : r.note
      });
    }
    const medsOut: BackupMed[] = [];
    for (let i = 0; i < meds.length; i++) {
      const m: Medication = meds[i];
      medsOut.push({
        id: m.id, name: m.name, dosage: m.dosage, note: m.note === undefined ? null : m.note,
        isActive: m.isActive, createdAt: m.createdAt, updatedAt: m.updatedAt
      });
    }
    const plansOut: BackupPlan[] = [];
    for (let i = 0; i < plans.length; i++) {
      const p: MedPlan = plans[i];
      plansOut.push({
        id: p.id, medicationId: p.medicationId, timeSlots: p.timeSlots.slice(),
        startDate: p.startDate, endDate: p.endDate === undefined ? null : p.endDate,
        isActive: p.isActive, createdAt: p.createdAt, updatedAt: p.updatedAt
      });
    }
    const logsOut: BackupLog[] = [];
    for (let i = 0; i < logs.length; i++) {
      const l: MedLog = logs[i];
      logsOut.push({
        id: l.id, medicationId: l.medicationId, medName: l.medName, dosage: l.dosage,
        scheduledTime: l.scheduledTime, takenTime: l.takenTime === undefined ? null : l.takenTime,
        status: `${l.status}`, note: l.note === undefined ? null : l.note,
        createdAt: l.createdAt, updatedAt: l.updatedAt,
        sourcePlanId: l.planId
      });
    }
    const counts: BackupCounts = {
      bp: bpOut.length, meds: medsOut.length, plans: plansOut.length, logs: logsOut.length
    };
    const meta: BackupMeta = {
      formatVersion: BACKUP_FORMAT_VERSION,
      schemaVersion: DbConst.SCHEMA_VERSION,
      appVersion: appVersion,
      exportedAt: now,
      counts: counts
    };
    return { meta: meta, bp: bpOut, meds: medsOut, plans: plansOut, logs: logsOut };
  }

  /** 序列化为 JSON 单文件文本 */
  static serialize(file: BackupFile): string {
    return JSON.stringify(file);
  }

  /** 解析文本：结构不合法/版本不支持时 file 为 null，原因写进 issues */
  static parse(text: string): BackupParseResult {
    const issues: BackupIssue[] = [];
    let raw: BackupFile | null = null;
    try {
      raw = JSON.parse(text) as BackupFile;
    } catch (err) {
      const e = err as Error;
      issues.push({ path: '$', reason: `JSON 解析失败：${e.message}` });
      return { file: null, issues: issues };
    }
    if (raw === null || raw === undefined) {
      issues.push({ path: '$', reason: '空内容' });
      return { file: null, issues: issues };
    }
    const meta: BackupMeta = raw.meta;
    if (meta === null || meta === undefined) {
      issues.push({ path: 'meta', reason: '缺少 meta（不是备份文件？）' });
      return { file: null, issues: issues };
    }
    if (meta.formatVersion !== BACKUP_FORMAT_VERSION) {
      issues.push({
        path: 'meta.formatVersion',
        reason: `不支持的备份格式版本 ${meta.formatVersion}（本应用支持 ${BACKUP_FORMAT_VERSION}）`
      });
      return { file: null, issues: issues };
    }
    if (meta.schemaVersion > DbConst.SCHEMA_VERSION) {
      issues.push({
        path: 'meta.schemaVersion',
        reason: `备份来自更高版本数据库 ${meta.schemaVersion}（本应用支持 ${DbConst.SCHEMA_VERSION}）：请先升级应用`
      });
      return { file: null, issues: issues };
    }
    return { file: raw, issues: issues };
  }

  /**
   * 恢复（审查 R10.3/R10.4）：**单次事务**按稳定身份覆盖写入四表，先档案/计划再打卡/血压，
   * 过程中不生成 pending、不发布提醒；提醒由调用方在提交后统一重新协调。
   * 传回的计数是「本次实际新增 / 覆盖 / 忽略（备份内部重复）」，不是「插入成功」。
   */
  static async restore(target: BackupTarget, file: BackupFile,
    existingMedIds: Set<number>, existingPlanIds: Set<number>,
    existingLogKeys: Set<string>, existingBpKeys: Set<string>): Promise<BackupRestoreResult> {
    const result: BackupRestoreResult = {
      added: { bp: 0, meds: 0, plans: 0, logs: 0 },
      overwritten: { bp: 0, meds: 0, plans: 0, logs: 0 },
      ignored: 0,
      issues: BackupService.validate(file)
    };
    if (result.issues.length > 0) {
      return result;    // 校验不通过一律不写（避免半恢复）
    }
    const seenMed: Set<number> = new Set<number>();
    const seenPlan: Set<number> = new Set<number>();
    const seenLog: Set<string> = new Set<string>();
    const seenBp: Set<string> = new Set<string>();

    await target.runInTransaction(async (tx: TxSession): Promise<void> => {
      for (let i = 0; i < file.meds.length; i++) {
        const m: BackupMed = file.meds[i];
        if (seenMed.has(m.id)) {
          result.ignored++;
          continue;
        }
        seenMed.add(m.id);
        await target.restoreMedication(m, tx);
        if (existingMedIds.has(m.id)) {
          result.overwritten.meds++;
        } else {
          result.added.meds++;
        }
      }
      for (let i = 0; i < file.plans.length; i++) {
        const p: BackupPlan = file.plans[i];
        if (seenPlan.has(p.id)) {
          result.ignored++;
          continue;
        }
        seenPlan.add(p.id);
        await target.restorePlan(p, tx);
        if (existingPlanIds.has(p.id)) {
          result.overwritten.plans++;
        } else {
          result.added.plans++;
        }
      }
      for (let i = 0; i < file.logs.length; i++) {
        const l: BackupLog = file.logs[i];
        const key: string = `${l.medicationId}_${l.scheduledTime}`;
        if (seenLog.has(key)) {
          result.ignored++;
          continue;
        }
        seenLog.add(key);
        await target.restoreMedLog(l, tx);
        if (existingLogKeys.has(key)) {
          result.overwritten.logs++;
        } else {
          result.added.logs++;
        }
      }
      for (let i = 0; i < file.bp.length; i++) {
        const b: BackupBp = file.bp[i];
        const key: string = `${b.measureTime}_${b.systolic}_${b.diastolic}`;
        if (seenBp.has(key)) {
          result.ignored++;
          continue;
        }
        seenBp.add(key);
        await target.restoreBp(b, tx);
        if (existingBpKeys.has(key)) {
          result.overwritten.bp++;
        } else {
          result.added.bp++;
        }
      }
    });
    Logger.info(TAG, `backup restored: added=${JSON.stringify(result.added)}, overwritten=${JSON.stringify(result.overwritten)}`);
    return result;
  }

  /** 有限正时间戳 */
  private static badTs(v: number): boolean {
    return v === undefined || v === null || !Number.isFinite(v) || v <= 0;
  }

  /** 逐字段校验（引用完整性、范围、长度、时间戳有限性） */
  static validate(file: BackupFile): BackupIssue[] {
    const issues: BackupIssue[] = [];
    const medIds: Set<number> = new Set<number>();
    for (let i = 0; i < file.meds.length; i++) {
      const m: BackupMed = file.meds[i];
      const at: string = `meds[${i}]`;
      if (m === null || m === undefined) {
        issues.push({ path: at, reason: '空条目' });
        continue;
      }
      if (!Number.isFinite(m.id) || m.id <= 0) {
        issues.push({ path: `${at}.id`, reason: '药品 id 必须是正整数' });
      } else if (medIds.has(m.id)) {
        issues.push({ path: `${at}.id`, reason: `药品 id 重复：${m.id}` });
      } else {
        medIds.add(m.id);
      }
      const name: string = m.name === undefined || m.name === null ? '' : m.name;
      if (name.length === 0) {
        issues.push({ path: `${at}.name`, reason: '药品名不能为空' });
      } else if (name.length > MedLimits.NAME_MAX_LEN) {
        issues.push({ path: `${at}.name`, reason: `药品名超过 ${MedLimits.NAME_MAX_LEN} 字` });
      }
      const dosage: string = m.dosage === undefined || m.dosage === null ? '' : m.dosage;
      if (dosage.length > MedLimits.DOSAGE_MAX_LEN) {
        issues.push({ path: `${at}.dosage`, reason: `剂量超过 ${MedLimits.DOSAGE_MAX_LEN} 字` });
      }
      if (m.note !== null && m.note !== undefined && m.note.length > MedLimits.NOTE_MAX_LEN) {
        issues.push({ path: `${at}.note`, reason: `备注超过 ${MedLimits.NOTE_MAX_LEN} 字` });
      }
    }

    for (let i = 0; i < file.plans.length; i++) {
      const p: BackupPlan = file.plans[i];
      const at: string = `plans[${i}]`;
      if (p === null || p === undefined) {
        issues.push({ path: at, reason: '空条目' });
        continue;
      }
      if (!medIds.has(p.medicationId)) {
        issues.push({ path: `${at}.medicationId`, reason: `引用了不存在的药品 ${p.medicationId}` });
      }
      if (p.timeSlots === null || p.timeSlots === undefined || p.timeSlots.length === 0) {
        issues.push({ path: `${at}.timeSlots`, reason: '计划至少要有一个时点' });
      } else if (p.timeSlots.length > MedLimits.MAX_SLOTS) {
        issues.push({ path: `${at}.timeSlots`, reason: `时点数超过上限 ${MedLimits.MAX_SLOTS}` });
      } else {
        for (let k = 0; k < p.timeSlots.length; k++) {
          const parts: string[] = `${p.timeSlots[k]}`.split(':');
          if (parts.length !== 2) {
            issues.push({ path: `${at}.timeSlots[${k}]`, reason: `时点格式非法：${p.timeSlots[k]}` });
          }
        }
      }
      const start: number | null = DateUtils.parseDate(p.startDate);
      if (start === null) {
        issues.push({ path: `${at}.startDate`, reason: `开始日期非法：${p.startDate}` });
      }
      if (p.endDate !== null && p.endDate !== undefined && p.endDate.length > 0) {
        const end: number | null = DateUtils.parseDate(p.endDate);
        if (end === null) {
          issues.push({ path: `${at}.endDate`, reason: `结束日期非法：${p.endDate}` });
        } else if (start !== null && end < start) {
          issues.push({ path: `${at}.endDate`, reason: '结束日期早于开始日期' });
        }
      }
    }

    for (let i = 0; i < file.logs.length; i++) {
      const l: BackupLog = file.logs[i];
      const at: string = `logs[${i}]`;
      if (l === null || l === undefined) {
        issues.push({ path: at, reason: '空条目' });
        continue;
      }
      if (!medIds.has(l.medicationId) && (`${l.medName}`.length === 0)) {
        issues.push({ path: at, reason: '既没有有效药品 id，也没有药品名' });
      }
      if (BackupService.badTs(l.scheduledTime)) {
        issues.push({ path: `${at}.scheduledTime`, reason: '计划时间必须是有限正时间戳' });
      }
      if (l.takenTime !== null && l.takenTime !== undefined && BackupService.badTs(l.takenTime)) {
        issues.push({ path: `${at}.takenTime`, reason: '打卡时间必须是有限正时间戳或 null' });
      }
      const status: string = `${l.status}`;
      if (status !== 'taken' && status !== 'taken_makeup' && status !== 'skipped'
        && status !== 'missed' && status !== 'pending') {
        issues.push({ path: `${at}.status`, reason: `未知状态：${status}` });
      }
      if (l.note !== null && l.note !== undefined && l.note.length > MedLimits.NOTE_MAX_LEN) {
        issues.push({ path: `${at}.note`, reason: `备注超过 ${MedLimits.NOTE_MAX_LEN} 字` });
      }
    }

    for (let i = 0; i < file.bp.length; i++) {
      const b: BackupBp = file.bp[i];
      const at: string = `bp[${i}]`;
      if (b === null || b === undefined) {
        issues.push({ path: at, reason: '空条目' });
        continue;
      }
      if (BackupService.badTs(b.measureTime)) {
        issues.push({ path: `${at}.measureTime`, reason: '测量时间必须是有限正时间戳' });
      }
      if (!Number.isFinite(b.systolic) || !Number.isFinite(b.diastolic)) {
        issues.push({ path: at, reason: '收缩压/舒张压必须是有限数值' });
      }
      if (b.heartRate !== null && b.heartRate !== undefined && !Number.isFinite(b.heartRate)) {
        issues.push({ path: `${at}.heartRate`, reason: '心率必须是有限数值或 null' });
      }
      if (b.note !== null && b.note !== undefined && b.note.length > MedLimits.NOTE_MAX_LEN) {
        issues.push({ path: `${at}.note`, reason: `备注超过 ${MedLimits.NOTE_MAX_LEN} 字` });
      }
    }
    Logger.info(TAG, `backup validated: issues=${issues.length}`);
    return issues;
  }

  /**
   * 冲突预览（审查 R10）：按**稳定身份**判定「新增 / 覆盖 / 备份内部重复」。
   * 身份规则与库内唯一约束一致：药品/计划按 id，打卡按 (药品, 计划时间)，血压按 (时间, 收缩压, 舒张压)。
   */
  static preview(file: BackupFile, existingMedIds: Set<number>, existingPlanIds: Set<number>,
    existingLogKeys: Set<string>, existingBpKeys: Set<string>): BackupPreview {
    const issues: BackupIssue[] = BackupService.validate(file);
    const add: BackupCounts = { bp: 0, meds: 0, plans: 0, logs: 0 };
    const overwrite: BackupCounts = { bp: 0, meds: 0, plans: 0, logs: 0 };
    let internalDuplicates: number = 0;

    const seenMed: Set<number> = new Set<number>();
    for (let i = 0; i < file.meds.length; i++) {
      const id: number = file.meds[i].id;
      if (seenMed.has(id)) {
        internalDuplicates++;
      } else {
        seenMed.add(id);
        if (existingMedIds.has(id)) {
          overwrite.meds++;
        } else {
          add.meds++;
        }
      }
    }
    const seenPlan: Set<number> = new Set<number>();
    for (let i = 0; i < file.plans.length; i++) {
      const id: number = file.plans[i].id;
      if (seenPlan.has(id)) {
        internalDuplicates++;
      } else {
        seenPlan.add(id);
        if (existingPlanIds.has(id)) {
          overwrite.plans++;
        } else {
          add.plans++;
        }
      }
    }
    const seenLog: Set<string> = new Set<string>();
    for (let i = 0; i < file.logs.length; i++) {
      const l: BackupLog = file.logs[i];
      const key: string = `${l.medicationId}_${l.scheduledTime}`;
      if (seenLog.has(key)) {
        internalDuplicates++;
      } else {
        seenLog.add(key);
        if (existingLogKeys.has(key)) {
          overwrite.logs++;
        } else {
          add.logs++;
        }
      }
    }
    const seenBp: Set<string> = new Set<string>();
    for (let i = 0; i < file.bp.length; i++) {
      const b: BackupBp = file.bp[i];
      const key: string = `${b.measureTime}_${b.systolic}_${b.diastolic}`;
      if (seenBp.has(key)) {
        internalDuplicates++;
      } else {
        seenBp.add(key);
        if (existingBpKeys.has(key)) {
          overwrite.bp++;
        } else {
          add.bp++;
        }
      }
    }
    return {
      addCounts: add,
      overwriteCounts: overwrite,
      internalDuplicates: internalDuplicates,
      issues: issues,
      restorable: issues.length === 0
    };
  }
}

