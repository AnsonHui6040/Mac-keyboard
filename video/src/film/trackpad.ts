/**
 * Shot 21: what the fingers do on the trackpad page and what that does on the Mac. Everything is derived from the finger paths:
 * the cursor is its start plus GAIN times the one finger's movement, one frame late; the list scrolls 1:1 with two fingers, with no
 * inertia, so it stops when they stop. Frames come from PAD_AT in events.ts. Pure: node can import it.
 */
import { PAD_AT } from './events.ts';
import { CURSOR_START, FOLDER_WIN, ICON, MAC, MENU, MENU_OPEN_TIP, PAD } from './layout.ts';

export const GAIN = 1.5;
export const SCROLL_GAIN = 1;
/** Radius of the press ring (the largest thing a finger draws). The ring itself is 106 wide: 64 px in the frame at the size of shot 21. */
export const RING = 70;
export const RING_DIAMETER = 106;
/** The second finger sits this far to the right of the first. */
export const FINGER_GAP = 200;

type P = { x: number; y: number };
const sub = (a: P, b: P): P => ({ x: a.x - b.x, y: a.y - b.y });
/** The finger position that puts the cursor at `cursor`, given where the finger was and the cursor was. */
const fin = (f: P, from: P, to: P): P => ({ x: f.x + (to.x - from.x) / GAIN, y: f.y + (to.y - from.y) / GAIN });

export const menuTopLeft = (cursor: P): P => ({ x: cursor.x + MENU.offset.x, y: Math.min(cursor.y + MENU.offset.y, MAC.h - 12 - MENU.h) });
const OPEN_TIP: P = (() => { const m = menuTopLeft(ICON.folder); return { x: m.x + MENU_OPEN_TIP.x, y: m.y + MENU_OPEN_TIP.y }; })();

export const F0: P = { x: 150, y: 620 };
const F1 = fin(F0, CURSOR_START, ICON.file);
const F2 = fin(F1, ICON.file, ICON.folder);
const F3 = fin(F2, ICON.folder, OPEN_TIP);
const S0: P = { x: 190, y: 650 };
const S1: P = { x: 190, y: 370 };
const TAP2: P = { x: FINGER_GAP, y: 10 };
const SCROLL2: P = { x: FINGER_GAP, y: 0 };

type Seg = { t0: number; t1: number; a: P; b: P; ease: boolean; two?: P };
const A = PAD_AT;
const SEGS: Seg[] = [
  { t0: A.move1[0], t1: A.move1[1], a: F0, b: F1, ease: true },                    // 21b slide to the file
  { t0: A.tap1[0], t1: A.tap1[1], a: F1, b: F1, ease: false },                     // 21c tap
  { t0: A.touch, t1: A.lift, a: F1, b: F1, ease: false },                          // 21d touch and hold still
  { t0: A.lift, t1: A.dragEnd, a: F1, b: F2, ease: true },                         // 21d carry to the folder
  { t0: A.dragEnd, t1: A.drop, a: F2, b: F2, ease: false },                        // 21d hold, then let go at the drop
  { t0: A.tap2[0], t1: A.tap2[1], a: F2, b: F2, ease: false, two: TAP2 },          // 21e two finger tap: the menu
  { t0: A.move3[0], t1: A.move3[1], a: F2, b: F3, ease: true },                    // 21e to 打開
  { t0: A.tap3[0], t1: A.tap3[1], a: F3, b: F3, ease: false },                     // 21e tap 打開
  { t0: A.scrollDown, t1: A.swipe[0], a: S0, b: S0, ease: false, two: SCROLL2 },   // 21f two fingers down
  { t0: A.swipe[0], t1: A.swipe[1], a: S0, b: S1, ease: true, two: SCROLL2 },      // 21f swipe up, still going at the cut
];

const GLIDE = 8;
const smooth = (u: number): number => (u <= 0 ? 0 : u >= 1 ? 1 : u * u * (3 - 2 * u));
const lerp = (a: P, b: P, u: number): P => ({ x: a.x + (b.x - a.x) * u, y: a.y + (b.y - a.y) * u });

export type Finger = { x: number; y: number; down: boolean };
/** Finger 1 at a frame: where it is and whether it touches. It glides to the next place while lifted. */
const finger1 = (frame: number): Finger => {
  let i = -1;
  for (let k = 0; k < SEGS.length; k++) if (SEGS[k].t0 <= frame) i = k;
  if (i < 0) return { ...F0, down: false };
  const s = SEGS[i];
  if (frame < s.t1) return { ...lerp(s.a, s.b, s.ease ? smooth((frame - s.t0) / (s.t1 - s.t0 - 1)) : 0), down: true };
  const next = SEGS[i + 1];
  if (!next) return { ...s.b, down: false };
  const dur = Math.min(GLIDE, next.t0 - s.t1);
  const u = dur <= 0 ? 1 : smooth((frame - (next.t0 - dur)) / dur);
  return { ...lerp(s.b, next.a, u), down: false };
};
const segAt = (frame: number): Seg | undefined => SEGS.find((s) => frame >= s.t0 && frame < s.t1);
const twoAt = (frame: number): Seg | undefined => SEGS.find((s) => s.two && frame >= s.t0 - 2 && frame < s.t1 + 2);

