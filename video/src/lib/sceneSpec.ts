/** Data-driven scenes: a SceneSpec lists, per subtitle beat, the screen, the device, the pointer steps and the labels. compileScene turns it into frames. */
import { SCREENS, restPoint } from '../screens/geometry.ts';
import { beatTimeline, splitBeats } from './captions.ts';
import type { PointerCue } from './pointer.ts';

export type Device = 'mac' | 'iphone';
export type Step = { target: string; press?: boolean };
export type Label = { target: string; kind: 'good' | 'bad'; head?: string };
export type BeatSpec = { screen: string; device?: Device; steps?: Step[]; labels?: Label[]; minSeconds?: number };
export type SceneSpec = { n: number; beats: BeatSpec[] };
export type Span = { from: number; to: number };

/** Pointer cues of consecutive beats on one device. The pointer is drawn only while the run lasts. */
export type PointerRun = { device: Device; from: number; to: number; cues: PointerCue[] };

export type CompiledScene = {
  beats: string[];
  timeline: Span[];
  /** Every run's cues, in order. */
  cues: PointerCue[];
  runs: PointerRun[];
  deviceAt(frame: number): Device | undefined;
  beatAt(frame: number): number;
};

/** Frames of the cross fade when the screen changes at the start of a beat. */
export const FADE_FRAMES = 8;
/** The pointer starts this many px below its first target and travels in. */
export const ENTRY_OFFSET = 120;
/** One step needs travel (18) + hold (15) + press (8) frames; a step without a press needs travel + hold. */
export const PRESS_STEP_FRAMES = 41;
export const PLAIN_STEP_FRAMES = 33;

export const DEFAULT_HEAD = { good: '按這個', bad: '不要按' } as const;

const stepFrames = (s: Step): number => (s.press ? PRESS_STEP_FRAMES : PLAIN_STEP_FRAMES);

/** Smallest beat length that fits its steps spaced evenly: every slot must hold the slowest step. */
export const beatStepFrames = (steps: Step[] | undefined): number =>
  steps && steps.length > 0 ? steps.length * Math.max(...steps.map(stepFrames)) : 0;

const hasTarget = (screen: string, target: string): boolean =>
  Object.hasOwn(SCREENS, screen) && Object.hasOwn(SCREENS[screen], target);

/**
 * Compile a scene against its caption and length. Throws, naming the scene, when the beat count differs from the
 * subtitle beats, a target is missing from its screen, or the beats (including the frames their steps need) do not fit.
 */
export function compileScene(spec: SceneSpec, caption: string, seconds: number, fps: number): CompiledScene {
  const where = `scene ${spec.n}`;
  const beats = splitBeats(caption);
  if (beats.length !== spec.beats.length) throw new Error(`${where}: ${beats.length} subtitle beats but ${spec.beats.length} planned`);

  spec.beats.forEach((b, i) => {
    if (!Object.hasOwn(SCREENS, b.screen)) throw new Error(`${where}: beat ${i} uses unknown screen ${b.screen}`);
    for (const t of [...(b.steps ?? []), ...(b.labels ?? [])]) {
      if (!hasTarget(b.screen, t.target)) throw new Error(`${where}: beat ${i} has no ${t.target} on ${b.screen}`);
    }
  });

  const minSeconds = spec.beats.map((b) => {
    const need = beatStepFrames(b.steps) / fps;
    if (need === 0) return b.minSeconds;
    return Math.max(need, b.minSeconds ?? 0);
  });
  let timeline: Span[];
  try {
    timeline = beatTimeline(beats, minSeconds, Math.round(seconds * fps), fps);
  } catch (e) {
    throw new Error(`${where}: ${(e as Error).message}`);
  }

  const runs: PointerRun[] = [];
  let run: PointerRun | undefined;
  spec.beats.forEach((b, i) => {
    const span = timeline[i];
    if (!b.device || (run && run.device !== b.device)) run = undefined;
    if (!b.device) return;
    if (!run) {
      run = { device: b.device, from: span.from, to: span.to, cues: [] };
      runs.push(run);
    }
    run.to = span.to;
    const steps = b.steps ?? [];
    const slot = steps.length > 0 ? Math.floor((span.to - span.from) / steps.length) : 0;
    steps.forEach((step, k) => {
      const p = restPoint(SCREENS[b.screen][step.target]);
      const from = span.from + k * slot;
      if (run!.cues.length === 0) {
        run!.cues.push({ from, x: p.x, y: p.y + ENTRY_OFFSET, press: false });
        run!.cues.push({ from: from + 1, x: p.x, y: p.y, press: !!step.press });
        return;
      }
      const last = run!.cues[run!.cues.length - 1];
      if (last.x === p.x && last.y === p.y && !step.press) return;
      run!.cues.push({ from, x: p.x, y: p.y, press: !!step.press });
    });
  });
  const shown = runs.filter((r) => r.cues.length > 0);

  const beatAt = (frame: number): number => {
    const i = timeline.findIndex((t) => frame >= t.from && frame < t.to);
    return i === -1 ? timeline.length - 1 : i;
  };
  return {
    beats,
    timeline,
    cues: shown.flatMap((r) => r.cues),
    runs: shown,
    deviceAt: (frame) => spec.beats[beatAt(frame)]?.device,
    beatAt,
  };
}

/** First beat index of the run of consecutive beats (ending at `i`) that all carry the same label (kind and target). */
export function labelRunStart(spec: SceneSpec, i: number, label: Label): number {
  const same = (b: BeatSpec) => b.labels?.some((l) => l.kind === label.kind && l.target === label.target) ?? false;
  let s = i;
  while (s > 0 && same(spec.beats[s - 1])) s--;
  return s;
}
