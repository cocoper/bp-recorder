import { describe, expect, it, beforeAll, afterAll } from '@ohos/hypium';
import { abilityDelegatorRegistry } from '@kit.TestKit';
import { common } from '@kit.AbilityKit';
import { relationalStore } from '@kit.ArkData';
import { BusinessError } from '@kit.BasicServicesKit';
import { BpDatabase } from '../../../main/ets/service/BpDatabase';
import { MedService } from '../../../main/ets/service/MedService';
import { Medication, MedLog, MedLogDraft, MedPlan, MedPlanDraft } from '../../../main/ets/model/Med';
import { BpRecord, BpRecordDraft } from '../../../main/ets/model/BpRecord';
import { MedLogStatus, Period } from '../../../main/ets/model/Types';
import { DateUtils } from '../../../main/ets/common/DateUtils';
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
  const db: BpDatabase = BpDatabase.getInstance();
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
      try {
        await db.init(ctx, TEST_DB_NAME);
      } catch (err) {
        const be = err as BusinessError;
        const src: string = getTestAbilityContext() !== null ? 'TestAbility' : 'delegator';
        throw new Error(`db.init failed: code=${be.code}, msg=${be.message}, ctxSource=${src}`);
      }
      await db.clearAll();
    });

    afterAll(async () => {
      await db.clearAll();
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

      const id: number = await db.insertBp(draft(128, 82, 72, t1));
      expect(id > 0).assertTrue();

      const page = await db.queryBpPage(0, 20);
      expect(page.total).assertEqual(1);
      expect(page.items[0].systolic).assertEqual(128);

      const loaded: BpRecord | null = await db.queryBpById(id);
      expect(loaded !== null).assertTrue();
      if (loaded === null) {
        return;
      }
      loaded.systolic = 135;
      await db.updateBp(loaded);
      const updated: BpRecord | null = await db.queryBpById(id);
      expect(updated === null ? 0 : updated.systolic).assertEqual(135);

      await db.insertBp(draft(140, 90, null, t2));
      const between = await db.queryBpBetween(t2 - 1000, t2 + 1000);
      expect(between.length).assertEqual(1);

      await db.deleteBp(id);
      const afterDelete = await db.queryBpPage(0, 20);
      expect(afterDelete.total).assertEqual(1);
    });

    it('page_order_is_desc', 0, async () => {
      await db.clearAll();
      const base: number = DateUtils.now();
      for (let i = 0; i < 25; i++) {
        await db.insertBp(draft(120 + i, 80, null, base - i * 60000));
      }
      const first = await db.queryBpPage(0, 20);
      expect(first.items.length).assertEqual(20);
      expect(first.hasMore).assertTrue();
      expect(first.items[0].systolic).assertEqual(120);
      const second = await db.queryBpPage(20, 20);
      expect(second.items.length).assertEqual(5);
      expect(second.hasMore).assertFalse();
    });

    it('medication_plan_log_crud', 0, async () => {
      await db.clearAll();
      const medId: number = await db.insertMedication({ name: '缬沙坦', dosage: '1片/80mg', note: null }, true);
      const planDraft: MedPlanDraft = {
        medicationId: medId, timeSlots: ['07:30', '18:00'],
        startDate: DateUtils.formatDate(DateUtils.now()), endDate: null
      };
      const planId: number = await db.upsertPlan(planDraft);
      expect(planId > 0).assertTrue();

      const plans: MedPlan[] = await db.queryActivePlans();
      expect(plans.length).assertEqual(1);
      expect(plans[0].timeSlots.length).assertEqual(2);

      const today: number = DateUtils.now();
      const drafts: MedLogDraft[] = MedService.pendingDrafts(plans, await db.queryMedications(), today, 7);
      const inserted: number = await db.insertMissingLogs(drafts);
      expect(inserted).assertEqual(drafts.length);

      // 幂等：重复预生成不再新增（CL-8）
      const again: number = await db.insertMissingLogs(drafts);
      expect(again).assertEqual(0);

      const logs: MedLog[] = await db.queryMedLogsOfDay(today);
      expect(logs.length > 0).assertTrue();
      const target: MedLog = logs[0];
      await db.updateMedLogStatus(target.id, MedLogStatus.TAKEN, DateUtils.now(), null);
      const after = await db.queryMedLog(target.medicationId, target.scheduledTime);
      expect(after === null ? '' : `${after.status}`).assertEqual(`${MedLogStatus.TAKEN}`);

      // 停用计划不影响历史打卡
      await db.deactivatePlan(planId);
      expect((await db.queryActivePlans()).length).assertEqual(0);
      expect((await db.queryMedLogsOfDay(today)).length > 0).assertTrue();
    });

    it('mark_missed_overdue', 0, async () => {
      await db.clearAll();
      const medId: number = await db.insertMedication({ name: '二甲双胍', dosage: '1片', note: null }, true);
      await db.upsertPlan({
        medicationId: medId, timeSlots: ['07:30'],
        startDate: DateUtils.formatDate(DateUtils.addDays(DateUtils.now(), -3)), endDate: null
      });
      const plans: MedPlan[] = await db.queryActivePlans();
      const meds: Medication[] = await db.queryMedications();
      await db.insertMissingLogs(MedService.pendingDrafts(plans, meds, DateUtils.now(), 4));

      const now: number = DateUtils.now();
      const marked: number = await db.markMissed(now);
      expect(marked > 0).assertTrue();
      const logs: MedLog[] = await db.queryMedLogsBetween(0, Number.MAX_SAFE_INTEGER);
      let missed: number = 0;
      for (let i = 0; i < logs.length; i++) {
        if (logs[i].status === MedLogStatus.MISSED) {
          missed++;
        }
      }
      expect(missed).assertEqual(marked);
    });

    it('transaction_rollback', 0, async () => {
      await db.clearAll();
      const before: number = await db.countBp();
      let threw: boolean = false;
      try {
        // 事务中先成功插入一条，再抛错 → 整批回滚，不产生半批数据（FR-6.8）
        await db.runInTransaction(async () => {
          await db.insertBp(draft(130, 85, null, DateUtils.now()));
          throw new Error('simulated failure');
        });
      } catch (err) {
        threw = true;
      }
      expect(threw).assertTrue();
      expect(await db.countBp()).assertEqual(before);
    });

    it('clear_all_removes_everything', 0, async () => {
      await db.insertBp(draft(126, 80, 70, DateUtils.now()));
      const medId: number = await db.insertMedication({ name: '阿司匹林', dosage: '1片', note: null }, true);
      await db.upsertPlan({
        medicationId: medId, timeSlots: ['12:00'],
        startDate: DateUtils.formatDate(DateUtils.now()), endDate: null
      });
      await db.clearAll();
      expect(await db.countBp()).assertEqual(0);
      expect(await db.countMedLogs()).assertEqual(0);
      expect((await db.queryMedications()).length).assertEqual(0);
      expect((await db.queryPlans()).length).assertEqual(0);
    });

    // ── 以下三条用例对应 v1.3 审查意见的 P1-3 与 P1-4 ──

    it('unique_triple_index_enforced', 0, async () => {
      await db.clearAll();
      const t: number = DateUtils.now() - 1000;
      await db.insertBp(draft(150, 95, null, t));
      let threw: boolean = false;
      try {
        // 同「测量时间 + 收缩压 + 舒张压」重复插入应被唯一索引拒绝（P1-4）
        await db.insertBp(draft(150, 95, null, t));
      } catch (err) {
        threw = true;
      }
      expect(threw).assertTrue();
      expect(await db.countBp()).assertEqual(1);
    });

    it('exists_bp_triple_precheck', 0, async () => {
      await db.clearAll();
      const t: number = DateUtils.now() - 2000;
      const id: number = await db.insertBp(draft(148, 92, null, t));
      expect(await db.existsBpTriple(t, 148, 92, 0)).assertTrue();
      // 编辑自身时应排除自己，否则会误判为重复
      expect(await db.existsBpTriple(t, 148, 92, id)).assertFalse();
      expect(await db.existsBpTriple(t, 148, 93, 0)).assertFalse();
    });

    it('delete_future_pending_logs_only', 0, async () => {
      await db.clearAll();
      const now: number = DateUtils.now();
      const medId: number = await db.insertMedication({ name: '测试药', dosage: '1片', note: null }, true);
      // 过去的待服：是当时真实存在的服药义务 → 必须保留（会在超时后派生为漏服）
      await db.insertMedLogForImport(medId, '测试药', '1片', now - 3600000,
        MedLogStatus.PENDING, null, null);
      // 未来的待服：按旧计划预生成、尚未发生 → 计划变更后应被清理（P1-3）
      await db.insertMedLogForImport(medId, '测试药', '1片', now + 3600000,
        MedLogStatus.PENDING, null, null);
      // 未来的已服：历史记录 → 永不删除
      await db.insertMedLogForImport(medId, '测试药', '1片', now + 7200000,
        MedLogStatus.TAKEN, now, null);

      const removed: number = await db.deleteFuturePendingLogs(medId, now);
      expect(removed).assertEqual(1);
      const rest: MedLog[] = await db.queryMedLogsBetween(0, Number.MAX_SAFE_INTEGER);
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

    it('period_roundtrip', 0, async () => {
      await db.clearAll();
      const t: number = DateUtils.atMinutesOfDay(DateUtils.now(), 7 * 60 + 30);
      const id: number = await db.insertBp(draft(122, 78, 66, t));
      const loaded: BpRecord | null = await db.queryBpById(id);
      expect(loaded === null ? '' : `${loaded.period}`).assertEqual(`${Period.MORNING}`);
    });
  });
}
