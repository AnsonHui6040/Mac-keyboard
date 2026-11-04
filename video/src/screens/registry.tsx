import type { ReactNode } from 'react';
import type { Device } from '../lib/sceneSpec.ts';
import { DialogAuth } from './DialogAuth.tsx';
import { DialogBlocked } from './DialogBlocked.tsx';
import { DialogConfirm } from './DialogConfirm.tsx';
import { SettingsSecurity } from './SettingsSecurity.tsx';

/** `active`: the device the current beat operates (two-device screens dim the other to 40% brightness). `frame`: global frame. `localFrame`: frames since the scene started. */
export type ScreenProps = { active?: Device; frame: number; localFrame: number };

/** Screen id (a key of SCREENS in geometry.ts) to the component that draws it. */
export const SCREEN_VIEWS: Record<string, (props: ScreenProps) => ReactNode> = {
  dialogBlocked: () => <DialogBlocked />,
  settingsSecurity: () => <SettingsSecurity />,
  dialogConfirm: () => <DialogConfirm />,
  auth: () => <DialogAuth />,
};
