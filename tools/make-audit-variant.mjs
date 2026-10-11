#!/usr/bin/env node
// 测试包名变体（审查 R20.1）：把 AppScope/app.json5 的 bundleName 换成隔离包名，
// 让破坏性验收装到「另一个应用」上，绝不碰用户生产安装（com.bp.recorder）。
//
// 用法：
//   node tools/make-audit-variant.mjs --status    # 看当前包名与是否有备份
//   node tools/make-audit-variant.mjs --apply     # 切到审计包名 com.bp.recorder.audit
//   node tools/make-audit-variant.mjs --restore   # 切回生产包名
//
// 规则：apply 前必须没有 uncommitted 的生产改动（避免把变体包名误提交）；备份文件放在同目录，
// 只改 bundleName 一个字段，其余原样保留。
import { readFileSync, writeFileSync, existsSync, unlinkSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { execFileSync } from 'node:child_process';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const appPath = join(root, 'BpRecorder/AppScope/app.json5');
const backupPath = `${appPath}.prod-backup`;
const PROD = 'com.bp.recorder';
const AUDIT = 'com.bp.recorder.audit';

const args = process.argv.slice(2);
const mode = args.find((a) => ['--status', '--apply', '--restore'].includes(a)) || '--status';

function currentBundle() {
  const text = readFileSync(appPath, 'utf8');
  const m = /"bundleName"\s*:\s*"([^"]+)"/.exec(text);
  return m === null ? null : m[1];
}

function status() {
  const bundle = currentBundle();
  console.log(`app.json5 bundleName : ${bundle}`);
  console.log(`生产包名             : ${PROD}`);
  console.log(`审计包名             : ${AUDIT}`);
  console.log(`备份文件             : ${existsSync(backupPath) ? backupPath : '（无）'}`);
  console.log(bundle === AUDIT ? '当前状态：审计变体（不要在真机用户数据上做任何破坏性操作）'
    : '当前状态：生产包名');
}

if (mode === '--status') {
  status();
  process.exit(0);
}

if (mode === '--apply') {
  const bundle = currentBundle();
  if (bundle === AUDIT) {
    console.log('已经是审计变体，无需重复切换');
    status();
    process.exit(0);
  }
  if (bundle !== PROD) {
    console.error(`拒绝执行：当前 bundleName 既不是 ${PROD} 也不是 ${AUDIT}（${bundle}），请先人工确认`);
    process.exit(1);
  }
  // 生产改动未提交时拒绝（避免把变体包名混进提交）
  try {
    const dirty = execFileSync('git', ['-C', root, 'status', '--porcelain', '--', 'BpRecorder/AppScope/app.json5'],
      { encoding: 'utf8' }).trim();
    if (dirty.length > 0) {
      console.error('拒绝执行：BpRecorder/AppScope/app.json5 有未提交改动，请先提交或还原');
      process.exit(1);
    }
  } catch (err) {
    console.error('拒绝执行：无法读取 git 状态（需要 git 工作区）');
    process.exit(1);
  }
  writeFileSync(backupPath, readFileSync(appPath, 'utf8'));
  const patched = readFileSync(appPath, 'utf8').replace(/"bundleName"\s*:\s*"[^"]+"/, `"bundleName": "${AUDIT}"`);
  writeFileSync(appPath, patched);
  console.log(`已切到审计包名 ${AUDIT}（原文件备份在 ${backupPath}）`);
  console.log('提醒：验收结束后必须 node tools/make-audit-variant.mjs --restore，并确认 git 里没有残留变体包名');
  status();
  process.exit(0);
}

if (mode === '--restore') {
  if (!existsSync(backupPath)) {
    const bundle = currentBundle();
    if (bundle === PROD) {
      console.log('已是生产包名且没有备份文件，无需恢复');
      process.exit(0);
    }
    console.error('拒绝执行：既没有备份文件，当前也不是生产包名 —— 请人工确认 app.json5');
    process.exit(1);
  }
  writeFileSync(appPath, readFileSync(backupPath, 'utf8'));
  unlinkSync(backupPath);
  console.log('已恢复生产包名，备份文件已删除');
  status();
  process.exit(0);
}
