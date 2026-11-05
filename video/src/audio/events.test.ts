import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { FILM_FRAMES, FPS, SCENES, compileRegistered, sceneFrames } from '../data/scenes/index.ts';
import { IPA_NAME, ZIP_NAME } from '../data/artifacts.ts';
import { PRESS_FRAMES, pointerAt } from '../lib/pointer.ts';
import { commandText } from '../screens/terminal.ts';
import { CONNECT_AT, TYPED_20, TYPE20_PITCH, TYPE20_START } from '../screens/typing20.ts';
import { TYPED_01, TYPE01_PITCH, TYPE01_START, SUCCESS_GAP_FRAMES, soundEvents, sceneStart, successFrames, type SoundEvent } from './events.ts';

const events = soundEvents();
const inScene = (n: number): SoundEvent[] => {
  const from = sceneStart(n);
  return events.filter((e) => e.frame >= from && e.frame < from + sceneFrames(n));
};
const spec = (n: number) => SCENES.find((s) => s.n === n)!;

test('film frame of a scene is the sum of the earlier scenes, and the last scene ends at the film end', () => {
  assert.equal(sceneStart(1), 0);
  assert.equal(sceneStart(2), sceneFrames(1));
  assert.equal(sceneStart(16), 7050);
  assert.equal(sceneStart(21) + sceneFrames(21), FILM_FRAMES);
});

test('events are whole film frames inside the film, sorted, and two calls give equal output', () => {
  assert.ok(events.length > 0);
  for (const e of events) {
    assert.ok(Number.isInteger(e.frame) && e.frame >= 0 && e.frame < FILM_FRAMES, `${e.kind} at ${e.frame}`);
  }
  for (let i = 1; i < events.length; i++) assert.ok(events[i].frame >= events[i - 1].frame, `unsorted at ${i}`);
  assert.deepEqual(soundEvents(), events);
});

test('every press step yields exactly one click (Mac) or tap (iPhone) at the frame its press starts, offset into the film', () => {
  let presses = 0;
  for (const s of SCENES) {
    const c = compileRegistered(s);
    const expected: SoundEvent[] = [];
    s.beats.forEach((b, i) => {
      (b.steps ?? []).forEach((step, k) => {
        if (!step.press) return;
        const device = step.device ?? b.device;
        expected.push({ frame: sceneStart(s.n) + c.timeline[i].from + c.stepTimes[i][k].land - PRESS_FRAMES / 2, kind: device === 'iphone' ? 'tap' : 'click' });
      });
    });
    presses += expected.length;
    const got = inScene(s.n).filter((e) => e.kind === 'click' || e.kind === 'tap');
    assert.deepEqual(got, expected, `scene ${s.n}`);
  }
  assert.ok(presses > 30, `only ${presses} press steps found`);
  assert.equal(events.filter((e) => e.kind === 'click' || e.kind === 'tap').length, presses);
});

test('scene 16 has its two presses at local frames 261 and 401 (pulses 261-269 and 401-409), clicks on the Mac', () => {
  const c = compileRegistered(spec(16));
  const pulse = (from: number) => [from - 1, from, from + 1, from + PRESS_FRAMES, from + PRESS_FRAMES + 1].map((f) => Math.round(pointerAt(f, c.runs.find((r) => f >= r.cues[0].from && f < r.to)!.cues, FPS).press * 100) / 100);
  assert.deepEqual(pulse(261), [0, 0, 0.25, 0, 0]);
  assert.deepEqual(pulse(401), [0, 0, 0.25, 0, 0]);
  const off = sceneStart(16);
  assert.deepEqual(inScene(16).filter((e) => e.kind === 'click' || e.kind === 'tap'), [{ frame: off + 261, kind: 'click' }, { frame: off + 401, kind: 'click' }]);
});

test('scene 10 has a click for the Mac press and a tap for the iPhone press in the same beat', () => {
  const kinds = inScene(10).filter((e) => e.kind === 'click' || e.kind === 'tap').map((e) => e.kind);
  assert.deepEqual(kinds, ['click', 'click', 'tap']);
});

test('scenes 11 and 16 each have exactly one good then one bad, at the start of the beat that first shows each label', () => {
  for (const n of [11, 16]) {
    const c = compileRegistered(spec(n));
    const labels = inScene(n).filter((e) => e.kind === 'good' || e.kind === 'bad');
    assert.deepEqual(labels.map((e) => e.kind), ['good', 'bad'], `scene ${n}`);
    const beatOf = (kind: 'good' | 'bad') => spec(n).beats.findIndex((b) => b.labels?.some((l) => l.kind === kind));
    assert.equal(labels[0].frame, sceneStart(n) + c.timeline[beatOf('good')].from);
    assert.equal(labels[1].frame, sceneStart(n) + c.timeline[beatOf('bad')].from);
    assert.ok(labels[0].frame < labels[1].frame);
  }
  assert.deepEqual(events.filter((e) => e.kind === 'good' || e.kind === 'bad').length, 4);
});

