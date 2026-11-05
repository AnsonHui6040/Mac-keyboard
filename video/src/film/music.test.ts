import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import { FPS, FRAMES } from './timeline.ts';
import { DUCK_DB, DUCK_FRAMES, MUSIC, musicGain, musicSource, trimFrames } from './music.ts';
import { soundEvents } from './events.ts';

const sec = (s: number) => Math.round(s * FPS);
const db = (a: number, b: number) => 20 * Math.log10(a / b);
const near = (a: number, b: number, d: number, msg: string) => assert.ok(Math.abs(a - b) <= d, `${msg}: ${a} vs ${b}`);

const FILE_SECONDS = 46.994;

test('the music is one take of Clean Geometry from frame 0 to the end of the file, and silent after it', () => {
  assert.equal(MUSIC.length, 1);
  assert.equal(MUSIC[0].file, 'audio/Clean_Geometry.mp3');
  assert.equal(MUSIC[0].from, 0);
  assert.equal(MUSIC[0].to, Math.floor((FILE_SECONDS - 0.058) * FPS), 'it runs until the file does');
  assert.ok(MUSIC[0].to < FRAMES);
  for (let f = 0; f < MUSIC[0].to; f++) assert.ok(musicGain(f) > 0, `frame ${f}`);
  for (let f = MUSIC[0].to; f < FRAMES; f++) assert.equal(musicGain(f), 0, `silent ${f}`);
});

test('there is no splice: every frame plays the next 1/30 s of the file, so nothing cuts, replays or restarts', () => {
  for (let f = 1; f < MUSIC[0].to; f++) {
    near(musicSource(f).seconds - musicSource(f - 1).seconds, 1 / FPS, 1e-9, `frame ${f}`);
    assert.equal(musicSource(f).file, musicSource(0).file);
  }
  for (let f = 1; f < MUSIC[0].to - 1; f++) assert.ok(musicGain(f) > 0.2 * musicGain(f - 1) && musicGain(f) < 5 * musicGain(f - 1), `a gain jump at ${f}`);
});

test('nothing in the film or its script or storyboard names the second music file', () => {
  const dir = new URL('./', import.meta.url);
  const files = [...readdirSync(dir)].filter((f) => !f.endsWith('.test.ts')).map((f) => new URL(f, dir));
  files.push(new URL('../../scripts/render-film.sh', import.meta.url), new URL('../../../docs/video/product-film-storyboard.md', import.meta.url));
  for (const u of files) assert.ok(!/soft[_ ]geometry/i.test(readFileSync(u, 'utf8')), u.pathname);
  assert.ok(!MUSIC.some((m) => /soft/i.test(m.file)));
});

test('the music is there from the first frame, and is audible well inside the first second', () => {
  assert.ok(musicGain(0) > 0);
  assert.ok(musicGain(1) > 0.5 * musicGain(30));
  for (let f = 0; f < 30; f++) assert.ok(musicGain(f) > 0, `frame ${f}`);
  assert.equal(musicSource(0).file, 'audio/Clean_Geometry.mp3');
  assert.ok(Math.abs(musicSource(0).seconds - 0.058) < 1e-9, 'the file plays from its first 0.1 s');
});

test('the music comes in with a half-gain first frame, and is off after the end of the file', () => {
  for (const m of MUSIC) {
    assert.ok(musicGain(m.from) < musicGain(m.from + 10), `${m.id} start`);
    assert.ok(musicGain(m.to - 1) > 0, `${m.id} last frame`);
    assert.equal(musicGain(m.to), 0);
    assert.equal(musicGain(m.from - 1), 0);
  }
});

test('no two adjacent frames differ by more than 1.5 dB, except at the tap and click duck onsets from 29 to 41 s and at frame 0', () => {
  const onsets = new Set(soundEvents().filter((e) => (e.kind === 'tap' || e.kind === 'click') && e.frame >= sec(29) && e.frame < sec(41)).map((e) => e.frame));
  let worst = 0;
  for (let f = 1; f < MUSIC[0].to; f++) {
    if (f === 1 || onsets.has(f)) continue; // frame 0 starts at half gain
    const step = Math.abs(db(musicGain(f), musicGain(f - 1)));
    worst = Math.max(worst, step);
    assert.ok(step <= 1.5, `${step.toFixed(2)} dB between frames ${f - 1} and ${f}`);
  }
  assert.ok(worst > 0.1, 'the ramps are really there');
});

test('the handwriting dip ramps over 12 frames: down from 18.1 s, back up ending at 21.7 s', () => {
  const a = sec(18.1);
  const b = sec(21.7);
  const top = musicGain(a - 1);
  assert.equal(musicGain(a), top);
  assert.ok(musicGain(a + 6) < top && musicGain(a + 6) > 0.5 * top, 'half way down');
  near(musicGain(a + 12), 0.5 * top, 1e-12, 'the bottom is reached 12 frames in');
  near(musicGain(b - 13), 0.5 * top, 1e-12, 'the bottom holds until 12 frames before the end');
  assert.ok(musicGain(b - 6) > 0.5 * top && musicGain(b - 6) < top);
  near(musicGain(b), top, 1e-12, 'back at the full level at 21.7 s');
});

