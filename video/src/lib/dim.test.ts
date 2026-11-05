import { test } from 'node:test';
import assert from 'node:assert/strict';
import { DIM_BRIGHTNESS, DIM_FRAMES, deviceBrightness } from './dim.ts';

test('the inactive device is dimmed to 40%, the active one and an unset active stay at 100%', () => {
  assert.equal(deviceBrightness('iphone', { active: 'mac', beatFrame: 50 }), DIM_BRIGHTNESS);
  assert.equal(deviceBrightness('mac', { active: 'mac', beatFrame: 50 }), 1);
  assert.equal(deviceBrightness('mac', { beatFrame: 0 }), 1);
});

test('when the device changes on the same screen the brightness eases over 8 frames instead of snapping', () => {
  const at = (device: 'mac' | 'iphone', beatFrame: number) => deviceBrightness(device, { active: 'iphone', prevActive: 'mac', beatFrame });
  assert.equal(at('iphone', 0), DIM_BRIGHTNESS);
  assert.equal(at('mac', 0), 1);
  assert.equal(at('iphone', DIM_FRAMES), 1);
  assert.equal(at('mac', DIM_FRAMES), DIM_BRIGHTNESS);
  assert.equal(at('mac', 50), DIM_BRIGHTNESS);
  let prev = at('iphone', 0);
  for (let f = 1; f <= DIM_FRAMES; f++) {
    const v = at('iphone', f);
    assert.ok(v > prev && v <= 1, `frame ${f}`);
    prev = v;
  }
  assert.ok(at('iphone', 4) > DIM_BRIGHTNESS && at('iphone', 4) < 1);
  assert.ok(Math.abs(at('mac', 4) + at('iphone', 4) - 1.4) < 1e-9); // the two ease in lockstep
});

test('a screen that is new (no previous beat on it) is already settled', () => {
  assert.equal(deviceBrightness('mac', { active: 'iphone', beatFrame: 0 }), DIM_BRIGHTNESS);
});
