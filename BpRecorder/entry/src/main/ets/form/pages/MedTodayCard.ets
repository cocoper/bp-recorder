/** 桌面卡片「今日用药」：2*2 看整体；2*4 竖版额外列出今天每一次用药 */
let storage: LocalStorage = new LocalStorage();

/** 明细行（与 TodayCardRow 对齐，卡片侧自行解析） */
interface CardRow {
  time: string;
  name: string;
  status: string;
  label: string;
}

@Entry(storage)
@Component
struct MedTodayCard {
  @LocalStorageProp('headline') headline: string = '—';
  @LocalStorageProp('subline') subline: string = '';
  @LocalStorageProp('tone') tone: string = 'idle';
  @LocalStorageProp('total') total: number = 0;
  @LocalStorageProp('taken') taken: number = 0;
  @LocalStorageProp('updatedAt') updatedAt: string = '';
  @LocalStorageProp('dateLabel') dateLabel: string = '';
  @LocalStorageProp('rowsJson') rowsJson: string = '[]';
  @LocalStorageProp('rowCount') rowCount: number = 0;
  /** 1 = 2*4 竖版（展示分次明细） */
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

  private rowColor(status: string): Resource {
    if (status === 'taken') {
      return $r('app.color.card_tone_done');
    }
    if (status === 'missed') {
      return $r('app.color.card_tone_missed');
    }
    if (status === 'skipped') {
      return $r('app.color.card_tone_idle');
    }
    return $r('app.color.card_tone_next');
  }

  private percent(): string {
    if (this.total <= 0) {
      return '0%';
    }
    const p: number = Math.round((this.taken * 100) / this.total);
    return `${p > 100 ? 100 : p}%`;
  }

  private rows(): CardRow[] {
    try {
      return JSON.parse(this.rowsJson) as CardRow[];
    } catch (err) {
      return [];
    }
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

      if (this.showRows === 1) {
        Text(this.dateLabel)
          .fontSize(11)
          .fontColor($r('app.color.card_text_dim'))
          .width('100%')
          .margin({ top: 6 })
      } else {
        Row()
          .width('100%')
          .layoutWeight(1)
      }

      // 大号状态
      Text(this.headline)
        .width('100%')
        .fontSize(this.showRows === 1 ? 40 : 34)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.accent())
        .maxLines(2)
      Text(this.subline)
        .width('100%')
        .fontSize(12)
        .fontColor($r('app.color.card_text_dim'))
        .margin({ top: 3 })
        .maxLines(2)

      // 2*4 竖版：今天每一次用药（时间 · 药品 · 状态）
      if (this.showRows === 1) {
        Column() {
          if (this.rowCount === 0) {
            Text('今天没有用药安排')
              .fontSize(12)
              .fontColor($r('app.color.card_text_dim'))
              .width('100%')
          }
          ForEach(this.rows(), (row: CardRow) => {
            Row() {
              Row()
                .width(6)
                .height(6)
                .borderRadius(3)
                .backgroundColor(this.rowColor(row.status))
              Text(row.time)
                .fontSize(11)
                .fontColor($r('app.color.card_text_dim'))
                .margin({ left: 6 })
                .width(40)
              Text(row.name)
                .fontSize(12)
                .fontColor($r('app.color.card_text'))
                .layoutWeight(1)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
              Text(row.label)
                .fontSize(11)
                .fontColor(this.rowColor(row.status))
            }
            .width('100%')
            .margin({ top: 4 })
          }, (row: CardRow) => `${row.time}_${row.name}_${row.status}`)
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        .margin({ top: 8 })
      } else {
        Row()
          .width('100%')
          .layoutWeight(1)
      }

      // 进度条
      Row() {
        Row()
          .width(this.percent())
          .height('100%')
          .borderRadius(4)
          .backgroundColor(this.accent())
      }
      .width('100%')
      .height(8)
      .borderRadius(4)
      .backgroundColor($r('app.color.card_bar_track'))
    }
    .width('100%')
    .height('100%')
    .padding(16)
    .alignItems(HorizontalAlign.Start)
    .justifyContent(FlexAlign.Start)
    .borderRadius(22)
    .backgroundColor($r('app.color.card_bg'))
    .borderWidth(1)
    .borderColor($r('app.color.card_border'))
  }
}
