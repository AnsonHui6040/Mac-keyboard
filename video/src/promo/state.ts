/**
 * What the phone, the three computers and the finger look like at a frame of the v0.2 promo, worked out from the press table
 * (events.ts) and the trackpad (film/trackpad.ts). The algorithms are those of film/state.ts. Pure: no JSX, node can import it.
 */
import { QUICK_BAR } from '../intro/layout.ts';
import { KB } from '../intro/layout.ts';
import { STROKES, partialStroke, strokePoint } from '../intro/ink.ts';
import { QUICK_CANDIDATES, QUICK_SCROLL_TOTAL, draftCaretX, type KeyFinger, type MacState, type PhoneState } from '../film/state.ts';
import { centerOf, draftRect, hwCandidateRect, kbTop, keyRect, onPhone, quickCandidateRect, toggleRect, STATUS_CELL, type KbName, type R } from '../film/layout.ts';
import { trackAt, type TrackState } from '../film/trackpad.ts';
import { CUTS_FX, HW_CANDIDATES_AT, INK, MAC_DELAY, PRESSES, SWIPES, actFrame, hostAt, type CutFx, type Host, type PromoFx, type PromoPress } from './events.ts';
import { SEGMENTS, padFrame, seg } from './timeline.ts';

export type { Host, KeyFinger };

type S = { ime: 'en' | 'hw' | 'quick' | 'pad'; mode: 'live' | 'draft'; shift: boolean; draft: string; caret: number; code: string; picked: boolean };
const START: S = { ime: 'en', mode: 'live', shift: false, draft: '', caret: 0, code: '', picked: false };
const insert = (s: S, text: string): S => ({ ...s, draft: s.draft.slice(0, s.caret) + text + s.draft.slice(s.caret), caret: s.caret + text.length });

const apply = (s: S, fx: PromoFx | CutFx): { s: S; add: string } => {
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
    case 'cut':
      n.ime = fx.ime;
      if ('mode' in fx) { n.mode = fx.mode; n.draft = ''; n.caret = 0; n.code = ''; n.picked = false; n.shift = false; }
      break;
    default: break;
  }
  return { s: n, add };
};

type Item = { t: number; fx: PromoFx | CutFx; press?: PromoPress };
const ITEMS: Item[] = [...PRESSES.map((p) => ({ t: actFrame(p), fx: p.fx, press: p })), ...CUTS_FX.map((c) => ({ t: c.t, fx: c.fx }))].sort((a, b) => a.t - b.t);

/** Every change of the text of a computer: the frame it shows, which computer, what is added. The host is the one connected when the press came. */
type Op = { frame: number; host: Host; add: string };
const OPS: Op[] = (() => {
  const out: Op[] = [];
  let s = START;
  for (const it of ITEMS) {
    const r = apply(s, it.fx);
    s = r.s;
    if (r.add) out.push({ frame: it.t + MAC_DELAY, host: hostAt(it.t), add: r.add });
  }
  return out;
})();

/** The text of a computer at a frame. A draft arrives whole in one frame, so Linux's paste of 香港 is one frame too. */
export const docAt = (host: Host, frame: number): { lines: string[]; caretOn: boolean } => {
  const mine = OPS.filter((o) => o.host === host && o.frame <= frame);
  const text = mine.map((o) => o.add).join('');
  const changed = mine.length ? mine[mine.length - 1].frame : -99;
  const caretOn = frame - changed < 12 || Math.floor(frame / 15) % 2 === 0;
  return { lines: text.split('\n'), caretOn };
};

// --- the quick page scroll: the three flicks together ---
const SWIPE_FROM_X = 650;
const ease = (u: number): number => (u <= 0 ? 0 : u >= 1 ? 1 : u * u * (3 - 2 * u));
const quickScrollAt = (frame: number): number => {
  if (frame >= SWIPES[SWIPES.length - 1].to) return QUICK_SCROLL_TOTAL;
  let s = 0;
  for (const w of SWIPES) s += (QUICK_SCROLL_TOTAL / SWIPES.length) * ease((frame - w.from) / (w.to - w.from));
  return s;
};

