import type { ReactNode } from 'react';
import { Layer } from '@kinetographdev/core';
import { IPhoneFrame } from './IPhoneFrame.tsx';
import { ios } from './ios.tsx';
import { PHONE_ORIGIN, type PhoneOrigin } from '../screens/phone.ts';
import type { StepTime } from '../lib/sceneSpec.ts';

/** An iPhone in iOS dark mode. `brightness` dims the whole device (used on two-device screens). */
export const PhoneScreen = ({ children, origin = PHONE_ORIGIN, brightness = 1 }: { children?: ReactNode; origin?: PhoneOrigin; brightness?: number }) => (
  <Layer id="phone-device" opacity={brightness}>
    <IPhoneFrame background={ios.bg} origin={origin}>{children}</IPhoneFrame>
  </Layer>
);

export const clamp01 = (v: number): number => Math.min(1, Math.max(0, v));

/** Fade factor: 0 before `from`, 1 after `from + frames`. */
export const fadeIn = (beatFrame: number, from: number, frames = 6): number => clamp01((beatFrame - from) / frames);

/** Index of the page a beat shows: it moves to page k when step k starts (the pointer begins heading for step k's target). */
export const pageAt = (stepTimes: StepTime[], beatFrame: number): number => {
  let page = 0;
  for (let k = 1; k < stepTimes.length; k++) if (beatFrame >= stepTimes[k].start) page = k;
  return page;
};
