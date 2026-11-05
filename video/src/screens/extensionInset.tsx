import { Layer, Rect, Text } from '@kinetographdev/core';
import { ios } from '../components/ios.tsx';
import { theme } from '../theme.ts';
import { INSET_CARD, INSET_LEADER, INSET_LINES, INSET_LINE_HEIGHT, INSET_PAD_Y, INSET_RING_WIDTH, INSET_SIZE, INSET_WEIGHT } from './extensionInset.ts';

/** A magnified copy of the second option, with the good callout's green ring and a thin leader line to the phone's row. `opacity` follows the good label. */
export const ExtensionInset = ({ opacity }: { opacity: number }) => {
  const c = INSET_CARD;
  const l = INSET_LEADER;
  return (
    <Layer id="ext-inset" opacity={opacity}>
      <Rect id="ext-inset-card" x={c.x} y={c.y} width={c.width} height={c.height} radius={28} fill={ios.card2} stroke={{ color: theme.good.ring, width: INSET_RING_WIDTH }} />
      <Text id="ext-inset-text" font={theme.font} weight={INSET_WEIGHT} size={INSET_SIZE} color={ios.blue} x={c.x} y={c.y + INSET_PAD_Y} maxWidth={c.width} align="center" lineHeight={INSET_LINE_HEIGHT}>
        {INSET_LINES.join('\n')}
      </Text>
      <Rect id="ext-inset-leader" x={l.x1} y={l.y - l.width / 2} width={l.x2 - l.x1} height={l.width} fill={theme.good.ring} />
    </Layer>
  );
};
