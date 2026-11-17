import { test } from 'node:test';
import assert from 'node:assert/strict';
import { KB } from '../intro/layout.ts';
import { STATUS_CELL, kbTop } from '../film/layout.ts';
import { trackAt } from '../film/trackpad.ts';
import { FRAMES, padFrame, seg } from './timeline.ts';
import { HOST_TAPS, PRESSES, hostAt, type Host } from './events.ts';
import { docAt, promoFingerAt, promoInkAt, promoMacAt, promoPhoneAt, promoTrackAt, pressRect } from './state.ts';

const all = Array.from({ length: FRAMES }, (_, f) => f);
const linesAt = (h: Host, f: number): string[] => docAt(h, f).lines;

test('text goes only to the host that was connected when it was sent', () => {
  assert.deepEqual(linesAt('Mac', FRAMES - 1), ['Hello from my iPhone', 'Check before sending', 'Remote Keyboard']);
  assert.deepEqual(linesAt('Windows', FRAMES - 1), ['香港']);
  assert.deepEqual(linesAt('Linux', FRAMES - 1), ['香港']);
  for (const h of ['Windows', 'Linux'] as const) assert.deepEqual(linesAt(h, HOST_TAPS[0] - 1), ['']);
  assert.deepEqual(linesAt('Windows', seg('5').from), ['香港'], 'Windows has its text before the tap to Linux');
  assert.deepEqual(linesAt('Linux', seg('5').from), [''], 'Linux has nothing yet');
  assert.deepEqual(linesAt('Mac', HOST_TAPS[0] - 1), ['Hello from my iPhone', 'Check before sending', ''], 'Mac has both lines and an empty third when the first tap comes');
});

test('Linux gets 香港 in one frame (paste)', () => {
  const changes = all.filter((f) => f > 0 && linesAt('Linux', f).join('\n') !== linesAt('Linux', f - 1).join('\n'));
  assert.equal(changes.length, 1);
  assert.deepEqual([linesAt('Linux', changes[0] - 1), linesAt('Linux', changes[0])], [[''], ['香港']]);
});

test('the phone always shows the current host as connected', () => {
  for (const f of all) {
    const s = promoPhoneAt(f);
    assert.equal(s.host, hostAt(f), `frame ${f}`);
    assert.equal(s.status, 'connected');
  }
});

test('the phone page follows the story', () => {
  assert.equal(promoPhoneAt(seg('7').to - 1).kb, 'trackpad');
  assert.equal(promoPhoneAt(seg('8').from).kb, 'trackpad');
  const nine = promoPhoneAt(seg('9').from);
  assert.equal(nine.kb, 'connected');
  assert.equal(nine.draft, '');
  assert.equal(promoPhoneAt(seg('2').from).kb, 'connected');
  assert.equal(promoPhoneAt(seg('3').from).kb, 'draft');
  assert.equal(promoPhoneAt(seg('4').to - 1).kb, 'handwriting');
  assert.equal(promoPhoneAt(seg('6').from).kb, 'quick');
  assert.equal(promoPhoneAt(seg('6').to - 1).kb, 'quick');
  assert.equal(promoPhoneAt(seg('6').to - 1).draft, '', 'the draft is sent');
  // the text of segment 9 only reaches the Mac
  for (const h of ['Windows', 'Linux'] as const) assert.deepEqual(linesAt(h, FRAMES - 1), ['香港']);
  assert.deepEqual(linesAt('Mac', seg('9').from), ['Hello from my iPhone', 'Check before sending', '']);
  // the candidates and the scroll of the quick page
  const ha = promoPhoneAt(seg('6').from + 20);
  assert.equal(ha.code, 'ha');
  assert.equal(ha.candidates[3], '香');
  assert.equal(promoPhoneAt(seg('6').to - 1).scroll, 0, 'scroll is only with the code eu');
});

