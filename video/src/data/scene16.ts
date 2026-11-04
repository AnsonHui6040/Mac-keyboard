/** Scene 16 plan: which screen, pointer target and callouts each subtitle beat has, and the pointer cues derived from them. */
import { beatTimeline } from '../lib/captions.ts';
import script from './script.json' with { type: 'json' };
import type { PointerCue } from '../lib/pointer.ts';
import { SCREENS, restPoint, type Rect, type ScreenId, type TargetId } from '../screens/geometry.ts';

export type Scene16Beat = {
  screen: ScreenId;
  target?: TargetId;
  press?: boolean;
  labels?: ('good' | 'bad')[];
  minSeconds?: number;
};

export const SCENE16_FPS = 30;
const entry = script.scenes.find((sc) => sc.n === 16);
if (!entry) throw new Error('script.json has no scene 16');
/** Scene 16 length in seconds, taken from the script. */
export const SCENE16_SECONDS: number = entry.seconds;
/** Scene 16 length in frames: seconds times fps, derived from the script. */
export const SCENE16_FRAMES = SCENE16_SECONDS * SCENE16_FPS;
/** Frames of the cross fade when the screen changes at the start of a beat. */
export const FADE_FRAMES = 8;
/** The pointer starts this many px below its first target and travels in. */
export const ENTRY_OFFSET = 120;

export const SCENE16_BEATS: Scene16Beat[] = [
  { screen: 'dialogBlocked' },
  { screen: 'dialogBlocked' },
  { screen: 'dialogBlocked', target: 'done', press: true },
  { screen: 'settingsSecurity', target: 'open', press: true },
  { screen: 'dialogConfirm', target: 'open', labels: ['good'] },
  { screen: 'dialogConfirm', target: 'open', labels: ['good', 'bad'], minSeconds: 4 },
  { screen: 'auth', target: 'password' },
];

export const targetRect = (screen: ScreenId, target: TargetId): Rect | undefined =>
  (SCREENS[screen] as Partial<Record<TargetId, Rect>>)[target];

export type Span = { from: number; to: number };

export const scene16Timeline = (beats: string[]): Span[] =>
  beatTimeline(beats, SCENE16_BEATS.map((b) => b.minSeconds), SCENE16_FRAMES, SCENE16_FPS);

/**
 * One cue per beat whose pointer position changes, always at the target's rest point. The first
 * cue starts ENTRY_OFFSET px below its target; the real cue follows one frame later so the
 * pointer visibly travels in. A beat with no new position (beat 5 stays on `open`) adds no cue.
 */
export function scene16Cues(timeline: Span[]): PointerCue[] {
  const cues: PointerCue[] = [];
  SCENE16_BEATS.forEach((b, i) => {
    if (!b.target) return;
    const rect = targetRect(b.screen, b.target);
    if (!rect) throw new Error(`scene16: beat ${i} has no ${b.target} on ${b.screen}`);
    const p = restPoint(rect);
    const from = timeline[i].from;
    if (cues.length === 0) {
      cues.push({ from, x: p.x, y: p.y + ENTRY_OFFSET, press: false });
      cues.push({ from: from + 1, x: p.x, y: p.y, press: !!b.press });
      return;
    }
    const last = cues[cues.length - 1];
    if (last.x === p.x && last.y === p.y && !b.press) return;
    cues.push({ from, x: p.x, y: p.y, press: !!b.press });
  });
  return cues;
}

/** First beat index of the run of consecutive beats (ending at `i`) that all carry `label`. */
export function labelRunStart(i: number, label: 'good' | 'bad'): number {
  let s = i;
  while (s > 0 && SCENE16_BEATS[s - 1].labels?.includes(label)) s--;
  return s;
}
