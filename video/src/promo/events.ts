/**
 * The one table of what the finger does in the v0.2 promo, and which computer is connected when. The picture, the sound and the
 * tests all read it. The algorithms are those of film/events.ts; the frames are this film's, worked out from the segments and the
 * voice (timeline.ts). Pure: no JSX, node can import it.
 */
import manifestJson from './voice-manifest.json' with { type: 'json' };
import { STROKES, strokeLength } from '../intro/ink.ts';
import { PAD_AT, PAD_EVENTS as OLD_PAD_EVENTS, type Fx, type PadWhat, type SoundKind } from '../film/events.ts';
import type { KbName } from '../film/layout.ts';
import { FRAMES, PAD_RATE, PAD_START, seg, voice, type LineId, type SegId } from './timeline.ts';

export type { SoundKind };
export const MAC_DELAY = 2;
export type Host = 'Mac' | 'Windows' | 'Linux';
export type PromoFx = Fx | { k: 'host' };
/** What happens on the phone without a finger. The second cut also empties the draft, as the cut of old shot 30 did. */
export type CutFx = { k: 'cut'; ime: 'quick' } | { k: 'cut'; ime: 'en'; mode: 'live' };
export type PromoPress = { t: number; kb: KbName; key: string; label: string; snd: 'key' | 'tap'; fx: PromoFx; hold: number };

const manifest = manifestJson as Record<LineId, { firstPause: number | null }>;
/** The frame a line has said 「點一下」 (the first pause of the line). */
const tapOf = (id: LineId): number => voice(id).from + Math.round(manifest[id].firstPause! * 30);
export const HOST_TAPS: readonly [number, number, number] = [tapOf('03'), tapOf('05'), tapOf('07')];
const HOSTS: readonly Host[] = ['Mac', 'Windows', 'Linux', 'Mac'];
/** The computer the phone is connected to at a frame: it changes on the frame of the tap. */
export const hostAt = (frame: number): Host => HOSTS[HOST_TAPS.filter((t) => frame >= t).length];

type Token = { kb: KbName; key: string; label: string; snd: 'key' | 'tap'; fx: PromoFx };
const drafts: (Token & { t: number })[] = [];
const place = (tokens: Token[], times: number[]): void => {
  if (tokens.length !== times.length) throw new Error(`${tokens.length} keys but ${times.length} times`);
  tokens.forEach((k, i) => drafts.push({ ...k, t: times[i] }));
};
const one = (t: number, kb: KbName, key: string, fx: PromoFx, snd: 'key' | 'tap', label = key): void => place([{ kb, key, label, snd, fx }], [t]);
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
const run = (start: number, step: number, n: number): number[] => Array.from({ length: n }, (_, i) => start + step * i);
/** A frame given as seconds into a segment. */
const at = (id: SegId, sec: number): number => seg(id).from + Math.round(sec * 30);
const after = (id: SegId, frames: number): number => seg(id).from + frames;

// --- segment 2: live to the Mac, then the draft with the c missing ---
const HELLO = tokens('Hello from my iPhone', 'connected');
place(HELLO, run(at('2', 0.4), 4, HELLO.length));
const helloEnd = at('2', 0.4) + 4 * (HELLO.length - 1);
one(helloEnd + 8, 'connected', 'enter', { k: 'enter' }, 'tap', '換行');
one(helloEnd + 18, 'connected', 'toggle:draft', { k: 'mode', to: 'draft' }, 'tap', '草稿');
const CHEK = tokens('Chek before sending', 'draft');
const chekStart = helloEnd + 28;
place(CHEK, run(chekStart, 3, CHEK.length));
const chekEnd = chekStart + 3 * (CHEK.length - 1);
one(chekEnd + 11, 'draft', 'draft:3', { k: 'caret', index: 3 }, 'tap', '草稿');
one(chekEnd + 23, 'draft', 'c', { k: 'char', c: 'c' }, 'key');
one(chekEnd + 39, 'draft', 'draft:20', { k: 'caret', index: 20 }, 'tap', '草稿');
one(chekEnd + 49, 'draft', 'enter', { k: 'enter' }, 'tap', '換行');
one(chekEnd + 59, 'draft', 'send', { k: 'send' }, 'tap', '傳送');

// --- segments 3, 5, 7: the tap on the status cell of whatever page the phone shows ---
one(HOST_TAPS[0], 'draft', 'status', { k: 'host' }, 'tap', '點一下');

// --- segment 4: 中英, the ink, the first candidate, send ---
export const INK_FROM = at('4', 1.0);
export const INK_TO = at('4', 4.2);
one(at('4', 0.5), 'draft', 'zh', { k: 'ime', to: 'hw' }, 'tap', '中英');
/** The candidates show 8 frames after the last stroke. */
export const HW_CANDIDATES_AT = INK_TO + 8;
one(HW_CANDIDATES_AT + 18, 'handwriting', 'cand:0', { k: 'pick', text: '香港', index: 0 }, 'tap', '香港');
one(HW_CANDIDATES_AT + 30, 'handwriting', 'send', { k: 'send' }, 'tap', '傳送');

