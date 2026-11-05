/** Which finger source is drawn on the phone at a frame: the keyboard finger (script.ts) up to the moment the pad fingers appear, then the pad fingers (trackpad.ts). Never both. Pure. */
import { FINGERS_FROM, FINGERS_TO } from './trackpad.ts';
import type { Chapter } from './timeline.ts';

export const fingerSource = (frame: number, chapter: Chapter): 'phone' | 'pad' => (chapter === 0 && frame >= FINGERS_FROM && frame < FINGERS_TO ? 'pad' : 'phone');
