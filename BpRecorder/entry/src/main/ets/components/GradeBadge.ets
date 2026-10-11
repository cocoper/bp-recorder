import { GradeColor, GradeText } from '../common/Constants';
import { GradeLevel } from '../model/Types';

/**
 * 分级色标（FR-2.2）。
 * 色点 + 分级文字，颜色与文字均来自资源，随「分级标准」设置变化由父组件重新传入 level 触发刷新。
 */
@Component
export struct GradeBadge {
  @Prop level: GradeLevel = GradeLevel.NORMAL;
  @Prop showText: boolean = true;
  @Prop dotSize: number = 8;
  @Prop textSize: number = 12;

  build() {
    Row({ space: 4 }) {
      Circle({ width: this.dotSize, height: this.dotSize })
        .fill(GradeColor.of(this.level))
      if (this.showText) {
        Text(GradeText.label(this.level))
          .fontSize(this.textSize)
          .fontColor(GradeColor.of(this.level))
      }
    }
    .alignItems(VerticalAlign.Center)
  }
}
