import { Ellipse, Layer } from '@kinetographdev/core';
import type { PointerState } from '../lib/pointer.ts';

const SIZE = 56;

/** Finger touch marker for iPhone screens: centered on (x, y). Shrinks and shows a ring while `press` is above 0. */
export const TapDot = ({ state }: { state: PointerState }) => (
  <Layer id="pointer" x={state.x} y={state.y} opacity={state.visible ? 1 : 0}>
    <Ellipse x={-SIZE} y={-SIZE} width={SIZE * 2} height={SIZE * 2} fill="#00000000" stroke={{ color: '#ffffff', width: 4 }} opacity={state.press * 0.7} scale={0.6 + 0.4 * state.press} origin="center" />
    <Ellipse x={-SIZE / 2} y={-SIZE / 2} width={SIZE} height={SIZE} fill="#00000000" stroke={{ color: '#ffffff', width: 4 }} scale={1 - 0.15 * state.press} origin="center" />
  </Layer>
);
