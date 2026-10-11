// 审查反例的**正式回归副本**（源：docs/review-2026-10-11/repro.cjs，审查方冻结件）。
//
// 为什么要有一份副本：
//   1) 源文件在审查证据包里、按交接说明只留本地；门禁需要一份随仓库走的可复现脚本。
//   2) R06-a 的表达在「正确串行化」实现下必须改写（见下），否则会出现
//      「A 等 B、B 等 A」的自锁 —— 那是脚本时序问题，不是被测代码的问题。
//      业务断言含义**保留并加强**：B 的写入不得被 A 的回滚带走，且 B 不得并入 A 的事务。
//
// 运行：node tools/parity/run.mjs && node tools/regression/review-2026-10-11.cjs
// 审查反例：只运行 parity 转译后的真实服务代码；系统服务/存储均为内存桩。
// 不连接设备、不打开用户数据库、不发布真实通知。先运行 node tools/parity/run.mjs。
// 当前版本出现 FAIL 是在重现缺陷；修复后应迁移为正式回归测试，不能删除断言来消除失败。
const path = require('node:path');
const fs = require('node:fs');
const root = path.resolve(__dirname, '../..');
const out = path.join(root, 'tools/parity/.build/out/src');
global.$r = key => ({ id: key.split('.').pop() });
const { DateUtils } = require(path.join(out, 'common/DateUtils.js'));
const { Csv } = require(path.join(out, 'common/Csv.js'));
const { VocabFactory } = require(path.join(out, 'common/Vocab.js'));
const { PrefKeys } = require(path.join(out, 'common/Constants.js'));
const { ExportService } = require(path.join(out, 'service/ExportService.js'));
const { ImportService } = require(path.join(out, 'service/ImportService.js'));
const { GenericImportService, ColRole } = require(path.join(out, 'service/GenericImportService.js'));
const { MedService } = require(path.join(out, 'service/MedService.js'));
const { ReportService } = require(path.join(out, 'service/ReportService.js'));
const { ReminderService } = require(path.join(out, 'service/ReminderService.js'));
const { BpDatabase } = require(path.join(out, 'service/BpDatabase.js'));
const kit = name => require(path.join(root, 'tools/parity/.build/node_modules', name));
const ark = kit('@kit.ArkData');
const agent = kit('@kit.BackgroundTasksKit').reminderAgentManager;
const notification = kit('@kit.NotificationKit').notificationManager;
const strings = Object.fromEntries(JSON.parse(fs.readFileSync(path.join(root,
  'BpRecorder/entry/src/main/resources/base/element/string.json'), 'utf8')).string.map(x => [x.name, x.value]));
const context = { abilityInfo: { bundleName: 'audit.memory.only', name: 'EntryAbility' },
  resourceManager: { getStringSync: id => strings[id] } };
const vocab = VocabFactory.csv(context);
const reminderVocab = VocabFactory.reminder(context);
const ts = (day, hour=0, minute=0, second=0, ms=0) => new Date(2026, 9, day, hour, minute, second, ms).getTime();
const med = (id, dosage='1片') => ({ id, name: `测试药${id}`, dosage, note: null, isActive: true, createdAt: 0, updatedAt: 0 });
const plan = (id, start='2026-10-01', slots=['08:00']) => ({ id, medicationId: id, timeSlots: slots,
  startDate: start, endDate: null, isActive: true, createdAt: 0, updatedAt: 0 });
const bp = time => ({ id: 1, systolic: 120, diastolic: 80, heartRate: 70, measureTime: time,
  period: DateUtils.periodOf(time), note: null, userId: 1, source: 'manual', createdAt: time, updatedAt: time });
const log = (scheduledTime, takenTime) => ({ id: 1, medicationId: 1, medName: '测试药1', dosage: '1片',
  scheduledTime, takenTime, status: 'taken', note: null, createdAt: 0, updatedAt: 0 });
