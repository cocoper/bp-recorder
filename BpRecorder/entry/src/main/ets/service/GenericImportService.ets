import { BpRecordDraft, ValidationResult } from '../model/BpRecord';
import { MedDedupeTuple } from '../model/Med';
import { MedLogStatus, Period } from '../model/Types';
import { Csv } from '../common/Csv';
import { CsvVocab, ImportVocab, parsePeriodCsvName } from '../common/Vocab';
import { DateUtils } from '../common/DateUtils';
import { LooseParse, BpPairValue } from '../common/LooseParse';
import { ImportKind, ImportUnit, MedLimits } from '../common/Constants';
import { Logger } from '../common/Logger';
import { BpValidator } from './BpValidator';
import { ImportService, BpImportPreview, ImportIssue, MedImportDraft, MedImportPreview } from './ImportService';

const TAG: string = 'GenericImportService';

/** 内容画像采样行数上限：够判断列类型，又不至于在大文件上耗时 */
const SAMPLE_ROWS: number = 30;
/** 别名完全命中的基础分 */
const ALIAS_EXACT: number = 100;
/** 别名部分命中（包含关系）的基础分 */
const ALIAS_PARTIAL: number = 40;
/** 内容画像命中的系数：比例 × 该系数即得分 */
const CONTENT_WEIGHT: number = 60;
/** 低于该分不参与列角色分配 */
const MIN_SCORE: number = 30;

/** 列角色。取值顺序即「同分时的优先级」（小者优先），并与 ImportAliasRes.ORDER 严格一致。 */
export enum ColRole {
  NONE = 0,
  DATETIME = 1,
  DATE = 2,
  TIME = 3,
  SYSTOLIC = 4,
  DIASTOLIC = 5,
  BP_PAIR = 6,
  HEART_RATE = 7,
  PERIOD = 8,
  NOTE = 9,
  MED_NAME = 10,
  DOSAGE = 11,
  STATUS = 12,
  TAKEN_TIME = 13,
  SLOTS = 14,
  DAY_COUNT = 15,
  START_DATE = 16,
  END_DATE = 17
}

/** 除 NONE 之外的角色个数，等于 ImportAliasRes.ORDER.length */
export const ROLE_COUNT: number = 17;

/** 每列的识别结果（供 UI 展示「第几列 / 表头 / 样例 / 判定角色」） */
export interface ColumnProbe {
  index: number;
  /** 原表头文本（无表头时为空串） */
  header: string;
  /** 首个非空数据样例 */
  sample: string;
  role: ColRole;
  score: number;
}

/** 解析所需的列对应关系（用户在 UI 上可调整） */
export interface MappingPlan {
  hasHeader: boolean;
  /** 角色 → 列下标；长度 18（下标 = ColRole），-1 表示未指定 */
  roleIndex: number[];
  /** ImportUnit.MMHG | ImportUnit.KPA */
  unit: string;
  /** 单位换算系数（kPa → mmHg） */
  unitScale: number;
}

/**
 * 自动识别结果。
 *
 * **显式继承 MappingPlan**，而不是把字段再抄一遍 ——
 * ArkTS **不支持结构类型**（arkts-no-structural-typing），
 * 两个字段完全相同的独立接口之间不能互相赋值，只有真实的继承关系才成立。
 * （静态类型检查用的 tsc 走结构等价，会放过这类错误；只有真编译能抓到。）
 */
export interface Detection extends MappingPlan {
  /** ImportKind.BP | MED | PLAN | UNKNOWN */
  kind: string;
  /** 数据起始行下标（有表头为 1） */
  dataStart: number;
  columnCount: number;
  probes: ColumnProbe[];
  /** 按 kind 判定为「必需但未识别到」的角色 */
  missing: ColRole[];
}

/** 通用血压导入预览（在 BpImportPreview 之上补充来源信息，可直接交给 ImportService.commitBp） */
export interface GenericBpPreview extends BpImportPreview {
  /** 文件没有时间列：时间统一记为 00:00 */
  noTimeColumn: boolean;
  /** 数值单位为 kPa，已换算为 mmHg */
  convertedFromKpa: boolean;
  /** 原值带小数、已四舍五入的条数 */
  roundedCount: number;
}

/** 通用用药打卡导入预览（可直接交给 ImportService.commitMed） */
export interface GenericMedPreview extends MedImportPreview {
  noTimeColumn: boolean;
}

/** 单列的内容画像 */
interface ColumnProfile {
  dateOnly: number;
  dateTime: number;
  timeOnly: number;
  pair: number;
  num: number;
  sysLike: number;
  diaLike: number;
  hrLike: number;
  periodLike: number;
  statusLike: number;
  /** 值形如「07:30;18:00」的时间点列表（用药计划列） */
  slotLike: number;
  text: number;
  samples: string[];
}

/**
 * 外部来源导入（v1.4 新增）。
 *
 * 解决的问题：本 App 原有导入（ImportService）要求文件格式与**自家导出完全对称**
 * （FR-6.1 / 6.4 / 6.9）。而「其他 App / 血压计软件 / 手写 Excel」导出的文件
 * 列名、列序、日期写法、数值单位都不同，原导入会把这些行全部判为错误。
 *
 * 本服务做两件事：
 *   1. `detect` —— 按「表头别名 + 列内容画像」自动判断每列的含义，并给出置信度与缺失项；
 *   2. `parseBp` / `parseMed` —— 按识别结果（可被用户手工修正）产出与
 *      `ImportService` **完全相同**的预览结构，因此入库直接复用
 *      `ImportService.commitBp` / `commitMed`（单事务、判重、自动建药品档案全部复用，零重复实现）。
 *
 * 分工铁律：
 * - 数值范围、收缩压 > 舒张压等**医学口径一律交回 `BpValidator.validateCore`**，
 *   本服务不复制任何医学阈值；
 * - 本服务不触碰 resourceManager / getContext，文案经词表传入（保持纯函数、可离线单测）。
 */
export class GenericImportService {
  static readonly SAMPLE_ROWS: number = SAMPLE_ROWS;

