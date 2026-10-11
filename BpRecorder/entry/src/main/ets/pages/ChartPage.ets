import { common } from '@kit.AbilityKit';
import { router, window } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { DateUtils } from '../common/DateUtils';
import { Logger } from '../common/Logger';
import { ChartScheme, RefBasis } from '../common/Constants';
import { Prefs } from '../common/Prefs';
import { ResUtils } from '../common/ResUtils';
import { ReportVocab, VocabFactory } from '../common/Vocab';
import { BpRecord, DailyPoint, RangeStats } from '../model/BpRecord';
import { BpDatabase } from '../service/BpDatabase';
import { FileService } from '../service/FileService';
import { ReportService } from '../service/ReportService';
import { ShareService } from '../service/ShareService';
import { StatsService } from '../service/StatsService';
import { BpGauge } from '../components/BpGauge';
import { BpLineChart } from '../components/BpLineChart';
import { ZoomChip } from '../components/ZoomChip';

const TAG: string = 'ChartPage';
const CAPTURE_ID: string = 'bp_chart_capture';
/** 放大时每一天占的宽度（vp）：30/90 天横向铺开后每天的间距都舒服 */
const MIN_COL_WIDTH: number = 46;
/** 画布高度（vp）。固定值——若随缩放变高，捏合时整页会跟着上下跳 */
const CHART_HEIGHT: number = 340;
/** 缩放倍数上限 */
const MAX_ZOOM: number = 5;
/** 按钮每次点击的缩放步长 */
const ZOOM_STEP: number = 1.3;
/**
 * 内容宽度上限（vp）。Canvas 的位图是「宽 × 高 × 像素密度²」，必须封顶：
 * 2400 × 340 × 3² ≈ 7.3M 像素 ≈ 29MB，再往上就有撑爆渲染内存的风险。
 * 据此算出的可用放大范围随区间变长而收窄（90 天约 1.7 倍，7 天可到 5 倍）。
 */
const MAX_CONTENT_WIDTH: number = 2400;
/** 可视宽度未知时的兜底值 */
const FALLBACK_VIEW_WIDTH: number = 320;

/**
 * 页面方向三档（用户要求「两个都要」：既跟随系统自动旋转，也能手动切）。
 * 顶栏的方向胶囊按 AUTO → LANDSCAPE → PORTRAIT → AUTO 轮换。
 */
enum OrientMode {
  /** 跟随传感器自动旋转（window.Orientation.AUTO_ROTATION） */
  AUTO = 0,
  LANDSCAPE = 1,
  PORTRAIT = 2
}

/**
 * 横屏时顶栏（周期分段已并入本行）+ 图表卡的标题 / 图例 / 内外边距占掉的高度（vp），
 * 从窗口高度里扣掉它，剩下的全部给画布。
 *
 * v1.11 由 230 降到 150：旧值是按「顶栏 74 + 独占一行的周期分段 41 + 卡片内固定 112」算的，
 * 在 424vp 高的横屏里只给画布留下约 194vp，三条线挤成一条色带（真机截图确认）。
 * 现在分段并入顶栏后，预算 = 顶栏 50 + 滚动区上边距 12 + 卡片内固定（标题 20 + 间距 6 +
 * 图例 30 + 内边距 18）≈ 136，取 150 留一点余量 → 画布约 274vp。
 */
const LANDSCAPE_CHROME: number = 150;
const LANDSCAPE_MIN_CHART_HEIGHT: number = 140;
const LANDSCAPE_MAX_CHART_HEIGHT: number = 520;

/**
 * 趋势图表页（FR-3 / FR-11 / 策划文档 §5.3）。
 *
 * ## 画布与缩放（本次改造的核心）
 * 图表卡里是一个**横向 Scroll 包着一张可更宽的画布**：
 * - 进入页面时默认「全览」——画布宽 = 可视宽，整段趋势一屏看完；
 * - 双指捏合（或下方 −/+ 按钮）放大后画布变宽，每天拿到 MIN_COL_WIDTH 的间距，
 *   单指左右滑动查看前后日期，图例与水印留在滚动区外面始终可见；
 * - 「全览」按钮一键回到开头的一屏视图。
 *
 * ## 分享 / 保存截的就是这张图
 * 被截屏的容器（CAPTURE_ID）就是图表卡本身，里面只有这一张画布，因此
 * **分享/保存的产物 = 用户当下看到的视图**：默认是全览（完整区间），放大后是当前视口。
 * 这样做是为了不引入第二张隐藏画布或「截屏前临时还原视图」的状态机 ——
 * 后者在「保存到相册」路径上会错过 SaveButton 的临时授权窗口，风险更高。
 *
 * ## 横竖屏（v1.10）
 * 顶栏右侧的方向胶囊显示当前档位，点一下按「自动旋转 → 横屏 → 竖屏」轮换：
 * - 「自动旋转」下发 `window.Orientation.AUTO_ROTATION`（跟随传感器四向，**不受控制中心
 *   旋转开关限制**），所以手机横过来图就横过来，不需要用户先解锁旋转开关；
 * - 横屏时页面自动精简为「只看图」——概览卡、缩放按钮、保存与免责声明都让位给画布，
 *   画布高度按窗口高度算（`chartHeight()`），尽量把屏幕填满；
 * - 离开页面时把方向控制权交还系统（`UNSPECIFIED`），趋势页之外仍然是竖屏。
 */
