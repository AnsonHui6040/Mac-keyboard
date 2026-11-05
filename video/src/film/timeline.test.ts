import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { END_CARD, FORBIDDEN, FPS, FRAMES, SHOTS, TITLES, captionLength, shotAt } from './timeline.ts';

const doc = readFileSync(new URL('../../../docs/video/product-film-storyboard.md', import.meta.url), 'utf8');

// Rows of the storyboard table: "| id | from–to | ..." with seconds.
const rows = doc.split('\n').filter((l) => /^\| (\d+(?:[a-f]|–\d+)?) \| \d+\.\d–\d+\.\d \|/.test(l)).map((l) => {
  const c = l.split('|').map((s) => s.trim());
  const [from, to] = c[2].split('–').map(Number);
  return { id: c[1], from, to };
});

test('the shots are the storyboard rows, in order, in frames = seconds times 30', () => {
  assert.equal(FPS, 30);
  assert.equal(FRAMES, 1800);
  const real = rows.filter((r) => r.id !== '24–27');
  const byId = new Map(SHOTS.map((s) => [s.id, s]));
  for (const r of real) {
    const s = byId.get(r.id)!;
    assert.ok(s, `shot ${r.id}`);
    assert.equal(s.from, Math.round(r.from * FPS), `${r.id} from`);
    assert.equal(s.to, Math.round(r.to * FPS), `${r.id} to`);
  }
  const order = real.map((r) => r.id);
  const ids = SHOTS.map((s) => s.id);
  assert.deepEqual(ids.filter((i) => order.includes(i)), order);
});

test('shots 24 to 27 split the 43.2 to 45.4 stretch into four, phone and Mac alternating, starting with the phone', () => {
  const four = ['24', '25', '26', '27'].map((id) => SHOTS.find((s) => s.id === id)!);
  assert.equal(four[0].from, 1296);
  assert.equal(four[3].to, 1362);
  assert.deepEqual(four.map((s) => s.kind), ['phone', 'mac', 'phone', 'mac']);
});

test('the shots cover 0 to 1800 without a gap or an overlap, and every frame has exactly one shot', () => {
  assert.equal(SHOTS[0].from, 0);
  assert.equal(SHOTS[SHOTS.length - 1].to, 1800);
  for (let i = 1; i < SHOTS.length; i++) assert.equal(SHOTS[i].from, SHOTS[i - 1].to, SHOTS[i].id);
  for (const s of SHOTS) assert.ok(s.to > s.from, s.id);
  for (let f = 0; f < FRAMES; f++) assert.ok(shotAt(f).from <= f && f < shotAt(f).to);
});

test('every title is at most 7 characters a second, at least 76 px, and starts and ends inside the film', () => {
  for (const t of TITLES) {
    const sec = (t.to - t.from) / FPS;
    assert.ok(sec >= 1.5, `${t.text}: ${sec}s`);
    assert.ok(captionLength(t.text) / sec <= 7, `${t.text}: ${captionLength(t.text)} in ${sec}s`);
    assert.ok(t.size >= 76, `${t.text}: size ${t.size}`);
    assert.ok(t.from >= 0 && t.to <= FRAMES);
  }
  assert.equal(captionLength('部分終端機與遠端桌面偵測不到'), 14);
});

test('the titles are the storyboard titles with the storyboard seconds', () => {
  const want: [string, number, number][] = [
    ['人不在 Mac 前卻要打字', 0.6, 2.8], ['用 iPhone 打字到 Mac', 4.0, 6.4], ['即時模式每按一個鍵就送出', 6.4, 9.0],
    ['草稿模式先改好再傳送', 10.2, 13.2], ['中文可以用手寫', 17.7, 20.5], ['也可以在 App 改用速成', 24.1, 26.8],
    ['一指移動游標', 29.0, 31.2], ['輕點就是點按', 31.2, 32.8], ['按住再拖曳', 32.8, 35.4], ['兩指輕點是右鍵', 35.4, 37.7], ['兩指滑動來捲動', 37.7, 41.0],
    ['系統標示的密碼欄不會輸入文字', 42.2, 45.4], ['部分終端機與遠端桌面偵測不到', 45.4, 48.3], ['請不要用這個鍵盤輸入密碼', 48.3, 50.5],
  ];
  assert.deepEqual(TITLES.map((t) => [t.text, t.from, t.to]), want.map(([a, b, c]) => [a, Math.round(b * FPS), Math.round(c * FPS)]));
  for (const [text] of want) assert.ok(doc.includes(text), text);
});

test('no title or card holds a banned string, a comma, a middle dot or an arrow', () => {
  const copy = [...TITLES.map((t) => t.text), ...END_CARD.map((c) => c.text)];
  for (const text of copy) for (const bad of FORBIDDEN) assert.ok(!text.includes(bad), `"${text}" has "${bad}"`);
  for (const text of copy) assert.ok(!/[,，·→←↑↓➜]/.test(text), text);
});

test('the end card is the storyboard table: seven lines, two layers at 54.0 and 56.0, with the sizes', () => {
  const table = doc.slice(doc.indexOf('## 第 31 鏡字卡'));
  const lines = table.split('\n').filter((l) => /^\| \d+\.\d \| /.test(l)).map((l) => {
    const c = l.split('|').map((s) => s.trim());
    return { at: Math.round(Number(c[1]) * FPS), text: c[2].replace(/（小字）$/, ''), size: Number(c[3]) };
  });
  assert.equal(lines.length, 7);
  assert.deepEqual(END_CARD.map((c) => ({ at: c.at, text: c.text, size: c.size })), lines);
  assert.deepEqual([...new Set(END_CARD.map((c) => c.at))], [1620, 1680]);
});

test('titles never overlap each other in time', () => {
  const sorted = [...TITLES].sort((a, b) => a.from - b.from);
  for (let i = 1; i < sorted.length; i++) assert.ok(sorted[i].from >= sorted[i - 1].to, sorted[i].text);
});
