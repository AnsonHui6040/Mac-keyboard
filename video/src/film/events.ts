/**
 * The one table of what the fingers do. The picture, the sound and the tests all read it, so a sound or a Mac letter can never
 * drift away from the key press it belongs to. Most keys act the frame they go down; a key that turns the page acts when the
 * finger lifts, so its press is seen on the page it belongs to. The Mac shows a typed character MAC_DELAY frames after the key.
 * Pure: no JSX, node can import it.
 */
import { STROKES, strokeLength } from '../intro/ink.ts';
import { FRAMES } from './timeline.ts';
import type { KbName } from './layout.ts';

export const MAC_DELAY = 2;
export type Chapter = 0 | 1;
/** 0 the document (shots 1 to 21), 1 the empty document of shot 30. */
export const CHAPTER_START = [0, 1230] as const;
export const chapterOf = (t: number): Chapter => {
  let c: Chapter = 0;
  for (let i = 1; i < CHAPTER_START.length; i++) if (t >= CHAPTER_START[i]) c = i as Chapter;
  return c;
};

export type Fx =
  | { k: 'char'; c: string }
  | { k: 'shift' }
  | { k: 'enter' }
  | { k: 'mode'; to: 'draft' }
  | { k: 'ime'; to: 'hw' | 'pad' }
  | { k: 'caret'; index: number }
  | { k: 'pick'; text: string; index: number }
  | { k: 'code'; c: string }
  | { k: 'send' }
  | { k: 'cut'; ime: 'quick' };

/** `macDelay` is set on one press only (see MAC_DELAY_EXCEPTION); every other press uses MAC_DELAY. */
export type Press = { t: number; kb: KbName; key: string; label: string; snd: 'key' | 'tap'; fx: Fx; hold: number; chapter: Chapter; macDelay?: number };

/** The one press with its own Mac delay: shot 3 shows a blank page for two frames after the cut at 117, so the H of the key at 114 shows at 119. */
export const MAC_DELAY_EXCEPTION = { t: 114, key: 'h', delay: 5 } as const;
export const macDelayOf = (p: Press): number => p.macDelay ?? MAC_DELAY;

type Token = { kb: KbName; key: string; label: string; snd: 'key' | 'tap'; fx: Fx };
const drafts: (Token & { t: number })[] = [];
const place = (tokens: Token[], times: number[]): void => {
  if (tokens.length !== times.length) throw new Error(`${tokens.length} keys but ${times.length} times`);
  tokens.forEach((k, i) => drafts.push({ ...k, t: times[i] }));
};
const one = (t: number, kb: KbName, key: string, fx: Fx, snd: 'key' | 'tap', label = key): void => place([{ kb, key, label, snd, fx }], [t]);
/** The key presses that type a string: a capital is shift then the letter. */
const tokens = (text: string, kb: KbName): Token[] => {
  const out: Token[] = [];
  for (const c of text) {
    if (c === '\n') { out.push({ kb, key: 'enter', label: '換行', snd: 'tap', fx: { k: 'enter' } }); continue; }
    if (/[A-Z]/.test(c)) out.push({ kb, key: 'shift', label: 'shift', snd: 'tap', fx: { k: 'shift' } });
    out.push({ kb, key: c === ' ' ? 'space' : c.toLowerCase(), label: c === ' ' ? '空白' : c, snd: 'key', fx: { k: 'char', c } });
  }
  return out;
};

// --- shots 2 to 7: Hello from my iPhone. Shift, H at 3.8 s, e just before the cut to the Mac, five quick keys a shot 6, the rest in shot 7.
place(tokens('Hello from my iPhone', 'connected'), [98, 114, 144, 163, 166, 169, 172, 175, 178, 181, 184, 190, 195, 199, 204, 208, 213, 217, 221, 226, 230, 234]);
// --- shot 8: new line, then the 草稿 switch.
one(278, 'connected', 'enter', { k: 'enter' }, 'tap', '換行');
one(292, 'connected', 'toggle:draft', { k: 'mode', to: 'draft' }, 'tap', '草稿');
// --- shot 9: the draft, with the c missing.
place(tokens('Chek before sending', 'draft'), Array.from({ length: 20 }, (_, i) => 306 + 3 * i));
// --- shot 11: the finger taps between e and k, c goes in. Shot 12: the finger taps the end of the draft, new line, send.
one(412, 'draft', 'draft:3', { k: 'caret', index: 3 }, 'tap', '草稿');
one(428, 'draft', 'c', { k: 'char', c: 'c' }, 'key');
one(457, 'draft', 'draft:20', { k: 'caret', index: 20 }, 'tap', '草稿');
one(467, 'draft', 'enter', { k: 'enter' }, 'tap', '換行');
one(478, 'draft', 'send', { k: 'send' }, 'tap', '傳送');
// --- shots 14 to 17: 中英 opens the writing page, the ink is drawn, the first candidate is picked, new line, send.
one(531, 'draft', 'zh', { k: 'ime', to: 'hw' }, 'tap', '中英');
export const HW_CANDIDATES_AT = 653;
one(671, 'handwriting', 'cand:0', { k: 'pick', text: '香港', index: 0 }, 'tap', '香港');
one(681, 'handwriting', 'enter', { k: 'enter' }, 'tap', '換行');
one(691, 'handwriting', 'send', { k: 'send' }, 'tap', '傳送');
// --- shot 18: the quick page (hard cut at QUICK_AT), roots 竹日, 香, roots 水山, three flicks, 港, send.
export const QUICK_AT = 717;
one(724, 'quick', 'h', { k: 'code', c: 'h' }, 'key');
one(731, 'quick', 'a', { k: 'code', c: 'a' }, 'key');
one(743, 'quick', 'qcand:3', { k: 'pick', text: '香', index: 3 }, 'tap', '香');
one(752, 'quick', 'e', { k: 'code', c: 'e' }, 'key');
one(758, 'quick', 'u', { k: 'code', c: 'u' }, 'key');
export const SWIPES = [{ from: 763, to: 771 }, { from: 774, to: 782 }, { from: 785, to: 793 }] as const;
one(797, 'quick', 'qcand:15', { k: 'pick', text: '港', index: 15 }, 'tap', '港');
one(805, 'quick', 'send', { k: 'send' }, 'tap', '傳送');
// --- shot 20: 觸控板.
one(833, 'quick', 'trackpadBtn', { k: 'ime', to: 'pad' }, 'tap', '觸控板');
/** The phone says it is connected from this frame. */
export const CONNECT_AT = 42;
// --- shot 30: the product name, 4 frames a key, the last Mac letter at 43.5 s.
export const PRODUCT_START = 1239;
place(tokens('Remote Keyboard', 'connected'), Array.from({ length: 17 }, (_, i) => PRODUCT_START + 4 * i));

