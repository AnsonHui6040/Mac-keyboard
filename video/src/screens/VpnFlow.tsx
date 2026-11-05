import { PhoneScreen, fadeIn } from '../components/PhoneScreen.tsx';
import { AppStorePage, VpnAllowAlert, VpnPage } from './phonePages.tsx';
import type { ScreenProps } from './registry.tsx';

/** Scene 4. Beat 0: App Store page of LocalDevVPN. Beat 1: the app, connect, the allow alert, then 已連線. */
export const VpnFlow = ({ beatIndex, beatFrame, stepTimes }: ScreenProps) => {
  if (beatIndex === 0) {
    return (
      <PhoneScreen>
        <AppStorePage />
      </PhoneScreen>
    );
  }
  const connectLand = stepTimes[0]?.land ?? Infinity;
  const allowLand = stepTimes[1]?.land ?? Infinity;
  const connected = beatFrame >= allowLand;
  const alert = fadeIn(beatFrame, connectLand) * (1 - fadeIn(beatFrame, allowLand, 4));
  return (
    <PhoneScreen>
      <VpnPage connected={connected} />
      {alert > 0 && <VpnAllowAlert opacity={alert} />}
    </PhoneScreen>
  );
};
