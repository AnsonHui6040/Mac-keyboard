import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { parseScript } from './gen-script-data.mjs';

const scriptPath = fileURLToPath(
  new URL('../../docs/video/install-tutorial-script.md', import.meta.url),
);

test('parses the real script into 21 scenes totalling 310 seconds', () => {
  const md = readFileSync(scriptPath, 'utf8');
  const { scenes } = parseScript(md);
  assert.equal(scenes.length, 21);
  assert.equal(scenes.reduce((a, s) => a + s.seconds, 0), 310);
  assert.equal(scenes[15].n, 16);
  assert.equal(scenes[15].seconds, 26);
  assert.ok(scenes[15].caption.startsWith('這個版本沒有經過 Apple 公證'));
  assert.ok(scenes[15].caption.includes('丟到垃圾桶'));
});

test('a row with a missing field throws an error naming the scene number', () => {
  const md = [
    '## 場景',
    '',
    '| # | 秒數 | 畫面 | 操作重點（不上畫面） | 字幕 |',
    '|---|---|---|---|---|',
    '| 1 | 10 | 畫面一 | 重點一 | 字幕一 |',
    '| 7 | 11 | 畫面七 | 重點七 | |',
  ].join('\n');
  assert.throws(() => parseScript(md), /第 7 場/);
});

test('a row with too few cells throws an error naming the scene number', () => {
  const md = [
    '## 場景',
    '',
    '| # | 秒數 | 畫面 | 操作重點 | 字幕 |',
    '|---|---|---|---|---|',
    '| 3 | 13 | 畫面三 | 重點三 |',
  ].join('\n');
  assert.throws(() => parseScript(md), /第 3 場/);
});
