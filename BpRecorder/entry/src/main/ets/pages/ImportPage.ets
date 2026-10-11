import { common } from '@kit.AbilityKit';
import { router } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { ImportKind, ImportUnit, MedLimits } from '../common/Constants';
import { Csv } from '../common/Csv';
import { DateUtils } from '../common/DateUtils';
import { Logger } from '../common/Logger';
import { ResUtils } from '../common/ResUtils';
import { CsvVocab, ImportVocab, VocabFactory } from '../common/Vocab';
import { ColumnMapRow } from '../components/ColumnMapRow';
import { Medication, MedPlan } from '../model/Med';
import { BpDatabase } from '../service/BpDatabase';
import { FileService } from '../service/FileService';
import {
  ColRole,
  ColumnProbe,
  Detection,
  GenericBpPreview,
  GenericImportService,
  GenericMedPreview,
  MappingPlan
} from '../service/GenericImportService';
import { MedService } from '../service/MedService';
import { ReminderService } from '../service/ReminderService';
import {
  BpImportPreview,
  ImportIssue,
  ImportResult,
  ImportService,
  MedImportPreview,
  PlanImportPreview
} from '../service/ImportService';

const TAG: string = 'ImportPage';
const TYPE_BP: string = 'bp';
const TYPE_MED: string = 'med';
const TYPE_PLAN: string = 'plan';
/** 其他来源（外部 App / 血压计软件 / 手写表格导出） */
const TYPE_AUTO: string = 'auto';

/**
 * CSV 导入页（FR-6.5–6.8 / 策划文档 §5.11，v1.4 新增「其他来源」）。
 *
 * 两条导入路径：
 * 1. 自家格式（血压 / 用药打卡 / 用药计划）：格式与导出严格对称，解析走 ImportService；
 * 2. **其他来源**：列名、列序、日期写法、数值单位都可能不同，
 *    由 GenericImportService 自动识别列含义，识别不准时用户在页面上手工指定列对应关系。
 *
 * 两条路径共用同一套「预览 → 确认 → 单事务入库」流程与同一个结果页，
 * 入库分别复用 ImportService.commitBp / commitMed，不存在第二份事务实现。
 */
@Entry
@Component
struct ImportPage {
  @State private type: string = TYPE_BP;
  @State private fileName: string = '';
  @State private totalRows: number = 0;
  @State private validCount: number = 0;
  @State private dupCount: number = 0;
  @State private errors: ImportIssue[] = [];
  @State private previewLines: string[] = [];
  /** idle | preview | result */
  @State private phase: string = 'idle';
  @State private result: ImportResult | null = null;
  @State private busy: boolean = false;

  private bpPreview: BpImportPreview | null = null;
  private medPreview: MedImportPreview | null = null;
  private planPreview: PlanImportPreview | null = null;

  // ── 其他来源（TYPE_AUTO）状态 ──
  /** 解析出的原始二维数组，列对应关系变化时据此重新解析 */
  private rawRows: string[][] = [];
  /** 判重键在选文件时一次性取好，列对应调整时可同步重算 */
  private bpKeys: Set<string> = new Set<string>();
  private medKeys: Set<string> = new Set<string>();
  private nameToId: Map<string, number> = new Map<string, number>();
  /** 自动识别出的数据种类（用于提示，不直接决定入库目标） */
  @State private detectedKind: string = ImportKind.UNKNOWN;
  /** 用户选定的入库目标种类：bp | med */
  @State private targetKind: string = ImportKind.BP;
  @State private genUnit: string = ImportUnit.MMHG;
  @State private genScale: number = 1;
  @State private columnCount: number = 0;
  @State private headerRow: boolean = true;
  @State private mappingOpen: boolean = false;
  /** 角色 → 列下标（下标 = ColRole），-1 表示未指定 */
  @State private roleCols: number[] = [];
  /** 需要展示的映射行（角色值数组） */
  @State private roleRows: number[] = [];
  /** 下拉选项文本：下标 0 为「不使用该列」，其后为各列 */
  @State private optionLabels: string[] = [];
  @State private missingText: string = '';
  @State private allMatched: boolean = false;
  @State private noTimeColumn: boolean = false;
  @State private roundedCount: number = 0;
  @State private genBp: GenericBpPreview | null = null;
  @State private genMed: GenericMedPreview | null = null;

