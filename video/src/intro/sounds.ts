/**
 * Sound events of the product intro, derived from the same press list and trackpad timetable that draw the picture.
 * Pure: node can import it. register.ts turns them into Web Audio calls.
 */
import { FPS, FRAMES } from './timeline.ts';
import { LOGIN, MAC_DELAY, PRESSES, PRODUCT_START } from './script.ts';
import { TRACKPAD_EVENTS } from './trackpad.ts';

export type SoundKind = 'key' | 'tap' | 'click' | 'good' | 'bad' | 'success';
export type SoundEvent = { frame: number; kind: SoundKind };

export const soundEvents = (): SoundEvent[] => {
  const out: SoundEvent[] = [];
  for (const p of PRESSES) {
    out.push({ frame: p.t, kind: p.snd });
    if (p.fx.k === 'send') out.push({ frame: p.t + MAC_DELAY, kind: 'good' });
  }
  const product = PRESSES.filter((p) => p.t >= PRODUCT_START);
  out.push({ frame: product[product.length - 1].t + MAC_DELAY, kind: 'success' });
  for (const e of TRACKPAD_EVENTS) {
    if (e.what === 'tap' || e.what === 'touch' || e.what === 'tap2') out.push({ frame: e.frame, kind: 'tap' });
    else if (e.what === 'select' || e.what === 'lift' || e.what === 'drop' || e.what === 'dismiss') out.push({ frame: e.frame, kind: 'click' });
  }
  out.push({ frame: LOGIN.click, kind: 'click' });
  out.push({ frame: LOGIN.blocked, kind: 'bad' });
  return out.filter((e) => e.frame >= 0 && e.frame < FRAMES).sort((a, b) => a.frame - b.frame);
};

/**
 * The effects registry is global, so every callback asks whether the context belongs to ProductIntro: a context exactly 61 s long
 * (one sample either way). The install film's Main is 335 s and its scenes are shorter, so none of them matches.
 */
export const isIntroContext = (length: number, sampleRate: number): boolean => Math.abs(length - Math.round((FRAMES / FPS) * sampleRate)) <= 1;
