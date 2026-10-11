// 统一门禁：按《全面审查报告与修改要求-2026-10-11.md》§5.1 逐条跑，保留每组明细与退出码。
//
// 用法：
//   node tools/check-all.mjs                          # 全部（含审查反例，当前应为红：19 个待修）
//   node tools/check-all.mjs --skip-review-regression # 迭代时只跑 7 组常规检查
//
// 规则：不吞异常、不把失败算成跳过；任何一组非 0 退出码都会让整体退出码非 0。
import { spawnSync } from 'node:child_process';
import { existsSync } from 'node:fs';
import { join } from 'node:path';
import { NODE_BIN, PROJECT_ROOT } from './toolchain.mjs';

const args = process.argv.slice(2);
const skipReview = args.includes('--skip-review-regression');

const STEPS = [
  ['parity（类型检查 + 边界用例）', 'tools/parity/run.mjs'],
  ['sqlcheck（DDL / 迁移）', 'tools/sqlcheck.mjs'],
  ['check-resources（文案与颜色）', 'tools/check-resources.mjs'],
  ['check-project-config（工程配置）', 'tools/check-project-config.mjs'],
  ['check-api-usage（API 使用扫描）', 'tools/check-api-usage.mjs'],
  ['check-encoding-fallback（编码回落）', 'tools/check-encoding-fallback.mjs'],
  ['check-tooltip-geometry（气泡几何）', 'tools/check-tooltip-geometry.mjs']
];

if (!skipReview) {
  // 用随仓库走的正式回归副本（源：审查包里的 repro.cjs，冻结件仍在 docs/review-2026-10-11/）：
  // 其中 R06-a 按时序改写，业务断言含义保留并加强，见该文件头部说明。
  STEPS.push(['review-regression（审查 19 反例，红=缺陷待修）', 'tools/regression/review-2026-10-11.cjs']);
}

const results = [];
for (const [name, rel] of STEPS) {
  const file = join(PROJECT_ROOT, rel);
  process.stdout.write(`\n=============== ${name} ===============\n`);
  if (!existsSync(file)) {
    results.push({ name, code: 127, note: '脚本不存在' });
    process.stdout.write(`跳过：找不到 ${rel}\n`);
    continue;
  }
  const r = spawnSync(NODE_BIN, [file], { encoding: 'utf8', cwd: PROJECT_ROOT });
  process.stdout.write(r.stdout ?? '');
  process.stderr.write(r.stderr ?? '');
  results.push({ name, code: r.status ?? 1, note: '' });
}

process.stdout.write('\n=============== 汇总 ===============\n');
for (const r of results) {
  process.stdout.write(`${r.code === 0 ? 'PASS' : 'FAIL'}  exit=${r.code}  ${r.name}${r.note ? '  (' + r.note + ')' : ''}\n`);
}
if (skipReview) {
  process.stdout.write('注意：本次用 --skip-review-regression 跳过了审查反例组，不代表门禁通过。\n');
}
const failed = results.filter(r => r.code !== 0);
process.stdout.write(`共 ${results.length} 组：通过 ${results.length - failed.length}，失败 ${failed.length}\n`);
process.exit(failed.length === 0 ? 0 : 1);
