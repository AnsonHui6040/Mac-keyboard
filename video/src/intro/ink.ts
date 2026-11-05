/**
 * The 香港 handwriting of scene 3a. Points were traced from docs/manual/images/kb-handwriting.png (782 px high, pad top at 169)
 * and moved up by 27 so they sit on kb-handwriting-empty.png (755 px high, pad top at 141), where the picture is drawn.
 * Image coordinates; pure numbers.
 */
import { HW_SHIFT } from './layout.ts';

export type Pt = [number, number];

const TRACED: Pt[][] = [
  // 香: the turn at the left (diagonal down to the left, then across), the downstroke, the slash, the bar, the box and its inner bar
  [[237, 254], [215, 266], [190, 290], [165, 318], [143, 341], [175, 336], [210, 328], [250, 317], [283, 298]],
  [[223, 281], [226, 310], [228, 345], [230, 372], [237, 384]],
  [[214, 333], [200, 347], [185, 366], [170, 381]],
  [[200, 357], [240, 355], [288, 350]],
  [[202, 404], [205, 435], [207, 465], [212, 483]],
  [[209, 420], [225, 405], [250, 396], [280, 392], [295, 396], [299, 420], [300, 445], [298, 462], [288, 470]],
  [[223, 437], [250, 435], [277, 434]],
  [[222, 471], [240, 478], [262, 482], [280, 478], [290, 470]],
  // 港: two dots and a dash, the bar, two uprights, the long slash, the cross bar with its hook, the hook, the big curve
  [[346, 292], [346.2, 292.2]],
  [[348, 350], [348.2, 350.2]],
  [[335, 442], [352, 435], [371, 425]],
  [[403, 299], [430, 293], [465, 282], [502, 262]],
  [[441, 268], [442, 300], [443, 330], [444, 350]],
  [[477, 272], [478, 300], [478, 325], [473, 337]],
  [[544, 311], [520, 319], [480, 330], [450, 350], [425, 378], [402, 410]],
  [[418, 357], [450, 357], [490, 358], [520, 358], [530, 366], [531, 375]],
  [[456, 402], [473, 398], [485, 399], [488, 408], [481, 415]],
  [[448, 417], [441, 435], [433, 460], [432, 483], [445, 497], [470, 502], [500, 502], [518, 498], [522, 483], [523, 470]],
];

export const STROKES: readonly (readonly Pt[])[] = TRACED.map((s) => s.map(([x, y]): Pt => [x, y - HW_SHIFT]));

export const INK_START = 556;
export const INK_END = 646;
export const INK_WIDTH = 8;
/** The candidates show this many frames after the last stroke ends and the finger leaves. */
export const HW_CANDIDATE_DELAY = 8;

export const strokeLength = (s: readonly Pt[]): number => {
  let n = 0;
  for (let i = 1; i < s.length; i++) n += Math.hypot(s[i][0] - s[i - 1][0], s[i][1] - s[i - 1][1]);
  return n;
};

/** When each stroke is drawn: frames proportional to length (at least 2), one frame of lift between strokes, all inside INK_START to INK_END. */
export const strokeSchedule = (): { from: number; to: number }[] => {
  const lens = STROKES.map(strokeLength);
  const budget = INK_END - INK_START - (STROKES.length - 1);
  const total = lens.reduce((a, b) => a + b, 0);
  const raw = lens.map((l) => Math.max(2, (l / total) * budget));
  const scale = budget / raw.reduce((a, b) => a + b, 0);
  let t = INK_START;
  return raw.map((r) => {
    const from = Math.round(t);
    t += r * scale;
    const to = Math.max(from + 2, Math.round(t));
    t = to + 1;
    return { from, to };
  });
};

/** The part of a stroke drawn at progress u (0 to 1) along its length. */
export const partialStroke = (s: readonly Pt[], u: number): Pt[] => {
  const total = strokeLength(s);
  let left = Math.max(0, Math.min(1, u)) * total;
  const out: Pt[] = [[s[0][0], s[0][1]]];
  for (let i = 1; i < s.length; i++) {
    const seg = Math.hypot(s[i][0] - s[i - 1][0], s[i][1] - s[i - 1][1]);
    if (left >= seg) {
      out.push([s[i][0], s[i][1]]);
      left -= seg;
    } else {
      const k = seg === 0 ? 0 : left / seg;
      out.push([s[i - 1][0] + (s[i][0] - s[i - 1][0]) * k, s[i - 1][1] + (s[i][1] - s[i - 1][1]) * k]);
      break;
    }
  }
  return out;
};

/** Where the fingertip is on stroke i at a frame. */
export const strokePoint = (s: readonly Pt[], u: number): Pt => {
  const p = partialStroke(s, u);
  return p[p.length - 1];
};
