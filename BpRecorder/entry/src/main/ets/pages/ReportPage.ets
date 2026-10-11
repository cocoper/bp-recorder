import { common } from '@kit.AbilityKit';
import { display, router } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { GradeColor, GradeText, PeriodText, ReportKind } from '../common/Constants';
import { DateUtils } from '../common/DateUtils';
import { Logger } from '../common/Logger';
import { ReportVocab, VocabFactory } from '../common/Vocab';
import { BpRecord, DateRange, DistRow } from '../model/BpRecord';
import { AbnormalItem, MedLog, MedPlan, ReportData } from '../model/Med';
import { BpDatabase } from '../service/BpDatabase';
import { RequestGuard } from '../common/RequestGuard';
import { FileService } from '../service/FileService';
import { ReportService } from '../service/ReportService';
import { ShareService } from '../service/ShareService';
import { BpLineChart } from '../components/BpLineChart';
import { ResUtils } from '../common/ResUtils';

const TAG: string = 'ReportPage';
const CAPTURE_ID: string = 'bp_report_capture';

/**
 * 周期报告页（FR-10 / 策划文档 §5.10）。
 *
 * 九个板块按序：头部 → 核心指标卡 → 趋势图 → 分级分布 → 晨峰分析 → 环比对比
 * → 异常清单 → 用药小结 → 免责声明全文。
 * 三种输出：保存长图（安全控件 SaveButton）、系统分享、打印（可另存为 PDF）。
 * 报告内容固定使用印刷配色（白底深字），保证长图/打印在不同主题下完全一致。
 */
@Entry
@Component
struct ReportPage {

  /** 审查 R12：过期响应不得覆盖新报告 */
  private guard: RequestGuard = new RequestGuard();  @State private kind: string = ReportKind.WEEK;
  @State private rangeLabel: string = '';
  @State private report: ReportData | null = null;

  /** 出图容器实测高度（vp）：用于出图预算（审查 R15.4） */
  private captureHeightVp: number = 0;

  @State private busy: boolean = false;

  private range: DateRange = { start: 0, end: 0, label: '' };

  aboutToAppear(): void {
    this.applyKind(ReportKind.WEEK);
  }

  private context(): common.UIAbilityContext {
    return ResUtils.hostContext(this.getUIContext());
  }

  private toast(res: Resource): void {
    this.getUIContext().getPromptAction().showToast({ message: res, duration: 2200 });
  }

  private applyKind(kind: string): void {
    this.kind = kind;
    const now: number = DateUtils.now();
    this.load(kind === ReportKind.MONTH ? ReportService.monthRange(now) : ReportService.weekRange(now));
  }

  /** 周期快选：周报最近 4 周 / 月报最近 3 个月 */
  private pickPeriod(): void {
    const now: number = DateUtils.now();
    const sheets: SheetInfo[] = [];
    if (this.kind === ReportKind.MONTH) {
      const months: DateRange[] = ReportService.recentMonths(now, 3);
      for (let i = 0; i < months.length; i++) {
        const r: DateRange = months[i];
        sheets.push({ title: r.label, action: () => this.load(r) });
      }
    } else {
      const weeks: DateRange[] = ReportService.recentWeeks(now, 4);
      for (let i = 0; i < weeks.length; i++) {
        const r: DateRange = weeks[i];
        sheets.push({ title: r.label, action: () => this.load(r) });
      }
    }
    sheets.push({ title: $r('app.string.report_custom_range'), action: () => this.pickCustom() });
    this.getUIContext().showActionSheet({
      title: $r('app.string.report_pick_period'),
      message: $r('app.string.sheet_msg_report_period'),
      sheets: sheets
    });
  }

  /** 自定义周期：先选开始日期，再选结束日期，自动校验 ≤92 天（FR-10.1） */
  private pickCustom(): void {
    this.getUIContext().showDatePickerDialog({
      selected: new Date(DateUtils.startOfWeek(DateUtils.now())),
      start: new Date(2000, 0, 1),
      end: new Date(),
      onDateAccept: (startValue: Date) => {
        const startDay: number = DateUtils.startOfDay(startValue.getTime());
        this.getUIContext().showDatePickerDialog({
          selected: new Date(startDay),
          start: new Date(startDay),
          end: new Date(),
          onDateAccept: (endValue: Date) => {
            const endDay: number = DateUtils.startOfDay(endValue.getTime());
            if (!ReportService.isCustomRangeValid(startDay, endDay)) {
              this.toast($r('app.string.report_range_invalid'));
              return;
            }
            this.kind = ReportKind.CUSTOM;
            this.load(ReportService.customRange(startDay, endDay));
          }
        });
      }
    });
  }

