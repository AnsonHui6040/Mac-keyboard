/**
 * Registers the promo's sound effects: one onFrame call per frame that has events, at PromoFilm frames. The effects registry is
 * global (every composition's render runs every callback), so a callback plays only into a context exactly as long as the promo
 * (mix.ts isPromoContext); no other composition has that length, so the other films never get these sounds. Under the narration
 * each event is turned down by sfxGainDb at its frame. The narration and the music are not here: Promo.tsx plays them with <Audio>.
 * As in film/register.ts, a `--range` render of PromoFilm has no effects, because the guard needs a context of the whole film.
 */
import { onFrame } from '@kinetographdev/audio';
import { mixer, type Mixer } from '../audio/synth.ts';
import { filmClick, filmGood, filmInk, filmKey, filmSuccess, filmTap } from '../film/sounds.ts';
import { soundEvents, type PromoSoundEvent } from './events.ts';
import { dbToGain, isPromoContext, sfxGainDb } from './mix.ts';
import { FPS, FRAMES } from './timeline.ts';

const silence = Float32Array.from([0, 0]);
const mix = (ctx: OfflineAudioContext): Mixer => mixer(ctx, silence, FRAMES / FPS);

/** The mixer with its effects bus scaled, so one event can be turned down without touching the others. */
const quieter = (m: Mixer, gain: number): Mixer => {
  const g = m.ctx.createGain();
  g.gain.value = gain;
  g.connect(m.sfx);
  return { ...m, sfx: g };
};

const play = (e: PromoSoundEvent, m: Mixer, t: number, seed: string): void => {
  if (e.kind === 'click') filmClick(m, t);
  else if (e.kind === 'tap' || e.kind === 'host') filmTap(m, t);
  else if (e.kind === 'ink') filmInk(m, t);
  else if (e.kind === 'key') filmKey(m, t, seed);
  else if (e.kind === 'good') filmGood(m, t);
  else filmSuccess(m, t);
};

const byFrame = new Map<number, PromoSoundEvent[]>();
for (const e of soundEvents()) byFrame.set(e.frame, [...(byFrame.get(e.frame) ?? []), e]);
for (const [frame, list] of byFrame) {
  onFrame(frame, (ctx, t) => {
    if (!isPromoContext(ctx.length, ctx.sampleRate)) return;
    const m = quieter(mix(ctx), dbToGain(sfxGainDb(frame)));
    list.forEach((e, i) => play(e, m, Math.max(0, t), `promo-${frame}-${i}`));
  });
}
