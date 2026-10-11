import { relationalStore } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { BpDedupeTuple, BpRecord, BpRecordDraft, PageResult } from '../model/BpRecord';
import { MedDedupeTuple, Medication, MedicationDraft, MedLog, MedLogDraft, MedPlan, MedPlanDraft } from '../model/Med';
import { MedLogStatus, parseMedLogStatus, parsePeriod } from '../model/Types';
import { DbConst, MedLimits } from '../common/Constants';
import { DateUtils } from '../common/DateUtils';
import { AppError } from '../common/Errors';
import { Logger } from '../common/Logger';

const TAG: string = 'BpDatabase';

/** bp_record 查询列（显式列出，避免依赖列顺序） */
const COLS_BP: string[] = [
  'id', 'systolic', 'diastolic', 'heart_rate', 'measure_time', 'period', 'note',
  'user_id', 'source', 'created_at', 'updated_at'
];
const COLS_MED: string[] = ['id', 'name', 'dosage', 'note', 'is_active', 'created_at', 'updated_at'];
const COLS_PLAN: string[] = ['id', 'medication_id', 'time_slots', 'start_date', 'end_date', 'is_active', 'created_at', 'updated_at'];
const COLS_LOG: string[] = ['id', 'medication_id', 'med_name', 'dosage', 'scheduled_time', 'taken_time', 'status', 'note', 'created_at', 'updated_at'];

/** 建表语句（严格对齐策划文档 §3.1） */
const DDL: string[] = [
  `CREATE TABLE IF NOT EXISTS bp_record (
     id           INTEGER PRIMARY KEY AUTOINCREMENT,
     systolic     INTEGER NOT NULL,
     diastolic    INTEGER NOT NULL,
     heart_rate   INTEGER,
     measure_time INTEGER NOT NULL,
     period       TEXT    NOT NULL,
     note         TEXT,
     user_id      INTEGER NOT NULL DEFAULT 1,
     source       TEXT    NOT NULL DEFAULT 'manual',
     created_at   INTEGER NOT NULL,
     updated_at   INTEGER NOT NULL
   )`,
  `CREATE INDEX IF NOT EXISTS idx_measure_time ON bp_record (measure_time DESC)`,
  `CREATE INDEX IF NOT EXISTS idx_period_time ON bp_record (period, measure_time)`,
  `CREATE TABLE IF NOT EXISTS medication (
     id         INTEGER PRIMARY KEY AUTOINCREMENT,
     name       TEXT    NOT NULL,
     dosage     TEXT    NOT NULL,
     note       TEXT,
     is_active  INTEGER NOT NULL DEFAULT 1,
     created_at INTEGER NOT NULL,
     updated_at INTEGER NOT NULL
   )`,
  `CREATE TABLE IF NOT EXISTS med_plan (
     id            INTEGER PRIMARY KEY AUTOINCREMENT,
     medication_id INTEGER NOT NULL REFERENCES medication(id),
     time_slots    TEXT    NOT NULL,
     start_date    TEXT    NOT NULL,
     end_date      TEXT,
     is_active     INTEGER NOT NULL DEFAULT 1,
     created_at    INTEGER NOT NULL,
     updated_at    INTEGER NOT NULL
   )`,
  `CREATE INDEX IF NOT EXISTS idx_plan_med ON med_plan (medication_id)`,
  `CREATE TABLE IF NOT EXISTS med_log (
     id             INTEGER PRIMARY KEY AUTOINCREMENT,
     medication_id  INTEGER NOT NULL,
     med_name       TEXT    NOT NULL,
     dosage         TEXT    NOT NULL,
     scheduled_time INTEGER NOT NULL,
     taken_time     INTEGER,
     status         TEXT    NOT NULL DEFAULT 'pending',
     note           TEXT,
     created_at     INTEGER NOT NULL,
     updated_at     INTEGER NOT NULL
   )`,
  `CREATE INDEX IF NOT EXISTS idx_medlog_scheduled ON med_log (scheduled_time)`,
  `CREATE INDEX IF NOT EXISTS idx_medlog_med_time ON med_log (medication_id, scheduled_time)`,
  // 幂等约束：保证 §3.1「预生成幂等」与「导入判重」在数据库层面成立。
  // 策划文档表结构中未列此约束，属实现层补齐（见实现方案 §9.4-D2）。
  `CREATE UNIQUE INDEX IF NOT EXISTS uidx_medlog_med_time ON med_log (medication_id, scheduled_time)`
];

/**
 * 数据访问层（单例）。
 *
 * 职责：4 张表的建表/迁移与全部 CRUD、事务封装。
 * 设计要点：
 * - 全局单例，App 启动时初始化一次并复用连接，避免频繁开关库（性能要求 NFR-1/NFR-3）。
 * - 所有写操作失败均向上抛出，由页面统一提示（NFR-6：写入失败必须有兜底提示）。
 * - 事务封装支持嵌套调用（内层复用外层事务），防止 SQLite 不支持嵌套事务导致报错。
 */
export class BpDatabase {
  private static instance: BpDatabase | null = null;
  private store: relationalStore.RdbStore | null = null;
  private initPromise: Promise<void> | null = null;
  private inTransaction: boolean = false;

