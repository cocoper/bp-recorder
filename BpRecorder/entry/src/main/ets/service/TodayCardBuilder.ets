import { MedLog } from '../model/Med';
import { MedLogStatus } from '../model/Types';
import { MedService } from './MedService';
import { DateUtils } from '../common/DateUtils';

/** 卡片里的一行（4*2 布局用；最多展示 3 行） */
export interface TodayCardRow {
  /** 计划时间 HH:mm */
  time: string;
  /** 药品名 */
  name: string;
  /** taken | pending | missed | skipped */
  status: string;
  /** 中文状态词（卡片上直接显示） */
  label: string;
}

/**
 * 桌面卡片的数据模型。
 *
 * 纯函数：输入「今天的打卡记录」与「当前时刻」，输出卡片可直接渲染的字段。
 * 卡片渲染只能在真机上看，但**数据口径必须可离线回归**。
 */
export interface TodayCardData {
  hasPlan: boolean;
  total: number;
  taken: number;
  pending: number;
  missed: number;
  skipped: number;
  /** 大标题，例如「3/4」「全部完成」「无安排」 */
  headline: string;
  /** 副标题，例如「下一次 21:00」 */
  subline: string;
  /** 语气：done | next | missed | idle（决定配色） */
  tone: string;
  /** 下一次待服时间 HH:mm；没有则为空串 */
  nextTime: string;
  /** 最多 3 行明细 */
  rows: TodayCardRow[];
  /** 刷新时间 HH:mm（卡片角标） */
  updatedAt: string;
}

const MAX_ROWS: number = 3;

/** 卡片绑定字段（ArkTS 要求字面量有显式类型） */
export interface TodayCardBinding {
  hasPlan: number;
  total: number;
  taken: number;
  pending: number;
  missed: number;
  headline: string;
  subline: string;
  tone: string;
  nextTime: string;
  rowsText: string;
  rowCount: number;
  updatedAt: string;
  /** 1 = 大卡（展示分次明细） */
  showRows: number;
}

/** 由今日打卡记录构建卡片数据（口径与 App 内一致） */
export class TodayCardBuilder {
  static build(logs: MedLog[], now: number): TodayCardData {
    const sorted: MedLog[] = logs.slice().sort((a: MedLog, b: MedLog) => a.scheduledTime - b.scheduledTime);
    let taken: number = 0;
    let pending: number = 0;
    let missed: number = 0;
    let skipped: number = 0;
    let nextTime: string = '';
    const rows: TodayCardRow[] = [];
    for (let i = 0; i < sorted.length; i++) {
      const log: MedLog = sorted[i];
      const status: MedLogStatus = MedService.resolveStatus(log, now);
      let label: string = '待服';
      let key: string = 'pending';
      if (status === MedLogStatus.TAKEN) {
        taken++;
        // 补记是派生展示（takenTime 超过宽限期），枚举里只有 TAKEN
        label = MedService.isMakeUp(log) ? '补记' : '已服';
        key = 'taken';
      } else if (status === MedLogStatus.MISSED) {
        missed++;
        label = '漏服';
        key = 'missed';
      } else if (status === MedLogStatus.SKIPPED) {
        skipped++;
        label = '跳过';
        key = 'skipped';
      } else {
        pending++;
        if (nextTime.length === 0) {
          nextTime = DateUtils.formatTime(log.scheduledTime);
        }
      }
      if (rows.length < MAX_ROWS) {
        rows.push({ time: DateUtils.formatTime(log.scheduledTime), name: log.medName, status: key, label: label });
      }
    }
    const total: number = sorted.length;
    let headline: string = '';
    let subline: string = '';
    let tone: string = 'idle';
    if (total === 0) {
      headline = '无安排';
      subline = '今天没有用药计划';
    } else if (missed > 0) {
      headline = `${taken}/${total}`;
      subline = `已漏 ${missed} 次，尽快处理`;
      tone = 'missed';
    } else if (taken === total) {
      headline = '已完成';
      subline = `今天 ${total} 次都已服`;
      tone = 'done';
    } else {
      headline = `${taken}/${total}`;
      subline = nextTime.length > 0 ? `下一次 ${nextTime}` : `还有 ${pending + skipped} 次待处理`;
      tone = pending > 0 ? 'next' : 'done';
    }
    return {
      hasPlan: total > 0, total: total, taken: taken, pending: pending, missed: missed, skipped: skipped,
      headline: headline, subline: subline, tone: tone, nextTime: nextTime, rows: rows,
      updatedAt: DateUtils.formatTime(now)
    };
  }

  /** 扁平成卡片绑定字段（卡片侧只认基本类型） */
  static toBinding(data: TodayCardData): TodayCardBinding {
    let rowText: string = '';
    for (let i = 0; i < data.rows.length; i++) {
      const r: TodayCardRow = data.rows[i];
      if (i > 0) {
        rowText += '\n';
      }
      rowText += `${r.time}  ${r.name}  ${r.label}`;
    }
    return {
      hasPlan: data.hasPlan ? 1 : 0,
      total: data.total, taken: data.taken, pending: data.pending, missed: data.missed,
      headline: data.headline, subline: data.subline, tone: data.tone,
      nextTime: data.nextTime, rowsText: rowText, rowCount: data.rows.length,
      updatedAt: data.updatedAt, showRows: 0
    };
  }
}
