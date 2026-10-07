#!/usr/bin/env node
/**
 * 工程配置体检（打开 DevEco 之前的静态检查）
 *
 * 为什么需要它：
 *   本机没有 DevEco / HarmonyOS SDK，无法通过"编译一次"来暴露配置类错误。
 *   而配置类错误（缺文件、字段缺失、路由表与页面文件不一致）**会在用户打开工程的第一步就报错**，
 *   恰恰是本机唯一还能提前拦住的一类问题。
 *
 * 检查项：
 *   1. 所有 .json5 配置文件语法正确（去注释、去尾逗号后按 JSON 解析）
 *   2. 构建/工程必需文件齐全（含 hvigor/hvigor-config.json5）
 *   3. hvigor-config.json5 的必选字段（modelVersion、dependencies）
 *   4. main_pages.json 与 pages/*.ets **双向**一致（漏一个 → 运行时路由找不到页面）
 *   5. 代码里 router.pushUrl 的目标必须都在 main_pages.json 中
 *   6. 工程路径合法性：字符白名单 + **路径上不得有符号链接**（后者会让 DevEco 同步失败）
 *   7. build-profile.json5 的 SDK 版本字段：非空 + 格式合规（用 IDE 自己的正则）+ targetSdkVersion 与模板同值
 *   8. 权限声明红线：不得出现 INTERNET；不得残留已废弃的权限名 REMINDER_AGENT
 *   9. app.json5：必填字段存在 + 版本相关可选字段不得与 build-profile.json5 冲突
 *      （apiReleaseType 由 hvigor 从 SDK 覆盖写入，手工写错会让 HAP 构建失败）
 *
 * 用法：
 *   node tools/check-project-config.mjs
 *   node tools/check-project-config.mjs --open-path=<DEVECO 将要打开的绝对路径>
 *     （不给 --open-path 时，默认检查工程根自身的路径）
 */

import { readFileSync, existsSync, readdirSync, statSync, lstatSync, realpathSync } from 'node:fs';
import { join, dirname, resolve, relative } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = resolve(HERE, '..', 'BpRecorder');
const ETS = join(ROOT, 'entry', 'src', 'main', 'ets');

let passCount = 0;
const problems = [];
let groupName = '';

function group(name) {
  groupName = name;
}
function ok(cond, name, detail) {
  if (cond) {
    passCount++;
  } else {
    problems.push(`[${groupName}] ${name}${detail === undefined ? '' : ' :: ' + detail}`);
  }
}

/**
 * 宽松 json5 → JSON：去掉行/块注释与尾逗号（字符串内容整体跳过）。
 * 目的只是语法体检，不追求完整 json5 规范。
 */
function json5ToJson(text) {
  let out = '';
  let i = 0;
  while (i < text.length) {
    const c = text[i];
    if (c === '/' && text[i + 1] === '/') {
      while (i < text.length && text[i] !== '\n') {
        i++;
      }
      continue;
    }
    if (c === '/' && text[i + 1] === '*') {
      i += 2;
      while (i < text.length && !(text[i] === '*' && text[i + 1] === '/')) {
        i++;
      }
      i += 2;
      continue;
    }
    if (c === '"') {
      out += c;
      i++;
      while (i < text.length) {
        out += text[i];
        if (text[i] === '\\') {
          i++;
          out += text[i];
        } else if (text[i] === '"') {
          i++;
          break;
        }
        i++;
      }
      continue;
    }
    out += c;
    i++;
  }
  return out.replace(/,(\s*[}\]])/g, '$1');
}

function readJson5(rel) {
  const p = join(ROOT, rel);
  if (!existsSync(p)) {
    return null;
  }
  return JSON.parse(json5ToJson(readFileSync(p, 'utf8')));
}