  // ───────────────────────── 自动识别 ─────────────────────────

  /**
   * 识别每列的角色。
   * 两级信号：表头别名（有表头时）+ 列内容画像（对无表头文件是唯一依据）。
   */
  static detect(rows: string[][], vocab: ImportVocab, csvVocab: CsvVocab): Detection {
    const data: string[][] = Csv.normalize(rows);
    if (data.length === 0) {
      return GenericImportService.emptyDetection();
    }

    const columnCount: number = GenericImportService.maxColumnCount(data);
    const hasHeader: boolean = GenericImportService.looksLikeHeader(data[0], vocab);

    const rawHeaders: string[] = [];
    for (let j = 0; j < columnCount; j++) {
      rawHeaders.push(hasHeader ? Csv.cell(data[0], j) : '');
    }
    const headerKeys: string[] = [];
    for (let j = 0; j < columnCount; j++) {
      headerKeys.push(hasHeader ? LooseParse.normalizeKey(rawHeaders[j]) : '');
    }

    const dataStart: number = hasHeader ? 1 : 0;
    const roleIndex: number[] = GenericImportService.emptyRoleIndex();
    const scores: number[][] = [];
    for (let j = 0; j < columnCount; j++) {
      scores.push(new Array<number>(ROLE_COUNT + 1).fill(0));
    }

    for (let j = 0; j < columnCount; j++) {
      const profile: ColumnProfile = GenericImportService.profile(data, dataStart, j, csvVocab, vocab);
      for (let r = 1; r <= ROLE_COUNT; r++) {
        const role: ColRole = r as ColRole;
        scores[j][r] = GenericImportService.aliasScore(headerKeys[j], vocab.roleAliases[r], rawHeaders[j])
          + GenericImportService.contentScore(role, profile);
      }
    }

    GenericImportService.assign(columnCount, scores, roleIndex, headerKeys, vocab);
    GenericImportService.refineBpColumns(data, dataStart, columnCount, roleIndex, scores, headerKeys, vocab);

    const probes: ColumnProbe[] = [];
    for (let j = 0; j < columnCount; j++) {
      const role: ColRole = GenericImportService.roleOfColumn(roleIndex, j);
      probes.push({
        index: j,
        header: rawHeaders[j],
        sample: GenericImportService.firstSample(data, dataStart, j),
        role: role,
        score: role === ColRole.NONE ? 0 : scores[j][role]
      });
    }

    const kind: string = GenericImportService.decideKind(roleIndex);
    const unitInfo: string[] = GenericImportService.detectUnit(data, dataStart, roleIndex, rawHeaders);
    const unit: string = unitInfo[0];
    const unitScale: number = unit === ImportUnit.KPA ? LooseParse.KPA_TO_MMHG : 1;

    const detection: Detection = {
      kind: kind,
      hasHeader: hasHeader,
      dataStart: dataStart,
      columnCount: columnCount,
      probes: probes,
      roleIndex: roleIndex,
      missing: GenericImportService.missingRoles(kind, roleIndex),
      unit: unit,
      unitScale: unitScale
    };
    Logger.info(TAG, `detect: kind=${kind}, header=${hasHeader}, cols=${columnCount}, unit=${unit}, `
      + `roles=${JSON.stringify(roleIndex)}, missing=${JSON.stringify(detection.missing)}`);
    return detection;
  }

  /** 按 kinds（用户可能手动改了目标类型）重算缺失项 */
  static missingRolesFor(kind: string, roleIndex: number[]): ColRole[] {
    return GenericImportService.missingRoles(kind, roleIndex);
  }

  private static emptyRoleIndex(): number[] {
    const arr: number[] = [];
    for (let i = 0; i <= ROLE_COUNT; i++) {
      arr.push(-1);
    }
    return arr;
  }

  private static emptyDetection(): Detection {
    return {
      kind: ImportKind.UNKNOWN,
      hasHeader: false,
      dataStart: 0,
      columnCount: 0,
      probes: [],
      roleIndex: GenericImportService.emptyRoleIndex(),
      missing: [],
      unit: ImportUnit.MMHG,
      unitScale: 1
    };
  }

  private static maxColumnCount(data: string[][]): number {
    let max: number = 0;
    for (let i = 0; i < data.length; i++) {
      if (data[i].length > max) {
        max = data[i].length;
      }
    }
    return max;
  }

  /** 表头判定：首行至少两列能对上别名，才认为有表头（避免把数据首行误判为表头） */
  private static looksLikeHeader(row: string[], vocab: ImportVocab): boolean {
    let hits: number = 0;
    for (let j = 0; j < row.length; j++) {
      const key: string = LooseParse.normalizeKey(Csv.cell(row, j));
      if (key.length === 0) {
        continue;
      }
      for (let r = 1; r <= ROLE_COUNT; r++) {
        if (GenericImportService.aliasScore(key, vocab.roleAliases[r], Csv.cell(row, j)) > 0) {
          hits++;
          break;
        }
      }
    }
    return hits >= 2;
  }

  /** 表头别名得分：完全一致 > 包含关系（按别名长度加权，更具体的别名优先） */
  private static aliasScore(headerKey: string, aliases: string[], rawHeader: string): number {
    if (headerKey.length === 0) {
      return 0;
    }
    let best: number = 0;
    for (let i = 0; i < aliases.length; i++) {
      const alias: string = aliases[i];
      if (alias.length === 0) {
        continue;
      }
      let score: number = 0;
      if (headerKey === alias) {
        score = ALIAS_EXACT;
      } else if (headerKey.indexOf(alias) >= 0 || alias.indexOf(headerKey) >= 0) {
        score = ALIAS_PARTIAL + (alias.length < 10 ? alias.length : 10);
      }
      if (score > best) {
        best = score;
      }
    }
    // 数值单位写在表头里（如「收缩压(kPa)」）：归一化会去掉括号内容，故用原表头单独判一次
    if (best > 0 && rawHeader.length > 0 && LooseParse.toHalfWidth(rawHeader).toLowerCase().indexOf('kpa') >= 0) {
      best += 5;
    }
    return best;
  }

