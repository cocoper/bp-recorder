import { common } from '@kit.AbilityKit';
import { fileIo, fileUri, picker } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { Logger } from '../common/Logger';

const TAG: string = 'FileService';

/** 用户选中的文件 */
export interface PickedFile {
  uri: string;
  name: string;
}

/**
 * 文件读写（CSV 导入导出、分享/打印临时图）。
 *
 * 设计要点（NFR-5 隐私）：
 * - 选择与保存一律走系统 picker，拿到的是**一次性授权的 URI**，不申请任何持久文件权限；
 * - 临时图写在应用 cacheDir，通过 fileUri.getUriFromPath 得到可被系统分享/打印消费的 URI。
 */
export class FileService {
  /** 选择单个 CSV 文件 */
  static async pickCsv(context: common.UIAbilityContext): Promise<PickedFile | null> {
    const options: picker.DocumentSelectOptions = new picker.DocumentSelectOptions();
    options.maxSelectNumber = 1;
    options.fileSuffixFilters = ['.csv'];
    const viewPicker: picker.DocumentViewPicker = new picker.DocumentViewPicker(context);
    const uris: string[] = await viewPicker.select(options);
    if (uris === null || uris === undefined || uris.length === 0) {
      return null;
    }
    const uri: string = uris[0];
    return { uri: uri, name: FileService.baseName(uri) };
  }

  /** 选择单个文档（审查 R10：完整备份为 .json） */
  static async pickDocument(context: common.UIAbilityContext, suffix: string): Promise<PickedFile | null> {
    const options: picker.DocumentSelectOptions = new picker.DocumentSelectOptions();
    options.maxSelectNumber = 1;
    options.fileSuffixFilters = [suffix];
    const viewPicker: picker.DocumentViewPicker = new picker.DocumentViewPicker(context);
    const uris: string[] = await viewPicker.select(options);
    if (uris === null || uris === undefined || uris.length === 0) {
      return null;
    }
    const uri: string = uris[0];
    return { uri: uri, name: FileService.baseName(uri) };
  }

  /** 让用户选择保存位置与文件名，返回目标 URI；取消返回 null */
  static async pickSaveTarget(context: common.UIAbilityContext, fileName: string): Promise<string | null> {
    const options: picker.DocumentSaveOptions = new picker.DocumentSaveOptions();
    options.newFileNames = [fileName];
    options.fileSuffixChoices = ['.csv'];
    const viewPicker: picker.DocumentViewPicker = new picker.DocumentViewPicker(context);
    const uris: string[] = await viewPicker.save(options);
    if (uris === null || uris === undefined || uris.length === 0) {
      return null;
    }
    return uris[0];
  }

  /**
   * 读取文本，**自适应编码**。
   *
   * BOM 说明：`TextDecoder` 的 `ignoreBOM` 默认 false，按规范此时 BOM 会被**消费掉**，
   * 因此解码结果不含 U+FEFF；`Csv.parse` 里的剥 BOM 是兜底而非必要条件。
   *
   * 为什么需要自适应：本 App 自家导出的 CSV 固定是 UTF-8 带 BOM，但「别处来的」文件未必 ——
   * Windows 版 Excel 把表格另存为 CSV 时默认使用系统 ANSI 代码页，简体中文环境下就是
   * **GBK / GB18030**。若按 UTF-8 强解，中文表头会变成乱码，列名识别随之失效。
   *
   * 策略是「先严格、后放宽」，不做猜测性替换：
   *   1. UTF-8 **严格**解码，失败说明不是合法 UTF-8；
   *   2. GB18030 严格解码（GBK 的超集，覆盖简体中文常见字形）；
   *   3. 都失败时按 UTF-8 放宽解码兜底 —— 宁可出现替换字符，也不要抛错中断导入。
   *
   * 注：日期与数值都是 ASCII，即使编码判断错误也能解析，受影响的主要是中文表头与文本字段。
   */
  static async readText(uri: string): Promise<string> {
    const file: fileIo.File = fileIo.openSync(uri, fileIo.OpenMode.READ_ONLY);
    try {
      const stat: fileIo.Stat = fileIo.statSync(file.fd);
      const size: number = stat.size;
      if (size <= 0) {
        return '';
      }
      const buffer: ArrayBuffer = new ArrayBuffer(size);
      const readLength: number = fileIo.readSync(file.fd, buffer);
      const bytes: Uint8Array = new Uint8Array(buffer, 0, readLength);
      return FileService.decodeAdaptive(bytes);
    } finally {
      fileIo.closeSync(file);
    }
  }

