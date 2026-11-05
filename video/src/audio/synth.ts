/**
 * The sounds, each one a small function: it builds a few Web Audio nodes at time `t` and lets them end. No sample files.
 * Peak levels are chosen so the effects sit about 6 to 10 dB above the music's peak (keys are meant to be nearly
 * inaudible). Noise is seeded: `random(seed)` gives the generator its start, never Math.random.
 */
import { random } from '@kinetographdev/core';

/** What a sound needs: the context and the buses it plays into. */
export type Mixer = { ctx: OfflineAudioContext; sfx: GainNode; padBus: AudioNode; pluckBus: AudioNode };
export type VoiceSpec = { freq: number; wave: 'sine' | 'triangle'; gain: number; pan: number; detune: number; dur: number };

const FLOOR = 0.0001;
/** Gain into the music compressor and the compressor's settings (a peak limiter in all but name). */
const MUSIC_TRIM = 2.5;
/** Gain after the compressor, which sets the music's loudness in the film. */
const MUSIC_LEVEL = 0.72;
/** The master limiter, and the gain that cancels the makeup gain the compressor node adds by itself. */
const LIMIT = { threshold: -2, release: 0.08, makeup: 0.877 };
/** A DynamicsCompressorNode delays its output by 6 ms (its look-ahead), so effects are started this much early to land on their frame. */
export const LIMITER_DELAY = 0.006;
const COMP = { threshold: -18, knee: 0, ratio: 20, attack: 0, release: 0.3 };

/** A seeded noise buffer of `seconds` (mono). The seed goes through random(), then a small generator makes the samples. */
const noiseBuffer = (ctx: BaseAudioContext, seed: string, seconds: number, channels = 1): AudioBuffer => {
  const length = Math.max(1, Math.round(seconds * ctx.sampleRate));
  const buf = ctx.createBuffer(channels, length, ctx.sampleRate);
  for (let c = 0; c < channels; c++) {
    let s = Math.floor(random(`${seed}-${c}`) * 4294967296) >>> 0;
    const data = buf.getChannelData(c);
    for (let i = 0; i < length; i++) {
      s = (s + 0x6d2b79f5) >>> 0; // mulberry32
      let z = s;
      z = Math.imul(z ^ (z >>> 15), z | 1);
      z ^= z + Math.imul(z ^ (z >>> 7), z | 61);
      data[i] = (((z ^ (z >>> 14)) >>> 0) / 4294967296) * 2 - 1;
    }
  }
  return buf;
};

/** Gain that rises to `peak` over `attack` then falls to nothing over `decay`. */
const pluckEnv = (ctx: BaseAudioContext, out: AudioNode, t: number, peak: number, attack: number, decay: number): GainNode => {
  const g = ctx.createGain();
  g.gain.setValueAtTime(FLOOR, t);
  g.gain.linearRampToValueAtTime(peak, t + attack);
  g.gain.exponentialRampToValueAtTime(FLOOR, t + attack + decay);
  g.connect(out);
  return g;
};

const osc = (ctx: BaseAudioContext, type: OscillatorType, from: number, to: number | null, t: number, bend: number): OscillatorNode => {
  const o = ctx.createOscillator();
  o.type = type;
  o.frequency.setValueAtTime(from, t);
  if (to !== null) o.frequency.exponentialRampToValueAtTime(to, t + bend);
  return o;
};

const noise = (ctx: BaseAudioContext, seed: string, seconds: number): AudioBufferSourceNode => {
  const n = ctx.createBufferSource();
  n.buffer = noiseBuffer(ctx, seed, seconds);
  return n;
};

/** Mac pointer press: a dry soft click of about 40 ms (a short filtered noise and a falling triangle). */
export function click(m: Mixer, t: number): void {
  const { ctx, sfx } = m;
  const o = osc(ctx, 'triangle', 2100, 850, t, 0.025);
  o.connect(pluckEnv(ctx, sfx, t, 0.69, 0.0008, 0.034));
  o.start(t);
  o.stop(t + 0.045);
  const n = noise(ctx, 'click', 0.03);
  const bp = ctx.createBiquadFilter();
  bp.type = 'bandpass';
  bp.frequency.value = 3200;
  bp.Q.value = 0.7;
  n.connect(bp).connect(pluckEnv(ctx, sfx, t, 0.4, 0.0005, 0.016));
  n.start(t);
  n.stop(t + 0.03);
}

