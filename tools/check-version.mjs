#!/usr/bin/env node
// 发布版本与构建产物一致性校验（审查 R19.6）。
//
// 目的：不能只看源 JSON 里没有 debug 字段就下发布结论。这里核对
//   ① 应用版本与 SDK 版本的事实来源（AppScope/app.json5、build-profile.json5）；
//   ② 已构建的 HAP 产物是否存在、是否**比源码新**（过期产物一律报错）；
//   ③ 产物文件名里的 debug/release 形态与签名信息是否与预期一致（能在文件系统层面看到的）。
// 未构建时不算失败，但会明确打印「跳过产物校验」，不伪装成已验证。
import { readFileSync, statSync, existsSync, readdirSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const problems = [];

function readIf(path) {
  return existsSync(path) ? readFileSync(path, 'utf8') : '';
}

const appJson = readIf(join(root, 'BpRecorder/AppScope/app.json5'));
const profile = readIf(join(root, 'BpRecorder/build-profile.json5'));
const versionName = (/"versionName"\s*:\s*"([^"]+)"/.exec(appJson) || [])[1];
const versionCodeRaw = (/"versionCode"\s*:\s*(\d+)/.exec(appJson) || [])[1];
const bundleName = (/"bundleName"\s*:\s*"([^"]+)"/.exec(appJson) || [])[1];
const compatibleSdk = (/"compatibleSdkVersion"\s*:\s*"([^"]+)"/.exec(profile) || [])[1];
const targetSdk = (/"targetSdkVersion"\s*:\s*"([^"]+)"/.exec(profile) || [])[1];

if (!versionName) problems.push('AppScope/app.json5 读不到 versionName');
if (!versionCodeRaw) problems.push('AppScope/app.json5 读不到 versionCode');
if (!bundleName) problems.push('AppScope/app.json5 读不到 bundleName');
if (!compatibleSdk || !targetSdk) problems.push('build-profile.json5 读不到 SDK 版本（先跑 tools/init-local-config.mjs）');
if (compatibleSdk && targetSdk && compatibleSdk !== targetSdk) {
  problems.push(`compatibleSdkVersion(${compatibleSdk}) 与 targetSdkVersion(${targetSdk}) 不一致`);
}

// 源码最新修改时间（只扫会进包的内容）
let newest = 0;
function walk(dir) {
  if (!existsSync(dir)) return;
  for (const name of readdirSync(dir)) {
    const p = join(dir, name);
    const st = statSync(p);
    if (st.isDirectory()) walk(p);
    else newest = Math.max(newest, st.mtimeMs);
  }
}
walk(join(root, 'BpRecorder/entry/src/main'));
walk(join(root, 'BpRecorder/AppScope'));

// 找 HAP 产物
const haps = [];
function findHap(dir) {
  if (!existsSync(dir)) return;
  for (const name of readdirSync(dir)) {
    const p = join(dir, name);
    const st = statSync(p);
    if (st.isDirectory()) findHap(p);
    else if (name.endsWith('.hap')) haps.push(p);
  }
}
findHap(join(root, 'BpRecorder/entry/build'));

console.log('---- 发布事实来源 ----');
console.log(`bundleName   : ${bundleName}`);
console.log(`versionName  : ${versionName}`);
console.log(`versionCode  : ${versionCodeRaw}`);
console.log(`SDK          : compatible=${compatibleSdk} target=${targetSdk}`);

if (haps.length === 0) {
  console.log('\n---- 产物校验 ----');
  console.log('未找到 HAP 产物：跳过产物校验（未构建，不等于已验证）');
} else {
  console.log('\n---- 产物校验 ----');
  let signedCount = 0;
  for (const hap of haps) {
    const st = statSync(hap);
    const rel = hap.slice(root.length + 1);
    const unsigned = hap.includes('unsigned');
    if (unsigned) {
      // 未签名产物是构建的正常中间产物：只作说明，不当作问题
      console.log(`· ${rel}  ${st.size} 字节  （未签名中间产物，不作为发布依据）`);
      continue;
    }
    signedCount++;
    const fresh = st.mtimeMs >= newest;
    console.log(`${fresh ? '✓' : '✗'} ${rel}  ${st.size} 字节  ${new Date(st.mtimeMs).toISOString()}`);
    if (!fresh) {
      problems.push(`产物比源码旧：${rel}（先重新构建再下发布结论）`);
    }
  }
  if (signedCount === 0) {
    problems.push('只找到未签名产物：没有可作发布依据的签名 HAP');
  }
}

console.log('\n---- 结论 ----');
if (problems.length === 0) {
  console.log('版本与产物一致。注意：签名校验与 debug/release 标记需要真实 release 构建与签名工具，本脚本不替代。');
  process.exit(0);
}
for (const p of problems) console.log(`✗ ${p}`);
process.exit(1);
