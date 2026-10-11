import { GradeLevel, GradeStandard, Period, ReminderMode } from '../model/Types';

/** 录入字段取值范围（FR-1.1 / CL-2 逐项校验） */
export class BpLimits {
  static readonly SYSTOLIC_MIN: number = 40;
  static readonly SYSTOLIC_MAX: number = 300;
  static readonly DIASTOLIC_MIN: number = 30;
  static readonly DIASTOLIC_MAX: number = 200;
  static readonly HEART_RATE_MIN: number = 30;
  static readonly HEART_RATE_MAX: number = 220;
  static readonly NOTE_MAX_LEN: number = 100;
}

/** 药品与计划字段限制（FR-8.1 / FR-8.2 / CL-8） */
export class MedLimits {
  static readonly NAME_MAX_LEN: number = 30;
  static readonly DOSAGE_MAX_LEN: number = 30;
  static readonly NOTE_MAX_LEN: number = 100;
  static readonly MIN_SLOTS: number = 1;
  static readonly MAX_SLOTS: number = 4;
  /** 漏服判定宽限期：计划时间 + 2h（§3.4 / FR-9.4） */
  static readonly MISS_GRACE_MS: number = 2 * 60 * 60 * 1000;
  /** 打卡记录预生成滚动窗口天数（§3.1） */
  static readonly PRE_GEN_DAYS: number = 7;
}

/** 分级阈值规格。收缩压与舒张压各判一级，取较高者（§3.2）。 */
export interface GradeSpec {
  /** 正常：收缩 < normalSysMax 且 舒张 < normalDiaMax */
  normalSysMax: number;
  normalDiaMax: number;
  /** 正常高值上界（含） */
  highNormalSysMax: number;
  highNormalDiaMax: number;
  /** 1 级上界（含） */
  grade1SysMax: number;
  grade1DiaMax: number;
  /** 2 级上界（含） */
  grade2SysMax: number;
  grade2DiaMax: number;
  /** 3 级下界（含） */
  severeSys: number;
  severeDia: number;
}

/**
 * 诊断分级阈值表（唯一）。
 *
 * v1.3 起（审查意见 P0-2 / 决策 D1）：**分级只有这一套表**。
 * 依据《中国高血压防治指南（2024 年修订版）》的**诊室血压**分类标准 ——
 * 它是唯一有出处、能给出「正常 / 正常高值 / 1 级 / 2 级 / 3 级」名称的表。
 *
 * v1.2 的「家庭自测标准：阈值整体下移 5 mmHg」并非指南给出的分级表（属自创规则），
 * 已删除。家庭自测界值 135/85 仅作为「测量场景阈值」存在，用于图表参考线与趋势预警，
 * 见 AppConst.REF_HOME_*。因此同一条记录的分级名与色标**不随任何设置变化**。
 */
export class GradeSpecs {
  static readonly CN_GUIDELINE: GradeSpec = {
    normalSysMax: 120,
    normalDiaMax: 80,
    highNormalSysMax: 139,
    highNormalDiaMax: 89,
    grade1SysMax: 159,
    grade1DiaMax: 99,
    grade2SysMax: 179,
    grade2DiaMax: 109,
    severeSys: 180,
    severeDia: 110
  };

}

/** 图表与列表通用常量 */
export class AppConst {
  /** 列表分页每页条数（FR-2.3） */
  static readonly PAGE_SIZE: number = 20;
  /** 图表 Y 轴最小跨度下限 / 上限（§5.3 绘制要求） */
  static readonly CHART_Y_MIN: number = 40;
  static readonly CHART_Y_MAX: number = 200;

  /**
   * 图表参考线：诊室血压（FR-3.2）。
   * 同时是「参考口径」的诊室选项阈值，也是异常清单判定线（FR-10.2 板块 7）。
   */
  static readonly REF_CLINIC_SYS: number = 140;
  static readonly REF_CLINIC_DIA: number = 90;
  /**
   * 图表参考线 + 趋势预警阈值：家庭自测界值（FR-3.2 / FR-5.3）。
   * 本 App 数据 100% 为居家自测（§1.2），趋势预警固定取此口径，
   * **不随「参考口径」设置变化**（见 RefBasis 的说明）。
   */
  static readonly REF_HOME_SYS: number = 135;
  static readonly REF_HOME_DIA: number = 85;
  /** 趋势预警回看的自然天数（FR-5.3「近 7 天」） */
  static readonly WARN_LOOKBACK_DAYS: number = 7;
  /** 自定义报告周期上限天数（FR-10.1） */
  static readonly REPORT_MAX_DAYS: number = 92;
  /** 分享图/报告长图目标宽度，px（FR-11.4） */
  static readonly SNAPSHOT_WIDTH: number = 1080;
  /** 分享图目标高度（FR-11.4 约 1080×810） */
  static readonly SNAPSHOT_HEIGHT: number = 810;
  /** 分享图渲染倍率，用于 1080 宽换算 */
  static readonly SNAPSHOT_SCALE: number = 3;
}

