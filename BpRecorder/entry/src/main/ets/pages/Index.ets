import { common } from '@kit.AbilityKit';
import { router } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { AppConst, Disclaimers } from '../common/Constants';
import { DateUtils } from '../common/DateUtils';
import { Logger } from '../common/Logger';
import { Prefs } from '../common/Prefs';
import { ResUtils } from '../common/ResUtils';
import { BpRecord } from '../model/BpRecord';
import { TodayMedLine } from '../model/Med';
import { CheckInAction, MedLogStatus } from '../model/Types';
import { BpDatabase } from '../service/BpDatabase';
import { MedLifecycleService } from '../service/MedLifecycleService';
import { TodayCardService } from '../service/TodayCardService';
import { MedService } from '../service/MedService';
import { StatsService, MeanPair } from '../service/StatsService';
import { MedCheckInDialog } from '../components/MedCheckInDialog';
import { RecordListItem } from '../components/RecordListItem';
import { TodayMedCard } from '../components/TodayMedCard';
import { WarningBanner } from '../components/WarningBanner';

const TAG: string = 'Index';

/**
 * LazyForEach 数据源。
 * 使用 LazyForEach + IDataSource 而非 ForEach，保证 4000 条数据下只渲染可视区域（NFR-3）。
 * 变更统一走 onDataReloaded：分页每次仅追加 20 条，重载成本远低于维护增量索引的出错风险。
 */
class BpListDataSource implements IDataSource {
  private items: BpRecord[] = [];
  private listeners: DataChangeListener[] = [];

  totalCount(): number {
    return this.items.length;
  }

  getData(index: number): BpRecord {
    return this.items[index];
  }

  registerDataChangeListener(listener: DataChangeListener): void {
    if (this.listeners.indexOf(listener) < 0) {
      this.listeners.push(listener);
    }
  }

  unregisterDataChangeListener(listener: DataChangeListener): void {
    const idx: number = this.listeners.indexOf(listener);
    if (idx >= 0) {
      this.listeners.splice(idx, 1);
    }
  }

  private notifyReload(): void {
    for (let i = 0; i < this.listeners.length; i++) {
      this.listeners[i].onDataReloaded();
    }
  }

  setAll(items: BpRecord[]): void {
    this.items = items;
    this.notifyReload();
  }

  append(items: BpRecord[]): void {
    this.items = this.items.concat(items);
    this.notifyReload();
  }

  getCount(): number {
    return this.items.length;
  }
}

/**
 * 首页：记录列表（FR-2 / 策划文档 §5.1）。
 *
 * 组成：趋势预警条（FR-5.3，满足条件才显示）→ 今日服药卡片（FR-9.3，无计划时隐藏）
 * → 今日概览 → 记录列表（下拉刷新 + 上拉分页，每页 20 条）→ 底部 5 项导航。
 * 左滑列表项出现「编辑 / 删除」，删除需二次确认（CL-1）。
 */
@Entry
@Component
struct Index {
  private ds: BpListDataSource = new BpListDataSource();
  @State private loaded: number = 0;
  @State private total: number = 0;
  /** 本页当天是否已跑过用药生命周期（跨日保护，审查 R01.1） */
  private lifecycleDate: string = '';
  @State private noMore: boolean = true;
  @State private loading: boolean = false;
  @State private refreshing: boolean = false;
  @State private dbError: boolean = false;

  @State private todayLines: TodayMedLine[] = [];
  @State private todayTaken: number = 0;
  @State private todaySys: number = 0;
  @State private todayDia: number = 0;
  @State private todayHr: number = -1;

  @State private warnVisible: boolean = false;
  @State private warnSys: number = 0;
  @State private warnDia: number = 0;

  private checkInDialog: CustomDialogController | null = null;

  aboutToAppear(): void {
    this.bootstrap();
  }

  onPageShow(): void {
    // 从录入/编辑页返回后同步刷新列表、今日概览与预警条
    if (BpDatabase.getInstance().isReady()) {
      this.refreshLifecycleThenReload();
    }
  }