  private async load(range: DateRange): Promise<void> {
    const token: number = this.guard.next();
    if (token < 0) {
      return;
    }
    // 审查 R12：捕获本次请求的不可变快照 —— 加载期间用户改周期标签不会串进本次结果
    const kind: string = this.kind;
    const now: number = DateUtils.now();
    this.busy = true;
    this.range = range;
    this.rangeLabel = range.label;
    // 这里**不需要**先把 report 置空：reportSheet 现在直接读 this.report，
    // 换成新报告时会正常重建（置空反而会闪一下空白，且在 await 很短时未必真的触发重渲染）。
    try {
      const db: BpDatabase = BpDatabase.getInstance();
      const records: BpRecord[] = await db.queryBpAll();
      const logs: MedLog[] = await db.queryMedLogsAll();
      const plans: MedPlan[] = await db.queryActivePlans();
      const vocab: ReportVocab = VocabFactory.report(this.context());
      // 周期内无血压数据时返回 null，页面提示「该周期暂无数据」（FR-10.4）
      const report: ReportData | null = ReportService.build(kind, range, records, logs, plans, vocab, now);
      if (!this.guard.isCurrent(token)) {
        return;                                            // 过期响应：不提交（含不覆盖 busy）
      }
      this.report = report;
    } catch (err) {
      const e = err as BusinessError;
      Logger.error(TAG, `build report failed: code=${e.code}, message=${e.message}`);
      if (!this.guard.isCurrent(token)) {
        return;
      }
      // 失败时不保留旧报告配新标签：清空并如实提示
      this.report = null;
      this.toast($r('app.string.error_db_read'));
    } finally {
      if (this.guard.isCurrent(token)) {
        this.busy = false;
      }
    }
  }

  /** 出图显式像素宽（审查 R15.3）：1080px 换算成 vp，不随屏幕密度/用户缩放漂移 */
  private captureWidthVp(): number {
    try {
      const d: number = display.getDefaultDisplaySync().densityPixels;
      return ShareService.captureWidthVp(d);
    } catch (err) {
      return 360;   // 兜底：3x 密度下 1080px
    }
  }

  private deviceDensity(): number {
    try {
      return display.getDefaultDisplaySync().densityPixels;
    } catch (err) {
      return 3;
    }
  }

  /**
   * 出图预算（审查 R15.4）：超过 8192px 高时**明确提示需要几张**，
   * 而不是把长文缩到不可读或悄悄截断异常清单。
   */
  private withinCaptureBudget(): boolean {
    const plan = ShareService.planCapture(this.captureHeightVp, this.deviceDensity());
    if (plan.split) {
      Logger.warn(TAG, `capture exceeds budget: heightPx=${plan.heightPx}, pages=${plan.pages}`);
      this.toast($r('app.string.report_too_long', plan.pages));
      return false;
    }
    return true;
  }

  private async captureData(): Promise<ArrayBuffer> {
    // 审查 R15.1：快照的 PixelMap 由创建者释放
    return ShareService.withSnapshot(CAPTURE_ID, (pixelMap) => ShareService.packPng(pixelMap));
  }

  /**
   * 分享/打印的前置条件（审查 R12）：不在加载中、且当前已有报告数据。
   * 否则截图可能把「新周期标签 + 旧报告内容」混在一起导出。
   */
  private canExport(): boolean {
    return !this.busy && this.report !== null;
  }

  private async shareReport(): Promise<void> {
    if (!this.canExport()) {
      this.toast($r('app.string.report_not_ready'));
      return;
    }
    if (!this.withinCaptureBudget()) {
      return;
    }
    try {
      const fileName: string = FileService.stampName('bp_report_', '.png', DateUtils.now());
      const title: string = this.report === null ? '' : this.report.title;
      await ShareService.withSnapshot(CAPTURE_ID, (pixelMap) =>
        ShareService.shareImage(this.context(), pixelMap, fileName, title));
    } catch (err) {
      const e = err as BusinessError;
      Logger.error(TAG, `share report failed: ${ShareService.describeError(e)}`);
      this.toast($r('app.string.error_snapshot'));
    }
  }

