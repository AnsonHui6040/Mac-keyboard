/**
 * What the phone and the Mac look like at a frame, worked out from the press table (events.ts) and the trackpad (trackpad.ts).
 * Pure: no JSX, node can import it.
 */
import { QUICK_BAR, quickCenter, quickScrollFor } from '../intro/layout.ts';
import { STROKES, partialStroke, strokePoint } from '../intro/ink.ts';
import { CHAPTER_START, CONNECT_AT, CUTS, HW_CANDIDATES_AT, INK, LOGIN, MAC_DELAY, PAD_AT, PRESSES, SWIPES, actFrame, chapterOf, macDelayOf, type Chapter, type Fx, type Press } from './events.ts';
import { centerOf, draftRect, hwCandidateRect, keyRect, kbTop, quickCandidateRect, toggleRect, type KbName, type R } from './layout.ts';
import { LOGIN_FIELDS } from './layout.ts';
import { textWidth } from './metrics.ts';
import { trackAt, type TrackState } from './trackpad.ts';

export const DRAFT_TEXT = { size: 31, weight: 400 as const, padLeft: 14 };

type S = { ime: 'en' | 'hw' | 'quick' | 'pad'; mode: 'live' | 'draft'; shift: boolean; draft: string; caret: number; code: string; picked: boolean; blocked: boolean };
const START: S = { ime: 'en', mode: 'live', shift: false, draft: '', caret: 0, code: '', picked: false, blocked: false };

const insert = (s: S, text: string): S => ({ ...s, draft: s.draft.slice(0, s.caret) + text + s.draft.slice(s.caret), caret: s.caret + text.length });

const apply = (s: S, fx: Fx): { s: S; add: string } => {
  let n = { ...s };
  let add = '';
  switch (fx.k) {
    case 'char': n.shift = false; if (s.mode === 'live') add = fx.c; else n = insert(n, fx.c); break;
    case 'shift': n.shift = !s.shift; break;
    case 'enter': if (s.mode === 'live') add = '\n'; else n = insert(n, '\n'); break;
    case 'mode': n.mode = fx.to; break;
    case 'ime': n.ime = fx.to; n.picked = false; break;
    case 'caret': n.caret = Math.min(s.draft.length, fx.index); break;
    case 'pick': n = insert(n, fx.text); n.code = ''; n.picked = true; break;
    case 'code': n.code += fx.c; break;
    case 'send': add = s.draft; n.draft = ''; n.caret = 0; break;
    case 'cut': if (fx.ime) n.ime = fx.ime; if (fx.blocked) n.blocked = true; break;
    default: break;
  }
  return { s: n, add };
};

type Item = { t: number; fx: Fx; press?: Press };
const ITEMS: Item[] = [...PRESSES.map((p) => ({ t: actFrame(p), fx: p.fx, press: p })), ...CUTS.map((c) => ({ t: c.t, fx: c.fx }))].sort((a, b) => a.t - b.t);

export type MacOp = { frame: number; press: Press; add: string; chapter: Chapter };
let opsCache: MacOp[] | null = null;
/** Every change of the Mac text: the frame it shows, the press it comes from, what is added. */
export const macOps = (): MacOp[] => {
  if (opsCache) return opsCache;
  const out: MacOp[] = [];
  const state: S[] = [START, START, START, START];
  for (const it of ITEMS) {
    const c = chapterOf(it.t);
    const r = apply(state[c], it.fx);
    state[c] = r.s;
    if (r.add && it.press) out.push({ frame: it.t + macDelayOf(it.press), press: it.press, add: r.add, chapter: c });
  }
  opsCache = out;
  return out;
};

/** The text of the document of a chapter (0 the first, 3 the empty one of shot 30) at a frame. */
export const macTextAt = (frame: number, chapter: Chapter = chapterOf(frame)): string =>
  macOps().filter((o) => o.chapter === chapter && o.frame <= frame).map((o) => o.add).join('');
const lastMacChange = (frame: number, chapter: Chapter): number => {
  let last = -99;
  for (const o of macOps()) if (o.chapter === chapter && o.frame <= frame) last = o.frame;
  return last;
};

// --- quick candidates, the order of iOS/RemoteKeyboardExtension/Resources/quick-table.txt ---
export const QUICK_CANDIDATES: Record<string, string[]> = {
  h: ['竹'],
  ha: ['白', '昏', '徇', '香', '舶', '筍', '箔', '箸', '稽'],
  e: ['水'],
  eu: [...'氾汕沈沉沅沌況泡流洗洸洎浥淹淘港湘溉湄滬澆澠'],
};
/** The three flicks together scroll candidate 13 (淹) to image x 37, the picture of kb-quickComposing.png. */
export const QUICK_SCROLL_TOTAL = quickScrollFor(2, 13, 37);
const SWIPE_FROM_X = 650;
const ease = (u: number): number => (u <= 0 ? 0 : u >= 1 ? 1 : u * u * (3 - 2 * u));
export const quickScrollAt = (frame: number): number => {
  if (frame >= SWIPES[SWIPES.length - 1].to) return QUICK_SCROLL_TOTAL;
  let s = 0;
  for (const w of SWIPES) s += (QUICK_SCROLL_TOTAL / SWIPES.length) * ease((frame - w.from) / (w.to - w.from));
  return s;
};

