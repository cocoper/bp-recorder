import { common } from '@kit.AbilityKit';
import { AppConst, ChartScheme } from '../common/Constants';
import { DateUtils } from '../common/DateUtils';
import { ResUtils } from '../common/ResUtils';
import { DailyPoint } from '../model/BpRecord';
import { GradeService } from '../service/GradeService';

/** 绘图几何参数（内部使用） */
interface Geom {
  width: number;
  height: number;
  padL: number;
  padR: number;
  padT: number;
  padB: number;
  bpLo: number;
  bpHi: number;
  /** 血压轴刻度步长（v1.11：由 axisRange 选出的圆整步长，刻度从 bpLo 起铺满） */
  bpStep: number;
  hrLo: number;
  hrHi: number;
  /** X 轴时间范围（当日 00:00 时间戳）。v1.11 起 X 轴按**真实日期**等比定位，不再是「点序号等距」 */
  tMin: number;
  tMax: number;
}

/** 一套图表配色（由 scheme 决定取哪一族资源） */
interface ChartPalette {
  bg: number;
  textPrimary: number;
  textSecondary: number;
  axis: number;
  refLine: number;
  lineSys: number;
  lineDia: number;
  lineHr: number;
  medMark: number;
  /** 异常测量点的标记色（v1.13） */
  pointAbnormal: number;
  watermark: number;
  tooltipBg: number;
  tooltipText: number;
}

// ── 排版基准（二次上调：14–15px 的刻度在真机上仍然偏小，看不清）
// 全部经 fs() 乘 fontScale，放大视图里同步变大。
const FONT_TICK: number = 17;      // Y 轴刻度
const FONT_DATE: number = 16;      // X 轴日期
const FONT_REF: number = 15;       // 参考线数值与标签
const FONT_TOOLTIP: number = 19;   // 点击浮层
const FONT_LEGEND: number = 16;    // 图例
const FONT_WATERMARK: number = 15; // 水印行
const FONT_EMPTY: number = 18;     // 空数据占位
const PAD_L: number = 54;
const PAD_R_HR: number = 54;
const PAD_R: number = 20;
const PAD_T: number = 24;
const PAD_B: number = 64;          // 两行日期标签（上行月 / 下行日）+ 药丸标记泳道
// v1.11：血压轴由「固定 40–200」改为「围着数据收窄」，参数如下
const PAD_Y_BP: number = 15;       // 数据上下各留的余量（mmHg）
const MIN_BP_SPAN: number = 60;    // 最小跨度，避免只有一两个点时纵轴被压成一根线
const Y_STEPS: number[] = [10, 20, 25, 50, 100]; // 候选刻度步长（圆整数）
const Y_STEP_MIN_TICKS: number = 3;
const Y_STEP_MAX_TICKS: number = 5;
const X_STEPS: number[] = [1, 2, 3, 5, 7, 10, 14, 30, 60]; // 日期刻度的候选间隔（天）

/**
 * 血压趋势折线图（FR-3 / 策划文档 §5.3）。
 *
 * 绘制规格（全部自绘，不引入三方图表库）：
 * - 三条曲线：收缩压、舒张压（共用左轴）、心率（**独立右副轴**，经裁决采用副轴方案）；
 * - 参考线：140/90（诊室标准）与 135/85（家庭自测标准），虚线 + **数字标注**；
 *   两条线只差 5 mmHg（横屏下约 6vp）而字号 15vp，所以两个标注**分居绘图区左右两端**（v1.12），
 *   结构上不可能重叠；线义另由图例下方的 ref_caption 说明行 + 线型区分（家庭自测长虚线 / 诊室短虚线）；
 * - Y 轴**围着数据收窄**：始终包含 85–140 参考带，上下各留 PAD_Y_BP，取整到圆整步长（v1.11）；
 *   旧版固定 40–200，实测 85–130 的数据只占纵轴中间 28%，曲线被压成一条带；
 * - 点击数据点显示当日数值浮层（气泡）；
 * - X 轴**按真实日期等比定位**（v1.11）：某天没测就留空，不再把「有数据的那些天」等距摊开 ——
 *   旧版按点序号等距，90 天里只有 15 天有记录时，日期标签会变成 19/21/24/12/22 这种看起来随机的排列；
 * - X 轴日期标注（上行月 / 下行日）落在**日期网格**上，按每天可用宽度自动选 1/2/3/5/7/10/14/30 天为间隔（v1.11）；
 *   区间只覆盖一个自然日时（趋势页「今天」档，各点是当天的一次次测量）刻度改为**时刻** HH:mm，
 *   按放得下的密度跳着标、首末必定标出；浮层同样只显示时刻与数值（v1.13）；
 * - x 轴下方为当日完成全部服药打卡的日期绘制药丸标记（FR-9.6）；
 * - **异常测量点**（收缩压 ≥ 140 或舒张压 ≥ 90，与报告页 FR-10.2 同一判据）画成橙色实心点 + 底色外圈（v1.13），
 *   图例同步增加「异常」一项 —— 参考第三方血压 App 的观感：该注意的那几次一眼可见；
 * - 线型走「细线 + 圆点」（v1.13）：下线 v1.11 的收缩压—舒张压区间色带，心率线更细更淡，
 *   去色块后心率与血压不再互相割裂；
 * - 空数据 / 单点数据不崩溃（CL-3），空数据显示占位文案。
 *
 * ## 配色分两族（v1.5）
 * - `ChartScheme.PRINT`：**固定白底深字**，base 与 dark 同值。用于报告页 / 打印产物 ——
 *   给医生看或打印时白底才合适，且保证「应用内预览 == 分享产物」。
 * - `ChartScheme.THEME`：**跟随深浅主题**，base 与 dark 取值不同。用于在手机上看图 ——
 *   深色模式下不再是刺眼的白板。
 *
 * ## Canvas 与主题切换
 * 画布是命令式绘制的，系统切换深浅色时 ArkUI 只会重新解析资源、不会重绘已有像素，
 * 因此这里监听 AppStorage 的 `themeVersion`（由 EntryAbility.onConfigurationUpdate 递增）主动重绘。
 *
 * 可读性（v1.5 修订）：字号、内边距、数据点半径随 `fontScale` 一起放大；
 * 画布尺寸变化（旋转屏幕、捏合缩放）时重绘，避免用旧尺寸绘制。
 */
