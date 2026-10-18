/** 桌面卡片「今日用药」的 UI（2*2 与 4*4 共用；vp 绝对尺寸，不随 designWidth 缩放） */
let storage: LocalStorage = new LocalStorage();

@Entry(storage)
@Component
struct MedTodayCard {
  @LocalStorageProp('headline') headline: string = '—';
  @LocalStorageProp('subline') subline: string = '';
  @LocalStorageProp('tone') tone: string = 'idle';
  @LocalStorageProp('total') total: number = 0;
  @LocalStorageProp('taken') taken: number = 0;
  @LocalStorageProp('rowsText') rowsText: string = '';
  @LocalStorageProp('rowCount') rowCount: number = 0;
  @LocalStorageProp('updatedAt') updatedAt: string = '';
  /** 1 = 大卡（展示分次明细） */
  @LocalStorageProp('showRows') showRows: number = 0;

  private accent(): Resource {
    if (this.tone === 'missed') {
      return $r('app.color.card_tone_missed');
    }
    if (this.tone === 'next') {
      return $r('app.color.card_tone_next');
    }
    if (this.tone === 'done') {
      return $r('app.color.card_tone_done');
    }
    return $r('app.color.card_tone_idle');
  }

  private percent(): string {
    if (this.total <= 0) {
      return '0%';
    }
    const p: number = Math.round((this.taken * 100) / this.total);
    return `${p > 100 ? 100 : p}%`;
  }

  build() {
    Column() {
      // 顶部：状态点 + 标题 + 刷新时间
      Row() {
        Row()
          .width(8)
          .height(8)
          .borderRadius(4)
          .backgroundColor(this.accent())
        Text('今日用药')
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.card_text'))
          .margin({ left: 7 })
        Blank()
        Text(this.updatedAt)
          .fontSize(11)
          .fontColor($r('app.color.card_text_dim'))
      }
      .width('100%')

      // 大号状态（直接作为外层 Column 的子节点，宽度才稳定）
      Text(this.headline)
        .width('100%')
        .fontSize(this.showRows === 1 ? 48 : 34)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.accent())
        .maxLines(2)
        .textAlign(TextAlign.Start)
      Text(this.subline)
        .width('100%')
        .fontSize(13)
        .fontColor($r('app.color.card_text_dim'))
        .margin({ top: 3 })
        .maxLines(2)
        .textAlign(TextAlign.Start)

      if (this.showRows === 1 && this.rowCount > 0) {
        Text(this.rowsText)
          .width('100%')
          .fontSize(12)
          .lineHeight(18)
          .fontColor($r('app.color.card_text'))
          .margin({ top: 8 })
          .maxLines(3)
      }

      // 弹性空白：把进度条压到卡片底部（Blank 在卡片里不一定撑开，用 layoutWeight 更可靠）
      Row()
        .width('100%')
        .layoutWeight(1)

      // 进度条：轨道 + 已完成部分
      Row() {
        Row()
          .width(this.percent())
          .height('100%')
          .borderRadius(5)
          .backgroundColor(this.accent())
      }
      .width('100%')
      .height(10)
      .borderRadius(5)
      .backgroundColor($r('app.color.card_bar_track'))
    }
    .width('100%')
    .height('100%')
    .padding(18)
    .alignItems(HorizontalAlign.Start)
    .justifyContent(FlexAlign.Start)
    .borderRadius(22)
    .backgroundColor($r('app.color.card_bg'))
    .borderWidth(1)
    .borderColor($r('app.color.card_border'))
  }
}
