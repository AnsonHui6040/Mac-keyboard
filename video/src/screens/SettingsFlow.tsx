import { Layer } from '@kinetographdev/core';
import { PhoneScreen, clamp01, fadeIn, pageAt } from '../components/PhoneScreen.tsx';
import { DevModeAlert, DevPage, GeneralPage, HomePage, PasscodePage, PrivacyPage, RestartAlert, SettingsPage, VpnMgmtPage } from './phonePages.tsx';
import type { ScreenProps } from './registry.tsx';

/** Frames between filled passcode dots. */
const DOT_FRAMES = 7;

const dotsSince = (beatFrame: number, from: number): number => Math.max(0, Math.min(6, Math.floor((beatFrame - from) / DOT_FRAMES) + 1));

/**
 * Scene 6, all on the iPhone. A beat is a short walk through pages; the page changes when the next step starts.
 * Beat 0: home, Settings, General (taps 設定, 一般, VPN與裝置管理). Beat 1: VPN與裝置管理 list, the developer, 信任, the alert, the passcode.
 * Beat 2: Settings, 隱私權與安全性, 開發者模式 switched on. Beat 3: the screen after the restart, the confirmation, the passcode.
 */
export const SettingsFlow = ({ beatIndex, beatFrame, stepTimes }: ScreenProps) => {
  const page = pageAt(stepTimes, beatFrame);

  if (beatIndex === 0) {
    return <PhoneScreen>{page === 0 ? <HomePage named="settings" /> : page === 1 ? <SettingsPage /> : <GeneralPage />}</PhoneScreen>;
  }

  if (beatIndex === 1) {
    const trustLand = stepTimes[1]?.land ?? Infinity;
    const alert = page === 1 ? fadeIn(beatFrame, trustLand) : page === 2 ? 1 : 0;
    const pageNode = page === 0 ? <VpnMgmtPage /> : page <= 2 ? <DevPage /> : <PasscodePage dots={dotsSince(beatFrame, (stepTimes[3]?.start ?? 0) + 18)} />;
    return (
      <PhoneScreen>
        {pageNode}
        {alert > 0 && page <= 2 && <RestartAlert opacity={alert} />}
      </PhoneScreen>
    );
  }

  if (beatIndex === 2) {
    const toggle = clamp01((beatFrame - (stepTimes[1]?.land ?? Infinity)) / 6);
    return <PhoneScreen>{page === 0 ? <SettingsPage /> : <PrivacyPage toggle={toggle} />}</PhoneScreen>;
  }

  // Beat 3: dark while the phone restarts, then the confirmation, then the passcode.
  const alert = fadeIn(beatFrame, 8, 6);
  return (
    <PhoneScreen>
      {page === 0 ? (
        <Layer id="restart">{alert > 0 && <DevModeAlert opacity={alert} />}</Layer>
      ) : (
        <PasscodePage dots={dotsSince(beatFrame, (stepTimes[1]?.start ?? 0) + 18)} />
      )}
    </PhoneScreen>
  );
};