/** 递归收集 .ets */
function walk(dir, out = []) {
  let entries;
  try {
    entries = readdirSync(dir);
  } catch {
    return out;
  }
  for (const name of entries) {
    const p = join(dir, name);
    let st;
    try {
      st = statSync(p);
    } catch {
      continue;
    }
    if (st.isDirectory()) {
      walk(p, out);
    } else if (p.endsWith('.ets')) {
      out.push(p);
    }
  }
  return out;
}

console.log('================ 工程配置体检 ================');
console.log('');

// ───────────────────────── 1. json5 语法 ─────────────────────────
group('json5 语法');
const JSON5_FILES = [
  'AppScope/app.json5',
  'build-profile.json5',
  'oh-package.json5',
  'entry/build-profile.json5',
  'entry/oh-package.json5',
  'entry/src/main/module.json5',
  'entry/src/ohosTest/module.json5',
  'hvigor/hvigor-config.json5'
];
for (const f of JSON5_FILES) {
  const p = join(ROOT, f);
  if (!existsSync(p)) {
    ok(false, `${f} 存在`, '文件缺失');
    continue;
  }
  try {
    JSON.parse(json5ToJson(readFileSync(p, 'utf8')));
    ok(true, `${f} 语法正确`);
  } catch (err) {
    ok(false, `${f} 语法正确`, err.message);
  }
}

// ───────────────────────── 2. 必需文件齐全 ─────────────────────────
group('必需文件');
const REQUIRED = [
  'AppScope/app.json5',
  'AppScope/resources/base/element/string.json',
  'AppScope/resources/base/media/layered_image.json',
  'AppScope/resources/base/media/background.png',
  'AppScope/resources/base/media/foreground.png',
  'build-profile.json5',
  'hvigorfile.ts',
  'oh-package.json5',
  'hvigor/hvigor-config.json5',
  'entry/build-profile.json5',
  'entry/hvigorfile.ts',
  'entry/oh-package.json5',
  'entry/src/main/module.json5',
  'entry/src/main/resources/base/profile/main_pages.json',
  'entry/src/main/resources/base/element/string.json',
  'entry/src/main/resources/base/element/color.json',
  'entry/src/main/resources/dark/element/color.json',
  // 分层图标（华为 UX 硬规范：1024×1024、前景/背景两层、背景不得透明）
  'AppScope/resources/base/media/layered_image.json',
  'AppScope/resources/base/media/background.png',
  'AppScope/resources/base/media/foreground.png',
  'entry/src/main/resources/base/media/layered_image.json',
  'entry/src/main/resources/base/media/background.png',
  'entry/src/main/resources/base/media/foreground.png',
  'entry/src/main/resources/base/media/startIcon.png'
];
for (const f of REQUIRED) {
  ok(existsSync(join(ROOT, f)), `${f} 存在`);
}

// ───────────────────────── 3. hvigor-config 必选字段 ─────────────────────────
group('hvigor 构建配置');
const hvigor = readJson5('hvigor/hvigor-config.json5');
if (hvigor === null) {
  ok(false, 'hvigor/hvigor-config.json5 可解析');
} else {
  ok(typeof hvigor.modelVersion === 'string' && hvigor.modelVersion.length > 0,
    'hvigor-config 含必选字段 modelVersion', `实际：${JSON.stringify(hvigor.modelVersion)}`);
  ok(hvigor.dependencies !== undefined && typeof hvigor.dependencies === 'object' && !Array.isArray(hvigor.dependencies),
    'hvigor-config 含必选字段 dependencies（对象）',
    '缺少该字段时 DevEco 报 missingProperty: dependencies');
}

// ───────────────────────── 4. 路由表 与 页面文件 双向一致 ─────────────────────────
group('路由表 ↔ 页面文件');
const mainPages = readJson5('entry/src/main/resources/base/profile/main_pages.json');
if (mainPages === null || !Array.isArray(mainPages.src)) {
  ok(false, 'main_pages.json 含数组字段 src');
} else {
  const declared = new Set(mainPages.src);
  const pagesDir = join(ETS, 'pages');
  const actualFiles = readdirSync(pagesDir)
    .filter((n) => n.endsWith('.ets'))
    .map((n) => `pages/${n.replace(/\.ets$/, '')}`);

  for (const p of actualFiles) {
    ok(declared.has(p), `页面文件已在路由表登记：${p}`,
      '未登记 → 运行到该页面会报「页面找不到」');
  }
  const actualSet = new Set(actualFiles);
  for (const d of mainPages.src) {
    ok(actualSet.has(d), `路由表条目对应真实文件：${d}`,
      '路由表指向不存在的页面 → 构建或运行时失败');
  }
}

