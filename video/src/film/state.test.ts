import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { KB } from '../intro/layout.ts';
import { PHONE } from './layout.ts';
import { CONNECT_AT, HW_CANDIDATES_AT, INK, LOGIN, PRESSES } from './events.ts';
import { QUICK_CANDIDATES, QUICK_SCROLL_TOTAL, fingerAt, macAt, macTextAt, phoneAt, pressRect } from './state.ts';

const text = (f: number): string => macTextAt(f);

test('Hello from my iPhone grows one letter at a time, each two frames after its key; the first letters are the storyboard frames', () => {
  assert.equal(text(116), '', 'h was pressed at 114');
  assert.equal(text(117), '', 'shot 3 starts here: a blank page');
  assert.equal(text(118), '', 'and one frame more');
  assert.equal(text(119), 'H', 'the one press with its own Mac delay of 5');
  assert.equal(text(145), 'H');
  assert.equal(text(146), 'He');
  assert.equal(text(149), 'He', 'shot 4 ends, shot 5 shows He');
  for (let f = 1; f < 250; f++) assert.ok(text(f).startsWith(text(f - 1)) && text(f).length - text(f - 1).length <= 1, `frame ${f}`);
  assert.equal(text(237), 'Hello from my iPhone');
  assert.equal(text(235), 'Hello from my iPhon');
});

test('the line break lands in live mode, then the draft is typed and the Mac does not change until the send', () => {
  assert.equal(text(279), 'Hello from my iPhone');
  assert.equal(text(280), 'Hello from my iPhone\n');
  for (let f = 280; f < 480; f++) assert.equal(text(f), 'Hello from my iPhone\n', `frame ${f}`);
  const m = macAt(400);
  assert.deepEqual(m.lines, ['Hello from my iPhone', ''], 'shot 10 and 11: line two has the cursor and no text');
});

test('draft: Chek is typed, the caret goes between e and k, c makes Check; the line break shows as the return mark at the end', () => {
  assert.equal(phoneAt(365).draft, 'Chek before sending');
  assert.equal(phoneAt(365).kb, 'draft');
  const tap = PRESSES.find((p) => p.fx.k === 'caret')!;
  assert.equal(phoneAt(tap.t - 1).caret, 19, 'the caret is at the end while typing');
  assert.equal(phoneAt(tap.t).caret, 3, 'e is the third character, k the fourth');
  assert.equal(phoneAt(tap.t).draft, 'Chek before sending');
  const c = PRESSES.find((p) => p.key === 'c' && p.chapter === 0 && p.t > tap.t)!;
  assert.equal(phoneAt(c.t - 1).draft, 'Chek before sending');
  assert.equal(phoneAt(c.t).draft, 'Check before sending');
  assert.equal(phoneAt(c.t).caret, 4);
  const end = PRESSES.filter((p) => p.fx.k === 'caret')[1];
  assert.equal(phoneAt(end.t).caret, 20, 'the second tap puts the caret at the end before the line break');
  const enter = PRESSES.find((p) => p.fx.k === 'enter' && p.t > end.t)!;
  assert.equal(phoneAt(enter.t).draft, 'Check before sending\n');
  assert.equal(phoneAt(enter.t - 1).draft, 'Check before sending');
});

test('the second line lands whole in one frame, and so do the third and the fourth', () => {
  assert.equal(text(479), 'Hello from my iPhone\n');
  assert.equal(text(480), 'Hello from my iPhone\nCheck before sending\n');
  assert.equal(macAt(480).lines.length, 3);
  assert.equal(text(692), 'Hello from my iPhone\nCheck before sending\n');
  assert.equal(text(693), 'Hello from my iPhone\nCheck before sending\n香港\n');
  assert.equal(text(806), 'Hello from my iPhone\nCheck before sending\n香港\n');
  assert.equal(text(807), 'Hello from my iPhone\nCheck before sending\n香港\n香港');
  assert.equal(phoneAt(808).draft, '');
  assert.deepEqual(macAt(1000).lines, ['Hello from my iPhone', 'Check before sending', '香港', '香港']);
});

