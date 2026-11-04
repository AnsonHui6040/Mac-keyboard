import { Layer, Text } from '@kinetographdev/core';
import { LockIcon, NoMark } from '../components/icons.tsx';
import { fadeIn } from '../components/PhoneScreen.tsx';
import type { ScreenProps } from './registry.tsx';
import { theme } from '../theme.ts';

const LINES = ['不把 Apple 帳號密碼和驗證碼交給任何人', '不用這個鍵盤輸入密碼'];

/** Scene 3: a padlock, then the two reminders one by one. */
export const Reminders = ({ beatIndex, beatFrame }: ScreenProps) => {
  const lock = fadeIn(beatFrame + (beatIndex > 0 ? 100 : 0), 0, 16);
  return (
    <Layer id="screen-reminders">
      <Layer id="lock-group" opacity={lock} y={(1 - lock) * 16}>
        <LockIcon x={800} y={96} size={320} color={theme.ink} accent={theme.stage} />
      </Layer>
      {LINES.map((text, i) => {
        const shown = beatIndex > i ? 1 : beatIndex === i ? fadeIn(beatFrame, i === 0 ? 24 : 8, 14) : 0;
        const y = 500 + i * 140;
        return (
          <Layer key={text} id={`reminder-${i}`} opacity={shown} y={(1 - shown) * 20}>
            <NoMark x={420} y={y - 6} size={92} color={theme.bad} />
            <Text font={theme.font} weight={700} size={60} color={theme.ink} x={550} y={y + 4}>{text}</Text>
          </Layer>
        );
      })}
    </Layer>
  );
};
