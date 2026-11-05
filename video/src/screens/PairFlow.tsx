import { Layer } from '@kinetographdev/core';
import { PhoneScreen, pageAt } from '../components/PhoneScreen.tsx';
import { deviceBrightness } from '../lib/dim.ts';
import { ReceiverPanel } from './macReceiver.tsx';
import { PairCodePage, PairPage, PairSavedPage, PairWaitPage, SetupHomePage } from './phonePages3.tsx';
import { PANEL18 } from './layouts.ts';
import { PHONE_ORIGIN_RIGHT } from './phone.ts';
import type { ScreenProps } from './registry.tsx';

/** Frames after a beat starts at which the code shows up on both devices (the iPhone connected to the Mac). */
export const CODE_AT = 14;

/** A row lights up for a few frames around the press peak. */
const pressed = (beatFrame: number, land: number | undefined): number => (land === undefined ? 0 : Math.max(0, 1 - Math.abs(beatFrame - land) / 6));

/**
 * Scene 18. Beat 0 and 1: the panel in its idle state (尚未開始接收, 待命: nothing is receiving yet), then a press on 配對新 iPhone.
 * Pairing starts the receiving (ReceiverSecurity arms the central), so from beat 2 the panel looks for the iPhone and counts down. Beat 2: the panel waits; on the iPhone 已配對 Mac, then 配對 Mac.
 * Beat 3: both show the code (the waiting pages for the first CODE_AT frames). Beat 4: 確認 on the Mac, then on the iPhone.
 * Each press shows its result in the next beat, so the button the beat ends on is still on screen.
 */
export const PairFlow = ({ active, prevActive, deviceFrame, beatIndex, beatFrame, stepTimes }: ScreenProps) => {
  const dim = (d: 'mac' | 'iphone') => deviceBrightness(d, { active, prevActive, beatFrame: deviceFrame });
  const waiting = beatIndex === 2 || (beatIndex === 3 && beatFrame < CODE_AT);
  const code = beatIndex === 4 || (beatIndex === 3 && beatFrame >= CODE_AT);
  const panel = code ? PANEL18.code : waiting ? PANEL18.waiting : PANEL18.idle;
  const kind = code ? 'code' : waiting ? 'waiting' : 'idle';

  let phone;
  if (beatIndex <= 1) phone = <SetupHomePage press={0} />;
  else if (beatIndex === 2) {
    phone = pageAt(stepTimes, beatFrame) === 0
      ? <SetupHomePage press={pressed(beatFrame, stepTimes[0]?.land)} />
      : <PairPage paired={false} press={pressed(beatFrame, stepTimes[1]?.land)} />;
  } else if (!code) phone = <PairWaitPage />;
  else phone = <PairCodePage press={beatIndex === 4 ? pressed(beatFrame, stepTimes[1]?.land) : 0} />;

  return (
    <Layer id="screen-pairFlow">
      <Layer id="mac-device" opacity={dim('mac')}>
        <ReceiverPanel layout={panel} state={{ kind, link: kind === 'idle' ? 'idle' : kind === 'code' ? 'ready' : 'searching', access: false }} />
      </Layer>
      <PhoneScreen origin={PHONE_ORIGIN_RIGHT} brightness={dim('iphone')}>{phone}</PhoneScreen>
    </Layer>
  );
};

/**
 * Scene 19, one beat: 已儲存 on both. 完成 on the Mac (the panel then says 配對完成), then 完成 on the iPhone
 * (the page says 已配對 Mac, its 完成 stays where it was).
 */
export const PairDone = ({ active, prevActive, deviceFrame, beatFrame, stepTimes }: ScreenProps) => {
  const dim = (d: 'mac' | 'iphone') => deviceBrightness(d, { active, prevActive, beatFrame: deviceFrame });
  const macDone = beatFrame >= (stepTimes[0]?.land ?? Infinity) + 6;
  const phoneDone = beatFrame >= (stepTimes[1]?.land ?? Infinity) + 6;
  return (
    <Layer id="screen-pairDone">
      <Layer id="mac-device" opacity={dim('mac')}>
        <ReceiverPanel layout={macDone ? PANEL18.paired : PANEL18.saved} state={{ kind: macDone ? 'paired' : 'saved', link: 'ready', access: false }} />
      </Layer>
      <PhoneScreen origin={PHONE_ORIGIN_RIGHT} brightness={dim('iphone')}>
        <PairSavedPage paired={phoneDone} press={pressed(beatFrame, stepTimes[1]?.land)} />
      </PhoneScreen>
    </Layer>
  );
};