  static getInstance(): BpDatabase {
    if (BpDatabase.instance === null) {
      BpDatabase.instance = new BpDatabase();
    }
    return BpDatabase.instance;
  }

  /** 是否已就绪（页面可据此决定是否显示「数据库初始化失败」提示） */
  isReady(): boolean {
    return this.store !== null;
  }

  /**
   * 初始化：建表 + 版本迁移。重复调用安全（幂等）。
   * 初始化失败会抛错，调用方需捕获并提示用户（CL-1：不闪退）。
   *
   * @param storeName 数据库文件名，默认 `DbConst.NAME`。
   *   单元测试必须传入独立的测试库名（如 `bp_recorder_unittest.db`），
   *   否则测试的 clearAll 会清空用户真实数据（2026-10-08 复盘：BpDatabaseTest
   *   曾直接在生产库上跑，仅因 init 失败才未造成数据丢失）。
   */
  async init(context: common.Context, storeName: string = DbConst.NAME): Promise<void> {
    if (this.store !== null) {
      return;
    }
    if (this.initPromise === null) {
      this.initPromise = this.doInit(context, storeName);
    }
    return this.initPromise;
  }

  private async doInit(context: common.Context, storeName: string): Promise<void> {
    const config: relationalStore.StoreConfig = {
      name: storeName,
      securityLevel: relationalStore.SecurityLevel.S1
    };
    const store: relationalStore.RdbStore = await relationalStore.getRdbStore(context, config);
    for (let i = 0; i < DDL.length; i++) {
      await store.executeSql(DDL[i]);
    }
    await BpDatabase.migrate(store);
    this.store = store;
    Logger.info(TAG, `database ready, schemaVersion=${DbConst.SCHEMA_VERSION}`);
  }

  /** 版本化迁移：以 PRAGMA user_version 为基准，整体在一个事务内完成 */
  private static async migrate(store: relationalStore.RdbStore): Promise<void> {
    const current: number = await BpDatabase.readUserVersion(store);
    if (current >= DbConst.SCHEMA_VERSION) {
      return;
    }

    await store.beginTransaction();
    try {
      if (current < 2) {
        // ── v1 → v2 ──
        // 背景：v1 的「导入判重三元组」与「每个药品一条生效计划」只活在应用层，
        // 数据库无约束保障（v1.3 审查意见 P1-4）。v2 补齐结构级约束。
        // 建唯一索引前必须先清理历史脏数据，否则索引创建会失败并导致整个应用无法启动。

        // 1) 清理同三元组（测量时间 + 收缩压 + 舒张压）的重复血压记录，保留最早一条
        await store.executeSql(
          `DELETE FROM ${DbConst.T_BP} WHERE id NOT IN (
             SELECT MIN(id) FROM ${DbConst.T_BP}
             GROUP BY measure_time, systolic, diastolic)`
        );

        // 2) 同一药品若存在多条生效计划，只保留最新一条，其余置为停用
        await store.executeSql(
          `UPDATE ${DbConst.T_PLAN} SET is_active = 0
           WHERE is_active = 1 AND id NOT IN (
             SELECT MAX(id) FROM ${DbConst.T_PLAN}
             WHERE is_active = 1 GROUP BY medication_id)`
        );

        // 3) 建立唯一索引（部分唯一索引需 SQLite ≥ 3.8，relationalStore 为 3.32+）
        await store.executeSql(
          `CREATE UNIQUE INDEX IF NOT EXISTS uidx_bp_triple
             ON ${DbConst.T_BP} (measure_time, systolic, diastolic)`
        );
        await store.executeSql(
          `CREATE UNIQUE INDEX IF NOT EXISTS uidx_plan_active_med
             ON ${DbConst.T_PLAN} (medication_id) WHERE is_active = 1`
        );
      }

      await store.executeSql(`PRAGMA user_version = ${DbConst.SCHEMA_VERSION}`);
      await store.commit();
      Logger.info(TAG, `schema migrated: ${current} -> ${DbConst.SCHEMA_VERSION}`);
    } catch (err) {
      const e = err as BusinessError;
      Logger.error(TAG, `migration failed, rolling back: code=${e.code}, message=${e.message}`);
      try {
        await store.rollBack();
      } catch (rollbackErr) {
        const re = rollbackErr as BusinessError;
        Logger.error(TAG, `migration rollback failed: code=${re.code}, message=${re.message}`);
      }
      // BusinessError 是 interface，不能直接 throw（arkts-limited-throw），转成 Error 子类
      throw new AppError(e.code, e.message);
    }
  }

  private static async readUserVersion(store: relationalStore.RdbStore): Promise<number> {
    const rs: relationalStore.ResultSet = await store.querySql('PRAGMA user_version');
    let version: number = 0;
    try {
      if (rs.goToFirstRow()) {
        version = rs.getLong(0);
      }
    } finally {
      rs.close();
    }
    return version;
  }

  private requireStore(): relationalStore.RdbStore {
    const store: relationalStore.RdbStore | null = this.store;
    if (store === null) {
      throw new Error('BP_DB_NOT_READY');
    }
    return store;
  }

