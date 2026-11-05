/**
 * The film's sound effects: the shared tick, tap and click made louder so they stand above the music, and the two chimes retuned
 * to the key of the music (Clean Geometry is C# major, Soft Geometry F# major). audio/synth.ts is not touched.
 */
import { bad, click, key, tap, type Mixer } from '../audio/synth.ts';

/** Overall level of the effects against the music, set by measuring the render (see the handover notes). */
export const SFX_TRIM = 0.8;
/** Gain of each sound over the shared synth's level. */
export const LEVEL = { key: 4.3 * SFX_TRIM, tap: 1.1 * SFX_TRIM, click: 1.35 * SFX_TRIM, ink: 0.25 * SFX_TRIM, good: 1.2 * SFX_TRIM, bad: 1.1 * SFX_TRIM, success: 1.0 * SFX_TRIM } as const;

const FLOOR = 0.0001;
/** The same mixer with its effects bus turned up or down. */
const scaled = (m: Mixer, gain: number): Mixer => {
  const g = m.ctx.createGain();
  g.gain.value = gain;
  g.connect(m.sfx);
  return { ...m, sfx: g };
};

/** A sine note with a quiet second harmonic through a lowpass, as the shared chimes are. */
const bell = (m: Mixer, t: number, freq: number, peak: number, decay: number, cutoff: number): void => {
  const { ctx, sfx } = m;
  const lp = ctx.createBiquadFilter();
  lp.type = 'lowpass';
  lp.frequency.value = cutoff;
  const env = ctx.createGain();
  env.gain.setValueAtTime(FLOOR, t);
  env.gain.linearRampToValueAtTime(peak, t + 0.012);
  env.gain.exponentialRampToValueAtTime(FLOOR, t + 0.012 + decay);
  lp.connect(env).connect(sfx);
  for (const [mult, amp] of [[1, 1], [2, 0.18]] as const) {
    const o = ctx.createOscillator();
    o.type = 'sine';
    o.frequency.setValueAtTime(freq * mult, t);
    const g = ctx.createGain();
    g.gain.value = amp;
    o.connect(g).connect(lp);
    o.start(t);
    o.stop(t + 0.012 + decay);
  }
};

export const filmKey = (m: Mixer, t: number, seed: string): void => key(scaled(m, LEVEL.key), t, seed);
export const filmTap = (m: Mixer, t: number): void => tap(scaled(m, LEVEL.tap), t);
export const filmInk = (m: Mixer, t: number): void => tap(scaled(m, LEVEL.ink), t);
export const filmClick = (m: Mixer, t: number): void => click(scaled(m, LEVEL.click), t);
export const filmBad = (m: Mixer, t: number): void => bad(scaled(m, LEVEL.bad), t);

/** 按這個: C#5 then G#5 (the shared one is D5 then A5). */
export const filmGood = (m: Mixer, t: number): void => {
  const s = scaled(m, LEVEL.good);
  bell(s, t, 554.37, 0.53, 0.55, 3600);
  bell(s, t + 0.13, 830.61, 0.53, 0.7, 3600);
};
/** A warm F# major chord (F#4, C#5, F#5, A#5), rolled over 100 ms. */
export const filmSuccess = (m: Mixer, t: number): void => {
  const s = scaled(m, LEVEL.success);
  [369.99, 554.37, 739.99, 932.33].forEach((f, i) => bell(s, t + i * 0.035, f, 0.255, 1.5, 3000));
};
