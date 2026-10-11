#!/usr/bin/env node
/**
 * SQL 层离线校验（真实 SQLite 执行）
 *
 * 为什么需要它：
 *   本机没有 DevEco / HarmonyOS SDK / 真机，无法运行 App，也就无法验证
 *   `BpDatabase` 的建表语句与 v1→v2 迁移是否真的能跑通。
 *   而迁移代码位于**启动初始化路径且没有容错**——一旦失败，App 直接起不来。
 *   这是整个工程里「最错不起」的一段 SQL，不能只靠肉眼审查。
 *
 * 做法：
 *   1. **从真实 .ets 源码里正则提取** DDL 与迁移语句（不是手工复制，避免漂移）；
 *   2. 用 Node 内置的 node:sqlite 在内存库上真实执行；
 *   3. 模拟「老版本升级」：v1 建表 + 造脏数据 → 跑迁移 → 断言结果；
 *   4. **反证**：在脏数据上「不清理直接建唯一索引」必须失败 ——
 *      证明「先清理后建索引」不是多余步骤。
 *
 * 用法：node --no-warnings tools/sqlcheck.mjs
 */

import { readFileSync } from 'node:fs';
import { join, dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { DatabaseSync } from 'node:sqlite';

const HERE = dirname(fileURLToPath(import.meta.url));
const ETS = resolve(HERE, '..', 'BpRecorder', 'entry', 'src', 'main', 'ets');

// ───────────────────────── 断言框架 ─────────────────────────

let passCount = 0;
const failures = [];
let groupName = '';

function group(name) {
  groupName = name;
}
function ok(cond, name, extra) {
  if (cond) {
    passCount++;
  } else {
    failures.push(`[${groupName}] ${name}${extra === undefined ? '' : ' :: ' + extra}`);
  }
}
function eq(actual, expected, name) {
  ok(actual === expected, name, `期望 ${String(expected)}，实际 ${String(actual)}`);
}

// ───────────────────────── 从 .ets 提取 SQL ─────────────────────────

const constSrc = readFileSync(join(ETS, 'common', 'Constants.ets'), 'utf8');
const dbSrc = readFileSync(join(ETS, 'service', 'BpDatabase.ets'), 'utf8');

/** 读取 Constants.ets 中 DbConst 的某个静态常量（字符串或数字） */
function constOf(name) {
  const re = new RegExp(`static\\s+readonly\\s+${name}\\s*:\\s*(?:string|number)\\s*=\\s*([^;]+);`);
  const m = re.exec(constSrc);
  if (m === null) {
    throw new Error(`未能在 Constants.ets 中找到 DbConst.${name}`);
  }
  const raw = m[1].trim();
  const strMatch = /^'([^']*)'$/.exec(raw);
  if (strMatch !== null) {
    return strMatch[1];
  }
  return Number(raw);
}

const T = {
  T_BP: constOf('T_BP'),
  T_MED: constOf('T_MED'),
  T_PLAN: constOf('T_PLAN'),
  T_LOG: constOf('T_LOG')
};
const SCHEMA_VERSION = constOf('SCHEMA_VERSION');

if (SCHEMA_VERSION !== 4) {
  throw new Error(`本校验针对 v4 结构编写，但 Constants.ets 中 SCHEMA_VERSION=${SCHEMA_VERSION}`);
}

/** 把模板字符串里的 ${DbConst.XXX} 替换为真实值 */
function substitute(sql) {
  return sql.replace(/\$\{DbConst\.(\w+)\}/g, (_, key) => {
    if (key === 'SCHEMA_VERSION') {
      return String(SCHEMA_VERSION);
    }
    if (T[key] === undefined) {
      throw new Error(`未知的 DbConst.${key}`);
    }
    return T[key];
  });
}

