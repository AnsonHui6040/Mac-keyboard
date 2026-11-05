/**
 * Scene 11: the magnified option label. The real row is drawn tiny (the iPhone shrinks the long label to fit one line),
 * so while the good callout is on, a card to the left of the phone shows the same text large, joined to the row by a
 * thin line. Pure numbers in canvas pixels, so tests can check the card stays clear of the phone, the device tag and the subtitle divider.
 */
import { SCREENS, type Rect } from './geometry.ts';
import { theme } from '../theme.ts';

export const INSET_LINES = ['Keep App Extensions', '(Register App ID for Each Extension)'] as const;
/** Medium weight, never below 30 px. */
export const INSET_SIZE = 32;
export const INSET_WEIGHT = 500;
export const INSET_LINE_HEIGHT = 1.45;
export const INSET_PAD_X = 24;
export const INSET_PAD_Y = 20;
export const INSET_RING_WIDTH = 5;
/** The card keeps clear of the stage margin (72) and of the phone bezel by at least this much. */
export const INSET_X = 72 + INSET_RING_WIDTH / 2;
export const INSET_RIGHT_MAX = 700 - INSET_RING_WIDTH / 2;

/** The good callout's ring sits this far outside the row (theme.callout.ringGap); the leader ends on the ring. */
const row = SCREENS.extDialog.keepEach;

const textHeight = INSET_LINES.length * INSET_SIZE * INSET_LINE_HEIGHT;
export const INSET_HEIGHT = Math.round(textHeight + INSET_PAD_Y * 2);
/** Width of the card; the text is centered in it. */
export const INSET_WIDTH = INSET_RIGHT_MAX - INSET_X;

/** The card, vertically centered on the row so the leader line is a horizontal line. */
export const INSET_CARD: Rect = { x: INSET_X, y: Math.round(row.y + row.height / 2 - INSET_HEIGHT / 2), width: INSET_WIDTH, height: INSET_HEIGHT };

/** Leader line: from the card's right edge to the left edge of the row's green ring, at the row's center height. */
export const INSET_LEADER = {
  x1: INSET_CARD.x + INSET_CARD.width,
  x2: row.x - theme.callout.ringGap,
  y: row.y + row.height / 2,
  width: 3,
};

