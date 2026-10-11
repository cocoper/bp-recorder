import { common } from '@kit.AbilityKit';
import { router } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { Disclaimers, RefBasis } from '../common/Constants';
import { DateUtils } from '../common/DateUtils';
import { Logger } from '../common/Logger';
import { Prefs } from '../common/Prefs';
import { ResUtils } from '../common/ResUtils';
import { ReminderText } from '../common/Constants';
import { VocabFactory } from '../common/Vocab';
import { Medication, MedPlan, PlanExportRow, ReminderCapability } from '../model/Med';
import { GradeStandard, ReminderMode } from '../model/Types';
import { BpDatabase } from '../service/BpDatabase';
import { ExportService, ExportRangeKind } from '../service/ExportService';
import { BackupService } from '../service/BackupService';
import { BackupFile } from '../model/Backup';
import { FileService } from '../service/FileService';
import { ReminderService } from '../service/ReminderService';
import { LifecycleResult, MedLifecycleService } from '../service/MedLifecycleService';
import { ClearDataDialog } from '../components/ClearDataDialog';
import { SettingRow } from '../components/SettingRow';

const TAG: string = 'SettingsPage';
const APP_VERSION: string = '1.0.0';

/** 设置页（FR-7 / FR-9.1 / FR-6 / 策划文档 §5.5、§5.9） */
/** 恢复前从库里取出的「已有身份」集合（审查 R10：用于冲突预览与新增/覆盖计数） */
interface ExistingSets {
  medIds: Set<number>;
  planIds: Set<number>;
  logKeys: Set<string>;
  bpKeys: Set<string>;
}

@Entry
@Component
struct SettingsPage {
  /** 参考口径（原「分级标准」）：只影响主参考线与参考文案，不影响分级色标（决策 D1） */
  @State private standard: GradeStandard = RefBasis.DEFAULT;
  @State private reminderMode: ReminderMode = ReminderMode.DENIED;
  @State private notificationEnabled: boolean = false;
  /** v1.14 提醒自查：系统里仍有效的代理提醒条数（-1 = 查询失败）与最近一次探测详情（含错误码） */
  @State private reminderCount: number = -1;
  @State private reminderDetail: string = '';
  @State private checking: boolean = false;

  private clearDialog: CustomDialogController | null = null;

  aboutToAppear(): void {
    const context = this.context();
    this.standard = Prefs.standard(context);
    this.probeReminder(false);
  }

  private context(): common.UIAbilityContext {
    return ResUtils.hostContext(this.getUIContext());
  }

  private toast(res: Resource): void {
    this.getUIContext().getPromptAction().showToast({ message: res, duration: 2000 });
  }

  private async probeReminder(force: boolean): Promise<void> {
    this.checking = true;
    try {
      const capability: ReminderCapability = await ReminderService.probe(
        this.context(), force, VocabFactory.reminder(this.context()));
      this.reminderMode = capability.mode;
      this.notificationEnabled = capability.notificationEnabled;
      this.reminderDetail = capability.detail;
      this.reminderCount = await ReminderService.validReminderCount();
      if (force) {
        await this.rebuildFromSettings();
      }
    } catch (err) {
      const e = err as BusinessError;
      Logger.error(TAG, `probe reminder failed: code=${e.code}, message=${e.message}`);
    } finally {
      this.checking = false;
    }
  }

  private async rebuildFromSettings(): Promise<void> {
    const db: BpDatabase = BpDatabase.getInstance();
    const plans: MedPlan[] = await db.queryActivePlans();
    const meds: Medication[] = await db.queryMedications();
    await ReminderService.rebuildAll(this.context(), plans, meds,
      VocabFactory.reminder(this.context()), DateUtils.now(), true);
  }

  private pickStandard(): void {
    this.getUIContext().showActionSheet({
      title: $r('app.string.settings_grade_standard'),
      message: $r('app.string.sheet_msg_grade_standard'),
      sheets: [
        {
          title: $r('app.string.grade_standard_cn'),
          action: () => {
            this.applyStandard(GradeStandard.CN_GUIDELINE);
          }
        },
        {
          title: $r('app.string.grade_standard_home'),
          action: () => {
            this.applyStandard(GradeStandard.HOME_MONITOR);
          }
        }
      ]
    });
  }

  private applyStandard(value: GradeStandard): void {
    this.standard = value;
    Prefs.setStandard(this.context(), value);
    this.toast($r('app.string.toast_standard_changed'));
  }

