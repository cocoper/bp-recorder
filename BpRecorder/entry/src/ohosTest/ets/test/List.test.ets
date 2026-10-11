import gradeServiceTest from './GradeService.test';
import bpValidatorTest from './BpValidator.test';
import statsServiceTest from './StatsService.test';
import medServiceTest from './MedService.test';
import reportServiceTest from './ReportService.test';
import importServiceTest from './ImportService.test';
import genericImportServiceTest from './GenericImportService.test';
import bpDatabaseTest from './BpDatabase.test';

/**
 * Hypium 测试入口。
 * 运行方式：DevEco Studio 中右键本文件 → Run，或使用 `hvigor test`。
 *
 * 覆盖范围（对应 CL-7）：
 * - GradeService / StatsService / MedService / ReportService / ImportService /
 *   GenericImportService（FR-6.11 外部来源导入）/ BpValidator：分支全覆盖；
 * - BpDatabase：CRUD 主路径、分页顺序、预生成幂等、事务回滚、清空。
 */
export default function testsuite() {
  gradeServiceTest();
  bpValidatorTest();
  statsServiceTest();
  medServiceTest();
  reportServiceTest();
  importServiceTest();
  genericImportServiceTest();
  bpDatabaseTest();
}