  /** 词表缓存：词表由资源解析而来，构造一次复用，避免每次重绘都解析上百条资源 */
  private csvVocabCache: CsvVocab | null = null;
  private impVocabCache: ImportVocab | null = null;

  private context(): common.UIAbilityContext {
    return ResUtils.hostContext(this.getUIContext());
  }

  private csvVocab(): CsvVocab {
    if (this.csvVocabCache === null) {
      this.csvVocabCache = VocabFactory.csv(this.context());
    }
    return this.csvVocabCache;
  }

  private impVocab(): ImportVocab {
    if (this.impVocabCache === null) {
      this.impVocabCache = VocabFactory.imp(this.context());
    }
    return this.impVocabCache;
  }

  private toast(res: Resource): void {
    this.getUIContext().getPromptAction().showToast({ message: res, duration: 2200 });
  }

  private reset(): void {
    this.phase = 'idle';
    this.fileName = '';
    this.totalRows = 0;
    this.validCount = 0;
    this.dupCount = 0;
    this.errors = [];
    this.previewLines = [];
    this.result = null;
    this.bpPreview = null;
    this.medPreview = null;
    this.planPreview = null;
    this.rawRows = [];
    this.bpKeys = new Set<string>();
    this.medKeys = new Set<string>();
    this.nameToId = new Map<string, number>();
    this.detectedKind = ImportKind.UNKNOWN;
    this.targetKind = ImportKind.BP;
    this.genUnit = ImportUnit.MMHG;
    this.genScale = 1;
    this.columnCount = 0;
    this.headerRow = true;
    this.mappingOpen = false;
    this.roleCols = [];
    this.roleRows = [];
    this.optionLabels = [];
    this.missingText = '';
    this.allMatched = false;
    this.noTimeColumn = false;
    this.roundedCount = 0;
    this.genBp = null;
    this.genMed = null;
  }

  private async pickAndParse(): Promise<void> {
    if (this.busy) {
      return;
    }
    this.busy = true;
    try {
      const context = this.context();
      const file = await FileService.pickCsv(context);
      if (file === null) {
        return;
      }
      this.fileName = file.name;

      const text: string = await FileService.readText(file.uri);
      const rows: string[][] = Csv.parse(text);
      const vocab: CsvVocab = VocabFactory.csv(context);
      const db: BpDatabase = BpDatabase.getInstance();

      if (this.type === TYPE_AUTO) {
        await this.detectGeneric(rows, vocab, db);
      } else if (this.type === TYPE_BP) {
        const keys = ImportService.buildBpKeySet(await db.queryBpDedupeTuples());
        const preview: BpImportPreview = ImportService.parseBpTable(rows, vocab, keys);
        this.bpPreview = preview;
        this.applyPreview(preview.totalRows, preview.drafts.length, preview.duplicateCount,
          preview.errors, preview.previewLines);
      } else if (this.type === TYPE_PLAN) {
        // 计划导入：判重键为「药品名 + 时间点集合」
        const meds: Medication[] = await db.queryMedications();
        const plans: MedPlan[] = await db.queryPlans();
        const keys: Set<string> = ImportService.buildPlanKeySet(meds, plans);
        const preview: PlanImportPreview = ImportService.parsePlanTable(rows, vocab, keys);
        this.planPreview = preview;
        this.applyPreview(preview.totalRows, preview.drafts.length, preview.duplicateCount,
          preview.errors, preview.previewLines);
      } else {
        const keys = ImportService.buildMedKeySet(await db.queryMedLogDedupeTuples());
        const nameToId: Map<string, number> = new Map<string, number>();
        const meds: Medication[] = await db.queryMedications();
        for (let i = 0; i < meds.length; i++) {
          nameToId.set(meds[i].name, meds[i].id);
        }
        const preview: MedImportPreview = ImportService.parseMedTable(rows, vocab, keys, nameToId);
        this.medPreview = preview;
        this.applyPreview(preview.totalRows, preview.drafts.length, preview.duplicateCount,
          preview.errors, preview.previewLines);
      }
      this.phase = 'preview';
    } catch (err) {
      const e = err as BusinessError;
      Logger.error(TAG, `pick and parse failed: code=${e.code}, message=${e.message}`);
      this.toast($r('app.string.error_import_parse'));
    } finally {
      this.busy = false;
    }
  }