const CURSOR: P[] = [];
const cursorAt = (frame: number): P => {
  if (CURSOR.length === 0) {
    CURSOR[0] = { ...CURSOR_START };
    for (let f = 1; f <= 1400; f++) {
      const a = finger1(f - 2);
      const b = finger1(f - 1);
      const one = a.down && b.down && !segAt(f - 2)?.two && !segAt(f - 1)?.two;
      CURSOR[f] = one ? { x: CURSOR[f - 1].x + GAIN * (b.x - a.x), y: CURSOR[f - 1].y + GAIN * (b.y - a.y) } : { ...CURSOR[f - 1] };
    }
  }
  return CURSOR[Math.max(0, Math.min(1400, frame))];
};

export type TrackState = {
  fingers: Finger[];
  fingerOpacity: number;
  /** 0 to 1: the ring is filled in once the file is carried. */
  ringSolid: number;
  cursor: P;
  cursorOpacity: number;
  /** 0 to 1: the cursor shrinks and shows a ring for a few frames after a click and while the file is carried. */
  cursorPress: number;
  fileSelected: boolean;
  fileLifted: boolean;
  /** Where the file icon is: on the desktop, then at the cursor while it is carried, then on the folder. */
  filePos: P;
  /** 0 to 1: the file shrinks into the folder after the drop. */
  fileDrop: number;
  fileGone: boolean;
  menuOpen: boolean;
  menuPos: P;
  /** The menu row under the cursor, or -1. */
  menuHover: number;
  /** 0 to 1: the folder window opens from the folder icon. */
  folderU: number;
  scrollY: number;
};

const FOLDER_OPEN_FRAMES = 16;
const DROP_FRAMES = 10;
const pulse = (frame: number, from: number): number => (frame >= from && frame < from + 6 ? 1 - (frame - from) / 6 : 0);

export const trackAt = (frame: number): TrackState => {
  const f1 = finger1(frame);
  const fingers: Finger[] = [];
  if (frame >= A.fingersIn) {
    fingers.push(f1);
    const two = twoAt(frame);
    if (two) {
      const s = segAt(frame);
      fingers.push({ x: f1.x + two.two!.x, y: f1.y + two.two!.y, down: !!s && frame >= s.t0 && frame < s.t1 });
    }
  }
  const cursor = cursorAt(frame);
  const lifted = frame >= A.lift && frame < A.drop;
  const dropped = frame >= A.drop;
  const menuOpen = frame >= A.menu && frame < A.open;
  const menuPos = menuTopLeft(cursorAt(A.menu));
  let menuHover = -1;
  if (menuOpen && cursor.x >= menuPos.x && cursor.x <= menuPos.x + MENU.w) {
    const i = Math.floor((cursor.y - menuPos.y - MENU.pad) / MENU.itemH);
    if (i >= 0 && i < MENU.items.length) menuHover = i;
  }
  const dropU = dropped ? Math.min(1, (frame - A.drop) / DROP_FRAMES) : 0;
  const scrolling = frame > A.swipe[0] ? Math.max(0, SCROLL_GAIN * (S0.y - finger1(frame - 1).y)) : 0;
  return {
    fingers,
    fingerOpacity: frame >= A.fingersIn ? Math.min(1, (frame - A.fingersIn + 1) / 4) : 0,
    ringSolid: lifted ? 1 : 0,
    cursor,
    cursorOpacity: frame >= A.move1[0] + 2 ? Math.min(1, (frame - A.move1[0] - 1) / 4) : 0,
    cursorPress: lifted ? 1 : Math.max(pulse(frame, A.select), pulse(frame, A.open)),
    fileSelected: frame >= A.select && !dropped,
    fileLifted: lifted,
    filePos: lifted ? cursor : dropped ? { ...ICON.folder } : { ...ICON.file },
    fileDrop: dropU,
    fileGone: dropped && dropU >= 1,
    menuOpen,
    menuPos,
    menuHover,
    folderU: frame >= A.open ? Math.min(1, (frame - A.open) / FOLDER_OPEN_FRAMES) : 0,
    scrollY: scrolling,
  };
};
export { FOLDER_WIN };
