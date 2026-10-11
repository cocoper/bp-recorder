import { DateUtils } from './DateUtils';

/**
 * 宽容解析（外部来源数据导入专用，纯函数，可单测）。
 *
 * 存在的原因：本 App 自家导出的 CSV 格式固定（FR-6.1 / FR-6.4 / FR-6.9），
 * 但「别处来的」数据格式五花八门 —— 其他血压 App、血压计厂商软件、手写 Excel 表格。
 * 它们的差异集中在四处：
 *   1. 日期写法：`2026-10-06` / `2026/10/6` / `2026.10.6` / `2026年10月6日` / `20261006` / Excel 序列号；
 *   2. 时间写法：`08:30` / `8:30` / `0830` / `8时30分` / `下午3:20`；
 *   3. 日期与时间可能合并在同一列；
 *   4. 数值带单位、全角字符，或整列使用 kPa 而非 mmHg。
 *
 * 本类只做「格式宽容」，**不做任何医学判定** —— 范围与大小关系一律交回
 * `BpValidator.validateCore`，保证「导入校验规则 == 录入校验规则」。
 *
 * 刻意不做的事（避免把脏数据静默「修正」成合法数据）：
 * - 不猜没有年份的日期（`10/06` 一律判为非法）；
 * - 不猜 2 位年份（`26/10/06` 一律判为非法）；
 * - 不猜「月/日/年」还是「日/月/年」以外的含义：首段 4 位按「年-月-日」，
 *   末段 4 位时，首段 > 12 判为「日-月-年」，否则按「月-日-年」。
 */
export class LooseParse {
  /** kPa → mmHg 换算系数（1 mmHg = 0.133322 kPa） */
  static readonly KPA_TO_MMHG: number = 7.50062;

  /**
   * Excel 序列号 1 对应 1900-01-01（含 1900 闰年缺陷），因此
   * 序列号 25569 == 1970-01-01，换算时**减去**该锚点得到「距 1970-01-01 的天数」。
   */
  private static readonly EXCEL_EPOCH_OFFSET_DAYS: number = 25569;
  private static readonly MS_PER_DAY: number = 24 * 60 * 60 * 1000;

  /**
   * 单位词：出现在表头或数值尾部，解析前去掉。
   * 注意同时收录带斜杠的写法（`次/分`），否则 `72次/分` 会因残留斜杠而解析失败。
   */
  private static readonly UNIT_WORDS: string[] = [
    'mmhg', '毫米汞柱', 'mmhg柱', 'kpa', '千帕', 'bpm',
    '次/每分', '次/分钟', '次/分', '次每分', '次分', '每分钟'
  ];

  /** 日期分隔符（含中文「年月日」） */
  private static readonly DATE_SEPARATORS: string = '-/.年月日';
  /** 时间分隔符（含中文「时点分」） */
  private static readonly TIME_SEPARATORS: string = ':：时点分';

  // ───────────────────────── 字符与词归一 ─────────────────────────

  /** 全角 → 半角（数字 / 字母 / 标点 / 全角空格），`【】` 单独处理 */
  static toHalfWidth(text: string): string {
    if (text === null || text === undefined) {
      return '';
    }
    let out: string = '';
    for (let i = 0; i < text.length; i++) {
      const code: number = text.charCodeAt(i);
      if (code === 0x3000) {
        out += ' ';
      } else if (code === 0x3010) {
        out += '[';
      } else if (code === 0x3011) {
        out += ']';
      } else if (code >= 0xFF01 && code <= 0xFF5E) {
        out += String.fromCharCode(code - 0xFEE0);
      } else {
        out += text.charAt(i);
      }
    }
    return out;
  }

  /** 去掉括号及其内容（表头常把单位写在括号里，如「收缩压(mmHg)」） */
  static stripBrackets(text: string): string {
    let out: string = '';
    let depth: number = 0;
    for (let i = 0; i < text.length; i++) {
      const ch: string = text.charAt(i);
      if (ch === '(' || ch === '[' || ch === '{') {
        depth++;
        continue;
      }
      if (ch === ')' || ch === ']' || ch === '}') {
        if (depth > 0) {
          depth--;
        }
        continue;
      }
      if (depth === 0) {
        out += ch;
      }
    }
    return out;
  }

