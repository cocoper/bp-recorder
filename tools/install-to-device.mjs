// 真机安装助手（含「签名档案是否包含该设备」的前置检查）。
//
// 为什么需要它：鸿蒙的**调试签名包只能装到签名档案（Profile）里登记过 UDID 的设备**。
// 在 DevEco 里勾选「自动签名」时，IDE 会把**当时连着的那台设备**写进 Profile ——
// 所以「只连了模拟器就做了签名」是最容易踩的坑：包能装模拟器，装手机必然失败，
// 而报错只有一句 `9568332 install sign info inconsistent` / `9568322 signature verification failed`，
// 完全看不出根因是"设备没登记"。
//
// 本工具把这三件事一次做完：
//   1. 列出当前 hdc 能看到的设备，并判断每台是**真机**还是**模拟器**；
//   2. 读出 `build-profile.json5` 指向的签名档案里**已登记的 UDID 列表**，与设备逐一比对；
//   3. 对「已登记」的设备执行安装（默认装真机；不猜，多台时必须显式指定）。
//
// 用法：
//   node tools/install-to-device.mjs --list                  # 只做检查，不安装
//   node tools/install-to-device.mjs                         # 唯一已登记设备时直接安装
//   node tools/install-to-device.mjs --target=<hdc 目标>      # 指定设备（多台时必填）
//   node tools/install-to-device.mjs --build                 # 先编译出已签名 HAP 再安装
//   node tools/install-to-device.mjs --hap=<路径>             # 指定 HAP
//   node tools/install-to-device.mjs --profile=<路径>         # 诊断用：改用指定的档案做登记检查
//
// 退出码：0 成功；1 前置条件不满足（设备未连接 / 设备未登记 / 产物缺失）；2 安装失败。

