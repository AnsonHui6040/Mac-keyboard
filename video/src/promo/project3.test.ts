import { test } from 'node:test';
import assert from 'node:assert/strict';
import { STAGE, bounds, forward, heroStage, macPin, phoneBody, phonePin, type Corners } from '../film/project.ts';
import { PAD_START, TITLES, seg } from './timeline.ts';
import { textWidth } from '../film/metrics.ts';
import { FAR, WIDE, brightness, heroCam3, linuxPin, stageCam, wideCam, wideStage, winPin } from './project3.ts';
import { cam21 } from '../film/project.ts';
import { padFrame } from './timeline.ts';

const s9 = seg('9');
const W = 1920;
const H = 1080;
const MARGIN = 60;
const wid = (c: Corners) => { const b = bounds(c); return b.x1 - b.x0; };
const cx = (c: Corners) => { const b = bounds(c); return (b.x0 + b.x1) / 2; };
const cy = (c: Corners) => { const b = bounds(c); return (b.y0 + b.y1) / 2; };
const rel = (a: number, b: number) => Math.abs(a - b) / Math.max(a, b);
const screens = (f: number) => {
  const cam = wideCam(f);
  const st = wideStage();
  return { mac: macPin(cam, st), win: winPin(cam), linux: linuxPin(cam), phone: phonePin(cam, st), body: phoneBody(cam, st) };
};

test('the three computers are not a row of equals', () => {
  const { mac, win, linux } = screens(s9.from);
  assert.ok(rel(wid(mac), wid(win)) >= 0.15, `mac ${wid(mac)} win ${wid(win)}`);
  assert.ok(rel(wid(win), wid(linux)) >= 0.15, `win ${wid(win)} linux ${wid(linux)}`);
  assert.ok(rel(wid(mac), wid(linux)) >= 0.15, `mac ${wid(mac)} linux ${wid(linux)}`);
  const d1 = Math.hypot(cx(mac) - cx(win), cy(mac) - cy(win));
  const d2 = Math.hypot(cx(win) - cx(linux), cy(win) - cy(linux));
  assert.ok(rel(d1, d2) >= 0.1, `distances ${d1} ${d2}`);
});

test('the Mac is the bright one in shots 1 and 9', () => {
  for (const id of ['1', '9'] as const) {
    assert.equal(brightness('Mac', id), 1);
    assert.ok(brightness('Windows', id) <= 0.5 && brightness('Linux', id) <= 0.5);
  }
});

test('shot 8 keeps the Mac and phone where shot 9 has them', () => {
  const d = (a: number[], b: number[]) => a.map((v, i) => v - b[i]);
  const was = d(STAGE.phonePos, STAGE.macPos);
  const now = d(WIDE.phone.pos, WIDE.mac.pos);
  was.forEach((v, i) => assert.ok(Math.abs(v - now[i]) < 1e-9, `axis ${i}`));
  assert.deepEqual(WIDE.mac.rot, STAGE.macRot);
  assert.deepEqual(WIDE.phone.rot, STAGE.phoneRot);
});

test('shot 8 camera is the old shot 21 camera, held at its last frame', () => {
  const s8 = seg('8');
  assert.deepEqual(stageCam(s8.from), cam21(Math.min(1229, padFrame(s8.from))));
  assert.deepEqual(stageCam(s8.to - 1), cam21(1229));
  assert.ok(PAD_START > s8.from);
});

test('every screen of shot 9 is fully in frame, 60 px from the edges, first and last frame', () => {
  for (const f of [s9.from, Math.round((s9.from + s9.to) / 2), s9.to - 1]) {
    for (const [name, c] of Object.entries(screens(f))) {
      const b = bounds(c);
      assert.ok(b.x0 >= MARGIN && b.y0 >= MARGIN && b.x1 <= W - MARGIN && b.y1 <= H - MARGIN, `${name} at ${f}: ${JSON.stringify(b)}`);
    }
  }
});

test('shot 9 moves back at one speed only, away from the target', () => {
  const step = (f: number) => wideCam(f + 1).position.map((v, i) => v - wideCam(f).position[i]);
  const first = step(s9.from);
  const len = (v: number[]) => Math.hypot(...v);
  for (let f = s9.from; f < s9.to - 1; f += 7) {
    const st = step(f);
    st.forEach((v, i) => assert.ok(Math.abs(v - first[i]) < 1e-9, `step ${f} axis ${i}`));
    const away = wideCam(f).position.map((v, i) => v - wideCam(f).target[i]);
    const dot = away.reduce((a, v, i) => a + v * st[i], 0) / (len(away) * len(st));
    assert.ok(dot > 0.999, `direction ${dot}`);
  }
  assert.ok(len(first) > 0);
  assert.deepEqual(wideCam(s9.from).target, wideCam(s9.to - 1).target);
});

test('the Mac screen of shot 9 stays big enough to read: at least 480 px wide', () => {
  for (const f of [s9.from, s9.to - 1]) assert.ok(wid(screens(f).mac) >= 480, `${wid(screens(f).mac)}`);
});

test('shot 1: the camera is the film hero camera and the far computers are three different placements', () => {
  const cam = heroCam3(0);
  assert.ok(forward(cam)[2] < -0.99);
  const xs = [FAR.mac.pos[0], FAR.win.pos[0], FAR.linux.pos[0]];
  assert.equal(new Set(xs).size, 3);
  assert.ok(FAR.win.pos[2] < FAR.mac.pos[2] && FAR.linux.pos[2] < FAR.mac.pos[2] + 0, 'the Mac is the nearest of the three');
});

test('the title of shot 1 stays 40 px clear of the phone in every frame it is shown', () => {
  const t = TITLES.find((x) => x.id === 'p1')!;
  const w = Math.min(t.width, textWidth(t.text, t.size, 700));
  const box = { x0: t.x, x1: t.x + w, y0: t.y, y1: t.y + t.size * 1.45 };
  assert.ok(t.size >= 76);
  const s1 = seg('1');
  assert.ok(t.from >= s1.from && t.to <= s1.to);
  for (let f = t.from; f < t.to; f++) {
    const b = bounds(phoneBody(heroCam3(f), heroStage(f)));
    const gapX = Math.max(box.x0 - b.x1, b.x0 - box.x1);
    const gapY = Math.max(box.y0 - b.y1, b.y0 - box.y1);
    assert.ok(Math.max(gapX, gapY) >= 40, `frame ${f}: gap ${Math.max(gapX, gapY).toFixed(0)}`);
  }
});