const results = [];
async function check(id, title, expected, fn) {
  try {
    const actual = await fn();
    const pass = JSON.stringify(actual) === JSON.stringify(expected);
    results.push({ id, title, expected, actual, pass });
    console.log(`${pass ? 'PASS' : 'FAIL'} ${id} ${title}\n  expected=${JSON.stringify(expected)} actual=${JSON.stringify(actual)}`);
  } catch (e) {
    results.push({ id, title, expected, error: String(e), pass: false, harnessError: true });
    console.log(`HARNESS_ERROR ${id}: ${e.stack}`);
  }
}
function reminderStub(failHour=-1) {
  const memory = new Map([[PrefKeys.REMINDER_MODE, 'agent']]);
  const state = { alarms: [], attempts: 0, cancels: 0, memory };
  ark.preferences.getPreferencesSync = () => ({ getSync: (k,d) => memory.has(k) ? memory.get(k) : d,
    putSync: (k,v) => memory.set(k,v), flush: async () => {} });
  agent.ReminderType = { REMINDER_TYPE_ALARM: 1, REMINDER_TYPE_TIMER: 0 };
  agent.ActionButtonType = { ACTION_BUTTON_TYPE_CLOSE: 0 };
  notification.SlotType = { SOCIAL_COMMUNICATION: 0 };
  notification.ContentType = { NOTIFICATION_CONTENT_BASIC_TEXT: 0 };
  notification.isNotificationEnabled = async () => true;
  agent.getAllValidReminders = async () => state.alarms;
  agent.cancelAllReminders = async () => { state.cancels++; state.alarms = []; };
  agent.publishReminder = async request => {
    state.attempts++;
    if (request.hour === failHour) throw Object.assign(new Error('injected publish failure'), { code: 1700002 });
    state.alarms.push(request); return state.attempts;
  };
  return state;
}