  private async printReport(): Promise<void> {
    if (!this.canExport()) {
      this.toast($r('app.string.report_not_ready'));
      return;
    }
    if (!this.withinCaptureBudget()) {
      return;
    }
    try {
      await ShareService.withSnapshot(CAPTURE_ID, (pixelMap) =>
        ShareService.printImage(this.context(), pixelMap,
          FileService.stampName('bp_report_', '.png', DateUtils.now())));
    } catch (err) {
      const e = err as BusinessError;
      Logger.error(TAG, `print report failed: ${ShareService.describeError(e)}`);
      this.toast($r('app.string.error_print'));
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
        Text($r('app.string.title_report'))
          .fontSize(17)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
        Blank()
        Row({ space: 12 }) {
          Text($r('app.string.action_share'))
            .fontSize(14)
            .fontColor($r('app.color.primary'))
            .onClick(() => {
              this.shareReport();
            })
          Text($r('app.string.action_print'))
            .fontSize(14)
            .fontColor($r('app.color.primary'))
            .onClick(() => {
              this.printReport();
            })
        }
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 12, bottom: 12 })

      // 周期类型与周期选择
      Row({ space: 8 }) {
        this.kindChip($r('app.string.report_week'), ReportKind.WEEK)
        this.kindChip($r('app.string.report_month'), ReportKind.MONTH)
        Blank()
        Text(this.rangeLabel)
          .fontSize(13)
          .fontColor($r('app.color.primary'))
          .onClick(() => {
            this.pickPeriod();
          })
      }
      .width('100%')
      .padding({ left: 16, right: 16, bottom: 8 })

      Scroll() {
        if (this.report === null && !this.busy) {
          Column({ space: 8 }) {
            Text($r('app.string.report_no_data'))
              .fontSize(15)
              .fontColor($r('app.color.text_secondary'))
          }
          .width('100%')
          .padding({ top: 80 })
        } else if (this.report !== null) {
          this.reportSheet()
        }
      }
      .layoutWeight(1)

      if (this.report !== null) {
        // SaveButtonAttribute 只继承 SecurityComponentMethod 的那组属性，不支持 .margin()，
        // 因此把外边距移到外层 Row 上
        Row() {
          SaveButton({
            icon: SaveIconStyle.FULL_FILLED,
            text: SaveDescription.SAVE_IMAGE,
            buttonType: ButtonType.Capsule
          })
            .onClick(async (event: ClickEvent, result: SaveButtonOnClickResult) => {
              if (result !== SaveButtonOnClickResult.SUCCESS) {
                return;
              }
              if (!this.withinCaptureBudget()) {
                return;
              }
              try {
                const data: ArrayBuffer = await this.captureData();
                await ShareService.saveToAlbum(this.context(), data);
                this.toast($r('app.string.toast_saved_album'));
              } catch (err) {
                const e = err as BusinessError;
                Logger.error(TAG, `save report image failed: ${ShareService.describeError(e)}`);
                this.toast($r('app.string.error_save_album'));
              }
            })
        }
        .width('100%')
        .justifyContent(FlexAlign.Center)
        .margin({ top: 8, bottom: 12 })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_bg'))
  }

  @Builder
  kindChip(label: Resource, kind: string) {
    Text(label)
      .fontSize(13)
      .fontColor(this.kind === kind ? $r('app.color.on_primary') : $r('app.color.text_primary'))
      .padding({ left: 16, right: 16, top: 6, bottom: 6 })
      .backgroundColor(this.kind === kind ? $r('app.color.primary') : $r('app.color.surface'))
      .borderRadius(16)
      .onClick(() => {
        this.applyKind(kind);
      })
  }

