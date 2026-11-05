/**
 * Registers the film's sound: one onFrame call per frame that has events, at ProductFilm frames. The effects registry is global
 * (every composition's render runs every callback), so a callback plays only into a context exactly 50.5 s long. No other
 * composition of the project is 1515 frames (events.test.ts checks), so the install film and ProductIntro never get these sounds.
 * The music is not here: Film.tsx plays it with <Audio>. A `--range` render of ProductFilm therefore has music but no sound
 * effects, because the guard needs a context of the whole film (the same limit intro/register.ts documents).
 */
import { onFrame } from '@kinetographdev/audio';
import { mixer, type Mixer } from '../audio/synth.ts';
import { isFilmContext, soundEvents, type SoundEvent } from './events.ts';
import { FPS, FRAMES } from './timeline.ts';
import { filmClick, filmGood, filmInk, filmKey, filmSuccess, filmTap } from './sounds.ts';

const silence = Float32Array.from([0, 0]);
const mix = (ctx: OfflineAudioContext): Mixer => mixer(ctx, silence, FRAMES / FPS);

const play = (e: SoundEvent, m: Mixer, t: number, seed: string): void => {
  if (e.kind === 'click') filmClick(m, t);
  else if (e.kind === 'tap') filmTap(m, t);
  else if (e.kind === 'ink') filmInk(m, t);
  else if (e.kind === 'key') filmKey(m, t, seed);
  else if (e.kind === 'good') filmGood(m, t);
  else filmSuccess(m, t);
};

const byFrame = new Map<number, SoundEvent[]>();
for (const e of soundEvents()) byFrame.set(e.frame, [...(byFrame.get(e.frame) ?? []), e]);
for (const [frame, list] of byFrame) {
  onFrame(frame, (ctx, t) => {
    if (!isFilmContext(ctx.length, ctx.sampleRate)) return;
    const m = mix(ctx);
    list.forEach((e, i) => play(e, m, Math.max(0, t), `film-${frame}-${i}`));
  });
}
