import { Period } from '../model/Types';

/**
 * 日期时间工具（纯函数，可单测）。
 * 全部按设备本地时区计算；中国无夏令时，按毫秒数做日加减是安全的。
 */
export class DateUtils {
  static readonly MS_PER_MIN: number = 60 * 1000;
  static readonly MS_PER_HOUR: number = 60 * 60 * 1000;
  static readonly MS_PER_DAY: number = 24 * 60 * 60 * 1000;

  /** 补齐两位 */
  static pad2(v: number): string {
    return v < 10 ? `0${v}` : `${v}`;
  }

  static now(): number {
    return Date.now();
  }

  /**
   * 时段自动推断（§3.3，v1.3 修订）。
   * 区间为左闭右开：04:59→other、05:00→morning、09:00→forenoon、
   * 14:00→afternoon、18:00→night、23:59→night、00:00→other。
   *
   * v1.3 起「睡前」区间由 [18:00, 23:00) 延展为 [18:00, 24:00)
   * （审查意见 P2-7 / 决策 D3）：原区间让 23:00–23:59 测量的用户拿不到「睡前」标签，
   * 而 23 点后恰是睡前测量的常见时段；00:00–04:59 仍归「其他」。
   */
  static periodOf(ts: number): Period {
    const d: Date = new Date(ts);
    const minutes: number = d.getHours() * 60 + d.getMinutes();
    if (minutes >= 5 * 60 && minutes < 9 * 60) {
      return Period.MORNING;
    }
    if (minutes >= 9 * 60 && minutes < 14 * 60) {
      return Period.FORENOON;
    }
    if (minutes >= 14 * 60 && minutes < 18 * 60) {
      return Period.AFTERNOON;
    }
    if (minutes >= 18 * 60) {
      return Period.NIGHT;
    }
    return Period.OTHER;
  }

  /** 当日 00:00:00.000 */
  static startOfDay(ts: number): number {
    const d: Date = new Date(ts);
    d.setHours(0, 0, 0, 0);
    return d.getTime();
  }

  /** 当日 23:59:59.999 */
  static endOfDay(ts: number): number {
    const d: Date = new Date(ts);
    d.setHours(23, 59, 59, 999);
    return d.getTime();
  }

  /** 加减天数（保持时刻不变） */
  static addDays(ts: number, days: number): number {
    const d: Date = new Date(ts);
    d.setDate(d.getDate() + days);
    return d.getTime();
  }

  /** 加减月数（自动处理月末溢出） */
  static addMonths(ts: number, months: number): number {
    const d: Date = new Date(ts);
    d.setMonth(d.getMonth() + months);
    return d.getTime();
  }

  /** 所在自然周周一 00:00（周报周期起点，FR-10.1） */
  static startOfWeek(ts: number): number {
    const d: Date = new Date(DateUtils.startOfDay(ts));
    // getDay(): 0=周日 → 换算为「距本周一的天数」
    const offset: number = (d.getDay() + 6) % 7;
    d.setDate(d.getDate() - offset);
    return d.getTime();
  }

  /** 所在自然周周日 23:59:59.999 */
  static endOfWeek(ts: number): number {
    return DateUtils.endOfDay(DateUtils.addDays(DateUtils.startOfWeek(ts), 6));
  }

  /** 所在自然月 1 日 00:00（月报周期起点） */
  static startOfMonth(ts: number): number {
    const d: Date = new Date(DateUtils.startOfDay(ts));
    d.setDate(1);
    return d.getTime();
  }

  /** 所在自然月最后一日 23:59:59.999 */
  static endOfMonth(ts: number): number {
    const d: Date = new Date(DateUtils.startOfDay(ts));
    d.setDate(1);
    d.setMonth(d.getMonth() + 1);
    return d.getTime() - 1;
  }

  /** YYYY-MM-DD */
  static formatDate(ts: number): string {
    const d: Date = new Date(ts);
    return `${d.getFullYear()}-${DateUtils.pad2(d.getMonth() + 1)}-${DateUtils.pad2(d.getDate())}`;
  }

  /** YYYY.MM.DD（报告展示用） */
  static formatDateDot(ts: number): string {
    const d: Date = new Date(ts);
    return `${d.getFullYear()}.${DateUtils.pad2(d.getMonth() + 1)}.${DateUtils.pad2(d.getDate())}`;
  }

  /** MM-DD */
  static formatMonthDay(ts: number): string {
    const d: Date = new Date(ts);
    return `${DateUtils.pad2(d.getMonth() + 1)}-${DateUtils.pad2(d.getDate())}`;
  }

  /** MM.DD */
  static formatMonthDayDot(ts: number): string {
    const d: Date = new Date(ts);
    return `${DateUtils.pad2(d.getMonth() + 1)}.${DateUtils.pad2(d.getDate())}`;
  }

  /** M月D日（列表分组标题） */
  static formatDateCN(ts: number): string {
    const d: Date = new Date(ts);
    return `${d.getMonth() + 1}月${d.getDate()}日`;
  }

  /** HH:mm */
  static formatTime(ts: number): string {
    const d: Date = new Date(ts);
    return `${DateUtils.pad2(d.getHours())}:${DateUtils.pad2(d.getMinutes())}`;
  }

  /** YYYY-MM-DD HH:mm */
  static formatDateTime(ts: number): string {
    return `${DateUtils.formatDate(ts)} ${DateUtils.formatTime(ts)}`;
  }

  /** 时间戳 → 当日分钟数 */
  static minutesOfDay(ts: number): number {
    const d: Date = new Date(ts);
    return d.getHours() * 60 + d.getMinutes();
  }

