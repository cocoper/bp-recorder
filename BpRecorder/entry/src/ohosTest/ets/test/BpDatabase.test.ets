import { describe, expect, it, beforeAll, afterAll } from '@ohos/hypium';
import { abilityDelegatorRegistry } from '@kit.TestKit';
import { common } from '@kit.AbilityKit';
import { relationalStore } from '@kit.ArkData';
import { BusinessError } from '@kit.BasicServicesKit';
import { BpDatabase, SaveMedicationPlanResult, TxSession } from '../../../main/ets/service/BpDatabase';
import { MedService } from '../../../main/ets/service/MedService';
import { Medication, MedLog, MedLogDraft, MedPlan, MedPlanDraft } from '../../../main/ets/model/Med';
import { BpRecord, BpRecordDraft } from '../../../main/ets/model/BpRecord';
import { MedLogStatus, Period } from '../../../main/ets/model/Types';
import { DateUtils } from '../../../main/ets/common/DateUtils';
import { MedLimits } from '../../../main/ets/common/Constants';
import { getTestAbilityContext } from '../testability/TestContext';

/**
 * 数据层单测（CL-1 CRUD 主路径 / CL-8 预生成幂等 / FR-6.8 事务回滚）。
 *
 * 安全纪律（2026-10-08 修订，教训：本用例曾在生产库上执行 clearAll，
 * 仅因 init 抛错才未清空用户数据）：
 * 1. 必须使用**独立测试库** `bp_recorder_unittest.db`，绝不允许触碰生产库；
 * 2. context 必须用 TestAbility.onCreate 里存下的真实 UIAbilityContext
 *    （aa test 进程里 delegator 的两种取法都会被 relationalStore 判为
 *    Illegal context，见 TestContext.ets 的背景注释）；
 * 3. afterAll 删除测试库文件，做到零残留。
 */
const TEST_DB_NAME: string = 'bp_recorder_unittest.db';

