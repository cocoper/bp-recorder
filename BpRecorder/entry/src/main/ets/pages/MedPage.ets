import { common } from '@kit.AbilityKit';
import { router } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { DateUtils } from '../common/DateUtils';
import { Logger } from '../common/Logger';
import { ResUtils } from '../common/ResUtils';
import { VocabFactory } from '../common/Vocab';
import { Medication, MedListRow, MedPlan } from '../model/Med';
import { BpDatabase } from '../service/BpDatabase';
import { MedService } from '../service/MedService';
import { ReminderService } from '../service/ReminderService';

const TAG: string = 'MedPage';

/** 用药管理页（FR-8.1 / FR-8.2 / 策划文档 §5.7） */
@Entry
@Component
struct MedPage {
  @State private rows: MedListRow[] = [];
  @State private loading: boolean = true;
  /** v1.14 提醒自查：有时点要提醒吗 / 通知是否已授权 / 系统里已登记几条有效提醒 */
  @State private hasSlots: boolean = false;
  @State private notifyEnabled: boolean = true;
  @State private reminderCount: number = -1;

  aboutToAppear(): void {
    this.load();
  }

  onPageShow(): void {
    this.load();
  }

  private context(): common.UIAbilityContext {
    return ResUtils.hostContext(this.getUIContext());
  }

  private async load(): Promise<void> {
    this.loading = true;
    try {
      const db: BpDatabase = BpDatabase.getInstance();
      const meds: Medication[] = await db.queryMedications();
      const plans: MedPlan[] = await db.queryPlans();

      const rows: MedListRow[] = [];
      const today: string = DateUtils.formatDate(DateUtils.now());
      for (let i = 0; i < meds.length; i++) {
        const med: Medication = meds[i];
        // 每个药品只保留一条生效计划（FR-8.2）
        let activePlan: MedPlan | null = null;
        for (let j = 0; j < plans.length; j++) {
          if (plans[j].medicationId === med.id && plans[j].isActive) {
            activePlan = plans[j];
            break;
          }
        }
        // v1.15（裁决 D3）：没有生效计划、但存在 end_date 已过的旧计划时，说明它是被
        // 「到期自动停用」的（见 EntryAbility 的前台自愈），而不是用户手动归档 —— 如实标出。
        let expiredLine: string = '';
        if (activePlan === null) {
          const expiredEnd: string | null = MedService.expiredEndDate(plans, med.id, today);
          if (expiredEnd !== null) {
            expiredLine = ResUtils.format(this.context(), $r('app.string.med_plan_auto_expired'), [expiredEnd]);
          }
        }
        rows.push({
          medication: med,
          plan: activePlan,
          active: med.isActive && activePlan !== null,
          dosageLine: this.dosageLine(med, activePlan),
          planLine: this.planLine(activePlan),
          expiredLine: expiredLine
        });
      }
      this.rows = rows;

      // v1.14 提醒自查：有生效计划却发不出提醒时，页面顶部给出可见的修复入口（见 reminderBroken）
      let hasSlots: boolean = false;
      for (let i = 0; i < rows.length; i++) {
        const plan: MedPlan | null = rows[i].plan;
        if (rows[i].active && plan !== null && plan.timeSlots.length > 0) {
          hasSlots = true;
          break;
        }
      }
      this.hasSlots = hasSlots;
      this.notifyEnabled = await ReminderService.isNotificationEnabled();
      this.reminderCount = hasSlots ? await ReminderService.validReminderCount() : -1;
    } catch (err) {
      const e = err as BusinessError;
      Logger.error(TAG, `load medications failed: code=${e.code}, message=${e.message}`);
      this.getUIContext().getPromptAction().showToast({ message: $r('app.string.error_db_read') });
    } finally {
      this.loading = false;
    }
  }

  private dosageLine(med: Medication, plan: MedPlan | null): string {
    const context = this.context();
    const dosage: string = med.dosage.length > 0 ? med.dosage : ResUtils.text(context, $r('app.string.med_dosage_unknown'));
    if (plan === null) {
      return dosage;
    }
    return `${dosage}${ResUtils.text(context, $r('app.string.dot_separator'))}${ResUtils.format(context, $r('app.string.med_per_day'), [plan.timeSlots.length])}`;
  }

