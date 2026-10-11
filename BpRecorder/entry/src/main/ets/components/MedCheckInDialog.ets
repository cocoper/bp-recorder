import { DateUtils } from '../common/DateUtils';
import { TodayMedLine } from '../model/Med';
import { CheckInAction, MedLogStatus } from '../model/Types';

/**
 * 服药打卡弹窗（FR-9.2 / 策划文档 §5.8）。
 * 可由首页「今日服药」卡片点击进入，也可由提醒通知拉起 App 后打开。
 * 已漏服的条目标题改为「漏服补记」，文案相应调整。
 */
@CustomDialog
export struct MedCheckInDialog {
  controller?: CustomDialogController;
  @Prop line: TodayMedLine = {
    logId: 0,
    medName: '',
    dosage: '',
    scheduledTime: 0,
    status: MedLogStatus.PENDING,
    isMakeUp: false,
    slotSeq: 0,
    medSeq: 0,
    medCountInSlot: 0
  };
  onAction?: (action: CheckInAction) => void;

  private isMissed(): boolean {
    return this.line.status === MedLogStatus.MISSED;
  }

  @Builder
  actionButton(text: Resource, action: CheckInAction, primary: boolean) {
    Button(text)
      .width('100%')
      .height(44)
      .fontSize(16)
      .backgroundColor(primary ? $r('app.color.med_taken') : $r('app.color.surface_subtle'))
      .fontColor(primary ? $r('app.color.on_primary') : $r('app.color.text_primary'))
      .onClick(() => {
        const handler = this.onAction;
        if (handler !== undefined) {
          handler(action);
        }
      })
  }

  build() {
    Column({ space: 12 }) {
      Text($r('app.string.med_pill_icon'))
        .fontSize(22)

      if (this.isMissed()) {
        Text($r('app.string.checkin_title_makeup'))
          .fontSize(17)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.med_missed'))
      } else {
        Text($r('app.string.checkin_title', DateUtils.formatTime(this.line.scheduledTime)))
          .fontSize(17)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
      }

      Text(`${this.line.medName}  ${this.line.dosage}`)
        .fontSize(15)
        .fontColor($r('app.color.text_primary'))

      Text($r('app.string.checkin_seq', this.line.medSeq))
        .fontSize(12)
        .fontColor($r('app.color.text_secondary'))

      this.actionButton($r('app.string.checkin_take'), CheckInAction.TAKE, true)
      this.actionButton($r('app.string.checkin_skip'), CheckInAction.SKIP, false)

      Text($r('app.string.checkin_hint'))
        .fontSize(11)
        .textAlign(TextAlign.Center)
        .fontColor($r('app.color.text_tertiary'))
        .width('100%')

      Text($r('app.string.disclaimer_med'))
        .fontSize(11)
        .textAlign(TextAlign.Center)
        .fontColor($r('app.color.text_tertiary'))
        .width('100%')
    }
    .width('100%')
    .padding(20)
    .backgroundColor($r('app.color.surface'))
    .borderRadius(16)
  }
}