// --- the phone ---
export type PhoneState = {
  chapter: Chapter;
  kb: KbName;
  status: 'none' | 'connected' | 'blocked';
  /** Frame the status last changed, for the fade. */
  statusSince: number;
  shift: boolean;
  draft: string;
  caret: number;
  code: string;
  candidates: string[];
  scroll: number;
  inkOn: boolean;
  hwCandidates: boolean;
  /** The press whose key is down at this frame, if any. */
  pressed: Press | null;
};

export const phoneAt = (frame: number): PhoneState => {
  const chapter = chapterOf(frame);
  let s = START;
  for (const it of ITEMS) {
    if (it.t > frame) break;
    if (chapterOf(it.t) !== chapter) continue;
    s = apply(s, it.fx).s;
  }
  const kb: KbName = s.ime === 'pad' ? 'trackpad' : s.ime === 'hw' ? 'handwriting' : s.ime === 'quick' ? 'quick' : s.mode === 'live' ? (s.blocked ? 'blocked' : 'connected') : 'draft';
  const inkOn = s.ime === 'hw' && !s.picked;
  const status = chapter === 0 ? (frame < CONNECT_AT ? 'none' : 'connected') : s.blocked ? 'blocked' : 'connected';
  const statusSince = chapter === 0 ? CONNECT_AT : s.blocked ? LOGIN.blocked : CHAPTER_START[chapter];
  const pressed = PRESSES.find((p) => frame >= p.t && frame < p.t + p.hold && p.chapter === chapter) ?? null;
  return {
    chapter, kb, status, statusSince, shift: s.shift, draft: s.draft, caret: s.caret, code: s.code,
    candidates: s.ime === 'quick' ? QUICK_CANDIDATES[s.code] ?? [] : [],
    scroll: s.ime === 'quick' && s.code === 'eu' ? quickScrollAt(frame) : 0,
    inkOn, hwCandidates: inkOn && frame >= HW_CANDIDATES_AT, pressed,
  };
};

// --- where a press lands, on the phone (local coordinates) ---
/** x of the caret in the draft field and its text, as drawn. */
export const draftCaretX = (kb: KbName, draft: string, caret: number): number =>
  draftRect(kb).x + DRAFT_TEXT.padLeft + textWidth(draft.slice(0, caret).replace(/\n/g, '⏎'), DRAFT_TEXT.size, DRAFT_TEXT.weight);

export const pressRect = (p: Press): R => {
  if (p.key === 'toggle:draft') return toggleRect(p.kb, 'draft');
  if (p.key.startsWith('cand:')) return hwCandidateRect(p.kb, Number(p.key.slice(5)));
  if (p.key.startsWith('qcand:')) {
    const before = phoneAt(p.t - 1);
    return quickCandidateRect(p.kb, before.code.length, Number(p.key.slice(6)), before.scroll);
  }
  if (p.key.startsWith('draft:')) {
    const before = phoneAt(p.t - 1);
    const f = draftRect(p.kb);
    const x = draftCaretX(p.kb, before.draft, Number(p.key.slice(6)));
    return { x: x - 14, y: f.y, w: 28, h: f.h };
  }
  return keyRect(p.kb, p.key);
};

// --- the finger on the phone's keyboard pages (the pad of shot 21 is trackpad.ts) ---
type Pt = { x: number; y: number };
type Seg = { t0: number; t1: number; a: Pt; path?: (u: number) => Pt };
const SEGS: Seg[] = [];
for (const p of PRESSES) SEGS.push({ t0: p.t, t1: p.t + p.hold, a: centerOf(pressRect(p)) });
{
  const top = kbTop('handwriting');
  STROKES.forEach((s, i) => SEGS.push({
    t0: INK[i].from, t1: INK[i].to, a: { x: s[0][0], y: top + s[0][1] },
    path: (u) => { const [x, y] = strokePoint(s, u); return { x, y: top + y }; },
  }));
  const y = kbTop('quick') + QUICK_BAR.y;
  const d = QUICK_SCROLL_TOTAL / SWIPES.length;
  for (const w of SWIPES) SEGS.push({ t0: w.from, t1: w.to, a: { x: SWIPE_FROM_X, y }, path: (u) => ({ x: SWIPE_FROM_X - d * ease(u), y }) });
}
SEGS.sort((a, b) => a.t0 - b.t0);
const segEnd = (s: Seg): Pt => (s.path ? s.path(1) : s.a);
const GLIDE = 8;
const GROUPS = [0, 1, 2, 3].map((c) => {
  const segs = SEGS.filter((s) => chapterOf(s.t0) === c);
  return { segs, from: segs[0].t0 - 6, to: segs[segs.length - 1].t1 + 6 };
});