  /** 取出所有括号内的内容（部分 App 写成「128/82(96)」，括号里是心率） */
  static bracketContents(text: string): string[] {
    const out: string[] = [];
    let buf: string = '';
    let depth: number = 0;
    for (let i = 0; i < text.length; i++) {
      const ch: string = text.charAt(i);
      if (ch === '(' || ch === '[' || ch === '{') {
        depth++;
        buf = '';
        continue;
      }
      if (ch === ')' || ch === ']' || ch === '}') {
        if (depth > 0) {
          depth--;
          if (depth === 0 && buf.length > 0) {
            out.push(buf);
          }
        }
        continue;
      }
      if (depth > 0) {
        buf += ch;
      }
    }
    return out;
  }

  /** 词归一：全角转半角 → 去括号内容 → 转小写 → 去标点空白 → 去单位词。用于表头与别名的比对。 */
  static normalizeKey(text: string): string {
    let s: string = LooseParse.toHalfWidth(text === null || text === undefined ? '' : text);
    s = LooseParse.stripBrackets(s);
    s = s.toLowerCase();
    let out: string = '';
    for (let i = 0; i < s.length; i++) {
      const ch: string = s.charAt(i);
      if (LooseParse.isNoiseChar(ch)) {
        continue;
      }
      out += ch;
    }
    return LooseParse.stripUnitWords(out);
  }

  private static isNoiseChar(ch: string): boolean {
    const code: number = ch.charCodeAt(0);
    if (code <= 0x20) {
      return true;
    }
    return ' \t\n\r-_—–/\\、,，.。;；:：*#\'"+=%|~`^&()[]{}<>'.indexOf(ch) >= 0;
  }

  /** 去掉尾部/任意位置的单位词 */
  private static stripUnitWords(text: string): string {
    let out: string = text;
    for (let i = 0; i < LooseParse.UNIT_WORDS.length; i++) {
      out = LooseParse.replaceAll(out, LooseParse.UNIT_WORDS[i], '');
    }
    return out;
  }

  private static replaceAll(text: string, find: string, who: string): string {
    if (find.length === 0 || text.indexOf(find) < 0) {
      return text;
    }
    let out: string = '';
    let i: number = 0;
    while (i < text.length) {
      if (text.substr(i, find.length) === find) {
        out += who;
        i += find.length;
      } else {
        out += text.charAt(i);
        i++;
      }
    }
    return out;
  }

  // ───────────────────────── 数值 ─────────────────────────

  /** 去除数值中的单位、空格与千分位逗号，便于统一解析 */
  private static cleanNumber(text: string): string {
    let s: string = LooseParse.toHalfWidth(text === null || text === undefined ? '' : text).trim();
    if (s.length === 0) {
      return '';
    }
    s = LooseParse.replaceAll(s, ',', '');
    s = LooseParse.replaceAll(s, ' ', '');
    s = s.toLowerCase();
    s = LooseParse.stripUnitWords(s);
    return s;
  }

  private static isSignedDigits(s: string): boolean {
    if (s.length === 0) {
      return false;
    }
    let i: number = 0;
    if (s.charAt(0) === '+' || s.charAt(0) === '-') {
      i = 1;
    }
    if (i >= s.length) {
      return false;
    }
    return DateUtils.isDigits(s.substring(i));
  }

  private static isSignedDecimal(s: string): boolean {
    if (s.length === 0) {
      return false;
    }
    let i: number = 0;
    if (s.charAt(0) === '+' || s.charAt(0) === '-') {
      i = 1;
    }
    const body: string = s.substring(i);
    if (body.length === 0) {
      return false;
    }
    if (body.indexOf('.') < 0) {
      return DateUtils.isDigits(body);
    }
    const dot: number = body.indexOf('.');
    if (body.indexOf('.', dot + 1) >= 0) {
      return false;
    }
    const head: string = body.substring(0, dot);
    const tail: string = body.substring(dot + 1);
    if (head.length === 0 && tail.length === 0) {
      return false;
    }
    if (head.length > 0 && !DateUtils.isDigits(head)) {
      return false;
    }
    return tail.length === 0 || DateUtils.isDigits(tail);
  }