one(HOST_TAPS[1], 'handwriting', 'status', { k: 'host' }, 'tap', '點一下');

// --- segment 6: the quick page (cut at the segment start), roots 竹日, 香, roots 水山, three flicks, 港, send ---
const Q = seg('6').from;
one(Q + 7, 'quick', 'h', { k: 'code', c: 'h' }, 'key');
one(Q + 14, 'quick', 'a', { k: 'code', c: 'a' }, 'key');
one(Q + 26, 'quick', 'qcand:3', { k: 'pick', text: '香', index: 3 }, 'tap', '香');
one(Q + 35, 'quick', 'e', { k: 'code', c: 'e' }, 'key');
one(Q + 41, 'quick', 'u', { k: 'code', c: 'u' }, 'key');
export const SWIPES = [{ from: Q + 47, to: Q + 55 }, { from: Q + 58, to: Q + 66 }, { from: Q + 69, to: Q + 77 }] as const;
one(Q + 83, 'quick', 'qcand:15', { k: 'pick', text: '港', index: 15 }, 'tap', '港');
one(Q + 91, 'quick', 'send', { k: 'send' }, 'tap', '傳送');

// --- segment 7: back to the Mac, then 觸控板 ---
one(HOST_TAPS[2], 'quick', 'status', { k: 'host' }, 'tap', '點一下');
one(HOST_TAPS[2] + 9, 'quick', 'trackpadBtn', { k: 'ime', to: 'pad' }, 'tap', '觸控板');

// --- segment 9: the product name on the Mac, 4 frames a key ---
const PRODUCT = tokens('Remote Keyboard', 'connected');
place(PRODUCT, run(after('9', 9), 4, PRODUCT.length));

/** A press holds for 4 frames, less when the next one comes sooner. */
export const PRESSES: readonly PromoPress[] = (() => {
  const sorted = [...drafts].sort((a, b) => a.t - b.t);
  return sorted.map((d, i) => {
    const next = sorted[i + 1];
    const gap = next && next.t - d.t < 40 ? next.t - d.t : 99;
    return { ...d, hold: Math.min(4, Math.max(2, gap - 1)) };
  });
})();

/** Page changes without a finger: the hard cuts at the start of segments 6 and 9. */
export const CUTS_FX: readonly { t: number; fx: CutFx }[] = [
  { t: seg('6').from, fx: { k: 'cut', ime: 'quick' } },
  { t: seg('9').from, fx: { k: 'cut', ime: 'en', mode: 'live' } },
];

/** The frame a press acts on the phone: a page changes when the finger lifts. */
export const actFrame = (p: PromoPress): number => (p.fx.k === 'ime' || p.fx.k === 'mode' ? p.t + p.hold : p.t);

// --- handwriting: 18 strokes drawn from 1.0 s to 4.2 s of segment 4, a frame of lift between strokes ---
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

// --- the trackpad: the events of old shot 21, through padFrame backwards ---
const OLD_PAD_FIRST = 876;
const toPromo = (old: number): number => Math.round(PAD_START + (old - OLD_PAD_FIRST) / PAD_RATE);
export const PAD_EVENTS: readonly { frame: number; what: PadWhat }[] = OLD_PAD_EVENTS.map((e) => ({ frame: toPromo(e.frame), what: e.what }));
export const PAD_FRAMES = { fingersIn: toPromo(PAD_AT.fingersIn) };

// --- sound ---
export type PromoSoundKind = SoundKind | 'host';
export type PromoSoundEvent = { frame: number; kind: PromoSoundKind };

export const soundEvents = (): PromoSoundEvent[] => {
  const out: PromoSoundEvent[] = [];
  for (const p of PRESSES) {
    out.push({ frame: p.t, kind: p.fx.k === 'host' ? 'host' : p.snd });
    if (p.fx.k === 'send') out.push({ frame: p.t + MAC_DELAY, kind: 'good' });
  }
  const product = PRESSES.filter((p) => p.t >= seg('9').from && p.t < seg('9').to);
  out.push({ frame: product[product.length - 1].t + MAC_DELAY, kind: 'success' });
  for (const s of INK) out.push({ frame: s.from, kind: 'ink' });
  for (const e of PAD_EVENTS) {
    if (e.what === 'tap' || e.what === 'tap2' || e.what === 'tap3') out.push({ frame: e.frame, kind: 'tap' });
    else if (e.what === 'select' || e.what === 'lift' || e.what === 'drop' || e.what === 'open') out.push({ frame: e.frame, kind: 'click' });
  }
  return out.filter((e) => e.frame >= 0 && e.frame < FRAMES).sort((a, b) => a.frame - b.frame);
};