@Entry
@Component
struct ChartPage {
  @State private days: number = 7;
  @State private points: DailyPoint[] = [];
  @State private loading: boolean = true;
  @State private watermark: string = '';
  /** 区间内「每条记录等权」的统计量：概览的均值口径与统计页、报告页一致 */
  @State private stats: RangeStats | null = null;
  /** 横向滚动容器的可视宽度，画布要不要加宽由它决定 */
  @State private viewWidth: number = 0;
  /** 当前缩放倍数（1 = 画面宽度等于可视宽度） */
  @State private zoom: number = 1;
  /**
   * 周期档位（v1.13，按用户指定的第三方参考界面调整为「今天 / 7 / 14 / 30 天」）。
   * 0 = 今天：区间是当天 00:00–24:00，且**每次测量各占一个点**（不做同日聚合，见 StatsService.intradayPoints）。
   */
  private readonly ranges: number[] = [0, 7, 14, 30];
  /** 加载代次：区间切换与页面返回都可能连发多次请求，用它丢弃过期响应 */
  private loadSeq: number = 0;
  private scroller: Scroller = new Scroller();
  /** 一次捏合手势开始时的缩放倍数（事件里的 scale 是相对手势起点的累计值） */
  private pinchBase: number = 1;
  /** 用户是否手动缩放过；没动过就让视图一直跟着「全览」走（会影响「全览」按钮的可用态，故为 @State） */
  @State private manualZoom: boolean = false;
  /** 补发滚动的定时器 id；-1 表示没有待补发的滚动 */
  private scrollTimer: number = -1;
  /** 当前方向档位（顶栏胶囊显示它，点一下就轮换） */
  @State private orientMode: OrientMode = OrientMode.AUTO;
  /** 页面可视区宽高：旋屏后由根容器的 onAreaChange 更新，用来判断当前是不是横屏 */
  @State private pageWidth: number = 0;
  @State private pageHeight: number = 0;
  /** 参考口径的目标值（FR-7.1 的设置项，趋势页只读展示） */
  @State private refSys: number = 0;
  @State private refDia: number = 0;
  /** 应用主窗口（方向控制只对主窗口生效，进页面时取一次缓存下来） */
  private topWindow: window.Window | null = null;

  // 只在 onPageShow 触发加载：@Entry 页首次显示也会走 onPageShow，
  // 若再在 aboutToAppear 里加载一次，首屏会对同一区间并发两次查询。
  onPageShow(): void {
    // 按当前档位重新下发一次方向（幂等）；首次进入档位是「自动旋转」
    this.applyOrientation();
    // 「参考口径」可能在设置页被改过，每次显示都重读一次
    this.loadRefTarget();
    // 从录入页返回等场景静默刷新：保留当前缩放与横向位置，避免图表闪烁与选中点丢失。
    this.load(false);
  }

  aboutToDisappear(): void {
    // 页面销毁后 scroller 不再有效，必须清掉待补发的滚动
    if (this.scrollTimer !== -1) {
      clearTimeout(this.scrollTimer);
      this.scrollTimer = -1;
    }
    // 把方向控制权交还系统，趋势页之外仍然是竖屏
    this.releaseOrientation();
  }

  private context(): common.UIAbilityContext {
    return ResUtils.hostContext(this.getUIContext());
  }

  /**
   * 拉取当前区间数据并重算概览。
   * @param showLoading true = 显示加载态并先清空旧区间结果（首屏 / 切换周期）；
   *                    false = 静默刷新（从录入页返回等），保留当前图表不闪烁。
   */
  private async load(showLoading: boolean): Promise<void> {
    const seq: number = ++this.loadSeq;
    if (showLoading) {
      this.loading = true;
      // 先清空：否则会出现「旧区间的数值 + 新天数的副标题」这种自相矛盾的中间态
      this.points = [];
      this.stats = null;
    }
    const now: number = DateUtils.now();
    // 「今天」档只要当天 00:00–24:00 这一段（lastDaysRange(1) 就是它）
    const range = StatsService.lastDaysRange(this.days > 0 ? this.days : 1, now);
    try {
      const db: BpDatabase = BpDatabase.getInstance();
      const records: BpRecord[] = await db.queryBpBetween(range.start, range.end);
      const logs = await db.queryMedLogsBetween(range.start, range.end);
      if (seq !== this.loadSeq) {
        // 已有更新的请求发出，丢弃本次过期响应，避免后发先至的旧数据覆盖新区间
        return;
      }
      const medDays: number[] = ReportService.medCompleteDays(logs, now);
      if (this.days === 0) {
        // 「今天」档：每次测量各占一个点 —— 一天的曲线不该被压成一个点（X 轴间距 = 真实时间差）
        this.points = StatsService.intradayPoints(records, medDays);
      } else {
        // 同日多次测量取平均值；带出「当日已完成全部服药打卡」标记（FR-3.3 / FR-9.6）
        this.points = StatsService.dailyMeans(records, medDays);
      }
      // 概览的均值口径：区间内每条记录等权（StatsService 的口径约定，与统计页/报告页一致）
      this.stats = StatsService.rangeStats(records);
      // 点数变了，画布宽度跟着变：没手动缩放过就回到「全览」
      this.syncZoomToFit();

      const vocab: ReportVocab = VocabFactory.report(this.context());
      this.watermark = `${range.label}${vocab.separator}${DateUtils.formatDateTime(now)}${vocab.separator}${vocab.watermarkSuffix}`;
    } catch (err) {
      if (seq !== this.loadSeq) {
        return;
      }
      const e = err as BusinessError;
      Logger.error(TAG, `load chart failed: code=${e.code}, message=${e.message}`);
      this.points = [];
      this.stats = null;
      this.toast($r('app.string.error_db_read'));
    } finally {
      // 只有「最后一次」请求负责收尾加载态；被丢弃的旧请求不能把新请求的加载态提前关掉
      if (seq === this.loadSeq) {
        this.loading = false;
      }
    }
  }