@Component
export struct BpLineChart {
  @Prop @Watch('redraw') points: DailyPoint[] = [];
  /** 右侧副轴是否展示（心率） */
  @Prop showHeartRate: boolean = true;
  /**
   * 是否由本组件绘制图例。趋势页把图例移到横向滚动区**外面**：
   * 左右滑动 / 捏合缩放时图例始终留在屏幕上，而截屏容器仍包含它，分享图不受影响。
   */
  @Prop showLegend: boolean = true;
  /** 是否在底部绘制水印行（分享图使用，FR-11.2） */
  @Prop showWatermark: boolean = false;
  @Prop watermarkText: string = '';
  /** 画布高度（vp） */
  @Prop @Watch('redraw') chartHeight: number = 300;
  /**
   * 画布宽度（vp）。0 表示撑满父容器；
   * 放大视图传入「可视宽 × 缩放倍数」，配合横向滚动实现捏合缩放。
   */
  @Prop @Watch('redraw') chartWidth: number = 0;
  /** 字号缩放（放大的图用 >1 的值） */
  @Prop @Watch('redraw') fontScale: number = 1;
  /** 配色方案：ChartScheme.PRINT（白底印刷）或 ChartScheme.THEME（跟随主题），默认 PRINT */
  @Prop @Watch('redraw') scheme: string = ChartScheme.PRINT;

