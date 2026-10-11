#!/usr/bin/env node
/**
 * API 使用一致性扫描（UI 层兜底）
 *
 * 为什么需要它：
 *   tools/parity/run.mjs 只用 tsc 编译 common + model + service，
 *   **pages / components 是 ArkUI 专有语法（@Component / struct / @Builder），tsc 无法编译**。
 *   因此当某个服务层函数改了签名（例如 GradeService.gradeOf 去掉「参考口径」参数），
 *   UI 层的漏改不会被类型检查发现，只会在 DevEco 编译时才暴露。
 *
 * 本脚本用「正则定位 + 顶层逗号计数」的方式，对 UI 层做两项检查：
 *   1. 废弃标识符残留（已删除/改名的类型与函数不得再出现）
 *   2. 关键函数调用的实参个数（防止改签名后旧调用被漏改）
 *
 * 用法：node tools/check-api-usage.mjs
 */

import { readFileSync, readdirSync, statSync } from 'node:fs';
import { join, dirname, resolve, relative } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = resolve(HERE, '..', 'BpRecorder');
const SCAN_DIRS = [
  join(ROOT, 'entry', 'src', 'main', 'ets'),
  join(ROOT, 'entry', 'src', 'ohosTest', 'ets')
];

/** 递归收集 .ets 文件 */
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
    } else if (p.endsWith('.ets') || p.endsWith('.ts')) {
      out.push(p);
    }
  }
  return out;
}

/**
 * 从某个 '(' 起，统计顶层实参个数（支持跨行、嵌套括号、字符串字面量）。
 * 返回 -1 表示括号未闭合（视为异常）。
 */
function countTopLevelArgs(text, openIdx) {
  let depth = 0;
  let commas = 0;
  let hasContent = false;
  let i = openIdx;
  while (i < text.length) {
    const c = text[i];
    if (c === '\'' || c === '"' || c === '`') {
      const quote = c;
      i++;
      while (i < text.length && text[i] !== quote) {
        if (text[i] === '\\') {
          i++;
        }
        i++;
      }
      if (depth === 1) {
        hasContent = true;
      }
      i++;
      continue;
    }
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
    if (c === '(' || c === '[' || c === '{') {
      if (depth === 1) {
        // 顶层参数以数组/对象字面量开头（如 gradeDistribution([...])）时也算「有实参」
        hasContent = true;
      }
      depth++;
      if (depth === 1) {
        i++;
        continue;
      }
    } else if (c === ')' || c === ']' || c === '}') {
      if (c === ')') {
        depth--;
        if (depth === 0) {
          return hasContent ? commas + 1 : 0;
        }
      } else {
        depth--;
      }
    } else if (depth === 1) {
      if (c === ',') {
        commas++;
      } else if (!/\s/.test(c)) {
        hasContent = true;
      }
    }
    i++;
  }
  return -1;
}

/**
 * 把注释内容替换为等长空格（保留换行），使正则匹配不会命中注释里的示例文字。
 * 字符串字面量整体跳过，避免把字符串里的 // 误判成注释。
 */
function stripComments(text) {
  const out = text.split('');
  let i = 0;
  while (i < text.length) {
    const c = text[i];
    if (c === '/' && text[i + 1] === '/') {
      while (i < text.length && text[i] !== '\n') {
        out[i] = ' ';
        i++;
      }
      continue;
    }
    if (c === '/' && text[i + 1] === '*') {
      out[i] = ' ';
      out[i + 1] = ' ';
      i += 2;
      while (i < text.length && !(text[i] === '*' && text[i + 1] === '/')) {
        if (text[i] !== '\n') {
          out[i] = ' ';
        }
        i++;
      }
      if (i < text.length) {
        out[i] = ' ';
        out[i + 1] = ' ';
        i += 2;
      }
      continue;
    }
    if (c === '\'' || c === '"' || c === '`') {
      const quote = c;
      i++;
      while (i < text.length && text[i] !== quote) {
        if (text[i] === '\\') {
          i++;
        }
        i++;
      }
      i++;
      continue;
    }
    i++;
  }
  return out.join('');
}

