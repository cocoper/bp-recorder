import { common } from '@kit.AbilityKit';
import { router } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { MedLimits } from '../common/Constants';
import { DateUtils } from '../common/DateUtils';
import { Logger } from '../common/Logger';
import { VocabFactory } from '../common/Vocab';
import { Medication, MedicationDraft, MedPlan, MedPlanDraft } from '../model/Med';
import { BpDatabase } from '../service/BpDatabase';
import { MedService } from '../service/MedService';
import { ReminderService } from '../service/ReminderService';
import { LabeledInput } from '../components/LabeledInput';
import { ResUtils } from '../common/ResUtils';

const TAG: string = 'MedPlanEditPage';

interface MedPlanEditParams {
  medicationId?: number;
}

/** 药品 / 服药计划编辑页（FR-8.1 / FR-8.2 / 策划文档 §5.7） */
@Entry
@Component
struct MedPlanEditPage {
  @State private medicationId: number = 0;
  @State private planId: number = 0;
  @State private name: string = '';
  @State private dosage: string = '';
  @State private note: string = '';
  @State private slotCount: number = 1;
  @State private slots: string[] = ['07:30'];
  @State private startDate: string = DateUtils.formatDate(DateUtils.now());
  @State private longTerm: boolean = true;
  @State private endDate: string = DateUtils.formatDate(DateUtils.addDays(DateUtils.now(), 30));

  @State private errName: Resource | null = null;
  @State private errDosage: Resource | null = null;
  @State private errSlots: Resource | null = null;
  @State private errStart: Resource | null = null;
  @State private errEnd: Resource | null = null;

  private readonly countOptions: number[] = [1, 2, 3, 4];
  /** 增加次数时的默认时间点，避免用户逐个手填 */
  private readonly defaultSlots: string[] = ['07:30', '12:00', '18:00', '22:00'];

  aboutToAppear(): void {
    const params = router.getParams() as MedPlanEditParams;
    if (params === null || params === undefined || params.medicationId === undefined) {
      return;
    }
    this.medicationId = params.medicationId;
    this.load();
  }

  private context(): common.UIAbilityContext {
    return ResUtils.hostContext(this.getUIContext());
  }

  private async load(): Promise<void> {
    try {
      const db: BpDatabase = BpDatabase.getInstance();
      const meds: Medication[] = await db.queryMedications();
      for (let i = 0; i < meds.length; i++) {
        if (meds[i].id === this.medicationId) {
          this.name = meds[i].name;
          this.dosage = meds[i].dosage;
          // 用 ?? 而非三元：ArkTS 对两次独立的 meds[i].note 访问不做类型收窄，
          // 写成 `note === null ? '' : note` 会被判为 string | null 不可赋给 string
          this.note = meds[i].note ?? '';
        }
      }
      const plans: MedPlan[] = await db.queryPlans();
      for (let i = 0; i < plans.length; i++) {
        const p: MedPlan = plans[i];
        if (p.medicationId === this.medicationId && p.isActive) {
          this.planId = p.id;
          this.slots = p.timeSlots.length > 0 ? p.timeSlots.slice() : ['07:30'];
          this.slotCount = this.slots.length;
          this.startDate = p.startDate;
          this.longTerm = p.endDate === null || p.endDate.length === 0;
          if (!this.longTerm && p.endDate !== null) {
            this.endDate = p.endDate;
          }
          break;
        }
      }
    } catch (err) {
      const e = err as BusinessError;
      Logger.error(TAG, `load plan failed: code=${e.code}, message=${e.message}`);
    }
  }

  private toast(res: Resource): void {
    this.getUIContext().getPromptAction().showToast({ message: res, duration: 2000 });
  }

  private resolveErr(res: Resource | null): Resource {
    return res === null ? $r('app.string.placeholder_empty') : res;
  }

  /** 每日次数变化时联动时间点数量（CL-8：次数与时间点联动校验） */
  private applySlotCount(count: number): void {
    this.slotCount = count;
    const next: string[] = [];
    for (let i = 0; i < count; i++) {
      next.push(i < this.slots.length ? this.slots[i] : this.defaultSlots[i]);
    }
    this.slots = next;
    this.revalidate();
  }

