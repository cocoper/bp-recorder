// 生产哨兵（审查 R20.4）：**只读**取证，用来证明「测试前后用户生产数据未变」。
//
// 用法：
//   node tools/sentinel.mjs take  --out /tmp/sentinel-before.json
//   node tools/sentinel.mjs take  --out /tmp/sentinel-after.json
//   node tools/sentinel.mjs compare /tmp/sentinel-before.json /tmp/sentinel-after.json
//
// 纪律：只调用 `hdc file recv` 把库文件拉到本机临时目录读取；**绝不**写设备、不删数据、
// 不安装/卸载应用。设备与库文件读不到时明确报错，不伪造结论。
import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { mkdtempSync, readFileSync, writeFileSync, existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { DatabaseSync } from 'node:sqlite';
import { hdcBin } from './toolchain.mjs';

const BUNDLE = 'com.bp.recorder';
const RDB_DIR = `/data/app/el2/100/database/${BUNDLE}/entry/rdb`;
const FILES = ['bp_recorder.db', 'bp_recorder.db-wal', 'bp_recorder.db-shm'];

function hdc(args) {
  const r = spawnSync(hdcBin(), args, { encoding: 'utf8' });
  if (r.error) throw new Error(`无法执行 hdc（${hdcBin()}）：${r.error.message}`);
  if (r.status !== 0) throw new Error(`hdc ${args.join(' ')} 失败：${(r.stderr || r.stdout || '').trim()}`);
  return r.stdout ?? '';
}

function deviceInfo() {
  const list = hdc(['list', 'targets']).trim().split('\n')[0] ?? '';
  const target = list.split('\t')[0];
  if (!target || target.includes('[Empty]')) throw new Error('没有已连接设备（hdc list targets 返回 [Empty]，请插好 USB 并解锁）');
  return target;
}

function take(outPath) {
  const target = deviceInfo();
  const dir = mkdtempSync(join(tmpdir(), 'bp-sentinel-'));
  const files = {};
  for (const f of FILES) {
    const local = join(dir, f);
    spawnSync(hdcBin(), ['file', 'recv', `${RDB_DIR}/${f}`, local], { encoding: 'utf8' });
    if (!existsSync(local)) continue;
    files[f] = {
      bytes: readFileSync(local).length,
      sha256: createHash('sha256').update(readFileSync(local)).digest('hex')
    };
  }
  if (!files['bp_recorder.db']) {
    throw new Error(`读不到 ${RDB_DIR}/bp_recorder.db（设备锁屏或路径不存在？）`);
  }
  const db = new DatabaseSync(join(dir, 'bp_recorder.db'));
  const count = (sql) => db.prepare(sql).get().c;
  const counts = {
    bp_record: count('SELECT COUNT(*) AS c FROM bp_record'),
    med_log: count('SELECT COUNT(*) AS c FROM med_log'),
    med_log_taken: count("SELECT COUNT(*) AS c FROM med_log WHERE status = 'taken'"),
    med_log_pending: count("SELECT COUNT(*) AS c FROM med_log WHERE status = 'pending'"),
    med_log_skipped: count("SELECT COUNT(*) AS c FROM med_log WHERE status = 'skipped'"),
    med_log_missed: count("SELECT COUNT(*) AS c FROM med_log WHERE status = 'missed'"),
    med_plan_active: count('SELECT COUNT(*) AS c FROM med_plan WHERE is_active = 1'),
    medication: count('SELECT COUNT(*) AS c FROM medication')
  };
  const fingerprint = createHash('sha256').update(JSON.stringify(counts)).digest('hex').slice(0, 16);
  const snapshot = { takenAt: new Date().toISOString(), target, bundle: BUNDLE, counts, fingerprint, files };
  db.close();
  writeFileSync(outPath, JSON.stringify(snapshot, null, 2) + '\n', 'utf8');
  process.stdout.write(`哨兵已记录：${outPath}\n`);
  process.stdout.write(`  设备 ${snapshot.target}｜指纹 ${snapshot.fingerprint}\n`);
  for (const [k, v] of Object.entries(counts)) process.stdout.write(`  ${k} = ${v}\n`);
  return snapshot;
}

function compare(aPath, bPath) {
  const a = JSON.parse(readFileSync(aPath, 'utf8'));
  const b = JSON.parse(readFileSync(bPath, 'utf8'));
  const diffs = [];
  for (const k of Object.keys(a.counts)) {
    if (a.counts[k] !== b.counts[k]) diffs.push(`${k}: ${a.counts[k]} → ${b.counts[k]}`);
  }
  process.stdout.write(`前 ${a.takenAt} 指纹 ${a.fingerprint}\n后 ${b.takenAt} 指纹 ${b.fingerprint}\n`);
  if (diffs.length === 0) {
    process.stdout.write('结论：生产数据计数与指纹一致 —— 测试未改动生产数据。\n');
    process.exit(0);
  }
  process.stdout.write('结论：**生产数据发生变化**：\n' + diffs.map(d => '  - ' + d).join('\n') + '\n');
  process.exit(1);
}

const [action, arg, extra] = process.argv.slice(2);
if (action === 'take') {
  take(arg === '--out' ? extra : (arg ?? '/tmp/bp-sentinel.json'));
} else if (action === 'compare') {
  if (!arg || !extra) {
    console.error('用法：node tools/sentinel.mjs compare <before.json> <after.json>');
    process.exit(2);
  }
  compare(arg, extra);
} else {
  console.error('用法：node tools/sentinel.mjs take --out <file> ｜ compare <before> <after>');
  process.exit(2);
}
