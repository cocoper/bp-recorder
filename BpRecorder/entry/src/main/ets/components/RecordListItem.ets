import { PeriodText } from '../common/Constants';
import { DateUtils } from '../common/DateUtils';
import { BpRecord } from '../model/BpRecord';
import { Period } from '../model/Types';
import { GradeBadge } from './GradeBadge';
import { GradeService } from '../service/GradeService';

/**
 * 记录列表项（FR-2.1 / FR-2.2）。
 *
 * 根节点为 ListItem，因此在父级 List 内可直接使用；
 * 左滑动作（编辑 / 删除）由本组件提供，删除的二次确认由父页面负责（CL-1）。
 */
@Component
export struct RecordListItem {
  @Prop record: BpRecord = {
    id: 0,
    systolic: 0,
    diastolic: 0,
    heartRate: null,
    measureTime: 0,
    period: Period.OTHER,
    note: null,
    userId: 1,
    source: 'manual',
    createdAt: 0,
    updatedAt: 0
  };
  onEdit?: (record: BpRecord) => void;
  onDelete?: (record: BpRecord) => void;
  onTap?: (record: BpRecord) => void;

  @Builder
  swipeActions() {
    Row() {
      Text($r('app.string.action_edit'))
        .fontSize(14)
        .fontColor($r('app.color.on_primary'))
        .width(64)
        .height('100%')
        .textAlign(TextAlign.Center)
        .backgroundColor($r('app.color.action_edit_bg'))
        .onClick(() => {
          const handler = this.onEdit;
          if (handler !== undefined) {
            handler(this.record);
          }
        })
      Text($r('app.string.action_delete'))
        .fontSize(14)
        .fontColor($r('app.color.on_primary'))
        .width(64)
        .height('100%')
        .textAlign(TextAlign.Center)
        .backgroundColor($r('app.color.action_delete_bg'))
        .onClick(() => {
          const handler = this.onDelete;
          if (handler !== undefined) {
            handler(this.record);
          }
        })
    }
    .height('100%')
  }

  build() {
    ListItem() {
      Column({ space: 6 }) {
        Row({ space: 8 }) {
          Text(DateUtils.formatDateCN(this.record.measureTime))
            .fontSize(13)
            .fontColor($r('app.color.text_secondary'))
          Text(DateUtils.formatTime(this.record.measureTime))
            .fontSize(13)
            .fontColor($r('app.color.text_secondary'))
          Text(PeriodText.label(this.record.period))
            .fontSize(11)
            .fontColor($r('app.color.chip_text'))
            .padding({ left: 6, right: 6, top: 2, bottom: 2 })
            .backgroundColor($r('app.color.chip_bg'))
            .borderRadius(6)
          Blank()
          GradeBadge({
            level: GradeService.gradeOf(this.record.systolic, this.record.diastolic)
          })
        }
        .width('100%')

        Row({ space: 12 }) {
          Text(`${this.record.systolic} / ${this.record.diastolic}`)
            .fontSize(22)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
          Text($r('app.string.unit_mmhg'))
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
            .margin({ bottom: 3 })
          if (this.record.heartRate !== null) {
            Text($r('app.string.heart_rate_value', this.record.heartRate))
              .fontSize(13)
              .fontColor($r('app.color.text_secondary'))
          }
          Blank()
        }
        .width('100%')
        .alignItems(VerticalAlign.Bottom)

        if (this.record.note !== null && this.record.note.length > 0) {
          Text(this.record.note)
            .fontSize(12)
            .fontColor($r('app.color.text_tertiary'))
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
        }
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 12, bottom: 12 })
      .alignItems(HorizontalAlign.Start)
    }
    .backgroundColor($r('app.color.surface'))
    .onClick(() => {
      const handler = this.onTap;
      if (handler !== undefined) {
        handler(this.record);
      }
    })
    .swipeAction({ end: this.swipeActions() })
  }
}
