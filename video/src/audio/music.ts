/**
 * The background music as data, and the function that schedules it. 72 BPM in 4/4, so a bar is 100 frames and a chord
 * (two bars) 200 frames: every chord change falls on a whole frame. A soft pad of sine and triangle voices on
 * Dmaj9, Bm7, Gmaj7, A6 round, with sparse plucks from the D major pentatonic at seeded positions. The three scene groups
 * (1 to 9, 10 to 16, 17 to 21) change the voicing and the pluck density so the film does not sound like a short loop.
 * Pure data: no clock, no Math.random; every choice comes from `random(seed)`.
 */
import { random } from '@kinetographdev/core';
import { FILM_FRAMES, FPS } from '../data/scenes/index.ts';
import { labelWindows, sceneStart } from './events.ts';
import { pad, pluck, type Mixer } from './synth.ts';

export const BPM = 72;
export const BEAT_FRAMES = (FPS * 60) / BPM;
export const BAR_FRAMES = 4 * BEAT_FRAMES;
export const CHORD_FRAMES = 2 * BAR_FRAMES;
export const FILM_SECONDS = FILM_FRAMES / FPS;
export const CHORD_COUNT = Math.ceil(FILM_FRAMES / CHORD_FRAMES);
export const CHORD_NAMES = ['Dmaj9', 'Bm7', 'Gmaj7', 'A6'] as const;

export const FADE_IN_SECONDS = 2;
export const FADE_OUT_SECONDS = 3;
/** The music steps back by this many dB while a callout is up, over DIP_IN_SECONDS going down and DIP_OUT_SECONDS coming back. */
export const DIP_DB = 4;
export const DIP_IN_SECONDS = 0.6;
export const DIP_OUT_SECONDS = 0.9;
/** Samples per second of the gain envelope the mixer plays with setValueCurveAtTime. */
export const ENVELOPE_RATE = 20;

/** Each pad note rings past its chord by this long, so the next chord's slow attack crosses it. */
const PAD_RELEASE_SECONDS = 2.4;
const EIGHTH_SECONDS = 30 / BPM;

export type Group = 'A' | 'B' | 'C';
export type MusicNote = {
  kind: 'pad' | 'pluck';
  /** Chord index from the film start (0 is Dmaj9). */
  chord: number;
  name: (typeof CHORD_NAMES)[number];
  group: Group;
  /** Seconds from the film start, and length including the release. */
  start: number;
  dur: number;
  freq: number;
  wave: 'sine' | 'triangle';
  gain: number;
  pan: number;
  /** Cents. */
  detune: number;
};

/** The group of scenes a frame belongs to: 1 to 9, 10 to 16, 17 to 21. */
export const groupAt = (frame: number): Group => (frame < sceneStart(10) ? 'A' : frame < sceneStart(17) ? 'B' : 'C');

const hz = (midi: number): number => 440 * 2 ** ((midi - 69) / 12);

/** MIDI notes per group and chord; the first is the bass (triangle), the others sine. D3 is 50. */
const VOICINGS: Record<Group, number[][]> = {
  // calm and close: four voices
  A: [[50, 57, 64, 66], [47, 57, 62, 66], [43, 59, 62, 66], [45, 61, 64, 66]],
  // fuller: the same chords with two upper voices added
  B: [[50, 57, 64, 66, 69, 73], [47, 57, 62, 66, 69, 74], [43, 59, 62, 66, 71, 74], [45, 61, 64, 66, 69, 73]],
  // open and higher: five voices spread over two octaves
  C: [[50, 57, 64, 69, 73], [47, 57, 66, 69, 74], [43, 59, 66, 71, 74], [45, 61, 66, 69, 76]],
};
const VOICE_GAIN = { A: 0.05, B: 0.04, C: 0.045 } as const;

/** D major pentatonic: D E F# A B, from D4 to B5. */
const PENTATONIC = [62, 64, 66, 69, 71, 74, 76, 78, 81, 83].map(hz);
/** Which part of PENTATONIC each group draws from: [first index, count]. */
const PLUCK_RANGE: Record<Group, [number, number]> = { A: [0, 7], B: [0, 9], C: [3, 7] };

/** How many plucks a chord gets, from one random number: A is sparse, B denser, C sparse and high. */
const pluckCount = (g: Group, r: number): number => {
  if (g === 'A') return r < 0.3 ? 0 : r < 0.8 ? 1 : 2;
  if (g === 'B') return r < 0.5 ? 2 : 3;
  return r < 0.5 ? 1 : 2;
};

