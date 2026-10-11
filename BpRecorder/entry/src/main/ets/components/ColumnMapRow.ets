/**
 * 列对应行（外部来源导入用）：左侧是数据项名称，右侧是下拉的列选择。
 *
 * 与 NumberField / SettingRow 同因：@Builder 无法可靠接收回调闭包，
 * 凡是「带回调的表单行」一律做成 @Component。
 */
@Component
export struct ColumnMapRow {
  /** 数据项名称（如「收缩压」，由调用方从词表解析后传入；支持 Resource 与字符串） */
  @Prop label: ResourceStr = '';
  /** 下拉选项：下标 0 固定为「不使用该列」 */
  @Prop options: SelectOption[] = [];
  @Prop selectedIndex: number = 0;
  @Prop selectedText: string = '';
  onPick: (index: number) => void = () => {};

  build() {
    Row({ space: 8 }) {
      Text(this.label)
        .fontSize(13)
        .fontColor($r('app.color.text_primary'))
        .layoutWeight(1)
      Select(this.options)
        .selected(this.selectedIndex)
        .value(this.selectedText)
        .font({ size: 13 })
        .optionFont({ size: 13 })
        .backgroundColor($r('app.color.surface'))
        .onSelect((index: number) => {
          const handler = this.onPick;
          handler(index);
        })
    }
    .width('100%')
    .height(44)
  }
}
