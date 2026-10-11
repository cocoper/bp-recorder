import { common } from '@kit.AbilityKit';
import { GradeColor, GradeText } from '../common/Constants';
import { ResUtils } from '../common/ResUtils';
import { GradeLevel } from '../model/Types';
import { GradeService } from '../service/GradeService';

/**
 * 「严重度」尺度：2 × 舒张压 − 40 恰好把舒张压的四条界值（80 / 90 / 100 / 110）
 * 映到收缩压的四条界值（120 / 140 / 160 / 180）上 ——
 * 于是 max(收缩压, 2 × 舒张压 − 40) 落在哪一段，就和 GradeService.gradeOf 判出的分级完全一致，
 * 不会出现「指针停在橙色段而文字写着 2 级」这种自相矛盾的画面。
 */
const SCALE_LO: number = 80;
const SCALE_HI: number = 200;
/** 分级界值（收缩压口径，与 GradeSpecs.CN_GUIDELINE 同源） */
const BOUNDS: number[] = [120, 140, 160, 180];
/** 弧段数 = 分级档数 */
const SEGMENTS: number = 5;

/** 仪表盘配色（取自 chart_* 与 grade_* 资源，随深浅色主题走） */
interface GaugePalette {
  value: number;
  unit: number;
  caption: number;
  pointer: number;
  empty: number;
  seg: number[];
}

/**
 * 血压半圆仪表盘（v1.13 趋势页顶部的「一眼看结果」区域，参考第三方血压 App 的界面）。
 *
 * 结构：五段彩色半圆弧（按分级色标着色）+ 一枚白色三角指针 + 弧内居中的
 * 「分级 / 收缩压·舒张压 / 心率」三行文字。
 *
 * - 弧段与指针都在 Canvas 上自绘，**文字用 ArkUI 的 Text**：
 *   系统字号放大时文字跟着长，而弧是几何图形，缩放不参与；
 * - 画布**不填背景**，卡片底色由调用方决定（趋势页是深色卡）；
 * - 无数据（收缩压或舒张压 ≤ 0）时只画一条灰弧、不画指针与文字，不崩溃（CL-3）。
 */
@Component
export struct BpGauge {
  /** 本次测量收缩压；≤ 0 视为无数据 */
  @Prop @Watch('redraw') systolic: number = 0;
  /** 本次测量舒张压；≤ 0 视为无数据 */
  @Prop @Watch('redraw') diastolic: number = 0;
  /** 本次测量心率；< 0 表示未记录（显示占位符「心率 —」） */
  @Prop @Watch('redraw') heartRate: number = -1;
  /** 画布高度（vp） */
  @Prop @Watch('redraw') gaugeHeight: number = 180;