  /** 宽容整数：允许单位、全角、千分位、`.0` 结尾；含有效小数位时返回 null（由 parseFloatLoose 处理） */
  static parseIntLoose(text: string): number | null {
    const s: string = LooseParse.cleanNumber(text);
    if (s.length === 0) {
      return null;
    }
    if (LooseParse.isSignedDigits(s)) {
      return Number.parseInt(s, 10);
    }
    if (LooseParse.isSignedDecimal(s)) {
      const v: number = Number.parseFloat(s);
      if (Number.isNaN(v)) {
        return null;
      }
      if (v === Math.floor(v)) {
        return v;
      }
      return null;
    }
    return null;
  }

  /** 宽容小数：允许单位、全角、千分位 */
  static parseFloatLoose(text: string): number | null {
    const s: string = LooseParse.cleanNumber(text);
    if (s.length === 0 || !LooseParse.isSignedDecimal(s)) {
      return null;
    }
    const v: number = Number.parseFloat(s);
    return Number.isNaN(v) ? null : v;
  }

  // ───────────────────────── 日期 / 时间 ─────────────────────────

  /**
   * 数字串切分：只按「日期分隔符」切，非数字且非日期分隔符的字符视为终止。
   * `2026-10-06` → ['2026','10','06']；`2026年10月6日` → ['2026','10','6']
   */
  private static dateGroups(text: string): string[] {
    const groups: string[] = [];
    let buf: string = '';
    for (let i = 0; i < text.length; i++) {
      const ch: string = text.charAt(i);
      if (ch >= '0' && ch <= '9') {
        buf += ch;
        continue;
      }
      if (LooseParse.DATE_SEPARATORS.indexOf(ch) >= 0) {
        if (buf.length > 0) {
          groups.push(buf);
          buf = '';
        }
        continue;
      }
      // 其他字符（含时间分隔符）一律终止
      if (buf.length > 0) {
        groups.push(buf);
      }
      return groups;
    }
    if (buf.length > 0) {
      groups.push(buf);
    }
    return groups;
  }

  /** 纯数字串 → 时间戳：Unix 秒 / Unix 毫秒 / Excel 序列号（仅这三种，不做其他猜测） */
  static parseEpochOrSerial(text: string): number | null {
    const s: string = text.trim();
    if (s.length === 0 || !DateUtils.isDigits(s)) {
      return null;
    }
    const n: number = Number.parseInt(s, 10);
    if (s.length === 10 && n >= 946684800 && n <= 4102444800) {
      return n * 1000;
    }
    if (s.length === 13 && n >= 946684800000 && n <= 4102444800000) {
      return n;
    }
    // Excel 序列号：约 1954-10-03（20000）～ 2119-02-18（80000）
    if (s.length >= 5 && s.length <= 7 && n >= 20000 && n <= 80000) {
      return LooseParse.civilFromExcelSerial(n);
    }
    return null;
  }

  /** Excel 序列号 → 当日 00:00 时间戳（走 UTC 取年月日，结果与设备时区无关） */
  static civilFromExcelSerial(serial: number): number {
    const days: number = serial - LooseParse.EXCEL_EPOCH_OFFSET_DAYS;
    const utc: Date = new Date(days * LooseParse.MS_PER_DAY);
    return new Date(utc.getUTCFullYear(), utc.getUTCMonth(), utc.getUTCDate(), 0, 0, 0, 0).getTime();
  }

  /** 年月日 → 时间戳（反向校验，拒绝 2026-02-30） */
  private static buildDate(y: number, mo: number, da: number): number | null {
    if (y < 1900 || y > 2200 || mo < 1 || mo > 12 || da < 1 || da > 31) {
      return null;
    }
    const d: Date = new Date(y, mo - 1, da, 0, 0, 0, 0);
    if (d.getFullYear() !== y || d.getMonth() !== mo - 1 || d.getDate() !== da) {
      return null;
    }
    const ms: number = d.getTime();
    return Number.isNaN(ms) ? null : ms;
  }

