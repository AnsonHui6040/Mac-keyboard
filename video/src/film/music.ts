/**
 * The music: one take of Clean Geometry from film second 0 to the end of the file, with no cut, gap or restart (the file is not
 * committed, public/audio is ignored). Film second 0.0 plays source 0.058 s, the first beat of its grid (0.058 s + n * 0.5 s), so
 * source = film + 0.058 all through. The arrangement lifts by about 10 dB at source 16.058 s, which is film 16.0 s, the moment the
 * whole sentence lands on the Mac, and it winds down from about film 42 s: measured on the file, it is silent from source 44.5 s
 * (film 44.4 s) by itself, so nothing is faded or stopped by the edit. Pure: node can import it.
 */
import { soundEvents } from './events.ts';
import { FPS } from './timeline.ts';

export type MusicSegment = { id: string; file: string; from: number; to: number; /** film seconds minus source seconds */ shift: number; trimBefore: number; base: number };
const sec = (s: number): number => Math.round(s * FPS);

/** Length of Clean_Geometry.mp3 (ffprobe) and the source second that film second 0 plays. */
const FILE_SECONDS = 46.994;
const SOURCE_AT_ZERO = 0.058;

/** Overall level of the music, set by measuring the render. */
export const MUSIC_TRIM = 1.1;
const BASE = 0.5 * MUSIC_TRIM;
export const MUSIC: readonly MusicSegment[] = [
  { id: 'clean', file: 'audio/Clean_Geometry.mp3', from: 0, to: Math.floor((FILE_SECONDS - SOURCE_AT_ZERO) * FPS), shift: -SOURCE_AT_ZERO, base: BASE, trimBefore: Math.round(SOURCE_AT_ZERO * FPS) },
];
export const trimFrames = (id: string): number => MUSIC.find((m) => m.id === id)!.trimBefore;

/** Which file and which second of it the film plays at a frame. */
export const musicSource = (frame: number): { file: string; seconds: number } => {
  const m = MUSIC.find((x) => frame >= x.from && frame < x.to) ?? MUSIC[0];
  return { file: m.file, seconds: frame / FPS - m.shift };
};

/** The source is about 10 dB louder from film 16.0 s on; the gain steps down over the 12 frames before, while the source is still quiet. */
const LIFT = sec(16);
const LOUD = 0.42;

/** Writing stretch: half as loud, so the light ink taps are heard. The gain ramps over 12 frames into and out of the dip, so no frame steps by more than 1.5 dB. */
const HAND = [sec(18.1), sec(21.7)] as const;
/** From 29.0 to 41.0 s every tap and click dips the music by DUCK_DB and it is back after DUCK_FRAMES. */
export const DUCK_DB = 3;
export const DUCK_FRAMES = 6;
const DUCK = [sec(29), sec(41)] as const;
const DUCK_AT = soundEvents().filter((e) => (e.kind === 'tap' || e.kind === 'click') && e.frame >= DUCK[0] && e.frame < DUCK[1]).map((e) => e.frame);
const FLOOR = 10 ** (-DUCK_DB / 20);

const RAMP = 12;
const clamp01 = (v: number): number => Math.min(1, Math.max(0, v));

export const musicGain = (frame: number): number => {
  const m = MUSIC.find((x) => frame >= x.from && frame < x.to);
  if (!m) return 0;
  let g = m.base;
  if (frame === m.from) g *= 0.5;
  g *= 1 - (1 - LOUD) * Math.min(1, Math.max(0, (frame - (LIFT - RAMP)) / RAMP));
  g *= 1 - 0.5 * Math.min(clamp01((frame - HAND[0]) / RAMP), clamp01((HAND[1] - frame) / RAMP));
  let duck = 1;
  for (const e of DUCK_AT) if (frame >= e && frame < e + DUCK_FRAMES) duck = Math.min(duck, FLOOR + (1 - FLOOR) * ((frame - e) / DUCK_FRAMES));
  return g * duck;
};