  /**
   * 页面跨日保护（审查 R01.1）：跨过 00:00 后再进首页时，先跑一次用药生命周期
   * （补齐应服实例 → 派生漏服 → 停用到期计划），再刷新界面。同一天内不重复跑。
   */
  private async refreshLifecycleThenReload(): Promise<void> {
    const now: number = DateUtils.now();
    const today: string = DateUtils.formatDate(now);
    try {
      if (this.lifecycleDate !== today) {
        const result = await MedLifecycleService.run(BpDatabase.getInstance(), now);
        this.lifecycleDate = today;
        Logger.info(TAG, `lifecycle on page show: backfilled=${result.backfilled}, missed=${result.markedMissed}, deactivated=${result.deactivatedPlans}`);
      }
    } catch (err) {
      const e = err as BusinessError;
      Logger.error(TAG, `lifecycle on page show failed: code=${e.code}, message=${e.message}`);
    }
    this.reloadAll();
  }

  private context(): common.UIAbilityContext {
    return ResUtils.hostContext(this.getUIContext());
  }

  private async bootstrap(): Promise<void> {
    try {
      await BpDatabase.getInstance().init(this.context());
    } catch (err) {
      const e = err as BusinessError;
      Logger.error(TAG, `database init failed: code=${e.code}, message=${e.message}`);
      this.dbError = true;
      return;
    }
    this.showDisclaimerOnce();
    await this.reloadAll();
  }

  /** 首次启动展示免责声明（CL-6：仅一次） */
  private showDisclaimerOnce(): void {
    const context = this.context();
    if (Prefs.isDisclaimerShown(context)) {
      return;
    }
    Prefs.markDisclaimerShown(context);
    this.getUIContext().showAlertDialog({
      title: $r('app.string.disclaimer_title'),
      message: ResUtils.text(context, Disclaimers.FULL),
      confirm: {
        value: $r('app.string.action_got_it'),
        action: () => {
        }
      }
    });
  }

  private async reloadAll(): Promise<void> {
    const db: BpDatabase = BpDatabase.getInstance();
    const now: number = DateUtils.now();
    try {
      // 打开 App 时先把超时未打卡的记录标记为漏服（FR-9.4）
      await db.markMissed(now);
      const page = await db.queryBpPage(0, AppConst.PAGE_SIZE);
      this.ds.setAll(page.items);
      this.loaded = page.items.length;
      this.total = page.total;
      this.noMore = !page.hasMore;
      await this.loadToday(now);
      await this.loadWarning(now);
    } catch (err) {
      const e = err as BusinessError;
      Logger.error(TAG, `reload failed: code=${e.code}, message=${e.message}`);
      this.toast($r('app.string.error_db_read'));
    }
  }

  private async loadToday(now: number): Promise<void> {
    const db: BpDatabase = BpDatabase.getInstance();
    const logs = await db.queryMedLogsOfDay(now);
    const lines: TodayMedLine[] = MedService.todayLines(logs, now);
    this.todayLines = lines;

    let taken: number = 0;
    for (let i = 0; i < lines.length; i++) {
      if (lines[i].status === MedLogStatus.TAKEN) {
        taken++;
      }
    }
    this.todayTaken = taken;

    const dayRecords: BpRecord[] = await db.queryBpBetween(DateUtils.startOfDay(now), DateUtils.endOfDay(now));
    if (dayRecords.length > 0) {
      const mean: MeanPair = StatsService.meanOf(dayRecords);
      this.todaySys = mean.sys;
      this.todayDia = mean.dia;
      const stats = StatsService.rangeStats(dayRecords);
      const hr: number | null = stats.hrMean;
      this.todayHr = hr === null || hr === undefined ? -1 : hr;
    } else {
      this.todaySys = 0;
      this.todayDia = 0;
      this.todayHr = -1;
    }
  }

  private async loadWarning(now: number): Promise<void> {
    const db: BpDatabase = BpDatabase.getInstance();
    const range = StatsService.lastDaysRange(AppConst.WARN_LOOKBACK_DAYS, now);
    const records: BpRecord[] = await db.queryBpBetween(range.start, range.end);
    const visible: boolean = StatsService.isTrendWarning(records, now, AppConst.WARN_LOOKBACK_DAYS);
    this.warnVisible = visible;
    if (visible) {
      const mean: MeanPair = StatsService.meanOf(records);
      this.warnSys = mean.sys;
      this.warnDia = mean.dia;
    }
  }

