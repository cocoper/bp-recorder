import { common } from '@kit.AbilityKit';
import { router } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { BpLimits, PeriodText } from '../common/Constants';
import { DateUtils } from '../common/DateUtils';
import { Logger } from '../common/Logger';
import { Prefs } from '../common/Prefs';
import { BpRecord, BpRecordDraft } from '../model/BpRecord';
import { GradeLevel, Period } from '../model/Types';
import { BpDatabase } from '../service/BpDatabase';
import { BpValidator, BpFormValues } from '../service/BpValidator';
import { GradeService } from '../service/GradeService';
import { GradeAdviceDialog } from '../components/GradeAdviceDialog';
import { NumberField } from '../components/NumberField';
import { ResUtils } from '../common/ResUtils';

const TAG: string = 'RecordEditPage';

/** 路由参数 */
interface RecordEditParams {
  id?: number;
  readonly?: boolean;
}

/**
 * 记录录入 / 编辑 / 只读详情页（FR-1 / 策划文档 §5.2）。
 *
 * 校验规则全部来自 BpValidator（与 CSV 导入共用同一套规则），
 * 校验不通过时对应输入框红色描边 + 红字提示，且「保存」置灰。
 * 保存成功后弹出分级提示卡（FR-5.1），三级时不可滑动关闭（FR-5.2）。
 */
@Entry
@Component
struct RecordEditPage {
  @State private recordId: number = 0;
  @State private viewOnly: boolean = false;
  @State private editing: boolean = false;

  @State private systolicText: string = '';
  @State private diastolicText: string = '';
  @State private heartRateText: string = '';
  @State private measureTime: number = DateUtils.now();
  @State private period: Period = Period.OTHER;
  @State private note: string = '';

  @State private errSys: Resource | null = null;
  @State private errDia: Resource | null = null;
  @State private errHr: Resource | null = null;
  @State private errNote: Resource | null = null;
  @State private errTime: Resource | null = null;
  @State private valid: boolean = false;

  private adviceDialog: CustomDialogController | null = null;

  aboutToAppear(): void {
    const params = router.getParams() as RecordEditParams;
    if (params === null || params === undefined || params.id === undefined) {
      this.resetForm();
      return;
    }
    this.recordId = params.id;
    this.viewOnly = params.readonly === true;
    this.editing = !this.viewOnly;
    this.loadRecord(params.id);
  }

  private context(): common.UIAbilityContext {
    return ResUtils.hostContext(this.getUIContext());
  }

  private resetForm(): void {
    this.recordId = 0;
    this.viewOnly = false;
    this.editing = true;
    this.systolicText = '';
    this.diastolicText = '';
    this.heartRateText = '';
    this.measureTime = DateUtils.now();
    this.period = DateUtils.periodOf(this.measureTime);
    this.note = '';
    this.clearErrors();
  }

  private async loadRecord(id: number): Promise<void> {
    try {
      const record: BpRecord | null = await BpDatabase.getInstance().queryBpById(id);
      if (record === null) {
        this.getUIContext().getPromptAction().showToast({ message: $r('app.string.error_record_missing') });
        router.back();
        return;
      }
      this.systolicText = `${record.systolic}`;
      this.diastolicText = `${record.diastolic}`;
      this.heartRateText = record.heartRate === null ? '' : `${record.heartRate}`;
      this.measureTime = record.measureTime;
      this.period = record.period;
      this.note = record.note === null ? '' : record.note;
      this.clearErrors();
    } catch (err) {
      const e = err as BusinessError;
      Logger.error(TAG, `load record failed: code=${e.code}, message=${e.message}`);
      this.toast($r('app.string.error_db_read'));
    }
  }

  private clearErrors(): void {
    this.errSys = null;
    this.errDia = null;
    this.errHr = null;
    this.errNote = null;
    this.errTime = null;
  }

  private toast(res: Resource): void {
    this.getUIContext().getPromptAction().showToast({ message: res, duration: 2000 });
  }

  /** 可空错误资源 → 非空（hasError 为 false 时占位资源不会被渲染） */
  private resolveErr(res: Resource | null): Resource {
    return res === null ? $r('app.string.placeholder_empty') : res;
  }

  /** 实时校验：驱动「保存」按钮可用状态与字段级错误提示 */
  private revalidate(): void {
    const form: BpFormValues = {
      systolicText: this.systolicText,
      diastolicText: this.diastolicText,
      heartRateText: this.heartRateText,
      measureTime: this.measureTime,
      note: this.note
    };
    const result = BpValidator.validateForm(form, DateUtils.now());
    this.errSys = result.fieldErrors.get(BpValidator.FIELD_SYSTOLIC) ?? null;
    this.errDia = result.fieldErrors.get(BpValidator.FIELD_DIASTOLIC) ?? null;
    this.errHr = result.fieldErrors.get(BpValidator.FIELD_HEART_RATE) ?? null;
    this.errNote = result.fieldErrors.get(BpValidator.FIELD_NOTE) ?? null;
    this.errTime = result.fieldErrors.get(BpValidator.FIELD_TIME) ?? null;
    this.valid = result.ok;
  }

