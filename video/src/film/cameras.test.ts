import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { CLOSE_IDS, PAN, PUSH, closeCam, toPlane } from './cameras.ts';
import { projectSlab, type Pt } from './slabMath.ts';
import { DOC, DOC_LINE, ICON, PHONE_TOP, hwCandidateRect, kbTop, keyRect, type R } from './layout.ts';
import { caretAt, fingerAt, macAt, phoneAt } from './state.ts';
import { SHOTS, TITLES } from './timeline.ts';
import { textWidth } from './metrics.ts';

const shot = (id: string) => SHOTS.find((s) => s.id === id)!;
const frames = (id: string): number[] => Array.from({ length: shot(id).to - shot(id).from }, (_, i) => shot(id).from + i);
const near = (a: number, b: number, d: number, msg: string) => assert.ok(Math.abs(a - b) <= d, `${msg}: ${a} vs ${b}`);
const MARGIN = 60;
const inside = (p: Pt, m = MARGIN) => p.x >= m && p.x <= 1920 - m && p.y >= m && p.y <= 1080 - m;
const at = (id: string, f: number, dev: 'phone' | 'mac', x: number, y: number): Pt => {
  const c = closeCam(id, f);
  const q = toPlane(dev, { x, y });
  return projectSlab(c.p, c.fx, c.fy, q.x, q.y);
};
const titleAt = (f: number) => TITLES.find((t) => f >= t.from && f < t.to);

test('the close-up shots are exactly the phone and Mac shots', () => {
  const want = SHOTS.filter((s) => s.kind === 'phone' || s.kind === 'mac').map((s) => s.id).sort();
  assert.deepEqual([...CLOSE_IDS].sort(), want);
  assert.ok(!CLOSE_IDS.includes('1') && !CLOSE_IDS.includes('21a') && !CLOSE_IDS.includes('30'));
});

test('every close-up is locked: fixed focus, offset and angles; mag grows at one constant rate of at most 1.5 % a second', () => {
  assert.ok(PUSH * 100 <= 1.5);
  for (const id of CLOSE_IDS) {
    const a = frames(id).map((f) => closeCam(id, f));
    const first = a[0];
    for (const [i, c] of a.entries()) {
      for (const k of ['tx', 'ty', 'pitch', 'yaw', 'roll', 'persp', 'focusH'] as const) assert.equal(c.p[k], first.p[k], `shot ${id} ${k} at ${i}`);
      assert.equal(c.fy, first.fy, `shot ${id} fy`);
      assert.equal(c.dev, first.dev);
      if (id !== '18') assert.equal(c.fx, first.fx, `shot ${id} fx`);
    }
    const step = a[1].p.mag - a[0].p.mag;
    for (let i = 1; i < a.length; i++) near(a[i].p.mag - a[i - 1].p.mag, step, 1e-9, `shot ${id} mag step at ${i}`);
    assert.ok(step >= 0);
    const perSecond = (step * 30) / first.p.mag;
    assert.ok(perSecond <= 0.015 + 1e-12, `shot ${id}: ${(perSecond * 100).toFixed(2)} % a second`);
  }
});

test('shot 18 is the one pan: only fx moves, 0.5 plane px a frame, with the same mag all through', () => {
  assert.equal(PAN, 0.5);
  const a = frames('18').map((f) => closeCam('18', f));
  for (let i = 1; i < a.length; i++) {
    near(a[i].fx - a[i - 1].fx, 0.5, 1e-9, 'pan step');
    assert.equal(a[i].p.mag, a[0].p.mag);
  }
  for (const id of CLOSE_IDS.filter((x) => x !== '18')) assert.equal(closeCam(id, shot(id).to - 1).fx, closeCam(id, shot(id).from).fx);
});