  private async exportBp(kind: string): Promise<void> {
    const context = this.context();
    try {
      const db: BpDatabase = BpDatabase.getInstance();
      const all = await db.queryBpAll();
      const now: number = DateUtils.now();
      const scoped = ExportService.filterBpByRange(all, kind, now);
      const csv: string = ExportService.buildBpCsv(scoped, VocabFactory.csv(context));
      const target: string | null = await FileService.pickSaveTarget(context, FileService.stampName('bp_export_', '.csv', now));
      if (target === null) {
        return;
      }
      await FileService.writeText(target, csv);
      this.toast($r('app.string.toast_export_done', scoped.length));
    } catch (err) {
      const e = err as BusinessError;
      Logger.error(TAG, `export bp failed: code=${e.code}, message=${e.message}`);
      this.toast($r('app.string.error_export'));
    }
  }

  /**
   * 导出完整备份（审查 R10）：JSON 单文件，四表逐字段、含稳定 ID/启停状态/毫秒时间。
   * 这是唯一能兑现「换机完整恢复」的载体；三份 CSV 只是交换格式。
   */
  private async exportBackup(): Promise<void> {
    const context = this.context();
    try {
      const db: BpDatabase = BpDatabase.getInstance();
      const bp = await db.queryBpAll();
      const meds = await db.queryMedications();
      const plans = await db.queryPlans();
      const logs = await db.queryMedLogsAll();
      const now: number = DateUtils.now();
      const file: BackupFile = BackupService.build(bp, meds, plans, logs, APP_VERSION, now);
      const text: string = BackupService.serialize(file);
      const target: string | null = await FileService.pickSaveTarget(context, FileService.stampName('bp_backup_', '.json', now));
      if (target === null) {
        return;
      }
      await FileService.writeText(target, text);
      const total: number = file.meta.counts.bp + file.meta.counts.meds + file.meta.counts.plans + file.meta.counts.logs;
      this.toast($r('app.string.toast_backup_done', total));
    } catch (err) {
      const e = err as BusinessError;
      Logger.error(TAG, `export backup failed: code=${e.code}, message=${e.message}`);
      this.toast($r('app.string.error_export'));
    }
  }

  /** 从完整备份恢复：解析 → 逐字段校验 → 冲突预览 → 用户确认 → 单事务写入 → 统一重新协调提醒 */
  private async importBackup(): Promise<void> {
    const context = this.context();
    try {
      const picked = await FileService.pickDocument(context, '.json');
      if (picked === null) {
        return;
      }
      const text: string = await FileService.readText(picked.uri);
      const parsed = BackupService.parse(text);
      if (parsed.file === null) {
        for (let i = 0; i < parsed.issues.length; i++) {
          Logger.warn(TAG, `backup rejected: ${parsed.issues[i].path} ${parsed.issues[i].reason}`);
        }
        this.toast($r('app.string.error_backup_format'));
        return;
      }
      const file: BackupFile = parsed.file;
      const db: BpDatabase = BpDatabase.getInstance();
      const existing: ExistingSets = await this.collectExisting(db);
      const add = file.bp.length + file.meds.length + file.plans.length + file.logs.length;
      const preview = BackupService.preview(file, existing.medIds, existing.planIds, existing.logKeys, existing.bpKeys);
      if (!preview.restorable) {
        Logger.warn(TAG, `backup not restorable: issues=${preview.issues.length}`);
        this.toast($r('app.string.error_backup_format'));
        return;
      }
      const addTotal: number = preview.addCounts.bp + preview.addCounts.meds + preview.addCounts.plans + preview.addCounts.logs;
      const overTotal: number = preview.overwriteCounts.bp + preview.overwriteCounts.meds
        + preview.overwriteCounts.plans + preview.overwriteCounts.logs;
      this.getUIContext().showAlertDialog({
        title: $r('app.string.backup_restore_title'),
        message: $r('app.string.backup_restore_counts', addTotal, overTotal, preview.internalDuplicates),
        autoCancel: true,
        primaryButton: {
          value: $r('app.string.action_cancel'),
          action: () => {}
        },
        secondaryButton: {
          value: $r('app.string.action_restore'),
          action: () => {
            this.doRestore(file, db, existing);
          }
        }
      });
    } catch (err) {
      const e = err as BusinessError;
      Logger.error(TAG, `import backup failed: code=${e.code}, message=${e.message}`);
      this.toast($r('app.string.error_backup_format'));
    }
  }