test('the keyboard page changes with the key that causes it, after the press shows', () => {
  assert.equal(phoneAt(0).kb, 'connected');
  const toggle = PRESSES.find((p) => p.key === 'toggle:draft')!;
  assert.equal(phoneAt(toggle.t).kb, 'connected');
  assert.equal(phoneAt(toggle.t + toggle.hold - 1).kb, 'connected', 'the press is seen on the page it belongs to');
  assert.equal(phoneAt(toggle.t + toggle.hold).kb, 'draft');
  const zh = PRESSES.find((p) => p.key === 'zh')!;
  assert.equal(phoneAt(zh.t + zh.hold - 1).kb, 'draft');
  assert.equal(phoneAt(zh.t + zh.hold).kb, 'handwriting');
  assert.equal(phoneAt(716).kb, 'handwriting');
  assert.equal(phoneAt(717).kb, 'quick', 'shot 18 is a hard cut to the quick page');
  const pad = PRESSES.find((p) => p.key === 'trackpadBtn')!;
  assert.equal(phoneAt(pad.t + pad.hold - 1).kb, 'quick');
  assert.equal(phoneAt(pad.t + pad.hold).kb, 'trackpad');
  assert.ok(pad.t + pad.hold <= 849 - 8, 'the grey pad shows a few frames before the 3D shot');
});

test('the status says nothing at first, connected from CONNECT_AT, and turns to blocked after the Mac focus moved into the password field', () => {
  assert.equal(phoneAt(CONNECT_AT - 1).status, 'none');
  assert.equal(phoneAt(CONNECT_AT).status, 'connected');
  assert.equal(phoneAt(1229).status, 'connected');
  assert.equal(phoneAt(1255).status, 'connected');
  assert.equal(phoneAt(LOGIN.blocked - 1).status, 'connected');
  assert.equal(phoneAt(LOGIN.blocked).status, 'blocked');
  assert.equal(phoneAt(LOGIN.blocked).kb, 'blocked');
  assert.ok(LOGIN.blocked >= LOGIN.focus + 8, 'the phone reacts after the focus, not with it');
  assert.ok(LOGIN.blocked >= 1254, 'the red shows inside shot 23');
});

test('the password field is empty for the whole of shots 24 to 27 and the Mac text and dots do not change', () => {
  assert.equal(macAt(LOGIN.focus - 1).loginFocused, false);
  assert.equal(macAt(LOGIN.focus).loginFocused, true);
  for (let f = 1296; f < 1362; f++) {
    const m = macAt(f);
    assert.equal(m.screen, 'login');
    assert.equal(m.loginValue, '');
    assert.equal(m.dots, 0);
    assert.ok(m.loginFocused);
  }
  const keys = PRESSES.filter((p) => p.chapter === 1 && p.fx.k === 'blockedkey');
  assert.equal(keys.length, 2, 'two keys');
  for (const k of keys) for (let f = k.t - 2; f < k.t + 6; f++) assert.equal(macAt(f).loginValue, '');
  assert.equal(phoneAt(1300).kb, 'blocked');
});

test('remote desktop: one dot two frames after each of four keys, the fourth is the last frame before the cut', () => {
  const keys = PRESSES.filter((p) => p.chapter === 2);
  assert.equal(keys.length, 4);
  for (const k of keys) {
    assert.equal(macAt(k.t + 1).dots, keys.indexOf(k));
    assert.equal(macAt(k.t + 2).dots, keys.indexOf(k) + 1);
  }
  assert.equal(macAt(1362).screen, 'remote');
  assert.equal(macAt(1362).dots, 0);
  assert.equal(macAt(1448).dots, 4);
  assert.ok(keys[3].t + 2 >= 1446 && keys[3].t + 2 <= 1448, 'the fourth dot shows in the last frames of shot 28');
});

test('the product name is typed into an empty document, letter by letter, finished at 53.0 s', () => {
  assert.equal(macAt(1515).screen, 'doc2');
  assert.deepEqual(macAt(1520).lines, ['']);
  assert.equal(macAt(1589).lines[0], 'Remote Keyboar');
  assert.equal(macAt(1590).lines[0], 'Remote Keyboard');
  assert.equal(macAt(1799).lines[0], 'Remote Keyboard');
});

test('handwriting candidates appear after the strokes and only from shot 16; pick, new line and send follow', () => {
  assert.equal(phoneAt(INK[0].from - 1).inkOn, true, 'the writing area is open before the first stroke');
  assert.equal(phoneAt(650).hwCandidates, false);
  assert.equal(phoneAt(HW_CANDIDATES_AT - 1).hwCandidates, false);
  assert.equal(phoneAt(HW_CANDIDATES_AT).hwCandidates, true);
  const pick = PRESSES.find((p) => p.key === 'cand:0')!;
  assert.equal(phoneAt(pick.t - 1).draft, '');
  assert.equal(phoneAt(pick.t).draft, '香港');
  assert.equal(phoneAt(pick.t).hwCandidates, false, 'the ink and the candidates clear when one is picked');
  const send = PRESSES.find((p) => p.fx.k === 'send' && p.t > pick.t)!;
  assert.equal(phoneAt(send.t).draft, '');
});

