import { common } from '@kit.AbilityKit';
import { router } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { GradeText, GradeColor } from '../common/Constants';
import { DateUtils } from '../common/DateUtils';
import { Logger } from '../common/Logger';
import { VocabFactory } from '../common/Vocab';
import { Adherence, BpRecord, DistRow, MorningCompare, RangeStats } from '../model/BpRecord';
import { MedLog } from '../model/Med';
import { BpDatabase } from '../service/BpDatabase';
import { RequestGuard } from '../common/RequestGuard';
import { ExportService, ExportRangeKind } from '../service/ExportService';
import { FileService } from '../service/FileService';
import { MedService } from '../service/MedService';
import { StatsService } from '../service/StatsService';
import { ResUtils } from '../common/ResUtils';

const TAG: string = 'StatsPage';

/** 统计分析页（FR-4 / FR-9.5 / FR-6.1–6.3 / 策划文档 §5.4） */
@Entry
@Component
struct StatsPage {

  /** 审查 R12：过期响应不得覆盖新状态 */
  private guard: RequestGuard = new RequestGuard();

  @State private days: number = 7;
  @State private stats: RangeStats = {
    count: 0, sysMean: 0, diaMean: 0, hrMean: null,
    sysMax: 0, sysMin: 0, diaMax: 0, diaMin: 0, sysStdDev: 0, diaStdDev: 0
  };
  @State private distribution: DistRow[] = [];
  @State private morningCompare: MorningCompare = {
    morningCount: 0, morningSys: 0, morningDia: 0,
    overallSys: 0, overallDia: 0, deltaSys: 0, deltaDia: 0
  };
  @State private adherence: Adherence = {
    expected: 0, taken: 0, skipped: 0, missed: 0, pendingNotDue: 0, due: 0, rate: null
  };

  private readonly ranges: number[] = [7, 30, 90];

  aboutToAppear(): void {
    this.load();
  }

    aboutToDisappear(): void {
    // 审查 R12：销毁后任何在途响应都不得再改视图
    this.guard.dispose();
  }

onPageShow(): void {
    this.load();
  }

  private context(): common.UIAbilityContext {
    return ResUtils.hostContext(this.getUIContext());
  }

  private async load(): Promise<void> {
    const token: number = this.guard.next();
    if (token < 0) {
      return;
    }
    const now: number = DateUtils.now();
    const days: number = this.days;                    // 本次请求的不可变快照
    const range = StatsService.lastDaysRange(days, now);
    try {
      const db: BpDatabase = BpDatabase.getInstance();
      const records: BpRecord[] = await db.queryBpBetween(range.start, range.end);
      const logs: MedLog[] = await db.queryMedLogsBetween(range.start, range.end);
      if (!this.guard.isCurrent(token)) {
        return;                                        // 过期响应：不提交任何视图状态
      }

      this.stats = StatsService.rangeStats(records);
      this.distribution = StatsService.gradeDistribution(records);
      this.morningCompare = StatsService.morningVsOverall(records);
      this.adherence = MedService.adherence(logs, now);
    } catch (err) {
      const e = err as BusinessError;
      Logger.error(TAG, `load stats failed: code=${e.code}, message=${e.message}`);
      this.getUIContext().getPromptAction().showToast({ message: $r('app.string.error_db_read') });
    }
  }

  /** 导出血压 CSV（FR-6.1–6.3）：picker 选择保存位置，无需持久文件权限 */
  private async exportBp(): Promise<void> {
    const format = this.getUIContext().getPromptAction();
    try {
      // 导出范围选择：全部 / 近 30 天 / 近 90 天
      this.getUIContext().showActionSheet({
        title: $r('app.string.export_pick_range'),
        message: $r('app.string.sheet_msg_export_range'),
        sheets: [
          { title: $r('app.string.export_range_all'), action: () => this.doExport(ExportRangeKind.ALL) },
          { title: $r('app.string.export_range_30'), action: () => this.doExport(ExportRangeKind.D30) },
          { title: $r('app.string.export_range_90'), action: () => this.doExport(ExportRangeKind.D90) }
        ]
      });
    } catch (err) {
      const e = err as BusinessError;
      Logger.error(TAG, `open range sheet failed: ${e.message}`);
      format.showToast({ message: $r('app.string.error_export') });
    }
  }