/** 行号（1 基） */
function lineOf(text, idx) {
  let line = 1;
  for (let i = 0; i < idx && i < text.length; i++) {
    if (text[i] === '\n') {
      line++;
    }
  }
  return line;
}

// ───────────────────────── 规则 ─────────────────────────

/**
 * 规则 1：废弃标识符不得再出现。
 * 背景：v1.3 决策 D1/D2 把这些名字删除或改名，任何残留都是漏改。
 */
const FORBIDDEN = [
  { re: /GradeSpecs\s*\.\s*HOME_MONITOR/g, why: '家庭分级表已删除（D1：分级只用诊室表）' },
  { re: /GradeSpecs\s*\.\s*of\s*\(/g, why: 'GradeSpecs.of() 已删除（D1）' },
  { re: /\bmorningSurge\b/g, why: '已更名 morningVsOverall（D2）' },
  { re: /\bSurgeResult\b/g, why: '已更名 MorningCompare（D2）' },
  { re: /\bsurge\s*:/g, why: '字段 surge 已更名 morningCompare（D2）' },
  { re: /\.surge\b/g, why: '字段 surge 已更名 morningCompare（D2）' },
  { re: /ReminderService\s*\.\s*notifyNow\s*\(/g, why: '已更名 notifyText / notifyCatchUpOncePerDay（P0-1）' }
];

/**
 * 规则 2：关键函数实参个数。
 * 背景：改签名后若 UI 层漏改，ArkTS 编译期才报错，本机抓不到。
 */
const ARITY = [
  { re: /GradeService\s*\.\s*gradeOf\s*\(/g, args: 2, why: 'D1：gradeOf 不再接收参考口径参数' },
  { re: /GradeService\s*\.\s*refThreshold\s*\(/g, args: 1, why: 'D1：refThreshold(standard)' },
  { re: /StatsService\s*\.\s*gradeDistribution\s*\(/g, args: 1, why: 'D1：gradeDistribution 不再接收参考口径参数' },
  { re: /StatsService\s*\.\s*morningVsOverall\s*\(/g, args: 1, why: 'D2：morningVsOverall(records)' },
  { re: /ReportService\s*\.\s*build\s*\(/g, args: 7, why: 'D1：build(kind, range, records, logs, plans, vocab, now)' }
];

// ───────────────────────── 执行 ─────────────────────────

const files = [];
for (const dir of SCAN_DIRS) {
  walk(dir, files);
}

const problems = [];

for (const file of files) {
  const raw = readFileSync(file, 'utf8');
  const text = stripComments(raw); // 等长替换，行号与原文一致
  const rel = relative(ROOT, file);

  for (const rule of FORBIDDEN) {
    rule.re.lastIndex = 0;
    let m;
    while ((m = rule.re.exec(text)) !== null) {
      problems.push(`${rel}:${lineOf(text, m.index)}  出现废弃标识符「${m[0]}」—— ${rule.why}`);
    }
  }

  for (const rule of ARITY) {
    rule.re.lastIndex = 0;
    let m;
    while ((m = rule.re.exec(text)) !== null) {
      const openIdx = m.index + m[0].length - 1;
      const n = countTopLevelArgs(text, openIdx);
      if (n !== rule.args) {
        problems.push(`${rel}:${lineOf(text, m.index)}  ${m[0]} 实参个数为 ${n}，期望 ${rule.args} —— ${rule.why}`);
      }
    }
  }
}

console.log('检查范围：仅扫描 entry/src 下的 ArkTS 源码中「已登记的关键 API 调用形态与实参个数」；',
  '不覆盖运行时行为，也不覆盖系统 API 的语义正确性。');
console.log('================ API 使用一致性扫描 ================');
console.log(`扫描文件：${files.length} 个（main + ohosTest）`);
console.log('');

if (problems.length === 0) {
  console.log('✓ 无废弃标识符残留');
  console.log('✓ 关键函数实参个数全部正确');
  console.log('');
  console.log('================ 结论 ================');
  console.log('全部一致。');
  process.exit(0);
}

console.log(`✗ 发现 ${problems.length} 处问题：`);
for (const p of problems) {
  console.log(`  - ${p}`);
}
console.log('');
console.log('================ 结论 ================');
console.log('存在不一致，需修正。');
process.exit(1);
