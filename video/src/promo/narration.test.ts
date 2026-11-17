import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { NARRATION } from './narration.ts';

const VOICE_DIR = new URL('../../public/voice/promo/', import.meta.url);
const manifest = JSON.parse(readFileSync(new URL('./voice-manifest.json', import.meta.url), 'utf8')) as Record<string, { seconds: number; sha256: string; firstPause: number | null }>;
const IDS = ['01', '02', '03', '04', '05', '06', '07', '08', '09', '10'];

test('ten lines, captions verbatim from the spec, spoken differs only in line 10', () => {
  assert.equal(NARRATION.length, 10);
  assert.deepEqual(NARRATION.map((n) => n.id), IDS);
  assert.deepEqual(NARRATION.map((n) => n.seg), ['1', '2', '3', '4', '5', '6', '7', '8', '9', '10']);
  assert.deepEqual(NARRATION.map((n) => n.caption), [
    '一支 iPhone，可以打字到三部電腦。',
    '先打到 Mac。即時模式每按一個鍵就送出；草稿模式可以先改好錯字，再一次傳送。',
    '點一下，換到 Windows。',
    '中文可以直接手寫，選好字按傳送，記事本就出現剛寫好的字。',
    '再點一下，換到 Linux。',
    '習慣速成的話，可以在 App 裡改用速成輸入，一樣打得出中文。',
    '再點一下，回到 Mac。',
    '鍵盤還能變成觸控板：一指移動游標，輕點就是點按，按住可以拖曳，兩指輕點是右鍵，兩指滑動來捲動。',
    '這就是 Remote Keyboard。',
    '目前是 v0.2 Alpha 版，透過 SideStore 安裝。下載連結在說明欄。',
  ]);
  assert.ok(NARRATION[9].spoken.includes('零點二'));
  assert.ok(NARRATION[9].caption.includes('v0.2'));
  assert.ok(!NARRATION[9].spoken.includes('v0.2'));
  for (const n of NARRATION.slice(0, 9)) assert.equal(n.spoken, n.caption, n.id);
});

test('no banned words in the narration', () => {
  for (const n of NARRATION) for (const w of ['密碼', '零延遲', 'Wi-Fi', '香港']) {
    assert.ok(!n.caption.includes(w), `${n.id} caption ${w}`);
    assert.ok(!n.spoken.includes(w), `${n.id} spoken ${w}`);
  }
});

test('approved takes are untouched', () => {
  const lines = readFileSync(new URL('requests.log', VOICE_DIR), 'utf8').split('\n');
  const cut = lines.indexOf('# replaced');
  const rows = (cut < 0 ? lines : lines.slice(0, cut)).filter((l) => l !== '' && !l.startsWith('#')).map((l) => l.split('\t'));
  assert.deepEqual(rows.map((r) => r[0]), IDS);
  for (const r of rows) {
    assert.match(r[7], /^\d{4}-\d{2}-\d{2}$/, `${r[0]} approved`);
    const actual = createHash('sha256').update(readFileSync(new URL(`${r[0]}.mp3`, VOICE_DIR))).digest('hex');
    assert.equal(r[6], actual, `${r[0]} log vs file`);
    assert.equal(manifest[r[0]].sha256, actual, `${r[0]} manifest vs file`);
  }
});

test('manifest durations match the files', () => {
  assert.deepEqual(Object.keys(manifest).sort(), IDS);
  for (const id of IDS) {
    const s = Number(execFileSync('ffprobe', ['-v', 'error', '-show_entries', 'format=duration', '-of', 'default=nw=1:nk=1', new URL(`${id}.mp3`, VOICE_DIR).pathname], { encoding: 'utf8' }).trim());
    assert.ok(Math.abs(s - manifest[id].seconds) <= 0.01, `${id}: ${s} vs ${manifest[id].seconds}`);
  }
});

test('the pauses that time the taps and the trackpad are where the words are', () => {
  for (const id of ['03', '05', '07']) {
    const p = manifest[id].firstPause!;
    assert.ok(p >= 0.4 && p <= 1.4, `${id} ${p}`);
  }
  const p8 = manifest['08'].firstPause!;
  assert.ok(p8 >= 1.2 && p8 <= 2.7, `08 ${p8}`);
});

test('no API key in the repo', () => {
  const root = execFileSync('git', ['rev-parse', '--show-toplevel'], { encoding: 'utf8' }).trim();
  let status = 0;
  try {
    execFileSync('git', ['-C', root, 'grep', '-nE', 'sk_[0-9a-f]{20,}', '--', '.', ':!Pods'], { stdio: 'pipe' });
  } catch (e) {
    status = (e as { status: number }).status;
  }
  assert.equal(status, 1);
});
