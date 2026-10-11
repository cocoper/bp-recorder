#!/usr/bin/env node
// 真机验收批处理（审查 R20.2/R20.4/R20.5 的「门禁演练」脚本化）。
//
// 一条命令依次做：静态门禁 → 生产哨兵前快照 → 构建 → 安装测试 HAP → 跑 Hypium → 哨兵后快照并比对
// → 按 docs/验收卡模板.md 的口径打印结论。
//
// 两条铁律：
//   ① 没有设备时明确输出「未执行」，退出码 0 但**绝不**写成通过；
//   ② 破坏性用例只允许在审计包名（com.bp.recorder.audit）上跑；发现是生产包名时拒绝执行破坏性步骤。
//
// 用法：
//   node tools/device-batch.mjs --dry-run     # 只打印将执行的命令（离线可核对）
//   node tools/device-batch.mjs              # 真机执行（需要 USB + 解锁）
import { existsSync, readFileSync, writeFileSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { join } from 'node:path';
import { PROJECT_ROOT, NODE_BIN, hdcBin, hvigorwBin, hvigorNodeBin, javaHome, sdkHome, requireDeveco } from './toolchain.mjs';

const args = process.argv.slice(2);
const dryRun = args.includes('--dry-run');
const PROD = 'com.bp.recorder';
const AUDIT = 'com.bp.recorder.audit';
const TEST_MODULE = 'entry_test';
const steps = [];
let failed = 0;

function log(msg) {
  console.log(msg);
}
function step(name, status, detail) {
  steps.push({ name, status, detail });
  const icon = status === 'pass' ? '✓' : status === 'fail' ? '✗' : status === 'skip' ? '·' : '…';
  log(`${icon} ${name}${detail === undefined || detail === '' ? '' : ` —— ${detail}`}`);
  if (status === 'fail') failed++;
}
function run(cmd, cmdArgs, options = {}) {
  if (dryRun) {
    log(`   [dry-run] ${cmd} ${cmdArgs.join(' ')}`);
    return '';
  }
  try {
    return execFileSync(cmd, cmdArgs, { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'], ...options }).trim();
  } catch (err) {
    const out = `${err.stdout ?? ''}${err.stderr ?? ''}`.trim();
    throw new Error(`${cmd} ${cmdArgs.join(' ')} 失败：${out.split('\n').slice(-3).join(' / ')}`);
  }
}

log('================ 真机验收批处理 ================');
log(dryRun ? '模式：dry-run（只打印命令，不执行）' : '模式：真机执行');

// ── 0. 前置：包名与静态门禁 ──
const appJson = readFileSync(join(PROJECT_ROOT, 'BpRecorder/AppScope/app.json5'), 'utf8');
const bundle = (/"bundleName"\s*:\s*"([^"]+)"/.exec(appJson) || [])[1];
log(`\n当前 bundleName：${bundle}`);
if (bundle === PROD) {
  step('审计包名检查', 'skip', `当前是生产包名 ${PROD}：破坏性用例不会执行；如需完整演练先跑 node tools/make-audit-variant.mjs --apply`);
} else if (bundle === AUDIT) {
  step('审计包名检查', 'pass', `隔离包名 ${AUDIT}`);
} else {
  step('审计包名检查', 'fail', `未知包名 ${bundle}`);
}

try {
  run(NODE_BIN, [join(PROJECT_ROOT, 'tools/check-isolation.mjs')]);
  step('静态隔离门禁', 'pass', 'check-isolation 全绿');
} catch (err) {
  step('静态隔离门禁', 'fail', String(err.message).split('\n')[0]);
}

// ── 1. 设备探测 ──
let device = '';
try {
  requireDeveco('真机批处理');
  const hdc = hdcBin();
  device = run(hdc, ['list', 'targets']).split('\n')[0].trim();
  if (device === '' || device.includes('[Empty]')) {
    device = '';
  }
} catch (err) {
  step('设备探测', 'fail', String(err.message).split('\n')[0]);
}

if (device === '') {
  step('设备探测', 'skip', 'hdc list targets 返回空：本次**未执行**真机步骤（不等于通过）');
  log('\n================ 结论 ================');
  log('未执行：没有已连接设备。');
  log('设备就绪后重跑本命令即可；执行顺序见下方计划。');
  log('\n计划执行的步骤：');
  log('  1) 哨兵前快照   node tools/sentinel.mjs take --out /tmp/sentinel-before.json');
  log('  2) 构建         assembleHap（entry@default + entry@ohosTest）');
  log('  3) 安装测试包   hdc install -r <entry-ohosTest-signed.hap>');
  log(`  4) 跑 Hypium    hdc shell aa test -b ${bundle} -m ${TEST_MODULE} -s unittest OpenHarmonyTestRunner`);
  log('  5) 哨兵后比对   node tools/sentinel.mjs take --out /tmp/sentinel-after.json && compare');
  log('  6) 人工项       锁屏实际送达、分享/相册/PDF 接收端内容、出图尺寸 —— 按 docs/验收卡模板.md 记录');
  process.exit(0);
}

step('设备探测', 'pass', device);
const hdc = hdcBin();
const started = new Date().toISOString();

// ── 2. 哨兵前快照 ──
const before = '/tmp/sentinel-before.json';
try {
  run(NODE_BIN, [join(PROJECT_ROOT, 'tools/sentinel.mjs'), 'take', '--out', before]);
  step('哨兵前快照', 'pass', before);
} catch (err) {
  step('哨兵前快照', 'fail', String(err.message).split('\n')[0]);
}

// ── 3. 构建 ──
const hvigorArgs = (module) => ['--mode', 'module', '-p', `module=${module}`, '-p', 'product=default',
  '-p', 'requiredDeviceType=phone', 'assembleHap', '--analyze=normal', '--parallel', '--no-daemon'];
const env = { ...process.env, DEVECO_SDK_HOME: sdkHome(), JAVA_HOME: javaHome() };
for (const module of ['entry@default', 'entry@ohosTest']) {
  try {
    run(hvigorNodeBin(), [hvigorwBin(), ...hvigorArgs(module)], { cwd: join(PROJECT_ROOT, 'BpRecorder'), env });
    step(`构建 ${module}`, 'pass', '');
  } catch (err) {
    step(`构建 ${module}`, 'fail', String(err.message).split('\n')[0]);
  }
}

// ── 4. 安装测试包并跑 Hypium ──
const testHap = join(PROJECT_ROOT,
  'BpRecorder/entry/build/default/outputs/ohosTest/entry-ohosTest-signed.hap');
if (existsSync(testHap)) {
  try {
    run(hdc, ['-t', device, 'install', '-r', testHap]);
    step('安装测试 HAP', 'pass', testHap.split('/').slice(-1)[0]);
  } catch (err) {
    step('安装测试 HAP', 'fail', String(err.message).split('\n')[0]);
  }
  try {
    const out = run(hdc, ['-t', device, 'shell', 'aa', 'test', '-b', bundle, '-m', TEST_MODULE,
      '-s', 'unittest', 'OpenHarmonyTestRunner']);
    const okLine = /OK|success|passed/i.test(out);
    step('Hypium 端侧测试', okLine ? 'pass' : 'fail', `输出末尾：${out.split('\n').slice(-2).join(' / ')}`);
  } catch (err) {
    step('Hypium 端侧测试', 'fail', String(err.message).split('\n')[0]);
  }
} else {
  step('安装测试 HAP', 'fail', `找不到产物：${testHap}`);
}

// ── 5. 哨兵后快照 + 比对 ──
const after = '/tmp/sentinel-after.json';
try {
  run(NODE_BIN, [join(PROJECT_ROOT, 'tools/sentinel.mjs'), 'take', '--out', after]);
  const cmp = run(NODE_BIN, [join(PROJECT_ROOT, 'tools/sentinel.mjs'), 'compare', before, after]);
  const unchanged = /一致|same|OK/i.test(cmp);
  step('哨兵前后比对', unchanged ? 'pass' : 'fail', cmp.split('\n').slice(-2).join(' / '));
} catch (err) {
  step('哨兵前后比对', 'fail', String(err.message).split('\n')[0]);
}

// ── 6. 验收卡字段 ──
const finished = new Date().toISOString();
log('\n================ 验收卡字段（照抄到 docs/验收卡-*.md）================');
log(`包名        : ${bundle}`);
log(`设备        : ${device}`);
log(`开始 / 结束 : ${started} → ${finished}`);
log('版本 / 库名 : 见 node tools/check-version.mjs 输出（versionName/versionCode 与数据库名）');
log('\n未由本脚本覆盖、必须人工记录的项目：');
log('  · 后台定时代理提醒的**锁屏实际送达**（请求被接受 ≠ 送达）');
log('  · 有结束日期计划在结束后不再触发');
log('  · 分享 / 相册 / PDF 的**接收端内容完整**（面板打开 ≠ 内容有效）');
log('  · 出图尺寸、连续导出 30 次的内存与缓存曲线');
log('\n================ 结论 ================');
for (const s of steps) {
  log(`${s.status === 'pass' ? '✓' : s.status === 'fail' ? '✗' : '·'} ${s.name}${s.detail ? ` —— ${s.detail}` : ''}`);
}
if (failed > 0) {
  log(`\n有 ${failed} 步失败：这不是"部分通过"，请按上面输出定位。`);
  process.exit(1);
}
log('\n脚本覆盖的步骤全部通过；人工项仍需按验收卡逐条记录后才能声明真机验收通过。');
