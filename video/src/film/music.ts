/**
 * The music: three stretches of two files (the files are not committed, public/audio is ignored), each one hard cut by the edit.
 * The beat grid of Clean Geometry sits at 0.058 s + n * 0.5 s, the film's bars start at 3.0 s, so source second = film second - 6.942;
 * the second stretch is moved by a further 6 s so that the lift of the source at 16.058 s falls on 29.0 s. Pure: node can import it.
 */
import { soundEvents } from './events.ts';
import { FPS } from './timeline.ts';

export type MusicSegment = { id: string; file: string; from: number; to: number; /** film seconds minus source seconds */ shift: number; trimBefore: number; base: number };
const sec = (s: number): number => Math.round(s * FPS);
const seg = (id: string, file: string, from: number, to: number, shift: number, base: number): MusicSegment => ({
  id, file, from: sec(from), to: sec(to), shift, base, trimBefore: Math.round((from - shift) * FPS),
});

/** Overall level of the music, set by measuring the render. */
export const MUSIC_TRIM = 1.1;
export const MUSIC: readonly MusicSegment[] = [
  seg('clean-a', 'audio/Clean_Geometry.mp3', 7.0, 12.2, 6.942, 0.62 * MUSIC_TRIM),
  seg('clean-b', 'audio/Clean_Geometry.mp3', 16.0, 41.0, 12.942, 0.5 * MUSIC_TRIM),
  seg('soft', 'audio/Soft_Geometry.mp3', 51.0, 59.0, -4, 0.7 * MUSIC_TRIM),
];
export const trimFrames = (id: string): number => MUSIC.find((m) => m.id === id)!.trimBefore;

/** Which file and which second of it the film plays at a frame. */
export const musicSource = (frame: number): { file: string; seconds: number } => {
  const m = MUSIC.find((x) => frame >= x.from && frame < x.to) ?? MUSIC[0];
  return { file: m.file, seconds: frame / FPS - m.shift };
};

/** Before the lift of the source (film 29.0 s) the music is 3 dB louder than after it: the bed is quiet there, the keys would drown. */
const LIFT = sec(29);
const PRE_LIFT = 1.45;

/** Writing stretch: the music has no quiet piano there, so it is half as loud. */
const HAND = [sec(18.1), sec(21.7)] as const;
/** From 29.0 to 41.0 s every tap and click dips the music by DUCK_DB and it is back after DUCK_FRAMES. */
export const DUCK_DB = 3;
export const DUCK_FRAMES = 6;
const DUCK = [sec(29), sec(41)] as const;
const DUCK_AT = soundEvents().filter((e) => (e.kind === 'tap' || e.kind === 'click') && e.frame >= DUCK[0] && e.frame < DUCK[1]).map((e) => e.frame);
const FLOOR = 10 ** (-DUCK_DB / 20);

export const musicGain = (frame: number): number => {
  const m = MUSIC.find((x) => frame >= x.from && frame < x.to);
  if (!m) return 0;
  let g = m.base;
  if (frame === m.from || frame === m.to - 1) g *= 0.5;
  if (m.id === 'clean-b') g *= PRE_LIFT - (PRE_LIFT - 1) * Math.min(1, Math.max(0, (frame - (LIFT - 6)) / 6));
  if (frame >= HAND[0] && frame < HAND[1]) g *= 0.5;
  let duck = 1;
  for (const e of DUCK_AT) if (frame >= e && frame < e + DUCK_FRAMES) duck = Math.min(duck, FLOOR + (1 - FLOOR) * ((frame - e) / DUCK_FRAMES));
  return g * duck;
};