  // ───────────────────────── 事务 ─────────────────────────

  /**
   * 事务执行器。任何异常都会回滚并向上抛出（FR-6.8：不产生半批数据）。
   * 嵌套调用时直接复用外层事务，避免 SQLite 报「cannot start a transaction within a transaction」。
   */
  async runInTransaction(work: () => Promise<void>): Promise<void> {
    const store: relationalStore.RdbStore = this.requireStore();
    if (this.inTransaction) {
      await work();
      return;
    }
    this.inTransaction = true;
    await store.beginTransaction();
    try {
      await work();
      await store.commit();
    } catch (err) {
      const e = err as BusinessError;
      Logger.error(TAG, `transaction failed, rolling back: code=${e.code}, message=${e.message}`);
      try {
        await store.rollBack();
      } catch (rollbackErr) {
        const re = rollbackErr as BusinessError;
        Logger.error(TAG, `rollback failed: code=${re.code}, message=${re.message}`);
      }
      // 同上：转成 Error 子类后再抛出
      throw new AppError(e.code, e.message);
    } finally {
      this.inTransaction = false;
    }
  }

  // ───────────────────────── bp_record ─────────────────────────

  /** 新增血压记录，返回新行 id */
  async insertBp(draft: BpRecordDraft): Promise<number> {
    const store: relationalStore.RdbStore = this.requireStore();
    const now: number = DateUtils.now();
    const values: relationalStore.ValuesBucket = {
      'systolic': draft.systolic,
      'diastolic': draft.diastolic,
      'heart_rate': draft.heartRate,
      'measure_time': draft.measureTime,
      'period': `${draft.period}`,
      'note': draft.note,
      'user_id': 1,
      'source': 'manual',
      'created_at': now,
      'updated_at': now
    };
    try {
      return await store.insert(DbConst.T_BP, values);
    } catch (err) {
      const e = err as BusinessError;
      Logger.error(TAG, `insertBp failed: code=${e.code}, message=${e.message}`);
      throw new AppError(e.code, e.message);
    }
  }

  /** 批量新增（导入用），返回成功条数 */
  async batchInsertBp(drafts: BpRecordDraft[]): Promise<number> {
    if (drafts.length === 0) {
      return 0;
    }
    const store: relationalStore.RdbStore = this.requireStore();
    const now: number = DateUtils.now();
    const buckets: relationalStore.ValuesBucket[] = [];
    for (let i = 0; i < drafts.length; i++) {
      const d: BpRecordDraft = drafts[i];
      buckets.push({
        'systolic': d.systolic,
        'diastolic': d.diastolic,
        'heart_rate': d.heartRate,
        'measure_time': d.measureTime,
        'period': `${d.period}`,
        'note': d.note,
        'user_id': 1,
        'source': 'manual',
        'created_at': now,
        'updated_at': now
      });
    }
    try {
      return await store.batchInsert(DbConst.T_BP, buckets);
    } catch (err) {
      const e = err as BusinessError;
      Logger.error(TAG, `batchInsertBp failed: code=${e.code}, message=${e.message}`);
      throw new AppError(e.code, e.message);
    }
  }

  /** 更新血压记录（按 id） */
  async updateBp(record: BpRecord): Promise<number> {
    const store: relationalStore.RdbStore = this.requireStore();
    const values: relationalStore.ValuesBucket = {
      'systolic': record.systolic,
      'diastolic': record.diastolic,
      'heart_rate': record.heartRate,
      'measure_time': record.measureTime,
      'period': `${record.period}`,
      'note': record.note,
      'updated_at': DateUtils.now()
    };
    const predicates: relationalStore.RdbPredicates = new relationalStore.RdbPredicates(DbConst.T_BP);
    predicates.equalTo('id', record.id);
    return store.update(values, predicates);
  }

  /** 删除血压记录（不可逆，UI 层负责二次确认，CL-1） */
  async deleteBp(id: number): Promise<number> {
    const store: relationalStore.RdbStore = this.requireStore();
    const predicates: relationalStore.RdbPredicates = new relationalStore.RdbPredicates(DbConst.T_BP);
    predicates.equalTo('id', id);
    return store.delete(predicates);
  }

  /** 分页查询（measure_time 倒序，FR-2.1 / FR-2.3） */
  async queryBpPage(offset: number, limit: number): Promise<PageResult<BpRecord>> {
    const store: relationalStore.RdbStore = this.requireStore();
    const safeOffset: number = offset < 0 ? 0 : offset;
    const safeLimit: number = limit < 1 ? 1 : limit;

    const predicates: relationalStore.RdbPredicates = new relationalStore.RdbPredicates(DbConst.T_BP);
    predicates.orderByDesc('measure_time');
    predicates.offsetAs(safeOffset);
    predicates.limitAs(safeLimit);

    const items: BpRecord[] = [];
    const rs: relationalStore.ResultSet = await store.query(predicates, COLS_BP);
    try {
      while (rs.goToNextRow()) {
        items.push(BpDatabase.mapBp(rs));
      }
    } finally {
      rs.close();
    }

    const total: number = await this.countBp();
    return {
      items: items,
      total: total,
      offset: safeOffset,
      limit: safeLimit,
      hasMore: safeOffset + items.length < total
    };
  }