  /** 单列内容画像 */
  private static profile(data: string[][], dataStart: number, col: number,
    csvVocab: CsvVocab, impVocab: ImportVocab): ColumnProfile {
    const p: ColumnProfile = {
      dateOnly: 0, dateTime: 0, timeOnly: 0, pair: 0, num: 0, sysLike: 0, diaLike: 0,
      hrLike: 0, periodLike: 0, statusLike: 0, slotLike: 0, text: 0, samples: []
    };
    const end: number = Math.min(dataStart + SAMPLE_ROWS, data.length);
    let counted: number = 0;
    for (let i = dataStart; i < end; i++) {
      const raw: string = Csv.cell(data[i], col);
      if (raw.length === 0) {
        continue;
      }
      counted++;
      if (p.samples.length < 3) {
        p.samples.push(raw);
      }

      const asDate: number | null = LooseParse.parseDateLoose(raw);
      const hasTime: boolean = LooseParse.hasTimePart(raw);
      if (asDate !== null && hasTime) {
        p.dateTime++;
      } else if (asDate !== null) {
        p.dateOnly++;
      } else if (LooseParse.isTimeToken(raw) && LooseParse.minutesLoose(raw) >= 0) {
        p.timeOnly++;
      }

      if (GenericImportService.pairPlausible(raw)) {
        p.pair++;
      }
      if (parsePeriodCsvName(csvVocab, raw) !== null) {
        p.periodLike++;
      }
      if (GenericImportService.resolveStatus(raw, csvVocab, impVocab) !== null) {
        p.statusLike++;
      }
      if (GenericImportService.isSlotList(raw, csvVocab)) {
        p.slotLike++;
      }

      const asFloat: number | null = LooseParse.parseFloatLoose(raw);
      if (asFloat !== null) {
        p.num++;
        if (asFloat >= 90 && asFloat <= 260) {
          p.sysLike++;
        }
        if (asFloat >= 40 && asFloat <= 130) {
          p.diaLike++;
        }
        if (asFloat >= 30 && asFloat <= 220) {
          p.hrLike++;
        }
      } else if (asDate === null && !LooseParse.isTimeToken(raw)) {
        p.text++;
      }
    }
    if (counted === 0) {
      return p;
    }
    const n: number = counted;
    p.dateOnly = p.dateOnly / n;
    p.dateTime = p.dateTime / n;
    p.timeOnly = p.timeOnly / n;
    p.pair = p.pair / n;
    p.num = p.num / n;
    p.sysLike = p.sysLike / n;
    p.diaLike = p.diaLike / n;
    p.hrLike = p.hrLike / n;
    p.periodLike = p.periodLike / n;
    p.statusLike = p.statusLike / n;
    p.slotLike = p.slotLike / n;
    p.text = p.text / n;
    return p;
  }

  /**
   * 是否形如「用药计划的每日时间点」——按时间点分隔符切开后，每一段都是一个合法的时刻。
   *
   * 为什么需要它：表头写「时间点」时，列内容本身也全是时刻（`07:30;18:00`），
   * 只看内容会被判成普通「时间」列。加上这条信号后，「时间点」列才能稳定胜出，
   * 否则用药计划文件会被误判为血压/打卡文件。
   */
  private static isSlotList(raw: string, csvVocab: CsvVocab): boolean {
    const sep: string = csvVocab.slotSeparator.length > 0 ? csvVocab.slotSeparator : ';';
    const parts: string[] = raw.split(sep);
    let valid: number = 0;
    for (let i = 0; i < parts.length; i++) {
      const t: string = parts[i].trim();
      if (t.length === 0) {
        continue;
      }
      if (LooseParse.minutesLoose(t) < 0) {
        return false;
      }
      if (t.indexOf(':') < 0 && t.indexOf('时') < 0 && t.indexOf('点') < 0) {
        // 纯数字（如「2」）不算时刻，避免把「每日次数」列也当成时间点
        return false;
      }
      valid++;
    }
    return valid >= 1;
  }

  /** 「收缩压/舒张压」组合值的合理性判定：能拆成对（含 mmHg / kPa 两种量级）且行内收缩压更大 */
  private static pairPlausible(raw: string): boolean {
    const pair: BpPairValue | null = LooseParse.parseBpPair(raw);
    return pair !== null && pair.systolic > pair.diastolic;
  }

  /** 内容画像 → 角色得分 */
  private static contentScore(role: ColRole, p: ColumnProfile): number {
    switch (role) {
      case ColRole.DATETIME:
        return p.dateTime * CONTENT_WEIGHT;
      case ColRole.DATE:
        return p.dateOnly * CONTENT_WEIGHT;
      case ColRole.TIME:
        return p.timeOnly * CONTENT_WEIGHT;
      case ColRole.SYSTOLIC:
        return p.sysLike * (CONTENT_WEIGHT - 5);
      case ColRole.DIASTOLIC:
        return p.diaLike * (CONTENT_WEIGHT - 5);
      case ColRole.BP_PAIR:
        return p.pair * CONTENT_WEIGHT;
      case ColRole.HEART_RATE:
        return p.hrLike * (CONTENT_WEIGHT - 10);
      case ColRole.PERIOD:
        return p.periodLike * CONTENT_WEIGHT;
      case ColRole.NOTE:
        return p.text * 30;
      case ColRole.MED_NAME:
        return p.text * 40;
      case ColRole.DOSAGE:
        return p.text * 25;
      case ColRole.STATUS:
        return p.statusLike * CONTENT_WEIGHT;
      case ColRole.TAKEN_TIME:
        return p.dateTime * 35 + p.timeOnly * 35;
      case ColRole.SLOTS:
        return p.slotLike * 30;
      case ColRole.START_DATE:
      case ColRole.END_DATE:
        return p.dateOnly * 30;
      default:
        return 0;
    }
  }

