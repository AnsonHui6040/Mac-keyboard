import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { FILM_FRAMES, SCENES as INSTALL_SCENES, sceneFrames } from '../data/scenes/index.ts';
import { FRAMES as INTRO_FRAMES } from '../intro/timeline.ts';
import { FRAMES, SHOTS, shotAt } from './timeline.ts';
import { CHAPTER_START, HW_CANDIDATES_AT, INK, LOGIN, MAC_DELAY, MAC_DELAY_EXCEPTION, PRESSES, SWIPES, chapterOf, isFilmContext, soundEvents, type SoundKind } from './events.ts';
import { macOps } from './state.ts';

test('every press is at a whole frame inside its chapter, sorted, and a chapter starts where the table says', () => {
  assert.deepEqual([...CHAPTER_START], [0, 1230, 1362, 1515]);
  for (let i = 0; i < PRESSES.length; i++) {
    const p = PRESSES[i];
    assert.ok(Number.isInteger(p.t) && p.t >= 0 && p.t + p.hold <= FRAMES, `${p.label} at ${p.t}`);
    assert.equal(p.chapter, chapterOf(p.t));
    if (i > 0) assert.ok(p.t > PRESSES[i - 1].t, `${p.label} at ${p.t} is not after the one before`);
  }
});

test('every Mac change comes exactly MAC_DELAY frames after the press that causes it, never before', () => {
  assert.equal(MAC_DELAY, 2);
  const ops = macOps();
  assert.equal(ops.length, 20 + 1 + 3 + 15, 'twenty letters, a new line, three sends, fifteen letters of the product name');
  const odd = ops.filter((op) => op.frame !== op.press.t + MAC_DELAY);
  assert.equal(odd.length, 1, 'exactly one press has its own delay');
  assert.deepEqual([odd[0].press.t, odd[0].press.key, odd[0].frame - odd[0].press.t], [MAC_DELAY_EXCEPTION.t, MAC_DELAY_EXCEPTION.key, MAC_DELAY_EXCEPTION.delay]);
  assert.equal(odd[0].press.t, 114, 'the h of shot 2 at 3.8 s');
  assert.equal(odd[0].frame, 119, 'the Mac is blank on 117 and 118, the first two frames of shot 3');
  assert.equal(PRESSES.filter((p) => p.macDelay !== undefined).length, 1);
  for (const op of ops) if (op !== odd[0]) assert.equal(op.frame, op.press.t + MAC_DELAY, `${op.press.label} at ${op.press.t}`);
});

test('the keys of the first words are where the storyboard puts them: shift then h at 3.8 s, e before the cut to the Mac', () => {
  const doc = PRESSES.filter((p) => p.chapter === 0);
  assert.equal(doc[0].key, 'shift');
  assert.equal(doc[1].t, 114, 'h at 3.8 s');
  assert.equal(doc[2].t, 144);
  assert.ok(doc[0].t < doc[1].t - 8, 'the ring clearly lands on shift before h');
  const ll = doc.filter((p) => p.t >= 162 && p.t < 186).map((p) => p.label);
  assert.deepEqual(ll, ['l', 'l', 'o', '空白', 'f', 'r', 'o', 'm'], 'shot 6 types l l o space f r o m');
});

test('each typed key has a sound at its own frame; letters make key, function keys tap', () => {
  const ev = soundEvents();
  for (const p of PRESSES) assert.ok(ev.some((e) => e.frame === p.t && e.kind === p.snd), `${p.label} at ${p.t}`);
  for (const p of PRESSES) {
    const letter = p.fx.k === 'char' || p.fx.k === 'code' || p.fx.k === 'blockedkey' || p.fx.k === 'remotekey';
    assert.equal(p.snd, letter ? 'key' : 'tap', `${p.label} at ${p.t}`);
  }
});

test('good sounds the frame the sentence lands, which is the first frame of the Mac shot; bad, click and success are where the plan says', () => {
  const ev = soundEvents();
  const good = ev.filter((e) => e.kind === 'good').map((e) => e.frame);
  assert.deepEqual(good, [480, 693, 807]);
  for (const g of good) assert.equal(shotAt(g).from, g, 'the cut and the landing are the same frame');
  const sends = PRESSES.filter((p) => p.fx.k === 'send' && p.chapter === 0);
  assert.deepEqual(sends.map((s) => s.t + MAC_DELAY), good);
  assert.deepEqual(ev.filter((e) => e.kind === 'bad').map((e) => e.frame), [LOGIN.blocked]);
  const last = PRESSES.filter((p) => p.chapter === 3).pop()!;
  assert.deepEqual(ev.filter((e) => e.kind === 'success').map((e) => e.frame), [last.t + MAC_DELAY]);
  assert.equal(last.t + MAC_DELAY, 1590, 'success at 53.0 s');
});