  /**
   * 仅解析**日期部分**（不含时间）→ 当日 00:00；失败返回 null。
   * 支持的写法见类注释；`2026-10-06 08:30` 这类混合文本请用 parseDateTimeLoose。
   */
  static parseDateLoose(text: string): number | null {
    if (text === null || text === undefined) {
      return null;
    }
    const raw: string = LooseParse.toHalfWidth(text).trim();
    if (raw.length === 0) {
      return null;
    }

    const serial: number | null = LooseParse.parseEpochOrSerial(raw);
    if (serial !== null) {
      return DateUtils.startOfDay(serial);
    }

    const g: string[] = LooseParse.dateGroups(raw);
    if (g.length === 1) {
      // 紧凑写法：YYYYMMDD / YYYYMMDDHHmmss
      const s: string = g[0];
      if (s.length === 8) {
        return LooseParse.buildDate(
          Number.parseInt(s.substring(0, 4), 10),
          Number.parseInt(s.substring(4, 6), 10),
          Number.parseInt(s.substring(6, 8), 10));
      }
      if (s.length === 14) {
        return LooseParse.buildDate(
          Number.parseInt(s.substring(0, 4), 10),
          Number.parseInt(s.substring(4, 6), 10),
          Number.parseInt(s.substring(6, 8), 10));
      }
      return null;
    }
    if (g.length !== 3) {
      return null;
    }

    if (g[0].length === 4) {
      return LooseParse.buildDate(
        Number.parseInt(g[0], 10), Number.parseInt(g[1], 10), Number.parseInt(g[2], 10));
    }
    if (g[2].length === 4) {
      const a: number = Number.parseInt(g[0], 10);
      const b: number = Number.parseInt(g[1], 10);
      const y: number = Number.parseInt(g[2], 10);
      // 首段 > 12 只能是「日」，故为 日-月-年；否则按国际常见的 月-日-年
      if (a > 12 && b <= 12) {
        return LooseParse.buildDate(y, b, a);
      }
      return LooseParse.buildDate(y, a, b);
    }
    // 无 4 位年份（含 2 位年份）：不猜，判为非法
    return null;
  }

  /** 是否含时间部分（用于区分「纯日期列」与「日期时间列」） */
  static hasTimePart(text: string): boolean {
    if (text === null || text === undefined) {
      return false;
    }
    const raw: string = LooseParse.toHalfWidth(text);
    for (let i = 0; i < raw.length; i++) {
      if (raw.charAt(i) === ':') {
        return true;
      }
      if (raw.charAt(i) === '时' || raw.charAt(i) === '点') {
        return true;
      }
    }
    // 空格之后的纯数字时间，如「2026-10-06 0830」
    const tokens: string[] = raw.trim().split(' ');
    if (tokens.length >= 2) {
      const last: string = tokens[tokens.length - 1];
      if ((last.length === 3 || last.length === 4) && DateUtils.isDigits(last)) {
        return true;
      }
    }
    return false;
  }

  /**
   * 是否为「纯时间」写法（不含日期）。
   *
   * 刻意收紧：紧凑数字形式只在 4 位且「时分均合法」（如 `0830`）时认可。
   * 目的：`128`、`830` 这类既可能是心率/血压又可能是时间的值，**不**被自动判为时间列，
   * 而是留给用户手动指定列对应关系。解析侧（minutesLoose）本身是宽容的，
   * 因此「用户指定后能正常解析」与「自动识别保守」两件事互不冲突。
   */
  static isTimeToken(text: string): boolean {
    if (text === null || text === undefined) {
      return false;
    }
    const raw: string = LooseParse.toHalfWidth(text).trim();
    if (raw.length === 0) {
      return false;
    }
    if (raw.indexOf(':') >= 0 || raw.indexOf('时') >= 0 || raw.indexOf('点') >= 0) {
      return true;
    }
    const tokens: string[] = raw.split(' ');
    for (let i = 0; i < tokens.length; i++) {
      const t: string = tokens[i];
      if (t.length === 4 && DateUtils.isDigits(t)) {
        const h: number = Number.parseInt(t.substring(0, 2), 10);
        const m: number = Number.parseInt(t.substring(2, 4), 10);
        if (h <= 23 && m <= 59) {
          return true;
        }
      }
    }
    return false;
  }

