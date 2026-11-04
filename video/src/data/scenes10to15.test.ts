import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { SCREENS, restPoint, type Rect } from '../screens/geometry.ts';
import { FPS, compileRegistered, sceneEntry } from './scenes/index.ts';
import { scene10 } from './scenes/scene10.ts';
import { scene11 } from './scenes/scene11.ts';
import { scene12 } from './scenes/scene12.ts';
import { scene14 } from './scenes/scene14.ts';
import { scene15 } from './scenes/scene15.ts';
import { IPA_NAME, ZIP_NAME, IPA_SHA256, ZIP_SHA256 } from './artifacts.ts';
import { pointerAt } from '../lib/pointer.ts';
import { fitSize } from '../screens/extensionFit.ts';

const inside = (p: { x: number; y: number }, r: Rect) => p.x >= r.x && p.x <= r.x + r.width && p.y >= r.y && p.y <= r.y + r.height;

test('the SHA-256 values are 64 hex characters and equal the design document', () => {
  const doc = readFileSync(new URL('../../../docs/superpowers/specs/2026-11-04-install-tutorial-video-design.md', import.meta.url), 'utf8');
  for (const [name, sha] of [[IPA_NAME, IPA_SHA256], [ZIP_NAME, ZIP_SHA256]]) {
    assert.match(sha, /^[0-9a-f]{64}$/);
    assert.ok(doc.includes(`${name}\`）為 \`${sha}\``) || doc.includes(sha), name);
  }
  assert.equal(IPA_NAME, 'RemoteKeyboard-v0.1.0-unsigned.ipa');
  assert.equal(ZIP_NAME, 'RemoteKeyboardReceiver-v0.1.0-macOS.zip');
});

test('scene 10 goes from the Mac to the iPhone', () => {
  assert.deepEqual(scene10.beats.map((b) => b.device), ['mac', 'mac', 'iphone']);
  const c = compileRegistered(scene10);
  assert.equal(c.deviceAt(0), 'mac');
  assert.equal(c.deviceAt(c.timeline[2].from + 5), 'iphone');
});

test('scene 11: the second option is good, Remove is bad; both labels together at least 3 s; the dialog is never pressed and the pointer never rests on Remove', () => {
  const both = scene11.beats.filter((b) => b.labels?.some((l) => l.kind === 'bad'));
  assert.equal(both.length, 1);
  assert.deepEqual(both[0].labels, [{ target: 'keepEach', kind: 'good' }, { target: 'remove', kind: 'bad' }]);
  const c = compileRegistered(scene11);
  const i = scene11.beats.indexOf(both[0]);
  assert.ok((c.timeline[i].to - c.timeline[i].from) / FPS >= 3);
  assert.equal(both[0].minSeconds && both[0].minSeconds >= 3, true);
  for (const b of scene11.beats.slice(1)) assert.ok(b.steps?.every((s) => s.target === 'keepEach' && !s.press));
  for (let f = c.timeline[1].from; f < c.timeline[3].to; f++) {
    const p = pointerAt(f, c.cues, FPS);
    assert.ok(!inside(p, SCREENS.extDialog.remove), `frame ${f}`);
  }
  const end = pointerAt(c.timeline[3].to - 5, c.cues, FPS);
  const r = restPoint(SCREENS.extDialog.keepEach);
  assert.ok(Math.abs(end.x - r.x) < 1 && Math.abs(end.y - r.y) < 1);
  // the two Keep labels stay on one line: the longer one is shrunk below the other
  assert.ok(fitSize(26.95) < fitSize(18.47));
});

test('the dialog buttons run in the document order, top to bottom, with room for neighbouring rings', () => {
  const d = SCREENS.extDialog;
  const order = ['keepMain', 'keepEach', 'remove', 'choose', 'cancel'];
  assert.deepEqual(Object.keys(d), order);
  for (let k = 1; k < order.length; k++) assert.ok(d[order[k]].y - (d[order[k - 1]].y + d[order[k - 1]].height) >= 20);
});

test('scene 12 and 14 raised their seconds by at most 3 over the first script (13 and 12)', () => {
  assert.ok(sceneEntry(12).seconds - 13 >= 0 && sceneEntry(12).seconds - 13 <= 3);
  assert.ok(sceneEntry(14).seconds - 12 >= 0 && sceneEntry(14).seconds - 12 <= 3);
  assert.equal(scene12.beats[0].steps?.length, 5);
  assert.equal(scene14.beats[0].steps?.filter((s) => s.target === 'next').length, 4);
});

test('scene 15: the drag has no press step, and the pointer ends on 應用程式', () => {
  const drag = scene15.beats[2].steps!;
  assert.deepEqual(drag.map((s) => s.target), ['receiver', 'apps']);
  assert.ok(drag.every((s) => !s.press));
  const c = compileRegistered(scene15);
  const end = pointerAt(c.timeline[2].to - 5, c.cues, FPS);
  assert.ok(inside(end, SCREENS.zipFlow.apps));
  assert.equal(scene15.beats[0].steps, undefined);
});
