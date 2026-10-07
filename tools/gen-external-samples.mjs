// 生成「外部来源」导入样例数据。
//
// 用途：验证「导入数据 → 其他来源」这条路径（FR-6.11）。
// 这批文件刻意模仿**其他 App / 血压计软件 / 手写表格**的导出格式：
// 列名和列序与本 App 不同、日期写法各异、血压可能只有一列、数值单位可能是 kPa。
//
// 与 gen-testdata.mjs 的分工：
//   - gen-testdata.mjs 生成**本 App 自家格式**的大数据量文件（性能与往返幂等用）；
//   - 本脚本生成**外部格式**的小文件（列识别与容错解析用），产物在 testdata/external/。
//
// 用法：node tools/gen-external-samples.mjs

import { execFileSync } from 'node:child_process';
import { mkdirSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const PROJECT_ROOT = resolve(HERE, '..');
const OUT = join(PROJECT_ROOT, 'tools', 'testdata', 'external');

const BOM = '\uFEFF';
const nl = '\r\n';

/** 每个样例文件：文件名 → { 说明, 内容, 预期 } */
const FILES = [
  {
    name: 'ext_1_alt_headers.csv',
    title: '其他 App 风格表头（列名同义但不同、日期用斜杠、心率有留空）',
    kind: '血压记录',
    expect: '识别为血压记录；6 行全部有效',
    content: [
      '测量日期,测量时间,高压,低压,脉搏,备注',
      '2026/9/28,6:35,132,86,74,起床后',
      '2026/9/29,12:10,128,82,,午休前',
      '2026/9/30,15:40,145,92,88,爬楼后',
      '2026/10/1,21:40,138,88,76,睡前',
      '2026/10/2,7:05,121,79,70,服药后',
      '2026/10/3,23:10,126,81,,加班到家'
    ].join(nl)
  },
  {
    name: 'ext_2_single_column.csv',
    title: '单列血压 + 无表头 + 斜杠日期',
    kind: '血压记录',
    expect: '无表头，按列内容识别出日期/时间/血压组合值；5 行全部有效',
    content: [
      '2026-10-01,06:30,132/86',
      '2026-10-02,12:10,128/82(70)',
      '2026-10-03,15:20,145/92(88)',
      '2026-10-04,21:40,138/88',
      '2026-10-05,07:05,121/79(70)'
    ].join(nl)
  },
  {
    name: 'ext_3_kpa.csv',
    title: '数值单位为 kPa（带小数，需换算为 mmHg）',
    kind: '血压记录',
    expect: '按数值量级自动判定为 kPa 并换算；4 行全部有效',
    content: [
      '日期,时间,收缩压(kPa),舒张压(kPa),心率(bpm)',
      '2026-10-01,06:30,16.8,10.5,74',
      '2026-10-02,12:10,17.1,10.9,72',
      '2026-10-03,15:20,19.3,12.3,88',
      '2026-10-04,21:40,18.4,11.7,76'
    ].join(nl)
  },
  {
    name: 'ext_4_datetime_merged.csv',
    title: '日期与时间合并在同一列 + 额外无关列',
    kind: '血压记录',
    expect: '识别为「日期时间」合并列，忽略无关列；4 行全部有效',
    content: [
      '设备型号,记录时间,收缩压,舒张压,心率,测量位置',
      'OMRON HEM-7361T,2026-10-01 06:30:00,132,86,74,左臂',
      'OMRON HEM-7361T,2026-10-02 12:10:00,128,82,,左臂',
      'OMRON HEM-7361T,2026-10-03 15:20:00,145,92,88,右臂',
      'OMRON HEM-7361T,2026-10-04 21:40:00,138,88,76,左臂'
    ].join(nl)
  },
  {
    name: 'ext_5_date_only.csv',
    title: '只有日期没有时间（时间统一记为 00:00）',
    kind: '血压记录',
    expect: '识别出「无时间列」并在预览中提示；3 行全部有效，测量时间均为 00:00',
    content: [
      '日期,高压,低压',
      '2026-10-01,132,86',
      '2026-10-02,128,82',
      '2026-10-03,145,92'
    ].join(nl)
  },
  {
    name: 'ext_6_dirty_rows.csv',
    title: '含错误行（日期不存在 / 时间非法 / 收缩压小于舒张压 / 缺日期）',
    kind: '血压记录',
    expect: '2 行有效，4 行被逐行隔离并给出原因，不中断整批',
    content: [
      '日期,时间,收缩压,舒张压',
      '2026-10-01,6:30,132,86',
      '2026-02-30,6:30,132,86',
      '2026-10-03,25:00,132,86',
      '2026-10-04,6:30,86,132',
      ',6:30,132,86',
      '2026-10-06,7:15,124,80'
    ].join(nl)
  },
  {
    name: 'ext_7_med_alt.csv',
    title: '用药打卡的外部写法（已服 / 漏服 / 已服(补记)）',
    kind: '用药打卡',
    expect: '识别为用药打卡；6 行全部有效，药品无档案时自动建档（停用、不建计划）',
    content: [
      '日期,时间,药品,剂量,状态,实际打卡时间',
      '2026/9/28,07:30,缬沙坦,1片,已服,07:32',
      '2026/9/28,18:00,缬沙坦,1片,漏服,',
      '2026/9/29,07:30,缬沙坦,1片,已服(补记),09:05',
      '2026/9/29,18:00,缬沙坦,1片,已服,18:04',
      '2026/9/30,07:30,二甲双胍,0.5g,已服,07:40',
      '2026/9/30,18:00,二甲双胍,0.5g,已服,'
    ].join(nl)
  },
  {
    name: 'ext_8_plan_like.csv',
    title: '用药计划列结构（应被识别为用药计划并提示改用「用药计划」类型）',
    kind: '用药计划',
    expect: '识别为用药计划；导入按钮置灰，提示改用上方「用药计划」类型',
    content: [
      '药品,剂量,每日次数,时间点,开始日期,结束日期,备注',
      '缬沙坦,1片,2,07:30;18:00,2026-10-01,,长期',
      '二甲双胍,0.5g,1,12:00,2026-10-01,2026-12-31,随餐'
    ].join(nl)
  },
  {
    name: 'ext_9_gbk_ansi.csv',
    title: 'GBK / ANSI 编码（Windows 版 Excel 另存为 CSV 的默认编码）',
    kind: '血压记录',
    expect: '读取时自动识别为 GBK 并正确解码，中文表头不乱码；5 行全部有效',
    gbk: true,
    content: [
      '日期,时间,高压,低压,心率',
      '2026/10/01,06:30,132,86,74',
      '2026/10/02,12:10,128,82,72',
      '2026/10/03,15:20,145,92,88',
      '2026/10/04,21:40,138,88,76',
      '2026/10/05,07:05,121,79,70'
    ].join(nl)
  }
];

mkdirSync(OUT, { recursive: true });

let gbkOk = false;
for (const f of FILES) {
  if (f.gbk === true) {
    // Windows 版 Excel「另存为 CSV」默认落在系统 ANSI 代码页（简体中文即 GBK），
    // 且**不带 BOM**。这里用系统 iconv 生成，并立刻回转校验，确保样例本身没被转坏。
    try {
      const bytes = execFileSync('iconv', ['-f', 'UTF-8', '-t', 'GBK'],
        { input: Buffer.from(f.content + nl, 'utf8') });
      writeFileSync(join(OUT, f.name), bytes);
      const back = execFileSync('iconv', ['-f', 'GBK', '-t', 'UTF-8'], { input: bytes }).toString('utf8');
      if (back !== f.content + nl) {
        throw new Error('GBK 回转校验不一致，样例已丢弃');
      }
      gbkOk = true;
    } catch (err) {
      console.warn(`  ⚠ 跳过 ${f.name}：${err.message}`);
    }
    continue;
  }
  // 与自家导出一致：UTF-8 带 BOM，Excel 双击不乱码
  writeFileSync(join(OUT, f.name), BOM + f.content + nl, 'utf8');
}

const readme = `# 外部来源导入样例（tools/testdata/external/）

用于验证 App 的 **「导入数据 → 其他来源」** 路径（它容忍列名、列序、日期写法、
数值单位的差异）。这批文件刻意模仿其他 App / 血压计软件 / 手写表格的导出格式，
与 \`../bp_4000.csv\` 那批**自家格式**文件不是一回事。

使用方式：把文件传到手机（或放到手机可访问的位置），
打开 App →（设置）→ 导入数据 → 选「**其他来源**」 → 选择文件 →
核对页面上的「识别结果」与「前 5 行预览」 → 确认导入。

| 文件 | 覆盖的场景 | 期望结果 |
|---|---|---|
${FILES.map((f) => `| \`${f.name}\` | ${f.title} | ${f.expect} |`).join('\n')}