export default function bpDatabaseTest() {
  // 审查 R17：测试**不得**通过 getInstance() 拿生产单例（过去会因已初始化而复用生产连接）。
  // 一律用 createIsolated(测试库名) 建独立实例；库名不是 bp_recorder_unittest 前缀会直接抛错。
  let db: BpDatabase | null = null;
  const requireDb = (): BpDatabase => {
    const inst: BpDatabase | null = db;
    if (inst === null) {
      throw new Error('测试实例未初始化：beforeAll 失败时不应继续执行用例');
    }
    return inst;
  };
  const clearTestDb = async (): Promise<void> => {
    const inst: BpDatabase = requireDb();
    inst.requireTestInstance('clearAll');
    await inst.clearAll();
  };
  let context: common.Context | null = null;

  const draft = (sys: number, dia: number, hr: number | null, t: number): BpRecordDraft => ({
    systolic: sys, diastolic: dia, heartRate: hr, measureTime: t,
    period: DateUtils.periodOf(t), note: null
  });

  describe('BpDatabaseTest', () => {
    beforeAll(async () => {
      const delegator = abilityDelegatorRegistry.getAbilityDelegator();
      // aa test 不会自动创建 TestAbility（2026-10-08 实测：onCreate 未执行），
      // 需要显式拉起，等它把真实 context 写进 TestContext。
      if (getTestAbilityContext() === null) {
        try {
          await delegator.startAbility({
            bundleName: 'com.bp.recorder',
            moduleName: 'entry_test',
            abilityName: 'TestAbility'
          });
        } catch (err) {
          // 已在前台等情况会报错，忽略后继续等 context
        }
        for (let i = 0; i < 50 && getTestAbilityContext() === null; i++) {
          await new Promise<void>((resolve) => {
            setTimeout(resolve, 100);
          });
        }
      }
      let ctx: common.Context | null = getTestAbilityContext();
      if (ctx === null) {
        ctx = delegator.getAppContext();
      }
      context = ctx;
      // 诊断（2026-10-08）：把 context 来源与真实错误码带进失败信息，
      // 便于区分「context 非法」与「别的原因」。
      db = BpDatabase.createIsolated(TEST_DB_NAME);
      try {
        await requireDb().init(ctx, TEST_DB_NAME);
      } catch (err) {
        const be = err as BusinessError;
        const src: string = getTestAbilityContext() !== null ? 'TestAbility' : 'delegator';
        throw new Error(`db.init failed: code=${be.code}, msg=${be.message}, ctxSource=${src}`);
      }
      await clearTestDb();
    });

    afterAll(async () => {
      // 审查 R17：只有确实打开了测试库才允许清空/删除；先关连接再删库。
      const inst: BpDatabase | null = db;
      if (inst !== null && inst.isReady()) {
        inst.requireTestInstance('afterAll 清空');
        await inst.clearAll();
        await inst.close();
      }
      // 删除测试库文件，避免在设备上留下残留
      const ctx: common.Context | null = context;
      if (ctx !== null) {
        try {
          await relationalStore.deleteRdbStore(ctx, {
            name: TEST_DB_NAME,
            securityLevel: relationalStore.SecurityLevel.S1
          });
        } catch (err) {
          // 删除失败不阻断测试结论
        }
      }
    });

    it('insert_query_update_delete', 0, async () => {
      const t1: number = DateUtils.now() - 3600000;
      const t2: number = DateUtils.now() - 7200000;

      const id: number = await requireDb().insertBp(draft(128, 82, 72, t1));
      expect(id > 0).assertTrue();

      const page = await requireDb().queryBpPage(0, 20);
      expect(page.total).assertEqual(1);
      expect(page.items[0].systolic).assertEqual(128);

      const loaded: BpRecord | null = await requireDb().queryBpById(id);
      expect(loaded !== null).assertTrue();
      if (loaded === null) {
        return;
      }
      loaded.systolic = 135;
      await requireDb().updateBp(loaded);
      const updated: BpRecord | null = await requireDb().queryBpById(id);
      expect(updated === null ? 0 : updated.systolic).assertEqual(135);

      await requireDb().insertBp(draft(140, 90, null, t2));
      const between = await requireDb().queryBpBetween(t2 - 1000, t2 + 1000);
      expect(between.length).assertEqual(1);

      await requireDb().deleteBp(id);
      const afterDelete = await requireDb().queryBpPage(0, 20);
      expect(afterDelete.total).assertEqual(1);
    });

    it('page_order_is_desc', 0, async () => {
      await clearTestDb();
      const base: number = DateUtils.now();
      for (let i = 0; i < 25; i++) {
        await requireDb().insertBp(draft(120 + i, 80, null, base - i * 60000));
      }
      const first = await requireDb().queryBpPage(0, 20);
      expect(first.items.length).assertEqual(20);
      expect(first.hasMore).assertTrue();
      expect(first.items[0].systolic).assertEqual(120);
      const second = await requireDb().queryBpPage(20, 20);
      expect(second.items.length).assertEqual(5);
      expect(second.hasMore).assertFalse();
    });

    it('medication_plan_log_crud', 0, async () => {
      await clearTestDb();
      const medId: number = await requireDb().insertMedication({ name: '缬沙坦', dosage: '1片/80mg', note: null }, true);
      const planDraft: MedPlanDraft = {
        medicationId: medId, timeSlots: ['07:30', '18:00'],
        startDate: DateUtils.formatDate(DateUtils.now()), endDate: null
      };
      const planId: number = await requireDb().upsertPlan(planDraft);
      expect(planId > 0).assertTrue();

      const plans: MedPlan[] = await requireDb().queryActivePlans();
      expect(plans.length).assertEqual(1);
      expect(plans[0].timeSlots.length).assertEqual(2);

      const today: number = DateUtils.now();
      const drafts: MedLogDraft[] = MedService.pendingDrafts(plans, await requireDb().queryMedications(), today, 7);
      const inserted: number = await requireDb().insertMissingLogs(drafts);
      expect(inserted).assertEqual(drafts.length);

      // 幂等：重复预生成不再新增（CL-8）
      const again: number = await requireDb().insertMissingLogs(drafts);
      expect(again).assertEqual(0);

      const logs: MedLog[] = await requireDb().queryMedLogsOfDay(today);
      expect(logs.length > 0).assertTrue();
      const target: MedLog = logs[0];
      await requireDb().updateMedLogStatus(target.id, MedLogStatus.TAKEN, DateUtils.now(), null);
      const after = await requireDb().queryMedLog(target.medicationId, target.scheduledTime);
      expect(after === null ? '' : `${after.status}`).assertEqual(`${MedLogStatus.TAKEN}`);

      // 停用计划不影响历史打卡
      await requireDb().deactivatePlan(planId);
      expect((await requireDb().queryActivePlans()).length).assertEqual(0);
      expect((await requireDb().queryMedLogsOfDay(today)).length > 0).assertTrue();
    });

    it('mark_missed_overdue', 0, async () => {
      await clearTestDb();
      const medId: number = await requireDb().insertMedication({ name: '二甲双胍', dosage: '1片', note: null }, true);
      await requireDb().upsertPlan({
        medicationId: medId, timeSlots: ['07:30'],
        startDate: DateUtils.formatDate(DateUtils.addDays(DateUtils.now(), -3)), endDate: null
      });
      const plans: MedPlan[] = await requireDb().queryActivePlans();
      const meds: Medication[] = await requireDb().queryMedications();
      await requireDb().insertMissingLogs(MedService.pendingDrafts(plans, meds, DateUtils.now(), 4));

      const now: number = DateUtils.now();
      const marked: number = await requireDb().markMissed(now);
      expect(marked > 0).assertTrue();
      const logs: MedLog[] = await requireDb().queryMedLogsBetween(0, Number.MAX_SAFE_INTEGER);
      let missed: number = 0;
      for (let i = 0; i < logs.length; i++) {
        if (logs[i].status === MedLogStatus.MISSED) {
          missed++;
        }
      }
      expect(missed).assertEqual(marked);
    });

    it('transaction_rollback', 0, async () => {
      await clearTestDb();
      const before: number = await requireDb().countBp();
      let threw: boolean = false;
      try {
        // 事务中先成功插入一条，再抛错 → 整批回滚，不产生半批数据（FR-6.8）
        await requireDb().runInTransaction(async () => {
          await requireDb().insertBp(draft(130, 85, null, DateUtils.now()));
          throw new Error('simulated failure');
        });
      } catch (err) {
        threw = true;
      }
      expect(threw).assertTrue();
      expect(await requireDb().countBp()).assertEqual(before);
    });

    it('clear_all_removes_everything', 0, async () => {
      await requireDb().insertBp(draft(126, 80, 70, DateUtils.now()));
      const medId: number = await requireDb().insertMedication({ name: '阿司匹林', dosage: '1片', note: null }, true);
      await requireDb().upsertPlan({
        medicationId: medId, timeSlots: ['12:00'],
        startDate: DateUtils.formatDate(DateUtils.now()), endDate: null
      });
      await clearTestDb();
      expect(await requireDb().countBp()).assertEqual(0);
      expect(await requireDb().countMedLogs()).assertEqual(0);
      expect((await requireDb().queryMedications()).length).assertEqual(0);
      expect((await requireDb().queryPlans()).length).assertEqual(0);
    });

    // ── 以下三条用例对应 v1.3 审查意见的 P1-3 与 P1-4 ──

    it('unique_triple_index_enforced', 0, async () => {
      await clearTestDb();
      const t: number = DateUtils.now() - 1000;
      await requireDb().insertBp(draft(150, 95, null, t));
      let threw: boolean = false;
      try {
        // 同「测量时间 + 收缩压 + 舒张压」重复插入应被唯一索引拒绝（P1-4）
        await requireDb().insertBp(draft(150, 95, null, t));
      } catch (err) {
        threw = true;
      }
      expect(threw).assertTrue();
      expect(await requireDb().countBp()).assertEqual(1);
    });

    it('exists_bp_triple_precheck', 0, async () => {
      await clearTestDb();
      const t: number = DateUtils.now() - 2000;
      const id: number = await requireDb().insertBp(draft(148, 92, null, t));
      expect(await requireDb().existsBpTriple(t, 148, 92, 0)).assertTrue();
      // 编辑自身时应排除自己，否则会误判为重复
      expect(await requireDb().existsBpTriple(t, 148, 92, id)).assertFalse();
      expect(await requireDb().existsBpTriple(t, 148, 93, 0)).assertFalse();
    });

    it('delete_future_pending_logs_only', 0, async () => {
      await clearTestDb();
      const now: number = DateUtils.now();
      const medId: number = await requireDb().insertMedication({ name: '测试药', dosage: '1片', note: null }, true);
      // 过去的待服：是当时真实存在的服药义务 → 必须保留（会在超时后派生为漏服）
      await requireDb().insertMedLogForImport(medId, '测试药', '1片', now - 3600000,
        MedLogStatus.PENDING, null, null);
      // 未来的待服：按旧计划预生成、尚未发生 → 计划变更后应被清理（P1-3）
      await requireDb().insertMedLogForImport(medId, '测试药', '1片', now + 3600000,
        MedLogStatus.PENDING, null, null);
      // 未来的已服：历史记录 → 永不删除
      await requireDb().insertMedLogForImport(medId, '测试药', '1片', now + 7200000,
        MedLogStatus.TAKEN, now, null);

      const removed: number = await requireDb().deleteFuturePendingLogs(medId, now);
      expect(removed).assertEqual(1);
      const rest: MedLog[] = await requireDb().queryMedLogsBetween(0, Number.MAX_SAFE_INTEGER);
      expect(rest.length).assertEqual(2);
      let pendingPast: number = 0;
      let takenFuture: number = 0;
      for (let i = 0; i < rest.length; i++) {
        if (rest[i].status === MedLogStatus.PENDING && rest[i].scheduledTime < now) {
          pendingPast++;
        }
        if (rest[i].status === MedLogStatus.TAKEN && rest[i].scheduledTime > now) {
          takenFuture++;
        }
      }
      expect(pendingPast).assertEqual(1);
      expect(takenFuture).assertEqual(1);
    });

    // 审查 R07：归档药品通过「保存服药计划」恢复使用时必须真正复活（is_active 显式写回），
    // 且药品/计划/待服在同一事务内提交。真实数据库验证，不使用任何桩。
    it('plan_save_reactivates_archived_medication', 0, async () => {
      await clearTestDb();
      const now: number = DateUtils.now();
      const medId: number = await requireDb().insertMedication({ name: '测试药复活', dosage: '1片', note: null }, true);
      await requireDb().upsertPlan({
        medicationId: medId,
        timeSlots: ['08:00'],
        startDate: DateUtils.formatDate(now),
        endDate: null
      });

      await requireDb().archiveMedication(medId, now);
      const afterArchive: Medication[] = await requireDb().queryMedications();
      let archivedActive: boolean = true;
      for (let i = 0; i < afterArchive.length; i++) {
        if (afterArchive[i].id === medId) {
          archivedActive = afterArchive[i].isActive;
        }
      }
      expect(archivedActive).assertFalse();

      const result: SaveMedicationPlanResult = await requireDb().saveMedicationAndPlan({
        medicationId: medId,
        medication: { name: '测试药复活', dosage: '2片', note: null },
        plan: { medicationId: medId, timeSlots: ['09:00'], startDate: DateUtils.formatDate(now), endDate: null },
        regenerateFrom: now,
        preGenDays: MedLimits.PRE_GEN_DAYS
      }, async (tx: TxSession, id: number): Promise<number> => {
        const plans: MedPlan[] = await requireDb().queryActivePlans();
        const meds: Medication[] = await requireDb().queryMedications();
        return requireDb().insertMissingLogs(MedService.pendingDrafts(plans, meds, now, MedLimits.PRE_GEN_DAYS), tx);
      });

      expect(result.medicationId).assertEqual(medId);
      expect(result.generatedPending > 0).assertTrue();

      const after: Medication[] = await requireDb().queryMedications();
      let revived: boolean = false;
      let dosage: string = '';
      for (let i = 0; i < after.length; i++) {
        if (after[i].id === medId) {
          revived = after[i].isActive;
          dosage = after[i].dosage;
        }
      }
      expect(revived).assertTrue();
      expect(dosage).assertEqual('2片');
    });

    it('period_roundtrip', 0, async () => {
      await clearTestDb();
      const t: number = DateUtils.atMinutesOfDay(DateUtils.now(), 7 * 60 + 30);
      const id: number = await requireDb().insertBp(draft(122, 78, 66, t));
      const loaded: BpRecord | null = await requireDb().queryBpById(id);
      expect(loaded === null ? '' : `${loaded.period}`).assertEqual(`${Period.MORNING}`);
    });
  });
}
