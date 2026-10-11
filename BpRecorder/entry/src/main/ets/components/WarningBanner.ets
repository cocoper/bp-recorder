/**
 * 首页趋势预警条（FR-5.3）。
 * 由 Index 页判定是否满足「近 7 天均值 ≥135/85」，满足才渲染本组件（不满足时整条隐藏）。
 * 文案末尾统一附加免责声明（FR-5.4）。
 */
@Component
export struct WarningBanner {
  @Prop sysMean: number = 0;
  @Prop diaMean: number = 0;
  @Prop days: number = 7;

  build() {
    Column({ space: 4 }) {
      Row({ space: 6 }) {
        Text($r('app.string.warn_icon'))
          .fontSize(14)
          .fontColor($r('app.color.warn_text'))
        Text($r('app.string.warn_title'))
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.warn_text'))
        Blank()
        Text($r('app.string.warn_avg', Math.round(this.sysMean), Math.round(this.diaMean)))
          .fontSize(13)
          .fontColor($r('app.color.warn_text'))
      }
      .width('100%')

      Text($r('app.string.warn_detail', this.days))
        .fontSize(12)
        .fontColor($r('app.color.warn_text_secondary'))
        .width('100%')

      Text($r('app.string.disclaimer_short'))
        .fontSize(11)
        .fontColor($r('app.color.warn_text_secondary'))
        .width('100%')
    }
    .width('100%')
    .padding(12)
    .backgroundColor($r('app.color.warn_bg'))
    .borderRadius(12)
  }
}