  private settings: RenderingContextSettings = new RenderingContextSettings(true);
  private ctx: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.settings);
  @State private selectedIndex: number = -1;
  /**
   * 配色缓存。资源取值要走资源管理器，不必每次 build 都重取；
   * 方案或系统主题变化时由 redraw() 清空，下次再取就是新值。
   */
  private palCache: ChartPalette | null = null;
  /** 系统配置变更（含深浅色切换）的版本号，由 EntryAbility 递增 */
  @StorageProp('themeVersion') @Watch('redraw') themeVersion: number = 0;

  private abilityContext(): common.UIAbilityContext {
    return ResUtils.hostContext(this.getUIContext());
  }

  private color(res: Resource): number {
    return ResUtils.colorValue(this.abilityContext(), res);
  }

  /** 当前配色方案对应的一整套颜色（$r 的键必须是字面量，故两个分支各写一遍） */
  private palette(): ChartPalette {
    // build() 里不允许在根节点前声明局部变量，故这里统一走带缓存的取值
    if (this.palCache === null) {
      this.palCache = this.buildPalette();
    }
    return this.palCache;
  }

  private buildPalette(): ChartPalette {
    if (this.scheme === ChartScheme.THEME) {
      return {
        bg: this.color($r('app.color.chart_bg')),
        textPrimary: this.color($r('app.color.chart_text_primary')),
        textSecondary: this.color($r('app.color.chart_text_secondary')),
        axis: this.color($r('app.color.chart_axis')),
        refLine: this.color($r('app.color.chart_ref_line')),
        lineSys: this.color($r('app.color.chart_line_sys')),
        lineDia: this.color($r('app.color.chart_line_dia')),
        lineHr: this.color($r('app.color.chart_line_hr')),
        medMark: this.color($r('app.color.chart_med_mark')),
        // 异常点标记：白底（打印）与深色底都用同一个橙，键在 base/dark 里各有一版
        pointAbnormal: this.color($r('app.color.chart_point_abnormal')),
        watermark: this.color($r('app.color.chart_watermark')),
        tooltipBg: this.color($r('app.color.chart_tooltip_bg')),
        tooltipText: this.color($r('app.color.chart_tooltip_text'))
      };
    }
    return {
      bg: this.color($r('app.color.print_bg')),
      textPrimary: this.color($r('app.color.print_text_primary')),
      textSecondary: this.color($r('app.color.print_text_secondary')),
      axis: this.color($r('app.color.print_axis')),
      refLine: this.color($r('app.color.print_ref_line')),
      lineSys: this.color($r('app.color.print_line_sys')),
      lineDia: this.color($r('app.color.print_line_dia')),
      lineHr: this.color($r('app.color.print_line_hr')),
      medMark: this.color($r('app.color.print_med_mark')),
      pointAbnormal: this.color($r('app.color.chart_point_abnormal')),
      watermark: this.color($r('app.color.print_watermark')),
      tooltipBg: this.color($r('app.color.print_tooltip_bg')),
      tooltipText: this.color($r('app.color.print_tooltip_text'))
    };
  }

  /** 字号：以基准值乘缩放系数，保证放大视图里同步变大 */
  private fs(base: number): number {
    return Math.round(base * this.fontScale);
  }

  /** 父组件更新 points / 尺寸 / 缩放 / 配色后重绘 */
  redraw(): void {
    // 配色可能随 scheme / 系统主题变化，先失效缓存再重绘
    this.palCache = null;
    if (this.selectedIndex >= this.points.length) {
      this.selectedIndex = -1;
    }
    this.draw();
  }

  build() {
    Column({ space: 6 }) {
      if (this.points.length === 0) {
        Column({ space: 8 }) {
          Text($r('app.string.chart_empty'))
            .fontSize(this.fs(FONT_EMPTY))
            .fontColor(this.palette().textSecondary)
        }
        .width('100%')
        .height(this.chartHeight)
        .justifyContent(FlexAlign.Center)
        .backgroundColor(this.palette().bg)
      } else {
        Canvas(this.ctx)
          .width(this.chartWidth > 0 ? this.chartWidth : '100%')
          .height(this.chartHeight)
          .onReady(() => {
            this.draw();
          })
          // 尺寸真正变化后重绘：否则旋转屏幕或缩放后会沿用旧宽度绘制
          .onAreaChange((oldValue: Area, newValue: Area) => {
            this.draw();
          })
          .onClick((event: ClickEvent) => {
            this.handleTap(event.x);
          })
      }

      // 图例（§5.3：图例标明三条曲线含义与药丸标记含义）
      if (this.showLegend) {
        // v1.13：增加「异常」一项（橙色圆点，对应画布上的异常点标记）。
        // 五项在窄屏 + 系统大字号下会超出一行，故用可换行的 Flex，而不是固定单行的 Row。
        Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Center }) {
          this.legendDot(this.palette().pointAbnormal, $r('app.string.legend_abnormal'))
          this.legendItem(this.palette().lineSys, $r('app.string.legend_systolic'))
          this.legendItem(this.palette().lineDia, $r('app.string.legend_diastolic'))
          if (this.showHeartRate) {
            this.legendItem(this.palette().lineHr, $r('app.string.legend_heart_rate'))
          }
          this.legendDot(this.palette().medMark, $r('app.string.legend_med_mark'))
        }
        .width('100%')

        // v1.11：两条参考线的**线义**移到这里 —— 画布内只留 140/90、135/85 数字对，
        // 句子放在画布外既不会压住曲线，也不会因为两线只差 5 mmHg 而叠字。
        Row({ space: 10 }) {
          Text($r('app.string.ref_caption'))
            .fontSize(this.fs(FONT_LEGEND - 2))
            .fontColor(this.palette().watermark)
          Text($r('app.string.ref_home'))
            .fontSize(this.fs(FONT_LEGEND - 2))
            .fontColor(this.palette().textSecondary)
          Text($r('app.string.ref_clinic'))
            .fontSize(this.fs(FONT_LEGEND - 2))
            .fontColor(this.palette().textSecondary)
        }
        .width('100%')
        .justifyContent(FlexAlign.Center)
      }

      if (this.showWatermark) {
        Text(this.watermarkText)
          .fontSize(this.fs(FONT_WATERMARK))
          .fontColor(this.palette().watermark)
          .width('100%')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .margin({ top: 4 })
      }
    }
    .width('100%')
    // 传了固定画布宽度（放大后横向滚动）时不能再加内边距：
    // 父容器宽度等于 chartWidth，再叠 10vp 会把右轴刻度裁掉 20vp。
    .padding(this.chartWidth > 0 ? 0 : 10)
    .backgroundColor(this.palette().bg)
    .borderRadius(12)
  }

  /** 资源以参数传入（$r 的键必须是字面量，不能在 Builder 内用变量拼接） */
  @Builder
  legendItem(color: number, label: Resource) {
    Row({ space: 4 }) {
      Divider()
        .vertical(true)
        .strokeWidth(2)
        .height(13)
        .color(color)
      Text(label)
        .fontSize(this.fs(FONT_LEGEND - 2))
        .fontColor(this.palette().textSecondary)
    }
    .margin({ left: 5, right: 5, top: 2, bottom: 2 })
  }

  /** 圆点式图例项（异常点 / 服药打卡标记），与线式图例项区分 */
  @Builder
  legendDot(color: number, label: Resource) {
    Row({ space: 4 }) {
      Circle({ width: 8, height: 8 }).fill(color)
      Text(label)
        .fontSize(this.fs(FONT_LEGEND - 2))
        .fontColor(this.palette().textSecondary)
    }
    .margin({ left: 5, right: 5, top: 2, bottom: 2 })
  }

  // ───────────────────────── 交互 ─────────────────────────

  /** 点击 → 选中最近的数据点并显示浮层 */
  private handleTap(x: number): void {
    const n: number = this.points.length;
    if (n === 0) {
      return;
    }
    const geom: Geom = this.buildGeom();
    if (n === 1) {
      this.selectedIndex = 0;
      this.draw();
      return;
    }
    // v1.11：X 轴按真实日期定位后，点间距不再均匀，不能再按 step 反推下标 ——
    // 直接找 x 方向最近的那个点；阈值取半个最小点距，避免点到空白处也弹浮层。
    let idx: number = 0;
    let best: number = -1;
    for (let i = 0; i < n; i++) {
      const d: number = Math.abs(this.xAt(geom, i) - x);
      if (best < 0 || d < best) {
        best = d;
        idx = i;
      }
    }
    const span: number = geom.width - geom.padL - geom.padR;
    const gap: number = span / (n - 1);
    if (best > Math.max(gap * 0.8, 18)) {
      return;
    }
    this.selectedIndex = idx === this.selectedIndex ? -1 : idx;
    this.draw();
  }

  // ───────────────────────── 绘制 ─────────────────────────

  private buildGeom(): Geom {
    const width: number = this.ctx.width;
    const height: number = this.ctx.height;
    // 内边距随字号放大，避免放大后刻度文字被裁掉
    const padL: number = this.fs(PAD_L);
    const padR: number = this.showHeartRate ? this.fs(PAD_R_HR) : this.fs(PAD_R);
    const padT: number = this.fs(PAD_T);
    const padB: number = this.fs(PAD_B);

    // v1.11：血压轴改为「围着数据收窄」。旧版固定 40–200，实测数据落在 85–130，
    // 曲线只占纵轴中间 28%，上下各留一大片空白（真机截图确认）。
    // 规则：始终包含 85–140 的参考带（否则参考线会被挡在画布外），上下各留 PAD_Y_BP，
    // 再交给 axisRange 选出圆整步长；数据越界时自然外扩，不会裁掉任何点。
    let dataLo: number = 1000;
    let dataHi: number = -1000;
    let hrDataLo: number = 1000;
    let hrDataHi: number = -1000;
    for (let i = 0; i < this.points.length; i++) {
      const p: DailyPoint = this.points[i];
      dataLo = Math.min(dataLo, p.sysAvg, p.diaAvg);
      dataHi = Math.max(dataHi, p.sysAvg, p.diaAvg);
      const hr: number | null = p.hrAvg;
      if (hr !== null && hr !== undefined) {
        hrDataLo = Math.min(hrDataLo, hr);
        hrDataHi = Math.max(hrDataHi, hr);
      }
    }
    const hasData: boolean = dataHi >= dataLo;
    const hasHr: boolean = hrDataHi >= hrDataLo;
    const rawLo: number = hasData
      ? Math.min(dataLo, AppConst.REF_HOME_DIA) - PAD_Y_BP
      : AppConst.CHART_Y_MIN;
    const rawHi: number = hasData
      ? Math.max(dataHi, AppConst.REF_CLINIC_SYS) + PAD_Y_BP
      : AppConst.CHART_Y_MAX;
    const bpAxis: number[] = BpLineChart.axisRange(rawLo, rawHi, MIN_BP_SPAN, this.maxYLabels(height - padT - padB));
    const bpLo: number = bpAxis[0];
    const bpHi: number = bpAxis[1];

    // 心率右副轴：同样是「围着数据收窄」，只留上/中/下三档
    let hrLo: number = hasHr ? Math.floor((hrDataLo - 5) / 10) * 10 : 40;
    let hrHi: number = hasHr ? Math.ceil((hrDataHi + 5) / 10) * 10 : 120;
    if (hrHi - hrLo < 30) {
      const hrMid: number = Math.round((hrLo + hrHi) / 2);
      hrLo = hrMid - 20;
      hrHi = hrMid + 20;
    }
    if (hrLo < 0) {
      hrLo = 0;
    }

    // X 轴时间范围：首末数据点的当日 00:00
    const count: number = this.points.length;
    const tMin: number = count > 0 ? this.points[0].dayStart : 0;
    const tMax: number = count > 0 ? this.points[count - 1].dayStart : 0;

    return {
      width: width,
      height: height,
      padL: padL,
      padR: padR,
      padT: padT,
      padB: padB,
      bpLo: bpLo,
      bpHi: bpHi,
      bpStep: bpAxis[2],
      hrLo: hrLo,
      hrHi: hrHi,
      tMin: tMin,
      tMax: tMax
    };
  }

  /**
   * 纵轴最多能放几条刻度线（按可用高度和刻度字号算出来的**间隔数**）。
   *
   * 真机上 17vp 的字号需要约 2.2 倍行距才不挤在一起；横屏画布矮、系统字号放大时
   * 这个上限会自动变小，于是刻度自动变稀 —— 而不是硬塞 7 个数字叠在一起（v1.11）。
   */
  private maxYLabels(usable: number): number {
    const gap: number = this.fs(FONT_TICK) * 2.2;
    const fit: number = usable > 0 ? Math.floor(usable / gap) : Y_STEP_MAX_TICKS;
    if (fit < Y_STEP_MIN_TICKS) {
      return Y_STEP_MIN_TICKS;
    }
    return Math.min(Y_STEP_MAX_TICKS, fit);
  }

  /**
   * 选一组「圆整」的纵轴：返回 [下界, 上界, 步长]。
   *
   * 候选步长里挑**跨度最小**、且刻度间隔数落在 [3, maxTicks] 的那组 ——
   * 步长太小会挤成一片（旧版 40–200 只有上/中/下三档，中间却密密麻麻全是参考线数值），
   * 步长太大又会让曲线贴边。返回数组而不是对象，是为了少定义一个只在本文档内用到的类型。
   */
  private static axisRange(rawLo: number, rawHi: number, minSpan: number, maxTicks: number): number[] {
    let lo: number = rawLo;
    let hi: number = rawHi;
    if (hi - lo < minSpan) {
      const grow: number = (minSpan - (hi - lo)) / 2;
      lo = lo - grow;
      hi = hi + grow;
    }
    // 兜底：一个候选都没通过时用最紧的 10 步长区间（宁可密也不要越界）
    let bestLo: number = Math.floor(lo / 10) * 10;
    let bestHi: number = Math.ceil(hi / 10) * 10;
    let bestStep: number = 10;
    let bestSpan: number = -1;
    for (let i = 0; i < Y_STEPS.length; i++) {
      const step: number = Y_STEPS[i];
      const candLo: number = Math.floor(lo / step) * step;
      const candHi: number = candLo + step * Math.ceil((hi - candLo) / step);
      const ticks: number = Math.round((candHi - candLo) / step);
      if (ticks < Y_STEP_MIN_TICKS || ticks > maxTicks) {
        continue;
      }
      const span: number = candHi - candLo;
      // 取第一个（最细的）可行步长：跨度越小，刻度线越多越贴近数据
      if (bestSpan < 0 || span < bestSpan) {
        bestLo = candLo;
        bestHi = candHi;
        bestStep = step;
        bestSpan = span;
      }
    }
    return [bestLo, bestHi, bestStep];
  }

  private draw(): void {
    const ctx: CanvasRenderingContext2D = this.ctx;
    const geom: Geom = this.buildGeom();
    if (geom.width <= 0 || geom.height <= 0) {
      return;
    }

    // 背景
    ctx.fillStyle = this.palette().bg;
    ctx.fillRect(0, 0, geom.width, geom.height);

    // 先画线、再画浮层，保证气泡压在最上层
    this.drawAxes(geom);
    this.drawReferenceLines(geom);
    if (this.points.length > 0) {
      this.drawSeries(geom);
      this.drawMedMarks(geom);
      this.drawSelection(geom);
    }
  }

  /**
   * X 坐标：按**真实日期**在 tMin..tMax 上等比定位（v1.11）。
   * 某天没测量就不占宽度，而不是把「有数据的那几天」等距摊开 —— 后者会让 90 天视图的
   * 日期标签看起来毫无规律（旧版真机截图里出现 19/21/24/12/22 这种排列）。
   * 只有一个点、或所有点同为一天时退回居中。
   */
  private xAt(geom: Geom, index: number): number {
    const n: number = this.points.length;
    const span: number = geom.width - geom.padL - geom.padR;
    if (n <= 1) {
      return geom.padL + span / 2;
    }
    const total: number = geom.tMax - geom.tMin;
    if (total <= 0) {
      return geom.padL + (span * index) / (n - 1);
    }
    const ratio: number = (this.points[index].dayStart - geom.tMin) / total;
    return geom.padL + span * ratio;
  }

  private yBp(geom: Geom, value: number): number {
    const usable: number = geom.height - geom.padT - geom.padB;
    const ratio: number = (geom.bpHi - value) / (geom.bpHi - geom.bpLo);
    return geom.padT + usable * ratio;
  }

  private yHr(geom: Geom, value: number): number {
    const usable: number = geom.height - geom.padT - geom.padB;
    const ratio: number = (geom.hrHi - value) / (geom.hrHi - geom.hrLo);
    return geom.padT + usable * ratio;
  }

  /** 日期标签第一行（月份）的基线：画布底部留白里，紧贴上沿 */
  private dateLabelBaseline(geom: Geom): number {
    return geom.height - geom.padB + this.fs(FONT_DATE) + 2;
  }

  /** 两行日期标签的行距（月份行 → 日行） */
  private dateLineHeight(): number {
    return Math.round(this.fs(FONT_DATE) * 1.25);
  }

  private drawAxes(geom: Geom): void {
    const ctx: CanvasRenderingContext2D = this.ctx;
    const pal: ChartPalette = this.palette();
    const tickFont: number = this.fs(FONT_TICK);
    ctx.strokeStyle = pal.axis;
    ctx.lineWidth = 1;
    ctx.setLineDash([]);

    // 左右轴
    ctx.beginPath();
    ctx.moveTo(geom.padL, geom.padT);
    ctx.lineTo(geom.padL, geom.height - geom.padB);
    ctx.stroke();
    if (this.showHeartRate) {
      ctx.beginPath();
      ctx.moveTo(geom.width - geom.padR, geom.padT);
      ctx.lineTo(geom.width - geom.padR, geom.height - geom.padB);
      ctx.stroke();
    }

    // Y 轴刻度：按 axisRange 选出的圆整步长从下往上铺满（v1.11）。
    // 旧版固定只画上/中/下三档，而参考线数值又画在绘图区内侧，于是真机截图里
    // 左轴出现 200/140/135/120/90/85/40 七个数字，140 与 135、90 与 85 几乎贴在一起。
    ctx.fillStyle = pal.textSecondary;
    ctx.font = `${tickFont}px sans-serif`;
    ctx.textAlign = 'right';
    const tickCount: number = Math.round((geom.bpHi - geom.bpLo) / geom.bpStep);
    for (let k = 0; k <= tickCount; k++) {
      const value: number = geom.bpLo + geom.bpStep * k;
      const y: number = this.yBp(geom, value);
      // 淡虚线网格：读竖向位置时有参照，又不与参考线抢注意力
      ctx.globalAlpha = 0.35;
      ctx.strokeStyle = pal.axis;
      ctx.setLineDash([2, 5]);
      ctx.beginPath();
      ctx.moveTo(geom.padL, y);
      ctx.lineTo(geom.width - geom.padR, y);
      ctx.stroke();
      ctx.setLineDash([]);
      ctx.globalAlpha = 1;
      ctx.fillStyle = pal.textSecondary;
      ctx.fillText(`${value}`, geom.padL - 5, y + tickFont * 0.36);
    }

    if (this.showHeartRate) {
      // 右副轴只保留上 / 中 / 下三档：已经挂了三条曲线，右侧再铺满刻度就只剩噪声
      const hrMid: number = Math.round((geom.hrHi + geom.hrLo) / 2);
      ctx.textAlign = 'left';
      ctx.fillText(`${geom.hrHi}`, geom.width - geom.padR + 5, this.yHr(geom, geom.hrHi) + tickFont * 0.36);
      ctx.fillText(`${hrMid}`, geom.width - geom.padR + 5, this.yHr(geom, hrMid) + tickFont * 0.36);
      ctx.fillText(`${geom.hrLo}`, geom.width - geom.padR + 5, this.yHr(geom, geom.hrLo) + tickFont * 0.36);
    }

    // X 轴日期：落在**日期网格**上（v1.11）。
    // 有数据的日期在时间轴上不再等距，所以刻度必须按「每 N 天」生成，而不是按「第几个点」生成；
    // N 从候选表里挑第一个放得下的（日期越多越稀），因此放大、横屏、缩短区间都会自动标得更密。
    // X 轴刻度：当天档（区间只覆盖一个自然日）按**时刻**标注，其余按日期网格标注（v1.13）。
    const n: number = this.points.length;
    if (n > 0 && geom.tMax - geom.tMin < DateUtils.MS_PER_DAY) {
      this.drawTimeLabels(geom, pal);
      return;
    }
    if (n > 0) {
      const span: number = geom.width - geom.padL - geom.padR;
      const labelFont: number = this.fs(FONT_DATE);
      ctx.font = `${labelFont}px sans-serif`;
      ctx.fillStyle = pal.textSecondary;
      const totalDays: number = Math.max(1, Math.round((geom.tMax - geom.tMin) / DateUtils.MS_PER_DAY));
      const pxPerDay: number = span / totalDays;
      const minGap: number = Math.max(ctx.measureText('88').width * 2, labelFont * 1.6);
      let stride: number = X_STEPS[X_STEPS.length - 1];
      for (let i = 0; i < X_STEPS.length; i++) {
        if (X_STEPS[i] * pxPerDay >= minGap) {
          stride = X_STEPS[i];
          break;
        }
      }
      const days: number[] = [];
      for (let d = 0; d <= totalDays; d += stride) {
        days.push(d);
      }
      if (days[days.length - 1] !== totalDays) {
        // 末尾与已选的最后一个挨得太近就先顶掉前一个，避免两个日期叠在一起
        if (days.length > 1 && totalDays - days[days.length - 1] < stride * 0.6) {
          days.pop();
        }
        days.push(totalDays);
      }
      const monthY: number = this.dateLabelBaseline(geom);
      const dayY: number = monthY + this.dateLineHeight();
      let prevMonth: string = '';
      for (let k = 0; k < days.length; k++) {
        const x: number = geom.padL + pxPerDay * days[k];
        if (k === 0) {
          ctx.textAlign = 'left';
        } else if (k === days.length - 1) {
          ctx.textAlign = 'right';
        } else {
          ctx.textAlign = 'center';
        }
        const md: string = DateUtils.formatMonthDay(geom.tMin + days[k] * DateUtils.MS_PER_DAY);
        const cut: number = md.indexOf('-');
        const mm: string = cut > 0 ? md.substring(0, cut) : '';
        const dd: string = cut > 0 ? md.substring(cut + 1) : md;
        // 月份只在第一个标签和跨月那天出现：一屏七个「08」是纯噪声
        if (mm.length > 0 && mm !== prevMonth) {
          ctx.fillText(mm, x, monthY);
          prevMonth = mm;
        }
        ctx.fillText(dd, x, dayY);
      }
    }
  }

  /**
   * 当天档的 X 轴刻度（v1.13）：点就是当天的各次测量，所以刻度是**时刻**而不是日期。
   * 一天可能量十几次，每次都标会挤成一团 —— 按放得下的密度跳着标，首末两次必定标出。
   * 纵向位置沿用日期网格的「日」行，切换档位时刻度不会跳。
   */
  private drawTimeLabels(geom: Geom, pal: ChartPalette): void {
    const ctx: CanvasRenderingContext2D = this.ctx;
    const n: number = this.points.length;
    const span: number = geom.width - geom.padL - geom.padR;
    const labelFont: number = this.fs(FONT_DATE);
    ctx.font = `${labelFont}px sans-serif`;
    ctx.fillStyle = pal.textSecondary;
    const step: number = n > 1 ? span / (n - 1) : span;
    const need: number = ctx.measureText('88:88').width * 1.35;
    let skip: number = 1;
    while (step * skip < need && skip < n) {
      skip++;
    }
    const labelY: number = this.dateLabelBaseline(geom) + this.dateLineHeight();
    for (let i = 0; i < n; i += skip) {
      if (i === 0) {
        ctx.textAlign = 'left';
      } else if (i + skip >= n) {
        ctx.textAlign = 'right';
      } else {
        ctx.textAlign = 'center';
      }
      ctx.fillText(DateUtils.formatTime(this.points[i].dayStart), this.xAt(geom, i), labelY);
    }
    const last: number = n - 1;
    if (last > 0 && last % skip !== 0) {
      ctx.textAlign = 'right';
      ctx.fillText(DateUtils.formatTime(this.points[last].dayStart), this.xAt(geom, last), labelY);
    }
  }

  /** 双参考线：140/90（诊室）与 135/85（家庭自测），FR-3.2 */
  private drawReferenceLines(geom: Geom): void {
    // v1.12：两条线的标注分别放在绘图区的**左端与右端**。
    // 两条线只差 5 mmHg —— 横屏下约 6vp、竖屏下约 8vp，而字号是 15vp，
    // 只要放在同一侧就必然叠字（v1.11 那版「上下错开 1.25 倍字号」在真机上仍被读成挤在一起）。
    // 两端分开是结构上的不可能重叠；线义另外由画布外的 ref_caption 说明行 + 线型区分。
    const clinic: string = `${AppConst.REF_CLINIC_SYS}/${AppConst.REF_CLINIC_DIA}`;
    const home: string = `${AppConst.REF_HOME_SYS}/${AppConst.REF_HOME_DIA}`;
    // 线型区分：家庭自测是默认参考口径，用长虚线；诊室标准用短虚线
    this.drawRefLine(geom, AppConst.REF_CLINIC_SYS, clinic, true, [3, 4]);
    this.drawRefLine(geom, AppConst.REF_CLINIC_DIA, '', true, [3, 4]);
    this.drawRefLine(geom, AppConst.REF_HOME_SYS, home, false, [7, 4]);
    this.drawRefLine(geom, AppConst.REF_HOME_DIA, '', false, [7, 4]);
  }

  /**
   * 一条参考线：横线 + 一端的「数字对」标注（带底色垫）。
   * 旧版把数值（140 / 135）左对齐画进绘图区、与左轴刻度挤成一堆；v1.11 改成只在右端标一次，
   * 但两条线的标注仍然贴在一起；v1.12 起由 `atRight` 决定标在左端还是右端，两条线各占一头。
   */
  private drawRefLine(geom: Geom, value: number, label: string, atRight: boolean, dash: number[]): void {
    if (value < geom.bpLo || value > geom.bpHi) {
      return;
    }
    const ctx: CanvasRenderingContext2D = this.ctx;
    const pal: ChartPalette = this.palette();
    const y: number = this.yBp(geom, value);
    ctx.strokeStyle = pal.refLine;
    ctx.lineWidth = 1;
    ctx.setLineDash(dash);
    ctx.beginPath();
    ctx.moveTo(geom.padL, y);
    ctx.lineTo(geom.width - geom.padR, y);
    ctx.stroke();
    ctx.setLineDash([]);

    if (label.length === 0) {
      return;
    }
    const refFont: number = this.fs(FONT_REF);
    ctx.font = `${refFont}px sans-serif`;
    const padX: number = 5;
    const boxW: number = ctx.measureText(label).width + padX * 2;
    const boxH: number = refFont + 6;
    // 标注贴在自己那条线的同一高度上（不做上下偏移，避免读者认错线），靠左右分居两端避免重叠
    const boxX: number = atRight ? geom.width - geom.padR - 3 - boxW : geom.padL + 3;
    const boxY: number = y - boxH / 2;
    // 底色垫：压掉虚线穿字，横向滚动时也读得清
    ctx.fillStyle = pal.bg;
    this.roundedRectPath(boxX, boxY, boxW, boxH, 4);
    ctx.fill();
    ctx.fillStyle = pal.textSecondary;
    ctx.textAlign = 'left';
    ctx.fillText(label, boxX + padX, y + refFont * 0.36);
  }

  /**
   * 异常测量点（收缩压 ≥ 140 或舒张压 ≥ 90）：橙色实心点 + 一圈底色描边。
   *
   * v1.13 取代了 v1.11 的「收缩压—舒张压区间色带」。真机上那块面的问题是不管数据好坏都在喊，
   * 而第三方参考界面用「异常点变色」这种更克制的标记，反而更容易找到该注意的那几次；
   * 底色外圈是为了让橙点在曲线穿过时也读得出来（尤其是同一列上收缩压/舒张压都异常时）。
   */
  private drawAbnormalMarks(geom: Geom): void {
    const n: number = this.points.length;
    if (n === 0) {
      return;
    }
    const ctx: CanvasRenderingContext2D = this.ctx;
    const pal: ChartPalette = this.palette();
    const r: number = this.fontScale > 1 ? 4.6 : 4;
    ctx.setLineDash([]);
    for (let i = 0; i < n; i++) {
      const p: DailyPoint = this.points[i];
      if (!GradeService.isAbnormal(Math.round(p.sysAvg), Math.round(p.diaAvg))) {
        continue;
      }
      const x: number = this.xAt(geom, i);
      const ys: number = this.yBp(geom, p.sysAvg);
      const yd: number = this.yBp(geom, p.diaAvg);
      ctx.fillStyle = pal.bg;
      this.fillDot(x, ys, r + 1.6);
      this.fillDot(x, yd, r + 1.6);
      ctx.fillStyle = pal.pointAbnormal;
      this.fillDot(x, ys, r);
      this.fillDot(x, yd, r);
    }
  }

  /** 画一个实心圆点（多处复用，省去重复的 beginPath / arc / fill 三连） */
  private fillDot(x: number, y: number, r: number): void {
    const ctx: CanvasRenderingContext2D = this.ctx;
    ctx.beginPath();
    ctx.arc(x, y, r, 0, Math.PI * 2);
    ctx.fill();
  }

  private drawSeries(geom: Geom): void {
    // v1.11：心率先画 —— 它退到背景层，血压两条线压在上面
    if (this.showHeartRate) {
      this.strokeSeries(geom, 'hr');
    }
    this.strokeSeries(geom, 'sys');
    this.strokeSeries(geom, 'dia');
    // v1.13：异常点压在三条线之上
    this.drawAbnormalMarks(geom);
  }

  private strokeSeries(geom: Geom, kind: string): void {
    const ctx: CanvasRenderingContext2D = this.ctx;
    const pal: ChartPalette = this.palette();
    const n: number = this.points.length;
    if (n === 0) {
      return;
    }

    if (kind === 'hr') {
      ctx.strokeStyle = pal.lineHr;
    } else if (kind === 'sys') {
      ctx.strokeStyle = pal.lineSys;
    } else {
      ctx.strokeStyle = pal.lineDia;
    }
    // 线宽下调：3–3.5vp 在真机上显得笨重，2vp 与更大的字号搭配更清爽。
    // v1.11：心率退到背景层；v1.13 再细一档并进一步压淡 —— 参考界面的观感是「细线 + 圆点」
    const isHr: boolean = kind === 'hr';
    const grow: number = this.fontScale > 1.3 ? 0.5 : 0;
    ctx.lineWidth = isHr ? 1.1 + grow : (kind === 'sys' ? 1.8 + grow : 1.5 + grow);
    if (isHr) {
      ctx.globalAlpha = 0.6;
    }
    ctx.lineJoin = 'round';
    ctx.lineCap = 'round';
    ctx.setLineDash([]);
    ctx.beginPath();

    let started: boolean = false;
    for (let i = 0; i < n; i++) {
      const p: DailyPoint = this.points[i];
      const x: number = this.xAt(geom, i);
      const value: number | null = GenericChartHelper.pickOf(p, kind);
      if (value === null || value === undefined) {
        continue;
      }
      const y: number = kind === 'hr' ? this.yHr(geom, value) : this.yBp(geom, value);
      if (!started) {
        ctx.moveTo(x, y);
        started = true;
      } else {
        ctx.lineTo(x, y);
      }
    }
    if (started) {
      ctx.stroke();
    }

    // 数据点：半径随水平间距走 —— 90 天全览时点挨得极近，大圆点会连成一串珠子
    const dotSpan: number = geom.width - geom.padL - geom.padR;
    const dotStep: number = n > 1 ? dotSpan / (n - 1) : dotSpan;
    let dotR: number = dotStep >= 18 ? (this.fontScale > 1 ? 4 : 3.2) : 2.4;
    if (isHr) {
      dotR = 2.2;
    }
    ctx.fillStyle = ctx.strokeStyle;
    for (let i = 0; i < n; i++) {
      const p: DailyPoint = this.points[i];
      const x: number = this.xAt(geom, i);
      const value: number | null = GenericChartHelper.pickOf(p, kind);
      if (value === null || value === undefined) {
        continue;
      }
      const y: number = kind === 'hr' ? this.yHr(geom, value) : this.yBp(geom, value);
      ctx.beginPath();
      ctx.arc(x, y, dotR, 0, Math.PI * 2);
      ctx.fill();
    }
    if (isHr) {
      ctx.globalAlpha = 1;
    }
  }

  /** 药丸标记：当日完成全部服药打卡（FR-9.6）。画在日期标签**下方**单独一条泳道，避免与标签重叠 */
  private drawMedMarks(geom: Geom): void {
    const ctx: CanvasRenderingContext2D = this.ctx;
    // 与日期标签共用同一套基线公式（月份行 + 日行），药丸画在两行下面
    const y: number = this.dateLabelBaseline(geom) + this.dateLineHeight() + this.fs(9);
    const r: number = this.fontScale > 1 ? 4 : 3.4;
    ctx.fillStyle = this.palette().medMark;
    for (let i = 0; i < this.points.length; i++) {
      if (!this.points[i].medComplete) {
        continue;
      }
      const x: number = this.xAt(geom, i);
      ctx.beginPath();
      ctx.arc(x, y, r, 0, Math.PI * 2);
      ctx.fill();
    }
  }

  /**
   * 标准圆角矩形路径（用 arcTo，不用 arc 手工拼）。
   *
   * v1.4 修正：原来用两个 arc + lineTo 手工拼，顶点顺序错了 ——
   * 左端圆心落在**上边**上、右端圆心落在**下边**上，closePath 再拉一条斜线，
   * 结果填充区域被斜切掉一个角（实测 y 范围 26–54，而矩形本应是 30–50），
   * 文字左侧约 30% 落在色块之外 → 看起来「背景与前景不一致」。
   */
  private roundedRectPath(x: number, y: number, w: number, h: number, radius: number): void {
    const ctx: CanvasRenderingContext2D = this.ctx;
    const r: number = Math.min(radius, w / 2, h / 2);
    ctx.beginPath();
    ctx.moveTo(x + r, y);
    ctx.lineTo(x + w - r, y);
    ctx.arcTo(x + w, y, x + w, y + r, r);
    ctx.lineTo(x + w, y + h - r);
    ctx.arcTo(x + w, y + h, x + w - r, y + h, r);
    ctx.lineTo(x + r, y + h);
    ctx.arcTo(x, y + h, x, y + h - r, r);
    ctx.lineTo(x, y + r);
    ctx.arcTo(x, y, x + r, y, r);
    ctx.closePath();
  }

  /** 点击浮层：显示当日日期、收缩/舒张/心率与测量次数 */
  private drawSelection(geom: Geom): void {
    const idx: number = this.selectedIndex;
    if (idx < 0 || idx >= this.points.length) {
      return;
    }
    const ctx: CanvasRenderingContext2D = this.ctx;
    const pal: ChartPalette = this.palette();
    const p: DailyPoint = this.points[idx];
    const x: number = this.xAt(geom, idx);

    ctx.strokeStyle = pal.axis;
    ctx.lineWidth = 1;
    ctx.setLineDash([3, 3]);
    ctx.beginPath();
    ctx.moveTo(x, geom.padT);
    ctx.lineTo(x, geom.height - geom.padB);
    ctx.stroke();
    ctx.setLineDash([]);

    // 当天档的点就是「一次测量」：日期对这十几条全一样、x1 也是噪声，所以只标时刻（v1.13）
    const intraday: boolean = geom.tMax - geom.tMin < DateUtils.MS_PER_DAY;
    const stamp: string = intraday
      ? DateUtils.formatTime(p.dayStart)
      : DateUtils.formatMonthDay(p.dayStart);
    const text: string = `${stamp}  ${Math.round(p.sysAvg)}/${Math.round(p.diaAvg)}`;
    const hrText: string = p.hrAvg === null || p.hrAvg === undefined ? '' : `  ${Math.round(p.hrAvg)}`;
    const countText: string = intraday ? '' : `  x${p.count}`;
    const content: string = `${text}${hrText}${countText}`;

    const boxFont: number = this.fs(FONT_TOOLTIP);
    ctx.font = `${boxFont}px sans-serif`;
    const textWidth: number = ctx.measureText(content).width;
    const padX: number = 10;
    const boxW: number = textWidth + padX * 2;
    const boxH: number = boxFont + 14;

    // 横向夹在绘图区内，纵向贴着顶部（不与底部日期标签重叠）
    const left: number = geom.padL;
    const right: number = geom.width - geom.padR;
    let boxX: number = x - boxW / 2;
    if (boxX < left) {
      boxX = left;
    }
    if (boxX + boxW > right) {
      boxX = Math.max(left, right - boxW);
    }
    let boxY: number = geom.padT + 2;
    if (boxY + boxH > geom.height - geom.padB) {
      boxY = Math.max(0, geom.height - geom.padB - boxH);
    }

    ctx.fillStyle = pal.tooltipBg;
    this.roundedRectPath(boxX, boxY, boxW, boxH, 6);
    ctx.fill();

    ctx.fillStyle = pal.tooltipText;
    ctx.textAlign = 'left';
    // 垂直居中：基线 = 盒中心 + 约 0.36 倍字号
    ctx.fillText(content, boxX + padX, boxY + boxH / 2 + boxFont * 0.36);
  }
}

/** 取序列值：三条曲线共用一段取值逻辑，避免在两处复制同一判断 */
class GenericChartHelper {
  static pickOf(p: DailyPoint, kind: string): number | null {
    if (kind === 'sys') {
      return p.sysAvg;
    }
    if (kind === 'dia') {
      return p.diaAvg;
    }
    return p.hrAvg;
  }
}