/** iPhone press: a soft rounded tick of about 50 ms, lower than the click (a falling sine and a little low noise). */
export function tap(m: Mixer, t: number): void {
  const { ctx, sfx } = m;
  const o = osc(ctx, 'sine', 560, 250, t, 0.04);
  o.connect(pluckEnv(ctx, sfx, t, 0.68, 0.002, 0.048));
  o.start(t);
  o.stop(t + 0.06);
  const n = noise(ctx, 'tap', 0.03);
  const lp = ctx.createBiquadFilter();
  lp.type = 'lowpass';
  lp.frequency.value = 1400;
  n.connect(lp).connect(pluckEnv(ctx, sfx, t, 0.1, 0.001, 0.02));
  n.start(t);
  n.stop(t + 0.03);
}

/** One typed character: a very quiet tick whose pitch and noise colour vary a little with the seed. */
export function key(m: Mixer, t: number, seed: string): void {
  const { ctx, sfx } = m;
  const a = random(`${seed}-a`);
  const b = random(`${seed}-b`);
  const o = osc(ctx, 'sine', 1500 * (0.85 + 0.3 * a), 650 * (0.85 + 0.3 * a), t, 0.015);
  o.connect(pluckEnv(ctx, sfx, t, 0.13, 0.0006, 0.016));
  o.start(t);
  o.stop(t + 0.03);
  const n = noise(ctx, `key-${Math.floor(b * 4)}`, 0.02);
  const bp = ctx.createBiquadFilter();
  bp.type = 'bandpass';
  bp.frequency.value = 2400 * (0.85 + 0.3 * b);
  bp.Q.value = 0.9;
  n.connect(bp).connect(pluckEnv(ctx, sfx, t, 0.09, 0.0004, 0.008));
  n.start(t);
  n.stop(t + 0.02);
}

/** A sine note with a quiet second harmonic through a lowpass, for the chimes. */
const bell = (m: Mixer, t: number, freq: number, peak: number, decay: number, cutoff: number): void => {
  const { ctx, sfx } = m;
  const lp = ctx.createBiquadFilter();
  lp.type = 'lowpass';
  lp.frequency.value = cutoff;
  lp.connect(pluckEnv(ctx, sfx, t, peak, 0.012, decay));
  for (const [mult, amp] of [[1, 1], [2, 0.18]] as const) {
    const o = osc(ctx, 'sine', freq * mult, null, t, 0);
    const g = ctx.createGain();
    g.gain.value = amp;
    o.connect(g).connect(lp);
    o.start(t);
    o.stop(t + 0.012 + decay);
  }
};

/** 按這個: a soft rising two-note chime (D5 then A5). */
export function good(m: Mixer, t: number): void {
  bell(m, t, 587.33, 0.53, 0.55, 3600);
  bell(m, t + 0.13, 880, 0.53, 0.7, 3600);
}

/** 不要按: a muted low two-note tone, falling (B3 then G3), triangle through a low lowpass. Cautionary, not harsh. */
export function bad(m: Mixer, t: number): void {
  const { ctx, sfx } = m;
  const lp = ctx.createBiquadFilter();
  lp.type = 'lowpass';
  lp.frequency.value = 650;
  lp.Q.value = 0.5;
  lp.connect(sfx);
  [[246.94, 0], [196, 0.17]].forEach(([f, dt]) => {
    const o = osc(ctx, 'triangle', f, null, t + dt, 0);
    o.connect(pluckEnv(ctx, lp, t + dt, 0.63, 0.02, 0.32));
    o.start(t + dt);
    o.stop(t + dt + 0.4);
  });
}

/** A small warm chord (D4, A4, D5, F#5), rolled over 100 ms. */
export function success(m: Mixer, t: number): void {
  [293.66, 440, 587.33, 739.99].forEach((f, i) => bell(m, t + i * 0.035, f, 0.255, 1.5, 3000));
}

