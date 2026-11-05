/** The calendar of scene 21: a month of 31 days, seven to a row, the first seven marked. */
export const CARD = { x: 130, y: 130, width: 980, height: 640 };
const CELL_W = 124;
const CELL_H = 92;
const GAP = 8;
const GRID_X = CARD.x + 32;
const GRID_Y = CARD.y + 32 + 60 + 24;
export const DAYS = 31;
export const MARKED_DAYS = 7;
/** Frames into the first beat when day 1 is marked, and between two days. */
export const MARK_START = 8;
export const MARK_PITCH = 9;

export const cellRect = (day: number): { x: number; y: number; width: number; height: number } => ({
  x: GRID_X + ((day - 1) % 7) * (CELL_W + GAP),
  y: GRID_Y + Math.floor((day - 1) / 7) * (CELL_H + GAP),
  width: CELL_W,
  height: CELL_H,
});