const ALLOWED: Record<string, SoundKind[]> = {
  '1': [], '2': ['tap', 'key'], '3': [], '4': ['key'], '5': [], '6': ['key'], '7': ['key', 'tap'], '8': ['tap'], '9': ['key', 'tap'], '10': [],
  '11': ['tap', 'key'], '12': ['tap'], '13': ['good'], '14': ['tap'], '15': ['ink'], '16': ['tap'], '17': ['good'], '18': ['key', 'tap'], '19': ['good'], '20': ['tap'],
  '21a': [], '21b': [], '21c': ['tap', 'click'], '21d': ['click'], '21e': ['tap', 'click'], '21f': [], '22': ['click'], '23': ['bad'],
  '24': ['key'], '25': [], '26': ['key'], '27': [], '28': ['key'], '29': [], '30': ['key', 'tap', 'success'], '31': [],
};
test('every sound falls in a shot whose sound column allows its kind; the silent shots are silent', () => {
  for (const e of soundEvents()) assert.ok(ALLOWED[shotAt(e.frame).id].includes(e.kind), `${e.kind} at ${e.frame} in shot ${shotAt(e.frame).id}`);
  for (const s of SHOTS) if (ALLOWED[s.id].length === 0) assert.equal(soundEvents().filter((e) => e.frame >= s.from && e.frame < s.to).length, 0, `shot ${s.id}`);
  const ev = soundEvents();
  for (let i = 1; i < ev.length; i++) assert.ok(ev[i].frame >= ev[i - 1].frame);
  for (const e of ev) assert.ok(Number.isInteger(e.frame) && e.frame >= 0 && e.frame < FRAMES);
});

test('the 21 sub-beats have the sounds the storyboard names: tap and click on the tap, click and click on the drag', () => {
  const kinds = (a: number, b: number) => soundEvents().filter((e) => e.frame >= a && e.frame < b).map((e) => e.kind);
  assert.deepEqual(kinds(936, 984), ['tap', 'click']);
  assert.deepEqual(kinds(984, 1062), ['click', 'click']);
  assert.ok(kinds(1062, 1131).includes('tap') && kinds(1062, 1131).includes('click'));
  assert.deepEqual(kinds(1131, 1230), []);
});

test('handwriting: the strokes are drawn inside shot 15, candidates wait for shot 16 and for the last stroke, ink taps are very light events', () => {
  const s15 = SHOTS.find((s) => s.id === '15')!;
  const s16 = SHOTS.find((s) => s.id === '16')!;
  assert.equal(INK.length, 18);
  assert.ok(INK[0].from >= s15.from + 4);
  for (let i = 1; i < INK.length; i++) assert.ok(INK[i].from >= INK[i - 1].to, `stroke ${i}`);
  const end = INK[INK.length - 1].to;
  assert.ok(end < s16.from, 'the last stroke ends before the cut to shot 16');
  assert.ok(HW_CANDIDATES_AT >= s16.from && HW_CANDIDATES_AT >= end + 8);
  const pick = PRESSES.find((p) => p.key === 'cand:0')!;
  assert.ok(pick.t >= HW_CANDIDATES_AT + 8, 'the candidates are on screen a while before the tap');
  assert.equal(soundEvents().filter((e) => e.kind === 'ink').length, 18);
});

test('quick: swipes follow the two roots and come before the second pick; the three flicks do not overlap', () => {
  assert.equal(SWIPES.length, 3);
  const u = PRESSES.find((p) => p.key === 'u')!;
  const pick = PRESSES.find((p) => p.key === 'qcand:15')!;
  assert.ok(SWIPES[0].from > u.t);
  for (let i = 1; i < SWIPES.length; i++) assert.ok(SWIPES[i].from > SWIPES[i - 1].to);
  assert.ok(pick.t > SWIPES[2].to + 2);
});

test('the sound registration plays only into a context exactly 60 s long; no other composition of the project is 1800 frames', () => {
  assert.ok(isFilmContext(1800 * 48000 / 30, 48000));
  assert.ok(isFilmContext(1800 * 48000 / 30 + 1, 48000));
  assert.ok(!isFilmContext(INTRO_FRAMES * 48000 / 30, 48000));
  assert.ok(!isFilmContext(FILM_FRAMES * 48000 / 30, 48000));
  for (const s of INSTALL_SCENES) assert.notEqual(sceneFrames(s.n), FRAMES, `Scene${s.n}`);
  assert.notEqual(INTRO_FRAMES, FRAMES);
  assert.notEqual(FILM_FRAMES, FRAMES);
});

test('quick-table.txt, which the candidate test in state.test.ts reads, exists and is longer than 1000 characters', () => {
  assert.ok(readFileSync(new URL('../../../iOS/RemoteKeyboardExtension/Resources/quick-table.txt', import.meta.url), 'utf8').length > 1000);
});