  private applyPreview(total: number, valid: number, dup: number,
    issues: ImportIssue[], lines: string[]): void {
    this.totalRows = total;
    this.validCount = valid;
    this.dupCount = dup;
    this.errors = issues;
    this.previewLines = lines;
  }

  // ───────────────────── 其他来源：识别 → 预览 ─────────────────────

  /** 读入文件后做一次自动识别，并取好判重所需的数据 */
  private async detectGeneric(rows: string[][], vocab: CsvVocab, db: BpDatabase): Promise<void> {
    const context = this.context();
    const impVocab: ImportVocab = VocabFactory.imp(context);
    this.csvVocabCache = vocab;
    this.impVocabCache = impVocab;
    const detection: Detection = GenericImportService.detect(rows, impVocab, vocab);

    this.rawRows = rows;
    this.bpKeys = ImportService.buildBpKeySet(await db.queryBpDedupeTuples());
    this.medKeys = ImportService.buildMedKeySet(await db.queryMedLogDedupeTuples());
    const nameToId: Map<string, number> = new Map<string, number>();
    const meds: Medication[] = await db.queryMedications();
    for (let i = 0; i < meds.length; i++) {
      nameToId.set(meds[i].name, meds[i].id);
    }
    this.nameToId = nameToId;

    this.detectedKind = detection.kind;
    this.targetKind = detection.kind === ImportKind.MED ? ImportKind.MED : ImportKind.BP;
    this.genUnit = detection.unit;
    this.genScale = detection.unitScale;
    this.columnCount = detection.columnCount;
    this.headerRow = detection.hasHeader;
    this.optionLabels = this.buildOptionLabels(detection.probes);
    this.roleCols = detection.roleIndex.slice();
    // 识别失败时直接展开列对应，省得用户再点一次
    this.mappingOpen = detection.kind === ImportKind.UNKNOWN;
    this.recomputeGeneric();
  }

  /**
   * 按当前「目标种类 + 列对应 + 表头 + 单位」重新解析。
   * 判重键与药品映射已在选文件时取好，故此步为同步计算，调整映射后能即时看到结果。
   */
  private recomputeGeneric(): void {
    const plan: MappingPlan = {
      hasHeader: this.headerRow,
      roleIndex: this.roleCols.slice(),
      unit: this.genUnit,
      unitScale: this.genScale
    };
    this.roleRows = this.rolesOfTarget(this.targetKind);
    const missing: ColRole[] = GenericImportService.missingRolesFor(this.targetKind, plan.roleIndex);
    this.missingText = this.joinRoleNames(missing);
    this.allMatched = missing.length === 0;

    if (this.targetKind === ImportKind.MED) {
      const preview: GenericMedPreview = GenericImportService.parseMed(
        this.rawRows, this.csvVocab(), this.impVocab(), plan, this.medKeys, this.nameToId);
      this.genMed = preview;
      this.genBp = null;
      this.noTimeColumn = preview.noTimeColumn;
      this.roundedCount = 0;
      this.applyPreview(preview.totalRows, preview.drafts.length, preview.duplicateCount,
        preview.errors, preview.previewLines);
    } else {
      const preview: GenericBpPreview = GenericImportService.parseBp(
        this.rawRows, this.csvVocab(), plan, this.bpKeys);
      this.genBp = preview;
      this.genMed = null;
      this.noTimeColumn = preview.noTimeColumn;
      this.roundedCount = preview.roundedCount;
      this.applyPreview(preview.totalRows, preview.drafts.length, preview.duplicateCount,
        preview.errors, preview.previewLines);
    }
  }

  /** 目标种类对应的映射行（只列与本次导入相关的角色，避免界面冗长） */
  private rolesOfTarget(kind: string): number[] {
    if (kind === ImportKind.MED) {
      return [ColRole.DATE, ColRole.TIME, ColRole.DATETIME, ColRole.MED_NAME,
        ColRole.DOSAGE, ColRole.STATUS, ColRole.TAKEN_TIME, ColRole.NOTE];
    }
    return [ColRole.DATE, ColRole.TIME, ColRole.DATETIME, ColRole.SYSTOLIC,
      ColRole.DIASTOLIC, ColRole.BP_PAIR, ColRole.HEART_RATE, ColRole.PERIOD, ColRole.NOTE];
  }