import { execFileSync } from 'node:child_process';
import { existsSync, readFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const PROJECT_ROOT = resolve(HERE, '..');
const PROJECT = join(PROJECT_ROOT, 'BpRecorder');
const DEFAULT_HAP = join(PROJECT, 'entry', 'build', 'default', 'outputs', 'default', 'entry-default-signed.hap');
const DEVECO = process.env.DEVECO_HOME ?? '/Volumes/ZT700-Data/Applications/DevEco-Studio.app/Contents';
const HDC = process.env.HDC_BIN ?? join(DEVECO, 'sdk', 'default', 'openharmony', 'toolchains', 'hdc');

const args = process.argv.slice(2);
const flag = (name) => args.includes(`--${name}`);
const opt = (name) => {
  const hit = args.find((a) => a.startsWith(`--${name}=`));
  return hit === undefined ? undefined : hit.slice(name.length + 3);
};

function run(cmd, cmdArgs, options = {}) {
  try {
    return { ok: true, out: execFileSync(cmd, cmdArgs, { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'], ...options }) };
  } catch (err) {
    return { ok: false, out: `${err.stdout ?? ''}${err.stderr ?? ''}${err.message ?? ''}` };
  }
}

function preflight() {
  if (!existsSync(HDC)) {
    console.error(`✗ 找不到 hdc：${HDC}`);
    console.error('  用 HDC_BIN=/path/to/hdc 指定，或 HDC_BIN=$(which hdc)。');
    process.exit(1);
  }
}

/** 列出 hdc 目标；返回 [{ id, kind, model, udid }] */
function listDevices() {
  const res = run(HDC, ['list', 'targets']);
  const lines = res.out.split('\n').map((l) => l.trim()).filter((l) => l.length > 0);
  const ids = lines.filter((l) => !l.startsWith('[') && l !== '[Empty]');
  return ids.map((id) => {
    const model = (run(HDC, ['-t', id, 'shell', 'param', 'get', 'const.product.model']).out ?? '').trim();
    const brand = (run(HDC, ['-t', id, 'shell', 'param', 'get', 'const.product.brand']).out ?? '').trim();
    // device-ids 与 UDID 都是 64 位十六进制
    const udidOut = run(HDC, ['-t', id, 'shell', 'bm', 'get', '--udid']).out ?? '';
    const m = udidOut.match(/[0-9A-Fa-f]{32,64}/);
    const emulator = /emulator/i.test(model) || id.startsWith('127.0.0.1:') || id === 'localhost';
    return {
      id,
      kind: emulator ? '模拟器' : '真机',
      emulator,
      model: model.length > 0 ? `${brand} ${model}`.trim() : '(未知机型)',
      udid: m === null ? null : m[0].toUpperCase()
    };
  });
}

/** 从 build-profile.json5 里取出签名档案（.p7b）路径 */
function readProfilePath() {
  const raw = readFileSync(join(PROJECT, 'build-profile.json5'), 'utf8');
  // json5 允许注释与尾逗号：这里只需抽出路径，用正则足够，避免引入 json5 依赖
  const certs = [...raw.matchAll(/"profile"\s*:\s*"([^"]+)"/g)].map((m) => m[1]);
  return certs.length > 0 ? certs[0] : null;
}

/** 从 PKCS#7（.p7b）中抽出档案 JSON，读已登记的 device-ids */
function readRegisteredUdids(profilePath) {
  const buf = readFileSync(profilePath);
  // 档案 JSON 在 DER 中是一段连续的可见 ASCII，取所有可见字符后正则抽取
  const ascii = buf.toString('latin1').replace(/[^\x20-\x7e]/g, '');
  const m = ascii.match(/"device-ids"\s*:\s*\[([^\]]*)\]/);
  if (m === null) {
    return { ok: false, ids: [], bundleName: null, type: null };
  }
  const ids = [...m[1].matchAll(/"([0-9A-Fa-f]{16,})"/g)].map((x) => x[1].toUpperCase());
  const bundle = ascii.match(/"bundle-name"\s*:\s*"([^"]+)"/);
  const type = ascii.match(/"type"\s*:\s*"([^"]+)"/);
  const notBefore = ascii.match(/"not-before"\s*:\s*(\d+)/);
  const notAfter = ascii.match(/"not-after"\s*:\s*(\d+)/);
  return {
    ok: true,
    ids,
    bundleName: bundle === null ? null : bundle[1],
    type: type === null ? null : type[1],
    notBefore: notBefore === null ? null : Number(notBefore[1]) * 1000,
    notAfter: notAfter === null ? null : Number(notAfter[1]) * 1000
  };
}

const fmtDate = (ms) => (ms === null ? '?' : new Date(ms).toISOString().slice(0, 10));

function buildSignedHap() {
  console.log('→ 正在编译已签名 HAP …');
  const env = {
    ...process.env,
    DEVECO_SDK_HOME: join(DEVECO, 'sdk'),
    JAVA_HOME: join(DEVECO, 'jbr', 'Contents', 'Home')
  };
  env.PATH = `${join(env.JAVA_HOME, 'bin')}:${env.PATH}`;
  const res = run(join(DEVECO, 'tools', 'node', 'bin', 'node'), [
    join(DEVECO, 'tools', 'hvigor', 'bin', 'hvigorw.js'),
    '--mode', 'module', '-p', 'module=entry@default', '-p', 'product=default',
    '-p', 'requiredDeviceType=phone', 'assembleHap', '--analyze=normal', '--parallel', '--no-daemon'
  ], { cwd: PROJECT, env });
  const tail = res.out.split('\n').filter((l) => /BUILD|Error Message|skip sign/.test(l));
  console.log(tail.map((l) => `  ${l.trim()}`).join('\n'));
  return res.ok && existsSync(DEFAULT_HAP);
}

// ── 主流程 ──
preflight();

console.log('================ 真机安装助手 ================');

const devices = listDevices();
if (devices.length === 0) {
  console.error('\n✗ hdc 没有看到任何设备。');
  console.error('  手机侧：设置 → 关于手机 → 连点「版本号」7 次开启开发者模式，');
  console.error('          再到 系统与更新 → 开发人员选项 → 打开「USB 调试」；');
  console.error('          用**能传数据**的 USB 线连接，手机上弹「是否允许 USB 调试」时点允许。');
  console.error('  然后用 `hdc list targets` 确认真能看到设备序列号（只插上线不算数）。');
  process.exit(1);
}

const profilePath = opt('profile') ?? readProfilePath();
if (profilePath === null) {
  console.error('\n✗ build-profile.json5 里没有 signingConfigs.material.profile —— 说明尚未配置签名。');
  console.error('  请在 DevEco 中 File → Project Structure → Signing Configs 勾选「自动签名」并 Apply。');
  process.exit(1);
}
if (!existsSync(profilePath)) {
  console.error(`\n✗ 签名档案不存在：${profilePath}`);
  console.error('  说明签名材料被移动/删除（例如换机或清理过 ~/.ohos/config），需在 DevEco 重新自动签名。');
  process.exit(1);
}

const profile = readRegisteredUdids(profilePath);
console.log(`\n签名档案：${profilePath.split('/').pop()}`);
if (profile.ok) {
  console.log(`  类型 ${profile.type ?? '?'}｜bundle ${profile.bundleName ?? '?'}｜` +
    `有效期 ${fmtDate(profile.notBefore)} → ${fmtDate(profile.notAfter)}`);
  console.log(`  已登记设备数：${profile.ids.length}`);
} else {
  console.log('  无法从档案中解析 device-ids（档案格式可能已变），下面的登记判断将不可靠。');
}

console.log('\n当前 hdc 可见设备：');
let installable = [];
for (const d of devices) {
  const registered = d.udid !== null && profile.ok && profile.ids.includes(d.udid);
  if (registered) {
    installable.push(d);
  }
  const mark = registered ? '✓ 已登记，可安装' : '✗ 未登记，装不上';
  console.log(`  [${d.kind}] ${d.id}  ${d.model}`);
  console.log(`       UDID ${d.udid ?? '(读不到)'}  → ${mark}`);
}

if (installable.length === 0) {
  console.error('\n✗ 当前连接的设备**都不在签名档案里**，安装必然失败（会报 9568332 / 9568322）。');
  console.error('  根因：DevEco 自动签名只登记「签名那一刻连着的设备」。');
  console.error('  修法：把手机用 USB 连好并让 hdc 真正识别 → 到 DevEco 里');
  console.error('        File → Project Structure → Signing Configs → 重新勾选「自动签名」→ Apply；');
  console.error('        或直接在 DevEco 顶部设备下拉里选中手机后点 ▶ Run（IDE 会自动补签名并安装）。');
  process.exit(1);
}

if (flag('list')) {
  console.log('\n(--list：仅检查，未执行安装)');
  process.exit(0);
}

// 目标选择：显式指定 > 唯一可装真机 > 唯一可装设备（多台时不猜）
let target;
const explicit = opt('target');
if (explicit !== undefined) {
  target = installable.find((d) => d.id === explicit);
  if (target === undefined) {
    console.error(`\n✗ --target=${explicit} 不是「已登记」的设备。可选：${installable.map((d) => d.id).join(', ')}`);
    process.exit(1);
  }
} else {
  const physical = installable.filter((d) => !d.emulator);
  if (physical.length === 1) {
    target = physical[0];
  } else if (installable.length === 1) {
    target = installable[0];
  } else {
    console.error(`\n✗ 有多台已登记设备，请用 --target=<目标> 指定：${installable.map((d) => d.id).join(', ')}`);
    process.exit(1);
  }
}

const hap = opt('hap') ?? DEFAULT_HAP;
if (flag('build') || !existsSync(hap)) {
  if (!flag('build')) {
    console.log(`\n! 产物不存在：${hap}\n  将先编译（也可以直接用 DevEco 的 Run 按钮）。`);
  }
  if (!buildSignedHap()) {
    console.error('✗ 编译未产出已签名 HAP。请确认已配置签名（见 docs/运行与部署说明.md §4.2）。');
    process.exit(1);
  }
}

console.log(`\n→ 安装到 [${target.kind}] ${target.id}`);
const inst = run(HDC, ['-t', target.id, 'install', '-r', hap]);
const out = inst.out.trim();
console.log(out.split('\n').map((l) => `  ${l}`).join('\n'));

if (!inst.ok || /failed to install/i.test(out)) {
  console.error('\n✗ 安装失败。');
  if (/9568332|9568322/.test(out)) {
    console.error('  这是**签名不一致**：设备上已装的旧版本用了不同的签名材料。');
    console.error(`  若可以丢弃旧数据：先执行 \`${HDC.split('/').pop()} -t ${target.id} uninstall com.bp.recorder\`，再重跑本命令。`);
    console.error('  若想保留数据：改用 DevEco 的 Run 按钮（IDE 会处理覆盖安装）。');
  }
  process.exit(2);
}

console.log(`\n✓ 安装成功。设备上可直接启动「血压助手」。`);
console.log('  首次启动应弹出免责声明弹窗，首页为空列表并显示「暂无记录」——即装入正确。');
