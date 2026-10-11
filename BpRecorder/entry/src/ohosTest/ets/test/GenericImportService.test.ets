import { describe, expect, it } from '@ohos/hypium';
import { LooseParse, BpPairValue } from '../../../main/ets/common/LooseParse';
import { Csv } from '../../../main/ets/common/Csv';
import { CsvVocab, ImportVocab } from '../../../main/ets/common/Vocab';
import { ImportKind, ImportUnit } from '../../../main/ets/common/Constants';
import { ColRole, GenericImportService, Detection, MappingPlan, ROLE_COUNT }
  from '../../../main/ets/service/GenericImportService';
import { ImportService } from '../../../main/ets/service/ImportService';
import { MedLogStatus, Period } from '../../../main/ets/model/Types';

/**
 * 外部来源导入单测（FR-6.11）。
 *
 * 覆盖：宽容解析（日期/时间/数值/血压组合值）、列角色自动识别（有表头 / 无表头 / 列序打乱）、
 * 脏行逐行隔离、以及「导入校验 == 录入校验」的口径一致性。
 *
 * 与 `tools/parity/harness.ts` 的关系：两者断言同一批规则 —— harness 在本机离线跑（无需设备），
 * 本文件在真机上跑（覆盖 device 侧的 ArkTS 运行时差异）。任何一边发现规则不符，
 * 都应先确认口径本身，再同步另一侧。
 */