test('scene 11 shows 按這個 at beat 1 and 不要按 at beat 3; scene 16 at beats 4 and 5', () => {
  const idx = (n: number, kind: 'good' | 'bad') => spec(n).beats.findIndex((b) => b.labels?.some((l) => l.kind === kind));
  assert.deepEqual([idx(11, 'good'), idx(11, 'bad'), idx(16, 'good'), idx(16, 'bad')], [1, 3, 4, 5]);
});

test('keys: one per typed character in scenes 1 and 20 and in the terminal typing of scenes 10 and 15, none elsewhere', () => {
  const count = (n: number) => inScene(n).filter((e) => e.kind === 'key').length;
  assert.equal(count(1), 'Hello Mac, this is typed on my iPhone'.length);
  assert.equal(count(1), TYPED_01.length);
  assert.equal(count(20), TYPED_20.length);
  assert.equal(count(10), commandText(IPA_NAME).length);
  assert.equal(count(15), commandText(ZIP_NAME).length);
  const others = events.filter((e) => e.kind === 'key').length - count(1) - count(20) - count(10) - count(15);
  assert.equal(others, 0);
});

test('keys of scene 1 start at the first letter frame and follow the letter pitch; scene 20 keys sit in its last beat', () => {
  const k1 = inScene(1).filter((e) => e.kind === 'key').map((e) => e.frame);
  assert.equal(k1[0], TYPE01_START);
  assert.equal(k1[1] - k1[0], TYPE01_PITCH);
  const c20 = compileRegistered(spec(20));
  const k20 = inScene(20).filter((e) => e.kind === 'key').map((e) => e.frame - sceneStart(20));
  assert.equal(k20[0], c20.timeline[3].from + TYPE20_START);
  assert.equal(k20[k20.length - 1], c20.timeline[3].from + TYPE20_START + TYPE20_PITCH * (TYPED_20.length - 1));
  assert.ok(k20[k20.length - 1] < c20.timeline[3].to, 'the last letter appears before the scene ends');
});

test('terminal keys of scenes 10 and 15 fall while the terminal page is on screen', () => {
  const c10 = compileRegistered(spec(10));
  const k10 = inScene(10).filter((e) => e.kind === 'key').map((e) => e.frame - sceneStart(10));
  assert.ok(k10.every((f) => f >= c10.timeline[1].from && f < c10.timeline[1].to));
  const c15 = compileRegistered(spec(15));
  const k15 = inScene(15).filter((e) => e.kind === 'key').map((e) => e.frame - sceneStart(15));
  const open = c15.timeline[1].from + c15.stepTimes[1][1].start;
  const close = c15.timeline[1].from + c15.stepTimes[1][2].start;
  assert.ok(k15.every((f) => f > open && f < close), `${k15[0]}..${k15[k15.length - 1]} vs ${open}..${close}`);
});

test('success: scene 20 has one when 已連接 appears and one when the sentence completes, since they are more than 3 s apart', () => {
  const c = compileRegistered(spec(20));
  const base = sceneStart(20) + c.timeline[3].from;
  const done = base + TYPE20_START + TYPE20_PITCH * (TYPED_20.length - 1);
  assert.deepEqual(events.filter((e) => e.kind === 'success'), [{ frame: base + CONNECT_AT, kind: 'success' }, { frame: done, kind: 'success' }]);
  assert.ok(done - (base + CONNECT_AT) > 3 * FPS);
});

test('the second success is dropped when it is within 3 seconds of the first', () => {
  assert.equal(SUCCESS_GAP_FRAMES, 3 * FPS);
  assert.deepEqual(successFrames(100, 100 + 89), [100]);
  assert.deepEqual(successFrames(100, 100 + 90), [100]);
  assert.deepEqual(successFrames(100, 100 + 91), [100, 191]);
});

test('events list has the six kinds and nothing else', () => {
  assert.deepEqual([...new Set(events.map((e) => e.kind))].sort(), ['bad', 'click', 'good', 'key', 'success', 'tap']);
});

test('the typing constants copied for scene 1 equal the ones in Typing.tsx (that file cannot be imported by node)', () => {
  const src = readFileSync(new URL('../screens/Typing.tsx', import.meta.url), 'utf8');
  assert.equal(Number(/export const TYPE_START = (\d+);/.exec(src)?.[1]), TYPE01_START);
  assert.equal(Number(/export const TYPE_PITCH = (\d+);/.exec(src)?.[1]), TYPE01_PITCH);
  assert.equal(/export const TYPED = '([^']+)';/.exec(src)?.[1], TYPED_01);
  assert.match(src, /Math\.floor\(\(localFrame - TYPE_START\) \/ TYPE_PITCH\) \+ 1/);
});
