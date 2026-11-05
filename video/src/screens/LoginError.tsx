import { Layer, Text } from '@kinetographdev/core';
import { PhoneScreen, fadeIn } from '../components/PhoneScreen.tsx';
import { ErrorAlert, SignInPage } from './phonePages.tsx';
import type { ScreenProps } from './registry.tsx';
import { theme } from '../theme.ts';

/** Scene 9. The -80045 alert on the sign-in page, and where to read about it. */
export const LoginError = ({ beatFrame }: ScreenProps) => {
  const note = fadeIn(beatFrame, 60, 14);
  return (
    <Layer id="screen-loginError">
      <PhoneScreen>
        <SignInPage />
        <ErrorAlert opacity={fadeIn(beatFrame, 18, 8)} />
      </PhoneScreen>
      <Layer id="manual-note" opacity={note} y={(1 - note) * 14}>
        <Text font={theme.font} weight={700} size={64} color={theme.ink} x={1250} y={380}>手冊第 02 章</Text>
        <Text font={theme.font} weight={500} size={36} color={theme.muted} x={1250} y={470}>登入出現 -80045</Text>
      </Layer>
    </Layer>
  );
};
