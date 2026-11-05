import { Layer, Rect, Text } from '@kinetographdev/core';
import { SideStoreIcon } from '../components/icons.tsx';
import { fadeIn } from '../components/PhoneScreen.tsx';
import { REPO_URL } from '../data/artifacts.ts';
import { theme } from '../theme.ts';
import { CARD, DAYS, MARKED_DAYS, MARK_PITCH, MARK_START, cellRect } from './calendar.ts';
import type { ScreenProps } from './registry.tsx';

const NONE = '#00000000';
const LINK = '#6cb0ff';
const Right = ({ opacity, children }: { opacity: number; children: React.ReactNode }) => <Layer opacity={opacity}>{children}</Layer>;

/**
 * Scene 21, no device. A month with the first 7 days marked one after another (beat 0); the 7th day is circled and SideStore
 * named for the refresh (beat 1); the manual on GitHub (beat 2).
 */
export const Calendar = ({ beatIndex, beatFrame }: ScreenProps) => {
  const last = cellRect(MARKED_DAYS);
  // In beat 2 the calendar fades out so the manual and its address have the whole width, at a size a phone screen can read.
  const calendar = beatIndex === 2 ? 1 - fadeIn(beatFrame, 0, 8) : 1;
  return (
    <Layer id="screen-calendar">
      <Layer id="calendar-card" opacity={calendar}>
      <Rect x={CARD.x} y={CARD.y} width={CARD.width} height={CARD.height} radius={26} fill="#222328" stroke={{ color: theme.hairline, width: 2 }} />
      <Rect x={CARD.x + 32} y={CARD.y + 32} width={260} height={28} radius={14} fill={theme.skeleton.color} />
      {Array.from({ length: DAYS }, (_, k) => {
        const day = k + 1;
        const r = cellRect(day);
        const mark = day <= MARKED_DAYS ? (beatIndex === 0 ? fadeIn(beatFrame, MARK_START + (day - 1) * MARK_PITCH, 6) : 1) : 0;
        return (
          <Layer key={day} id={`day-${day}`} x={r.x} y={r.y}>
            <Rect width={r.width} height={r.height} radius={14} fill="#2c2d32" />
            <Rect width={r.width} height={r.height} radius={14} fill={theme.blue} opacity={mark} />
            <Text font={theme.font} weight={500} size={34} color={mark > 0.5 ? '#ffffff' : theme.muted} x={0} y={(r.height - 34 * 1.45) / 2} maxWidth={r.width} align="center">{String(day)}</Text>
          </Layer>
        );
      })}
      {beatIndex >= 1 && (
        <Rect id="last-day-ring" x={last.x - 7} y={last.y - 7} width={last.width + 14} height={last.height + 14} radius={20} fill={NONE}
          stroke={{ color: theme.good.ring, width: 5 }} opacity={beatIndex === 1 ? fadeIn(beatFrame, 0, 8) : 1} />
      )}
      </Layer>
      {beatIndex === 1 && (
        <Right opacity={fadeIn(beatFrame, 6, 10)}>
          <SideStoreIcon x={1260} y={360} size={150} />
          <Text font={theme.font} weight={700} size={56} color={theme.ink} x={1440} y={360}>SideStore</Text>
          <Text font={theme.font} weight={500} size={48} color={theme.muted} x={1440} y={440}>續簽</Text>
        </Right>
      )}
      {beatIndex === 2 && (
        <Right opacity={fadeIn(beatFrame, 6, 10)}>
          <Text id="manual-link" font={theme.font} weight={700} size={72} color={LINK} x={0} y={330} maxWidth={1920} align="center">GitHub 上的使用手冊</Text>
          <Text id="repo-address" font={theme.font} weight={500} size={60} color={theme.ink} x={0} y={470} maxWidth={1920} align="center">{REPO_URL}</Text>
        </Right>
      )}
    </Layer>
  );
};
