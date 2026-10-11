import { relationalStore } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { BpDedupeTuple, BpRecord, BpRecordDraft, PageResult } from '../model/BpRecord';
import { MedDedupeTuple, Medication, MedicationDraft, MedLog, MedLogDraft, MedPlan, MedPlanDraft } from '../model/Med';
import { BackupBp, BackupLog, BackupMed, BackupPlan } from '../model/Backup';
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
const COLS_PLAN: string[] = ['id', 'medication_id', 'time_slots', 'start_date', 'end_date', 'is_active', 'created_at', 'updated_at', 'effective_from', 'effective_to'];
const COLS_LOG: string[] = ['id', 'medication_id', 'med_name', 'dosage', 'scheduled_time', 'taken_time', 'status', 'note', 'created_at', 'updated_at', 'source_plan_id'];

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
     updated_at    INTEGER NOT NULL,
     -- v3（审查 R01.3）：显式有效区间，避免「有效区间」只靠 start_date/created_at/updated_at 推导
     effective_from INTEGER NOT NULL DEFAULT 0,
     effective_to   INTEGER
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
     updated_at     INTEGER NOT NULL,
     -- v4（审查 R01.3）：生成这条打卡的来源计划 id（历史行未知 → NULL）
     source_plan_id INTEGER
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
/**
 * 事务会话（审查 R06.2）：显式携带本次事务使用的连接。
 * 领域命令内部要复用同一事务时，**必须**把会话作为参数往下传，
 * 不允许用全局布尔/环境变量去猜「调用者是否属于当前事务」。
 */
export interface TxSession {
  readonly store: relationalStore.RdbStore;
}

/** 「保存药品档案 + 计划版本」领域命令（审查 R07）：一次事务内改药品、计划、受影响 pending 与生成结果 */
export interface SaveMedicationPlanCommand {
  /** 0 = 新建药品；>0 = 既有药品（会被显式置为启用） */
  medicationId: number;
  medication: MedicationDraft;
  plan: MedPlanDraft;
  /** 重新生成待服的基准时刻（由调用方传入，便于测试固定时钟） */
  regenerateFrom: number;
  preGenDays: number;
}

export interface SaveMedicationPlanResult {
  medicationId: number;
  planId: number;
  clearedPending: number;
  generatedPending: number;
}

/**
 * 恢复写入目标（审查 R10.4）：完整备份恢复只需要这四张表的写入与事务入口。
 * 放在这里是为了让 BpDatabase 显式 implements（ArkTS 不支持结构化类型），
 * 同时避免与 BackupService 形成循环依赖。
 */
export interface BackupTarget {
  runInTransaction(work: (tx: TxSession) => Promise<void>): Promise<void>;
  restoreMedication(m: BackupMed, tx?: TxSession): Promise<void>;
  restorePlan(p: BackupPlan, tx?: TxSession): Promise<void>;
  restoreMedLog(l: BackupLog, tx?: TxSession): Promise<void>;
  restoreBp(b: BackupBp, tx?: TxSession): Promise<void>;
}

export class BpDatabase implements BackupTarget {
  /** 测试库名必须以此开头（审查 R17：指定库名不等于隔离，测试构造器只接受严格测试前缀） */
  static readonly TEST_DB_PREFIX: string = 'bp_recorder_unittest';

  private static instance: BpDatabase | null = null;
  private store: relationalStore.RdbStore | null = null;
  private initPromise: Promise<void> | null = null;
  /** 写操作串行队列（审查 R06.1）：单步写与事务写共用同一条队列，杜绝独立写被卷进别人的事务 */
  private txQueue: Promise<void> = Promise.resolve();
  /** 实际已连接的库名（'' = 未连接）。任何「换库名」请求都以此为准做拒绝判断。 */
  private openedStoreName: string = '';
  /** 是否由 createIsolated 创建的测试实例（生产单例为 false）。 */
  private testInstance: boolean = false;

  static getInstance(): BpDatabase {
    if (BpDatabase.instance === null) {
      BpDatabase.instance = new BpDatabase();
    }
    return BpDatabase.instance;
  }

  /**
   * **仅供测试**：创建一个与生产单例完全无关的独立实例（审查 R17）。
   * - 不注册为单例，绝不复用生产连接；
   * - 库名必须以 `bp_recorder_unittest` 开头，否则直接抛错，避免测试误清用户库。
   */
  static createIsolated(storeName: string): BpDatabase {
    if (!storeName.startsWith(BpDatabase.TEST_DB_PREFIX)) {
      throw new Error(`测试实例的库名必须以 ${BpDatabase.TEST_DB_PREFIX} 开头，收到：${storeName}`);
    }
    const db: BpDatabase = new BpDatabase();
    db.testInstance = true;
    return db;
  }

