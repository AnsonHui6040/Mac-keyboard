/**
 * The cameras of the close-up cuts of the v0.2 promo (cuts.ts). Every one is locked: a fixed framing that does not look at where a
 * finger or a typed letter is, so nothing shakes. The only motion is a constant slow push (mag grows linearly), and the quick page
 * pans along its candidate row at one speed. The kinds of shot follow the old film (film/cameras.ts):
 *   typing and Mac   oblique, a fixed framing on the text
 *   draft            straight on, sharp all over
 *   handwriting      seen from above, rolled a little, sharp all over
 *   quick            oblique with a slow pan
 *   status cell      straight on, sharp, about 2.4 times, the cell in the middle
 *   Windows, Linux   oblique like the Mac, the text at size 52
 * Positions are in device coordinates (the phone's 720 wide screen with its bottom edge at 864, the 1280 by 800 computer screens).
 * Pure: node can import it.
 */
import { DOC_LINE, PHONE_TOP } from '../film/layout.ts';
import { textWidth } from '../film/metrics.ts';
import type { Pt, SlabParams } from '../film/slabMath.ts';
import { cutById } from './cuts.ts';

export type Device = 'phone' | 'mac' | 'win' | 'linux';
export type CloseCam = { dev: Device; p: SlabParams; /** the plane point in the middle of the frame, plane coordinates */ fx: number; fy: number; sharp: boolean };

/** Share of its size the picture grows each second. */
export const PUSH = 0.012;
/** Plane pixels the pan of the quick cut moves each frame. */
export const PAN = 0.5;

/** The Windows screen: the Notepad window and the taskbar under it. The text is at size 52 like the Mac. */
export const WIN_DOC = { x: 140, y: 64, w: 1000, h: 640, bar: 56, menu: 48, textX: 196, textY: 200, size: 52 } as const;
export const WIN_TASKBAR = { y: 752, h: 48 } as const;
/** The Linux screen: the top bar, the dock on the left and the editor window. */
export const LIN_DOC = { x: 150, y: 96, w: 1010, h: 620, bar: 60, textX: 206, textY: 220, size: 52 } as const;
export const LIN_TOP = 36;
export const LIN_DOCK = 72;

type Spec = { dev: Device; p: SlabParams; at: Pt; push?: number; pan?: number; sharp?: boolean };
type Base = Omit<SlabParams, 'mag' | 'tx' | 'ty'>;
const phoneOblique: Base = { pitch: 30, roll: -9, yaw: 7, persp: 1300, focusH: 150 };
const macOblique: Base = { pitch: 28, roll: 6, yaw: -5, persp: 1350, focusH: 80 };
const straight: Base = { pitch: 0, roll: 0, yaw: 0, persp: 1300, focusH: 100 };
const above: Base = { pitch: 0, roll: -8, yaw: 0, persp: 1300, focusH: 100 };
const P = (base: Base, mag: number, tx = 0, ty = 0): SlabParams => ({ ...base, mag, tx, ty });

const lineY = (i: number): number => 168 + (i + 0.5) * 52 * DOC_LINE;
const lineMid = (text: string, back = 0): number => 96 + textWidth(text, 52, 500) / 2 - back;
/** Straight-on keyboard: the bottom edge of the page lands near the bottom of the frame whatever page it is, so the top varies. */
const straightAt = (mag: number, bottom: number): Pt => ({ x: 360, y: 864 - (bottom - 540) / mag });
/** The middle of the whole toolbar width at the height of the status cell (device y of its centre). */
const cellAt = (centreY: number): Pt => ({ x: 360, y: centreY });

const SPECS: Record<string, Spec> = {
  // segment 2: live on the phone, the Mac, the draft, the Mac
  '2a': { dev: 'phone', p: P(phoneOblique, 1.9, 0, 0), at: { x: 360, y: 492 } },
  '2b': { dev: 'mac', p: P(macOblique, 1.6, 0, 60), at: { x: lineMid('Hello from my iPhone', 90), y: lineY(0.5) } },
  '2c': { dev: 'phone', p: P(straight, 1.35), at: straightAt(1.35, 1075), sharp: true },
  '2d': { dev: 'mac', p: P(macOblique, 1.6, 0, 60), at: { x: lineMid('Check before sending', 100), y: lineY(1) } },
  // segments 3, 5, 7: the tap on the status cell
  '3': { dev: 'phone', p: P(straight, 2.0), at: cellAt(263), sharp: true },
  '5': { dev: 'phone', p: P(straight, 2.0), at: cellAt(116), sharp: true },
  '7': { dev: 'phone', p: P(straight, 2.0), at: cellAt(272), sharp: true },
  // segment 4: handwriting, the candidates, Windows
  '4a': { dev: 'phone', p: P(above, 1.1, 0, 100), at: { x: 360, y: 109 + 377 }, sharp: true },
  '4b': { dev: 'phone', p: P(above, 1.4, 0, 80), at: { x: 360, y: 455 }, sharp: true },
  '4c': { dev: 'win', p: P({ ...macOblique, focusH: 130 }, 1.5, 0, -90), at: { x: 620, y: 240 } },
  // segment 6: quick, Linux
  '6a': { dev: 'phone', p: P({ ...phoneOblique, focusH: 220 }, 1.4, 0, -55), at: { x: 330, y: 373 }, push: 0, pan: PAN },
  '6b': { dev: 'linux', p: P({ ...macOblique, focusH: 130 }, 1.5, 0, -60), at: { x: 620, y: 250 } },
};

export const CLOSE_IDS: readonly string[] = Object.keys(SPECS);

/** A point of the device in the plane the Slab draws (the phone's plane starts at the top of its tallest page). */
export const toPlane = (dev: Device, pt: Pt): Pt => (dev === 'phone' ? { x: pt.x, y: pt.y - PHONE_TOP } : pt);

export const closeCam = (id: string, frame: number): CloseCam => {
  const s = SPECS[id];
  const l = frame - cutById(id).from;
  const at = toPlane(s.dev, s.at);
  const mag = s.p.mag * (1 + ((s.push ?? PUSH) * l) / 30);
  return { dev: s.dev, p: { ...s.p, mag }, fx: at.x + (s.pan ?? 0) * l, fy: at.y, sharp: s.sharp ?? false };
};