  private toast(res: Resource): void {
    this.getUIContext().getPromptAction().showToast({ message: res, duration: 2000 });
  }

  // ───────────────────────── 屏幕方向（v1.10） ─────────────────────────

  /** 是否处于横屏：按页面可视区的宽高比判断（旋屏后 onAreaChange 会刷新） */
  private isLandscape(): boolean {
    return this.pageWidth > 0 && this.pageWidth > this.pageHeight;
  }

  /** 胶囊上的字：显示当前档位 */
  private orientLabel(): Resource {
    if (this.orientMode === OrientMode.LANDSCAPE) {
      return $r('app.string.rotate_landscape');
    }
    if (this.orientMode === OrientMode.PORTRAIT) {
      return $r('app.string.rotate_portrait');
    }
    return $r('app.string.rotate_auto');
  }

  /** 三档轮换：自动旋转 → 横屏 → 竖屏 → 自动旋转 */
  private cycleOrientation(): void {
    if (this.orientMode === OrientMode.AUTO) {
      this.orientMode = OrientMode.LANDSCAPE;
    } else if (this.orientMode === OrientMode.LANDSCAPE) {
      this.orientMode = OrientMode.PORTRAIT;
    } else {
      this.orientMode = OrientMode.AUTO;
    }
    this.applyOrientation();
  }

  /** 档位 → window 枚举 */
  private windowOrientation(): window.Orientation {
    if (this.orientMode === OrientMode.LANDSCAPE) {
      return window.Orientation.LANDSCAPE;
    }
    if (this.orientMode === OrientMode.PORTRAIT) {
      return window.Orientation.PORTRAIT;
    }
    return window.Orientation.AUTO_ROTATION;
  }

  /** 取应用主窗口并缓存。方向控制只对主窗口生效，页面本身不是窗口 */
  private async resolveWindow(): Promise<window.Window | null> {
    if (this.topWindow !== null) {
      return this.topWindow;
    }
    try {
      const win: window.Window = await window.getLastWindow(this.context());
      this.topWindow = win;
      return win;
    } catch (err) {
      const e = err as BusinessError;
      Logger.error(TAG, `resolve window failed: code=${e.code}, message=${e.message}`);
      return null;
    }
  }

  /**
   * 把当前档位下发给主窗口。
   * 失败只记日志：拿不到窗口不该让整个图表页不可用
   * （setPreferredOrientation 可能抛 401 参数错误 / 1300002 窗口状态异常）。
   */
  private async applyOrientation(): Promise<void> {
    const win: window.Window | null = await this.resolveWindow();
    if (win === null) {
      return;
    }
    try {
      await win.setPreferredOrientation(this.windowOrientation());
    } catch (err) {
      const e = err as BusinessError;
      Logger.error(TAG, `set orientation failed: code=${e.code}, message=${e.message}`);
    }
  }

  /** 离页时把方向控制权交还系统（UNSPECIFIED = 跟随系统默认，应用其余页面仍是竖屏） */
  private async releaseOrientation(): Promise<void> {
    const win: window.Window | null = this.topWindow;
    if (win === null) {
      return;
    }
    try {
      await win.setPreferredOrientation(window.Orientation.UNSPECIFIED);
    } catch (err) {
      const e = err as BusinessError;
      Logger.error(TAG, `release orientation failed: code=${e.code}, message=${e.message}`);
    }
  }

  /** 画布高度：竖屏用固定值；横屏把扣掉顶栏等固定高度之后的窗口高度全给画布 */
  private chartHeight(): number {
    if (!this.isLandscape()) {
      return CHART_HEIGHT;
    }
    const avail: number = this.pageHeight - LANDSCAPE_CHROME;
    return Math.max(LANDSCAPE_MIN_CHART_HEIGHT, Math.min(LANDSCAPE_MAX_CHART_HEIGHT, avail));
  }

  // ───────────────────────── 缩放与横向滚动 ─────────────────────────

  private viewW(): number {
    return this.viewWidth > 0 ? this.viewWidth : FALLBACK_VIEW_WIDTH;
  }

  /** zoom = 1 时的内容宽度：至少铺满可视区，且每天不少于 MIN_COL_WIDTH */
  private baseWidth(): number {
    const wanted: number = this.points.length * MIN_COL_WIDTH;
    return Math.max(this.viewW(), wanted);
  }