/** One pad voice: slow attack, long release, a few cents of detune and a place in the stereo field. */
export function pad(m: Mixer, t: number, v: VoiceSpec): void {
  const { ctx } = m;
  const o = osc(ctx, v.wave, v.freq, null, t, 0);
  o.detune.value = v.detune;
  const attack = Math.min(1.8, v.dur * 0.4);
  const release = Math.min(2.4, v.dur * 0.5);
  const g = ctx.createGain();
  g.gain.setValueAtTime(0, t);
  g.gain.linearRampToValueAtTime(v.gain, t + attack);
  g.gain.setValueAtTime(v.gain, t + v.dur - release);
  g.gain.linearRampToValueAtTime(0, t + v.dur);
  const p = ctx.createStereoPanner();
  p.pan.value = v.pan;
  o.connect(g).connect(p).connect(m.padBus);
  o.start(t);
  o.stop(t + v.dur);
}

/** A soft pluck: quick attack, long exponential decay. */
export function pluck(m: Mixer, t: number, v: VoiceSpec): void {
  const { ctx } = m;
  const o = osc(ctx, v.wave, v.freq, null, t, 0);
  const p = ctx.createStereoPanner();
  p.pan.value = v.pan;
  o.connect(pluckEnv(ctx, p, t, v.gain, 0.006, v.dur - 0.006));
  p.connect(m.pluckBus);
  o.start(t);
  o.stop(t + v.dur);
}

const mixers = new WeakMap<object, Mixer>();

/**
 * The buses of one context, built the first time they are asked for: music (pad through a 900 Hz lowpass, plucks through a
 * 2.4 kHz one, a little shared reverb, then the gain curve of fades and dips) and the effects bus, into one master.
 */
export function mixer(ctx: OfflineAudioContext, musicCurve: Float32Array, curveSeconds: number): Mixer {
  const have = mixers.get(ctx);
  if (have) return have;
  // Last in the chain: a limiter, so an effect that lands on a peak of the pad cannot push the film over the true-peak ceiling.
  const limiter = ctx.createDynamicsCompressor();
  limiter.threshold.value = LIMIT.threshold;
  limiter.knee.value = 0;
  limiter.ratio.value = 20;
  limiter.attack.value = 0;
  limiter.release.value = LIMIT.release;
  const makeup = ctx.createGain();
  makeup.gain.value = LIMIT.makeup;
  const master = ctx.createGain();
  master.connect(limiter).connect(makeup).connect(ctx.destination);
  const sfx = ctx.createGain();
  sfx.connect(master);

  const music = ctx.createGain();
  music.gain.value = 0;
  music.gain.setValueCurveAtTime(musicCurve, 0, curveSeconds);
  music.connect(master);

  // The pad is many sines that beat against each other, so its peaks run far above its loudness. A fast, high-ratio compressor
  // takes only those peaks down, which leaves room for the effects above the music without making the film quieter.
  const comp = ctx.createDynamicsCompressor();
  comp.threshold.value = COMP.threshold;
  comp.knee.value = COMP.knee;
  comp.ratio.value = COMP.ratio;
  comp.attack.value = COMP.attack;
  comp.release.value = COMP.release;
  const intake = ctx.createGain();
  intake.gain.value = MUSIC_TRIM;
  const level = ctx.createGain();
  level.gain.value = MUSIC_LEVEL;
  intake.connect(comp).connect(level).connect(music);

  const padLp = ctx.createBiquadFilter();
  padLp.type = 'lowpass';
  padLp.frequency.value = 900;
  padLp.Q.value = 0.6;
  padLp.connect(intake);

  const pluckLp = ctx.createBiquadFilter();
  pluckLp.type = 'lowpass';
  pluckLp.frequency.value = 2400;
  pluckLp.connect(intake);

  // A small room: seeded noise that dies away over 2.4 s, different in the two ears.
  const verb = ctx.createConvolver();
  const ir = noiseBuffer(ctx, 'room', 2.4, 2);
  for (let c = 0; c < 2; c++) {
    const d = ir.getChannelData(c);
    for (let i = 0; i < d.length; i++) d[i] *= Math.exp((-6.5 * i) / d.length);
  }
  verb.buffer = ir;
  const send = ctx.createGain();
  send.gain.value = 0.3;
  const wet = ctx.createGain();
  wet.gain.value = 0.9;
  padLp.connect(send);
  pluckLp.connect(send);
  send.connect(verb).connect(wet).connect(intake);

  const made: Mixer = { ctx, sfx, padBus: padLp, pluckBus: pluckLp };
  mixers.set(ctx, made);
  return made;
}