/** 参考阈值对（收缩压 / 舒张压，mmHg） */
export interface RefThreshold {
  sys: number;
  dia: number;
}

/**
 * 参考口径（设置项「参考口径」，原 FR-7.1「分级标准」）。
 *
 * v1.3 起语义收窄（决策 D1）：
 * - **不影响**任何分级判定、色标、分级名与分布统计 —— 那些固定按 GradeSpecs.CN_GUIDELINE；
 * - 只决定「图表上以哪条线为主参考线」与「参考阈值文案」的措辞。
 *
 * 因此用户切换该项时，同一条记录的分级色标**不会变化**，
 * 变化的只有图例/文案中对参考线的表述（CL-6 验收项已据此改写）。
 */
export class RefBasis {
  /** 默认参考口径：本 App 数据 100% 为居家自测（§1.2），默认取家庭自测界值 */
  static readonly DEFAULT: GradeStandard = GradeStandard.HOME_MONITOR;

  /** 口径 → 阈值对（数值唯一来源为 AppConst 的参考线常量） */
  static of(standard: GradeStandard): RefThreshold {
    if (standard === GradeStandard.HOME_MONITOR) {
      return { sys: AppConst.REF_HOME_SYS, dia: AppConst.REF_HOME_DIA };
    }
    return { sys: AppConst.REF_CLINIC_SYS, dia: AppConst.REF_CLINIC_DIA };
  }
}

/** 数据库常量 */
export class DbConst {
  static readonly NAME: string = 'bp_recorder.db';
  /**
   * 当前结构版本，写入 PRAGMA user_version。
   * v1：4 张表 + 4 条普通索引 + med_log 唯一索引
   * v2：新增「bp_record 三元组唯一」「med_plan 每药品至多一条生效计划」两条唯一索引，
   *     并在建索引前清理历史重复数据（里程碑 v1.3 审查意见 P1-4）
   */
  static readonly SCHEMA_VERSION: number = 3;
  static readonly T_BP: string = 'bp_record';
  static readonly T_MED: string = 'medication';
  static readonly T_PLAN: string = 'med_plan';
  static readonly T_LOG: string = 'med_log';
}

/** Preferences 键名 */
export class PrefKeys {
  static readonly STORE: string = 'bp_settings';
  static readonly GRADE_STANDARD: string = 'grade_standard';
  static readonly REMINDER_MODE: string = 'reminder_mode';
  static readonly DISCLAIMER_SHOWN: string = 'disclaimer_shown';
  /** 上次构建提醒时的计划签名，用于避免每次前台都重建提醒 */
  static readonly REMINDER_SIG: string = 'reminder_signature';
  /** 上次补发「今日漏服」提醒的日期（YYYY-MM-DD），避免同一天重复打扰 */
  static readonly CATCHUP_DATE: string = 'catchup_notify_date';
  /** 是否已为「有生效计划但通知未开」主动请求过一次通知授权（v1.14，每次安装至多一次） */
  static readonly NOTIFY_ASKED: string = 'notify_asked';
}

/** 通知与提醒常量 */
/** 出图与临时文件契约（审查 R15） */
export class ShareConst {
  /** 目标出图宽度（像素） */
  static readonly CAPTURE_WIDTH_PX: number = 1080;
  /** 单张位图最大像素高：超过必须分页输出 */
  static readonly CAPTURE_MAX_HEIGHT_PX: number = 8192;
  /** 本应用临时图文件名前缀（cacheDir 里只清理自己的） */
  static readonly TEMP_IMAGE_PREFIX: string = 'bp_';
  /** 临时图最长保留时间：24 小时 */
  static readonly TEMP_IMAGE_MAX_AGE_MS: number = 24 * 60 * 60 * 1000;
  /** 临时图总量上限：50 MiB */
  static readonly TEMP_IMAGE_MAX_BYTES: number = 50 * 1024 * 1024;
  /** 这个时长内创建的文件不参与「超量清理」：系统分享/打印可能还在读 */
  static readonly TEMP_IMAGE_FRESH_MS: number = 5 * 60 * 1000;
}

