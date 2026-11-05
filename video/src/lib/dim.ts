/** Brightness of a device on a two-device screen: the inactive one sits at 40%, easing over 8 frames when the active device changes. */
import type { Device } from './sceneSpec.ts';

export const DIM_BRIGHTNESS = 0.4;
export const DIM_FRAMES = 8;

const easeOutCubic = (t: number): number => 1 - Math.pow(1 - t, 3);

/**
 * `active` is this beat's device (undefined: nothing is dimmed). `prevActive` is the previous beat's device when that
 * beat shows the same screen, otherwise undefined: then the brightness is already settled. `beatFrame` counts frames
 * since this beat started.
 */
export function deviceBrightness(device: Device, p: { active?: Device; prevActive?: Device; beatFrame: number }): number {
  const level = (active: Device | undefined): number => (active === undefined || active === device ? 1 : DIM_BRIGHTNESS);
  const to = level(p.active);
  if (p.prevActive === undefined || p.prevActive === p.active) return to;
  const from = level(p.prevActive);
  const t = Math.min(1, Math.max(0, p.beatFrame / DIM_FRAMES));
  return from + (to - from) * easeOutCubic(t);
}
