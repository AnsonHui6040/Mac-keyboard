/**
 * Scene 4: what the fingers do on the trackpad, and what that does on the Mac. Everything is derived from the finger paths:
 * the cursor is its start plus GAIN times the finger's movement, one frame late. Pure: node can import it.
 */
import { DESKTOP, DISPLAY, KB, MENU, PHONE, kbTop, type R } from './layout.ts';

export const GAIN = 1.5;
export const SCROLL_GAIN = 1.8;
/** The grey pad on the canvas. */
export const PAD: R = { x: PHONE.x + KB.trackpad.keys.pad.x, y: kbTop('trackpad') + KB.trackpad.keys.pad.y, w: KB.trackpad.keys.pad.w, h: KB.trackpad.keys.pad.h };

type P = { x: number; y: number };
const C0: P = DESKTOP.cursorStart;
const FILE: P = DESKTOP.file;
const DROP: P = { x: 790, y: 650 };
const WIN_AT: P = { x: 400, y: 330 };
const sub = (a: P, b: P): P => ({ x: a.x - b.x, y: a.y - b.y });
const fin = (a: P, cursor: P): P => ({ x: a.x + cursor.x / GAIN, y: a.y + cursor.y / GAIN });

// Finger positions: each move ends where the cursor must be, so the finger path is the wanted cursor path divided by GAIN.
const F0: P = { x: 1380, y: 470 };
const F1 = fin(F0, sub(FILE, C0));
const F2 = fin(F1, sub(DROP, FILE));
const F5 = fin(F2, sub(WIN_AT, DROP));
const S0: P = { x: 1380, y: 620 };
const S1: P = { x: 1380, y: 460 };
/** The second finger sits this far from the first: more than two ring diameters (ring radius 56), so the rings never touch. */
export const FINGER_GAP = 130;
export const RING_RADIUS = 56;
const SECOND = { tap: { x: FINGER_GAP, y: 10 }, scroll: { x: FINGER_GAP, y: 0 } };

type Seg = { t0: number; t1: number; a: P; b: P; ease: boolean; two?: P };
const SEGS: Seg[] = [
  { t0: 957, t1: 1015, a: F0, b: F1, ease: true },                       // 4b: slide to the file
  { t0: 1030, t1: 1034, a: F1, b: F1, ease: false },                      // 4c: tap
  { t0: 1085, t1: 1099, a: F1, b: F1, ease: false },                      // 4d: touch and hold still
  { t0: 1099, t1: 1146, a: F1, b: F2, ease: true },                       // 4d: drag to the folder
  { t0: 1146, t1: 1152, a: F2, b: F2, ease: false },                      // 4d: hold, then let go at 1152
  { t0: 1206, t1: 1210, a: F2, b: F2, ease: false, two: SECOND.tap },     // 4e: two finger tap on the file: the menu opens
  { t0: 1226, t1: 1230, a: F2, b: F2, ease: false },                      // 4e: one tap, finger and cursor stay: the cursor is outside the menu, it closes
  { t0: 1240, t1: 1262, a: F2, b: F5, ease: true },                       // 4f: from the file onto the document window
  { t0: 1270, t1: 1272, a: S0, b: S0, ease: false, two: SECOND.scroll },  // 4f: two fingers down
  { t0: 1272, t1: 1304, a: S0, b: S1, ease: true, two: SECOND.scroll },   // 4f: swipe up
  { t0: 1304, t1: 1308, a: S1, b: S1, ease: false, two: SECOND.scroll },
];

export const FINGERS_FROM = 952;
export const FINGERS_TO = 1316;
const GLIDE = 8;
const smooth = (u: number): number => (u <= 0 ? 0 : u >= 1 ? 1 : u * u * (3 - 2 * u));
const lerp = (a: P, b: P, u: number): P => ({ x: a.x + (b.x - a.x) * u, y: a.y + (b.y - a.y) * u });

export type TrackFinger = { x: number; y: number; down: boolean };
/** Finger 1 at a frame: where it is and whether it touches. */
const finger1 = (frame: number): TrackFinger => {
  let i = -1;
  for (let k = 0; k < SEGS.length; k++) if (SEGS[k].t0 <= frame) i = k;
  if (i < 0) return { ...F0, down: false };
  const s = SEGS[i];
  if (frame < s.t1) {
    return { ...lerp(s.a, s.b, s.ease ? smooth((frame - s.t0) / (s.t1 - s.t0 - 1)) : 0), down: true };
  }
  const next = SEGS[i + 1];
  if (!next) return { ...s.b, down: false };
  const dur = Math.min(GLIDE, next.t0 - s.t1);
  const u = dur <= 0 ? 1 : smooth((frame - (next.t0 - dur)) / dur);
  return { ...lerp(s.b, next.a, u), down: false };
};
const segAt = (frame: number): Seg | undefined => SEGS.find((s) => frame >= s.t0 && frame < s.t1);
const twoAt = (frame: number): P | undefined => SEGS.find((s) => s.two && frame >= s.t0 - 2 && frame < s.t1 + 2)?.two;