## 关键交互点清单

| 检查项 | 期望 |
|---|---|
| \`ext_1_alt_headers.csv\` | 「识别为：血压记录」，必需的列都已识别；导入 6 条 |
| \`ext_2_single_column.csv\` | 无表头也能识别；\`128/82(70)\` 的括号被当作心率 |
| \`ext_3_kpa.csv\` | 页面显示「数值单位：kPa（已按 1 kPa ≈ 7.5 mmHg 换算为整数）」 |
| \`ext_4_datetime_merged.csv\` | 额外的「设备型号」列不参与血压导入；「测量位置」会被认成备注列，可在「调整列对应」中改为「不使用该列」 |
| \`ext_5_date_only.csv\` | 显示「文件中没有时间列，导入后测量时间统一记为 00:00」 |
| \`ext_6_dirty_rows.csv\` | 「有效 2 / 错误 4」，错误明细逐行给出行号与原因 |
| \`ext_7_med_alt.csv\` | 目标种类需切到「用药打卡」；结果页列出自动建档的药品名 |
| \`ext_8_plan_like.csv\` | 识别为「用药计划」，确认按钮不可点，并提示改用「用药计划」类型 |
| \`ext_9_gbk_ansi.csv\` | **GBK 编码**（Windows Excel 另存 CSV 的默认编码，无 BOM）：中文表头应正常显示、不乱码 |

## 编码说明

- \`ext_1\`–\`ext_8\` 是 **UTF-8 带 BOM**（与本 App 自家导出相同，Excel 双击不乱码）。
- \`ext_9_gbk_ansi.csv\` 是 **GBK 且无 BOM**，用来验证读取端会先按 UTF-8 严格试解、
  失败后回落 GB18030。${gbkOk ? '' : '\n  > 注意：本次生成时系统缺少 `iconv`，该文件**未生成**。'}

如果 \`ext_9\` 的中文表头显示为乱码，说明编码回落没有生效 ——
但请注意：日期与数值都是 ASCII，**即使表头乱码，列识别仍能靠「列内容画像」认出各列**，
所以这类文件通常照样能导入成功（可直接用「调整列对应」确认识别结果）。

## 幂等性检查

同一文件导入两次：第二次应显示「有效 0 条 / 重复 N 条 / 错误 0 条」，
即判重键与导入成功的数据完全一致（不会重复入库）。

重新生成：\`node tools/gen-external-samples.mjs\`
`;

writeFileSync(join(OUT, 'README.md'), readme, 'utf8');

console.log('生成完成 →', OUT);
for (const f of FILES) {
  console.log(`  ${f.name.padEnd(32)} ${f.content.split(nl).length} 行  ${f.title}`);
}
