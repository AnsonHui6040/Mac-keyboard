import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { SCREENS, restPoint, type Rect } from '../screens/geometry.ts';
import { SCENES, FPS, compileRegistered, sceneEntry } from '../data/scenes/index.ts';
import { scene16 } from '../data/scenes/scene16.ts';
import { ENTRY_OFFSET, compileScene, labelRunStart, type BeatSpec } from './sceneSpec.ts';
import { pointerAt } from './pointer.ts';

const A = '第一句。';
const B = '第二句。';
const C = '第三句。';
const done = SCREENS.dialogBlocked.done;
const trash = SCREENS.dialogBlocked.trash;
const inside = (p: { x: number; y: number }, r: Rect) => p.x >= r.x && p.x <= r.x + r.width && p.y >= r.y && p.y <= r.y + r.height;
const blocked = (b: Partial<BeatSpec> = {}): BeatSpec => ({ screen: 'dialogBlocked', device: 'mac', ...b });

test('beat count must equal the subtitle beats, and the error names the scene', () => {
  assert.throws(() => compileScene({ n: 99, beats: [] }, '一句話。', 5, 30), /99/);
  assert.throws(() => compileScene({ n: 98, beats: [blocked(), blocked()] }, A, 10, 30), /98/);
});

test('every step and label target must exist on the beat screen', () => {
  assert.throws(() => compileScene({ n: 97, beats: [blocked({ steps: [{ target: 'password' }] })] }, A, 5, 30), /97.*password.*dialogBlocked/);
  assert.throws(() => compileScene({ n: 96, beats: [blocked({ labels: [{ target: 'nope', kind: 'good' }] })] }, A, 5, 30), /96.*nope/);
  assert.throws(() => compileScene({ n: 95, beats: [{ screen: 'noScreen' }] }, A, 5, 30), /95.*noScreen/);
});

test('a beat needs 41 frames per press step and 33 per step without a press; what does not fit throws', () => {
  const three = (press: boolean): BeatSpec => blocked({ steps: [{ target: 'done', press }, { target: 'trash', press }, { target: 'done', press }] });
  // 3 press steps need 123 frames: 4 s (120 frames) is too short, 5 s is enough.
  assert.throws(() => compileScene({ n: 94, beats: [three(true)] }, A, 4, 30), /94/);
  const ok = compileScene({ n: 94, beats: [three(true)] }, A, 5, 30);
  assert.ok(ok.timeline[0].to - ok.timeline[0].from >= 123);
  // 3 steps without a press need 99 frames: 3 s (90 frames) is too short, 3.4 s is enough.
  assert.throws(() => compileScene({ n: 93, beats: [three(false)] }, A, 3, 30), /93/);
  compileScene({ n: 93, beats: [three(false)] }, A, 3.4, 30);
  // The step minimum pushes the beat longer than its reading time when it must.
  const crowded = compileScene({ n: 92, beats: [blocked(), three(true)] }, A + B, 8, 30);
  assert.ok(crowded.timeline[1].to - crowded.timeline[1].from >= 123);
});

test('a mixed beat gives every step a slot at least as long as the slowest step, so no press is dropped', () => {
  const beat = blocked({ steps: [{ target: 'done' }, { target: 'trash', press: true }] });
  const c = compileScene({ n: 91, beats: [beat] }, A, 5, 30);
  const [t] = c.timeline;
  assert.ok(t.to - t.from >= 82);
  let peak = 0;
  for (let f = t.from; f < t.to; f++) peak = Math.max(peak, pointerAt(f, c.cues, 30).press);
  assert.equal(peak, 1);
});

test('the first pointer enters ENTRY_OFFSET below its target; later steps start from the current position; rests use restPoint', () => {
  const c = compileScene({ n: 90, beats: [blocked({ steps: [{ target: 'done' }, { target: 'trash', press: true }] })] }, A, 5, 30);
  const d = restPoint(done);
  const t = restPoint(trash);
  const from = c.timeline[0].from;
  const slot = Math.floor((c.timeline[0].to - from) / 2);
  assert.deepEqual(c.cues, [
    { from, x: d.x, y: d.y + ENTRY_OFFSET, press: false },
    { from: from + 1, x: d.x, y: d.y, press: false },
    { from: from + slot, x: t.x, y: t.y, press: true },
  ]);
  assert.equal(pointerAt(from - 1, c.cues, 30).visible, false);
});

test('steps of one beat run in order, spread evenly from the beat start, and every press ends inside the beat', () => {
  const steps = [{ target: 'done', press: true }, { target: 'trash', press: true }, { target: 'done', press: true }];
  const c = compileScene({ n: 89, beats: [blocked({ steps })] }, A, 6, 30);
  const { from, to } = c.timeline[0];
  const slot = Math.floor((to - from) / 3);
  assert.deepEqual(c.cues.map((q) => q.from), [from, from + 1, from + slot, from + 2 * slot]);
  for (let k = 0; k < 3; k++) {
    let peak = 0;
    for (let f = from + k * slot; f < from + (k + 1) * slot; f++) peak = Math.max(peak, pointerAt(f, c.cues, 30).press);
    assert.equal(peak, 1, `step ${k}`);
  }
  assert.ok(from + 2 * slot + 41 <= to);
});