  private async doExport(kind: string): Promise<void> {
    const context = this.context();
    const now: number = DateUtils.now();
    try {
      const db: BpDatabase = BpDatabase.getInstance();
      const all: BpRecord[] = await db.queryBpAll();
      const scoped: BpRecord[] = ExportService.filterBpByRange(all, kind, now);
      const csv: string = ExportService.buildBpCsv(scoped, VocabFactory.csv(context));
      const fileName: string = FileService.stampName('bp_export_', '.csv', now);
      const target: string | null = await FileService.pickSaveTarget(context, fileName);
      if (target === null) {
        return;
      }
      await FileService.writeText(target, csv);
      this.getUIContext().getPromptAction().showToast({
        message: $r('app.string.toast_export_done', scoped.length),
        duration: 2500
      });
    } catch (err) {
      const e = err as BusinessError;
      Logger.error(TAG, `export failed: code=${e.code}, message=${e.message}`);
      this.getUIContext().getPromptAction().showToast({ message: $r('app.string.error_export') });
    }
  }

  build() {
    Column() {
      Row() {
        Text($r('app.string.action_back'))
          .fontSize(15)
          .fontColor($r('app.color.primary'))
          .onClick(() => {
            router.back();
          })
        Blank()
        Text($r('app.string.title_stats'))
          .fontSize(17)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
        Blank()
        Text($r('app.string.action_gen_report'))
          .fontSize(14)
          .fontColor($r('app.color.primary'))
          .onClick(() => {
            router.pushUrl({ url: 'pages/ReportPage' });
          })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 12, bottom: 12 })

      Row({ space: 8 }) {
        ForEach(this.ranges, (d: number) => {
          Text($r('app.string.range_days', d))
            .fontSize(13)
            .fontColor(this.days === d ? $r('app.color.on_primary') : $r('app.color.text_primary'))
            .padding({ left: 16, right: 16, top: 6, bottom: 6 })
            .backgroundColor(this.days === d ? $r('app.color.primary') : $r('app.color.surface'))
            .borderRadius(16)
            .onClick(() => {
              if (this.days !== d) {
                this.days = d;
                this.load();
              }
            })
        }, (d: number) => `${d}`)
      }
      .width('100%')
      .padding({ left: 16, right: 16, bottom: 8 })

      Scroll() {
        Column({ space: 12 }) {
          this.metricsCard()
          this.distributionCard()
          this.morningCompareCard()
          this.adherenceCard()

          Button($r('app.string.export_bp_csv'))
            .width('100%')
            .height(44)
            .fontSize(15)
            .backgroundColor($r('app.color.surface'))
            .fontColor($r('app.color.primary'))
            .onClick(() => {
              this.exportBp();
            })

          Text($r('app.string.disclaimer_med'))
            .fontSize(11)
            .fontColor($r('app.color.text_tertiary'))
            .width('100%')
            .textAlign(TextAlign.Center)
            .padding({ bottom: 20 })
        }
        .width('100%')
        .padding({ left: 12, right: 12 })
      }
      .layoutWeight(1)
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_bg'))
  }

  @Builder
  metricsCard() {
    Column({ space: 10 }) {
      this.metricRow(0)
      this.metricRow(1)
      this.metricRow(2)
      this.metricRow(3)
      this.metricRow(4)
      this.metricRow(5)
    }
    .width('100%')
    .padding(14)
    .backgroundColor($r('app.color.surface'))
    .borderRadius(12)
  }

  /**
   * 指标一行。参数只允许传常量序号：@Builder 的传参是**首帧快照**，
   * 早期版本直接把 this.stats.xxx 算好传进来，于是这一整块永远停在首帧的 0（v1.18 真机发现）。
   * 可变值必须在 builder 内部读 this.stats，才会登记成刷新依赖。
   */
  @Builder
  metricRow(which: number) {
    Row() {
      Text(StatsPage.metricLabel(which))
        .fontSize(14)
        .fontColor($r('app.color.text_secondary'))
      Blank()
      Text(this.metricValue(which))
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
    }
    .width('100%')
  }

  /** 指标行的标题（常量，与 metricValue 的序号一一对应） */
  private static metricLabel(which: number): Resource {
    switch (which) {
      case 0:
        return $r('app.string.metric_count');
      case 1:
        return $r('app.string.metric_avg_bp');
      case 2:
        return $r('app.string.metric_max');
      case 3:
        return $r('app.string.metric_min');
      case 4:
        return $r('app.string.metric_stddev');
      default:
        return $r('app.string.metric_hr');
    }
  }

  /** 指标行的数值：必须在 builder 内部调用（读 this.stats 才会被记成刷新依赖） */
  private metricValue(which: number): Resource {
    const s: RangeStats = this.stats;
    switch (which) {
      case 0:
        return $r('app.string.metric_count_value', s.count);
      case 1:
        return $r('app.string.metric_bp_value', Math.round(s.sysMean), Math.round(s.diaMean));
      case 2:
        return $r('app.string.metric_bp_value_only', s.sysMax, s.diaMax);
      case 3:
        return $r('app.string.metric_bp_value_only', s.sysMin, s.diaMin);
      case 4:
        return $r('app.string.metric_plain', s.sysStdDev.toFixed(1));
      default:
        return s.hrMean === null || s.hrMean === undefined
          ? $r('app.string.metric_placeholder')
          : $r('app.string.metric_hr_value', Math.round(s.hrMean));
    }
  }