  /** 「全览」对应的缩放倍数：正好把整段趋势塞进一屏 */
  private minZoom(): number {
    const base: number = this.baseWidth();
    if (base <= 0) {
      return 1;
    }
    const fit: number = this.viewW() / base;
    return Math.min(1, Math.max(0.05, fit));
  }

  /** 当前内容宽度（vp）；封顶在 MAX_CONTENT_WIDTH，避免放出巨型位图 */
  private contentWidth(): number {
    const raw: number = Math.max(this.viewW(), Math.round(this.baseWidth() * this.zoom));
    return Math.min(MAX_CONTENT_WIDTH, raw);
  }

  /** 本区间实际可用的最大缩放倍数（受内容宽度上限约束，可能小于 MAX_ZOOM） */
  private hardMaxZoom(): number {
    const base: number = this.baseWidth();
    if (base <= 0) {
      return MAX_ZOOM;
    }
    return Math.min(MAX_ZOOM, MAX_CONTENT_WIDTH / base);
  }

  private needScroll(): boolean {
    return this.contentWidth() > this.viewW() + 1;
  }

  /**
   * 缩放倍数文案：**相对「全览」**，全览永远是 100%。
   *
   * 旧版直接显示 this.zoom —— 90 天视图为了把 15 个点排开会把基础宽度撑到 690vp，
   * 而屏幕只有约 392vp，于是「全览」状态显示成 58%，用户看到的是一个与「放大到几倍」无关的数。
   * 另外百分比符号写进实参而不是格式串：真机上 `缩放 %d%%` 渲染成了 `缩放 58%%`。
   */
  private zoomText(): ResourceStr {
    const fit: number = this.minZoom();
    const ratio: number = fit > 0 ? this.zoom / fit : 1;
    return $r('app.string.zoom_level', `${Math.round(ratio * 100)}%`);
  }

  /** 没手动缩放过时，让倍数一直等于「全览」——换区间、旋屏后仍是一屏看完 */
  private syncZoomToFit(): void {
    if (this.manualZoom) {
      return;
    }
    const fit: number = this.minZoom();
    if (Math.abs(fit - this.zoom) > 0.0005) {
      this.zoom = fit;
    }
  }

  /**
   * 设置缩放倍数，并按锚点保持视觉位置不动。
   * @param next 目标倍数（内部会夹到合法区间）
   * @param contentX 锚点在**内容坐标系**里的位置
   * @param viewportX 锚点在**可视区**里的位置
   */
  private setZoom(next: number, contentX: number, viewportX: number): void {
    const old: number = this.zoom;
    const low: number = this.minZoom();
    const high: number = Math.max(low, this.hardMaxZoom());
    const clamped: number = Math.max(low, Math.min(high, next));
    if (Math.abs(clamped - old) < 0.0005) {
      return;
    }
    const target: number = contentX * (clamped / old) - viewportX;
    this.zoom = clamped;
    this.scrollToX(target);
  }

  /** 滚动到指定横向偏移；内容宽度要等布局更新，故延迟补发一次 */
  private scrollToX(target: number): void {
    const x: number = Math.max(0, target);
    const y: number = this.scroller.currentOffset().yOffset;
    this.scroller.scrollTo({ xOffset: x, yOffset: y, animation: false });
    if (this.scrollTimer !== -1) {
      clearTimeout(this.scrollTimer);
    }
    this.scrollTimer = setTimeout(() => {
      this.scrollTimer = -1;
      this.scroller.scrollTo({ xOffset: x, yOffset: this.scroller.currentOffset().yOffset, animation: false });
    }, 30);
  }

  /** Area.width / Area.height 的静态类型是 Length（运行时可能是数字或带单位字符串），统一解析成 vp 数值 */
  private areaLen(v: Length): number {
    if (typeof v === 'number') {
      return v;
    }
    if (typeof v === 'string') {
      const n: number = Number.parseFloat(v);
      return Number.isNaN(n) ? 0 : n;
    }
    return 0;
  }

  /** 按钮缩放：以当前可视区中心为锚点 */
  private stepZoom(up: boolean): void {
    this.manualZoom = true;
    const offsetX: number = this.scroller.currentOffset().xOffset;
    const centerViewport: number = this.viewW() / 2;
    const centerContent: number = offsetX + centerViewport;
    this.setZoom(up ? this.zoom * ZOOM_STEP : this.zoom / ZOOM_STEP, centerContent, centerViewport);
  }

  /** 一键回到「全览」：倍数回到最合适的一屏视图并滚回起点 */
  private fitZoom(): void {
    this.manualZoom = false;
    this.zoom = this.minZoom();
    this.scrollToX(0);
  }

  /** 双指捏合：以手势中心为锚点（event.pinchCenterX 是相对组件自身区域的坐标，即内容坐标） */
  private onPinchUpdate(event: GestureEvent): void {
    const offsetX: number = this.scroller.currentOffset().xOffset;
    const next: number = this.pinchBase * event.scale;
    this.setZoom(next, event.pinchCenterX, event.pinchCenterX - offsetX);
  }

  // ── 概览三格的取值（全部由 this.points 现算，避免再查一次库） ──

  private lastPoint(): DailyPoint | null {
    const n: number = this.points.length;
    return n > 0 ? this.points[n - 1] : null;
  }

