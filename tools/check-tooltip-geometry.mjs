// 图表提示气泡（tooltip）几何回归检查。
//
// 背景：`BpLineChart.drawSelection` 里的气泡原本是手工用两个 `arc` + `lineTo` 拼的圆角矩形，
// 顶点顺序写错了 —— 左端圆心落在**上边**上、右端圆心落在**下边**上，`closePath` 再补一条斜线，
// 于是填充区域被斜切掉一个角：实测 y 范围是 26–54，而矩形本应是 30–50。
// 后果：文字左侧约 30% 落在色块之外，白字压在白色卡片上，看起来「背景与前景不一致」。
//
// 本检查做两件事（既查源码写法，也算几何覆盖）：
//   1. 源码断言：气泡必须走 `arcTo` 版的标准圆角矩形，且 `drawSelection` 里不得再出现手工 arc 拼装；
//   2. 几何断言：按源码里的字号/内边距算出气泡盒，验证文字 100% 被覆盖，且填充区域恰好等于盒子范围。
//
// 用法：node tools/check-tooltip-geometry.mjs

import { readFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const SRC = join(resolve(HERE, '..'), 'BpRecorder', 'entry', 'src', 'main', 'ets', 'components', 'BpLineChart.ets');
const src = readFileSync(SRC, 'utf8');

// 字号与盒高从源码解析，不在本文件里写死：
// 这里曾经硬编码「字号基准 14」，而 BpLineChart 的 FONT_TOOLTIP 后来调到 17、19，
// 于是几何断言一直在验一个早已不存在的盒子（断言照旧全绿，等于白验）。
function parseConst(re, name) {
  const m = re.exec(src);
  if (m === null) {
    console.error(`✗ 无法从 BpLineChart.ets 解析气泡常量 ${name}（源码写法变了？）`);
    process.exit(1);
  }
  return Number(m[1]);
}
const FONT_BASE = parseConst(/const\s+FONT_TOOLTIP\s*:\s*number\s*=\s*(\d+)/, 'FONT_TOOLTIP');
const BOX_H_EXTRA = parseConst(/const\s+boxH\s*:\s*number\s*=\s*boxFont\s*\+\s*(\d+)/, 'boxH = boxFont + N');
const PAD_X = parseConst(/const\s+padX\s*:\s*number\s*=\s*(\d+)/, 'padX');

let problems = 0;
function check(ok, name, extra) {
  if (ok) {
    console.log(`  ✓ ${name}`);
  } else {
    problems += 1;
    console.log(`  ✗ ${name}${extra === undefined ? '' : `  ← ${extra}`}`);
  }
}

console.log('================ 图表气泡几何检查 ================');

// ── 1. 源码写法断言 ──
console.log('\n[源码]');
const hasArcToRect = /roundedRectPath\s*\(\s*x:\s*number[\s\S]{0,900}?ctx\.arcTo\(/.test(src);
check(hasArcToRect, '存在基于 arcTo 的 roundedRectPath 方法');

const drawSelection = src.slice(src.indexOf('private drawSelection'));
const callsRounded = /this\.roundedRectPath\(/.test(drawSelection);
check(callsRounded, 'drawSelection 通过 roundedRectPath 绘制气泡底');

const handRolled = /ctx\.arc\(\s*boxX/.test(drawSelection) || /ctx\.arc\([^)]*boxW/.test(drawSelection);
check(!handRolled, 'drawSelection 内不再手工 arc 拼装圆角矩形', '又改回手工拼装了，几何会再次出错');

// 文字基线必须由盒高与字号推出，而不是硬编码的固定像素
check(/boxY\s*\+\s*boxH\s*\/\s*2/.test(drawSelection), '文字基线按「盒中心 + 字号比例」计算（字号变大不会溢出盒外）');

// ── 2. 几何断言 ──
console.log('\n[几何] 文字是否 100% 落在气泡底内');

function flattenArc(cx, cy, r, a0, a1, seg = 16) {
  const pts = [];
  for (let i = 0; i <= seg; i++) {
    const a = a0 + (a1 - a0) * (i / seg);
    pts.push([cx + r * Math.cos(a), cy + r * Math.sin(a)]);
  }
  return pts;
}

/** 现行实现：标准圆角矩形（arcTo 语义等价的多边形） */
function fixedPath(x, y, w, h, r) {
  const rr = Math.min(r, w / 2, h / 2);
  const pts = [[x + rr, y], [x + w - rr, y]];
  pts.push(...flattenArc(x + w - rr, y + rr, rr, -Math.PI / 2, 0));
  pts.push([x + w, y + h - rr]);
  pts.push(...flattenArc(x + w - rr, y + h - rr, rr, 0, Math.PI / 2));
  pts.push([x + rr, y + h]);
  pts.push(...flattenArc(x + rr, y + h - rr, rr, Math.PI / 2, Math.PI));
  pts.push([x, y + rr]);
  pts.push(...flattenArc(x + rr, y + rr, rr, Math.PI, Math.PI * 1.5));
  return pts;
}

/** 缺陷版：两个 arc + lineTo + closePath（用于反证，确保不会被改回去） */
function brokenPath(x, y, w, h) {
  const pts = [];
  pts.push(...flattenArc(x + 4, y, 4, Math.PI * 0.5, Math.PI * 1.5));
  pts.push([x + w - 4, y]);
  pts.push([x + w - 4, y + h - 4]);
  pts.push(...flattenArc(x + w - 4, y + h, 4, Math.PI * 1.5, Math.PI * 0.5));
  return pts;
}

function inside(poly, x, y) {
  let hit = false;
  for (let i = 0, j = poly.length - 1; i < poly.length; j = i++) {
    const [xi, yi] = poly[i];
    const [xj, yj] = poly[j];
    if ((yi > y) !== (yj > y) && x < ((xj - xi) * (y - yi)) / (yj - yi) + xi) {
      hit = !hit;
    }
  }
  return hit;
}

/** 按源码常量构造气泡盒：字号基准 / 盒高偏移 / 内边距均由上面从源码解析得到，圆角 6 */
function coverage(scale, boxX = 40, boxY = 30, textLen = 100) {
  const font = Math.round(FONT_BASE * scale);
  const boxH = font + BOX_H_EXTRA;
  const padX = PAD_X;
  const boxW = textLen + padX * 2;
  const r = 6;
  const poly = fixedPath(boxX, boxY, boxW, boxH, r);
  const baseline = boxY + boxH / 2 + font * 0.36;
  const textCenterY = baseline - font * 0.35;    // 字面高度的中心
  let ok = 0;
  const samples = 9;
  for (let i = 0; i < samples; i++) {
    const x = boxX + padX + ((boxW - padX * 2) * i) / (samples - 1);
    if (inside(poly, x, textCenterY)) { ok++; }
  }
  const ys = poly.map((p) => p[1]);
  return { font, boxH, ok, samples, yMin: Math.min(...ys), yMax: Math.max(...ys), boxY };
}

for (const scale of [1, 1.35]) {
  const g = coverage(scale);
  check(g.ok === g.samples, `字号缩放 ${scale}（${g.font}vp，盒高 ${g.boxH}）：文字覆盖 ${g.ok}/${g.samples}`);
  check(Math.abs(g.yMin - g.boxY) < 0.5 && Math.abs(g.yMax - (g.boxY + g.boxH)) < 0.5,
    `字号缩放 ${scale}：填充区域恰好等于盒子范围（y ${g.yMin.toFixed(1)}–${g.yMax.toFixed(1)}，期望 ${g.boxY}–${g.boxY + g.boxH}）`);
}

console.log('\n[反证] 缺陷版写法确实覆盖不全（据此保留本检查的意义）');
{
  const boxY = 30;
  const boxH = 28;
  const boxX = 40;
  const boxW = 120;
  const poly = brokenPath(boxX, boxY, boxW, boxH);
  const ys = poly.map((p) => p[1]);
  let ok = 0;
  const samples = 9;
  const textCenterY = boxY + boxH / 2 + 14 * 0.36 - 14 * 0.35;
  for (let i = 0; i < samples; i++) {
    const x = boxX + 10 + ((boxW - 20) * i) / (samples - 1);
    if (inside(poly, x, textCenterY)) { ok++; }
  }
  check(ok < samples, `手工 arc 版覆盖 ${ok}/${samples}（不满即证明确有缺陷）`);
  check(Math.max(...ys) > boxY + boxH + 1, `手工 arc 版 y 范围 ${Math.min(...ys).toFixed(1)}–${Math.max(...ys).toFixed(1)} 超出盒子（期望 ${boxY}–${boxY + boxH}）`);
}

console.log('\n================ 结论 ================');
console.log(problems === 0 ? '气泡几何与源码写法均正确。' : `发现 ${problems} 处问题，需修正。`);
process.exit(problems === 0 ? 0 : 1);