  private buildOptionLabels(probes: ColumnProbe[]): string[] {
    const context = this.context();
    const labels: string[] = [];
    labels.push(ResUtils.text(context, $r('app.string.gen_mapping_none')));
    for (let j = 0; j < probes.length; j++) {
      const probe: ColumnProbe = probes[j];
      const head: string = probe.header.length > 0
        ? ResUtils.format(context, $r('app.string.gen_mapping_col'), [j + 1, probe.header])
        : ResUtils.format(context, $r('app.string.gen_mapping_col_empty'), [j + 1]);
      labels.push(probe.sample.length > 0
        ? `${head} · ${ResUtils.format(context, $r('app.string.gen_mapping_col_sample'), [probe.sample])}`
        : head);
    }
    return labels;
  }

  private joinRoleNames(roles: ColRole[]): string {
    const context = this.context();
    const vocab: ImportVocab = this.impVocab();
    const sep: string = ResUtils.text(context, $r('app.string.list_separator'));
    let out: string = '';
    for (let i = 0; i < roles.length; i++) {
      if (i > 0) {
        out += sep;
      }
      out += vocab.roleNames.length > roles[i] ? vocab.roleNames[roles[i]] : '';
    }
    return out;
  }

  /** 角色当前选中的下拉下标（0 = 不使用该列） */
  private optionIndexOf(role: number): number {
    const col: number = this.roleCols.length > role ? this.roleCols[role] : -1;
    return col < 0 ? 0 : col + 1;
  }

  private optionTextOf(index: number): string {
    return this.optionLabels.length > index ? this.optionLabels[index] : '';
  }

  private options(): SelectOption[] {
    const out: SelectOption[] = [];
    for (let i = 0; i < this.optionLabels.length; i++) {
      out.push({ value: this.optionLabels[i] });
    }
    return out;
  }

  /** 用户改动了某数据项对应的列 */
  private applyPick(role: number, optionIndex: number): void {
    const next: number[] = this.roleCols.slice();
    while (next.length <= role) {
      next.push(-1);
    }
    next[role] = optionIndex <= 0 ? -1 : optionIndex - 1;
    // 一列只能承担一个角色：把此前占用该列的其它角色清空
    if (next[role] >= 0) {
      for (let r = 1; r < next.length; r++) {
        if (r !== role && next[r] === next[role]) {
          next[r] = -1;
        }
      }
    }
    this.roleCols = next;
    this.recomputeGeneric();
  }

  private onTargetKind(kind: string): void {
    if (this.targetKind === kind) {
      return;
    }
    this.targetKind = kind;
    this.recomputeGeneric();
  }

  private onHeaderSwitch(on: boolean): void {
    if (this.headerRow === on) {
      return;
    }
    this.headerRow = on;
    this.recomputeGeneric();
  }

  /** 识别结果摘要文案 */
  private detectedText(): string {
    const context = this.context();
    if (this.detectedKind === ImportKind.BP) {
      return ResUtils.format(context, $r('app.string.gen_detected'),
        [ResUtils.text(context, $r('app.string.import_type_bp'))]);
    }
    if (this.detectedKind === ImportKind.MED) {
      return ResUtils.format(context, $r('app.string.gen_detected'),
        [ResUtils.text(context, $r('app.string.import_type_med'))]);
    }
    if (this.detectedKind === ImportKind.PLAN) {
      return ResUtils.format(context, $r('app.string.gen_detected'),
        [ResUtils.text(context, $r('app.string.import_type_plan'))]);
    }
    return ResUtils.text(context, $r('app.string.gen_detected_unknown'));
  }

  private unitText(): string {
    return this.genUnit === ImportUnit.KPA
      ? ResUtils.text(this.context(), $r('app.string.gen_unit_kpa'))
      : ResUtils.text(this.context(), $r('app.string.gen_unit_mmhg'));
  }

  // ───────────────────── 入库 ─────────────────────

