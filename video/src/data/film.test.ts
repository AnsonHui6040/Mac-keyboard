import { test } from 'node:test';
import assert from 'node:assert/strict';
import script from './script.json' with { type: 'json' };
import { FILM_FRAMES, FPS, SCENES, sceneFrames } from './scenes/index.ts';

test('the film has all 21 scenes in order and FILM_FRAMES equals the script seconds times 30', () => {
  assert.deepEqual(SCENES.map((s) => s.n), Array.from({ length: 21 }, (_, i) => i + 1));
  assert.deepEqual(script.scenes.map((s) => s.n), SCENES.map((s) => s.n));
  const seconds = script.scenes.reduce((sum, s) => sum + s.seconds, 0);
  assert.equal(seconds, 335);
  assert.equal(FILM_FRAMES, seconds * FPS);
  assert.equal(FILM_FRAMES, 10050);
  assert.equal(FILM_FRAMES, SCENES.reduce((sum, s) => sum + sceneFrames(s.n), 0));
});