  /** 区间查询（左闭右闭），measure_time 升序，供统计与图表使用 */
  async queryBpBetween(start: number, end: number): Promise<BpRecord[]> {
    const store: relationalStore.RdbStore = this.requireStore();
    const predicates: relationalStore.RdbPredicates = new relationalStore.RdbPredicates(DbConst.T_BP);
    predicates.between('measure_time', start, end);
    predicates.orderByAsc('measure_time');

    const items: BpRecord[] = [];
    const rs: relationalStore.ResultSet = await store.query(predicates, COLS_BP);
    try {
      while (rs.goToNextRow()) {
        items.push(BpDatabase.mapBp(rs));
      }
    } finally {
      rs.close();
    }
    return items;
  }

  /** 全部记录（升序），CSV 导出使用 */
  async queryBpAll(): Promise<BpRecord[]> {
    return this.queryBpBetween(0, Number.MAX_SAFE_INTEGER);
  }

  /** 记录总数 */
  async countBp(): Promise<number> {
    const store: relationalStore.RdbStore = this.requireStore();
    const rs: relationalStore.ResultSet = await store.querySql(`SELECT COUNT(*) AS c FROM ${DbConst.T_BP}`);
    let count: number = 0;
    try {
      if (rs.goToFirstRow()) {
        count = rs.getLong(0);
      }
    } finally {
      rs.close();
    }
    return count;
  }

  /** 按 id 查询单条（编辑页回填） */
  async queryBpById(id: number): Promise<BpRecord | null> {
    const store: relationalStore.RdbStore = this.requireStore();
    const predicates: relationalStore.RdbPredicates = new relationalStore.RdbPredicates(DbConst.T_BP);
    predicates.equalTo('id', id);
    const rs: relationalStore.ResultSet = await store.query(predicates, COLS_BP);
    try {
      if (rs.goToFirstRow()) {
        return BpDatabase.mapBp(rs);
      }
    } finally {
      rs.close();
    }
    return null;
  }

  /**
   * 是否已存在相同的「测量时间 + 收缩压 + 舒张压」记录（FR-6.6 判重三元组的录入侧前置检查）。
   *
   * 存在两层保障：
   * 1. 本方法做前置检查，用于给出「已有相同记录」的明确提示，而不是抛数据库约束错误；
   * 2. `uidx_bp_triple` 唯一索引做结构级保障（v1.3 审查意见 P1-4）。
   *
   * @param excludeId 编辑场景下排除自身，传 0 表示不排除
   */
  async existsBpTriple(measureTime: number, systolic: number, diastolic: number, excludeId: number): Promise<boolean> {
    const store: relationalStore.RdbStore = this.requireStore();
    const predicates: relationalStore.RdbPredicates = new relationalStore.RdbPredicates(DbConst.T_BP);
    predicates.equalTo('measure_time', measureTime);
    predicates.equalTo('systolic', systolic);
    predicates.equalTo('diastolic', diastolic);
    if (excludeId > 0) {
      predicates.notEqualTo('id', excludeId);
    }
    const rs: relationalStore.ResultSet = await store.query(predicates, ['id']);
    try {
      return rs.goToFirstRow();
    } finally {
      rs.close();
    }
  }

  private static mapBp(rs: relationalStore.ResultSet): BpRecord {
    const hrIdx: number = rs.getColumnIndex('heart_rate');
    const noteIdx: number = rs.getColumnIndex('note');
    return {
      id: rs.getLong(rs.getColumnIndex('id')),
      systolic: rs.getLong(rs.getColumnIndex('systolic')),
      diastolic: rs.getLong(rs.getColumnIndex('diastolic')),
      heartRate: rs.isColumnNull(hrIdx) ? null : rs.getLong(hrIdx),
      measureTime: rs.getLong(rs.getColumnIndex('measure_time')),
      period: parsePeriod(rs.getString(rs.getColumnIndex('period'))),
      note: rs.isColumnNull(noteIdx) ? null : rs.getString(noteIdx),
      userId: rs.getLong(rs.getColumnIndex('user_id')),
      source: rs.getString(rs.getColumnIndex('source')),
      createdAt: rs.getLong(rs.getColumnIndex('created_at')),
      updatedAt: rs.getLong(rs.getColumnIndex('updated_at'))
    };
  }

  // ───────────────────────── medication ─────────────────────────

  /**
   * 新增药品档案。
   * @param active CSV 导入自动创建的档案需传 false（FR-6.7：仅建档案、状态停用、不建计划）
   */
  async insertMedication(draft: MedicationDraft, active: boolean = true): Promise<number> {
    const store: relationalStore.RdbStore = this.requireStore();
    const now: number = DateUtils.now();
    const values: relationalStore.ValuesBucket = {
      'name': draft.name,
      'dosage': draft.dosage,
      'note': draft.note,
      'is_active': active ? 1 : 0,
      'created_at': now,
      'updated_at': now
    };
    return store.insert(DbConst.T_MED, values);
  }

