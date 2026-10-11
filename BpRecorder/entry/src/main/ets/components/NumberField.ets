/**
 * 通用数值输入行（大号数字键盘 + 单位 + 字段级错误提示）。
 *
 * 抽成独立组件的原因：@Builder 的参数按值传递、不支持可靠地传入回调闭包，
 * 因此「带回调的输入行」必须以 @Component 形式实现，由父组件通过 onValueChange 接收变更。
 *
 * 注意：错误态用 hasError + errorText 两个参数表达，而不直接传 Resource | null，
 * 避免 @Prop 对可空联合类型的支持差异。
 */
@Component
export struct NumberField {
  @Prop label: Resource = $r('app.string.field_systolic');
  @Prop value: string = '';
  /** 是否显示「选填」标记 */
  @Prop showOptional: boolean = false;
  @Prop editable: boolean = true;
  @Prop hasError: boolean = false;
  @Prop errorText: Resource = $r('app.string.placeholder_empty');
  @Prop unit: Resource = $r('app.string.unit_mmhg');
  @Prop maxLength: number = 3;
  onValueChange?: (value: string) => void;

  build() {
    Column({ space: 6 }) {
      Row({ space: 4 }) {
        Text(this.label)
          .fontSize(13)
          .fontColor($r('app.color.text_secondary'))
        if (this.showOptional) {
          Text($r('app.string.field_optional'))
            .fontSize(11)
            .fontColor($r('app.color.text_tertiary'))
        }
      }
      .width('100%')

      Row({ space: 8 }) {
        TextInput({ text: this.value })
          .type(InputType.Number)
          .maxLength(this.maxLength)
          .fontSize(28)
          .height(56)
          .layoutWeight(1)
          .backgroundColor($r('app.color.surface'))
          .border({
            width: 1,
            color: this.hasError ? $r('app.color.danger') : $r('app.color.border')
          })
          .enabled(this.editable)
          .onChange((v: string) => {
            const handler = this.onValueChange;
            if (handler !== undefined) {
              handler(v);
            }
          })
        Text(this.unit)
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
      }
      .width('100%')

      if (this.hasError) {
        Text(this.errorText)
          .fontSize(11)
          .fontColor($r('app.color.danger'))
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }
}