// ───────────────────────── 5. 代码中的跳转目标都在路由表内 ─────────────────────────
group('router 跳转目标');
if (mainPages !== null && Array.isArray(mainPages.src)) {
  const declared = new Set(mainPages.src);
  const allEts = walk(ETS);
  const targets = new Set();
  const re = /url:\s*'([^']+)'/g;
  for (const f of allEts) {
    const text = readFileSync(f, 'utf8');
    let m;
    while ((m = re.exec(text)) !== null) {
      if (m[1].startsWith('pages/')) {
        targets.add(m[1]);
      }
    }
  }
  ok(targets.size > 0, '至少解析到一个 router 跳转目标');
  for (const t of targets) {
    ok(declared.has(t), `跳转目标已登记在路由表：${t}`);
  }
}

// ───────────────────────── 6. 工程路径合法性（DevEco 硬性要求）─────────────────────────
group('工程路径合法性');
{
  // 6.1 字符白名单：只允许字母、数字、句点(.)、反斜杠(\)、下划线(_)、连字符(-)，且不以句点结尾。
  //     **不允许空格与中文** —— 否则报「路径无效，请选择只包含字母、数字、句点(.)、反斜杠(\)、
  //     下划线(_)和连字符(-) 的路径，且不能以句点结尾」，工程根本打不开。
  //     这里用 realpath 解析，保证校验的始终是真实路径。
  let realRoot = ROOT;
  try {
    realRoot = realpathSync(ROOT);
  } catch {
    realRoot = ROOT;
  }
  const segs = realRoot.split('/').filter(Boolean);
  const badSegs = segs.filter((s) => !/^[A-Za-z0-9._-]+$/.test(s));
  ok(badSegs.length === 0,
    '工程路径只含合法字符（无空格、无中文）',
    `非法路径段：${badSegs.map((s) => JSON.stringify(s)).join(', ')} → DevEco 会拒绝打开工程`);
  ok(!/\.$/.test(realRoot), '工程路径不以句点结尾');

  // 6.2 路径上不得有符号链接。
  //     不能用"本脚本自身路径"来判断：Node 会把 import.meta.url 解析成真实路径，
  //     从符号链接入口运行也看不出问题（已实测）。因此这里检查的是
  //     **IDE 将要打开的路径** —— 默认取工程根，可用 --open-path=<路径> 指定。
  //
  //     为什么这条要紧：工程目录经符号链接时，DevEco 判「模块是否在工程目录之内」会失配，
  //     把 entry 模块当成「外部模块」，因它不是 HAR/HSP 而中断同步，报
  //     「检测到不合法的依赖，请移除外部依赖中不是 HAR 或 HSP 类型的模块。」
  //     （消息键 invalid.dependency.module.type.error；栈在 CheckProjectImlFile.checkOuterModule）
  const openArg = process.argv.find((a) => a.startsWith('--open-path='));
  const openPath = openArg === undefined ? ROOT : openArg.slice('--open-path='.length);
  const linkSegs = [];
  const missingSegs = [];
  let walk = '';
  for (const s of openPath.split('/').filter(Boolean)) {
    walk += '/' + s;
    let st = null;
    try {
      st = lstatSync(walk);
    } catch {
      missingSegs.push(walk);
      continue;
    }
    if (st.isSymbolicLink()) {
      linkSegs.push(walk);
    }
  }
  ok(missingSegs.length === 0,
    'IDE 打开路径的每一段都存在',
    `不存在的路径段：${missingSegs.join(', ')}`);
  ok(linkSegs.length === 0,
    'IDE 打开路径上没有符号链接',
    `命中符号链接：${linkSegs.join(' → ')}；DevEco 会把 entry 判成「外部模块」，`
    + '同步失败并报「检测到不合法的依赖，请移除外部依赖中不是 HAR 或 HSP 类型的模块」');

  console.log(`  （IDE 打开路径：${openPath}）`);
  console.log(`  （工程真实路径：${realRoot}）`);
}

