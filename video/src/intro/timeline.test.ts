import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { FILM_FRAMES } from '../data/scenes/index.ts';
import { sceneFrames } from '../data/scenes/index.ts';
import { SCENES as FILM_SCENES } from '../data/scenes/index.ts';
import { CHANGE_FRAMES, CHAPTER_START, FORBIDDEN, FPS, FRAMES, SCENES, SCREEN_TEXT, captionAt, captionLength, layerAt } from './timeline.ts';
import { DISPLAY, KB, MENU, PHONE, keyRect, kbTop } from './layout.ts';
import { MAC_DELAY, PAD_AT, PRESSES, TYPED_DEMO, fingerAt, macOps, macTextAt, phoneAt, pressRect } from './script.ts';
import { FINGERS_FROM, FINGER_GAP, GAIN, MENU_OFFSET, PAD, RING_RADIUS, TRACKPAD_EVENTS, trackpadState } from './trackpad.ts';
import { isIntroContext, soundEvents } from './sounds.ts';
import { fingerSource } from './fingers.ts';
import { HW_CANDIDATE_DELAY, STROKES, strokeSchedule } from './ink.ts';

// --- the script table is the only source for times and captions ---
const script = readFileSync(new URL('../../../docs/video/product-intro-script.md', import.meta.url), 'utf8');
const rows = script.split('\n').filter((l) => /^\| (\d[a-f]?) \| \d+–\d+ \|/.test(l)).map((l) => {
  const c = l.split('|').map((s) => s.trim());
  const [from, to] = c[2].split('–').map(Number);
  return { id: c[1], from, to, caption: c[5].replace('（換行）', '\n') };
});

test('the film is 1830 frames at 30 fps and the scenes match the script table row for row', () => {
  assert.equal(FRAMES, 1830);
  assert.equal(FPS, 30);
  assert.equal(rows.length, 16);
  assert.deepEqual(SCENES.map((s) => ({ id: s.id, from: s.from, to: s.to, caption: s.caption })), rows);
});

test('captions cover 0 to 1830 without a gap or an overlap', () => {
  assert.equal(SCENES[0].from, 0);
  assert.equal(SCENES[SCENES.length - 1].to, 1830);
  for (let i = 1; i < SCENES.length; i++) assert.equal(SCENES[i].from, SCENES[i - 1].to);
  for (let f = 0; f < FRAMES; f++) assert.ok(SCENES.some((s) => f >= s.from && f < s.to && captionAt(f) === s.caption), `frame ${f}`);
});

test('every caption stays 1.5 s or longer and reads at 7 characters a second or less', () => {
  for (const s of SCENES) {
    const sec = (s.to - s.from) / FPS;
    assert.ok(sec >= 1.5, `${s.id} is ${sec}s`);
    assert.ok(captionLength(s.caption) / sec <= 7, `${s.id}: ${captionLength(s.caption)} in ${sec}s`);
  }
  assert.equal(captionLength('也可以在 App 改用速成'), 9);
});

test('captions, fixed on-screen text and every typed demo sentence hold none of the banned strings', () => {
  const copy = [...SCENES.map((s) => s.caption), ...SCREEN_TEXT, ...TYPED_DEMO];
  for (const text of copy) for (const bad of FORBIDDEN) assert.ok(!text.includes(bad), `"${text}" has "${bad}"`);
  assert.ok(TYPED_DEMO.includes('Check before sending'));
});

test('scene 5 warns about terminals and remote desktop, scene 6 names Alpha, SideStore and the App Store', () => {
  assert.ok(SCENES.filter((s) => s.id.startsWith('5')).some((s) => s.caption.includes('部分終端機與遠端桌面偵測不到')));
  const six = SCENES.filter((s) => s.id.startsWith('6')).map((s) => s.caption).join('');
  for (const w of ['Alpha', 'SideStore', 'App Store']) assert.ok(six.includes(w), w);
});