  /** 报告正文（同时是被截图的容器，固定印刷配色） */
  @Builder
  reportSheet() {
    // 直接读 this.report，而不是把它当参数传进来：@Builder 的传参是首帧快照，
    // 旧报告换成新报告时不会重建（切周报/月报会留着上一期的数字，v1.18 真机发现）。
    if (this.report !== null) {
      Column({ space: 14 }) {
        // 板块 1：头部
        Column({ space: 4 }) {
          Text(this.report.title)
            .fontSize(20)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.print_text_primary'))
          Text(this.report.range.label)
            .fontSize(13)
            .fontColor($r('app.color.print_text_secondary'))
          Text(this.report.adherence.due === 0
            ? $r('app.string.report_head_line_no_adh', this.report.stats.count)
            : $r('app.string.report_head_line', this.report.stats.count,
              this.report.adherence.rate === null ? '-' : this.report.adherence.rate.toFixed(1) + '%'))
            .fontSize(12)
            .fontColor($r('app.color.print_text_secondary'))
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)

        Divider().color($r('app.color.print_divider'))

        // 板块 2：核心指标卡
        Column({ space: 6 }) {
          Text($r('app.string.metric_avg_bp'))
            .fontSize(13)
            .fontColor($r('app.color.print_text_secondary'))
          Text($r('app.string.metric_bp_value', Math.round(this.report.stats.sysMean), Math.round(this.report.stats.diaMean)))
            .fontSize(26)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.print_text_primary'))
          // 平均心率全空时与统计页 / 趋势页统一显示占位符「—」，不再整行消失
          Text(this.report.stats.hrMean === null
            ? $r('app.string.metric_placeholder')
            : $r('app.string.metric_hr_value', Math.round(this.report.stats.hrMean)))
            .fontSize(13)
            .fontColor($r('app.color.print_text_secondary'))
          Text($r('app.string.report_max_min', this.report.stats.sysMax, this.report.stats.diaMax,
            this.report.stats.sysMin, this.report.stats.diaMin))
            .fontSize(13)
            .fontColor($r('app.color.print_text_primary'))
          Text($r('app.string.report_stddev', this.report.stats.sysStdDev.toFixed(1), this.report.stats.diaStdDev.toFixed(1)))
            .fontSize(13)
            .fontColor($r('app.color.print_text_primary'))

          // 板块 6：环比对比（无上期数据显示「—」）
          if (this.report.hasPrev) {
            Text($r('app.string.report_compare_with', this.report.prevLabel))
              .fontSize(12)
              .fontColor($r('app.color.print_text_secondary'))
            Text($r('app.string.report_compare_value', this.deltaText(this.report.deltaSys), this.deltaText(this.report.deltaDia)))
              .fontSize(14)
              .fontWeight(FontWeight.Medium)
              .fontColor(this.deltaColor(this.report.deltaSys))
          } else {
            Text($r('app.string.report_compare_none'))
              .fontSize(12)
              .fontColor($r('app.color.print_text_secondary'))
          }
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)

        // 板块 3：周期趋势折线图（复用 BpLineChart，含参考线与服药标记）
        Text($r('app.string.report_trend_title'))
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.print_text_primary'))
          .width('100%')
        BpLineChart({
          points: this.report.dailyPoints,
          showHeartRate: true,
          showWatermark: false,
          chartHeight: 220
        })

        // 板块 4：分级分布
        Text($r('app.string.distribution_title'))
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.print_text_primary'))
          .width('100%')
        ForEach(this.nonZeroRows(this.report.distribution), (row: DistRow) => {
          Row({ space: 8 }) {
            Text(GradeText.label(row.level))
              .fontSize(12)
              .fontColor($r('app.color.print_text_secondary'))
              .width(56)
            Stack({ alignContent: Alignment.Start }) {
              Row().width('100%').height(9).backgroundColor($r('app.color.print_bar_track')).borderRadius(5)
              Row().width(`${row.percent}%`).height(9).backgroundColor(GradeColor.of(row.level)).borderRadius(5)
            }
            .layoutWeight(1)
            .height(9)
            Text($r('app.string.percent_value', row.percent.toFixed(1) + '%'))
              .fontSize(12)
              .fontColor($r('app.color.print_text_primary'))
              .width(52)
              .textAlign(TextAlign.End)
          }
          .width('100%')
        }, (row: DistRow) => `${row.level}_${row.count}_${row.percent}`)

        // 板块 5：晨起 / 全天对比（原「晨峰分析」，v1.3 更名，见决策 D2）
        Text($r('app.string.surge_title'))
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.print_text_primary'))
          .width('100%')
        Text(this.report.morningCompare.morningCount === 0
          ? $r('app.string.surge_no_data')
          : $r('app.string.surge_delta', this.deltaText(this.report.morningCompare.deltaSys), this.deltaText(this.report.morningCompare.deltaDia)))
          .fontSize(13)
          .fontColor($r('app.color.print_text_primary'))
          .width('100%')
        Text($r('app.string.surge_note'))
          .fontSize(11)
          .fontColor($r('app.color.print_text_secondary'))
          .width('100%')

        // 板块 7：异常清单（≥140/90）
        Text($r('app.string.report_abnormal_title'))
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.print_text_primary'))
          .width('100%')
        if (this.report.abnormals.length === 0) {
          Text($r('app.string.report_abnormal_none'))
            .fontSize(13)
            .fontColor($r('app.color.print_text_secondary'))
            .width('100%')
        } else {
          ForEach(this.report.abnormals, (item: AbnormalItem) => {
            Row({ space: 10 }) {
              Text(DateUtils.formatMonthDay(item.measureTime))
                .fontSize(13)
                .fontColor($r('app.color.print_text_secondary'))
              Text(PeriodText.label(item.period))
                .fontSize(12)
                .fontColor($r('app.color.print_text_secondary'))
              Blank()
              Text($r('app.string.metric_bp_value_only', item.systolic, item.diastolic))
                .fontSize(14)
                .fontWeight(FontWeight.Medium)
                .fontColor($r('app.color.print_line_sys'))
            }
            .width('100%')
          }, (item: AbnormalItem) => `${item.measureTime}_${item.systolic}_${item.diastolic}_${item.period}`)
        }

        // 板块 8：用药小结（审查 R11：条件看周期内用药数据，不看「当前是否有生效计划」）
        if (this.report.hasMedicationData) {
          Text($r('app.string.report_med_title'))
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.print_text_primary'))
            .width('100%')
          Text($r('app.string.report_med_line', this.report.adherence.due, this.report.adherence.taken,
            this.report.adherence.missed, this.report.adherence.skipped))
            .fontSize(13)
            .fontColor($r('app.color.print_text_primary'))
            .width('100%')
          if (this.report.adherence.due === 0 && this.report.medPendingNotDue > 0) {
            // 与「完全没有用药数据」区分开：本期有义务，只是还没到点
            Text($r('app.string.report_med_pending_not_due'))
              .fontSize(12)
              .fontColor($r('app.color.print_text_secondary'))
              .width('100%')
          }
        }

        Divider().color($r('app.color.print_divider'))

        // 板块 9：免责声明全文
        Text($r('app.string.disclaimer_full'))
          .fontSize(11)
          .lineHeight(16)
          .fontColor($r('app.color.print_watermark'))
          .width('100%')

        // 水印行（FR-11.2）
        Text(this.report.watermark)
          .fontSize(10)
          .fontColor($r('app.color.print_watermark'))
          .width('100%')
          .margin({ bottom: 12 })
      }
      .id(CAPTURE_ID)
      // 审查 R15.3：显式 1080px 宽（换算成 vp），不随屏幕密度与用户缩放变化
      .width(this.captureWidthVp())
      .onAreaChange((oldValue: Area, newValue: Area) => {
        this.captureHeightVp = Number(newValue.height);
      })
      .padding(16)
      .backgroundColor($r('app.color.print_bg'))
      .borderRadius(12)
      .alignItems(HorizontalAlign.Start)
    }
  }

  private nonZeroRows(rows: DistRow[]): DistRow[] {
    const out: DistRow[] = [];
    for (let i = 0; i < rows.length; i++) {
      if (rows[i].count > 0) {
        out.push(rows[i]);
      }
    }
    return out;
  }

  /** 环比差值文案：正数带 + 号，负数带 − 号 */
  private deltaText(value: number): string {
    const rounded: number = Math.round(value * 10) / 10;
    if (rounded > 0) {
      return `↑${rounded}`;
    }
    if (rounded < 0) {
      return `↓${Math.abs(rounded)}`;
    }
    return `—`;
  }

  /** 环比颜色：升为红、降为绿（中国习惯），持平时用正文色 */
  private deltaColor(delta: number): Resource {
    if (delta > 0) {
      return $r('app.color.print_delta_up');
    }
    if (delta < 0) {
      return $r('app.color.print_delta_down');
    }
    return $r('app.color.print_text_primary');
  }
}
