import { Layer, Rect, Text } from '@kinetographdev/core';
import { wrapBeat } from '../lib/captions.ts';
import { theme } from '../theme.ts';

/** Divider plus one centered subtitle beat (at most two lines, wrapped by wrapBeat). */
export const Subtitle = ({ beat }: { beat: string }) => (
  <Layer id="subtitle-area">
    <Rect id="subtitle-divider" {...theme.divider} fill={theme.hairline} />
    <Text id="subtitle" font={theme.font} weight={theme.subtitle.weight} size={theme.subtitle.size} color={theme.ink}
      x={theme.divider.x} y={theme.subtitle.y} maxWidth={theme.subtitle.maxWidth} align="center" lineHeight={theme.subtitle.lineHeight}>
      {wrapBeat(beat).join('\n')}
    </Text>
  </Layer>
);