  async updateMedication(med: Medication): Promise<number> {
    const store: relationalStore.RdbStore = this.requireStore();
    const values: relationalStore.ValuesBucket = {
      'name': med.name,
      'dosage': med.dosage,
      'note': med.note,
      'updated_at': DateUtils.now()
    };
    const predicates: relationalStore.RdbPredicates = new relationalStore.RdbPredicates(DbConst.T_MED);
    predicates.equalTo('id', med.id);
    return store.update(values, predicates);
  }

  /** 启停药品档案（停用为归档，历史打卡保留，FR-8.1） */
  async setMedicationActive(id: number, active: boolean): Promise<number> {
    const store: relationalStore.RdbStore = this.requireStore();
    const values: relationalStore.ValuesBucket = {
      'is_active': active ? 1 : 0,
      'updated_at': DateUtils.now()
    };
    const predicates: relationalStore.RdbPredicates = new relationalStore.RdbPredicates(DbConst.T_MED);
    predicates.equalTo('id', id);
    return store.update(values, predicates);
  }

  async queryMedications(): Promise<Medication[]> {
    const store: relationalStore.RdbStore = this.requireStore();
    const predicates: relationalStore.RdbPredicates = new relationalStore.RdbPredicates(DbConst.T_MED);
    predicates.orderByDesc('is_active');
    predicates.orderByAsc('id');
    const items: Medication[] = [];
    const rs: relationalStore.ResultSet = await store.query(predicates, COLS_MED);
    try {
      while (rs.goToNextRow()) {
        items.push(BpDatabase.mapMed(rs));
      }
    } finally {
      rs.close();
    }
    return items;
  }

  /** 按名称精确匹配药品（CSV 导入用，FR-6.7） */
  async queryMedicationByName(name: string): Promise<Medication | null> {
    const store: relationalStore.RdbStore = this.requireStore();
    const predicates: relationalStore.RdbPredicates = new relationalStore.RdbPredicates(DbConst.T_MED);
    predicates.equalTo('name', name);
    const rs: relationalStore.ResultSet = await store.query(predicates, COLS_MED);
    try {
      if (rs.goToFirstRow()) {
        return BpDatabase.mapMed(rs);
      }
    } finally {
      rs.close();
    }
    return null;
  }

  private static mapMed(rs: relationalStore.ResultSet): Medication {
    const noteIdx: number = rs.getColumnIndex('note');
    return {
      id: rs.getLong(rs.getColumnIndex('id')),
      name: rs.getString(rs.getColumnIndex('name')),
      dosage: rs.getString(rs.getColumnIndex('dosage')),
      note: rs.isColumnNull(noteIdx) ? null : rs.getString(noteIdx),
      isActive: rs.getLong(rs.getColumnIndex('is_active')) === 1,
      createdAt: rs.getLong(rs.getColumnIndex('created_at')),
      updatedAt: rs.getLong(rs.getColumnIndex('updated_at'))
    };
  }

  // ───────────────────────── med_plan ─────────────────────────

  /**
   * 保存计划：每个药品只保留一条生效计划（FR-8.2）。
   * 旧计划置为停用而非删除，历史追溯不受影响（FR-8.3）。
   */
  async upsertPlan(draft: MedPlanDraft): Promise<number> {
    let newId: number = 0;
    await this.runInTransaction(async () => {
      await this.deactivatePlansOf(draft.medicationId);
      newId = await this.insertPlan(draft);
    });
    return newId;
  }

  private async insertPlan(draft: MedPlanDraft): Promise<number> {
    const store: relationalStore.RdbStore = this.requireStore();
    const now: number = DateUtils.now();
    const values: relationalStore.ValuesBucket = {
      'medication_id': draft.medicationId,
      'time_slots': JSON.stringify(draft.timeSlots),
      'start_date': draft.startDate,
      'end_date': draft.endDate,
      'is_active': 1,
      'created_at': now,
      'updated_at': now
    };
    return store.insert(DbConst.T_PLAN, values);
  }

  private async deactivatePlansOf(medicationId: number): Promise<number> {
    const store: relationalStore.RdbStore = this.requireStore();
    const values: relationalStore.ValuesBucket = {
      'is_active': 0,
      'updated_at': DateUtils.now()
    };
    const predicates: relationalStore.RdbPredicates = new relationalStore.RdbPredicates(DbConst.T_PLAN);
    predicates.equalTo('medication_id', medicationId);
    predicates.equalTo('is_active', 1);
    return store.update(values, predicates);
  }

  /** 按药品停用计划（FR-8.3：停用不影响历史打卡） */
  async deactivatePlan(planId: number): Promise<number> {
    const store: relationalStore.RdbStore = this.requireStore();
    const values: relationalStore.ValuesBucket = {
      'is_active': 0,
      'updated_at': DateUtils.now()
    };
    const predicates: relationalStore.RdbPredicates = new relationalStore.RdbPredicates(DbConst.T_PLAN);
    predicates.equalTo('id', planId);
    return store.update(values, predicates);
  }