export type TrackEvent = { frame: number; what: 'tap' | 'touch' | 'tap2' | 'select' | 'lift' | 'drop' | 'menu' | 'dismiss' };
export const TRACKPAD_EVENTS: readonly TrackEvent[] = [
  { frame: 1030, what: 'tap' },
  { frame: 1032, what: 'select' },
  { frame: 1085, what: 'touch' },
  { frame: 1097, what: 'lift' },
  { frame: 1152, what: 'drop' },
  { frame: 1206, what: 'tap2' },
  { frame: 1208, what: 'menu' },
  { frame: 1226, what: 'tap' },
  { frame: 1228, what: 'dismiss' },
];
const at = (what: TrackEvent['what'], n = 0): number => TRACKPAD_EVENTS.filter((e) => e.what === what)[n].frame;

// The cursor: integrate GAIN times the one finger's movement, one frame behind. Two fingers scroll and leave the cursor alone.
const CURSOR: P[] = [];
const cursorAt = (frame: number): P => {
  if (CURSOR.length === 0) {
    CURSOR[0] = { ...C0 };
    for (let f = 1; f <= 1400; f++) {
      const a = finger1(f - 2);
      const b = finger1(f - 1);
      const sa = segAt(f - 2);
      const sb = segAt(f - 1);
      const one = a.down && b.down && !sa?.two && !sb?.two;
      CURSOR[f] = one ? { x: CURSOR[f - 1].x + GAIN * (b.x - a.x), y: CURSOR[f - 1].y + GAIN * (b.y - a.y) } : { ...CURSOR[f - 1] };
    }
  }
  return CURSOR[Math.max(0, Math.min(1400, frame))];
};

/** The menu opens 14 px right of and 8 px below the cursor tip; its bottom may not pass the Mac screen (12 px margin), so it moves up. */
export const MENU_OFFSET = { x: 14, y: 8 } as const;
export const menuTopLeft = (cursor: P): P => {
  const bottom = DISPLAY.y + DISPLAY.h - DISPLAY.inset - 12;
  return { x: cursor.x + MENU_OFFSET.x, y: Math.min(cursor.y + MENU_OFFSET.y, bottom - MENU.h) };
};

export type TrackState = {
  fingers: TrackFinger[];
  fingerOpacity: number;
  cursor: P;
  cursorVisible: boolean;
  /** 0 to 1: the cursor shrinks and shows a ring while the button is down. */
  cursorPress: number;
  fileSelected: boolean;
  filePos: P;
  fileLifted: boolean;
  menuOpen: boolean;
  /** Top-left of the menu: right of the cursor, pushed up when it would end below the Mac screen. */
  menuPos: P;
  scrollY: number;
  /** TextEdit window scale: 1 until 912, 0.62 from 936. */
  winScale: number;
};

export const WIN_SCALE_FROM = 912;
export const WIN_SCALE_TO = 936;
export const WIN_SCALE = 0.62;
export const winScaleAt = (frame: number): number => (frame < WIN_SCALE_FROM ? 1 : 1 + (WIN_SCALE - 1) * smooth((frame - WIN_SCALE_FROM) / (WIN_SCALE_TO - WIN_SCALE_FROM)));

export const trackpadState = (frame: number): TrackState => {
  const shown = frame >= FINGERS_FROM && frame < FINGERS_TO;
  const fingers: TrackFinger[] = [];
  if (shown) {
    const f1 = finger1(frame);
    fingers.push(f1);
    const two = twoAt(frame);
    if (two) {
      const s = segAt(frame) ?? SEGS.find((x) => x.two && frame >= x.t0 - 2 && frame < x.t1 + 2)!;
      fingers.push({ x: f1.x + two.x, y: f1.y + two.y, down: frame >= s.t0 && frame < s.t1 });
    }
  }
  const fingerOpacity = shown ? Math.min(1, (frame - FINGERS_FROM + 1) / 4, (FINGERS_TO - frame) / 4) : 0;
  const cursor = cursorAt(frame);
  const select = at('select');
  const lift = at('lift');
  const drop = at('drop');
  const open = at('menu');
  const dismiss = at('dismiss');
  const fileLifted = frame >= lift && frame < drop;
  const pulse = (from: number): number => (frame >= from && frame < from + 6 ? 1 - (frame - from) / 6 : 0);
  const cursorPress = fileLifted ? 1 : Math.max(pulse(select), pulse(dismiss));
  const start = SEGS.find((s) => s.t0 === 1270)!;
  const y1 = finger1(frame - 1).y;
  const scrolling = frame >= 1271 ? Math.max(0, SCROLL_GAIN * (start.a.y - y1)) : 0;
  return {
    fingers,
    fingerOpacity,
    cursor,
    cursorVisible: frame >= 950 && frame < 1320,
    cursorPress,
    fileSelected: frame >= select,
    filePos: fileLifted ? cursor : frame >= drop ? cursorAt(drop) : { ...FILE },
    fileLifted,
    menuOpen: frame >= open && frame < dismiss,
    menuPos: menuTopLeft(cursorAt(open)),
    scrollY: scrolling,
    winScale: winScaleAt(frame),
  };
};