// --- the phone ---
export const promoPhoneAt = (frame: number): PhoneState => {
  let s = START;
  for (const it of ITEMS) {
    if (it.t > frame) break;
    s = apply(s, it.fx).s;
  }
  const kb: KbName = s.ime === 'pad' ? 'trackpad' : s.ime === 'hw' ? 'handwriting' : s.ime === 'quick' ? 'quick' : s.mode === 'live' ? 'connected' : 'draft';
  const inkOn = s.ime === 'hw' && !s.picked;
  const pressed = PRESSES.find((p) => frame >= p.t && frame < p.t + p.hold) ?? null;
  return {
    chapter: 0, kb, status: 'connected', host: hostAt(frame), shift: s.shift, draft: s.draft, caret: s.caret, code: s.code,
    candidates: s.ime === 'quick' ? QUICK_CANDIDATES[s.code] ?? [] : [],
    scroll: s.ime === 'quick' && s.code === 'eu' ? quickScrollAt(frame) : 0,
    inkOn, hwCandidates: inkOn && frame >= HW_CANDIDATES_AT, pressed,
  };
};

// --- where a press lands on the phone (local coordinates) ---
export const pressRect = (p: PromoPress): R => {
  if (p.key === 'status') return onPhone(p.kb, { x: STATUS_CELL.x, y: KB[p.kb].toolbarY, w: STATUS_CELL.w, h: STATUS_CELL.h });
  if (p.key === 'toggle:draft') return toggleRect(p.kb, 'draft');
  if (p.key.startsWith('cand:')) return hwCandidateRect(p.kb, Number(p.key.slice(5)));
  if (p.key.startsWith('qcand:')) {
    const before = promoPhoneAt(p.t - 1);
    return quickCandidateRect(p.kb, before.code.length, Number(p.key.slice(6)), before.scroll);
  }
  if (p.key.startsWith('draft:')) {
    const before = promoPhoneAt(p.t - 1);
    const f = draftRect(p.kb);
    const x = draftCaretX(p.kb, before.draft, Number(p.key.slice(6)));
    return { x: x - 14, y: f.y, w: 28, h: f.h };
  }
  return keyRect(p.kb, p.key);
};

// --- the finger on the phone's keyboard pages (the pad of segment 8 is trackpad.ts) ---
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
/** One group per story segment that has finger work: it fades in 6 frames before its first move and out 6 frames after its last. */
const GROUPS = SEGMENTS.map((sg) => {
  const segs = SEGS.filter((s) => s.t0 >= sg.from && s.t0 < sg.to);
  return segs.length ? { segs, from: segs[0].t0 - 6, to: segs[segs.length - 1].t1 + 6 } : null;
}).filter((g): g is { segs: Seg[]; from: number; to: number } => g !== null);

const lerp = (a: number, b: number, u: number): number => a + (b - a) * u;
export const promoFingerAt = (frame: number): KeyFinger => {
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
export const promoInkAt = (frame: number): Pt[][] => {
  const out: Pt[][] = [];
  STROKES.forEach((s, i) => {
    if (frame < INK[i].from) return;
    const u = (frame - INK[i].from) / (INK[i].to - INK[i].from);
    out.push(partialStroke(s, u).map(([x, y]) => ({ x, y })));
  });
  return out;
};

// --- the trackpad and the Mac ---
/** The trackpad runs through all of segment 8: old shot 21 through padFrame. */
export const promoTrackAt = (frame: number): TrackState | null => {
  const s = seg('8');
  return frame >= s.from && frame < s.to ? trackAt(Math.round(padFrame(frame))) : null;
};

export const promoMacAt = (frame: number): MacState => {
  const { lines, caretOn } = docAt('Mac', frame);
  const track = promoTrackAt(frame);
  const cursor: MacState['cursor'] = track ? { x: track.cursor.x, y: track.cursor.y, opacity: track.cursorOpacity, press: track.cursorPress } : null;
  return { screen: 'doc', lines, caretOn, cursor, track };
};