  /**
   * 宽容时间 → 当日分钟数；失败返回 -1。
   * 支持 `08:30` / `8:30` / `08:30:00` / `0830` / `830` / `8时30分` / `下午3:20` / `PM 3:20`。
   */
  static minutesLoose(text: string): number {
    if (text === null || text === undefined) {
      return -1;
    }
    const raw: string = LooseParse.toHalfWidth(text).trim();
    if (raw.length === 0) {
      return -1;
    }

    const lower: string = raw.toLowerCase();
    let pm: boolean = lower.indexOf('下午') >= 0 || lower.indexOf('晚上') >= 0
      || lower.indexOf('傍晚') >= 0 || lower.indexOf('中午') >= 0 || lower.indexOf('pm') >= 0;
    const am: boolean = lower.indexOf('上午') >= 0 || lower.indexOf('早上') >= 0
      || lower.indexOf('凌晨') >= 0 || lower.indexOf('am') >= 0;

    let hour: number = -1;
    let minute: number = 0;

    // 优先匹配「H:M」「H时M」「H点M」
    let hourStr: string = '';
    let minuteStr: string = '';
    let sawSeparator: boolean = false;
    for (let i = 0; i < raw.length; i++) {
      const ch: string = raw.charAt(i);
      if (LooseParse.TIME_SEPARATORS.indexOf(ch) >= 0 && ch !== '分') {
        // 第二次遇到时间分隔符（`08:30:00` 的秒位）即停止，避免把秒并进分钟
        if (sawSeparator) {
          break;
        }
        sawSeparator = true;
        continue;
      }
      if (!DateUtils.isDigits(ch)) {
        if (sawSeparator && hourStr.length > 0) {
          break;
        }
        continue;
      }
      if (!sawSeparator) {
        hourStr += ch;
      } else {
        minuteStr += ch;
      }
    }
    if (sawSeparator && hourStr.length > 0 && minuteStr.length > 0) {
      hour = Number.parseInt(hourStr, 10);
      minute = Number.parseInt(minuteStr, 10);
    } else {
      // 紧凑数字：0830 → 08:30；830 → 8:30；单/双位数字视为整点
      let digits: string = '';
      for (let i = 0; i < raw.length; i++) {
        const ch: string = raw.charAt(i);
        if (DateUtils.isDigits(ch)) {
          digits += ch;
        } else if (ch === ' ') {
          continue;
        } else {
          digits = '';
          break;
        }
      }
      if (digits.length === 4) {
        hour = Number.parseInt(digits.substring(0, 2), 10);
        minute = Number.parseInt(digits.substring(2, 4), 10);
      } else if (digits.length === 3) {
        hour = Number.parseInt(digits.substring(0, 1), 10);
        minute = Number.parseInt(digits.substring(1, 3), 10);
      } else if (digits.length === 1 || digits.length === 2) {
        hour = Number.parseInt(digits, 10);
        minute = 0;
      } else {
        return -1;
      }
    }

    if (pm && hour < 12) {
      hour += 12;
    } else if (am && hour === 12) {
      hour = 0;
    }
    if (hour < 0 || hour > 23 || minute < 0 || minute > 59) {
      return -1;
    }
    return hour * 60 + minute;
  }

  /** 「日期 [时间]」混合文本 → 时间戳；只有日期时按 00:00；失败返回 null */
  static parseDateTimeLoose(text: string): number | null {
    if (text === null || text === undefined) {
      return null;
    }
    const raw: string = LooseParse.toHalfWidth(text).trim();
    if (raw.length === 0) {
      return null;
    }

    const split: string[] = LooseParse.splitDateTime(raw);
    const datePart: string = split[0];
    const timePart: string = split[1];

    const day: number | null = LooseParse.parseDateLoose(datePart);
    if (day === null) {
      return null;
    }
    if (timePart.length === 0) {
      return day;
    }
    const minutes: number = LooseParse.minutesLoose(timePart);
    if (minutes < 0) {
      return null;
    }
    return day + minutes * DateUtils.MS_PER_MIN;
  }

