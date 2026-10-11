import { describe, expect, it } from '@ohos/hypium';
import { GradeService } from '../../../main/ets/service/GradeService';
import { GradeLevel, GradeStandard } from '../../../main/ets/model/Types';

/**
 * 分级判定单测（CL-5：构造 6 个边界值用例，逐项核对 §3.2 表）。
 * 与 tools/parity/harness.ts 共用同一批边界值，保证「离线校验」与「设备单测」口径一致。
 *
 * v1.3（决策 D1）：分级固定按诊室表，gradeOf 不再接收「参考口径」参数；
 * 参考口径只决定参考线与阈值文案，由 refThreshold() 提供。
 */
export default function gradeServiceTest() {
  describe('GradeServiceTest', () => {
    it('CL5_boundary_cases', 0, () => {
      expect(GradeService.gradeOf(119, 79)).assertEqual(GradeLevel.NORMAL);
      expect(GradeService.gradeOf(120, 80)).assertEqual(GradeLevel.HIGH_NORMAL);
      expect(GradeService.gradeOf(140, 90)).assertEqual(GradeLevel.GRADE_1);
      expect(GradeService.gradeOf(160, 100)).assertEqual(GradeLevel.GRADE_2);
      expect(GradeService.gradeOf(180, 110)).assertEqual(GradeLevel.GRADE_3);
      expect(GradeService.gradeOf(135, 85)).assertEqual(GradeLevel.HIGH_NORMAL);
    });

    it('band_edges_cn', 0, () => {
      expect(GradeService.gradeOf(139, 89)).assertEqual(GradeLevel.HIGH_NORMAL);
      expect(GradeService.gradeOf(159, 99)).assertEqual(GradeLevel.GRADE_1);
      expect(GradeService.gradeOf(179, 109)).assertEqual(GradeLevel.GRADE_2);
    });

    it('take_higher_level', 0, () => {
      expect(GradeService.gradeOf(118, 95)).assertEqual(GradeLevel.GRADE_1);
      expect(GradeService.gradeOf(165, 70)).assertEqual(GradeLevel.GRADE_2);
      expect(GradeService.gradeOf(139, 90)).assertEqual(GradeLevel.GRADE_1);
    });

    it('ref_basis_does_not_change_grade', 0, () => {
      // D1：参考口径不参与分级。下列均为原「家庭表」的边界值，现一律按诊室表判定
      expect(GradeService.gradeOf(114, 74)).assertEqual(GradeLevel.NORMAL);
      expect(GradeService.gradeOf(135, 85)).assertEqual(GradeLevel.HIGH_NORMAL);
      expect(GradeService.gradeOf(175, 105)).assertEqual(GradeLevel.GRADE_2);
      // 参考口径仅提供参考阈值，不影响上面的分级结果
      expect(GradeService.refThreshold(GradeStandard.CN_GUIDELINE).sys).assertEqual(140);
      expect(GradeService.refThreshold(GradeStandard.CN_GUIDELINE).dia).assertEqual(90);
      expect(GradeService.refThreshold(GradeStandard.HOME_MONITOR).sys).assertEqual(135);
      expect(GradeService.refThreshold(GradeStandard.HOME_MONITOR).dia).assertEqual(85);
    });

    it('severe_and_abnormal', 0, () => {
      expect(GradeService.isSevere(180, 70)).assertTrue();
      expect(GradeService.isSevere(120, 110)).assertTrue();
      expect(GradeService.isSevere(179, 109)).assertFalse();
      expect(GradeService.isAbnormal(140, 80)).assertTrue();
      expect(GradeService.isAbnormal(139, 90)).assertTrue();
      expect(GradeService.isAbnormal(139, 89)).assertFalse();
    });
  });
}