export type KeyFinger = { x: number; y: number; visible: boolean; press: number; opacity: number };
const lerp = (a: number, b: number, u: number): number => a + (b - a) * u;
/** The finger of the keyboard pages: one group per chapter, fading in 6 frames before its first move and out 6 frames after its last. */
export const fingerAt = (frame: number): KeyFinger => {
  const g = GROUPS.find((x) => frame >= x.from && frame < x.to);
  if (!g) return { x: 0, y: 0, visible: false, press: 0, opacity: 0 };
  const opacity = Math.min(1, (frame - g.from + 1) / 4, (g.to - frame) / 4);
  const segs = g.segs;
  let i = -1;
  for (let k = 0; k < segs.length; k++) if (segs[k].t0 <= frame) i = k;
  if (i < 0) return { ...segs[0].a, visible: true, press: 0, opacity };
  const s = segs[i];
  if (frame < s.t1) {
    const pos = s.path ? s.path(Math.min(1, (frame - s.t0) / Math.max(1, s.t1 - s.t0))) : s.a;
    return { ...pos, visible: true, press: 1, opacity };
  }
  const end = segEnd(s);
  const next = segs[i + 1];
  if (!next) return { ...end, visible: true, press: 0, opacity };
  const dur = Math.min(GLIDE, next.t0 - s.t1);
  const u = dur <= 0 ? 1 : ease((frame - (next.t0 - dur)) / dur);
  return { x: lerp(end.x, next.a.x, u), y: lerp(end.y, next.a.y, u), visible: true, press: 0, opacity };
};

/** The strokes drawn so far at a frame: each stroke's points up to its progress. */
export const inkAt = (frame: number): Pt[][] => {
  const out: Pt[][] = [];
  STROKES.forEach((s, i) => {
    if (frame < INK[i].from) return;
    const u = (frame - INK[i].from) / (INK[i].to - INK[i].from);
    out.push(partialStroke(s, u).map(([x, y]) => ({ x, y })));
  });
  return out;
};

// --- the Mac ---
const smooth = ease;
export const LOGIN_CURSOR = { start: { x: 820, y: 560 }, target: { x: LOGIN_FIELDS.password.x + 300, y: LOGIN_FIELDS.password.y + 32 } } as const;

export type MacState = {
  screen: 'doc' | 'login' | 'remote' | 'doc2';
  lines: string[];
  caretOn: boolean;
  /** Mac pointer, or null when it is not on the screen. */
  cursor: { x: number; y: number; opacity: number; press: number } | null;
  track: TrackState | null;
  loginFocused: boolean;
  loginValue: string;
  dots: number;
};

export const macAt = (frame: number): MacState => {
  const chapter = chapterOf(frame);
  const text = macTextAt(frame, chapter);
  const changed = lastMacChange(frame, chapter);
  const caretOn = frame - changed < 12 || Math.floor(frame / 15) % 2 === 0;
  const screen = (['doc', 'login', 'remote', 'doc2'] as const)[chapter];
  const track = chapter === 0 && frame >= PAD_AT.fingersIn ? trackAt(frame) : null;
  let cursor: MacState['cursor'] = null;
  if (track) cursor = { x: track.cursor.x, y: track.cursor.y, opacity: track.cursorOpacity, press: track.cursorPress };
  if (chapter === 1) {
    const u = smooth((frame - LOGIN.cursorFrom) / (LOGIN.arrive - LOGIN.cursorFrom));
    const p = frame - LOGIN.click;
    cursor = {
      x: LOGIN_CURSOR.start.x + (LOGIN_CURSOR.target.x - LOGIN_CURSOR.start.x) * u,
      y: LOGIN_CURSOR.start.y + (LOGIN_CURSOR.target.y - LOGIN_CURSOR.start.y) * u,
      opacity: 1, press: p >= 0 && p < 6 ? 1 - p / 6 : 0,
    };
  }
  const dots = chapter === 2 ? PRESSES.filter((p) => p.chapter === 2 && p.t + MAC_DELAY <= frame).length : 0;
  return { screen, lines: text.split('\n'), caretOn, cursor, track, loginFocused: chapter === 1 && frame >= LOGIN.focus, loginValue: '', dots };
};