// ───────────────────────── 7. build-profile.json5 的 SDK 版本字段 ─────────────────────────
// 背景（踩过一次，且是 IDE 自己改坏的）：
//   DevEco 会往 products[].targetSdkVersion 写入空字符串 ""（发生在它对工程做"API 配置升级"时），
//   空串匹配不上 IDE 内部的版本号正则，于是工程同步直接中断，通知报：
//     「compileSdkVersion、compatibleSdkVersion或targetSdkVersio（若显式配置）的值不正确，
//       请按照指南中的说明修改该值。」（消息键 project.check.dotApi.format.error，
//       抛错点 HosIntegrationChecker.checkApiVersionFormat）
//   本检查用与 IDE **相同** 的正则、以及 IDE 自带工程模板的取值，提前拦住这种脏值。
group('build-profile.json5 的版本字段');
{
  // 两套官方正则，取自本机 DevEco 26.0.0.851 自带源码（逐字，未改动）：
  //   旧格式 HOS_COMPILE_SDK_VERSION_PATTERN：
  //     plugins/openharmony/lib/ohos-project-model-26.0.0.851.jar 的 CommonConstants
  //   新格式 DOT_API_VERSION_PATTERN + FIRST_DOT_API_VERSION=26：
  //     tools/hvigor/hvigor-ohos-plugin/node_modules/@ohos/sdkmanager-common/build/src/
  //     constants/component-contants.js
  // 判定规则与 sdkmanager 的 shouldUseDotApiVersion 一致：主版本号 >= 26 用点分制，否则旧格式。
  const SDK_PATTERN_OLD = /^(\d+)(\.\d+){2}\((?:[1-9]\d{0,2}|[1-9]\d{0,2}\.[1-9]\d{0,2}|[1-9]\d{0,2}\.(?:0|[1-9]\d{0,2})\.[1-9]\d{0,2})\)$/;
  const SDK_PATTERN_DOT = /^[1-9]\d?\.(?:[0-9]|[1-9]\d)\.(?:[0-9]|[1-9]\d)$/;
  const FIRST_DOT_API_VERSION = 26;
  // 项目级 app 字段只允许这 4 个键（取自 IDE 的 ohos-project-build-profile-schema.json）
  const APP_ALLOWED = ['signingConfigs', 'products', 'buildModeSet', 'multiProjects'];
  // 每个 product 必填（同上，取自 schema 的 products[].required）
  const PRODUCT_REQUIRED = ['name', 'compatibleSdkVersion'];

  const sdkVersionOk = (v) => {
    if (typeof v !== 'string') {
      return false;
    }
    const major = Number(v.split('.')[0]);
    return major >= FIRST_DOT_API_VERSION ? SDK_PATTERN_DOT.test(v) : SDK_PATTERN_OLD.test(v);
  };

  const profile = readJson5('build-profile.json5');
  if (profile === null || profile.app === undefined) {
    ok(false, 'build-profile.json5 可解析且含 app 字段');
  } else {
    const app = profile.app;
    const extraAppKeys = Object.keys(app).filter((k) => !APP_ALLOWED.includes(k));
    ok(extraAppKeys.length === 0,
      'app 字段只含 schema 允许的键',
      `出现了不允许的键：${extraAppKeys.join(', ')} → IDE 会报 build-profile.json5 配置不正确`);

    const products = Array.isArray(app.products) ? app.products : [];
    ok(products.length > 0, 'products 至少有一个');

    for (const p of products) {
      const label = `product「${p.name ?? '(未命名)'}」`;
      for (const k of PRODUCT_REQUIRED) {
        ok(p[k] !== undefined && p[k] !== '', `${label} 配置了必填项 ${k}`);
      }

      // 三个版本字段：显式配置时必须是合法字符串，且绝不能是空串
      for (const k of ['compileSdkVersion', 'compatibleSdkVersion', 'targetSdkVersion']) {
        if (p[k] === undefined) {
          continue;
        }
        const v = p[k];
        ok(typeof v === 'string' && v.length > 0,
          `${label} 的 ${k} 非空`,
          `当前值 ${JSON.stringify(v)} 为空或非字符串 → IDE 报「值不正确」并中断同步`);
        ok(typeof v === 'string' && sdkVersionOk(v),
          `${label} 的 ${k} 版本号格式合规（API≥26 用 x.y.z，以下用 x.y.z(n)）`,
          `当前值 ${JSON.stringify(v)} 不匹配本机 IDE 的两套官方正则 → hvigor 报 00308018「api version parameter is illegal」`);
      }

      // 模板要求：HarmonyOS 工程显式给出 targetSdkVersion，且与 compatibleSdkVersion 同值
      if (p.runtimeOS === 'HarmonyOS') {
        ok(p.targetSdkVersion !== undefined,
          `${label}（HarmonyOS）显式配置了 targetSdkVersion`,
          'IDE 自带模板会显式写 targetSdkVersion；缺失时 IDE 的「API 配置升级」可能写入空串导致同步中断');
        if (p.targetSdkVersion !== undefined && p.compatibleSdkVersion !== undefined) {
          ok(p.targetSdkVersion === p.compatibleSdkVersion,
            `${label} 的 targetSdkVersion 与 compatibleSdkVersion 一致`,
            `当前 ${JSON.stringify(p.targetSdkVersion)} vs ${JSON.stringify(p.compatibleSdkVersion)}`);
        }
      }

      if (p.runtimeOS !== undefined) {
        ok(['HarmonyOS', 'OpenHarmony'].includes(p.runtimeOS),
          `${label} 的 runtimeOS 取值合法`, `当前 ${JSON.stringify(p.runtimeOS)}`);
      }
    }
  }
}

