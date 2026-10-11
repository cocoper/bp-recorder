/**
 * 设置项行（标签 + 当前值 + 右箭头）。
 * 与 NumberField 同因：@Builder 无法可靠接收回调闭包，故以组件形式实现。
 */
@Component
export struct SettingRow {
  @Prop label: Resource = $r('app.string.settings_about');
  @Prop hasValue: boolean = false;
  @Prop value: Resource = $r('app.string.placeholder_empty');
  @Prop danger: boolean = false;
  onTap?: () => void;

  build() {
    Row() {
      Text(this.label)
        .fontSize(15)
        .fontColor(this.danger ? $r('app.color.danger') : $r('app.color.text_primary'))
      Blank()
      if (this.hasValue) {
        Text(this.value)
          .fontSize(13)
          .fontColor($r('app.color.text_secondary'))
      }
      Text($r('app.string.arrow_right'))
        .fontSize(13)
        .fontColor($r('app.color.text_tertiary'))
        .margin({ left: 6 })
    }
    .width('100%')
    .height(52)
    .padding({ left: 16, right: 16 })
    .onClick(() => {
      const handler = this.onTap;
      if (handler !== undefined) {
        handler();
      }
    })
  }
}