  /** 贪心分配：按得分降序，同分时按角色优先级（枚举值小的优先） */
  private static assign(columnCount: number, scores: number[][], roleIndex: number[],
    headerKeys: string[], vocab: ImportVocab): void {
    const pairs: number[][] = [];
    for (let j = 0; j < columnCount; j++) {
      for (let r = 1; r <= ROLE_COUNT; r++) {
        if (scores[j][r] >= MIN_SCORE) {
          pairs.push([j, r, scores[j][r]]);
        }
      }
    }
    pairs.sort((a: number[], b: number[]): number => {
      if (b[2] !== a[2]) {
        return b[2] - a[2];
      }
      return a[1] - b[1];
    });

    const usedCol: boolean[] = new Array<boolean>(columnCount).fill(false);
    for (let i = 0; i < pairs.length; i++) {
      const col: number = pairs[i][0];
      const role: number = pairs[i][1];
      if (usedCol[col] || roleIndex[role] >= 0) {
        continue;
      }
      roleIndex[role] = col;
      usedCol[col] = true;
    }

    // 表头明确写了「日期」而内容是纯日期时，别让 DATETIME 抢走（反之亦然）
    GenericImportService.fixDateRoles(scores, roleIndex, headerKeys, vocab);
  }

  /** DATETIME / DATE 互斥修正：两者都指向同一列或错位时按得分重排 */
  private static fixDateRoles(scores: number[][], roleIndex: number[], headerKeys: string[], vocab: ImportVocab): void {
    const dt: number = roleIndex[ColRole.DATETIME];
    const d: number = roleIndex[ColRole.DATE];
    if (dt < 0 || d < 0 || dt !== d) {
      return;
    }
    if (scores[dt][ColRole.DATETIME] >= scores[dt][ColRole.DATE]) {
      roleIndex[ColRole.DATE] = -1;
    } else {
      roleIndex[ColRole.DATETIME] = -1;
    }
    // 被让出的角色再找一次最合适的列
    const freed: ColRole = roleIndex[ColRole.DATE] < 0 ? ColRole.DATE : ColRole.DATETIME;
    let bestCol: number = -1;
    let bestScore: number = MIN_SCORE;
    for (let j = 0; j < scores.length; j++) {
      if (GenericImportService.roleOfColumn(roleIndex, j) !== ColRole.NONE) {
        continue;
      }
      if (scores[j][freed] > bestScore) {
        bestScore = scores[j][freed];
        bestCol = j;
      }
    }
    if (bestCol >= 0) {
      roleIndex[freed] = bestCol;
    }
  }

  /**
   * 收缩压 / 舒张压 专门修正。
   *
   * 为什么必需：两列数值的范围高度重叠（心率 72 也落在舒张压的合理区间内），
   * 单看一列无法区分。这里用**行内大小关系**（收缩压必须大于舒张压）来定序与选列。
   */
  private static refineBpColumns(data: string[][], dataStart: number, columnCount: number,
    roleIndex: number[], scores: number[][], headerKeys: string[], vocab: ImportVocab): void {
    if (roleIndex[ColRole.BP_PAIR] >= 0) {
      // 组合列已能同时提供收缩压与舒张压
      roleIndex[ColRole.SYSTOLIC] = -1;
      roleIndex[ColRole.DIASTOLIC] = -1;
      return;
    }

    const candidates: number[] = [];
    for (let j = 0; j < columnCount; j++) {
      if (GenericImportService.roleOfColumn(roleIndex, j) !== ColRole.NONE) {
        // 已被其它角色占用：只有「弱占用」（得分低）才允许重新竞争
        if (GenericImportService.occupiedStrongly(roleIndex, scores, j)) {
          continue;
        }
      }
      if (headerKeys[j].length > 0 && GenericImportService.aliasScore(headerKeys[j], vocab.roleAliases[ColRole.HEART_RATE], '') > 0) {
        // 表头明写「心率」的列不参与血压两列的竞争
        continue;
      }
      if (GenericImportService.numericPlausibleRatio(data, dataStart, j) >= 0.6) {
        candidates.push(j);
      }
    }
    if (candidates.length < 2) {
      return;
    }

    let bestA: number = -1;
    let bestB: number = -1;
    let bestScore: number = -1;
    for (let i = 0; i < candidates.length; i++) {
      for (let k = 0; k < candidates.length; k++) {
        if (i === k) {
          continue;
        }
        const ratio: number = GenericImportService.greaterRatio(data, dataStart, candidates[i], candidates[k]);
        if (ratio > bestScore) {
          bestScore = ratio;
          bestA = candidates[i];
          bestB = candidates[k];
        }
      }
    }

    // 行内大小关系不成立（比例低于 0.8）时不强行指定，避免把数据摆错
    if (bestScore < 0.8) {
      return;
    }
    // 若已有识别结果与大小关系矛盾，则以大小关系为准
    const curSys: number = roleIndex[ColRole.SYSTOLIC];
    const curDia: number = roleIndex[ColRole.DIASTOLIC];
    if (curSys >= 0 && curDia >= 0) {
      const curRatio: number = GenericImportService.greaterRatio(data, dataStart, curSys, curDia);
      if (curRatio >= 0.8) {
        return;
      }
    }
    if (curSys >= 0 && curSys !== bestA) {
      roleIndex[ColRole.SYSTOLIC] = -1;
    }
    if (curDia >= 0 && curDia !== bestB) {
      roleIndex[ColRole.DIASTOLIC] = -1;
    }
    roleIndex[ColRole.SYSTOLIC] = bestA;
    roleIndex[ColRole.DIASTOLIC] = bestB;
  }

  private static occupiedStrongly(roleIndex: number[], scores: number[][], col: number): boolean {
    const role: ColRole = GenericImportService.roleOfColumn(roleIndex, col);
    if (role === ColRole.NONE) {
      return false;
    }
    if (role === ColRole.SYSTOLIC || role === ColRole.DIASTOLIC) {
      return false;
    }
    return scores[col][role] >= CONTENT_WEIGHT;
  }