export class ReminderConst {
  /** 通知渠道 id */
  static readonly SLOT_ID: string = 'bp_med_reminder';
  /** 通知 id 基址，避免与代理提醒通知冲突 */
  static readonly NOTIFICATION_BASE: number = 9000;
  /** 代理提醒可用的错误码：能力未开通 */
  static readonly ERR_AGENT_NOT_ENABLED: number = 1700001;
  /** 代理提醒可用的错误码：数量超限 */
  static readonly ERR_AGENT_EXCEED_LIMIT: number = 1700002;
}

/** 分级 → 文案资源（文案全部落在资源文件，此处只做映射，CL-7） */
export class GradeText {
  static label(level: GradeLevel): Resource {
    switch (level) {
      case GradeLevel.NORMAL:
        return $r('app.string.grade_normal');
      case GradeLevel.HIGH_NORMAL:
        return $r('app.string.grade_high_normal');
      case GradeLevel.GRADE_1:
        return $r('app.string.grade_1');
      case GradeLevel.GRADE_2:
        return $r('app.string.grade_2');
      default:
        return $r('app.string.grade_3');
    }
  }

  /** 录入后即时提示文案（§3.2 提示文案模板） */
  static advice(level: GradeLevel): Resource {
    switch (level) {
      case GradeLevel.NORMAL:
        return $r('app.string.advice_normal');
      case GradeLevel.HIGH_NORMAL:
        return $r('app.string.advice_high_normal');
      case GradeLevel.GRADE_1:
        return $r('app.string.advice_grade_1');
      case GradeLevel.GRADE_2:
        return $r('app.string.advice_grade_2');
      default:
        return $r('app.string.advice_grade_3');
    }
  }
}

/** 分级 → 色标资源（FR-2.2） */
export class GradeColor {
  static of(level: GradeLevel): Resource {
    switch (level) {
      case GradeLevel.NORMAL:
        return $r('app.color.grade_normal');
      case GradeLevel.HIGH_NORMAL:
        return $r('app.color.grade_high_normal');
      case GradeLevel.GRADE_1:
        return $r('app.color.grade_1');
      case GradeLevel.GRADE_2:
        return $r('app.color.grade_2');
      default:
        return $r('app.color.grade_3');
    }
  }
}

/** 时段 → 显示名资源（§3.3） */
export class PeriodText {
  static label(period: Period): Resource {
    switch (period) {
      case Period.MORNING:
        return $r('app.string.period_morning');
      case Period.FORENOON:
        return $r('app.string.period_forenoon');
      case Period.AFTERNOON:
        return $r('app.string.period_afternoon');
      case Period.NIGHT:
        return $r('app.string.period_night');
      default:
        return $r('app.string.period_other');
    }
  }

  /** 时段选项顺序（录入页胶囊按钮） */
  static readonly ORDER: Period[] = [Period.MORNING, Period.FORENOON, Period.AFTERNOON, Period.NIGHT, Period.OTHER];
}

/** 打卡状态 → 显示名资源（§3.4） */
export class MedStatusText {
  static label(status: string): Resource {
    switch (status) {
      case 'taken':
        return $r('app.string.med_status_taken');
      case 'skipped':
        return $r('app.string.med_status_skipped');
      case 'missed':
        return $r('app.string.med_status_missed');
      default:
        return $r('app.string.med_status_pending');
    }
  }

  static color(status: string): Resource {
    switch (status) {
      case 'taken':
        return $r('app.color.med_taken');
      case 'skipped':
        return $r('app.color.med_skipped');
      case 'missed':
        return $r('app.color.med_missed');
      default:
        return $r('app.color.med_pending');
    }
  }
}

/** 提醒方式 → 显示名资源（§5.9） */
export class ReminderText {
  static label(mode: ReminderMode): Resource {
    switch (mode) {
      case ReminderMode.AGENT:
        return $r('app.string.reminder_mode_agent');
      case ReminderMode.NOTIFICATION:
        return $r('app.string.reminder_mode_notification');
      default:
        return $r('app.string.reminder_mode_denied');
    }
  }
}

/** 全局免责声明资源引用（FR-5.4 / FR-9.7 / FR-10.2 板块 9） */
export class Disclaimers {
  static readonly BP: Resource = $r('app.string.disclaimer_bp');
  static readonly MED: Resource = $r('app.string.disclaimer_med');
  static readonly FULL: Resource = $r('app.string.disclaimer_full');
  static readonly SHORT: Resource = $r('app.string.disclaimer_short');
}