  private async confirmImport(): Promise<void> {
    if (this.busy) {
      return;
    }
    this.busy = true;
    try {
      const db: BpDatabase = BpDatabase.getInstance();
      let result: ImportResult | null = null;
      if (this.type === TYPE_BP && this.bpPreview !== null) {
        result = await ImportService.commitBp(db, this.bpPreview);
      } else if (this.type === TYPE_MED && this.medPreview !== null) {
        result = await ImportService.commitMed(db, this.medPreview);
      } else if (this.type === TYPE_PLAN && this.planPreview !== null) {
        result = await ImportService.commitPlan(db, this.planPreview);
        // 计划导入后立即滚动预生成打卡记录并重建提醒，否则新计划不会产生应服记录
        const now: number = DateUtils.now();
        const plans: MedPlan[] = await db.queryActivePlans();
        const meds: Medication[] = await db.queryMedications();
        await db.insertMissingLogs(MedService.pendingDrafts(plans, meds, now, MedLimits.PRE_GEN_DAYS));
        await ReminderService.rebuildAll(this.context(), plans, meds,
          VocabFactory.reminder(this.context()), now, true);
      } else if (this.type === TYPE_AUTO) {
        if (this.targetKind === ImportKind.MED && this.genMed !== null) {
          result = await ImportService.commitMed(db, this.genMed);
        } else if (this.genBp !== null) {
          result = await ImportService.commitBp(db, this.genBp);
        }
      }
      this.result = result;
      this.phase = 'result';
    } catch (err) {
      // 事务已回滚，不产生半批数据（FR-6.8）
      const e = err as BusinessError;
      Logger.error(TAG, `commit import failed: code=${e.code}, message=${e.message}`);
      this.toast($r('app.string.error_import_commit'));
    } finally {
      this.busy = false;
    }
  }