  /** 实际执行恢复：单次事务写四表；成功后统一重新协调提醒（报告 R10.3） */
  private async doRestore(file: BackupFile, db: BpDatabase, existing: ExistingSets): Promise<void> {
    const context = this.context();
    try {
      const result = await BackupService.restore(db, file, existing.medIds, existing.planIds,
        existing.logKeys, existing.bpKeys);
      if (result.issues.length > 0) {
        Logger.error(TAG, `restore aborted: issues=${result.issues.length}`);
        this.toast($r('app.string.error_backup_restore'));
        return;
      }
      const added: number = result.added.bp + result.added.meds + result.added.plans + result.added.logs;
      const overwritten: number = result.overwritten.bp + result.overwritten.meds
        + result.overwritten.plans + result.overwritten.logs;
      Logger.info(TAG, `restore done: added=${added}, overwritten=${overwritten}, ignored=${result.ignored}`);
      // 审查 R10.4：提交完成后**统一补齐 + 调度** —— 恢复过程本身不生成 pending、不发提醒。
      // 先补齐应服记录（滚动补齐 → 派生漏服 → 停用到期计划），再按最新全量生效计划协调提醒；
      // 顺序不能颠倒：提醒要按补齐后的真实义务集合来登记。
      const now: number = DateUtils.now();
      const lifecycle: LifecycleResult = await MedLifecycleService.run(db, now);
      Logger.info(TAG, `post-restore lifecycle: backfilled=${lifecycle.backfilled}, missed=${lifecycle.markedMissed}, deactivated=${lifecycle.deactivatedPlans}`);
      await ReminderService.syncFromDatabase(context, db, VocabFactory.reminder(context), now);
      this.toast($r('app.string.toast_restore_done', added, overwritten, result.ignored));
    } catch (err) {
      const e = err as BusinessError;
      Logger.error(TAG, `restore failed: code=${e.code}, message=${e.message}`);
      this.toast($r('app.string.error_backup_restore'));
    }
  }

  /** 取库内已有的稳定身份集合（用于冲突预览与计数） */
  private async collectExisting(db: BpDatabase): Promise<ExistingSets> {
    const meds: Medication[] = await db.queryMedications();
    const plans: MedPlan[] = await db.queryPlans();
    const logTuples = await db.queryMedLogDedupeTuples();
    const bpTuples = await db.queryBpDedupeTuples();
    const medIds: Set<number> = new Set<number>();
    for (let i = 0; i < meds.length; i++) {
      medIds.add(meds[i].id);
    }
    const planIds: Set<number> = new Set<number>();
    for (let i = 0; i < plans.length; i++) {
      planIds.add(plans[i].id);
    }
    const logKeys: Set<string> = new Set<string>();
    for (let i = 0; i < logTuples.length; i++) {
      logKeys.add(`${logTuples[i].medicationId}_${logTuples[i].scheduledTime}`);
    }
    const bpKeys: Set<string> = new Set<string>();
    for (let i = 0; i < bpTuples.length; i++) {
      bpKeys.add(`${bpTuples[i].measureTime}_${bpTuples[i].systolic}_${bpTuples[i].diastolic}`);
    }
    return { medIds: medIds, planIds: planIds, logKeys: logKeys, bpKeys: bpKeys };
  }

  /**
   * 完整备份面板（审查 R10.6）：单独入口 + 明确说明「三份 CSV 只是交换格式，
   * 不能作为卸载/清空前的可靠恢复保证」，避免用户把 CSV 当备份用。
   */
  private openBackupSheet(): void {
    this.getUIContext().showActionSheet({
      title: $r('app.string.backup_sheet_title'),
      message: $r('app.string.backup_sheet_msg'),
      sheets: [
        { title: $r('app.string.settings_backup_export'), action: () => this.exportBackup() },
        { title: $r('app.string.settings_backup_import'), action: () => this.importBackup() }
      ]
    });
  }

  private openExportSheet(): void {
    this.getUIContext().showActionSheet({
      title: $r('app.string.settings_export'),
      message: $r('app.string.sheet_msg_export'),
      sheets: [
        { title: $r('app.string.export_range_all'), action: () => this.exportBp(ExportRangeKind.ALL) },
        { title: $r('app.string.export_range_30'), action: () => this.exportBp(ExportRangeKind.D30) },
        { title: $r('app.string.export_range_90'), action: () => this.exportBp(ExportRangeKind.D90) },
        { title: $r('app.string.export_med_csv'), action: () => this.exportMed() },
        { title: $r('app.string.export_plan_csv'), action: () => this.exportPlan() }
      ]
    });
  }