test('exactly one chapter is drawn on every frame, the changes at 1320 and 1530 are cross fades that never overlap', () => {
  assert.deepEqual([...CHAPTER_START], [0, 1320, 1530]);
  assert.equal(CHANGE_FRAMES, 8);
  for (let f = 0; f < FRAMES; f++) {
    const l = layerAt(f);
    assert.ok(l.opacity > 0 && l.opacity <= 1, `frame ${f}`);
  }
  assert.deepEqual([1319, 1320, 1323, 1324, 1327, 1328].map((f) => layerAt(f).chapter), [0, 0, 0, 1, 1, 1]);
  const r2 = (f: number) => Math.round(layerAt(f).opacity * 100) / 100;
  assert.deepEqual([1320, 1321, 1322, 1323].map(r2), [0.8, 0.6, 0.4, 0.2], 'old chapter out, never an empty frame');
  assert.deepEqual([1324, 1325, 1326, 1327, 1328].map(r2), [0.2, 0.4, 0.6, 0.8, 1]);
  assert.equal(layerAt(1321).at, 1319, 'the old chapter holds its last frame while it fades out');
  assert.deepEqual([1530, 1534, 1538].map((f) => layerAt(f).chapter), [1, 2, 2]);
});

test('no scene composition of the install film is 1830 frames long, so ProductIntro sound cannot play into one', () => {
  for (const s of FILM_SCENES) assert.notEqual(sceneFrames(s.n), FRAMES, `Scene${s.n}`);
  assert.ok(FILM_FRAMES > FRAMES, 'Main is longer than ProductIntro, so its sounds (which need a context as long as Main) never play here');
});

// --- keyboard layout ---
test('key rectangles lie inside their screenshot and the screenshots sit on the phone screen bottom', () => {
  for (const [name, info] of Object.entries(KB)) {
    assert.equal(kbTop(name as keyof typeof KB), PHONE.bottom - info.h);
    for (const [k, r] of Object.entries(info.keys)) {
      assert.ok(r.x >= 0 && r.y >= 0 && r.x + r.w <= 720 && r.y + r.h <= info.h, `${name}.${k}`);
    }
  }
  assert.equal(KB.connected.h, 594);
  assert.equal(KB.draft.h, 648);
  assert.equal(KB.handwriting.h, 755);
  const q = keyRect('connected', 'q');
  assert.deepEqual(q, { x: 1152 + 6, y: 864 - 594 + 89, w: 60, h: 73 });
});

// --- typing: what the phone does and when the Mac shows it ---
test('every Mac character appears exactly MAC_DELAY frames after its key press, never before', () => {
  assert.equal(MAC_DELAY, 2);
  const ops = macOps();
  assert.ok(ops.length > 50);
  for (const op of ops) {
    assert.equal(op.frame, op.press.t + MAC_DELAY);
    assert.ok(macTextAt(op.press.t + MAC_DELAY - 1, op.chapter).length < macTextAt(op.press.t + MAC_DELAY, op.chapter).length || op.add === '', `${op.press.label} at ${op.press.t}`);
  }
});

test('the TextEdit text grows letter by letter to the lines of scenes 1 to 3, and stays put while the draft is edited', () => {
  assert.equal(macTextAt(0, 0), '');
  assert.equal(macTextAt(143, 0), 'Hello from my iPhone');
  assert.equal(macTextAt(297, 0), 'Hello from my iPhone\nEach key is sent\n');
  assert.equal(macTextAt(335, 0), macTextAt(489, 0), 'draft mode: nothing reaches the Mac until 傳送');
  assert.equal(macTextAt(489, 0), 'Hello from my iPhone\nEach key is sent\n');
  assert.equal(macTextAt(491, 0), 'Hello from my iPhone\nEach key is sent\nCheck before sending\n');
  assert.equal(macTextAt(899, 0), 'Hello from my iPhone\nEach key is sent\nCheck before sending\n香港\n香港');
  assert.equal(macTextAt(1829, 2), 'Remote Keyboard');
  for (let f = 1; f <= 143; f++) {
    const a = macTextAt(f - 1, 0);
    const b = macTextAt(f, 0);
    assert.ok(b.startsWith(a) && b.length - a.length <= 1, `frame ${f}`);
  }
});

