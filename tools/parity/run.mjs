// 离线逻辑一致性校验器。
//
// 为什么需要它：本机没有 DevEco / HarmonyOS SDK，无法编译整个工程。但策划文档 §4.3 要求
// 业务逻辑纯函数化以便单测。本脚本把**真实的 .ets 源码**（而不是另写一份实现）复制成 .ts，
// 用 tsc 做全量类型检查，并把纯逻辑部分真正跑起来做边界断言。
//
// 两道关卡：
//   1) 类型检查：common + model + service **全部文件**进入编译，
//      可捕获导入路径错误、类型不匹配、语法等问题（这些本应由 IDE 报出）；
//   2) 行为校验：纯函数（分级 / 统计 / 时段 / 状态机 / CSV 编解码 / 导入判重 / 导出格式 /
//      报告周期与组装）逐条断言，含 CL-10 的「导出 → 原样回导」往返幂等验证。
//
// 覆盖不到的（已在 docs/自检报告.md 如实标注）：
//   - HarmonyOS Kit 使用类型桩（见下方 STUBS），桩签名与真实 SDK 若有偏差，本机无法发现；
//   - ArkUI 组件与页面（@Entry / @Component / build()）需要 ArkUI 编译器，本机无法校验；
//   - 一切依赖真机的能力（代理提醒、相册安全控件、系统分享、打印、性能指标）。
//
// 用法：node tools/parity/run.mjs

