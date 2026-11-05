/**
 * A close-up: the picture lies on a slab seen at a steep angle, the focus point at the middle of the frame. The plane is drawn six
 * times with a different blur and a band of sharpness around the focus, so depth of field falls off up and down; a dark pool takes
 * the rest. `overlay` is drawn once, sharp (the finger rings). Taken from the proven test film.
 */
import { Camera, Layer, Rect, blur, radialGradient } from '@kinetographdev/core';
import type { ReactNode } from 'react';

export type SlabParams = { mag: number; pitch: number; roll: number; yaw: number; tx: number; ty: number; persp: number; focusH: number; pool?: number };

export const Slab = ({ w, h, p, fx, fy, overlay, children }: { w: number; h: number; p: SlabParams; fx: number; fy: number; overlay?: ReactNode; children: ReactNode }) => {
  const radii = [9, 6, 4, 2.4, 1.1, 0];
  const pool = p.pool ?? 1;
  const band = (i: number) => {
    const b = p.focusH * (0.5 + (radii.length - 1 - i) * 0.8);
    const fade = p.focusH * 0.55;
    const y0 = fy - b - fade;
    const y1 = fy + b + fade;
    const at = (y: number) => (y - y0) / (y1 - y0);
    const mask = i === 0 ? undefined : { mode: 'alpha' as const, gradient: { type: 'linear' as const, x0: 0, y0, x1: 0, y1, extend: 'pad' as const, stops: [{ offset: 0, color: '#ffffff00' }, { offset: at(fy - b), color: '#ffffff' }, { offset: at(fy + b), color: '#ffffff' }, { offset: 1, color: '#ffffff00' }] } };
    return <Layer key={i} mask={mask}><Layer effects={radii[i] > 0 ? [blur(radii[i])] : undefined}>{children}</Layer></Layer>;
  };
  return (
    <>
      <Camera perspective={p.persp} />
      <Layer x={960 + p.tx} y={540 + p.ty} rotateX={p.pitch} rotateY={p.yaw}>
        <Layer rotation={p.roll} scale={p.mag}>
          <Layer x={-fx} y={-fy}>
            {radii.map((_, i) => band(i))}
            {overlay}
            <Rect x={-1200} y={-1200} width={w + 2400} height={h + 2400} fill={radialGradient([[0, '#00000000'], [0.12 * pool, '#00000000'], [0.24 * pool, '#000000a8'], [0.36 * pool, '#000000fa']], { cx: (fx + 1200) / (w + 2400), cy: (fy + 1200) / (h + 2400), r: 0.62 })} />
          </Layer>
        </Layer>
      </Layer>
    </>
  );
};
