import { Fragment } from 'react';
import { Layer, spring, useVideoConfig } from '@kinetographdev/core';
import { PhoneScreen, fadeIn, pageAt } from '../components/PhoneScreen.tsx';
import { ExtensionDialog } from './extensionDialog.tsx';
import { ExtensionInset } from './extensionInset.tsx';
import { MyAppsInstalledPage, MyAppsPlusPage, PickerPage } from './phonePages2.tsx';
import type { ScreenProps } from './registry.tsx';

/** Scene 11, beat 0: My Apps (tap +), then the file picker (tap the .ipa). The page changes when the second step starts. */
export const AddIpa = ({ beatFrame, stepTimes }: ScreenProps) => (
  <PhoneScreen>{pageAt(stepTimes, beatFrame) === 0 ? <MyAppsPlusPage vpn /> : <PickerPage vpn />}</PhoneScreen>
);

/** Frames after the Register option is pressed until the dialog is gone. */
const DISMISS_FRAMES = 6;

/**
 * Scene 11, beats 1 to 4: My Apps with the App Contains Extensions dialog. The second row is tinted green from beat 1,
 * the Remove row red from beat 3 (the beat that carries both callouts). In beats 1 to 3 the dialog is not pressed.
 * The magnified option label (left of the phone) comes in with the good callout in beat 1, with the same spring, and stays while the dialog does.
 * Beat 4, two steps: the pointer presses the second option, the dialog goes and a bar fills to the second step's start; then My Apps
 * lists Remote Keyboard under SideStore, and the pointer rests on its icon.
 */
export const ExtDialog = ({ beatIndex, beatFrame, stepTimes }: ScreenProps) => {
  const { fps } = useVideoConfig();
  const rise = beatIndex === 1 ? Math.min(1, Math.max(0, spring({ frame: beatFrame, fps, config: { damping: 30, stiffness: 140 } }))) : 1;
  if (beatIndex === 4) {
    const pressed = (stepTimes[0]?.land ?? Infinity) + 4;
    const listed = stepTimes[1]?.start ?? Infinity;
    if (beatFrame >= pressed + DISMISS_FRAMES) {
      const progress = (beatFrame - pressed - DISMISS_FRAMES) / Math.max(1, listed - pressed - DISMISS_FRAMES);
      return <PhoneScreen><MyAppsInstalledPage progress={progress} installed={beatFrame >= listed} /></PhoneScreen>;
    }
    const fade = 1 - fadeIn(beatFrame, pressed, DISMISS_FRAMES);
    return (
      <Fragment>
        <PhoneScreen>
          <MyAppsPlusPage vpn />
          <ExtensionDialogFaded opacity={fade} />
        </PhoneScreen>
        <ExtensionInset opacity={fade} />
      </Fragment>
    );
  }
  return (
    <Fragment>
      <PhoneScreen>
        <MyAppsPlusPage vpn />
        <ExtensionDialog tintGood={beatIndex === 1 ? fadeIn(beatFrame, 6, 12) : 1} tintBad={beatIndex >= 3 ? fadeIn(beatFrame, 0, 12) : 0} />
      </PhoneScreen>
      <ExtensionInset opacity={rise} />
    </Fragment>
  );
};

const ExtensionDialogFaded = ({ opacity }: { opacity: number }) => <Layer id="dialog-fade" opacity={opacity}><ExtensionDialog tintGood={1} tintBad={1} /></Layer>;
