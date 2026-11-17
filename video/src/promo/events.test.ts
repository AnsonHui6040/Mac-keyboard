import { test } from 'node:test';
import assert from 'node:assert/strict';
import manifestJson from './voice-manifest.json' with { type: 'json' };
import { FRAMES, SEGMENTS, VOICE, seg, type SegId } from './timeline.ts';
import { CUTS_FX, HOST_TAPS, INK, PAD_EVENTS, PRESSES, SWIPES, hostAt, soundEvents, type PromoPress } from './events.ts';

const manifest = manifestJson as Record<string, { firstPause: number | null }>;
const MARGIN = 18;
const segOf = (t: number): SegId => SEGMENTS.find((s) => t >= s.from && t < s.to)!.id;
const inSeg = (id: SegId): PromoPress[] => PRESSES.filter((p) => segOf(p.t) === id);
const sym = (p: PromoPress): string => {
  const fx = p.fx;
  switch (fx.k) {
    case 'char': return fx.c;
    case 'shift': return '⇧';
    case 'enter': return '↵';
    case 'mode': return '草稿';
    case 'caret': return `@${fx.index}`;
    case 'pick': return `[${fx.text}]`;
    case 'code': return `#${fx.c}`;
    case 'send': return '送';
    case 'host': return 'HOST';
    case 'ime': return `ime:${fx.to}`;
    default: return '?';
  }
};
const story = (id: SegId): string => inSeg(id).map(sym).join('');
const gaps = (ps: PromoPress[]): number[] => ps.slice(1).map((p, i) => p.t - ps[i].t);

test('the three host taps land when 點一下 has been said', () => {
  const ids = ['03', '05', '07'];
  ids.forEach((id, i) => {
    const v = VOICE.find((x) => x.id === id)!;
    assert.equal(HOST_TAPS[i], v.from + Math.round(manifest[id].firstPause! * 30));
  });
  const hostPresses = PRESSES.filter((p) => p.fx.k === 'host');
  assert.deepEqual(hostPresses.map((p) => p.t), [...HOST_TAPS]);
  for (const p of hostPresses) assert.equal(p.key, 'status');
});

test('hostAt goes Mac, Windows, Linux, Mac', () => {
  assert.equal(hostAt(0), 'Mac');
  assert.equal(hostAt(HOST_TAPS[0] - 1), 'Mac');
  assert.equal(hostAt(HOST_TAPS[0]), 'Windows');
  assert.equal(hostAt(HOST_TAPS[1] - 1), 'Windows');
  assert.equal(hostAt(HOST_TAPS[1]), 'Linux');
  assert.equal(hostAt(HOST_TAPS[2] - 1), 'Linux');
  assert.equal(hostAt(HOST_TAPS[2]), 'Mac');
  assert.equal(hostAt(FRAMES - 1), 'Mac');
});

test('each segment holds its own presses', () => {
  assert.equal(story('1'), '');
  assert.equal(story('2'), '⇧Hello from my i⇧Phone↵草稿⇧Chek before sending@3c@20↵送');
  assert.equal(story('3'), 'HOST');
  assert.equal(story('4'), 'ime:hw[香港]送');
  assert.equal(story('5'), 'HOST');
  assert.equal(story('6'), '#h#a[香]#e#u[港]送');
  assert.equal(story('7'), 'HOST' + 'ime:pad');
  assert.equal(story('8'), '');
  assert.equal(story('9'), '⇧Remote ⇧Keyboard');
  assert.equal(story('10'), '');

  const s2 = inSeg('2');
  assert.equal(s2[0].t, seg('2').from + 12 + 0, 'live typing starts 0.4 s into segment 2');
  assert.ok(gaps(s2.slice(0, 22)).every((g) => g === 4), 'Hello from my iPhone, four frames a key');
  assert.equal(s2[22].key, 'enter');
  assert.equal(s2[23].key, 'toggle:draft');
  assert.ok(gaps(s2.slice(24, 44)).every((g) => g === 3), 'Chek before sending, three frames a key');
  assert.deepEqual(s2.slice(44).map((p) => p.key), ['draft:3', 'c', 'draft:20', 'enter', 'send']);
  assert.ok(s2[s2.length - 1].t <= seg('2').from + 240, 'sent by about 8.0 s');

  const s7 = inSeg('7');
  assert.equal(s7[1].key, 'trackpadBtn');
  assert.deepEqual(s7[1].fx, { k: 'ime', to: 'pad' });
  assert.ok(s7[1].t - s7[0].t <= 12, 'the 觸控板 key within 0.4 s of the host tap');

  const s9 = inSeg('9');
  assert.equal(s9.length, 17);
  assert.ok(gaps(s9).every((g) => g === 4));
  assert.deepEqual(CUTS_FX, [
    { t: seg('6').from, fx: { k: 'cut', ime: 'quick' } },
    { t: seg('9').from, fx: { k: 'cut', ime: 'en', mode: 'live' } },
  ]);

  for (const id of ['4', '6']) assert.ok(inSeg(id as SegId)[0].t > seg(id as SegId).from);
  assert.ok(inSeg('6')[0].t > seg('6').from, 'letters come after the cut to the quick page');
  assert.ok(inSeg('9')[0].t > seg('9').from, 'letters come after the cut back to the English page');

  for (let i = 0; i < PRESSES.length; i++) {
    const p = PRESSES[i];
    const s = seg(segOf(p.t));
    assert.ok(Number.isInteger(p.t) && p.t >= s.from, `${p.label} at ${p.t}`);
    assert.ok(p.t + p.hold <= s.to - MARGIN, `${p.label} at ${p.t} is less than 0.6 s before the segment ends`);
    assert.ok(p.hold >= 2 && p.hold <= 4);
    if (i > 0) assert.ok(p.t > PRESSES[i - 1].t);
  }
});