  /** 是否已就绪（页面可据此决定是否显示「数据库初始化失败」提示） */
  isReady(): boolean {
    return this.store !== null;
  }

  /** 实际已连接的库名（未连接时为空串）——测试收尾与「核验实际连接身份」都读它 */
  storeName(): string {
    return this.openedStoreName;
  }

  /** 是否测试实例（由 createIsolated 创建） */
  isTestInstance(): boolean {
    return this.testInstance;
  }

  /** 任何清空/删除前核验身份（审查 R17）：只允许在测试实例 + 测试库上执行 */
  requireTestInstance(action: string): void {
    if (!this.testInstance || !this.openedStoreName.startsWith(BpDatabase.TEST_DB_PREFIX)) {
      throw new Error(`${action} 只允许在测试实例与测试库上执行（当前实例：${this.openedStoreName === '' ? '未连接' : this.openedStoreName}）`);
    }
  }

  /**
   * **仅供离线回归/测试**：注入一个 RdbStore 形状的替身，用于验证连接身份与事务控制流，
   * 不打开任何真实数据库。生产代码不得调用。
   */
  attachStoreStub(stub: object): void {
    this.store = stub as relationalStore.RdbStore;
    if (this.openedStoreName === '') {
      this.openedStoreName = '(stub)';
    }
  }