// ───────────────────────── 8. 权限红线 ─────────────────────────
group('权限声明');
const moduleJson = readJson5('entry/src/main/module.json5');
if (moduleJson === null || moduleJson.module === undefined) {
  ok(false, 'module.json5 可解析且含 module 字段');
} else {
  const perms = (moduleJson.module.requestPermissions ?? []).map((p) => p.name);
  ok(!perms.includes('ohos.permission.INTERNET'), '未声明网络权限（NFR-5）');
  ok(!perms.some((n) => n === 'ohos.permission.REMINDER_AGENT'),
    '未残留已废弃的权限名 ohos.permission.REMINDER_AGENT',
    '该名称在 API 12 不存在，会导致编译失败');
  ok(perms.includes('ohos.permission.PUBLISH_AGENT_REMINDER'),
    '已按真实名称声明代理提醒权限');
  ok(perms.includes('ohos.permission.PRINT'), '已声明打印权限');
  ok(moduleJson.module.pages === '$profile:main_pages', 'module.pages 指向 $profile:main_pages');
  const abilities = moduleJson.module.abilities ?? [];
  ok(abilities.length > 0 && abilities[0].srcEntry !== undefined, 'abilities[0] 含 srcEntry');
  const srcEntry = abilities.length > 0 ? abilities[0].srcEntry : '';
  ok(existsSync(join(ROOT, 'entry/src/main', srcEntry.replace(/^\.\//, ''))),
    `EntryAbility 源文件存在：${srcEntry}`);

  // 权限文案资源必须已定义（否则打包报资源找不到）
  const entryStrings = readJson5('entry/src/main/resources/base/element/string.json');
  if (entryStrings !== null && Array.isArray(entryStrings.string)) {
    const names = new Set(entryStrings.string.map((e) => e.name));
    for (const p of (moduleJson.module.requestPermissions ?? [])) {
      const reason = p.reason ?? '';
      if (reason.startsWith('$string:')) {
        const key = reason.slice('$string:'.length);
        ok(names.has(key), `权限 reason 文案已定义：${key}`);
      }
    }
  }
}

// ───────────────────────── 9. app.json5 字段 ─────────────────────────
// 注意：minAPIVersion / targetAPIVersion / apiReleaseType **都是可选的**，
// IDE 自带工程模板里一个都不写；构建配置（build-profile.json5）才是版本号的正主。
// 其中 apiReleaseType 还由 hvigor 从 SDK 覆盖写入
// （hvigor-ohos-plugin/src/tasks/merge-profile.js: apiReleaseType = this.sdkInfo.getReleaseType()），
// 手工写它一旦格式不合规，HAP 构建会在 PreBuild 阶段直接失败：
//   00303038 Configuration Error / Schema validate failed（app.apiReleaseType 不匹配 pattern）。
group('app.json5');
const appJson = readJson5('AppScope/app.json5');
if (appJson === null || appJson.app === undefined) {
  ok(false, 'app.json5 可解析且含 app 字段');
} else {
  const a = appJson.app;
  ok(typeof a.bundleName === 'string' && a.bundleName.length > 0, 'bundleName 已配置');
  ok(typeof a.versionCode === 'number', 'versionCode 为数字');
  ok(typeof a.versionName === 'string', 'versionName 已配置');
  ok(typeof a.icon === 'string' && a.icon.length > 0, 'icon 已配置');
  ok(typeof a.label === 'string' && a.label.length > 0, 'label 已配置');

  const profile = readJson5('build-profile.json5');
  const product = profile?.app?.products?.[0] ?? {};
  const compatible = product.compatibleSdkVersion;
  const targetSdk = product.targetSdkVersion;

  // ── SDK 版本：两种合法格式
  //   旧："<osVersion>(<api>)"，如 "5.0.0(12)"
  //   新（HarmonyOS 26.0.0 起）："<version>"，如 "26.0.0" —— hvigor 报错原文：
  //   "api version parameter is illegal! Expected format: <major>[.<minor>][.<patch>],
  //    e.g., \"17\", \"17.2\", \"17.2.3\""
  const OLD_FMT = /^(\d+)\.(\d+)\.(\d+)\((\d+)\)$/;
  const NEW_FMT = /^\d+(?:\.\d+){0,2}$/;
  const fmtOk = (v) => typeof v === 'string' && (OLD_FMT.test(v) || NEW_FMT.test(v));
  ok(fmtOk(compatible), 'compatibleSdkVersion 格式合法（旧 X.Y.Z(N) / 新 X.Y.Z）',
    `实际：${JSON.stringify(compatible)}`);
  ok(fmtOk(targetSdk), 'targetSdkVersion 格式合法且显式非空', `实际：${JSON.stringify(targetSdk)}`);
  ok(compatible === targetSdk, 'compatibleSdkVersion 与 targetSdkVersion 同值',
    `compatible=${JSON.stringify(compatible)}，target=${JSON.stringify(targetSdk)}`);

  // 与本机 SDK 比对：本机通常只装一个 SDK，工程版本号必须能对上它，
  // 否则 hvigor 解析不到对应 SDK（这就是 00308018 的根因之一）。
  const sdkPkgPath = process.env.DEVECO_SDK_HOME
    ? join(process.env.DEVECO_SDK_HOME, 'default', 'openharmony', 'ets', 'oh-uni-package.json')
    : '/Volumes/ZT700-Data/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/ets/oh-uni-package.json';
  if (existsSync(sdkPkgPath)) {
    const pkg = JSON.parse(readFileSync(sdkPkgPath, 'utf8'));
    const sdkVer = String(pkg.platformVersion ?? '');
    const sdkApi = String(pkg.apiVersion ?? '');
    const oldMatch = OLD_FMT.exec(String(compatible));
    const projVer = oldMatch === null ? String(compatible) : oldMatch[1] + '.' + oldMatch[2] + '.' + oldMatch[3];
    ok(projVer === sdkVer, `compatibleSdkVersion 的版本号与本机 SDK 一致（${sdkVer}）`, `工程：${compatible}`);
    if (oldMatch !== null) {
      ok(oldMatch[4] === sdkApi, 'compatibleSdkVersion 的 API 号与本机 SDK 一致',
        `工程 ${oldMatch[4]}，SDK ${sdkApi}`);
    }
  } else {
    ok(true, '未找到本机 SDK 清单，跳过 SDK 版本比对');
  }

  // apiReleaseType 不得手工配置；若出现则必须匹配 hvigor 的校验正则
  // （正转载自构建报错 00303038 的 params.pattern，未做任何改动）
  const RELEASE_TYPE_PATTERN = /^(Canary[1-9]\d*)|(Beta[1-9]\d*)|(Release[1-9]\d*)$/;
  if (a.apiReleaseType === undefined) {
    ok(true, 'apiReleaseType 未手工配置（与 IDE 模板一致）');
  } else {
    ok(false, 'apiReleaseType 不应手工配置',
      `当前值 ${JSON.stringify(a.apiReleaseType)}；该字段由 hvigor 从 SDK 覆盖写入，IDE 模板也不写它`);
    ok(RELEASE_TYPE_PATTERN.test(String(a.apiReleaseType)),
      'apiReleaseType 形如 Release1 / Beta1 / Canary1',
      `当前值 ${JSON.stringify(a.apiReleaseType)} 不匹配 hvigor 的正则 `
      + '^(Canary[1-9]\\d*)|(Beta[1-9]\\d*)|(Release[1-9]\\d*)$');
  }

  // 可选字段若出现，不得与 build-profile.json5 的版本声明冲突
  const apiNum = (v) => {
    const m = /\((\d+)\)\s*$/.exec(String(v === undefined ? '' : v));
    return m === null ? null : Number(m[1]);
  };
  if (a.minAPIVersion !== undefined) {
    if (apiNum(compatible) === null) {
      ok(true, 'minAPIVersion 存在；compatibleSdkVersion 为新格式（不含 API 号），无法做数字比对');
    } else {
      ok(Number(a.minAPIVersion) === apiNum(compatible),
        'minAPIVersion 与 compatibleSdkVersion 的 API 号一致',
        `minAPIVersion=${JSON.stringify(a.minAPIVersion)}，compatibleSdkVersion=${JSON.stringify(compatible)}`);
    }
  }
  if (a.targetAPIVersion !== undefined) {
    if (apiNum(product.targetSdkVersion) === null) {
      ok(true, 'targetAPIVersion 存在；targetSdkVersion 为新格式（不含 API 号），无法做数字比对');
    } else {
      ok(Number(a.targetAPIVersion) === apiNum(product.targetSdkVersion),
        'targetAPIVersion 与 targetSdkVersion 的 API 号一致',
        `targetAPIVersion=${JSON.stringify(a.targetAPIVersion)}，targetSdkVersion=${JSON.stringify(product.targetSdkVersion)}`);
    }
  }
}

// ───────────────────────── 汇总 ─────────────────────────
console.log('================ 体检结果 ================');
console.log(`检查项通过：${passCount}    问题：${problems.length}`);
if (problems.length > 0) {
  console.log('');
  console.log('问题清单：');
  for (const p of problems) {
    console.log(`  ✗ ${p}`);
  }
  console.log('');
  console.log('================ 结论 ================');
  console.log('存在配置问题，打开 DevEco 前请先修正。');
  process.exit(1);
}
console.log('');
console.log('================ 结论 ================');
console.log('工程配置完备，可直接在 DevEco 中打开构建。');