  private async save(): Promise<void> {
    this.revalidate();
    if (!this.valid) {
      return;
    }
    const sys: number = BpValidator.parsePositiveInt(this.systolicText) ?? 0;
    const dia: number = BpValidator.parsePositiveInt(this.diastolicText) ?? 0;
    const hrText: string = this.heartRateText.trim();
    const hr: number | null = hrText.length === 0 ? null : BpValidator.parsePositiveInt(hrText);
    const noteText: string = this.note.trim();
    const note: string | null = noteText.length === 0 ? null : noteText;

    const db: BpDatabase = BpDatabase.getInstance();
    try {
      // 判重前置检查：同一「测量时间 + 收缩压 + 舒张压」已存在时给出明确提示，
      // 而不是让数据库唯一索引抛出约束错误（v1.3 审查意见 P1-4）
      const duplicated: boolean = await db.existsBpTriple(this.measureTime, sys, dia, this.recordId);
      if (duplicated) {
        this.errTime = $r('app.string.err_duplicate_record');
        this.getUIContext().getPromptAction().showToast({ message: $r('app.string.err_duplicate_record') });
        return;
      }

      if (this.recordId > 0) {
        const record: BpRecord = {
          id: this.recordId,
          systolic: sys,
          diastolic: dia,
          heartRate: hr,
          measureTime: this.measureTime,
          period: this.period,
          note: note,
          userId: 1,
          source: 'manual',
          createdAt: 0,
          updatedAt: DateUtils.now()
        };
        await db.updateBp(record);
      } else {
        const draft: BpRecordDraft = {
          systolic: sys,
          diastolic: dia,
          heartRate: hr,
          measureTime: this.measureTime,
          period: this.period,
          note: note
        };
        this.recordId = await db.insertBp(draft);
      }
    } catch (err) {
      const e = err as BusinessError;
      Logger.error(TAG, `save failed: code=${e.code}, message=${e.message}`);
      this.toast($r('app.string.error_db_write'));
      return;
    }
    this.showAdvice(sys, dia);
  }

  /** 保存后弹出分级提示卡；三级为深红主题且不可滑动关闭（§5.6） */
  private showAdvice(systolic: number, diastolic: number): void {
    // 分级固定按诊室表，不再读取「参考口径」设置（决策 D1）
    const level: GradeLevel = GradeService.gradeOf(systolic, diastolic);
    const severe: boolean = GradeService.isSevere(systolic, diastolic);
    this.adviceDialog = new CustomDialogController({
      builder: GradeAdviceDialog({
        systolic: systolic,
        diastolic: diastolic,
        level: level,
        severe: severe
      }),
      autoCancel: !severe,
      alignment: DialogAlignment.Center
    });
    this.adviceDialog.open();
  }

