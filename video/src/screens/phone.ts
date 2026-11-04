/** Canvas geometry of the iPhone drawn by IPhoneFrame. Pure numbers, so geometry.ts and tests can import them. */
import type { Rect } from './geometry.ts';

/** Logical iPhone screen size in points; iPhone screens are drawn in this space. */
export const PHONE_LOGICAL = { width: 390, height: 844 } as const;
/** Canvas pixels per logical point: the screen is about 367 x 793 px, under the 800 px limit. */
export const PHONE_SCALE = 0.94;
export const PHONE_SCREEN_W = PHONE_LOGICAL.width * PHONE_SCALE;
export const PHONE_SCREEN_H = PHONE_LOGICAL.height * PHONE_SCALE;
export const PHONE_BEZEL = 14;

export type PhoneOrigin = { x: number; y: number };

/** Canvas position of the screen's top-left corner when the phone is alone: centered across the stage, 48 px from the top. */
export const PHONE_ORIGIN: PhoneOrigin = { x: (1920 - PHONE_SCREEN_W) / 2, y: 48 };
/** Screen top-left for a phone to the right of a Mac window (a window may end at x=1460). Bezel spans x 1486 to 1881. */
export const PHONE_ORIGIN_RIGHT: PhoneOrigin = { x: 1500, y: 48 };

/** Maps a rect in the logical 390 x 844 screen to canvas pixels. */
export const phoneRect = (r: Rect, origin: PhoneOrigin = PHONE_ORIGIN): Rect => ({
  x: origin.x + r.x * PHONE_SCALE,
  y: origin.y + r.y * PHONE_SCALE,
  width: r.width * PHONE_SCALE,
  height: r.height * PHONE_SCALE,
});

/** Canvas bottom of the whole device, bezel included. Stays above the subtitle divider (y=884). */
export const phoneBottom = (origin: PhoneOrigin = PHONE_ORIGIN): number => origin.y + PHONE_SCREEN_H + PHONE_BEZEL;
/** Canvas right edge of the whole device, bezel included. */
export const phoneRight = (origin: PhoneOrigin = PHONE_ORIGIN): number => origin.x + PHONE_SCREEN_W + PHONE_BEZEL;
