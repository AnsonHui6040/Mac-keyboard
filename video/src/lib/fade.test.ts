import { test } from 'node:test';
import assert from 'node:assert/strict';
import { openingFade } from './fade.ts';
import { FADE_FRAMES } from './sceneSpec.ts';

test('the opening fade takes FADE_FRAMES (8) frames, rises from 1/8 to 1 and never draws an empty frame', () => {
  assert.equal(FADE_FRAMES, 8);
  assert.equal(openingFade(0), 1 / 8);
  assert.equal(openingFade(3), 0.5);
  assert.equal(openingFade(FADE_FRAMES - 1), 1);
  assert.equal(openingFade(FADE_FRAMES + 100), 1);
  let last = 0;
  for (let f = 0; f < FADE_FRAMES; f++) {
    assert.ok(openingFade(f) > last, `frame ${f}`);
    last = openingFade(f);
  }
});