  private revalidate(): void {
    const medResult = MedService.validateMedicationForm(this.name, this.dosage, this.note);
    this.errName = medResult.fieldErrors.get(MedService.FIELD_NAME) ?? null;
    this.errDosage = medResult.fieldErrors.get(MedService.FIELD_DOSAGE) ?? null;

    const endValue: string | null = this.longTerm ? null : this.endDate;
    const planResult = MedService.validatePlanForm(this.slots, this.startDate, endValue);
    this.errSlots = planResult.fieldErrors.get(MedService.FIELD_SLOTS) ?? null;
    this.errStart = planResult.fieldErrors.get(MedService.FIELD_START) ?? null;
    this.errEnd = planResult.fieldErrors.get(MedService.FIELD_END) ?? null;
  }

  private isValid(): boolean {
    this.revalidate();
    return this.errName === null && this.errDosage === null && this.errSlots === null
      && this.errStart === null && this.errEnd === null;
  }

  private pickSlotTime(index: number): void {
    const minutes: number = DateUtils.hhmmToMinutes(this.slots[index]);
    const h: number = minutes < 0 ? 8 : Math.floor(minutes / 60);
    const m: number = minutes < 0 ? 0 : minutes % 60;
    this.getUIContext().showTimePickerDialog({
      selected: new Date(1970, 0, 1, h, m),
      onAccept: (value: TimePickerResult) => {
        const next: string[] = this.slots.slice();
        next[index] = DateUtils.minutesToHhmm(value.hour * 60 + value.minute);
        this.slots = next;
        this.revalidate();
      }
    });
  }

  private pickStartDate(): void {
    const selected: number | null = DateUtils.parseDate(this.startDate);
    this.getUIContext().showDatePickerDialog({
      selected: new Date(selected === null ? DateUtils.now() : selected),
      start: new Date(2000, 0, 1),
      end: new Date(2100, 11, 31),
      onDateAccept: (value: Date) => {
        this.startDate = DateUtils.formatDate(value.getTime());
        this.revalidate();
      }
    });
  }

  private pickEndDate(): void {
    const selected: number | null = DateUtils.parseDate(this.endDate);
    this.getUIContext().showDatePickerDialog({
      selected: new Date(selected === null ? DateUtils.now() : selected),
      start: new Date(2000, 0, 1),
      end: new Date(2100, 11, 31),
      onDateAccept: (value: Date) => {
        this.endDate = DateUtils.formatDate(value.getTime());
        this.revalidate();
      }
    });
  }

  private async save(): Promise<void> {
    if (!this.isValid()) {
      return;
    }
    const db: BpDatabase = BpDatabase.getInstance();
    const now: number = DateUtils.now();
    try {
      const medDraft: MedicationDraft = {
        name: this.name.trim(),
        dosage: this.dosage.trim(),
        note: this.note.trim().length === 0 ? null : this.note.trim()
      };

      if (this.medicationId > 0) {
        const existing: Medication = {
          id: this.medicationId,
          name: medDraft.name,
          dosage: medDraft.dosage,
          note: medDraft.note,
          isActive: true,
          createdAt: 0,
          updatedAt: now
        };
        await db.updateMedication(existing);
      } else {
        this.medicationId = await db.insertMedication(medDraft, true);
      }

      // 计划规范化：去重 + 升序（避免重复时间点导致提醒冲突，CL-8）
      const planDraft: MedPlanDraft = {
        medicationId: this.medicationId,
        timeSlots: MedService.normalizeSlots(this.slots),
        startDate: this.startDate,
        endDate: this.longTerm ? null : this.endDate
      };
      // 旧计划置为停用而非删除，历史打卡不受影响（FR-8.3）
      this.planId = await db.upsertPlan(planDraft);

      // 计划已变更：先清掉按旧计划预生成、且尚未到期的待服记录，
      // 再按新计划重新生成，避免「计划已改、旧提醒与旧卡片还在」（v1.3 审查意见 P1-3）
      const cleared: number = await db.deleteFuturePendingLogs(this.medicationId, now);
      Logger.info(TAG, `plan changed, cleared ${cleared} stale future pending logs`);

      // 计划变更后：重建提醒（含合并同一时间点）并重新滚动预生成打卡记录。
      // v1.14：代理提醒必须先获得通知授权，否则 publishReminder 报 1700001「Notification is not enabled」，
      // 结果是「设了提醒却永远不响」。用户刚设完提醒时间，正是申请授权的时机 —— 先确保授权再重建。
      const notifyGranted: boolean = await ReminderService.ensureNotificationEnabled(this.context());
      const plans: MedPlan[] = await db.queryActivePlans();
      const meds: Medication[] = await db.queryMedications();
      await ReminderService.rebuildAll(this.context(), plans, meds, VocabFactory.reminder(this.context()), now, true);
      await db.insertMissingLogs(MedService.pendingDrafts(plans, meds, now, MedLimits.PRE_GEN_DAYS));

      if (this.slots.length > 0 && !notifyGranted) {
        // 提醒是这个页面的核心承诺：没拿到授权时必须说清楚，不能只提示「已保存」
        this.toast($r('app.string.toast_reminder_need_notification'));
      } else {
        this.toast($r('app.string.toast_med_saved'));
      }
      router.back();
    } catch (err) {
      const e = err as BusinessError;
      Logger.error(TAG, `save plan failed: code=${e.code}, message=${e.message}`);
      this.toast($r('app.string.error_db_write'));
    }
  }