  build() {
    Column() {
      Row() {
        Text($r('app.string.action_back'))
          .fontSize(15)
          .fontColor($r('app.color.primary'))
          .onClick(() => {
            router.back();
          })
        Blank()
        Text($r('app.string.title_import'))
          .fontSize(17)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
        Blank()
        Text(' ')
          .fontSize(15)
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 12, bottom: 12 })

      Scroll() {
        Column({ space: 12 }) {
          // 数据类型切换（四类，窄屏放不下时横向滚动）
          Scroll() {
            Row({ space: 8 }) {
              this.typeChip($r('app.string.import_type_bp'), TYPE_BP)
              this.typeChip($r('app.string.import_type_med'), TYPE_MED)
              this.typeChip($r('app.string.import_type_plan'), TYPE_PLAN)
              this.typeChip($r('app.string.import_type_auto'), TYPE_AUTO)
            }
          }
          .scrollable(ScrollDirection.Horizontal)
          .scrollBar(BarState.Off)
          .width('100%')
          .align(Alignment.Start)

          Button($r('app.string.import_pick_file'))
            .width('100%')
            .height(44)
            .fontSize(15)
            .backgroundColor($r('app.color.primary'))
            .fontColor($r('app.color.on_primary'))
            .onClick(() => {
              this.pickAndParse();
            })

          if (this.fileName.length > 0) {
            Text($r('app.string.import_selected', this.fileName))
              .fontSize(13)
              .fontColor($r('app.color.text_secondary'))
              .width('100%')
          }

          if (this.type === TYPE_AUTO && this.phase !== 'idle') {
            this.autoSection()
          }

          if (this.phase === 'preview') {
            Column({ space: 6 }) {
              Text($r('app.string.import_result_title'))
                .fontSize(14)
                .fontWeight(FontWeight.Medium)
                .fontColor($r('app.color.text_primary'))
                .width('100%')
              Text($r('app.string.import_total_rows', this.totalRows))
                .fontSize(13)
                .fontColor($r('app.color.text_secondary'))
                .width('100%')
              Text($r('app.string.import_valid', this.validCount))
                .fontSize(13)
                .fontColor($r('app.color.med_taken'))
                .width('100%')
              Text($r('app.string.import_dup', this.dupCount))
                .fontSize(13)
                .fontColor($r('app.color.warn_text'))
                .width('100%')
              Text($r('app.string.import_error', this.errors.length))
                .fontSize(13)
                .fontColor($r('app.color.danger'))
                .width('100%')
              if (this.type === TYPE_AUTO && this.noTimeColumn) {
                Text($r('app.string.gen_no_time_hint'))
                  .fontSize(11)
                  .lineHeight(17)
                  .fontColor($r('app.color.warn_text'))
                  .width('100%')
              }
              if (this.type === TYPE_AUTO && this.roundedCount > 0) {
                Text($r('app.string.gen_rounded_hint', this.roundedCount))
                  .fontSize(11)
                  .lineHeight(17)
                  .fontColor($r('app.color.text_tertiary'))
                  .width('100%')
              }
            }
            .width('100%')
            .padding(14)
            .backgroundColor($r('app.color.surface'))
            .borderRadius(12)
            .alignItems(HorizontalAlign.Start)

            if (this.previewLines.length > 0) {
              Column({ space: 4 }) {
                Text($r('app.string.import_preview_title'))
                  .fontSize(13)
                  .fontColor($r('app.color.text_secondary'))
                  .width('100%')
                ForEach(this.previewLines, (line: string) => {
                  Text(line)
                    .fontSize(12)
                    .fontColor($r('app.color.text_primary'))
                    .width('100%')
                }, (line: string, index: number) => `${index}_${line}`)
              }
              .width('100%')
              .padding(12)
              .backgroundColor($r('app.color.surface'))
              .borderRadius(12)
              .alignItems(HorizontalAlign.Start)
            }

            if (this.errors.length > 0) {
              Column({ space: 4 }) {
                Text($r('app.string.import_error_list'))
                  .fontSize(13)
                  .fontColor($r('app.color.danger'))
                  .width('100%')
                ForEach(this.errors, (issue: ImportIssue) => {
                  Row({ space: 8 }) {
                    Text($r('app.string.import_line_no', issue.lineNo))
                      .fontSize(12)
                      .fontColor($r('app.color.text_secondary'))
                    Text(issue.reason)
                      .fontSize(12)
                      .fontColor($r('app.color.danger'))
                      .layoutWeight(1)
                    if (issue.detail.length > 0) {
                      Text($r('app.string.import_line_detail', issue.detail))
                        .fontSize(11)
                        .fontColor($r('app.color.text_tertiary'))
                    }
                  }
                  .width('100%')
                }, (issue: ImportIssue) => `${issue.lineNo}_${issue.detail}`)
              }
              .width('100%')
              .padding(12)
              .backgroundColor($r('app.color.danger_bg'))
              .borderRadius(12)
              .alignItems(HorizontalAlign.Start)
            }

            if (this.type === TYPE_AUTO) {
              Text($r('app.string.gen_check_hint'))
                .fontSize(11)
                .lineHeight(17)
                .fontColor($r('app.color.text_tertiary'))
                .width('100%')
            }

            Row({ space: 10 }) {
              Button($r('app.string.action_cancel'))
                .layoutWeight(1)
                .height(44)
                .fontSize(15)
                .backgroundColor($r('app.color.surface'))
                .fontColor($r('app.color.text_primary'))
                .onClick(() => {
                  this.reset();
                })
              Button($r('app.string.import_confirm'))
                .layoutWeight(1)
                .height(44)
                .fontSize(15)
                .enabled(this.canConfirm())
                .backgroundColor(this.canConfirm() ? $r('app.color.primary') : $r('app.color.btn_disabled'))
                .fontColor($r('app.color.on_primary'))
                .onClick(() => {
                  this.confirmImport();
                })
            }
            .width('100%')
          }

          if (this.phase === 'result' && this.result !== null) {
            this.resultCard(this.result)
          }

          Text(this.type === TYPE_AUTO ? $r('app.string.gen_hint') : $r('app.string.import_hint'))
            .fontSize(11)
            .lineHeight(17)
            .fontColor($r('app.color.text_tertiary'))
            .width('100%')
            .padding({ bottom: 24 })
        }
        .width('100%')
        .padding({ left: 12, right: 12 })
      }
      .layoutWeight(1)
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_bg'))
  }

  /** 确认按钮是否可用：其他来源多一道「必需列都已识别」与「非用药计划」的门槛 */
  private canConfirm(): boolean {
    if (this.validCount <= 0) {
      return false;
    }
    if (this.type !== TYPE_AUTO) {
      return true;
    }
    if (this.detectedKind === ImportKind.PLAN) {
      return false;
    }
    return this.allMatched;
  }

