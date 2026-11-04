import { Ellipse, Layer, Path } from '@kinetographdev/core';
import type { PointerState } from '../lib/pointer.ts';

const ARROW = 'M0 0 L0 29 L7 22.5 L12 34 L17.5 31.5 L12.5 20.5 L22 20.5 Z';
const SCALE = 1.4; // arrow is 34 units tall: about 48 px on the canvas

/** macOS arrow pointer: tip at (x, y). Shrinks and shows a ring while `press` is above 0. */
export const MacCursor = ({ state }: { state: PointerState }) => (
  <Layer id="pointer" x={state.x} y={state.y} opacity={state.visible ? 1 : 0}>
    <Ellipse x={-20} y={-20} width={40} height={40} fill="#00000000" stroke={{ color: '#ffffff', width: 4 }} opacity={state.press * 0.7} scale={0.6 + 0.4 * state.press} origin="center" />
    <Layer scale={SCALE * (1 - 0.1 * state.press)}>
      <Path d={ARROW} fill="#111111" stroke={{ color: '#ffffff', width: 2.2 }} />
    </Layer>
  </Layer>
);
