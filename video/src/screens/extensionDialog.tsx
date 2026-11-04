/**
 * The App Contains Extensions dialog of scene 11. Its two long labels are drawn smaller, each on one line: that is how
 * the real dialog looks (the labels shrink to fit), and it is the one place an iPhone label is below PHONE_MIN_TEXT.
 * This file is not in the phoneText test on purpose.
 */
import { Layer, Rect, Text } from '@kinetographdev/core';
import { Btn, PText, Skel, Scrim, ios } from '../components/ios.tsx';
import { theme } from '../theme.ts';
import { EM, FULL, fitSize } from './extensionFit.ts';
import * as L from './layouts.ts';

const BUTTONS = [
  { target: 'keepMain', label: 'Keep App Extensions (Use Main Profile)', size: fitSize(EM.keepMain), color: ios.blue, weight: 500 as const },
  { target: 'keepEach', label: 'Keep App Extensions (Register App ID for Each Extension)', size: fitSize(EM.keepEach), color: ios.blue, weight: 500 as const },
  { target: 'remove', label: 'Remove App Extensions', size: FULL, color: ios.red, weight: 500 as const },
  { target: 'choose', label: 'Choose App Extensions', size: FULL, color: ios.blue, weight: 500 as const },
  { target: 'cancel', label: 'Cancel', size: FULL, color: ios.blue, weight: 700 as const },
];

/**
 * `tintGood` and `tintBad` (0 to 1) fade in a green fill on the second row and a red fill on the Remove row, so the
 * two rows read at a glance while their callouts are on.
 */
export const ExtensionDialog = ({ tintGood, tintBad }: { tintGood: number; tintBad: number }) => {
  const c = L.EXT_CARD;
  return (
    <Layer id="alert">
      <Scrim opacity={1} />
      <Rect x={c.x} y={c.y} width={c.width} height={c.height} radius={30} fill={ios.card2} stroke={{ color: '#48484a', width: 1.5 }} />
      <PText x={c.x + 12} y={L.EXT_TITLE_Y} size={26} weight={700} w={c.width - 24} align="center">App Contains Extensions</PText>
      <Skel x={c.x + 60} y={L.EXT_BODY_Y} w={c.width - 120} />
      <Skel x={c.x + 100} y={L.EXT_BODY_Y + 38} w={c.width - 200} />
      {BUTTONS.map((b, i) => {
        const r = L.extBtn(i);
        const tint = b.target === 'keepEach' ? tintGood : b.target === 'remove' ? tintBad : 0;
        const tone = b.target === 'remove' ? '#4a2220' : '#1d4a2d';
        return (
          <Layer key={b.target}>
            <Rect x={c.x} y={c.y + 160 + 88 * i} width={c.width} height={1.5} fill={ios.sep} />
            <Btn target={b.target} rect={r}>
              <Rect width={r.width} height={r.height} radius={r.height / 2} fill={tone} opacity={tint} />
              <Text font={theme.font} weight={b.weight} size={b.size} color={b.color} x={0} y={(r.height - b.size * 1.45) / 2} maxWidth={r.width} align="center">{b.label}</Text>
            </Btn>
          </Layer>
        );
      })}
    </Layer>
  );
};
