/**
 * The promo's music: none yet. The user picks a track from the YouTube audio library; Task 7 fills PROMO_MUSIC with one entry per
 * stretch of the file (the same shape as film/music.ts) and Promo.tsx plays whatever is listed. Pure: node can import it.
 */
import type { MusicSegment } from '../film/music.ts';

export type { MusicSegment };
export const PROMO_MUSIC: readonly MusicSegment[] = [];