  /** 编码自适应决策（纯字节 → 文本；可用同一算法在离线环境复现验证） */
  static decodeAdaptive(bytes: Uint8Array): string {
    if (bytes === null || bytes === undefined || bytes.length === 0) {
      return '';
    }
    const utf8: string | null = FileService.decodeStrict(bytes, 'utf-8');
    if (utf8 !== null) {
      return utf8;
    }
    const gb: string | null = FileService.decodeStrict(bytes, 'gb18030');
    if (gb !== null) {
      Logger.info(TAG, 'text is not valid UTF-8, decoded as GB18030');
      return gb;
    }
    Logger.warn(TAG, 'text is neither valid UTF-8 nor GB18030, fallback to lenient UTF-8');
    return FileService.decodeLenient(bytes, 'utf-8');
  }

  /** 严格解码：失败（含非法字节序列）返回 null，不抛给调用方 */
  private static decodeStrict(bytes: Uint8Array, encoding: string): string | null {
    try {
      const options: util.TextDecoderOptions = { fatal: true };
      const decoder: util.TextDecoder = util.TextDecoder.create(encoding, options);
      return decoder.decodeToString(bytes);
    } catch (err) {
      const e = err as BusinessError;
      Logger.debug(TAG, `strict decode as ${encoding} failed: ${e.message}`);
      return null;
    }
  }

  /** 放宽解码：仅用于兜底，不抛错 */
  private static decodeLenient(bytes: Uint8Array, encoding: string): string {
    try {
      return util.TextDecoder.create(encoding).decodeToString(bytes);
    } catch (err) {
      const e = err as BusinessError;
      Logger.error(TAG, `lenient decode as ${encoding} failed: ${e.message}`);
      return '';
    }
  }

  /** 写入文本到指定 URI（picker 授权的一次性 URI，无需额外权限） */
  static async writeText(uri: string, text: string): Promise<void> {
    const file: fileIo.File = fileIo.openSync(uri,
      fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
    try {
      fileIo.writeSync(file.fd, text);
    } finally {
      fileIo.closeSync(file);
    }
  }

  /** 写入二进制到 cacheDir，返回可分享的 file URI */
  static async writeTempImage(context: common.UIAbilityContext, fileName: string, data: ArrayBuffer): Promise<string> {
    const path: string = `${context.cacheDir}/${fileName}`;
    const file: fileIo.File = fileIo.openSync(path,
      fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
    try {
      fileIo.writeSync(file.fd, data);
    } finally {
      fileIo.closeSync(file);
    }
    return fileUri.getUriFromPath(path);
  }

  /** 生成带时间戳的导出文件名，避免同名覆盖 */
  static stampName(prefix: string, suffix: string, now: number): string {
    const d: Date = new Date(now);
    const pad = (v: number): string => (v < 10 ? `0${v}` : `${v}`);
    return `${prefix}${d.getFullYear()}${pad(d.getMonth() + 1)}${pad(d.getDate())}${pad(d.getHours())}${pad(d.getMinutes())}${pad(d.getSeconds())}${suffix}`;
  }

  private static baseName(uri: string): string {
    const idx: number = uri.lastIndexOf('/');
    const raw: string = idx >= 0 ? uri.substring(idx + 1) : uri;
    try {
      return decodeURIComponent(raw);
    } catch (err) {
      const e = err as BusinessError;
      Logger.warn(TAG, `decode uri failed: ${e.message}`);
      return raw;
    }
  }
}