  private planLine(plan: MedPlan | null): string {
    const context = this.context();
    if (plan === null) {
      return ResUtils.text(context, $r('app.string.med_no_plan'));
    }
    const slots: string = plan.timeSlots.join(' / ');
    const end: string = plan.endDate === null || plan.endDate.length === 0
      ? ResUtils.text(context, $r('app.string.med_long_term'))
      : ResUtils.format(context, $r('app.string.med_until'), [plan.endDate]);
    return `${slots}${ResUtils.text(context, $r('app.string.dot_separator'))}${end}`;
  }

  private toast(res: Resource): void {
    this.getUIContext().getPromptAction().showToast({ message: res, duration: 2000 });
  }

  /**
   * 提醒是否「看起来没生效」（v1.14）：有时点要提醒，但通知没授权，或系统里一条有效提醒都没有。
   *
   * 两种原因文案不同，不能混为一谈（真机 v1.15 验收发现，见自检报告 §29）：
   * ① 通知未授权 —— `publishReminder` 报 1700001，一条也发不出去，需引导去授权；
   * ② 已授权但系统拒收登记 —— 本机实测为 `1700002 The number of reminders exceeds the limit`，
   *    与本应用已登记的提醒无关（`cancelAllReminders()` 先成功、`getAllValidReminders()` 为 0），
   *    此时「点按钮授权」没有任何作用，文案必须说明是系统侧拒收，按钮只承诺重试。
   */
  private reminderBroken(): boolean {
    return this.hasSlots && (!this.notifyEnabled || this.reminderCount === 0);
  }

  /** 用药页「开启提醒」：申请通知授权 → 重建提醒 → 复查系统登记条数 */
  private async fixReminder(): Promise<void> {
    try {
      const granted: boolean = await ReminderService.ensureNotificationEnabled(this.context());
      if (!granted) {
        this.toast($r('app.string.toast_reminder_need_notification'));
        await this.load();
        return;
      }
      const db: BpDatabase = BpDatabase.getInstance();
      const plans: MedPlan[] = await db.queryActivePlans();
      const meds: Medication[] = await db.queryMedications();
      await ReminderService.rebuildAll(this.context(), plans, meds,
        VocabFactory.reminder(this.context()), DateUtils.now(), true);
      await this.load();
      // 重建后如实回报：系统仍可能因为与本应用无关的原因（如整机提醒配额）拒收登记
      this.toast(this.reminderCount > 0 ? $r('app.string.toast_reminder_fixed') : $r('app.string.toast_reminder_still_broken'));
    } catch (err) {
      const e = err as BusinessError;
      Logger.error(TAG, `fix reminder failed: code=${e.code}, message=${e.message}`);
      this.toast($r('app.string.error_db_write'));
    }
  }

  /** 停用药品档案（归档，历史打卡保留，FR-8.1） */
  private confirmArchive(row: MedListRow): void {
    this.getUIContext().showAlertDialog({
      title: $r('app.string.med_archive_title'),
      message: $r('app.string.med_archive_message'),
      primaryButton: {
        value: $r('app.string.action_cancel'),
        action: () => {
        }
      },
      secondaryButton: {
        value: $r('app.string.med_archive_confirm'),
        action: () => {
          this.doArchive(row);
        }
      }
    });
  }

  private async doArchive(row: MedListRow): Promise<void> {
    try {
      const db: BpDatabase = BpDatabase.getInstance();
      await db.setMedicationActive(row.medication.id, false);
      if (row.plan !== null) {
        await db.deactivatePlan(row.plan.id);
      }
      // 归档后不再产生应服义务，清掉尚未到期的待服记录（P1-3）；历史打卡记录保留
      await db.deleteFuturePendingLogs(row.medication.id, DateUtils.now());
      this.toast($r('app.string.toast_med_archived'));
      await this.load();
    } catch (err) {
      const e = err as BusinessError;
      Logger.error(TAG, `archive failed: code=${e.code}, message=${e.message}`);
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
        Text($r('app.string.title_med'))
          .fontSize(17)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
        Blank()
        Text($r('app.string.action_add'))
          .fontSize(15)
          .fontColor($r('app.color.primary'))
          .onClick(() => {
            router.pushUrl({ url: 'pages/MedPlanEditPage' });
          })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 12, bottom: 12 })

