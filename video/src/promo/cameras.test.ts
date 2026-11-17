import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { CLOSE_IDS, LIN_DOC, PAN, PUSH, WIN_DOC, closeCam, toPlane } from './cameras.ts';
import { CUTS, DRAFT_SEND, LIVE_LAST, cutAt, cutById } from './cuts.ts';
import { HOST_TAPS, MAC_DELAY } from './events.ts';
import { docAt, promoFingerAt, promoMacAt, promoPhoneAt } from './state.ts';
import { FRAMES, TITLES, seg } from './timeline.ts';
import { projectSlab, type Pt } from '../film/slabMath.ts';
import { DOC, DOC_LINE, ICON, STATUS_CELL, kbTop } from '../film/layout.ts';
import { KB } from '../intro/layout.ts';
import { caretAt } from '../film/state.ts';
import { textWidth } from '../film/metrics.ts';

const cut = cutById;
const frames = (id: string): number[] => Array.from({ length: cut(id).to - cut(id).from }, (_, i) => cut(id).from + i);
const near = (a: number, b: number, d: number, msg: string) => assert.ok(Math.abs(a - b) <= d, `${msg}: ${a} vs ${b}`);
const MARGIN = 60;
const inside = (p: Pt, m = MARGIN) => p.x >= m && p.x <= 1920 - m && p.y >= m && p.y <= 1080 - m;
type Dev = 'phone' | 'mac' | 'win' | 'linux';
const at = (id: string, f: number, dev: Dev, x: number, y: number): Pt => {
  const c = closeCam(id, f);
  const q = toPlane(dev, { x, y });
  return projectSlab(c.p, c.fx, c.fy, q.x, q.y);
};
const titleAt = (f: number) => TITLES.find((t) => f >= t.from && f < t.to);
const devOf = (id: string): Dev => closeCam(id, cut(id).from).dev;
const idsOf = (d: Dev) => CLOSE_IDS.filter((id) => devOf(id) === d);

test('cuts cover the film with no gap and follow the segments', () => {
  assert.equal(CUTS[0].from, 0);
  assert.equal(CUTS[CUTS.length - 1].to, FRAMES);
  for (let i = 1; i < CUTS.length; i++) assert.equal(CUTS[i].from, CUTS[i - 1].to, `gap before ${CUTS[i].id}`);
  for (const c of CUTS) assert.ok(c.to > c.from);
  assert.equal(cutAt(0).id, '1');
  assert.equal(cutAt(FRAMES - 1).dev, 'card');
  const of = (id: '1' | '2' | '3' | '4' | '5' | '6' | '7' | '8' | '9' | '10') => CUTS.filter((c) => c.from >= seg(id).from && c.to <= seg(id).to);
  for (const id of ['1', '2', '3', '4', '5', '6', '7', '8', '9', '10'] as const) {
    const cs = of(id);
    assert.equal(cs[0].from, seg(id).from, `segment ${id} start`);
    assert.equal(cs[cs.length - 1].to, seg(id).to, `segment ${id} end`);
  }
  // segment 2: the phone and the Mac take turns; the Mac cuts start MAC_DELAY frames (up to 2 more) after the key
  assert.deepEqual(of('2').map((c) => c.dev), ['phone', 'mac', 'phone', 'mac']);
  const live = of('2')[1];
  const draft = of('2')[3];
  assert.ok(live.from > seg('2').from && live.from < LIVE_LAST, `live Mac cut at ${live.from} is in the middle of the live typing`);
  assert.ok(draft.from >= DRAFT_SEND + MAC_DELAY && draft.from <= DRAFT_SEND + MAC_DELAY + 2, `draft Mac cut at ${draft.from}`);
  for (const id of ['3', '5', '7'] as const) assert.deepEqual(of(id).map((c) => c.dev), ['phone']);
  assert.equal(of('4')[of('4').length - 1].dev, 'win');
  assert.equal(of('6')[of('6').length - 1].dev, 'linux');
  assert.deepEqual([of('1'), of('8'), of('9'), of('10')].map((a) => a.map((c) => c.dev)), [['hero'], ['stage'], ['wide'], ['card']]);
});

