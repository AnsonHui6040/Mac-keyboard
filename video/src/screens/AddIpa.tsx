import { Fragment } from 'react';
import { spring, useVideoConfig } from '@kinetographdev/core';
import { PhoneScreen, fadeIn, pageAt } from '../components/PhoneScreen.tsx';
import { ExtensionDialog } from './extensionDialog.tsx';
import { ExtensionInset } from './extensionInset.tsx';
import { MyAppsPlusPage, PickerPage } from './phonePages2.tsx';
import type { ScreenProps } from './registry.tsx';

/** Scene 11, beat 0: My Apps (tap +), then the file picker (tap the .ipa). The page changes when the second step starts. */
export const AddIpa = ({ beatFrame, stepTimes }: ScreenProps) => (
  <PhoneScreen>{pageAt(stepTimes, beatFrame) === 0 ? <MyAppsPlusPage vpn /> : <PickerPage vpn />}</PhoneScreen>
);

/**
 * Scene 11, beats 1 to 3: My Apps with the App Contains Extensions dialog. The second row is tinted green from beat 1,
 * the Remove row red from beat 3 (the beat that carries both callouts). The dialog is never pressed.
 * The magnified option label (left of the phone) comes in with the good callout in beat 1, with the same spring, and stays.
 */
export const ExtDialog = ({ beatIndex, beatFrame }: ScreenProps) => {
  const { fps } = useVideoConfig();
  const rise = beatIndex === 1 ? Math.min(1, Math.max(0, spring({ frame: beatFrame, fps, config: { damping: 30, stiffness: 140 } }))) : 1;
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