  private static numericPlausibleRatio(data: string[][], dataStart: number, col: number): number {
    const end: number = Math.min(dataStart + SAMPLE_ROWS, data.length);
    let counted: number = 0;
    let hits: number = 0;
    for (let i = dataStart; i < end; i++) {
      const raw: string = Csv.cell(data[i], col);
      if (raw.length === 0) {
        continue;
      }
      counted++;
      const v: number | null = LooseParse.parseFloatLoose(raw);
      if (v !== null && v >= 20 && v <= 300) {
        hits++;
      }
    }
    return counted === 0 ? 0 : hits / counted;
  }

  /** 行内 a > b 的比例 */
  private static greaterRatio(data: string[][], dataStart: number, colA: number, colB: number): number {
    const end: number = Math.min(dataStart + SAMPLE_ROWS, data.length);
    let counted: number = 0;
    let greater: number = 0;
    for (let i = dataStart; i < end; i++) {
      const a: number | null = LooseParse.parseFloatLoose(Csv.cell(data[i], colA));
      const b: number | null = LooseParse.parseFloatLoose(Csv.cell(data[i], colB));
      if (a === null || b === null) {
        continue;
      }
      counted++;
      if (a > b) {
        greater++;
      }
    }
    return counted === 0 ? 0 : greater / counted;
  }

  private static roleOfColumn(roleIndex: number[], col: number): ColRole {
    for (let r = 1; r <= ROLE_COUNT; r++) {
      if (roleIndex[r] === col) {
        return r as ColRole;
      }
    }
    return ColRole.NONE;
  }

  private static firstSample(data: string[][], dataStart: number, col: number): string {
    const end: number = Math.min(dataStart + SAMPLE_ROWS, data.length);
    for (let i = dataStart; i < end; i++) {
      const raw: string = Csv.cell(data[i], col);
      if (raw.length > 0) {
        return raw;
      }
    }
    return '';
  }

  private static decideKind(roleIndex: number[]): string {
    const hasTime: boolean = roleIndex[ColRole.DATETIME] >= 0 || roleIndex[ColRole.DATE] >= 0;
    const hasBp: boolean = roleIndex[ColRole.BP_PAIR] >= 0
      || (roleIndex[ColRole.SYSTOLIC] >= 0 && roleIndex[ColRole.DIASTOLIC] >= 0);
    if (roleIndex[ColRole.SLOTS] >= 0 && roleIndex[ColRole.MED_NAME] >= 0) {
      return ImportKind.PLAN;
    }
    if (hasTime && hasBp) {
      return ImportKind.BP;
    }
    if (hasTime && roleIndex[ColRole.MED_NAME] >= 0 && roleIndex[ColRole.STATUS] >= 0) {
      return ImportKind.MED;
    }
    return ImportKind.UNKNOWN;
  }

  private static missingRoles(kind: string, roleIndex: number[]): ColRole[] {
    const missing: ColRole[] = [];
    const hasTime: boolean = roleIndex[ColRole.DATETIME] >= 0 || roleIndex[ColRole.DATE] >= 0;
    if (kind === ImportKind.BP) {
      if (!hasTime) {
        missing.push(ColRole.DATE);
      }
      if (roleIndex[ColRole.BP_PAIR] < 0) {
        if (roleIndex[ColRole.SYSTOLIC] < 0) {
          missing.push(ColRole.SYSTOLIC);
        }
        if (roleIndex[ColRole.DIASTOLIC] < 0) {
          missing.push(ColRole.DIASTOLIC);
        }
      }
    } else if (kind === ImportKind.MED) {
      if (!hasTime) {
        missing.push(ColRole.DATE);
      }
      if (roleIndex[ColRole.MED_NAME] < 0) {
        missing.push(ColRole.MED_NAME);
      }
      if (roleIndex[ColRole.STATUS] < 0) {
        missing.push(ColRole.STATUS);
      }
    } else if (kind === ImportKind.PLAN) {
      if (roleIndex[ColRole.MED_NAME] < 0) {
        missing.push(ColRole.MED_NAME);
      }
      if (roleIndex[ColRole.SLOTS] < 0) {
        missing.push(ColRole.SLOTS);
      }
    }
    return missing;
  }

  /** 数值单位判定：表头写明 kPa 优先；否则看数值量级（kPa 收缩压 ≈ 10–35 且带小数） */
  private static detectUnit(data: string[][], dataStart: number, roleIndex: number[], rawHeaders: string[]): string[] {
    const pairCol: number = roleIndex[ColRole.BP_PAIR];
    const sysCol: number = roleIndex[ColRole.SYSTOLIC];
    const probeCol: number = pairCol >= 0 ? pairCol : sysCol;
    if (probeCol < 0) {
      return [ImportUnit.MMHG, '1'];
    }
    if (probeCol < rawHeaders.length && rawHeaders[probeCol].length > 0
      && LooseParse.toHalfWidth(rawHeaders[probeCol]).toLowerCase().indexOf('kpa') >= 0) {
      return [ImportUnit.KPA, `${LooseParse.KPA_TO_MMHG}`];
    }

    const end: number = Math.min(dataStart + SAMPLE_ROWS, data.length);
    let counted: number = 0;
    let kpaLike: number = 0;
    for (let i = dataStart; i < end; i++) {
      const raw: string = Csv.cell(data[i], probeCol);
      if (raw.length === 0) {
        continue;
      }
      let value: number | null = null;
      let decimal: boolean = false;
      if (pairCol >= 0) {
        const pair: BpPairValue | null = LooseParse.parseBpPair(raw);
        if (pair !== null) {
          value = pair.systolic;
          decimal = pair.decimal;
        }
      } else {
        value = LooseParse.parseFloatLoose(raw);
        decimal = raw.indexOf('.') >= 0;
      }
      if (value === null) {
        continue;
      }
      counted++;
      if (decimal && value < 45) {
        kpaLike++;
      }
    }
    if (counted > 0 && kpaLike / counted >= 0.6) {
      return [ImportUnit.KPA, `${LooseParse.KPA_TO_MMHG}`];
    }
    return [ImportUnit.MMHG, '1'];
  }

  // ───────────────────────── 血压解析 ─────────────────────────

