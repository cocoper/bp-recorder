/**
 * 业务枚举集中定义。
 * 所有枚举的字符串值与策划文档 §3.1 数据库字段取值严格一致，不得随意更改。
 */

/** 时段标签（对应 bp_record.period / 策划文档 §3.3） */
export enum Period {
  MORNING = 'morning',
  FORENOON = 'forenoon',
  AFTERNOON = 'afternoon',
  NIGHT = 'night',
  OTHER = 'other'
}

/** 血压分级（数值越大级别越高，便于取高者比较） */
export enum GradeLevel {
  NORMAL = 0,
  HIGH_NORMAL = 1,
  GRADE_1 = 2,
  GRADE_2 = 3,
  GRADE_3 = 4
}

/**
 * 参考口径（对应 Preferences.grade_standard）。
 *
 * v1.3 起语义变更（决策 D1）：它**不再是分级标准**，而是「参考口径」——
 * 只影响图表主参考线与参考阈值文案，不影响分级色标 / 分级名 / 分布统计。
 * 枚举名与字符串值保持不变，以免破坏已存用户偏好（Preferences 键 'grade_standard'）。
 */
export enum GradeStandard {
  /** 诊室血压口径：参考线 140/90 */
  CN_GUIDELINE = 'cn_guideline',
  /** 家庭自测口径：参考线 135/85（默认，本 App 数据的实际测量场景） */
  HOME_MONITOR = 'home_monitor'
}

/** 服药打卡状态（对应 med_log.status / 策划文档 §3.4 状态机） */
export enum MedLogStatus {
  PENDING = 'pending',
  TAKEN = 'taken',
  SKIPPED = 'skipped',
  MISSED = 'missed'
}

/** 打卡动作（用户在弹窗中的选择） */
export enum CheckInAction {
  TAKE = 'take',
  SKIP = 'skip'
}

/** 当前生效的提醒方式（设置页展示 / Preferences.reminder_mode） */
export enum ReminderMode {
  /** 系统后台代理提醒（reminderAgent），App 未启动也能触发 */
  AGENT = 'agent',
  /** 本地通知回退（NotificationKit），需 App 存活或到点后补发 */
  NOTIFICATION = 'notification',
  /** 通知权限被拒或不可用 */
  DENIED = 'denied'
}

/** 统计/图表的周期档位 */
export enum RangeDays {
  D7 = 7,
  D30 = 30,
  D90 = 90
}

/**
 * 数据库字符串 → 枚举的解析函数。
 * 集中在此处，避免各层各自写 switch 导致取值口径不一致；
 * 遇到未知取值时回退到最安全的默认值（不抛异常，保证脏数据不引发崩溃）。
 */
export function parsePeriod(value: string): Period {
  switch (value) {
    case 'morning':
      return Period.MORNING;
    case 'forenoon':
      return Period.FORENOON;
    case 'afternoon':
      return Period.AFTERNOON;
    case 'night':
      return Period.NIGHT;
    default:
      return Period.OTHER;
  }
}

export function parseGradeStandard(value: string): GradeStandard {
  return value === 'home_monitor' ? GradeStandard.HOME_MONITOR : GradeStandard.CN_GUIDELINE;
}

export function parseMedLogStatus(value: string): MedLogStatus {
  switch (value) {
    case 'taken':
      return MedLogStatus.TAKEN;
    case 'skipped':
      return MedLogStatus.SKIPPED;
    case 'missed':
      return MedLogStatus.MISSED;
    default:
      return MedLogStatus.PENDING;
  }
}

export function parseReminderMode(value: string): ReminderMode {
  switch (value) {
    case 'agent':
      return ReminderMode.AGENT;
    case 'notification':
      return ReminderMode.NOTIFICATION;
    default:
      return ReminderMode.DENIED;
  }
}