  /**
   * 读「参考口径」设置里的目标值（家庭自测 135/85 或诊室 140/90）。
   * 仪表盘下方的「参考」行显示它，让用户知道图上那两条虚线是以什么为标准的（FR-7.1）。
   */
  private loadRefTarget(): void {
    const target = RefBasis.of(Prefs.standard(this.context()));
    this.refSys = target.sys;
    this.refDia = target.dia;
  }

  /** 仪表盘上的最新一次测量：无数据时给 0 / -1，由组件自己画一条灰弧 */
  private lastSys(): number {
    const p: DailyPoint | null = this.lastPoint();
    return p === null ? 0 : Math.round(p.sysAvg);
  }

  private lastDia(): number {
    const p: DailyPoint | null = this.lastPoint();
    return p === null ? 0 : Math.round(p.diaAvg);
  }

  private lastHr(): number {
    const p: DailyPoint | null = this.lastPoint();
    if (p === null || p.hrAvg === null || p.hrAvg === undefined) {
      return -1;
    }
    return Math.round(p.hrAvg);
  }

  /** 顶栏副标题：今天档不能写「近 0 天」 */
  private rangeSubtitle(): ResourceStr {
    return this.days === 0 ? $r('app.string.range_today') : $r('app.string.chart_range_subtitle', this.days);
  }

  /** 「—」占位：无数据时的统一显示（直接给资源，交给 Text 在渲染时解析） */
  private dash(): Resource {
    return $r('app.string.metric_placeholder');
  }

  /** 空串会让这一行塌掉，故无数据时用空格占位 */
  private latestSub(): string {
    const p: DailyPoint | null = this.lastPoint();
    return p === null ? ' ' : DateUtils.formatMonthDay(p.dayStart);
  }

  /**
   * 平均血压：区间内**每条记录**等权（StatsService.rangeStats），与统计页、报告页同口径。
   * 不能拿 this.points（已经是日均）再平均——那会变成「每天等权」，同一天测得多的那天权重被压小，
   * 手工核算对不上。例：A 日 3 次 180、B 日 1 次 120 → 本口径 165，每天等权口径 150。
   */
  private avgValue(): ResourceStr {
    const s: RangeStats | null = this.stats;
    if (s === null || s.count === 0) {
      return this.dash();
    }
    return `${Math.round(s.sysMean)} / ${Math.round(s.diaMean)}`;
  }

  /** 平均心率：同样走 rangeStats；单位由该格的 sub 单独给出，此处只回数值，避免「72 bpm / bpm」 */
  private avgHr(): ResourceStr {
    const s: RangeStats | null = this.stats;
    if (s === null || s.hrMean === null || s.hrMean === undefined) {
      return this.dash();
    }
    return `${Math.round(s.hrMean)}`;
  }

  /** 把当前视图渲染为 PNG 并调起系统分享面板（FR-11.1 / FR-11.3） */
  private async shareChart(): Promise<void> {
    if (this.loading) {
      // 加载中截屏会拿到上一个区间的图（或空图），先给出明确反馈而不是失败提示
      this.toast($r('app.string.list_loading'));
      return;
    }
    try {
      const pixelMap = await ShareService.snapshot(CAPTURE_ID);
      const fileName: string = FileService.stampName('bp_chart_', '.png', DateUtils.now());
      const title: string = ResUtils.text(this.context(), $r('app.string.share_chart_title'));
      await ShareService.shareImage(this.context(), pixelMap, fileName, title);
    } catch (err) {
      const e = err as BusinessError;
      Logger.error(TAG, `share chart failed: ${ShareService.describeError(e)}`);
      this.toast($r('app.string.error_snapshot'));
    }
  }

  /**
   * 图例。原本由 BpLineChart 自己画在画布下面，这里改由页面绘制：
   * 画布加宽后它会在横向滚动区里被推到屏幕外，放到滚动区外面才能一直看见。
   * 截屏容器包含这一段，因此分享图里仍然有图例（§5.3）。
   */
  @Builder
  legendItem(color: ResourceColor, label: Resource) {
    Row({ space: 4 }) {
      Divider()
        .vertical(true)
        .strokeWidth(2)
        .height(13)
        .color(color)
      Text(label)
        .fontSize(14)
        .fontColor($r('app.color.chart_text_secondary'))
    }
    .margin({ left: 5, right: 5, top: 2, bottom: 2 })
  }

  /** 圆点式图例项（异常点 / 服药打卡标记），与线式图例项区分（v1.13） */
  @Builder
  legendDot(color: ResourceColor, label: Resource) {
    Row({ space: 4 }) {
      Circle({ width: 8, height: 8 }).fill(color)
      Text(label)
        .fontSize(14)
        .fontColor($r('app.color.chart_text_secondary'))
    }
    .margin({ left: 5, right: 5, top: 2, bottom: 2 })
  }

  @Builder
  legendRow() {
    Column({ space: 4 }) {
      // v1.13：增加「异常」一项（橙色圆点），与画布上的异常点标记一一对应；
      // 五项在窄屏 + 系统大字号下会超出一行，故用可换行的 Flex。
      Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Center }) {
        this.legendDot($r('app.color.chart_point_abnormal'), $r('app.string.legend_abnormal'))
        this.legendItem($r('app.color.chart_line_sys'), $r('app.string.legend_systolic'))
        this.legendItem($r('app.color.chart_line_dia'), $r('app.string.legend_diastolic'))
        this.legendItem($r('app.color.chart_line_hr'), $r('app.string.legend_heart_rate'))
        this.legendDot($r('app.color.chart_med_mark'), $r('app.string.legend_med_mark'))
      }
      .width('100%')

