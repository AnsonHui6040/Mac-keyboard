import { Layer, Rect } from '@kinetographdev/core';
import type { ReactNode } from 'react';
import { PHONE_BEZEL, PHONE_LOGICAL, PHONE_ORIGIN, PHONE_SCALE, PHONE_SCREEN_H, PHONE_SCREEN_W, type PhoneOrigin } from '../screens/phone.ts';

const SCREEN_RADIUS = 52 * PHONE_SCALE;

const roundedRectPath = (w: number, h: number, r: number): string =>
  `M${r} 0 H${w - r} A${r} ${r} 0 0 1 ${w} ${r} V${h - r} A${r} ${r} 0 0 1 ${w - r} ${h} H${r} A${r} ${r} 0 0 1 0 ${h - r} V${r} A${r} ${r} 0 0 1 ${r} 0 Z`;

/**
 * Phone body with a dynamic island. Children are drawn in logical 390 x 844 coordinates and clipped to the rounded
 * screen. `origin` is the canvas position of the screen's top-left (PHONE_ORIGIN alone, PHONE_ORIGIN_RIGHT beside a Mac).
 * Pass the same origin to `phoneRect` for the targets drawn on it.
 */
export const IPhoneFrame = ({ children, background = '#f2f2f6', origin = PHONE_ORIGIN }: { children?: ReactNode; background?: string; origin?: PhoneOrigin }) => (
  <Layer id="iphone">
    <Rect id="iphone-body" x={origin.x - PHONE_BEZEL} y={origin.y - PHONE_BEZEL} width={PHONE_SCREEN_W + PHONE_BEZEL * 2} height={PHONE_SCREEN_H + PHONE_BEZEL * 2}
      radius={SCREEN_RADIUS + PHONE_BEZEL} fill="#0c0c0e" stroke={{ color: '#4a4b50', width: 3 }} />
    <Layer id="iphone-screen" x={origin.x} y={origin.y} clip={{ kind: 'path', d: roundedRectPath(PHONE_SCREEN_W, PHONE_SCREEN_H, SCREEN_RADIUS) }}>
      <Rect width={PHONE_SCREEN_W} height={PHONE_SCREEN_H} fill={background} />
      <Layer scale={PHONE_SCALE}>
        {children}
        <Rect id="iphone-island" x={(PHONE_LOGICAL.width - 120) / 2} y={11} width={120} height={35} radius={17.5} fill="#0c0c0e" />
      </Layer>
    </Layer>
  </Layer>
);