/** 取出文本中所有反引号模板字符串的内容 */
function backticks(text) {
  const out = [];
  const re = /`([^`]*)`/g;
  let m;
  while ((m = re.exec(text)) !== null) {
    out.push(m[1]);
  }
  return out;
}

const ddlBlock = /const DDL: string\[\] = \[([\s\S]*?)\n\];/.exec(dbSrc);
if (ddlBlock === null) {
  throw new Error('未能在 BpDatabase.ets 中定位 DDL 数组');
}
const DDL_STATEMENTS = backticks(ddlBlock[1]).map(substitute);

const migrateStart = dbSrc.indexOf('private static async migrate(');
const migrateEnd = dbSrc.indexOf('private static async readUserVersion(');
if (migrateStart < 0 || migrateEnd < 0 || migrateEnd <= migrateStart) {
  throw new Error('未能在 BpDatabase.ets 中定位 migrate() 方法');
}
// migrate() 里除了 SQL 还有 Logger 的模板字符串，按语句首关键字过滤掉
const MIGRATE_STATEMENTS = backticks(dbSrc.slice(migrateStart, migrateEnd))
  .map(substitute)
  .filter((s) => /^\s*(CREATE|DELETE|UPDATE|INSERT|PRAGMA|ALTER|DROP)\b/i.test(s));

// 从迁移语句里挑出「建索引」与「清理」两类，供反证使用
const MIG_CLEAN_BP = MIGRATE_STATEMENTS.find((s) => /DELETE FROM/i.test(s));
const MIG_CLEAN_PLAN = MIGRATE_STATEMENTS.find((s) => /^\s*UPDATE/i.test(s));
const MIG_IDX_TRIPLE = MIGRATE_STATEMENTS.find((s) => /uidx_bp_triple/.test(s));
const MIG_IDX_PLAN = MIGRATE_STATEMENTS.find((s) => /uidx_plan_active_med/.test(s));
const MIG_PRAGMA = MIGRATE_STATEMENTS.find((s) => /PRAGMA\s+user_version/i.test(s));
// v3：把「计划有效区间」变成显式列的 ALTER（审查 R01.3）
const MIG_ALTERS = MIGRATE_STATEMENTS.filter((s) => /^\s*ALTER\s+TABLE/i.test(s));

if (!MIG_CLEAN_BP || !MIG_CLEAN_PLAN || !MIG_IDX_TRIPLE || !MIG_IDX_PLAN || !MIG_PRAGMA) {
  throw new Error('迁移语句提取不完整，请检查 BpDatabase.migrate() 是否被改动');
}

// ───────────────────────── 建库辅助 ─────────────────────────

const NOW = 1759708800000; // 2025-10-06 00:00:00 UTC 附近的固定时间戳，保证可复现

function newV1Database() {
  const db = new DatabaseSync(':memory:');
  for (const sql of DDL_STATEMENTS) {
    db.exec(sql);
  }
  db.exec('PRAGMA user_version = 1');
  return db;
}

function indexNames(db) {
  return db.prepare("SELECT name FROM sqlite_master WHERE type = 'index' AND name NOT LIKE 'sqlite_%'")
    .all()
    .map((r) => r.name);
}

function countBp(db) {
  return db.prepare(`SELECT COUNT(*) AS c FROM ${T.T_BP}`).get().c;
}

function countActivePlans(db) {
  return db.prepare(`SELECT COUNT(*) AS c FROM ${T.T_PLAN} WHERE is_active = 1`).get().c;
}

function countLogs(db) {
  return db.prepare(`SELECT COUNT(*) AS c FROM ${T.T_LOG}`).get().c;
}

const INS_BP = `INSERT INTO ${T.T_BP}
  (systolic, diastolic, heart_rate, measure_time, period, note, user_id, source, created_at, updated_at)
  VALUES (?, ?, ?, ?, ?, ?, 1, 'manual', ?, ?)`;
const INS_PLAN = `INSERT INTO ${T.T_PLAN}
  (medication_id, time_slots, start_date, end_date, is_active, created_at, updated_at)
  VALUES (?, ?, ?, ?, ?, ?, ?)`;

console.log('================ SQL 层离线校验（真实 SQLite 执行）================');
console.log(`数据源：BpDatabase.ets（DDL ${DDL_STATEMENTS.length} 条 / 迁移 ${MIGRATE_STATEMENTS.length} 条）`);
console.log(`表名解析：${T.T_BP} / ${T.T_MED} / ${T.T_PLAN} / ${T.T_LOG}，目标版本 v${SCHEMA_VERSION}`);
console.log('');

// ═══════════════════ 1. v1 结构 ═══════════════════
group('v1 建表（DDL 真实可执行）');

const db = newV1Database();
const v1Indexes = indexNames(db);

eq(
  db.prepare("SELECT COUNT(*) AS c FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'").get().c,
  4,
  'v1 建立 4 张业务表'
);
ok(v1Indexes.includes('idx_measure_time'), 'v1 索引 idx_measure_time 已创建');
ok(v1Indexes.includes('idx_period_time'), 'v1 索引 idx_period_time 已创建');
ok(v1Indexes.includes('idx_plan_med'), 'v1 索引 idx_plan_med 已创建');
ok(v1Indexes.includes('idx_medlog_scheduled'), 'v1 索引 idx_medlog_scheduled 已创建');
ok(v1Indexes.includes('idx_medlog_med_time'), 'v1 索引 idx_medlog_med_time 已创建');
ok(!v1Indexes.includes('uidx_bp_triple'), 'v1 尚无 uidx_bp_triple（升级前状态正确）');
ok(!v1Indexes.includes('uidx_plan_active_med'), 'v1 尚无 uidx_plan_active_med（升级前状态正确）');
eq(db.prepare('PRAGMA user_version').get().user_version, 1, 'v1 user_version = 1');

// med_log 幂等（v1 已具备的约束）
group('v1 med_log 幂等约束（INSERT OR IGNORE）');
const insLogIgnore = db.prepare(`INSERT OR IGNORE INTO ${T.T_LOG}
  (medication_id, med_name, dosage, scheduled_time, taken_time, status, note, created_at, updated_at)
  VALUES (?, ?, ?, ?, NULL, ?, NULL, ?, ?)`);
const logsBefore = countLogs(db);
insLogIgnore.run(1, '缬沙坦', '1片/80mg', NOW, 'pending', NOW, NOW);
insLogIgnore.run(1, '缬沙坦', '1片/80mg', NOW, 'pending', NOW, NOW);
insLogIgnore.run(1, '缬沙坦', '1片/80mg', NOW, 'pending', NOW, NOW);
eq(countLogs(db) - logsBefore, 1, '同 (药品, 计划时间) 重复写入只落 1 条');

// ═══════════════════ 2. 造脏数据（模拟 v1 用户库） ═══════════════════
group('模拟 v1 脏数据');

const insBp = db.prepare(INS_BP);
const insPlan = db.prepare(INS_PLAN);

db.exec(`INSERT INTO ${T.T_MED} (name, dosage, note, is_active, created_at, updated_at)
         VALUES ('缬沙坦', '1片/80mg', NULL, 1, ${NOW}, ${NOW})`);

// 同一三元组写 3 次（v1 无结构约束，只能靠应用层判重，用户手工改库/旧版本导入会留下）
insBp.run(128, 82, 72, NOW, 'morning', null, NOW, NOW);
insBp.run(128, 82, 72, NOW, 'morning', null, NOW, NOW);
insBp.run(128, 82, 72, NOW, 'morning', null, NOW, NOW);
// 同一时刻不同数值：应保留
insBp.run(135, 88, 76, NOW, 'night', null, NOW, NOW);
// 不同时刻同数值：应保留
insBp.run(128, 82, 72, NOW + 300000, 'morning', null, NOW, NOW);

eq(countBp(db), 5, '血压记录 5 条（其中 3 条互为重复三元组）');

// 同一药品 3 条生效计划
insPlan.run(1, '["07:30"]', '2026-01-01', null, 1, NOW, NOW);
insPlan.run(1, '["12:00"]', '2026-02-01', null, 1, NOW + 1000, NOW + 1000);
insPlan.run(1, '["18:00"]', '2026-03-01', null, 1, NOW + 2000, NOW + 2000);
eq(countActivePlans(db), 3, '同一药品 3 条生效计划（v1 可写入）');

// ═══════════════════ 3. 反证：不清理直接建唯一索引必定失败 ═══════════════════
group('反证：先建索引 / 后清理 的顺序不可颠倒');

const probeDb = newV1Database();
const probeInsBp = probeDb.prepare(INS_BP);
probeInsBp.run(128, 82, 72, NOW, 'morning', null, NOW, NOW);
probeInsBp.run(128, 82, 72, NOW, 'morning', null, NOW, NOW);

let tripleIndexThrew = false;
try {
  probeDb.exec(MIG_IDX_TRIPLE);
} catch (err) {
  tripleIndexThrew = true;
}
ok(tripleIndexThrew, '含重复三元组的库上直接建 uidx_bp_triple 会失败（err=' +
  (tripleIndexThrew ? '已抛出' : '未抛出') + '）');

const probePlanIns = probeDb.prepare(INS_PLAN);
probeDb.exec(`INSERT INTO ${T.T_MED} (name, dosage, note, is_active, created_at, updated_at)
              VALUES ('A', '1片', NULL, 1, ${NOW}, ${NOW})`);
probePlanIns.run(1, '["07:30"]', '2026-01-01', null, 1, NOW, NOW);
probePlanIns.run(1, '["12:00"]', '2026-02-01', null, 1, NOW + 1, NOW + 1);

let planIndexThrew = false;
try {
  probeDb.exec(MIG_IDX_PLAN);
} catch (err) {
  planIndexThrew = true;
}
ok(planIndexThrew, '含多生效计划的库上直接建 uidx_plan_active_med 会失败（证明清理是必要步骤）');

probeDb.close();

// ═══════════════════ 4. 走完整迁移 v1 → v2 ═══════════════════
group('执行迁移 v1 → v2（按 migrate() 的语句顺序）');

const order = [MIG_CLEAN_BP, MIG_CLEAN_PLAN, MIG_IDX_TRIPLE, MIG_IDX_PLAN, MIG_PRAGMA];
let migrated = false;
try {
  for (const sql of order) {
    db.exec(sql);
  }
  migrated = true;
} catch (err) {
  ok(false, '迁移整体成功执行', `异常：${err.message}`);
}
ok(migrated, '迁移整体成功执行（无异常）');

if (migrated) {
  eq(db.prepare('PRAGMA user_version').get().user_version, SCHEMA_VERSION, `迁移后 user_version = ${SCHEMA_VERSION}`);

  // 血压：重复三元组保留最早一条
  eq(countBp(db), 3, '重复三元组被清理（5 → 3）');
  const keptBp = db.prepare(`SELECT COUNT(*) AS c FROM ${T.T_BP} WHERE measure_time = ? AND systolic = ? AND diastolic = ?`)
    .get(NOW, 128, 82).c;
  eq(keptBp, 1, '同三元组只保留 1 条');
  eq(
    db.prepare(`SELECT COUNT(*) AS c FROM ${T.T_BP} WHERE measure_time = ? AND systolic = ?`).get(NOW, 135).c,
    1,
    '同一时刻不同数值的记录未被误删'
  );
  eq(
    db.prepare(`SELECT COUNT(*) AS c FROM ${T.T_BP} WHERE measure_time = ?`).get(NOW + 300000).c,
    1,
    '不同时刻同数值的记录未被误删'
  );

  // 计划：同一药品只保留最新一条生效
  eq(countActivePlans(db), 1, '同一药品只保留 1 条生效计划');
  const keptSlot = db.prepare(`SELECT time_slots FROM ${T.T_PLAN} WHERE is_active = 1 AND medication_id = 1`).get();
  eq(keptSlot.time_slots, '["18:00"]', '保留的是最新（MAX(id)）那条生效计划');
  eq(
    db.prepare(`SELECT COUNT(*) AS c FROM ${T.T_PLAN} WHERE is_active = 0`).get().c,
    2,
    '被替换的旧计划置为停用而非删除（历史可追溯）'
  );

  // 索引落位
  const v2Indexes = indexNames(db);
  ok(v2Indexes.includes('uidx_bp_triple'), 'v2 索引 uidx_bp_triple 已建立');
  ok(v2Indexes.includes('uidx_plan_active_med'), 'v2 索引 uidx_plan_active_med 已建立');

  // ═══════════════════ 5. 迁移后约束真实生效 ═══════════════════
  group('迁移后：结构级约束真实生效');

  let dupBpThrew = false;
  try {
    insBp.run(128, 82, 72, NOW, 'morning', null, NOW, NOW);
  } catch (err) {
    dupBpThrew = true;
  }
  ok(dupBpThrew, '插入重复三元组被拒绝（FR-6.6 判重从应用层提升到结构层）');

  let okBp = true;
  try {
    insBp.run(128, 82, 72, NOW + 600000, 'morning', null, NOW, NOW);
  } catch (err) {
    okBp = false;
  }
  ok(okBp, '不同测量时间的同数值记录仍可插入（约束不过度收紧）');

  let dupPlanThrew = false;
  try {
    insPlan.run(1, '["20:00"]', '2026-04-01', null, 1, NOW, NOW);
  } catch (err) {
    dupPlanThrew = true;
  }
  ok(dupPlanThrew, '同一药品插入第二条生效计划被拒绝（FR-8.2 结构级保障）');

  let inactivePlanOk = true;
  try {
    insPlan.run(1, '["20:00"]', '2025-01-01', '2025-06-30', 0, NOW, NOW);
    insPlan.run(1, '["21:00"]', '2024-01-01', '2024-06-30', 0, NOW, NOW);
  } catch (err) {
    inactivePlanOk = false;
  }
  ok(inactivePlanOk, '部分唯一索引只约束 is_active=1，停用计划可多条共存');

  // 幂等：同一批次重复执行迁移不应报错（IF NOT EXISTS + 清理幂等）
  group('迁移幂等（重复执行安全）');
  let idempotent = true;
  try {
    for (const sql of order) {
      db.exec(sql);
    }
  } catch (err) {
    idempotent = false;
    ok(false, '迁移可重复执行', `异常：${err.message}`);
  }
  ok(idempotent, '迁移语句可重复执行而不报错（启动时重复调用安全）');
  eq(countBp(db), 4, '重复迁移不改变数据条数');
}

db.close();

// ═══════════════════ 汇总 ═══════════════════
console.log('================ 校验结果 ================');
console.log(`断言总数：${passCount + failures.length}    通过：${passCount}    失败：${failures.length}`);
if (failures.length > 0) {
  console.log('');
  console.log('失败项：');
  for (const f of failures) {
    console.log(`  ✗ ${f}`);
  }
  console.log('');
  
// ═══════════════════ 5. v2 → v3：显式有效区间列（审查 R01.3） ═══════════════════
group('迁移 v2 → v3（计划有效区间显式化）');

ok(MIG_ALTERS.length >= 2, `migrate() 中提取到 ${MIG_ALTERS.length} 条 ALTER（应含 effective_from / effective_to）`);

function columnNames(db, table) {
  return db.prepare(`PRAGMA table_info(${table})`).all().map((r) => r.name);
}

// 迁移前的 v2 库里没有这两列 —— 先造一个「v2 库」验证 ALTER 的效果
const v2db = new DatabaseSync(':memory:');
for (const sql of DDL_STATEMENTS) {
  v2db.exec(sql);
}
// 模拟旧库：把 v3 列删掉（SQLite 3.35+ 支持 DROP COLUMN；不支持时退化为跳过该断言）
let droppedOk = true;
try {
  v2db.exec(`ALTER TABLE ${T.T_PLAN} DROP COLUMN effective_from`);
  v2db.exec(`ALTER TABLE ${T.T_PLAN} DROP COLUMN effective_to`);
} catch (err) {
  droppedOk = false;
}
if (droppedOk) {
  ok(!columnNames(v2db, T.T_PLAN).includes('effective_from'), 'v2 库确认没有 effective_from');
  const v2InsPlan = v2db.prepare(INS_PLAN);
  v2db.exec(`INSERT INTO ${T.T_MED} (name, dosage, note, is_active, created_at, updated_at)
             VALUES ('A', '1片', NULL, 1, ${NOW}, ${NOW})`);
  v2InsPlan.run(1, '["07:30"]', '2026-01-01', null, 1, NOW, NOW);

  // 逐条执行 ALTER：列已存在就跳过（与 BpDatabase.hasColumn 的幂等逻辑一致）
  for (const sql of MIG_ALTERS) {
    const m = /ALTER\s+TABLE\s+(\w+)\s+ADD\s+COLUMN\s+(\w+)/i.exec(sql);
    if (m !== null && columnNames(v2db, m[1]).includes(m[2])) {
      continue;
    }
    v2db.exec(sql);
  }
  const cols = columnNames(v2db, T.T_PLAN);
  ok(cols.includes('effective_from'), 'ALTER 后 med_plan 有 effective_from');
  ok(cols.includes('effective_to'), 'ALTER 后 med_plan 有 effective_to');
  const row = v2db.prepare(`SELECT effective_from, effective_to FROM ${T.T_PLAN} WHERE id = 1`).get();
  eq(row.effective_from, 0, '旧行的 effective_from 默认 0（表示未回填，调用方按既有列推导）');
  eq(row.effective_to, null, '旧行的 effective_to 默认 NULL（长期 / 未回填）');
  // v4：med_log.source_plan_id（历史行来源未知 → NULL）
  ok(columnNames(v2db, T.T_LOG).includes('source_plan_id'), 'ALTER 后 med_log 有 source_plan_id');
  const logCol = v2db.prepare(`PRAGMA table_info(${T.T_LOG})`).all().find((c) => c.name === 'source_plan_id');
  eq(logCol && logCol.dflt_value, null, 'source_plan_id 默认 NULL（不伪造历史来源）');
  // 幂等：再跑一遍 ALTER 不应抛错
  let secondPassOk = true;
  try {
    for (const sql of MIG_ALTERS) {
      const m = /ALTER\s+TABLE\s+(\w+)\s+ADD\s+COLUMN\s+(\w+)/i.exec(sql);
      if (m !== null && columnNames(v2db, m[1]).includes(m[2])) {
        continue;
      }
      v2db.exec(sql);
    }
  } catch (err) {
    secondPassOk = false;
  }
  ok(secondPassOk, '重复执行迁移的 ALTER 幂等（列存在即跳过）');
  // 回填规则由 TS 执行（backfillPlanWindows）：静态确认它确实写了这两列
  ok(/backfillPlanWindows/.test(dbSrc) && /effective_from = \?/.test(dbSrc),
    'migrate() 会调用 backfillPlanWindows 回填历史有效区间');
} else {
  console.log('· 当前 SQLite 不支持 DROP COLUMN，跳过 v2 → v3 的列级断言（不代表通过）');
}
v2db.close();

console.log('================ 结论 ================');
  console.log('存在失败项，需修正。');
  process.exit(1);
}
console.log('');
console.log('================ 结论 ================');
console.log('全部通过：DDL 可执行、迁移顺序正确、约束真实生效。');
