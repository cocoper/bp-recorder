// 资源键一致性校验器。
//
// 职责：核对「代码引用的资源键」与「资源文件实际定义的键」双向一致：
//   1) 代码引用了但资源文件没有定义 → 运行时会报错，必须修掉；
//   2) 资源文件定义了但代码没用到 → 死资源，应清理。
// 同时校验 base 与 dark 的 color.json 键集合完全一致（否则深色模式下会缺色）。
//
// 用法：node tools/check-resources.mjs

import { existsSync, readFileSync, readdirSync, statSync } from 'node:fs';
import { dirname, join, resolve, extname } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = resolve(HERE, '..', 'BpRecorder');
/** 工程内有多个模块，各自持有自己的资源目录：main（应用本体）与 ohosTest（测试模块） */
const RES_ROOTS = [
  join(ROOT, 'entry', 'src', 'main', 'resources'),
  join(ROOT, 'entry', 'src', 'ohosTest', 'resources')
];

/** 递归收集文件（目录不存在时返回空，便于统一处理各模块可选目录） */
function walk(dir, filter, out = []) {
  if (!existsSync(dir)) {
    return out;
  }
  for (const name of readdirSync(dir)) {
    const p = join(dir, name);
    if (statSync(p).isDirectory()) {
      walk(p, filter, out);
    } else if (filter(p)) {
      out.push(p);
    }
  }
  return out;
}

// ── 1. 采集代码引用的键 ──────────────────────────────────────────
const codeFiles = walk(join(ROOT, 'entry', 'src'), (p) => extname(p) === '.ets' || p.endsWith('.json5'));
const referenced = { string: new Set(), color: new Set(), media: new Set() };
const re = /app\.(string|color|media)\.([A-Za-z0-9_]+)/g;
for (const f of codeFiles) {
  const text = readFileSync(f, 'utf8');
  let m;
  while ((m = re.exec(text)) !== null) {
    referenced[m[1]].add(m[2]);
  }
}

// ── 2. 采集资源文件定义的键（合并所有模块，并区分 main 模块用于深色对比） ──
function elementKeys(dir, kind) {
  const file = join(dir, 'element', `${kind}.json`);
  let raw;
  try {
    raw = readFileSync(file, 'utf8');
  } catch {
    return null;
  }
  const parsed = JSON.parse(raw);
  return new Set((parsed[kind] ?? []).map((e) => e.name));
}

const definedString = new Set();
const definedColorBase = new Set();
const definedColorDark = new Set();
const mediaFiles = new Set();
for (const res of RES_ROOTS) {
  for (const k of elementKeys(join(res, 'base'), 'string') ?? []) definedString.add(k);
  for (const k of elementKeys(join(res, 'base'), 'color') ?? []) definedColorBase.add(k);
  for (const k of elementKeys(join(res, 'dark'), 'color') ?? []) definedColorDark.add(k);
  for (const p of walk(join(res, 'base', 'media'), () => true)) {
    mediaFiles.add(p.split('/').pop().replace(/\.[^.]+$/, ''));
  }
}

// AppScope 有自己的资源目录
const appScopeRes = join(ROOT, 'AppScope', 'resources');
for (const k of elementKeys(join(appScopeRes, 'base'), 'string') ?? []) definedString.add(k);
for (const k of elementKeys(join(appScopeRes, 'base'), 'color') ?? []) definedColorBase.add(k);
for (const k of elementKeys(join(appScopeRes, 'dark'), 'color') ?? []) definedColorDark.add(k);
for (const p of walk(join(appScopeRes, 'base', 'media'), () => true)) {
  mediaFiles.add(p.split('/').pop().replace(/\.[^.]+$/, ''));
}

// json5 中的 $string / $color / $media（module.json5 / app.json5）
// 另需扫 resources/*/media/*.json —— 分层图标 layered_image.json 就是用
// "$media:background" / "$media:foreground" 引用两层图的，漏扫会把这两张图误报成死资源。
// 还需扫 resources/*/profile/*.json —— 卡片 form_config.json 用 "$string:xxx" 声明展示名与描述，
// 漏扫会把它们误报成「已定义但未使用」。
const refSources = walk(join(ROOT), (p) =>
  (p.endsWith('.json5')
    || /[/\\]media[/\\][^/\\]+\.json$/.test(p)
    || /[/\\]profile[/\\][^/\\]+\.json$/.test(p)) && !p.includes('/build/'));
for (const f of refSources) {
  const text = readFileSync(f, 'utf8');
  let m;
  const r = /\$(string|color|media):([A-Za-z0-9_]+)/g;
  while ((m = r.exec(text)) !== null) {
    referenced[m[1]].add(m[2]);
  }
}

// ── 3. 比对 ─────────────────────────────────────────────────────
let problems = 0;