test('quick: roots 竹日 give the candidates of the table, 香 is picked, then roots 水山, three flicks scroll the bar, 港 is picked', () => {
  const h = PRESSES.find((p) => p.key === 'h' && p.kb === 'quick')!;
  assert.equal(phoneAt(h.t).code, 'h');
  assert.deepEqual(phoneAt(h.t).candidates, ['竹']);
  const a = PRESSES.find((p) => p.key === 'a' && p.kb === 'quick')!;
  assert.deepEqual(phoneAt(a.t).candidates, ['白', '昏', '徇', '香', '舶', '筍', '箔', '箸', '稽']);
  const p1 = PRESSES.find((p) => p.key === 'qcand:3')!;
  assert.equal(phoneAt(p1.t).draft, '香');
  assert.equal(phoneAt(p1.t).code, '');
  const u = PRESSES.find((p) => p.key === 'u' && p.kb === 'quick')!;
  assert.equal(phoneAt(u.t).code, 'eu');
  assert.equal(phoneAt(u.t).scroll, 0);
  const p2 = PRESSES.find((p) => p.key === 'qcand:15')!;
  assert.equal(phoneAt(p2.t - 1).scroll, QUICK_SCROLL_TOTAL);
  assert.equal(phoneAt(p2.t).draft, '香港');
});

test('the candidate order is the order of quick-table.txt', () => {
  const table = readFileSync(new URL('../../../iOS/RemoteKeyboardExtension/Resources/quick-table.txt', import.meta.url), 'utf8').split('\n').filter((l) => l && !l.startsWith('#')).map((l) => l.split('\t'));
  const of = (code: string) => table.filter(([c]) => c === code).map(([, ch]) => ch);
  assert.deepEqual(QUICK_CANDIDATES.h, of('h').slice(0, QUICK_CANDIDATES.h.length));
  assert.deepEqual(QUICK_CANDIDATES.ha, of('ha').slice(0, QUICK_CANDIDATES.ha.length));
  assert.deepEqual(QUICK_CANDIDATES.e, of('e').slice(0, QUICK_CANDIDATES.e.length));
  const eu = of('eu');
  assert.deepEqual(QUICK_CANDIDATES.eu, eu.slice(0, QUICK_CANDIDATES.eu.length));
  assert.equal(QUICK_CANDIDATES.ha[3], '香');
  assert.equal(QUICK_CANDIDATES.eu[15], '港');
  assert.deepEqual(QUICK_CANDIDATES.eu.slice(13, 22), [...'淹淘港湘溉湄滬澆澠']);
});

test('the finger rests on the thing it presses at the moment of the press', () => {
  for (const p of PRESSES) {
    const f = fingerAt(p.t);
    assert.ok(f.visible && f.press > 0, `${p.label} at ${p.t}`);
    const r = pressRect(p);
    assert.ok(f.x >= r.x && f.x <= r.x + r.w && f.y >= r.y && f.y <= r.y + r.h, `${p.label} at ${p.t}: finger ${f.x.toFixed(0)},${f.y.toFixed(0)} not in ${JSON.stringify(r)}`);
  }
});

test('the finger lands on the key centers of the real keyboard screenshots, with the page bottom aligned to the phone bottom', () => {
  // x, y are worked out by hand from intro/layout.ts KB: key center plus the page offset 864 minus the page height (594, 648, 739).
  const want = [
    { kb: 'connected', key: 'h', x: 432, y: 492 },
    { kb: 'connected', key: 'shift', x: 51.5, y: 589 },
    { kb: 'draft', key: 'send', x: 655, y: 318 },
    { kb: 'quick', key: 'send', x: 655, y: 254 },
  ] as const;
  for (const w of want) {
    const k = KB[w.kb].keys[w.key];
    assert.equal(k.x + k.w / 2, w.x, `${w.kb} ${w.key} x`);
    assert.equal(PHONE.bottom - KB[w.kb].h + k.y + k.h / 2, w.y, `${w.kb} ${w.key} y`);
    const press = PRESSES.find((p) => p.kb === w.kb && p.key === w.key);
    assert.ok(press, `a press of ${w.kb} ${w.key}`);
    const f = fingerAt(press.t);
    assert.ok(Math.abs(f.x - w.x) < 1 && Math.abs(f.y - w.y) < 1, `${w.kb} ${w.key} at ${press.t}: finger ${f.x.toFixed(1)},${f.y.toFixed(1)}`);
  }
});

test('every press target lies inside the page it belongs to', () => {
  for (const p of PRESSES) {
    const r = pressRect(p);
    const h = KB[p.kb].h;
    assert.ok(r.x >= 0 && r.x + r.w <= 720 && r.y >= 864 - h && r.y + r.h <= 864, `${p.label} at ${p.t}`);
  }
});