test('slower pace: every cut of segments 2 to 7 is at least 30 frames, the Mac cuts of segment 2 at least 45, the host names stay 75 frames', () => {
  for (const c of CUTS.filter((x) => x.from >= seg('2').from && x.to <= seg('7').to)) assert.ok(c.to - c.from >= 30, `cut ${c.id} is ${c.to - c.from} frames`);
  const s2 = CUTS.filter((c) => c.from >= seg('2').from && c.to <= seg('2').to);
  for (const c of s2.filter((x) => x.dev === 'mac')) assert.ok(c.to - c.from >= 45, `Mac cut ${c.id} is ${c.to - c.from} frames`);
  assert.ok(HOST_TAPS[0] + 75 <= seg('3').to, 'the Windows name stays 75 frames');
  assert.ok(HOST_TAPS[1] + 75 <= seg('5').to, 'the Linux name stays 75 frames');
});

test('the first Mac cut of segment 2 shows the letters arrive one by one, and the whole line stays in frame', () => {
  const c = cut('2b');
  let changes = 0;
  let prev = promoMacAt(c.from).lines.join('\n');
  for (const f of frames('2b')) {
    const cur = promoMacAt(f).lines.join('\n');
    if (cur.length > prev.length) changes++;
    prev = cur;
  }
  assert.ok(changes >= 6, `${changes} letters appeared during the cut`);
  const first = promoMacAt(c.from).lines.join('').length;
  const last = promoMacAt(c.to - 1).lines.join('').length;
  assert.ok(last > first, 'the text grows');
  for (const f of [c.from, c.to - 1]) {
    for (const x of [DOC.textX, DOC.textX + textWidth('Hello from my iPhone', DOC.size, 500)]) assert.ok(inside(at('2b', f, 'mac', x, DOC.textY)), `frame ${f}: the line at x ${x} is in the frame`);
  }
});

test('the status cell close-ups (segments 3, 5, 7) are front on at about 2 times, the whole toolbar width in the frame, the cell in the middle band on every frame', () => {
  for (const id of ['3', '5', '7']) {
    const c = closeCam(id, cut(id).from);
    assert.deepEqual([c.p.pitch, c.p.yaw, c.p.roll], [0, 0, 0]);
    assert.ok(c.p.mag >= 1.9 && c.p.mag <= 2.2 && c.sharp, `${id} mag ${c.p.mag}`);
    for (const f of frames(id)) {
      const kb = promoPhoneAt(f).kb;
      const y = kbTop(kb) + KB[kb].toolbarY + STATUS_CELL.h / 2;
      const p = at(id, f, 'phone', STATUS_CELL.x + STATUS_CELL.w / 2, y);
      assert.ok(Math.abs(p.y - 540) <= 200 && p.x >= 100 && p.x <= 1820, `shot ${id} frame ${f}: the cell is at ${p.x.toFixed(0)},${p.y.toFixed(0)}`);
      const left = at(id, f, 'phone', 0, y);
      const right = at(id, f, 'phone', 720, y);
      assert.ok(left.x >= 40 && right.x <= 1880, `shot ${id} frame ${f}: the toolbar runs ${left.x.toFixed(0)} to ${right.x.toFixed(0)}`);
    }
  }
});

test('close-ups are locked: only mag grows (1.2 % a second, at most 1.5 %), or one constant pan', () => {
  assert.ok(PUSH * 100 <= 1.5);
  assert.ok(CLOSE_IDS.length >= 10);
  for (const id of CLOSE_IDS) {
    const a = frames(id).map((f) => closeCam(id, f));
    const first = a[0];
    for (const [i, c] of a.entries()) {
      for (const k of ['tx', 'ty', 'pitch', 'yaw', 'roll', 'persp', 'focusH'] as const) assert.equal(c.p[k], first.p[k], `cut ${id} ${k} at ${i}`);
      assert.equal(c.fy, first.fy, `cut ${id} fy`);
      assert.equal(c.dev, first.dev);
      if (id !== '6a') assert.equal(c.fx, first.fx, `cut ${id} fx`);
    }
    const step = a[1].p.mag - a[0].p.mag;
    for (let i = 1; i < a.length; i++) near(a[i].p.mag - a[i - 1].p.mag, step, 1e-9, `cut ${id} mag step at ${i}`);
    assert.ok(step >= 0);
    assert.ok((step * 30) / first.p.mag <= 0.015 + 1e-12, `cut ${id} pushes too fast`);
  }
  const a = frames('6a').map((f) => closeCam('6a', f));
  assert.equal(PAN, 0.5);
  for (let i = 1; i < a.length; i++) { near(a[i].fx - a[i - 1].fx, 0.5, 1e-9, 'pan step'); assert.equal(a[i].p.mag, a[0].p.mag); }
});