  /**
   * 按识别结果解析血压表。
   * 校验一律复用 `BpValidator.validateCore`；判重复用 `ImportService.bpKey`。
   */
  static parseBp(rows: string[][], csvVocab: CsvVocab, plan: MappingPlan,
    existingKeys: Set<string>): GenericBpPreview {
    const data: string[][] = Csv.normalize(rows);
    const drafts: BpRecordDraft[] = [];
    const errors: ImportIssue[] = [];
    const previewLines: string[] = [];
    const seen: Set<string> = new Set<string>();
    let duplicateCount: number = 0;
    let roundedCount: number = 0;
    let noTimeColumn: boolean = false;

    const start: number = plan.hasHeader ? 1 : 0;
    const totalRows: number = data.length > start ? data.length - start : 0;
    const kpa: boolean = plan.unit === ImportUnit.KPA;
    const scale: number = plan.unitScale > 0 ? plan.unitScale : 1;

    for (let i = start; i < data.length; i++) {
      const lineNo: number = i + 1;
      const row: string[] = data[i];

      const time: RowTime = GenericImportService.resolveTime(row, plan);
      if (!time.ok) {
        errors.push({
          lineNo: lineNo,
          reason: time.reason === null ? $r('app.string.err_imp_unknown') : time.reason,
          detail: time.detail
        });
        continue;
      }
      if (time.noTimeColumn) {
        noTimeColumn = true;
      }

      const pairCol: number = plan.roleIndex[ColRole.BP_PAIR];
      let sysText: string = '';
      let diaText: string = '';
      let hrText: string = '';

      if (pairCol >= 0) {
        const pair: BpPairValue | null = LooseParse.parseBpPair(Csv.cell(row, pairCol));
        if (pair === null) {
          errors.push({
            lineNo: lineNo,
            reason: $r('app.string.err_imp_bp_invalid'),
            detail: Csv.cell(row, pairCol)
          });
          continue;
        }
        const sys: string = GenericImportService.scaleValue(pair.systolic, kpa, scale);
        const dia: string = GenericImportService.scaleValue(pair.diastolic, kpa, scale);
        if (pair.decimal) {
          roundedCount++;
        }
        sysText = sys;
        diaText = dia;
        if (pair.heartRate !== null) {
          hrText = `${pair.heartRate}`;
        }
      } else {
        const sysCol: number = plan.roleIndex[ColRole.SYSTOLIC];
        const diaCol: number = plan.roleIndex[ColRole.DIASTOLIC];
        const sysRaw: string = sysCol >= 0 ? Csv.cell(row, sysCol) : '';
        const diaRaw: string = diaCol >= 0 ? Csv.cell(row, diaCol) : '';
        const converted: string[] = GenericImportService.scaleText(sysRaw, diaRaw, kpa, scale);
        if (converted.length === 0) {
          errors.push({
            lineNo: lineNo,
            reason: $r('app.string.err_imp_bp_invalid'),
            detail: `${sysRaw}/${diaRaw}`
          });
          continue;
        }
        sysText = converted[0];
        diaText = converted[1];
        if (kpa || sysRaw.indexOf('.') >= 0 || diaRaw.indexOf('.') >= 0) {
          roundedCount++;
        }
      }

      const hrCol: number = plan.roleIndex[ColRole.HEART_RATE];
      if (hrCol >= 0) {
        const hrRaw: string = Csv.cell(row, hrCol);
        if (hrRaw.length > 0) {
          // 审查 R13：非空但解析不出数值的心率必须报行错误 —— 过去静默变成空串（等同「未填写」），
          // 用户以为数据进来了，实际心率被悄悄丢掉。
          const hrValue: number | null = LooseParse.parseIntLoose(hrRaw);
          if (hrValue === null) {
            errors.push({
              lineNo: lineNo,
              reason: $r('app.string.err_hr_invalid'),
              detail: hrRaw
            });
            continue;
          }
          hrText = `${Math.round(hrValue)}`;
        }
      }

      // 医学口径唯一落点：与录入页同一套规则（范围、收缩压 > 舒张压）
      const core: ValidationResult = BpValidator.validateCore(sysText, diaText, hrText);
      if (!core.ok) {
        const reason: Resource = core.firstError === null ? $r('app.string.err_imp_unknown') : core.firstError;
        errors.push({ lineNo: lineNo, reason: reason, detail: `${sysText}/${diaText}` });
        continue;
      }

      const systolic: number = Number.parseInt(sysText, 10);
      const diastolic: number = Number.parseInt(diaText, 10);
      const heartRate: number | null = hrText.length === 0 ? null : Number.parseInt(hrText, 10);

      const periodCol: number = plan.roleIndex[ColRole.PERIOD];
      const periodFromFile: Period | null = periodCol < 0
        ? null : parsePeriodCsvName(csvVocab, Csv.cell(row, periodCol));
      const period: Period = periodFromFile === null ? DateUtils.periodOf(time.ts) : periodFromFile;

      const noteCol: number = plan.roleIndex[ColRole.NOTE];
      const noteRaw: string = noteCol < 0 ? '' : Csv.cell(row, noteCol);
      const note: string | null = noteRaw.length === 0 ? null : noteRaw;

      const key: string = ImportService.bpKey(time.ts, systolic, diastolic);
      if (existingKeys.has(key) || seen.has(key)) {
        duplicateCount++;
        seen.add(key);
        continue;
      }
      seen.add(key);
      drafts.push({
        systolic: systolic,
        diastolic: diastolic,
        heartRate: heartRate,
        measureTime: time.ts,
        period: period,
        note: note
      });
    }

    for (let i = 0; i < drafts.length && i < 5; i++) {
      previewLines.push(ImportService.bpPreviewLine(drafts[i], csvVocab));
    }
    Logger.info(TAG, `parse generic bp: total=${totalRows}, valid=${drafts.length}, dup=${duplicateCount}, `
      + `err=${errors.length}, kpa=${kpa}, rounded=${roundedCount}`);

    const preview: GenericBpPreview = {
      drafts: drafts,
      duplicateCount: duplicateCount,
      errors: errors,
      previewLines: previewLines,
      totalRows: totalRows,
      noTimeColumn: noTimeColumn,
      convertedFromKpa: kpa,
      roundedCount: roundedCount
    };
    return preview;
  }