  async queryPlans(): Promise<MedPlan[]> {
    const store: relationalStore.RdbStore = this.requireStore();
    const predicates: relationalStore.RdbPredicates = new relationalStore.RdbPredicates(DbConst.T_PLAN);
    predicates.orderByDesc('is_active');
    predicates.orderByAsc('id');
    const items: MedPlan[] = [];
    const rs: relationalStore.ResultSet = await store.query(predicates, COLS_PLAN);
    try {
      while (rs.goToNextRow()) {
        items.push(BpDatabase.mapPlan(rs));
      }
    } finally {
      rs.close();
    }
    return items;
  }

  /** 生效中的计划 */
  async queryActivePlans(): Promise<MedPlan[]> {
    const store: relationalStore.RdbStore = this.requireStore();
    const predicates: relationalStore.RdbPredicates = new relationalStore.RdbPredicates(DbConst.T_PLAN);
    predicates.equalTo('is_active', 1);
    const items: MedPlan[] = [];
    const rs: relationalStore.ResultSet = await store.query(predicates, COLS_PLAN);
    try {
      while (rs.goToNextRow()) {
        items.push(BpDatabase.mapPlan(rs));
      }
    } finally {
      rs.close();
    }
    return items;
  }

  private static mapPlan(rs: relationalStore.ResultSet): MedPlan {
    const endIdx: number = rs.getColumnIndex('end_date');
    const slotsRaw: string = rs.getString(rs.getColumnIndex('time_slots'));
    return {
      id: rs.getLong(rs.getColumnIndex('id')),
      medicationId: rs.getLong(rs.getColumnIndex('medication_id')),
      timeSlots: BpDatabase.parseSlots(slotsRaw),
      startDate: rs.getString(rs.getColumnIndex('start_date')),
      endDate: rs.isColumnNull(endIdx) ? null : rs.getString(endIdx),
      isActive: rs.getLong(rs.getColumnIndex('is_active')) === 1,
      createdAt: rs.getLong(rs.getColumnIndex('created_at')),
      updatedAt: rs.getLong(rs.getColumnIndex('updated_at'))
    };
  }

  /** JSON 数组解析；脏数据回退为空数组而不是抛异常 */
  private static parseSlots(raw: string): string[] {
    if (raw === null || raw === undefined || raw.length === 0) {
      return [];
    }
    try {
      const parsed: string[] = JSON.parse(raw) as string[];
      return Array.isArray(parsed) ? parsed : [];
    } catch (err) {
      Logger.warn(TAG, `invalid time_slots json, fallback to empty: ${raw}`);
      return [];
    }
  }

  // ───────────────────────── med_log ─────────────────────────

  /**
   * 幂等预生成打卡记录（§3.1）。
   *
   * 实现：先一次性取出窗口内已存在的 (药品, 计划时间) 组合，只插入差集，
   * 因此返回值是**实际新增**的条数（而非尝试插入的条数）。
   * 配合 uidx_medlog_med_time 唯一索引 + INSERT OR IGNORE 双保险，
   * 同一天重复打开 App 不会产生重复 pending。
   */
  async insertMissingLogs(drafts: MedLogDraft[]): Promise<number> {
    if (drafts.length === 0) {
      return 0;
    }
    const store: relationalStore.RdbStore = this.requireStore();

    let minTs: number = drafts[0].scheduledTime;
    let maxTs: number = drafts[0].scheduledTime;
    for (let i = 1; i < drafts.length; i++) {
      const ts: number = drafts[i].scheduledTime;
      if (ts < minTs) {
        minTs = ts;
      }
      if (ts > maxTs) {
        maxTs = ts;
      }
    }

    const existing: MedLog[] = await this.queryMedLogsBetween(minTs, maxTs);
    const keys: Set<string> = new Set<string>();
    for (let i = 0; i < existing.length; i++) {
      keys.add(BpDatabase.logKey(existing[i].medicationId, existing[i].scheduledTime));
    }

    const pending: MedLogDraft[] = [];
    for (let i = 0; i < drafts.length; i++) {
      const d: MedLogDraft = drafts[i];
      if (!keys.has(BpDatabase.logKey(d.medicationId, d.scheduledTime))) {
        pending.push(d);
      }
    }
    if (pending.length === 0) {
      return 0;
    }

    const now: number = DateUtils.now();
    await this.runInTransaction(async () => {
      for (let i = 0; i < pending.length; i++) {
        const d: MedLogDraft = pending[i];
        await store.executeSql(
          `INSERT OR IGNORE INTO ${DbConst.T_LOG}
           (medication_id, med_name, dosage, scheduled_time, taken_time, status, note, created_at, updated_at)
           VALUES (?, ?, ?, ?, NULL, ?, NULL, ?, ?)`,
          [d.medicationId, d.medName, d.dosage, d.scheduledTime, MedLogStatus.PENDING, now, now]
        );
      }
    });
    return pending.length;
  }

  private static logKey(medicationId: number, scheduledTime: number): string {
    return `${medicationId}_${scheduledTime}`;
  }