  static isSameDay(a: number, b: number): boolean {
    return DateUtils.startOfDay(a) === DateUtils.startOfDay(b);
  }

  /** 是否有效 HH:mm */
  static isValidHhmm(hhmm: string): boolean {
    if (hhmm === null || hhmm === undefined || hhmm.length !== 5) {
      return false;
    }
    if (hhmm.charAt(2) !== ':') {
      return false;
    }
    const hStr: string = hhmm.substring(0, 2);
    const mStr: string = hhmm.substring(3, 5);
    if (!DateUtils.isDigits(hStr) || !DateUtils.isDigits(mStr)) {
      return false;
    }
    const h: number = Number.parseInt(hStr, 10);
    const m: number = Number.parseInt(mStr, 10);
    return h >= 0 && h <= 23 && m >= 0 && m <= 59;
  }

  static isDigits(s: string): boolean {
    if (s.length === 0) {
      return false;
    }
    for (let i = 0; i < s.length; i++) {
      const c: number = s.charCodeAt(i);
      if (c < 48 || c > 57) {
        return false;
      }
    }
    return true;
  }

  /** HH:mm → 当日分钟数；非法返回 -1 */
  static hhmmToMinutes(hhmm: string): number {
    if (!DateUtils.isValidHhmm(hhmm)) {
      return -1;
    }
    return Number.parseInt(hhmm.substring(0, 2), 10) * 60 + Number.parseInt(hhmm.substring(3, 5), 10);
  }

  /** 当日分钟数 → HH:mm */
  static minutesToHhmm(minutes: number): string {
    const m: number = ((minutes % 1440) + 1440) % 1440;
    return `${DateUtils.pad2(Math.floor(m / 60))}:${DateUtils.pad2(m % 60)}`;
  }

  /** 是否有效 YYYY-MM-DD 且真实存在（拒绝 2026-02-30） */
  static isValidDateStr(dateStr: string): boolean {
    return DateUtils.parseDate(dateStr) !== null;
  }

  /** YYYY-MM-DD → 当日 00:00 时间戳；非法返回 null */
  static parseDate(dateStr: string): number | null {
    if (dateStr === null || dateStr === undefined || dateStr.length !== 10) {
      return null;
    }
    if (dateStr.charAt(4) !== '-' || dateStr.charAt(7) !== '-') {
      return null;
    }
    const yStr: string = dateStr.substring(0, 4);
    const mStr: string = dateStr.substring(5, 7);
    const dStr: string = dateStr.substring(8, 10);
    if (!DateUtils.isDigits(yStr) || !DateUtils.isDigits(mStr) || !DateUtils.isDigits(dStr)) {
      return null;
    }
    const y: number = Number.parseInt(yStr, 10);
    const mo: number = Number.parseInt(mStr, 10);
    const da: number = Number.parseInt(dStr, 10);
    if (mo < 1 || mo > 12 || da < 1 || da > 31) {
      return null;
    }
    const d: Date = new Date(y, mo - 1, da, 0, 0, 0, 0);
    // 反向校验，拒绝 2026-02-30 一类不存在的日期
    if (d.getFullYear() !== y || d.getMonth() !== mo - 1 || d.getDate() !== da) {
      return null;
    }
    return d.getTime();
  }

  /** YYYY-MM-DD + HH:mm → 时间戳；非法返回 null */
  static parseDateTime(dateStr: string, hhmm: string): number | null {
    const dayStart: number | null = DateUtils.parseDate(dateStr);
    if (dayStart === null) {
      return null;
    }
    const minutes: number = DateUtils.hhmmToMinutes(hhmm);
    if (minutes < 0) {
      return null;
    }
    return dayStart + minutes * DateUtils.MS_PER_MIN;
  }

  /** 指定日期 + 当日分钟数 → 时间戳 */
  static atMinutesOfDay(dayTs: number, minutes: number): number {
    return DateUtils.startOfDay(dayTs) + minutes * DateUtils.MS_PER_MIN;
  }

  /** 两个时间戳之间的自然日跨度（同日为 0） */
  static diffDays(a: number, b: number): number {
    return Math.round((DateUtils.startOfDay(b) - DateUtils.startOfDay(a)) / DateUtils.MS_PER_DAY);
  }

  /** 含首尾的自然日天数：同日为 1 */
  static daysInclusive(start: number, end: number): number {
    return DateUtils.diffDays(start, end) + 1;
  }

  /** 周期展示标签：2026.09.28 – 10.04（跨年时补全年份） */
  static rangeLabel(start: number, end: number): string {
    const sy: number = new Date(start).getFullYear();
    const ey: number = new Date(end).getFullYear();
    if (sy === ey) {
      return `${DateUtils.formatDateDot(start)} – ${DateUtils.formatMonthDayDot(end)}`;
    }
    return `${DateUtils.formatDateDot(start)} – ${DateUtils.formatDateDot(end)}`;
  }

  /** 枚举区间内的每个自然日 00:00 */
  static eachDayStart(start: number, end: number): number[] {
    const result: number[] = [];
    let cursor: number = DateUtils.startOfDay(start);
    const last: number = DateUtils.startOfDay(end);
    // 上限保护：避免异常入参导致死循环（报告周期 ≤92 天，此处放宽到 400）
    let guard: number = 0;
    while (cursor <= last && guard < 400) {
      result.push(cursor);
      cursor = DateUtils.addDays(cursor, 1);
      guard++;
    }
    return result;
  }
}