  // ───────────────────────── 用药打卡解析 ─────────────────────────

  /** 按识别结果解析用药打卡表（入库复用 ImportService.commitMed） */
  static parseMed(rows: string[][], csvVocab: CsvVocab, impVocab: ImportVocab, plan: MappingPlan,
    existingKeys: Set<string>, nameToId: Map<string, number>): GenericMedPreview {
    const data: string[][] = Csv.normalize(rows);
    const drafts: MedImportDraft[] = [];
    const errors: ImportIssue[] = [];
    const previewLines: string[] = [];
    const seen: Set<string> = new Set<string>();
    let duplicateCount: number = 0;
    let noTimeColumn: boolean = false;

    const start: number = plan.hasHeader ? 1 : 0;
    const totalRows: number = data.length > start ? data.length - start : 0;

    for (let i = start; i < data.length; i++) {
      const lineNo: number = i + 1;
      const row: string[] = data[i];

      const time: RowTime = GenericImportService.resolveTime(row, plan);
      if (!time.ok) {
        errors.push({
          lineNo: lineNo,
          reason: time.reason === null ? $r('app.string.err_imp_unknown') : time.reason,
          detail: time.detail
        });
        continue;
      }
      if (time.noTimeColumn) {
        noTimeColumn = true;
      }

      const nameCol: number = plan.roleIndex[ColRole.MED_NAME];
      const medName: string = nameCol < 0 ? '' : Csv.cell(row, nameCol);
      if (medName.length === 0) {
        errors.push({ lineNo: lineNo, reason: $r('app.string.err_imp_med_name_required'), detail: '' });
        continue;
      }

      const statusCol: number = plan.roleIndex[ColRole.STATUS];
      const statusText: string = statusCol < 0 ? '' : Csv.cell(row, statusCol);
      const status: MedLogStatus | null = GenericImportService.resolveStatus(statusText, csvVocab, impVocab);
      if (status === null) {
        errors.push({ lineNo: lineNo, reason: $r('app.string.err_imp_status_unknown'), detail: statusText });
        continue;
      }

      const madeUp: boolean = GenericImportService.isMakeup(statusText, impVocab);
      let takenTime: number | null = null;
      const takenCol: number = plan.roleIndex[ColRole.TAKEN_TIME];
      const takenRaw: string = takenCol < 0 ? '' : Csv.cell(row, takenCol);
      if (takenRaw.length > 0) {
        const parsed: number | null = GenericImportService.resolveTimeCell(takenRaw, time.ts);
        if (parsed === null) {
          errors.push({ lineNo: lineNo, reason: $r('app.string.err_imp_taken_time_invalid'), detail: takenRaw });
          continue;
        }
        takenTime = ImportService.adjustTakenTime(time.ts, parsed);
      } else if (madeUp) {
        // 只有文件**明确标注**「补记」时才推断打卡时刻（取宽限期后 1ms），
        // 否则单纯的状态「已服」按本 App 口径记为「按时」（takenTime 为 null），
        // 不凭空claim「服晚了」。
        takenTime = time.ts + MedLimits.MISS_GRACE_MS + 1;
      }

      const dosageCol: number = plan.roleIndex[ColRole.DOSAGE];
      const dosage: string = dosageCol < 0 ? '' : Csv.cell(row, dosageCol);
      const noteCol: number = plan.roleIndex[ColRole.NOTE];
      const noteRaw: string = noteCol < 0 ? '' : Csv.cell(row, noteCol);

      const idKey: string | null = GenericImportService.nameKeyOf(medName, time.ts, nameToId);
      const nameKey: string = ImportService.medKeyByName(medName, time.ts);
      const isDup: boolean = existingKeys.has(nameKey) || seen.has(nameKey)
        || (idKey !== null && (existingKeys.has(idKey) || seen.has(idKey)));
      if (isDup) {
        duplicateCount++;
        seen.add(nameKey);
        continue;
      }
      seen.add(nameKey);
      drafts.push({
        medName: medName,
        dosage: dosage,
        scheduledTime: time.ts,
        status: status,
        takenTime: takenTime,
        note: noteRaw.length === 0 ? null : noteRaw
      });
    }

    for (let i = 0; i < drafts.length && i < 5; i++) {
      const d: MedImportDraft = drafts[i];
      previewLines.push(`${DateUtils.formatMonthDay(d.scheduledTime)} ${DateUtils.formatTime(d.scheduledTime)}  `
        + `${d.medName}  ${ImportService.statusName(d.status, csvVocab)}`);
    }
    Logger.info(TAG, `parse generic med: total=${totalRows}, valid=${drafts.length}, dup=${duplicateCount}, err=${errors.length}`);

    const preview: GenericMedPreview = {
      drafts: drafts,
      duplicateCount: duplicateCount,
      errors: errors,
      previewLines: previewLines,
      totalRows: totalRows,
      noTimeColumn: noTimeColumn
    };
    return preview;
  }

  /** 用药打卡判重键集合（与 ImportService.buildMedKeySet 同构，供页面在导入前构造） */
  static buildMedKeySet(tuples: MedDedupeTuple[]): Set<string> {
    return ImportService.buildMedKeySet(tuples);
  }

  private static nameKeyOf(medName: string, scheduledTime: number, nameToId: Map<string, number>): string | null {
    const id: number | undefined = nameToId.get(medName);
    return id === undefined ? null : ImportService.medKeyById(id, scheduledTime);
  }

