import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0xB000;

/**
 * 统一日志封装。
 * 集中一处便于后续接入文件日志或做发布版降噪（debug 级在 release 构建可整体关闭）。
 */
export class Logger {
  static debug(tag: string, message: string): void {
    hilog.debug(DOMAIN, tag, '%{public}s', message);
  }

  static info(tag: string, message: string): void {
    hilog.info(DOMAIN, tag, '%{public}s', message);
  }

  static warn(tag: string, message: string): void {
    hilog.warn(DOMAIN, tag, '%{public}s', message);
  }

  static error(tag: string, message: string): void {
    hilog.error(DOMAIN, tag, '%{public}s', message);
  }
}