(async () => {
  await check('R01-a', '新建/修改计划不应倒造今天已过去的应服记录', 0, () =>
    MedService.pendingDrafts([plan(1)], [med(1)], ts(11, 12), 7).filter(x => x.scheduledTime < ts(11, 12)).length);
  await check('R04-a', '明日开始的计划在明日重建后应有两条提醒', 2, async () => {
    const s = reminderStub();
    const plans = [plan(1), plan(2, '2026-10-12', ['18:00'])];
    await ReminderService.rebuildAll(context, plans, [med(1), med(2)], reminderVocab, ts(11), false);
    await ReminderService.rebuildAll(context, plans, [med(1), med(2)], reminderVocab, ts(12), false);
    return s.alarms.length;
  });
  await check('R05-a', '一条发布失败后下次调用应补足缺失提醒', 2, async () => {
    const s = reminderStub(18);
    const p = [plan(1, '2026-10-01', ['08:00','18:00'])];
    await ReminderService.rebuildAll(context, p, [med(1)], reminderVocab, ts(11), false);
    agent.publishReminder = async req => { s.alarms.push(req); return ++s.attempts; };
    await ReminderService.rebuildAll(context, p, [med(1)], reminderVocab, ts(11), false);
    return s.alarms.length;
  });
  await check('R05-b', '通知发送失败不应返回成功或写入今日已发送标记', { returned: false, marked: false }, async () => {
    const s = reminderStub();
    notification.publish = async () => { throw new Error('injected notification failure'); };
    const returned = await ReminderService.notifyCatchUpOncePerDay(context, 1, 't', 'c', 42);
    return { returned, marked: s.memory.has(PrefKeys.CATCHUP_DATE) };
  });
  await check('R06-a', '独立事务B成功后不应被事务A回滚（且不得并入A的事务）', { rows: ['B'], begins: 2 }, async () => {
    const db = new BpDatabase();
    const rows = [];
    let begins = 0;
    db.store = {
      beginTransaction: async () => { begins++; },
      commit: async () => {},
      rollBack: async () => { rows.length = 0; }
    };
    let release; let entered;
    const hold = new Promise(r => { release = r; });
    const start = new Promise(r => { entered = r; });
    // A 先进入事务并挂起；B 作为**独立事务**发起（不 await，等 A 结束才轮到它）。
    const a = db.runInTransaction(async () => { entered(); await hold; throw new Error('A fails'); }).catch(() => {});
    const b = db.runInTransaction(async () => { rows.push('B'); }).catch(() => {});
    await start;
    release();
    await a; await b;
    return { rows, begins };
  });
  await check('R06-b', 'beginTransaction失败后下一事务仍须调用begin', 2, async () => {
    const db = new BpDatabase(); let calls = 0;
    db.store = { beginTransaction: async () => { calls++; if(calls === 1) throw new Error('begin fails'); },
      commit: async () => {}, rollBack: async () => {} };
    await db.runInTransaction(async () => {}).catch(() => {});
    await db.runInTransaction(async () => {});
    return calls;
  });
  await check('R08-a', '包含秒和毫秒的血压原样回导应全部判重', { added: 0, duplicate: 1 }, () => {
    const r = bp(ts(11, 8, 30, 45, 123));
    const csv = ExportService.buildBpCsv([r], vocab);
    const preview = ImportService.parseBpTable(Csv.parse(csv), vocab,
      new Set([ImportService.bpKey(r.measureTime, r.systolic, r.diastolic)]));
    return { added: preview.drafts.length, duplicate: preview.duplicateCount };
  });
  await check('R08-b', '同一分钟两条独立血压记录换机恢复不得合并', 2, () => {
    const r1 = bp(ts(11, 8, 30, 10)); const r2 = { ...bp(ts(11, 8, 30, 40)), id: 2 };
    return ImportService.parseBpTable(Csv.parse(ExportService.buildBpCsv([r1,r2], vocab)), vocab, new Set()).drafts.length;
  });
  await check('R09-a', '隔两日补记的完整时间不得变成当天', ts(13, 9, 15, 3, 25), () => {
    const l = log(ts(11,8), ts(13,9,15,3,25));
    return ImportService.parseMedTable(Csv.parse(ExportService.buildMedCsv([l],vocab)), vocab, new Set(), new Map()).drafts[0].takenTime;
  });
  await check('R09-b', '刚超过宽限期1毫秒的补记往返后仍是补记', true, () => {
    const l = log(ts(11,8), ts(11,10)+1);
    const d = ImportService.parseMedTable(Csv.parse(ExportService.buildMedCsv([l],vocab)), vocab, new Set(), new Map()).drafts[0];
    return MedService.isMakeUp({ ...l, ...d });
  });
  await check('R10-a', '计划导入已有药品时应同步预览中的新剂量', '2片', async () => {
    const m = med(1); const fake = { runInTransaction: async f => f(), queryMedications: async () => [m],
      setMedicationActive: async () => {}, deleteFuturePendingLogs: async () => {}, upsertPlan: async () => 2,
      updateMedication: async next => { Object.assign(m,next); } };
    await ImportService.commitPlan(fake, { drafts: [{ medName:m.name,dosage:'2片',timeSlots:['18:00'],startDate:'2026-10-11',endDate:null,note:null }],
      errors:[],duplicateCount:0,previewLines:[],totalRows:1 });
    return m.dosage;
  });
  // R10-b 表达改写（报告允许）：修复后语义是「备份里的真实打卡覆盖自动 pending，即更新 1 条」。
  // 原写法只传键集合，无法表达「库内那条是自动 pending 还是真实打卡」——
  // 现在通过 existingPendingKeys（由库内 status 构造）表达同一业务含义，并另加对照组（真实打卡仍判重复）。
  await check('R10-b', '已有自动pending不应把备份taken当普通重复丢弃（改写为：更新 1 条）', 1, () => {
    const l = log(ts(11,8),ts(11,8,5));
    const tuples = [{ medicationId: 1, medName: l.medName, scheduledTime: l.scheduledTime, status: 'pending' }];
    const keys = new Set([ImportService.medKeyById(1, l.scheduledTime), ImportService.medKeyByName(l.medName,l.scheduledTime)]);
    const pendingKeys = ImportService.buildMedPendingKeySet(tuples);
    return ImportService.parseMedTable(Csv.parse(ExportService.buildMedCsv([l],vocab)),vocab,keys,
      new Map([[l.medName,1]]), pendingKeys).drafts.length;
  });
  await check('R10-b2', '已有真实打卡时原样回导仍判重复（不重复入库）', 0, () => {
    const l = log(ts(11,8),ts(11,8,5));
    const tuples = [{ medicationId: 1, medName: l.medName, scheduledTime: l.scheduledTime, status: 'taken' }];
    return ImportService.parseMedTable(Csv.parse(ExportService.buildMedCsv([l],vocab)),vocab,
      ImportService.buildMedKeySet(tuples), new Map([[l.medName,1]]),
      ImportService.buildMedPendingKeySet(tuples)).drafts.length;
  });
  await check('R10-c', '两个同名药品的独立打卡备份不得被合并', 2, () => {
    const a = log(ts(11,8),ts(11,8,5));
    const b = { ...a, id: 2, medicationId: 2, dosage: '2片' };
    return ImportService.parseMedTable(Csv.parse(ExportService.buildMedCsv([a,b],vocab)),vocab,new Set(),new Map()).drafts.length;
  });
  await check('R11-a', '周期内有历史打卡时停用计划后仍显示用药小结', true, () => {
    const r = ReportService.build('week',ReportService.weekRange(ts(11)),[bp(ts(11,8))],
      [log(ts(11,8),ts(11,8,5))],[],VocabFactory.report(context),ts(11,12));
    return r.hasMedPlan;
  });
  await check('R13-a', '导入血压不应接受未来日期及超长备注', 0, () =>
    ImportService.parseBpTable([['2099-10-11','08:00','120','80','70','', 'x'.repeat(101)]],vocab,new Set()).drafts.length);
  await check('R13-b', '外部导入显式非法心率不可静默变为空值', { valid: 0, errors: 1 }, () => {
    const roleIndex = Array(18).fill(-1);
    roleIndex[ColRole.DATE]=0; roleIndex[ColRole.TIME]=1; roleIndex[ColRole.SYSTOLIC]=2;
    roleIndex[ColRole.DIASTOLIC]=3; roleIndex[ColRole.HEART_RATE]=4;
    const p = GenericImportService.parseBp([['2026-10-11','08:00','120','80','abc']],vocab,
      { hasHeader:false, roleIndex,unit:'mmHg',unitScale:1 },new Set());
    return { valid:p.drafts.length,errors:p.errors.length };
  });
  await check('R14-a', '未闭合CSV引号不应被作为有效记录接受', 0, () =>
    ImportService.parseBpTable(Csv.parse('2026-10-11,08:00,120,80,70,,"unfinished'),vocab,new Set()).drafts.length);
  await check('R17-a', '已初始化实例切换测试库名时必须拒绝复用连接', true, async () => {
    const db = new BpDatabase(); db.store = { auditOnly: true };
    let rejected = false;
    try { await db.init(context, 'bp_recorder_unittest.db'); } catch { rejected = true; }
    return rejected;
  });
  await check('R18-a', '一次初始化失败后再次init应重试打开数据库', 2, async () => {
    const db = new BpDatabase(); let opens = 0;
    ark.relationalStore.SecurityLevel = { S1: 1 };
    ark.relationalStore.getRdbStore = async () => { opens++; throw new Error('temporary failure'); };
    await db.init(context).catch(() => {});
    await db.init(context).catch(() => {});
    return opens;
  });
  console.log(JSON.stringify({ cases: results.length, failed: results.filter(r=>!r.pass).length,
    harnessErrors: results.filter(r=>r.harnessError).length, results }, null, 2));
  process.exitCode = results.some(r=>!r.pass) ? 1 : 0;
})();
