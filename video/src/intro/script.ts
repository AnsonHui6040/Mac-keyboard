/**
 * What the fingers do on the keyboard, and what that does to the phone and the Mac. One list of presses drives the picture,
 * the sound and the tests, so a sound or a Mac letter can never drift away from the key press it belongs to.
 * Pure: no JSX, node can import it.
 */
import { CHAPTER_START, layerAt, type Chapter } from './timeline.ts';
import { HW_CAND, QUICK_BAR, centerOf, keyRect, kbTop, modeToggle, quickCenter, quickScrollFor, toCanvas, PHONE, type KbName, type R } from './layout.ts';
import { HW_CANDIDATE_DELAY, STROKES, strokePoint, strokeSchedule } from './ink.ts';

/** The Mac shows a typed character this many frames after the key goes down. */
export const MAC_DELAY = 2;
export const TYPED_DEMO = ['Hello from my iPhone', 'Each key is sent', 'Check before sending', 'Remote Keyboard'] as const;

export type Fx =
  | { k: 'char'; c: string }
  | { k: 'shift' }
  | { k: 'enter' }
  | { k: 'mode'; to: 'live' | 'draft' }
  | { k: 'ime' }
  | { k: 'pick'; text: string; index: number }
  | { k: 'code'; c: string }
  | { k: 'send' }
  | { k: 'pad' }
  | { k: 'blockedkey' }
  | { k: 'cut'; ime?: 'quick'; blocked?: boolean };

export type Press = { t: number; kb: KbName; key: string; label: string; snd: 'key' | 'tap'; fx: Fx; hold: number };

type Draft = Omit<Press, 'hold'>;
const drafts: Draft[] = [];
const add = (t: number, kb: KbName, key: string, fx: Fx, snd: 'key' | 'tap', label = key): void => {
  drafts.push({ t, kb, key, label, snd, fx });
};

/** Types a string, one press every `pitch` frames. Capitals press shift first. Returns the next free frame. */
const typeText = (start: number, pitch: number, text: string, kb: KbName): number => {
  let t = start;
  for (const tok of text) {
    if (tok === '\n') { add(t, kb, 'enter', { k: 'enter' }, 'tap', '換行'); t += pitch; continue; }
    const lower = tok.toLowerCase();
    if (tok !== lower && /[A-Z]/.test(tok)) { add(t, kb, 'shift', { k: 'shift' }, 'tap', 'shift'); t += pitch; }
    const key = tok === ' ' ? 'space' : lower;
    add(t, kb, key, { k: 'char', c: tok }, 'key', tok === ' ' ? '空白' : tok);
    t += pitch;
  }
  return t;
};

// Scene 1 (0-180): live mode, 6 frames a key.
typeText(14, 6, 'Hello from my iPhone', 'connected');
// Scene 2a (180-330): new line, a sentence, new line.
typeText(186, 6, '\nEach key is sent\n', 'connected');
// Scene 2b (330-450): 草稿, then the sentence lives only on the keyboard.
add(334, 'connected', 'toggle:draft', { k: 'mode', to: 'draft' }, 'tap', '草稿');
typeText(342, 4, 'Check before sending', 'draft');
// Scene 2c (450-540): the new line shows in the draft, 傳送 sends everything at once.
add(462, 'draft', 'enter', { k: 'enter' }, 'tap', '換行');
add(488, 'draft', 'send', { k: 'send' }, 'tap', '傳送');
// Scene 3a (540-720): 中英 opens handwriting, the ink is drawn (ink.ts), the candidate is picked.
add(546, 'draft', 'zh', { k: 'ime' }, 'tap', '中英');
export const HW_PICK = 668;
add(HW_PICK, 'handwriting', 'cand:0', { k: 'pick', text: '香港', index: 0 }, 'tap', '香港');
add(682, 'handwriting', 'enter', { k: 'enter' }, 'tap', '換行');
add(696, 'handwriting', 'send', { k: 'send' }, 'tap', '傳送');
// Scene 3b (720-900): the App is set to 速成 (hard cut at 720), roots 竹日 then 水山.
export const QUICK_AT = 720;
add(730, 'quick', 'h', { k: 'code', c: 'h' }, 'key');
add(738, 'quick', 'a', { k: 'code', c: 'a' }, 'key');
add(750, 'quick', 'qcand:3', { k: 'pick', text: '香', index: 3 }, 'tap', '香');
add(760, 'quick', 'e', { k: 'code', c: 'e' }, 'key');
add(768, 'quick', 'u', { k: 'code', c: 'u' }, 'key');
add(824, 'quick', 'qcand:15', { k: 'pick', text: '港', index: 15 }, 'tap', '港');
add(846, 'quick', 'send', { k: 'send' }, 'tap', '傳送');
// Scene 4a: 觸控板 (what happens on the pad is trackpad.ts).
export const PAD_AT = 906;
add(PAD_AT, 'quick', 'trackpadBtn', { k: 'pad' }, 'tap', '觸控板');
// Scene 5: the password field turns the keyboard to 密碼不能輸入; five keys, nothing arrives.
export const LOGIN = { cursorFrom: 1340, arrive: 1356, click: 1358, blocked: 1362 } as const;
['k', 'm', 'e', 't', 'w'].forEach((c, i) => add(1375 + i * 7, 'blocked', c, { k: 'blockedkey' }, 'key'));
// Scene 6: the product name, 4 frames a key.
export const PRODUCT_START = 1540;
typeText(PRODUCT_START, 4, 'Remote Keyboard', 'connected');

