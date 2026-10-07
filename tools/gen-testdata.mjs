// 测试数据生成器（M6 性能与容量验证用，策划文档 §9.6）。
//
// 产物（写入 tools/testdata/）：
//   1) bp_4000.csv        4000 条血压记录，格式与 App 导出格式完全一致，
//                         因此可直接通过 App 的「导入数据」灌入（无需任何调试接口）。
//   2) med_1100.csv       2 个药品、1 年打卡记录（约 1100 条），含漏服/跳过/补记混合状态。
//   3) import_dirty_4000.csv  4000 行脏数据（含故意的重复行与错误行），用于验证 CL-10。
//   4) README.md          每个文件的行数、有效/重复/错误条数与预期导入结果。
//
// 随机数使用固定种子的 mulberry32，保证多次运行结果完全一致（可复现）。
//
// 用法：node tools/gen-testdata.mjs

import { mkdirSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const OUT = resolve(HERE, '..', 'tools', 'testdata');

// ── 固定种子随机数 ──────────────────────────────────────────────
function mulberry32(seed) {
  let a = seed >>> 0;
  return function () {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

const rand = mulberry32(20261006);

/** Box-Muller 正态分布 */
function normal(mean, sd) {
  const u1 = Math.max(rand(), 1e-9);
  const u2 = rand();
  return mean + sd * Math.sqrt(-2 * Math.log(u1)) * Math.cos(2 * Math.PI * u2);
}

const clamp = (v, lo, hi) => Math.min(hi, Math.max(lo, Math.round(v)));
const pad2 = (v) => (v < 10 ? `0${v}` : `${v}`);
const fmtDate = (d) => `${d.getFullYear()}-${pad2(d.getMonth() + 1)}-${pad2(d.getDate())}`;
const fmtTime = (d) => `${pad2(d.getHours())}:${pad2(d.getMinutes())}`;

const PERIOD_BY_HOUR = (h) => {
  if (h >= 5 && h < 9) return '晨起';
  if (h >= 9 && h < 14) return '上午';
  if (h >= 14 && h < 18) return '下午';
  if (h >= 18 && h < 23) return '睡前';
  return '其他';
};

/** 测量时段候选（覆盖全部时段标签） */
const SLOT_HOURS = [6, 7, 8, 10, 12, 15, 16, 19, 21, 22, 1, 23];

const NOTES = [
  '服药后', '运动后', '晨起空腹', '午休后', '情绪波动后', '饮酒后', '睡眠不足',
  '感冒中', '复测', '含,逗号与"引号"', '换新血压计首测'
];

// ── 1. 生成血压记录 ─────────────────────────────────────────────
const BP_TOTAL = 4000;
const daysBack = Math.ceil(BP_TOTAL / 2.2) + 30; // 约 5 年
const today = new Date();
today.setHours(0, 0, 0, 0);
const startDay = new Date(today.getTime() - daysBack * 86400000);

const bpRows = [];
const bpTriples = new Set();

for (let i = 0; i < BP_TOTAL; i++) {
  // 从起点均匀铺开，避免全部堆在最近几天
  const dayOffset = Math.floor((i / BP_TOTAL) * daysBack);
  const day = new Date(startDay.getTime() + dayOffset * 86400000);

  const hour = SLOT_HOURS[Math.floor(rand() * SLOT_HOURS.length)];
  const minute = Math.floor(rand() * 60);
  const d = new Date(day.getFullYear(), day.getMonth(), day.getDate(), hour, minute, 0, 0);
  // 不能晚于现在
  const stamp = d.getTime() > Date.now() ? new Date(Date.now() - 60000) : d;

  const systolic = clamp(normal(135, 15), 105, 165);
  let diastolic = clamp(normal(85, 10), 60, 110);
  if (diastolic >= systolic) {
    diastolic = systolic - 10;
  }
  if (diastolic < 30) {
    diastolic = 30;
  }
  const hasHr = rand() > 0.12;
  const hr = hasHr ? clamp(normal(72, 8), 45, 120) : '';

  const key = `${stamp}_${systolic}_${diastolic}`;
  if (bpTriples.has(key)) {
    i--; // 极少数时间戳碰撞，重抽一条，保证文件内无重复
    continue;
  }
  bpTriples.add(key);

  const note = rand() < 0.15 ? NOTES[Math.floor(rand() * NOTES.length)] : '';
  bpRows.push({
    stamp: stamp,
    cells: [fmtDate(stamp), fmtTime(stamp), `${systolic}`, `${diastolic}`,
      hr === '' ? '' : `${hr}`, PERIOD_BY_HOUR(stamp.getHours()), note]
  });
}

bpRows.sort((a, b) => a.stamp - b.stamp);

// ── 2. 生成用药打卡记录 ─────────────────────────────────────────
const medSlots = [
  { name: '缬沙坦', dosage: '1片/80mg', hour: 7, minute: 30 },
  { name: '缬沙坦', dosage: '1片/80mg', hour: 18, minute: 0 },
  { name: '二甲双胍', dosage: '1片/0.5g', hour: 12, minute: 0 }
];
const medRows = [];
let takenCount = 0;
let skippedCount = 0;
let missedCount = 0;
let makeupCount = 0;

for (let dayOffset = 364; dayOffset >= 0; dayOffset--) {
  const dayBase = new Date(today.getTime() - dayOffset * 86400000);
  for (const slot of medSlots) {
    const scheduled = new Date(dayBase.getFullYear(), dayBase.getMonth(), dayBase.getDate(),
      slot.hour, slot.minute, 0, 0);
    if (scheduled.getTime() > Date.now()) {
      continue; // 未来时点不生成记录（与实际运行一致）
    }
    const roll = rand();
    let status = '已服用';
    let takenTime = '';

    if (roll < 0.9) {
      // 多数为准时服用；约 6% 为超过计划时间 2h 的补记（覆盖 CL-8 的补记分支）
      const late = rand() < 0.06
        ? 130 + Math.floor(rand() * 300)
        : Math.max(0, Math.floor(normal(4, 6)));
      const takenAt = new Date(scheduled.getTime() + late * 60000);
      if (takenAt.getTime() > scheduled.getTime() + 2 * 3600000) {
        status = '已服用(补记)';
        makeupCount++;
      } else {
        takenCount++;
      }
      takenTime = fmtTime(takenAt);
    } else if (roll < 0.94) {
      status = '跳过';
      skippedCount++;
    } else {
      status = '漏服';
      missedCount++;
    }

    medRows.push({
      stamp: scheduled.getTime(),
      cells: [fmtDate(scheduled), fmtTime(scheduled), slot.name, slot.dosage, status, takenTime,
        rand() < 0.08 ? '遵医嘱' : '']
    });
  }
}
medRows.sort((a, b) => a.stamp - b.stamp);

// ── 3. 生成脏数据 CSV（4000 行 = 有效 + 重复 + 错误，含故意的重复与错误） ──
const DIRTY_TOTAL = 4000;
const DIRTY_DUP = 110;
const DIRTY_ERR = 60;
const dirtyRows = [];
const dirtySeen = new Set();
let dirtyValid = 0;

const validPool = bpRows.map((r) => r.cells.slice());
const validTake = DIRTY_TOTAL - DIRTY_DUP - DIRTY_ERR; // 3830

// 3.1 有效行（文件内互不重复）
for (let i = 0; i < validTake && i < validPool.length; i++) {
  const cells = validPool[i];
  const key = `${bpRows[i].stamp}_${cells[2]}_${cells[3]}`;
  dirtySeen.add(key);
  dirtyRows.push(cells);
  dirtyValid++;
}

// 3.2 重复行：复制前面已出现过的有效行，判重键完全相同
for (let i = 0; i < DIRTY_DUP; i++) {
  const src = validPool[i % 1000];
  dirtyRows.push(src.slice());
}

// 3.3 错误行：6 类缺陷均匀分布，逐类验证错误分支
const errSpecs = [
  () => [fmtDate(today), fmtTime(today)],                                   // 列数不足
  () => ['2026-13-45', '08:00', '128', '82', '72', '晨起', '月份与日期非法'],   // 日期非法
  () => [fmtDate(today), '08:00', '350', '82', '72', '晨起', '收缩压越界'],     // 收缩压越界
  () => [fmtDate(today), '08:00', '128', '25', '72', '晨起', '舒张压越界'],     // 舒张压越界
  () => [fmtDate(today), '08:00', '100', '120', '72', '晨起', '收缩压小于舒张压'], // 大小关系非法
  () => [fmtDate(today), '08:00', 'abc', '82', '72', '晨起', '非数字']          // 非数字
];
for (let i = 0; i < DIRTY_ERR; i++) {
  dirtyRows.push(errSpecs[i % errSpecs.length]());
}

// 3.4 确定性洗牌：让错误行与重复行分散在文件中，避免集中在尾部
for (let i = dirtyRows.length - 1; i > 0; i--) {
  const j = Math.floor(rand() * (i + 1));
  const tmp = dirtyRows[i];
  dirtyRows[i] = dirtyRows[j];
  dirtyRows[j] = tmp;
}

// ── 4. 输出 ────────────────────────────────────────────────────
const csvEscape = (v) => {
  const s = `${v}`;
  return /[",\r\n]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s;
};
const toCsv = (header, rows, bom) =>
  (bom ? '\uFEFF' : '') + [header, ...rows].map((r) => r.map(csvEscape).join(',')).join('\r\n') + '\r\n';

mkdirSync(OUT, { recursive: true });

const BP_HEADER = ['日期', '时间', '收缩压(mmHg)', '舒张压(mmHg)', '心率(bpm)', '时段', '备注'];
const MED_HEADER = ['日期', '计划时间', '药品', '剂量', '状态', '实际打卡时间', '备注'];

writeFileSync(join(OUT, 'bp_4000.csv'),
  toCsv(BP_HEADER, bpRows.map((r) => r.cells), true), 'utf8');
writeFileSync(join(OUT, 'med_1100.csv'),
  toCsv(MED_HEADER, medRows.map((r) => r.cells), true), 'utf8');
writeFileSync(join(OUT, 'import_dirty_4000.csv'),
  toCsv(BP_HEADER, dirtyRows, true), 'utf8');

// 统计脏文件中实际的重复/错误条数（按 App 的判重规则复算）
const dupSet = new Set();
let realDup = 0;
let realErr = 0;
let realValid = 0;
for (const row of dirtyRows) {
  if (row.length < 4) {
    realErr++;
    continue;
  }
  const stamp = Date.parse(`${row[0]}T${row[1]}:00`);
  const sys = Number.parseInt(row[2], 10);
  const dia = Number.parseInt(row[3], 10);
  if (!Number.isFinite(stamp) || !Number.isFinite(sys) || !Number.isFinite(dia)
    || sys < 40 || sys > 300 || dia < 30 || dia > 200 || sys <= dia) {
    realErr++;
    continue;
  }
  const key = `${stamp}_${sys}_${dia}`;
  if (dupSet.has(key)) {
    realDup++;
    continue;
  }
  dupSet.add(key);
  realValid++;
}

writeFileSync(join(OUT, 'README.md'), `# 测试数据说明

由 \`node tools/gen-testdata.mjs\` 生成，使用固定随机种子，多次运行结果完全一致。

| 文件 | 用途 | 行数（不含表头） |
|---|---|---|
| \`bp_4000.csv\` | 血压记录容量与性能验证，格式与 App 导出完全一致 | ${bpRows.length} |
| \`med_1100.csv\` | 用药打卡半年~1 年记录，含漏服/跳过/补记混合状态 | ${medRows.length} |
| \`import_dirty_4000.csv\` | CSV 导入健壮性验证（含故意构造的重复行与错误行） | ${dirtyRows.length} |

## 灌入方式

三个文件都是 **UTF-8 带 BOM 的标准 CSV**，可直接通过 App 的
「设置 → 导入数据」选择文件导入，无需任何调试接口：

1. \`bp_4000.csv\` → 导入类型选「血压记录」
2. \`med_1100.csv\` → 导入类型选「用药打卡」
   （药品名无匹配时会自动创建**停用**档案且不建计划，符合 FR-6.7；
   如需带服药计划的完整数据，请在「用药管理」中补充计划）

## bp_4000.csv 数据特征

- 收缩压：正态分布 N(135, 15)，截断到 105–165 mmHg（符合策划文档 §9.6）
- 舒张压：正态分布 N(85, 10)，截断到 60–110 mmHg，且保证大于收缩压约束成立
- 时间跨度：约 ${Math.round(daysBack / 365 * 10) / 10} 年（${daysBack} 天），覆盖晨起/上午/下午/睡前/其他全部时段
- 心率：约 88% 的记录有心率值，其余留空（验证空心率路径）
- 备注：约 15% 的记录带备注，含逗号与引号（验证 CSV 转义）
- 文件内无重复行（按「测量时间 + 收缩压 + 舒张压」判重）

## med_1100.csv 数据特征

- 3 个时间点/天（07:30 缬沙坦、12:00 二甲双胍、18:00 缬沙坦）× 365 天
- 状态分布：准时服用 ${takenCount} 条、补记 ${makeupCount} 条、跳过 ${skippedCount} 条、漏服 ${missedCount} 条

## import_dirty_4000.csv 预期导入结果（CL-10 核对）

采用与 App 完全相同的判重与校验规则复算（\`tools/gen-testdata.mjs\` 内实现）：

| 项 | 预期值 |
|---|---|
| 数据行总数 | ${dirtyRows.length} |
| 有效（将入库） | ${realValid} |
| 重复（将跳过） | ${realDup} |
| 错误（将跳过，逐行给原因） | ${realErr} |

将 \`bp_4000.csv\` 导入一次后再原样导入一次，第二次应得到
**有效 0 条 / 重复 ${bpRows.length} 条 / 错误 0 条** —— 即幂等（CL-10）。
`, 'utf8');

console.log('生成完成 →', OUT);
console.log(`  bp_4000.csv              ${bpRows.length} 行`);
console.log(`  med_1100.csv             ${medRows.length} 行（准时 ${takenCount} / 补记 ${makeupCount} / 跳过 ${skippedCount} / 漏服 ${missedCount}）`);
console.log(`  import_dirty_4000.csv    ${dirtyRows.length} 行（有效 ${realValid} / 重复 ${realDup} / 错误 ${realErr}）`);
