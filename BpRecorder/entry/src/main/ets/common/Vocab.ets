import { common } from '@kit.AbilityKit';
import { Period } from '../model/Types';
import {
  CsvHeaderRes,
  CsvSlot,
  CsvStatusRes,
  Disclaimers,
  ImportAliasRes,
  ImportSlot,
  ReminderTextRes,
  ReportTextRes
} from './Constants';
import { LooseParse } from './LooseParse';
import { ResUtils } from './ResUtils';

/**
 * 「文案词表」模块。
 *
 * 为什么需要它：CL-7 要求代码零中文硬编码，但以下三处必须拿到**具体字符串**而不是 Resource：
 *   1. CSV 表头与状态文字（附录 A 规定格式，导入时还要按原文比对）；
 *   2. 报告标题与水印（纯函数 ReportService 的输出）；
 *   3. 系统通知的标题与正文（NotificationKit 只接受 string）。
 *
 * 因此把「资源 → 字符串」的解析动作收敛到本文件，由页面构造一次后作为参数传入服务层。
 * 这样服务层保持**纯函数**（不触碰 resourceManager），
 * 「导出 → 导入」的往返一致性才能在本机离线用例中真实验证（CL-10）。
 */

/** CSV 导入导出词表 */
export interface CsvVocab {
  bpHeaders: string[];
  medHeaders: string[];
  /** 用药计划表头（P1-9 新增） */
  planHeaders: string[];
  /** 计划中多个时间点的分隔符（默认 ";"） */
  slotSeparator: string;
  periodMorning: string;
  periodForenoon: string;
  periodAfternoon: string;
  periodNight: string;
  periodOther: string;
  statusTaken: string;
  statusTakenMakeup: string;
  statusSkipped: string;
  statusMissed: string;
  /** 「待服」为附录 A 之外的补充状态：未到期的 pending 也必须能导出并原样回导 */
  statusPending: string;
}

/** 报告词表 */
export interface ReportVocab {
  titleWeek: string;
  titleMonth: string;
  titleCustom: string;
  /** 水印固定尾句：由「血压助手」生成，仅供参考 */
  watermarkSuffix: string;
  /** 水印各段之间的分隔符（避免在服务层出现标点硬编码） */
  separator: string;
}

/** 提醒词表（系统通知只接受字符串） */
export interface ReminderVocab {
  /** 通知标题，如「服药提醒」 */
  title: string;
  /** 多药品分隔符 */
  separator: string;
  expiredContent: string;
  snoozeContent: string;
  /** 通知按钮文字：知道了 */
  actionClose: string;
}

/**
 * 外部来源导入词表（v1.4 新增）。
 *
 * 与 CsvVocab 的分工：CsvVocab 是**本 App 自家**导出的固定表头/状态文字；
 * 本词表是**别处来的**数据里可能出现的列名别名与状态别名，用于自动识别列含义。
 *
 * 索引约定：`roleNames` 与 `roleAliases` 的长度均为 18，
 * **下标 = ColRole 枚举值**，下标 0（ColRole.NONE）固定为空，便于直接索引、不写换算。
 */
export interface ImportVocab {
  /** 列角色显示名；roleNames[0] 为空串 */
  roleNames: string[];
  /** 列角色匹配别名（已归一化）；roleAliases[0] 为空数组 */
  roleAliases: string[][];
  /** 用药状态别名（已归一化） */
  statusTaken: string[];
  statusSkipped: string[];
  statusMissed: string[];
  statusPending: string[];
  /** 「补记」标记别名（已归一化） */
  statusMakeup: string[];
}

