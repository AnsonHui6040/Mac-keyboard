import { PhoneScreen, fadeIn, pageAt } from '../components/PhoneScreen.tsx';
import { BluetoothAlert, GuidePage, HomeRkPage, MainPage } from './phonePages2.tsx';
import type { ScreenProps } from './registry.tsx';

/**
 * Scene 14. Beat 0: the home screen (tap the app), the four guide pages (a tap on 下一步 each, 完成 on the last),
 * then the main screen (tap 藍牙). Beat 1: 藍牙 is open with 允許藍牙; its tap brings in the system question, 允許 answers it.
 * Beat 2: 藍牙 is ticked.
 */
export const AppSetup = ({ beatIndex, beatFrame, stepTimes }: ScreenProps) => {
  if (beatIndex === 0) {
    const page = pageAt(stepTimes, beatFrame);
    return (
      <PhoneScreen>
        {page === 0 ? <HomeRkPage /> : page <= 4 ? <GuidePage index={page - 1} /> : <MainPage state="initial" />}
      </PhoneScreen>
    );
  }
  if (beatIndex === 1) {
    const land = stepTimes[0]?.land ?? Infinity;
    return (
      <PhoneScreen>
        <MainPage state="open" />
        {beatFrame >= land && <BluetoothAlert opacity={fadeIn(beatFrame, land, 8)} />}
      </PhoneScreen>
    );
  }
  return (
    <PhoneScreen>
      <MainPage state="done" />
    </PhoneScreen>
  );
};
