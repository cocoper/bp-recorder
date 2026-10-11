import { GradeLevel, GradeStandard } from '../model/Types';
import { AppConst, GradeSpec, GradeSpecs, RefBasis, RefThreshold } from '../common/Constants';

/**
 * 血压分级判定（纯函数，无 UI / 无数据库依赖，便于 Hypium 100% 分支覆盖）。
 *
 * 规则来源：策划文档 §3.2（v1.3 修订）
 *  **分级只有一套表** —— 《中国高血压防治指南（2024 年修订版）》诊室血压分类标准；
 *  收缩压与舒张压分属不同级别时，取较高者。
 *
 * 注意：分级结果**不随「参考口径」设置变化**（决策 D1）。
 * v1.2 的「家庭自测标准（整体下移 5 mmHg）」并非指南给出的分级表，属自创规则，已移除；
 * 家庭自测界值 135/85 仅用于图表参考线与趋势预警
 * （见 RefBasis / StatsService.isTrendWarning）。
 */
export class GradeService {
  /** 唯一分级阈值表（诊室标准） */
  static diagnosisSpec(): GradeSpec {
    return GradeSpecs.CN_GUIDELINE;
  }

  /**
   * 参考口径 → 参考阈值对。
   * 仅供「主参考线高亮」与「参考阈值文案」使用，**不参与任何分级判定**。
   */
  static refThreshold(standard: GradeStandard): RefThreshold {
    return RefBasis.of(standard);
  }

  /**
   * 收缩压单独分级。
   * 边界（中国指南）：119→正常、120→正常高值、139→正常高值、140→1 级、159→1 级、
   * 160→2 级、179→2 级、180→3 级。
   */
  static levelOfSystolic(systolic: number, spec: GradeSpec): GradeLevel {
    if (systolic < spec.normalSysMax) {
      return GradeLevel.NORMAL;
    }
    if (systolic <= spec.highNormalSysMax) {
      return GradeLevel.HIGH_NORMAL;
    }
    if (systolic <= spec.grade1SysMax) {
      return GradeLevel.GRADE_1;
    }
    if (systolic <= spec.grade2SysMax) {
      return GradeLevel.GRADE_2;
    }
    return GradeLevel.GRADE_3;
  }

  /**
   * 舒张压单独分级。
   * 边界（中国指南）：79→正常、80→正常高值、89→正常高值、90→1 级、99→1 级、
   * 100→2 级、109→2 级、110→3 级。
   */
  static levelOfDiastolic(diastolic: number, spec: GradeSpec): GradeLevel {
    if (diastolic < spec.normalDiaMax) {
      return GradeLevel.NORMAL;
    }
    if (diastolic <= spec.highNormalDiaMax) {
      return GradeLevel.HIGH_NORMAL;
    }
    if (diastolic <= spec.grade1DiaMax) {
      return GradeLevel.GRADE_1;
    }
    if (diastolic <= spec.grade2DiaMax) {
      return GradeLevel.GRADE_2;
    }
    return GradeLevel.GRADE_3;
  }

  /**
   * 综合分级：收缩压与舒张压取较高者（§3.2 规则）。
   * 固定使用诊室分级表，**不接受「参考口径」参数** —— 这是决策 D1 的核心约束。
   */
  static gradeOf(systolic: number, diastolic: number): GradeLevel {
    const spec: GradeSpec = GradeSpecs.CN_GUIDELINE;
    const sysLevel: GradeLevel = GradeService.levelOfSystolic(systolic, spec);
    const diaLevel: GradeLevel = GradeService.levelOfDiastolic(diastolic, spec);
    return sysLevel >= diaLevel ? sysLevel : diaLevel;
  }

  /**
   * 是否触发强警示（FR-5.2）。
   * 收缩压 ≥180 或 舒张压 ≥110 —— 取中国指南诊室标准的 3 级下界，
   * 语义是「重度升高，尽快就医」的绝对警戒线，与参考口径设置无关。
   */
  static isSevere(systolic: number, diastolic: number): boolean {
    return systolic >= GradeSpecs.CN_GUIDELINE.severeSys || diastolic >= GradeSpecs.CN_GUIDELINE.severeDia;
  }

  /**
   * 异常清单判定（FR-10.2 板块 7）：固定以 ≥140/90（诊室参考线）为准，
   * 与「参考口径」设置无关，保证报告口径稳定、可跨期比较。
   */
  static isAbnormal(systolic: number, diastolic: number): boolean {
    return systolic >= AppConst.REF_CLINIC_SYS || diastolic >= AppConst.REF_CLINIC_DIA;
  }
}
