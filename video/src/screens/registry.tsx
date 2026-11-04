import type { ReactNode } from 'react';
import type { PointerState } from '../lib/pointer.ts';
import type { Device } from '../lib/sceneSpec.ts';
import { DialogAuth } from './DialogAuth.tsx';
import { DialogBlocked } from './DialogBlocked.tsx';
import { DialogConfirm } from './DialogConfirm.tsx';
import { SettingsSecurity } from './SettingsSecurity.tsx';

/**
 * What a screen is told each frame.
 * - `active`: the device the current beat operates. Two-device screens draw the other one at `deviceBrightness`.
 * - `prevActive`: the previous beat's device when that beat shows the same screen (else undefined); `deviceBrightness` eases from it.
 * - `frame`: global frame. `localFrame`: frames since the scene started. `beatFrame`: frames since this beat started.
 * - `beatIndex`: index of this beat in the scene. Typing and list reveal count from `beatFrame`.
 * - `pointer`: where the pointer is; a dragged item is drawn at this position.
 */
export type ScreenProps = {
  active?: Device;
  prevActive?: Device;
  frame: number;
  localFrame: number;
  beatIndex: number;
  beatFrame: number;
  pointer: PointerState;
};

/** Screen id (a key of SCREENS in geometry.ts) to the component that draws it. */
export const SCREEN_VIEWS: Record<string, (props: ScreenProps) => ReactNode> = {
  dialogBlocked: () => <DialogBlocked />,
  settingsSecurity: () => <SettingsSecurity />,
  dialogConfirm: () => <DialogConfirm />,
  auth: () => <DialogAuth />,
};