test('a beat without steps leaves the pointer where it is; a step on the same spot without a press adds no cue', () => {
  const c = compileScene({ n: 88, beats: [blocked({ steps: [{ target: 'done', press: true }] }), blocked(), blocked({ steps: [{ target: 'done' }] })] }, A + B + C, 12, 30);
  assert.equal(c.cues.length, 2);
  const p = restPoint(done);
  const s = pointerAt(c.timeline[2].to - 1, c.cues, 30);
  assert.ok(s.visible && Math.abs(s.x - p.x) < 1e-9 && Math.abs(s.y - p.y) < 1e-9);
});

test('the pointer hides when the device changes or a beat has no device', () => {
  const c = compileScene(
    {
      n: 87,
      beats: [
        blocked({ steps: [{ target: 'done' }] }),
        { screen: 'dialogBlocked', device: 'iphone', steps: [{ target: 'trash' }] },
        { screen: 'dialogBlocked' },
        blocked({ steps: [{ target: 'trash' }] }),
      ],
    },
    A + B + C + A,
    16,
    30,
  );
  assert.deepEqual(c.runs.map((r) => r.device), ['mac', 'iphone', 'mac']);
  assert.deepEqual(c.runs.map((r) => [r.from, r.to]), [[c.timeline[0].from, c.timeline[0].to], [c.timeline[1].from, c.timeline[1].to], [c.timeline[3].from, c.timeline[3].to]]);
  // each run opens with its own entry cue below its target
  for (const r of c.runs) assert.ok(r.cues[0].y > r.cues[1].y);
});

test('deviceAt returns the beat device, undefined when the scene has none', () => {
  const c = compileScene({ n: 86, beats: [blocked(), { screen: 'dialogBlocked', device: 'iphone' }] }, A + B, 6, 30);
  assert.equal(c.deviceAt(c.timeline[0].from), 'mac');
  assert.equal(c.deviceAt(c.timeline[1].from), 'iphone');
  const none = compileScene({ n: 85, beats: [{ screen: 'dialogBlocked' }] }, A, 4, 30);
  assert.equal(none.deviceAt(0), undefined);
});

test('labelRunStart finds the first beat of a run of the same label', () => {
  const lab = { target: 'open', kind: 'good' as const };
  const spec = { n: 84, beats: [{ screen: 'dialogConfirm' }, { screen: 'dialogConfirm', labels: [lab] }, { screen: 'dialogConfirm', labels: [lab] }, { screen: 'dialogConfirm' }] };
  assert.equal(labelRunStart(spec, 2, lab), 1);
  assert.equal(labelRunStart(spec, 1, lab), 1);
});

test('scene 16 compiles to the same timeline and cues as V1; presses land on frames 261-269 and 401-409', () => {
  const c = compileRegistered(scene16);
  assert.deepEqual(c.timeline, [
    { from: 0, to: 150 }, { from: 150, to: 227 }, { from: 227, to: 368 }, { from: 368, to: 448 },
    { from: 448, to: 571 }, { from: 571, to: 694 }, { from: 694, to: 780 },
  ]);
  assert.deepEqual(c.cues, [
    { from: 227, x: 726.52, y: 757.6, press: false },
    { from: 228, x: 726.52, y: 637.6, press: true },
    { from: 368, x: 1360, y: 474.2, press: true },
    { from: 448, x: 952.48, y: 671.6, press: false },
    { from: 694, x: 952.48, y: 578.6, press: false },
  ]);
  const pressing = (lo: number, hi: number) => {
    const fs: number[] = [];
    for (let f = lo; f < hi; f++) if (pointerAt(f, c.cues, FPS).press > 0) fs.push(f);
    return fs;
  };
  // the pulse window is frames 261..269; it is 0 on both ends and peaks at 265 (401..409, peak 405)
  assert.deepEqual(pressing(228, 368), [262, 263, 264, 265, 266, 267, 268]);
  assert.equal(pointerAt(265, c.cues, FPS).press, 1);
  assert.equal(pointerAt(405, c.cues, FPS).press, 1);
  assert.equal(pointerAt(261, c.cues, FPS).press, 0);
  assert.equal(pointerAt(269, c.cues, FPS).press, 0);
  assert.deepEqual(pressing(368, 448), [402, 403, 404, 405, 406, 407, 408]);
  assert.equal(c.runs.length, 1);
  assert.equal(c.deviceAt(0), 'mac');
});