/**
 * CSV 表头资源（附录 A）。
 * 注意：为满足 CL-7「代码无中文硬编码」，此处只保存 Resource 引用，
 * 实际字面量在 resources/base/element/string.json 与 zh_CN 资源中；
 * 导出时由 CsvVocabFactory 解析为字符串（见 common/CsvVocab.ets）。
 */
export class CsvHeaderRes {
  static readonly BP: Resource[] = [
    $r('app.string.csv_hdr_date'),
    $r('app.string.csv_hdr_time'),
    $r('app.string.csv_hdr_systolic'),
    $r('app.string.csv_hdr_diastolic'),
    $r('app.string.csv_hdr_heart_rate'),
    $r('app.string.csv_hdr_period'),
    $r('app.string.csv_hdr_note'),
    // v1.20（审查 R08）：精确时间戳列。旧文件没有这一列，导入时按「只有分钟精度」处理并提示。
    $r('app.string.csv_hdr_timestamp')
  ];

  static readonly MED: Resource[] = [
    $r('app.string.csv_hdr_date'),
    $r('app.string.csv_hdr_plan_time'),
    $r('app.string.csv_hdr_med_name'),
    $r('app.string.csv_hdr_dosage'),
    $r('app.string.csv_hdr_status'),
    $r('app.string.csv_hdr_taken_time'),
    $r('app.string.csv_hdr_note'),
    // v1.20（审查 R09）：精确时间列 —— 计划/打卡的完整毫秒时间戳，保证补记时间与标记无损往返
    $r('app.string.csv_hdr_plan_ts'),
    $r('app.string.csv_hdr_taken_ts'),
    // v1.20（审查 R10-c）：稳定药品 ID —— 同名不同 ID 的两条独立记录不得在恢复时被合并
    $r('app.string.csv_hdr_med_id')
  ];

  /**
   * 用药计划表头（v1.3 审查意见 P1-9 新增）。
   * 起因：原有导出只覆盖血压记录与打卡记录，药品档案与服药计划无处导出，
   * 导致「换机迁移」只闭环一半（导入打卡只会自动建**停用**档案、计划全部丢失）。
   */
  static readonly PLAN: Resource[] = [
    $r('app.string.csv_hdr_med_name'),
    $r('app.string.csv_hdr_dosage'),
    $r('app.string.csv_hdr_slot_count'),
    $r('app.string.csv_hdr_time_slots'),
    $r('app.string.csv_hdr_start_date'),
    $r('app.string.csv_hdr_end_date'),
    $r('app.string.csv_hdr_note')
  ];
}

/** 用药打卡状态文字资源（附录 A 的导入导出口径，导入时按原文比对） */
export class CsvStatusRes {
  static readonly TAKEN: Resource = $r('app.string.csv_status_taken');
  static readonly TAKEN_MAKEUP: Resource = $r('app.string.csv_status_taken_makeup');
  static readonly SKIPPED: Resource = $r('app.string.csv_status_skipped');
  static readonly MISSED: Resource = $r('app.string.csv_status_missed');
  /**
   * 「待服」是附录 A 未列出的补充状态。
   * 原因：未到计划时间的 pending 记录也必须能导出并原样回导，
   * 否则「导出→导入」将丢数据、破坏 CL-10 的往返幂等性。
   */
  static readonly PENDING: Resource = $r('app.string.csv_status_pending');
}

/** CSV 结构常量 */
export class CsvSlot {
  /** 用药计划中多个时间点的分隔符（资源化，避免代码内硬编码标点） */
  static readonly SEPARATOR: Resource = $r('app.string.csv_slot_separator');
}

/**
 * 外部来源导入：列角色别名资源。
 *
 * 背景（v1.4 新增能力）：本 App 自家导出的 CSV 列名与列序固定，
 * 但「其他地方的数据」——其他血压 App、血压计厂商软件、手写 Excel ——
 * 列名五花八门（收缩压/高压/SBP/SYS…），列序也不固定。
 *
 * 每个资源是一**组**别名，用 `|` 分隔（在代码里由 LooseParse.normalizeKey 归一后使用），
 * 这样一个字段只占一条资源、便于维护，也避免在代码里出现任何中文字面量（CL-7）。
 *
 * **顺序必须与 `service/GenericImportService.ets` 的 `ColRole` 枚举 1..17 严格一致**，
 * 由 `tools/parity` 的断言锁定。
 */
