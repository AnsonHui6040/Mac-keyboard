/**
 * The promo's mix: the narration comes first, so the music and the effects dip while a line is spoken. The dip follows
 * voiceDuck, 1 inside a line and 0 outside, with a linear ramp of 0.25 s into and out of each line. Pure: node can import it.
 */
import { LIFT_FRAME } from './music.ts';
import { FPS, FRAMES, VOICE } from './timeline.ts';

const RAMP = Math.round(0.25 * FPS);
export const MUSIC_DUCK_DB = -10;
export const SFX_DUCK_DB = -6;
/** The track is about 11 dB quieter before its lift at LIFT_FRAME than after it. Until 15 frames before the lift the music is raised by this much, then it steps down over 12 frames while the source is still quiet, so the intro is not lost under the voice and the lift keeps about 5 dB. */
export const PRELIFT_DB = 6;
export const PRELIFT_RAMP = 12;
const PRELIFT_END = LIFT_FRAME - 3;

const clamp01 = (v: number): number => Math.min(1, Math.max(0, v));

/** 1 while a line is spoken, 0 well outside it, a linear ramp of 0.25 s before the line and after it. */
export const voiceDuck = (frame: number): number => {
  let d = 0;
  for (const v of VOICE) {
    const into = clamp01((frame - (v.from - RAMP)) / RAMP);
    const out = clamp01(((v.to + RAMP) - frame) / RAMP);
    d = Math.max(d, Math.min(into, out));
  }
  return d;
};

/** PRELIFT_DB before the lift ramp, 0 from the end of it. */
export const preLiftDb = (frame: number): number => PRELIFT_DB * clamp01((PRELIFT_END - frame) / PRELIFT_RAMP);

/** The additions of 0 turn a -0 into 0. */
export const musicGainDb = (frame: number): number => MUSIC_DUCK_DB * voiceDuck(frame) + preLiftDb(frame) + 0;
export const sfxGainDb = (frame: number): number => SFX_DUCK_DB * voiceDuck(frame) + 0;
/** The linear factor of a gain in dB. */
export const dbToGain = (db: number): number => 10 ** (db / 20);

/** The promo's sound effects play only into a context exactly as long as the film (within one sample). */
export const isPromoContext = (length: number, sampleRate: number): boolean => Math.abs(length - Math.round((FRAMES / FPS) * sampleRate)) <= 1;
