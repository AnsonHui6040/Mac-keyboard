import { PhoneScreen, fadeIn } from '../components/PhoneScreen.tsx';
import { IPA_NAME } from '../data/artifacts.ts';
import { HomePage } from './phonePages.tsx';
import { ShareSheetOverlay } from './phonePages2.tsx';
import { AirDropPage, ReleasePage, TerminalPage } from './macPages.tsx';
import { commandText, matchAt } from './terminal.ts';
import type { ScreenProps } from './registry.tsx';

/** Scene 10, beat 0: the Release page; the pointer is on the .ipa row. After it lands the row lights up and the download mark shows. */
export const IpaDownload = ({ beatFrame, stepTimes }: ScreenProps) => {
  const land = stepTimes[0]?.land ?? Infinity;
  return <ReleasePage row="ipa" hover={fadeIn(beatFrame, land - 4, 6)} downloaded={fadeIn(beatFrame, land + 4, 8)} />;
};

/**
 * Scene 10, beat 1: 終端機. The command is typed, the output shows, and green marks say it equals the Release page's value
 * once the pointer is on the two values. Both values then stay on screen to the end of the beat (`minSeconds` in the scene data).
 */
export const IpaVerify = ({ beatFrame, stepTimes }: ScreenProps) => {
  const at = matchAt(commandText(IPA_NAME).length, stepTimes[0]?.land ?? Infinity);
  return <TerminalPage kind="ipa" pageFrame={beatFrame} match={fadeIn(beatFrame, at, 10)} />;
};

/**
 * Scene 10, beat 2: the AirDrop window on the Mac (the ring shows once 我的 iPhone is pressed), then, when the second step starts
 * on the iPhone, the AirDrop share sheet with 儲存到「檔案」.
 */
export const IpaSend = ({ beatFrame, stepTimes }: ScreenProps) => {
  const phoneAt = stepTimes[1]?.start ?? Infinity;
  if (beatFrame < phoneAt) return <AirDropPage sent={fadeIn(beatFrame, stepTimes[0]?.land ?? Infinity, 14)} />;
  return (
    <PhoneScreen>
      <HomePage />
      <ShareSheetOverlay opacity={fadeIn(beatFrame, phoneAt, 8)} />
    </PhoneScreen>
  );
};