test('the camera table reads no finger and no caret: it does not import the state or the screens', () => {
  const src = readFileSync(new URL('./cameras.ts', import.meta.url), 'utf8');
  const code = src.replace(/\/\*[\s\S]*?\*\//g, '').replace(/\/\/.*$/gm, '');
  assert.ok(!/finger|caret|fingerAt|caretAt|draftCaretX|macAt|phoneAt|pressRect|PRESSES|INK/i.test(code), 'a finger or caret name is in the code');
  const imports = [...src.matchAll(/from '([^']+)'/g)].map((m) => m[1]).sort();
  assert.deepEqual(imports, ['./layout.ts', './metrics.ts', './slabMath.ts', './timeline.ts']);
});

test('shots 2 and 4 are the same camera; the typing shots show the three letter rows and the shift key', () => {
  assert.deepEqual(closeCam('2', shot('2').from), { ...closeCam('4', shot('4').from) });
  for (const id of ['2', '4', '6']) {
    const c = closeCam(id, shot(id).from);
    assert.ok(c.p.mag >= 1.6 && c.p.mag <= 2.05, `${id} mag ${c.p.mag}`);
    assert.ok(c.p.pitch >= 25 && c.p.pitch <= 35 && !c.sharp);
    assert.ok(c.p.focusH >= 120, 'a wide band of focus');
    for (const key of ['q', 'p', 'a', 'l', 'z', 'm', 'shift']) {
      const r = keyRect('connected', key);
      for (const [x, y] of [[r.x, r.y], [r.x + r.w, r.y + r.h]]) assert.ok(inside(at(id, shot(id).from, 'phone', x, y), 20), `${id}: ${key} is in the frame`);
    }
  }
});

test('every finger position of every phone close-up is in the frame, 60 px from the edge, and below the title band while a title is up', () => {
  let n = 0;
  for (const id of CLOSE_IDS.filter((x) => closeCam(x, shot(x).from).dev === 'phone')) {
    for (const f of frames(id)) {
      const k = fingerAt(f);
      if (!k.visible || k.opacity <= 0) continue;
      const p = at(id, f, 'phone', k.x, k.y);
      n++;
      assert.ok(inside(p), `shot ${id} frame ${f}: the ring is at ${p.x.toFixed(0)},${p.y.toFixed(0)}`);
      if (titleAt(f)) assert.ok(p.y >= 215, `shot ${id} frame ${f}: the ring is under a title at y ${p.y.toFixed(0)}`);
    }
  }
  assert.ok(n > 500, `${n} positions checked`);
});

test('every Mac caret of the Mac close-ups is in the frame, and so are the text lines of the document', () => {
  let n = 0;
  for (const id of CLOSE_IDS.filter((x) => closeCam(x, shot(x).from).dev === 'mac')) {
    for (const f of frames(id)) {
      const m = macAt(f);
      const c = caretAt(m.lines, m.screen === 'doc2');
      const p = at(id, f, 'mac', c.x, c.y);
      n++;
      assert.ok(inside(p), `shot ${id} frame ${f}: the caret is at ${p.x.toFixed(0)},${p.y.toFixed(0)}`);
      if (titleAt(f)) assert.ok(p.y >= 215, `shot ${id} frame ${f}: the caret is under a title`);
      const widest = Math.max(...m.lines.map((l) => textWidth(l, DOC.size, 500)));
      const top = DOC.textY;
      const bottom = DOC.textY + m.lines.length * DOC.size * DOC_LINE;
      for (const [x, y] of [[DOC.textX, top], [DOC.textX + widest, top], [DOC.textX, bottom], [DOC.textX + widest, bottom]]) assert.ok(inside(at(id, f, 'mac', x, y)), `shot ${id} frame ${f}: the text block corner ${x},${y}`);
    }
  }
  assert.ok(n >= 100);
});

test('the desktop icons and their labels are out of the frame in every Mac close-up, so no label is cut by the edge', () => {
  for (const id of CLOSE_IDS.filter((x) => closeCam(x, shot(x).from).dev === 'mac')) {
    for (const f of [shot(id).from, shot(id).to - 1]) {
      for (const [cx, cy, up, down] of [[ICON.file.x, ICON.file.y, 110, 150], [ICON.folder.x, ICON.folder.y, 90, 140]]) {
        for (const [x, y] of [[cx - 90, cy - up], [cx - 90, cy + down]]) assert.ok(at(id, f, 'mac', x, y).x >= 1935, `shot ${id} frame ${f}: an icon edge is at ${at(id, f, 'mac', x, y).x.toFixed(0)}`);
      }
    }
  }
});

test('shot 7 shows the whole line Hello from my iPhone with room on both sides; shots 3 and 5 are locked on the start of the line', () => {
  const f = shot('7').to - 1;
  const last = at('7', f, 'mac', DOC.textX + textWidth('Hello from my iPhone', DOC.size, 500), 0);
  const first = at('7', f, 'mac', DOC.textX, 0);
  assert.ok(first.x >= 200 && last.x <= 1720, `the line runs ${first.x.toFixed(0)} to ${last.x.toFixed(0)}`);
  for (const id of ['3', '5']) {
    const c = closeCam(id, shot(id).from);
    assert.ok(c.p.mag >= 2.4 && c.p.mag <= 2.8);
    const start = at(id, shot(id).from, 'mac', DOC.textX, 0);
    assert.ok(start.x >= 200 && start.x <= 960, `the start of the line is at ${start.x.toFixed(0)}`);
  }
});

test('the draft shots are straight on and sharp: pitch, yaw and roll are 0, one layer, the panel top below the title', () => {
  for (const id of ['8', '9', '11', '12', '14', '20']) {
    const c = closeCam(id, shot(id).from);
    assert.deepEqual([c.p.pitch, c.p.yaw, c.p.roll], [0, 0, 0], id);
    assert.equal(c.sharp, true, id);
  }
  for (const id of ['8', '9', '12', '14', '20']) assert.ok(Math.abs(closeCam(id, shot(id).from).p.mag - 1.35) <= 0.01, `shot ${id} is at about mag 1.35`);
  assert.ok(closeCam('11', shot('11').from).p.mag >= 1.9 && closeCam('11', shot('11').from).p.mag <= 2.1);
  for (const id of ['8', '9', '12', '14', '20']) {
    for (const f of frames(id)) {
      const kb = phoneAt(f).kb;
      const top = at(id, f, 'phone', 360, kbTop(kb));
      const left = at(id, f, 'phone', 0, kbTop(kb));
      const right = at(id, f, 'phone', 720, kbTop(kb));
      assert.ok(left.x >= 100 && right.x <= 1820, `shot ${id} frame ${f}: the panel is ${left.x.toFixed(0)} to ${right.x.toFixed(0)}`);
      assert.ok(top.y <= 1000 && top.y >= 55, `shot ${id} frame ${f}: the panel top is at ${top.y.toFixed(0)}`);
      if (titleAt(f)) assert.ok(top.y >= 190, `shot ${id} frame ${f}: the panel top ${top.y.toFixed(0)} is under the title`);
    }
  }
});

test('in shots 14, 15 and 18 the top of the phone panel stays below y 200, clear of the title, on every frame', () => {
  for (const id of ['14', '15', '18']) {
    for (const f of frames(id)) {
      const kb = phoneAt(f).kb;
      for (const x of [0, 720]) {
        const p = at(id, f, 'phone', x, kbTop(kb));
        assert.ok(p.y >= 200, `shot ${id} frame ${f}: the panel top corner at x ${x} is at y ${p.y.toFixed(0)}`);
      }
    }
  }
});

test('shot 11 holds the draft bar and the c key in the frame together', () => {
  for (const f of frames('11')) {
    const bar = at('11', f, 'phone', 360, kbTop('draft') + 75 + 26);
    const c = keyRect('draft', 'c');
    const key = at('11', f, 'phone', c.x + c.w / 2, c.y + c.h / 2);
    assert.ok(inside(bar, 100) && inside(key, 100), `frame ${f}: bar ${bar.y.toFixed(0)}, c ${key.y.toFixed(0)}`);
  }
});

test('the handwriting shots are seen from above: pitch 0, yaw 0, a fixed roll of about -8, sharp; shot 15 holds the pad, shot 16 the candidates, enter and send', () => {
  for (const id of ['15', '16']) {
    const c = closeCam(id, shot(id).from);
    assert.deepEqual([c.p.pitch, c.p.yaw], [0, 0]);
    near(c.p.roll, -8, 1, `roll of ${id}`);
    assert.equal(c.sharp, true);
  }
  assert.ok(closeCam('15', shot('15').from).p.mag >= 1.2 && closeCam('15', shot('15').from).p.mag <= 2.2);
  assert.ok(Math.abs(closeCam('16', shot('16').from).p.mag - 1.4) <= 0.15);
  const pad: R = keyRect('handwriting', 'pad');
  for (const f of frames('15')) for (const [x, y] of [[pad.x, pad.y], [pad.x + pad.w, pad.y], [pad.x, pad.y + pad.h], [pad.x + pad.w, pad.y + pad.h]]) {
    const p = at('15', f, 'phone', x, y);
    assert.ok(p.x >= -140 && p.x <= 2060 && p.y >= -60 && p.y <= 1140, `frame ${f}: pad corner ${p.x.toFixed(0)},${p.y.toFixed(0)}`);
  }
  const wanted: R[] = [...[0, 1, 2, 3].map((i) => hwCandidateRect('handwriting', i)), keyRect('handwriting', 'enter'), keyRect('handwriting', 'send')];
  for (const f of frames('16')) for (const r of wanted) for (const [x, y] of [[r.x, r.y], [r.x + r.w, r.y + r.h]]) assert.ok(inside(at('16', f, 'phone', x, y), 40), `frame ${f}: ${JSON.stringify(r)}`);
});

test('shot 18 keeps every pressed key, candidate and the send key in the frame; its band of focus is wide', () => {
  assert.ok(closeCam('18', shot('18').from).p.focusH >= 200);
  const keys = ['h', 'a', 'e', 'u', 'send'];
  for (const f of frames('18')) {
    for (const key of keys) {
      const r = keyRect('quick', key);
      assert.ok(inside(at('18', f, 'phone', r.x + r.w / 2, r.y + r.h / 2), 100), `frame ${f}: ${key}`);
    }
    for (const x of [140, 600]) assert.ok(inside(at('18', f, 'phone', x, kbTop('quick') + 194), 100), `frame ${f}: the candidate bar at ${x}`);
  }
});

test('the plane helper puts the phone page where the Slab draws it', () => {
  assert.deepEqual(toPlane('phone', { x: 10, y: PHONE_TOP + 20 }), { x: 10, y: 20 });
  assert.deepEqual(toPlane('mac', { x: 10, y: 20 }), { x: 10, y: 20 });
});
