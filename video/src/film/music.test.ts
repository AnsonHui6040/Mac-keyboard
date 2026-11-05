import { test } from 'node:test';
import assert from 'node:assert/strict';
import { FPS, FRAMES } from './timeline.ts';
import { DUCK_DB, DUCK_FRAMES, MUSIC, musicGain, musicSource, trimFrames } from './music.ts';
import { soundEvents } from './events.ts';

const sec = (s: number) => Math.round(s * FPS);
const db = (a: number, b: number) => 20 * Math.log10(a / b);

test('the music plays in three places: 7.0 to 12.2, 16.0 to 41.0 and 51.0 to 59.0, and is silent everywhere else', () => {
  assert.deepEqual(MUSIC.map((m) => [m.from, m.to]), [[sec(7), sec(12.2)], [sec(16), sec(41)], [sec(51), sec(59)]]);
  for (let f = 0; f < FRAMES; f++) {
    const inside = MUSIC.some((m) => f >= m.from && f < m.to);
    if (!inside) assert.equal(musicGain(f), 0, `frame ${f}`);
    else assert.ok(musicGain(f) > 0, `frame ${f}`);
  }
  for (const [a, b] of [[0, 7], [12.2, 16], [41, 51], [59, 60]]) for (let f = sec(a); f < sec(b); f++) assert.equal(musicGain(f), 0, `silent ${f}`);
});

test('each segment fades in and out over one frame, so a hard stop never clicks', () => {
  for (const m of MUSIC) {
    const mid = musicGain(m.from + 10);
    assert.ok(musicGain(m.from) < mid, `${m.id} start`);
    assert.ok(musicGain(m.to - 1) < musicGain(m.to - 2) + 1e-12 && musicGain(m.to - 1) < mid, `${m.id} end`);
    assert.equal(musicGain(m.to), 0);
    assert.equal(musicGain(m.from - 1), 0);
  }
});

test('the source time of the film second: Clean Geometry 0.058 at 7.0, 3.058 at 16.0 and 16.058 at 29.0; Soft Geometry 55.0 at 51.0', () => {
  const at = (t: number) => musicSource(Math.round(t * FPS));
  assert.equal(at(7.0).file, 'audio/Clean_Geometry.mp3');
  assert.ok(Math.abs(at(7.0).seconds - 0.058) < 1e-9);
  assert.ok(Math.abs(at(16.0).seconds - 3.058) < 1e-9);
  assert.ok(Math.abs(at(29.0).seconds - 16.058) < 1e-9, 'the lift of the source lands on 29.0 s');
  assert.ok(Math.abs(at(40.9).seconds - (40.9 - 12.942)) < 1e-9);
  assert.equal(at(51.0).file, 'audio/Soft_Geometry.mp3');
  assert.ok(Math.abs(at(51.0).seconds - 55.0) < 1e-9);
  assert.ok(Math.abs(at(58.9).seconds - 62.9) < 1e-9);
  assert.equal(musicSource(sec(20)).file, 'audio/Clean_Geometry.mp3');
});

test('the files are long enough for what is asked of them (Clean 46.99 s, Soft 63.37 s) and trimBefore is a whole frame within half a frame of the mapping', () => {
  const LEN: Record<string, number> = { 'audio/Clean_Geometry.mp3': 46.99, 'audio/Soft_Geometry.mp3': 63.37 };
  for (const m of MUSIC) {
    assert.ok(musicSource(m.from).seconds >= 0);
    assert.ok(musicSource(m.to - 1).seconds + 1 / FPS <= LEN[m.file]);
    assert.ok(Number.isInteger(m.trimBefore) && m.trimBefore >= 0);
    assert.ok(Math.abs(m.trimBefore / FPS - musicSource(m.from).seconds) <= 0.5 / FPS + 1e-9, `${m.id}: ${m.trimBefore}`);
    assert.equal(trimFrames(m.id), m.trimBefore);
  }
});

test('the writing stretch 18.1 to 21.7 is half as loud as the music around it', () => {
  const a = sec(18.1);
  const b = sec(21.7);
  assert.ok(Math.abs(db(musicGain(a + 10), musicGain(a - 10)) - -6.02) < 0.1, `${db(musicGain(a + 10), musicGain(a - 10))} dB`);
  assert.ok(Math.abs(musicGain(b - 10) / musicGain(b + 10) - 0.5) < 1e-9);
  assert.ok(Math.abs(musicGain(sec(20)) / musicGain(sec(25)) - 0.5) < 1e-9);
});

test('from 29 to 41 s every tap and click dips the music 2 to 3 dB and it is back after 6 frames; nowhere else is the music dipped', () => {
  assert.ok(DUCK_DB >= 2 && DUCK_DB <= 3);
  assert.equal(DUCK_FRAMES, 6);
  const taps = soundEvents().filter((e) => (e.kind === 'tap' || e.kind === 'click') && e.frame >= sec(29) && e.frame < sec(41));
  assert.ok(taps.length >= 7, `${taps.length}`);
  for (const e of taps) {
    const rest = musicGain(e.frame + DUCK_FRAMES + 1);
    assert.ok(Math.abs(db(musicGain(e.frame - 1), musicGain(e.frame + 40)) ) < 5);
    const dip = -db(musicGain(e.frame), musicGain(e.frame + 8) || rest);
    assert.ok(dip >= 2 && dip <= 3, `dip ${dip} at ${e.frame}`);
    assert.ok(musicGain(e.frame + 1) > musicGain(e.frame), 'recovering');
    assert.ok(Math.abs(musicGain(e.frame + DUCK_FRAMES) - musicGain(e.frame + DUCK_FRAMES + 8)) < 1e-9 || taps.some((o) => o.frame > e.frame && o.frame <= e.frame + DUCK_FRAMES + 8), `back at ${e.frame}`);
  }
  // 24 to 29 s: the same sounds play, the music is not dipped by them
  for (const e of soundEvents().filter((x) => x.frame >= sec(16) + 14 && x.frame < sec(29) && !(x.frame >= sec(18.1) && x.frame < sec(21.7)))) {
    assert.equal(musicGain(e.frame), musicGain(Math.max(e.frame - 12, sec(16) + 3)), `${e.kind} at ${e.frame}`);
  }
});