function report(title, missing, unused) {
  if (missing.length > 0) {
    problems += missing.length;
    console.log(`\n✗ ${title}：引用了但未定义（${missing.length}）`);
    for (const k of missing.sort()) console.log(`    ${k}`);
  } else {
    console.log(`\n✓ ${title}：引用全部已定义`);
  }
  if (unused.length > 0) {
    problems += unused.length;
    console.log(`✗ ${title}：已定义但未使用（${unused.length}）`);
    for (const k of unused.sort()) console.log(`    ${k}`);
  } else {
    console.log(`✓ ${title}：无死资源`);
  }
}

const miss = (ref, def) => [...ref].filter((k) => !def.has(k));
const dead = (ref, def) => [...def].filter((k) => !ref.has(k));

console.log('检查范围：string/color/media 资源的定义-引用一致性、base 与 dark 的键对应、',
  'print_* / chart_* 配色族约束；不覆盖资源在真机上的最终渲染效果。');
console.log('================ 资源键一致性校验 ================');
console.log(`代码文件 ${codeFiles.length} 个，引用 string ${referenced.string.size} 个 / color ${referenced.color.size} 个 / media ${referenced.media.size} 个`);
console.log(`定义 string ${definedString.size} 个 / color(base) ${definedColorBase.size} 个 / color(dark) ${definedColorDark.size} 个 / media ${mediaFiles.size} 个`);

report('string', miss(referenced.string, definedString), dead(referenced.string, definedString));
report('color', miss(referenced.color, definedColorBase), dead(referenced.color, definedColorBase));
report('media', miss(referenced.media, mediaFiles), dead(referenced.media, mediaFiles));

// base / dark 颜色键必须一一对应
const darkMissing = [...definedColorBase].filter((k) => !definedColorDark.has(k));
const darkExtra = [...definedColorDark].filter((k) => !definedColorBase.has(k));
if (darkMissing.length > 0 || darkExtra.length > 0) {
  problems += darkMissing.length + darkExtra.length;
  console.log(`\n✗ base 与 dark 颜色键不一致：dark 缺少 ${JSON.stringify(darkMissing)}，dark 多出 ${JSON.stringify(darkExtra)}`);
} else {
  console.log(`✓ base 与 dark 颜色键一一对应（各 ${definedColorBase.size} 个）`);
}

// ── 3.5 图表双配色族 ────────────────────────────────────────────────────────
//
// 为什么单独校验：图表有两族配色（见 common/Constants.ChartScheme）。
//   print_* = 报告 / 打印用，base 与 dark **必须同值**（固定白底深字）；
//   chart_* = 手机看图用，**必须随主题变化**。
// 若哪天有人把 chart_* 也改成两套同值，深色模式下的图表会静默退回浅色外观 ——
// 既不会编译报错、也不会运行时报错，只能靠这条断言拦住。
console.log('\n---- 图表配色族：print_* 同值 / chart_* 异值 ----');

const MAIN_RES = join(ROOT, 'entry', 'src', 'main', 'resources');
const colorValues = (qualifier) => {
  const parsed = JSON.parse(readFileSync(join(MAIN_RES, qualifier, 'element', 'color.json'), 'utf8'));
  const m = new Map();
  for (const e of parsed.color ?? []) m.set(e.name, String(e.value).trim().toUpperCase());
  return m;
};
const cvBase = colorValues('base');
const cvDark = colorValues('dark');

// 允许两套同值的例外：气泡文字在两个主题下都是白字（底色一深一浅，白字都成立）
const CHART_SAME_ALLOWED = new Set(['chart_tooltip_text']);

const printDiff = [];
let printCount = 0;
for (const [name, baseVal] of cvBase) {
  if (!name.startsWith('print_')) {
    continue;
  }
  printCount++;
  if (cvDark.get(name) !== baseVal) {
    printDiff.push(`${name}(base=${baseVal}, dark=${cvDark.get(name)})`);
  }
}
if (printDiff.length > 0) {
  problems += printDiff.length;
  console.log(`✗ print_* 在 base / dark 取值不同（印刷配色必须两套完全一致）：${printDiff.join('、')}`);
} else {
  console.log(`✓ print_* ${printCount} 个键在 base / dark 取值完全一致（印刷配色不随主题变化）`);
}

const chartSame = [];
let chartCount = 0;
for (const [name, baseVal] of cvBase) {
  if (!name.startsWith('chart_')) {
    continue;
  }
  chartCount++;
  if (CHART_SAME_ALLOWED.has(name)) {
    continue;
  }
  if (cvDark.get(name) === baseVal) {
    chartSame.push(name);
  }
}
const chartUnknown = [...CHART_SAME_ALLOWED].filter((k) => !cvBase.has(k));
if (chartCount === 0) {
  problems += 1;
  console.log('✗ 未找到 chart_* 颜色键 —— 跟随主题的图表配色族缺失');
} else if (chartSame.length > 0) {
  problems += chartSame.length;
  console.log(`✗ 以下 chart_* 键 base / dark 同值，深色模式下不会变化：${JSON.stringify(chartSame)}`);
} else {
  console.log(`✓ chart_* ${chartCount} 个键随主题取值不同（其中 ${CHART_SAME_ALLOWED.size} 个为例外，已登记）`);
}
if (chartUnknown.length > 0) {
  problems += chartUnknown.length;
  console.log(`✗ 登记的例外键在资源中不存在：${JSON.stringify(chartUnknown)}`);
}

