/**
 * The maths of a close-up slab (Slab.tsx), as the engine composes it: the plane point `f` goes to the centre of the layer at
 * (960 + tx, 540 + ty), the plane is scaled by `mag` and rolled, then turned by rotateX (pitch) and rotateY (yaw) about that point,
 * and the camera (eye over the middle of the canvas, `persp` away) magnifies a point `z` toward the viewer by persp / (persp - z).
 * Pure: node can import it.
 */
export type SlabParams = { mag: number; pitch: number; roll: number; yaw: number; tx: number; ty: number; persp: number; focusH: number; pool?: number };
export type Pt = { x: number; y: number };

const rad = (d: number): number => (d * Math.PI) / 180;
export const CANVAS = { w: 1920, h: 1080 } as const;

/** A point (x, y) of the plane, with the focus (fx, fy) in the middle, on the 1920 by 1080 frame. */
export const projectSlab = (p: SlabParams, fx: number, fy: number, x: number, y: number): Pt => {
  const sx = p.mag * (x - fx);
  const sy = p.mag * (y - fy);
  const dx = sx * Math.cos(rad(p.roll)) - sy * Math.sin(rad(p.roll));
  const dy = sx * Math.sin(rad(p.roll)) + sy * Math.cos(rad(p.roll));
  const x1 = dx * Math.cos(rad(p.yaw));
  const z1 = -dx * Math.sin(rad(p.yaw));
  const y2 = dy * Math.cos(rad(p.pitch)) - z1 * Math.sin(rad(p.pitch));
  const z2 = dy * Math.sin(rad(p.pitch)) + z1 * Math.cos(rad(p.pitch));
  const s = p.persp / (p.persp - z2);
  const cx = CANVAS.w / 2;
  const cy = CANVAS.h / 2;
  return { x: cx + (p.tx + x1) * s, y: cy + (p.ty + y2) * s };
};
