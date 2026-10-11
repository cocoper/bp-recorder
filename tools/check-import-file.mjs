// CSV 导入预检：在把文件传到手机之前，先在电脑上判断它能不能被这个 App 正常导入。
//
// 为什么需要它：App 的导入页会显示「有效 N / 重复 N / 错误 N」并逐行给原因，
// 但那要等到文件已经在手机上、点了导入之后才知道。本工具让你在电脑上先验一遍，
// 避免「传上去才发现格式不对」的来回。
//
// 关键性质：**它直接调用工程里真实的解析实现**（把 `.ets` 编译成 `.js` 后加载，
// 见 tools/parity/run.mjs），不是另写一份规则 —— 所以结论与 App 内的行为一致。
// 词表（表头文字、时段/状态枚举、别名）从 resources/base/element/string.json 读取，
// 因此资源改动后本工具自动跟随，不需要手工同步。
//
// 用法：
//   node tools/check-import-file.mjs <csv 文件路径>
//
// 退出码：0 可以导入且无错误行；1 有错误行或完全无法导入。

import { existsSync, readFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { spawnSync } from 'node:child_process';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

// 本文件是 ESM，但被测实现是 CommonJS 产物，需要一个 require
const require = createRequire(import.meta.url);

const HERE = dirname(fileURLToPath(import.meta.url));
const PROJECT_ROOT = resolve(HERE, '..');
const PROJECT = join(PROJECT_ROOT, 'BpRecorder');
const BUILD_OUT = join(HERE, 'parity', '.build', 'out');
const STRING_JSON = join(PROJECT, 'entry', 'src', 'main', 'resources', 'base', 'element', 'string.json');
// Node 由 tools/toolchain.mjs 解析（审查 R16：不写死某台机器的路径）。
const NODE_BIN = process.env.PARITY_NODE ?? process.execPath;

const target = process.argv[2];
if (target === undefined) {
  console.error('用法：node tools/check-import-file.mjs <csv 文件路径>');
  process.exit(1);
}
const file = resolve(target);
if (!existsSync(file)) {
  console.error(`✗ 文件不存在：${file}`);
  process.exit(1);
}

// 复用 parity 的编译产物；没有就先构建一次（约 10 秒）
if (!existsSync(join(BUILD_OUT, 'src', 'service', 'ImportService.js'))) {
  console.log('→ 首次使用，先构建解析器（复用 tools/parity 的编译产物）…');
  const build = spawnSync(NODE_BIN, [join(HERE, 'parity', 'run.mjs')], { encoding: 'utf8' });
  if (!existsSync(join(BUILD_OUT, 'src', 'service', 'ImportService.js'))) {
    console.error('✗ 构建失败，请先单独运行 `node tools/parity/run.mjs` 查看原因。');
    process.exit(1);
  }
}

// ── 从资源读出词表（不硬编码，避免与资源漂移）──
const table = new Map(JSON.parse(readFileSync(STRING_JSON, 'utf8')).string.map((e) => [e.name, e.value]));
const s = (name) => {
  const v = table.get(name);
  if (v === undefined) {
    console.error(`✗ 资源里缺少 ${name}（资源文件被改过？）`);
    process.exit(1);
  }
  return v;
};
const group = (name) => s(name).split('|').map((x) => x.trim()).filter((x) => x.length > 0);

const VOCAB = {
  bpHeaders: ['csv_hdr_date', 'csv_hdr_time', 'csv_hdr_systolic', 'csv_hdr_diastolic',
    'csv_hdr_heart_rate', 'csv_hdr_period', 'csv_hdr_note'].map(s),
  medHeaders: ['csv_hdr_date', 'csv_hdr_plan_time', 'csv_hdr_med_name', 'csv_hdr_dosage',
    'csv_hdr_status', 'csv_hdr_taken_time', 'csv_hdr_note'].map(s),
  planHeaders: ['csv_hdr_med_name', 'csv_hdr_dosage', 'csv_hdr_slot_count', 'csv_hdr_time_slots',
    'csv_hdr_start_date', 'csv_hdr_end_date', 'csv_hdr_note'].map(s),
  slotSeparator: s('csv_slot_separator'),
  periodMorning: s('period_morning'), periodForenoon: s('period_forenoon'),
  periodAfternoon: s('period_afternoon'), periodNight: s('period_night'), periodOther: s('period_other'),
  statusTaken: s('csv_status_taken'), statusTakenMakeup: s('csv_status_taken_makeup'),
  statusSkipped: s('csv_status_skipped'), statusMissed: s('csv_status_missed'),
  statusPending: s('csv_status_pending')
};

// 别名组顺序与 GenericImportService.ColRole 1..17 一致（该一致性由 tools/check-resources.mjs 守住）
const ALIAS_NAMES = ['imp_alias_datetime', 'imp_alias_date', 'imp_alias_time', 'imp_alias_systolic',
  'imp_alias_diastolic', 'imp_alias_bp_pair', 'imp_alias_heart_rate', 'imp_alias_period',
  'imp_alias_note', 'imp_alias_med_name', 'imp_alias_dosage', 'imp_alias_status',
  'imp_alias_taken_time', 'imp_alias_slots', 'imp_alias_day_count', 'imp_alias_start_date',
  'imp_alias_end_date'];
// 词表里的别名需与 VocabFactory.imp 一样先做归一化（这里用被测实现自带的归一函数）
// preload 为编译产物注入 $r 运行时桩（与 parity 用例用的是同一个）
require(join(BUILD_OUT, 'preload.js'));
const { Csv } = require(join(BUILD_OUT, 'src', 'common', 'Csv.js'));
const { LooseParse } = require(join(BUILD_OUT, 'src', 'common', 'LooseParse.js'));
const { ImportService } = require(join(BUILD_OUT, 'src', 'service', 'ImportService.js'));
const { GenericImportService } = require(join(BUILD_OUT, 'src', 'service', 'GenericImportService.js'));

const IMPV = {
  roleNames: ['', ...group('imp_role_names')],
  roleAliases: [[], ...ALIAS_NAMES.map((n) => group(n).map((x) => LooseParse.normalizeKey(x)))],
  statusTaken: group('imp_status_taken').map((x) => LooseParse.normalizeKey(x)),
  statusSkipped: group('imp_status_skipped').map((x) => LooseParse.normalizeKey(x)),
  statusMissed: group('imp_status_missed').map((x) => LooseParse.normalizeKey(x)),
  statusPending: group('imp_status_pending').map((x) => LooseParse.normalizeKey(x)),
  statusMakeup: group('imp_status_makeup').map((x) => LooseParse.normalizeKey(x))
};

// ── 解析 ──
const bytes = readFileSync(file);

/**
 * 编码自适应：与 App 的 FileService.readText 同一策略
 * （UTF-8 严格 → GB18030 严格 → UTF-8 放宽）。
 * 这里必须复现这一步，否则 GBK 文件会被误判为"无法导入"（假阴性）。
 */
function decodeAdaptive(buf) {
  for (const enc of ['utf-8', 'gb18030']) {
    try {
      return { text: new TextDecoder(enc, { fatal: true }).decode(buf), encoding: enc };
    } catch {
      // 继续试下一种
    }
  }
  return { text: new TextDecoder('utf-8').decode(buf), encoding: 'utf-8(放宽)' };
}

const decoded = decodeAdaptive(bytes);
const text = decoded.text;
const rows = Csv.parse(text);
console.log('================ CSV 导入预检 ================');
console.log(`文件：${file}`);
console.log(`大小：${bytes.length} 字节｜解析出 ${rows.length} 行`);
const bom = bytes.length >= 3 && bytes[0] === 0xef && bytes[1] === 0xbb && bytes[2] === 0xbf;
const encNote = decoded.encoding === 'gb18030'
  ? 'GBK/GB18030（App 会按同样的规则回落解码）'
  : (bom ? 'UTF-8 带 BOM（与本 App 导出一致）' : 'UTF-8（无 BOM；Excel 打开中文可能乱码，App 读取正常）');
console.log(`编码：${encNote}`);

const kindName = { bp: '血压记录', med: '用药打卡', plan: '用药计划', unknown: '未识别' };

console.log('\n---- 路径一：严格格式（对应导入页里的「血压记录 / 用药打卡 / 用药计划」）----');
const strictBp = ImportService.parseBpTable(rows, VOCAB, new Set());
const strictMed = ImportService.parseMedTable(rows, VOCAB, new Set(), new Map());
const strictPlan = ImportService.parsePlanTable(rows, VOCAB, new Set());
const candidates = [
  { name: '血压记录', r: strictBp },
  { name: '用药打卡', r: strictMed },
  { name: '用药计划', r: strictPlan }
];
let best = null;
for (const c of candidates) {
  console.log(`  ${c.name.padEnd(6)} 数据行 ${c.r.totalRows}｜有效 ${c.r.drafts.length}｜重复 ${c.r.duplicateCount}｜错误 ${c.r.errors.length}`);
  if (best === null || c.r.drafts.length > best.r.drafts.length) {
    best = c;
  }
}

console.log('\n---- 路径二：其他来源（列名/列序/日期写法可不同，自动识别）----');
const det = GenericImportService.detect(rows, IMPV, VOCAB);
console.log(`  识别为：${kindName[det.kind] ?? det.kind}｜有表头 ${det.hasHeader}｜列数 ${det.columnCount}｜数值单位 ${det.unit}`);
const roleLabels = ['', '日期时间', '日期', '时间', '收缩压', '舒张压', '血压组合', '心率', '时段', '备注',
  '药品', '剂量', '状态', '实际打卡时间', '时间点', '每日次数', '开始日期', '结束日期'];
console.log('  列识别：' + det.probes.map((p) => `[${p.index}]${p.header || '(无表头)'}→${roleLabels[p.role] || '不使用'}`).join('  '));
let generic = null;
if (det.kind === 'med') {
  generic = GenericImportService.parseMed(rows, VOCAB, IMPV, det, new Set(), new Map());
  console.log(`  有效 ${generic.drafts.length}｜重复 ${generic.duplicateCount}｜错误 ${generic.errors.length}`);
} else if (det.kind === 'bp') {
  generic = GenericImportService.parseBp(rows, VOCAB, det, new Set());
  console.log(`  有效 ${generic.drafts.length}｜重复 ${generic.duplicateCount}｜错误 ${generic.errors.length}` +
    `${generic.convertedFromKpa ? '｜已按 kPa 换算' : ''}${generic.noTimeColumn ? '｜无时间列（记 00:00）' : ''}`);
} else if (det.kind === 'plan') {
  console.log('  识别为用药计划：请在导入页选「用药计划」类型，不要用「其他来源」。');
} else {
  console.log('  未能自动识别列含义：导入时需在页面上手工指定列对应关系。');
}

// ── 结论：以「错误最少的可行路径」为准 ──
console.log('\n================ 结论 ================');
let exitCode = 1;
/** 两条路径里错误更少的（平手时再比有效行数）作为推荐路径；
 *  仍平手则保留精确格式 —— 它是本 App 的规范路径，语义最明确。 */
let rec = { path: `「${best.name}」类型`, r: best.r };
if (generic !== null && generic.drafts.length > 0) {
  const fewerErrors = generic.errors.length < rec.r.errors.length;
  const sameErrorsMoreRows = generic.errors.length === rec.r.errors.length
    && generic.drafts.length > rec.r.drafts.length;
  if (fewerErrors || sameErrorsMoreRows) {
    rec = { path: '「其他来源」模式', r: generic };
  }
}

if (rec.r.drafts.length === 0 && rec.r.errors.length === 0) {
  console.log('✗ 三种类型都解析不出任何数据行 —— 大概率是表头或分隔符不对（本工具按英文逗号分隔）。');
  console.log('  请核对首行表头是否为：' + VOCAB.bpHeaders.join(','));
} else if (rec.r.errors.length === 0) {
  console.log(`✓ 可导入：${rec.r.drafts.length} 行全部有效，无错误行。`);
  console.log(`  导入时请选：${rec.path}。`);
  exitCode = 0;
} else {
  console.log(`✗ 仍有 ${rec.r.errors.length} 行会被判为错误并跳过（其余 ${rec.r.drafts.length} 行会正常导入）。`);
  console.log(`  建议导入时选：${rec.path}。`);
  console.log('  出错的行号与原值（具体原因由 App 在导入页逐行显示）：');
  for (const e of rec.r.errors.slice(0, 20)) {
    console.log(`    第 ${e.lineNo} 行  ${e.detail.length > 0 ? e.detail : '(空值)'}`);
  }
  if (rec.r.errors.length > 20) {
    console.log(`    …… 其余 ${rec.r.errors.length - 20} 行省略`);
  }
  console.log('  修好这些行再导入，或直接导入（错误行不会入库，也不会中断其余行）。');
}
process.exit(exitCode);
