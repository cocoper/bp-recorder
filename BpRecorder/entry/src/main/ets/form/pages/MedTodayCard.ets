/** 桌面卡片「今日用药」的 UI（2*2 与 4*2 共用一套布局，按宽度自适应） */
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

  /** 语气 → 主色（与 App 内配色分开，保证在桌面上足够醒目） */
  private accent(): Resource {
    if (this.tone === 'done') {
      return $r('app.color.card_tone_done');
    }
    if (this.tone === 'missed') {
      return $r('app.color.card_tone_missed');
    }
    if (this.tone === 'next') {
      return $r('app.color.card_tone_next');
    }
    return $r('app.color.card_tone_idle');
  }

  /** 分段进度条：每格一次用药，已服格点亮 */
  private cells(): number {
    return this.total > 8 ? 8 : this.total;
  }

  /** 进度条格子的索引数组（避免在 build 里用泛型 Array.from） */
  private cellIndexes(): number[] {
    const out: number[] = [];
    for (let i = 0; i < this.cells(); i++) {
      out.push(i);
    }
    return out;
  }

  private filledCells(): number {
    const cells: number = this.cells();
    if (cells === 0) {
      return 0;
    }
    if (this.taken >= this.total) {
      return cells;
    }
    return Math.floor((this.taken * cells) / this.total);
  }

  build() {
    Column() {
      Row() {
        Row() {
          Row()
            .width(7)
            .height(7)
            .borderRadius(4)
            .backgroundColor(this.accent())
          Text('今日用药')
            .fontSize(13)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.card_text'))
            .margin({ left: 6 })
        }
        Blank()
        Text(this.updatedAt.length > 0 ? this.updatedAt : '')
          .fontSize(10)
          .fontColor($r('app.color.card_text_dim'))
      }
      .width('100%')

      Row() {
        Column() {
          Text(this.headline)
            .fontSize(this.headline.length > 4 ? 30 : 40)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.accent())
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(this.subline)
            .fontSize(12)
            .fontColor($r('app.color.card_text_dim'))
            .margin({ top: 2 })
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        if (this.showRows === 1 && this.rowCount > 0) {
          Text(this.rowsText)
            .fontSize(11)
            .lineHeight(17)
            .fontColor($r('app.color.card_text'))
            .layoutWeight(1)
            .maxLines(3)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Top)
      .margin({ top: 10 })

      Blank()

      // 分段进度条
      Row() {
        ForEach(this.cellIndexes(),
          (i: number) => {
            Row()
              .height(6)
              .layoutWeight(1)
              .borderRadius(3)
              .backgroundColor(i < this.filledCells() ? this.accent() : $r('app.color.card_bar_track'))
              .margin({ right: i === this.cells() - 1 ? 0 : 4 })
          }, (i: number) => `${i}_${this.filledCells()}_${this.cells()}`)
      }
      .width('100%')
      .margin({ top: 10 })
    }
    .width('100%')
    .height('100%')
    .padding(16)
    .borderRadius(20)
    .backgroundColor($r('app.color.card_bg'))
    .borderWidth(1)
    .borderColor($r('app.color.card_border'))
    .justifyContent(FlexAlign.Start)
  }
}