  /** 更新打卡状态（状态机结果落库） */
  async updateMedLogStatus(id: number, status: MedLogStatus, takenTime: number | null, note: string | null): Promise<number> {
    const store: relationalStore.RdbStore = this.requireStore();
    const values: relationalStore.ValuesBucket = {
      'status': `${status}`,
      'taken_time': takenTime,
      'note': note,
      'updated_at': DateUtils.now()
    };
    const predicates: relationalStore.RdbPredicates = new relationalStore.RdbPredicates(DbConst.T_LOG);
    predicates.equalTo('id', id);
    return store.update(values, predicates);
  }

  /** 自动标记漏服：status='pending' 且 计划时间早于 now−2h（FR-9.4） */
  async markMissed(now: number): Promise<number> {
    const store: relationalStore.RdbStore = this.requireStore();
    const cutoff: number = now - MedLimits.MISS_GRACE_MS;
    const values: relationalStore.ValuesBucket = {
      'status': `${MedLogStatus.MISSED}`,
      'updated_at': now
    };
    const predicates: relationalStore.RdbPredicates = new relationalStore.RdbPredicates(DbConst.T_LOG);
    predicates.equalTo('status', `${MedLogStatus.PENDING}`);
    predicates.lessThan('scheduled_time', cutoff);
    return store.update(values, predicates);
  }

  /**
   * 删除某药品「尚未到期且仍为待服」的打卡记录（v1.3 审查意见 P1-3）。
   *
   * 计划被修改或停用后，此前按旧计划预生成的未来 pending 记录已不再成立，
   * 若不清理，会出现「计划已改、旧提醒与旧卡片还在」的数据错乱。
   *
   * 删除边界（只删这三类之外都不动）：
   * - 只删 status='pending'：已服 / 跳过 / 漏服属历史记录，永不删除（FR-8.3）；
   * - 只删 scheduled_time > now：**过去**的 pending 是当时真实存在的服药义务，
   *   保留后会在超时 2h 自然派生为漏服，计入侵入依从率分母，不应抹掉。
   *
   * @returns 被删除的行数
   */
  async deleteFuturePendingLogs(medicationId: number, now: number): Promise<number> {
    const store: relationalStore.RdbStore = this.requireStore();
    const predicates: relationalStore.RdbPredicates = new relationalStore.RdbPredicates(DbConst.T_LOG);
    predicates.equalTo('medication_id', medicationId);
    predicates.equalTo('status', `${MedLogStatus.PENDING}`);
    predicates.greaterThan('scheduled_time', now);
    return store.delete(predicates);
  }

  /** 删除全部药品的未来待服记录（清空数据 / 全部停用时使用） */
  async deleteAllFuturePendingLogs(now: number): Promise<number> {
    const store: relationalStore.RdbStore = this.requireStore();
    const predicates: relationalStore.RdbPredicates = new relationalStore.RdbPredicates(DbConst.T_LOG);
    predicates.equalTo('status', `${MedLogStatus.PENDING}`);
    predicates.greaterThan('scheduled_time', now);
    return store.delete(predicates);
  }

  /** 区间查询打卡记录，scheduled_time 升序 */
  async queryMedLogsBetween(start: number, end: number): Promise<MedLog[]> {
    const store: relationalStore.RdbStore = this.requireStore();
    const predicates: relationalStore.RdbPredicates = new relationalStore.RdbPredicates(DbConst.T_LOG);
    predicates.between('scheduled_time', start, end);
    predicates.orderByAsc('scheduled_time');
    return BpDatabase.readLogs(store, predicates);
  }

  /** 全部打卡记录（CSV 导出） */
  async queryMedLogsAll(): Promise<MedLog[]> {
    return this.queryMedLogsBetween(0, Number.MAX_SAFE_INTEGER);
  }

  /** 指定自然日的打卡记录 */
  async queryMedLogsOfDay(dayTs: number): Promise<MedLog[]> {
    return this.queryMedLogsBetween(DateUtils.startOfDay(dayTs), DateUtils.endOfDay(dayTs));
  }

  /** 按药品 + 计划时间精确查询（导入判重用） */
  async queryMedLog(medicationId: number, scheduledTime: number): Promise<MedLog | null> {
    const store: relationalStore.RdbStore = this.requireStore();
    const predicates: relationalStore.RdbPredicates = new relationalStore.RdbPredicates(DbConst.T_LOG);
    predicates.equalTo('medication_id', medicationId);
    predicates.equalTo('scheduled_time', scheduledTime);
    const rs: relationalStore.ResultSet = await store.query(predicates, COLS_LOG);
    try {
      if (rs.goToFirstRow()) {
        return BpDatabase.mapLog(rs);
      }
    } finally {
      rs.close();
    }
    return null;
  }

  /** 导入用：按原始状态与打卡时间写入（不入库为 pending） */
  async insertMedLogForImport(medicationId: number, medName: string, dosage: string,
    scheduledTime: number, status: MedLogStatus, takenTime: number | null, note: string | null): Promise<number> {
    const store: relationalStore.RdbStore = this.requireStore();
    const now: number = DateUtils.now();
    const values: relationalStore.ValuesBucket = {
      'medication_id': medicationId,
      'med_name': medName,
      'dosage': dosage,
      'scheduled_time': scheduledTime,
      'taken_time': takenTime,
      'status': `${status}`,
      'note': note,
      'created_at': now,
      'updated_at': now
    };
    return store.insert(DbConst.T_LOG, values);
  }