  /** 关闭连接并清空初始化缓存（测试收尾用；生产单例不调用） */
  async close(): Promise<void> {
    const current: relationalStore.RdbStore | null = this.store;
    this.store = null;
    this.initPromise = null;
    this.openedStoreName = '';
    if (current !== null) {
      await current.close();
    }
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
      // 审查 R17：已初始化实例再指定另一个库名时，过去会静默复用旧连接 —— 这里必须拒绝。
      // 注意这里**不**给「库名未知」留后门：连接身份说不清时宁可拒绝，也不静默复用。
      if (storeName !== this.openedStoreName) {
        throw new Error(`该实例已连接 ${this.openedStoreName}，不能改连 ${storeName}；测试请用 BpDatabase.createIsolated(库名)`);
      }
      return;
    }
    if (this.initPromise === null) {
      // 审查 R18：失败的初始化不能把 in-flight Promise 永久缓存住 —— 否则重试按钮永远拿到同一个失败结果。
      // 这里在失败分支清掉缓存；并发调用在失败前仍共用同一次任务（不重复打开）。
      const attempt: Promise<void> = this.doInit(context, storeName).catch((err: Error) => {
        this.initPromise = null;
        const be = err as BusinessError;
        Logger.error(TAG, `database init failed (will retry on next call): code=${be.code}, message=${be.message}`);
        // ArkTS 的 arkts-limited-throw 只接受静态类型为 Error 的抛出值
        throw err;
      });
      this.initPromise = attempt;
    }
    return this.initPromise;
  }

  private async doInit(context: common.Context, storeName: string): Promise<void> {
    const config: relationalStore.StoreConfig = {
      name: storeName,
      securityLevel: relationalStore.SecurityLevel.S1
    };
    let store: relationalStore.RdbStore | null = null;
    try {
      store = await relationalStore.getRdbStore(context, config);
      for (let i = 0; i < DDL.length; i++) {
        await store.executeSql(DDL[i]);
      }
      await BpDatabase.migrate(store);
      this.store = store;
      this.openedStoreName = storeName;
      Logger.info(TAG, `database ready, storeName=${storeName}, schemaVersion=${DbConst.SCHEMA_VERSION}`);
    } catch (err) {
      // 半开连接必须关掉：否则重试会同时持有两个连接，且文件句柄泄漏（审查 R18）
      if (store !== null) {
        try {
          await store.close();
        } catch (closeErr) {
          const ce = closeErr as BusinessError;
          Logger.error(TAG, `close half-open store failed: code=${ce.code}, message=${ce.message}`);
        }
      }
      // ArkTS 只允许抛 Error（arkts-limited-throw）：是 Error 就原样抛（保留 code 等字段），
      // 否则包装成 Error 再抛。
      const failure: Error = err instanceof Error ? err : new Error(`database init failed: ${String(err)}`);
      throw failure;
    }
  }

  /** 版本化迁移：以 PRAGMA user_version 为基准，整体在一个事务内完成 */
  private static async migrate(store: relationalStore.RdbStore): Promise<void> {
    const current: number = await BpDatabase.readUserVersion(store);
    if (current === DbConst.SCHEMA_VERSION) {
      return;
    }
    if (current > DbConst.SCHEMA_VERSION) {
      // 审查 R18：未来版本的库不能被旧应用当正常库写入（会破坏用户数据）。
      throw new Error(`数据库结构版本 ${current} 高于本应用支持的 ${DbConst.SCHEMA_VERSION}：请升级应用后再使用，本版本不写入该库`);
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

      if (current < 3) {
        // ── v2 → v3（审查 R01.3）──
        // 「有效区间」过去只靠 start_date/created_at/updated_at 推导，口径散落在各处；
        // v3 起作为显式列持久化。全新库的 DDL 已包含这两列，故先探测再 ALTER（幂等）。
        if (!await BpDatabase.hasColumn(store, DbConst.T_PLAN, 'effective_from')) {
          await store.executeSql(
            `ALTER TABLE ${DbConst.T_PLAN} ADD COLUMN effective_from INTEGER NOT NULL DEFAULT 0`);
        }
        if (!await BpDatabase.hasColumn(store, DbConst.T_PLAN, 'effective_to')) {
          await store.executeSql(`ALTER TABLE ${DbConst.T_PLAN} ADD COLUMN effective_to INTEGER`);
        }
        await BpDatabase.backfillPlanWindows(store);
      }

      if (current < 4) {
        // ── v3 → v4（审查 R01.3）──
        // med_log.source_plan_id：记录这条打卡由哪一版计划生成/补齐。历史行来源未知，保持 NULL。
        if (!await BpDatabase.hasColumn(store, DbConst.T_LOG, 'source_plan_id')) {
          await store.executeSql(
            `ALTER TABLE ${DbConst.T_LOG} ADD COLUMN source_plan_id INTEGER`);
        }
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
  /**
   * 串行队列（审查 R06.1/R06.3）：所有写操作（含事务）排队执行，先来先服务。
   * 无论成功、失败还是 begin 失败，finally 都会释放队列，避免一次故障把后续写入永久堵死。
   */
  private async runExclusive<T>(work: () => Promise<T>): Promise<T> {
    const previous: Promise<void> = this.txQueue;
    let release: () => void = () => {};
    this.txQueue = new Promise<void>((resolve: () => void) => {
      release = resolve;
    });
    await previous;
    try {
      return await work();
    } finally {
      release();
    }
  }

  /**
   * 叶子写操作的统一入口（审查 R06.1）：
   * - 传了会话 → 直接复用该事务的连接（嵌套领域命令，不再 begin/commit）；
   * - 没传会话 → 排队独占执行，绝不会被卷进别人正在开的事务里。
   */
  private async write<T>(tx: TxSession | undefined, op: (store: relationalStore.RdbStore) => Promise<T>): Promise<T> {
    if (tx !== undefined) {
      return op(tx.store);
    }
    return this.runExclusive<T>(() => op(this.requireStore()));
  }

  /**
   * 显式事务（审查 R06）：排队 → begin → work(tx) → commit，异常时回滚。
   * 嵌套调用**不**猜上下文：调用方要么把 tx 往下传（走领域命令），要么就是一次独立事务（排队）。
   */
  async runInTransaction(work: (tx: TxSession) => Promise<void>): Promise<void> {
    await this.runExclusive(async () => {
      const store: relationalStore.RdbStore = this.requireStore();
      try {
        await store.beginTransaction();
      } catch (err) {
        const be = err as BusinessError;
        Logger.error(TAG, `beginTransaction failed: code=${be.code}, message=${be.message}`);
        // begin 失败：队列由 runExclusive 的 finally 释放，这里只负责把错误抛给调用方
        throw new AppError(be.code, be.message);
      }
      const tx: TxSession = { store };
      try {
        await work(tx);
        await store.commit();
      } catch (err) {
        const be = err as BusinessError;
        Logger.error(TAG, `transaction failed, rolling back: code=${be.code}, message=${be.message}`);
        try {
          await store.rollBack();
        } catch (rollbackErr) {
          const re = rollbackErr as BusinessError;
          // 回滚失败要如实记录，但**保留原始故障**抛给调用方（不能让调用方以为事务成功了）
          Logger.error(TAG, `rollback failed: code=${re.code}, message=${re.message}`);
        }
        throw new AppError(be.code, be.message);
      }
    });
  }

  // ───────────────────────── bp_record ─────────────────────────

  /** 新增血压记录，返回新行 id */
  async insertBp(draft: BpRecordDraft, tx?: TxSession): Promise<number> {
    return this.write(tx, async (store: relationalStore.RdbStore): Promise<number> => {
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
    });
  }

  /** 批量新增（导入用），返回成功条数 */
  async batchInsertBp(drafts: BpRecordDraft[], tx?: TxSession): Promise<number> {
    if (drafts.length === 0) {
      return 0;
    }
    return this.write(tx, async (store: relationalStore.RdbStore): Promise<number> => {
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
    });
  }

  /** 更新血压记录（按 id） */
  async updateBp(record: BpRecord, tx?: TxSession): Promise<number> {
    return this.write(tx, async (store: relationalStore.RdbStore): Promise<number> => {
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
    });
  }

  /** 删除血压记录（不可逆，UI 层负责二次确认，CL-1） */
  async deleteBp(id: number, tx?: TxSession): Promise<number> {
    return this.write(tx, async (store: relationalStore.RdbStore): Promise<number> => {
    const predicates: relationalStore.RdbPredicates = new relationalStore.RdbPredicates(DbConst.T_BP);
    predicates.equalTo('id', id);
    return store.delete(predicates);
    });
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
  async insertMedication(draft: MedicationDraft, active: boolean = true, tx?: TxSession): Promise<number> {
    return this.write(tx, async (store: relationalStore.RdbStore): Promise<number> => {
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
    });
  }

  async updateMedication(med: Medication, tx?: TxSession): Promise<number> {
    return this.write(tx, async (store: relationalStore.RdbStore): Promise<number> => {
    const values: relationalStore.ValuesBucket = {
      'name': med.name,
      'dosage': med.dosage,
      'note': med.note,
      'updated_at': DateUtils.now()
    };
    const predicates: relationalStore.RdbPredicates = new relationalStore.RdbPredicates(DbConst.T_MED);
    predicates.equalTo('id', med.id);
    return store.update(values, predicates);
    });
  }

  /** 启停药品档案（停用为归档，历史打卡保留，FR-8.1） */
  async setMedicationActive(id: number, active: boolean, tx?: TxSession): Promise<number> {
    return this.write(tx, async (store: relationalStore.RdbStore): Promise<number> => {
    const values: relationalStore.ValuesBucket = {
      'is_active': active ? 1 : 0,
      'updated_at': DateUtils.now()
    };
    const predicates: relationalStore.RdbPredicates = new relationalStore.RdbPredicates(DbConst.T_MED);
    predicates.equalTo('id', id);
    return store.update(values, predicates);
    });
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
  async upsertPlan(draft: MedPlanDraft, tx?: TxSession): Promise<number> {
    if (tx !== undefined) {
      return this.upsertPlanIn(tx, draft);
    }
    let newId: number = 0;
    await this.runInTransaction(async (session: TxSession) => {
      newId = await this.upsertPlanIn(session, draft);
    });
    return newId;
  }

  /** 事务内的计划写入（明确的非开事务私有方法，审查 R06.2） */
  private async upsertPlanIn(tx: TxSession, draft: MedPlanDraft): Promise<number> {
    await this.deactivatePlansOf(draft.medicationId, tx);
    return this.insertPlan(draft, tx);
  }

  private async insertPlan(draft: MedPlanDraft, tx?: TxSession): Promise<number> {
    return this.write(tx, async (store: relationalStore.RdbStore): Promise<number> => {
    const now: number = DateUtils.now();
    const values: relationalStore.ValuesBucket = {
      'medication_id': draft.medicationId,
      'time_slots': JSON.stringify(draft.timeSlots),
      'start_date': draft.startDate,
      'end_date': draft.endDate,
      'is_active': 1,
      'created_at': now,
      'updated_at': now,
      // 审查 R01.3：写入时就把有效区间定下来（起点不得早于保存时刻；终点 = 结束日 23:59 或长期）
      'effective_from': BpDatabase.planEffectiveFrom(draft.startDate, now),
      'effective_to': BpDatabase.planEffectiveTo(draft.endDate)
    };
    return store.insert(DbConst.T_PLAN, values);
    });
  }

  private async deactivatePlansOf(medicationId: number, tx?: TxSession): Promise<number> {
    return this.write(tx, async (store: relationalStore.RdbStore): Promise<number> => {
    const now: number = DateUtils.now();
    const values: relationalStore.ValuesBucket = {
      'is_active': 0,
      'updated_at': now,
      // 审查 R01.3：停用即收口有效区间（旧数据未回填时为 0/null，由调用方按既有列推导）
      'effective_to': now
    };
    const predicates: relationalStore.RdbPredicates = new relationalStore.RdbPredicates(DbConst.T_PLAN);
    predicates.equalTo('medication_id', medicationId);
    predicates.equalTo('is_active', 1);
    return store.update(values, predicates);
    });
  }

  /** 按药品停用计划（FR-8.3：停用不影响历史打卡） */
  async deactivatePlan(planId: number, tx?: TxSession): Promise<number> {
    return this.write(tx, async (store: relationalStore.RdbStore): Promise<number> => {
    const values: relationalStore.ValuesBucket = {
      'is_active': 0,
      'updated_at': DateUtils.now()
    };
    const predicates: relationalStore.RdbPredicates = new relationalStore.RdbPredicates(DbConst.T_PLAN);
    predicates.equalTo('id', planId);
    return store.update(values, predicates);
    });
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

  /** 有效区间起点：max(start_date 00:00, 保存时刻)（审查 R01.3） */
  static planEffectiveFrom(startDate: string, now: number): number {
    const startTs: number | null = DateUtils.parseDate(startDate);
    const start: number = startTs === null ? now : startTs;
    return start > now ? start : now;
  }

  /** 有效区间终点：有结束日期 → 结束日 23:59；长期 → null */
  static planEffectiveTo(endDate: string | null): number | null {
    if (endDate === null || endDate === undefined || endDate.length === 0) {
      return null;
    }
    const ts: number | null = DateUtils.parseDate(endDate);
    return ts === null ? null : DateUtils.endOfDay(ts);
  }

  /** 迁移时回填历史计划的有效区间（审查 R01.3）：旧数据按既有列推导一次并落盘 */
  private static async backfillPlanWindows(store: relationalStore.RdbStore): Promise<void> {
    const rs: relationalStore.ResultSet = await store.querySql(
      `SELECT id, start_date, end_date, is_active, created_at, updated_at FROM ${DbConst.T_PLAN}`);
    const ids: number[] = [];
    const froms: number[] = [];
    const tos: number[] = [];
    try {
      while (rs.goToNextRow()) {
        const id: number = rs.getLong(rs.getColumnIndex('id'));
        const startDate: string = rs.getString(rs.getColumnIndex('start_date'));
        const endIdx: number = rs.getColumnIndex('end_date');
        const endDate: string | null = rs.isColumnNull(endIdx) ? null : rs.getString(endIdx);
        const active: boolean = rs.getLong(rs.getColumnIndex('is_active')) === 1;
        const created: number = rs.getLong(rs.getColumnIndex('created_at'));
        const updated: number = rs.getLong(rs.getColumnIndex('updated_at'));
        const startTs: number | null = DateUtils.parseDate(startDate);
        const start: number = startTs === null ? created : startTs;
        const from: number = start > created ? start : created;
        let to: number = 0;
        const endBound: number | null = BpDatabase.planEffectiveTo(endDate);
        if (endBound !== null) {
          to = endBound;
        }
        if (!active) {
          const closed: number = updated > 0 ? updated : created;
          if (to === 0 || closed < to) {
            to = closed;
          }
        }
        ids.push(id);
        froms.push(from);
        tos.push(to);
      }
    } finally {
      rs.close();
    }
    for (let i = 0; i < ids.length; i++) {
      await store.executeSql(
        `UPDATE ${DbConst.T_PLAN} SET effective_from = ?, effective_to = ? WHERE id = ?`,
        [froms[i], tos[i] === 0 ? null : tos[i], ids[i]]);
    }
    Logger.info(TAG, `backfilled plan windows: ${ids.length}`);
  }

  /** 列是否存在（迁移的幂等前提：全新库由 DDL 直接建出 v3 列，不能再 ALTER） */
  private static async hasColumn(store: relationalStore.RdbStore, table: string, column: string): Promise<boolean> {
    const rs: relationalStore.ResultSet = await store.querySql(`PRAGMA table_info(${table})`);
    try {
      while (rs.goToNextRow()) {
        if (rs.getString(rs.getColumnIndex('name')) === column) {
          return true;
        }
      }
    } finally {
      rs.close();
    }
    return false;
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
      updatedAt: rs.getLong(rs.getColumnIndex('updated_at')),
      effectiveFrom: rs.getLong(rs.getColumnIndex('effective_from')),
      effectiveTo: rs.isColumnNull(rs.getColumnIndex('effective_to'))
        ? null : rs.getLong(rs.getColumnIndex('effective_to'))
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
  async insertMissingLogs(drafts: MedLogDraft[], tx?: TxSession): Promise<number> {
    if (drafts.length === 0) {
      return 0;
    }

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
    const insertAll = async (store: relationalStore.RdbStore): Promise<void> => {
      for (let i = 0; i < pending.length; i++) {
        const d: MedLogDraft = pending[i];
        await store.executeSql(
          `INSERT OR IGNORE INTO ${DbConst.T_LOG}
           (medication_id, med_name, dosage, scheduled_time, taken_time, status, note, created_at, updated_at, source_plan_id)
           VALUES (?, ?, ?, ?, NULL, ?, NULL, ?, ?, ?)`,
          [d.medicationId, d.medName, d.dosage, d.scheduledTime, MedLogStatus.PENDING, now, now,
            d.planId === undefined ? null : d.planId]
        );
      }
    };
    if (tx !== undefined) {
      await insertAll(tx.store);
    } else {
      await this.runInTransaction(async (session: TxSession) => {
        await insertAll(session.store);
      });
    }
    return pending.length;
  }

  private static logKey(medicationId: number, scheduledTime: number): string {
    return `${medicationId}_${scheduledTime}`;
  }

  /** 更新打卡状态（状态机结果落库） */
  async updateMedLogStatus(id: number, status: MedLogStatus, takenTime: number | null, note: string | null, tx?: TxSession): Promise<number> {
    return this.write(tx, async (store: relationalStore.RdbStore): Promise<number> => {
    const values: relationalStore.ValuesBucket = {
      'status': `${status}`,
      'taken_time': takenTime,
      'note': note,
      'updated_at': DateUtils.now()
    };
    const predicates: relationalStore.RdbPredicates = new relationalStore.RdbPredicates(DbConst.T_LOG);
    predicates.equalTo('id', id);
    return store.update(values, predicates);
    });
  }

  /** 自动标记漏服：status='pending' 且 计划时间早于 now−2h（FR-9.4） */
  async markMissed(now: number, tx?: TxSession): Promise<number> {
    return this.write(tx, async (store: relationalStore.RdbStore): Promise<number> => {
    const cutoff: number = now - MedLimits.MISS_GRACE_MS;
    const values: relationalStore.ValuesBucket = {
      'status': `${MedLogStatus.MISSED}`,
      'updated_at': now
    };
    const predicates: relationalStore.RdbPredicates = new relationalStore.RdbPredicates(DbConst.T_LOG);
    predicates.equalTo('status', `${MedLogStatus.PENDING}`);
    predicates.lessThan('scheduled_time', cutoff);
    return store.update(values, predicates);
    });
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
  async deleteFuturePendingLogs(medicationId: number, now: number, tx?: TxSession): Promise<number> {
    return this.write(tx, async (store: relationalStore.RdbStore): Promise<number> => {
    const predicates: relationalStore.RdbPredicates = new relationalStore.RdbPredicates(DbConst.T_LOG);
    predicates.equalTo('medication_id', medicationId);
    predicates.equalTo('status', `${MedLogStatus.PENDING}`);
    predicates.greaterThan('scheduled_time', now);
    return store.delete(predicates);
    });
  }

  /** 删除全部药品的未来待服记录（清空数据 / 全部停用时使用） */
  async deleteAllFuturePendingLogs(now: number, tx?: TxSession): Promise<number> {
    return this.write(tx, async (store: relationalStore.RdbStore): Promise<number> => {
    const predicates: relationalStore.RdbPredicates = new relationalStore.RdbPredicates(DbConst.T_LOG);
    predicates.equalTo('status', `${MedLogStatus.PENDING}`);
    predicates.greaterThan('scheduled_time', now);
    return store.delete(predicates);
    });
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
    scheduledTime: number, status: MedLogStatus, takenTime: number | null, note: string | null,
    tx?: TxSession, planId?: number): Promise<number> {
    return this.write(tx, async (store: relationalStore.RdbStore): Promise<number> => {
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
      'updated_at': now,
      'source_plan_id': planId === undefined ? null : planId
    };
    return store.insert(DbConst.T_LOG, values);
    });
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
    const planIdx: number = rs.getColumnIndex('source_plan_id');
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
      updatedAt: rs.getLong(rs.getColumnIndex('updated_at')),
      planId: rs.isColumnNull(planIdx) ? undefined : rs.getLong(planIdx)
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
  // ───────────────────── 完整备份恢复（审查 R10.4）─────────────────────
  // 说明：恢复按**稳定 id**覆盖写入，保留原 created_at/updated_at 与启停状态；
  // 恢复过程中**不生成 pending、不发布提醒**，提醒由调用方在提交后统一重新协调（报告 R10.3）。

  /** 按 id 覆盖写入药品档案 */
  async restoreMedication(m: BackupMed, tx?: TxSession): Promise<void> {
    return this.write(tx, async (store: relationalStore.RdbStore): Promise<void> => {
      const fallback: number = DateUtils.now();
      await store.executeSql(
        `INSERT OR REPLACE INTO medication (id, name, dosage, note, is_active, created_at, updated_at)
         VALUES (?, ?, ?, ?, ?, ?, ?)`,
        [m.id, m.name, m.dosage, m.note, m.isActive ? 1 : 0,
          m.createdAt > 0 ? m.createdAt : fallback, m.updatedAt > 0 ? m.updatedAt : fallback]);
    });
  }

  /** 按 id 覆盖写入用药计划（含起止日期与启停状态） */
  async restorePlan(p: BackupPlan, tx?: TxSession): Promise<void> {
    return this.write(tx, async (store: relationalStore.RdbStore): Promise<void> => {
      const fallback: number = DateUtils.now();
      await store.executeSql(
        `INSERT OR REPLACE INTO med_plan
           (id, medication_id, time_slots, start_date, end_date, is_active, created_at, updated_at,
            effective_from, effective_to)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
        [p.id, p.medicationId, p.timeSlots.join(','), p.startDate, p.endDate, p.isActive ? 1 : 0,
          p.createdAt > 0 ? p.createdAt : fallback, p.updatedAt > 0 ? p.updatedAt : fallback,
          // 审查 R01.3：备份带区间就照写；旧备份没有则按既有列推导一次，避免恢复后口径不一致
          p.effectiveFrom === undefined || p.effectiveFrom <= 0
            ? BpDatabase.planEffectiveFrom(p.startDate, fallback)
            : p.effectiveFrom,
          p.effectiveTo === undefined ? BpDatabase.planEffectiveTo(p.endDate) : p.effectiveTo]);
    });
  }

  /** 按 id 覆盖写入打卡记录（含毫秒时间与状态） */
  async restoreMedLog(l: BackupLog, tx?: TxSession): Promise<void> {
    return this.write(tx, async (store: relationalStore.RdbStore): Promise<void> => {
      const fallback: number = DateUtils.now();
      await store.executeSql(
        `INSERT OR REPLACE INTO med_log
           (id, medication_id, med_name, dosage, scheduled_time, taken_time, status, note, created_at, updated_at, source_plan_id)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
        [l.id, l.medicationId, l.medName, l.dosage, l.scheduledTime, l.takenTime, `${l.status}`, l.note,
          l.createdAt > 0 ? l.createdAt : fallback, l.updatedAt > 0 ? l.updatedAt : fallback,
          l.sourcePlanId === undefined ? null : l.sourcePlanId]);
    });
  }

  /** 血压：身份为 (测量时间, 收缩压, 舒张压)，存在则覆盖可变成分，不存在则插入 */
  async restoreBp(b: BackupBp, tx?: TxSession): Promise<void> {
    return this.write(tx, async (store: relationalStore.RdbStore): Promise<void> => {
      const now: number = DateUtils.now();
      const rs: relationalStore.ResultSet = await store.querySql(
        'SELECT id FROM bp_record WHERE measure_time = ? AND systolic = ? AND diastolic = ?',
        [b.measureTime, b.systolic, b.diastolic]);
      let exists: boolean = false;
      try {
        exists = rs.goToNextRow();
      } finally {
        rs.close();
      }
      if (exists) {
        await store.executeSql(
          `UPDATE bp_record SET heart_rate = ?, period = ?, note = ?, updated_at = ?
           WHERE measure_time = ? AND systolic = ? AND diastolic = ?`,
          [b.heartRate, b.period, b.note, now, b.measureTime, b.systolic, b.diastolic]);
      } else {
        await store.executeSql(
          `INSERT INTO bp_record (systolic, diastolic, heart_rate, measure_time, period, note, created_at, updated_at)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
          [b.systolic, b.diastolic, b.heartRate, b.measureTime, b.period, b.note, now, now]);
      }
    });
  }

  async queryMedLogDedupeTuples(): Promise<MedDedupeTuple[]> {
    const store: relationalStore.RdbStore = this.requireStore();
    const rs: relationalStore.ResultSet = await store.querySql(
      `SELECT medication_id, med_name, scheduled_time, status FROM ${DbConst.T_LOG}`
    );
    const out: MedDedupeTuple[] = [];
    try {
      while (rs.goToNextRow()) {
        out.push({
          medicationId: rs.getLong(0),
          medName: rs.getString(1),
          scheduledTime: rs.getLong(2),
          status: rs.getString(3)
        });
      }
    } finally {
      rs.close();
    }
    return out;
  }

  // ─────────────────── 领域命令（审查 R07）───────────────────

  /**
   * 保存「药品档案 + 计划版本」：**一个事务**内完成药品写入/启用、旧计划停用、新计划写入、
   * 清理按旧计划生成且尚未到期的待服、并按新计划重新生成待服。
   * 步骤：调用方通过 `generate` 传回生成逻辑（由页面/服务决定口径，避免 DB 层依赖业务规则）。
   * 提醒的登记**不在**事务内：DB 无共同事务边界，提交后再单独协调（报告规则 6）。
   */
  async saveMedicationAndPlan(cmd: SaveMedicationPlanCommand,
    generate: (tx: TxSession, medicationId: number) => Promise<number>): Promise<SaveMedicationPlanResult> {
    let medicationId: number = 0;
    let planId: number = 0;
    let cleared: number = 0;
    let generated: number = 0;
    await this.runInTransaction(async (tx: TxSession) => {
      if (cmd.medicationId > 0) {
        medicationId = await this.updateMedicationIn(tx, cmd.medicationId, cmd.medication, true);
      } else {
        medicationId = await this.insertMedication(cmd.medication, true, tx);
      }
      const plan: MedPlanDraft = {
        medicationId: medicationId,
        timeSlots: cmd.plan.timeSlots,
        startDate: cmd.plan.startDate,
        endDate: cmd.plan.endDate
      };
      planId = await this.upsertPlanIn(tx, plan);
      cleared = await this.deleteFuturePendingLogs(medicationId, cmd.regenerateFrom, tx);
      generated = await generate(tx, medicationId);
    });
    return {
      medicationId: medicationId,
      planId: planId,
      clearedPending: cleared,
      generatedPending: generated
    };
  }

  /** 更新药品档案并**显式**设置启用位（过去 updateMedication 不写 is_active，归档药品永远救不回来） */
  private async updateMedicationIn(tx: TxSession, id: number, draft: MedicationDraft, active: boolean): Promise<number> {
    const values: relationalStore.ValuesBucket = {
      'name': draft.name,
      'dosage': draft.dosage,
      'note': draft.note,
      'is_active': active ? 1 : 0,
      'updated_at': DateUtils.now()
    };
    const predicates: relationalStore.RdbPredicates = new relationalStore.RdbPredicates(DbConst.T_MED);
    predicates.equalTo('id', id);
    const affected: number = await this.write(tx, (store: relationalStore.RdbStore) => store.update(values, predicates));
    return affected > 0 ? id : 0;
  }

  /**
   * 归档药品：一个事务内停用档案、停用其计划、清理未来待服。
   * 提醒的协调由调用方在提交后单独做（审查 R02：不能实现成「全量取消」）。
   */
  async archiveMedication(medicationId: number, now: number): Promise<void> {
    await this.runInTransaction(async (tx: TxSession) => {
      await this.setMedicationActive(medicationId, false, tx);
      await this.deactivatePlansOf(medicationId, tx);
      await this.deleteFuturePendingLogs(medicationId, now, tx);
    });
  }

  // ───────────────────────── 清空 ─────────────────────────

  /**
   * 清空全部业务数据（FR-7.2）。
   * 单事务执行四表删除；Preferences 中的设置项（分级标准、免责声明已读）保留。
   */
  async clearAll(tx?: TxSession): Promise<void> {
    const store: relationalStore.RdbStore = tx !== undefined ? tx.store : this.requireStore();
    const wipe = async (): Promise<void> => {
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
    };
    if (tx !== undefined) {
      await wipe();
    } else {
      await this.runInTransaction(async (session: TxSession) => {
        await wipe();
      });
    }
    Logger.info(TAG, 'all data cleared');
  }
}
