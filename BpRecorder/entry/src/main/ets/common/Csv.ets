/**
 * CSV 编解码（导入导出共用，纯函数，可单测）。
 * 编码：UTF-8 带 BOM（FR-6.1，Excel 直接打开不乱码）。
 * 解析：兼容 RFC 4180 引号转义、字段内逗号与换行、CRLF/LF/CR 三种行尾、UTF-8 BOM（CL-10）。
 */
/**
 * CSV 结构问题（审查 R14）：解析时发现的行级问题。
 * 导入器必须据此**拒绝整行**，而不是把被合并的后续内容当成一条合法备注。
 */
export interface CsvRowIssue {
  /** 行下标（与 Csv.normalize 之后的结果对齐） */
  index: number;
  /** 'unclosedQuote' | 'fieldTooLong' | 'tooManyColumns' */
  kind: string;
  /** 物理行号（1 起，含引号内换行的真实行） */
  physicalLine: number;
  detail: string;
}

export class Csv {
  /** 最近一次 parse 的结构问题（由 normalize 同步过滤，索引与返回结果对齐） */
  private static issues: CsvRowIssue[] = [];
  /** 最近一次 parse 每行的物理行号（与返回结果对齐） */
  private static lines: number[] = [];
  /** 容量契约（审查 R14.2）：防失控的工程上限，不替代更严格的业务文本限制 */
  static readonly MAX_FIELD_LEN: number = 4096;
  static readonly MAX_COLUMNS: number = 64;
  static readonly MAX_ROWS: number = 50000;
  static readonly MAX_BYTES: number = 10 * 1024 * 1024;

  /** 最近一次解析的结构问题（索引与 normalize 结果对齐） */
  static rowIssues(): CsvRowIssue[] {
    return Csv.issues;
  }

  /** 取某一行的结构问题；没有则返回 null */
  static issueAt(index: number): CsvRowIssue | null {
    for (let i = 0; i < Csv.issues.length; i++) {
      if (Csv.issues[i].index === index) {
        return Csv.issues[i];
      }
    }
    return null;
  }

  /** 某一行的物理行号（1 起）；未知返回 index+1 */
  static physicalLineOf(index: number): number {
    return index >= 0 && index < Csv.lines.length ? Csv.lines[index] : index + 1;
  }

  static readonly BOM: string = '\uFEFF';
  static readonly CRLF: string = '\r\n';

  /** 单个字段转义：含逗号/引号/换行时用双引号包裹，内部引号翻倍 */
  static escapeField(value: string): string {
    if (value === null || value === undefined || value.length === 0) {
      return '';
    }
    let needQuote: boolean = false;
    for (let i = 0; i < value.length; i++) {
      const c: string = value.charAt(i);
      if (c === ',' || c === '"' || c === '\n' || c === '\r') {
        needQuote = true;
        break;
      }
    }
    if (!needQuote) {
      return value;
    }
    let out: string = '"';
    for (let i = 0; i < value.length; i++) {
      const c: string = value.charAt(i);
      if (c === '"') {
        out += '""';
      } else {
        out += c;
      }
    }
    return `${out}"`;
  }

  /** 二维字符串数组 → CSV 文本 */
  static stringify(rows: string[][], withBom: boolean): string {
    let out: string = withBom ? Csv.BOM : '';
    for (let i = 0; i < rows.length; i++) {
      const row: string[] = rows[i];
      for (let j = 0; j < row.length; j++) {
        if (j > 0) {
          out += ',';
        }
        out += Csv.escapeField(row[j]);
      }
      out += Csv.CRLF;
    }
    return out;
  }