test('the draft holds what is typed and 傳送 empties it; the draft shows the new line mark before sending', () => {
  assert.equal(phoneAt(445).draft, 'Check before sending');
  assert.equal(phoneAt(445).kb, 'draft');
  assert.ok(phoneAt(470).draft.endsWith('\n'));
  assert.equal(phoneAt(495).draft, '');
  assert.equal(phoneAt(395).kb, 'draft');
  assert.ok(!PRESSES.some((p) => p.key === 'sym' || p.key === 'abc'), 'no symbol page in the film');
});

test('every press has a sound at its own frame and sounds are sorted and inside the film', () => {
  const ev = soundEvents();
  for (const p of PRESSES) assert.ok(ev.some((e) => e.frame === p.t && e.kind === p.snd), `${p.label} at ${p.t}`);
  for (let i = 0; i < ev.length; i++) {
    assert.ok(Number.isInteger(ev[i].frame) && ev[i].frame >= 0 && ev[i].frame < FRAMES);
    if (i > 0) assert.ok(ev[i].frame >= ev[i - 1].frame, `unsorted at ${i}`);
  }
  assert.deepEqual(soundEvents(), ev);
});

test('letters and space make key, function keys tap, 傳送 sounds good when the text lands, the blocked status bad, the product name success', () => {
  const ev = soundEvents();
  for (const p of PRESSES) {
    const typed = p.fx.k === 'char' || p.fx.k === 'code' || p.fx.k === 'blockedkey';
    assert.equal(p.snd, typed ? 'key' : 'tap', `${p.label} at ${p.t}`);
  }
  const sends = PRESSES.filter((p) => p.fx.k === 'send');
  assert.equal(sends.length, 3);
  for (const s of sends) assert.ok(ev.some((e) => e.kind === 'good' && e.frame === s.t + MAC_DELAY));
  assert.deepEqual(ev.filter((e) => e.kind === 'bad').map((e) => e.frame), [1362]);
  const last = PRESSES.filter((p) => p.t >= 1530).pop()!;
  assert.deepEqual(ev.filter((e) => e.kind === 'success').map((e) => e.frame), [last.t + MAC_DELAY]);
  assert.ok(ev.filter((e) => e.kind === 'click').length >= 5);
});

test('the sound registration plays only into a context exactly as long as ProductIntro', () => {
  assert.ok(isIntroContext(1830 * 48000 / 30, 48000));
  assert.ok(isIntroContext(1830 * 48000 / 30 + 1, 48000));
  assert.ok(!isIntroContext(FILM_FRAMES * 48000 / 30, 48000));
  assert.ok(!isIntroContext(180 * 48000 / 30, 48000));
});

test('the finger rests on the key it presses at the moment of the press', () => {
  for (const p of PRESSES) {
    const f = fingerAt(p.t);
    assert.ok(f.visible && f.press > 0, `${p.label} at ${p.t}`);
    const r = pressRect(p);
    assert.ok(f.x >= r.x && f.x <= r.x + r.w && f.y >= r.y && f.y <= r.y + r.h, `${p.label} at ${p.t}: finger ${f.x},${f.y}`);
  }
});

