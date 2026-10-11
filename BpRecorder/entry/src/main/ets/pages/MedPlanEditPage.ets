import { common } from '@kit.AbilityKit';
import { router } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { MedLimits } from '../common/Constants';
import { DateUtils } from '../common/DateUtils';
import { Logger } from '../common/Logger';
import { VocabFactory } from '../common/Vocab';
import { Medication, MedicationDraft, MedPlan, MedPlanDraft , ReminderSyncResult } from '../model/Med';
import { BpDatabase, SaveMedicationPlanResult, TxSession } from '../service/BpDatabase';
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
  /** 审查 R07.3：保存期间禁止重入（快速双击只产生一版计划） */
  private saving: boolean = false;
  /** 审查 R07.4：编辑模式下读取失败时表单是空的，不允许覆盖保存 */
  private loadFailed: boolean = false;
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
      // 编辑模式下读不到真实档案：标记失败，save() 会拒绝提交（避免空表单覆盖真实数据）
      if (this.medicationId > 0) {
        this.loadFailed = true;
      }
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

  /**
   * 保存：走 BpDatabase.saveMedicationAndPlan 领域命令（审查 R07）——
   * 药品、计划、受影响待服、生成结果在**一个事务**里提交；提醒在提交后单独协调。
   */
  private async save(): Promise<void> {
    if (this.saving) {
      return;
    }
    if (!this.isValid()) {
      return;
    }
    if (this.medicationId > 0 && this.loadFailed) {
      this.toast($r('app.string.error_db_read'));
      return;
    }
    this.saving = true;
    const db: BpDatabase = BpDatabase.getInstance();
    const now: number = DateUtils.now();
    try {
      const noteText: string = this.note.trim();
      const result: SaveMedicationPlanResult = await db.saveMedicationAndPlan({
        medicationId: this.medicationId,
        medication: {
          name: this.name.trim(),
          dosage: this.dosage.trim(),
          note: noteText.length === 0 ? null : noteText
        },
        plan: {
          medicationId: this.medicationId,
          timeSlots: MedService.normalizeSlots(this.slots),
          startDate: this.startDate,
          endDate: this.longTerm ? null : this.endDate
        },
        regenerateFrom: now,
        preGenDays: MedLimits.PRE_GEN_DAYS
      }, async (tx: TxSession, medicationId: number): Promise<number> => {
        const plans: MedPlan[] = await db.queryActivePlans();
        const meds: Medication[] = await db.queryMedications();
        return db.insertMissingLogs(MedService.pendingDrafts(plans, meds, now, MedLimits.PRE_GEN_DAYS), tx);
      });

      // 只有提交成功后才更新页面状态（失败时页面仍指向旧对象）
      this.medicationId = result.medicationId;
      this.planId = result.planId;
      Logger.info(TAG, `plan saved: med=${result.medicationId}, plan=${result.planId}, cleared=${result.clearedPending}, generated=${result.generatedPending}`);

      // 提交之后再协调系统提醒：数据库与通知系统没有共同事务边界（报告规则 6 / R07）
      const notifyGranted: boolean = await ReminderService.ensureNotificationEnabled(this.context());
      const plans: MedPlan[] = await db.queryActivePlans();
      const meds: Medication[] = await db.queryMedications();
      await ReminderService.rebuildAll(this.context(), plans, meds, VocabFactory.reminder(this.context()), now, true);

      if (this.slots.length > 0 && !notifyGranted) {
        this.toast($r('app.string.toast_reminder_need_notification'));
      } else {
        this.toast($r('app.string.toast_med_saved'));
      }
      router.back();
    } catch (err) {
      const e = err as BusinessError;
      Logger.error(TAG, `save plan failed: code=${e.code}, message=${e.message}`);
      this.toast($r('app.string.error_db_write'));
    } finally {
      this.saving = false;
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
      // 审查 R02：停用走统一领域命令（档案停用 + 计划停用 + 清未来待服，一个事务），
      // 然后按**最新全量生效计划**协调提醒 —— 过去这里直接 cancelAll()，
      // 结果是把其他药品的提醒也一起取消了。
      await db.archiveMedication(this.medicationId, DateUtils.now());
      const result: ReminderSyncResult = await ReminderService.syncFromDatabase(this.context(), db,
        VocabFactory.reminder(this.context()), DateUtils.now());
      Logger.info(TAG, `plan deactivated: med=${this.medicationId}, reminder status=${result.status}, registered=${result.registered}/${result.expected}`);
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
