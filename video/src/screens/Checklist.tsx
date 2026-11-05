import { Layer, Rect, Text } from '@kinetographdev/core';
import { CableLine, LaptopLine, PersonLine, PhoneLine, WifiLine } from '../components/icons.tsx';
import { fadeIn } from '../components/PhoneScreen.tsx';
import type { ScreenProps } from './registry.tsx';
import { theme } from '../theme.ts';

type Item = { icon: (p: { x: number; y: number; size: number; color: string }) => React.ReactNode; name: string; note?: string };
const ITEMS: Item[] = [
  { icon: PhoneLine, name: 'iPhone', note: 'iOS 18 以上，已設定螢幕鎖定密碼' },
  { icon: LaptopLine, name: 'Mac', note: 'macOS 15 以上，Apple 晶片' },
  { icon: CableLine, name: 'USB 線' },
  { icon: WifiLine, name: 'Wi-Fi' },
  { icon: PersonLine, name: 'Apple 帳號', note: '你自己的免費帳號' },
];
/** Frame within its beat when item i appears. Items 0 to 3 come in beat 0 (the first clause of the sentence), item 4 in beat 1. */
export const ITEM_AT = [14, 62, 110, 158, 14];
const ROW = 134;
const TOP = 126;

/** Scene 2: the five things to prepare, one row at a time. No device, no pointer. */
export const Checklist = ({ beatIndex, beatFrame }: ScreenProps) => (
  <Layer id="screen-checklist">
    {ITEMS.map((it, i) => {
      const shown = i < 4 ? (beatIndex >= 1 ? 1 : fadeIn(beatFrame, ITEM_AT[i], 14)) : beatIndex >= 1 ? fadeIn(beatFrame, ITEM_AT[i], 14) : 0;
      const y = TOP + i * ROW;
      return (
        <Layer key={it.name} id={`item-${i}`} opacity={shown} y={(1 - shown) * 22}>
          {it.icon({ x: 380, y: y - 4, size: 92, color: theme.ink })}
          <Text font={theme.font} weight={700} size={56} color={theme.ink} x={520} y={y + 4}>{it.name}</Text>
          {it.note && <Text font={theme.font} weight={500} size={38} color={theme.muted} x={880} y={y + 16}>{it.note}</Text>}
          {i < ITEMS.length - 1 && <Rect x={380} y={y + ROW - 16} width={1160} height={2} fill={theme.hairline} />}
        </Layer>
      );
    })}
  </Layer>
);
