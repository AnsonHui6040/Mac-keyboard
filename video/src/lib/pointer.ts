/** Pure pointer timing: ease-out cubic travel between cues, then an optional press pulse. */

export type PointerCue = { from: number; x: number; y: number; press: boolean };
export type PointerState = { x: number; y: number; visible: boolean; press: number };

export const TRAVEL_SECONDS = 0.6;
export const SETTLE_SECONDS = 0.5;
export const PRESS_FRAMES = 8;

const easeOutCubic = (t: number): number => 1 - Math.pow(1 - t, 3);

/** Position of the pointer at `frame` while heading for `cue`, starting from (sx, sy). */
function travel(frame: number, cue: PointerCue, sx: number, sy: number, travelFrames: number) {
  if (frame - cue.from >= travelFrames) return { x: cue.x, y: cue.y };
  const t = Math.min(1, Math.max(0, (frame - cue.from) / travelFrames));
  const e = easeOutCubic(t);
  return { x: sx + (cue.x - sx) * e, y: sy + (cue.y - sy) * e };
}

/**
 * Pointer state at a frame. Hidden before the first cue; the first cue appears
 * in place at its target. Each later cue starts moving from wherever the
 * pointer is at that cue's `from`, arrives 0.6 s later, waits 0.5 s, then (if
 * `press`) pulses 0 -> 1 -> 0 over 8 frames.
 */
export function pointerAt(frame: number, cues: PointerCue[], fps: number): PointerState {
  if (cues.length === 0 || frame < cues[0].from) {
    const first = cues[0];
    return { x: first ? first.x : 0, y: first ? first.y : 0, visible: false, press: 0 };
  }
  const travelFrames = Math.round(TRAVEL_SECONDS * fps);
  const settleFrames = Math.round(SETTLE_SECONDS * fps);

  // Walk cues in time order, tracking where the pointer is at each cue's start.
  let active = 0;
  let sx = cues[0].x;
  let sy = cues[0].y;
  for (let i = 1; i < cues.length && cues[i].from <= frame; i++) {
    const prev = cues[i - 1];
    const at = travel(cues[i].from, prev, sx, sy, travelFrames);
    sx = at.x;
    sy = at.y;
    active = i;
  }
  const cue = cues[active];
  const pos = travel(frame, cue, sx, sy, travelFrames);

  let press = 0;
  if (cue.press) {
    const p = frame - (cue.from + travelFrames + settleFrames);
    if (p >= 0 && p <= PRESS_FRAMES) {
      const half = PRESS_FRAMES / 2;
      press = 1 - Math.abs(p - half) / half;
    }
  }
  return { x: pos.x, y: pos.y, visible: true, press };
}
