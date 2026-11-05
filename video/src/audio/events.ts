/**
 * When the interface sounds happen, in film-global frames. Everything is derived from the compiled scene data (the same
 * pointer cues, step times, label runs and typing maths the pictures use), so a sound cannot drift from what is on screen.
 * Pure: no audio, no randomness, no clock. A film-global frame is the sum of the earlier scenes' frames plus the scene-local frame.
 */
import { FPS, SCENES, compileRegistered, sceneFrames } from '../data/scenes/index.ts';
import { IPA_NAME, ZIP_NAME } from '../data/artifacts.ts';
import { SETTLE_SECONDS, TRAVEL_SECONDS } from '../lib/pointer.ts';
import { labelRunStart, type SceneSpec } from '../lib/sceneSpec.ts';
import { commandText, typedChars } from '../screens/terminal.ts';
import { CONNECT_AT, TYPED_20, TYPE20_PITCH, TYPE20_START, typed20 } from '../screens/typing20.ts';

export type SoundKind = 'click' | 'tap' | 'key' | 'good' | 'bad' | 'success';
export type SoundEvent = { frame: number; kind: SoundKind };

/**
 * Scene 1's typing. The maths lives in screens/Typing.tsx, which node cannot import (JSX); these are copies, and a test
 * reads that file and fails if they ever differ.
 */
export const TYPED_01 = 'Hello Mac, this is typed on my iPhone';
export const TYPE01_START = 12;
export const TYPE01_PITCH = 7;
const typed01 = (localFrame: number): number =>
  localFrame < TYPE01_START ? 0 : Math.min(TYPED_01.length, Math.floor((localFrame - TYPE01_START) / TYPE01_PITCH) + 1);

/** The second success chime is dropped when it would come within this many frames (3 s) of the first. */
export const SUCCESS_GAP_FRAMES = 3 * FPS;

/** First film frame of scene `n`. */
export const sceneStart = (n: number): number => {
  let at = 0;
  for (const s of SCENES) {
    if (s.n === n) return at;
    at += sceneFrames(s.n);
  }
  throw new Error(`no scene ${n}`);
};

/** The success chimes of one scene: the first always, the second only when it is more than 3 s after the first. */
export const successFrames = (first: number, second: number): number[] => (second - first > SUCCESS_GAP_FRAMES ? [first, second] : [first]);

/** Frames in [from, to) at which `count` rises, once per new item (two items on one frame give two entries). */
const risingFrames = (count: (frame: number) => number, from: number, to: number): number[] => {
  const out: number[] = [];
  let seen = count(from - 1);
  for (let f = from; f < to; f++) {
    const n = count(f);
    for (; seen < n; seen++) out.push(f);
  }
  return out;
};

const KIND_ORDER: SoundKind[] = ['success', 'good', 'bad', 'click', 'tap', 'key'];

/** Sound events of one scene, in scene-local frames. */
const sceneEvents = (spec: SceneSpec): SoundEvent[] => {
  const c = compileRegistered(spec);
  const frames = sceneFrames(spec.n);
  const out: SoundEvent[] = [];

  // A press lands the frame its pulse starts: the cue's start plus travel and settle (pointer.ts).
  const travel = Math.round(TRAVEL_SECONDS * FPS);
  const settle = Math.round(SETTLE_SECONDS * FPS);
  for (const run of c.runs) {
    for (const cue of run.cues) if (cue.press) out.push({ frame: cue.from + travel + settle, kind: run.device === 'iphone' ? 'tap' : 'click' });
  }

  // A label sounds when its run of beats starts, which is when the callout begins to rise.
  spec.beats.forEach((b, i) => {
    for (const l of b.labels ?? []) if (labelRunStart(spec, i, l) === i) out.push({ frame: c.timeline[i].from, kind: l.kind });
  });

  // Typing: scene 1 follows the scene frame; scene 20 and the two terminal pages count from the frame their page starts.
  const keys = (counter: (frame: number) => number, start: number, end: number) => {
    for (const f of risingFrames((frame) => counter(frame - start), start, end)) out.push({ frame: f, kind: 'key' });
  };
  if (spec.n === 1) keys(typed01, 0, frames);
  if (spec.n === 20) {
    const b = c.timeline[3];
    keys(typed20, b.from, b.to);
    const sentenceDone = b.from + TYPE20_START + TYPE20_PITCH * (TYPED_20.length - 1);
    for (const f of successFrames(b.from + CONNECT_AT, sentenceDone)) out.push({ frame: f, kind: 'success' });
  }
  if (spec.n === 10) keys((f) => typedChars(f, commandText(IPA_NAME).length), c.timeline[1].from, c.timeline[1].to);
  if (spec.n === 15) {
    const open = c.timeline[1].from + c.stepTimes[1][1].start;
    const close = c.timeline[1].from + c.stepTimes[1][2].start;
    keys((f) => typedChars(f, commandText(ZIP_NAME).length), open, close);
  }
  return out;
};

/** Every sound of the film, sorted by frame. Two calls give equal output. */
export function soundEvents(): SoundEvent[] {
  const all: SoundEvent[] = [];
  for (const spec of SCENES) {
    const at = sceneStart(spec.n);
    for (const e of sceneEvents(spec)) all.push({ frame: at + e.frame, kind: e.kind });
  }
  return all.sort((a, b) => a.frame - b.frame || KIND_ORDER.indexOf(a.kind) - KIND_ORDER.indexOf(b.kind));
}

/** Film frame ranges `[from, to)` in which a callout is up (scenes 11 and 16): the music steps back so the eyes stay on the screen. */
export function labelWindows(): { from: number; to: number }[] {
  const out: { from: number; to: number }[] = [];
  for (const spec of SCENES) {
    const labelled = spec.beats.map((b) => (b.labels?.length ?? 0) > 0);
    const first = labelled.indexOf(true);
    if (first === -1) continue;
    const c = compileRegistered(spec);
    const at = sceneStart(spec.n);
    out.push({ from: at + c.timeline[first].from, to: at + c.timeline[labelled.lastIndexOf(true)].to });
  }
  return out;
}