/** Presses of a chapter whose clock is the film's: a press holds for 4 frames, less when the next one comes sooner. */
export const PRESSES: readonly Press[] = (() => {
  const sorted = [...drafts].sort((a, b) => a.t - b.t);
  return sorted.map((d, i) => {
    const next = sorted[i + 1];
    const gap = next && next.t - d.t < 40 ? next.t - d.t : 99;
    return { ...d, hold: Math.min(4, Math.max(2, gap - 1)) };
  });
})();

/** Things that happen on the phone without a finger. */
export const CUTS: readonly { t: number; fx: Fx }[] = [
  { t: QUICK_AT, fx: { k: 'cut', ime: 'quick' } },
  { t: LOGIN.blocked, fx: { k: 'cut', blocked: true } },
];

export const chapterOf = (frame: number): Chapter => layerAt(frame).chapter;
const chapterOfPress = (t: number): Chapter => {
  let c: Chapter = 0;
  for (let i = 1; i < CHAPTER_START.length; i++) if (t >= CHAPTER_START[i]) c = i as Chapter;
  return c;
};

type S = { ime: 'en' | 'hw' | 'quick' | 'pad'; mode: 'live' | 'draft'; shift: boolean; draft: string; code: string; picked: boolean; blocked: boolean };
const START: S = { ime: 'en', mode: 'live', shift: false, draft: '', code: '', picked: false, blocked: false };

const apply = (s: S, fx: Fx): { s: S; add: string } => {
  const n = { ...s };
  let add = '';
  switch (fx.k) {
    case 'char': n.shift = false; if (s.mode === 'live') add = fx.c; else n.draft += fx.c; break;
    case 'shift': n.shift = !s.shift; break;
    case 'enter': if (s.mode === 'live') add = '\n'; else n.draft += '\n'; break;
    case 'mode': n.mode = fx.to; break;
    case 'ime': n.ime = 'hw'; n.picked = false; break;
    case 'pick': n.draft += fx.text; n.code = ''; n.picked = true; break;
    case 'code': n.code += fx.c; break;
    case 'send': add = s.draft; n.draft = ''; break;
    case 'pad': n.ime = 'pad'; break;
    case 'cut': if (fx.ime) n.ime = fx.ime; if (fx.blocked) n.blocked = true; break;
    default: break;
  }
  return { s: n, add };
};

type Item = { t: number; fx: Fx; press?: Press };
const ITEMS: Item[] = [...PRESSES.map((p) => ({ t: p.t, fx: p.fx, press: p })), ...CUTS.map((c) => ({ t: c.t, fx: c.fx }))].sort((a, b) => a.t - b.t);

