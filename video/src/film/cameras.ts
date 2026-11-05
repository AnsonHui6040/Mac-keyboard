/**
 * The cameras of the close-up shots (2 to 20). Every one is a locked shot: a fixed framing that does not look at where a finger or
 * a typed letter is, so nothing shakes. The only motion is a constant slow push (mag grows linearly), and shot 18 pans along its
 * candidate row at one speed. Each section has its own kind of shot:
 *   typing      oblique, three letter rows in focus
 *   draft       straight on, sharp all over, the keyboard panel floating on black
 *   handwriting seen from above, rolled a little, sharp all over
 *   quick       oblique with a slow pan
 *   Mac         oblique, a fixed framing on the text
 * Positions are in device coordinates (the phone's 720 wide screen with its bottom edge at 864, the Mac's 1280 by 800 screen).
 * Pure: node can import it.
 */
import { DOC, DOC_LINE, PHONE_TOP } from './layout.ts';
import { textWidth } from './metrics.ts';
import { shotById } from './timeline.ts';
import type { Pt, SlabParams } from './slabMath.ts';

export type Device = 'phone' | 'mac';
export type CloseCam = { dev: Device; p: SlabParams; /** the plane point in the middle of the frame, plane coordinates */ fx: number; fy: number; sharp: boolean };

/** Share of its size the picture grows each second. */
export const PUSH = 0.012;
/** Plane pixels the pan of shot 18 moves each frame. */
export const PAN = 0.5;

type Spec = { dev: Device; p: SlabParams; at: Pt; push?: number; pan?: number; sharp?: boolean };
const phoneOblique: Omit<SlabParams, 'mag' | 'tx' | 'ty'> = { pitch: 30, roll: -9, yaw: 7, persp: 1300, focusH: 150 };
const macOblique: Omit<SlabParams, 'mag' | 'tx' | 'ty'> = { pitch: 28, roll: 6, yaw: -5, persp: 1350, focusH: 80 };
const straight: Omit<SlabParams, 'mag' | 'tx' | 'ty'> = { pitch: 0, roll: 0, yaw: 0, persp: 1300, focusH: 100 };
const above: Omit<SlabParams, 'mag' | 'tx' | 'ty'> = { pitch: 0, roll: -8, yaw: 0, persp: 1300, focusH: 100 };
const P = (base: Omit<SlabParams, 'mag' | 'tx' | 'ty'>, mag: number, tx = 0, ty = 0): SlabParams => ({ ...base, mag, tx, ty });

const lineY = (i: number): number => DOC.textY + (i + 0.5) * DOC.size * DOC_LINE;
/** Middle of a line of the document, moved left by `back` so the desktop icons at the right of the screen fall out of the frame. */
const lineMid = (text: string, back = 0): number => DOC.textX + textWidth(text, DOC.size, 500) / 2 - back;
/** Straight-on keyboard: the bottom edge of the page lands near the bottom of the frame whatever page it is, so the top varies. */
const straightAt = (mag: number, bottom: number): Pt => ({ x: 360, y: 864 - (bottom - 540) / mag });
/** Straight-on keyboard whose tallest page (the writing page) starts at y 220 of the frame, the lower rows running out of it. */
const straightFrom = (mag: number): Pt => ({ x: 360, y: PHONE_TOP + 320 / mag });

const SPECS: Record<string, Spec> = {
  // typing
  '2': { dev: 'phone', p: P(phoneOblique, 1.9, 0, 50), at: { x: 360, y: 492 } },
  '4': { dev: 'phone', p: P(phoneOblique, 1.9, 0, 50), at: { x: 360, y: 492 } },
  '6': { dev: 'phone', p: P(phoneOblique, 1.7, 0, 50), at: { x: 360, y: 530 } },
  '3': { dev: 'mac', p: P(macOblique, 2.6, 0, 60), at: { x: DOC.textX + 200, y: lineY(0) } },
  '5': { dev: 'mac', p: P(macOblique, 2.6, 0, 60), at: { x: DOC.textX + 200, y: lineY(0) } },
  '7': { dev: 'mac', p: P(macOblique, 1.6, 0, 60), at: { x: lineMid('Hello from my iPhone', 90), y: lineY(0) } },
  // draft
  '8': { dev: 'phone', p: P(straight, 1.35), at: straightAt(1.35, 1075), sharp: true },
  '9': { dev: 'phone', p: P(straight, 1.35), at: straightAt(1.35, 1075), sharp: true },
  '11': { dev: 'phone', p: P(straight, 2.0), at: { x: 360, y: 391 }, sharp: true },
  '12': { dev: 'phone', p: P(straight, 1.35), at: straightAt(1.35, 1075), sharp: true },
  '14': { dev: 'phone', p: P(straight, 1.35), at: straightFrom(1.35), sharp: true },
  '20': { dev: 'phone', p: P(straight, 1.35), at: straightAt(1.35, 1075), sharp: true },
  // handwriting
  '15': { dev: 'phone', p: P(above, 1.3, 0, 172), at: { x: 360, y: 437 }, sharp: true },
  '16': { dev: 'phone', p: P(above, 1.4), at: { x: 360, y: 455 }, sharp: true },
  // quick
  '18': { dev: 'phone', p: P({ ...phoneOblique, focusH: 220 }, 1.4, 0, -55), at: { x: 330, y: 373 }, push: 0, pan: PAN },
  // Mac results
  '10': { dev: 'mac', p: P(macOblique, 1.6, 0, 60), at: { x: lineMid('Hello from my iPhone', 90), y: lineY(0.5) } },
  '13': { dev: 'mac', p: P(macOblique, 1.6, 0, 60), at: { x: lineMid('Check before sending', 100), y: lineY(1) } },
  '17': { dev: 'mac', p: P(macOblique, 1.6, 0, 60), at: { x: lineMid('Check before sending', 100), y: lineY(1.5) } },
  '19': { dev: 'mac', p: P(macOblique, 1.4, 0, 60), at: { x: lineMid('Check before sending', 190), y: lineY(1.5) } },
};

export const CLOSE_IDS: readonly string[] = Object.keys(SPECS);

/** A point of the device in the plane the Slab draws (the phone's plane starts at the top of its tallest page). */
export const toPlane = (dev: Device, pt: Pt): Pt => (dev === 'phone' ? { x: pt.x, y: pt.y - PHONE_TOP } : pt);

export const closeCam = (id: string, frame: number): CloseCam => {
  const s = SPECS[id];
  const l = frame - shotById(id).from;
  const at = toPlane(s.dev, s.at);
  const mag = s.p.mag * (1 + ((s.push ?? PUSH) * l) / 30);
  return { dev: s.dev, p: { ...s.p, mag }, fx: at.x + (s.pan ?? 0) * l, fy: at.y, sharp: s.sharp ?? false };
};