test('the quick page has three flicks between the roots and the second pick', () => {
  assert.equal(SWIPES.length, 3);
  const u = inSeg('6').find((p) => p.key === 'u')!;
  const pick = inSeg('6').find((p) => p.key === 'qcand:15')!;
  assert.ok(SWIPES[0].from >= u.t + u.hold);
  for (const w of SWIPES) assert.equal(w.to - w.from, 8);
  assert.ok(pick.t > SWIPES[2].to);
  assert.equal(inSeg('6').find((p) => p.key === 'qcand:3')!.label, '香');
});

test('ink strokes fit inside segment 4 before the pick', () => {
  const s = seg('4');
  assert.equal(INK.length, 18);
  assert.equal(INK[0].from, s.from + 30);
  assert.ok(INK[INK.length - 1].to <= s.from + 126);
  INK.forEach((w, i) => {
    assert.ok(w.to >= w.from + 2);
    if (i > 0) assert.ok(w.from > INK[i - 1].to);
  });
  const [zh, pick, send] = inSeg('4');
  assert.equal(zh.key, 'zh');
  assert.ok(zh.t + zh.hold <= INK[0].from);
  assert.ok(pick.t >= INK[INK.length - 1].to + 8 + 8, 'candidates show 8 frames after the ink ends');
  assert.equal(pick.key, 'cand:0');
  assert.equal(send.key, 'send');
});

test('the pad events are the old shot 21 events spread over segment 8', () => {
  assert.equal(PAD_EVENTS.length, 9);
  const s = seg('8');
  PAD_EVENTS.forEach((e, i) => {
    assert.ok(e.frame > s.from && e.frame < s.to, e.what);
    if (i > 0) assert.ok(e.frame >= PAD_EVENTS[i - 1].frame);
  });
});

test('sounds: one per press, good after each send, success after the last letter of segment 9, tap for host, ink per stroke', () => {
  const ev = soundEvents();
  const of = (k: string) => ev.filter((e) => e.kind === k);
  assert.equal(of('key').length + of('tap').length - PAD_EVENTS.filter((e) => ['tap', 'tap2', 'tap3'].includes(e.what)).length + of('host').length, PRESSES.length);
  assert.deepEqual(of('host').map((e) => e.frame), [...HOST_TAPS]);
  const sends = PRESSES.filter((p) => p.fx.k === 'send');
  assert.equal(sends.length, 3);
  assert.deepEqual(of('good').map((e) => e.frame), sends.map((p) => p.t + 2));
  const s9 = inSeg('9');
  assert.deepEqual(of('success').map((e) => e.frame), [s9[s9.length - 1].t + 2]);
  assert.deepEqual(of('ink').map((e) => e.frame), INK.map((w) => w.from));
  for (const e of ev) assert.ok(e.frame >= 0 && e.frame < FRAMES);
  assert.deepEqual(ev.map((e) => e.frame), [...ev.map((e) => e.frame)].sort((a, b) => a - b));
});
