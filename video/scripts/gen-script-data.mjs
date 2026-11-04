import { readFileSync, writeFileSync, existsSync, mkdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname } from 'node:path';

const here = dirname(fileURLToPath(import.meta.url));
const SCRIPT_PATH = `${here}/../../docs/video/install-tutorial-script.md`;
const OUT_PATH = `${here}/../src/data/script.json`;

const COLUMNS = ['#', '秒數', '畫面', '操作重點', '字幕'];

function splitRow(line) {
  let s = line.trim();
  if (s.startsWith('|')) s = s.slice(1);
  if (s.endsWith('|')) s = s.slice(0, -1);
  return s.split('|').map((c) => c.trim());
}

/**
 * Parse the table under "## 場景" into { scenes: { n, seconds, focus, caption }[] }.
 */
export function parseScript(md) {
  const lines = md.split(/\r?\n/);
  const start = lines.findIndex((l) => /^##\s+場景\s*$/.test(l));
  if (start === -1) throw new Error('找不到「## 場景」區段');

  let end = lines.length;
  for (let i = start + 1; i < lines.length; i++) {
    if (/^##\s/.test(lines[i])) {
      end = i;
      break;
    }
  }
  const tableLines = lines.slice(start + 1, end).filter((l) => l.trim().startsWith('|'));
  if (tableLines.length < 3) throw new Error('「## 場景」下找不到表格');

  const header = splitRow(tableLines[0]);
  const idx = {};
  for (const col of COLUMNS) {
    const i = header.findIndex((h) => h === col || h.startsWith(col));
    if (i === -1) throw new Error(`表頭缺少欄位「${col}」`);
    idx[col] = i;
  }

  const scenes = [];
  for (const line of tableLines.slice(2)) {
    const cells = splitRow(line);
    const label = cells[0] || '(未知)';
    for (const col of COLUMNS) {
      const v = cells[idx[col]];
      if (v === undefined || v === '') {
        throw new Error(`第 ${label} 場缺少欄位「${col}」`);
      }
    }
    const n = Number(cells[idx['#']]);
    const seconds = Number(cells[idx['秒數']]);
    if (!Number.isInteger(n)) throw new Error(`第 ${label} 場的場次編號不是整數`);
    if (!Number.isFinite(seconds) || seconds <= 0) {
      throw new Error(`第 ${n} 場的秒數不是正數：${cells[idx['秒數']]}`);
    }
    scenes.push({
      n,
      seconds,
      focus: cells[idx['操作重點']],
      caption: cells[idx['字幕']],
    });
  }
  return { scenes };
}

function render(data) {
  return JSON.stringify(data, null, 2) + '\n';
}

function diffScenes(a, b) {
  const byN = (d) => new Map(d.scenes.map((s) => [s.n, s]));
  const ma = byN(a);
  const mb = byN(b);
  const ns = [...new Set([...ma.keys(), ...mb.keys()])].sort((x, y) => x - y);
  return ns.filter((n) => JSON.stringify(ma.get(n)) !== JSON.stringify(mb.get(n)));
}

function main() {
  const check = process.argv.includes('--check');
  const generated = parseScript(readFileSync(SCRIPT_PATH, 'utf8'));
  const text = render(generated);

  if (check) {
    if (!existsSync(OUT_PATH)) {
      console.error(`${OUT_PATH} 不存在，請先執行 npm run data`);
      process.exit(1);
    }
    const existingText = readFileSync(OUT_PATH, 'utf8');
    if (existingText === text) {
      console.log('script.json 與腳本一致');
      return;
    }
    let existing;
    try {
      existing = JSON.parse(existingText);
    } catch {
      console.error('script.json 不是有效的 JSON');
      process.exit(1);
    }
    const diff = diffScenes(generated, existing);
    console.error(
      diff.length
        ? `script.json 與腳本不一致，差異場次：${diff.join(', ')}`
        : 'script.json 與腳本不一致（只有格式差異）',
    );
    process.exit(1);
  }

  mkdirSync(dirname(OUT_PATH), { recursive: true });
  writeFileSync(OUT_PATH, text);
  console.log(`寫入 ${generated.scenes.length} 場到 src/data/script.json`);
}

if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) main();