import { spawnSync } from 'node:child_process';
import { cpSync, mkdirSync, rmSync, writeFileSync, existsSync, readdirSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { NODE_BIN, resolveTsc } from '../toolchain.mjs';

const HERE = dirname(fileURLToPath(import.meta.url));
const PROJECT_ROOT = resolve(HERE, '..', '..');
const ETS_ROOT = join(PROJECT_ROOT, 'BpRecorder', 'entry', 'src', 'main', 'ets');
const BUILD = join(HERE, '.build');
const SRC = join(BUILD, 'src');
const NODE_MODULES = join(BUILD, 'node_modules');

// Node 与 TypeScript 一律由 tools/toolchain.mjs 解析（默认当前 Node + 仓库内 devDependency），
// 不再写死某台机器的绝对路径（审查 R16）。
const TSC = resolveTsc();

const GROUPS = ['common', 'model', 'service'];

/**
 * 明确排除、并逐个声明理由（审查 R16：不能夸大全覆盖）。
 * common / model / service 下的新增源码会被自动纳入类型检查；确实不能纳入的必须在此登记。
 */
const EXCLUDED = new Map([
  // ['common/Xxx.ets', '依赖 ArkUI 组件，本机无法转译；改由 src/ohosTest 覆盖']
]);

function discoverSources() {
  const list = [];
  for (const group of GROUPS) {
    const dir = join(ETS_ROOT, group);
    if (!existsSync(dir)) {
      console.error(`缺少源码目录：${dir}`);
      process.exit(2);
    }
    for (const f of readdirSync(dir)) {
      if (!f.endsWith('.ets')) continue;
      const rel = `${group}/${f}`;
      if (EXCLUDED.has(rel)) continue;
      list.push([rel, rel.replace(/\.ets$/, '.ts')]);
    }
  }
  return list;
}

const SOURCES = discoverSources();

/**
 * HarmonyOS Kit 类型桩。仅用于本机离线类型检查与运行，不参与真实工程构建。
 * 目标是「形状正确」，不是「实现正确」：桩本身不做任何事，只提供签名。
 */
const STUBS = {
  '@kit.ArkData': {
    dts: `
export namespace relationalStore {
  export type ValueType = number | string | boolean | Uint8Array | null | undefined;
  export type ValuesBucket = Record<string, ValueType>;
  export enum SecurityLevel { S1 = 1, S2 = 2, S3 = 3, S4 = 4 }
  export interface StoreConfig { name: string; securityLevel: SecurityLevel; encrypt?: boolean }
  export class RdbPredicates {
    constructor(name: string);
    equalTo(field: string, value: ValueType): RdbPredicates;
    notEqualTo(field: string, value: ValueType): RdbPredicates;
    lessThan(field: string, value: ValueType): RdbPredicates;
    lessThanOrEqualTo(field: string, value: ValueType): RdbPredicates;
    greaterThan(field: string, value: ValueType): RdbPredicates;
    greaterThanOrEqualTo(field: string, value: ValueType): RdbPredicates;
    between(field: string, low: ValueType, high: ValueType): RdbPredicates;
    in(field: string, value: Array<ValueType>): RdbPredicates;
    orderByAsc(field: string): RdbPredicates;
    orderByDesc(field: string): RdbPredicates;
    limitAs(value: number): RdbPredicates;
    offsetAs(value: number): RdbPredicates;
  }
  export interface ResultSet {
    readonly rowCount: number;
    goToFirstRow(): boolean;
    goToNextRow(): boolean;
    getLong(columnIndex: number): number;
    getString(columnIndex: number): string;
    getColumnIndex(columnName: string): number;
    isColumnNull(columnIndex: number): boolean;
    close(): void;
  }
  export interface RdbStore {
    executeSql(sql: string, bindArgs?: Array<ValueType>): Promise<void>;
    querySql(sql: string, bindArgs?: Array<ValueType>): Promise<ResultSet>;
    insert(table: string, values: ValuesBucket): Promise<number>;
    batchInsert(table: string, values: Array<ValuesBucket>): Promise<number>;
    update(values: ValuesBucket, predicates: RdbPredicates): Promise<number>;
    delete(predicates: RdbPredicates): Promise<number>;
    query(predicates: RdbPredicates, columns?: Array<string>): Promise<ResultSet>;
    beginTransaction(): Promise<void>;
    commit(): Promise<void>;
    rollBack(): Promise<void>;
    close(): Promise<void>;
    readonly version: number;
  }
  export function getRdbStore(context: object, config: StoreConfig): Promise<RdbStore>;
}

export namespace preferences {
  export type ValueType = number | string | boolean | Array<number> | Array<string> | Array<boolean>;
  export interface Preferences {
    getSync(key: string, defValue: ValueType): ValueType;
    putSync(key: string, value: ValueType): void;
    hasSync(key: string): boolean;
    deleteSync(key: string): void;
    flush(): Promise<void>;
  }
  export interface Options { name: string }
  export function getPreferencesSync(context: object, options: Options): Preferences;
}

/**
 * 导出名是 uniformTypeDescriptor —— **不是** utd（utd 只是社区惯用别名）。
 * 本项目以 import { uniformTypeDescriptor as utd } from '@kit.ArkData' 取别名使用。
 * 成员名与取值逐一照抄真实声明 api/@ohos.data.uniformTypeDescriptor.d.ts（该枚举实际有 177 个成员，
 * 此处只列可能用到的；需要新增时请从该文件复制，不要凭记忆写）。
 */
export namespace uniformTypeDescriptor {
  export enum UniformDataType {
    TEXT = 'general.text',
    PLAIN_TEXT = 'general.plain-text',
    HTML = 'general.html',
    MARKDOWN = 'general.markdown',
    IMAGE = 'general.image',
    JPEG = 'general.jpeg',
    PNG = 'general.png',
    VIDEO = 'general.video',
    AUDIO = 'general.audio',
    PDF = 'com.adobe.pdf'
  }
}
`,
    js: `exports.relationalStore = {}; exports.preferences = {}; exports.uniformTypeDescriptor = { UniformDataType: {} };`
  },
  '@kit.LocalizationKit': {
    dts: `
export namespace resourceManager {
  export interface ResourceManager {
    getStringSync(resId: number): string;
    getStringSync(resId: number, ...args: Array<string | number>): string;
    /** 返回 0xAARRGGBB 颜色数值 */
    getColorSync(resId: number): number;
  }
}
`,
    js: `exports.resourceManager = {};`
  },
  '@kit.AbilityKit': {
    dts: `
import { resourceManager } from '@kit.LocalizationKit';
export namespace common {
  export interface AbilityInfo { bundleName: string; name: string }
  export interface Context {
    readonly resourceManager: resourceManager.ResourceManager;
    readonly filesDir: string;
    readonly cacheDir: string;
  }
  export interface UIAbilityContext extends Context {
    readonly abilityInfo: AbilityInfo;
  }
  export interface AbilityStageContext extends Context {}
}
`,
    js: `exports.common = {};`
  },
  '@kit.BasicServicesKit': {
    dts: `
export interface BusinessError extends Error { code: number; message: string; name: string }

export namespace print {
  export interface PrintTask {
    on(type: string, callback: () => void): void;
    off(type: string, callback?: () => void): void;
  }
  export function print(files: Array<string>): Promise<PrintTask>;
}
`,
    js: `exports.BusinessError = class BusinessError extends Error {}; exports.print = { print: async () => ({ on() {}, off() {} }) };`
  },
  '@kit.PerformanceAnalysisKit': {
    dts: `
export namespace hilog {
  export function debug(domain: number, tag: string, format: string, ...args: Array<string | number>): void;
  export function info(domain: number, tag: string, format: string, ...args: Array<string | number>): void;
  export function warn(domain: number, tag: string, format: string, ...args: Array<string | number>): void;
  export function error(domain: number, tag: string, format: string, ...args: Array<string | number>): void;
  export function isLoggable(domain: number, tag: string, level: number): boolean;
}
`,
    js: `exports.hilog = { debug(){}, info(){}, warn(){}, error(){}, isLoggable(){ return false; } };`
  },
  '@kit.CoreFileKit': {
    dts: `
export namespace fileIo {
  export enum OpenMode { READ_ONLY = 0, WRITE_ONLY = 1, READ_WRITE = 2, CREATE = 64, TRUNC = 512 }
  export interface File { fd: number; path?: string; name?: string }
  export interface Stat { size: number; mtime: number; isDirectory(): boolean; isFile(): boolean }
  export function openSync(path: string, mode?: number): File;
  export function open(path: string, mode?: number): Promise<File>;
  export function statSync(file: number | string): Stat;
  export function listFileSync(path: string, options?: object): string[];
  export function unlinkSync(path: string): void;
  export function readSync(fd: number, buffer: ArrayBuffer, options?: object): number;
  export function writeSync(fd: number, buffer: ArrayBuffer | string, options?: object): number;
  export function write(fd: number, buffer: ArrayBuffer | string): Promise<number>;
  export function closeSync(file: number | File): void;
  export function close(file: File): Promise<void>;
}
export namespace fileUri {
  export function getUriFromPath(path: string): string;
}
export namespace picker {
  export class DocumentSelectOptions {
    maxSelectNumber?: number;
    fileSuffixFilters?: Array<string>;
    defaultFilePathUri?: string;
  }
  export class DocumentSaveOptions {
    newFileNames?: Array<string>;
    fileSuffixChoices?: Array<string>;
  }
  export class DocumentViewPicker {
    constructor(context?: object);
    select(options?: DocumentSelectOptions): Promise<Array<string>>;
    save(options?: DocumentSaveOptions): Promise<Array<string>>;
  }
}
`,
    js: `exports.fileIo = {}; exports.fileUri = {}; exports.picker = {};`
  },
  '@kit.ArkTS': {
    dts: `
export namespace util {
  export interface DecodeToStringOptions { stream?: boolean }
  /**
   * 成员名照抄真实声明 api/@ohos.util.d.ts 的 util.TextDecoderOptions（fatal / ignoreBOM）。
   * 本项目用它做「严格解码失败即换编码」的判断，故必须存在于桩中。
   */
  export interface TextDecoderOptions { fatal?: boolean; ignoreBOM?: boolean }
  /** 真实声明：api/@ohos.util.d.ts 的 util.TextEncoder（encodeInto 返回 Uint8Array） */
  export class TextEncoder {
    constructor(encoding?: string);
    encodeInto(input: string): Uint8Array;
    encodeIntoUint8Array(input: string, dest: Uint8Array): object;
  }
  export class TextDecoder {
    static create(encoding?: string, options?: TextDecoderOptions): TextDecoder;
    decodeToString(input: Uint8Array, options?: DecodeToStringOptions): string;
    decodeWithStream(input: Uint8Array, options?: DecodeToStringOptions): string;
  }
}
`,
    js: `exports.util = {};`
  },
  '@kit.ImageKit': {
    dts: `
export namespace image {
  export interface PackingOption { format: string; quality: number }
  export interface Size { width: number; height: number }
  export interface PixelMap {
    readonly isEditable: boolean;
    getImageInfoSync(): object;
    release(): void;
  }
  export interface ImagePacker {
    packToData(source: PixelMap, option: PackingOption): Promise<ArrayBuffer>;
    release(): void;
  }
  export function createImagePacker(): ImagePacker;
  export interface Region { size: Size; x: number; y: number }
  export interface DecodingOptions { desiredRegion?: Region; desiredSize?: Size; editable?: boolean }
  export interface ImageSource {
    createPixelMap(options?: DecodingOptions): Promise<PixelMap>;
    release(): void;
  }
  export function createImageSource(buf: ArrayBuffer | Uint8Array): ImageSource;
}
`,
    js: `exports.image = {};`
  },
  '@kit.MediaLibraryKit': {
    dts: `
export namespace photoAccessHelper {
  export enum PhotoType { IMAGE = 1, VIDEO = 2 }
  export interface PhotoAccessHelper {
    createAsset(photoType: PhotoType, extension: string): Promise<string>;
  }
  export function getPhotoAccessHelper(context: object): PhotoAccessHelper;
  export class MediaAssetChangeRequest {
    static deleteAssets(context: object, uriList: Array<string>): Promise<void>;
  }
}
`,
    js: `exports.photoAccessHelper = {};`
  },
  '@kit.ShareKit': {
    dts: `
export namespace systemShare {
  export interface ShareData { utd: string; uri?: string; title?: string; description?: string }
  export class SharedData {
    constructor(data: ShareData | Array<ShareData>);
  }
  export enum SelectionMode { SINGLE = 0, BATCH = 1 }
  export enum SharePreviewMode { DEFAULT = 0, DETAIL = 1 }
  export interface ShareControllerOptions { selectionMode?: SelectionMode; previewMode?: SharePreviewMode }
  export class ShareController {
    constructor(data: SharedData);
    show(context: object, options?: ShareControllerOptions): Promise<void>;
    hide(): Promise<void>;
  }
}
`,
    js: `exports.systemShare = {};`
  },
  '@kit.ArkUI': {
    dts: `
import { image } from '@kit.ImageKit';
export namespace componentSnapshot {
  export function get(id: string): Promise<image.PixelMap>;
  export function createFromBuilder(builder: () => void): Promise<image.PixelMap>;
}
/**
 * 成员名照抄真实声明 api/@ohos.arkui.UIContext.d.ts 的 UIContext。
 * 本工程在 common 层只用 getHostContext()（getContext 的现代替代，API 26 迁移），
 * 返回 Context | undefined —— undefined 分支由 ResUtils.hostContext 显式抛错。
 */
export class UIContext {
  getHostContext(): Context | undefined;
}
`,
    js: `exports.componentSnapshot = {}; exports.UIContext = class UIContext {};`
  },
  '@kit.BackgroundTasksKit': {
    dts: `
export namespace reminderAgentManager {
  export enum ReminderType { REMINDER_TYPE_TIMER = 'REMINDER_TYPE_TIMER', REMINDER_TYPE_CALENDAR = 'REMINDER_TYPE_CALENDAR', REMINDER_TYPE_ALARM = 'REMINDER_TYPE_ALARM' }
  export enum ActionButtonType { ACTION_BUTTON_TYPE_CLOSE = 'ACTION_BUTTON_TYPE_CLOSE', ACTION_BUTTON_TYPE_SNOOZE = 'ACTION_BUTTON_TYPE_SNOOZE' }
  export interface ActionButton { title: string; type: ActionButtonType }
  export interface WantAgent { pkgName: string; abilityName: string }
  export interface ReminderRequestTimer {
    reminderType: ReminderType;
    triggerTimeInSeconds: number;
    title?: string;
    content?: string;
    expiredContent?: string;
    snoozeContent?: string;
    notificationId?: number;
    slotType?: number;
    ringDuration?: number;
    wantAgent?: WantAgent;
    actionButton?: Array<ActionButton>;
  }
  export interface LocalDateTime { year: number; month: number; day: number; hour: number; minute: number; second?: number }
  export interface ReminderRequest {
    reminderType?: ReminderType;
    title?: string;
    content?: string;
    expiredContent?: string;
    snoozeContent?: string;
    notificationId?: number;
    slotType?: number;
    ringDuration?: number;
    wantAgent?: object;
    actionButton?: Array<object>;
    hour?: number;
    minute?: number;
    daysOfWeek?: Array<number>;
    endDateTime?: LocalDateTime;
  }
  export interface ReminderRequestCalendar {
    reminderType: ReminderType;
    dateTime: LocalDateTime;
    repeatMonths?: Array<number>;
    repeatDays?: Array<number>;
    daysOfWeek?: Array<number>;
    endDateTime?: LocalDateTime;
    title?: string;
    content?: string;
    expiredContent?: string;
    snoozeContent?: string;
    notificationId?: number;
    slotType?: number;
    ringDuration?: number;
    wantAgent?: object;
    actionButton?: Array<object>;
  }
  export interface ReminderRequestAlarm {
    reminderType: ReminderType;
    hour: number;
    minute: number;
    daysOfWeek?: Array<number>;
    title?: string;
    content?: string;
    expiredContent?: string;
    snoozeContent?: string;
    notificationId?: number;
    slotType?: number;
    ringDuration?: number;
    wantAgent?: WantAgent;
    actionButton?: Array<ActionButton>;
  }
  export function publishReminder(reminderReq: ReminderRequestTimer | ReminderRequestAlarm | ReminderRequestCalendar): Promise<number>;
  export function cancelReminder(reminderId: number): Promise<void>;
  export function cancelAllReminders(): Promise<void>;
  export function getValidReminders(): Promise<Array<number>>;
  export interface ReminderInfo { reminderId: number; reminderReq: ReminderRequest }
  export function getAllValidReminders(): Promise<Array<ReminderInfo>>;
}
`,
    js: `exports.reminderAgentManager = {};`
  },
  '@kit.NotificationKit': {
    dts: `
export namespace notificationManager {
  export enum SlotType { SOCIAL_COMMUNICATION = 1, SERVICE_INFORMATION = 2, CONTENT_INFORMATION = 3, OTHER = 0 }
  export enum ContentType { NOTIFICATION_CONTENT_BASIC_TEXT = 0, NOTIFICATION_CONTENT_LONG_TEXT = 1 }
  export interface NotificationBasicContent { title: string; text: string; additionalText?: string }
  export interface NotificationContent { notificationContentType: ContentType; normal?: NotificationBasicContent }
  export interface NotificationRequest { id: number; content: NotificationContent }
  export function publish(request: NotificationRequest): Promise<void>;
  export function cancel(id: number): Promise<void>;
  export function isNotificationEnabled(): Promise<boolean>;
  export function requestEnableNotification(context: object): Promise<void>;
}
`,
    js: `exports.notificationManager = {};`
  }
};

function step(msg) {
  process.stdout.write(`\n[parity] ${msg}\n`);
}

rmSync(BUILD, { recursive: true, force: true });
mkdirSync(SRC, { recursive: true });

step(`源码覆盖：自动发现 ${SOURCES.length} 个文件（${GROUPS.join('/')}），显式排除 ${EXCLUDED.size} 个`);
for (const [rel, why] of EXCLUDED) process.stdout.write(`  排除 ${rel}：${why}\n`);
step('复制真实 .ets 源码为 .ts');
for (const [from, to] of SOURCES) {
  const srcPath = join(ETS_ROOT, from);
  if (!existsSync(srcPath)) {
    console.error(`缺少源文件：${srcPath}`);
    process.exit(2);
  }
  const destPath = join(SRC, to);
  mkdirSync(dirname(destPath), { recursive: true });
  // 仅做 .ets → .ts 的等价拷贝，不改动任何逻辑
  cpSync(srcPath, destPath);
}

step('生成 HarmonyOS Kit 类型桩');
mkdirSync(NODE_MODULES, { recursive: true });
for (const [name, stub] of Object.entries(STUBS)) {
  const dir = join(NODE_MODULES, name);
  mkdirSync(dir, { recursive: true });
  writeFileSync(join(dir, 'package.json'),
    JSON.stringify({ name, version: '0.0.0', main: 'index.js', types: 'index.d.ts' }, null, 2), 'utf8');
  writeFileSync(join(dir, 'index.d.ts'), stub.dts.trim() + '\n', 'utf8');
  writeFileSync(join(dir, 'index.js'), stub.js + '\n', 'utf8');
}

writeFileSync(join(BUILD, 'shim.d.ts'), `
// ArkUI 运行时类型的编译期桩：仅用于本机离线编译，不参与真实工程构建。
interface Resource { id: number; }
declare function $r(key: string, ...args: Array<string | number>): Resource;
declare type ResourceColor = Resource | string | number;
declare type ResourceStr = Resource | string;
declare function getContext(): object;
declare const process: { stdout: { write(s: string): void }; exit(code: number): void };
`, 'utf8');

writeFileSync(join(BUILD, 'tsconfig.json'), JSON.stringify({
  compilerOptions: {
    target: 'ES2021',
    module: 'commonjs',
    moduleResolution: 'node',
    outDir: 'out',
    strict: false,
    noImplicitAny: false,
    skipLibCheck: true,
    esModuleInterop: true,
    lib: ['ES2021'],
    types: []
  },
  include: ['src/**/*.ts', 'harness.ts', 'shim.d.ts']
}, null, 2), 'utf8');

cpSync(join(HERE, 'harness.ts'), join(BUILD, 'harness.ts'));
cpSync(join(HERE, 'preload.ts'), join(BUILD, 'preload.ts'));

step('类型检查（common + model + service 全覆盖）');
const tsc = spawnSync(NODE_BIN, [TSC, '-p', join(BUILD, 'tsconfig.json')], { encoding: 'utf8' });
if (tsc.stdout) process.stdout.write(tsc.stdout);
if (tsc.stderr) process.stderr.write(tsc.stderr);
if (tsc.status !== 0) {
  console.error('\n[parity] 类型检查失败，未执行用例。');
  process.exit(3);
}

step('执行边界用例');
const run = spawnSync(NODE_BIN, [join(BUILD, 'out', 'harness.js')], { encoding: 'utf8' });
process.stdout.write(run.stdout ?? '');
process.stderr.write(run.stderr ?? '');
process.exit(run.status ?? 1);