/** 时段 → CSV 文字 */
export function periodCsvName(vocab: CsvVocab, period: Period): string {
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

/** CSV 文字 → 时段；无法识别返回 null（调用方据此回退为按时间自动推断） */
export function parsePeriodCsvName(vocab: CsvVocab, text: string): Period | null {
  const t: string = text === null || text === undefined ? '' : text.trim();
  if (t.length === 0) {
    return null;
  }
  if (t === vocab.periodMorning) {
    return Period.MORNING;
  }
  if (t === vocab.periodForenoon) {
    return Period.FORENOON;
  }
  if (t === vocab.periodAfternoon) {
    return Period.AFTERNOON;
  }
  if (t === vocab.periodNight) {
    return Period.NIGHT;
  }
  if (t === vocab.periodOther) {
    return Period.OTHER;
  }
  return null;
}

function resolveAll(context: common.UIAbilityContext, list: Resource[]): string[] {
  const out: string[] = [];
  for (let i = 0; i < list.length; i++) {
    out.push(ResUtils.text(context, list[i]));
  }
  return out;
}

/**
 * 把「以 `|` 分隔的一组别名」拆开并归一化。
 * 归一化（大小写 / 全角 / 标点 / 括号内容 / 单位词）统一走 LooseParse.normalizeKey，
 * 保证「别名」与「外部文件表头」在**同一套归一规则**下比对。
 */
function splitAliases(raw: string): string[] {
  const parts: string[] = raw.split(ImportSlot.ALIAS_SEP);
  const out: string[] = [];
  for (let i = 0; i < parts.length; i++) {
    const key: string = LooseParse.normalizeKey(parts[i]);
    if (key.length > 0) {
      out.push(key);
    }
  }
  return out;
}

/** 词表工厂：页面在需要导入 / 导出 / 生成报告 / 重建提醒时各调用一次 */
export class VocabFactory {
  static csv(context: common.UIAbilityContext): CsvVocab {
    return {
      bpHeaders: resolveAll(context, CsvHeaderRes.BP),
      medHeaders: resolveAll(context, CsvHeaderRes.MED),
      planHeaders: resolveAll(context, CsvHeaderRes.PLAN),
      slotSeparator: ResUtils.text(context, CsvSlot.SEPARATOR),
      periodMorning: ResUtils.text(context, $r('app.string.period_morning')),
      periodForenoon: ResUtils.text(context, $r('app.string.period_forenoon')),
      periodAfternoon: ResUtils.text(context, $r('app.string.period_afternoon')),
      periodNight: ResUtils.text(context, $r('app.string.period_night')),
      periodOther: ResUtils.text(context, $r('app.string.period_other')),
      statusTaken: ResUtils.text(context, CsvStatusRes.TAKEN),
      statusTakenMakeup: ResUtils.text(context, CsvStatusRes.TAKEN_MAKEUP),
      statusSkipped: ResUtils.text(context, CsvStatusRes.SKIPPED),
      statusMissed: ResUtils.text(context, CsvStatusRes.MISSED),
      statusPending: ResUtils.text(context, CsvStatusRes.PENDING)
    };
  }

  static report(context: common.UIAbilityContext): ReportVocab {
    return {
      titleWeek: ResUtils.text(context, ReportTextRes.TITLE_WEEK),
      titleMonth: ResUtils.text(context, ReportTextRes.TITLE_MONTH),
      titleCustom: ResUtils.text(context, ReportTextRes.TITLE_CUSTOM),
      watermarkSuffix: ResUtils.text(context, ReportTextRes.WATERMARK_SUFFIX),
      separator: ResUtils.text(context, ReportTextRes.WATERMARK_SEP)
    };
  }

  static reminder(context: common.UIAbilityContext): ReminderVocab {
    return {
      title: ResUtils.text(context, ReminderTextRes.TITLE),
      separator: ResUtils.text(context, ReminderTextRes.SEPARATOR),
      expiredContent: ResUtils.text(context, ReminderTextRes.EXPIRED),
      snoozeContent: ResUtils.text(context, ReminderTextRes.SNOOZE),
      actionClose: ResUtils.text(context, ReminderTextRes.ACTION_CLOSE)
    };
  }

  /**
   * 外部来源导入词表（v1.4）。
   * 数组下标 = ColRole 枚举值，故下标 0 用空占位，长度恒为 `1 + ImportAliasRes.ORDER.length`。
   */
  static imp(context: common.UIAbilityContext): ImportVocab {
    const roleNames: string[] = [''];
    const names: string[] = splitAliases(ResUtils.text(context, ImportAliasRes.ROLE_NAMES));
    for (let i = 0; i < names.length; i++) {
      roleNames.push(names[i]);
    }

    const roleAliases: string[][] = [[]];
    for (let i = 0; i < ImportAliasRes.ORDER.length; i++) {
      roleAliases.push(splitAliases(ResUtils.text(context, ImportAliasRes.ORDER[i])));
    }

    return {
      roleNames: roleNames,
      roleAliases: roleAliases,
      statusTaken: splitAliases(ResUtils.text(context, ImportAliasRes.STATUS_TAKEN)),
      statusSkipped: splitAliases(ResUtils.text(context, ImportAliasRes.STATUS_SKIPPED)),
      statusMissed: splitAliases(ResUtils.text(context, ImportAliasRes.STATUS_MISSED)),
      statusPending: splitAliases(ResUtils.text(context, ImportAliasRes.STATUS_PENDING)),
      statusMakeup: splitAliases(ResUtils.text(context, ImportAliasRes.STATUS_MAKEUP))
    };
  }

  /** 免责声明全文（报告底部、首启弹窗、关于页共用） */
  static disclaimerFull(context: common.UIAbilityContext): string {
    return ResUtils.text(context, Disclaimers.FULL);
  }
}
