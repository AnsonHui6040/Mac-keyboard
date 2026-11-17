/** The subtitle file of the promo: captions from narration.ts, times from the timeline. */
import { NARRATION } from './narration.ts';
import { FPS, voice } from './timeline.ts';

const pad = (n: number, w: number): string => String(n).padStart(w, '0');
const stamp = (frame: number): string => {
  const ms = Math.round((frame * 1000) / FPS);
  return `${pad(Math.floor(ms / 3600000), 2)}:${pad(Math.floor(ms / 60000) % 60, 2)}:${pad(Math.floor(ms / 1000) % 60, 2)},${pad(ms % 1000, 3)}`;
};

export const toSrt = (): string =>
  NARRATION.map((n, i) => {
    const v = voice(n.id);
    return `${i + 1}\n${stamp(v.from)} --> ${stamp(v.to)}\n${n.caption}\n`;
  }).join('\n');