  private confirmDeactivate(): void {
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
          this.doDeactivate();
        }
      }
    });
  }

  private async doDeactivate(): Promise<void> {
    try {
      const db: BpDatabase = BpDatabase.getInstance();
      if (this.planId > 0) {
        await db.deactivatePlan(this.planId);
      }
      await db.setMedicationActive(this.medicationId, false);
      // 停用后不再存在应服义务，清掉尚未到期的待服记录（P1-3）；历史记录保留
      await db.deleteFuturePendingLogs(this.medicationId, DateUtils.now());
      await ReminderService.cancelAll();
      this.toast($r('app.string.toast_med_archived'));
      router.back();
    } catch (err) {
      const e = err as BusinessError;
      Logger.error(TAG, `deactivate failed: code=${e.code}, message=${e.message}`);
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
        Text($r('app.string.title_med_plan'))
          .fontSize(17)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
        Blank()
        Text($r('app.string.action_save'))
          .fontSize(15)
          .fontColor($r('app.color.primary'))
          .onClick(() => {
            this.save();
          })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 12, bottom: 12 })

      Scroll() {
        Column({ space: 16 }) {
          LabeledInput({
            label: $r('app.string.field_med_name'),
            value: this.name,
            maxLength: MedLimits.NAME_MAX_LEN,
            hasError: this.errName !== null,
            errorText: this.resolveErr(this.errName),
            onValueChange: (v: string) => {
              this.name = v;
              this.revalidate();
            }
          })
          LabeledInput({
            label: $r('app.string.field_med_dosage'),
            value: this.dosage,
            maxLength: MedLimits.DOSAGE_MAX_LEN,
            hasError: this.errDosage !== null,
            errorText: this.resolveErr(this.errDosage),
            onValueChange: (v: string) => {
              this.dosage = v;
              this.revalidate();
            }
          })

          // 每日次数
          Column({ space: 6 }) {
            Text($r('app.string.field_per_day_count'))
              .fontSize(13)
              .fontColor($r('app.color.text_secondary'))
            Row({ space: 8 }) {
              ForEach(this.countOptions, (c: number) => {
                Text(`${c}`)
                  .fontSize(15)
                  .width(40)
                  .height(34)
                  .textAlign(TextAlign.Center)
                  .fontColor(this.slotCount === c ? $r('app.color.on_primary') : $r('app.color.text_primary'))
                  .backgroundColor(this.slotCount === c ? $r('app.color.primary') : $r('app.color.surface'))
                  .borderRadius(8)
                  .border({
                    width: 1,
                    color: this.slotCount === c ? $r('app.color.primary') : $r('app.color.border')
                  })
                  .onClick(() => {
                    this.applySlotCount(c);
                  })
              }, (c: number) => `${c}`)
            }
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)

          // 时间点（数量随每日次数联动）
          Column({ space: 8 }) {
            ForEach(this.slots, (slot: string, index: number) => {
              Row() {
                Text($r('app.string.field_slot_index', index + 1))
                  .fontSize(13)
                  .fontColor($r('app.color.text_secondary'))
                Blank()
                Text(slot)
                  .fontSize(15)
                  .fontColor($r('app.color.text_primary'))
                Text($r('app.string.action_pick'))
                  .fontSize(13)
                  .fontColor($r('app.color.primary'))
                  .margin({ left: 12 })
              }
              .width('100%')
              .padding(12)
              .backgroundColor($r('app.color.surface'))
              .borderRadius(8)
              .onClick(() => {
                this.pickSlotTime(index);
              })
            }, (slot: string, index: number) => `${index}_${slot}`)
            if (this.errSlots !== null) {
              Text(this.errSlots)
                .fontSize(11)
                .fontColor($r('app.color.danger'))
            }
          }
          .width('100%')

          // 开始日期
          Column({ space: 6 }) {
            Text($r('app.string.field_start_date'))
              .fontSize(13)
              .fontColor($r('app.color.text_secondary'))
            Row() {
              Text(this.startDate)
                .fontSize(15)
                .fontColor($r('app.color.text_primary'))
              Blank()
              Text($r('app.string.action_pick'))
                .fontSize(13)
                .fontColor($r('app.color.primary'))
            }
            .width('100%')
            .padding(12)
            .backgroundColor($r('app.color.surface'))
            .borderRadius(8)
            .onClick(() => {
              this.pickStartDate();
            })
            if (this.errStart !== null) {
              Text(this.errStart)
                .fontSize(11)
                .fontColor($r('app.color.danger'))
            }
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)

          // 结束日期（默认长期）
          Column({ space: 6 }) {
            Row() {
              Text($r('app.string.field_end_date'))
                .fontSize(13)
                .fontColor($r('app.color.text_secondary'))
              Blank()
              Toggle({ type: ToggleType.Switch, isOn: this.longTerm })
                .onChange((isOn: boolean) => {
                  this.longTerm = isOn;
                  this.revalidate();
                })
              Text($r('app.string.med_long_term'))
                .fontSize(13)
                .fontColor($r('app.color.text_secondary'))
                .margin({ left: 6 })
            }
            .width('100%')

            if (!this.longTerm) {
              Row() {
                Text(this.endDate)
                  .fontSize(15)
                  .fontColor($r('app.color.text_primary'))
                Blank()
                Text($r('app.string.action_pick'))
                  .fontSize(13)
                  .fontColor($r('app.color.primary'))
              }
              .width('100%')
              .padding(12)
              .backgroundColor($r('app.color.surface'))
              .borderRadius(8)
              .onClick(() => {
                this.pickEndDate();
              })
            }
            if (this.errEnd !== null) {
              Text(this.errEnd)
                .fontSize(11)
                .fontColor($r('app.color.danger'))
            }
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)

          LabeledInput({
            label: $r('app.string.field_note'),
            value: this.note,
            showOptional: true,
            maxLength: MedLimits.NOTE_MAX_LEN,
            onValueChange: (v: string) => {
              this.note = v;
              this.revalidate();
            }
          })

          if (this.medicationId > 0) {
            Button($r('app.string.med_archive_plan'))
              .width('100%')
              .height(44)
              .fontSize(15)
              .backgroundColor($r('app.color.danger_bg'))
              .fontColor($r('app.color.danger'))
              .onClick(() => {
                this.confirmDeactivate();
              })
          }

          Text($r('app.string.disclaimer_med'))
            .fontSize(11)
            .fontColor($r('app.color.text_tertiary'))
            .width('100%')
            .textAlign(TextAlign.Center)
            .padding({ bottom: 24 })
        }
        .width('100%')
        .padding(16)
      }
      .layoutWeight(1)
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_bg'))
  }
}
