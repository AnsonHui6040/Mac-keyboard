/**
 * Registers the film's sound with Kinetograph: one onFrame call per sound event, at film-global frames. The film has sound
 * effects only: music.ts is no longer scheduled.
 * Imported by src/index.tsx for its effect only.
 *
 * Standalone scene compositions (Scene16, ...) render silent. The registry is global and does not say which composition is being
 * rendered, and every frame number here is a film frame, so Scene16 would otherwise play scene 1's keys. A callback therefore
 * plays only into a context as long as the whole film (the Main composition); a shorter one gets nothing, and the render still
 * works (its audio track is silence).
 */
import { onFrame } from '@kinetographdev/audio';
import { FILM_FRAMES, FPS } from '../data/scenes/index.ts';
import { soundEvents, type SoundEvent } from './events.ts';
import { FILM_SECONDS, musicEnvelope } from './music.ts';
import { bad, click, good, key, mixer, success, tap, type Mixer } from './synth.ts';

const curve = Float32Array.from(musicEnvelope());

const playsHere = (ctx: OfflineAudioContext): boolean => ctx.length >= Math.round((FILM_FRAMES / FPS) * ctx.sampleRate);
const mix = (ctx: OfflineAudioContext): Mixer => mixer(ctx, curve, FILM_SECONDS);

const play = (e: SoundEvent, m: Mixer, time: number, seed: string): void => {
  const t = Math.max(0, time);
  if (e.kind === 'click') click(m, t);
  else if (e.kind === 'tap') tap(m, t);
  else if (e.kind === 'key') key(m, t, seed);
  else if (e.kind === 'good') good(m, t);
  else if (e.kind === 'bad') bad(m, t);
  else success(m, t);
};

// Effects: events on one frame share one callback. Several keys on a frame (the terminal types two characters a frame) are
// spread evenly across that frame so they do not fire as one click.
const byFrame = new Map<number, SoundEvent[]>();
for (const e of soundEvents()) byFrame.set(e.frame, [...(byFrame.get(e.frame) ?? []), e]);
for (const [frame, list] of byFrame) {
  onFrame(frame, (ctx, t) => {
    if (!playsHere(ctx)) return;
    const m = mix(ctx);
    const keys = list.filter((e) => e.kind === 'key').length;
    let seen = 0;
    list.forEach((e, i) => {
      const at = e.kind === 'key' ? t + (seen++ / keys) / FPS : t;
      play(e, m, at, `${frame}-${i}`);
    });
  });
}
