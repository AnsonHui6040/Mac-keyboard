/** Data-driven scenes: a SceneSpec lists, per subtitle beat, the screen, the device, the pointer steps and the labels. compileScene turns it into frames. */
import { SCREENS, restPoint } from '../screens/geometry.ts';
import { beatTimeline, splitBeats } from './captions.ts';
import { PRESS_FRAMES, SETTLE_SECONDS, TRAVEL_SECONDS, type PointerCue } from './pointer.ts';

export type Device = 'mac' | 'iphone';
/**
 * One pointer move to a target, optionally followed by a press. A drag has no pointer model of its own: it is a
 * sequence of steps without `press`, and the screen draws the dragged item at the `pointer` position it is given.
 */
export type Step = { target: string; press?: boolean };
export type Label = { target: string; kind: 'good' | 'bad'; head?: string };
/**
 * `hidePointer`: the pointer fades out over HIDE_FRAMES frames from the start of this beat and stays hidden to its end.
 * For a beat that shows a result and has no steps of its own (the tap ring would rest on an empty spot); a beat with steps cannot use it.
 */
export type BeatSpec = { screen: string; device?: Device; steps?: Step[]; labels?: Label[]; minSeconds?: number; hidePointer?: boolean };
export type SceneSpec = { n: number; beats: BeatSpec[] };
export type Span = { from: number; to: number };

/** Pointer cues of consecutive beats on one device. The pointer is drawn only while the run lasts. */
export type PointerRun = { device: Device; from: number; to: number; cues: PointerCue[] };

/** When a step happens, in frames since its beat started: `start` is when the pointer begins moving to the target, `land` when it arrives (a step without a press) or when its press peaks. */
export type StepTime = { start: number; land: number };

export type CompiledScene = {
  beats: string[];
  timeline: Span[];
  /** Per beat, per step: when the step starts and lands. Screens use it to show a step's result after it happens. */
  stepTimes: StepTime[][];
  /** Every run's cues, in order. */
  cues: PointerCue[];
  runs: PointerRun[];
  deviceAt(frame: number): Device | undefined;
  beatAt(frame: number): number;
  /** Opacity factor of the pointer from `hidePointer` beats: 1 normally, 1 to 0 over HIDE_FRAMES from such a beat's start, 0 to its end. */
  pointerHide(frame: number): number;
};

/** Frames of the cross fade when the screen changes at the start of a beat. */
export const FADE_FRAMES = 8;
/** Frames a `hidePointer` beat takes to fade the pointer out. */
export const HIDE_FRAMES = 8;
/** The pointer starts this many px below its first target and travels in. */
export const ENTRY_OFFSET = 120;
/** One step needs travel (18) + hold (15) + press (8) frames; a step without a press needs travel + hold. */
export const PRESS_STEP_FRAMES = 41;
export const PLAIN_STEP_FRAMES = 33;

export const DEFAULT_HEAD = { good: '按這個', bad: '不要按' } as const;

const stepFrames = (s: Step): number => (s.press ? PRESS_STEP_FRAMES : PLAIN_STEP_FRAMES);

/** The pointer's first step in a run starts one frame late (the entry cue takes the first frame), so a press there needs one more frame. */
export const ENTRY_CUE_FRAMES = 1;

/**
 * Smallest beat length that fits its steps spaced evenly: every slot must hold the slowest step. `startsRun` is true
 * when this beat holds the first step of a pointer run; a press there needs 42 frames, not 41.
 */
export const beatStepFrames = (steps: Step[] | undefined, startsRun = false): number => {
  if (!steps || steps.length === 0) return 0;
  const first = stepFrames(steps[0]) + (startsRun && steps[0].press ? ENTRY_CUE_FRAMES : 0);
  return steps.length * Math.max(first, ...steps.slice(1).map(stepFrames));
};

const hasTarget = (screen: string, target: string): boolean =>
  Object.hasOwn(SCREENS, screen) && Object.hasOwn(SCREENS[screen], target);

/**
 * Compile a scene against its caption and length. Throws, naming the scene, when the beat count differs from the
 * subtitle beats, a beat has steps but no device, a screen or target is unknown, or the beats (including the frames their steps need) do not fit.
 */
export function compileScene(spec: SceneSpec, caption: string, seconds: number, fps: number): CompiledScene {
  const where = `scene ${spec.n}`;
  const beats = splitBeats(caption);
  if (beats.length !== spec.beats.length) throw new Error(`${where}: ${beats.length} subtitle beats but ${spec.beats.length} planned`);

  spec.beats.forEach((b, i) => {
    if (!Object.hasOwn(SCREENS, b.screen)) throw new Error(`${where}: beat ${i} uses unknown screen ${b.screen}`);
    if (b.steps && b.steps.length > 0 && !b.device) throw new Error(`${where}: beat ${i} has steps but no device`);
    if (b.hidePointer && b.steps && b.steps.length > 0) throw new Error(`${where}: beat ${i} hides the pointer but has steps`);
    for (const t of [...(b.steps ?? []), ...(b.labels ?? [])]) {
      if (!hasTarget(b.screen, t.target)) throw new Error(`${where}: beat ${i} has no ${t.target} on ${b.screen}`);
    }
  });

  // Which beats hold the first step of a pointer run (consecutive beats on one device).
  const startsRun: boolean[] = [];
  let runDevice: Device | undefined;
  let runHasStep = false;
  spec.beats.forEach((b, i) => {
    if (b.device !== runDevice) {
      runDevice = b.device;
      runHasStep = false;
    }
    const hasSteps = !!b.device && (b.steps?.length ?? 0) > 0;
    startsRun[i] = hasSteps && !runHasStep;
    if (hasSteps) runHasStep = true;
  });

  const minSeconds = spec.beats.map((b, i) => {
    const need = beatStepFrames(b.steps, startsRun[i]) / fps;
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
  const stepTimes: StepTime[][] = spec.beats.map(() => []);
  const travel = Math.round(TRAVEL_SECONDS * fps);
  const settle = Math.round(SETTLE_SECONDS * fps);
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
      const moveFrom = run!.cues.length === 0 ? from + 1 : from;
      stepTimes[i][k] = { start: moveFrom - span.from, land: moveFrom - span.from + travel + settle + (step.press ? PRESS_FRAMES / 2 : 0) };
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
  const pointerHide = (frame: number): number => {
    const i = beatAt(frame);
    if (!spec.beats[i].hidePointer) return 1;
    return Math.min(1, Math.max(0, 1 - (frame - timeline[i].from) / HIDE_FRAMES));
  };
  return {
    beats,
    timeline,
    stepTimes,
    cues: shown.flatMap((r) => r.cues),
    runs: shown,
    deviceAt: (frame) => spec.beats[beatAt(frame)]?.device,
    beatAt,
    pointerHide,
  };
}

/** First beat index of the run of consecutive beats (ending at `i`) that all carry the same label (kind and target). */
export function labelRunStart(spec: SceneSpec, i: number, label: Label): number {
  const same = (b: BeatSpec) => b.labels?.some((l) => l.kind === label.kind && l.target === label.target) ?? false;
  let s = i;
  while (s > 0 && same(spec.beats[s - 1])) s--;
  return s;
}
