import { MedStatusText } from '../common/Constants';
import { DateUtils } from '../common/DateUtils';
import { TodayMedLine } from '../model/Med';
import { MedLogStatus } from '../model/Types';

/**
 * 首页「今日服药」卡片（FR-9.3）。
 *
 * 由父页面控制：无生效计划时整卡隐藏（CL-8）；漏服项显示红色角标。
 * 用药界面固定显示「遵医嘱」声明（FR-9.7）。
 */
@Component
export struct TodayMedCard {
  @Prop lines: TodayMedLine[] = [];
  @Prop takenCount: number = 0;
  @Prop totalCount: number = 0;
  onCheckIn?: (line: TodayMedLine) => void;

  @Builder
  statusTag(line: TodayMedLine) {
    Row({ space: 3 }) {
      Text(MedStatusText.label(`${line.status}`))
        .fontSize(12)
        .fontColor(MedStatusText.color(`${line.status}`))
      if (line.isMakeUp) {
        Text($r('app.string.med_makeup_tag'))
          .fontSize(11)
          .fontColor($r('app.color.med_makeup'))
      }
    }
  }

  build() {
    Column({ space: 8 }) {
      Row() {
        Text($r('app.string.med_pill_icon'))
          .fontSize(14)
        Text($r('app.string.today_med_title'))
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .margin({ left: 4 })
        Blank()
        Text($r('app.string.today_med_progress', this.takenCount, this.totalCount))
          .fontSize(13)
          .fontColor($r('app.color.text_secondary'))
      }
      .width('100%')

      if (this.lines.length === 0) {
        Text($r('app.string.today_med_empty'))
          .fontSize(13)
          .fontColor($r('app.color.text_tertiary'))
          .width('100%')
      } else {
        // 键里必须带上可变内容（打卡状态 / 补记位 / 计划时间 / 序号）：
        // ForEach 只在键变化时重建列表项，只写 logId 的话打完卡仍是「待服」（v1.16 同类缺陷）。
        ForEach(this.lines, (line: TodayMedLine) => {
          Row({ space: 8 }) {
            Text(DateUtils.formatTime(line.scheduledTime))
              .fontSize(14)
              .fontColor($r('app.color.text_primary'))
              .width(48)
            Text(line.medName)
              .fontSize(14)
              .fontColor($r('app.color.text_primary'))
              .layoutWeight(1)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            Text(line.dosage)
              .fontSize(12)
              .fontColor($r('app.color.text_secondary'))
          }
          .width('100%')
          .padding({ top: 6, bottom: 6 })
          .onClick(() => {
            const handler = this.onCheckIn;
            if (handler !== undefined) {
              handler(line);
            }
          })

          Row() {
            Blank()
            this.statusTag(line)
          }
          .width('100%')
          .margin({ top: -6 })
        }, (line: TodayMedLine) => `${line.logId}_${line.status}_${line.isMakeUp ? 1 : 0}_${line.scheduledTime}_${line.slotSeq}_${line.medSeq}`)
      }

      Divider().color($r('app.color.divider'))

      Text($r('app.string.disclaimer_med'))
        .fontSize(11)
        .fontColor($r('app.color.text_tertiary'))
        .width('100%')
    }
    .width('100%')
    .padding(12)
    .backgroundColor($r('app.color.surface'))
    .borderRadius(12)
  }
}
