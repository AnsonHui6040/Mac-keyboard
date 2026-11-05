/**
 * Registers the product intro's sound: one onFrame call per frame that has events, at ProductIntro frames. The effects registry is
 * global (every composition's render runs every callback), so a callback plays only into a context exactly as long as ProductIntro.
 * The install film's own register.ts plays only into a context as long as Main, which is longer than ProductIntro, so the two never mix.
 * The test is the context length, so a render of only part of ProductIntro (`--range`) has no sound; and a render of Main limited to exactly
 * 1830 frames has a context of the same length and would play this sound.
 */
import { onFrame } from '@kinetographdev/audio';
import { FPS, FRAMES } from './timeline.ts';
import { isIntroContext, soundEvents, type SoundEvent } from './sounds.ts';
import { bad, click, good, key, mixer, success, tap, type Mixer } from '../audio/synth.ts';

// The intro has no music: a flat zero curve (two points are the least a value curve takes).
const silence = Float32Array.from([0, 0]);
const mix = (ctx: OfflineAudioContext): Mixer => mixer(ctx, silence, FRAMES / FPS);

const play = (e: SoundEvent, m: Mixer, t: number, seed: string): void => {
  if (e.kind === 'click') click(m, t);
  else if (e.kind === 'tap') tap(m, t);
  else if (e.kind === 'key') key(m, t, seed);
  else if (e.kind === 'good') good(m, t);
  else if (e.kind === 'bad') bad(m, t);
  else success(m, t);
};

const byFrame = new Map<number, SoundEvent[]>();
for (const e of soundEvents()) byFrame.set(e.frame, [...(byFrame.get(e.frame) ?? []), e]);
for (const [frame, list] of byFrame) {
  onFrame(frame, (ctx, t) => {
    if (!isIntroContext(ctx.length, ctx.sampleRate)) return;
    const m = mix(ctx);
    const keys = list.filter((e) => e.kind === 'key').length;
    let seen = 0;
    list.forEach((e, i) => {
      // Several keys on one frame are spread across the frame so they do not fire as one click.
      const at = e.kind === 'key' ? t + seen++ / keys / FPS : t;
      play(e, m, Math.max(0, at), `intro-${frame}-${i}`);
    });
  });
}