test('five frames before each beat ends scene 16 has its pointer on that beat last target, never on the trash button in beat 5', () => {
  const c = compileRegistered(scene16);
  scene16.beats.forEach((b, i) => {
    if (!b.steps) return;
    const target = SCREENS[b.screen][b.steps[b.steps.length - 1].target];
    const s = pointerAt(c.timeline[i].to - 5, c.cues, FPS);
    assert.ok(s.visible && inside(s, target), `beat ${i}`);
  });
  assert.ok(!inside(pointerAt(c.timeline[5].to - 5, c.cues, FPS), SCREENS.dialogConfirm.trash));
});

test('registered scenes: numbers are unique, each is in the script, each compiles', () => {
  const ns = SCENES.map((s) => s.n);
  assert.equal(new Set(ns).size, ns.length);
  for (const spec of SCENES) {
    assert.ok(sceneEntry(spec.n));
    const c = compileRegistered(spec);
    assert.equal(c.timeline.length, spec.beats.length);
    assert.equal(c.timeline[c.timeline.length - 1].to, sceneEntry(spec.n).seconds * FPS);
  }
});

test('a beat with steps but no device throws, naming the scene', () => {
  assert.throws(() => compileScene({ n: 83, beats: [{ screen: 'dialogBlocked', steps: [{ target: 'done' }] }] }, A, 5, 30), /83.*no device/);
  // an empty steps list and a beat without steps are fine without a device
  compileScene({ n: 83, beats: [{ screen: 'dialogBlocked', steps: [] }] }, A, 5, 30);
});

test('every screen in SCREENS has a view in registry.tsx and the other way round (static check: node cannot import .tsx)', () => {
  const src = readFileSync(new URL('../screens/registry.tsx', import.meta.url), 'utf8');
  const body = src.slice(src.indexOf('export const SCREEN_VIEWS'));
  const keys = [...body.matchAll(/^ {2}(\w+):/gm)].map((m) => m[1]);
  assert.deepEqual([...keys].sort(), Object.keys(SCREENS).sort());
  // compileScene already throws for a screen that is not in SCREENS, and so for one with no view
  assert.throws(() => compileScene({ n: 82, beats: [{ screen: 'noView' }] }, A, 5, 30), /82.*noView/);
});

test('the first press step of a run needs 42 frames (the entry cue takes the first frame); later steps and runs need 41', () => {
  const two = (n: number, device: 'mac' | 'iphone' = 'mac'): BeatSpec => ({ screen: 'dialogBlocked', device, steps: [{ target: 'done', press: true }, { target: 'trash', press: true }] });
  // first beat of a run: 2 x 42 = 84 frames; 82 frames (2.7333 s) throws, 84 is enough
  assert.throws(() => compileScene({ n: 81, beats: [two(0)] }, A, 82 / 30, 30), /81/);
  const c = compileScene({ n: 81, beats: [two(0)] }, A, 84 / 30, 30);
  const { from, to } = c.timeline[0];
  assert.equal(to - from, 84);
  // the press of step 0 peaks inside its slot and is nearly done on the slot's last frame (the pulse ends at 0 on the next step's first frame)
  let peak = 0;
  for (let f = from; f < from + 42; f++) peak = Math.max(peak, pointerAt(f, c.cues, 30).press);
  assert.equal(peak, 1);
  assert.ok(pointerAt(from + 41, c.cues, 30).press <= 0.25);
  assert.equal(pointerAt(from + 42, c.cues, 30).press, 0);
  // a later beat of the same run needs only 2 x 41 = 82: 75 (first beat reading time) + 82 = 157 frames fit, 156 do not
  const later = [blocked({ steps: [{ target: 'done' }] }), two(1)];
  compileScene({ n: 80, beats: later }, A + B, 157 / 30, 30);
  assert.throws(() => compileScene({ n: 80, beats: later }, A + B, 156 / 30, 30), /80/);
  // a beat on a new run (device change) pays the extra frame again
  const switched = compileScene({ n: 79, beats: [blocked({ steps: [{ target: 'done' }] }), two(0, 'iphone')] }, A + B, 6, 30);
  assert.ok(switched.timeline[1].to - switched.timeline[1].from >= 84);
});

test('stepTimes: per step, when the pointer starts and lands (arrival, or the press peak), relative to the beat', () => {
  const c = compileScene({ n: 80, beats: [blocked({ steps: [{ target: 'done' }, { target: 'trash', press: true }] })] }, A, 5, 30);
  const [t] = c.timeline;
  const slot = Math.floor((t.to - t.from) / 2);
  // the first step of a run starts one frame late (the entry cue takes the first frame); a plain step lands after travel 18 + hold 15
  assert.deepEqual(c.stepTimes[0], [{ start: 1, land: 34 }, { start: slot, land: slot + 37 }]);
  // the press peak is the frame where pointerAt reports press 1
  assert.equal(pointerAt(t.from + slot + 37, c.cues, 30).press, 1);
});
