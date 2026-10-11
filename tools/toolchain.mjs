// 工具链解析（所有离线脚本共用）。
//
// 为什么要有它：审查 R16 指出 parity 脚本写死了某台机器的 Node 与 tsc 绝对路径
// （/Users/yang/.workbuddy/...），换机器即不可用。这里的规则是：
//   1) 只用**当前 Node**（process.execPath）或用显式环境变量覆盖，不依赖别人的目录；
//   2) DevEco / SDK / hdc 这类设备与构建工具，按「环境变量 → tools/toolchain.local.json → 标准安装位置」顺序解析；
//   3) 解析不到就报明确错误并给出补救命令，不静默使用错误工具。
import { existsSync, readFileSync, readdirSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createRequire } from 'node:module';

export const HERE = dirname(fileURLToPath(import.meta.url));
export const PROJECT_ROOT = resolve(HERE, '..');
export const ETS_ROOT = join(PROJECT_ROOT, 'BpRecorder', 'entry', 'src', 'main', 'ets');
export const LOCAL_CONFIG_PATH = join(HERE, 'toolchain.local.json');

function readLocalConfig() {
  if (!existsSync(LOCAL_CONFIG_PATH)) return {};
  try {
    return JSON.parse(readFileSync(LOCAL_CONFIG_PATH, 'utf8'));
  } catch (err) {
    throw new Error(`${LOCAL_CONFIG_PATH} 不是合法 JSON：${err.message}（删除后重新运行 node tools/init-local-config.mjs）`);
  }
}

const local = readLocalConfig();

/** 运行离线脚本的 Node：默认当前 Node，可用 PARITY_NODE 覆盖。 */
export const NODE_BIN = process.env.PARITY_NODE ?? local.nodeBin ?? process.execPath;

// 只认「环境变量 → 本机配置文件 → 操作系统标准安装位置」，不写死任何个人目录（审查 R16）。
const DEVECO_CANDIDATES = [
  process.env.DEVECO_HOME,
  local.devecoHome,
  '/Applications/DevEco-Studio.app/Contents'
];

/** DevEco Studio 的 Contents 目录；找不到返回 null（调用方决定是报错还是降级）。 */
export function devecoHome() {
  for (const c of DEVECO_CANDIDATES) {
    if (c && existsSync(join(c, 'sdk'))) return c;
  }
  return null;
}

export function requireDeveco(reason) {
  const home = devecoHome();
  if (home === null) {
    throw new Error(
      `找不到 DevEco Studio（${reason}）：请设置环境变量 DEVECO_HOME，` +
      '或运行 node tools/init-local-config.mjs 写入 tools/toolchain.local.json');
  }
  return home;
}

export function sdkHome() {
  return process.env.DEVECO_SDK_HOME ?? join(requireDeveco('构建/安装需要 SDK'), 'sdk');
}

export function hdcBin() {
  return process.env.HDC_BIN ?? join(sdkHome(), 'default', 'openharmony', 'toolchains', 'hdc');
}

export function hvigorwBin() {
  return process.env.HVIGORW ?? join(requireDeveco('构建需要 hvigor'), 'tools', 'hvigor', 'bin', 'hvigorw.js');
}

export function hvigorNodeBin() {
  const home = requireDeveco('构建需要 hvigor 自带的 Node');
  return process.env.HVIGOR_NODE ?? join(home, 'tools', 'node', 'bin', 'node');
}

export function javaHome() {
  return process.env.JAVA_HOME ?? join(requireDeveco('构建需要 JBR'), 'jbr', 'Contents', 'Home');
}

/** TypeScript 编译器：PARITY_TSC → 仓库内 node_modules → toolchain.local.json。 */
export function resolveTsc() {
  const candidates = [
    process.env.PARITY_TSC,
    join(PROJECT_ROOT, 'node_modules', 'typescript', 'bin', 'tsc'),
    local.tsc
  ];
  for (const c of candidates) {
    if (c && existsSync(c)) return c;
  }
  try {
    return createRequire(import.meta.url).resolve('typescript/bin/tsc');
  } catch {
    // 落到最后的明确报错
  }
  throw new Error(
    '找不到 TypeScript 编译器：请在仓库根执行 `npm install`（devDependency typescript），' +
    '或用环境变量 PARITY_TSC 指定 tsc 路径');
}

/** 便捷：列出某个源码目录下的 .ets（用于覆盖统计）。 */
export function listEts(group) {
  const dir = join(ETS_ROOT, group);
  return existsSync(dir) ? readdirSync(dir).filter(f => f.endsWith('.ets')).sort() : [];
}
