import { PhoneScreen, fadeIn, pageAt } from '../components/PhoneScreen.tsx';
import { HomePage, SettingsPage } from './phonePages.tsx';
import { AddKeyboardSheet, FullAccessAlert, FullAccessPage, GeneralKbPage, KeyboardListPage, KeyboardMenuPage } from './phonePages2.tsx';
import type { ScreenProps } from './registry.tsx';

/** Scene 12, beat 0: Settings, 一般, 鍵盤, 鍵盤, 新增鍵盤. The page changes when the next step starts. */
export const KbSettings = ({ beatFrame, stepTimes }: ScreenProps) => {
  const page = pageAt(stepTimes, beatFrame);
  return (
    <PhoneScreen>
      {page === 0 ? <HomePage named="settings" /> : page === 1 ? <SettingsPage /> : page === 2 ? <GeneralKbPage /> : page === 3 ? <KeyboardMenuPage /> : <KeyboardListPage withRk={false} />}
    </PhoneScreen>
  );
};

/** Scene 12, beat 1: the 新增鍵盤 sheet; the pointer is on Remote Keyboard under 第三方鍵盤. */
export const KbAdd = () => (
  <PhoneScreen>
    <AddKeyboardSheet />
  </PhoneScreen>
);

/** Scene 12, beat 2: the keyboard list, now with Remote Keyboard. */
export const KbList = () => (
  <PhoneScreen>
    <KeyboardListPage withRk />
  </PhoneScreen>
);

/**
 * Scene 13. Beat 0: the switch is tapped, the warning comes in after that tap lands, 允許 turns the switch on and the
 * warning stays to the end of the beat. Beat 1: the switch is on.
 */
export const FullAccess = ({ beatIndex, beatFrame, stepTimes }: ScreenProps) => {
  if (beatIndex > 0) {
    return (
      <PhoneScreen>
        <FullAccessPage on={1} />
      </PhoneScreen>
    );
  }
  const toggleLand = stepTimes[0]?.land ?? Infinity;
  const allowLand = stepTimes[1]?.land ?? Infinity;
  return (
    <PhoneScreen>
      <FullAccessPage on={fadeIn(beatFrame, allowLand, 8)} />
      {beatFrame >= toggleLand && <FullAccessAlert opacity={fadeIn(beatFrame, toggleLand, 8)} />}
    </PhoneScreen>
  );
};