  private async loadMore(): Promise<void> {
    if (this.noMore || this.loading || this.dbError) {
      return;
    }
    this.loading = true;
    try {
      const page = await BpDatabase.getInstance().queryBpPage(this.loaded, AppConst.PAGE_SIZE);
      this.ds.append(page.items);
      this.loaded += page.items.length;
      this.noMore = !page.hasMore;
    } catch (err) {
      const e = err as BusinessError;
      Logger.error(TAG, `loadMore failed: code=${e.code}, message=${e.message}`);
    } finally {
      this.loading = false;
    }
  }

  private async onRefresh(): Promise<void> {
    this.refreshing = true;
    await this.reloadAll();
    this.refreshing = false;
  }

  private toast(res: Resource): void {
    this.getUIContext().getPromptAction().showToast({ message: res, duration: 2000 });
  }

  /** 删除需二次确认（CL-1：删除不可逆） */
  private confirmDelete(record: BpRecord): void {
    this.getUIContext().showAlertDialog({
      title: $r('app.string.delete_confirm_title'),
      message: $r('app.string.delete_confirm_message'),
      primaryButton: {
        value: $r('app.string.action_cancel'),
        action: () => {
        }
      },
      secondaryButton: {
        value: $r('app.string.action_delete'),
        fontColor: $r('app.color.danger'),
        action: () => {
          this.doDelete(record);
        }
      }
    });
  }

  private async doDelete(record: BpRecord): Promise<void> {
    try {
      await BpDatabase.getInstance().deleteBp(record.id);
      await this.reloadAll();
    } catch (err) {
      const e = err as BusinessError;
      Logger.error(TAG, `delete failed: code=${e.code}, message=${e.message}`);
      this.toast($r('app.string.error_db_write'));
    }
  }

  private openCheckIn(line: TodayMedLine): void {
    this.checkInDialog = new CustomDialogController({
      builder: MedCheckInDialog({
        line: line,
        onAction: (action: CheckInAction) => {
          this.doCheckIn(line, action);
        }
      }),
      autoCancel: true,
      alignment: DialogAlignment.Center
    });
    this.checkInDialog.open();
  }

  private async doCheckIn(line: TodayMedLine, action: CheckInAction): Promise<void> {
    const controller = this.checkInDialog;
    if (controller !== null) {
      controller.close();
    }
    const now: number = DateUtils.now();
    const status: MedLogStatus = MedService.nextStatus(action);
    const takenTime: number | null = action === CheckInAction.TAKE ? now : null;
    try {
      await BpDatabase.getInstance().updateMedLogStatus(line.logId, status, takenTime, line.medName);
      await this.loadToday(now);
      // 打卡后推送桌面卡片（失败只记日志，不影响打卡）
      await TodayCardService.refreshAll(this.context());
    } catch (err) {
      const e = err as BusinessError;
      Logger.error(TAG, `check-in failed: code=${e.code}, message=${e.message}`);
      this.toast($r('app.string.error_db_write'));
    }
  }

