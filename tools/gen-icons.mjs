/**
 * 生成应用图标（华为 UX 规范 + 扁平专业风）。
 *
 * ## 规范依据（硬性，上架检查会卡）
 * - 应用图标资源**必须分层**：前景图 + 背景图两层；
 * - 尺寸必须为 **1024 px × 1024 px**，PNG；
 * - **不允许自行裁切圆角**、**不允许在资源内添加内间距**（圆角由系统遮罩裁）；
 * - **背景图不允许含有透明像素**（含圆角裁切或透明内边距导致的透明也不行）——
 *   否则在系统遮罩下会出现异常白边/黑边。
 *
 * ## 启动图标的尺寸与上面不同
 * startWindowIcon（`$media:startIcon`）由系统在启动窗口里居中显示，restool 对它有
 * **144 px 上限**，超出会在构建日志里给出
 * `Warning: The width or height of the png file referenced by the startWindowIcon exceeds the limit (144 pixels)`。
 * 该告警不影响编译（`restool resources compile success`），但 1024 px 的启动图在每次冷启动
 * 都要解码一张大图，属于白付的开销，故 startIcon 单独按 144 px 出图。
 *
 * ## 文件布局（对齐 DevEco 26.0 自带模板）
 *   AppScope/resources/base/media/      layered_image.json + background.png + foreground.png
 *   entry/src/main/resources/base/media/ layered_image.json + background.png + foreground.png + startIcon.png
 *   app.json5 / module.json5：icon 指向 $media:layered_image，startWindowIcon 指向 $media:startIcon
 *
 * ## 为什么用脚本生成而不是直接放二进制
 * SVG 是源，PNG 是产物 —— 改配色或形状只需改 SVG 再跑一次，且生成过程可复现、可校验。
 *
 * 运行：node tools/gen-icons.mjs
 * 依赖：rsvg-convert（librsvg）。未安装时脚本会明确报错，不静默产出错误图标。
 */