  /** 拆分「日期」与「时间」两段；返回 [日期, 时间]，时间缺失时为空串 */
  static splitDateTime(raw: string): string[] {
    // ISO：2026-10-06T08:30
    const tPos: number = raw.indexOf('T');
    if (tPos > 0 && raw.indexOf('-') >= 0) {
      return [raw.substring(0, tPos), raw.substring(tPos + 1)];
    }

    // 中文：2026年10月6日8时30分
    const hourMark: number = raw.indexOf('时');
    if (hourMark > 0) {
      let start: number = hourMark;
      while (start > 0) {
        const ch: string = raw.charAt(start - 1);
        if (DateUtils.isDigits(ch)) {
          start--;
        } else {
          break;
        }
      }
      if (start < hourMark) {
        return [raw.substring(0, start), raw.substring(start)];
      }
    }

    // 空格分隔：2026-10-06 08:30
    const tokens: string[] = raw.split(' ');
    if (tokens.length >= 2) {
      let datePart: string = tokens[0];
      let timeStart: number = 1;
      // 日期可能被空格拆成两段（如「2026-10-06 08:30」的日期只有一段；
      // 但「2026/10/6 8:30」也只有一段），此处保守：只把首段当日期
      let timePart: string = '';
      for (let i = timeStart; i < tokens.length; i++) {
        if (tokens[i].length === 0) {
          continue;
        }
        timePart = timePart.length === 0 ? tokens[i] : `${timePart} ${tokens[i]}`;
      }
      return [datePart, timePart];
    }

    return [raw, ''];
  }

  // ───────────────────────── 血压组合值 ─────────────────────────

  /**
   * 「128/82」「128 / 82 mmHg」「128/82(96)」「16.9/10.7」→ 收缩压 / 舒张压
   * （括号内容若像心率则一并取出）。
   *
   * 量级校验（用于排除「10/6」这类分数或日期片段）：
   * - mmHg 收缩压 ≥ 60；
   * - kPa 收缩压约为 10–35，且必定带小数。
   * 两条满足其一才认为是血压组合值。
   *
   * 仍然**不做大小关系判定**（收缩压 > 舒张压交回 BpValidator），
   * 以便把「写反了」的数据如实报为错误行，而不是静默对调。
   */
  static parseBpPair(text: string): BpPairValue | null {
    if (text === null || text === undefined) {
      return null;
    }
    const raw: string = LooseParse.toHalfWidth(text).trim();
    if (raw.length === 0) {
      return null;
    }

    let heartRate: number | null = null;
    const inner: string[] = LooseParse.bracketContents(raw);
    for (let i = 0; i < inner.length; i++) {
      const hr: number | null = LooseParse.parseIntLoose(inner[i]);
      if (hr !== null && hr >= 20 && hr <= 250) {
        heartRate = hr;
        break;
      }
    }

    const main: string = LooseParse.cleanNumber(LooseParse.stripBrackets(raw));
    if (main.length === 0) {
      return null;
    }
    // 只有唯一一个分隔符、两侧都是纯数值时才认可
    let slash: number = -1;
    let slashCount: number = 0;
    for (let i = 0; i < main.length; i++) {
      const ch: string = main.charAt(i);
      if (ch === '/' || ch === '\\' || ch === '-' || ch === '~') {
        slashCount++;
        slash = i;
      }
    }
    if (slashCount !== 1) {
      return null;
    }
    const left: string = main.substring(0, slash);
    const right: string = main.substring(slash + 1);
    const a: number | null = LooseParse.parseFloatLoose(left);
    const b: number | null = LooseParse.parseFloatLoose(right);
    if (a === null || b === null) {
      return null;
    }
    const decimal: boolean = left.indexOf('.') >= 0 || right.indexOf('.') >= 0;
    const magnitudeOk: boolean = a >= 60 || (a < 45 && decimal);
    if (!magnitudeOk) {
      return null;
    }
    if (a < 8 || a > 400 || b < 4 || b > 300) {
      return null;
    }
    return { systolic: a, diastolic: b, heartRate: heartRate, decimal: decimal };
  }
}

/** 「128/82(96)」的拆分结果 */
export interface BpPairValue {
  /** 收缩压原值（kPa 列会带小数，由调用方按单位决定是否换算与取整） */
  systolic: number;
  diastolic: number;
  /** 括号内的心率，无则 null */
  heartRate: number | null;
  /** 原值含小数点（提示调用方：可能是 kPa，或导出方记录了小数） */
  decimal: boolean;
}
