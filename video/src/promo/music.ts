/**
 * The promo's music: Measured_Steps.mp3 (made by the user with Gemini, instrumental, 67.5 s, about 119.7 BPM; the file is not committed,
 * public/audio is ignored). One continuous take from film frame 0 with no cut, gap or restart, source = film, so trimBefore is 0.
 * The quiet intro lifts hard at source 16.09 s, which is film frame 483; the first host switch (frame 498) is the next beat, and the
 * arrangement fades out by itself from 64.0 s: measured on the file, the last 5 ms block above -80 dBFS ends at 65.99 s, so the film
 * (66.10 s) ends 0.11 s after the fade is silent and nothing is cut or faded by the edit. Pure: node can import it.
 */
import { FRAMES } from './timeline.ts';
import type { MusicSegment } from '../film/music.ts';

export type { MusicSegment };

/** Length of Measured_Steps.mp3 (ffmpeg decode) and the source second after which it is silent (last 5 ms block above -80 dBFS: 65.985 s). */
export const FILE_SECONDS = 67.5;
export const FADE_SILENT_FROM = 65.99;

/** The beat grid, fitted to the kick attacks from the lift on (residual 21 ms rms; the strong onset of every beat sits 0 to 30 ms after it). */
export const BEAT_T0 = 16.09;
export const BEAT_PERIOD = 0.50108;

/** The film frame of the lift (source BEAT_T0 minus the trim, which is 0). */
export const LIFT_FRAME = 483;

/** Frames from the nearest beat to a film frame (positive: the frame is after the beat), for a track played from source frame trimBefore. */
export const beatOffsetFrames = (frame: number, trimBefore: number): number => {
  const src = frame + trimBefore;
  const k = Math.round((src / 30 - BEAT_T0) / BEAT_PERIOD);
  return src - (BEAT_T0 + k * BEAT_PERIOD) * 30;
};

/** Overall level of the music before the voice duck, set by measuring the render. */
const BASE = 0.35;

export const PROMO_MUSIC: readonly MusicSegment[] = [{ id: 'promo', file: 'audio/Measured_Steps.mp3', from: 0, to: FRAMES, shift: 0, trimBefore: 0, base: BASE }];
