/** A title: it un-blurs and rises over 22 frames, then stands still. Fixed in frame space, never inside a 3D transform. */
import { Layer, Text, blur } from '@kinetographdev/core';
import { theme } from '../theme.ts';
import type { Title } from './timeline.ts';

const clamp01 = (v: number): number => Math.min(1, Math.max(0, v));
/** Critically damped arrival: fast start, no overshoot. */
export const settle = (u: number): number => { const t = clamp01(u); return 1 - (1 + 5 * t) * Math.exp(-5 * t); };

export const Headline = ({ t, f }: { t: Title; f: number }) => {
  if (f < t.from || f >= t.to) return null;
  const u = settle((f - t.from) / 22);
  return (
    <Layer id={`title-${t.id}`} opacity={u} y={(1 - u) * 18} effects={u < 0.98 ? [blur((1 - u) * 14)] : undefined}>
      <Text font={theme.font} weight={700} size={t.size} color="#f5f5f7" x={t.x} y={t.y} maxWidth={t.width} align={t.align} lineHeight={1.12}>{t.text}</Text>
    </Layer>
  );
};

/** How far the title has arrived at a frame (0 to 1), the same value the title and the scrim under it follow. */
export const arrival = (t: Title, f: number): number => (f < t.from || f >= t.to ? 0 : settle((f - t.from) / 22));
