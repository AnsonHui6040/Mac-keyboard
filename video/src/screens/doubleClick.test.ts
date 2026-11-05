import { test } from 'node:test';
import assert from 'node:assert/strict';
import { compileRegistered, SCENES } from '../data/scenes/index.ts';
import { pointerAt } from '../lib/pointer.ts';
import { DOUBLE_CLICK_GAP, pulseAt, secondPeak } from './doubleClick.ts';

test('a pulse peaks at 1 on its frame, is 0 four frames either side, and the second peak is 10 frames after the first', () => {
  assert.equal(pulseAt(50, 50), 1);
  assert.equal(pulseAt(46, 50), 0);
  assert.equal(pulseAt(54, 50), 0);
  assert.equal(pulseAt(52, 50), 0.5);
  assert.equal(secondPeak(143), 143 + DOUBLE_CLICK_GAP);
  assert.equal(DOUBLE_CLICK_GAP, 10);
});

test('scene 15 beat 1: the step press peaks at land, the second pulse 10 frames later, both inside the beat, and the double click adds no step', () => {
  const spec = SCENES.find((s) => s.n === 15)!;
  assert.equal(spec.beats[1].steps!.length, 3);
  const c = compileRegistered(spec);
  const { from, to } = c.timeline[1];
  const land = c.stepTimes[1][2].land;
  assert.equal(pointerAt(from + land, c.cues, 30).press, 1, 'first ring peaks at land');
  const second = secondPeak(land);
  assert.equal(pulseAt(second, second), 1);
  // the second ring and the app that follows it (6 frames) end before the beat does, so the result is whole when beat 2 starts
  assert.ok(second + 6 <= to - from, `second peak ${second} + 6 within beat of ${to - from} frames`);
  assert.ok(second + 4 < to - from);
});