test('the press on 觸控板 is drawn: the phone finger stays until the pad fingers take over, never both, never none in between', () => {
  const press = PRESSES.find((p) => p.t === PAD_AT)!;
  assert.equal(press.key, 'trackpadBtn');
  for (let f = 900; f < FINGERS_FROM; f++) assert.equal(fingerSource(f, 0), 'phone', `frame ${f}`);
  assert.equal(fingerSource(FINGERS_FROM, 0), 'pad');
  const at = fingerAt(PAD_AT);
  assert.ok(at.visible && at.press > 0 && at.opacity > 0.9);
  assert.ok(fingerAt(899).visible && fingerAt(900).visible, 'the finger does not vanish at 900');
  assert.ok(!fingerAt(FINGERS_FROM).visible, 'the phone finger is gone before the pad fingers appear');
  for (let f = 900; f < 1320; f++) {
    const phone = fingerSource(f, 0) === 'phone' && fingerAt(f).visible;
    const pad = fingerSource(f, 0) === 'pad' && trackpadState(f).fingers.length > 0;
    assert.ok(!(phone && pad), `frame ${f}: two finger sets`);
  }
  const hold = press.hold;
  assert.equal(phoneAt(PAD_AT + hold - 1).kb, 'quick', 'the key is seen pressed on the old keyboard');
  assert.equal(phoneAt(PAD_AT + hold).kb, 'trackpad', 'the picture cuts when the finger lets go');
});

// --- handwriting ---
test('the 香港 ink is traced inside the writing area and grows stroke by stroke inside the scene', () => {
  assert.ok(STROKES.length >= 12);
  const sched = strokeSchedule();
  assert.equal(sched.length, STROKES.length);
  for (let i = 1; i < sched.length; i++) assert.ok(sched[i].from >= sched[i - 1].to);
  assert.ok(sched[0].from >= 548 && sched[sched.length - 1].to < 670);
  const lastEnd = sched[sched.length - 1].to;
  assert.ok(HW_CANDIDATE_DELAY >= 6);
  assert.equal(phoneAt(lastEnd + 5).hwCandidates, false);
  assert.equal(phoneAt(lastEnd + HW_CANDIDATE_DELAY - 1).hwCandidates, false);
  assert.equal(phoneAt(lastEnd + HW_CANDIDATE_DELAY).hwCandidates, true);
  assert.ok(fingerAt(lastEnd + 2).press === 0, 'the finger has left the pad before the candidates show');
  assert.ok(PRESSES.find((p) => p.key === 'cand:0')!.t >= lastEnd + HW_CANDIDATE_DELAY);
  const pad = KB.handwriting.keys.pad;
  for (const s of STROKES) for (const [x, y] of s) assert.ok(x >= pad.x && x <= pad.x + pad.w && y >= pad.y && y <= pad.y + pad.h, `${x},${y}`);
});

// --- trackpad ---
test('the Mac cursor moves exactly gain times the finger, one frame later', () => {
  assert.ok(GAIN > 1);
  let checked = 0;
  for (let f = 960; f < 1318; f++) {
    const a = trackpadState(f - 2);
    const b = trackpadState(f - 1);
    const c = trackpadState(f);
    if (!a.fingers[0] || !b.fingers[0] || !a.fingers[0].down || !b.fingers[0].down) {
      // no finger down in the previous two frames: the cursor must stand still unless a drag or scroll is being undone
      assert.ok(Math.abs(c.cursor.x - b.cursor.x) < 1e-9 && Math.abs(c.cursor.y - b.cursor.y) < 1e-9, `frame ${f} moved without a finger`);
      continue;
    }
    const sc = a.fingers.length === 2;
    if (sc) continue; // two finger scroll moves the page, not the cursor
    assert.ok(Math.abs(c.cursor.x - b.cursor.x - GAIN * (b.fingers[0].x - a.fingers[0].x)) < 1e-6, `frame ${f} x`);
    assert.ok(Math.abs(c.cursor.y - b.cursor.y - GAIN * (b.fingers[0].y - a.fingers[0].y)) < 1e-6, `frame ${f} y`);
    checked++;
  }
  assert.ok(checked > 100, `${checked}`);
});

