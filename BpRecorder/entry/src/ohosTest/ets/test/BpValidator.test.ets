import { describe, expect, it } from '@ohos/hypium';
import { BpValidator } from '../../../main/ets/service/BpValidator';
import { DateUtils } from '../../../main/ets/common/DateUtils';
import { Period } from '../../../main/ets/model/Types';

/** 录入校验与时段推断单测（CL-2） */
export default function bpValidatorTest() {
  const at = (h: number, m: number): number => new Date(2026, 9, 6, h, m, 0, 0).getTime();

  describe('BpValidatorTest', () => {
    it('period_boundaries', 0, () => {
      expect(DateUtils.periodOf(at(4, 59))).assertEqual(Period.OTHER);
      expect(DateUtils.periodOf(at(5, 0))).assertEqual(Period.MORNING);
      expect(DateUtils.periodOf(at(9, 0))).assertEqual(Period.FORENOON);
      expect(DateUtils.periodOf(at(14, 0))).assertEqual(Period.AFTERNOON);
      expect(DateUtils.periodOf(at(18, 0))).assertEqual(Period.NIGHT);
      // D3：睡前区间延至 24:00，23:00–23:59 归睡前
      expect(DateUtils.periodOf(at(23, 0))).assertEqual(Period.NIGHT);
      expect(DateUtils.periodOf(at(23, 59))).assertEqual(Period.NIGHT);
    });

    it('range_checks', 0, () => {
      expect(BpValidator.validateCore('120', '80', '72').ok).assertTrue();
      expect(BpValidator.validateCore('40', '30', '').ok).assertTrue();
      expect(BpValidator.validateCore('300', '200', '220').ok).assertTrue();
      expect(BpValidator.validateCore('39', '30', '').ok).assertFalse();
      expect(BpValidator.validateCore('301', '30', '').ok).assertFalse();
      expect(BpValidator.validateCore('120', '29', '').ok).assertFalse();
      expect(BpValidator.validateCore('120', '201', '').ok).assertFalse();
      expect(BpValidator.validateCore('120', '80', '29').ok).assertFalse();
      expect(BpValidator.validateCore('120', '80', '221').ok).assertFalse();
    });

    it('systolic_must_exceed_diastolic', 0, () => {
      expect(BpValidator.validateCore('120', '120', '').ok).assertFalse();
      expect(BpValidator.validateCore('100', '120', '').ok).assertFalse();
      expect(BpValidator.validateCore('121', '120', '').ok).assertTrue();
    });

    it('heart_rate_optional', 0, () => {
      expect(BpValidator.validateCore('120', '80', '').ok).assertTrue();
      expect(BpValidator.validateCore('120', '80', '  ').ok).assertTrue();
    });

    it('note_and_time', 0, () => {
      const now: number = DateUtils.now();
      expect(BpValidator.validateForm({
        systolicText: '120', diastolicText: '80', heartRateText: '',
        measureTime: now, note: 'a'.repeat(100)
      }, now).ok).assertTrue();
      expect(BpValidator.validateForm({
        systolicText: '120', diastolicText: '80', heartRateText: '',
        measureTime: now, note: 'a'.repeat(101)
      }, now).ok).assertFalse();
      expect(BpValidator.validateForm({
        systolicText: '120', diastolicText: '80', heartRateText: '',
        measureTime: now + 120000, note: ''
      }, now).ok).assertFalse();
      expect(BpValidator.validateForm({
        systolicText: '120', diastolicText: '80', heartRateText: '',
        measureTime: now - 5 * 365 * 86400000, note: ''
      }, now).ok).assertTrue();
    });

    it('date_parsing', 0, () => {
      expect(DateUtils.parseDate('2026-02-30')).assertNull();
      expect(DateUtils.parseDate('2026-13-01')).assertNull();
      expect(DateUtils.parseDate('2026-1-1')).assertNull();
      expect(DateUtils.parseDate('2028-02-29') !== null).assertTrue();
      expect(DateUtils.hhmmToMinutes('07:30')).assertEqual(450);
      expect(DateUtils.hhmmToMinutes('24:00')).assertEqual(-1);
      expect(DateUtils.hhmmToMinutes('7:30')).assertEqual(-1);
    });
  });
}