export type MacOp = { frame: number; press: Press; add: string; chapter: Chapter };
let opsCache: MacOp[] | null = null;
/** Every change of the Mac text: the frame it shows, the press it comes from, what is added. */
export const macOps = (): MacOp[] => {
  if (opsCache) return opsCache;
  const out: MacOp[] = [];
  const state: S[] = [START, START, START];
  for (const it of ITEMS) {
    const c = chapterOfPress(it.t);
    const r = apply(state[c], it.fx);
    state[c] = r.s;
    if (r.add && it.press) out.push({ frame: it.t + MAC_DELAY, press: it.press, add: r.add, chapter: c });
  }
  opsCache = out;
  return out;
};

/** The text in the TextEdit document of a chapter (0: scenes 1 to 4, 2: scene 6) at a frame. */
export const macTextAt = (frame: number, chapter: Chapter = chapterOf(frame)): string =>
  macOps().filter((o) => o.chapter === chapter && o.frame <= frame).map((o) => o.add).join('');

/** The frame the Mac text last changed in a chapter at or before `frame` (for the caret), or -99. */
export const lastMacChange = (frame: number, chapter: Chapter): number => {
  let last = -99;
  for (const o of macOps()) if (o.chapter === chapter && o.frame <= frame) last = o.frame;
  return last;
};

// --- quick candidates ---
export const QUICK_CANDIDATES: Record<string, string[]> = {
  h: ['竹'],
  ha: ['白', '昏', '徇', '香', '舶', '筍', '箔', '箸', '稽'],
  e: ['水'],
  eu: [...'氾汕沈沉沅沌況泡流洗洸洎浥淹淘港湘溉湄滬澆澠'],
};
/** Three flicks along the candidate bar; together they scroll candidate 13 (淹) to image x 37, which is the picture of kb-quickComposing.png. */
export const SWIPES = [{ from: 772, to: 782 }, { from: 787, to: 797 }, { from: 802, to: 812 }] as const;
export const QUICK_SCROLL_TOTAL = quickScrollFor(2, 13, 37);
const SWIPE_FROM_X = 650;
const ease = (u: number): number => (u <= 0 ? 0 : u >= 1 ? 1 : u * u * (3 - 2 * u));
export const quickScrollAt = (frame: number): number => {
  let s = 0;
  for (const w of SWIPES) s += (QUICK_SCROLL_TOTAL / SWIPES.length) * ease((frame - w.from) / (w.to - w.from));
  return s;
};

// --- phone state ---
export type PhoneState = {
  kb: KbName;
  shift: boolean;
  draft: string;
  code: string;
  candidates: string[];
  scroll: number;
  inkOn: boolean;
  hwCandidates: boolean;
  blocked: boolean;
  ime: S['ime'];
};

export const phoneAt = (frame: number, chapter: Chapter = chapterOf(frame)): PhoneState => {
  let s = START;
  for (const it of ITEMS) {
    if (it.t > frame) break;
    if (chapterOfPress(it.t) !== chapter) continue;
    s = apply(s, it.fx).s;
  }
  const kb: KbName = s.ime === 'pad' ? 'trackpad' : s.ime === 'hw' ? 'handwriting' : s.ime === 'quick' ? 'quick' : s.mode === 'live' ? (s.blocked ? 'blocked' : 'connected') : 'draft';
  const sched = strokeSchedule();
  const inkOn = s.ime === 'hw' && !s.picked && frame >= sched[0].from;
  const hwCandidates = inkOn && frame >= sched[sched.length - 1].to + HW_CANDIDATE_DELAY;
  const candidates = s.ime === 'quick' ? QUICK_CANDIDATES[s.code] ?? [] : [];
  return { kb, shift: s.shift, draft: s.draft, code: s.code, candidates, scroll: s.ime === 'quick' && s.code === 'eu' ? quickScrollAt(frame) : 0, inkOn, hwCandidates, blocked: s.blocked, ime: s.ime };
};

