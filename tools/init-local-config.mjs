// 首次初始化本机配置（审查 R16：提供安全的首次构建入口）。
//
// 做两件事，且**绝不覆盖已有文件**：
//   1) BpRecorder/build-profile.json5 ← 从脱敏模板 build-profile.example.json5 复制（若不存在）
//   2) tools/toolchain.local.json     ← 记录本机 DevEco / Node 位置（若不存在）
//
// 用法：node tools/init-local-config.mjs
import { copyFileSync, existsSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { HERE, PROJECT_ROOT, devecoHome, NODE_BIN } from './toolchain.mjs';

const EXAMPLE = join(PROJECT_ROOT, 'BpRecorder', 'build-profile.example.json5');
const TARGET = join(PROJECT_ROOT, 'BpRecorder', 'build-profile.json5');
const LOCAL = join(HERE, 'toolchain.local.json');

function refuse(what) {
  console.error(`已存在 ${what}：本脚本拒绝覆盖（防止抹掉本机签名配置或环境配置）。`);
  console.error('确认要重建时，请先手动删除该文件再运行。');
  process.exit(2);
}

let changed = 0;

if (existsSync(TARGET)) {
  console.log(`跳过：${TARGET} 已存在（本机签名配置受保护，已在 .gitignore 中）。`);
} else {
  if (!existsSync(EXAMPLE)) {
    console.error(`缺少模板：${EXAMPLE}`);
    process.exit(2);
  }
  copyFileSync(EXAMPLE, TARGET);
  console.log(`已生成 ${TARGET}（模板副本）—— 请填入本机签名信息，或用 DevEco 的 Automatically generate signature 就地重写。`);
  changed++;
}

if (existsSync(LOCAL)) {
  console.log(`跳过：${LOCAL} 已存在。`);
} else {
  const home = devecoHome();
  const body = {
    '_说明': '本机工具链位置，由 tools/init-local-config.mjs 生成；不进仓库（.gitignore）。',
    devecoHome: home ?? '未探测到，请填写 DevEco Studio 的 Contents 目录',
    nodeBin: NODE_BIN
  };
  writeFileSync(LOCAL, JSON.stringify(body, null, 2) + '\n', 'utf8');
  console.log(`已生成 ${LOCAL}（devecoHome=${home ?? '未探测到'}）。`);
  changed++;
}

console.log('\n下一步：');
console.log('  1) npm install                      # 安装 devDependency（typescript）');
console.log('  2) node tools/check-all.mjs --skip-review-regression');
console.log('  3) 构建见 README 的「构建与安装」一节');
process.exit(changed === 0 ? 0 : 0);
