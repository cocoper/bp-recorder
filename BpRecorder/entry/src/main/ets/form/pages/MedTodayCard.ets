/** 桌面卡片「今日用药」：2*2 方卡看整体；2*4 是 2 行×4 列的全宽横卡，左进度 / 右明细 */
let storage: LocalStorage = new LocalStorage();

interface CardRow {
  time: string;
  name: string;
  status: string;
  label: string;
}

const WIDE_MAX_ROWS: number = 4;

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
  /** 1 = 2*4 全宽横卡（左进度 / 右明细） */
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
      const all: CardRow[] = JSON.parse(this.rowsJson) as CardRow[];
      return all.length > WIDE_MAX_ROWS ? all.slice(0, WIDE_MAX_ROWS) : all;
    } catch (err) {
      return [];
    }
  }

  /** 进度条（左侧/底部共用） */
  @Builder
  bar() {
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

  /** 状态点 + 标题（两种尺寸共用） */
  @Builder
  header(leftLabel: string) {
    Row() {
      Row()
        .width(8)
        .height(8)
        .borderRadius(4)
        .backgroundColor(this.accent())
      Text(leftLabel)
        .fontSize(12)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.card_text'))
        .margin({ left: 6 })
      Blank()
      Text(this.updatedAt)
        .fontSize(10)
        .fontColor($r('app.color.card_text_dim'))
    }
    .width('100%')
  }

  /** 2*4 全宽横卡：左=状态+进度，右=每一次用药 */
  @Builder
  wideLayout() {
    Row() {
      Column() {
        this.header('今日用药')
        Text(this.headline)
          .width('100%')
          .fontSize(30)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.accent())
          .maxLines(1)
          .margin({ top: 4 })
        Text(this.subline)
          .width('100%')
          .fontSize(11)
          .fontColor($r('app.color.card_text_dim'))
          .maxLines(1)
          .margin({ top: 2 })
        Row()
          .width('100%')
          .layoutWeight(1)
        this.bar()
        Text(this.dateLabel)
          .width('100%')
          .fontSize(10)
          .fontColor($r('app.color.card_text_dim'))
          .margin({ top: 4 })
      }
      .layoutWeight(3)
      .alignItems(HorizontalAlign.Start)
      .height('100%')

      Column() {
        if (this.rowCount === 0) {
          Text('今天没有用药安排')
            .fontSize(11)
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
              .fontSize(10)
              .fontColor($r('app.color.card_text_dim'))
              .margin({ left: 5 })
              .width(36)
            Text(row.name)
              .fontSize(11)
              .fontColor($r('app.color.card_text'))
              .layoutWeight(1)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            Text(row.label)
              .fontSize(10)
              .fontColor(this.rowColor(row.status))
              .margin({ left: 4 })
          }
          .width('100%')
          .margin({ top: 2 })
        }, (row: CardRow) => `${row.time}_${row.name}_${row.status}`)
      }
      .layoutWeight(4)
      .alignItems(HorizontalAlign.Start)
      .height('100%')
      .margin({ left: 12 })
    }
    .width('100%')
    .height('100%')
    .alignItems(VerticalAlign.Top)
  }

  /** 2*2 方卡（已真机验证过的紧凑版式） */
  @Builder
  compactLayout() {
    Column() {
      this.header('今日用药')
      Row()
        .width('100%')
        .layoutWeight(1)
      Text(this.headline)
        .width('100%')
        .fontSize(34)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.accent())
        .maxLines(2)
      Text(this.subline)
        .width('100%')
        .fontSize(12)
        .fontColor($r('app.color.card_text_dim'))
        .margin({ top: 3 })
        .maxLines(2)
      Row()
        .width('100%')
        .layoutWeight(1)
      this.bar()
    }
    .width('100%')
    .height('100%')
    .alignItems(HorizontalAlign.Start)
  }

  build() {
    Column() {
      if (this.showRows === 1) {
        this.wideLayout()
      } else {
        this.compactLayout()
      }
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
