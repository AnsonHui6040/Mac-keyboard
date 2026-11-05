import { test } from 'node:test';
import assert from 'node:assert/strict';
import { CAM21, STAGE, bounds, cam21, cam30, forward, macPin, macPoint, phoneBody, phonePin, phonePoint, planeCorners, project, rotate, type Cam } from './project.ts';
import { CURSOR, PAD } from './layout.ts';

const near = (a: number, b: number, d = 1e-6, msg = '') => assert.ok(Math.abs(a - b) <= d, `${msg} ${a} vs ${b}`);

test('project: a camera 10 units away with a 90 degree fov puts the origin in the middle and a unit sideways 54 px off', () => {
  const cam: Cam = { fov: 90, position: [0, 0, 10], target: [0, 0, 0] };
  const [x0, y0] = project(cam, [0, 0, 0]);
  near(x0, 960); near(y0, 540);
  const [x1, y1] = project(cam, [1, 0, 0]);
  near(x1, 960 + 54); near(y1, 540);
  const [, y2] = project(cam, [0, 1, 0]);
  near(y2, 540 - 54);
  const [x3] = project(cam, [-1, 0, 5]);
  near(x3, 960 - 108, 1e-6, 'nearer things are bigger');
});

test('rotate follows the engine: Ry of 90 degrees takes +x to -z, Rx of 90 takes +y to +z, Rz of 90 takes +x to +y', () => {
  const r = (p: [number, number, number], rot: [number, number, number]) => rotate(p, rot).map((v) => Math.round(v * 1e9) / 1e9);
  assert.deepEqual(r([1, 0, 0], [0, 90, 0]), [0, 0, -1]);
  assert.deepEqual(r([0, 1, 0], [90, 0, 0]), [0, 0, 1]);
  assert.deepEqual(r([1, 0, 0], [0, 0, 90]), [0, 1, 0]);
});

test('planeCorners: a 2 by 2 plane facing the camera, and its reflection in the floor', () => {
  const cam: Cam = { fov: 90, position: [0, 0, 10], target: [0, 0, 0] };
  const c = planeCorners(cam, 2, 2, [[[0, 0, 0], [0, 0, 0]]]);
  near(c.topLeft[0], 906); near(c.topLeft[1], 486); near(c.bottomRight[0], 1014); near(c.bottomRight[1], 594);
  const m = planeCorners(cam, 2, 2, [[[0, 3, 0], [0, 0, 0]]], true);
  const up = planeCorners(cam, 2, 2, [[[0, 3, 0], [0, 0, 0]]]);
  near(m.topLeft[1] + up.topLeft[1], 1080, 1e-6, 'the mirror image is the plane turned over the floor line');
});

test('shot 21 is the storyboard frame at its first, middle and last frame: Mac 120 to 1200 by 230 to 900, phone body 1400 to 1860 down to 1040', () => {
  for (const f of [849, 1040, 1229]) {
    const cam = cam21(f);
    const m = bounds(macPin(cam, STAGE));
    const p = bounds(phoneBody(cam, STAGE));
    const w = 25;
    near(m.x0, 120, w, `mac x0 at ${f}`); near(m.x1, 1200, w, `mac x1 at ${f}`); near(m.y0, 230, w, `mac y0 at ${f}`); near(m.y1, 900, w, `mac y1 at ${f}`);
    near(p.x0, 1400, w, `phone x0 at ${f}`); near(p.x1, 1860, w, `phone x1 at ${f}`); near(p.y1, 1040, w, `phone bottom at ${f}`);
    near(m.x1 - m.x0, 1080, w, 'screen width 1080');
    near(p.x1 - p.x0, 460, w, 'body width 460');
  }
});

test('shot 21: the pad is at least 400 by 260 on the frame and the ring (106 wide) about 64 px', () => {
  for (const f of [849, 1229]) {
    const cam = cam21(f);
    const xs = [PAD.x, PAD.x + PAD.w].flatMap((x) => [PAD.y, PAD.y + PAD.h].map((y) => phonePoint(cam, STAGE, x, y)));
    const w = Math.max(...xs.map((p) => p[0])) - Math.min(...xs.map((p) => p[0]));
    const h = Math.max(...xs.map((p) => p[1])) - Math.min(...xs.map((p) => p[1]));
    assert.ok(w >= 400 && h >= 260, `pad ${w.toFixed(0)} by ${h.toFixed(0)} at ${f}`);
    const a = phonePoint(cam, STAGE, 300, 500);
    const b = phonePoint(cam, STAGE, 406, 500);
    assert.ok(Math.abs(b[0] - a[0]) >= 62 && Math.abs(b[0] - a[0]) <= 68, `ring ${Math.abs(b[0] - a[0]).toFixed(1)} px`);
    const c = macPoint(cam, STAGE, 0, 0);
    const foot = macPoint(cam, STAGE, 0, CURSOR.arrowH * CURSOR.stage);
    const side = macPoint(cam, STAGE, 22 * CURSOR.stage, 0);
    const tall = Math.hypot(foot[0] - c[0], foot[1] - c[1]);
    assert.ok(tall >= 44 && tall <= 52, `cursor ${tall.toFixed(1)} px tall at ${f}`);
    assert.ok(Math.hypot(side[0] - c[0], side[1] - c[1]) >= 28, 'and wide enough');
  }
});