export class ImportAliasRes {
  /** 列角色显示名（同样以 `|` 分隔，顺序与 ORDER 一致，索引 0 预留给「未指定」） */
  static readonly ROLE_NAMES: Resource = $r('app.string.imp_role_names');

  static readonly ORDER: Resource[] = [
    $r('app.string.imp_alias_datetime'),
    $r('app.string.imp_alias_date'),
    $r('app.string.imp_alias_time'),
    $r('app.string.imp_alias_systolic'),
    $r('app.string.imp_alias_diastolic'),
    $r('app.string.imp_alias_bp_pair'),
    $r('app.string.imp_alias_heart_rate'),
    $r('app.string.imp_alias_period'),
    $r('app.string.imp_alias_note'),
    $r('app.string.imp_alias_med_name'),
    $r('app.string.imp_alias_dosage'),
    $r('app.string.imp_alias_status'),
    $r('app.string.imp_alias_taken_time'),
    $r('app.string.imp_alias_slots'),
    $r('app.string.imp_alias_day_count'),
    $r('app.string.imp_alias_start_date'),
    $r('app.string.imp_alias_end_date')
  ];

  /** 用药状态别名（与 CsvStatusRes 的四个状态一一对应，用于识别外部文件的写法） */
  static readonly STATUS_TAKEN: Resource = $r('app.string.imp_status_taken');
  static readonly STATUS_SKIPPED: Resource = $r('app.string.imp_status_skipped');
  static readonly STATUS_MISSED: Resource = $r('app.string.imp_status_missed');
  static readonly STATUS_PENDING: Resource = $r('app.string.imp_status_pending');
  /** 「补记」标记别名：出现即视为补记打卡 */
  static readonly STATUS_MAKEUP: Resource = $r('app.string.imp_status_makeup');
}

/** 外部来源导入：数据种类（GenericImportService.detect 的 kind 取值） */
export class ImportKind {
  static readonly BP: string = 'bp';
  static readonly MED: string = 'med';
  static readonly PLAN: string = 'plan';
  static readonly UNKNOWN: string = 'unknown';
}

/** 外部来源导入：数值单位（GenericImportService 的 unit 取值） */
export class ImportUnit {
  static readonly MMHG: string = 'mmHg';
  static readonly KPA: string = 'kPa';
}

/** CSV 解析用到的分隔符（资源化，避免代码内硬编码标点） */
export class ImportSlot {
  /** 别名组 / 状态别名组 在资源里的分隔符 */
  static readonly ALIAS_SEP: string = '|';
}

/** 报告文案资源（FR-10.2 / FR-11.2） */
export class ReportTextRes {
  static readonly TITLE_WEEK: Resource = $r('app.string.report_title_week');
  static readonly TITLE_MONTH: Resource = $r('app.string.report_title_month');
  static readonly TITLE_CUSTOM: Resource = $r('app.string.report_title_custom');
  /** 水印固定尾句：由「血压助手」生成，仅供参考 */
  static readonly WATERMARK_SUFFIX: Resource = $r('app.string.report_watermark_suffix');
  /** 水印分隔符 */
  static readonly WATERMARK_SEP: Resource = $r('app.string.report_watermark_sep');
}

/** 提醒通知文案资源（FR-9.1） */
export class ReminderTextRes {
  static readonly TITLE: Resource = $r('app.string.reminder_title');
  static readonly SEPARATOR: Resource = $r('app.string.list_separator');
  static readonly EXPIRED: Resource = $r('app.string.reminder_expired');
  static readonly SNOOZE: Resource = $r('app.string.reminder_snooze');
  static readonly ACTION_CLOSE: Resource = $r('app.string.reminder_action_close');
}

/** 报告类型 */
export class ReportKind {
  static readonly WEEK: string = 'week';
  static readonly MONTH: string = 'month';
  static readonly CUSTOM: string = 'custom';
}

/**
 * 图表配色方案（v1.5 新增）。
 *
 * 两族并存的理由：
 * - `PRINT`：固定白底深字（base 与 dark **同值**）。用于**报告页 / 打印产物** ——
 *   给医生看或打印出来时白底才合适，且必须保证「应用内预览 == 分享产物」。
 * - `THEME`：跟随深浅色主题（base 与 dark **取值不同**）。用于在手机上看图 ——
 *   深色模式下图表卡片不再是一块刺眼的白板。
 */
export class ChartScheme {
  static readonly PRINT: string = 'print';
  static readonly THEME: string = 'theme';
}