// --- where a press lands ---
/** Canvas rectangle a press aims at. */
export const pressRect = (p: Press): R => {
  if (p.key === 'toggle:draft') return toCanvas(p.kb, modeToggle(p.kb, 'draft'));
  if (p.key.startsWith('cand:')) {
    const i = Number(p.key.slice(5));
    return toCanvas(p.kb, { x: HW_CAND.xs[i] - 60, y: HW_CAND.y - 26, w: 120, h: 52 });
  }
  if (p.key.startsWith('qcand:')) {
    const i = Number(p.key.slice(6));
    const code = p.fx.k === 'pick' ? phoneAt(p.t - 1).code : '';
    const x = quickCenter(code.length, i, phoneAt(p.t - 1).scroll);
    return toCanvas(p.kb, { x: x - QUICK_BAR.hit / 2, y: QUICK_BAR.y - QUICK_BAR.h / 2, w: QUICK_BAR.hit, h: QUICK_BAR.h });
  }
  return keyRect(p.kb, p.key);
};

// --- the finger on the phone (everything except the trackpad scene, which is trackpad.ts) ---
type Seg = { t0: number; t1: number; a: { x: number; y: number }; path?: (u: number) => { x: number; y: number }; press: boolean };
const SEGS: Seg[] = [];
for (const p of PRESSES) {
  const c = centerOf(pressRect(p));
  SEGS.push({ t0: p.t, t1: p.t + p.hold, a: c, press: true });
}
{
  const sched = strokeSchedule();
  const top = kbTop('handwriting');
  STROKES.forEach((s, i) => {
    SEGS.push({
      t0: sched[i].from, t1: sched[i].to, a: { x: PHONE.x + s[0][0], y: top + s[0][1] }, press: true,
      path: (u) => { const [x, y] = strokePoint(s, u); return { x: PHONE.x + x, y: top + y }; },
    });
  });
  const y = kbTop('quick') + QUICK_BAR.y;
  const d = QUICK_SCROLL_TOTAL / SWIPES.length;
  for (const w of SWIPES) SEGS.push({ t0: w.from, t1: w.to, a: { x: PHONE.x + SWIPE_FROM_X, y }, press: true, path: (u) => ({ x: PHONE.x + SWIPE_FROM_X - d * ease(u), y }) });
}
SEGS.sort((a, b) => a.t0 - b.t0);
const segEnd = (s: Seg) => (s.path ? s.path(1) : s.a);
/** Frames before a press in which the finger glides from the last key to the next. */
const GLIDE = 8;
/** One finger group per chapter: it fades in 4 frames before its first move and out 6 frames after its last. */
const GROUPS = [0, 1, 2].map((c) => {
  const segs = SEGS.filter((s) => chapterOfPress(s.t0) === c);
  return { segs, from: segs[0].t0 - 6, to: segs[segs.length - 1].t1 + 6 };
});

export type Finger = { x: number; y: number; visible: boolean; press: number; opacity: number };
const lerp = (a: number, b: number, u: number): number => a + (b - a) * u;

export const fingerAt = (frame: number): Finger => {
  const g = GROUPS.find((x) => frame >= x.from && frame < x.to);
  if (!g) return { x: 0, y: 0, visible: false, press: 0, opacity: 0 };
  const opacity = Math.min(1, (frame - g.from + 1) / 4, (g.to - frame) / 4);
  const segs = g.segs;
  let i = -1;
  for (let k = 0; k < segs.length; k++) if (segs[k].t0 <= frame) i = k;
  if (i < 0) return { ...segs[0].a, visible: true, press: 0, opacity };
  const s = segs[i];
  if (frame < s.t1) {
    const u = (frame - s.t0) / Math.max(1, s.t1 - s.t0 - (s.path ? 0 : 0));
    const pos = s.path ? s.path(Math.min(1, u)) : s.a;
    return { ...pos, visible: true, press: 1, opacity };
  }
  const end = segEnd(s);
  const next = segs[i + 1];
  if (!next) return { ...end, visible: true, press: 0, opacity };
  const dur = Math.min(GLIDE, next.t0 - s.t1);
  const u = dur <= 0 ? 1 : ease((frame - (next.t0 - dur)) / dur);
  return { x: lerp(end.x, next.a.x, u), y: lerp(end.y, next.a.y, u), visible: true, press: 0, opacity };
};

// --- other timings of the picture ---
export const caretOn = (frame: number, changedAt: number): boolean => (frame - changedAt < 12 ? true : Math.floor(frame / 15) % 2 === 0);