  build() {
    Column() {
      // 顶部标题
      Row() {
        Text($r('app.string.app_title'))
          .fontSize(20)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
        Blank()
        Text($r('app.string.index_total', this.total))
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 10, bottom: 10 })

      if (this.dbError) {
        Text($r('app.string.error_db_init'))
          .fontSize(13)
          .fontColor($r('app.color.danger'))
          .width('100%')
          .padding(12)
          .backgroundColor($r('app.color.danger_bg'))
      }

      Refresh({ refreshing: $$this.refreshing }) {
        List({ space: 8 }) {
          ListItem() {
            Column({ space: 10 }) {
              if (this.warnVisible) {
                WarningBanner({
                  sysMean: this.warnSys,
                  diaMean: this.warnDia,
                  days: AppConst.WARN_LOOKBACK_DAYS
                })
              }
              if (this.todayLines.length > 0) {
                TodayMedCard({
                  lines: this.todayLines,
                  takenCount: this.todayTaken,
                  totalCount: this.todayLines.length,
                  onCheckIn: (line: TodayMedLine) => {
                    this.openCheckIn(line);
                  }
                })
              }
              this.todayOverview()
            }
            .width('100%')
            .padding({ left: 12, right: 12 })
          }

          if (this.loaded === 0) {
            ListItem() {
              Column({ space: 8 }) {
                Text($r('app.string.empty_records'))
                  .fontSize(15)
                  .fontColor($r('app.color.text_secondary'))
                Text($r('app.string.empty_records_hint'))
                  .fontSize(12)
                  .fontColor($r('app.color.text_tertiary'))
              }
              .width('100%')
              .padding({ top: 60, bottom: 60 })
              .justifyContent(FlexAlign.Center)
            }
          } else {
            LazyForEach(this.ds, (record: BpRecord) => {
              RecordListItem({
                record: record,
                onEdit: (r: BpRecord) => {
                  router.pushUrl({ url: 'pages/RecordEditPage', params: { id: r.id } });
                },
                onDelete: (r: BpRecord) => {
                  this.confirmDelete(r);
                },
                onTap: (r: BpRecord) => {
                  router.pushUrl({ url: 'pages/RecordEditPage', params: { id: r.id, readonly: true } });
                }
              })
              // 键里带上 updatedAt：LazyForEach 只在键变化时重建列表项，只写 id 的话
              // 编辑过的记录会一直显示旧内容（真机 v1.15 验收发现，见自检报告 §29）
            }, (record: BpRecord) => `${record.id}_${record.updatedAt}`)
          }

          if (this.loaded > 0) {
            ListItem() {
              Text(this.noMore ? $r('app.string.list_no_more') : $r('app.string.list_loading'))
                .fontSize(12)
                .fontColor($r('app.color.text_tertiary'))
                .width('100%')
                .textAlign(TextAlign.Center)
                .padding({ top: 12, bottom: 16 })
            }
          }
        }
        .width('100%')
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        .onReachEnd(() => {
          this.loadMore();
        })
      }
      .layoutWeight(1)
      .onRefreshing(() => {
        this.onRefresh();
      })

      this.bottomNav()
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_bg'))
  }

  /** 今日概览：已测次数 + 均值 + 平均心率 */
  @Builder
  todayOverview() {
    Row() {
      Column({ space: 2 }) {
        Text($r('app.string.today_overview'))
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
        if (this.todaySys > 0) {
          Text($r('app.string.today_avg', Math.round(this.todaySys), Math.round(this.todayDia)))
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
        } else {
          Text($r('app.string.today_no_bp'))
            .fontSize(14)
            .fontColor($r('app.color.text_tertiary'))
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      // 今日有测量记录时心率槽位恒显示：未记录心率则用占位符，避免该槽位莫名消失
      if (this.todaySys > 0) {
        Text(this.todayHr >= 0
          ? $r('app.string.heart_rate_value', Math.round(this.todayHr))
          : $r('app.string.heart_rate_empty'))
          .fontSize(13)
          .fontColor($r('app.color.text_secondary'))
      }
    }
    .width('100%')
    .padding(12)
    .backgroundColor($r('app.color.surface'))
    .borderRadius(12)
  }

  /** 底部导航 5 项，中间「+」突出 */
  @Builder
  bottomNav() {
    Row() {
      this.navItem($r('app.string.nav_chart'), 'pages/ChartPage', false)
      this.navItem($r('app.string.nav_med'), 'pages/MedPage', false)
      this.navItem($r('app.string.nav_add'), 'pages/RecordEditPage', true)
      this.navItem($r('app.string.nav_stats'), 'pages/StatsPage', false)
      this.navItem($r('app.string.nav_settings'), 'pages/SettingsPage', false)
    }
    .width('100%')
    .height(56)
    .backgroundColor($r('app.color.surface'))
    .border({ width: { top: 1 }, color: $r('app.color.divider') })
  }

  @Builder
  navItem(label: Resource, url: string, highlight: boolean) {
    Column() {
      Text(label)
        .fontSize(highlight ? 22 : 13)
        .fontWeight(highlight ? FontWeight.Bold : FontWeight.Normal)
        .fontColor(highlight ? $r('app.color.on_primary') : $r('app.color.text_secondary'))
    }
    .layoutWeight(1)
    .height(highlight ? 40 : 56)
    .justifyContent(FlexAlign.Center)
    .backgroundColor(highlight ? $r('app.color.primary') : Color.Transparent)
    .borderRadius(highlight ? 20 : 0)
    .margin(highlight ? 8 : 0)
    .onClick(() => {
      router.pushUrl({ url: url });
    })
  }
}