  private async deleteRecord(): Promise<void> {
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
        action: async () => {
          try {
            await BpDatabase.getInstance().deleteBp(this.recordId);
            router.back();
          } catch (err) {
            const e = err as BusinessError;
            Logger.error(TAG, `delete failed: code=${e.code}, message=${e.message}`);
            this.toast($r('app.string.error_db_write'));
          }
        }
      }
    });
  }

  /** 选择测量时间：先日期后时间，日期上限为今天（不允许未来） */
  private pickDateTime(): void {
    const current: Date = new Date(this.measureTime);
    this.getUIContext().showDatePickerDialog({
      selected: current,
      start: new Date(2000, 0, 1),
      end: new Date(),
      onDateAccept: (value: Date) => {
        const day: Date = value;
        this.getUIContext().showTimePickerDialog({
          selected: new Date(1970, 0, 1, day.getHours(), day.getMinutes()),
          onAccept: (value: TimePickerResult) => {
            const minutes: number = value.hour * 60 + value.minute;
            this.measureTime = DateUtils.atMinutesOfDay(day.getTime(), minutes);
            // 时段默认跟随时间自动推断，用户仍可手动改选（§3.3）
            this.period = DateUtils.periodOf(this.measureTime);
            this.revalidate();
          }
        });
      }
    });
  }

  build() {
    Column() {
      // 顶部栏
      Row() {
        Text($r('app.string.action_back'))
          .fontSize(15)
          .fontColor($r('app.color.primary'))
          .onClick(() => {
            router.back();
          })
        Blank()
        Text(this.recordId > 0 ? $r('app.string.title_edit_record') : $r('app.string.title_new_record'))
          .fontSize(17)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
        Blank()
        if (this.editing) {
          Text($r('app.string.action_save'))
            .fontSize(15)
            .fontColor(this.valid ? $r('app.color.primary') : $r('app.color.text_disabled'))
            .onClick(() => {
              if (this.valid) {
                this.save();
              }
            })
        } else {
          Text($r('app.string.action_edit'))
            .fontSize(15)
            .fontColor($r('app.color.primary'))
            .onClick(() => {
              this.editing = true;
            })
        }
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 12, bottom: 12 })

      Scroll() {
        Column({ space: 16 }) {
          NumberField({
            label: $r('app.string.field_systolic'),
            value: this.systolicText,
            editable: this.editing,
            hasError: this.errSys !== null,
            errorText: this.resolveErr(this.errSys),
            onValueChange: (v: string) => {
              this.systolicText = v;
              this.revalidate();
            }
          })
          NumberField({
            label: $r('app.string.field_diastolic'),
            value: this.diastolicText,
            editable: this.editing,
            hasError: this.errDia !== null,
            errorText: this.resolveErr(this.errDia),
            onValueChange: (v: string) => {
              this.diastolicText = v;
              this.revalidate();
            }
          })
          NumberField({
            label: $r('app.string.field_heart_rate'),
            value: this.heartRateText,
            showOptional: true,
            editable: this.editing,
            hasError: this.errHr !== null,
            errorText: this.resolveErr(this.errHr),
            unit: $r('app.string.unit_bpm'),
            onValueChange: (v: string) => {
              this.heartRateText = v;
              this.revalidate();
            }
          })

          // 测量时间
          Column({ space: 6 }) {
            Text($r('app.string.field_measure_time'))
              .fontSize(13)
              .fontColor($r('app.color.text_secondary'))
            Row() {
              Text(DateUtils.formatDateTime(this.measureTime))
                .fontSize(15)
                .fontColor($r('app.color.text_primary'))
              Blank()
              Text($r('app.string.action_pick'))
                .fontSize(13)
                .fontColor($r('app.color.primary'))
            }
            .width('100%')
            .padding(12)
            .borderRadius(8)
            .backgroundColor($r('app.color.surface'))
            .border({ width: 1, color: this.errTime === null ? $r('app.color.border') : $r('app.color.danger') })
            .enabled(this.editing)
            .onClick(() => {
              this.pickDateTime();
            })
            this.errorText(0)
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)

          // 时段
          Column({ space: 6 }) {
            Text($r('app.string.field_period'))
              .fontSize(13)
              .fontColor($r('app.color.text_secondary'))
            Row({ space: 8 }) {
              ForEach(PeriodText.ORDER, (p: Period) => {
                Text(PeriodText.label(p))
                  .fontSize(13)
                  .fontColor(this.period === p ? $r('app.color.on_primary') : $r('app.color.text_primary'))
                  .padding({ left: 12, right: 12, top: 6, bottom: 6 })
                  .backgroundColor(this.period === p ? $r('app.color.primary') : $r('app.color.surface'))
                  .borderRadius(14)
                  .border({
                    width: 1,
                    color: this.period === p ? $r('app.color.primary') : $r('app.color.border')
                  })
                  .onClick(() => {
                    if (this.editing) {
                      this.period = p;
                    }
                  })
              }, (p: Period) => `${p}`)
            }
            .width('100%')
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)

          // 备注
          Column({ space: 6 }) {
            Text($r('app.string.field_note'))
              .fontSize(13)
              .fontColor($r('app.color.text_secondary'))
            TextInput({ text: this.note, placeholder: $r('app.string.note_placeholder') })
              .maxLength(BpLimits.NOTE_MAX_LEN)
              .enabled(this.editing)
              .backgroundColor($r('app.color.surface'))
              .border({ width: 1, color: this.errNote === null ? $r('app.color.border') : $r('app.color.danger') })
              .onChange((value: string) => {
                this.note = value;
                this.revalidate();
              })
            this.errorText(1)
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)

          if (this.recordId > 0) {
            Button($r('app.string.action_delete_record'))
              .width('100%')
              .height(44)
              .fontSize(15)
              .backgroundColor($r('app.color.danger_bg'))
              .fontColor($r('app.color.danger'))
              .onClick(() => {
                this.deleteRecord();
              })
          }
        }
        .width('100%')
        .padding(16)
      }
      .layoutWeight(1)
      .align(Alignment.Top)
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_bg'))
  }

  /**
   * 校验错误行。参数只允许传常量（0 = 时间，1 = 备注）：
   * @Builder 的传参是**首帧快照**，把 this.errTime 这类可变状态当参数传进来，
   * 之后校验失败也不会出现提示（v1.18 真机发现，与 ChartPage 均值格同一类）。
   * 可变值必须在 builder 内部用 this.xxx 读，才会登记成刷新依赖。
   */
  @Builder
  errorText(which: number) {
    if (this.errAt(which) !== null) {
      Text(this.errAt(which))
        .fontSize(11)
        .fontColor($r('app.color.danger'))
    }
  }

  private errAt(which: number): Resource | null {
    return which === 1 ? this.errNote : this.errTime;
  }
}
