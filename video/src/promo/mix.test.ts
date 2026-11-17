import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import { FILM_FRAMES } from '../data/scenes/index.ts';
import { FRAMES as INTRO_FRAMES } from '../intro/timeline.ts';
import { FRAMES as FILM_LENGTH } from '../film/timeline.ts';
import { FORBIDDEN } from '../film/timeline.ts';
import { NARRATION } from './narration.ts';
import { END_CARD, FPS, FRAMES, TITLES, VOICE } from './timeline.ts';
import { PROMO_MUSIC } from './music.ts';
import { isPromoContext, musicGainDb, sfxGainDb, voiceDuck } from './mix.ts';

const len = (frames: number, rate = 48000) => Math.round((frames / FPS) * rate);

test('voiceDuck is 1 inside a line, 0 well outside, and ramps over 0.25 s', () => {
  for (const v of VOICE) {
    assert.equal(voiceDuck(v.from), 1);
    assert.equal(voiceDuck(Math.floor((v.from + v.to) / 2)), 1);
    assert.equal(voiceDuck(v.to - 1), 1);
  }
  assert.equal(voiceDuck(VOICE[0].from - 8), 0);
  const mid = voiceDuck(VOICE[0].from - 4);
  assert.ok(mid > 0 && mid < 1, `${mid}`);
  assert.ok(voiceDuck(VOICE[0].to + 4) > 0 && voiceDuck(VOICE[0].to + 4) < 1);
  assert.equal(voiceDuck(VOICE[0].to + 8), 0);
  for (let f = 1; f < FRAMES; f++) assert.ok(Math.abs(voiceDuck(f) - voiceDuck(f - 1)) <= 1 / 7 + 1e-9, `step at ${f}`);
});

test('music is ducked 10 dB and effects 6 dB under the voice', () => {
  const inside = VOICE[1].from + 5;
  const outside = VOICE[0].to + 20;
  assert.equal(musicGainDb(inside), -10);
  assert.equal(sfxGainDb(inside), -6);
  assert.equal(musicGainDb(outside), 0);
  assert.equal(sfxGainDb(outside), 0);
  const mid = VOICE[0].from - 4;
  assert.ok(musicGainDb(mid) < 0 && musicGainDb(mid) > -10);
  assert.ok(sfxGainDb(mid) < 0 && sfxGainDb(mid) > -6);
});

test('the promo sounds play only in a context of the promo length', () => {
  assert.equal(isPromoContext(len(FRAMES), 48000), true);
  assert.equal(isPromoContext(len(FRAMES) + 1, 48000), true);
  assert.equal(isPromoContext(len(FRAMES) - 1, 48000), true);
  assert.equal(isPromoContext(len(FRAMES) + 5, 48000), false);
  for (const other of [FILM_LENGTH, INTRO_FRAMES, FILM_FRAMES]) assert.equal(isPromoContext(len(other), 48000), false, `${other}`);
});

test('no music segments before the user picks a track', () => {
  assert.equal(PROMO_MUSIC.length, 0);
});

test('no banned or Cantonese text anywhere in the promo', () => {
  const dir = new URL('.', import.meta.url);
  for (const f of readdirSync(dir).filter((n) => /\.tsx?$/.test(n) && n !== 'mix.test.ts')) {
    const src = readFileSync(new URL(f, dir), 'utf8');
    assert.ok(!/[嘅唔冇喺咗佢哋嚟啲]/.test(src), `Cantonese in ${f}`);
  }
  const forbidden = FORBIDDEN.filter((x) => x !== '，');
  const texts = [...TITLES.map((t) => t.text), ...END_CARD.map((c) => c.text), ...NARRATION.flatMap((n) => [n.caption, n.spoken])];
  for (const t of texts) for (const x of forbidden) assert.ok(!t.includes(x), `${JSON.stringify(t)} has ${x}`);
});