test('shot 21 camera moves at one speed and stays inside the limits: push at most 3 %, pan at most 30 px, yaw at most 1.5 degrees', () => {
  const a = cam21(849);
  const b = cam21(1229);
  const ma = bounds(macPin(a, STAGE));
  const mb = bounds(macPin(b, STAGE));
  assert.ok((mb.x1 - mb.x0) / (ma.x1 - ma.x0) <= 1.03, 'push');
  assert.ok((mb.x1 - mb.x0) / (ma.x1 - ma.x0) >= 1);
  assert.ok(Math.abs((mb.x0 + mb.x1) / 2 - (ma.x0 + ma.x1) / 2) <= 30, 'pan x');
  assert.ok(Math.abs((mb.y0 + mb.y1) / 2 - (ma.y0 + ma.y1) / 2) <= 30, 'pan y');
  const fa = forward(a);
  const fb = forward(b);
  const yaw = (Math.acos(Math.min(1, fa[0] * fb[0] + fa[1] * fb[1] + fa[2] * fb[2])) * 180) / Math.PI;
  assert.ok(yaw <= 1.5, `yaw ${yaw}`);
  assert.ok(CAM21.from.fov === CAM21.to.fov);
  // one speed: the same step every frame, and it never stops or reverses
  const step = (f: number) => cam21(f + 1).position.map((v, i) => v - cam21(f).position[i]);
  for (const f of [849, 900, 1000, 1100, 1228]) for (let i = 0; i < 3; i++) near(step(f)[i], step(849)[i], 1e-9, `step ${f}`);
  assert.ok(step(849).some((v) => Math.abs(v) > 1e-5), 'it is moving');
  // before the first and after the last frame the camera holds
  assert.deepEqual(cam21(849).position, CAM21.from.position);
});

test('shot 30 is the only pull back: the camera gets farther from what it looks at on every frame', () => {
  const dist = (c: Cam) => Math.hypot(c.position[0] - c.target[0], c.position[1] - c.target[1], c.position[2] - c.target[2]);
  let last = 0;
  for (let f = 1515; f < 1620; f++) {
    const d = dist(cam30(f));
    assert.ok(d > last, `frame ${f}`);
    last = d;
  }
  for (let f = 849; f < 1229; f++) assert.ok(dist(cam21(f + 1)) <= dist(cam21(f)) + 1e-12, 'shot 21 never pulls back');
});

test('the phone screen lies inside the phone body and the Mac screen is 16 to 10 on the frame at shot 21', () => {
  const cam = cam21(1040);
  const body = bounds(phoneBody(cam, STAGE));
  const scr = bounds(phonePin(cam, STAGE));
  assert.ok(scr.x0 >= body.x0 && scr.x1 <= body.x1 && scr.y1 <= body.y1);
  const p = macPin(cam, STAGE);
  const w = p.topRight[0] - p.topLeft[0];
  const h = p.bottomLeft[1] - p.topLeft[1];
  near(w / h, 1.6, 0.1, 'aspect');
});

test('shot 30 keeps both devices in the frame while it rises and pulls back, and the deck is seen from above at 8 degrees or more', () => {
  for (const f of [1515, 1567, 1619]) {
    const cam = cam30(f);
    const m = bounds(macPin(cam, STAGE));
    const p = bounds(phoneBody(cam, STAGE));
    assert.ok(m.x0 >= 20 && m.x1 <= 1900 && m.y0 >= 20 && m.y1 <= 1060, `mac at ${f}: ${JSON.stringify(m)}`);
    assert.ok(p.x0 >= 20 && p.x1 <= 1900 && p.y0 >= 20 && p.y1 <= 1075, `phone at ${f}: ${JSON.stringify(p)}`);
    const dx = cam.position[0] - STAGE.macPos[0];
    const dz = cam.position[2] - STAGE.macPos[2];
    const elevation = (Math.atan2(cam.position[1] - 0.09, Math.hypot(dx, dz)) * 180) / Math.PI;
    assert.ok(elevation >= 8, `elevation ${elevation.toFixed(1)} at ${f}`);
    assert.ok((m.x1 - m.x0) >= 750, `the Mac screen stays readable: ${(m.x1 - m.x0).toFixed(0)} px wide at ${f}`);
  }
  // the camera rises and backs off at one speed: no jump
  for (const i of [0, 1, 2]) {
    const step = (f: number) => cam30(f + 1).position[i] - cam30(f).position[i];
    near(step(1520), step(1600), 1e-9, `axis ${i}`);
  }
});
