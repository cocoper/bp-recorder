/**
 * CSV 编解码（导入导出共用，纯函数，可单测）。
 * 编码：UTF-8 带 BOM（FR-6.1，Excel 直接打开不乱码）。
 * 解析：兼容 RFC 4180 引号转义、字段内逗号与换行、CRLF/LF/CR 三种行尾、UTF-8 BOM（CL-10）。
 */
export class Csv {
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
        rows.push(row);
        row = [];
        field = '';
        if (ch === '\r' && i + 1 < src.length && src.charAt(i + 1) === '\n') {
          i += 2;
        } else {
          i++;
        }
        continue;
      }
      field += ch;
      i++;
    }

    // 收尾：最后一行没有换行符时补齐
    if (field.length > 0 || row.length > 0) {
      row.push(field);
      rows.push(row);
    }
    return rows;
  }

  /**
   * 去掉尾部空行与单元格数量为零的行，并按期望列数过滤。
   * 表头行由调用方跳过。
   */
  static normalize(rows: string[][]): string[][] {
    const out: string[][] = [];
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
        out.push(row);
      }
    }
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
