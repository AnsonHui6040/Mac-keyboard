import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readdirSync, readFileSync } from 'node:fs';

const dir = new URL('./', import.meta.url);
const sources = readdirSync(dir).filter((f) => f.endsWith('.ts') && !f.endsWith('.test.ts'));
const code = (f: string) => readFileSync(new URL(f, dir), 'utf8').replace(/\/\*[\s\S]*?\*\//g, '').replace(/^\s*\/\/.*$/gm, '');

test('src/audio has the modules the brief names', () => {
  for (const f of ['events.ts', 'music.ts', 'synth.ts', 'register.ts']) assert.ok(sources.includes(f), f);
});

test('src/audio is deterministic: no Math.random, no real time', () => {
  for (const f of sources) {
    const text = code(f);
    assert.doesNotMatch(text, /Math\.random/, f);
    assert.doesNotMatch(text, /Date\.now|new Date|performance\.now|setTimeout|setInterval|requestAnimationFrame/, f);
  }
});

test('src/audio is all synthesis: no sample files, no @remotion/sfx, no staticFile, no fetch', () => {
  for (const f of sources) {
    const text = code(f);
    assert.doesNotMatch(text, /@remotion\/sfx|staticFile|fetch\(|decodeAudioData|\.(mp3|wav|ogg|m4a|aac|flac)\b/i, f);
  }
});

test('the only module that registers onFrame is register.ts', () => {
  for (const f of sources) assert.equal(/\bonFrame\(/.test(code(f)), f === 'register.ts', f);
});
