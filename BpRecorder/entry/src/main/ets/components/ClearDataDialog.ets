import { ResUtils } from '../common/ResUtils';
import { common } from '@kit.AbilityKit';

/**
 * 清空全部数据的二次确认弹窗（FR-7.2）。
 * 除弹窗外，还要求用户手动输入「确认」二字，防止误触造成不可逆的数据丢失（CL-6）。
 */
@CustomDialog
export struct ClearDataDialog {
  controller?: CustomDialogController;
  onConfirm?: () => void;

  @State private input: string = '';
  @State private matched: boolean = false;

  private check(value: string): void {
    this.input = value;
    const context = ResUtils.hostContext(this.getUIContext());
    const keyword: string = ResUtils.text(context, $r('app.string.clear_confirm_keyword'));
    this.matched = value.trim() === keyword;
  }

  build() {
    Column({ space: 12 }) {
      Text($r('app.string.clear_data_title'))
        .fontSize(17)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))

      Text($r('app.string.clear_data_message'))
        .fontSize(13)
        .lineHeight(20)
        .fontColor($r('app.color.text_secondary'))
        .width('100%')

      Text($r('app.string.clear_data_hint'))
        .fontSize(13)
        .fontColor($r('app.color.danger'))
        .width('100%')

      TextInput({ text: this.input, placeholder: $r('app.string.clear_data_placeholder') })
        .maxLength(10)
        .backgroundColor($r('app.color.surface_subtle'))
        .onChange((v: string) => {
          this.check(v);
        })

      Row({ space: 10 }) {
        Button($r('app.string.action_cancel'))
          .layoutWeight(1)
          .height(42)
          .fontSize(15)
          .backgroundColor($r('app.color.surface_subtle'))
          .fontColor($r('app.color.text_primary'))
          .onClick(() => {
            const c = this.controller;
            if (c !== undefined) {
              c.close();
            }
          })
        Button($r('app.string.clear_data_confirm'))
          .layoutWeight(1)
          .height(42)
          .fontSize(15)
          .enabled(this.matched)
          .backgroundColor(this.matched ? $r('app.color.danger') : $r('app.color.btn_disabled'))
          .fontColor($r('app.color.on_primary'))
          .onClick(() => {
            const handler = this.onConfirm;
            if (handler !== undefined) {
              handler();
            }
            const c = this.controller;
            if (c !== undefined) {
              c.close();
            }
          })
      }
      .width('100%')
    }
    .width('100%')
    .padding(20)
    .backgroundColor($r('app.color.surface'))
    .borderRadius(16)
  }
}
