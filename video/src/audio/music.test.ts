import { test } from 'node:test';
import assert from 'node:assert/strict';
import { FILM_FRAMES, FPS } from '../data/scenes/index.ts';
import { labelWindows, sceneStart } from './events.ts';
import { BAR_FRAMES, CHORD_FRAMES, CHORD_NAMES, DIP_DB, ENVELOPE_RATE, FADE_IN_SECONDS, FADE_OUT_SECONDS, FILM_SECONDS, groupAt, musicEnvelope, musicSchedule, type MusicNote } from './music.ts';

const notes = musicSchedule();
const pads = notes.filter((n) => n.kind === 'pad');
const plucks = notes.filter((n) => n.kind === 'pluck');

test('72 BPM in 4/4: a bar is 100 frames and a chord two bars, so chord changes fall on whole frames', () => {
  assert.equal(BAR_FRAMES, 100);
  assert.equal(CHORD_FRAMES, 200);
  assert.equal(FILM_SECONDS, FILM_FRAMES / FPS);
});

test('the schedule is plain data and two calls give equal output', () => {
  assert.deepEqual(musicSchedule(), notes);
  assert.deepEqual(JSON.parse(JSON.stringify(notes)), notes);
});

test('nothing is scheduled after the film ends, and every note starts at or after 0', () => {
  for (const n of notes) {
    assert.ok(n.start >= 0 && n.start < FILM_SECONDS, `start ${n.start}`);
    assert.ok(n.start + n.dur <= FILM_SECONDS + 1e-9, `${n.kind} ${n.start}+${n.dur} past the end`);
    assert.ok(n.dur > 0 && n.freq > 20 && n.freq < 2000 && n.gain > 0);
  }
});

test('the pad covers the whole film: every half second has a pad note that sounds', () => {
  for (let t = 0; t < FILM_SECONDS; t += 0.5) {
    assert.ok(pads.some((n) => n.start <= t && t < n.start + n.dur), `no pad at ${t} s`);
  }
  assert.equal(Math.min(...pads.map((n) => n.start)), 0);
  assert.ok(Math.max(...pads.map((n) => n.start + n.dur)) >= FILM_SECONDS - 1e-9);
});

test('chords go Dmaj9, Bm7, Gmaj7, A6 round, two bars each', () => {
  assert.deepEqual(CHORD_NAMES, ['Dmaj9', 'Bm7', 'Gmaj7', 'A6']);
  const starts = [...new Set(pads.map((n) => n.chord))].sort((a, b) => a - b);
  assert.deepEqual(starts.slice(0, 5), [0, 1, 2, 3, 4]);
  assert.equal(starts.length, Math.ceil(FILM_FRAMES / CHORD_FRAMES));
  const first = pads.filter((n) => n.chord === 0);
  assert.ok(first.every((n) => n.name === 'Dmaj9'));
  assert.ok(pads.filter((n) => n.chord === 5).every((n) => n.name === 'Bm7'));
});

test('pad voices are sine or triangle only; plucks are triangle or sine, from the D major pentatonic', () => {
  assert.ok(pads.every((n) => n.wave === 'sine' || n.wave === 'triangle'));
  const pent = [293.66, 329.63, 369.99, 440, 493.88, 587.33, 659.26, 739.99, 880, 987.77];
  assert.ok(plucks.length > 20);
  for (const n of plucks) assert.ok(pent.some((f) => Math.abs(f - n.freq) < 0.05), `pluck ${n.freq}`);
});

test('the three scene groups change the music: pluck density and voicing differ', () => {
  assert.equal(groupAt(0), 'A');
  assert.equal(groupAt(sceneStart(10)), 'B');
  assert.equal(groupAt(sceneStart(17)), 'C');
  const perChord = (g: string) => {
    const idx = new Set(pads.filter((n) => n.group === g).map((n) => n.chord));
    return plucks.filter((n) => idx.has(n.chord)).length / idx.size;
  };
  const [a, b, c] = ['A', 'B', 'C'].map(perChord);
  assert.ok(b > a * 1.3, `B ${b} should be denser than A ${a}`);
  assert.notEqual(c, a);
  const voices = (g: string) => pads.filter((n) => n.group === g && n.chord === (g === 'A' ? 0 : g === 'B' ? 20 : 40)).length;
  assert.ok(new Set([voices('A'), voices('B'), voices('C')]).size >= 2, 'voicings should differ');
});

test('plucks are seeded: the same film always puts them at the same places, and none fall in a label window', () => {
  const windows = labelWindows().map((w) => [w.from / FPS, w.to / FPS]);
  assert.equal(windows.length, 2);
  for (const n of plucks) assert.ok(!windows.some(([a, b]) => n.start >= a && n.start < b), `pluck at ${n.start} inside a label window`);
  const keys = (list: MusicNote[]) => list.map((n) => `${n.start.toFixed(3)}:${n.freq}`);
  assert.deepEqual(keys(musicSchedule().filter((n) => n.kind === 'pluck')), keys(plucks));
});

test('the envelope fades in over 2 s, out over the last 3 s, and dips about 4 dB while labels are up', () => {
  const env = musicEnvelope();
  assert.equal(env.length, Math.ceil(FILM_SECONDS * ENVELOPE_RATE) + 1);
  const at = (s: number) => env[Math.round(s * ENVELOPE_RATE)];
  assert.equal(at(0), 0);
  assert.ok(at(FADE_IN_SECONDS / 2) > 0 && at(FADE_IN_SECONDS / 2) < 1);
  assert.equal(at(FADE_IN_SECONDS), 1);
  assert.equal(at(FILM_SECONDS), 0);
  assert.ok(at(FILM_SECONDS - FADE_OUT_SECONDS / 2) > 0 && at(FILM_SECONDS - FADE_OUT_SECONDS / 2) < 1);
  assert.equal(at(FILM_SECONDS - FADE_OUT_SECONDS), 1);
  const dip = 10 ** (-DIP_DB / 20);
  for (const w of labelWindows()) {
    const mid = (w.from + w.to) / 2 / FPS;
    assert.ok(Math.abs(at(mid) - dip) < 0.01, `mid-window ${at(mid)} vs ${dip}`);
    assert.equal(at(w.from / FPS - 1.5), 1);
    assert.equal(at(w.to / FPS + 2), 1);
  }
  assert.equal(DIP_DB, 4);
  // smooth: no jump between neighbours bigger than a few percent
  let worst = 0;
  for (let i = 1; i < env.length; i++) worst = Math.max(worst, Math.abs(env[i] - env[i - 1]));
  assert.ok(worst < 0.06, `largest step ${worst}`);
});

test('label windows are those of scenes 11 (beats 1 to 3) and 16 (beats 4 and 5), in film frames', () => {
  const w = labelWindows();
  assert.equal(w.length, 2);
  assert.ok(w[0].from >= sceneStart(11) && w[0].to <= sceneStart(12));
  assert.ok(w[1].from >= sceneStart(16) && w[1].to <= sceneStart(17));
  assert.ok(w[0].from < w[0].to && w[0].to < w[1].from);
});