  /**
   * 导出用药计划 CSV（v1.3 审查意见 P1-9）。
   * 与血压、打卡两个 CSV 合起来构成完整的换机迁移三件套。
   */
  private async exportPlan(): Promise<void> {
    const context = this.context();
    try {
      const db: BpDatabase = BpDatabase.getInstance();
      const meds: Medication[] = await db.queryMedications();
      const plans: MedPlan[] = await db.queryPlans();

      const medById: Map<number, Medication> = new Map<number, Medication>();
      for (let i = 0; i < meds.length; i++) {
        medById.set(meds[i].id, meds[i]);
      }

      const rows: PlanExportRow[] = [];
      for (let i = 0; i < plans.length; i++) {
        const p: MedPlan = plans[i];
        if (!p.isActive) {
          continue;
        }
        const med: Medication | undefined = medById.get(p.medicationId);
        if (med === undefined) {
          continue;
        }
        rows.push({
          medName: med.name,
          dosage: med.dosage,
          timeSlots: p.timeSlots,
          startDate: p.startDate,
          endDate: p.endDate,
          note: med.note
        });
      }

      const now: number = DateUtils.now();
      const csv: string = ExportService.buildPlanCsv(rows, VocabFactory.csv(context));
      const target: string | null = await FileService.pickSaveTarget(context,
        FileService.stampName('med_plan_', '.csv', now));
      if (target === null) {
        return;
      }
      await FileService.writeText(target, csv);
      this.toast($r('app.string.toast_export_done', rows.length));
    } catch (err) {
      const e = err as BusinessError;
      Logger.error(TAG, `export plan failed: code=${e.code}, message=${e.message}`);
      this.toast($r('app.string.error_export'));
    }
  }

  private async exportMed(): Promise<void> {
    const context = this.context();
    try {
      const db: BpDatabase = BpDatabase.getInstance();
      const logs = await db.queryMedLogsAll();
      const now: number = DateUtils.now();
      const csv: string = ExportService.buildMedCsv(logs, VocabFactory.csv(context));
      const target: string | null = await FileService.pickSaveTarget(context, FileService.stampName('med_export_', '.csv', now));
      if (target === null) {
        return;
      }
      await FileService.writeText(target, csv);
      this.toast($r('app.string.toast_export_done', logs.length));
    } catch (err) {
      const e = err as BusinessError;
      Logger.error(TAG, `export med failed: code=${e.code}, message=${e.message}`);
      this.toast($r('app.string.error_export'));
    }
  }

  private showDisclaimer(): void {
    this.getUIContext().showAlertDialog({
      title: $r('app.string.disclaimer_title'),
      message: ResUtils.text(this.context(), Disclaimers.FULL),
      confirm: {
        value: $r('app.string.action_got_it'),
        action: () => {
        }
      }
    });
  }

  private showAbout(): void {
    const context = this.context();
    this.getUIContext().showAlertDialog({
      title: $r('app.string.settings_about'),
      message: `${ResUtils.text(context, $r('app.string.about_version'))} ${APP_VERSION}\n\n${ResUtils.text(context, Disclaimers.FULL)}`,
      confirm: {
        value: $r('app.string.action_got_it'),
        action: () => {
        }
      }
    });
  }

  private openClearDialog(): void {
    this.clearDialog = new CustomDialogController({
      builder: ClearDataDialog({
        onConfirm: () => {
          this.doClearAll();
        }
      }),
      autoCancel: true,
      alignment: DialogAlignment.Center
    });
    this.clearDialog.open();
  }

  /** 清空全部业务数据（血压 + 用药），单事务执行；Settings 保留分级标准 */
  private async doClearAll(): Promise<void> {
    try {
      await BpDatabase.getInstance().clearAll();
      await ReminderService.cancelAll();
      Prefs.resetDisclaimer(this.context());
      this.toast($r('app.string.toast_cleared'));
    } catch (err) {
      const e = err as BusinessError;
      Logger.error(TAG, `clear all failed: code=${e.code}, message=${e.message}`);
      this.toast($r('app.string.error_db_write'));
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
        Text($r('app.string.title_settings'))
          .fontSize(17)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
        Blank()
        Text(' ')
          .fontSize(15)
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 12, bottom: 12 })

