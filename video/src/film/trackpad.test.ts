import { test } from 'node:test';
import assert from 'node:assert/strict';
import { PAD_AT, PAD_EVENTS } from './events.ts';
import { FINGER_GAP, GAIN, RING, SCROLL_GAIN, trackAt } from './trackpad.ts';
import { FOLDER_WIN, ICON, MAC, MENU, PAD } from './layout.ts';

test('the cursor moves exactly GAIN times the finger, one frame later, and only while one finger is down', () => {
  assert.equal(GAIN, 1.5);
  let checked = 0;
  for (let f = 880; f < 1235; f++) {
    const a = trackAt(f - 2);
    const b = trackAt(f - 1);
    const c = trackAt(f);
    const oneDown = a.fingers.length === 1 && b.fingers.length === 1 && a.fingers[0].down && b.fingers[0].down;
    if (!oneDown) {
      assert.ok(Math.abs(c.cursor.x - b.cursor.x) < 1e-9 && Math.abs(c.cursor.y - b.cursor.y) < 1e-9, `frame ${f} moved without one finger down`);
      continue;
    }
    assert.ok(Math.abs(c.cursor.x - b.cursor.x - GAIN * (b.fingers[0].x - a.fingers[0].x)) < 1e-6, `frame ${f} x`);
    assert.ok(Math.abs(c.cursor.y - b.cursor.y - GAIN * (b.fingers[0].y - a.fingers[0].y)) < 1e-6, `frame ${f} y`);
    checked++;
  }
  assert.ok(checked > 100, `${checked} frames checked`);
});

test('the cursor slides to the file, then the folder, then 打開; it never leaves the Mac screen', () => {
  const near = (a: { x: number; y: number }, b: { x: number; y: number }, d = 3) => Math.hypot(a.x - b.x, a.y - b.y) <= d;
  assert.ok(near(trackAt(PAD_AT.tap1[0] - 2).cursor, ICON.file), 'on the file before the tap');
  assert.ok(near(trackAt(PAD_AT.drop).cursor, ICON.folder), 'on the folder at the drop');
  const m = trackAt(PAD_AT.menu);
  assert.ok(near(m.cursor, ICON.folder), 'the menu belongs to the folder');
  const open = trackAt(PAD_AT.tap3[0]);
  assert.ok(open.cursor.x >= m.menuPos.x && open.cursor.x <= m.menuPos.x + MENU.w && open.cursor.y >= m.menuPos.y && open.cursor.y <= m.menuPos.y + MENU.itemH + MENU.pad, 'on 打開 at the tap');
  for (let f = 0; f < 1235; f++) {
    const c = trackAt(f).cursor;
    assert.ok(c.x >= 0 && c.x <= MAC.w && c.y >= 0 && c.y <= MAC.h, `frame ${f}: ${c.x},${c.y}`);
  }
});

test('every ring, press ring included, stays inside the grey pad; the two rings never touch', () => {
  assert.ok(FINGER_GAP > RING);
  let two = 0;
  for (let f = 0; f < 1235; f++) {
    const s = trackAt(f);
    for (const g of s.fingers) {
      const r = RING;
      assert.ok(g.x - r >= PAD.x && g.x + r <= PAD.x + PAD.w && g.y - r >= PAD.y && g.y + r <= PAD.y + PAD.h, `frame ${f}: ${g.x},${g.y}`);
    }
    if (s.fingers.length === 2) { two++; assert.ok(Math.hypot(s.fingers[0].x - s.fingers[1].x, s.fingers[0].y - s.fingers[1].y) > RING * 1.5); }
  }
  assert.ok(two > 80, `${two}`);
});

test('the tap selects the file two frames after the finger lands; nothing is selected before', () => {
  assert.equal(trackAt(PAD_AT.select - 1).fileSelected, false);
  assert.equal(trackAt(PAD_AT.select).fileSelected, true);
  assert.equal(PAD_AT.select - PAD_AT.tap1[0], 2);
  assert.equal(trackAt(PAD_AT.tap1[0]).fileSelected, false, 'effect after cause');
});

test('the drag starts only after the finger has held 12 frames: the ring turns solid and the file lifts then, not before', () => {
  assert.ok(PAD_AT.lift - PAD_AT.touch >= 12, 'held 0.4 s');
  for (let f = PAD_AT.touch; f < PAD_AT.lift; f++) {
    const s = trackAt(f);
    assert.equal(s.fileLifted, false, `frame ${f}`);
    assert.deepEqual(s.filePos, ICON.file);
    assert.equal(s.ringSolid, 0);
    assert.deepEqual(s.cursor, trackAt(PAD_AT.touch).cursor, 'the cursor waits too');
  }
  assert.equal(trackAt(PAD_AT.lift).fileLifted, true);
  assert.equal(trackAt(PAD_AT.lift).ringSolid, 1);
  const mid = trackAt((PAD_AT.lift + PAD_AT.dragEnd) / 2);
  assert.ok(Math.hypot(mid.filePos.x - mid.cursor.x, mid.filePos.y - mid.cursor.y) < 1e-6, 'the file is at the cursor while it is carried');
  assert.equal(trackAt(PAD_AT.drop).fileLifted, false);
  assert.equal(trackAt(PAD_AT.drop - 1).fileLifted, true);
  assert.ok(trackAt(PAD_AT.drop + 20).fileGone, 'the file is in the folder');
  assert.equal(trackAt(PAD_AT.drop - 1).fileGone, false);
});