test('the source time of the film second is film + 0.058 all through: 16.058 at 16.0 s, 29.058 at 29.0 s, 44.058 at 44.0 s', () => {
  const at = (t: number) => musicSource(Math.round(t * FPS));
  for (const t of [0, 3, 12.1, 14, 16, 20, 29, 40.9, 44]) near(at(t).seconds, t + 0.058, 1e-9, `film ${t}`);
  near(at(16.0).seconds, 16.058, 1e-9, 'the source lifts at 16.058 s, which is the moment the whole sentence lands on the Mac');
});

test('the file is long enough for the segment, and trimBefore is a whole frame within half a frame of the mapping', () => {
  for (const m of MUSIC) {
    assert.ok(musicSource(m.from).seconds >= 0);
    assert.ok(musicSource(m.to - 1).seconds + 1 / FPS <= FILE_SECONDS + 1e-9);
    assert.ok(Number.isInteger(m.trimBefore) && m.trimBefore >= 0);
    assert.ok(Math.abs(m.trimBefore / FPS - musicSource(m.from).seconds) <= 0.5 / FPS + 1e-9, `${m.id}: ${m.trimBefore}`);
    assert.equal(trimFrames(m.id), m.trimBefore);
  }
});

test('the gain follows the source lift: it steps down over the 12 frames before 16.0 s, while the source is still quiet, and is steady after', () => {
  const lift = sec(16);
  const before = musicGain(lift - 20);
  const after = musicGain(lift + 10);
  assert.ok(after < before, 'the louder arrangement gets a lower gain');
  assert.ok(db(before, after) >= 3 && db(before, after) <= 9, `${db(before, after)} dB`);
  for (let f = lift - 12; f < lift; f++) assert.ok(musicGain(f) <= musicGain(f - 1) + 1e-12, `still stepping down at ${f}`);
  for (let f = lift; f < sec(18.1) - 1; f++) assert.equal(musicGain(f), after, `steady at ${f}`);
});

test('the writing stretch 18.1 to 21.7 is half as loud as the music around it', () => {
  const a = sec(18.1);
  const b = sec(21.7);
  assert.ok(Math.abs(db(musicGain(a + 14), musicGain(a - 10)) - -6.02) < 0.1, `${db(musicGain(a + 14), musicGain(a - 10))} dB`);
  assert.ok(Math.abs(musicGain(b - 14) / musicGain(b + 10) - 0.5) < 1e-9);
  assert.ok(Math.abs(musicGain(sec(20)) / musicGain(sec(25)) - 0.5) < 1e-9);
});

test('from 29 to 41 s every tap and click dips the music 2 to 3 dB and it is back after 6 frames; nowhere else is the music dipped', () => {
  assert.ok(DUCK_DB >= 2 && DUCK_DB <= 3);
  assert.equal(DUCK_FRAMES, 6);
  const taps = soundEvents().filter((e) => (e.kind === 'tap' || e.kind === 'click') && e.frame >= sec(29) && e.frame < sec(41));
  assert.ok(taps.length >= 7, `${taps.length}`);
  // A tap with no other tap inside its window (from DUCK_FRAMES before to DUCK_FRAMES + 8 after) shows the whole dip and the return.
  const alone = taps.filter((e) => taps.every((o) => o === e || o.frame < e.frame - DUCK_FRAMES - 1 || o.frame > e.frame + DUCK_FRAMES + 8));
  assert.ok(alone.length >= 3, `${alone.length} lone taps`);
  for (const e of taps) assert.ok(musicGain(e.frame + 1) > musicGain(e.frame), `recovering at ${e.frame}`);
  for (const e of alone) {
    const back = musicGain(e.frame + DUCK_FRAMES);
    const dip = -db(musicGain(e.frame), back);
    assert.ok(dip >= 2 - 1e-9 && dip <= 3 + 1e-9, `dip ${dip} at ${e.frame}`);
    assert.ok(musicGain(e.frame + DUCK_FRAMES - 1) < back, `not yet back after ${DUCK_FRAMES - 1} frames at ${e.frame}`);
    assert.ok(Math.abs(back - musicGain(e.frame + DUCK_FRAMES + 8)) < 1e-9, `back after ${DUCK_FRAMES} frames at ${e.frame}`);
    assert.ok(Math.abs(db(musicGain(e.frame - 1), back)) < 1e-9, `the level before the tap is the level after it at ${e.frame}`);
  }
  // 24 to 29 s: the same sounds play, the music is not dipped by them
  for (const e of soundEvents().filter((x) => x.frame >= sec(16) + 14 && x.frame < sec(29) && !(x.frame >= sec(18.1) && x.frame < sec(21.7)))) {
    assert.equal(musicGain(e.frame), musicGain(Math.max(e.frame - 12, sec(16) + 3)), `${e.kind} at ${e.frame}`);
  }
});