test('the camera table reads no finger and no caret: it does not import the state or the screens', () => {
  const src = readFileSync(new URL('./cameras.ts', import.meta.url), 'utf8');
  const code = src.replace(/\/\*[\s\S]*?\*\//g, '').replace(/\/\/.*$/gm, '');
  assert.ok(!/finger|caret|fingerAt|caretAt|macAt|phoneAt|pressRect|PRESSES|INK/i.test(code), 'a finger or caret name is in the code');
});

test('rings stay 60 px from the edges, and below y 215 under a title', () => {
  let n = 0;
  for (const id of idsOf('phone')) {
    for (const f of frames(id)) {
      const k = promoFingerAt(f);
      if (!k.visible || k.opacity <= 0) continue;
      const p = at(id, f, 'phone', k.x, k.y);
      n++;
      assert.ok(inside(p), `cut ${id} frame ${f}: the ring is at ${p.x.toFixed(0)},${p.y.toFixed(0)}`);
      if (titleAt(f)) assert.ok(p.y >= 215, `cut ${id} frame ${f}: the ring is under a title at y ${p.y.toFixed(0)}`);
    }
  }
  assert.ok(n > 300, `${n} positions checked`);
});

test('the typed text is fully in frame on Mac, Windows and Linux cuts, and below the title band', () => {
  let n = 0;
  const block = (id: string, f: number, dev: Dev, geo: { textX: number; textY: number; size: number }, lines: string[]) => {
    const widest = Math.max(...lines.map((l) => textWidth(l, geo.size, 500)));
    const bottom = geo.textY + lines.length * geo.size * DOC_LINE;
    for (const [x, y] of [[geo.textX, geo.textY], [geo.textX + widest, geo.textY], [geo.textX, bottom], [geo.textX + widest, bottom]]) {
      const p = at(id, f, dev, x, y);
      assert.ok(inside(p), `cut ${id} frame ${f}: the text corner ${x},${y} is at ${p.x.toFixed(0)},${p.y.toFixed(0)}`);
      if (titleAt(f)) assert.ok(p.y >= 215, `cut ${id} frame ${f}: the text is under a title`);
    }
    n++;
  };
  for (const id of idsOf('mac')) {
    for (const f of frames(id)) {
      const m = promoMacAt(f);
      const c = caretAt(m.lines, false);
      assert.ok(inside(at(id, f, 'mac', c.x, c.y)), `cut ${id} frame ${f}: the caret`);
      block(id, f, 'mac', { textX: DOC.textX, textY: DOC.textY, size: DOC.size }, m.lines);
    }
  }
  for (const id of idsOf('win')) for (const f of frames(id)) block(id, f, 'win', WIN_DOC, docAt('Windows', f).lines);
  for (const id of idsOf('linux')) for (const f of frames(id)) block(id, f, 'linux', LIN_DOC, docAt('Linux', f).lines);
  assert.ok(n >= 150);
  assert.equal(WIN_DOC.size, 52);
  assert.equal(LIN_DOC.size, 52);
});

test('the desktop icons and their labels are out of the frame in every Mac close-up', () => {
  for (const id of idsOf('mac')) {
    for (const f of [cut(id).from, cut(id).to - 1]) {
      for (const [cx, cy, up, down] of [[ICON.file.x, ICON.file.y, 110, 150], [ICON.folder.x, ICON.folder.y, 90, 140]]) {
        for (const [x, y] of [[cx - 90, cy - up], [cx - 90, cy + down]]) assert.ok(at(id, f, 'mac', x, y).x >= 1935, `cut ${id} frame ${f}: an icon edge is at ${at(id, f, 'mac', x, y).x.toFixed(0)}`);
      }
    }
  }
});

test('the typing and handwriting cuts keep every pressed key in the frame', () => {
  for (const id of ['2a', '2c', '4a', '4b', '6a']) {
    for (const f of frames(id)) {
      const k = promoFingerAt(f);
      if (!k.visible) continue;
      assert.ok(inside(at(id, f, 'phone', k.x, k.y), 40), `cut ${id} frame ${f}`);
    }
  }
});

test('the plane helper puts the phone page where the Slab draws it', () => {
  assert.deepEqual(toPlane('phone', { x: 10, y: kbTop('draft') + 0 }), { x: 10, y: kbTop('draft') - 109 });
  assert.deepEqual(toPlane('win', { x: 10, y: 20 }), { x: 10, y: 20 });
});
