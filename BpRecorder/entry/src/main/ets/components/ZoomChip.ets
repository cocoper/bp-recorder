/**
 * 缩放按钮（缩小 / 放大 / 全览）。
 *
 * 与 SettingRow 同因：@Builder 无法可靠接收回调闭包（参数按值传递、会被重建），
 * 凡是带回调的条目一律做成 @Component。
 */
@Component
export struct ZoomChip {
  @Prop label: Resource = $r('app.string.action_zoom');
  /** 是否可点（到边界后置灰）。不能叫 enabled —— 那是组件内置属性名，会与基类冲突 */
  @Prop usable: boolean = true;
  onTap?: () => void;

  build() {
    Text(this.label)
      .fontSize(13)
      .fontColor(this.usable ? $r('app.color.text_primary') : $r('app.color.text_tertiary'))
      .padding({ left: 14, right: 14, top: 6, bottom: 6 })
      .backgroundColor($r('app.color.surface'))
      .borderRadius(16)
      .onClick(() => {
        const handler = this.onTap;
        if (this.usable && handler !== undefined) {
          handler();
        }
      })
  }
}