      Scroll() {
        Column({ space: 12 }) {
          Column() {
            SettingRow({
              label: $r('app.string.settings_reminder_mode'),
              hasValue: true,
              value: ReminderText.label(this.reminderMode),
              onTap: () => {
                this.probeReminder(true);
              }
            })
            Divider().color($r('app.color.divider'))
            SettingRow({
              label: $r('app.string.settings_notification'),
              hasValue: true,
              value: this.notificationEnabled ? $r('app.string.state_enabled') : $r('app.string.state_disabled'),
              onTap: () => {
                this.requestNotification();
              }
            })
            Divider().color($r('app.color.divider'))
            SettingRow({
              label: $r('app.string.settings_reminder_count'),
              hasValue: true,
              value: this.reminderCount >= 0
                ? $r('app.string.reminder_count_value', this.reminderCount)
                : $r('app.string.metric_placeholder'),
              onTap: () => {
                this.probeReminder(true);
              }
            })
          }
          .width('100%')
          .backgroundColor($r('app.color.surface'))
          .borderRadius(12)

          Column() {
            SettingRow({
              label: $r('app.string.settings_grade_standard'),
              hasValue: true,
              value: this.standard === GradeStandard.HOME_MONITOR
                ? $r('app.string.grade_standard_home')
                : $r('app.string.grade_standard_cn'),
              onTap: () => {
                this.pickStandard();
              }
            })
            Divider().color($r('app.color.divider'))
            SettingRow({
              label: $r('app.string.settings_export'),
              onTap: () => {
                this.openExportSheet();
              }
            })
            Divider().color($r('app.color.divider'))
            SettingRow({
              label: $r('app.string.settings_import'),
              onTap: () => {
                router.pushUrl({ url: 'pages/ImportPage' });
              }
            })
            Divider().color($r('app.color.divider'))
            SettingRow({
              label: $r('app.string.settings_clear'),
              danger: true,
              onTap: () => {
                this.openClearDialog();
              }
            })
          }
          .width('100%')
          .backgroundColor($r('app.color.surface'))
          .borderRadius(12)

          Column() {
            SettingRow({
              label: $r('app.string.settings_backup_export'),
              onTap: () => {
                this.openBackupSheet();
              }
            })
            Divider().color($r('app.color.divider'))
            SettingRow({
              label: $r('app.string.settings_backup_import'),
              onTap: () => {
                this.importBackup();
              }
            })
            Divider().color($r('app.color.divider'))
            SettingRow({
              label: $r('app.string.settings_disclaimer'),
              onTap: () => {
                this.showDisclaimer();
              }
            })
            Divider().color($r('app.color.divider'))
            SettingRow({
              label: $r('app.string.settings_about'),
              hasValue: true,
              value: $r('app.string.about_version_value', APP_VERSION),
              onTap: () => {
                this.showAbout();
              }
            })
          }
          .width('100%')
          .backgroundColor($r('app.color.surface'))
          .borderRadius(12)

          if (this.reminderMode !== ReminderMode.AGENT) {
            Text(this.reminderMode === ReminderMode.DENIED
              ? $r('app.string.reminder_denied_hint')
              : $r('app.string.reminder_fallback_hint'))
              .fontSize(12)
              .lineHeight(18)
              .fontColor($r('app.color.text_tertiary'))
              .width('100%')
            if (this.reminderDetail.length > 0 && this.reminderDetail !== 'cached') {
              // 探测详情含系统错误码（如 code=1700001 通知未使能），是排查「提醒不响」最直接的一手信息
              Text(`${ResUtils.text(this.context(), $r('app.string.settings_reminder_detail'))}：${this.reminderDetail}`)
                .fontSize(11)
                .lineHeight(16)
                .fontColor($r('app.color.text_tertiary'))
                .width('100%')
            }
          }

          Text($r('app.string.disclaimer_med'))
            .fontSize(11)
            .fontColor($r('app.color.text_tertiary'))
            .width('100%')
            .textAlign(TextAlign.Center)
            .padding({ top: 8, bottom: 24 })
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

  private async requestNotification(): Promise<void> {
    if (this.notificationEnabled) {
      // 已开启时跳系统设置页由用户自行关闭，避免误关导致提醒失效
      this.toast($r('app.string.toast_notification_on'));
      return;
    }
    const granted: boolean = await ReminderService.requestEnable(this.context());
    this.notificationEnabled = await ReminderService.isNotificationEnabled();
    if (!granted && !this.notificationEnabled) {
      this.toast($r('app.string.toast_notification_denied'));
    }
    await this.probeReminder(true);
  }
}
