import type { ReactNode } from 'react';
import type { PointerState } from '../lib/pointer.ts';
import type { Device, StepTime } from '../lib/sceneSpec.ts';
import { DialogAuth } from './DialogAuth.tsx';
import { DialogBlocked } from './DialogBlocked.tsx';
import { DialogConfirm } from './DialogConfirm.tsx';
import { SettingsSecurity } from './SettingsSecurity.tsx';
import { Checklist } from './Checklist.tsx';
import { Iloader } from './Iloader.tsx';
import { LoginError } from './LoginError.tsx';
import { MyApps } from './MyApps.tsx';
import { Reminders } from './Reminders.tsx';
import { SettingsFlow } from './SettingsFlow.tsx';
import { SignIn } from './SignIn.tsx';
import { Typing } from './Typing.tsx';
import { VpnFlow } from './VpnFlow.tsx';
import { AddIpa, ExtDialog } from './AddIpa.tsx';
import { AppSetup } from './AppSetup.tsx';
import { IpaDownload, IpaSave, IpaVerify } from './IpaFlow.tsx';
import { FullAccess, KbAdd, KbList, KbSettings } from './KeyboardFlow.tsx';
import { ZipFlow } from './ZipFlow.tsx';
import { MacAccess, MacBluetooth, ReceiverMenu } from './ReceiverFlow.tsx';
import { PairDone, PairFlow } from './PairFlow.tsx';
import { KeyboardOn } from './KeyboardOn.tsx';
import { Calendar } from './Calendar.tsx';

/**
 * What a screen is told each frame.
 * - `active`: the device the current beat operates. Two-device screens draw the other one at `deviceBrightness`.
 * - `prevActive`: the device operated before `active` (the previous beat's, when it shows the same screen; or the one before a change inside this beat), else undefined; `deviceBrightness` eases from it.
 * - `deviceFrame`: frames since `active` took over (the beat start, or the start of the step slot where this beat changed device). Pass it as `beatFrame` to `deviceBrightness`.
 * - `frame`: global frame. `localFrame`: frames since the scene started. `beatFrame`: frames since this beat started.
 * - `beatIndex`: index of this beat in the scene. Typing and list reveal count from `beatFrame`.
 * - `pointer`: where the pointer is; a dragged item is drawn at this position.
 * - `stepTimes`: per step of this beat, when the pointer starts moving (`start`) and when it lands (`land`: arrival, or the press peak),
 *   in frames since the beat started. A screen shows a step's result from `land` on, or swaps pages at the next step's `start`.
 */
export type ScreenProps = {
  active?: Device;
  prevActive?: Device;
  deviceFrame: number;
  frame: number;
  localFrame: number;
  beatIndex: number;
  beatFrame: number;
  pointer: PointerState;
  stepTimes: StepTime[];
};

/** Screen id (a key of SCREENS in geometry.ts) to the component that draws it. */
export const SCREEN_VIEWS: Record<string, (props: ScreenProps) => ReactNode> = {
  dialogBlocked: () => <DialogBlocked />,
  settingsSecurity: () => <SettingsSecurity />,
  dialogConfirm: () => <DialogConfirm />,
  auth: () => <DialogAuth />,
  typing: (p) => <Typing {...p} />,
  checklist: (p) => <Checklist {...p} />,
  reminders: (p) => <Reminders {...p} />,
  vpnFlow: (p) => <VpnFlow {...p} />,
  iloader: (p) => <Iloader {...p} />,
  settingsFlow: (p) => <SettingsFlow {...p} />,
  signIn: (p) => <SignIn {...p} />,
  myApps: (p) => <MyApps {...p} />,
  loginError: (p) => <LoginError {...p} />,
  ipaDownload: (p) => <IpaDownload {...p} />,
  ipaVerify: (p) => <IpaVerify {...p} />,
  ipaSave: (p) => <IpaSave {...p} />,
  addIpa: (p) => <AddIpa {...p} />,
  extDialog: (p) => <ExtDialog {...p} />,
  kbSettings: (p) => <KbSettings {...p} />,
  kbAdd: () => <KbAdd />,
  kbList: () => <KbList />,
  fullAccess: (p) => <FullAccess {...p} />,
  appSetup: (p) => <AppSetup {...p} />,
  zipFlow: (p) => <ZipFlow {...p} />,
  macBluetooth: () => <MacBluetooth />,
  receiverMenu: (p) => <ReceiverMenu {...p} />,
  macAccess: (p) => <MacAccess {...p} />,
  pairFlow: (p) => <PairFlow {...p} />,
  pairDone: (p) => <PairDone {...p} />,
  keyboardOn: (p) => <KeyboardOn {...p} />,
  calendar: (p) => <Calendar {...p} />,
};