  /** 其他来源：识别摘要 + 表头开关 + 目标种类 + 列对应调整 */
  @Builder
  autoSection() {
    Column({ space: 8 }) {
      Text(this.detectedText())
        .fontSize(13)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
        .width('100%')

      if (this.detectedKind === ImportKind.PLAN) {
        Text($r('app.string.gen_plan_hint'))
          .fontSize(12)
          .lineHeight(18)
          .fontColor($r('app.color.warn_text'))
          .width('100%')
      } else {
        Text(this.allMatched
          ? $r('app.string.gen_role_summary_ok')
          : $r('app.string.gen_role_summary', this.columnCount, this.missingText))
          .fontSize(12)
          .lineHeight(18)
          .fontColor(this.allMatched ? $r('app.color.med_taken') : $r('app.color.warn_text'))
          .width('100%')
      }

      Text(this.unitText())
        .fontSize(12)
        .fontColor($r('app.color.text_secondary'))
        .width('100%')

      Row() {
        Text($r('app.string.gen_header_switch'))
          .fontSize(13)
          .fontColor($r('app.color.text_primary'))
          .layoutWeight(1)
        Toggle({ type: ToggleType.Switch, isOn: this.headerRow })
          .onChange((isOn: boolean) => {
            this.onHeaderSwitch(isOn);
          })
      }
      .width('100%')
      .height(40)

      Row({ space: 8 }) {
        Text($r('app.string.gen_target_kind'))
          .fontSize(13)
          .fontColor($r('app.color.text_secondary'))
        this.kindChip($r('app.string.import_type_bp'), ImportKind.BP)
        this.kindChip($r('app.string.import_type_med'), ImportKind.MED)
      }
      .width('100%')

      Row() {
        Text(this.mappingOpen ? $r('app.string.gen_mapping_hide') : $r('app.string.gen_mapping_show'))
          .fontSize(13)
          .fontColor($r('app.color.primary'))
          .onClick(() => {
            this.mappingOpen = !this.mappingOpen;
          })
      }
      .width('100%')
      .height(36)

      if (this.mappingOpen) {
        Text($r('app.string.gen_mapping_title', this.columnCount))
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
          .width('100%')
        ForEach(this.roleRows, (role: number) => {
          ColumnMapRow({
            label: this.roleName(role),
            options: this.options(),
            selectedIndex: this.optionIndexOf(role),
            selectedText: this.optionTextOf(this.optionIndexOf(role)),
            onPick: (index: number) => {
              this.applyPick(role, index);
            }
          })
        }, (role: number) => `${role}_${this.optionIndexOf(role)}`)
        Text($r('app.string.gen_fix_hint'))
          .fontSize(11)
          .lineHeight(17)
          .fontColor($r('app.color.text_tertiary'))
          .width('100%')
      }
    }
    .width('100%')
    .padding(14)
    .backgroundColor($r('app.color.surface'))
    .borderRadius(12)
    .alignItems(HorizontalAlign.Start)
  }

  private roleName(role: number): string {
    const vocab: ImportVocab = this.impVocab();
    return vocab.roleNames.length > role ? vocab.roleNames[role] : '';
  }

  @Builder
  typeChip(label: Resource, type: string) {
    Text(label)
      .fontSize(13)
      .fontColor(this.type === type ? $r('app.color.on_primary') : $r('app.color.text_primary'))
      .padding({ left: 16, right: 16, top: 6, bottom: 6 })
      .backgroundColor(this.type === type ? $r('app.color.primary') : $r('app.color.surface'))
      .borderRadius(16)
      .onClick(() => {
        if (this.type !== type) {
          this.type = type;
          this.reset();
        }
      })
  }

  @Builder
  kindChip(label: Resource, kind: string) {
    Text(label)
      .fontSize(12)
      .fontColor(this.targetKind === kind ? $r('app.color.on_primary') : $r('app.color.text_primary'))
      .padding({ left: 12, right: 12, top: 4, bottom: 4 })
      .backgroundColor(this.targetKind === kind ? $r('app.color.primary') : $r('app.color.page_bg'))
      .borderRadius(12)
      .onClick(() => {
        this.onTargetKind(kind);
      })
  }

  @Builder
  resultCard(result: ImportResult) {
    Column({ space: 6 }) {
      Text($r('app.string.import_done_title'))
        .fontSize(14)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
        .width('100%')
      Text($r('app.string.import_done_line', result.inserted, result.skippedDuplicate, result.failed))
        .fontSize(13)
        .fontColor($r('app.color.text_primary'))
        .width('100%')
      if (result.createdMedications.length > 0) {
        Text($r('app.string.import_created_meds', result.createdMedications.join(' / ')))
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
          .width('100%')
        Text($r('app.string.import_created_meds_hint'))
          .fontSize(11)
          .fontColor($r('app.color.text_tertiary'))
          .width('100%')
      }
    }
    .width('100%')
    .padding(14)
    .backgroundColor($r('app.color.surface'))
    .borderRadius(12)
    .alignItems(HorizontalAlign.Start)
  }
}