/** A press holds for 4 frames, less when the next one comes sooner. */
export const PRESSES: readonly Press[] = (() => {
  const sorted = [...drafts].sort((a, b) => a.t - b.t);
  return sorted.map((d, i) => {
    const next = sorted[i + 1];
    const gap = next && chapterOf(next.t) === chapterOf(d.t) && next.t - d.t < 40 ? next.t - d.t : 99;
    const exception = d.t === MAC_DELAY_EXCEPTION.t && d.key === MAC_DELAY_EXCEPTION.key ? { macDelay: MAC_DELAY_EXCEPTION.delay } : {};
    return { ...d, ...exception, chapter: chapterOf(d.t), hold: Math.min(4, Math.max(2, gap - 1)) };
  });
})();

/** Things that happen on the phone without a finger. */
export const CUTS: readonly { t: number; fx: Fx }[] = [
  { t: QUICK_AT, fx: { k: 'cut', ime: 'quick' } },
];

/** The frame a press acts on the phone: page changes when the finger lifts. */
export const actFrame = (p: Press): number => (p.fx.k === 'ime' || p.fx.k === 'mode' ? p.t + p.hold : p.t);

// --- handwriting: 18 strokes drawn inside shot 15, a frame of lift between strokes ---
export const INK_FROM = 549;
export const INK_TO = 645;
export const INK: readonly { from: number; to: number }[] = (() => {
  const lens = STROKES.map(strokeLength);
  const budget = INK_TO - INK_FROM - (STROKES.length - 1);
  const total = lens.reduce((a, b) => a + b, 0);
  const raw = lens.map((l) => Math.max(2, (l / total) * budget));
  const scale = budget / raw.reduce((a, b) => a + b, 0);
  let t = INK_FROM;
  return raw.map((r) => {
    const from = Math.round(t);
    t += r * scale;
    const to = Math.max(from + 2, Math.round(t));
    t = to + 1;
    return { from, to };
  });
})();

// --- the trackpad, shot 21: where the frames fall. trackpad.ts turns them into finger paths ---
export const PAD_AT = {
  fingersIn: 868,
  move1: [876, 926], tap1: [948, 952], select: 950,
  touch: 990, lift: 1002, dragEnd: 1034, drop: 1042,
  tap2: [1074, 1078], menu: 1076, move3: [1092, 1104], tap3: [1110, 1114], open: 1112,
  scrollDown: 1150, swipe: [1158, 1252],
} as const;
export type PadWhat = 'tap' | 'select' | 'touch' | 'lift' | 'drop' | 'tap2' | 'menu' | 'tap3' | 'open';
export const PAD_EVENTS: readonly { frame: number; what: PadWhat }[] = [
  { frame: PAD_AT.tap1[0], what: 'tap' }, { frame: PAD_AT.select, what: 'select' },
  { frame: PAD_AT.touch, what: 'touch' }, { frame: PAD_AT.lift, what: 'lift' }, { frame: PAD_AT.drop, what: 'drop' },
  { frame: PAD_AT.tap2[0], what: 'tap2' }, { frame: PAD_AT.menu, what: 'menu' },
  { frame: PAD_AT.tap3[0], what: 'tap3' }, { frame: PAD_AT.open, what: 'open' },
];

// --- sound ---
export type SoundKind = 'key' | 'tap' | 'click' | 'good' | 'success' | 'ink';
export type SoundEvent = { frame: number; kind: SoundKind };

export const soundEvents = (): SoundEvent[] => {
  const out: SoundEvent[] = [];
  for (const p of PRESSES) {
    out.push({ frame: p.t, kind: p.snd });
    if (p.fx.k === 'send') out.push({ frame: p.t + MAC_DELAY, kind: 'good' });
  }
  const product = PRESSES.filter((p) => p.chapter === 1);
  out.push({ frame: product[product.length - 1].t + MAC_DELAY, kind: 'success' });
  for (const s of INK) out.push({ frame: s.from, kind: 'ink' });
  for (const e of PAD_EVENTS) {
    if (e.what === 'tap' || e.what === 'tap2' || e.what === 'tap3') out.push({ frame: e.frame, kind: 'tap' });
    else if (e.what === 'select' || e.what === 'lift' || e.what === 'drop' || e.what === 'open') out.push({ frame: e.frame, kind: 'click' });
  }
  return out.filter((e) => e.frame >= 0 && e.frame < FRAMES).sort((a, b) => a.frame - b.frame);
};

/** The effects registry is global, so every callback asks whether the context is this film's: exactly 50.5 s (one sample either way). */
export const isFilmContext = (length: number, sampleRate: number): boolean => Math.abs(length - Math.round((FRAMES / 30) * sampleRate)) <= 1;
