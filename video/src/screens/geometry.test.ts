import { test } from 'node:test';
import assert from 'node:assert/strict';
import { SCREENS, center, restPoint, DIALOGS, type Rect } from './geometry.ts';

const inside = (r: Rect, outer: Rect) =>
  r.x >= outer.x && r.y >= outer.y && r.x + r.width <= outer.x + outer.width && r.y + r.height <= outer.y + outer.height;

test('dialogConfirm stacks trash, open, done from top to bottom without touching rings', () => {
  const c = SCREENS.dialogConfirm;
  assert.deepEqual(Object.keys(c).sort(), ['done', 'open', 'trash']);
  assert.ok(c.trash.y < c.open.y && c.open.y < c.done.y); // 由上到下：丟到垃圾桶、強制打開、完成
  assert.ok(c.open.y - (c.trash.y + c.trash.height) >= 22); // 標示框不相碰
});

test('dialogConfirm uses the approved template numbers', () => {
  const c = SCREENS.dialogConfirm;
  assert.deepEqual(DIALOGS.dialogConfirm, { x: 480, y: 54, width: 590, height: 796 });
  assert.deepEqual(c.trash, { x: 514, y: 556, width: 522, height: 72 });
  assert.deepEqual(c.open, { x: 514, y: 650, width: 522, height: 72 });
  assert.deepEqual(c.done, { x: 514, y: 744, width: 522, height: 72 });
});

test('every target stays on the stage, above the subtitle divider', () => {
  for (const screen of Object.values(SCREENS))
    for (const r of Object.values(screen)) {
      assert.ok(r.x >= 0 && r.x + r.width <= 1920);
      assert.ok(r.y >= 0 && r.y + r.height <= 884); // 不可壓到字幕分隔線
    }
});

test('dialogBlocked has done on the left and trash on the right, same row', () => {
  const b = SCREENS.dialogBlocked;
  assert.deepEqual(Object.keys(b).sort(), ['done', 'trash']);
  assert.ok(b.done.x + b.done.width < b.trash.x);
  assert.equal(b.done.y, b.trash.y);
});

test('auth stacks password above cancel', () => {
  const a = SCREENS.auth;
  assert.deepEqual(Object.keys(a).sort(), ['cancel', 'password']);
  assert.ok(a.password.y + a.password.height < a.cancel.y);
});

test('settingsSecurity has a single open button', () => {
  assert.deepEqual(Object.keys(SCREENS.settingsSecurity), ['open']);
});

test('dialog screens keep their buttons inside the dialog', () => {
  for (const id of ['dialogBlocked', 'dialogConfirm', 'auth'] as const)
    for (const r of Object.values(SCREENS[id])) assert.ok(inside(r, DIALOGS[id]), id);
  assert.ok(inside(SCREENS.settingsSecurity.open, DIALOGS.settingsSecurity));
});

test('center is the middle of the rect', () => {
  assert.deepEqual(center({ x: 10, y: 20, width: 100, height: 50 }), { x: 60, y: 45 });
});

test('restPoint is 84% across and 30% down the rect', () => {
  const p = restPoint({ x: 100, y: 200, width: 500, height: 100 });
  assert.ok(Math.abs(p.x - 520) < 1e-9);
  assert.ok(Math.abs(p.y - 230) < 1e-9);
});

test('restPoint of every target is inside its rect and off the center', () => {
  for (const screen of Object.values(SCREENS))
    for (const r of Object.values(screen)) {
      const p = restPoint(r);
      assert.ok(p.x > r.x && p.x < r.x + r.width && p.y > r.y && p.y < r.y + r.height);
      assert.notDeepEqual(p, center(r));
    }
});