import { execFileSync } from 'node:child_process';
import { existsSync, mkdirSync, writeFileSync, readFileSync, rmSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');
const SIZE = 1024;
/** 启动图标尺寸：restool 对 startWindowIcon 的上限就是 144 px（见文件头说明） */
const START_SIZE = 144;

// ── 配色（扁平、专业；蓝色取自 Material Blue 700→900，线色与 App 内主色同系）
const BG_TOP = '#1976D2';
const BG_BOTTOM = '#0D47A1';
const HEART = '#FFFFFF';
/** 心电线：与 App 主色同系的中蓝，保证在白色心形上清晰，同时不与背景抢注意力 */
const PULSE = '#1565C0';

/** 扁平几何心形：居中，包围盒 x 236–788 / y 248–776（占画布约 54%） */
const HEART_PATH = 'M512,776 '
  + 'C512,776 236,572 236,408 '
  + 'C236,316 308,248 386,248 '
  + 'C437,248 484,275 512,316 '
  + 'C540,275 587,248 638,248 '
  + 'C716,248 788,316 788,408 '
  + 'C788,572 512,776 512,776 Z';

/** 心电线（ECG 复合波），水平居中穿过心形中部 */
const PULSE_PATH = 'M288,504 H388 L418,470 L452,538 L500,462 L540,520 L572,504 H736';

const svg = (inner, extraDefs = '') =>
  `<svg xmlns="http://www.w3.org/2000/svg" width="${SIZE}" height="${SIZE}" viewBox="0 0 ${SIZE} ${SIZE}">`
  + `<defs>${extraDefs}</defs>${inner}</svg>`;

/** 背景：整幅不透明（规范要求背景不得含透明像素） */
const backgroundSvg = svg(
  `<rect width="${SIZE}" height="${SIZE}" fill="url(#bg)"/>`,
  `<linearGradient id="bg" x1="0" y1="0" x2="0" y2="1">`
  + `<stop offset="0" stop-color="${BG_TOP}"/><stop offset="1" stop-color="${BG_BOTTOM}"/></linearGradient>`
);

/** 前景：心形 + 心电线，心形以外必须透明 */
const foregroundSvg = svg(
  `<path d="${HEART_PATH}" fill="${HEART}"/>`
  + `<g clip-path="url(#heartClip)">`
  + `<path d="${PULSE_PATH}" fill="none" stroke="${PULSE}" stroke-width="40"`
  + ` stroke-linecap="round" stroke-linejoin="round"/>`
  + `</g>`,
  `<clipPath id="heartClip"><path d="${HEART_PATH}"/></clipPath>`
);

/** 启动图标：背景 + 前景合成，不透明（任何 startWindowBackground 下都清晰） */
const startIconSvg = svg(
  `<rect width="${SIZE}" height="${SIZE}" fill="url(#bg)"/>`
  + `<path d="${HEART_PATH}" fill="${HEART}"/>`
  + `<g clip-path="url(#heartClip)">`
  + `<path d="${PULSE_PATH}" fill="none" stroke="${PULSE}" stroke-width="40"`
  + ` stroke-linecap="round" stroke-linejoin="round"/>`
  + `</g>`,
  `<linearGradient id="bg" x1="0" y1="0" x2="0" y2="1">`
  + `<stop offset="0" stop-color="${BG_TOP}"/><stop offset="1" stop-color="${BG_BOTTOM}"/></linearGradient>`
  + `<clipPath id="heartClip"><path d="${HEART_PATH}"/></clipPath>`
);

const LAYERED_JSON = JSON.stringify({
  'layered-image': {
    background: '$media:background',
    foreground: '$media:foreground'
  }
}, null, 2) + '\n';

function haveRsvg() {
  try {
    execFileSync('rsvg-convert', ['--version'], { stdio: 'ignore' });
    return true;
  } catch {
    return false;
  }
}

function render(svgText, outPath, size = SIZE) {
  const tmp = join(dirname(outPath), '.tmp-icon.svg');
  writeFileSync(tmp, svgText, 'utf8');
  try {
    execFileSync('rsvg-convert', ['-w', String(size), '-h', String(size), '-o', outPath, tmp],
      { stdio: 'pipe' });
  } finally {
    rmSync(tmp, { force: true });
  }
}

/** 读 PNG 的 IHDR，取宽高与颜色类型（6=RGBA，2=RGB，0=灰） */
function pngInfo(path) {
  const buf = readFileSync(path);
  if (buf.length < 24 || buf.toString('ascii', 1, 4) !== 'PNG') {
    return null;
  }
  return {
    width: buf.readUInt32BE(16),
    height: buf.readUInt32BE(20),
    colorType: buf[25]
  };
}

const problems = [];
function check(ok, msg) {
  if (!ok) {
    problems.push(msg);
    console.log(`✗ ${msg}`);
  } else {
    console.log(`✓ ${msg}`);
  }
}

console.log('================ 应用图标生成 ================');
if (!haveRsvg()) {
  console.error('✗ 未找到 rsvg-convert（librsvg）。请先安装：brew install librsvg');
  process.exit(1);
}

const targets = [
  join(ROOT, 'BpRecorder', 'AppScope', 'resources', 'base', 'media'),
  join(ROOT, 'BpRecorder', 'entry', 'src', 'main', 'resources', 'base', 'media')
];

for (const dir of targets) {
  if (!existsSync(dir)) {
    mkdirSync(dir, { recursive: true });
  }
  const scope = dir.includes('AppScope') ? 'AppScope' : 'entry/main';
  console.log(`\n---- ${scope} ----`);

  const bg = join(dir, 'background.png');
  const fg = join(dir, 'foreground.png');
  const si = join(dir, 'startIcon.png');

  render(backgroundSvg, bg);
  render(foregroundSvg, fg);
  writeFileSync(join(dir, 'layered_image.json'), LAYERED_JSON, 'utf8');
  console.log('  已写出 background.png / foreground.png / layered_image.json');

  if (scope === 'entry/main') {
    render(startIconSvg, si, START_SIZE);
    console.log('  已写出 startIcon.png');
  }

  const b = pngInfo(bg);
  const f = pngInfo(fg);
  check(b !== null && b.width === SIZE && b.height === SIZE,
    `background.png 为 ${SIZE}×${SIZE}（实际 ${b === null ? '无法解析' : `${b.width}×${b.height}`}）`);
  check(f !== null && f.width === SIZE && f.height === SIZE,
    `foreground.png 为 ${SIZE}×${SIZE}（实际 ${f === null ? '无法解析' : `${f.width}×${f.height}`}）`);
  // 关键红线：背景不得含透明通道，前景必须有透明区域
  check(b !== null && b.colorType !== 6, 'background.png 不含 alpha 通道（背景不允许透明像素）');
  check(f !== null && f.colorType === 6, 'foreground.png 含 alpha 通道（心形以外透明）');
  if (scope === 'entry/main') {
    const s = pngInfo(si);
    check(s !== null && s.width === START_SIZE && s.height === START_SIZE,
      `startIcon.png 为 ${START_SIZE}×${START_SIZE}（实际 ${s === null ? '无法解析' : `${s.width}×${s.height}`}）`);
  }
}

console.log('\n================ 结论 ================');
if (problems.length > 0) {
  console.log(`存在 ${problems.length} 项问题`);
  process.exit(1);
}
console.log('全部通过。');
