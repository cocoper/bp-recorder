#!/usr/bin/env node
// 隔离不变量静态检查（审查 R20.1/R20.4 的「门禁演练」中可离线执行的部分）。
//
// 检查的是「代码与文档有没有把破坏性操作指向用户生产安装」，不是「真机是否真的隔离」——
// 真机部分必须由验收卡 + 哨兵快照证明，本脚本不代替它。
import { readFileSync, existsSync, readdirSync, statSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
let pass = 0;
let fail = 0;
const problems = [];

function ok(msg) {
  pass++;
  console.log(`✓ ${msg}`);
}
function bad(msg) {
  fail++;
  problems.push(msg);
  console.log(`✗ ${msg}`);
}
function read(path) {
  return existsSync(path) ? readFileSync(path, 'utf8') : '';
}
function walk(dir, out = []) {
  if (!existsSync(dir)) return out;
  for (const name of readdirSync(dir)) {
    if (name === 'node_modules' || name === '.git' || name === 'build') continue;
    const p = join(dir, name);
    const st = statSync(p);
    if (st.isDirectory()) walk(p, out);
    else out.push(p);
  }
  return out;
}

const PROD = 'com.bp.recorder';
const db = read(join(root, 'BpRecorder/entry/src/main/ets/service/BpDatabase.ets'));
const isolationDoc = read(join(root, 'docs/隔离验收流程.md'));

console.log('================ 隔离不变量检查（静态）================');

// 1. 隔离库必须带强制前缀
if (/bp_recorder_unittest/.test(db) && /requireTestInstance/.test(db)) {
  ok('隔离测试库前缀 bp_recorder_unittest 与 requireTestInstance 守卫同时存在');
} else {
  bad('BpDatabase 缺少隔离库前缀或 requireTestInstance 守卫');
}

// 2. requireTestInstance 必须被真正调用（不是只定义）
let guardCalls = 0;
for (const f of walk(join(root, 'BpRecorder/entry/src'))) {
  if (!f.endsWith('.ets')) continue;
  guardCalls += (readFileSync(f, 'utf8').match(/requireTestInstance\(/g) || []).length;
}
if (guardCalls >= 3) {
  ok(`requireTestInstance 在清空/删除等破坏性路径被调用（${guardCalls} 处引用）`);
} else {
  bad(`requireTestInstance 引用过少（${guardCalls} 处），可能未真正守卫破坏性操作`);
}

// 3. 隔离流程文档与验收卡存在
if (isolationDoc.length > 0) {
  ok('docs/隔离验收流程.md 存在');
} else {
  bad('缺少 docs/隔离验收流程.md');
}
if (existsSync(join(root, 'docs/验收卡模板.md'))) {
  ok('docs/验收卡模板.md 存在（包名/库名/设备/版本/时间 + 哨兵证据字段）');
} else {
  bad('缺少 docs/验收卡模板.md');
}

// 4. 工具脚本里不得出现「对生产包名执行卸载/清空」的可执行代码
function stripComments(text) {
  return text
    .replace(/\/\*[\s\S]*?\*\//g, '')
    .split('\n')
    .filter((line) => !line.trim().startsWith('//'))
    .join('\n');
}
const dangerous = [];
for (const file of walk(join(root, 'tools'))) {
  if (!/\.(mjs|cjs|js|sh)$/.test(file)) continue;
  const code = stripComments(readFileSync(file, 'utf8'));
  if (PROD === '') continue;
  const lines = code.split('\n');
  for (const line of lines) {
    const isUninstall = /\buninstall\b/.test(line) || /\bbm\s+uninstall\b/.test(line);
    const isClear = /\bpm\s+clear\b/.test(line) || /\bclear\s+--?bundle/.test(line);
    if ((isUninstall || isClear) && line.includes(PROD)) {
      dangerous.push(`${file.slice(root.length + 1)}: ${line.trim()}`);
    }
  }
}
if (dangerous.length === 0) {
  ok('tools/ 里没有「对 com.bp.recorder 执行卸载/清空」的可执行代码');
} else {
  for (const d of dangerous) bad(`危险指令：${d}`);
}

// 5. 审计包名变体工具必须存在且能报状态
if (existsSync(join(root, 'tools/make-audit-variant.mjs'))) {
  ok('tools/make-audit-variant.mjs 存在（测试包名变体，可 apply/restore）');
} else {
  bad('缺少 tools/make-audit-variant.mjs');
}

// 6. 生产包名当前不得是审计变体
const appJson = read(join(root, 'BpRecorder/AppScope/app.json5'));
const bundle = (/"bundleName"\s*:\s*"([^"]+)"/.exec(appJson) || [])[1];
if (bundle === PROD) {
  ok(`app.json5 bundleName 是生产包名（${bundle}）`);
} else {
  bad(`app.json5 bundleName = ${bundle}，不是生产包名 —— 提交前必须 restore`);
}

// 7. 哨兵工具存在且拒绝空目标
const sentinel = read(join(root, 'tools/sentinel.mjs'));
if (/Empty/.test(sentinel)) {
  ok('tools/sentinel.mjs 拒绝 [Empty] 目标（不会把「设备未连接」当成功）');
} else {
  bad('sentinel.mjs 未见 Empty 拒绝逻辑');
}

console.log('\n================ 结论 ================');
console.log(`静态隔离不变量：通过 ${pass}，失败 ${fail}`);
if (fail > 0) {
  console.log('注意：本检查只覆盖静态不变量；真机隔离必须由验收卡 + 前后哨兵快照证明。');
  process.exit(1);
}
console.log('静态隔离不变量全部通过。真机部分仍需按验收卡执行并附哨兵快照。');