// ── 4. 外部来源导入：列角色别名资源的结构校验 ─────────────────────
//
// 为什么单独校验：`GenericImportService.ColRole` 枚举、`ImportAliasRes.ORDER` 数组、
// `imp_role_names` / `imp_alias_*` 资源三者的**顺序必须严格一致**（代码按下标直接取值），
// 任何一处增删角色而忘记同步其余两处，都会造成「列识别张冠李戴」这类静默错误。
// 这类错误不会有任何编译/运行时报错，只能靠这条结构断言拦住。
console.log('\n---- 外部来源导入：列角色资源结构 ----');

const ROLE_COUNT = 17;
const mainStringJson = join(ROOT, 'entry', 'src', 'main', 'resources', 'base', 'element', 'string.json');
const stringTable = new Map(
  (JSON.parse(readFileSync(mainStringJson, 'utf8')).string ?? []).map((e) => [e.name, e.value]));

const splitGroups = (v) => String(v).split('|').map((s) => s.trim()).filter((s) => s.length > 0);

const roleNames = stringTable.get('imp_role_names');
const nameParts = roleNames === undefined ? [] : splitGroups(roleNames);
if (nameParts.length !== ROLE_COUNT) {
  problems += 1;
  console.log(`✗ imp_role_names：应有 ${ROLE_COUNT} 项，实际 ${nameParts.length} 项`);
} else {
  console.log(`✓ imp_role_names：${ROLE_COUNT} 项，与 ColRole 角色数一致`);
}
const emptyNames = nameParts.filter((s) => s.length === 0).length;
if (emptyNames > 0) {
  problems += emptyNames;
  console.log(`✗ imp_role_names 存在 ${emptyNames} 个空项`);
}

const aliasKeys = [...stringTable.keys()].filter((k) => k.startsWith('imp_alias_')).sort();
if (aliasKeys.length !== ROLE_COUNT) {
  problems += 1;
  console.log(`✗ imp_alias_* 资源应有 ${ROLE_COUNT} 个，实际 ${aliasKeys.length} 个：${aliasKeys.join(', ')}`);
} else {
  console.log(`✓ imp_alias_* 资源 ${ROLE_COUNT} 个，与 ColRole 角色数一致`);
}
for (const k of aliasKeys) {
  const parts = splitGroups(stringTable.get(k));
  if (parts.length === 0) {
    problems += 1;
    console.log(`✗ ${k}：没有任何别名`);
  }
}

// 代码侧引用数量必须与资源数量一致（顺序由 .ets 中的书写顺序决定，由 parity 用例锁定角色语义）
const constantsSrc = readFileSync(join(ROOT, 'entry', 'src', 'main', 'ets', 'common', 'Constants.ets'), 'utf8');
const orderBlock = constantsSrc.slice(constantsSrc.indexOf('static readonly ORDER'));
const orderRefs = [...orderBlock.matchAll(/app\.string\.(imp_alias_[A-Za-z0-9_]+)/g)].map((m) => m[1]);
if (orderRefs.length !== ROLE_COUNT) {
  problems += 1;
  console.log(`✗ ImportAliasRes.ORDER 引用了 ${orderRefs.length} 个别名资源，应为 ${ROLE_COUNT} 个`);
} else {
  console.log(`✓ ImportAliasRes.ORDER 引用 ${orderRefs.length} 个别名资源`);
}
const orderSet = new Set(orderRefs);
const notReferenced = aliasKeys.filter((k) => !orderSet.has(k));
if (notReferenced.length > 0) {
  problems += notReferenced.length;
  console.log(`✗ 定义了但未在 ORDER 中引用的别名资源：${notReferenced.join(', ')}`);
}

// 状态别名组：五个状态各一组，且不得为空
const statusKeys = ['imp_status_taken', 'imp_status_skipped', 'imp_status_missed', 'imp_status_pending', 'imp_status_makeup'];
for (const k of statusKeys) {
  const parts = splitGroups(stringTable.get(k) ?? '');
  if (parts.length === 0) {
    problems += 1;
    console.log(`✗ ${k}：没有任何别名`);
  }
}
console.log(`✓ 状态别名组 ${statusKeys.length} 组均已定义且非空`);

console.log(`\n================ 结论 ================`);
console.log(problems === 0 ? '全部一致。' : `发现 ${problems} 处不一致，需修正。`);
process.exit(problems === 0 ? 0 : 1);
