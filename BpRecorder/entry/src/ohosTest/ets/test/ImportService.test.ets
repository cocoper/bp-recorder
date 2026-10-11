import { describe, expect, it } from '@ohos/hypium';
import { ImportService } from '../../../main/ets/service/ImportService';
import { ExportService } from '../../../main/ets/service/ExportService';
import { Csv } from '../../../main/ets/common/Csv';
import { CsvVocab } from '../../../main/ets/common/Vocab';
import { DateUtils } from '../../../main/ets/common/DateUtils';
import { BpRecord } from '../../../main/ets/model/BpRecord';
import { MedDedupeTuple, MedLog } from '../../../main/ets/model/Med';
import { MedLogStatus } from '../../../main/ets/model/Types';

/** CSV 导入导出单测（CL-10：往返幂等、判重三元组、错误行隔离） */
export default function importServiceTest() {
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

  const rec = (t: number, sys: number, dia: number, hr: number | null, id: number): BpRecord => ({
    id: id, systolic: sys, diastolic: dia, heartRate: hr, measureTime: t,
    period: DateUtils.periodOf(t), note: null, userId: 1, source: 'manual',
    createdAt: t, updatedAt: t
  });

  const mlog = (scheduled: number, status: MedLogStatus, taken: number | null, id: number,
    name: string, medId: number): MedLog => ({
    id: id, medicationId: medId, medName: name, dosage: '1片', scheduledTime: scheduled,
    takenTime: taken, status: status, note: null, createdAt: scheduled, updatedAt: scheduled
  });

  describe('ImportServiceTest', () => {
    it('csv_parse_tolerance', 0, () => {
      expect(Csv.parse('a,b\r\nc,d\r\n').length).assertEqual(2);
      expect(Csv.parse('a,b\nc,d').length).assertEqual(2);
      expect(Csv.parse('a,b\rc,d').length).assertEqual(2);
      expect(Csv.parse('\uFEFFa,b')[0][0]).assertEqual('a');
      expect(Csv.parse('"a""b",c')[0][0]).assertEqual('a"b');
      expect(Csv.parse('"a\nb",c').length).assertEqual(1);
      expect(Csv.cell(['a'], 5)).assertEqual('');
    });

    it('bp_export_import_roundtrip_idempotent', 0, () => {
      const records: BpRecord[] = [
        rec(ts(2026, 10, 1, 6, 30), 132, 86, 74, 1),
        rec(ts(2026, 10, 2, 12, 10), 128, 82, null, 2),
        rec(ts(2026, 10, 3, 15, 20), 145, 92, 88, 3)
      ];
      records[0].note = '含,逗号与"引号"及换行';
      const csv: string = ExportService.buildBpCsv(records, vocab);
      expect(csv.charCodeAt(0)).assertEqual(0xFEFF);

      const rows: string[][] = Csv.parse(csv);
      const first = ImportService.parseBpTable(rows, vocab, new Set<string>());
      expect(first.errors.length).assertEqual(0);
      expect(first.drafts.length).assertEqual(3);
      expect(first.duplicateCount).assertEqual(0);
      expect(first.drafts[0].note).assertEqual('含,逗号与"引号"及换行');
      expect(first.drafts[1].heartRate).assertNull();

      const keys: Set<string> = new Set<string>();
      for (let i = 0; i < first.drafts.length; i++) {
        const d = first.drafts[i];
        keys.add(ImportService.bpKey(d.measureTime, d.systolic, d.diastolic));
      }
      const second = ImportService.parseBpTable(rows, vocab, keys);
      expect(second.drafts.length).assertEqual(0);
      expect(second.duplicateCount).assertEqual(3);
      expect(second.errors.length).assertEqual(0);
    });

    it('bp_dedupe_triple', 0, () => {
      const text = '2026-10-06,08:12,128,82,72,晨起,\r\n'
        + '2026-10-06,08:12,128,82,72,晨起,\r\n'
        + '2026-10-06,08:12,135,88,72,晨起,\r\n';
      const preview = ImportService.parseBpTable(Csv.parse(text), vocab, new Set<string>());
      expect(preview.totalRows).assertEqual(3);
      expect(preview.duplicateCount).assertEqual(1);
      expect(preview.drafts.length).assertEqual(2);
    });

    it('bp_dirty_rows_isolated', 0, () => {
      const text = '日期,时间,收缩压(mmHg),舒张压(mmHg),心率(bpm),时段,备注\r\n'
        + '2026-10-01,08:00,128,82,72,晨起,正常行\r\n'
        + '2026-10-02,08:00,350,82,72,晨起,越界\r\n'
        + '2026-13-01,08:00,128,82,72,晨起,月份非法\r\n'
        + 'abc,def,128,82,72,晨起,时间非法\r\n'
        + '2026-10-03\r\n';
      const preview = ImportService.parseBpTable(Csv.parse(text), vocab, new Set<string>());
      expect(preview.totalRows).assertEqual(5);
      expect(preview.errors.length).assertEqual(4);
      expect(preview.drafts.length).assertEqual(1);
      expect(preview.errors[0].lineNo).assertEqual(3);
    });

    it('med_export_import_roundtrip', 0, () => {
      const logs: MedLog[] = [
        mlog(ts(2026, 10, 1, 7, 30), MedLogStatus.TAKEN, ts(2026, 10, 1, 7, 35), 1, '缬沙坦', 1),
        mlog(ts(2026, 10, 1, 12, 0), MedLogStatus.TAKEN, ts(2026, 10, 1, 21, 10), 2, '二甲双胍', 2),
        mlog(ts(2026, 10, 1, 18, 0), MedLogStatus.SKIPPED, null, 3, '缬沙坦', 1),
        mlog(ts(2026, 10, 2, 7, 30), MedLogStatus.MISSED, null, 4, '缬沙坦', 1),
        mlog(ts(2026, 10, 2, 12, 0), MedLogStatus.PENDING, null, 5, '二甲双胍', 2),
        mlog(ts(2026, 10, 5, 23, 50), MedLogStatus.TAKEN, ts(2026, 10, 6, 0, 10), 6, '缬沙坦', 1)
      ];
      expect(ExportService.medStatusText(logs[0], vocab)).assertEqual('已服用');
      expect(ExportService.medStatusText(logs[1], vocab)).assertEqual('已服用(补记)');
      expect(ExportService.medStatusText(logs[2], vocab)).assertEqual('跳过');
      expect(ExportService.medStatusText(logs[3], vocab)).assertEqual('漏服');
      expect(ExportService.medStatusText(logs[4], vocab)).assertEqual('待服');

      const rows: string[][] = Csv.parse(ExportService.buildMedCsv(logs, vocab));
      const first = ImportService.parseMedTable(rows, vocab, new Set<string>(), new Map<string, number>());
      expect(first.errors.length).assertEqual(0);
      expect(first.drafts.length).assertEqual(6);
      expect(first.drafts[1].status).assertEqual(MedLogStatus.TAKEN);
      expect(first.drafts[4].status).assertEqual(MedLogStatus.PENDING);
      // 跨零点打卡时间应还原为次日
      expect(first.drafts[5].takenTime).assertEqual(ts(2026, 10, 6, 0, 10));

      const tuples: MedDedupeTuple[] = [];
      for (let i = 0; i < logs.length; i++) {
        tuples.push({
          medicationId: logs[i].medicationId,
          medName: logs[i].medName,
          scheduledTime: logs[i].scheduledTime,
          // 审查 R10-b：库内状态参与判定（此处为真实打卡记录，故原样回导仍判重复）
          status: `${logs[i].status}`
        });
      }
      const keys: Set<string> = ImportService.buildMedKeySet(tuples);
      const nameToId: Map<string, number> = new Map<string, number>();
      nameToId.set('缬沙坦', 1);
      const second = ImportService.parseMedTable(rows, vocab, keys, nameToId);
      expect(second.drafts.length).assertEqual(0);
      expect(second.duplicateCount).assertEqual(6);
    });

    it('med_dirty_rows_isolated', 0, () => {
      const text = '日期,计划时间,药品,剂量,状态,实际打卡时间,备注\r\n'
        + '2026-10-01,07:30,缬沙坦,1片,已服用,07:35,\r\n'
        + '2026-10-01,25:00,缬沙坦,1片,已服用,,\r\n'
        + '2026-10-01,12:00,,1片,已服用,,\r\n'
        + '2026-10-01,18:00,缬沙坦,1片,吃了,,\r\n'
        + '2026-10-01,19:00,缬沙坦,1片,已服用,xx:yy,\r\n'
        + '2026-10-02,07:30,未知药,1片,已服用,,\r\n';
      const preview = ImportService.parseMedTable(Csv.parse(text), vocab, new Set<string>(), new Map<string, number>());
      expect(preview.totalRows).assertEqual(6);
      expect(preview.errors.length).assertEqual(4);
      expect(preview.drafts.length).assertEqual(2);
      expect(preview.drafts[1].medName).assertEqual('未知药');
    });

    it('export_range_filter', 0, () => {
      const now: number = ts(2026, 10, 6, 12, 0);
      const records: BpRecord[] = [
        rec(ts(2026, 10, 6, 8, 0), 120, 80, null, 1),
        rec(ts(2026, 9, 10, 8, 0), 120, 80, null, 2),
        rec(ts(2026, 7, 1, 8, 0), 120, 80, null, 3)
      ];
      expect(ExportService.filterBpByRange(records, 'all', now).length).assertEqual(3);
      expect(ExportService.filterBpByRange(records, 'd30', now).length).assertEqual(2);
      expect(ExportService.filterBpByRange(records, 'd90', now).length).assertEqual(2);
    });
  });
}