  /**
   * CSV 文本 → 二维字符串数组。
   * 逐字符状态机，不依赖正则，避免不同引号形态下的解析歧义。
   */
  static parse(text: string): string[][] {
    let src: string = text === null || text === undefined ? '' : text;
    // 剥离 UTF-8 BOM
    if (src.length > 0 && src.charCodeAt(0) === 0xFEFF) {
      src = src.substring(1);
    }

    const rows: string[][] = [];
    let row: string[] = [];
    let field: string = '';
    let inQuotes: boolean = false;
    let i: number = 0;
    // 审查 R14：记录每行的物理行号（引号内换行也照实计数）与行级结构问题
    const lines: number[] = [];
    const issues: CsvRowIssue[] = [];
    let physicalLine: number = 1;
    let rowStartLine: number = 1;
    let rowFlagged: boolean = false;
    const flagRow = (kind: string, detail: string): void => {
      if (!rowFlagged) {
        rowFlagged = true;
        issues.push({ index: rows.length, kind: kind, physicalLine: rowStartLine, detail: detail });
      }
    };

    while (i < src.length) {
      const ch: string = src.charAt(i);

      if (inQuotes) {
        if (ch === '"') {
          if (i + 1 < src.length && src.charAt(i + 1) === '"') {
            field += '"';
            i += 2;
            continue;
          }
          inQuotes = false;
          i++;
          continue;
        }
        field += ch;
        i++;
        continue;
      }

      if (ch === '"') {
        inQuotes = true;
        i++;
        continue;
      }
      if (ch === ',') {
        row.push(field);
        field = '';
        i++;
        continue;
      }
      if (ch === '\r' || ch === '\n') {
        row.push(field);
        lines.push(rowStartLine);
        if (row.length > Csv.MAX_COLUMNS) {
          flagRow('tooManyColumns', `${row.length}`);
        }
        rows.push(row);
        row = [];
        field = '';
        rowFlagged = false;
        if (ch === '\r' && i + 1 < src.length && src.charAt(i + 1) === '\n') {
          i += 2;
          physicalLine++;
        } else {
          i++;
          physicalLine++;
        }
        rowStartLine = physicalLine;
        continue;
      }
      if (field.length < Csv.MAX_FIELD_LEN + 1) {
        field += ch;
      } else if (!rowFlagged) {
        flagRow('fieldTooLong', `${field.length}+`);
      }
      i++;
    }

    // 收尾：最后一行没有换行符时补齐
    if (field.length > 0 || row.length > 0) {
      row.push(field);
      lines.push(rowStartLine);
      if (inQuotes) {
        // 审查 R14.1：文本结束时仍在引号内 —— 结构错误，导入器必须拒绝这一行，
        // 不能把被吞掉的后续内容当成一条合法备注。
        issues.push({ index: rows.length, kind: 'unclosedQuote', physicalLine: rowStartLine, detail: field.substring(0, 40) });
      }
      if (row.length > Csv.MAX_COLUMNS) {
        issues.push({ index: rows.length, kind: 'tooManyColumns', physicalLine: rowStartLine, detail: `${row.length}` });
      }
      rows.push(row);
    }
    Csv.issues = issues;
    Csv.lines = lines;
    return rows;
  }

  /**
   * 去掉尾部空行与单元格数量为零的行，并按期望列数过滤。
   * 表头行由调用方跳过。
   */
  static normalize(rows: string[][]): string[][] {
    const out: string[][] = [];
    const keptLines: number[] = [];
    const keptIssues: CsvRowIssue[] = [];
    for (let i = 0; i < rows.length; i++) {
      const row: string[] = rows[i];
      let hasContent: boolean = false;
      for (let j = 0; j < row.length; j++) {
        if (row[j].trim().length > 0) {
          hasContent = true;
          break;
        }
      }
      if (hasContent) {
        // 同步保留原始行号与结构问题（索引改写到过滤后的位置）
        keptLines.push(Csv.lines.length > i ? Csv.lines[i] : i + 1);
        for (let k = 0; k < Csv.issues.length; k++) {
          if (Csv.issues[k].index === i) {
            const src: CsvRowIssue = Csv.issues[k];
            keptIssues.push({ index: out.length, kind: src.kind, physicalLine: src.physicalLine, detail: src.detail });
          }
        }
        out.push(row);
      }
    }
    Csv.lines = keptLines;
    Csv.issues = keptIssues;
    return out;
  }

  /** 安全取单元格（越界返回空串，避免脏 CSV 触发越界读） */
  static cell(row: string[], index: number): string {
    if (row === null || row === undefined || index < 0 || index >= row.length) {
      return '';
    }
    const v: string = row[index];
    return v === null || v === undefined ? '' : v.trim();
  }
}
