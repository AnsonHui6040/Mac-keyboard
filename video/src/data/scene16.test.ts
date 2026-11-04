import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { splitBeats } from '../lib/captions.ts';
import { pointerAt } from '../lib/pointer.ts';
import { SCREENS, restPoint, type Rect } from '../screens/geometry.ts';
import { SCENE16_BEATS, SCENE16_FPS, SCENE16_FRAMES, SCENE16_SECONDS, ENTRY_OFFSET, scene16Cues, scene16Timeline, targetRect } from './scene16.ts';

const script = JSON.parse(readFileSync(new URL('./script.json', import.meta.url), 'utf8')) as { scenes: { n: number; seconds: number; caption: string }[] };
const caption = (script.scenes.find((s) => s.n === 16) as { caption: string }).caption;
const beats = splitBeats(caption);
const timeline = scene16Timeline(beats);
const cues = scene16Cues(timeline);

const inside = (p: { x: number; y: number }, r: Rect) => p.x >= r.x && p.x <= r.x + r.width && p.y >= r.y && p.y <= r.y + r.height;

test('SCENE16_BEATS matches the approved table', () => {
  assert.deepEqual(SCENE16_BEATS, [
    { screen: 'dialogBlocked' },
    { screen: 'dialogBlocked' },
    { screen: 'dialogBlocked', target: 'done', press: true },
    { screen: 'settingsSecurity', target: 'open', press: true },
    { screen: 'dialogConfirm', target: 'open', labels: ['good'] },
    { screen: 'dialogConfirm', target: 'open', labels: ['good', 'bad'], minSeconds: 4 },
    { screen: 'auth', target: 'password' },
  ]);
});

test('one entry per subtitle beat', () => {
  assert.equal(SCENE16_BEATS.length, beats.length);
});

test('every target exists on its beat screen', () => {
  for (const b of SCENE16_BEATS) if (b.target) assert.ok(targetRect(b.screen, b.target), `${b.screen}/${b.target}`);
});

test('frame count comes from the script entry (seconds x fps); the timeline covers it and beat 5 lasts at least 4 s', () => {
  const entry = script.scenes.find((s) => s.n === 16) as unknown as { seconds: number };
  assert.equal(SCENE16_SECONDS, entry.seconds);
  assert.equal(SCENE16_FRAMES, entry.seconds * SCENE16_FPS);
  assert.equal(timeline[0].from, 0);
  assert.equal(timeline[timeline.length - 1].to, SCENE16_FRAMES);
  assert.ok(timeline[5].to - timeline[5].from >= 4 * SCENE16_FPS);
});

test('the pointer enters from ENTRY_OFFSET below the first target one frame before heading for it', () => {
  const first = SCENE16_BEATS.findIndex((b) => b.target);
  const rest = restPoint(targetRect(SCENE16_BEATS[first].screen, SCENE16_BEATS[first].target!)!);
  assert.deepEqual(cues[0], { from: timeline[first].from, x: rest.x, y: rest.y + ENTRY_OFFSET, press: false });
  assert.equal(cues[1].from, timeline[first].from + 1);
  assert.equal(cues[1].x, rest.x);
  assert.equal(cues[1].y, rest.y);
  assert.equal(pointerAt(timeline[first].from - 1, cues, SCENE16_FPS).visible, false);
});

test('five frames before each beat ends the pointer is on that beat target, never on the trash button in beat 5', () => {
  SCENE16_BEATS.forEach((b, i) => {
    if (!b.target) return;
    const state = pointerAt(timeline[i].to - 5, cues, SCENE16_FPS);
    assert.ok(state.visible, `beat ${i}`);
    assert.ok(inside(state, targetRect(b.screen, b.target)!), `beat ${i}`);
  });
  const s5 = pointerAt(timeline[5].to - 5, cues, SCENE16_FPS);
  assert.ok(!inside(s5, SCREENS.dialogConfirm.trash));
});

test('every cue that is a target sits at that target rest point; pointer stays on open through beat 5', () => {
  for (const f of [timeline[5].from, timeline[5].from + 40, timeline[5].to - 1]) {
    const s = pointerAt(f, cues, SCENE16_FPS);
    const r = restPoint(SCREENS.dialogConfirm.open);
    assert.ok(Math.abs(s.x - r.x) < 1e-9 && Math.abs(s.y - r.y) < 1e-9);
  }
});

test('presses finish inside their beats', () => {
  SCENE16_BEATS.forEach((b, i) => {
    if (!b.press) return;
    let peak = 0;
    for (let f = timeline[i].from; f < timeline[i].to; f++) peak = Math.max(peak, pointerAt(f, cues, SCENE16_FPS).press);
    assert.equal(peak, 1, `beat ${i}`);
  });
});
