import { PhoneScreen, pageAt } from '../components/PhoneScreen.tsx';
import { HomePage, SignInPage, VpnPage } from './phonePages.tsx';
import type { ScreenProps } from './registry.tsx';

/** Scene 7. Beat 0: LocalDevVPN shows 已連線, then the home screen with SideStore. Beat 1: SideStore sign-in. */
export const SignIn = ({ beatIndex, beatFrame, stepTimes }: ScreenProps) => (
  <PhoneScreen>
    {beatIndex === 0 ? (pageAt(stepTimes, beatFrame) === 0 ? <VpnPage connected /> : <HomePage named="sidestore" />) : <SignInPage />}
  </PhoneScreen>
);