  private static async readLogs(store: relationalStore.RdbStore, predicates: relationalStore.RdbPredicates): Promise<MedLog[]> {
    const items: MedLog[] = [];
    const rs: relationalStore.ResultSet = await store.query(predicates, COLS_LOG);
    try {
      while (rs.goToNextRow()) {
        items.push(BpDatabase.mapLog(rs));
      }
    } finally {
      rs.close();
    }
    return items;
  }

  private static mapLog(rs: relationalStore.ResultSet): MedLog {
    const takenIdx: number = rs.getColumnIndex('taken_time');
    const noteIdx: number = rs.getColumnIndex('note');
    return {
      id: rs.getLong(rs.getColumnIndex('id')),
      medicationId: rs.getLong(rs.getColumnIndex('medication_id')),
      medName: rs.getString(rs.getColumnIndex('med_name')),
      dosage: rs.getString(rs.getColumnIndex('dosage')),
      scheduledTime: rs.getLong(rs.getColumnIndex('scheduled_time')),
      takenTime: rs.isColumnNull(takenIdx) ? null : rs.getLong(takenIdx),
      status: parseMedLogStatus(rs.getString(rs.getColumnIndex('status'))),
      note: rs.isColumnNull(noteIdx) ? null : rs.getString(noteIdx),
      createdAt: rs.getLong(rs.getColumnIndex('created_at')),
      updatedAt: rs.getLong(rs.getColumnIndex('updated_at'))
    };
  }

  /** 打卡记录总数 */
  async countMedLogs(): Promise<number> {
    const store: relationalStore.RdbStore = this.requireStore();
    const rs: relationalStore.ResultSet = await store.querySql(`SELECT COUNT(*) AS c FROM ${DbConst.T_LOG}`);
    let count: number = 0;
    try {
      if (rs.goToFirstRow()) {
        count = rs.getLong(0);
      }
    } finally {
      rs.close();
    }
    return count;
  }

  // ───────────────────────── 导入判重用的轻量查询 ─────────────────────────

  /**
   * 血压记录去重三元组（仅取 3 列）。
   * 4000 条数据下只传输去重所需的最小数据，避免整行加载造成的额外开销（NFR-3）。
   */
  async queryBpDedupeTuples(): Promise<BpDedupeTuple[]> {
    const store: relationalStore.RdbStore = this.requireStore();
    const rs: relationalStore.ResultSet = await store.querySql(
      `SELECT measure_time, systolic, diastolic FROM ${DbConst.T_BP}`
    );
    const out: BpDedupeTuple[] = [];
    try {
      while (rs.goToNextRow()) {
        out.push({
          measureTime: rs.getLong(0),
          systolic: rs.getLong(1),
          diastolic: rs.getLong(2)
        });
      }
    } finally {
      rs.close();
    }
    return out;
  }

  /** 用药打卡去重元组（药品 id / 名称 / 计划时间） */
  async queryMedLogDedupeTuples(): Promise<MedDedupeTuple[]> {
    const store: relationalStore.RdbStore = this.requireStore();
    const rs: relationalStore.ResultSet = await store.querySql(
      `SELECT medication_id, med_name, scheduled_time FROM ${DbConst.T_LOG}`
    );
    const out: MedDedupeTuple[] = [];
    try {
      while (rs.goToNextRow()) {
        out.push({
          medicationId: rs.getLong(0),
          medName: rs.getString(1),
          scheduledTime: rs.getLong(2)
        });
      }
    } finally {
      rs.close();
    }
    return out;
  }

  // ───────────────────────── 清空 ─────────────────────────

  /**
   * 清空全部业务数据（FR-7.2）。
   * 单事务执行四表删除；Preferences 中的设置项（分级标准、免责声明已读）保留。
   */
  async clearAll(): Promise<void> {
    const store: relationalStore.RdbStore = this.requireStore();
    await this.runInTransaction(async () => {
      await store.executeSql(`DELETE FROM ${DbConst.T_LOG}`);
      await store.executeSql(`DELETE FROM ${DbConst.T_PLAN}`);
      await store.executeSql(`DELETE FROM ${DbConst.T_MED}`);
      await store.executeSql(`DELETE FROM ${DbConst.T_BP}`);
      // 重置自增序列，保证清空后 id 从 1 开始。
      // sqlite_sequence 仅在存在 AUTOINCREMENT 表后才会被创建，故此处容错。
      try {
        await store.executeSql(`DELETE FROM sqlite_sequence WHERE name IN (?, ?, ?, ?)`,
          [DbConst.T_BP, DbConst.T_MED, DbConst.T_PLAN, DbConst.T_LOG]);
      } catch (err) {
        const e = err as BusinessError;
        Logger.warn(TAG, `reset sqlite_sequence skipped: code=${e.code}, message=${e.message}`);
      }
    });
    Logger.info(TAG, 'all data cleared');
  }
}
