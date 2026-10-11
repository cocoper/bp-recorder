import { GradeColor, GradeText } from '../common/Constants';
import { GradeLevel } from '../model/Types';

/**
 * 录入保存后的分级提示卡（FR-5.1 / FR-5.2 / 策划文档 §5.6）。
 *
 * 3 级（≥180/≥110）时使用深红主题，且由调用方将 autoCancel 设为 false，
 * 使弹窗不可通过点击遮罩或返回键关闭，必须点击「知道了」（§5.6）。
 * 所有文案尾部统一附免责声明（FR-5.4）。
 */
@CustomDialog
export struct GradeAdviceDialog {
  controller?: CustomDialogController;
  @Prop systolic: number = 0;
  @Prop diastolic: number = 0;
  @Prop level: GradeLevel = GradeLevel.NORMAL;
  @Prop severe: boolean = false;

  build() {
    Column({ space: 10 }) {
      Row({ space: 6 }) {
        Circle({ width: 12, height: 12 })
          .fill(this.severe ? $r('app.color.on_primary') : GradeColor.of(this.level))
        Text(GradeText.label(this.level))
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.severe ? $r('app.color.on_primary') : GradeColor.of(this.level))
      }

      Text(`${this.systolic} / ${this.diastolic} mmHg`)
        .fontSize(24)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.severe ? $r('app.color.on_primary') : $r('app.color.text_primary'))

      Text(GradeText.advice(this.level))
        .fontSize(14)
        .lineHeight(22)
        .textAlign(TextAlign.Center)
        .fontColor(this.severe ? $r('app.color.on_primary') : $r('app.color.text_primary'))
        .width('100%')

      Divider()
        .color(this.severe ? $r('app.color.severe_divider') : $r('app.color.divider'))

      Text($r('app.string.disclaimer_short'))
        .fontSize(11)
        .textAlign(TextAlign.Center)
        .fontColor(this.severe ? $r('app.color.on_primary_secondary') : $r('app.color.text_tertiary'))
        .width('100%')

      Button($r('app.string.action_got_it'))
        .width('100%')
        .height(42)
        .fontSize(15)
        .backgroundColor(this.severe ? $r('app.color.on_primary') : $r('app.color.primary'))
        .fontColor(this.severe ? $r('app.color.severe_text') : $r('app.color.on_primary'))
        .onClick(() => {
          const c = this.controller;
          if (c !== undefined) {
            c.close();
          }
        })
    }
    .width('100%')
    .padding(20)
    .backgroundColor(this.severe ? $r('app.color.severe_bg') : $r('app.color.surface'))
    .borderRadius(16)
  }
}