export default function genericImportServiceTest() {
  const ts = (y: number, m: number, d: number, hh: number, mm: number): number =>
    new Date(y, m - 1, d, hh, mm, 0, 0).getTime();

  // 与 resources/base/element/string.json 中的字面量保持一致
  const vocab: CsvVocab = {
    bpHeaders: ['日期', '时间', '收缩压(mmHg)', '舒张压(mmHg)', '心率(bpm)', '时段', '备注'],
    medHeaders: ['日期', '计划时间', '药品', '剂量', '状态', '实际打卡时间', '备注'],
    planHeaders: ['药品', '剂量', '每日次数', '时间点', '开始日期', '结束日期', '备注'],
    slotSeparator: ';',
    periodMorning: '晨起', periodForenoon: '上午', periodAfternoon: '下午',
    periodNight: '睡前', periodOther: '其他',
    statusTaken: '已服用', statusTakenMakeup: '已服用(补记)',
    statusSkipped: '跳过', statusMissed: '漏服', statusPending: '待服'
  };

  const impVocab: ImportVocab = {
    roleNames: ['', '日期时间', '日期', '时间', '收缩压', '舒张压', '血压', '心率', '时段', '备注',
      '药品', '剂量', '状态', '实际打卡时间', '时间点', '每日次数', '开始日期', '结束日期'],
    roleAliases: [
      [],
      ['日期时间', '时间戳', 'datetime', 'timestamp', 'measuretime', 'recordtime'],
      ['日期', '测量日期', '年月日', 'date', 'day'],
      ['时间', '时刻', '测量时刻', 'time', 'clock'],
      ['收缩压', '高压', '收缩', '上压', '最高压', '最高血压', 'sys', 'sbp'],
      ['舒张压', '低压', '舒张', '下压', '最低压', '最低血压', 'dia', 'dbp'],
      ['血压', '血压值', '血压读数', '测量值', '读数', 'bp', 'bloodpressure'],
      ['心率', '脉率', '脉搏', '心率值', 'hr', 'bpm', 'heartrate', 'pulse'],
      ['时段', '时间段', '测量时段', 'period'],
      ['备注', '说明', '注释', '备注说明', 'note', 'remark', 'comment'],
      ['药品', '药品名', '药品名称', '药物', '药名', 'medication', 'medicine', 'drug'],
      ['剂量', '用量', '每次剂量', '单次剂量', 'dosage', 'dose'],
      ['状态', '打卡状态', '服药状态', 'status'],
      ['实际打卡时间', '打卡时间', '实际时间', '服药时间', 'takentime', 'actualtime', 'taken'],
      ['时间点', '服药时间点', '时点', 'slots', 'times', 'schedule'],
      ['每日次数', '每天次数', '每日频次', '次数', '频次', 'timesperday'],
      ['开始日期', '起始日期', '开始时间', 'startdate', 'start'],
      ['结束日期', '截止日期', '终止日期', 'enddate', 'end']
    ],
    statusTaken: ['已服用', '已服', '已吃', '已用', '吃过', '服用了', '已完成', 'taken', 'done'],
    statusSkipped: ['跳过', '已跳过', '略过', 'skip', 'skipped'],
    statusMissed: ['漏服', '未服用', '未服', '漏吃', 'missed', 'miss'],
    statusPending: ['待服', '未到', '待服用', 'pending', 'due'],
    statusMakeup: ['补记', '补录', '补打卡', '补登']
  };

  describe('GenericImportServiceTest', () => {
    it('role_count_matches_alias_table', 0, () => {
      expect(ROLE_COUNT).assertEqual(17);
      expect(impVocab.roleNames.length).assertEqual(ROLE_COUNT + 1);
      expect(impVocab.roleAliases.length).assertEqual(ROLE_COUNT + 1);
      expect(ColRole.NONE).assertEqual(0);
    });

    it('loose_parse_date_writings', 0, () => {
      const d: number = ts(2026, 10, 6, 0, 0);
      expect(LooseParse.parseDateLoose('2026-10-06')).assertEqual(d);
      expect(LooseParse.parseDateLoose('2026/10/6')).assertEqual(d);
      expect(LooseParse.parseDateLoose('2026.10.6')).assertEqual(d);
      expect(LooseParse.parseDateLoose('2026年10月6日')).assertEqual(d);
      expect(LooseParse.parseDateLoose('20261006')).assertEqual(d);
      expect(LooseParse.parseDateLoose('10/6/2026')).assertEqual(d);
      // 不猜：缺年份 / 2 位年份 / 不存在的日期一律判为非法
      expect(LooseParse.parseDateLoose('10/06')).assertNull();
      expect(LooseParse.parseDateLoose('26/10/06')).assertNull();
      expect(LooseParse.parseDateLoose('2026-02-30')).assertNull();
      // Excel 序列号锚点：45292 == 2024-01-01
      expect(LooseParse.parseEpochOrSerial('45292')).assertEqual(ts(2024, 1, 1, 0, 0));
    });

    it('loose_parse_time_writings', 0, () => {
      expect(LooseParse.minutesLoose('08:30')).assertEqual(510);
      expect(LooseParse.minutesLoose('8:30')).assertEqual(510);
      expect(LooseParse.minutesLoose('0830')).assertEqual(510);
      expect(LooseParse.minutesLoose('8时30分')).assertEqual(510);
      expect(LooseParse.minutesLoose('08:30:00')).assertEqual(510);   // 秒不入分钟
      expect(LooseParse.minutesLoose('下午3:20')).assertEqual(15 * 60 + 20);
      expect(LooseParse.minutesLoose('PM 8:30')).assertEqual(20 * 60 + 30);
      expect(LooseParse.minutesLoose('25:00')).assertEqual(-1);
      expect(LooseParse.parseDateTimeLoose('2026-10-06 08:30')).assertEqual(ts(2026, 10, 6, 8, 30));
      expect(LooseParse.parseDateTimeLoose('2026年10月6日8时30分')).assertEqual(ts(2026, 10, 6, 8, 30));
      expect(LooseParse.parseDateTimeLoose('2026-10-06T08:30:00')).assertEqual(ts(2026, 10, 6, 8, 30));
    });

    it('loose_parse_value_and_pair', 0, () => {
      expect(LooseParse.parseIntLoose('128')).assertEqual(128);
      expect(LooseParse.parseIntLoose('１２８')).assertEqual(128);
      expect(LooseParse.parseIntLoose('128mmHg')).assertEqual(128);
      expect(LooseParse.parseIntLoose('72 次/分')).assertEqual(72);
      expect(LooseParse.parseIntLoose('16.9')).assertNull();
      const p: BpPairValue | null = LooseParse.parseBpPair('120 / 80 mmHg(72)');
      expect(p !== null).assertTrue();
      if (p !== null) {
        expect(p.systolic).assertEqual(120);
        expect(p.diastolic).assertEqual(80);
        expect(p.heartRate).assertEqual(72);
      }
      // 「10/6」量级不合理，不得当作血压组合值
      expect(LooseParse.parseBpPair('10/6') === null).assertTrue();
      // kPa → mmHg：16.8 kPa ≈ 126 mmHg
      expect(Math.round(16.8 * LooseParse.KPA_TO_MMHG)).assertEqual(126);
    });

    it('detect_alt_headers', 0, () => {
      const rows: string[][] = Csv.parse('测量日期,测量时间,高压,低压,脉搏,备注\r\n'
        + '2026/10/1,6:30,132,86,74,起床后\r\n');
      const det: Detection = GenericImportService.detect(rows, impVocab, vocab);
      expect(det.kind).assertEqual(ImportKind.BP);
      expect(det.hasHeader).assertTrue();
      expect(det.roleIndex[ColRole.DATE]).assertEqual(0);
      expect(det.roleIndex[ColRole.TIME]).assertEqual(1);
      expect(det.roleIndex[ColRole.SYSTOLIC]).assertEqual(2);
      expect(det.roleIndex[ColRole.DIASTOLIC]).assertEqual(3);
      expect(det.roleIndex[ColRole.HEART_RATE]).assertEqual(4);
      expect(det.roleIndex[ColRole.NOTE]).assertEqual(5);
      expect(det.unit).assertEqual(ImportUnit.MMHG);
      expect(det.missing.length).assertEqual(0);
    });

    it('detect_headerless_kpa_single_column', 0, () => {
      const rows: string[][] = Csv.parse('2026-10-01,06:30,16.8/10.5\r\n');
      const det: Detection = GenericImportService.detect(rows, impVocab, vocab);
      expect(det.hasHeader).assertFalse();
      expect(det.kind).assertEqual(ImportKind.BP);
      expect(det.roleIndex[ColRole.DATE]).assertEqual(0);
      expect(det.roleIndex[ColRole.TIME]).assertEqual(1);
      expect(det.roleIndex[ColRole.BP_PAIR]).assertEqual(2);
      expect(det.unit).assertEqual(ImportUnit.KPA);
      const pv = GenericImportService.parseBp(rows, vocab, det, new Set<string>());
      expect(pv.drafts.length).assertEqual(1);
      expect(pv.drafts[0].systolic).assertEqual(126);
      expect(pv.drafts[0].diastolic).assertEqual(79);
      expect(pv.convertedFromKpa).assertTrue();
    });

    it('parse_merged_datetime_and_no_time_column', 0, () => {
      const merged: string[][] = Csv.parse('记录时间,收缩压,舒张压\r\n2026-10-05 21:40,138,88\r\n');
      const d1: Detection = GenericImportService.detect(merged, impVocab, vocab);
      expect(d1.roleIndex[ColRole.DATETIME]).assertEqual(0);
      const p1 = GenericImportService.parseBp(merged, vocab, d1, new Set<string>());
      expect(p1.drafts[0].measureTime).assertEqual(ts(2026, 10, 5, 21, 40));
      expect(p1.drafts[0].period).assertEqual(Period.NIGHT);
      expect(p1.noTimeColumn).assertFalse();

      const dateOnly: string[][] = Csv.parse('日期,高压,低压\r\n2026-10-05,138,88\r\n');
      const d2: Detection = GenericImportService.detect(dateOnly, impVocab, vocab);
      expect(d2.roleIndex[ColRole.TIME]).assertEqual(-1);
      const p2 = GenericImportService.parseBp(dateOnly, vocab, d2, new Set<string>());
      expect(p2.drafts.length).assertEqual(1);
      // 无时间列时不臆造时间，统一记 00:00 并在界面提示
      expect(p2.drafts[0].measureTime).assertEqual(ts(2026, 10, 5, 0, 0));
      expect(p2.noTimeColumn).assertTrue();
    });

    it('dirty_rows_isolated_line_by_line', 0, () => {
      const rows: string[][] = Csv.parse('日期,时间,收缩压,舒张压\r\n'
        + '2026-10-01,6:30,132,86\r\n'
        + '2026-02-30,6:30,132,86\r\n'
        + '2026-10-03,25:00,132,86\r\n'
        + '2026-10-04,6:30,86,132\r\n'
        + ',6:30,132,86\r\n');
      const det: Detection = GenericImportService.detect(rows, impVocab, vocab);
      const pv = GenericImportService.parseBp(rows, vocab, det, new Set<string>());
      expect(pv.totalRows).assertEqual(5);
      expect(pv.drafts.length).assertEqual(1);
      expect(pv.errors.length).assertEqual(4);
      // 行号指向原始文件（含表头偏移）
      expect(pv.errors[0].lineNo).assertEqual(3);
    });

    it('manual_mapping_overrides_detection', 0, () => {
      const rows: string[][] = Csv.parse('日期,时间,甲列,乙列\r\n2026-10-01,6:30,86,132\r\n');
      const det: Detection = GenericImportService.detect(rows, impVocab, vocab);
      const plan: MappingPlan = {
        hasHeader: det.hasHeader,
        roleIndex: det.roleIndex.slice(),
        unit: det.unit,
        unitScale: det.unitScale
      };
      plan.roleIndex[ColRole.SYSTOLIC] = 3;
      plan.roleIndex[ColRole.DIASTOLIC] = 2;
      const pv = GenericImportService.parseBp(rows, vocab, plan, new Set<string>());
      expect(pv.drafts.length).assertEqual(1);
      expect(pv.drafts[0].systolic).assertEqual(132);
      expect(pv.drafts[0].diastolic).assertEqual(86);
      expect(GenericImportService.missingRolesFor(ImportKind.BP, plan.roleIndex).length).assertEqual(0);
    });

    it('med_status_alias_and_makeup', 0, () => {
      const rows: string[][] = Csv.parse('日期,时间,药品,剂量,状态,实际打卡时间\r\n'
        + '2026-10-01,07:30,缬沙坦,1片,已服,07:35\r\n'
        + '2026-10-01,18:00,缬沙坦,1片,漏服,\r\n'
        + '2026-10-02,07:30,缬沙坦,1片,已服(补记),09:05\r\n');
      const det: Detection = GenericImportService.detect(rows, impVocab, vocab);
      expect(det.kind).assertEqual(ImportKind.MED);
      const pv = GenericImportService.parseMed(
        rows, vocab, impVocab, det, new Set<string>(), new Map<string, number>());
      expect(pv.errors.length).assertEqual(0);
      expect(pv.drafts.length).assertEqual(3);
      expect(pv.drafts[0].status).assertEqual(MedLogStatus.TAKEN);
      expect(pv.drafts[0].takenTime).assertEqual(ts(2026, 10, 1, 7, 35));
      expect(pv.drafts[1].status).assertEqual(MedLogStatus.MISSED);
      expect(pv.drafts[1].takenTime).assertNull();
      expect(pv.drafts[2].takenTime).assertEqual(ts(2026, 10, 2, 9, 5));
    });

    it('detect_plan_like_structure', 0, () => {
      const rows: string[][] = Csv.parse('药品,剂量,每日次数,时间点,开始日期\r\n'
        + '缬沙坦,1片,2,07:30;18:00,2026-10-01\r\n');
      const det: Detection = GenericImportService.detect(rows, impVocab, vocab);
      // 必须识别为「用药计划」，而不是把计划当打卡导入
      expect(det.kind).assertEqual(ImportKind.PLAN);
      expect(det.roleIndex[ColRole.SLOTS]).assertEqual(3);
    });

    it('own_format_recognized_by_generic_path', 0, () => {
      // 自家导出格式也应能被「其他来源」路径吃下，且两条路径的有效条数与判重键完全一致
      const rows: string[][] = Csv.parse('日期,时间,收缩压(mmHg),舒张压(mmHg),心率(bpm),时段,备注\r\n'
        + '2026-10-01,06:30,132,86,74,晨起,起床后\r\n');
      const det: Detection = GenericImportService.detect(rows, impVocab, vocab);
      const generic = GenericImportService.parseBp(rows, vocab, det, new Set<string>());
      const strict = ImportService.parseBpTable(rows, vocab, new Set<string>());
      expect(generic.drafts.length).assertEqual(strict.drafts.length);
      expect(generic.drafts[0].period).assertEqual(Period.MORNING);
      expect(generic.drafts[0].note).assertEqual('起床后');
      expect(generic.drafts[0].systolic).assertEqual(132);
      // 判重键一致 —— 否则同一份数据经两条路径会重复入库
      const a = generic.drafts[0];
      const b = strict.drafts[0];
      expect(ImportService.bpKey(a.measureTime, a.systolic, a.diastolic))
        .assertEqual(ImportService.bpKey(b.measureTime, b.systolic, b.diastolic));
    });
  });
}