      Scroll() {
        Column({ space: 10 }) {
          if (this.reminderBroken()) {
            Column({ space: 8 }) {
              Text($r('app.string.reminder_warn_title'))
                .fontSize(15)
                .fontWeight(FontWeight.Medium)
                .fontColor($r('app.color.warn_text'))
                .width('100%')
              Text(this.notifyEnabled ? $r('app.string.reminder_warn_text_agent') : $r('app.string.reminder_warn_text'))
                .fontSize(13)
                .lineHeight(19)
                .fontColor($r('app.color.warn_text_secondary'))
                .width('100%')
              Button(this.notifyEnabled ? $r('app.string.reminder_warn_action_retry') : $r('app.string.reminder_warn_action'))
                .height(34)
                .fontSize(14)
                .backgroundColor($r('app.color.primary'))
                .fontColor($r('app.color.on_primary'))
                .onClick(() => {
                  this.fixReminder();
                })
            }
            .width('100%')
            .padding(14)
            .backgroundColor($r('app.color.warn_bg'))
            .borderRadius(12)
            .alignItems(HorizontalAlign.Start)
          }

          if (this.rows.length === 0) {
            Text($r('app.string.med_empty'))
              .fontSize(14)
              .fontColor($r('app.color.text_secondary'))
              .padding({ top: 60 })
          } else {
            ForEach(this.rows, (row: MedListRow) => {
              Column({ space: 4 }) {
                Row() {
                  Text(row.medication.name)
                    .fontSize(16)
                    .fontWeight(FontWeight.Medium)
                    .fontColor(row.active ? $r('app.color.text_primary') : $r('app.color.text_disabled'))
                    .layoutWeight(1)
                  Text(row.active ? $r('app.string.med_status_active') : $r('app.string.med_status_inactive'))
                    .fontSize(12)
                    .fontColor(row.active ? $r('app.color.med_taken') : $r('app.color.text_tertiary'))
                }
                .width('100%')

                Text(row.dosageLine)
                  .fontSize(13)
                  .fontColor(row.active ? $r('app.color.text_secondary') : $r('app.color.text_disabled'))
                  .width('100%')

                Text(row.planLine)
                  .fontSize(13)
                  .fontColor(row.active ? $r('app.color.text_secondary') : $r('app.color.text_disabled'))
                  .width('100%')

                if (row.expiredLine.length > 0) {
                  Text(row.expiredLine)
                    .fontSize(12)
                    .fontColor($r('app.color.warn_text'))
                    .width('100%')
                }

                if (row.medication.note !== null && row.medication.note.length > 0) {
                  Text(row.medication.note)
                    .fontSize(12)
                    .fontColor($r('app.color.text_tertiary'))
                    .width('100%')
                }

                Row({ space: 16 }) {
                  Blank()
                  Text($r('app.string.action_edit'))
                    .fontSize(13)
                    .fontColor($r('app.color.primary'))
                    .onClick(() => {
                      router.pushUrl({
                        url: 'pages/MedPlanEditPage',
                        params: { medicationId: row.medication.id }
                      });
                    })
                  if (row.medication.isActive) {
                    Text($r('app.string.med_archive'))
                      .fontSize(13)
                      .fontColor($r('app.color.danger'))
                      .onClick(() => {
                        this.confirmArchive(row);
                      })
                  }
                }
                .width('100%')
                .margin({ top: 6 })
              }
              .width('100%')
              .padding(14)
              .backgroundColor($r('app.color.surface'))
              .borderRadius(12)
              .alignItems(HorizontalAlign.Start)
              // 键里带上计划 id / 生效位 / 到期说明：ForEach 只在键变化时重建列表项，
              // 只写药品 id 的话「刚编辑完的计划」会一直显示旧内容（真机 v1.15 验收发现，见自检报告 §29）
            }, (row: MedListRow) => `${row.medication.id}_${row.plan === null ? 0 : row.plan.id}_${row.active ? 1 : 0}_${row.expiredLine}`)
          }

          Text($r('app.string.disclaimer_med'))
            .fontSize(12)
            .fontColor($r('app.color.med_missed'))
            .width('100%')
            .textAlign(TextAlign.Center)
            .padding({ top: 12, bottom: 24 })
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
}