test('every press is on the page the phone shows, and its key has a rect', () => {
  for (const p of PRESSES) {
    assert.equal(promoPhoneAt(p.t).kb, p.kb, `${p.label} at ${p.t}`);
    const r = pressRect(p);
    assert.ok(r.w > 0 && r.h > 0 && Number.isFinite(r.x) && Number.isFinite(r.y), `${p.label} at ${p.t}`);
    const pressed = promoPhoneAt(p.t).pressed;
    assert.equal(pressed?.key, p.key);
  }
  assert.equal(promoPhoneAt(0).pressed, null);
});

test('the Mac document does not change during the trackpad segment', () => {
  const s = seg('8');
  const a = promoMacAt(s.from).lines;
  for (let f = s.from; f < s.to; f += 7) {
    const m = promoMacAt(f);
    assert.deepEqual(m.lines, a);
    assert.equal(m.screen, 'doc');
  }
  assert.deepEqual(promoMacAt(s.to).lines, a);
  assert.deepEqual(promoMacAt(FRAMES - 1).lines, linesAt('Mac', FRAMES - 1));
});

test('the trackpad is the old shot 21 through padFrame', () => {
  const s = seg('8');
  for (let f = s.from; f < s.to; f += 5) {
    assert.deepEqual(promoTrackAt(f), trackAt(Math.round(padFrame(f))), `frame ${f}`);
    assert.deepEqual(promoMacAt(f).track, promoTrackAt(f));
  }
  for (const f of [0, s.from - 1, s.to, FRAMES - 1]) {
    assert.equal(promoTrackAt(f), null);
    assert.equal(promoMacAt(f).track, null);
    assert.equal(promoMacAt(f).cursor, null);
  }
});

test('the finger is hidden outside the keyboard pages and on the pad', () => {
  for (let f = seg('8').from; f < seg('8').to; f++) assert.equal(promoFingerAt(f).visible, false, `frame ${f}`);
  for (const f of [0, 60, seg('1').to - 1, seg('10').from, FRAMES - 1]) assert.equal(promoFingerAt(f).visible, false, `frame ${f}`);
  for (const p of PRESSES) {
    const k = promoFingerAt(p.t);
    assert.equal(k.visible, true, `${p.label} at ${p.t}`);
    assert.equal(k.press, 1);
    assert.ok(k.opacity > 0);
  }
  for (const f of all) if (promoPhoneAt(f).kb === 'trackpad') assert.equal(promoFingerAt(f).visible, false, `pad page at frame ${f}`);
  const hand = promoFingerAt(seg('4').from + 70);
  assert.equal(hand.visible, true, 'the finger draws the ink');
  assert.equal(promoInkAt(seg('4').from + 20).length, 0);
  assert.equal(promoInkAt(seg('4').from + 200).length, 18);
});

test('the Mac caret blinks and rests on a change', () => {
  assert.equal(typeof docAt('Mac', 200).caretOn, 'boolean');
  assert.equal(docAt('Mac', 134).caretOn, true, 'right after a letter the caret stays on');
});

test('after a status tap the finger leaves the host label: from tap + 8 to the end of the status cut it is 70 px from the cell centre or invisible', () => {
  const ids = ['3', '5', '7'] as const;
  HOST_TAPS.forEach((t, i) => {
    const end = seg(ids[i]).to;
    for (let f = t + 8; f < end; f++) {
      const k = promoFingerAt(f);
      if (!k.visible || k.opacity <= 0) continue;
      const kb = promoPhoneAt(f).kb;
      const cx = STATUS_CELL.x + STATUS_CELL.w / 2;
      const cy = kbTop(kb) + KB[kb].toolbarY + STATUS_CELL.h / 2;
      assert.ok(Math.hypot(k.x - cx, k.y - cy) >= 70, `frame ${f}: the finger is ${Math.hypot(k.x - cx, k.y - cy).toFixed(0)} px from the cell`);
    }
  });
});
