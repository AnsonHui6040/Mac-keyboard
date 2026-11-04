import { Layer, Rect } from '@kinetographdev/core';
import type { ReactNode } from 'react';
import type { Rect as Box } from '../screens/geometry.ts';

/** Logical iPhone screen size in points; screens are drawn in this space. */
export const PHONE_LOGICAL = { width: 390, height: 844 } as const;
/** Canvas pixels per logical point: the screen is about 367 x 793 px, under the 800 px limit. */
export const PHONE_SCALE = 0.94;
const SCREEN_W = PHONE_LOGICAL.width * PHONE_SCALE;
const SCREEN_H = PHONE_LOGICAL.height * PHONE_SCALE;
/** Canvas position of the screen's top-left corner: centered across the stage, 48 px from the top. */
export const PHONE_ORIGIN = { x: (1920 - SCREEN_W) / 2, y: 48 } as const;
const BEZEL = 14;
const SCREEN_RADIUS = 52 * PHONE_SCALE;

/** Maps a rect in the logical 390 x 844 screen to canvas pixels. */
export const phoneRect = (r: Box): Box => ({
  x: PHONE_ORIGIN.x + r.x * PHONE_SCALE,
  y: PHONE_ORIGIN.y + r.y * PHONE_SCALE,
  width: r.width * PHONE_SCALE,
  height: r.height * PHONE_SCALE,
});

/** Canvas bottom of the whole device, bezel included. Stays above the subtitle divider (y=884). */
export const PHONE_BOTTOM = PHONE_ORIGIN.y + SCREEN_H + BEZEL;

const roundedRectPath = (w: number, h: number, r: number): string =>
  `M${r} 0 H${w - r} A${r} ${r} 0 0 1 ${w} ${r} V${h - r} A${r} ${r} 0 0 1 ${w - r} ${h} H${r} A${r} ${r} 0 0 1 0 ${h - r} V${r} A${r} ${r} 0 0 1 ${r} 0 Z`;

/** Phone body with a dynamic island. Children are drawn in logical 390 x 844 coordinates and clipped to the rounded screen. */
export const IPhoneFrame = ({ children, background = '#f2f2f6' }: { children?: ReactNode; background?: string }) => (
  <Layer id="iphone">
    <Rect id="iphone-body" x={PHONE_ORIGIN.x - BEZEL} y={PHONE_ORIGIN.y - BEZEL} width={SCREEN_W + BEZEL * 2} height={SCREEN_H + BEZEL * 2}
      radius={SCREEN_RADIUS + BEZEL} fill="#0c0c0e" stroke={{ color: '#4a4b50', width: 3 }} />
    <Layer id="iphone-screen" x={PHONE_ORIGIN.x} y={PHONE_ORIGIN.y} clip={{ kind: 'path', d: roundedRectPath(SCREEN_W, SCREEN_H, SCREEN_RADIUS) }}>
      <Rect width={SCREEN_W} height={SCREEN_H} fill={background} />
      <Layer scale={PHONE_SCALE}>
        {children}
        <Rect id="iphone-island" x={(PHONE_LOGICAL.width - 120) / 2} y={11} width={120} height={35} radius={17.5} fill="#0c0c0e" />
      </Layer>
    </Layer>
  </Layer>
);
