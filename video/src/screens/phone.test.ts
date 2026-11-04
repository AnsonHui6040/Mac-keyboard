import { test } from 'node:test';
import assert from 'node:assert/strict';
import { PHONE_ORIGIN, PHONE_ORIGIN_RIGHT, PHONE_SCALE, PHONE_SCREEN_H, PHONE_BEZEL, phoneBottom, phoneRect, phoneRight } from './phone.ts';
import { SETTINGS_WINDOW, phoneRect as viaGeometry } from './geometry.ts';

const near = (a: number, b: number) => assert.ok(Math.abs(a - b) < 1e-9, `${a} vs ${b}`);

test('phoneRect maps logical points to canvas pixels with the scale and the origin', () => {
  const r = phoneRect({ x: 40, y: 600, width: 310, height: 60 });
  near(r.x, PHONE_ORIGIN.x + 40 * PHONE_SCALE);
  near(r.y, PHONE_ORIGIN.y + 600 * PHONE_SCALE);
  near(r.width, 310 * PHONE_SCALE);
  near(r.height, 60 * PHONE_SCALE);
  const right = phoneRect({ x: 40, y: 600, width: 310, height: 60 }, PHONE_ORIGIN_RIGHT);
  near(right.x, PHONE_ORIGIN_RIGHT.x + 40 * PHONE_SCALE);
  near(right.y, PHONE_ORIGIN_RIGHT.y + 600 * PHONE_SCALE);
});

test('geometry.ts re-exports phoneRect', () => {
  assert.equal(viaGeometry, phoneRect);
});

test('the screen is at most 800 px tall and the whole phone stays above y=884 in both placements', () => {
  assert.ok(PHONE_SCREEN_H <= 800);
  for (const o of [PHONE_ORIGIN, PHONE_ORIGIN_RIGHT]) assert.ok(phoneBottom(o) < 884, `${o.x}`);
  near(phoneBottom(PHONE_ORIGIN), PHONE_ORIGIN.y + PHONE_SCREEN_H + PHONE_BEZEL);
});

test('the lone phone is centered; the right placement clears the Settings window and fits the canvas', () => {
  near(phoneRight(PHONE_ORIGIN) - PHONE_ORIGIN.x + PHONE_BEZEL, 1920 - 2 * (PHONE_ORIGIN.x - PHONE_BEZEL));
  assert.ok(PHONE_ORIGIN_RIGHT.x - PHONE_BEZEL > SETTINGS_WINDOW.x + SETTINGS_WINDOW.width);
  assert.ok(phoneRight(PHONE_ORIGIN_RIGHT) <= 1920);
});