  private settings: RenderingContextSettings = new RenderingContextSettings(true);
  private ctx: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.settings);
  /** 配色缓存：资源取值要走资源管理器，不必每次重绘都重取 */
  private palCache: GaugePalette | null = null;
  /** 系统配置变更（含深浅色切换）的版本号，由 EntryAbility 递增 */
  @StorageProp('themeVersion') @Watch('redraw') themeVersion: number = 0;

  private abilityContext(): common.UIAbilityContext {
    return ResUtils.hostContext(this.getUIContext());
  }

  private color(res: Resource): number {
    return ResUtils.colorValue(this.abilityContext(), res);
  }

  private palette(): GaugePalette {
    if (this.palCache === null) {
      this.palCache = this.buildPalette();
    }
    return this.palCache;
  }

  private buildPalette(): GaugePalette {
    return {
      value: this.color($r('app.color.chart_text_primary')),
      unit: this.color($r('app.color.chart_text_secondary')),
      caption: this.color($r('app.color.chart_text_secondary')),
      pointer: this.color($r('app.color.chart_gauge_pointer')),
      empty: this.color($r('app.color.chart_axis')),
      seg: [
        this.color(GradeColor.of(GradeLevel.NORMAL)),
        this.color(GradeColor.of(GradeLevel.HIGH_NORMAL)),
        this.color(GradeColor.of(GradeLevel.GRADE_1)),
        this.color(GradeColor.of(GradeLevel.GRADE_2)),
        this.color(GradeColor.of(GradeLevel.GRADE_3))
      ]
    };
  }

  private hasData(): boolean {
    return this.systolic > 0 && this.diastolic > 0;
  }

  private level(): GradeLevel {
    return GradeService.gradeOf(this.systolic, this.diastolic);
  }

  /** 严重度值：收缩压与「舒张压折算到收缩压刻度」两者取高 */
  private severity(): number {
    const fromDia: number = this.diastolic * 2 - 40;
    return this.systolic >= fromDia ? this.systolic : fromDia;
  }

  /** 严重度 → 弧上比例（0 = 最左端起，1 = 最右端止） */
  private scaleRatio(value: number): number {
    const raw: number = (value - SCALE_LO) / (SCALE_HI - SCALE_LO);
    if (raw < 0) {
      return 0;
    }
    return raw > 1 ? 1 : raw;
  }

  redraw(): void {
    this.palCache = null;
    this.draw();
  }

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      Canvas(this.ctx)
        .width('100%')
        .height(this.gaugeHeight)
        .onReady(() => {
          this.draw();
        })
        // 尺寸真正变化后重绘：否则旋转屏幕后会沿用旧尺寸绘制
        .onAreaChange((oldValue: Area, newValue: Area) => {
          this.draw();
        })

      if (this.hasData()) {
        Column({ space: 2 }) {
          Text(GradeText.label(this.level()))
            .fontSize(17)
            .fontWeight(FontWeight.Medium)
            .fontColor(GradeColor.of(this.level()))
          Row({ space: 6 }) {
            Text($r('app.string.metric_bp_value_only', Math.round(this.systolic), Math.round(this.diastolic)))
              .fontSize(40)
              .fontWeight(FontWeight.Bold)
              .fontColor(this.palette().value)
            Text($r('app.string.unit_mmhg'))
              .fontSize(14)
              .fontColor(this.palette().unit)
              .margin({ bottom: 8 })
          }
          .width('100%')
          .alignItems(VerticalAlign.Bottom)
          .justifyContent(FlexAlign.Center)

          Text(this.heartRate >= 0
            ? $r('app.string.heart_rate_value', Math.round(this.heartRate))
            : $r('app.string.heart_rate_empty'))
            .fontSize(15)
            .fontColor(this.palette().caption)
        }
        .width('100%')
        .alignItems(HorizontalAlign.Center)
        .padding({ bottom: this.gaugeHeight * 0.06 })
        // 文字只做展示，别挡住画布（也不参与点击）
        .hitTestBehavior(HitTestMode.None)
      }
    }
    .width('100%')
    .height(this.gaugeHeight)
  }

  // ───────────────────────── 绘制 ─────────────────────────

  private draw(): void {
    const ctx: CanvasRenderingContext2D = this.ctx;
    const width: number = ctx.width;
    const height: number = ctx.height;
    if (width <= 0 || height <= 0) {
      return;
    }
    // 背景透明：卡片底色由调用方给（趋势页是深色卡）
    ctx.clearRect(0, 0, width, height);

    const pal: GaugePalette = this.palette();
    const band: number = 14;
    const bottomPad: number = 14;
    const cx: number = width / 2;
    const cy: number = height - bottomPad;
    // 半圆半径三重约束：宽度放得下、高度够（否则弧被压扁）、圆心以上留得下
    const radius: number = Math.max(20, Math.min(width / 2 - 12, height * 0.72, cy - 6));

    if (!this.hasData()) {
      ctx.beginPath();
      ctx.arc(cx, cy, radius, Math.PI, Math.PI * 2);
      ctx.lineWidth = band;
      ctx.strokeStyle = pal.empty;
      ctx.stroke();
      return;
    }

    // ① 五段分级弧：从最左端（SCALE_LO）到最右端（SCALE_HI），每段一个分级色
    const edges: number[] = [SCALE_LO, BOUNDS[0], BOUNDS[1], BOUNDS[2], BOUNDS[3], SCALE_HI];
    for (let i = 0; i < SEGMENTS; i++) {
      const a0: number = Math.PI + Math.PI * this.scaleRatio(edges[i]);
      const a1: number = Math.PI + Math.PI * this.scaleRatio(edges[i + 1]);
      ctx.beginPath();
      ctx.arc(cx, cy, radius, a0, a1);
      ctx.lineWidth = band;
      ctx.strokeStyle = pal.seg[i];
      ctx.stroke();
    }

    // ② 指针：底边压在弧上、尖端指向弧心（径向摆位，与弧的走向正交）
    const theta: number = Math.PI + Math.PI * this.scaleRatio(this.severity());
    const ux: number = Math.cos(theta);
    const uy: number = Math.sin(theta);
    const tx: number = -uy;
    const ty: number = ux;
    const tipR: number = radius - band / 2 - 11;
    const baseR: number = radius + band / 2 + 2;
    const half: number = 9;
    ctx.beginPath();
    ctx.moveTo(cx + ux * tipR, cy + uy * tipR);
    ctx.lineTo(cx + ux * baseR + tx * half, cy + uy * baseR + ty * half);
    ctx.lineTo(cx + ux * baseR - tx * half, cy + uy * baseR - ty * half);
    ctx.closePath();
    ctx.fillStyle = pal.pointer;
    ctx.fill();
  }
}