  @Builder
  distributionCard() {
    Column({ space: 8 }) {
      Text($r('app.string.distribution_title'))
        .fontSize(14)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
        .width('100%')

      if (this.stats.count === 0) {
        Text($r('app.string.metric_placeholder'))
          .fontSize(13)
          .fontColor($r('app.color.text_tertiary'))
      } else {
        ForEach(this.distribution, (row: DistRow) => {
          Row({ space: 8 }) {
            Text(GradeText.label(row.level))
              .fontSize(12)
              .fontColor($r('app.color.text_secondary'))
              .width(56)
            Stack({ alignContent: Alignment.Start }) {
              Row()
                .width('100%')
                .height(10)
                .backgroundColor($r('app.color.bar_track'))
                .borderRadius(5)
              Row()
                .width(`${row.percent}%`)
                .height(10)
                .backgroundColor(GradeColor.of(row.level))
                .borderRadius(5)
            }
            .layoutWeight(1)
            .height(10)
            Text($r('app.string.percent_value', row.percent.toFixed(1) + '%'))
              .fontSize(12)
              .fontColor($r('app.color.text_primary'))
              .width(52)
              .textAlign(TextAlign.End)
          }
          .width('100%')
        }, (row: DistRow) => `${row.level}_${row.count}_${row.percent}`)
      }
    }
    .width('100%')
    .padding(14)
    .backgroundColor($r('app.color.surface'))
    .borderRadius(12)
  }

  @Builder
  morningCompareCard() {
    Column({ space: 6 }) {
      Text($r('app.string.surge_title'))
        .fontSize(14)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
        .width('100%')
      if (this.morningCompare.morningCount === 0) {
        Text($r('app.string.surge_no_data'))
          .fontSize(13)
          .fontColor($r('app.color.text_tertiary'))
      } else {
        Text($r('app.string.surge_values',
          Math.round(this.morningCompare.morningSys), Math.round(this.morningCompare.morningDia),
          Math.round(this.morningCompare.overallSys), Math.round(this.morningCompare.overallDia)))
          .fontSize(13)
          .fontColor($r('app.color.text_primary'))
          .width('100%')
        Text($r('app.string.surge_delta', this.formatDelta(this.morningCompare.deltaSys), this.formatDelta(this.morningCompare.deltaDia)))
          .fontSize(13)
          .fontColor($r('app.color.text_primary'))
          .width('100%')
      }
      // 口径说明（决策 D2）：避免与临床「血压晨峰」混淆
      Text($r('app.string.surge_note'))
        .fontSize(11)
        .fontColor($r('app.color.text_tertiary'))
        .width('100%')
    }
    .width('100%')
    .padding(14)
    .backgroundColor($r('app.color.surface'))
    .borderRadius(12)
  }

  @Builder
  adherenceCard() {
    Column({ space: 6 }) {
      Text($r('app.string.adherence_title'))
        .fontSize(14)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
        .width('100%')
      if (this.adherence.expected === 0) {
        Text($r('app.string.adherence_no_data'))
          .fontSize(13)
          .fontColor($r('app.color.text_tertiary'))
      } else {
        Text($r('app.string.adherence_values', this.adherence.due, this.adherence.taken))
          .fontSize(13)
          .fontColor($r('app.color.text_primary'))
          .width('100%')
        // 无已到期义务时不渲染比率行，避免出现「依从率 -%」这种半截单位
        if (this.adherence.due > 0) {
          Text($r('app.string.adherence_rate',
            this.adherence.rate === null ? '-' : this.adherence.rate.toFixed(1) + '%',
            this.adherence.missed, this.adherence.skipped))
            .fontSize(13)
            .fontColor($r('app.color.text_primary'))
            .width('100%')
        }
        // 未到期的 pending 不计入依从率，单独说明其存在与不计入的事实
        if (this.adherence.pendingNotDue > 0) {
          Text($r('app.string.adherence_pending_note', this.adherence.pendingNotDue))
            .fontSize(13)
            .fontColor($r('app.color.text_tertiary'))
            .width('100%')
        }
      }
    }
    .width('100%')
    .padding(14)
    .backgroundColor($r('app.color.surface'))
    .borderRadius(12)
  }

  private formatDelta(value: number): string {
    const rounded: number = Math.round(value);
    return rounded > 0 ? `+${rounded}` : `${rounded}`;
  }
}