  /**
   * 状态文字 → 状态枚举。
   * 先按本 App 的标准写法精确匹配，再按别名（包含关系）匹配外部写法。
   */
  static resolveStatus(text: string, csvVocab: CsvVocab, impVocab: ImportVocab): MedLogStatus | null {
    const exact: MedLogStatus | null = ImportService.mapStatusText(text, csvVocab);
    if (exact !== null) {
      return exact;
    }
    const key: string = LooseParse.normalizeKey(text);
    if (key.length === 0) {
      return null;
    }
    if (GenericImportService.matchesAny(key, impVocab.statusSkipped)) {
      return MedLogStatus.SKIPPED;
    }
    if (GenericImportService.matchesAny(key, impVocab.statusMissed)) {
      return MedLogStatus.MISSED;
    }
    if (GenericImportService.matchesAny(key, impVocab.statusTaken)) {
      return MedLogStatus.TAKEN;
    }
    if (GenericImportService.matchesAny(key, impVocab.statusPending)) {
      return MedLogStatus.PENDING;
    }
    return null;
  }

  /**
   * 是否标注为补记。
   *
   * 注意：此处**不能**用 LooseParse.normalizeKey —— 归一化会剥掉括号内容，
   * 而外部文件常把标记写在括号里（`已服用(补记)`），标记会被一起删掉。
   * 因此这里只在原文本上做全角转半角与小写，再按别名做包含匹配。
   */
  static isMakeup(text: string, impVocab: ImportVocab): boolean {
    const raw: string = LooseParse.toHalfWidth(text === null || text === undefined ? '' : text).toLowerCase();
    if (raw.length === 0) {
      return false;
    }
    for (let i = 0; i < impVocab.statusMakeup.length; i++) {
      const alias: string = impVocab.statusMakeup[i];
      if (alias.length > 0 && raw.indexOf(alias) >= 0) {
        return true;
      }
    }
    return false;
  }

  private static matchesAny(key: string, aliases: string[]): boolean {
    for (let i = 0; i < aliases.length; i++) {
      const alias: string = aliases[i];
      if (alias.length > 0 && key.indexOf(alias) >= 0) {
        return true;
      }
    }
    return false;
  }

  // ───────────────────────── 行时间解析 ─────────────────────────

  /** 由「日期/时间/日期时间」三列中的可用列解析出该行时间戳 */
  private static resolveTime(row: string[], plan: MappingPlan): RowTime {
    const dtCol: number = plan.roleIndex[ColRole.DATETIME];
    if (dtCol >= 0) {
      const raw: string = Csv.cell(row, dtCol);
      const ts: number | null = LooseParse.parseDateTimeLoose(raw);
      if (ts === null) {
        return { ok: false, ts: 0, reason: $r('app.string.err_imp_date_invalid'), detail: raw, noTimeColumn: false };
      }
      return { ok: true, ts: ts, reason: null, detail: '', noTimeColumn: false };
    }

    const dateCol: number = plan.roleIndex[ColRole.DATE];
    const timeCol: number = plan.roleIndex[ColRole.TIME];
    if (dateCol < 0) {
      return {
        ok: false, ts: 0, reason: $r('app.string.err_imp_date_invalid'),
        detail: timeCol < 0 ? '' : Csv.cell(row, timeCol), noTimeColumn: false
      };
    }
    const dateRaw: string = Csv.cell(row, dateCol);
    const day: number | null = LooseParse.parseDateLoose(dateRaw);
    if (day === null) {
      return { ok: false, ts: 0, reason: $r('app.string.err_imp_date_invalid'), detail: dateRaw, noTimeColumn: false };
    }
    if (timeCol < 0) {
      // 没有时间列：时间记为 00:00，并在预览页明确提示，不臆造时间
      return { ok: true, ts: day, reason: null, detail: '', noTimeColumn: true };
    }
    const timeRaw: string = Csv.cell(row, timeCol);
    if (timeRaw.length === 0) {
      return { ok: true, ts: day, reason: null, detail: '', noTimeColumn: false };
    }
    const minutes: number = LooseParse.minutesLoose(timeRaw);
    if (minutes < 0) {
      return { ok: false, ts: 0, reason: $r('app.string.err_imp_time_invalid'), detail: timeRaw, noTimeColumn: false };
    }
    return { ok: true, ts: day + minutes * DateUtils.MS_PER_MIN, reason: null, detail: '', noTimeColumn: false };
  }

  /** 打卡时间列：可能是完整日期时间，也可能只有时分（此时借该行日期补全） */
  private static resolveTimeCell(raw: string, scheduledTime: number): number | null {
    const full: number | null = LooseParse.parseDateTimeLoose(raw);
    if (full !== null) {
      return full;
    }
    const minutes: number = LooseParse.minutesLoose(raw);
    if (minutes < 0) {
      return null;
    }
    return DateUtils.startOfDay(scheduledTime) + minutes * DateUtils.MS_PER_MIN;
  }

  /** 单值换算：kPa → mmHg 并四舍五入；返回整数字符串（交给 BpValidator 统一校验） */
  private static scaleValue(value: number, kpa: boolean, scale: number): string {
    const v: number = kpa ? value * scale : value;
    return `${Math.round(v)}`;
  }

  /** 两个独立数值列的换算；任一无法解析为空数组 */
  private static scaleText(sysRaw: string, diaRaw: string, kpa: boolean, scale: number): string[] {
    if (kpa) {
      const a: number | null = LooseParse.parseFloatLoose(sysRaw);
      const b: number | null = LooseParse.parseFloatLoose(diaRaw);
      if (a === null || b === null) {
        return [];
      }
      return [GenericImportService.scaleValue(a, true, scale), GenericImportService.scaleValue(b, true, scale)];
    }
    const a: number | null = LooseParse.parseIntLoose(sysRaw);
    const b: number | null = LooseParse.parseIntLoose(diaRaw);
    if (a === null || b === null) {
      return [];
    }
    return [`${Math.round(a)}`, `${Math.round(b)}`];
  }

  /** 心率文本：解析失败返回空串（按「未填」处理，与录入页一致） */
  private static intText(raw: string): string {
    const v: number | null = LooseParse.parseIntLoose(raw);
    return v === null ? '' : `${Math.round(v)}`;
  }
}

/** 单行时间解析结果 */
interface RowTime {
  ok: boolean;
  ts: number;
  /** 失败原因；成功时为 null */
  reason: Resource | null;
  detail: string;
  /** 该行来自「无时间列」的日期列 */
  noTimeColumn: boolean;
}