      // v1.11：两条参考线的线义放在画布外 —— 画布内只留 140/90、135/85 数字对，
      // 否则两条线只差 5 mmHg 时整句标注会互相叠字（真机截图确认）。
      Row({ space: 10 }) {
        Text($r('app.string.ref_caption'))
          .fontSize(13)
          .fontColor($r('app.color.chart_watermark'))
        Text($r('app.string.ref_home'))
          .fontSize(13)
          .fontColor($r('app.color.chart_text_secondary'))
        Text($r('app.string.ref_clinic'))
          .fontSize(13)
          .fontColor($r('app.color.chart_text_secondary'))
      }
      .width('100%')
      .justifyContent(FlexAlign.Center)
    }
    .width('100%')
  }

  /**
   * 缩放按钮 / 提示 / 保存到相册 / 免责声明。
   * v1.10 从 build() 里抽出来：横屏时整块隐藏，把纵向空间让给画布。
   * 注意 CAPTURE_ID 容器**不在这里** —— 它在任何方向下都必须常驻，
   * 否则分享与保存到相册会截不到组件。
   */
  @Builder
  auxControls() {
    Column({ space: 12 }) {
      // ── 缩放控件：画布在滚动区里，这里给手势之外的明确入口 ──
      Row({ space: 10 }) {
        ZoomChip({
          label: $r('app.string.zoom_out'),
          usable: !this.loading && this.zoom > this.minZoom() + 0.001,
          onTap: () => {
            this.stepZoom(false);
          }
        })
        Text(this.zoomText())
          .fontSize(14)
          .fontColor($r('app.color.text_secondary'))
        ZoomChip({
          label: $r('app.string.zoom_in'),
          usable: !this.loading && this.zoom < this.hardMaxZoom() - 0.001,
          onTap: () => {
            this.stepZoom(true);
          }
        })
        ZoomChip({
          label: $r('app.string.zoom_fit'),
          usable: !this.loading && (this.manualZoom || this.zoom > this.minZoom() + 0.001),
          onTap: () => {
            this.fitZoom();
          }
        })
      }
      .width('100%')
      .justifyContent(FlexAlign.Center)

      if (this.needScroll()) {
        Text($r('app.string.zoom_scroll_hint'))
          .fontSize(13)
          .fontColor($r('app.color.text_secondary'))
          .width('100%')
          .textAlign(TextAlign.Center)
      }

      Text($r('app.string.chart_tap_hint'))
        .fontSize(13)
        .fontColor($r('app.color.text_tertiary'))
        .width('100%')
        .textAlign(TextAlign.Center)

      // 保存到相册：使用系统安全控件，免相册权限（FR-11.3）
      SaveButton({
        icon: SaveIconStyle.FULL_FILLED,
        text: SaveDescription.SAVE_IMAGE,
        buttonType: ButtonType.Capsule
      })
        .width('100%')
        .height(42)
        .fontSize(15)
        .onClick(async (event: ClickEvent, result: SaveButtonOnClickResult) => {
          if (result !== SaveButtonOnClickResult.SUCCESS) {
            return;
          }
          if (this.loading) {
            // 加载中截屏会拿到上一个区间的图，先给出明确反馈
            this.toast($r('app.string.list_loading'));
            return;
          }
          try {
            const pixelMap = await ShareService.snapshot(CAPTURE_ID);
            const data: ArrayBuffer = await ShareService.packPng(pixelMap);
            await ShareService.saveToAlbum(this.context(), data);
            this.toast($r('app.string.toast_saved_album'));
          } catch (err) {
            const e = err as BusinessError;
            Logger.error(TAG, `save album failed: ${ShareService.describeError(e)}`);
            this.toast($r('app.string.error_save_album'));
          }
        })

      Text($r('app.string.disclaimer_short'))
        .fontSize(13)
        .fontColor($r('app.color.text_tertiary'))
        .width('100%')
        .textAlign(TextAlign.Center)
        .padding({ bottom: 20 })
    }
    .width('100%')
  }

  /**
   * 周期分段：全宽轨道 + 浮起选中块。
   * `compact` 为 true 时用于**横屏顶栏内联**：固定宽度、去掉左右外边距（v1.11）。
   */
  @Builder
  rangeTabs(compact: boolean) {
    Row() {
      ForEach(this.ranges, (d: number) => {
        Text(d === 0 ? $r('app.string.range_today') : $r('app.string.range_days', d))
          .fontSize(compact ? 14 : 15)
          .fontWeight(this.days === d ? FontWeight.Medium : FontWeight.Normal)
          .fontColor(this.days === d ? $r('app.color.text_primary') : $r('app.color.text_secondary'))
          .textAlign(TextAlign.Center)
          .layoutWeight(1)
          .padding({ top: compact ? 4 : 7, bottom: compact ? 4 : 7 })
          .backgroundColor(this.days === d ? $r('app.color.surface') : Color.Transparent)
          .borderRadius(9)
          .onClick(() => {
            if (this.days !== d) {
              this.days = d;
              // 换周期后原来的倍数没有意义（90 天「全览」的倍数放到 7 天会缩得极小）
              this.manualZoom = false;
              this.scroller.scrollTo({ xOffset: 0, yOffset: 0, animation: false });
              this.load(true);
            }
          })
      }, (d: number) => `${d}`)
    }
    .width(compact ? 280 : '100%')
    .padding(3)
    .margin(compact ? { left: 0, right: 0 } : { left: 16, right: 16 })
    .backgroundColor($r('app.color.surface_subtle'))
    .borderRadius(12)
  }

  build() {
    Column() {
      // ── 顶栏：圆形返回 + 大标题/副标题 + 右侧方向胶囊与分享 ──
      // v1.11：横屏把「周期分段」也并进这一行（并隐藏副标题），省下约 41vp 全给画布。
      Row({ space: this.isLandscape() ? 8 : 12 }) {
        Text($r('app.string.arrow_back'))
          .fontSize(24)
          .fontColor($r('app.color.text_primary'))
          .width(38)
          .height(38)
          .textAlign(TextAlign.Center)
          .borderRadius(19)
          .backgroundColor($r('app.color.surface_subtle'))
          .onClick(() => {
            router.back();
          })

        if (this.isLandscape()) {
          Text($r('app.string.title_chart'))
            .fontSize(18)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.text_primary'))
          this.rangeTabs(true)
        } else {
          Column({ space: 2 }) {
            Text($r('app.string.title_chart'))
              .fontSize(22)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.text_primary'))
            Text(this.rangeSubtitle())
              .fontSize(14)
              .fontColor($r('app.color.text_secondary'))
          }
          .alignItems(HorizontalAlign.Start)
        }

        Blank()

        // 方向胶囊（v1.10）：显示当前档位，点一下在「自动旋转 → 横屏 → 竖屏」之间轮换
        ZoomChip({
          label: this.orientLabel(),
          onTap: () => {
            this.cycleOrientation();
          }
        })

        Text($r('app.string.action_share'))
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.on_primary'))
          .padding({ left: 16, right: 16, top: 8, bottom: 8 })
          .backgroundColor($r('app.color.primary'))
          .borderRadius(17)
          .onClick(() => {
            this.shareChart();
          })
      }
      .width('100%')
      .padding(this.isLandscape()
        ? { left: 12, right: 12, top: 6, bottom: 6 }
        : { left: 16, right: 16, top: 12, bottom: 10 })

      if (!this.isLandscape()) {
        this.rangeTabs(false)
      }

      Scroll() {
        Column({ space: 12 }) {
          // ── 最新测量卡（v1.13，参考第三方血压 App 的界面）──
          // 半圆彩色弧 + 指针按分级色标指出这次落在哪一档，弧内是「分级 / 血压 / 心率」；
          // 下面接一行区间均值（口径与统计页、报告页一致）和一行「参考」目标值（FR-7.1 的设置）。
          // 横屏让位给画布，与 v1.10 的概览卡处理一致。
          if (!this.isLandscape()) {
            Column({ space: 6 }) {
              Row({ space: 6 }) {
                Text($r('app.string.chart_stat_latest'))
                  .fontSize(13)
                  .fontColor($r('app.color.text_tertiary'))
                Text(this.latestSub())
                  .fontSize(13)
                  .fontColor($r('app.color.text_secondary'))
              }
              .width('100%')
              .justifyContent(FlexAlign.Center)

              BpGauge({
                systolic: this.lastSys(),
                diastolic: this.lastDia(),
                heartRate: this.lastHr(),
                gaugeHeight: 166
              })

              Divider()
                .color($r('app.color.divider'))

              Row() {
                // 两格均值必须直接写在 build 里：@Builder 的「按值传参」只在首次创建时绑定参数，
                // 之后 this.stats 变化不会重跑 builder，数值会永远停在首帧（v1.18 的真机缺陷）。
                Column({ space: 3 }) {
                  Text($r('app.string.metric_avg_bp'))
                    .fontSize(14)
                    .fontColor($r('app.color.text_tertiary'))
                  Text(this.avgValue())
                    .fontSize(22)
                    .fontWeight(FontWeight.Medium)
                    .fontColor($r('app.color.text_primary'))
                  Text($r('app.string.unit_mmhg'))
                    .fontSize(13)
                    .fontColor($r('app.color.text_tertiary'))
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Center)

                Divider()
                  .vertical(true)
                  .height(30)
                  .color($r('app.color.divider'))

                Column({ space: 3 }) {
                  Text($r('app.string.metric_hr'))
                    .fontSize(14)
                    .fontColor($r('app.color.text_tertiary'))
                  Text(this.avgHr())
                    .fontSize(22)
                    .fontWeight(FontWeight.Medium)
                    .fontColor($r('app.color.text_primary'))
                  Text($r('app.string.unit_bpm'))
                    .fontSize(13)
                    .fontColor($r('app.color.text_tertiary'))
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Center)
              }
              .width('100%')
              .padding({ top: 4, bottom: 4 })

              Divider()
                .color($r('app.color.divider'))

              // 「参考」行：显示当前参考口径对应的目标值，避免用户以为图上的虚线写死了 140/90
              Row({ space: 14 }) {
                Text($r('app.string.chart_ref_target'))
                  .fontSize(13)
                  .fontColor($r('app.color.text_tertiary'))
                Row({ space: 4 }) {
                  Text($r('app.string.legend_systolic'))
                    .fontSize(13)
                    .fontColor($r('app.color.text_secondary'))
                  Text(`${this.refSys}`)
                    .fontSize(15)
                    .fontWeight(FontWeight.Medium)
                    .fontColor($r('app.color.text_primary'))
                  Text($r('app.string.unit_mmhg'))
                    .fontSize(12)
                    .fontColor($r('app.color.text_tertiary'))
                }
                Row({ space: 4 }) {
                  Text($r('app.string.legend_diastolic'))
                    .fontSize(13)
                    .fontColor($r('app.color.text_secondary'))
                  Text(`${this.refDia}`)
                    .fontSize(15)
                    .fontWeight(FontWeight.Medium)
                    .fontColor($r('app.color.text_primary'))
                  Text($r('app.string.unit_mmhg'))
                    .fontSize(12)
                    .fontColor($r('app.color.text_tertiary'))
                }
              }
              .width('100%')
              .justifyContent(FlexAlign.Center)
            }
            .width('100%')
            .padding({ top: 12, bottom: 12, left: 12, right: 12 })
            .backgroundColor($r('app.color.surface'))
            .borderRadius(16)
          }

          // 加载提示必须放在截屏容器**外面**：分享与保存到相册都是以 CAPTURE_ID 截屏，
          // 一旦把该容器换成条件分支，加载期间的截屏就会因找不到组件而失败。
          if (this.loading) {
            Row({ space: 8 }) {
              Progress({ value: 0, total: 100, type: ProgressType.Ring })
                .width(18)
                .height(18)
                .color($r('app.color.primary'))
              Text($r('app.string.list_loading'))
                .fontSize(13)
                .fontColor($r('app.color.text_secondary'))
            }
            .width('100%')
            .justifyContent(FlexAlign.Center)
          }

          // 被截图的容器：跟随主题配色（深色模式下不再是白板），保证「预览 == 分享产物」。
          // 报告页（就医/打印场景）仍用印刷白底，见 ChartScheme.PRINT。该容器必须**常驻**。
          Column({ space: 6 }) {
            Text($r('app.string.chart_card_title'))
              .fontSize(14)
              .fontColor($r('app.color.chart_text_secondary'))
              .width('100%')

            // 横向滚动容器：宽度撑满可视区，画布（内容）可以更宽
            Scroll(this.scroller) {
              Column() {
                BpLineChart({
                  points: this.points,
                  showHeartRate: true,
                  showLegend: false,
                  showWatermark: false,
                  watermarkText: '',
                  chartHeight: this.chartHeight(),
                  chartWidth: this.contentWidth(),
                  scheme: ChartScheme.THEME
                })
              }
              .width(this.contentWidth())
              // 双指捏合缩放：两指手势与 Scroll 的单指滑动互不干扰
              .gesture(
                PinchGesture({ fingers: 2, distance: 5 })
                  .onActionStart(() => {
                    this.manualZoom = true;
                    this.pinchBase = this.zoom;
                  })
                  .onActionUpdate((event: GestureEvent) => {
                    this.onPinchUpdate(event);
                  })
              )
            }
            .scrollable(ScrollDirection.Horizontal)
            .scrollBar(BarState.Auto)
            .width('100%')
            .height(this.chartHeight())
            .onAreaChange((oldValue: Area, newValue: Area) => {
              const w: number = this.areaLen(newValue.width);
              if (w > 0 && Math.abs(w - this.viewWidth) > 1) {
                this.viewWidth = w;
                // 可视宽度变了（旋屏 / 首次布局），没手动缩放过就重新贴合「全览」
                this.syncZoomToFit();
              }
            })

            this.legendRow()

            if (this.watermark.length > 0) {
              // v1.11：真机上这行在竖屏折成 3 行、压在图例上 —— 缩小字号、居中、最多两行
              Text(this.watermark)
                .fontSize(13)
                .fontColor($r('app.color.chart_watermark'))
                .width('100%')
                .textAlign(TextAlign.Center)
                .maxLines(2)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
            }
          }
          .id(CAPTURE_ID)
          .width('100%')
          .padding({ left: 10, right: 10, top: 8, bottom: 10 })
          .backgroundColor($r('app.color.chart_bg'))
          .borderRadius(16)

          // ── 缩放 / 提示 / 保存 / 免责声明：横屏时整块让位给画布（v1.10 专注模式） ──
          if (!this.isLandscape()) {
            this.auxControls()
          }
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 12 })
      }
      .layoutWeight(1)
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_bg'))
    // 记录可视宽高：旋屏后刷新，横屏布局与画布高度都据此计算
    .onAreaChange((oldValue: Area, newValue: Area) => {
      const w: number = this.areaLen(newValue.width);
      const h: number = this.areaLen(newValue.height);
      if (w > 0 && h > 0 && (Math.abs(w - this.pageWidth) > 1 || Math.abs(h - this.pageHeight) > 1)) {
        this.pageWidth = w;
        this.pageHeight = h;
      }
    })
  }
}
