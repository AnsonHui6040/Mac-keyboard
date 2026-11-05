/** Scene 15: a double click is one press step plus a second ring the screen draws itself. Pure frame maths, so tests can check it. */
import { PRESS_FRAMES } from '../lib/pointer.ts';

/** Frames between the two press peaks. */
export const DOUBLE_CLICK_GAP = 10;

/** Press strength (0 to 1) of a pulse peaking at `peak`: the same triangle over PRESS_FRAMES that pointerAt gives a press. */
export const pulseAt = (beatFrame: number, peak: number): number => {
  const half = PRESS_FRAMES / 2;
  return Math.max(0, 1 - Math.abs(beatFrame - peak) / half);
};

/** Peak frame of the second press, given the step's `land` (peak of the first press). */
export const secondPeak = (land: number): number => land + DOUBLE_CLICK_GAP;