test('every finger ring, outer ring included, stays inside the grey pad; two rings never overlap; the cursor reaches the file', () => {
  assert.equal(FINGER_GAP, 130);
  assert.ok(FINGER_GAP > 2 * RING_RADIUS);
  let two = 0;
  for (let f = 900; f < 1320; f++) {
    const fingers = trackpadState(f).fingers;
    for (const fg of fingers) {
      const m = RING_RADIUS;
      assert.ok(fg.x - m >= PAD.x && fg.x + m <= PAD.x + PAD.w && fg.y - m >= PAD.y && fg.y + m <= PAD.y + PAD.h, `frame ${f}: ${fg.x},${fg.y}`);
    }
    if (fingers.length === 2) {
      two++;
      assert.ok(Math.hypot(fingers[0].x - fingers[1].x, fingers[0].y - fingers[1].y) > 2 * RING_RADIUS, `frame ${f}: rings overlap`);
    }
  }
  assert.ok(two > 40, `${two} frames with two fingers`);
  const s = trackpadState(1020);
  assert.ok(Math.hypot(s.cursor.x - s.filePos.x, s.cursor.y - s.filePos.y) < 4, 'on the file after 4b');
});

test('the file is selected after the tap, lifted by the hold, the menu opens after the two finger tap and closes with the next tap', () => {
  const taps = TRACKPAD_EVENTS.filter((e) => e.what === 'tap');
  const tap = taps.find((e) => e.frame >= 1025 && e.frame < 1085)!;
  assert.ok(tap);
  assert.equal(trackpadState(tap.frame).fileSelected, false);
  assert.equal(trackpadState(tap.frame + 1).fileSelected, false);
  assert.equal(trackpadState(tap.frame + 2).fileSelected, true);
  const lift = TRACKPAD_EVENTS.find((e) => e.what === 'lift')!;
  assert.equal(trackpadState(lift.frame - 1).fileLifted, false);
  assert.equal(trackpadState(lift.frame).fileLifted, true);
  assert.ok(lift.frame - 1085 >= 12, 'held still for 12 frames or more');
  const drop = TRACKPAD_EVENTS.find((e) => e.what === 'drop')!;
  assert.equal(trackpadState(drop.frame).fileLifted, false);
  const two = TRACKPAD_EVENTS.find((e) => e.what === 'tap2')!;
  assert.equal(trackpadState(two.frame).fingers.length, 2);
  assert.equal(trackpadState(two.frame + 1).menuOpen, false);
  assert.equal(trackpadState(two.frame + 2).menuOpen, true);
  assert.equal(trackpadState(1208).menuOpen, true);
  // the menu is the file's: the cursor is on the file icon while it is open, and does not move until it closes
  for (let f = 1208; f < 1228; f++) {
    const s = trackpadState(f);
    assert.ok(Math.abs(s.cursor.x - s.filePos.x) <= 60 && Math.abs(s.cursor.y - s.filePos.y) <= 70, `frame ${f}: cursor off the file`);
    assert.deepEqual(s.cursor, trackpadState(1208).cursor);
  }
  const m = trackpadState(1208);
  assert.equal(m.menuPos.x, m.cursor.x + MENU_OFFSET.x);
  assert.ok(m.menuPos.y + MENU.h <= DISPLAY.y + DISPLAY.h - DISPLAY.inset, 'menu bottom stays on the Mac screen');
  assert.ok(m.menuPos.y <= m.cursor.y + MENU_OFFSET.y);
  assert.ok(m.cursor.x < m.menuPos.x, 'the cursor is outside the menu, so one tap closes it');
  const close = TRACKPAD_EVENTS.find((e) => e.what === 'tap' && e.frame > two.frame)!;
  assert.equal(trackpadState(close.frame + 1).menuOpen, true);
  assert.equal(trackpadState(close.frame + 2).menuOpen, false);
  assert.deepEqual(trackpadState(close.frame).cursor, trackpadState(two.frame).cursor, 'finger and cursor stay for the closing tap');
  assert.ok(close.frame + 2 <= 1235);
});

test('the page scrolls only while two fingers swipe up with the cursor on the window', () => {
  assert.equal(trackpadState(1260).scrollY, 0);
  const end = trackpadState(1318).scrollY;
  assert.ok(end > 150, `${end}`);
  for (let f = 1; f < 1320; f++) assert.ok(trackpadState(f).scrollY >= trackpadState(f - 1).scrollY);
});
