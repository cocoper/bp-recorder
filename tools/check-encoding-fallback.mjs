// 编码自适应回落校验（FR-6.11）。
//
// 背景：Windows 版 Excel「另存为 CSV」默认落在系统 ANSI 代码页（简体中文即 GBK），
// 且不带 BOM。`FileService.readText` 的策略是「先 UTF-8 严格解，失败再回落 GB18030」。
// 该策略在真机上依赖 `util.TextDecoder`，本机无法直接执行 ArkTS，
// 于是这里用**同一套编码库（Node 的 ICU TextDecoder）** 对真实样例文件复现该决策，
// 验证：GBK 文件确实会被 UTF-8 严格解码拒绝、而被 GB18030 接受；
// UTF-8 文件则在第一步就成功，不会误判。
//
// 与源实现的差异（如实登记）：本脚本是**检查器**，重写了那三行决策逻辑；
// 若将来改动 FileService 的编码顺序，必须同步改这里，否则检查会失真。
//
// 用法：node tools/check-encoding-fallback.mjs

import { readFileSync, existsSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const EXT = join(HERE, 'testdata', 'external');

let problems = 0;
function check(ok, name, extra) {
  if (ok) {
    console.log(`  ✓ ${name}`);
  } else {
    problems += 1;
    console.log(`  ✗ ${name}${extra ? `  ← ${extra}` : ''}`);
  }
}

/** 与 FileService.decodeAdaptive 一致的决策：UTF-8 严格 → GB18030 严格 → UTF-8 放宽 */
function decodeAdaptive(bytes) {
  for (const enc of ['utf-8', 'gb18030']) {
    try {
      const text = new TextDecoder(enc, { fatal: true }).decode(bytes);
      return { text, encoding: enc };
    } catch {
      // 继续尝试下一种编码
    }
  }
  return { text: new TextDecoder('utf-8').decode(bytes), encoding: 'utf-8(lenient)' };
}

function strictOk(bytes, enc) {
  try {
    new TextDecoder(enc, { fatal: true }).decode(bytes);
    return true;
  } catch {
    return false;
  }
}

console.log('================ 编码自适应回落校验 ================');

// ── 1. 反证：先把检查器自身证明有效 ──
console.log('\n[反证] 检查器有效性：故意用错编码时应当失败');
{
  const gbkPath = join(EXT, 'ext_9_gbk_ansi.csv');
  if (existsSync(gbkPath)) {
    const bytes = readFileSync(gbkPath);
    check(strictOk(bytes, 'utf-8') === false, 'GBK 样例在 UTF-8 严格解码下**确实失败**（否则本检查无意义）');
    check(strictOk(bytes, 'gb18030') === true, 'GBK 样例在 GB18030 严格解码下成功');
  } else {
    console.log('  (ext_9_gbk_ansi.csv 不存在，跳过 —— 生成它需要系统 iconv)');
  }
}

// ── 2. 正证：UTF-8 文件的决策路径 ──
console.log('\n[正证] UTF-8 带 BOM 文件');
{
  const p = join(EXT, 'ext_1_alt_headers.csv');
  const bytes = readFileSync(p);
  const r = decodeAdaptive(bytes);
  check(r.encoding === 'utf-8', 'ext_1 在第一步即按 UTF-8 解出，不发生回落', r.encoding);
  // TextDecoder 的 ignoreBOM 默认为 false，按规范此时 BOM 会被**消费掉**（不是保留）。
  // 因此解码结果里不应残留 U+FEFF；Csv.parse 里的剥 BOM 是兜底，不是必要条件。
  check(r.text.charCodeAt(0) !== 0xFEFF, 'ext_1 解码结果开头不残留 BOM（已由解码器按默认行为消费）');
  check(r.text.startsWith('测量日期'), 'ext_1 首个表头单元格直接是「测量日期」（无 BOM 残留）');
  check(r.text.includes('测量日期') && r.text.includes('高压'), 'ext_1 中文表头完好');
}

// ── 3. 正证：GBK 文件的决策路径 ──
console.log('\n[正证] GBK / ANSI 文件（Windows Excel 另存 CSV 的默认编码）');
{
  const p = join(EXT, 'ext_9_gbk_ansi.csv');
  if (existsSync(p)) {
    const bytes = readFileSync(p);
    check(bytes[0] !== 0xEF && bytes[1] !== 0xBB, 'ext_9 不带 UTF-8 BOM');
    const r = decodeAdaptive(bytes);
    check(r.encoding === 'gb18030', 'ext_9 经回落按 GB18030 解出', r.encoding);
    check(r.text.includes('日期') && r.text.includes('高压') && r.text.includes('心率'),
      'ext_9 中文表头解码正确（乱码时这里会失败）');
    check(!r.text.includes('\uFFFD'), 'ext_9 不含替换字符 U+FFFD');
    check(r.text.split('\n').filter((l) => l.trim().length > 0).length === 6,
      'ext_9 行数正确（1 表头 + 5 数据）');
  } else {
    console.log('  (ext_9_gbk_ansi.csv 不存在，跳过)');
  }
}

console.log(`\n================ 结论 ================`);
console.log(problems === 0
  ? '编码回落决策与样例文件一致。'
  : `发现 ${problems} 处不一致，需修正。`);
process.exit(problems === 0 ? 0 : 1);