test('the right click menu opens two frames after the two finger tap and the folder window opens from the folder when 打開 is tapped', () => {
  assert.equal(trackAt(PAD_AT.tap2[0] + 1).fingers.length, 2);
  assert.ok(trackAt(PAD_AT.tap2[0]).fingers.every((g) => g.down));
  assert.equal(PAD_AT.menu - PAD_AT.tap2[0], 2);
  assert.equal(trackAt(PAD_AT.menu - 1).menuOpen, false);
  assert.equal(trackAt(PAD_AT.menu).menuOpen, true);
  assert.equal(trackAt(PAD_AT.open - 1).menuOpen, true);
  assert.equal(trackAt(PAD_AT.open).menuOpen, false);
  assert.equal(PAD_AT.open - PAD_AT.tap3[0], 2);
  assert.equal(trackAt(PAD_AT.open - 1).folderU, 0);
  assert.ok(trackAt(PAD_AT.open + 8).folderU > 0 && trackAt(PAD_AT.open + 8).folderU < 1);
  assert.equal(trackAt(PAD_AT.open + 24).folderU, 1);
  assert.equal(trackAt(PAD_AT.open - 3).menuHover, 0, 'the cursor is on 打開 before the tap');
  const w = FOLDER_WIN;
  assert.ok(w.x >= 0 && w.x + w.w <= MAC.w && w.y >= 0 && w.y + w.h <= MAC.h);
});

test('the cursor tip is inside the folder window for every frame of the scroll, as on a Mac', () => {
  const w = FOLDER_WIN;
  for (let f = PAD_AT.scrollDown; f < 1230; f++) {
    const c = trackAt(f).cursor;
    assert.ok(c.x >= w.x && c.x <= w.x + w.w && c.y >= w.y + w.bar && c.y <= w.y + w.h, `frame ${f}: cursor ${c.x.toFixed(0)},${c.y.toFixed(0)}`);
  }
});

test('the list scrolls 1:1 with two fingers and stops with them: no inertia, and the cut at 41.0 s falls in the swipe', () => {
  assert.equal(SCROLL_GAIN, 1);
  assert.equal(trackAt(PAD_AT.scrollDown + 2).scrollY, 0);
  for (let f = PAD_AT.scrollDown; f <= PAD_AT.swipe[0]; f++) assert.equal(trackAt(f).scrollY, 0, `still while the fingers rest: frame ${f}`);
  for (let f = PAD_AT.swipe[0] + 1; f < 1235; f++) {
    const dScroll = trackAt(f).scrollY - trackAt(f - 1).scrollY;
    const dFinger = trackAt(f - 2).fingers[0].y - trackAt(f - 1).fingers[0].y;
    assert.ok(Math.abs(dScroll - SCROLL_GAIN * dFinger) < 1e-6, `frame ${f}`);
  }
  const s = trackAt(1229);
  assert.ok(s.fingers.length === 2 && s.fingers[0].down && s.fingers[1].down);
  assert.ok(trackAt(1230).scrollY - trackAt(1229).scrollY > 1, 'the list is still moving at the cut');
  assert.ok(trackAt(1229).scrollY > 120, `${trackAt(1229).scrollY}`);
  assert.ok(trackAt(1229).scrollY < FOLDER_WIN.row * 6, 'inside the list');
});

test('the finger rings show from 868, the cursor only after the finger has landed, and nothing of this shows before the 3D shot', () => {
  for (let f = 0; f < PAD_AT.fingersIn; f++) {
    const s = trackAt(f);
    assert.equal(s.fingerOpacity, 0);
    assert.equal(s.cursorOpacity, 0);
  }
  assert.ok(trackAt(PAD_AT.fingersIn + 4).fingerOpacity === 1);
  assert.equal(trackAt(PAD_AT.move1[0]).cursorOpacity, 0, 'the cursor follows the finger, not the other way');
  assert.equal(trackAt(PAD_AT.move1[0] + 8).cursorOpacity, 1);
});

test('the events of the pad are in order and have the frames the storyboard 21 needs', () => {
  const frames = PAD_EVENTS.map((e) => e.frame);
  assert.deepEqual([...frames].sort((a, b) => a - b), frames);
  assert.ok(frames[0] >= 936 && frames[frames.length - 1] < 1131);
});
