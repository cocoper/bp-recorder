import { ValidationResult } from '../model/BpRecord';
import { BpLimits } from '../common/Constants';
import { DateUtils } from '../common/DateUtils';

/** 录入表单原始值（保持字符串，便于逐项报错） */
export interface BpFormValues {
  systolicText: string;
  diastolicText: string;
  heartRateText: string;
  /** 测量时间戳 */
  measureTime: number;
  note: string;
}

/** 字段级错误条目（保持插入顺序，首个即 firstError） */
interface FieldError {
  field: string;
  res: Resource;
}

/**
 * 血压录入校验（纯函数，可单测，CL-2 全部校验规则的唯一落点）。
 *
 * 校验规则：
 * 1. 收缩压必填、整数、40–300；
 * 2. 舒张压必填、整数、30–200；
 * 3. 收缩压必须大于舒张压（FR-1.2）；
 * 4. 心率选填，填写时整数、30–220；
 * 5. 备注 ≤100 字；
 * 6. 测量时间不得晚于当前时间（容忍 60s 误差）。
 */
export class BpValidator {
  static readonly FIELD_SYSTOLIC: string = 'systolic';
  static readonly FIELD_DIASTOLIC: string = 'diastolic';
  static readonly FIELD_HEART_RATE: string = 'heartRate';
  static readonly FIELD_NOTE: string = 'note';
  static readonly FIELD_TIME: string = 'measureTime';

  /** 非负整数解析：空串 / 含非数字 返回 null */
  static parsePositiveInt(text: string): number | null {
    if (text === null || text === undefined) {
      return null;
    }
    const t: string = text.trim();
    if (t.length === 0 || !DateUtils.isDigits(t)) {
      return null;
    }
    return Number.parseInt(t, 10);
  }

  /** 条目列表 → 校验结果（首个条目即 firstError） */
  private static buildResult(entries: FieldError[]): ValidationResult {
    const map: Map<string, Resource> = new Map<string, Resource>();
    for (let i = 0; i < entries.length; i++) {
      map.set(entries[i].field, entries[i].res);
    }
    const first: Resource | null = entries.length > 0 ? entries[0].res : null;
    return { ok: entries.length === 0, fieldErrors: map, firstError: first };
  }

  private static normalize(text: string): string {
    if (text === null || text === undefined) {
      return '';
    }
    return text.trim();
  }

  /**
   * 逐项范围与大小关系校验（不含时间与备注）。
   * CSV 导入复用此方法，保证「导入校验规则 == 录入校验规则」。
   */
  static validateCore(systolicText: string, diastolicText: string, heartRateText: string): ValidationResult {
    const entries: FieldError[] = [];
    const sysText: string = BpValidator.normalize(systolicText);
    const diaText: string = BpValidator.normalize(diastolicText);
    const hrText: string = BpValidator.normalize(heartRateText);

    let sys: number | null = null;
    let dia: number | null = null;

    if (sysText.length === 0) {
      entries.push({ field: BpValidator.FIELD_SYSTOLIC, res: $r('app.string.err_sys_required') });
    } else {
      const parsed: number | null = BpValidator.parsePositiveInt(sysText);
      if (parsed === null) {
        entries.push({ field: BpValidator.FIELD_SYSTOLIC, res: $r('app.string.err_sys_invalid') });
      } else if (parsed < BpLimits.SYSTOLIC_MIN || parsed > BpLimits.SYSTOLIC_MAX) {
        entries.push({ field: BpValidator.FIELD_SYSTOLIC, res: $r('app.string.err_sys_range') });
      } else {
        sys = parsed;
      }
    }

    if (diaText.length === 0) {
      entries.push({ field: BpValidator.FIELD_DIASTOLIC, res: $r('app.string.err_dia_required') });
    } else {
      const parsed: number | null = BpValidator.parsePositiveInt(diaText);
      if (parsed === null) {
        entries.push({ field: BpValidator.FIELD_DIASTOLIC, res: $r('app.string.err_dia_invalid') });
      } else if (parsed < BpLimits.DIASTOLIC_MIN || parsed > BpLimits.DIASTOLIC_MAX) {
        entries.push({ field: BpValidator.FIELD_DIASTOLIC, res: $r('app.string.err_dia_range') });
      } else {
        dia = parsed;
      }
    }

    // FR-1.2：收缩压必须大于舒张压（两侧同时标红，便于用户定位）
    if (sys !== null && dia !== null && sys <= dia) {
      entries.push({ field: BpValidator.FIELD_SYSTOLIC, res: $r('app.string.err_sys_le_dia') });
      entries.push({ field: BpValidator.FIELD_DIASTOLIC, res: $r('app.string.err_sys_le_dia') });
    }

    // 心率选填：留空合法
    if (hrText.length > 0) {
      const hr: number | null = BpValidator.parsePositiveInt(hrText);
      if (hr === null) {
        entries.push({ field: BpValidator.FIELD_HEART_RATE, res: $r('app.string.err_hr_invalid') });
      } else if (hr < BpLimits.HEART_RATE_MIN || hr > BpLimits.HEART_RATE_MAX) {
        entries.push({ field: BpValidator.FIELD_HEART_RATE, res: $r('app.string.err_hr_range') });
      }
    }

    return BpValidator.buildResult(entries);
  }

  /** 录入表单完整校验：核心规则 + 时间 + 备注 */
  static validateForm(form: BpFormValues, now: number): ValidationResult {
    const entries: FieldError[] = [];

    const core: ValidationResult = BpValidator.validateCore(form.systolicText, form.diastolicText, form.heartRateText);
    const coreKeys: string[] = [BpValidator.FIELD_SYSTOLIC, BpValidator.FIELD_DIASTOLIC, BpValidator.FIELD_HEART_RATE];
    for (let i = 0; i < coreKeys.length; i++) {
      const res: Resource | undefined = core.fieldErrors.get(coreKeys[i]);
      if (res !== undefined) {
        entries.push({ field: coreKeys[i], res: res });
      }
    }

    if (!(form.measureTime > 0)) {
      entries.push({ field: BpValidator.FIELD_TIME, res: $r('app.string.err_time_invalid') });
    } else if (form.measureTime > now + 60 * 1000) {
      entries.push({ field: BpValidator.FIELD_TIME, res: $r('app.string.err_time_future') });
    }

    const note: string = form.note === null || form.note === undefined ? '' : form.note;
    if (note.length > BpLimits.NOTE_MAX_LEN) {
      entries.push({ field: BpValidator.FIELD_NOTE, res: $r('app.string.err_note_too_long') });
    }

    return BpValidator.buildResult(entries);
  }
}
