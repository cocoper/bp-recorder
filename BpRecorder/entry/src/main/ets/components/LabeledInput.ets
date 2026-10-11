/**
 * 通用单行文本输入（带标签、选填标记与字段级错误提示）。
 * 与 NumberField 同因：@Builder 无法可靠接收回调闭包，故以组件形式实现。
 */
@Component
export struct LabeledInput {
  @Prop label: Resource = $r('app.string.field_note');
  @Prop value: string = '';
  @Prop placeholder: Resource = $r('app.string.placeholder_empty');
  @Prop showOptional: boolean = false;
  @Prop hasError: boolean = false;
  @Prop errorText: Resource = $r('app.string.placeholder_empty');
  @Prop maxLength: number = 100;
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

      TextInput({ text: this.value, placeholder: this.placeholder })
        .maxLength(this.maxLength)
        .fontSize(15)
        .backgroundColor($r('app.color.surface'))
        .border({
          width: 1,
          color: this.hasError ? $r('app.color.danger') : $r('app.color.border')
        })
        .onChange((v: string) => {
          const handler = this.onValueChange;
          if (handler !== undefined) {
            handler(v);
          }
        })

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
