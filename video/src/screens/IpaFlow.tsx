import { PhoneScreen, fadeIn, pageAt } from '../components/PhoneScreen.tsx';
import { HomePage } from './phonePages.tsx';
import { ShareSheetOverlay } from './phonePages2.tsx';
import { AirDropPage, ReleasePage, TerminalPage } from './macPages.tsx';
import type { ScreenProps } from './registry.tsx';

/** Scene 10, beat 0: the Release page; the pointer is on the .ipa row. After it lands the row lights up and the download mark shows. */
export const IpaDownload = ({ beatFrame, stepTimes }: ScreenProps) => {
  const land = stepTimes[0]?.land ?? Infinity;
  return <ReleasePage row="ipa" hover={fadeIn(beatFrame, land - 4, 6)} downloaded={fadeIn(beatFrame, land + 4, 8)} />;
};

/** Scene 10, beat 1: Terminal with the two values (green marks once the pointer is on them), then the AirDrop window (the ring shows once 我的 iPhone is pressed). */
export const IpaVerify = ({ beatFrame, stepTimes }: ScreenProps) => {
  const page = pageAt(stepTimes, beatFrame);
  if (page === 0) return <TerminalPage kind="ipa" match={fadeIn(beatFrame, stepTimes[0]?.land ?? Infinity, 10)} />;
  return <AirDropPage sent={fadeIn(beatFrame, stepTimes[1]?.land ?? Infinity, 14)} />;
};

/** Scene 10, beat 2, on the iPhone: the AirDrop share sheet with 儲存到「檔案」. */
export const IpaSave = ({ beatFrame }: ScreenProps) => (
  <PhoneScreen>
    <HomePage />
    <ShareSheetOverlay opacity={fadeIn(beatFrame, 0, 8)} />
  </PhoneScreen>
);