const chordStartSeconds = (k: number): number => (k * CHORD_FRAMES) / FPS;

/** Plucks stay out of the callout windows (and the second before them), where the eyes are on the screen. */
const quietSpans = (): [number, number][] => labelWindows().map((w) => [w.from / FPS - 1, w.to / FPS]);

const buildChord = (k: number, quiet: [number, number][]): MusicNote[] => {
  const start = chordStartSeconds(k);
  const name = CHORD_NAMES[k % CHORD_NAMES.length];
  const group = groupAt(k * CHORD_FRAMES);
  const voicing = VOICINGS[group][k % CHORD_NAMES.length];
  const notes: MusicNote[] = voicing.map((m, i) => ({
    kind: 'pad',
    chord: k,
    name,
    group,
    start,
    dur: Math.min(CHORD_FRAMES / FPS + PAD_RELEASE_SECONDS, FILM_SECONDS - start),
    freq: hz(m),
    wave: i === 0 ? 'triangle' : 'sine',
    gain: VOICE_GAIN[group] * (i === 0 ? 1.1 : i >= 4 ? 0.6 : 1),
    pan: voicing.length === 1 ? 0 : -0.4 + (0.8 * i) / (voicing.length - 1),
    detune: Math.round((random(`pad-detune-${k}-${i}`) - 0.5) * 100) / 10 + 0,
  }));

  const n = pluckCount(group, random(`pluck-count-${k}`));
  const [first, count] = PLUCK_RANGE[group];
  const taken = new Set<number>();
  for (let j = 0; j < n; j++) {
    let slot = 2 + Math.floor(random(`pluck-slot-${k}-${j}`) * 13); // eighth notes 2 to 14 of 16
    while (taken.has(slot)) slot = slot === 14 ? 2 : slot + 1;
    taken.add(slot);
    const at = start + slot * EIGHTH_SECONDS;
    if (quiet.some(([a, b]) => at >= a && at < b) || at + 2.4 > FILM_SECONDS - 1) continue;
    const freq = PENTATONIC[first + Math.floor(random(`pluck-pitch-${k}-${j}`) * count)];
    notes.push({
      kind: 'pluck',
      chord: k,
      name,
      group,
      start: at,
      dur: 2.4,
      freq,
      wave: group === 'C' ? 'sine' : 'triangle',
      gain: group === 'C' ? 0.07 : 0.06,
      pan: Math.round((random(`pluck-pan-${k}-${j}`) * 0.9 - 0.45) * 100) / 100,
      detune: 0,
    });
  }
  return notes;
};

/** Every note of the film, chord by chord. */
export function musicSchedule(): MusicNote[] {
  const quiet = quietSpans();
  return Array.from({ length: CHORD_COUNT }, (_, k) => buildChord(k, quiet)).flat();
}

/** Notes of chord `k` only (what the onFrame callback of that chord plays). */
export const chordNotes = (k: number): MusicNote[] => buildChord(k, quietSpans());

/** Film frame at which chord `k` starts. */
export const chordFrame = (k: number): number => k * CHORD_FRAMES;

const smooth = (x: number): number => {
  const c = Math.min(1, Math.max(0, x));
  return c * c * (3 - 2 * c);
};

/**
 * Gain of the music bus over the film, ENVELOPE_RATE samples a second from 0 s to the end inclusive: a 2 s fade in, a
 * 3 s fade out, and a smooth dip of DIP_DB while a callout is up.
 */
export function musicEnvelope(): number[] {
  const dip = 10 ** (-DIP_DB / 20);
  const windows = labelWindows().map((w) => ({ from: w.from / FPS, to: w.to / FPS }));
  const out: number[] = [];
  for (let i = 0; i <= Math.ceil(FILM_SECONDS * ENVELOPE_RATE); i++) {
    const t = i / ENVELOPE_RATE;
    let g = smooth(t / FADE_IN_SECONDS) * smooth((FILM_SECONDS - t) / FADE_OUT_SECONDS);
    for (const w of windows) g *= 1 - (1 - dip) * smooth((t - w.from) / DIP_IN_SECONDS) * (1 - smooth((t - w.to) / DIP_OUT_SECONDS));
    out.push(g);
  }
  return out;
}

/** Plays chord `k` on `mix`; `t` is the context time of the chord's first frame. */
export function scheduleChord(mix: Mixer, k: number, t: number): void {
  const base = chordStartSeconds(k);
  for (const n of chordNotes(k)) {
    const when = t + (n.start - base);
    if (n.kind === 'pad') pad(mix, when, n);
    else pluck(mix, when, n);
  }
}
